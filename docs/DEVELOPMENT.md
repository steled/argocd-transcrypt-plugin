# Development Guide

Welcome to the ArgoCD Transcrypt Plugin development guide. This document provides comprehensive information for contributors and maintainers.

## Table of Contents

- [Architecture](#architecture)
- [Development Setup](#development-setup)
- [Building](#building)
- [Testing](#testing)
- [Contributing](#contributing)
- [Release Process](#release-process)
- [Troubleshooting](#troubleshooting)

## Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Docker Image Build Process                   │
├─────────────────────────────────────────────────────────────────┤
│  Base: quay.io/argoproj/argocd:$ARGOCD_VERSION                  │
│  ├─> Install transcrypt from GitHub                             │
│  ├─> Copy git-wrapper.sh to /usr/local/bin/git-wrapper          │
│  └─> Replace /usr/bin/git with the wrapper (real git: git.real) │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Runtime: Repo-Server Pod                      │
├─────────────────────────────────────────────────────────────────┤
│  Main Container: argocd-repo-server                             │
│  ├─> Git fetch/checkout/pull/clone go through the git wrapper   │
│  ├─> Wrapper derives the secret key from remote.origin.url      │
│  ├─> Reads password from /transcrypt-secret/<key>               │
│  ├─> Executes: transcrypt -c $CIPHER -p $PASSWORD -y            │
│  └─> Files decrypted in-place before ArgoCD processes them      │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

#### 1. Dockerfile (`docker/Dockerfile`)

**Responsibilities:**
- Install transcrypt binary
- Install the git wrapper and keep the real git binary as `git.real`
- Set up proper permissions
- Maintain compatibility with ArgoCD base image

**Design Decisions:**
- Uses build-arg for ArgoCD version (renovate compatibility)
- Single-stage build (simplicity over image size)
- Runs as non-root user (security best practice)

#### 2. Git Wrapper (`docker/git-wrapper.sh`)

**Responsibilities:**
- Run the real git first and pass its exit code through on failure
- After `clone`, `checkout`, `pull` and `fetch`: initialize transcrypt if it is not configured yet
- Read the repository password from the mounted secret
- Handle missing passwords gracefully

**Design Decisions:**
- Bash script for portability
- Idempotent (skipped when `transcrypt --display` succeeds)
- Fail-open for repositories without a matching secret key
- Never logs the password, only the secret key
- Detailed logging to stderr/stdout (visible in the repo-server logs); credentials embedded in remote URLs are masked

**Wrapper Execution Flow:**

```bash
git <command> ...            # /usr/bin/git is the wrapper
  │
  ├─> Run /usr/bin/git.real with the same arguments
  │     └─> Failure: return its exit code
  │
  ├─> Command is clone/checkout/pull/fetch?
  │     └─> NO: exit with git's exit code
  │
  ├─> transcrypt already configured? (transcrypt --display)
  │     └─> YES: skip
  │
  ├─> Derive secret key from remote.origin.url
  │     ├─> No URL: skip
  │     └─> /transcrypt-secret/<key> missing: log, exit 0 (repo does not use transcrypt)
  │
  ├─> Execute: transcrypt -c $TRANSCRYPT_CIPHER -p <password> -y
  │     ├─> Success: log success
  │     └─> Failure: log error details (no password), exit 1
  │
  └─> Exit with git's exit code
```

#### 3. Kubernetes Manifests (`kubernetes/`)

**Structure:**
```
kubernetes/
├── base/
│   ├── kustomization.yaml          # Base configuration
│   ├── transcrypt-secret.yaml      # Secret template (user must populate)
│   └── repo-server-patch.yaml      # Deployment patch for repo-server
└── overlays/
    └── production/
        └── kustomization.yaml      # Production customizations
```

**Design Decisions:**
- Kustomize for configuration management
- Patch-based approach (non-invasive to ArgoCD installation)
- Environment-specific overlays
- Secret externalized (not committed)

### Git Wrapper Mechanism

**Why a Git Wrapper?**

1. **Automatic Execution**: Runs after every `git clone`, `fetch`, `pull` and `checkout` performed by the repo-server
2. **No Cluster-Side Setup**: Everything is baked into the image, no init container or git configuration is required
3. **Per-Repository**: The password is looked up per repository; repositories without a key are left untouched
4. **Timing**: Executes right after Git operations, before ArgoCD accesses files

**Alternative Approaches Considered:**

| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| **Git Wrapper Script** | Works for every clone/fetch, no git configuration needed | Replaces the git binary in the image | ✅ **Chosen** |
| **Init Container Only** | Simple setup | Configuration does not reach the main container, doesn't run on each clone | ❌ Rejected |
| **Post-Checkout Hook** | Native git mechanism | Fires only for repositories created from the template directory, breaks checkouts when no password is found | ❌ Rejected |
| **CMP Plugin** | ArgoCD-native | Doesn't work with `ref:` sources | ❌ Not feasible |

### Multi-Source Application Integration

**ArgoCD Multi-Source Flow with Transcrypt:**

```
1. Application Sync Triggered
   ↓
2. ArgoCD clones values repository (with ref: values)
   ↓
3. Git wrapper runs after the fetch/checkout
   ├─> Looks up the repository's password in /transcrypt-secret
   ├─> Initializes transcrypt with password
   └─> Files decrypted in-place
   ↓
4. ArgoCD marks this source as "values" reference
   ↓
5. ArgoCD fetches Helm chart from external source
   ↓
6. ArgoCD resolves $values/ references
   ├─> Copies files from values repo (now decrypted)
   └─> Files available to Helm chart
   ↓
7. Helm renders templates with decrypted value files
   ↓
8. ArgoCD applies manifests to cluster
```

**Key Insight:** Transcrypt decryption happens at step 3, before ArgoCD processes `$values/` references at step 6. This is why the wrapper approach works seamlessly with multi-source applications.

## Development Setup

### Prerequisites

- **Docker** or **Podman**: For building images
- **Kubernetes cluster**: For testing (Kind, k3d, or Minikube)
- **kubectl**: Kubernetes CLI
- **ArgoCD CLI**: `argocd` command
- **Transcrypt**: Install locally for testing
- **Git**: Version 2.9+
- **Make** (optional): For convenience scripts

### Install Tools

```bash
# Install transcrypt
curl -O https://raw.githubusercontent.com/elasticdog/transcrypt/main/transcrypt
chmod +x transcrypt
sudo mv transcrypt /usr/local/bin/

# Install ArgoCD CLI
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Install Kind (Kubernetes in Docker)
curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x kind
sudo mv kind /usr/local/bin/

# Install Kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

### Local Development Environment

#### 1. Create Test Cluster

```bash
# Create Kind cluster
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: argocd-transcrypt-dev
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
EOF

# Verify cluster
kubectl cluster-info
```

#### 2. Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port-forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

#### 3. Create Test Transcrypt Repository

```bash
# Create test repo
mkdir -p ~/test-transcrypt-repo
cd ~/test-transcrypt-repo
git init

# Initialize transcrypt
TRANSCRYPT_PASSWORD="test-password-$(openssl rand -hex 16)"
echo "$TRANSCRYPT_PASSWORD" > ~/transcrypt-test-password.txt
transcrypt -c aes-256-cbc -p "$TRANSCRYPT_PASSWORD"

# Create encrypted file
cat > secret-values.yaml <<EOF
database:
  password: super-secret-password
  username: admin
EOF

# Configure transcrypt pattern
echo "secret-values.yaml filter=crypt diff=crypt merge=crypt" > .gitattributes

# Commit
git add .
git commit -m "Initial commit with encrypted secret-values.yaml"

# Push to remote (GitHub, GitLab, etc.)
# git remote add origin https://github.com/your-org/test-transcrypt-repo.git
# git push -u origin main
```

## Building

### Build Docker Image

```bash
cd docker

# Build with default ArgoCD version
docker build -t argocd-transcrypt-plugin:dev .

# Build with specific ArgoCD version
docker build \
  --build-arg ARGOCD_VERSION=v3.5.6 \
  -t argocd-transcrypt-plugin:dev-argocd-v2.10.0 \
  .

# Build and load into Kind cluster
docker build -t argocd-transcrypt-plugin:dev .
kind load docker-image argocd-transcrypt-plugin:dev --name argocd-transcrypt-dev
```

### Build Parameters

| Build Arg | Default | Description |
|-----------|---------|-------------|
| `ARGOCD_VERSION` | `v2.10.0` | Base ArgoCD image version |

### Verify Build

```bash
# Inspect image
docker inspect argocd-transcrypt-plugin:dev

# Check transcrypt is installed
docker run --rm argocd-transcrypt-plugin:dev transcrypt --version

# Check git is the wrapper and the real binary is kept
docker run --rm argocd-transcrypt-plugin:dev readlink /usr/bin/git
docker run --rm argocd-transcrypt-plugin:dev ls -la /usr/bin/git.real

# Verify base image
docker run --rm argocd-transcrypt-plugin:dev argocd version
```

## Testing

### Unit Tests

#### Test the Git Wrapper

The tests run against the built image (they need Docker):

```bash
# Build the image the tests use
docker build -t argocd-transcrypt-plugin:test docker/

# Run the wrapper tests
./tests/test-git-wrapper.sh

# Expected output:
# [PASS] git is the wrapper and the real binary is kept as git.real
# [PASS] Files are decrypted after fetch/checkout
# [PASS] Checkout succeeds, file remains encrypted
# [PASS] Key github.com_myorg_my-repo is used   (https URL)
# [PASS] Key github.com_myorg_my-repo is used   (ssh URL)
```

**What the tests cover:**

- `tests/test-git-wrapper.sh` starts containers from the image with different secret directories mounted.
- `tests/encrypted-repo-scenario.sh` is executed inside the container: it creates a transcrypt-encrypted repository, publishes it as a local remote and simulates what ArgoCD does (`git init`, `git fetch`, `git checkout`) through the wrapper. The same script is executed inside the repo-server pod by the integration test.

### Integration Tests

#### Test Full ArgoCD Integration

```bash
cd tests

# Run integration test (requires Kind cluster)
./test-argocd-integration.sh

# Test will:
# 1. Deploy custom image to Kind cluster
# 2. Create transcrypt secret
# 3. Patch ArgoCD repo-server
# 4. Create test application with encrypted values
# 5. Verify sync succeeds
# 6. Validate decryption occurred
```

**Integration test flow:**

```bash
#!/bin/bash
# tests/test-argocd-integration.sh

set -e

echo "🧪 Running ArgoCD integration test..."

# Setup
KIND_CLUSTER="argocd-transcrypt-test"
TEST_NAMESPACE="argocd-test"

# 1. Create Kind cluster if not exists
if ! kind get clusters | grep -q "$KIND_CLUSTER"; then
  kind create cluster --name "$KIND_CLUSTER"
fi

# 2. Install ArgoCD
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Build and load custom image
docker build -t argocd-transcrypt-plugin:test ../docker/
kind load docker-image argocd-transcrypt-plugin:test --name "$KIND_CLUSTER"

# 4. Create transcrypt secret
kubectl create secret generic transcrypt-password \
  --from-literal=github.com_example_repo1="test-password-12345" \
  -n argocd \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Patch repo-server with custom image
kubectl patch deployment argocd-repo-server -n argocd --patch "$(cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: argocd-repo-server
        image: argocd-transcrypt-plugin:test
        volumeMounts:
        - name: transcrypt-secret
          mountPath: /transcrypt-secret
          readOnly: true
      volumes:
      - name: transcrypt-secret
        secret:
          secretName: transcrypt-password
EOF
)"

# 6. Wait for rollout
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s

# 7. Create test application
# (Application manifest with transcrypt-encrypted values repo)

# 8. Trigger sync and validate
# (Check sync status, verify decryption logs)

echo "✅ Integration test passed!"
```

### Manual Testing

#### Test in Local Cluster

```bash
# 1. Build image
docker build -t argocd-transcrypt-plugin:local docker/

# 2. Load into cluster
kind load docker-image argocd-transcrypt-plugin:local --name argocd-transcrypt-dev

# 3. Create secret
kubectl create secret generic transcrypt-password \
  --from-literal=github.com_myorg_myapp-config="$(cat ~/transcrypt-test-password.txt)" \   # key = sanitized repo URL
  -n argocd

# 4. Apply manifests
kubectl apply -k kubernetes/overlays/production/

# 5. Monitor logs
kubectl logs -n argocd deployment/argocd-repo-server -f

# 6. Create test application
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-transcrypt-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/test-transcrypt-repo.git
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: default
EOF

# 7. Check sync status
argocd app sync test-transcrypt-app
argocd app get test-transcrypt-app
```

### Test Checklist

Before submitting PR:

- [ ] Wrapper tests pass (`./tests/test-git-wrapper.sh`)
- [ ] Integration tests pass (`./tests/test-argocd-integration.sh`)
- [ ] Manual testing in Kind cluster successful
- [ ] No errors in repo-server logs
- [ ] Test application syncs successfully
- [ ] Transcrypt decryption logs visible
- [ ] Documentation updated (if applicable)
- [ ] Commit messages follow conventional commits

## Contributing

### Code Style

**Shell Scripts:**
- Use `#!/bin/bash` (not `/bin/sh`)
- Use `set -e` for error handling
- Quote variables: `"$VAR"` not `$VAR`
- Use `[[]]` for conditionals
- Include comments for complex logic

**Dockerfile:**
- Multi-line RUN commands with `\`
- Clean up in same layer: `apt-get clean && rm -rf /var/lib/apt/lists/*`
- Use specific versions for dependencies
- Layer caching optimization

**Kubernetes Manifests:**
- Use Kustomize for customization
- Include comments for non-obvious configuration
- Follow Kubernetes naming conventions
- Validate with `kubectl --dry-run=client`

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `chore`: Maintenance tasks
- `test`: Adding/updating tests
- `refactor`: Code refactoring
- `perf`: Performance improvements
- `ci`: CI/CD changes

**Examples:**

```
feat(docker): add support for custom transcrypt cipher

Adds TRANSCRYPT_CIPHER environment variable to configure
the encryption cipher. Defaults to aes-256-cbc for backward
compatibility.

Closes #42
```

```
fix(wrapper): handle repositories without a password

The git wrapper was failing on repositories without a matching secret key.
Now it exits gracefully with git's exit code when no key exists.

Fixes #38
```

### Pull Request Process

1. **Fork and Branch**
```bash
# Fork repository on GitHub
git clone https://github.com/YOUR-USERNAME/argocd-transcrypt-plugin.git
cd argocd-transcrypt-plugin

# Create feature branch
git checkout -b feat/my-new-feature
```

2. **Make Changes**
```bash
# Make your changes
# Run tests
./tests/test-git-wrapper.sh

# Commit with conventional commits
git add .
git commit -m "feat: add my new feature"
```

3. **Push and Create PR**
```bash
# Push to your fork
git push origin feat/my-new-feature

# Create PR on GitHub
# - Describe changes
# - Link related issues
# - Add screenshots if applicable
# - Check all CI checks pass
```

4. **Code Review**
- Address reviewer feedback
- Keep PR focused (one feature/fix per PR)
- Update documentation if needed

5. **Merge**
- Maintainer will merge when approved
- Semantic versioning will auto-increment
- Changelog will be auto-generated

## Release Process

### Versioning Strategy

**Semantic Versioning (SemVer):**
- `MAJOR.MINOR.PATCH` (e.g., v1.2.3)
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

**Automated via semantic-release:**
- Analyzes commit messages
- Determines version bump
- Generates changelog
- Creates GitHub release
- Builds and pushes Docker image

### Release Workflow

#### Automatic Release (via CI/CD)

```bash
# 1. Merge feature/fix to main
git checkout main
git pull origin main

# 2. Commits on main trigger semantic-release
# - If commit includes "feat:", MINOR version bump
# - If commit includes "fix:", PATCH version bump
# - If commit includes "BREAKING CHANGE:", MAJOR version bump

# 3. CI/CD workflow:
#    a. A tag (e.g., v1.2.0) is pushed or release.yaml is dispatched
#    b. Builds Docker image with version tag
#    c. Runs unit and integration tests
#    d. Pushes to ghcr.io/steled/argocd-transcrypt-plugin
#    e. Creates GitHub release with generated notes
```

#### Manual Release (emergency)

```bash
# 1. Create tag manually
git tag -a v1.2.1 -m "Emergency patch release"
git push origin v1.2.1

# 2. GitHub Actions workflow triggers on tag push
# 3. Builds and releases automatically
```

### Release Checklist

Before creating a release:

- [ ] All tests pass on main branch
- [ ] Documentation is up to date
- [ ] CHANGELOG.md reflects changes (auto-generated)
- [ ] Version compatibility matrix updated
- [ ] Breaking changes documented in UPGRADE.md
- [ ] Example configurations tested
- [ ] Security vulnerabilities scanned (Trivy)

### Post-Release

After successful release:

1. **Announce Release:**
   - Update README badges
   - Post to GitHub Discussions
   - Notify stakeholders

2. **Monitor Issues:**
   - Watch for bug reports
   - Respond to questions
   - Triage issues quickly

3. **Plan Next Release:**
   - Create milestone for next version
   - Assign issues to milestone
   - Update project board

## Troubleshooting

### Common Development Issues

#### Issue: Docker build fails

```bash
# Check Docker daemon
docker info

# Build with verbose output
docker build --progress=plain -t test .

# Check build args
docker build --build-arg ARGOCD_VERSION=v3.5.6 -t test .
```

#### Issue: Wrapper tests fail

```bash
# Make sure the test image exists and is current
docker build -t argocd-transcrypt-plugin:test docker/

# Make sure the scripts are executable
chmod +x tests/*.sh

# Check that git is the wrapper
docker run --rm --entrypoint bash argocd-transcrypt-plugin:test -c 'readlink /usr/bin/git'
```

#### Issue: Kind cluster issues

```bash
# Delete and recreate cluster
kind delete cluster --name argocd-transcrypt-dev
kind create cluster --name argocd-transcrypt-dev

# Load image again
kind load docker-image argocd-transcrypt-plugin:dev --name argocd-transcrypt-dev
```

### Debugging Tips

**Enable verbose logging:**

```bash
# In git-wrapper.sh, add:
set -x  # Print commands as they execute

# In Dockerfile, add:
RUN set -x && ...
```

**Inspect running pod:**

```bash
# Exec into pod
kubectl exec -it -n argocd deployment/argocd-repo-server -- bash

# Check git config
git config --list

# Test transcrypt
which transcrypt
transcrypt --version

# Check the git wrapper
readlink /usr/bin/git
```

## Additional Resources

- **ArgoCD Docs**: https://argo-cd.readthedocs.io/
- **Transcrypt GitHub**: https://github.com/elasticdog/transcrypt
- **Kubernetes Docs**: https://kubernetes.io/docs/
- **Kind Docs**: https://kind.sigs.k8s.io/

## Getting Help

- 💬 **Discussions**: https://github.com/steled/argocd-transcrypt-plugin/discussions
- 🐛 **Issues**: https://github.com/steled/argocd-transcrypt-plugin/issues
