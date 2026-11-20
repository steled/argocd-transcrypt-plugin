# Security Guide

This document outlines security best practices, threat model, and operational security procedures for the ArgoCD Transcrypt Plugin.

## Table of Contents

- [Security Model](#security-model)
- [Threat Analysis](#threat-analysis)
- [Secret Management](#secret-management)
- [Access Control](#access-control)
- [Password Rotation](#password-rotation)
- [Audit Logging](#audit-logging)
- [Incident Response](#incident-response)
- [Compliance](#compliance)

## Security Model

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│ Git Repository (Encrypted at Rest)                          │
│ ✓ Transcrypt-encrypted sensitive files                      │
│ ✓ Safe to store in version control                          │
│ ✓ Visible structure, encrypted values                       │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTTPS/SSH (TLS)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster - ArgoCD Namespace                        │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Kubernetes Secret: transcrypt-password                  │ │
│ │ ⚠️  HIGH SECURITY ZONE                                  │ │
│ │ - Encrypted at rest (encryption-at-rest enabled)        │ │
│ │ - RBAC-protected (read access restricted)               │ │
│ │ - Mounted read-only to repo-server                      │ │
│ └─────────────────────────────────────────────────────────┘ │
│                            │                                  │
│                            │ Volume Mount (read-only)         │
│                            ▼                                  │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ ArgoCD Repo-Server Pod                                  │ │
│ │ - Password available only in memory                     │ │
│ │ - Git wrapper has access to password (never logs it)    │ │
│ │ - Decrypted files exist temporarily in pod filesystem   │ │
│ │ - No persistence of decrypted data                      │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Target Kubernetes Clusters                                   │
│ ✓ Only rendered manifests transmitted                        │
│ ✓ No transcrypt password leaves ArgoCD namespace            │
└─────────────────────────────────────────────────────────────┘
```

### Security Assumptions

✅ **Assumed Secure:**
- Kubernetes cluster with encryption-at-rest enabled
- Network policies isolating ArgoCD namespace
- RBAC properly configured
- TLS for all Git communications
- Trusted container registry (ghcr.io)

⚠️ **Attack Vectors Mitigated:**
- Git repository compromise (files remain encrypted)
- Git history exposure (sensitive values never committed in plaintext)
- Accidental public repository exposure (encrypted files useless without password)

❌ **Not Protected Against:**
- Kubernetes cluster compromise with admin access
- Compromised container registry (malicious image injection)
- Memory dump of repo-server pod (decrypted files in memory)
- Supply chain attacks on base ArgoCD image

## Threat Analysis

### Threat Model

| Threat | Likelihood | Impact | Mitigation |
|--------|-----------|---------|------------|
| **Git Repository Leak** | Medium | Low | Files encrypted; password stored separately |
| **Kubernetes Secret Exposure** | Low | Critical | RBAC, encryption-at-rest, audit logging |
| **Pod Memory Dump** | Low | High | Ephemeral decryption, pod security policies |
| **Insider Threat** | Medium | High | Audit logging, separation of duties, rotation |
| **Supply Chain Attack** | Low | Critical | Image signing (future), vulnerability scanning |
| **Password Brute Force** | Very Low | Medium | Strong password policy, AES-256 encryption |

### Attack Scenarios

#### Scenario 1: Git Repository Compromised

**Attack:** Adversary gains access to Git repository.

**Impact:** 
- ✅ **Mitigated**: Files are transcrypt-encrypted
- ✅ **Mitigated**: Password not stored in repository
- ⚠️ **Risk**: Attacker can see file structure and change history

**Recommendations:**
- Use private repositories with 2FA
- Implement branch protection rules
- Monitor for unauthorized access attempts

#### Scenario 2: Kubernetes Secret Leaked

**Attack:** Adversary obtains transcrypt-password Kubernetes Secret.

**Impact:**
- ❌ **Critical**: Can decrypt all files in the repository
- ❌ **Critical**: Can decrypt historical encrypted data

**Recommendations:**
- Enable encryption-at-rest for etcd
- Strict RBAC policies (see [Access Control](#access-control))
- Regular password rotation (see [Password Rotation](#password-rotation))
- External secret management (Vault, AWS Secrets Manager)

#### Scenario 3: Repo-Server Pod Compromise

**Attack:** Adversary gains exec access to repo-server pod.

**Impact:**
- ❌ **High**: Can read decrypted files in memory/filesystem
- ❌ **High**: Can access transcrypt password from mounted secret
- ⚠️ **Medium**: Access limited to pod's service account permissions

**Recommendations:**
- Pod Security Standards: Restricted profile
- Network policies: Egress filtering
- Runtime security monitoring (Falco, Tetragon)
- Regular security audits

## Secret Management

### Best Practices

#### 1. Kubernetes Secret Encryption

**Enable encryption-at-rest** for Kubernetes Secrets:

```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}
```

Apply to API server:
```bash
# Add to kube-apiserver manifest
--encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

#### 2. External Secret Management

**Option A: HashiCorp Vault Integration**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: transcrypt-password
  namespace: argocd
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/agent-inject-secret-password: "secret/data/argocd/transcrypt"
    vault.hashicorp.com/role: "argocd"
type: Opaque
```

**Option B: External Secrets Operator**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: transcrypt-password
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: transcrypt-password
    creationPolicy: Owner
  data:
    - secretKey: github.com_myorg_myapp-config   # key = sanitized repository URL
      remoteRef:
        key: argocd/transcrypt
        property: password
```

#### 3. Password Strength Requirements

**Minimum Requirements:**
- ✅ Length: 32+ characters
- ✅ Entropy: 128+ bits
- ✅ Randomness: Cryptographically secure random generator
- ✅ No dictionary words or patterns

**Generate Strong Password:**

```bash
# Using openssl
openssl rand -base64 32

# Using pwgen
pwgen -s 48 1

# Using /dev/urandom
tr -dc 'A-Za-z0-9!@#$%^&*()_+' < /dev/urandom | head -c 48
```

#### 4. Secret Distribution

**Never:**
- ❌ Store password in Git (even in private repos)
- ❌ Send password via email or chat
- ❌ Store password in CI/CD logs
- ❌ Hardcode password in scripts or configs

**Instead:**
- ✅ Use secure password managers (1Password, LastPass)
- ✅ Encrypt with recipient's GPG key for transfer
- ✅ Use time-limited secret sharing tools
- ✅ Implement proper onboarding/offboarding procedures

## Access Control

### RBAC Policies

#### Principle of Least Privilege

**Restrict access to transcrypt-password Secret:**

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-repo-server
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-repo-server-transcrypt
  namespace: argocd
rules:
  # Only allow reading the specific transcrypt secret
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["transcrypt-password"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-repo-server-transcrypt
  namespace: argocd
subjects:
  - kind: ServiceAccount
    name: argocd-repo-server
    namespace: argocd
roleRef:
  kind: Role
  name: argocd-repo-server-transcrypt
  apiGroup: rbac.authorization.k8s.io
```

#### Deny Human Access

**Prevent kubectl access to Secret:**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-admin-no-secrets
  namespace: argocd
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["*"]
  # Explicitly deny secrets access
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
    resourceNames: ["transcrypt-password"]
```

#### Break-Glass Access

For emergency access, use:

```bash
# Requires cluster-admin or equivalent
kubectl auth can-i get secrets/transcrypt-password -n argocd

# Audit trail
kubectl get secret transcrypt-password -n argocd \
  --as=system:admin \
  --audit-annotations='reason=password-rotation,ticket=INC-12345'
```

### Network Policies

**Isolate repo-server network access:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-repo-server-netpol
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Only from argocd-server
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-server
      ports:
        - protocol: TCP
          port: 8081
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Git repositories (HTTPS)
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 443
    # Kubernetes API
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 6443
```

## Password Rotation

### Rotation Policy

**Recommended Schedule:**
- 🔄 **Routine Rotation**: Every 90 days
- 🚨 **Emergency Rotation**: Immediately upon suspected compromise
- 👤 **Personnel Change**: When team members leave/change roles

### Rotation Procedure

#### Step 1: Generate New Password

```bash
# Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# Save securely (e.g., password manager)
echo "$NEW_PASSWORD" | gpg --encrypt --recipient team@example.com > new-transcrypt-password.gpg
```

#### Step 2: Re-encrypt Repository

```bash
# Clone the repository
git clone https://github.com/your-org/encrypted-repo.git
cd encrypted-repo

# Initialize with old password
transcrypt -c aes-256-cbc -p "$OLD_PASSWORD" -y

# Re-key with new password
transcrypt --rekey -c aes-256-cbc -p "$NEW_PASSWORD"

# Commit and push
git add .
git commit -m "security: rotate transcrypt password"
git push origin main
```

#### Step 3: Update Kubernetes Secret

```bash
# Update secret
kubectl create secret generic transcrypt-password \
  --from-literal=github.com_myorg_repo="$NEW_PASSWORD" \   # key = sanitized repository URL
  --from-literal=cipher='aes-256-cbc' \
  --namespace argocd \
  --dry-run=client -o yaml | kubectl apply -f -

# Verify secret updated
kubectl get secret transcrypt-password -n argocd -o jsonpath='{.metadata.creationTimestamp}'
```

#### Step 4: Rolling Restart

```bash
# Restart repo-server to pick up new password
kubectl rollout restart deployment/argocd-repo-server -n argocd

# Wait for completion
kubectl rollout status deployment/argocd-repo-server -n argocd

# Verify pods are using new secret
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

#### Step 5: Validate

```bash
# Trigger a sync of an application using encrypted values
argocd app sync test-app --force

# Check logs for successful decryption
kubectl logs -n argocd deployment/argocd-repo-server --tail=50 | grep "Transcrypt initialization successful"
```

#### Step 6: Revoke Old Password

```bash
# Document rotation in audit log
echo "$(date -Iseconds): Transcrypt password rotated. Old password revoked." >> /var/log/security-audit.log

# Remove old password from all storage locations
# - Update password manager
# - Update disaster recovery documentation
# - Notify team members with access
```

### Automation

**Scheduled Rotation with CronJob:**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: transcrypt-password-rotation-reminder
  namespace: argocd
spec:
  schedule: "0 0 1 */3 *"  # First day of every 3 months
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: notify
            image: curlimages/curl:latest
            command:
            - sh
            - -c
            - |
              # Send notification to ops team
              curl -X POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL \
                -H 'Content-Type: application/json' \
                -d '{"text":"🔐 Reminder: Rotate transcrypt password (due every 90 days)"}'
          restartPolicy: OnFailure
```

## Audit Logging

### Enable Kubernetes Audit Logging

**Audit Policy:**

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log all Secret access in argocd namespace
  - level: RequestResponse
    namespaces: ["argocd"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["secrets"]
    omitStages:
      - RequestReceived
  
  # Log repo-server pod exec attempts
  - level: Request
    namespaces: ["argocd"]
    verbs: ["create"]
    resources:
      - group: ""
        resources: ["pods/exec"]
    omitStages:
      - RequestReceived
```

### Monitoring and Alerting

**Alert on Secret Access:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  namespace: monitoring
data:
  transcrypt-alerts.yaml: |
    groups:
    - name: transcrypt-security
      interval: 30s
      rules:
      # Alert on secret access outside of expected service accounts
      - alert: UnauthorizedTranscryptSecretAccess
        expr: |
          sum(rate(apiserver_audit_event_total{
            objectRef_namespace="argocd",
            objectRef_name="transcrypt-password",
            objectRef_resource="secrets",
            verb=~"get|list|watch"
          }[5m])) by (user_username) > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Unauthorized access to transcrypt password secret"
          description: "User {{ $labels.user_username }} accessed transcrypt-password secret"
      
      # Alert on repo-server pod exec
      - alert: RepoServerPodExec
        expr: |
          sum(rate(apiserver_audit_event_total{
            objectRef_namespace="argocd",
            objectRef_resource="pods",
            objectRef_subresource="exec",
            verb="create"
          }[5m])) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Exec into repo-server pod detected"
          description: "Someone executed commands in repo-server pod"
```

### Log Retention

**Requirements:**
- 📅 **Audit Logs**: Retain for 1+ years
- 📅 **Access Logs**: Retain for 90+ days
- 📅 **Rotation Events**: Permanent retention

**Storage:**
```bash
# Forward audit logs to SIEM
# Example: Elasticsearch, Splunk, Azure Sentinel
```

## Incident Response

### Suspected Password Compromise

**Immediate Actions:**

1. **Isolate** (within 5 minutes):
```bash
# Scale down repo-server to zero
kubectl scale deployment argocd-repo-server -n argocd --replicas=0

# Delete the secret
kubectl delete secret transcrypt-password -n argocd
```

2. **Assess** (within 30 minutes):
   - Review audit logs for unauthorized access
   - Check Git repository access logs
   - Identify scope of compromise

3. **Rotate** (within 2 hours):
   - Follow [Password Rotation](#password-rotation) procedure
   - Use new password immediately
   - Re-encrypt all affected repositories

4. **Restore** (within 4 hours):
   - Create new secret with rotated password
   - Scale repo-server back up
   - Validate functionality

5. **Post-Incident** (within 1 week):
   - Complete incident report
   - Update security procedures
   - Conduct team training

### Contact Information

**Security Incidents:**
- 🚨 Report privately via [GitHub Security Advisories](https://github.com/steled/argocd-transcrypt-plugin/security/advisories/new)

## Compliance

### Data Protection

**GDPR Considerations:**
- ✅ Encryption at rest (Article 32)
- ✅ Access controls and logging (Article 32)
- ✅ Right to erasure (transcrypt rekey/removal)
- ✅ Data breach notification procedures (Article 33)

### Standards Alignment

**ISO 27001:**
- A.9.4.1: Information access restriction
- A.10.1.1: Policy on cryptographic controls
- A.12.4.1: Event logging
- A.12.4.3: Administrator logs

**CIS Kubernetes Benchmark:**
- 5.1.5: Encryption of secret data at rest
- 5.7.2: Use of RBAC policies

## Additional Resources

- 📖 [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)
- 📖 [NSA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)
- 📖 [Transcrypt Security Model](https://github.com/elasticdog/transcrypt#security)

## Support

For security concerns:
- 🔒 **Report vulnerabilities**: privately via GitHub Security Advisories (see below)
- 🔒 **Security advisories**: [GitHub Security Advisories](https://github.com/steled/argocd-transcrypt-plugin/security/advisories)
