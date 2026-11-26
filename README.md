# ArgoCD Transcrypt Plugin

[![Build Status](https://img.shields.io/github/actions/workflow/status/steled/argocd-transcrypt-plugin/release.yaml?branch=main)](https://github.com/steled/argocd-transcrypt-plugin/actions)
[![Version](https://img.shields.io/github/v/release/steled/argocd-transcrypt-plugin)](https://github.com/steled/argocd-transcrypt-plugin/releases)
[![License](https://img.shields.io/github/license/steled/argocd-transcrypt-plugin)](https://github.com/steled/argocd-transcrypt-plugin/blob/main/LICENSE)

A custom ArgoCD repo-server image that transparently decrypts [transcrypt](https://github.com/elasticdog/transcrypt)-encrypted files during Git operations, enabling secure storage of sensitive Helm values in Git repositories.

## Problem Statement

When using ArgoCD with Helm charts and multi-source applications, sensitive values (passwords, API keys, tokens) need to be stored securely. While solutions like SOPS and Sealed Secrets exist, they often require significant architectural changes or introduce additional complexity.

**Transcrypt** provides transparent file encryption in Git repositories using Git filters, but ArgoCD cannot decrypt these files out-of-the-box because it has no knowledge of the encryption mechanism.

This project solves that problem by providing a custom ArgoCD repo-server image with transcrypt integration via a thin Git wrapper that decrypts repositories right after they are fetched.

## Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          ArgoCD Application Sync                         │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       ArgoCD Repo-Server (Custom Image)                  │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ 1. Git Clone/Checkout (values repository)                          │ │
│  │    ├─> Transcrypt-encrypted files retrieved                        │ │
│  │    └─> Git wrapper (replaces /usr/bin/git) is invoked              │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                     │                                    │
│                                     ▼                                    │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ 2. Git Wrapper Execution                                           │ │
│  │    ├─> Derives secret key from the repository URL                  │ │
│  │    ├─> Reads password from /transcrypt-secret/<key>                │ │
│  │    └─> Runs: transcrypt -c aes-256-cbc -p <password> -y            │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                     │                                    │
│                                     ▼                                    │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ 3. Files Decrypted In-Place                                        │ │
│  │    └─> *-secret-values.yaml now in plaintext                       │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                     │                                    │
│                                     ▼                                    │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ 4. ArgoCD Processes Multi-Source Application                       │ │
│  │    ├─> Resolves $values/ references from decrypted values repo     │ │
│  │    ├─> Fetches Helm chart from external registry                   │ │
│  │    └─> Renders: helm template -f $values/path/to/decrypted.yaml    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Kubernetes Manifests Applied to Cluster               │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Features

- ✅ **Transparent Decryption**: Transcrypt files are automatically decrypted during Git clone/checkout
- ✅ **Multi-Source Compatible**: Works seamlessly with ArgoCD multi-source applications
- ✅ **Multi-Repository Support**: Different passwords for different repositories via Secret keys
- ✅ **No Chart Changes**: Existing Helm charts and value files remain unchanged
- ✅ **Git-Native**: Uses a git wrapper for automatic decryption after clone/fetch/checkout
- ✅ **Secure**: Transcrypt password stored as Kubernetes Secret, mounted read-only
- ✅ **Minimal Overhead**: ~1-2 seconds additional sync time per repository
- ✅ **Renovate Compatible**: ArgoCD base image version configurable via build args

## Quick Start

### Prerequisites

- ArgoCD >= v2.9.0 deployed in Kubernetes cluster
- kubectl access to ArgoCD namespace
- Transcrypt-encrypted repository (see [examples/README.md](examples/README.md))
- Docker/Podman for building custom image

### Installation

1. **Get the custom ArgoCD repo-server image.** Released versions are published to `ghcr.io/steled/argocd-transcrypt-plugin` (tag `<argocd-version>-transcrypt-<plugin-version>`, e.g. `v3.6.3-transcrypt-v1.3.0`). To build it yourself:

```bash
cd docker
docker build \
  --build-arg ARGOCD_VERSION=v3.6.3 \
  -t ghcr.io/steled/argocd-transcrypt-plugin:v1.3.0 \
  .
docker push ghcr.io/steled/argocd-transcrypt-plugin:v1.3.0
```

2. **Create Kubernetes Secret with transcrypt password:**

**Single Repository:**
```bash
kubectl create secret generic transcrypt-password \
  --from-literal=github.com_myorg_repo1='your-transcrypt-password' \
  --from-literal=cipher='aes-256-cbc' \
  -n argocd
```

**Multiple Repositories (different passwords per repo):**
```bash
kubectl create secret generic transcrypt-password \
  --from-literal=cipher='aes-256-cbc' \
  --from-literal=github.com_myorg_repo1='password-for-repo1' \
  --from-literal=github.com_myorg_repo2='password-for-repo2' \
  --from-literal=gitlab.com_team_secrets='password-for-gitlab-repo' \
  -n argocd
```

**Key naming convention for multi-repo:**
- Sanitize repository URL: remove protocol, user and `.git`, replace `/` and `:` with underscores, convert to lowercase
- Example: `https://github.com/myorg/repo1` → `github.com_myorg_repo1`
- Example: `https://gitlab.com/team/secrets` → `gitlab.com_team_secrets`
- Repositories without a matching key are left untouched (no decryption, no error)
- See [docs/MULTI-REPO.md](docs/MULTI-REPO.md) for detailed guide

3. **Create image pull secret (only required if the GHCR package is private):**

```bash
# First, create a Personal Access Token (PAT) at:
# https://github.com/settings/tokens
# Required scopes: read:packages

kubectl create secret docker-registry container-registry-credentials \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password=<your-personal-access-token> \
  --docker-email=<your-email> \
  -n argocd
```

For detailed PAT creation instructions, see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#31-generate-personal-access-token-pat).

4. **Deploy the image to the ArgoCD repo-server.** The way to do this depends on how ArgoCD is installed:

**Option A: ArgoCD installed with Helm (argo-helm chart)**

Use the provided values, which set the image, the environment and the secret mount for `repoServer`
(see [examples/helm-values.yaml](examples/helm-values.yaml)):

```bash
helm upgrade --install argocd argo/argo-cd -n argocd -f examples/helm-values.yaml
```

If you manage ArgoCD itself with ArgoCD or a GitOps tool, merge the `repoServer` and `global` sections of that file into your existing values.

**Option B: ArgoCD installed from the upstream manifests**

The Kustomize overlay patches the existing `argocd-repo-server` Deployment (container name `argocd-repo-server`):

```bash
kubectl apply -k kubernetes/overlays/production/
```

> **Why two options?** The Helm chart and the upstream manifests name the repo-server container differently
> (`repo-server` vs. `argocd-repo-server`), and a Helm-managed Deployment must not be patched with `kubectl`
> because the next `helm upgrade` would revert the change. Pick the option that matches your installation.

5. **Verify deployment:**

```bash
kubectl rollout status deployment/argocd-repo-server -n argocd
# Container name: "repo-server" (Helm) or "argocd-repo-server" (upstream manifests)
kubectl logs -n argocd deployment/argocd-repo-server -c repo-server --tail=50
```

6. **Test with sample application:**

See [examples/README.md](examples/README.md) for a complete example.

## Documentation

- **[Deployment Guide](docs/DEPLOYMENT.md)** - Detailed installation and configuration steps
- **[Security Guide](docs/SECURITY.md)** - Password rotation, RBAC policies, and security best practices
- **[Upgrade Guide](docs/UPGRADE.md)** - Version compatibility matrix and migration procedures
- **[Development Guide](docs/DEVELOPMENT.md)** - Architecture deep-dive, local testing, and contributing
- **[CI/CD Setup](docs/CICD-SETUP.md)** - GitHub Actions configuration and required secrets

## How It Works

### The Approach: A Git Wrapper in the Repo-Server Image

This solution replaces the `git` binary in the ArgoCD repo-server image with a thin wrapper:

1. **Git wrapper**: In the image, `/usr/bin/git` is a wrapper (`docker/git-wrapper.sh`) around the real binary (`/usr/bin/git.real`). It always runs the real git first. After a successful `clone`, `checkout`, `pull` or `fetch` it checks whether transcrypt is already configured in the repository; if not, it looks up the password for the repository and runs `transcrypt -c <cipher> -p <password> -y`.

2. **Password lookup**: The password secret is mounted at `/transcrypt-secret`. The wrapper derives a key from the repository URL (see [docs/MULTI-REPO.md](docs/MULTI-REPO.md)) and reads `/transcrypt-secret/<key>`. If no such key exists, the repository is assumed not to use transcrypt and is left untouched - git still succeeds.

3. **Secret hygiene**: The wrapper never logs the password, only the key it used.

4. **Transparent to ArgoCD**: By the time ArgoCD accesses the files, they're already decrypted. Multi-source applications with `$values/` references work without any modifications.

### Why Not a Config Management Plugin?

ArgoCD Config Management Plugins (CMPs) are designed for **manifest generation**, not for repository preprocessing. They have fundamental limitations with multi-source applications:

**Technical Limitations:**

1. **CMP Lifecycle**: CMPs are invoked only during the manifest generation phase for sources that explicitly specify `plugin:` or match discovery rules.

2. **Multi-Source Problem**: In multi-source applications, sources marked with `ref: values` are treated as **read-only reference sources**:
   - ArgoCD clones the repository
   - Files are copied directly to resolve `$values/` references
   - **No CMP plugin is invoked** for reference sources
   - Files must be decrypted BEFORE ArgoCD accesses them

3. **Discovery Doesn't Help**: Even with discovery rules, CMPs only run for sources generating manifests. Reference sources bypass the plugin system entirely.

**Why a Git Wrapper Works:**

The git wrapper approach solves this by operating at the **Git level**, not the ArgoCD level:
- The wrapper runs after every `clone`, `checkout`, `pull` and `fetch` that the repo-server performs
- Runs for ALL repositories, including reference sources
- Decrypts files transparently before ArgoCD processes them
- Works with both single-source and multi-source applications

**Comparison:**

| Feature | CMP Sidecar | Git Wrapper |
|---------|-------------|-------------|
| Works with single-source apps | ✅ Yes | ✅ Yes |
| Works with `ref:` sources | ❌ No | ✅ Yes |
| Requires custom ArgoCD image | ❌ No | ✅ Yes |
| Execution point | Manifest generation | Git checkout |
| Configuration in Application | Required | Not required |

For single-source applications (e.g., Helm chart from registry with inline values), a CMP sidecar could work. However, for maximum flexibility and support for all application patterns, **the git wrapper approach is the only viable solution**.

## Project Structure

```
.
├── .github/
│   ├── workflows/
│   │   ├── release.yaml         # Build, test, and release pipeline
│   │   ├── auto-release.yaml    # Tag + release after ArgoCD updates
│   │   ├── test.yaml            # PR validation and testing
│   │   ├── commitlint.yaml      # Enforce conventional commits
│   │   └── renovate.yaml        # Self-hosted Renovate
│   ├── renovate-config.json     # Renovate runner configuration
│   └── CODEOWNERS
├── renovate.json                # Renovate rules for dependency updates
├── docker/
│   ├── Dockerfile               # Custom ArgoCD repo-server image
│   ├── git-wrapper.sh           # git wrapper that initializes transcrypt on demand
│   ├── .dockerignore            # Docker build ignore patterns
│   └── README.md                # Docker build instructions
├── kubernetes/
│   ├── base/
│   │   ├── kustomization.yaml   # Base Kustomize configuration
│   │   ├── transcrypt-secret.yaml  # Secret template
│   │   └── repo-server-patch.yaml  # Deployment patch for repo-server
│   └── overlays/
│       └── production/
│           └── kustomization.yaml  # Production overlay
├── docs/
│   ├── DEPLOYMENT.md            # Installation and configuration guide
│   ├── SECURITY.md              # Security best practices
│   ├── UPGRADE.md               # Version upgrade procedures
│   ├── DEVELOPMENT.md           # Developer documentation
│   ├── CICD-SETUP.md            # GitHub Actions setup
│   └── MULTI-REPO.md            # Multi-repository with different passwords
├── examples/
│   └── README.md                # Example usage with step-by-step guide
├── tests/
│   ├── test-git-wrapper.sh      # Docker-based tests of the git wrapper
│   ├── encrypted-repo-scenario.sh  # Encrypted-repo scenario (also run in the pod)
│   ├── test-argocd-integration.sh  # Integration test with Kind
│   └── README.md                # Test documentation
├── README.md                    # This file
└── LICENSE                      # Project license
```

## Contributing

We welcome contributions! Please see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for:

- Architecture and design decisions
- Local development setup with Kind
- Testing procedures
- Commit message conventions (Conventional Commits)
- Pull request process

## Versioning

This project uses [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking changes to Kubernetes manifests or Docker image interface
- **MINOR**: New features, ArgoCD base image updates (non-breaking)
- **PATCH**: Bug fixes, documentation updates

Releases are created by the release workflow when a `v*` tag is pushed (ArgoCD and transcrypt updates via Renovate are tagged automatically).

### Image tags and contained versions

Image tags have the form `<argocd-version>-transcrypt-<plugin-version>` (for example `v3.6.3-transcrypt-v1.3.0`), where `<plugin-version>` is the release version of this repository, not the transcrypt version. The versions contained in an image are also stored as OCI labels:

```bash
docker inspect ghcr.io/steled/argocd-transcrypt-plugin:v1.3.0 \
  --format '{{ index .Config.Labels "org.opencontainers.image.version" }} / ArgoCD {{ index .Config.Labels "io.github.steled.argocd-version" }} / transcrypt {{ index .Config.Labels "io.github.steled.transcrypt-version" }}'
```

| Plugin version | ArgoCD | transcrypt |
|----------------|--------|------------|
| v1.3.0 | v3.6.3 | v2.3.2 |
| v1.2.0 | v3.6.2 | v2.3.2 |
| v1.1.0 | v3.5.6 | v2.3.2 |
| v1.0.0 | v3.5.6 | v2.3.2 |

## License

[Apache License 2.0](LICENSE)

## Support

For issues, questions, or feature requests, please open an issue on [GitHub](https://github.com/steled/argocd-transcrypt-plugin/issues).

## Acknowledgments

- [ArgoCD](https://argoproj.github.io/cd/) - Declarative GitOps continuous delivery tool for Kubernetes
- [Transcrypt](https://github.com/elasticdog/transcrypt) - Transparent Git repository encryption
