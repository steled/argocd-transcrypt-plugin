# ArgoCD Transcrypt Plugin - Examples

This guide provides practical examples of using the ArgoCD Transcrypt Plugin with your encrypted Helm values files.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Example 1: Basic Single-Source Application](#example-1-basic-single-source-application)
3. [Example 2: Multi-Source Application (Recommended)](#example-2-multi-source-application-recommended)
4. [Example 3: Multiple Environments](#example-3-multiple-environments)
5. [Verification Steps](#verification-steps)
6. [Troubleshooting](#troubleshooting)

## Prerequisites

Before starting, ensure you have:

- ✅ ArgoCD Transcrypt Plugin deployed (see [DEPLOYMENT.md](../docs/DEPLOYMENT.md))
- ✅ A Git repository with transcrypt-encrypted files
- ✅ The transcrypt password for your repository
- ✅ `kubectl` access to your cluster
- ✅ ArgoCD CLI installed (optional but helpful)

## Example 1: Basic Single-Source Application

### Scenario

You have a Helm chart in the same repository as your encrypted values files.

### Repository Structure

```
my-helm-repo/
├── .gitattributes         # Defines encryption patterns (filter=crypt)
├── charts/
│   └── myapp/
│       ├── Chart.yaml
│       ├── values.yaml    # Public values
│       └── templates/
│           └── ...
└── values/
    └── production/
        └── secret-values.yaml  # Encrypted with transcrypt
```

### Setup .gitattributes

```bash
# In your repository root
cat > .gitattributes <<EOF
# Encrypt all files matching pattern
**/secret-values.yaml filter=crypt diff=crypt merge=crypt
*-secret-values.yaml filter=crypt diff=crypt merge=crypt
EOF
```

### Initialize Transcrypt

```bash
# In your repository root
transcrypt -c aes-256-cbc -p 'your-password-here'

# Add your secret values
echo "database:" > values/production/secret-values.yaml
echo "  password: supersecret123" >> values/production/secret-values.yaml

# Commit and push
git add .gitattributes values/production/secret-values.yaml
git commit -m "Add encrypted values"
git push
```

### Create ArgoCD Application

```yaml
# application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-production
  namespace: argocd
spec:
  project: default
  
  source:
    repoURL: https://github.com/yourorg/my-helm-repo.git
    targetRevision: main
    path: charts/myapp
    helm:
      valueFiles:
        - values.yaml
        - ../../values/production/secret-values.yaml  # Encrypted file
  
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp-production
  
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Deploy

```bash
kubectl apply -f application.yaml
```

## Example 2: Multi-Source Application (Recommended)

### Scenario

Your Helm chart is in one repository, encrypted values in another.

### Repository Structure

**Chart Repository:** `github.com/yourorg/helm-charts`
```
helm-charts/
└── myapp/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        └── ...
```

**Values Repository:** `github.com/yourorg/encrypted-values`
```
encrypted-values/
├── .gitattributes
└── environments/
    ├── production/
    │   ├── myapp-secret-values.yaml  # Encrypted
    │   └── myapp-values.yaml         # Public
    └── staging/
        ├── myapp-secret-values.yaml  # Encrypted
        └── myapp-values.yaml         # Public
```

### Setup Values Repository

```bash
# Clone your values repository
git clone https://github.com/yourorg/encrypted-values.git
cd encrypted-values

# Initialize transcrypt
transcrypt -c aes-256-cbc -p 'your-password-here'

# Configure .gitattributes
cat > .gitattributes <<EOF
**/*-secret-values.yaml filter=crypt diff=crypt merge=crypt
EOF

# Create environment structure
mkdir -p environments/production environments/staging

# Add encrypted values
cat > environments/production/myapp-secret-values.yaml <<EOF
database:
  password: prod-secret-password
  connectionString: "encrypted-prod-connection"

api:
  secretKey: prod-api-key-xyz123
EOF

# Add public values
cat > environments/production/myapp-values.yaml <<EOF
replicas: 3
image:
  tag: v1.2.3
EOF

# Commit and push
git add .
git commit -m "Add production values"
git push
```

### Create Multi-Source Application

```yaml
# myapp-production.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-production
  namespace: argocd
spec:
  project: default
  
  # Multiple sources
  sources:
    # Source 1: Helm chart
    - repoURL: https://github.com/yourorg/helm-charts.git
      targetRevision: main
      path: myapp
      helm:
        valueFiles:
          # Reference values from second source using $values prefix
          - $values/environments/production/myapp-values.yaml
          - $values/environments/production/myapp-secret-values.yaml  # Encrypted!
    
    # Source 2: Values repository (encrypted)
    - repoURL: https://github.com/yourorg/encrypted-values.git
      targetRevision: main
      ref: values  # This is the reference name
  
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp-production
  
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Deploy

```bash
kubectl apply -f myapp-production.yaml
```

## Example 3: Multiple Environments

### Scenario

Deploy the same application to multiple environments with different encrypted values.

### Directory Structure

```
encrypted-values/
├── .gitattributes
└── environments/
    ├── production/
    │   ├── myapp-secret-values.yaml
    │   └── myapp-values.yaml
    ├── staging/
    │   ├── myapp-secret-values.yaml
    │   └── myapp-values.yaml
    └── development/
        ├── myapp-secret-values.yaml
        └── myapp-values.yaml
```

### Create Applications for Each Environment

**Production:**
```yaml
# myapp-production.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-production
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/yourorg/helm-charts.git
      targetRevision: v1.2.3  # Pinned version
      path: myapp
      helm:
        valueFiles:
          - $values/environments/production/myapp-values.yaml
          - $values/environments/production/myapp-secret-values.yaml
    - repoURL: https://github.com/yourorg/encrypted-values.git
      targetRevision: production  # Branch/tag per environment
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp-production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Staging:**
```yaml
# myapp-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-staging
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/yourorg/helm-charts.git
      targetRevision: main  # Latest from main
      path: myapp
      helm:
        valueFiles:
          - $values/environments/staging/myapp-values.yaml
          - $values/environments/staging/myapp-secret-values.yaml
    - repoURL: https://github.com/yourorg/encrypted-values.git
      targetRevision: staging
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Deploy All Environments:**
```bash
kubectl apply -f myapp-production.yaml
kubectl apply -f myapp-staging.yaml
kubectl apply -f myapp-development.yaml
```

## Verification Steps

### 1. Check Application Status

```bash
# List all applications
kubectl get applications -n argocd

# Check specific application
kubectl get application myapp-production -n argocd

# Using ArgoCD CLI
argocd app get myapp-production
```

### 2. Verify Decryption in Logs

```bash
# Get repo-server pod name
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')

# Check logs for transcrypt operations
kubectl logs -n argocd $POD | grep -i transcrypt

# Expected output:
# [git-wrapper] Found repository-specific password for: github.com_myorg_encrypted-values, loading
# [git-wrapper] Transcrypt initialization successful
```

### 3. Verify Application Sync

```bash
# Check sync status
argocd app sync myapp-production

# Watch sync progress
argocd app wait myapp-production --health

# Check deployed resources
kubectl get all -n myapp-production
```

### 4. Verify Secret Values are Applied

```bash
# Check if secrets are created correctly
kubectl get secrets -n myapp-production

# Describe a secret to verify it has expected keys
kubectl describe secret myapp-database -n myapp-production

# Check environment variables in pods (if applicable)
kubectl get pod <pod-name> -n myapp-production -o yaml | grep -A 10 env
```

### 5. Test Application Functionality

```bash
# Port-forward to application
kubectl port-forward -n myapp-production svc/myapp 8080:80

# Test database connection (application-specific)
curl http://localhost:8080/health
```

## Troubleshooting

### Issue: Application is "OutOfSync" or "Failed"

**Diagnosis:**
```bash
# Check application events
kubectl describe application myapp-production -n argocd

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

**Common Causes:**
1. **Transcrypt not initialized:** No decryption logs found
   - Solution: Verify transcrypt-password Secret exists and is correct
   ```bash
   kubectl get secret transcrypt-password -n argocd
   kubectl get secret transcrypt-password -n argocd -o jsonpath='{.data.github\.com_myorg_encrypted-values}' | base64 -d
   ```

2. **Wrong password:** Decryption fails
   - Solution: Update the Secret with correct password
   ```bash
   kubectl create secret generic transcrypt-password \
     --from-literal=github.com_myorg_encrypted-values='correct-password' \
     -n argocd --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart repo-server
   kubectl rollout restart deployment/argocd-repo-server -n argocd
   ```

3. **Git wrapper not executing:** No `[git-wrapper]` logs at all
   - Solution: Verify the git wrapper is installed
   ```bash
   POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n argocd $POD -- readlink /usr/bin/git   # expected: /usr/local/bin/git-wrapper
   ```

### Issue: Values file not found

**Error message:**
```
rpc error: code = Unknown desc = Manifest generation error: values don't meet the specifications of the schema
```

**Diagnosis:**
```bash
# Check file paths in Application manifest
kubectl get application myapp-production -n argocd -o yaml | grep valueFiles -A 5
```

**Solution:**
- Verify the file path is correct relative to repository root
- Check if the values repository was cloned successfully
- Ensure the `ref: values` matches in both sources

### Issue: Permission denied errors

**Error message:**
```
fatal: could not read Username for 'https://github.com': terminal prompts disabled
```

**Solution:**
1. For private repositories, configure SSH keys or access tokens
   ```bash
   # Add repository credentials
   argocd repo add https://github.com/yourorg/encrypted-values.git \
     --username your-username \
     --password your-token
   ```

2. Or use SSH URLs:
   ```yaml
   sources:
     - repoURL: git@github.com:yourorg/encrypted-values.git
   ```

### Issue: Decryption works but wrong values applied

**Diagnosis:**
```bash
# Check which values file is being used
argocd app manifests myapp-production | grep -A 20 "kind: ConfigMap"
```

**Solution:**
- Verify valueFiles order (later files override earlier ones)
- Check for typos in file paths
- Ensure transcrypt was initialized before git push

## Advanced Examples

### Using Different Passwords per Environment

If production and staging values live in separate repositories, add one key per repository to the same secret (key = sanitized repository URL, see [MULTI-REPO.md](../docs/MULTI-REPO.md)):

```bash
kubectl create secret generic transcrypt-password \
  --from-literal=cipher='aes-256-cbc' \
  --from-literal=github.com_myorg_prod-values='prod-password' \
  --from-literal=github.com_myorg_stg-values='stg-password' \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -
```

### Auto-Sync with Webhook

Configure webhook in Git repository to trigger ArgoCD sync on push:
```bash
# In ArgoCD UI or CLI
argocd proj create myproject \
  --description "My Project" \
  --src https://github.com/yourorg/* \
  --dest *,*
```

### Monitoring Decryption Operations

Create Prometheus alert for transcrypt failures:
```yaml
# prometheus-alert.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: argocd-transcrypt-alerts
  namespace: argocd
spec:
  groups:
    - name: argocd_transcrypt
      interval: 30s
      rules:
        - alert: TranscryptDecryptionFailure
          expr: |
            count(count_over_time({namespace="argocd",pod=~"argocd-repo-server.*"} 
              |= "transcrypt" |= "error"[5m])) > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Transcrypt decryption failure detected"
            description: "ArgoCD repo-server failed to decrypt transcrypt files"
```

## Best Practices

1. **Use Multi-Source Applications** for separation of concerns
2. **Pin chart versions** in production (`targetRevision: v1.2.3`)
3. **Use branches/tags** for environment-specific values
4. **Test in staging first** before promoting to production
5. **Monitor decryption logs** for failures
6. **Rotate passwords regularly** (see [SECURITY.md](../docs/SECURITY.md))
7. **Document your .gitattributes patterns** for team clarity
8. **Use descriptive value file names** (`myapp-secret-values.yaml`, not `secrets.yaml`)

## Next Steps

- 📖 Read the [DEPLOYMENT Guide](../docs/DEPLOYMENT.md) for installation details
- 🔒 Review [SECURITY Best Practices](../docs/SECURITY.md)
- 🔄 Learn about [UPGRADE Procedures](../docs/UPGRADE.md)
- 🛠️ See [DEVELOPMENT Guide](../docs/DEVELOPMENT.md) for contributing

## Support

- 🐛 [Report Issues](https://github.com/steled/argocd-transcrypt-plugin/issues)
- 💬 [Ask Questions](https://github.com/steled/argocd-transcrypt-plugin/discussions)
