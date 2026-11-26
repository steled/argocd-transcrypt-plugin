# Docker Build Instructions

This directory contains the Dockerfile and related scripts for building the custom ArgoCD repo-server image with transcrypt support.

## Quick Start

### Build Locally

```bash
# Build with default ArgoCD version
docker build -t argocd-transcrypt-plugin:latest .

# Build with specific ArgoCD version
docker build \
  --build-arg ARGOCD_VERSION=v3.6.3 \
  -t argocd-transcrypt-plugin:v1.0.0 \
  .

# Build with specific transcrypt version
docker build \
  --build-arg ARGOCD_VERSION=v3.6.3 \
  --build-arg TRANSCRYPT_VERSION=v2.3.2 \
  -t argocd-transcrypt-plugin:v1.0.0 \
  .
```

### Build for Different Platforms

```bash
# For amd64 (default)
docker build --platform linux/amd64 -t argocd-transcrypt-plugin:latest-amd64 .

# For arm64 (if needed in future)
docker build --platform linux/arm64 -t argocd-transcrypt-plugin:latest-arm64 .
```

### Push to Registry

```bash
# Tag for GitHub Container Registry
docker tag argocd-transcrypt-plugin:v1.0.0 \
  ghcr.io/steled/argocd-transcrypt-plugin:v1.0.0

# Login to registry
echo $GHCR_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin

# Push
docker push ghcr.io/steled/argocd-transcrypt-plugin:v1.0.0
```

## Files

### Dockerfile

Main image definition. Based on official ArgoCD image with transcrypt added.

**Key features:**
- Multi-stage ARG for ArgoCD and transcrypt versions
- Minimal layer count for faster builds
- Runs as non-root user (argocd)
- Includes health check

### git-wrapper.sh

Wrapper that replaces `/usr/bin/git` in the image (the real binary is kept as `/usr/bin/git.real`) and initializes transcrypt after git operations.

**Behavior:**
- Always runs the real git first; if it fails, its exit code is returned unchanged
- After `clone`, `checkout`, `pull` and `fetch` it checks whether transcrypt is already configured (`transcrypt --display`)
- Otherwise it derives a secret key from `remote.origin.url` (protocol and user removed, `:` and `/` replaced by `_`, lowercase, `.git` removed)
- Reads the password from `/transcrypt-secret/<key>`; repositories without a matching key are left untouched
- Initializes transcrypt with the cipher from `TRANSCRYPT_CIPHER` (default `aes-256-cbc`)
- Logs the key it used, never the password

**Testing the wrapper:**

```bash
# Build the image and run the docker-based tests
docker build -t argocd-transcrypt-plugin:test .
../tests/test-git-wrapper.sh argocd-transcrypt-plugin:test
```

### .dockerignore

Excludes unnecessary files from Docker build context.

**Benefits:**
- Faster builds (smaller context)
- Prevents secrets from being accidentally included
- Reduces image size

## Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `ARGOCD_VERSION` | `v2.10.0` | Base ArgoCD image version |
| `TRANSCRYPT_VERSION` | `v2.2.3` | Transcrypt version to install |

**Example with all args:**

```bash
docker build \
  --build-arg ARGOCD_VERSION=v3.6.3 \
  --build-arg TRANSCRYPT_VERSION=v2.3.2 \
  -t argocd-transcrypt-plugin:custom \
  .
```

## Testing the Image

### Test Locally

```bash
# Run container
docker run --rm -it argocd-transcrypt-plugin:latest bash

# Inside container:
# Check transcrypt is installed
transcrypt --version

# Check git is the wrapper and the real binary is kept
readlink /usr/bin/git        # -> /usr/local/bin/git-wrapper
ls -la /usr/bin/git.real

# Exit
exit
```

### Test with Kind

```bash
# Build and load into Kind cluster
docker build -t argocd-transcrypt-plugin:test .
kind load docker-image argocd-transcrypt-plugin:test --name your-cluster

# Verify image is loaded
docker exec -it your-cluster-control-plane crictl images | grep transcrypt
```

## Troubleshooting

### Build Failures

#### Issue: Cannot find transcrypt version

```
ERROR: curl: (22) The requested URL returned error: 404 Not Found
```

**Solution:** Check transcrypt version exists:
```bash
# List available versions
curl -s https://api.github.com/repos/elasticdog/transcrypt/tags | jq -r '.[].name'

# Use valid version
docker build --build-arg TRANSCRYPT_VERSION=v2.3.2 -t test .
```

#### Issue: Base image not found

```
ERROR: failed to solve: quay.io/argoproj/argocd:v2.99.99: not found
```

**Solution:** Check ArgoCD version exists:
```bash
# List available ArgoCD versions
curl -s https://api.github.com/repos/argoproj/argo-cd/releases | jq -r '.[].tag_name' | head -20

# Use valid version
docker build --build-arg ARGOCD_VERSION=v3.6.3 -t test .
```

### Runtime Issues

#### Issue: Files are not decrypted

```bash
# Check git is the wrapper
docker run --rm argocd-transcrypt-plugin:latest readlink /usr/bin/git
# Should output: /usr/local/bin/git-wrapper

# Check the wrapper is executable
docker run --rm argocd-transcrypt-plugin:latest \
  stat -c '%a %n' /usr/local/bin/git-wrapper

# Look at the wrapper log lines for the secret key that was looked up
kubectl logs -n argocd deploy/argocd-repo-server | grep git-wrapper
```

#### Issue: Permission denied

```bash
# Verify running as argocd user
docker run --rm argocd-transcrypt-plugin:latest whoami
# Should output: argocd

# Check wrapper permissions
docker run --rm argocd-transcrypt-plugin:latest \
  ls -la /usr/local/bin/git-wrapper
```

## Image Optimization

### Current Image Size

```bash
# Check size
docker images argocd-transcrypt-plugin:latest
# Expected: ~500-600 MB (based on ArgoCD base image size)
```

### Size Breakdown

```bash
# Analyze layers
docker history argocd-transcrypt-plugin:latest
```

**Largest layers:**
- ArgoCD base image: ~450 MB
- System packages: ~50 MB
- Transcrypt + script: ~100 KB

## Security Scanning

### Scan with Trivy

```bash
# Install Trivy
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# Scan image
trivy image --severity HIGH,CRITICAL argocd-transcrypt-plugin:latest
```

### Scan with Grype

```bash
# Install Grype
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin

# Scan image
grype argocd-transcrypt-plugin:latest
```

## Maintenance

### Updating Base Image

When a new ArgoCD version is released:

1. **Check compatibility** with transcrypt and Kubernetes
2. **Build with new version:**
   ```bash
   docker build --build-arg ARGOCD_VERSION=v3.6.3 -t test .
   ```
3. **Run tests** (see [../tests/README.md](../tests/README.md))
4. **Update documentation** if behavior changes
5. **Create release** with new version tag

### Updating Transcrypt

When a new transcrypt version is released:

1. **Check release notes** for breaking changes
2. **Build with new version:**
   ```bash
   docker build --build-arg TRANSCRYPT_VERSION=v2.3.2 -t test .
   ```
3. **Test encryption/decryption** with your repositories
4. **Update documentation** if needed

## CI/CD Integration

This Dockerfile is built automatically by GitHub Actions:
- On tag push: Builds and pushes to container registry
- On PR: Builds for testing only

See [../.github/workflows/release.yaml](../.github/workflows/release.yaml) for details.

## Additional Resources

- [ArgoCD Docker Hub](https://quay.io/repository/argoproj/argocd)
- [Transcrypt Releases](https://github.com/elasticdog/transcrypt/releases)
- [Dockerfile Best Practices](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)

## Support

For build-related issues:
- 🐛 [Report Issue](https://github.com/steled/argocd-transcrypt-plugin/issues)
- 💬 [Discussions](https://github.com/steled/argocd-transcrypt-plugin/discussions)
