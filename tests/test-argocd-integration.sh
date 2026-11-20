#!/bin/bash
#
# Integration tests for ArgoCD Transcrypt Plugin
#
# Tests the full integration with ArgoCD in a Kind cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KIND_CLUSTER_NAME="argocd-transcrypt-test"
TEST_NAMESPACE="argocd"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Cleanup function
# shellcheck disable=SC2317,SC2329
cleanup() {
    log_info "Cleaning up test environment..."
    kind delete cluster --name "$KIND_CLUSTER_NAME" 2>/dev/null || true
}

# Register cleanup on exit
trap cleanup EXIT

echo "======================================"
echo "ArgoCD Transcrypt Integration Tests"
echo "======================================"
echo ""

# Step 1: Create Kind cluster
log_info "Creating Kind cluster: $KIND_CLUSTER_NAME"
if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log_warn "Cluster already exists, deleting..."
    kind delete cluster --name "$KIND_CLUSTER_NAME"
fi

kind create cluster --name "$KIND_CLUSTER_NAME" --wait 5m
if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log_success "Kind cluster created"
else
    log_error "Failed to create Kind cluster"
    exit 1
fi

# Step 2: Install ArgoCD
log_info "Installing ArgoCD..."
kubectl create namespace "$TEST_NAMESPACE" || true
kubectl apply --server-side -n "$TEST_NAMESPACE" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log_info "Waiting for ArgoCD pods to be ready..."
if kubectl wait --for=condition=Ready pods --all -n "$TEST_NAMESPACE" --timeout=300s; then
    log_success "ArgoCD installed and ready"
else
    log_error "ArgoCD installation failed or timed out"
    exit 1
fi

# Step 3: Build and load custom image
log_info "Building custom ArgoCD image..."
if docker build -t argocd-transcrypt-plugin:test ./docker/; then
    log_success "Image built successfully"
else
    log_error "Failed to build image"
    exit 1
fi

log_info "Loading image into Kind cluster..."
if kind load docker-image argocd-transcrypt-plugin:test --name "$KIND_CLUSTER_NAME"; then
    log_success "Image loaded into cluster"
else
    log_error "Failed to load image"
    exit 1
fi

# Step 4: Create transcrypt secret with multi-repo support
log_info "Creating transcrypt secret with multi-repo passwords..."

# Create test passwords for different repos
TEST_PASSWORD_DEFAULT="default-test-password-$(openssl rand -hex 8)"
TEST_PASSWORD_REPO1="repo1-test-password-$(openssl rand -hex 8)"
TEST_PASSWORD_REPO2="repo2-test-password-$(openssl rand -hex 8)"

kubectl create secret generic transcrypt-password \
    --from-literal=password="$TEST_PASSWORD_DEFAULT" \
    --from-literal=cipher="aes-256-cbc" \
    --from-literal=github.com_example_repo1="$TEST_PASSWORD_REPO1" \
    --from-literal=github.com_example_repo2="$TEST_PASSWORD_REPO2" \
    --from-literal=_tmp_e2e-remote_remote="S3cret-pw" \
    -n "$TEST_NAMESPACE"

if kubectl get secret transcrypt-password -n "$TEST_NAMESPACE" &>/dev/null; then
    log_success "Transcrypt secret created with multi-repo support"
else
    log_error "Failed to create secret"
    exit 1
fi

# Step 5: Patch ArgoCD repo-server
log_info "Patching ArgoCD repo-server..."

# Use strategic merge patch to add our customizations
kubectl patch deployment argocd-repo-server -n "$TEST_NAMESPACE" --type='strategic' --patch '
spec:
  template:
    spec:
      containers:
      - name: argocd-repo-server
        image: argocd-transcrypt-plugin:test
        imagePullPolicy: Never
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 999
        volumeMounts:
        - name: transcrypt-secret
          mountPath: /transcrypt-secret
          readOnly: true
      volumes:
      - name: transcrypt-secret
        secret:
          secretName: transcrypt-password
          defaultMode: 0440
      securityContext:
        fsGroup: 999
'

if kubectl get deployment argocd-repo-server -n "$TEST_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q "argocd-transcrypt-plugin:test"; then
    log_success "Repo-server patched"
else
    log_error "Failed to patch repo-server"
    exit 1
fi

# Step 6: Wait for rollout
log_info "Waiting for repo-server rollout..."
if kubectl rollout status deployment/argocd-repo-server -n "$TEST_NAMESPACE" --timeout=300s; then
    log_success "Repo-server rollout complete"
else
    log_error "Repo-server rollout failed"
    exit 1
fi

# Give pods a moment to fully stabilize
log_info "Waiting for pods to stabilize..."
sleep 5

# Step 7: Verify pod is running and ready
log_info "Verifying repo-server pod..."

# Wait for pods to be ready (not just running)
if ! kubectl wait --for=condition=Ready pods -n "$TEST_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server --timeout=60s; then
    log_error "Repo-server pods did not become ready"
    kubectl get pods -n "$TEST_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server
    exit 1
fi

# Get the name of a ready pod
POD_NAME=$(kubectl get pods -n "$TEST_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD_NAME" ]; then
    log_error "No running repo-server pod found"
    kubectl get pods -n "$TEST_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server
    exit 1
fi
log_success "Repo-server pod is running: $POD_NAME"

# Step 8: Verify the git wrapper is installed
log_info "Verifying git wrapper installation..."
WRAPPER=$(kubectl exec -n "$TEST_NAMESPACE" "$POD_NAME" -c argocd-repo-server -- readlink /usr/bin/git || true)

if echo "$WRAPPER" | grep -q "git-wrapper"; then
    log_success "git is replaced by the transcrypt wrapper"
else
    log_error "git wrapper not found (readlink /usr/bin/git: '$WRAPPER')"
    exit 1
fi

# Step 9: Verify secret is mounted with all keys
log_info "Verifying secret mount and multi-repo keys..."
SECRET_EXISTS=$(kubectl exec -n "$TEST_NAMESPACE" "$POD_NAME" -c argocd-repo-server -- test -f /transcrypt-secret/password && echo "yes" || echo "no")

if [ "$SECRET_EXISTS" = "yes" ]; then
    log_success "Transcrypt default secret is mounted"
else
    log_error "Transcrypt default secret not mounted"
    exit 1
fi

# Verify repo-specific password files exist
REPO1_EXISTS=$(kubectl exec -n "$TEST_NAMESPACE" "$POD_NAME" -c argocd-repo-server -- test -f /transcrypt-secret/github.com_example_repo1 && echo "yes" || echo "no")
REPO2_EXISTS=$(kubectl exec -n "$TEST_NAMESPACE" "$POD_NAME" -c argocd-repo-server -- test -f /transcrypt-secret/github.com_example_repo2 && echo "yes" || echo "no")

if [ "$REPO1_EXISTS" = "yes" ] && [ "$REPO2_EXISTS" = "yes" ]; then
    log_success "Repository-specific passwords are mounted"
else
    log_error "Repository-specific passwords not found"
    exit 1
fi

# Step 10: Verify Secret keys in Kubernetes
log_info "Verifying Secret contains all expected keys..."
SECRET_KEYS=$(kubectl get secret transcrypt-password -n "$TEST_NAMESPACE" -o jsonpath='{.data}' | grep -o '"[^"]*"' | tr -d '"' | sort)
EXPECTED_KEYS=("cipher" "github.com_example_repo1" "github.com_example_repo2" "password")

for key in "${EXPECTED_KEYS[@]}"; do
    if echo "$SECRET_KEYS" | grep -q "$key"; then
        log_success "Secret key '$key' found"
    else
        log_error "Secret key '$key' missing"
        exit 1
    fi
done

# Step 10b: Decrypt an encrypted repository inside the repo-server pod
log_info "Running encrypted repository scenario inside the repo-server pod..."
SCENARIO_OUTPUT=$(kubectl exec -i -n "$TEST_NAMESPACE" "$POD_NAME" -c argocd-repo-server -- bash -s < "$(dirname "$0")/encrypted-repo-scenario.sh" 2>&1 || true)

if echo "$SCENARIO_OUTPUT" | grep -q '^RESULT=password: hunter2$'; then
    log_success "Encrypted repository is decrypted inside the pod"
else
    log_error "Decryption inside the pod failed"
    echo "$SCENARIO_OUTPUT"
    kubectl exec -n "$TEST_NAMESPACE" "$POD_NAME" -c argocd-repo-server -- ls -ln /transcrypt-secret/ || true
    exit 1
fi

# Step 11: Check logs for errors
log_info "Checking logs for errors..."
ERROR_COUNT=$(kubectl logs -n "$TEST_NAMESPACE" deployment/argocd-repo-server --tail=100 | grep -ci error || true)

if [ "$ERROR_COUNT" -eq 0 ]; then
    log_success "No errors found in logs"
else
    log_warn "Found $ERROR_COUNT errors in logs (may be expected)"
    kubectl logs -n "$TEST_NAMESPACE" deployment/argocd-repo-server --tail=50 | grep -i error
fi

# Summary
echo ""
echo "======================================"
echo "Integration Test Summary"
echo "======================================"
log_success "All integration tests passed!"
echo ""
log_info "Cluster: $KIND_CLUSTER_NAME"
log_info "Namespace: $TEST_NAMESPACE"
echo ""
log_info "To interact with the cluster:"
echo "  kubectl --context kind-$KIND_CLUSTER_NAME -n $TEST_NAMESPACE get pods"
echo ""
log_info "To cleanup:"
echo "  kind delete cluster --name $KIND_CLUSTER_NAME"
echo "======================================"

# Don't cleanup automatically for manual inspection
trap - EXIT

exit 0
