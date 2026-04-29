# Runbook 02: Backup & Restore Procedures

**Version:** 1.0  
**Last Updated:** 2025-01-09  
**Owner:** Platform Team  
**Review Frequency:** Quarterly  

---

## 1. Overview

This runbook describes backup and restore procedures for all data stores in the image conversion platform:

- **PostgreSQL Database** (Scaleway RDB)
- **Object Storage** (Scaleway S3-compatible)
- **Secrets** (Scaleway Secret Manager)
- **Container Registry** (Scaleway Registry)

### Backup Strategy Summary

| Component | Backup Type | Frequency | Retention | RPO | RTO |
|-----------|-------------|-----------|-----------|-----|-----|
| PostgreSQL | Continuous WAL | Real-time | 30 days | <5min | <1h |
| PostgreSQL | Full Snapshot | Daily | 30 days | 24h | <1h |
| PostgreSQL | Cross-Region | Daily | 7 days | 24h | <2h |
| S3 Bucket | Versioning + Replication | Real-time | Indefinite | <1min | <1h |
| S3 Bucket | Cross-Region Copy | Daily | 7 days | 24h | <2h |
| Secrets | Manual Export | Weekly | 4 weeks | 1 week | <30min |
| Registry | Image Retention | Indefinite | 10 latest tags | N/A | <30min |

---

## 2. PostgreSQL Database Backup

### 2.1 Automated Backups (Continuous)

Scaleway RDB provides continuous WAL (Write-Ahead Logging) backups automatically:

**Configuration:**
- **Location:** Scaleway Console → Database → onboarding-db → Backups
- **Retention:** 30 days (configurable)
- **RPO:** <5 minutes (WAL shipping)
- **RTO:** <1 hour (point-in-time recovery)

**Verify Automated Backups:**

```bash
# List available backups
scw rdb backup list \
  --database-id $(terraform output -raw database_id) \
  --region fr-par

# Check backup status
scw rdb backup get <backup-id> --region fr-par

# Verify backup schedule
scw rdb instance get onboarding-db --region fr-par
```

**Expected Output:**
```
ID         Database         Name            Status    Created At
abc123     onboarding-db    daily-backup    ready     2025-01-09 02:00:00
def456     onboarding-db    daily-backup    ready     2025-01-08 02:00:00
```

### 2.2 Manual Backup (On-Demand)

Create a manual backup before major operations:

```bash
# Create backup
scw rdb backup create \
  name=manual-backup-$(date +%Y%m%d-%H%M%S) \
  database-id=$(terraform output -raw database_id) \
  region=fr-par \
  expires-on=$(date -d "+30 days" +%Y-%m-%d)

# Wait for completion
scw rdb backup wait <backup-id> --region fr-par
```

### 2.3 Cross-Region Backup (Disaster Recovery)

**Purpose:** Protect against region-wide failures (fr-par unavailable)

**Procedure:**

```bash
# 1. Export latest backup to nl-ams region
scw rdb backup export <backup-id> \
  --bucket-name onboarding-dr-backups \
  --region fr-par

# 2. Verify export in S3 bucket
aws s3 ls s3://onboarding-dr-backups/rdb-backups/ \
  --endpoint-url https://s3.nl-ams.scw.cloud

# 3. Create backup schedule in dr.tf (Terraform)
```

**Terraform Configuration:**

```hcl
# terraform/dr.tf
resource "scaleway_rdb_backup_schedule" "cross_region" {
  instance_id   = scaleway_rdb_instance.main.id
  bucket_id     = scaleway_object_bucket.dr_backups.id
  retention_days = 7
  schedule_frequency = "daily"
  backup_hour   = 3 # 3 AM UTC
}
```

### 2.4 Database Restore Procedures

#### Scenario A: Point-in-Time Recovery

Restore to a specific point in time (within 30 days):

```bash
# 1. Stop application to prevent writes
kubectl scale deployment rest-api --replicas=0 -n onboarding

# 2. Create new instance from backup
scw rdb instance create \
  name=onboarding-db-restored \
  node-type=DB-DEV1-S \
  engine=PostgreSQL-15 \
  from-backup-id=<backup-id> \
  from-backup-time="2025-01-09T14:30:00Z" \
  --region fr-par

# 3. Wait for instance to be ready
scw rdb instance wait onboarding-db-restored --region fr-par

# 4. Update connection string in Secret Manager
scw secret secret-version create \
  secret-id=$(terraform output -raw secret_database_url_id) \
  data=$(echo -n "postgresql://user:pass@onboarding-db-restored:5432/onboarding" | base64) \
  --region fr-par

# 5. Restart application
kubectl scale deployment rest-api --replicas=2 -n onboarding

# 6. Verify data integrity
kubectl run db-check --rm -it --image=postgres:15 --env="DATABASE_URL=<new-url>" \
  -- psql -c "SELECT COUNT(*) FROM images;"
```

#### Scenario B: Full Restore from Cross-Region Backup

Restore from cross-region backup (nl-ams → fr-par):

```bash
# 1. Download backup from S3
aws s3 cp s3://onboarding-dr-backups/rdb-backups/latest.backup \
  /tmp/db-backup.dump \
  --endpoint-url https://s3.nl-ams.scw.cloud

# 2. Create new database instance
scw rdb instance create \
  name=onboarding-db-restored \
  node-type=DB-DEV1-S \
  engine=PostgreSQL-15 \
  --region fr-par

# 3. Wait for instance
scw rdb instance wait onboarding-db-restored --region fr-par

# 4. Restore from dump
PGPASSWORD=<password> psql -h <new-instance-host> -U postgres -d postgres \
  < /tmp/db-backup.dump

# 5. Update Secret Manager (as in Scenario A, step 4)
# 6. Restart application (as in Scenario A, step 5)
```

#### Scenario C: Table-Level Restore

Restore specific tables without full database restore:

```bash
# 1. Create temporary database
scw rdb database create \
  instance-id=<backup-instance-id> \
  name=temp-restore

# 2. Restore backup to temporary database
# (Use pg_restore with table filter)
PGPASSWORD=<password> pg_restore \
  -h <backup-instance-host> \
  -U postgres \
  -d temp-restore \
  --table=images \
  --table=image_alt_texts \
  /tmp/db-backup.dump

# 3. Copy specific tables to production
PGPASSWORD=<password> psql \
  -h <production-host> \
  -U postgres \
  -d onboarding \
  -c "INSERT INTO images SELECT * FROM temp-restore.images;"

# 4. Clean up temporary database
scw rdb database delete temp-restore
```

### 2.5 Backup Validation

**Weekly backup integrity test:**

```bash
#!/bin/bash
# scripts/validate-backup.sh

set -e

BACKUP_ID=$(scw rdb backup list --region fr-par -o json | jq -r '.[0].id')

echo "📦 Validating backup: $BACKUP_ID"

# Create temporary instance
TEMP_INSTANCE=$(scw rdb instance create \
  name=backup-test-$(date +%s) \
  from-backup-id=$BACKUP_ID \
  --region fr-par -o json | jq -r '.id')

echo "⏳ Waiting for instance to be ready..."
scw rdb instance wait $TEMP_INSTANCE --region fr-par

# Run validation queries
PGPASSWORD=<password> psql -h $(scw rdb instance get $TEMP_INSTANCE --region fr-par -o json | jq -r '.endpoint[0].ip') \
  -U postgres \
  -d onboarding <<EOF
SELECT 'images' as table_name, COUNT(*) as row_count FROM images
UNION ALL
SELECT 'image_alt_texts', COUNT(*) FROM image_alt_texts;
EOF

# Cleanup
scw rdb instance delete $TEMP_INSTANCE --region fr-par

echo "✅ Backup validation complete"
```

---

## 3. Object Storage (S3) Backup

### 3.1 Versioning Configuration

**Enable versioning for all buckets:**

```bash
# Enable versioning on primary bucket
aws s3api put-bucket-versioning \
  --bucket onboarding-images \
  --versioning-configuration Status=Enabled \
  --endpoint-url https://s3.fr-par.scw.cloud

# Verify versioning
aws s3api get-bucket-versioning \
  --bucket onboarding-images \
  --endpoint-url https://s3.fr-par.scw.cloud
```

**Expected Output:**
```json
{
  "Status": "Enabled"
}
```

### 3.2 Cross-Region Replication

**Setup replication from fr-par to nl-ams:**

```bash
# 1. Create IAM policy for replication
aws iam create-policy \
  --policy-name S3ReplicationPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetReplicationConfiguration", "s3:ListBucket"],
      "Resource": "arn:aws:s3:::onboarding-images"
    }, {
      "Effect": "Allow",
      "Action": ["s3:GetObjectVersion", "s3:ReplicateObject"],
      "Resource": ["arn:aws:s3:::onboarding-images/*", "arn:aws:s3:::onboarding-dr/*"]
    }]' \
  --endpoint-url https://iam.fr-par.scw.cloud

# 2. Configure replication rule
aws s3api put-bucket-replication \
  --bucket onboarding-images \
  --replication-configuration '{
    "Role": "arn:aws:iam::111111111111:role/S3ReplicationRole",
    "Rules": [{
      "ID": "CrossRegionReplication",
      "Status": "Enabled",
      "Destination": {
        "Bucket": "arn:aws:s3:::onboarding-dr",
        "StorageClass": "STANDARD"
      },
      "DeleteMarkerReplication": {"Status": "Enabled"}
    }]}' \
  --endpoint-url https://s3.fr-par.scw.cloud
```

### 3.3 S3 Backup Script

**Create automated backup script:**

```bash
#!/bin/bash
# scripts/backup-s3.sh

set -euo pipefail

# Configuration
SOURCE_BUCKET="onboarding-images"
DEST_BUCKET="onboarding-dr"
SOURCE_REGION="fr-par"
DEST_REGION="nl-ams"
LOG_FILE="/var/log/s3-backup-$(date +%Y%m%d).log"

# Logging function
log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

log "🚀 Starting S3 backup from $SOURCE_BUCKET to $DEST_BUCKET"

# Sync buckets
log "📦 Syncing objects..."
aws s3 sync s3://$SOURCE_BUCKET s3://$DEST_BUCKET \
  --endpoint-url https://s3.$SOURCE_REGION.scw.cloud \
  --source-region $SOURCE_REGION \
  --region $DEST_REGION \
  --storage-class STANDARD \
  --only-show-errors 2>&1 | tee -a "$LOG_FILE"

# Verify sync
log "🔍 Verifying sync..."
SOURCE_COUNT=$(aws s3 ls s3://$SOURCE_BUCKET --recursive \
  --endpoint-url https://s3.$SOURCE_REGION.scw.cloud | wc -l)
DEST_COUNT=$(aws s3 ls s3://$DEST_BUCKET --recursive \
  --endpoint-url https://s3.$DEST_REGION.scw.cloud | wc -l)

if [ "$SOURCE_COUNT" -eq "$DEST_COUNT" ]; then
  log "✅ Sync verified: $SOURCE_COUNT objects in both buckets"
else
  log "❌ Sync mismatch: source=$SOURCE_COUNT, dest=$DEST_COUNT"
  exit 1
fi

# Cleanup old backups (keep 7 days)
log "🗑️  Cleaning up backups older than 7 days..."
aws s3 ls s3://$DEST_BUCKET/backup-archive/ \
  --endpoint-url https://s3.$DEST_REGION.scw.cloud | \
  while read -r line; do
    date_str=$(echo "$line" | awk '{print $1, $2}')
    file_date=$(date -d "$date_str" +%s)
    now=$(date +%s)
    age_days=$(( (now - file_date) / 86400 ))
    if [ "$age_days" -gt 7 ]; then
      file_name=$(echo "$line" | awk '{print $4}')
      aws s3 rm "s3://$DEST_BUCKET/backup-archive/$file_name" \
        --endpoint-url https://s3.$DEST_REGION.scw.cloud
      log "Deleted: $file_name (age: $age_days days)"
    fi
  done

log "✅ S3 backup complete"

# Send notification (optional - integrate with Slack/PagerDuty)
# curl -X POST -H 'Content-type: application/json' \
#   --data "{\"text\":\"S3 backup completed successfully\"}" \
#   $SLACK_WEBHOOK_URL
```

**Make executable and add to cron:**

```bash
chmod +x scripts/backup-s3.sh

# Add to crontab (daily at 2 AM)
crontab -e
# Add: 0 2 * * * /path/to/scripts/backup-s3.sh
```

### 3.4 S3 Restore Procedures

#### Scenario A: Restore Deleted Objects (Versioning)

```bash
# 1. List all versions of deleted object
aws s3api list-object-versions \
  --bucket onboarding-images \
  --prefix path/to/deleted-object.jpg \
  --endpoint-url https://s3.fr-par.scw.cloud

# 2. Restore specific version
aws s3api copy-object \
  --bucket onboarding-images \
  --copy-source onboarding-images/path/to/deleted-object.jpg?versionId=VERSION_ID \
  --key path/to/deleted-object.jpg \
  --endpoint-url https://s3.fr-par.scw.cloud
```

#### Scenario B: Restore from Cross-Region Backup

```bash
# 1. List objects in DR bucket
aws s3 ls s3://onboarding-dr \
  --endpoint-url https://s3.nl-ams.scw.cloud

# 2. Sync DR bucket back to primary
aws s3 sync s3://onboarding-dr s3://onboarding-images \
  --endpoint-url https://s3.nl-ams.scw.cloud \
  --source-region nl-ams \
  --region fr-par \
  --only-show-errors

# 3. Verify restoration
aws s3 ls s3://onboarding-images \
  --endpoint-url https://s3.fr-par.scw.cloud \
  --recursive | wc -l
```

---

## 4. Secrets Backup

### 4.1 Manual Export Procedure

**Export all secrets (weekly):**

```bash
#!/bin/bash
# scripts/export-secrets.sh

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id)
SECRET_MANAGER_ID=$(terraform output -raw secret_manager_id)
EXPORT_DIR="/tmp/secrets-backup-$(date +%Y%m%d)"

mkdir -p "$EXPORT_DIR"

# List all secrets
secrets=$(scw secret secret list \
  --project-id $PROJECT_ID \
  --region fr-par \
  -o json)

echo "$secrets" | jq -r '.[].id' | while read -r secret_id; do
  secret_name=$(echo "$secrets" | jq -r --arg id "$secret_id" \
    '.[] | select(.id == $id) | .name')
  
  # Get latest version
  secret_version=$(scw secret secret-version get \
    secret-id=$secret_id \
    --region fr-par \
    -o json | jq -r '.data')
  
  # Export to file (ENCRYPTED)
  echo "$secret_version" | base64 -d | \
    gpg --encrypt --recipient backup-team@example.com \
    --output "$EXPORT_DIR/$secret_name.gpg"
  
  echo "Exported: $secret_name"
done

# Upload encrypted secrets to secure location
aws s3 cp "$EXPORT_DIR" s3://onboarding-secrets-backup/ \
  --recursive \
  --endpoint-url https://s3.fr-par.scw.cloud

echo "✅ Secrets exported to $EXPORT_DIR"
```

### 4.2 Secrets Import Procedure

```bash
# 1. Download encrypted secrets
aws s3 cp s3://onboarding-secrets-backup/20250109/ \
  /tmp/secrets-restore/ \
  --recursive \
  --endpoint-url https://s3.fr-par.scw.cloud

# 2. Decrypt and import
for file in /tmp/secrets-restore/*.gpg; do
  secret_name=$(basename "$file" .gpg)
  secret_id=$(scw secret secret get \
    name=$secret_name \
    --region fr-par \
    -o json | jq -r '.id')
  
  # Decrypt
  decrypted=$(gpg --decrypt "$file" | base64 -w 0)
  
  # Create new version
  scw secret secret-version create \
    secret-id=$secret_id \
    data="$decrypted" \
    --region fr-par
  
  echo "Imported: $secret_name"
done
```

---

## 5. Container Registry Backup

### 5.1 Image Retention Policy

**Configure retention in Terraform:**

```hcl
# terraform/registry.tf
resource "scaleway_registry_namespace" "main" {
  name       = "onboarding-registry"
  visibility = "private"
  
  # Keep 10 latest tags per image
  cleanup_policy {
    action          = "keep"
    tag_pattern     = "*"
    max_tag_count   = 10
    older_than_days = 30
  }
}
```

### 5.2 Manual Image Export

```bash
# Pull all images
docker pull rg.fr-par.scw.cloud/onboarding-registry/rest-api:latest
docker pull rg.fr-par.scw.cloud/onboarding-registry/image-converter:latest
docker pull rg.fr-par.scw.cloud/onboarding-registry/ai-alt-generator:latest

# Save to tar files
docker save rg.fr-par.scw.cloud/onboarding-registry/rest-api:latest \
  > /backup/rest-api-latest.tar
docker save rg.fr-par.scw.cloud/onboarding-registry/image-converter:latest \
  > /backup/image-converter-latest.tar
docker save rg.fr-par.scw.cloud/onboarding-registry/ai-alt-generator:latest \
  > /backup/ai-alt-generator-latest.tar

# Upload to S3 backup
aws s3 cp /backup/*.tar s3://onboarding-registry-backup/ \
  --endpoint-url https://s3.fr-par.scw.cloud
```

---

## 6. Backup Monitoring

### 6.1 Prometheus Alerts

```yaml
# k8s/alerting.yaml - Backup monitoring rules
groups:
  - name: backup-alerts
    rules:
      - alert: DatabaseBackupMissing
        expr: |
          absent(scaleway_rdb_backup_age_seconds{instance="onboarding-db"})
          or
          scaleway_rdb_backup_age_seconds{instance="onboarding-db"} > 86400
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Database backup is older than 24 hours"
          description: "Last backup was {{ $value | humanizeDuration }} ago"

      - alert: S3ReplicationLag
        expr: s3_replication_lag_seconds{bucket="onboarding-images"} > 3600
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "S3 replication lag exceeds 1 hour"
          description: "Replication lag is {{ $value | humanizeDuration }}"

      - alert: BackupJobFailed
        expr: backup_job_status{status="failed"} == 1
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Backup job failed"
          description: "Backup job {{ $labels.job }} failed at {{ $value }}"
```

### 6.2 Backup Dashboard (Grafana)

**Import dashboard ID: 12345** (custom backup dashboard)

**Panels:**
- Database backup age (hours)
- S3 replication lag (seconds)
- Backup job success rate (%)
- Backup storage usage (GB)
- Restore test success rate (%)

---

## 7. Disaster Recovery Drill

### 7.1 Quarterly DR Test

**Schedule:** Last Saturday of each quarter

**Scenario:** Complete fr-par region failure

**Procedure:**

```bash
# 1. Simulate failure
kubectl config delete-context fr-par-production

# 2. Activate DR region
kubectl config use-context nl-ams-dr

# 3. Verify database connectivity
kubectl exec -it rest-api-pod -- curl -s http://database:5432

# 4. Verify S3 bucket access
aws s3 ls s3://onboarding-dr \
  --endpoint-url https://s3.nl-ams.scw.cloud

# 5. Test full workflow
curl -F "file=@test.png" https://dr-api.image-converter.example.com/upload

# 6. Measure RTO
time_from_failure=$(kubectl get events --sort-by=.lastTimestamp | tail -1)
echo "RTO: $(($(date +%s) - $(date -d "$time_from_failure" +%s))) seconds"

# 7. Restore primary region
kubectl config use-context fr-par-production
```

### 7.2 DR Test Report Template

```markdown
## DR Drill Report - Q1 2025

**Date:** 2025-03-29  
**Duration:** 2 hours  
**Participants:** Platform Team, On-Call

### Results

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| RTO | <1h | 45min | ✅ PASS |
| RPO | <5min | 2min | ✅ PASS |
| Data Integrity | 100% | 100% | ✅ PASS |
| Service Availability | >99% | 99.8% | ✅ PASS |

### Issues Found

1. [Issue description]
   - Severity: Low/Medium/High
   - Remediation: [Action]
   - Owner: [Name]
   - Due: [Date]

### Lessons Learned

[Summary of improvements]

### Next Drill Date

2025-06-28
```

---

## 8. Troubleshooting

### 8.1 Common Issues

#### Issue: Backup job fails with "disk full"

**Symptoms:**
```
Error: could not write backup file: no space left on device
```

**Resolution:**
```bash
# Check backup storage usage
scw rdb instance get onboarding-db --region fr-par

# Increase backup storage
scw rdb instance update onboarding-db \
  --backup-volume-size 50GB \
  --region fr-par
```

#### Issue: S3 replication not working

**Symptoms:**
```
aws s3 sync shows no objects transferred
```

**Resolution:**
```bash
# Check replication configuration
aws s3api get-bucket-replication \
  --bucket onboarding-images \
  --endpoint-url https://s3.fr-par.scw.cloud

# Verify IAM role permissions
aws iam get-policy \
  --policy-arn arn:aws:iam::111111111111:policy/S3ReplicationPolicy

# Check destination bucket permissions
aws s3api get-bucket-policy \
  --bucket onboarding-dr \
  --endpoint-url https://s3.nl-ams.scw.cloud
```

#### Issue: Database restore fails

**Symptoms:**
```
FATAL: database "onboarding" does not exist
```

**Resolution:**
```bash
# Create database manually
PGPASSWORD=<password> psql -h <instance-host> -U postgres -c \
  "CREATE DATABASE onboarding;"

# Restore again
pg_restore -h <instance-host> -U postgres -d onboarding backup.dump
```

---

## 9. Contacts & Escalation

| Issue Type | Contact | Escalation Path |
|------------|---------|-----------------|
| Backup Job Failed | Platform Team | #incidents-general |
| Database Corruption | DBA On-Call | #incidents-critical |
| S3 Data Loss | Platform Lead | #incidents-critical |
| DR Activation Required | CTO | Executive Team |

---

## 10. Appendix

### A. Backup Schedule Summary

| Time (UTC) | Job | Retention | Location |
|------------|-----|-----------|----------|
| 02:00 Daily | PostgreSQL full backup | 30 days | fr-par |
| 03:00 Daily | PostgreSQL cross-region | 7 days | nl-ams |
| 02:00 Daily | S3 cross-region sync | 7 days | nl-ams |
| Weekly Sunday | Secrets export | 4 weeks | Encrypted S3 |
| Monthly 1st | Full DR drill | N/A | Test report |

### B. Backup Cost Estimate

| Component | Monthly Cost |
|-----------|--------------|
| PostgreSQL backups (30 days) | €15 |
| S3 fr-par (100 GB) | €5 |
| S3 nl-ams DR (100 GB) | €5 |
| Secrets storage | €1 |
| **Total** | **€26/month** |

### C. Related Documentation

- [DISASTER_RECOVERY.md](../../DISASTER_RECOVERY.md)
- [Runbook 01: Incident Response](01-incident-response.md)
- [Runbook 03: Scaling Procedures](03-scaling-procedures.md)

---

**End of Runbook 02**