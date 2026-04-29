# Production Readiness Checklist

**Project:** Cloud-Native Image Converter on Scaleway  
**Version:** 1.0  
**Last Updated:** 2025-01-09  
**Owner:** Platform Team  
**Review Frequency:** Before each production deployment

---

## 1. Infrastructure Readiness

### 1.1 Kubernetes Cluster

- [ ] **Cluster Health**
  - [ ] All nodes in `Ready` state
  - [ ] No node pressure alerts (CPU, Memory, Disk)
  - [ ] Cluster version supported (Kubernetes 1.28+)
  - [ ] Auto-upgrade enabled with maintenance window

- [ ] **Node Pools**
  - [ ] Default pool: 2-5 nodes (DEV1-S)
  - [ ] Serverless pool: 0-3 nodes (DEV1-M)
  - [ ] Auto-scaling enabled (min/max configured)
  - [ ] Placement group configured for low latency

- [ ] **Network Configuration**
  - [ ] Private Network enabled
  - [ ] CNI (Calico) properly configured
  - [ ] Network policies applied (default deny)
  - [ ] Ingress controller configured

- [ ] **Load Balancer**
  - [ ] Health checks passing (HTTP 200)
  - [ ] SSL/TLS certificate valid (90+ days)
  - [ ] Backend servers registered
  - [ ] Sticky sessions configured (if needed)
  - [ ] Connection limits configured

**Verification Commands:**
```bash
kubectl get nodes
kubectl cluster-info
scw k8s cluster get $(terraform output -raw kapsule_cluster_id)
```

---

## 2. Application Readiness

### 2.1 REST API Deployment

- [ ] **Deployment Configuration**
  - [ ] Minimum 2 replicas for high availability
  - [ ] Resource requests/limits defined
  - [ ] Liveness probe configured
  - [ ] Readiness probe configured
  - [ ] Pod Disruption Budget (PDB) set

- [ ] **Container Image**
  - [ ] Image tag is immutable (SHA256 or semantic version)
  - [ ] Image scanned for vulnerabilities (Trivy)
  - [ ] Base image is minimal (Alpine/Distroless)
  - [ ] No hardcoded secrets in image

- [ ] **Configuration**
  - [ ] ConfigMap for non-sensitive config
  - [ ] Secrets for sensitive data
  - [ ] Environment variables documented
  - [ ] Feature flags configured

**Verification Commands:**
```bash
kubectl get deployment rest-api -n onboarding -o yaml
kubectl describe deployment rest-api -n onboarding
trivy image rg.fr-par.scw.cloud/$(NAMESPACE)/rest-api:latest
```

### 2.2 Serverless Containers

- [ ] **Image Converter**
  - [ ] Function deployed and active
  - [ ] Scale-to-zero enabled (min_scale=0)
  - [ ] Max scale configured (max_scale=10)
  - [ ] Memory/CPU limits appropriate
  - [ ] Timeout configured (30s default)

- [ ] **AI Alt-Generator**
  - [ ] Function deployed and active
  - [ ] Qwen API key configured
  - [ ] Rate limiting enabled
  - [ ] Error handling configured

**Verification Commands:**
```bash
scw container container list
scw container container get <container-id>
curl https://<converter-url>/health
```

### 2.3 Database

- [ ] **PostgreSQL Instance**
  - [ ] Instance type appropriate (DB-DEV1-S minimum)
  - [ ] High availability enabled
  - [ ] Automated backups configured (daily)
  - [ ] Point-in-time recovery enabled
  - [ ] Connection pooling configured (PgBouncer)

- [ ] **Schema & Migrations**
  - [ ] All migrations applied
  - [ ] Database user has minimal privileges
  - [ ] Tables indexed appropriately
  - [ ] Foreign keys defined

- [ ] **Connection String**
  - [ ] Stored in Secret Manager
  - [ ] SSL mode set to `require`
  - [ ] Connection timeout configured
  - [ ] Max connections defined

**Verification Commands:**
```bash
scw rdb instance get onboarding-db
kubectl get secret onboarding-db-creds -n onboarding
psql <connection-string> -c "\dt"
```

### 2.4 Object Storage

- [ ] **S3 Bucket**
  - [ ] Bucket created in fr-par region
  - [ ] Versioning enabled
  - [ ] Lifecycle policies configured
  - [ ] CORS policy set (if web access)
  - [ ] Access logging enabled

- [ ] **Cross-Region Replication**
  - [ ] DR bucket in nl-ams region
  - [ ] Replication rules configured
  - [ ] IAM role for replication created
  - [ ] Replication lag monitored

**Verification Commands:**
```bash
aws s3api get-bucket-versioning --bucket onboarding-images
aws s3api get-bucket-replication --bucket onboarding-images
```

---

## 3. Security Readiness

### 3.1 Access Control

- [ ] **RBAC (Kubernetes)**
  - [ ] ServiceAccount created for pods
  - [ ] Roles defined with minimal permissions
  - [ ] RoleBindings applied
  - [ ] No cluster-admin bindings for apps

- [ ] **IAM (Scaleway)**
  - [ ] Applications use dedicated IAM users
  - [ ] Least privilege principle applied
  - [ ] Access keys rotated (<90 days)
  - [ ] MFA enabled for admin accounts

- [ ] **Network Security**
  - [ ] Security groups restrict traffic
  - [ ] No public IPs on worker nodes
  - [ ] Private communication only
  - [ ] Bastion host for SSH access

**Verification Commands:**
```bash
kubectl get role,rolebinding -n onboarding
scw iam user list
scw instance security-group list
```

### 3.2 Secrets Management

- [ ] **Secret Manager**
  - [ ] All secrets stored in Secret Manager
  - [ ] No plaintext secrets in code
  - [ ] No plaintext secrets in environment
  - [ ] Secret versions tracked

- [ ] **Secret Rotation**
  - [ ] Rotation schedule defined (90 days)
  - [ ] Rotation procedure documented
  - [ ] Last rotation date recorded
  - [ ] Rollback procedure tested

**Verification Commands:**
```bash
scw secret secret list
kubectl get secrets -n onboarding
grep -r "password\|secret\|key" --exclude-dir=.git .
```

### 3.3 Image Security

- [ ] **Vulnerability Scanning**
  - [ ] All images scanned with Trivy
  - [ ] No CRITICAL vulnerabilities
  - [ ] HIGH vulnerabilities remediated
  - [ ] Scan results documented

- [ ] **Image Signing** (Optional)
  - [ ] Images signed with Cosign
  - [ ] Signature verified on deploy
  - [ ] Key management configured

**Verification Commands:**
```bash
trivy image rg.fr-par.scw.cloud/$(NAMESPACE)/rest-api:latest
trivy image rg.fr-par.scw.cloud/$(NAMESPACE)/image-converter:latest
trivy image rg.fr-par.scw.cloud/$(NAMESPACE)/ai-alt-generator:latest
```

### 3.4 Application Security

- [ ] **OWASP Top 10**
  - [ ] Input validation implemented
  - [ ] SQL injection prevented (parameterized queries)
  - [ ] XSS prevention (output encoding)
  - [ ] CSRF tokens (if forms)
  - [ ] Rate limiting enabled

- [ ] **Authentication & Authorization**
  - [ ] Service-to-service auth (tokens)
  - [ ] Token validation implemented
  - [ ] Authorization checks in place
  - [ ] Failed login attempts logged

- [ ] **TLS/Encryption**
  - [ ] TLS 1.3 enforced
  - [ ] Valid certificates (Let's Encrypt or commercial)
  - [ ] HSTS header set
  - [ ] Encryption at rest (database, S3)

**Verification Commands:**
```bash
curl -I https://<lb-ip>/health
openssl s_client -connect <lb-ip>:443
nmap --script ssl-enum-ciphers -p 443 <lb-ip>
```

---

## 4. Monitoring & Observability

### 4.1 Metrics

- [ ] **Prometheus**
  - [ ] Prometheus server running
  - [ ] All targets scraped successfully
  - [ ] Scrape interval configured (15-30s)
  - [ ] Retention period set (15+ days)

- [ ] **Application Metrics**
  - [ ] Request rate (requests/sec)
  - [ ] Error rate (errors/sec)
  - [ ] Latency (p50, p95, p99)
  - [ ] Active connections
  - [ ] Database query latency
  - [ ] S3 upload/download latency

- [ ] **Business Metrics**
  - [ ] Images uploaded per day
  - [ ] Conversion success rate
  - [ ] AI alt-text generation rate
  - [ ] Format distribution (JPEG/WebP/AVIF)

**Verification Commands:**
```bash
kubectl get pods -l app=prometheus
curl http://<prometheus-url>:/targets
curl http://<app-url>:/metrics
```

### 4.2 Logging

- [ ] **Log Collection**
  - [ ] Structured logging (JSON format)
  - [ ] Log levels appropriate (INFO, WARN, ERROR)
  - [ ] Sensitive data redacted
  - [ ] Correlation IDs included

- [ ] **Log Aggregation**
  - [ ] Central log storage configured
  - [ ] Log retention policy set (30+ days)
  - [ ] Log search enabled
  - [ ] Log-based alerts configured

**Verification Commands:**
```bash
kubectl logs -l app=rest-api -n onboarding | head -20
kubectl logs -l app=rest-api -n onboarding | grep ERROR
```

### 4.3 Alerting

- [ ] **AlertManager**
  - [ ] AlertManager running
  - [ ] Notification channels configured (Slack, PagerDuty, Email)
  - [ ] Alert routing rules defined
  - [ ] Silencing procedure documented

- [ ] **Critical Alerts**
  - [ ] Pod crashlooping (>5 restarts)
  - [ ] Node not ready
  - [ ] High error rate (>5% for 5min)
  - [ ] High latency (p95 >5s for 10min)
  - [ ] Database connection failures
  - [ ] Disk usage >85%
  - [ ] Memory usage >90%
  - [ ] Backup job failed

- [ ] **Warning Alerts**
  - [ ] Pod pending >10min
  - [ ] High CPU usage (>80% for 15min)
  - [ ] SSL certificate expires <30 days
  - [ ] Secret rotation overdue (>90 days)
  - [ ] S3 replication lag >1 hour

**Verification Commands:**
```bash
kubectl get pods -l app=alertmanager
curl http://<alertmanager-url>:/api/v1/alerts
```

### 4.4 Dashboards

- [ ] **Grafana**
  - [ ] Grafana server running
  - [ ] Data sources configured (Prometheus, Loki)
  - [ ] Authentication enabled
  - [ ] Dashboards provisioned

- [ ] **Required Dashboards**
  - [ ] Cluster Overview (nodes, pods, resources)
  - [ ] Application Performance (latency, errors, throughput)
  - [ ] Database Metrics (connections, queries, replication)
  - [ ] Business Metrics (uploads, conversions, AI usage)
  - [ ] Cost Dashboard (infrastructure spend)
  - [ ] SLO Dashboard (reliability targets)

**Verification Commands:**
```bash
kubectl get pods -l app=grafana
curl http://<grafana-url>/api/health
```

---

## 5. Reliability & Resilience

### 5.1 High Availability

- [ ] **Multi-Replica**
  - [ ] REST API: 2+ replicas
  - [ ] Pods spread across nodes (anti-affinity)
  - [ ] No single point of failure

- [ ] **Failover**
  - [ ] Automatic pod restart on failure
  - [ ] Node auto-replacement enabled
  - [ ] Load balancer health checks failover
  - [ ] Database failover tested

**Verification Commands:**
```bash
kubectl get deployment rest-api -n onboarding
kubectl get pods -n onboarding -o wide
```

### 5.2 Disaster Recovery

- [ ] **Backup Strategy**
  - [ ] Database: continuous WAL + daily full
  - [ ] S3: versioning + cross-region replication
  - [ ] Secrets: weekly export to secure storage
  - [ ] Backup restoration tested

- [ ] **RPO/RTO Targets**
  - [ ] RPO: <5 minutes (data loss tolerance)
  - [ ] RTO: <1 hour (recovery time)
  - [ ] DR drill conducted quarterly
  - [ ] DR runbook documented

- [ ] **Cross-Region DR**
  - [ ] DR region: nl-ams
  - [ ] Database backups replicated
  - [ ] S3 bucket replicated
  - [ ] Failover procedure tested

**Verification Commands:**
```bash
./scripts/backup-db.sh --test-restore
./scripts/backup-s3.sh --verify
```

### 5.3 Chaos Engineering

- [ ] **Resilience Testing**
  - [ ] Pod failure test (delete random pod)
  - [ ] Node failure test (cordon + drain)
  - [ ] Network partition test
  - [ ] Database failover test
  - [ ] Load spike test

**Verification Commands:**
```bash
kubectl delete pod -l app=rest-api -n onboarding
# Monitor recovery time
```

---

## 6. Performance & Scalability

### 6.1 Load Testing

- [ ] **Performance Targets**
  - [ ] p50 latency: <500ms
  - [ ] p95 latency: <2s
  - [ ] p99 latency: <3s
  - [ ] Error rate: <0.1%
  - [ ] Throughput: 100 req/sec minimum

- [ ] **Load Test Results**
  - [ ] Load test executed
  - [ ] Results documented
  - [ ] Bottlenecks identified
  - [ ] Optimizations applied

**Verification Commands:**
```bash
./scripts/test-load.sh --concurrency 50 --requests 1000
```

### 6.2 Auto-Scaling

- [ ] **Horizontal Pod Autoscaler**
  - [ ] HPA configured for REST API
  - [ ] CPU threshold: 70%
  - [ ] Memory threshold: 80%
  - [ ] Min replicas: 2
  - [ ] Max replicas: 10

- [ ] **Cluster Autoscaler**
  - [ ] Node pool auto-scaling enabled
  - [ ] Scale-down delay configured
  - [ ] Scale-up threshold appropriate

- [ ] **Serverless Scaling**
  - [ ] Scale-to-zero working
  - [ ] Cold start time acceptable (<3s)
  - [ ] Max scale limit appropriate

**Verification Commands:**
```bash
kubectl get hpa -n onboarding
kubectl describe hpa rest-api-hpa -n onboarding
```

### 6.3 Resource Optimization

- [ ] **Right-Sizing**
  - [ ] CPU requests match actual usage
  - [ ] Memory requests match actual usage
  - [ ] No over-provisioning
  - [ ] Cost optimization applied

- [ ] **Caching** (Optional)
  - [ ] Redis cache for frequent images
  - [ ] CDN for static content
  - [ ] Database query caching
  - [ ] Cache hit rate monitored

**Verification Commands:**
```bash
kubectl top pods -n onboarding
kubectl top nodes
```

---

## 7. Documentation

### 7.1 Technical Documentation

- [ ] **Architecture**
  - [ ] Architecture diagram up-to-date
  - [ ] Data flow diagram
  - [ ] Network topology diagram
  - [ ] Component interaction diagram

- [ ] **API Documentation**
  - [ ] OpenAPI specification complete
  - [ ] API versioning strategy
  - [ ] Rate limits documented
  - [ ] Error codes documented

- [ ] **Runbooks**
  - [ ] 01: Incident Response
  - [ ] 02: Backup & Restore
  - [ ] 03: Scaling Procedures
  - [ ] 04: Secret Rotation
  - [ ] 05: Deployment Guide

**Files to Check:**
```
docs/api/openapi.yaml
docs/runbooks/01-incident-response.md
docs/runbooks/02-backup-restore.md
docs/runbooks/03-scaling-procedures.md
docs/runbooks/04-secret-rotation.md
```

### 7.2 Operational Documentation

- [ ] **Onboarding**
  - [ ] README.md complete
  - [ ] Quick start guide
  - [ ] Local development setup
  - [ ] Troubleshooting guide

- [ ] **Procedures**
  - [ ] Deployment procedure
  - [ ] Rollback procedure
  - [ ] Emergency procedures
  - [ ] Maintenance windows

- [ ] **Compliance**
  - [ ] Security audit report
  - [ ] WCAG compliance report
  - [ ] Data privacy documentation
  - [ ] Incident response plan

---

## 8. Team Readiness

### 8.1 Training

- [ ] **Team Training Completed**
  - [ ] Kubernetes basics
  - [ ] Serverless Containers
  - [ ] Monitoring & alerting
  - [ ] Incident response
  - [ ] Security best practices

- [ ] **On-Call Rotation**
  - [ ] On-call schedule defined
  - [ ] Escalation path documented
  - [ ] PagerDuty/Slack configured
  - [ ] Handover procedure defined

### 8.2 Support

- [ ] **Support Channels**
  - [ ] Slack: #scaleway-migration
  - [ ] Slack: #incidents-critical
  - [ ] Email: oncall@example.com
  - [ ] Status page configured

- [ ] **Contact List**
  - [ ] Platform Team Lead
  - [ ] Security Team Lead
  - [ ] On-Call Engineer
  - [ ] Project Manager

---

## 9. Compliance & Legal

### 9.1 Regulatory Compliance

- [ ] **GDPR** (if applicable)
  - [ ] Data processing agreement
  - [ ] Privacy policy updated
  - [ ] Data retention policy
  - [ ] Right to erasure implemented

- [ ] **WCAG 2.1 AA**
  - [ ] Alt-text generation working
  - [ ] Compliance tested
  - [ ] Accessibility statement

- [ ] **Security Standards**
  - [ ] OWASP Top 10 addressed
  - [ ] SOC 2 controls (if applicable)
  - [ ] ISO 27001 alignment (if applicable)

### 9.2 Cost Management

- [ ] **Budget**
  - [ ] Monthly budget defined
  - [ ] Cost alerts configured
  - [ ] Cost allocation tags
  - [ ] Monthly cost report

- [ ] **Cost Optimization**
  - [ ] Spot instances for non-critical
  - [ ] S3 Intelligent Tiering
  - [ ] Reserved capacity (if stable)
  - [ ] Serverless for variable workloads

**Estimated Monthly Cost:**
- Kubernetes: €20-30
- Serverless: €5-15 (variable)
- Database: €15-25
- S3 Storage: €5-10
- Load Balancer: €5-10
- **Total: €50-90/month**

---

## 10. Final Validation

### 10.1 Pre-Deployment Checklist

- [ ] All critical checks passed
- [ ] All warnings acknowledged
- [ ] Team notified of deployment
- [ ] Rollback plan reviewed
- [ ] Monitoring dashboards open
- [ ] On-call engineer available

### 10.2 Post-Deployment Validation

- [ ] Health checks passing
- [ ] No errors in logs (first 30min)
- [ ] Metrics flowing correctly
- [ ] Alerts not firing
- [ ] User acceptance testing passed
- [ ] Performance targets met

### 10.3 Sign-Off

| Role | Name | Signature | Date |
|------|------|-----------|------|
| **Platform Lead** | | | |
| **Security Lead** | | | |
| **DevOps Lead** | | | |
| **Project Manager** | | | |

---

## Appendix: Quick Reference

### Emergency Contacts

| Issue | Contact | Escalation |
|-------|---------|------------|
| SEV-1 Incident | On-Call | Platform Lead → CTO |
| Security Breach | Security Team | CISO → CEO |
| Data Loss | DBA + Platform | CTO |
| Cost Anomaly | FinOps | CFO |

### Key Commands

```bash
# Health check
./scripts/health-check.sh --verbose

# Deploy
make deploy

# Rollback
kubectl rollout undo deployment/rest-api -n onboarding

# Scale
kubectl scale deployment rest-api --replicas=5 -n onboarding

# Logs
kubectl logs -l app=rest-api -n onboarding --tail=100 -f

# Database backup
./scripts/backup-db.sh

# Secret rotation
./scripts/rotate-secrets.sh --secret all
```

### Monitoring URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://grafana.internal:3000 | admin/**** |
| Prometheus | http://prometheus.internal:9090 | - |
| AlertManager | http://alertmanager.internal:9093 | - |
| Load Balancer | http://<LB_IP> | - |

---

**Document Version:** 1.0  
**Last Review:** 2025-01-09  
**Next Review:** Before next production deployment  
**Approved By:** Platform Team Lead