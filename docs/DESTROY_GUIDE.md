# Infrastructure Destruction Guide

**Last Updated:** 2026-04-27  
**Project:** scaleway-infra-lab  
**Danger Level:** ⚠️ HIGH - These operations are DESTRUCTIVE and IRREVERSIBLE

---

## ⚠️ CRITICAL WARNINGS

### Before Running Any Destroy Command

1. **BACKUP EVERYTHING**
   - Download all images from S3 bucket if needed
   - Export database if it contains important data
   - Save any configuration files or secrets

2. **UNDERSTAND WHAT WILL BE LOST**
   - `make destroy` → Destroys infrastructure, keeps bucket & registry
   - `make destroy-all` → Destroys EVERYTHING (IRREVERSIBLE!)

3. **VERIFY YOU'RE IN THE RIGHT PROJECT**
   ```bash
   scw config get project_id
   # Should show: <YOUR_PROJECT_ID>
   ```

4. **CHECK WHAT WILL BE DESTROYED**
   ```bash
   terraform -chdir=terraform plan -destroy
   ```

---

## Available Destroy Commands

### 1. `make destroy` - Standard Cleanup

**What it destroys:**
- ✅ Serverless Containers (image-converter, ai-alt-generator)
- ✅ LoadBalancer configuration (frontend, backend, routes)
- ✅ Kubernetes cluster and all node pools
- ✅ PostgreSQL database instance
- ✅ All secrets (Secret Manager + Kubernetes)
- ✅ Security Group rules (manual additions)

**What it PRESERVES:**
- 🛡️ Object Storage bucket (`onboarding-images-prod`)
- 🛡️ Container Registry namespace (`onboarding`)
- 🛡️ All images in bucket
- 🛡️ All Docker images in registry

**When to use:**
- Regular cleanup after testing
- You want to keep your data
- You plan to redeploy soon
- Cost reduction while preserving assets

**Command:**
```bash
make destroy
```

**Expected Output:**
```
🗑️  Destroying Serverless Containers...
   Deleting container: xxx-xxx-xxx
   Waiting for containers to be deleted...
✅ Serverless Containers destroyed
🗑️  Destroying manual LoadBalancer configuration...
   Found LoadBalancer: xxx-xxx-xxx
   Deleting frontend: xxx-xxx-xxx
   Deleting backend: xxx-xxx-xxx
✅ LoadBalancer configuration destroyed
🗑️  Running Terraform destroy...
...
✅ Terraform resources destroyed
🗑️  Cleaning up Security Group rules...
✅ Security Group rules cleaned

╔═══════════════════════════════════════════════════════════╗
║              ✅ Destruction Complete!                     ║
╚═══════════════════════════════════════════════════════════╝

  The following resources have been destroyed:
    ✓ Serverless Containers
    ✓ Load Balancer configuration
    ✓ Kubernetes cluster
    ✓ Database instance
    ✓ Secrets

  The following resources are PRESERVED:
    ✓ Object Storage bucket (onboarding-images-prod)
    ✓ Container Registry namespace

  Use 'make destroy-all' to delete EVERYTHING
```

**Duration:** ~15-25 minutes

---

### 2. `make destroy-all` - Complete Annihilation ☠️

**⚠️ WARNING: THIS IS IRREVERSIBLE! ⚠️**

**What it destroys:**
- ☠️ EVERYTHING from `make destroy`, PLUS:
- ☠️ Object Storage bucket and ALL objects inside
- ☠️ Container Registry namespace and ALL Docker images
- ☠️ ALL data is PERMANENTLY LOST

**When to use:**
- Complete project shutdown
- Security incident response
- Cost elimination (no resources left running)
- Starting completely fresh

**Command:**
```bash
make destroy-all
```

**Confirmation Required:**
```
Type 'destroy' to confirm:
```

**Expected Output:**
```
☠️  DESTRUCTIVE: This will delete EVERYTHING including:
    - All infrastructure
    - S3 bucket and all files
    - Container registry and all images

🗑️  Destroying Serverless Containers...
...
🗑️  Destroying Object Storage bucket...
   Emptying bucket: onboarding-images-prod
   Deleting bucket: onboarding-images-prod
🗑️  Destroying Container Registry...
   Deleting namespace...
...

╔═══════════════════════════════════════════════════════════╗
║         ☠️  Complete Destruction Achieved!                ║
╚═══════════════════════════════════════════════════════════╝

  ALL resources have been destroyed:
    ✓ Serverless Containers
    ✓ Load Balancer and all configuration
    ✓ Kubernetes cluster
    ✓ Database instance
    ✓ Secrets
    ✓ Object Storage bucket
    ✓ Container Registry

  ⚠️  WARNING: This action is IRREVERSIBLE!
```

**Duration:** ~20-30 minutes

---

## Manual Cleanup Steps

If automated destroy fails, here are manual steps:

### Step 1: Delete Serverless Containers

```bash
# List all containers
scw container container list

# Delete each container
scw container container delete <container-id>

# Wait for deletion to complete
sleep 30
scw container container list
```

### Step 2: Delete LoadBalancer Configuration

```bash
# Find LoadBalancer
LB_ID=$(scw lb lb list --tags onboarding -o json | jq -r '.[0].id')
echo "LoadBalancer ID: $LB_ID"

# List and delete frontends
scw lb frontend list lb-id=$LB_ID
scw lb frontend delete <frontend-id>

# List and delete backends
scw lb backend list lb-id=$LB_ID
scw lb backend delete <backend-id>

# Delete LoadBalancer
scw lb lb delete $LB_ID
```

### Step 3: Delete Kubernetes Cluster

```bash
# Get cluster ID
CLUSTER_ID=$(terraform -chdir=terraform output -raw kapsule_cluster_id)
echo "Cluster ID: $CLUSTER_ID"

# Delete via Terraform
terraform -chdir=terraform destroy -target=scaleway_k8s_cluster.main -auto-approve

# Or via CLI
scw k8s cluster delete $CLUSTER_ID
```

### Step 4: Delete Database

```bash
# Get database ID
DB_ID=$(terraform -chdir=terraform output -raw database_id)
echo "Database ID: $DB_ID"

# Delete via Terraform
terraform -chdir=terraform destroy -target=scaleway_rdb_instance.main -auto-approve

# Or via CLI
scw rdb instance delete $DB_ID
```

### Step 5: Delete LoadBalancer

```bash
# Get LB ID
LB_ID=$(terraform -chdir=terraform output -raw load_balancer_id)
echo "LB ID: $LB_ID"

# Delete via Terraform
terraform -chdir=terraform destroy -target=scaleway_lb.main -auto-approve

# Or via CLI
scw lb lb delete $LB_ID
```

### Step 6: Delete Security Group Rules

```bash
# Find Kapsule security group
SG_ID=$(scw instance security-group list -o json | \
        jq -r '.[] | select(.name | contains("Kapsule default")) | .id')
echo "Security Group ID: $SG_ID"

# List inbound rules
scw instance security-group list-rules security-group-id=$SG_ID direction=inbound

# Delete specific rules (by ID)
scw instance security-group delete-rule <rule-id>
```

### Step 7: Empty and Delete S3 Bucket

```bash
# Using s3cmd (install: pip install s3cmd)
ACCESS_KEY=$(grep 'access_key' terraform/terraform.tfvars | cut -d'"' -f2)
SECRET_KEY=$(grep 'secret_key' terraform/terraform.tfvars | cut -d'"' -f2)

# Empty bucket
s3cmd --access_key=$ACCESS_KEY \
      --secret_key=$SECRET_KEY \
      --host=s3.fr-par.scw.cloud \
      --host-bucket=s3.fr-par.scw.cloud \
      del --recursive s3://onboarding-images-prod/*

# Delete bucket
scw object bucket delete --name=onboarding-images-prod
```

### Step 8: Delete Container Registry

```bash
# List images
scw registry image list

# Delete all images
scw registry image list -o json | jq -r '.[].id' | \
  xargs -I {} scw registry image delete {}

# Delete namespace
REGISTRY_ID=$(scw registry namespace list -o json | \
              jq -r '.[] | select(.name == "onboarding") | .id')
scw registry namespace delete $REGISTRY_ID
```

### Step 9: Clean Terraform State

```bash
# Remove all resources from state
terraform -chdir=terraform state list | \
  xargs -I {} terraform -chdir=terraform state rm {}

# Verify state is empty
terraform -chdir=terraform state list
# Should show: (empty)
```

---

## Troubleshooting

### Issue: Container Deletion Stuck

**Symptoms:** Container stays in "deleting" state indefinitely

**Solution:**
```bash
# Force delete
scw container container delete <container-id> --force

# If still stuck, wait 10-15 minutes and retry
sleep 600
scw container container delete <container-id>
```

### Issue: Terraform Destroy Fails

**Symptoms:** `terraform destroy` errors on specific resources

**Solution:**
```bash
# Try destroying resources individually
terraform -chdir=terraform state list | tac | while read resource; do
  terraform -chdir=terraform destroy -auto-approve -target="$resource" || true
done

# Or remove from state and delete manually
terraform -chdir=terraform state rm <resource-name>
scw <resource-type> delete <resource-id>
```

### Issue: LoadBalancer Won't Delete

**Symptoms:** "LB has active frontends/backends"

**Solution:**
```bash
LB_ID=<your-lb-id>

# Delete all frontends first
scw lb frontend list lb-id=$LB_ID -o json | jq -r '.[].id' | \
  xargs -I {} scw lb frontend delete {}

# Then delete all backends
scw lb backend list lb-id=$LB_ID -o json | jq -r '.[].id' | \
  xargs -I {} scw lb backend delete {}

# Finally delete LB
scw lb lb delete $LB_ID
```

### Issue: Database Deletion Fails

**Symptoms:** "Database has backups" or "Database is not stopped"

**Solution:**
```bash
DB_ID=<your-db-id>

# Stop database first
scw rdb instance stop $DB_ID

# Wait for stop to complete
watch "scw rdb instance get $DB_ID | grep Status"

# Delete backups
scw rdb backup list database-id=$DB_ID -o json | jq -r '.[].id' | \
  xargs -I {} scw rdb backup delete {}

# Delete database
scw rdb instance delete $DB_ID
```

### Issue: Bucket Not Empty

**Symptoms:** "Bucket is not empty" error

**Solution:**
```bash
BUCKET_NAME=onboarding-images-prod

# Using AWS CLI
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 rm s3://$BUCKET_NAME --recursive

# Or using s3cmd
s3cmd --access_key=<key> --secret_key=<secret> \
      --host=s3.fr-par.scw.cloud \
      del --recursive s3://$BUCKET_NAME/*

# Then delete bucket
scw object bucket delete --name=$BUCKET_NAME
```

---

## Post-Destruction Verification

After running destroy, verify everything is cleaned up:

```bash
# Check for remaining containers
scw container container list
# Should be empty or not show your containers

# Check for remaining LoadBalancers
scw lb lb list --tags onboarding
# Should be empty

# Check for remaining K8s clusters
scw k8s cluster list
# Should not show your cluster

# Check for remaining databases
scw rdb instance list
# Should be empty

# Check for remaining buckets
scw object bucket list
# Should not show onboarding-images-prod

# Check for remaining registry namespaces
scw registry namespace list
# Should not show "onboarding"

# Verify Terraform state is empty
terraform -chdir=terraform state list
# Should show: (empty)
```

---

## Cost Impact

### Resources That Cost Money (If Not Destroyed)

| Resource | Monthly Cost | Destroy Command |
|----------|-------------|-----------------|
| Kapsule Cluster (3 nodes) | ~€45 | `make destroy` |
| LoadBalancer LB-S | ~€10 | `make destroy` |
| PostgreSQL HA | ~€30 | `make destroy` |
| Object Storage (10GB) | ~€5 | `make destroy-all` |
| Serverless Containers | €0 (scale to zero) | `make destroy` |
| Container Registry | ~€5 | `make destroy-all` |
| **Total if NOT destroyed** | **~€95/month** | |

### Cost After `make destroy`

- Object Storage: ~€5/month
- Container Registry: ~€5/month
- **Total:** ~€10/month

### Cost After `make destroy-all`

- **Total:** €0/month ✅

---

## Best Practices

### Before Destruction

1. ✅ **Backup critical data**
   ```bash
   # Download all files from S3
   aws --endpoint-url https://s3.fr-par.scw.cloud \
       s3 cp s3://onboarding-images-prod/ ./backup/ --recursive
   
   # Export database
   pg_dump "postgresql://..." > backup.sql
   ```

2. ✅ **Document current state**
   ```bash
   # Save infrastructure IDs
   terraform -chdir=terraform output > infrastructure-backup.txt
   
   # Save container configs
   scw container container list -o json > containers-backup.json
   ```

3. ✅ **Notify team members**
   - Send Slack/Email notification
   - Update project status
   - Update documentation

### During Destruction

1. ✅ **Monitor progress**
   ```bash
   # Watch deletion progress
   watch "scw container container list | wc -l"
   ```

2. ✅ **Keep terminal open**
   - Don't close terminal until complete
   - Some operations take 10-15 minutes

3. ✅ **Save logs**
   ```bash
   make destroy 2>&1 | tee destroy-$(date +%Y%m%d-%H%M%S).log
   ```

### After Destruction

1. ✅ **Verify all resources deleted** (see verification section above)

2. ✅ **Check Scaleway console**
   - Navigate to each section
   - Verify no orphaned resources

3. ✅ **Check billing**
   - Wait 24-48 hours for billing to update
   - Verify no unexpected charges

4. ✅ **Update documentation**
   - Mark project as inactive/destroyed
   - Update runbooks
   - Archive repository if needed

---

## Emergency Contacts

If you encounter issues that can't be resolved:

- **Scaleway Support:** https://console.scaleway.com/support/tickets
- **Scaleway Documentation:** https://www.scaleway.com/en/docs/
- **Terraform Scaleway Provider:** https://registry.terraform.io/providers/scaleway/scaleway/latest/docs

---

## Quick Reference Card

```bash
# Standard cleanup (keeps bucket & registry)
make destroy

# Complete annihilation (deletes EVERYTHING)
make destroy-all

# Manual verification after destroy
scw container container list
scw lb lb list
scw k8s cluster list
scw rdb instance list
scw object bucket list
scw registry namespace list
terraform -chdir=terraform state list

# Emergency manual cleanup
./scripts/emergency-cleanup.sh  # (create this script if needed)
```

---

**Remember:** Destruction is permanent. Always double-check before running destroy commands, especially `make destroy-all`.

**When in doubt:** Use `make destroy` first (safer), verify, then use `make destroy-all` if you're certain.