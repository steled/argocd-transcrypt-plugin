# Deployment Guide

This guide provides detailed instructions for deploying the ArgoCD Transcrypt Plugin in your Kubernetes cluster.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
- [Configuration](#configuration)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)

## Prerequisites

Before deploying the ArgoCD Transcrypt Plugin, ensure you have:

### Required

- ✅ **Kubernetes Cluster**: Version 1.24 or higher
- ✅ **ArgoCD Installed**: Version 2.9.0 or higher
- ✅ **kubectl Access**: Admin access to the ArgoCD namespace (typically `argocd`)
- ✅ **Transcrypt-Encrypted Repository**: A Git repository with transcrypt configured
  - `.gitattributes` must contain the `filter=crypt` patterns of the encrypted files
- ✅ **Transcrypt Password**: The password used to encrypt the repository
- ✅ **Container Registry Access**: Permissions to push/pull images from `ghcr.io` (pull is anonymous if the package is public)

### Optional

- 🔧 **Kustomize**: For customizing Kubernetes manifests (v4.5.0+)
- 🔧 **Docker/Podman**: For building custom images locally

### Version Compatibility Matrix

| ArgoCD Version | Plugin Version | Kubernetes Version | Status |
|----------------|----------------|-------------------|--------|
| v2.10.x | v1.x.x | 1.24+ | ✅ Supported |
| v2.9.x | v1.x.x | 1.23+ | ✅ Supported |
| v2.8.x | v1.x.x | 1.23+ | ⚠️ Untested |
| < v2.8 | v1.x.x | Any | ❌ Not Supported |

## Installation Steps

### Step 1: Build or Pull the Custom Image

#### Option A: Pull Pre-Built Image (Recommended)

```bash
# Pull the latest release
docker pull ghcr.io/steled/argocd-transcrypt-plugin:v1.0.0

# Verify image
docker inspect ghcr.io/steled/argocd-transcrypt-plugin:v1.0.0
```

#### Option B: Build Image Locally

```bash
# Clone the repository
git clone https://github.com/steled/argocd-transcrypt-plugin.git
cd argocd-transcrypt-plugin/docker

# Build with specific ArgoCD version
docker build \
  --build-arg ARGOCD_VERSION=v3.5.6 \
  -t ghcr.io/steled/argocd-transcrypt-plugin:v1.0.0 \
  .

# Push to registry
docker push ghcr.io/steled/argocd-transcrypt-plugin:v1.0.0
```

### Step 2: Create Transcrypt Password Secret

Create a Kubernetes Secret containing your transcrypt password:

```bash
# Replace 'your-transcrypt-password' with your actual password.
# The key is the sanitized repository URL (see MULTI-REPO.md), e.g. for
# https://github.com/myorg/myapp-config.git: github.com_myorg_myapp-config
kubectl create secret generic transcrypt-password \
  --from-literal=github.com_myorg_myapp-config='your-transcrypt-password' \
  --from-literal=cipher='aes-256-cbc' \
  --namespace argocd \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Note**: Repositories without a matching key are left untouched by the git wrapper (they are not decrypted, and no error is raised).

**Security Note**: Store this password securely. Consider using a secrets management solution like:
- HashiCorp Vault
- AWS Secrets Manager
- Azure Key Vault
- Google Secret Manager

See [SECURITY.md](SECURITY.md) for best practices.

### Step 3: Create Image Pull Secret

#### 3.1: Generate Personal Access Token (PAT)

To authenticate with the GitHub Container Registry (`ghcr.io`) when the package is private, you need to create a Personal Access Token with the appropriate permissions.

**Steps to create a PAT:**

1. Navigate to your GitHub token settings:
   ```
   https://github.com/settings/tokens
   ```
   Or manually: **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**

2. Click **Generate new token** → **Generate new token (classic)**

3. Configure the token:
   - **Note**: `ArgoCD Container Registry Access` (or descriptive name)
   - **Expiration**: Set according to your security policy (recommended: 90 days with rotation)
   - **Select scopes**:
     - ✅ `read:packages` - Download packages from GitHub Package Registry
     - ✅ `write:packages` - Upload packages (only if pushing images)
     - ✅ `delete:packages` - Delete packages (only if managing images)

4. Click **Generate token** and copy the token immediately (it won't be shown again)

5. Store the token securely:
   ```bash
   # Example: Store in password manager or secure vault
   export GHCR_PAT="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   ```

**Token Security Best Practices:**
- ⚠️ Never commit tokens to Git repositories
- 🔄 Rotate tokens every 90 days
- 🔒 Use HashiCorp Vault, AWS Secrets Manager, or similar for production
- 📊 Monitor token usage via the GitHub security log
- ❌ Revoke unused or compromised tokens immediately

#### 3.2: Create Kubernetes Secret

Create a Kubernetes Secret for authenticating with the private container registry:

```bash
# Using your GitHub username and PAT
kubectl create secret docker-registry container-registry-credentials \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password=<your-personal-access-token> \
  --docker-email=<your-email> \
  --namespace argocd
```

**Example with environment variable:**

```bash
# Assuming you exported GHCR_PAT earlier
kubectl create secret docker-registry container-registry-credentials \
  --docker-server=ghcr.io \
  --docker-username=john.doe \
  --docker-password="${GHCR_PAT}" \
  --docker-email=john.doe@example.com \
  --namespace argocd
```

**Alternative: Using existing Docker credentials**

If you have Docker already configured with registry credentials:

```bash
# Use your existing Docker config
kubectl create secret generic container-registry-credentials \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json \
  --type=kubernetes.io/dockerconfigjson \
  --namespace argocd
```

**Verify the secret**:

```bash
kubectl get secret container-registry-credentials -n argocd -o yaml
```

### Step 4: Apply Kubernetes Manifests

How the image is rolled out depends on how ArgoCD is installed. The Helm chart (argo-helm) names the repo-server container `repo-server`, the upstream manifests name it `argocd-repo-server`, and a Helm-managed Deployment must not be patched with `kubectl` (the next `helm upgrade` would revert it).

#### Option A: ArgoCD Installed with Helm (Recommended for Helm installations)

Use [examples/helm-values.yaml](../examples/helm-values.yaml), which sets the image, the environment variables and the secret mount for `repoServer`:

```bash
helm upgrade --install argocd argo/argo-cd -n argocd -f examples/helm-values.yaml
```

If ArgoCD is managed by ArgoCD or another GitOps tool, merge the `global` and `repoServer` sections of that file into your existing values. The transcrypt password secret (Step 2) must exist before the repo-server restarts.

#### Option B: ArgoCD Installed from Upstream Manifests - Using Kustomize

```bash
# Clone the repository if not already done
git clone https://github.com/steled/argocd-transcrypt-plugin.git
cd argocd-transcrypt-plugin

# Review the production overlay
cat kubernetes/overlays/production/kustomization.yaml

# Apply the production overlay
kubectl apply -k kubernetes/overlays/production/

# Verify the resources
kubectl get deployment argocd-repo-server -n argocd
kubectl get secret transcrypt-password -n argocd
```

#### Option C: Manual Application (upstream manifests)

If you prefer not to use Kustomize:

```bash
# Apply base manifests
kubectl apply -f kubernetes/base/transcrypt-secret.yaml
kubectl apply -f kubernetes/base/repo-server-patch.yaml

# Note: You'll need to manually edit the secret with your password
kubectl edit secret transcrypt-password -n argocd
```

### Step 4b: Patch ArgoCD Repo-Server Deployment (Option C only)

The Kustomize overlay automatically patches the `argocd-repo-server` deployment. If applying manually:

```bash
# Patch the deployment
kubectl patch deployment argocd-repo-server -n argocd --patch-file kubernetes/base/repo-server-patch.yaml

# Alternative: Edit directly
kubectl edit deployment argocd-repo-server -n argocd
```

### Step 5: Restart ArgoCD Repo-Server

Force a rollout to apply changes:

```bash
# Rollout restart
kubectl rollout restart deployment/argocd-repo-server -n argocd

# Wait for rollout to complete
kubectl rollout status deployment/argocd-repo-server -n argocd
```

## Configuration

### Environment Variables

The following environment variables can be configured in the repo-server deployment:

| Variable | Default | Description |
|----------|---------|-------------|
| `TRANSCRYPT_CIPHER` | `aes-256-cbc` | Encryption cipher used by transcrypt |
| `TRANSCRYPT_PASSWORD_DIR` | `/transcrypt-secret` | Directory in the container where the secret keys are mounted as files |

### Custom Cipher Configuration

If your repository uses a different cipher:

```yaml
# In kubernetes/overlays/production/kustomization.yaml
patchesStrategicMerge:
  - |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: argocd-repo-server
      namespace: argocd
    spec:
      template:
        spec:
          containers:
          - name: argocd-repo-server
            env:
            - name: TRANSCRYPT_CIPHER
              value: "aes-256-ctr"  # Your custom cipher
```

### Multi-Cluster Setup

For multi-cluster ArgoCD installations:

1. Deploy the custom image to each cluster's ArgoCD instance
2. Use cluster-specific secrets for transcrypt passwords
3. Consider using ArgoCD ApplicationSets for managing multiple deployments

## Verification

### Step 1: Verify Pod Status

```bash
# Check pod is running
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Expected output:
# NAME                                  READY   STATUS    RESTARTS   AGE
# argocd-repo-server-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Step 2: Verify the Git Wrapper

```bash
# Exec into the repo-server pod
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n argocd $POD -c argocd-repo-server -- readlink /usr/bin/git

# Expected output:
# /usr/local/bin/git-wrapper
```

(The container is called `repo-server` instead of `argocd-repo-server` if ArgoCD was installed with the Helm chart.)

### Step 3: Verify the Secret Is Mounted

```bash
kubectl exec -n argocd $POD -c argocd-repo-server -- ls -la /transcrypt-secret/

# Expected output: one file per secret key, e.g.
# github.com_myorg_myapp-config
# cipher
```

### Step 4: Test with Sample Application

Create a test ArgoCD Application that references your transcrypt-encrypted repository:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-transcrypt
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/your-org/encrypted-values-repo.git
      targetRevision: main
      ref: values
    - repoURL: https://charts.example.com
      chart: test-chart
      targetRevision: 1.0.0
      helm:
        valueFiles:
          - $values/path/to/secret-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
```

Apply and check sync status:

```bash
kubectl apply -f test-application.yaml

# Check sync status
argocd app get test-transcrypt

# Check repo-server logs for decryption
kubectl logs -n argocd deployment/argocd-repo-server --tail=100 | grep -i transcrypt
```

### Step 5: Verify Decryption in Logs

Successful decryption logs should show:

```
Initializing transcrypt for repository...
Transcrypt initialization successful
```

## Troubleshooting

### Common Issues and Solutions

#### Issue 1: Pod Fails to Start

**Symptoms:**
```
kubectl get pods -n argocd
NAME                                  READY   STATUS             RESTARTS   AGE
argocd-repo-server-xxxxxxxxxx-xxxxx   0/1     CrashLoopBackOff   5          5m
```

**Solutions:**

1. Check pod logs:
```bash
kubectl logs -n argocd deployment/argocd-repo-server -c argocd-repo-server
```

2. Verify image exists and is accessible:
```bash
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
# Look for ImagePullBackOff errors
```

3. Check secret exists:
```bash
kubectl get secret transcrypt-password -n argocd
```

#### Issue 2: Transcrypt Password Not Found

**Symptoms:**
```
[git-wrapper] No repository-specific password found (key: github.com_myorg_repo), repository does not use transcrypt
```

**Solutions:**

1. Verify secret is created:
```bash
kubectl get secret transcrypt-password -n argocd -o yaml
```

2. Check secret is mounted correctly:
```bash
kubectl describe deployment argocd-repo-server -n argocd | grep -A 10 "Volumes:"
```

3. Verify secret key name:
```bash
kubectl get secret transcrypt-password -n argocd -o jsonpath='{.data}' | jq 'keys'
# Should include "password"
```

#### Issue 3: Transcrypt Initialization Fails

**Symptoms:**
```
[git-wrapper] ====== TRANSCRYPT ERROR ======
[git-wrapper] Exit code: 1
```

**Solutions:**

1. Verify transcrypt is installed in image:
```bash
kubectl exec -n argocd deployment/argocd-repo-server -c argocd-repo-server -- which transcrypt
```

2. Check cipher compatibility:
```bash
# Verify cipher in your repo matches the configured cipher
kubectl exec -n argocd deployment/argocd-repo-server -c argocd-repo-server -- \
  transcrypt --version
```

3. Test password manually:
```bash
# Clone your repo locally and test transcrypt
git clone https://github.com/your-org/encrypted-repo.git test-repo
cd test-repo
transcrypt -c aes-256-cbc -p 'your-password' -y
# If this fails, your password or cipher is incorrect
```

#### Issue 4: Application Sync Fails with Encrypted Files

**Symptoms:**
```
argocd app sync my-app
# Error: failed to unmarshal: error unmarshaling JSON: while decoding JSON: json: cannot unmarshal string into Go value of type map[string]interface {}
```

**Solutions:**

1. Check if files are actually decrypted:
```bash
kubectl logs -n argocd deployment/argocd-repo-server --tail=200 | grep "git-wrapper"
```

2. Verify the transcrypt filter is registered in the repo:
```bash
git clone https://github.com/your-org/encrypted-repo.git
grep 'filter=crypt' encrypted-repo/.gitattributes
```

3. Check `.gitattributes` patterns:
```bash
cat .gitattributes
# Should include patterns like: *-secret-values.yaml filter=crypt diff=crypt merge=crypt
```

#### Issue 5: Git Wrapper Not Executing

**Symptoms:**
No `[git-wrapper]` messages in logs when syncing applications.

**Solutions:**

1. Verify `git` is the wrapper:
```bash
kubectl exec -n argocd deployment/argocd-repo-server -c argocd-repo-server -- \
  readlink /usr/bin/git
# Expected: /usr/local/bin/git-wrapper
```

2. Check the wrapper log lines in the repo-server logs:
```bash
kubectl logs -n argocd deployment/argocd-repo-server | grep git-wrapper
```

3. Test the wrapper manually:
```bash
kubectl exec -it -n argocd deployment/argocd-repo-server -c argocd-repo-server -- bash
cd /tmp && mkdir t && cd t && git init && git remote add origin https://github.com/your-org/encrypted-repo.git
git fetch origin
# The wrapper logs which secret key it looks up
```

### Debug Mode

Enable verbose logging for troubleshooting:

```bash
# Add to repo-server deployment
kubectl set env deployment/argocd-repo-server -n argocd \
  ARGOCD_EXEC_TIMEOUT=300s \
  ARGOCD_REPO_SERVER_LOGLEVEL=debug
```

### Getting Help

If issues persist:

1. **Collect Diagnostic Information:**
```bash
# Save logs
kubectl logs -n argocd deployment/argocd-repo-server --tail=500 > repo-server.log

# Save pod description
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server > pod-describe.txt

# Save deployment configuration
kubectl get deployment argocd-repo-server -n argocd -o yaml > deployment.yaml
```

2. **Open a GitHub Issue:**
   - Include diagnostic logs (redact sensitive information)
   - Specify ArgoCD version and Kubernetes version
   - Describe steps to reproduce the issue

## Uninstallation

To remove the ArgoCD Transcrypt Plugin:

### Step 1: Revert Repo-Server to Original Image

```bash
# Restore original ArgoCD repo-server image
kubectl set image deployment/argocd-repo-server -n argocd \
  argocd-repo-server=quay.io/argoproj/argocd:v2.10.0

# Remove the transcrypt volume and mount (requires manual edit)
kubectl edit deployment argocd-repo-server -n argocd
# Remove transcrypt-secret volume and mount
```

### Step 2: Remove Transcrypt Secret

```bash
# Delete the secret (optional - keep if you might reinstall)
kubectl delete secret transcrypt-password -n argocd
```

### Step 3: Restart Repo-Server

```bash
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
```

### Step 4: Update Applications

Any applications using transcrypt-encrypted values will need to be updated to use an alternative secrets management solution (SOPS, Sealed Secrets, etc.).

## Next Steps

- Review [SECURITY.md](SECURITY.md) for password rotation and security best practices
- See [examples/README.md](../examples/README.md) for complete usage examples
- Consult [DEVELOPMENT.md](DEVELOPMENT.md) for customization and contributing

## Support

For additional help:
- 📖 [FAQ](https://github.com/steled/argocd-transcrypt-plugin/wiki/FAQ)
- 🐛 [Open an Issue](https://github.com/steled/argocd-transcrypt-plugin/issues)
- 💬 [Discussions](https://github.com/steled/argocd-transcrypt-plugin/discussions)
