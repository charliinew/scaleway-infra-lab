# Architecture Documentation

**Project:** Cloud-Native Image Converter (imgflow)  
**Version:** 2.0.0  
**Last Updated:** 2025-01-09  
**Owner:** Platform Team

---

## 1. Overview

imgflow is a production-ready, cloud-native image processing platform deployed on Scaleway infrastructure. It converts images to multiple formats (JPEG, WebP, AVIF) with AI-powered WCAG-compliant alt-text generation.

### Key Features

- **Multi-format conversion:** PNG, JPEG, WebP, AVIF
- **AI-powered accessibility:** WCAG 2.1 AA compliant alt-text generation
- **Cloud-native architecture:** Kubernetes + Serverless Containers
- **Production-ready:** Auto-scaling, monitoring, disaster recovery
- **Cost-optimized:** Scale-to-zero for variable workloads (€50-90/month)

---

## 2. High-Level Architecture

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

---

## 3. Components

### 3.1 REST API (Kubernetes)

**Technology:** Python 3.12 + FastAPI 0.115  
**Deployment:** Kubernetes Deployment with HPA  
**Replicas:** 2-10 (auto-scaled)

**Responsibilities:**
- HTTP API endpoint (`/upload`, `/health`, `/generate-alt`)
- File upload handling and validation
- Orchestration: calls Image Converter + AI Alt-Generator
- Database persistence (metadata, alt-text)
- S3 storage management

**Key Endpoints:**
```
POST /upload          - Upload and convert image
GET  /health          - Health check
POST /generate-alt    - Generate AI alt-text
GET  /images/{id}     - Get image metadata
```

**Configuration:**
- CPU: 250m-500m (requests/limits)
- Memory: 256Mi-512Mi
- Port: 8080

---

### 3.2 Image Converter (Serverless)

**Technology:** Serverless Container + Pillow  
**Scaling:** 0-10 instances (scale-to-zero)  
**Cold Start:** ~2-3 seconds

**Responsibilities:**
- Multi-format image conversion (PNG/JPEG/WebP/AVIF → JPEG/WebP/AVIF)
- Quality optimization (1-100)
- Format-specific compression

**Performance:**
- Average conversion: 0.5-2s
- Cost: €0 when idle, ~€0.001 per conversion

---

### 3.3 AI Alt-Generator (Serverless)

**Technology:** Serverless Container + Qwen Vision API  
**Scaling:** 0-10 instances  
**Model:** Qwen-VL-Max

**Responsibilities:**
- Image analysis using Qwen Vision API
- WCAG 2.1 AA compliant alt-text generation
- HTML + React component output
- Confidence scoring

**Output:**
```json
{
  "alt_text": "A professional logo with blue and white colors",
  "html": "<img src='...' alt='A professional logo...'>",
  "react_component": "<Image alt='...' />",
  "confidence": 0.95
}
```

---

### 3.4 Kubernetes Cluster (Kapsule)

**Version:** Kubernetes 1.28 (Managed)  
**Node Pools:** 2 pools (default + serverless)

**Default Pool:**
- Node type: DEV1-S
- Size: 2 nodes (auto-scale 1-5)
- Workloads: REST API deployment

**Serverless Pool:**
- Node type: DEV1-M
- Size: 0-3 nodes (scale-to-zero)
- Workloads: Serverless Containers

**Features:**
- Auto-upgrade enabled
- Private network
- Calico CNI
- HPA (Horizontal Pod Autoscaler)

---

### 3.5 PostgreSQL Database

**Service:** Scaleway Managed PostgreSQL 15  
**Instance:** DB-DEV1-S  
**High Availability:** Enabled

**Schema:**
```sql
-- Images table
CREATE TABLE images (
  id UUID PRIMARY KEY,
  original_filename VARCHAR(255),
  format VARCHAR(10),
  quality INTEGER,
  s3_key VARCHAR(500),
  s3_url VARCHAR(1000),
  file_size BIGINT,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

-- Alt texts table
CREATE TABLE image_alt_texts (
  id UUID PRIMARY KEY,
  image_id UUID REFERENCES images(id),
  alt_text TEXT,
  html TEXT,
  react_component TEXT,
  confidence FLOAT,
  created_at TIMESTAMP
);
```

**Backup Strategy:**
- Continuous WAL archiving
- Daily full backups
- Cross-region replication (nl-ams)
- RPO: <5 minutes, RTO: <1 hour

---

### 3.6 Object Storage (S3)

**Service:** Scaleway Object Storage  
**Region:** fr-par (primary), nl-ams (DR)  
**Features:**
- Versioning enabled
- Cross-region replication
- Lifecycle policies

**Bucket Structure:**
```
onboarding-images-prod/
├── original/
│   └── {uuid}.{ext}
├── converted/
│   └── {uuid}.{format}
└── backup/
    └── {date}/
```

---

### 3.7 Load Balancer

**Service:** Scaleway Load Balancer  
**Ports:** 80 (HTTP), 443 (HTTPS)  
**Features:**
- SSL/TLS termination (Let's Encrypt)
- Health checks (HTTP /health)
- Backend servers: REST API pods
- Sticky sessions: disabled

---

## 4. Data Flow

### 4.1 Upload & Conversion Flow

```
1. User uploads image via POST /upload
   ↓
2. REST API validates file (type, size)
   ↓
3. Upload to S3 (original/)
   ↓
4. Call Image Converter (Serverless)
   - Convert to target format
   - Optimize quality
   ↓
5. Upload converted to S3 (converted/)
   ↓
6. (Optional) Call AI Alt-Generator
   - Analyze image
   - Generate alt-text
   ↓
7. Save metadata to PostgreSQL
   ↓
8. Return JSON response with URLs
```

### 4.2 AI Alt-Text Generation Flow

```
1. REST API receives image bytes
   ↓
2. Call Qwen Vision API
   - POST /v1/vision/analyze
   - Image as base64
   ↓
3. Qwen returns analysis
   - Alt-text (<125 chars)
   - HTML snippet
   - React component
   - Confidence score
   ↓
4. Validate WCAG compliance
   - Length check
   - No "image of" phrases
   ↓
5. Return structured response
```

---

## 5. Networking

### 5.1 VPC Architecture

```
┌────────────────────────────────────┐
│         VPC (fr-par)               │
│                                    │
│  ┌──────────────────────────────┐ │
│  │  Private Network             │ │
│  │  10.0.0.0/16                 │ │
│  │                              │ │
│  │  ┌─────────┐  ┌──────────┐  │ │
│  │  │ Kapsule │  │   RDB    │  │ │
│  │  │ Cluster │  │  (Private)│  │ │
│  │  └─────────┘  └──────────┘  │ │
│  │                              │ │
│  └──────────────────────────────┘ │
│                                    │
│  ┌──────────────────────────────┐ │
│  │  Public Gateway (NAT)        │ │
│  │  - Outbound internet         │ │
│  │  - Bastion for SSH           │ │
│  └──────────────────────────────┘ │
│                                    │
│  ┌──────────────────────────────┐ │
│  │  Load Balancer (Public)      │ │
│  │  - Port 80/443               │ │
│  └──────────────────────────────┘ │
└────────────────────────────────────┘
```

### 5.2 Security Groups

| Component | Inbound Rules | Outbound |
|-----------|---------------|----------|
| **Kapsule Nodes** | SSH (bastion IP only) | All (NAT) |
| **Load Balancer** | HTTP/HTTPS (0.0.0.0/0) | To K8s pods |
| **PostgreSQL** | 5432 (K8s private IPs) | None |
| **REST API Pods** | 8080 (LB only) | DB, S3, Serverless |

### 5.3 Kubernetes Network Policies

```yaml
# Default deny all ingress/egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: onboarding
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# Allow REST API ingress from LB
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rest-api-ingress
  namespace: onboarding
spec:
  podSelector:
    matchLabels:
      app: rest-api
  ingress:
  - from:
    - ipBlock:
        cidr: 10.0.0.0/8  # VPC range
    ports:
    - protocol: TCP
      port: 8080
  policyTypes:
  - Ingress
```

---

## 6. Security

### 6.1 Authentication & Authorization

**Service-to-Service:**
- Bearer tokens for internal APIs
- Token rotation every 90 days
- Stored in Secret Manager

**External Access:**
- Rate limiting (100 req/min per IP)
- Input validation on all endpoints
- CORS configured for web clients

### 6.2 Secrets Management

**Scaleway Secret Manager:**
```
onboarding-database-url     → PostgreSQL connection string
onboarding-s3-credentials   → S3 access key + secret
qwen-api-key               → Qwen Vision API key
onboarding-service-token   → Internal auth token
```

**Rotation Schedule:**
- Database URL: 90 days
- S3 credentials: 90 days
- Qwen API key: 180 days
- Service token: 90 days

### 6.3 Data Protection

**Encryption:**
- TLS 1.3 in transit (everywhere)
- AES-256 at rest (PostgreSQL, S3)
- Secrets encrypted in Secret Manager

**Access Control:**
- RBAC for Kubernetes (least privilege)
- IAM roles for S3 access
- Network policies (default deny)

---

## 7. Monitoring & Observability

### 7.1 Stack

- **Prometheus:** Metrics collection
- **Grafana:** Dashboards & visualization
- **AlertManager:** Alerting & notifications

### 7.2 Key Metrics

**Application:**
- Request rate (req/s)
- Error rate (%)
- Latency (p50, p95, p99)
- Active connections

**Infrastructure:**
- Pod CPU/Memory usage
- Node resources
- Database connections
- S3 operations

**Business:**
- Images uploaded/day
- Conversion success rate
- AI alt-text generation rate
- Format distribution

### 7.3 Dashboards

| Dashboard | Purpose | URL Path |
|-----------|---------|----------|
| Cluster Overview | Nodes, pods, resources | `/d/cluster` |
| Application Performance | Latency, errors, throughput | `/d/app` |
| Business Metrics | Uploads, conversions | `/d/business` |
| Cost Tracking | Infrastructure spend | `/d/cost` |

### 7.4 Alerts

**Critical (SEV-1):**
- Pod crashlooping (>5 restarts)
- Error rate >5% for 5min
- p95 latency >5s for 10min
- Database connection failures
- Backup job failed

**Warning (SEV-2/3):**
- High CPU (>80% for 15min)
- SSL certificate expires <30 days
- Secret rotation overdue
- S3 replication lag >1h

---

## 8. Disaster Recovery

### 8.1 Strategy

**Primary Region:** fr-par (Paris)  
**DR Region:** nl-ams (Amsterdam)

**RPO (Recovery Point Objective):** <5 minutes  
**RTO (Recovery Time Objective):** <1 hour

### 8.2 Backup Components

| Component | Backup Type | Frequency | Retention |
|-----------|-------------|-----------|-----------|
| PostgreSQL | Continuous WAL | Real-time | 30 days |
| PostgreSQL | Full snapshot | Daily | 30 days |
| S3 Bucket | Versioning + replication | Real-time | Indefinite |
| Secrets | Manual export | Weekly | 4 weeks |

### 8.3 Failover Procedure

```
1. Detect failure (monitoring alerts)
   ↓
2. Activate DR region (nl-ams)
   - Update DNS to DR Load Balancer
   - Point to DR database replica
   ↓
3. Restore from backups
   - Database: latest snapshot + WAL
   - S3: cross-region replication
   ↓
4. Validate services
   - Health checks
   - Smoke tests
   ↓
5. Notify stakeholders
```

---

## 9. Cost Optimization

### 9.1 Monthly Breakdown

| Component | Cost (€) | Optimization |
|-----------|----------|--------------|
| Kapsule Cluster | 20-30 | Auto-scaling, right-sized nodes |
| Serverless | 5-15 | Scale-to-zero (€0 idle) |
| PostgreSQL | 15-25 | DB-DEV1-S, HA enabled |
| S3 Storage | 5-10 | 100GB + Intelligent Tiering |
| Load Balancer | 5-10 | Single LB, efficient config |
| Secret Manager | 1-2 | ~10 secrets |
| **Total** | **€50-90** | Production ready |

### 9.2 Optimization Strategies

**Implemented:**
- ✅ Serverless scale-to-zero
- ✅ Auto-scaling (HPA + Cluster Autoscaler)
- ✅ S3 lifecycle policies
- ✅ Right-sized resources

**Potential:**
- Spot instances for non-critical workloads (30% savings)
- Reserved capacity for baseline load (25% savings)
- CDN for static image delivery (20% cost reduction)

---

## 10. Deployment

### 10.1 Infrastructure as Code

**Terraform:**
```
terraform/
├── main.tf           # Provider configuration
├── variables.tf      # Input variables
├── outputs.tf        # Output values
├── network.tf        # VPC, Private Network, Gateway
├── kapsule.tf        # Kubernetes cluster + pools
├── serverless.tf     # Serverless Containers
├── database.tf       # Managed PostgreSQL
├── loadbalancer.tf   # Load Balancer
├── storage.tf        # Object Storage (S3)
├── secrets.tf        # Secret Manager
└── secrets-ai.tf     # Qwen API credentials
```

### 10.2 Kubernetes Manifests

```
k8s/
├── namespace.yaml    # onboarding namespace
├── configmap.yaml    # Application configuration
├── secrets.yaml      # Kubernetes secrets
├── deployment.yaml   # REST API + HPA
├── service.yaml      # Services (LB + ClusterIP)
├── monitoring.yaml   # Prometheus + Grafana
└── alerting.yaml     # AlertManager rules
```

### 10.3 Deployment Commands

```bash
# First deployment
make init
make deploy

# After code changes
make redeploy

# Destroy
make destroy
```

---

## 11. Performance

### 11.1 Benchmarks

**Load Testing (50 concurrent, 1000 requests):**

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| p50 Latency | <500ms | 320ms | ✅ |
| p95 Latency | <2s | 1.2s | ✅ |
| p99 Latency | <3s | 2.1s | ✅ |
| Error Rate | <0.1% | 0.05% | ✅ |
| Availability | >99.9% | 99.95% | ✅ |

### 11.2 Scaling

**REST API:**
- Min replicas: 2
- Max replicas: 10
- Scale trigger: CPU >70%, Memory >80%
- Scale-up time: ~30s
- Scale-down time: ~5min (stabilization)

**Serverless:**
- Min instances: 0 (scale-to-zero)
- Max instances: 10
- Scale trigger: Request-based
- Cold start: 2-3s
- Warm start: <100ms

---

## 12. Future Roadmap

### Q2 2025
- [ ] Service mesh (Istio) for traffic management
- [ ] Web Application Firewall (WAF)
- [ ] SLSA Level 2 compliance
- [ ] Multi-region active-active

### Q3 2025
- [ ] OAuth2/OIDC authentication
- [ ] Redis caching layer
- [ ] CDN integration
- [ ] GPU acceleration for image processing

### Q4 2025
- [ ] SOC 2 Type II certification
- [ ] ISO 27001 alignment
- [ ] Automated penetration testing
- [ ] Zero-trust network architecture

---

## Appendix A: Quick Reference

### Commands

```bash
# Health check
curl http://<LB_IP>/health

# Upload image
curl -F "file=@photo.png" -F "format=webp" http://<LB_IP>/upload

# View logs
kubectl logs -l app=rest-api -n onboarding -f

# Scale manually
kubectl scale deployment rest-api --replicas=5 -n onboarding

# Database backup
./scripts/backup-db.sh

# Rotate secrets
./scripts/rotate-secrets.sh --secret all
```

### URLs

| Service | URL | Notes |
|---------|-----|-------|
| Load Balancer | http://<LB_IP> | Main entry point |
| Grafana | http://<LB_IP>:3000 | Monitoring dashboards |
| Prometheus | http://prometheus:9090 | Metrics (internal) |
| AlertManager | http://alertmanager:9093 | Alerts (internal) |

---

**Document Version:** 1.0  
**Last Review:** 2025-01-09  
**Next Review:** Quarterly (2025-04-09)  
**Approved By:** Platform Team Lead