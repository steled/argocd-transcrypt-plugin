# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial implementation of ArgoCD Transcrypt Plugin
- Custom Docker image based on ArgoCD
- Git wrapper for automatic transcrypt initialization
- Kubernetes manifests using Kustomize
- Comprehensive documentation (DEPLOYMENT, SECURITY, UPGRADE, DEVELOPMENT, CICD-SETUP)
- Automated CI/CD with GitHub Actions
- Unit and integration test suite
- Example configurations for single and multi-source applications
- Renovate configuration for automated dependency updates

### Changed
- N/A

### Deprecated
- N/A

### Removed
- N/A

### Fixed
- N/A

### Security
- Transcrypt password stored in Kubernetes Secret
- RBAC policies for least-privilege access

---

## Release Notes

Releases are created by the release workflow when a `v*` tag is pushed.

For detailed release information, see [GitHub Releases](https://github.com/steled/argocd-transcrypt-plugin/releases).
