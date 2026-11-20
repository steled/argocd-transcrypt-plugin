# Upgrade Guide

This guide provides detailed instructions for upgrading the ArgoCD Transcrypt Plugin to newer versions and migrating between different ArgoCD versions.

## Table of Contents

- [Version Compatibility](#version-compatibility)
- [Upgrade Paths](#upgrade-paths)
- [Pre-Upgrade Checklist](#pre-upgrade-checklist)
- [Upgrade Procedures](#upgrade-procedures)
- [Post-Upgrade Validation](#post-upgrade-validation)
- [Rollback Procedures](#rollback-procedures)
- [Breaking Changes](#breaking-changes)
- [Migration Guides](#migration-guides)

## Version Compatibility

### Plugin Version Matrix

| Plugin Version | ArgoCD Version | Kubernetes Version | Transcrypt Version | Status |
|---------------|----------------|-------------------|-------------------|---------|
| v1.2.x | v2.11.x | 1.26+ | v2.2.3+ | ✅ Current |
| v1.1.x | v2.10.x | 1.24+ | v2.2.3+ | ✅ Supported |
| v1.0.x | v2.9.x - v2.10.x | 1.23+ | v2.2.0+ | ⚠️ Deprecated |

### Feature Compatibility

| Feature | v1.0.x | v1.1.x | v1.2.x |
|---------|--------|--------|--------|
| Git wrapper (transcrypt decryption) | ✅ | ✅ | ✅ |
| Multi-source apps | ✅ | ✅ | ✅ |
| AES-256-CBC cipher | ✅ | ✅ | ✅ |
| AES-256-CTR cipher | ❌ | ✅ | ✅ |
| Custom cipher config | ❌ | ✅ | ✅ |
| Multi-architecture | ❌ | ❌ | ✅ (amd64 only) |
| Image vulnerability scanning | ❌ | ✅ | ✅ |
| Automated testing | ❌ | ✅ | ✅ |

## Upgrade Paths

### Supported Upgrade Paths

```
v1.0.x ──────────┐
                 ├──> v1.1.x ──────> v1.2.x ──────> v1.3.x (future)
v1.0.x ──────────┘         ▲
                            │
                            └──────── Direct upgrade possible
```

**Recommendations:**
- ✅ **Patch upgrades** (e.g., v1.1.0 → v1.1.1): Direct upgrade
- ✅ **Minor upgrades** (e.g., v1.1.x → v1.2.x): Direct upgrade with validation
- ⚠️ **Major upgrades** (e.g., v1.x → v2.x): Follow migration guide (when available)
- ❌ **Skip versions**: Not recommended, test intermediate versions

### Version Selection

**Choose version based on:**

1. **ArgoCD Version**: Match plugin version to your ArgoCD version
2. **Required Features**: Check [Feature Compatibility](#feature-compatibility)
3. **Security Updates**: Always use latest patch version
4. **Stability**: Wait 1-2 weeks after major/minor releases in production

**Check current version:**

```bash
# Check deployed image tag
kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.containers[?(@.name=="argocd-repo-server")].image}'

# Expected output:
# ghcr.io/steled/argocd-transcrypt-plugin:v1.1.0
```

## Pre-Upgrade Checklist

Before upgrading, complete the following checklist:

### 1. Review Release Notes

```bash
# View release notes on GitHub
curl -s https://api.github.com/repos/steled/argocd-transcrypt-plugin/releases/latest | jq -r '.body'
```

Check for:
- ✅ Breaking changes
- ✅ New features
- ✅ Bug fixes
- ✅ Security patches
- ✅ Deprecated features

### 2. Backup Current Configuration

```bash
# Backup repo-server deployment
kubectl get deployment argocd-repo-server -n argocd -o yaml > backup/repo-server-deployment.yaml

# Backup transcrypt secret
kubectl get secret transcrypt-password -n argocd -o yaml > backup/transcrypt-secret.yaml

# Backup kustomization
cp -r kubernetes/overlays/production/ backup/kustomization-$(date +%Y%m%d)/
```

### 3. Test in Non-Production Environment

- ✅ Deploy to development/staging cluster first
- ✅ Test with representative workloads
- ✅ Validate transcrypt decryption works
- ✅ Verify application sync times
- ✅ Check for any errors in logs

### 4. Schedule Maintenance Window

**Estimated downtime:**
- Minor version upgrade: 2-5 minutes
- Major version upgrade: 5-10 minutes
- Rollback (if needed): 3-5 minutes

**Impact:**
- ArgoCD sync operations temporarily unavailable
- Running applications continue unchanged
- No impact on deployed workloads

### 5. Notify Stakeholders

```
Subject: Scheduled Maintenance - ArgoCD Transcrypt Plugin Upgrade

Date: [YYYY-MM-DD]
Time: [HH:MM - HH:MM UTC]
Duration: ~5 minutes
Impact: ArgoCD sync operations temporarily unavailable

What we're doing:
- Upgrading ArgoCD Transcrypt Plugin from v1.1.0 to v1.2.0
- No changes to deployed applications expected

Contact: team@example.com for questions
```

## Upgrade Procedures

### Minor Version Upgrade (e.g., v1.1.x → v1.2.x)

#### Step 1: Update Image Tag

**Option A: Using Kustomize**

```bash
cd kubernetes/overlays/production

# Edit kustomization.yaml
cat <<EOF > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: argocd

resources:
  - ../../base

images:
  - name: argocd-transcrypt-plugin
    newName: ghcr.io/steled/argocd-transcrypt-plugin
    newTag: v1.2.0  # Updated version

patchesStrategicMerge:
  - repo-server-patch.yaml
EOF

# Apply
kubectl apply -k .
```

**Option B: Direct kubectl**

```bash
# Update image
kubectl set image deployment/argocd-repo-server \
  argocd-repo-server=ghcr.io/steled/argocd-transcrypt-plugin:v1.2.0 \
  -n argocd

# Verify
kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.containers[?(@.name=="argocd-repo-server")].image}'
```

#### Step 2: Monitor Rollout

```bash
# Watch rollout status
kubectl rollout status deployment/argocd-repo-server -n argocd

# Monitor pod creation
watch kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check logs for successful startup
kubectl logs -n argocd deployment/argocd-repo-server -c argocd-repo-server --tail=50
```

#### Step 3: Validate Functionality

```bash
# Test sync of an application with encrypted values
argocd app sync test-app --force

# Check for transcrypt initialization in logs
kubectl logs -n argocd deployment/argocd-repo-server --tail=100 | grep -i transcrypt

# Verify no errors
kubectl get events -n argocd --field-selector type=Warning --sort-by='.lastTimestamp'
```

### Patch Version Upgrade (e.g., v1.1.0 → v1.1.1)

Patch upgrades are typically safe and can be performed with minimal validation:

```bash
# Update image (Kustomize or kubectl)
kubectl set image deployment/argocd-repo-server \
  argocd-repo-server=ghcr.io/steled/argocd-transcrypt-plugin:v1.1.1 \
  -n argocd

# Wait for rollout
kubectl rollout status deployment/argocd-repo-server -n argocd

# Quick validation
argocd app list
```

### Major Version Upgrade (Future: v1.x → v2.x)

*Note: v2.x is not yet released. This section will be updated when available.*

Major version upgrades may include breaking changes. Steps will be documented here when v2.0 is released.

### Upgrading ArgoCD Base Image

When upgrading to a new ArgoCD version, rebuild the custom image:

#### Step 1: Build New Image

```bash
cd docker

# Build with new ArgoCD version
docker build \
  --build-arg ARGOCD_VERSION=v3.5.6 \
  -t ghcr.io/steled/argocd-transcrypt-plugin:v1.2.0-argocd-v2.11.0 \
  .

# Push to registry
docker push ghcr.io/steled/argocd-transcrypt-plugin:v1.2.0-argocd-v2.11.0
```

#### Step 2: Update Deployment

```bash
# Update image tag
kubectl set image deployment/argocd-repo-server \
  argocd-repo-server=ghcr.io/steled/argocd-transcrypt-plugin:v1.2.0-argocd-v2.11.0 \
  -n argocd

# Monitor
kubectl rollout status deployment/argocd-repo-server -n argocd
```

## Post-Upgrade Validation

### Automated Validation Script

```bash
#!/bin/bash
# validate-upgrade.sh

set -e

echo "🔍 Validating ArgoCD Transcrypt Plugin upgrade..."

# 1. Check pod is running
echo "1. Checking pod status..."
kubectl wait --for=condition=Ready \
  pod -l app.kubernetes.io/name=argocd-repo-server \
  -n argocd \
  --timeout=300s

# 2. Verify image version
echo "2. Verifying image version..."
IMAGE=$(kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.containers[?(@.name=="argocd-repo-server")].image}')
echo "   Current image: $IMAGE"

# 3. Check the git wrapper is installed
echo "3. Checking git wrapper..."
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n argocd $POD -c argocd-repo-server -- \
  sh -c 'readlink /usr/bin/git | grep -q git-wrapper'
echo "   ✓ Git wrapper is installed"

# 4. Verify secret is mounted
echo "4. Verifying secret mount..."
kubectl exec -n argocd $POD -c argocd-repo-server -- \
  test -d /transcrypt-secret
echo "   ✓ Secret mounted correctly"

# 5. Test application sync
echo "5. Testing application sync..."
if argocd app list &>/dev/null; then
  # Get first app
  TEST_APP=$(argocd app list -o name | head -1)
  if [ -n "$TEST_APP" ]; then
    argocd app sync $TEST_APP --dry-run &>/dev/null
    echo "   ✓ Application sync test passed"
  else
    echo "   ⚠ No applications found to test"
  fi
else
  echo "   ⚠ ArgoCD CLI not configured, skipping sync test"
fi

# 6. Check for errors in logs
echo "6. Checking logs for errors..."
ERROR_COUNT=$(kubectl logs -n argocd deployment/argocd-repo-server --tail=100 | grep -ci error || true)
if [ "$ERROR_COUNT" -gt 0 ]; then
  echo "   ⚠ Found $ERROR_COUNT errors in logs, review manually:"
  kubectl logs -n argocd deployment/argocd-repo-server --tail=50 | grep -i error
else
  echo "   ✓ No errors in logs"
fi

echo ""
echo "✅ Validation complete!"
```

Run validation:

```bash
chmod +x validate-upgrade.sh
./validate-upgrade.sh
```

### Manual Validation Checklist

- [ ] Repo-server pod is Running
- [ ] No CrashLoopBackOff or ImagePullBackOff errors
- [ ] `/usr/bin/git` is the git wrapper
- [ ] Transcrypt secret is mounted
- [ ] At least one application syncs successfully
- [ ] Transcrypt decryption logs appear
- [ ] No unusual errors in pod logs
- [ ] Application sync times are reasonable (<30s additional overhead)

## Rollback Procedures

If issues are encountered after upgrade, roll back to the previous version:

### Quick Rollback (< 5 minutes)

```bash
# Rollback to previous revision
kubectl rollout undo deployment/argocd-repo-server -n argocd

# Wait for rollback
kubectl rollout status deployment/argocd-repo-server -n argocd

# Verify previous version
kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.containers[?(@.name=="argocd-repo-server")].image}'
```

### Full Rollback (from backup)

```bash
# Restore from backup
kubectl apply -f backup/repo-server-deployment.yaml

# Force pod recreation
kubectl rollout restart deployment/argocd-repo-server -n argocd

# Verify
kubectl rollout status deployment/argocd-repo-server -n argocd
```

### Post-Rollback Steps

1. **Document the issue:**
```bash
# Collect logs
kubectl logs -n argocd deployment/argocd-repo-server --previous > rollback-logs-$(date +%Y%m%d-%H%M%S).log

# Save events
kubectl get events -n argocd --sort-by='.lastTimestamp' > rollback-events-$(date +%Y%m%d-%H%M%S).log
```

2. **Report issue:**
   - Open GitHub issue with logs and steps to reproduce
   - Include ArgoCD version, Kubernetes version, plugin version
   - Document impact and rollback reason

3. **Schedule retry:**
   - Wait for fix or guidance from maintainers
   - Test fix in non-production environment
   - Retry upgrade in next maintenance window

## Breaking Changes

### v1.1.0 → v1.2.0

**⚠️ Breaking Changes:**
- None

**New Features:**
- Multi-cipher support (AES-256-CTR, ChaCha20)
- Improved error logging
- Performance optimizations

**Deprecations:**
- None

### v1.0.0 → v1.1.0

**⚠️ Breaking Changes:**
- None

**New Features:**
- Custom cipher configuration via environment variable
- Automated testing in CI/CD
- Trivy vulnerability scanning

**Deprecations:**
- None

### Future Breaking Changes (v2.0.0)

*Planned for future release:*
- Migration to CMP sidecar architecture (if ArgoCD supports plugins on ref sources)
- New secret format (backward compatible migration path will be provided)
- Minimum ArgoCD version: v2.12.0

## Migration Guides

### Migrating from SOPS to Transcrypt

If migrating from SOPS to transcrypt with this plugin:

#### Step 1: Decrypt SOPS Files

```bash
# Decrypt all SOPS files
find . -name "*-secret-values.yaml" -type f -exec sops -d -i {} \;
```

#### Step 2: Initialize Transcrypt

```bash
# Initialize transcrypt in repository
transcrypt -c aes-256-cbc -p "$(openssl rand -base64 32)"

# Update .gitattributes
echo "*-secret-values.yaml filter=crypt diff=crypt merge=crypt" >> .gitattributes

# Commit
git add .gitattributes
git commit -m "chore: migrate from SOPS to transcrypt"
git push
```

#### Step 3: Deploy Plugin

Follow [DEPLOYMENT.md](DEPLOYMENT.md) installation steps.

#### Step 4: Update Applications

Remove SOPS-specific configuration from ArgoCD Applications (no plugin references needed).

### Migrating from Sealed Secrets to Transcrypt

If migrating from Sealed Secrets:

#### Step 1: Export Secrets

```bash
# For each SealedSecret, extract the actual secret values
kubectl get sealedsecret grafana-credentials -n monitoring -o json | \
  kubeseal --recovery-unseal --recovery-private-key sealed-secrets-key.pem
```

#### Step 2: Create Values Files

```bash
# Create Helm values files with sensitive data
cat > helm-values/environments/prod/grafana-secret-values.yaml <<EOF
grafana:
  user: admin
  password: extracted-password-here
EOF
```

#### Step 3: Initialize Transcrypt

Follow [Step 2 from SOPS migration](#step-2-initialize-transcrypt)

#### Step 4: Update Helm Charts

Modify Helm charts to use values directly instead of referencing SealedSecrets:

```yaml
# Before (Sealed Secrets approach)
existingSecret: grafana-credentials

# After (Helm values approach)
user: {{ .Values.grafana.user }}
password: {{ .Values.grafana.password }}
```

## Support

For upgrade-related issues:

- 📖 [GitHub Discussions](https://github.com/steled/argocd-transcrypt-plugin/discussions)
- 🐛 [Report Bug](https://github.com/steled/argocd-transcrypt-plugin/issues/new?template=bug_report.md)
- 💬 [Community Chat](https://github.com/steled/argocd-transcrypt-plugin/discussions)

## Next Steps

- Review [SECURITY.md](SECURITY.md) for security best practices after upgrade
- Check [DEVELOPMENT.md](DEVELOPMENT.md) for contributing to future releases
- Read [Release Notes](https://github.com/steled/argocd-transcrypt-plugin/releases) for detailed changelog
