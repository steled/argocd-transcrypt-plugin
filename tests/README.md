# Test Suite for ArgoCD Transcrypt Plugin

This directory contains automated tests for the ArgoCD Transcrypt Plugin.

## Test Files

### test-git-wrapper.sh

**Purpose:** Docker-based tests of the git wrapper (`docker/git-wrapper.sh`) in the built image

**Tests:**
- `git` is replaced by the wrapper and the real binary is kept as `git.real`
- Encrypted files are decrypted after `fetch`/`checkout` when a matching password exists
- Repositories without a matching password stay encrypted and the checkout does not fail
- Secret key derivation for https URLs (`https://github.com/MyOrg/My-Repo.git`)
- Secret key derivation for ssh URLs (`git@github.com:MyOrg/My-Repo.git`)

**Prerequisites:** Docker and a built test image:

```bash
docker build -t argocd-transcrypt-plugin:test docker/
```

**Run:**
```bash
./tests/test-git-wrapper.sh [image]    # default image: argocd-transcrypt-plugin:test
```

**Expected output:**
```
======================================
Git Wrapper Tests (image: argocd-transcrypt-plugin:test)
======================================

[TEST] git is replaced by the wrapper
[PASS] git is the wrapper and the real binary is kept as git.real
...
======================================
Test Summary
======================================
Total tests run: 5
Passed: 5
Failed: 0
======================================
```

### encrypted-repo-scenario.sh

**Purpose:** Scenario that runs *inside* the image or the repo-server pod. It creates a transcrypt-encrypted repository, publishes it as a local remote, simulates ArgoCD (`git init`, `git fetch`, `git checkout`) through the wrapper and prints `RESULT=<first line of the decrypted file>`.

It is used by `test-git-wrapper.sh` (via `docker run`) and by `test-argocd-integration.sh` (via `kubectl exec`). It expects the password under the secret key `_tmp_e2e-remote_remote` in `/transcrypt-secret`.

### test-argocd-integration.sh

**Purpose:** Integration tests with full ArgoCD deployment in Kind cluster

**Tests:**
- Kind cluster creation
- ArgoCD installation
- Custom image build and load
- Transcrypt secret creation with multi-repo support
- Repo-server patching
- Pod deployment verification
- Git wrapper installation verification
- Secret mount verification (repo-specific keys)
- Decryption of an encrypted repository inside the repo-server pod
- Kubernetes Secret keys verification
- Log error checking

**Prerequisites:**
- Docker
- Kind
- kubectl

**Run:**
```bash
chmod +x tests/test-argocd-integration.sh
./tests/test-argocd-integration.sh
```

**Duration:** ~5-10 minutes

**Expected output:**
```
======================================
ArgoCD Transcrypt Integration Tests
======================================

[INFO] Creating Kind cluster: argocd-transcrypt-test
[SUCCESS] Kind cluster created
[INFO] Installing ArgoCD...
[SUCCESS] ArgoCD installed and ready
[INFO] Creating transcrypt secret with multi-repo passwords...
[SUCCESS] Transcrypt secret created with multi-repo support
...
[SUCCESS] Repository-specific passwords are mounted
...
======================================
Integration Test Summary
======================================
[SUCCESS] All integration tests passed!
...
```

**Cleanup:**
The integration test leaves the cluster running for manual inspection. To clean up:
```bash
kind delete cluster --name argocd-transcrypt-test
```

## Running Tests Locally

### Prerequisites

```bash
# Install required tools
# Docker (already installed)
# Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

### Run All Tests

```bash
# From repository root
chmod +x tests/*.sh

# Build the image used by the wrapper tests
docker build -t argocd-transcrypt-plugin:test docker/

# Run the wrapper tests
./tests/test-git-wrapper.sh

# Run integration tests
./tests/test-argocd-integration.sh
```

## CI/CD Integration

These tests are automatically run in GitHub Actions:

- **test.yaml**: Runs on PR and push to main
  - Builds Docker image
  - Runs unit tests
  - Runs integration tests
  - Lints code

- **release.yaml**: Runs on tag push
  - Runs all tests before releasing

## Writing New Tests

### Unit Test Template

```bash
#!/bin/bash
set -euo pipefail

# Test setup
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Test implementation
print_test "Your test description"
if your_test_condition; then
    print_pass "Test passed"
else
    print_fail "Test failed"
fi

# Test summary
print_summary
```

### Integration Test Additions

To add a new integration test step:

```bash
# Step N: Your new test
log_info "Running your new test..."
your_test_commands
if [ $? -eq 0 ]; then
    log_success "Your test passed"
else
    log_error "Your test failed"
    exit 1
fi
```

## Debugging Failed Tests

### Wrapper Tests

```bash
# Run with bash debug mode
bash -x ./tests/test-git-wrapper.sh

# Run the scenario by hand and inspect the wrapper log
docker run --rm -it --entrypoint bash \
  -v "$PWD/tests/encrypted-repo-scenario.sh:/scenario.sh:ro" \
  argocd-transcrypt-plugin:test
# inside: /scenario.sh (the wrapper logs to the terminal)
```

### Integration Tests

```bash
# Keep cluster after test failure
# Comment out the cleanup trap in test-argocd-integration.sh

# Inspect cluster
kubectl --context kind-argocd-transcrypt-test get all -n argocd

# Check logs
kubectl logs -n argocd deployment/argocd-repo-server --tail=100

# Exec into pod
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n argocd $POD -c argocd-repo-server -- bash
```

## Test Coverage

### Current Coverage

- ✅ Git wrapper installation
- ✅ Actual transcrypt decryption through the wrapper (image and repo-server pod)
- ✅ Repositories without a password are left untouched
- ✅ **Repository-specific password detection**
- ✅ **URL sanitization for multi-repo support (https and ssh)**
- ✅ ArgoCD deployment
- ✅ Image build and deployment
- ✅ Secret mounting
- ✅ **Multi-key Secret support**

### Future Tests (TODO)

- ⏳ Multi-source ArgoCD application sync
- ⏳ Performance benchmarks
- ⏳ Error recovery scenarios
- ⏳ Password rotation procedures

## Continuous Improvement

To improve test coverage:

1. **Add test cases** for edge scenarios
2. **Mock transcrypt operations** to avoid needing actual encrypted repos
3. **Performance tests** to track sync time overhead
4. **Chaos testing** to validate error handling

## Support

For test-related issues:
- 🐛 [Report Bug](https://github.com/steled/argocd-transcrypt-plugin/issues)
- 💬 [Discussions](https://github.com/steled/argocd-transcrypt-plugin/discussions)
