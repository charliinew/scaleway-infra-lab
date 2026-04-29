# Quick Start Guide — imgflow

Deploy a production-ready image converter on Scaleway in 20 minutes.

---

## Prerequisites

- [Scaleway CLI](https://www.scaleway.com/en/docs/develop-and-test/install-tools/) (`scw`)
- [Terraform](https://developer.hashicorp.com/terraform/downloads)
- [Docker](https://docs.docker.com/get-docker/) with buildx
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

---

## Step 1: Initialize (One-Time)

```bash
# Authenticate with Scaleway
scw init

# Initialize Terraform providers
make init
```

---

## Step 2: Configure Credentials

```bash
# Copy the template
cp dot.env terraform/terraform.tfvars

# Edit with your Scaleway credentials
# Required: access_key, secret_key, project_id
nano terraform/terraform.tfvars
```

**Example `terraform/terraform.tfvars`:**
```hcl
access_key          = "SCWXXXXXXXXXXXXXXXXX"
secret_key          = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
project_id          = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
registry_namespace  = "onboarding"
```

---

## Step 3: Deploy Everything

```bash
# This single command deploys:
# - Kubernetes cluster (Kapsule)
# - Serverless Containers
# - PostgreSQL database
# - Object Storage (S3)
# - Load Balancer
# - All application containers
make deploy
```

**What happens:**
1. ⏳ Provisions infrastructure (10-15 min)
2. 🔨 Builds Docker images (3-5 min)
3. 📦 Deploys to Kubernetes (2-3 min)
4. ✅ Runs health checks

**Total time:** ~20 minutes

---

## Step 4: Test

```bash
# Get Load Balancer IP
LB_IP=$(terraform -chdir=terraform output -raw load_balancer_ip)

# Health check
curl http://$LB_IP/health

# Upload an image
curl -F "file=@logo.png" \
     -F "format=webp" \
     -F "quality=80" \
     -F "generate_alt=true" \
     http://$LB_IP/upload
```

**Example response:**
```json
{
  "id": "77a55aeb-...",
  "url": "https://bucket.s3.fr-par.scw.cloud/77a55aeb-.webp",
  "alt_text": "A professional logo with blue and white colors",
  "formats": {
    "jpeg": "...",
    "webp": "...",
    "avif": "..."
  }
}
```

---

## After Code Changes

Modified your code? Redeploy in 2-3 minutes:

```bash
make redeploy
```

---

## View Logs

Stream logs in real-time:

```bash
make logs
```

Or with kubectl:
```bash
kubectl logs -l app=rest-api -n onboarding --tail=100 -f
```

---

## Clean Up

When you're done:

```bash
# Destroy infrastructure (keeps bucket and registry)
make destroy

# OR destroy everything (DESTRUCTIVE)
make destroy-all
```

---

## Commands Reference

| Command | Description | Time |
|---------|-------------|------|
| `make init` | Initialize Terraform | 30s |
| `make deploy` | Deploy everything | 20 min |
| `make redeploy` | Rebuild and redeploy | 3 min |
| `make test` | Quick health check | 5s |
| `make logs` | View live logs | - |
| `make destroy` | Remove infrastructure | 10 min |

---

## Troubleshooting

### Authentication fails
```bash
scw init
scw account get
```

### Deployment timeout
```bash
# Check cluster status
scw k8s cluster list

# Check pods
kubectl get pods -n onboarding

# View events
kubectl get events -n onboarding --sort-by='.lastTimestamp'
```

### Health check fails
Wait 2-3 minutes after deploy for pods to start, then:
```bash
make logs
kubectl describe deployment rest-api -n onboarding
```

---

## Next Steps

- **Monitor:** Access Grafana at `http://<LB_IP>:3000`
- **Scale:** `kubectl scale deployment rest-api --replicas=5 -n onboarding`
- **Backup:** `./scripts/backup-s3.sh --verify`
- **Rotate secrets:** `./scripts/rotate-secrets.sh`

---

## Need Help?

- **Documentation:** See [README.md](README.md)
- **Runbooks:** [docs/runbooks/](docs/runbooks/)
- **API Docs:** [docs/api/openapi.yaml](docs/api/openapi.yaml)
- **Issues:** GitHub Issues

---

**Happy deploying! 🚀**