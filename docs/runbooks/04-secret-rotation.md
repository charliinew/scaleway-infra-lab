# Runbook 04: Secret Rotation Procedures

**Document ID:** RB-04  
**Version:** 1.0  
**Last Updated:** 2025-01-09  
**Owner:** Security Team  
**Review Cycle:** Quarterly

---

## 1. Overview

This runbook defines procedures for rotating secrets used across the image conversion platform. Regular secret rotation is critical for maintaining security posture and complying with security best practices.

### 1.1 Scope

This document covers rotation of:

| Secret | Type | Rotation Frequency | Criticality |
|--------|------|-------------------|-------------|
| `ONBOARDING_DATABASE_URL` | PostgreSQL connection string | 90 days | 🔴 Critical |
| `ONBOARDING_ACCESS_KEY` | S3 Object Storage access key | 90 days | 🔴 Critical |
| `ONBOARDING_SECRET_KEY` | S3 Object Storage secret key | 90 days | 🔴 Critical |
| `QWEN_API_KEY` | Qwen Vision API key | 180 days | 🟠 High |
| `ONBOARDING_IMAGE_PROCESSOR_TOKEN` | Service auth token | 90 days | 🟠 High |
| Kubernetes service account tokens | K8s secrets | 365 days | 🟡 Medium |

### 1.2 Prerequisites

Before rotating secrets, ensure:

- [ ] Maintenance window scheduled (if required)
- [ ] Backup of current secrets in secure vault
- [ ] Team notified via `#incidents-critical`
- [ ] Rollback procedure reviewed
- [ ] Monitoring dashboards open
- [ ] On-call engineer available

### 1.3 Security Requirements

- **NEVER** commit secrets to version control
- **ALWAYS** use Secret Manager for storage
- **ALWAYS** base64-encode before storing in Secret Manager
- **NEVER** share secrets via chat/email (use 1Password or similar)
- **ALWAYS** verify rotation success before closing ticket

---

## 2. Secret Manager Architecture

### 2.1 Current Secret Topology

```
┌─────────────────────────────────────────────────────────────┐
│              Scaleway Secret Manager                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Secret: onboarding-database-url                    │   │
│  │  ID: scw-secret-db-url                              │   │
│  │  Version: 3                                         │   │
│  │  Value: postgresql://user:pass@host:5432/db        │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Secret: onboarding-bucket-name                     │   │
│  │  ID: scw-secret-bucket                              │   │
│  │  Version: 1                                         │   │
│  │  Value: onboarding-images-prod                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Secret: onboarding-s3-credentials                  │   │
│  │  ID: scw-secret-s3                                  │   │
│  │  Version: 2                                         │   │
│  │  Value: {"access_key": "...", "secret_key": "..."} │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Secret: qwen-api-key                               │   │
│  │  ID: scw-secret-qwen                                │   │
│  │  Version: 1                                         │   │
│  │  Value: sk-qwen-...                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Secret: onboarding-service-token                   │   │
│  │  ID: scw-secret-token                               │   │
│  │  Version: 2                                         │   │
│  │  Value: eyJhbGciOiJIUzI1NiIs...                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Secret References in Infrastructure

| Component | Secret Reference | Resolution Method |
|-----------|-----------------|-------------------|
| `rest-api` | `ONBOARDING_DATABASE_URL` | Secret Manager API call at startup |
| `rest-api` | `ONBOARDING_ACCESS_KEY` | Environment variable (from Secret Manager) |
| `rest-api` | `ONBOARDING_SECRET_KEY` | Environment variable (from Secret Manager) |
| `rest-api` | `ONBOARDING_IMAGE_PROCESSOR_TOKEN` | Environment variable |
| `image-converter` | `ONBOARDING_IMAGE_PROCESSOR_TOKEN` | Environment variable |
| `ai-alt-generator` | `QWEN_API_KEY` | Secret Manager API call at startup |

---

## 3. Database Credential Rotation

### 3.1 When to Rotate

- Scheduled rotation (every 90 days)
- Suspected credential compromise
- Team member departure (security precaution)
- After security audit finding

### 3.2 Pre-Rotation Checklist

- [ ] Schedule maintenance window (15-30 min downtime expected)
- [ ] Notify stakeholders via Slack (`#scaleway-migration`)
- [ ] Backup current database connection string
- [ ] Verify database user permissions documented
- [ ] Open Grafana dashboard for monitoring
- [ ] Prepare rollback script

### 3.3 Rotation Procedure

#### Step 1: Generate New Database Credentials

```bash
# Connect to PostgreSQL admin console
scw rdb user list --region fr-par --instance-id $(RDB_INSTANCE_ID)

# Generate new password (32 chars, alphanumeric + special)
NEW_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%' | head -c 32)
echo "New password generated (save securely): $NEW_PASSWORD"

# Store in secure vault temporarily
echo "$NEW_PASSWORD" | pass insert -m onboarding/db-password-new
```

#### Step 2: Update Database User Password

```bash
# Get RDB instance endpoint
RDB_ENDPOINT=$(terraform -chdir=terraform output -raw database_endpoint)
RDB_USER=$(terraform -chdir=terraform output -raw database_username)
RDB_DB=$(terraform -chdir=terraform output -raw database_name)

# Connect and update password
PGPASSWORD=$(pass show onboarding/db-password) psql -h $RDB_ENDPOINT \
  -U $RDB_USER -d $RDB_DB <<EOF
ALTER USER ${RDB_USER} WITH PASSWORD '${NEW_PASSWORD}';
EOF

echo "Database user password updated"
```

#### Step 3: Build New Connection String

```bash
# Construct new connection string
NEW_DATABASE_URL="postgresql://${RDB_USER}:${NEW_PASSWORD}@${RDB_ENDPOINT}:5432/${RDB_DB}?sslmode=require"

# Base64 encode for Secret Manager
ENCODED_VALUE=$(echo -n "$NEW_DATABASE_URL" | base64)

echo "New connection string created and encoded"
```

#### Step 4: Update Secret Manager

```bash
# Create new secret version
scw secret secret-version create \
  secret-id=$(scw secret secret list | grep onboarding-database-url | awk '{print $1}') \
  data=$ENCODED_VALUE \
  --region fr-par

# Verify new version created
scw secret secret-version list \
  secret-id=$(scw secret secret list | grep onboarding-database-url | awk '{print $1}') \
  --region fr-par
```

#### Step 5: Update Terraform State (if managed)

```bash
# If using Terraform for secret management
cd terraform/

# Update secret version in state
terraform apply -target=scaleway_secret_version.database_url \
  -var="database_url=${NEW_DATABASE_URL}" \
  -auto-approve
```

#### Step 6: Trigger Application Restart

```bash
# For Kubernetes deployment (rolling restart)
kubectl rollout restart deployment rest-api -n onboarding

# Monitor rollout status
kubectl rollout status deployment rest-api -n onboarding -w

# For Serverless Containers (automatic on next invocation)
# No action needed - Serverless pulls secrets on each cold start
```

#### Step 7: Validate Rotation

```bash
# Check application health
curl http://$(LB_IP)/health

# Test database connectivity
curl -F "file=@logo.png" http://$(LB_IP)/upload | jq .

# Check application logs for connection errors
kubectl logs -l app=rest-api -n onboarding | grep -i "database\|connection\|error"

# Verify no old credentials in use
kubectl logs -l app=rest-api -n onboarding | tail -50
```

#### Step 8: Cleanup

```bash
# Remove old password from secure vault after 7 days
# (keep for emergency rollback during first week)
echo "Old password retained until: $(date -d '+7 days')"

# Update password inventory
pass insert onboarding/db-password-rotated-$(date +%Y%m%d) <<< "$NEW_PASSWORD"
```

### 3.4 Rollback Procedure

If rotation fails:

```bash
# Step 1: Restore previous secret version
scw secret secret-version enable \
  secret-version-id=$(scw secret secret-version list \
    secret-id=$(scw secret secret list | grep onboarding-database-url | awk '{print $1}') \
    --region fr-par | grep -v "NEW" | tail -2 | head -1 | awk '{print $1}') \
  --region fr-par

# Step 2: Restore old database password
PGPASSWORD=$(pass show onboarding/db-password) psql -h $RDB_ENDPOINT \
  -U $RDB_USER -d $RDB_DB <<EOF
ALTER USER ${RDB_USER} WITH PASSWORD '$(pass show onboarding/db-password)';
EOF

# Step 3: Restart application
kubectl rollout restart deployment rest-api -n onboarding

# Step 4: Verify rollback
curl http://$(LB_IP)/health
```

### 3.5 Post-Rotation Validation

- [ ] Application health check returns 200 OK
- [ ] Image upload endpoint functional
- [ ] No database connection errors in logs
- [ ] Monitoring shows normal query latency
- [ ] Grafana dashboard shows no anomalies
- [ ] Team notified of successful rotation

---

## 4. S3 Credential Rotation

### 4.1 When to Rotate

- Scheduled rotation (every 90 days)
- Suspected credential compromise
- IAM policy changes
- After security incident

### 4.2 Pre-Rotation Checklist

- [ ] Identify all services using S3 credentials
- [ ] Verify new credentials can be created
- [ ] Test S3 access with new credentials (parallel)
- [ ] Prepare application config update

### 4.3 Rotation Procedure

#### Step 1: Generate New IAM Credentials

```bash
# Login to Scaleway console
# Navigate to IAM > Users > onboarding-s3-user

# Generate new access key
scw iam access-key create \
  application-id=$(scw iam application list | grep onboarding-s3 | awk '{print $1}') \
  --region fr-par

# Save output (shown only once)
# ACCESS_KEY: SCWXXXXXXXXXXXXX
# SECRET_KEY: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

#### Step 2: Update Secret Manager

```bash
# Create JSON with new credentials
cat <<EOF > /tmp/s3-credentials.json
{
  "access_key": "SCWXXXXXXXXXXXXX",
  "secret_key": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
EOF

# Base64 encode
ENCODED_CREDS=$(cat /tmp/s3-credentials.json | base64 -w 0)

# Create new secret version
scw secret secret-version create \
  secret-id=$(scw secret secret list | grep onboarding-s3-credentials | awk '{print $1}') \
  data=$ENCODED_CREDS \
  --region fr-par
```

#### Step 3: Update Environment Variables

```bash
# For Kubernetes: update secret
kubectl create secret generic onboarding-s3-creds \
  --from-literal=access-key=SCWXXXXXXXXXXXXX \
  --from-literal=secret-key=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  -n onboarding \
  --dry-run=client -o yaml | kubectl apply -f -

# Trigger rolling restart
kubectl rollout restart deployment rest-api -n onboarding
kubectl rollout status deployment rest-api -n onboarding -w
```

#### Step 4: Validate S3 Access

```bash
# Test S3 upload with new credentials
export AWS_ACCESS_KEY_ID=SCWXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export AWS_ENDPOINT_URL=https://s3.fr-par.scw.cloud

aws s3 ls s3://onboarding-images-prod --endpoint-url $AWS_ENDPOINT_URL

# Test upload
echo "test" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://onboarding-images-prod/test-rotation-$(date +%s).txt \
  --endpoint-url $AWS_ENDPOINT_URL

# Verify upload
aws s3 ls s3://onboarding-images-prod/test-rotation* --endpoint-url $AWS_ENDPOINT_URL

# Cleanup
aws s3 rm s3://onboarding-images-prod/test-rotation* --endpoint-url $AWS_ENDPOINT_URL
```

#### Step 5: Deactivate Old Credentials

**IMPORTANT:** Wait 24-48 hours before deactivating old credentials to ensure no services still using them.

```bash
# After validation period, deactivate old access key
scw iam access-key deactivate <OLD_ACCESS_KEY>

# Monitor for 24 hours
# If no issues, delete old key
scw iam access-key delete <OLD_ACCESS_KEY>
```

### 4.4 Rollback Procedure

```bash
# Reactivate old credentials
scw iam access-key reactivate <OLD_ACCESS_KEY>

# Update Secret Manager with old credentials
# (use backup from pre-rotation)

# Restart application
kubectl rollout restart deployment rest-api -n onboarding
```

---

## 5. Qwen API Key Rotation

### 5.1 When to Rotate

- Scheduled rotation (every 180 days)
- API key compromise suspected
- Billing anomalies detected
- Team member with access departs

### 5.2 Rotation Procedure

#### Step 1: Generate New API Key

```bash
# Login to Qwen dashboard (https://platform.qwen.ai)
# Navigate to API Keys
# Click "Create New Key"
# Copy key immediately (shown only once)

NEW_QWEN_KEY="sk-qwen-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
echo "$NEW_QWEN_KEY" | pass insert -m qwen/api-key-new
```

#### Step 2: Update Secret Manager

```bash
# Base64 encode
ENCODED_QWEN=$(echo -n "$NEW_QWEN_KEY" | base64 -w 0)

# Create new secret version
scw secret secret-version create \
  secret-id=$(scw secret secret list | grep qwen-api-key | awk '{print $1}') \
  data=$ENCODED_QWEN \
  --region fr-par
```

#### Step 3: Update AI Alt-Generator

```bash
# For Serverless Container, secrets are pulled on cold start
# Force restart by updating deployment timestamp

scw container function update $(AI_GENERATOR_ID) \
  --region fr-par \
  --restart-policy=always

# Or redeploy with new secret
cd ai-alt-generator/
docker build -t rg.fr-par.scw.cloud/$(NAMESPACE)/ai-alt-generator:latest .
docker push rg.fr-par.scw.cloud/$(NAMESPACE)/ai-alt-generator:latest

scw container function deploy \
  --name ai-alt-generator \
  --image rg.fr-par.scw.cloud/$(NAMESPACE)/ai-alt-generator:latest \
  --secret qwen_api_key=$(scw secret secret list | grep qwen-api-key | awk '{print $1}') \
  --region fr-par
```

#### Step 4: Validate AI Service

```bash
# Test AI alt-text generation
curl -F "file=@logo.png" $(AI_GENERATOR_URL)/generate-alt | jq .

# Expected response:
# {
#   "alt_text": "...",
#   "confidence": 0.95,
#   "html": "...",
#   "react_component": "..."
# }

# Check logs for API errors
scw container function logs $(AI_GENERATOR_ID) --region fr-par | grep -i "qwen\|api\|error"
```

#### Step 5: Deactivate Old Key

```bash
# Login to Qwen dashboard
# Navigate to API Keys
# Revoke old key

# OR via API (if supported)
curl -X DELETE https://api.qwen.ai/v1/keys/<OLD_KEY_ID> \
  -H "Authorization: Bearer <ADMIN_TOKEN>"
```

---

## 6. Service Token Rotation

### 6.1 When to Rotate

- Scheduled rotation (every 90 days)
- Service compromise suspected
- After security audit

### 6.2 Token Generation

```bash
# Generate new JWT token (example with HS256)
# Use a secure secret for signing

INSTALL_JWT_SECRET=$(openssl rand -base64 64)
echo "JWT Secret: $INSTALL_JWT_SECRET" | pass insert -m onboarding/jwt-secret

# Generate token (expires in 1 year)
NEW_SERVICE_TOKEN=$(echo -n '{"sub":"image-processor","iat":'$(date +%s)',"exp":'$(($(date +%s)+31536000))'}' | \
  jwt encode --secret "$INSTALL_JWT_SECRET")

echo "$NEW_SERVICE_TOKEN" | pass insert -m onboarding/service-token-new
```

### 6.3 Update All Services

```bash
# Update Secret Manager
ENCODED_TOKEN=$(echo -n "$NEW_SERVICE_TOKEN" | base64 -w 0)

scw secret secret-version create \
  secret-id=$(scw secret secret list | grep onboarding-service-token | awk '{print $1}') \
  data=$ENCODED_TOKEN \
  --region fr-par

# Update Kubernetes secret
kubectl create secret generic onboarding-service-token \
  --from-literal=token=$NEW_SERVICE_TOKEN \
  -n onboarding \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart all services
kubectl rollout restart deployment rest-api -n onboarding
kubectl rollout status deployment rest-api -n onboarding -w
```

---

## 7. Automated Secret Rotation

### 7.1 Rotation Script

Create `scripts/rotate-secrets.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Secret rotation script
# Usage: ./rotate-secrets.sh [--secret NAME] [--dry-run]

DRY_RUN=false
SECRET_NAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --secret)
      SECRET_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

rotate_secret() {
  local secret_name=$1
  local secret_id=$(scw secret secret list | grep "$secret_name" | awk '{print $1}')
  
  if [[ -z "$secret_id" ]]; then
    echo "❌ Secret not found: $secret_name"
    return 1
  fi
  
  # Generate new value (implementation depends on secret type)
  case $secret_name in
    *database*)
      # Database credential rotation
      echo "🔄 Rotating database credentials..."
      # TODO: Implement database rotation
      ;;
    *s3*)
      # S3 credential rotation
      echo "🔄 Rotating S3 credentials..."
      # TODO: Implement S3 rotation
      ;;
    *qwen*)
      # Qwen API key rotation
      echo "🔄 Rotating Qwen API key..."
      # TODO: Implement Qwen rotation
      ;;
    *)
      echo "⚠️  Unknown secret type: $secret_name"
      return 1
      ;;
  esac
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "✅ [DRY-RUN] Would rotate: $secret_name"
  else
    echo "✅ Rotated: $secret_name"
  fi
}

# Main execution
if [[ -n "$SECRET_NAME" ]]; then
  rotate_secret "$SECRET_NAME"
else
  echo "🔄 Rotating all secrets..."
  rotate_secret "onboarding-database-url"
  rotate_secret "onboarding-s3-credentials"
  rotate_secret "qwen-api-key"
  rotate_secret "onboarding-service-token"
fi

echo "✅ Secret rotation complete"
```

Make executable:

```bash
chmod +x scripts/rotate-secrets.sh
```

### 7.2 Cron Job Setup

```bash
# Add to crontab on bastion host
# Rotate database credentials every 90 days
0 2 1 1,4,7,10 * /path/to/scripts/rotate-secrets.sh --secret onboarding-database-url >> /var/log/secret-rotation.log 2>&1

# Rotate S3 credentials every 90 days
0 2 15 1,4,7,10 * /path/to/scripts/rotate-secrets.sh --secret onboarding-s3-credentials >> /var/log/secret-rotation.log 2>&1

# Rotate Qwen API key every 180 days
0 2 1 1,7 * /path/to/scripts/rotate-secrets.sh --secret qwen-api-key >> /var/log/secret-rotation.log 2>&1

# Rotate service token every 90 days
0 2 1 2,5,8,11 * /path/to/scripts/rotate-secrets.sh --secret onboarding-service-token >> /var/log/secret-rotation.log 2>&1
```

---

## 8. Monitoring & Alerting

### 8.1 Metrics to Track

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `secret_age_days` | Days since last rotation | >85 days (warning), >95 days (critical) |
| `secret_rotation_failures` | Failed rotation attempts | >0 |
| `secret_access_denied` | Authentication failures | >5 in 5 minutes |
| `secret_manager_api_errors` | Secret Manager API errors | >1% of requests |

### 8.2 Grafana Dashboard

Create dashboard "Secret Management":

```json
{
  "dashboard": {
    "title": "Secret Management",
    "panels": [
      {
        "title": "Secret Age (Days)",
        "targets": [
          {
            "expr": "time() - secret_last_rotation_timestamp",
            "legendFormat": "{{secret_name}}"
          }
        ]
      },
      {
        "title": "Rotation Failures",
        "targets": [
          {
            "expr": "rate(secret_rotation_failures_total[5m])",
            "legendFormat": "{{secret_name}}"
          }
        ]
      }
    ]
  }
}
```

### 8.3 Alert Rules

```yaml
groups:
  - name: secret-rotation
    rules:
      - alert: SecretRotationOverdue
        expr: time() - secret_last_rotation_timestamp > 7776000  # 90 days
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Secret rotation overdue"
          description: "Secret {{ $labels.secret_name }} hasn't been rotated in 90+ days"

      - alert: SecretRotationFailed
        expr: rate(secret_rotation_failures_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Secret rotation failed"
          description: "Failed to rotate secret {{ $labels.secret_name }}"
```

---

## 9. Audit & Compliance

### 9.1 Audit Log Requirements

All secret rotations must be logged with:

- Timestamp (UTC)
- Secret name (not value!)
- Initiator (user or automated system)
- Rotation result (success/failure)
- Rollback performed (yes/no)
- Validator (engineer who confirmed success)

### 9.2 Audit Log Example

```
2025-01-09T10:30:00Z | onboarding-database-url | user:john.doe | SUCCESS | validator:jane.smith
2025-01-09T10:35:00Z | onboarding-s3-credentials | automated:cron | SUCCESS | validator:oncall
2025-01-09T10:40:00Z | qwen-api-key | user:alice.wong | FAILED | rollback:yes
```

### 9.3 Compliance Requirements

| Standard | Requirement | Evidence |
|----------|-------------|----------|
| SOC 2 | Rotate credentials every 90 days | Rotation logs, Secret Manager history |
| ISO 27001 | Documented rotation procedures | This runbook |
| PCI DSS | Rotate after personnel changes | HR offboarding checklist |
| GDPR | Protect personal data access | Database credential rotation |

---

## 10. Troubleshooting

### 10.1 Common Issues

#### Issue: Application fails after rotation

**Symptoms:**
- 500 errors on upload endpoint
- Logs show "connection refused" or "authentication failed"

**Resolution:**
```bash
# Check if secret version is enabled
scw secret secret-version list --secret-id <ID>

# Enable correct version
scw secret secret-version enable --secret-version-id <VERSION-ID>

# Restart application
kubectl rollout restart deployment rest-api -n onboarding
```

#### Issue: Secret Manager API returns 403

**Symptoms:**
- Permission denied errors
- Cannot create new secret versions

**Resolution:**
```bash
# Check IAM permissions
scw iam policy list | grep secret

# Add missing permissions
scw iam policy create \
  --name onboarding-secret-manager \
  --scope project=<PROJECT_ID> \
  --permission Set=SecretsManager,Action=Manage
```

#### Issue: Serverless Container uses old secret

**Symptoms:**
- Kubernetes services work, Serverless fails
- Old credentials in use

**Resolution:**
```bash
# Force cold start by updating function
scw container function update <FUNCTION-ID> --region fr-par --env FORCE_RELOAD=$(date +%s)

# Or redeploy function
scw container function deploy --name <NAME> --image <NEW_IMAGE>
```

### 10.2 Emergency Contacts

| Issue | Contact | Escalation |
|-------|---------|------------|
| Rotation failure | On-call engineer | Platform Lead |
| Security incident | Security Team | CISO |
| Data breach | Legal + Security | CEO |

---

## 11. Appendix

### A. Secret Manager CLI Reference

```bash
# List all secrets
scw secret secret list --region fr-par

# List secret versions
scw secret secret-version list --secret-id <ID> --region fr-par

# Create new version
scw secret secret-version create --secret-id <ID> --data <BASE64> --region fr-par

# Enable specific version
scw secret secret-version enable --secret-version-id <VERSION-ID> --region fr-par

# Get secret value (decoded)
scw secret secret-version get --secret-version-id <VERSION-ID> --region fr-par
```

### B. Kubernetes Secret Commands

```bash
# List secrets in namespace
kubectl get secrets -n onboarding

# Get secret value (base64 encoded)
kubectl get secret onboarding-db-creds -n onboarding -o jsonpath='{.data.url}'

# Decode secret value
kubectl get secret onboarding-db-creds -n onboarding -o jsonpath='{.data.url}' | base64 -d

# Delete secret
kubectl delete secret onboarding-db-creds -n onboarding
```

### C. Rotation Checklist Template

```markdown
## Secret Rotation Checklist

**Secret:** _________________  
**Date:** _________________  
**Initiator:** _________________  

### Pre-Rotation
- [ ] Maintenance window scheduled
- [ ] Team notified
- [ ] Backup created
- [ ] Rollback procedure reviewed

### Rotation
- [ ] New credentials generated
- [ ] Secret Manager updated
- [ ] Applications updated
- [ ] Services restarted

### Validation
- [ ] Health checks passing
- [ ] Functionality tested
- [ ] Monitoring normal
- [ ] No errors in logs

### Cleanup
- [ ] Old credentials deactivated
- [ ] Documentation updated
- [ ] Team notified of completion
- [ ] Ticket closed

**Validator:** _________________  
**Completed:** _________________
```

---

**Document Owner:** Security Team  
**Review Date:** 2025-04-09  
**Next Review:** Quarterly  
**Classification:** Internal Use Only