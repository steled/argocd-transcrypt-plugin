# CI/CD Setup

This document describes the GitHub Actions pipelines of this repository and the one-time setup they require.

## Table of Contents

- [Workflow Overview](#workflow-overview)
- [Required Secrets](#required-secrets)
- [Repository Settings](#repository-settings)
- [Release Process](#release-process)
- [Dependency Updates (Renovate)](#dependency-updates-renovate)
- [Troubleshooting](#troubleshooting)

## Workflow Overview

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `test.yaml` | PR / push to `main` (relevant paths) | hadolint, shellcheck, image build, unit and Kind integration tests |
| `commitlint.yaml` | Pull request | Validates [Conventional Commits](https://www.conventionalcommits.org/) |
| `auto-release.yaml` | Merged PR labeled `dependencies` | Creates the next minor tag when the ArgoCD or transcrypt version changed and dispatches `release.yaml` |
| `release.yaml` | Tag `v*` or manual dispatch | Builds, tests and pushes the image to GHCR, creates the GitHub release and opens a PR that updates version references |
| `renovate.yaml` | Weekly (Friday) / manual | Runs self-hosted Renovate |

### Image tags

`release.yaml` pushes `ghcr.io/steled/argocd-transcrypt-plugin` with the tags

- `vX.Y.Z` (plugin version),
- `<argocd-version>-transcrypt-vX.Y.Z` (combined tag) and
- `latest`.

## Required Secrets

| Secret | Used by | Purpose |
|--------|---------|---------|
| `GITHUB_TOKEN` | all workflows | Provided automatically by GitHub (GHCR push, releases, tags, workflow dispatch) |
| `RENOVATE_TOKEN` | `renovate.yaml` | Personal access token of the Renovate bot account (needs `repo` and `workflow` scopes) |

No registry credentials have to be configured: GHCR is authenticated with `GITHUB_TOKEN`.

```bash
gh secret set RENOVATE_TOKEN --repo steled/argocd-transcrypt-plugin
```

## Repository Settings

- **Default branch:** `main`
- **Actions > General > Workflow permissions:** "Read repository contents and packages permissions" (the workflows request what they need via `permissions:`) and "Allow GitHub Actions to create and approve pull requests" (needed for the version reference PR)
- **Labels:** a `dependencies` label must exist (Renovate sets it, `auto-release.yaml` evaluates it)
- **Packages:** after the first release, set the visibility of the `argocd-transcrypt-plugin` package under *Package settings* as desired (public to allow pulls without an image pull secret)

## Release Process

The manifests reference `v1.0.0`, so create the first release manually with that tag (auto-release continues from the latest tag with the next minor version).

Releases are tag driven:

```bash
git tag v1.2.0
git push origin v1.2.0
```

or manually via *Actions > Release > Run workflow* with the tag as input.

For ArgoCD updates the process is automatic:

1. Renovate opens a PR that bumps `ARGOCD_VERSION` or `TRANSCRYPT_VERSION` in `docker/Dockerfile` (and the references in workflows and docs).
2. After merging, `auto-release.yaml` compares both versions with the latest tag, creates the next minor tag and dispatches `release.yaml`.
3. `release.yaml` builds the image, runs the tests, pushes to GHCR and creates the GitHub release.
4. `release.yaml` opens a PR (`chore: update version references to vX.Y.Z`) that updates the image tags in `examples/helm-values.yaml`, the Kubernetes manifests and the README to the new release (`<argocd>-transcrypt-<plugin>` and plugin tags). Merge it to keep all references current.

## Dependency Updates (Renovate)

- `renovate.json` contains the update rules (ArgoCD image, transcrypt release, version references in workflows and docs). Image tags of the plugin itself are not tracked by Renovate; the release workflow updates them.
- `.github/renovate-config.json` is the runner configuration (bot account, repositories).
- `.github/workflows/renovate.yaml` runs Renovate with `RENOVATE_TOKEN`.

## Troubleshooting

### Image push fails with `unauthorized`

- Check that the workflow has `packages: write` permission (set in `release.yaml`).
- If the package already exists from a different source, grant the repository *Write* access under *Package settings > Manage Actions access*.

### Renovate does not create PRs

- Verify that `RENOVATE_TOKEN` exists and is not expired.
- Check the run log of the *Renovate* workflow (log level is `debug`).

### `auto-release.yaml` does not create a tag

- The merged PR must carry the `dependencies` label.
- The ArgoCD version in `docker/Dockerfile` must differ from the version at the latest tag.

### Commitlint fails

Commit messages must follow Conventional Commits, for example `feat(deps): update ArgoCD to v3.5.6`. The rules are defined in `commitlint.config.js`.
