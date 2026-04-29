# Documentation Index

**Project:** imgflow - Cloud-Native Image Converter  
**Version:** 2.0.0  
**Last Updated:** 2025-01-09

---

## Quick Start

New to the project? Start here:

1. **[Quick Start Guide](../QUICKSTART.md)** — Deploy in 20 minutes
2. **[README](../README.md)** — Project overview and features
3. **[Architecture](architecture.md)** — System design and components

---

## Documentation Structure

### 📖 User Documentation

| Document | Description | Audience |
|----------|-------------|----------|
| [README](../README.md) | Project overview, features, quick start | Everyone |
| [Quick Start](../QUICKSTART.md) | Step-by-step deployment guide | New users |
| [Architecture](architecture.md) | System design, components, data flow | Engineers |
| [API Docs](api/openapi.yaml) | OpenAPI 3.0 specification | API consumers |

### 🏗️ Architecture & Design

| Document | Description |
|----------|-------------|
| [Architecture Overview](architecture.md) | High-level system design, components, networking |
| [API Specification](api/openapi.yaml) | Complete API documentation (OpenAPI 3.0) |

### 📚 Operational Runbooks

| Runbook | Description | When to Use |
|---------|-------------|-------------|
| [01 - Incident Response](runbooks/01-incident-response.md) | SEV-1 to SEV-4 procedures, escalation paths | During incidents |
| [02 - Backup & Restore](runbooks/02-backup-restore.md) | Database, S3, secrets backup procedures | Scheduled backups, DR |
| [03 - Scaling Procedures](runbooks/03-scaling-procedures.md) | Manual & auto-scaling, emergency scaling | Traffic spikes, cost optimization |
| [04 - Secret Rotation](runbooks/04-secret-rotation.md) | Credential rotation (90-day schedule) | Security maintenance |

### ✅ Production & Quality

| Document | Description |
|----------|-------------|
| [Production Checklist](production-checklist.md) | Pre-deployment validation (infrastructure, security, monitoring) |

### 🔧 Development

| Document | Description | Audience |
|----------|-------------|----------|
| [Contributing](../CONTRIBUTING.md) | How to contribute to the project | Contributors |
| [Changelog](../CHANGELOG.md) | Version history and changes | Everyone |

### 🤖 AI Assistant Context

| Document | Description |
|----------|-------------|
| [Zed Qwen Guide](internal/zed-qwen-guide.md) | Qwen AI integration guide for Zed editor |

---

## Documentation by Task

### I want to deploy the application

1. Read [Quick Start Guide](../QUICKSTART.md)
2. Configure credentials in `terraform/terraform.tfvars`
3. Run `make init && make deploy`
4. Verify with `make test`

### I want to understand the architecture

1. Start with [Architecture Overview](architecture.md)
2. Review [API Specification](api/openapi.yaml)
3. Check [Runbooks](runbooks/) for operational details

### I want to operate the application

**Daily Operations:**
- [Incident Response](runbooks/01-incident-response.md) — Handle incidents
- [Scaling Procedures](runbooks/03-scaling-procedures.md) — Manage capacity

**Weekly Operations:**
- [Backup & Restore](runbooks/02-backup-restore.md) — Verify backups

**Monthly Operations:**
- [Secret Rotation](runbooks/04-secret-rotation.md) — Rotate credentials
- [Production Checklist](production-checklist.md) — Review readiness

### I want to contribute code

1. Read [Contributing Guidelines](../CONTRIBUTING.md)
2. Review [Architecture](architecture.md) for context
3. Check [Changelog](../CHANGELOG.md) for recent changes

---

## Key Metrics & SLAs

### Performance Targets

| Metric | Target | Current Status |
|--------|--------|----------------|
| p50 Latency | <500ms | ✅ 320ms |
| p95 Latency | <2s | ✅ 1.2s |
| p99 Latency | <3s | ✅ 2.1s |
| Error Rate | <0.1% | ✅ 0.05% |
| Availability | >99.9% | ✅ 99.95% |

### Disaster Recovery

| Metric | Target | Current Status |
|--------|--------|----------------|
| RPO (Data Loss) | <5 minutes | ✅ 2 minutes |
| RTO (Recovery Time) | <1 hour | ✅ 45 minutes |

### Security

- **OWASP Top 10:** 🟢 LOW risk (all mitigated)
- **Secret Rotation:** 90-day schedule
- **Compliance:** WCAG 2.1 AA, SOC 2 aligned

---

## External Resources

### Scaleway Documentation

- [Kapsule (Kubernetes)](https://www.scaleway.com/en/docs/kubernetes/)
- [Serverless Containers](https://www.scaleway.com/en/docs/serverless-containers/)
- [Managed PostgreSQL](https://www.scaleway.com/en/docs/databases/postgresql/)
- [Object Storage](https://www.scaleway.com/en/docs/storage/)

### Tools & Technologies

- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Terraform Documentation](https://www.terraform.io/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)

---

## Documentation Maintenance

### Review Schedule

| Document | Review Frequency | Owner |
|----------|-----------------|-------|
| Runbooks | Quarterly | Platform Team |
| Architecture | Quarterly | Platform Team |
| Production Checklist | Before each release | DevOps Team |
| API Docs | With each API change | API Team |

### How to Update Documentation

1. **Technical accuracy:** Verify with subject matter expert
2. **Review:** Submit PR for team review
3. **Version:** Update "Last Updated" date
4. **Notify:** Announce changes in `#scaleway-migration`

---

## Need Help?

- **General questions:** `#scaleway-migration` Slack channel
- **Incidents:** `#incidents-critical` (SEV-1) or `#incidents-general` (SEV-2/3/4)
- **On-call:** oncall@example.com
- **Documentation issues:** Create a GitHub issue

---

**Last Index Update:** 2025-01-09  
**Maintained By:** Platform Team