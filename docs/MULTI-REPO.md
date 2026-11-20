# Multi-Repository Setup with Different Transcrypt Passwords

This document describes how to use multiple repositories, each encrypted with a different transcrypt password, in ArgoCD.

## Overview

The ArgoCD Transcrypt Plugin looks up the password of a repository by a key derived from the repository URL. Every transcrypt-encrypted repository needs its own key in the secret (repositories sharing a password simply get the same value under different keys).

**Repositories without a matching key are left untouched**: the git wrapper does not decrypt them and does not fail. There is no default or fallback password.

Two strategies are possible:

1. **One secret with multiple keys** (recommended)
2. **Separate secrets per repository**

## Strategy 1: One Kubernetes Secret with Multiple Keys (Recommended)

### Concept

Create one Kubernetes Secret with multiple data keys, where each key corresponds to one repository:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: transcrypt-password
  namespace: argocd
type: Opaque
stringData:
  # Cipher used for all repositories (optional, default: aes-256-cbc)
  cipher: "aes-256-cbc"

  # Repository-specific passwords
  # Key format: sanitized repository URL
  github.com_myorg_myapp-config: "password-for-myapp-config"
  github.com_myorg_helm-charts: "password-for-helm-charts"
  github.com_myorg_encrypted-values: "password-for-values-repo"
```

### URL Sanitization

The git wrapper converts repository URLs into secret keys automatically:

| Repository URL | Secret Key |
|----------------|------------|
| `https://github.com/myorg/repo.git` | `github.com_myorg_repo` |
| `git@github.com:myorg/repo.git` | `github.com_myorg_repo` |
| `https://gitlab.com/group/subgroup/project.git` | `gitlab.com_group_subgroup_project` |

**Sanitization rules:**
- The protocol (`https://`) and the user part (`git@`) are removed
- The `.git` suffix is removed
- `:` and `/` are replaced by `_`
- The result is converted to lowercase
- Dots and dashes are kept

### Example: Setup for Three Repositories

```bash
# Find the repository URLs used by your applications
kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.spec.sources[*].repoURL}{"\n"}{end}' | sort -u

# Output:
# https://github.com/myorg/myapp-config.git
# https://github.com/myorg/helm-charts.git
# https://github.com/myorg/encrypted-values.git

# Create the secret with all passwords
kubectl create secret generic transcrypt-password -n argocd \
  --from-literal=cipher="aes-256-cbc" \
  --from-literal=github.com_myorg_myapp-config="AppConfigPassword123!" \
  --from-literal=github.com_myorg_helm-charts="HelmChartsPassword456!" \
  --from-literal=github.com_myorg_encrypted-values="EncryptedValuesPassword789!" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Secret as YAML File

```yaml
# transcrypt-passwords.yaml
apiVersion: v1
kind: Secret
metadata:
  name: transcrypt-password
  namespace: argocd
type: Opaque
stringData:
  # Cipher (optional)
  cipher: "aes-256-cbc"

  # App-config repository
  github.com_myorg_myapp-config: "myapp-config-transcrypt-password"

  # Helm charts repository
  github.com_myorg_helm-charts: "helm-charts-transcrypt-password"

  # Encrypted values repository
  github.com_myorg_encrypted-values: "encrypted-values-transcrypt-password"
```

Apply it:
```bash
kubectl apply -f transcrypt-passwords.yaml
```

## Strategy 2: Separate Secrets per Repository

### Concept

Create a separate secret for every repository and adjust the deployment patches accordingly.

**Not recommended**, because it is more complex and requires multiple deployment patches.

### Example

```yaml
# transcrypt-password-myapp-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: transcrypt-password-myapp-config
  namespace: argocd
stringData:
  password: "myapp-config-password"
---
# transcrypt-password-helm.yaml
apiVersion: v1
kind: Secret
metadata:
  name: transcrypt-password-helm
  namespace: argocd
stringData:
  password: "helm-charts-password"
```

This strategy requires custom logic in the wrapper to select the right secret.

## How the Git Wrapper Works

`/usr/bin/git` in the image is `git-wrapper.sh`. After a successful `clone`, `checkout`, `pull` or `fetch` it implements the following logic:

```bash
# 1. Skip if transcrypt is already configured in the repository
transcrypt --display >/dev/null 2>&1 && exit 0

# 2. Determine the repository URL
repo_url=$(git.real config --get remote.origin.url)
# Example: https://github.com/myorg/myapp-config.git

# 3. Sanitize the URL
repo_key=$(echo "$repo_url" | sed -e 's|.*://||' -e 's|^[^@/]*@||' -e 's|[:/]|_|g' -e 's|\.git$||' | tr '[:upper:]' '[:lower:]')
# Result: github.com_myorg_myapp-config

# 4. Look for the repository-specific password
if [ ! -f "/transcrypt-secret/${repo_key}" ]; then
    # No key: the repository is assumed not to use transcrypt, nothing is changed
    exit 0
fi
password=$(cat "/transcrypt-secret/${repo_key}")

# 5. Initialize transcrypt (decrypts the files); the password is never logged
transcrypt -c "$TRANSCRYPT_CIPHER" -p "$password" -y
```

## Deployment

### Updating the Kubernetes Manifests

No changes to the deployment are required. The existing manifest works as is:

```yaml
# kubernetes/base/repo-server-patch.yaml
# (no changes required)
```

### Creating the Secret

```bash
# Method 1: kubectl create
kubectl create secret generic transcrypt-password -n argocd \
  --from-literal=github.com_myorg_repo1="password1" \
  --from-literal=github.com_myorg_repo2="password2"

# Method 2: YAML file
kubectl apply -f transcrypt-passwords.yaml

# Method 3: Sealed Secrets (for GitOps)
kubeseal -f transcrypt-passwords.yaml -w transcrypt-passwords-sealed.yaml
kubectl apply -f transcrypt-passwords-sealed.yaml
```

## Verification

### 1. Check the Secret Keys

```bash
# Show all keys in the secret
kubectl get secret transcrypt-password -n argocd -o jsonpath='{.data}' | jq 'keys'

# Example output:
# [
#   "github.com_myorg_myapp-config",
#   "github.com_myorg_encrypted-values",
#   "github.com_myorg_helm-charts",
#   "password"
# ]
```

### 2. Check the Wrapper Logs

```bash
# Filter the repo-server logs
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n argocd $POD | grep git-wrapper

# Expected output:
# [git-wrapper] Git command: fetch, checking for transcrypt configuration
# [git-wrapper] Transcrypt not configured, attempting initialization...
# [git-wrapper] Repository URL: https://github.com/myorg/myapp-config.git
# [git-wrapper] Found repository-specific password for: github.com_myorg_myapp-config, loading
# [git-wrapper] Transcrypt initialization successful
```

### 3. Test an Application Sync

```bash
# Sync the ArgoCD application
argocd app sync myapp-production

# Check the status
argocd app get myapp-production

# On success: Status = Synced, Health = Healthy
```

## Troubleshooting

### Problem: Wrong Password Used

**Symptom:**
```
[git-wrapper] ====== TRANSCRYPT ERROR ======
[git-wrapper] Exit code: 1
transcrypt: password does not match the one used to configure this repository
```

**Solution:**
```bash
# 1. Check the repository URL
kubectl logs -n argocd <repo-server-pod> | grep "Repository URL:"   # logged by [git-wrapper]

# 2. Compute the expected secret key
# Example: https://github.com/myorg/repo.git → github.com_myorg_repo

# 3. Check the secret key
kubectl get secret transcrypt-password -n argocd -o jsonpath='{.data.github\.com_myorg_repo}' | base64 -d

# 4. If the key is missing or wrong: update the secret
kubectl create secret generic transcrypt-password -n argocd \
  --from-literal=github.com_myorg_repo="correct-password" \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Restart the repo-server
kubectl rollout restart deployment/argocd-repo-server -n argocd
```

### Problem: Repository Is Not Decrypted

**Symptom:** Files stay encrypted and the log shows
`[git-wrapper] No repository-specific password found (key: ...), repository does not use transcrypt`

**Cause:** The secret has no key matching the sanitized URL (there is no default password)

**Solution:**
```bash
# 1. Determine the actual repository URL from the ArgoCD application
kubectl get application myapp -n argocd -o jsonpath='{.spec.sources[*].repoURL}'

# 2. Sanitize it manually
# https://github.com/myorg/my-repo.git
# → github.com_myorg_my-repo (WITHOUT .git)

# 3. Create the secret with the correct key
kubectl patch secret transcrypt-password -n argocd \
  --type='json' \
  -p='[{"op": "add", "path": "/data/github.com_myorg_my-repo", "value":"'$(echo -n "my-password" | base64)'"}]'
```

### Problem: Key Names with Special Characters

**Symptom:** The secret key contains characters that cause problems

**Example:**
```yaml
stringData:
  # WRONG: contains "/"
  "github.com/myorg/repo": "password"

  # RIGHT: "/" and ":" replaced by "_"
  github.com_myorg_repo: "password"
```

**Solution:** Use `_` as the separator instead of `/` or `:`. Dots and dashes are kept as they are in the URL.

## Best Practices

### 1. Naming Convention

Use consistent names for secret keys:
```
<domain>_<org>_<repo>
```

Examples:
- `github.com_myorg_myapp-config`
- `gitlab.example.com_team_project`
- `bitbucket.org_user_repository`

### 2. Documentation

Document your repository-to-key mappings:

```markdown
| Repository | Secret Key | Password Rotation |
|------------|------------|-------------------|
| github.com/myorg/myapp-config | github.com_myorg_myapp-config | 2025-12-01 |
| github.com/myorg/helm-charts | github.com_myorg_helm-charts | 2025-11-15 |
```

### 3. Password Rotation

Rotate passwords regularly:

```bash
# 1. Set a new password in the repository
cd /path/to/repo
transcrypt --rekey -p "new-password"
git push

# 2. Update the secret in Kubernetes
kubectl patch secret transcrypt-password -n argocd \
  --type='json' \
  -p='[{"op": "replace", "path": "/data/github.com_myorg_repo", "value":"'$(echo -n "new-password" | base64)'"}]'

# 3. Restart the repo-server
kubectl rollout restart deployment/argocd-repo-server -n argocd

# 4. Sync the application again
argocd app sync myapp
```

### 4. Monitoring

Monitor transcrypt errors:

```yaml
# prometheus-alerts.yaml
- alert: TranscryptPasswordMismatch
  expr: |
    count_over_time({namespace="argocd",pod=~"argocd-repo-server.*"}
      |= "password does not match"[10m]) > 0
  for: 2m
  annotations:
    summary: "Transcrypt password mismatch detected"
    description: "Check if the password in Secret matches the repository"
```

### 5. GitOps-Ready

Use Sealed Secrets for GitOps:

```bash
# 1. Create the secret
cat > transcrypt-passwords.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: transcrypt-password
  namespace: argocd
stringData:
  cipher: "aes-256-cbc"
  github.com_myorg_repo1: "password1"
  github.com_myorg_repo2: "password2"
EOF

# 2. Encrypt it with kubeseal
kubeseal -f transcrypt-passwords.yaml -w transcrypt-passwords-sealed.yaml

# 3. Commit it to Git
git add transcrypt-passwords-sealed.yaml
git commit -m "feat(argocd): add transcrypt passwords for multiple repos"
git push
```

## Example: Complete Setup

### 1. Identify the Repositories

```bash
cd /path/to/myapp-config

# Show the git URL
git config --get remote.origin.url
# Example: https://github.com/myorg/myapp-config.git

# Resulting secret key: github.com_myorg_myapp-config
```

### 2. Create the Secret

```bash
# Collect the transcrypt passwords from your repositories
APP_CONFIG_PASSWORD="your-myapp-config-transcrypt-password"
OTHER_REPO_PASSWORD="other-repo-transcrypt-password"

# Create the secret
kubectl create secret generic transcrypt-password -n argocd \
  --from-literal=cipher="aes-256-cbc" \
  --from-literal=github.com_myorg_myapp-config="$APP_CONFIG_PASSWORD" \
  --from-literal=github.com_myorg_other-repo="$OTHER_REPO_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3. Verify

```bash
# Check the secret keys
kubectl get secret transcrypt-password -n argocd -o jsonpath='{.data}' | jq 'keys'

# Check the repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50 | grep transcrypt
```

## Further Information

- 📖 [DEPLOYMENT.md](DEPLOYMENT.md) - Installation and basic configuration
- 🔒 [SECURITY.md](SECURITY.md) - Security best practices
- 📚 [examples/README.md](../examples/README.md) - Practical examples

## Support

- 🐛 [Report issues](https://github.com/steled/argocd-transcrypt-plugin/issues)
- 💬 [Discussions](https://github.com/steled/argocd-transcrypt-plugin/discussions)
