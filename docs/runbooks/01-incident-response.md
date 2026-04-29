# Runbook 01: Incident Response & Maintenance

**Version:** 1.0.0  
**Last Updated:** 2024  
**Owner:** Platform Team  
**Review Cycle:** Quarterly

---

## 📋 Table of Contents

1. [Incident Classification](#incident-classification)
2. [Response Procedures](#response-procedures)
3. [Escalation Matrix](#escalation-matrix)
4. [Communication Templates](#communication-templates)
5. [Post-Incident Review](#post-incident-review)
6. [Maintenance Procedures](#maintenance-procedures)
7. [Contact Information](#contact-information)

---

## 🚨 Incident Classification

### Severity Levels

| Severity | Name | Response Time | Resolution Time | Examples |
|----------|------|---------------|-----------------|----------|
| **SEV-1** | Critical | 15 minutes | 4 hours | Complete service outage, data loss, security breach |
| **SEV-2** | High | 1 hour | 8 hours | Major feature broken, >50% error rate |
| **SEV-3** | Medium | 4 hours | 24 hours | Partial degradation, >10% error rate |
| **SEV-4** | Low | 24 hours | 1 week | Minor issues, <10% error rate, cosmetic |

### Impact Assessment

```
Impact = Users Affected × Functionality Loss

Critical:    >10,000 users OR core functionality broken
High:        1,000-10,000 users OR major feature broken
Medium:      100-1,000 users OR minor feature broken
Low:         <100 users OR cosmetic issues
```

---

## 🔧 Response Procedures

### SEV-1: Critical Incident

#### Symptoms
- ❌ Service completely unavailable (HTTP 5xx > 90%)
- ❌ Database unreachable
- ❌ All image conversions failing
- ❌ Security breach detected
- ❌ Data loss confirmed

#### Immediate Actions (First 15 minutes)

```bash
# 1. Assess the situation
kubectl get pods -n onboarding
kubectl get events -n onboarding --sort-by='.lastTimestamp'

# 2. Check service health
curl -s http://<LB_IP>/health | jq .

# 3. Check error rates
kubectl logs -n onboarding -l app=rest-api --tail=100 | grep -i error

# 4. Declare incident
# Send to Slack: #incidents-critical
# Page on-call engineer via PagerDuty
```

#### Response Team

| Role | Responsibility | Contact |
|------|---------------|---------|
| **Incident Commander** | Coordinate response, make decisions | On-call Lead |
| **Tech Lead** | Technical diagnosis and fix | Senior Engineer |
| **Communications** | Status updates, stakeholder comms | PM/Support |
| **Scribe** | Document timeline, actions | Rotating |

#### Resolution Steps

1. **Acknowledge** (0-5 min)
   - Acknowledge alert in PagerDuty
   - Join incident bridge: [Zoom Link]
   - Announce in #incidents-critical

2. **Assess** (5-15 min)
   - Gather initial data
   - Identify affected services
   - Estimate impact

3. **Mitigate** (15-60 min)
   - Implement immediate workaround if available
   - Consider rollback if recent deployment
   - Scale up resources if capacity issue

4. **Resolve** (1-4 hours)
   - Implement permanent fix
   - Verify all services healthy
   - Monitor for 30 minutes

5. **Close** (4+ hours)
   - Confirm resolution with stakeholders
   - Schedule post-incident review
   - Send incident summary

---

### SEV-2: High Priority Incident

#### Symptoms
- ⚠️ Error rate > 50% for > 5 minutes
- ⚠️ Latency p95 > 5s
- ⚠️ AI service unavailable
- ⚠️ Image conversion failures > 50%

#### Response Actions

```bash
# 1. Check metrics
kubectl top pods -n onboarding

# 2. Review recent changes
git log --oneline -10

# 3. Check dependencies
terraform output | grep -E "(converter|ai_generator)_url"

# 4. Review logs
kubectl logs -n onboarding -l app=rest-api --since=1h | tail -200
```

#### Resolution Timeline

| Time | Action |
|------|--------|
| 0-30 min | Diagnosis and initial mitigation |
| 30-60 min | Implement workaround or fix |
| 1-4 hours | Verify and monitor |
| 4-8 hours | Full resolution and documentation |

---

### SEV-3: Medium Priority

#### Symptoms
- ⚠️ Error rate 10-50%
- ⚠️ Latency p95 > 2s
- ⚠️ WCAG compliance < 90%
- ⚠️ Intermittent failures

#### Response Actions

1. Create ticket in Jira (Priority: High)
2. Assign to on-call engineer
3. Investigate during business hours
4. Implement fix within 24 hours
5. Monitor for 48 hours post-fix

---

### SEV-4: Low Priority

#### Symptoms
- ⚠️ Error rate < 10%
- ⚠️ Minor UI issues
- ⚠️ Documentation gaps
- ⚠️ Feature requests

#### Response Actions

1. Create ticket in Jira (Priority: Medium/Low)
2. Add to backlog
3. Address in next sprint
4. No immediate action required

---

## 📞 Escalation Matrix

### Level 1: On-Call Engineer

**Contact:** PagerDuty Rotation  
**Response:** 24/7  
**Scope:** Initial diagnosis, standard procedures

### Level 2: Senior Engineer / Tech Lead

**Contact:** [Phone/Slack]  
**Response:** < 30 minutes  
**Scope:** Complex technical issues, architecture decisions

### Level 3: Engineering Manager

**Contact:** [Phone/Slack]  
**Response:** < 1 hour  
**Scope:** Resource allocation, priority decisions

### Level 4: VP Engineering / CTO

**Contact:** [Phone]  
**Response:** < 2 hours  
**Scope:** Major incidents, customer-impacting issues, PR concerns

### External Escalation

| Vendor | Issue Type | Contact |
|--------|------------|---------|
| **Scaleway Support** | Infrastructure, Kapsule, Serverless | support@scaleway.com |
| **Qwen API** | AI service issues | api-support@qwen.ai |
| **PostgreSQL** | Database corruption | DBA Team |
| **Security Team** | Security incidents | security@example.com |

---

## 📢 Communication Templates

### Initial Incident Notification

```
🚨 INCIDENT ALERT - SEV-[1/2/3/4]

Service: Image Converter API
Status: Investigating
Impact: [Brief description of user impact]
Start Time: [YYYY-MM-DD HH:MM UTC]

Current Status:
- [ ] Incident declared
- [ ] Team assembled
- [ ] Investigation started
- [ ] Customers notified

Next Update: [Time]
Incident Channel: #incidents-[date]
```

### Status Update

```
📊 INCIDENT UPDATE - [Incident ID]

Status: [Investigating / Identified / Fixing / Monitoring / Resolved]

Summary:
[Brief technical summary of current state]

Actions Taken:
- [Action 1]
- [Action 2]

Next Steps:
- [Planned action 1]
- [Planned action 2]

ETA to Resolution: [Time estimate]

Next Update: [Time]
```

### Resolution Notification

```
✅ INCIDENT RESOLVED - [Incident ID]

Service: Image Converter API
Duration: [X hours Y minutes]
Impact: [Summary of user impact]

Root Cause:
[Brief description of what caused the incident]

Resolution:
[What was done to fix the issue]

Prevention:
[Steps being taken to prevent recurrence]

Post-Incident Review: [Date/Time]
Incident Report: [Link to post-mortem document]
```

---

## 📝 Post-Incident Review

### Timeline

- **SEV-1:** Within 48 hours
- **SEV-2:** Within 1 week
- **SEV-3:** Within 2 weeks
- **SEV-4:** As needed

### Attendees

- Incident Commander
- On-call engineer(s)
- Tech Lead
- Relevant team members
- Optional: Customers affected (for SEV-1)

### Agenda (60-90 minutes)

1. **Incident Summary** (10 min)
   - Timeline review
   - Impact assessment

2. **What Went Well** (10 min)
   - Positive actions
   - Good decisions

3. **What Went Wrong** (20 min)
   - Root cause analysis (5 Whys)
   - Contributing factors

4. **Action Items** (20 min)
   - Prevention measures
   - Detection improvements
   - Process improvements

5. **Follow-up** (10 min)
   - Assign owners
   - Set deadlines
   - Schedule follow-ups

### Post-Incident Report Template

```markdown
# Post-Incident Report: [Incident ID]

## Summary
- **Date:** YYYY-MM-DD
- **Duration:** X hours Y minutes
- **Severity:** SEV-[1/2/3/4]
- **Services Affected:** [List]
- **Users Affected:** [Estimate]

## Timeline
| Time | Event |
|------|-------|
| HH:MM | Incident started |
| HH:MM | Alert triggered |
| HH:MM | On-call acknowledged |
| HH:MM | Root cause identified |
| HH:MM | Fix deployed |
| HH:MM | Services restored |

## Root Cause
[Detailed description using 5 Whys technique]

## Impact
- [Quantified impact]
- [Customer complaints]
- [Revenue impact if applicable]

## What Went Well
- [Positive points]

## What Went Wrong
- [Issues identified]

## Action Items
| Action | Owner | Due Date | Status |
|--------|-------|----------|--------|
| [Action 1] | [Name] | [Date] | [ ] |
| [Action 2] | [Name] | [Date] | [ ] |

## Lessons Learned
- [Key takeaways]

## Appendix
- [Relevant logs, graphs, screenshots]
```

---

## 🔧 Maintenance Procedures

### Daily Checks

```bash
# 1. Service Health
curl -s http://<LB_IP>/health | jq .

# 2. Pod Status
kubectl get pods -n onboarding

# 3. Error Rate (last 24h)
kubectl logs -n onboarding -l app=rest-api --since=24h | grep -c "ERROR"

# 4. Disk Usage
kubectl top nodes

# 5. Check alerts
kubectl get alerts -n monitoring
```

**Frequency:** Automated (every 5 minutes via monitoring)  
**Owner:** On-call engineer  
**Escalation:** SEV-3 if any check fails

---

### Weekly Maintenance

#### Monday: Review Previous Week

- [ ] Review error rates and trends
- [ ] Check failed jobs and retries
- [ ] Review cost reports
- [ ] Check certificate expiration

```bash
# Cost check (last 7 days)
# Serverless invocations
# Qwen API calls
# Storage costs
```

#### Wednesday: Performance Review

- [ ] Check latency percentiles (p50, p95, p99)
- [ ] Review compression ratios
- [ ] Check AI confidence scores
- [ ] Analyze slow queries

```bash
# Latency check
kubectl top pods -n onboarding

# Database slow queries
psql -h <db-host> -U onboarding -c "SELECT * FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;"
```

#### Friday: Backup Verification

- [ ] Verify database backups completed
- [ ] Test backup restoration (monthly)
- [ ] Check S3 bucket replication
- [ ] Verify disaster recovery readiness

```bash
# Check latest backup
aws s3 ls s3://<backup-bucket>/postgresql/ --recursive | tail -5

# Verify backup integrity
# (Run monthly restoration test)
```

---

### Monthly Maintenance

#### Week 1: Security Review

- [ ] Review security scan results (Trivy, Snyk)
- [ ] Check for dependency updates
- [ ] Review access logs for anomalies
- [ ] Rotate service account tokens (quarterly)

```bash
# Run security scan
trivy image rg.fr-par.scw.cloud/<namespace>/rest-api:latest

# Check for outdated dependencies
pip list --outdated
```

#### Week 2: Performance Optimization

- [ ] Analyze query performance
- [ ] Review and optimize slow endpoints
- [ ] Check index usage
- [ ] Review caching effectiveness

```bash
# Check database indexes
psql -h <db-host> -U onboarding -c "SELECT schemaname, tablename, indexname FROM pg_indexes WHERE schemaname = 'public';"

# Analyze table statistics
psql -h <db-host> -U onboarding -c "ANALYZE VERBOSE;"
```

#### Week 3: Capacity Planning

- [ ] Review resource utilization trends
- [ ] Forecast growth for next quarter
- [ ] Plan capacity upgrades if needed
- [ ] Review and adjust auto-scaling thresholds

```bash
# Resource usage trends (last 30 days)
# CPU, Memory, Storage, Network
# Compare against billing projections
```

#### Week 4: Disaster Recovery Test

- [ ] Test failover procedures (quarterly)
- [ ] Verify backup restoration
- [ ] Update runbooks if needed
- [ ] Conduct tabletop exercise (quarterly)

---

### Quarterly Maintenance

#### Q1, Q2, Q3, Q4: Major Reviews

- [ ] **Security Audit:** Full OWASP compliance check
- [ ] **Penetration Test:** External security firm
- [ ] **Disaster Recovery Drill:** Full failover test
- [ ] **Cost Optimization:** Review and right-size resources
- [ ] **Documentation Review:** Update all runbooks and docs
- [ ] **Training:** Team training on new features/procedures

---

## 📞 Contact Information

### On-Call Schedule

| Week | Primary | Secondary |
|------|---------|-----------|
| Week 1 | [Name] | [Name] |
| Week 2 | [Name] | [Name] |
| Week 3 | [Name] | [Name] |
| Week 4 | [Name] | [Name] |

**Rotation starts:** First Monday of each month  
**Handover:** Monday 9:00 AM CET  
**Contact:** oncall@example.com

### Emergency Contacts

| Role | Name | Phone | Email |
|------|------|-------|-------|
| **On-Call Lead** | [Name] | +33-X-XXXX | oncall@example.com |
| **Tech Lead** | [Name] | +33-X-XXXX | tech-lead@example.com |
| **Engineering Manager** | [Name] | +33-X-XXXX | eng-manager@example.com |
| **VP Engineering** | [Name] | +33-X-XXXX | vp-eng@example.com |
| **Security Lead** | [Name] | +33-X-XXXX | security@example.com |

### External Support

| Vendor | Support Level | Contact | SLA |
|--------|--------------|---------|-----|
| **Scaleway** | Business | support@scaleway.com | 4h response |
| **Qwen API** | Enterprise | api-support@qwen.ai | 2h response |
| **PagerDuty** | Standard | support@pagerduty.com | 24h response |
| **Sentry** | Team | support@sentry.io | 24h response |

---

## 📚 Related Documents

- [Architecture Overview](../../README.md#architecture-overview)
- [API Documentation](../api/openapi.yaml)
- [Disaster Recovery Plan](../../DISASTER_RECOVERY.md)
- [Security Audit Report](../../SECURITY_AUDIT.md)
- [Monitoring Setup](../../k8s/monitoring.yaml)
- [Backup Procedures](./02-backup-restore.md)

---

## 📊 Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0 | 2024-XX-XX | [Your Name] | Initial version |
| | | | |

---

**Document Owner:** Platform Team  
**Review Cycle:** Quarterly  
**Next Review:** [Date]  
**Approved By:** [Engineering Manager Name]