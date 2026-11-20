# GitHub Actions Workflows

This directory contains the CI/CD workflows for the ArgoCD Transcrypt Plugin.

## Workflows Overview

### 1. Test Workflow (`test.yaml`)
**Trigger:** Pull requests and pushes to `main`

**Purpose:** Validates code quality and functionality

**Jobs:**
- **lint**: Runs hadolint (Dockerfile) and shellcheck (shell scripts)
- **build**: Builds Docker image and tests basic functionality
- **test**: Runs unit tests and integration tests with Kind

**Job Dependencies:**
```
lint (runs first)
  ├─> build (after lint)
  └─> test (after lint + build)
```

### 2. Release Workflow (`release.yaml`)
**Trigger:** Git tags matching `v*` (e.g., `v1.0.0`)

**Purpose:** Builds, tests, and publishes releases

**Steps:**
1. Builds Docker image
2. Runs all tests (unit + integration)
3. Pushes image to `ghcr.io/steled/argocd-transcrypt-plugin`
4. Creates GitHub release

### 3. Auto-Release Workflow (`auto-release.yaml`)
**Trigger:** Merged PRs with `dependencies` label

**Purpose:** Automatically creates releases when ArgoCD version is updated by Renovate

**Logic:**
1. Checks if merged PR updated `ARG ARGOCD_VERSION` in Dockerfile
2. If yes:
   - Increments minor version (e.g., v1.2.3 → v1.3.0)
   - Creates annotated git tag
   - Pushes tag (triggers `release.yaml`)
3. If no: Does nothing

**Why Minor Version?**
ArgoCD version updates are considered **minor** releases because they:
- Add compatibility with new ArgoCD features
- Don't break existing functionality
- Follow semantic versioning for dependencies

### 4. Commitlint Workflow (`commitlint.yaml`)
**Trigger:** Pull requests

**Purpose:** Enforces Conventional Commits standard

**Rules:**
- Commit messages must follow format: `<type>(<scope>): <subject>`
- Types: `feat`, `fix`, `docs`, `chore`, `test`, `refactor`, etc.
- Validated by `commitlint.yaml` on every pull request

## Dependency Update Process

### Renovate → Auto-Release Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Renovate detects new ArgoCD version (weekly on Friday)       │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Renovate creates PR with updates:                            │
│    - docker/Dockerfile (ARG ARGOCD_VERSION)                     │
│    - All workflows (build-args)                                 │
│    - All documentation (README, docs/*)                         │
│                                                                  │
│    Labels: ["dependencies"]                                     │
│    Commit: "feat(deps): update ArgoCD to v2.11.0"               │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Test workflow runs on PR                                     │
│    - Linting, building, testing with new version                │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Manual review and merge                                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Auto-Release workflow triggers (PR merged + dependencies)    │
│    - Detects ArgoCD version change                              │
│    - Calculates next version (minor bump)                       │
│    - Creates git tag (e.g., v1.3.0)                             │
│    - Pushes tag to repository                                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Release workflow triggers (on tag push)                      │
│    - Builds Docker image                                        │
│    - Runs tests                                                 │
│    - Pushes to container registry                               │
│    - Creates GitHub release                                     │
└─────────────────────────────────────────────────────────────────┘
```

## Required Secrets

Configure these secrets in repository settings:

- `RENOVATE_TOKEN`: Personal access token of the Renovate bot (used by `renovate.yaml`)

`GITHUB_TOKEN` is provided automatically and is used for the GHCR login, tags, releases and for dispatching `release.yaml` from `auto-release.yaml` (workflow dispatches are the one exception to the rule that `GITHUB_TOKEN` events do not trigger workflows).

## Manual Release Process

If you need to create a release manually (not via Renovate):

```bash
# Create and push a tag
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0

# The release workflow will automatically build and publish
```

## Troubleshooting

### Auto-release not triggering
**Check:**
1. PR has `dependencies` label
2. PR was merged (not closed without merge)
3. `docker/Dockerfile` contains `ARG ARGOCD_VERSION` change

### Release workflow fails
**Common issues:**
- Missing `packages: write` permission or package access for the repository
- Test failures (fix before releasing)

## Version Strategy

- **Patch (x.y.Z)**: Bug fixes, documentation updates
- **Minor (x.Y.0)**: ArgoCD version updates, new features
- **Major (X.0.0)**: Breaking changes (e.g., Kubernetes API changes)

Renovate + Auto-release handles **minor** bumps for ArgoCD updates automatically.
