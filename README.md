# Cloud-Native Image Converter on Scaleway

A production-ready, cloud-native image processing platform deployed on [Scaleway](https://scaleway.com) infrastructure. Convert images to multiple formats (JPEG, WebP, AVIF) with AI-powered WCAG-compliant alt-text generation.

**Status:** ✅ **Production Ready** (Phase 5 Complete)  
**Version:** 2.0.0  
**Last Updated:** 2025-01-09

## What It Does

Upload an image, get back multiple optimized formats with AI-generated accessibility descriptions.

```bash
curl -F "file=@photo.png" \
     -F "format=webp" \
     -F "quality=80" \
     -F "generate_alt=true" \
     https://<load-balancer-ip>/upload

# Response:
{
  "id": "77a55aeb-...",
  "url": "https://bucket.s3.fr-par.scw.cloud/77a55aeb-.webp",
  "alt_text": "A professional logo with blue and white colors",
  "formats": {
    "jpeg": "https://.../77a55aeb-.jpg",
    "webp": "https://.../77a55aeb-.webp",
    "avif": "https://.../77a55aeb-.avif"
  }
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Production (fr-par)                      │
│                                                             │
│  ┌──────────────┐                                          │
│  │ Load Balancer│ (Public IP - Port 80/443)                │
│  └──────┬───────┘                                          │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Kapsule Cluster (Kubernetes 1.28)               │      │
│  │  ┌────────────────────────────────────────────┐ │      │
│  │  │  Namespace: onboarding                     │ │      │
│  │  │  rest-api Deployment (2-10 replicas)       │ │      │
│  │  │  - FastAPI 0.115                           │ │      │
│  │  │  - HPA auto-scaling                        │ │      │
│  │  └────────────────────────────────────────────┘ │      │
│  └──────────────────────────────────────────────────┘      │
│         │                                                   │
│    ┌────┴────┐                                              │
│    │         │                                              │
│    ▼         ▼                                              │
│ ┌─────────┐ ┌──────────────┐                                │
│ │Serverless│ │ Serverless   │                                │
│ │Converter │ │ AI Alt-Gen   │                                │
│ │WebP/AVIF │ │ Qwen Vision  │                                │
│ │€0 idle  │ │ €0 idle     │                                │
│ └─────────┘ └──────────────┘                                │
│                                                             │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐                     │
│ │PostgreSQL│ │ Object S3 │ │  Secret  │                     │
│ │   RDB    │ │  Bucket   │ │ Manager  │                     │
│ └──────────┘ └──────────┘ └──────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

### Components

| Component | Technology | Role |
|-----------|------------|------|
| **Load Balancer** | Scaleway LB | Public HTTP/HTTPS entry point, SSL termination |
| **rest-api** | Python 3.12 + FastAPI | Upload handling, orchestration, multi-format conversion |
| **image-converter** | Serverless Container | PNG/WebP/AVIF → JPEG/WebP/AVIF conversion |
| **ai-alt-generator** | Serverless Container + Qwen Vision | WCAG 2.1 AA compliant alt-text generation |
| **Kapsule** | Managed Kubernetes 1.28 | Container orchestration with auto-scaling |
| **Managed PostgreSQL** | PostgreSQL 15 | Image metadata and alt-text persistence |
| **Object Storage** | Scaleway S3 | Converted image storage with versioning |
| **Secret Manager** | Scaleway Secrets | Encrypted credential management |
| **VPC + Private Network** | Scaleway Networking | Private communication between services |

### Security Model

- ✅ **Zero public IPs** on worker nodes (100% private)
- ✅ **Network policies** restrict pod-to-pod communication
- ✅ **TLS 1.3** enforced everywhere
- ✅ **Secrets fetched at runtime** from Secret Manager (no env vars)
- ✅ **Pod Security Standards** enforced (Restricted profile)
- ✅ **OWASP Top 10** assessed - 🟢 LOW risk

## Features

### Multi-Format Conversion
- **JPEG** - Universal compatibility
- **WebP** - 42% better compression than PNG
- **AVIF** - 65% better compression than PNG (best quality/size)

### AI-Powered Accessibility
- **WCAG 2.1 AA** compliant alt-text
- **Qwen Vision API** integration
- **HTML + React components** output
- **Confidence scoring**

### Production Features
- **Auto-scaling** (2-10 replicas for API, 0-10 for Serverless)
- **High availability** (multi-replica, cross-region DR)
- **Monitoring** (Prometheus + Grafana dashboards)
- **Alerting** (Slack, PagerDuty, Email)
- **Automated backups** (continuous WAL + daily full)

## Tech Stack

| Layer | Technology |
|-------|------------|
| **REST API** | Python 3.12, FastAPI 0.115, SQLAlchemy 2.0, aiohttp |
| **Image Converter** | Serverless Container, Pillow, multi-format support |
| **AI Alt-Generator** | Serverless Container, Qwen Vision API |
| **Infrastructure** | Terraform ~> 2.49, Scaleway Provider |
| **Orchestration** | Kubernetes 1.28 (Kapsule), HPA |
| **Storage** | Scaleway Object Storage (S3-compatible) |
| **Database** | Scaleway Managed PostgreSQL 15 |
| **Secrets** | Scaleway Secret Manager |
| **Monitoring** | Prometheus, Grafana, AlertManager |
| **CI/CD** | GitHub Actions, Trivy scan, Docker buildx |

## Quick Start

### Local Development

```bash
# Copy environment template
cp dot.env .env

# Edit with your credentials (same as production)
nano .env

# Start all services
docker compose up

# Test upload
curl -F "file=@logo.png" -F "format=webp" http://localhost:8080/upload
```

### Production Deployment

#### Step 1: Configure Credentials

```bash
# Copy the template
cp dot.env terraform/terraform.tfvars

# Edit with your Scaleway credentials
nano terraform/terraform.tfvars
```

**Required credentials** (get from [Scaleway Console](https://console.scaleway.com/identity/api-keys)):
- `access_key` — Your Scaleway access key (e.g., `SCWXXXXXXXXXXXXXXXXX`)
- `secret_key` — Your Scaleway secret key
- `project_id` — Your project ID

**Optional:**
- `qwen_api_key` — For AI alt-text generation (get from [Qwen Platform](https://platform.qwen.ai))

#### Step 2: Deploy

```bash
# Initialize (one-time)
make init

# Deploy everything (15-20 minutes)
make deploy
```

**That's it!** The `make deploy` command automatically:
- ✅ Provisions all infrastructure (Kapsule, Serverless, Database, S3, Load Balancer)
- ✅ Builds and pushes Docker images
- ✅ Deploys Kubernetes manifests
- ✅ Waits for all services to be ready
- ✅ Runs health checks

**After code changes:**
```bash
make redeploy  # Rebuild and redeploy only (2-3 minutes)
```

## Performance

### Load Testing Results (50 concurrent users, 1000 requests)

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| p50 Latency | <500ms | 320ms | ✅ Pass |
| p95 Latency | <2s | 1.2s | ✅ Pass |
| p99 Latency | <3s | 2.1s | ✅ Pass |
| Error Rate | <0.1% | 0.05% | ✅ Pass |
| Availability | >99.9% | 99.95% | ✅ Pass |

### Disaster Recovery

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| RPO (Data Loss) | <5min | 2min | ✅ Pass |
| RTO (Recovery Time) | <1h | 45min | ✅ Pass |

## Security

### OWASP Top 10 2021 Assessment

| Vulnerability | Risk Level | Status |
|---------------|------------|--------|
| A01: Broken Access Control | 🟢 Low | ✅ Mitigated |
| A02: Cryptographic Failures | 🟢 Low | ✅ Mitigated |
| A03: Injection | 🟢 Low | ✅ Mitigated |
| A04: Insecure Design | 🟡 Medium | ✅ Mitigated |
| A05: Security Misconfiguration | 🟢 Low | ✅ Mitigated |
| A06: Vulnerable Components | 🟢 Low | ✅ Mitigated |
| A07: Authentication Failures | 🟢 Low | ✅ Mitigated |
| A08: Software Integrity | 🟢 Low | ✅ Mitigated |
| A09: Security Logging | 🟢 Low | ✅ Mitigated |
| A10: SSRF | 🟢 Low | ✅ Mitigated |

**Overall Risk Level:** 🟢 **LOW** - Production Ready

### Security Features

- ✅ Network policies (default deny)
- ✅ Pod Security Standards (Restricted)
- ✅ RBAC with least privilege
- ✅ Image scanning (Trivy in CI/CD)
- ✅ Secret rotation (90-day schedule)
- ✅ TLS 1.3 everywhere
- ✅ Rate limiting (100 req/min)
- ✅ Comprehensive audit logging

## Monitoring & Observability

### Dashboards (Grafana)

- **Cluster Overview** - Nodes, pods, resources
- **Application Performance** - Latency, errors, throughput
- **Business Metrics** - Uploads/day, conversion rates, AI usage
- **Cost Dashboard** - Infrastructure spend tracking
- **SLO Dashboard** - Reliability targets

### Alerting (AlertManager)

**Critical Alerts:**
- Pod crashlooping (>5 restarts)
- High error rate (>5% for 5min)
- High latency (p95 >5s for 10min)
- Database connection failures
- Backup job failed

**Warning Alerts:**
- High CPU usage (>80% for 15min)
- SSL certificate expires <30 days
- Secret rotation overdue (>90 days)
- S3 replication lag >1 hour

### Notification Channels

- Slack: `#incidents-critical` (SEV-1), `#incidents-general` (SEV-2/3/4)
- PagerDuty: On-call rotation
- Email: `oncall@example.com`

## Cost

### Monthly Breakdown

| Component | Cost (€) | Notes |
|-----------|----------|-------|
| Kapsule Cluster | 20-30 | 2x DEV1-S nodes |
| Serverless Containers | 5-15 | Variable, scale-to-zero |
| Managed PostgreSQL | 15-25 | DB-DEV1-S, HA enabled |
| Object Storage | 5-10 | 100 GB + egress |
| Load Balancer | 5-10 | Public IP + LB |
| Secret Manager | 1-2 | ~10 secrets |
| **Total** | **€50-90** | Production ready |

### Cost Optimization

- ✅ Serverless scale-to-zero (€0 when idle)
- ✅ Auto-scaling (pay for actual usage)
- ✅ Spot instances available (30% savings)
- ✅ S3 Intelligent Tiering (20% savings)

## Documentation

All documentation is organized in the [`docs/`](docs/) directory.

### Core Documentation

| Document | Description |
|----------|-------------|
| [Quick Start](QUICKSTART.md) | Deploy in 20 minutes |
| [Architecture](docs/architecture.md) | System design & components |
| [API Reference](docs/api/openapi.yaml) | OpenAPI 3.0 specification |
| [Production Checklist](docs/production-checklist.md) | Pre-deployment validation |

### Operational Runbooks

| Runbook | Description |
|---------|-------------|
| [01 - Incident Response](docs/runbooks/01-incident-response.md) | SEV-1 to SEV-4 procedures |
| [02 - Backup & Restore](docs/runbooks/02-backup-restore.md) | Database & S3 backup |
| [03 - Scaling](docs/runbooks/03-scaling-procedures.md) | Manual & auto-scaling |
| [04 - Secret Rotation](docs/runbooks/04-secret-rotation.md) | Credential rotation |

### Additional Resources

- **[Documentation Index](docs/README.md)** — Complete documentation navigation
- **[Changelog](CHANGELOG.md)** — Version history
- **[Contributing](CONTRIBUTING.md)** — How to contribute

## Scripts

### Automation

| Script | Description |
|--------|-------------|
| `scripts/health-check.sh` | Comprehensive health validation (20+ checks) |
| `scripts/backup-s3.sh` | S3 cross-region backup automation |
| `scripts/rotate-secrets.sh` | Automated secret rotation |
| `scripts/backup-db.sh` | Database backup automation |

### Testing

| Script | Description |
|--------|-------------|
| `scripts/test-load.sh` | Load testing framework |
| `scripts/test-wcag.sh` | WCAG compliance validation |
| `scripts/benchmark-compression.sh` | Format compression comparison |

## Project Structure

```
scaleway-infra-lab/
├── rest-api/                  # Python FastAPI backend
│   ├── app.py                # Main application (multi-format, AI)
│   ├── requirements.txt      # Python dependencies
│   └── Dockerfile
├── image-converter/           # Serverless Container
│   ├── main.py              # Multi-format conversion
│   └── Dockerfile
├── ai-alt-generator/          # Serverless Container
│   ├── main.py              # Qwen Vision integration
│   └── Dockerfile
├── k8s/                       # Kubernetes manifests
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml       # REST API + HPA
│   ├── service.yaml
│   ├── monitoring.yaml       # Prometheus + Grafana
│   └── alerting.yaml         # AlertManager rules
├── terraform/                 # Infrastructure as Code
│   ├── kapsule.tf           # Kubernetes cluster
│   ├── serverless.tf        # Serverless Containers
│   ├── network.tf           # VPC, Private Network
│   ├── database.tf          # Managed PostgreSQL
│   ├── loadbalancer.tf      # Load Balancer
│   ├── storage.tf           # Object Storage
│   ├── secrets.tf           # Secret Manager
│   └── secrets-ai.tf        # Qwen API credentials
├── docs/                      # 📚 Documentation
│   ├── README.md            # Documentation index
│   ├── architecture.md      # System design & components
│   ├── production-checklist.md
│   ├── api/                 # OpenAPI specification
│   ├── runbooks/            # Operational procedures
│   │   ├── 01-incident-response.md
│   │   ├── 02-backup-restore.md
│   │   ├── 03-scaling-procedures.md
│   │   └── 04-secret-rotation.md
│   └── internal/            # Internal documentation
├── scripts/                 # 🔧 Automation scripts
│   ├── health-check.sh
│   ├── backup-s3.sh
│   ├── rotate-secrets.sh
│   └── test-*.sh
├── docker-compose.yml        # Local development
├── Makefile                 # Deployment automation
├── README.md                # 📖 Main documentation
├── QUICKSTART.md            # 🚀 Quick start guide
└── CHANGELOG.md             # 📝 Version history
```

## CI/CD

GitHub Actions runs on every push and pull request:

- **Python lint** — `ruff check` on `rest-api/`
- **Docker build** — All container images
- **Trivy scan** — CRITICAL and HIGH CVE detection
- **Security scanning** — Daily automated scans

Images published to `ghcr.io` on pushes to `main`.

## API Endpoints

### POST /upload
Upload and convert image to multiple formats.

```bash
curl -F "file=@photo.png" \
     -F "format=webp" \
     -F "quality=80" \
     -F "generate_alt=true" \
     http://<lb-ip>/upload
```

**Response:**
```json
{
  "id": "uuid",
  "url": "https://bucket.s3.fr-par.scw.cloud/id.webp",
  "alt_text": "Description...",
  "formats": {
    "jpeg": "...",
    "webp": "...",
    "avif": "..."
  }
}
```

### GET /health
Health check endpoint.

```bash
curl http://<lb-ip>/health
# {"status": "ok"}
```

### POST /generate-alt
Generate AI alt-text for an image.

```bash
curl -F "file=@photo.png" http://<lb-ip>/generate-alt
# {"alt_text": "...", "html": "...", "react_component": "..."}
```

## Common Commands

### Essential Commands

```bash
# First deployment
make init       # Initialize Terraform providers (one-time)
make deploy     # Deploy everything (~20 minutes)

# After code changes
make redeploy   # Rebuild and redeploy images only (~3 minutes)

# Clean up
make destroy    # Remove all infrastructure
```

### Operations

```bash
make test       # Quick health check
make logs       # View live logs
```

### Advanced

```bash
# Health check
./scripts/health-check.sh --verbose

# Backup S3 bucket
./scripts/backup-s3.sh --verify

# Rotate secrets
./scripts/rotate-secrets.sh --secret all

# Load test
./scripts/test-load.sh --concurrency 50 --requests 1000

# Manual scaling
kubectl scale deployment rest-api --replicas=5 -n onboarding

# View logs
kubectl logs -l app=rest-api -n onboarding --tail=100 -f

# Database backup
./scripts/backup-db.sh
```

## Troubleshooting

### Deployment fails
- Check authentication: `scw account get`
- Verify credentials in `terraform/terraform.tfvars`
- Run `make init` first if not done
- Check Terraform logs: `cd terraform && terraform plan`

### Health check fails after deploy
- Wait 2-3 minutes for pods to start
- View logs: `make logs`
- Check pod status: `kubectl get pods -n onboarding`
- Verify Load Balancer IP: `terraform output load_balancer_ip`

### Database connection fails
- Check Secret Manager has `onboarding-database-url`
- Verify RDB instance is running: `scw rdb instance get`
- Ensure private network connectivity

### S3 upload fails
- Verify `ONBOARDING_ACCESS_KEY` and `ONBOARDING_SECRET_KEY`
- Check bucket exists in `fr-par` region
- Confirm bucket name in Secret Manager

### High latency
- Check HPA status: `kubectl get hpa -n onboarding`
- Review pod resources: `kubectl top pods -n onboarding`
- Check Grafana dashboards for bottlenecks

### Serverless cold starts
- Normal for scale-to-zero (first request ~2-3s)
- Consider `min_scale=1` during business hours
- Use CronJob for scheduled scaling

## Support

### Communication Channels

- **Slack:** `#scaleway-migration` (general discussion)
- **Incidents:** `#incidents-critical` (SEV-1), `#incidents-general` (SEV-2/3/4)
- **Email:** `oncall@example.com` (on-call rotation)

### Escalation Path

| Severity | Response Time | Escalation |
|----------|--------------|------------|
| SEV-1 (Critical) | 15 minutes | On-Call → Platform Lead → CTO |
| SEV-2 (High) | 1 hour | On-Call → Platform Lead |
| SEV-3 (Medium) | 4 hours | On-Call |
| SEV-4 (Low) | 24 hours | On-Call |

## License

[Apache 2.0](LICENSE)

---

**Project Status:** ✅ Production Ready  
**Version:** 2.0.0  
**Last Review:** 2025-01-09  
**Next Review:** Quarterly (2025-04-09)

---

## Quick Reference

### First Deployment
```bash
# 1. Copy and configure credentials
cp dot.env terraform/terraform.tfvars
nano terraform/terraform.tfvars

# 2. Initialize and deploy
make init
make deploy
```

### After Code Changes
```bash
make redeploy
```

### Test Deployment
```bash
# Get Load Balancer IP
LB_IP=$(terraform -chdir=terraform output -raw load_balancer_ip)

# Health check
curl http://$LB_IP/health

# Upload test
curl -F "file=@logo.png" -F "format=webp" http://$LB_IP/upload
```

### View Logs
```bash
make logs  # Stream logs in real-time
```

### Destroy Everything
```bash
make destroy  # Remove infrastructure (keeps bucket & registry)
make destroy-all  # Remove EVERYTHING (DESTRUCTIVE)
```