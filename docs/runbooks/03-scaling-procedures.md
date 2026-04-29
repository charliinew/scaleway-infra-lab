# Runbook 03: Scaling Procedures

**Version:** 1.0  
**Last Updated:** 2025-01-09  
**Owner:** Platform Team  
**Severity:** P1 (Operational)

---

## 1. Overview

This runbook covers scaling procedures for the image converter platform, including automatic scaling, manual scaling, and emergency scaling scenarios.

### Architecture Components

| Component | Scaling Method | Min | Max | Scale-to-Zero |
|-----------|---------------|-----|-----|---------------|
| **REST API (K8s)** | HPA (CPU/Memory) | 2 | 10 | ❌ No |
| **Image Converter (Serverless)** | Request-based | 0 | 10 | ✅ Yes |
| **AI Alt-Generator (Serverless)** | Request-based | 0 | 10 | ✅ Yes |
| **K8s Node Pool** | Cluster Autoscaler | 1 | 5 | ❌ No |

---

## 2. Automatic Scaling

### 2.1 REST API Horizontal Pod Autoscaler (HPA)

The REST API deployment uses HPA for automatic scaling based on CPU and memory metrics.

#### Configuration

```yaml
# k8s/deployment.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rest-api-hpa
  namespace: onboarding
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rest-api
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

#### Monitoring HPA Status

```bash
# Check HPA current status
kubectl get hpa rest-api-hpa -n onboarding

# Detailed HPA information
kubectl describe hpa rest-api-hpa -n onboarding

# Watch HPA in real-time
kubectl get hpa rest-api-hpa -n onboarding --watch
```

#### Expected Behavior

| Metric | Current | Target | Action |
|--------|---------|--------|--------|
| CPU Usage | >70% | 70% | Scale UP (+1 pod) |
| CPU Usage | <30% | 70% | Scale DOWN (-1 pod) |
| Memory Usage | >80% | 80% | Scale UP (+1 pod) |
| Memory Usage | <40% | 80% | Scale DOWN (-1 pod) |

#### Troubleshooting HPA

**Problem:** HPA not scaling up

```bash
# Check metrics-server
kubectl get pods -n kube-system | grep metrics-server

# Check if metrics are available
kubectl top pods -n onboarding

# Check HPA events
kubectl describe hpa rest-api-hpa -n onboarding | grep -A 10 Events

# Check resource requests/limits
kubectl get deployment rest-api -n onboarding -o yaml | grep -A 10 resources
```

**Problem:** HPA scaling too aggressively

```bash
# Adjust stabilization window
kubectl patch hpa rest-api-hpa -n onboarding --type='json' -p='[
  {"op": "add", "path": "/spec/behavior/scaleDown/stabilizationWindowSeconds", "value": 300}
]'
```

### 2.2 Serverless Containers Auto-Scaling

Serverless Containers automatically scale based on incoming requests.

#### Configuration

```hcl
# terraform/serverless.tf
resource "scaleway_container" "image_converter" {
  name         = "image-converter"
  namespace_id = scaleway_container_namespace.main.id
  registry_image = "rg.fr-par.scw.cloud/${var.registry_namespace}/image-converter:latest"
  
  # Scaling configuration
  min_scale   = 0  # Scale to zero when idle
  max_scale   = 10 # Maximum concurrent instances
  cpu_limit   = 1000 # 1 CPU core
  memory_limit = 512 # 512MB RAM
  
  # Scale based on concurrent requests
  scale_on_requests = true
  requests_per_second_threshold = 10
}
```

#### Monitoring Serverless Scaling

```bash
# Check container status
scw container function get <function-id>

# Check scaling metrics
scw container function metrics get <function-id> --period 1h

# View active instances
scw container function list --namespace <namespace-id>
```

---

## 3. Manual Scaling

### 3.1 Scale REST API Deployment

#### Scale Up (Planned Traffic Increase)

```bash
# Check current replicas
kubectl get deployment rest-api -n onboarding

# Scale to specific replica count
kubectl scale deployment rest-api --replicas=5 -n onboarding

# Verify scaling
kubectl get pods -l app=rest-api -n onboarding
```

#### Scale Down (Cost Optimization)

```bash
# Scale down to minimum
kubectl scale deployment rest-api --replicas=2 -n onboarding

# Verify no active requests first
kubectl top pods -n onboarding
```

### 3.2 Scale Node Pool

#### Add More Nodes

```bash
# Check current node pool size
scw k8s pool get <pool-id>

# Update node pool size
scw k8s pool update <pool-id> \
  --size 4 \
  --min-size 2 \
  --max-size 6

# Or via Terraform
terraform -c 'variable "node_pool_size" { default = 4 }'
terraform apply -target=scaleway_k8s_pool.default
```

#### Emergency Node Addition

```bash
# Add nodes immediately (bypass Terraform)
scw k8s pool upgrade <pool-id> --size 5

# Wait for nodes to be ready
kubectl get nodes --watch
```

### 3.3 Scale Serverless Containers

#### Adjust Min/Max Scale

```bash
# Update minimum scale (prevent scale-to-zero)
scw container function update <function-id> --min-scale 2

# Update maximum scale (handle more traffic)
scw container function update <function-id> --max-scale 20

# Update CPU/memory limits
scw container function update <function-id> \
  --cpu-limit 2000 \
  --memory-limit 1024
```

---

## 4. Emergency Scaling

### 4.1 Traffic Spike Response

**Trigger:** CPU/Memory >90% for 5+ minutes, error rate >5%

#### Immediate Actions (0-5 minutes)

```bash
# 1. Scale REST API immediately
kubectl scale deployment rest-api --replicas=10 -n onboarding

# 2. Scale node pool
scw k8s pool update <pool-id> --size 5 --min-size 3

# 3. Increase Serverless max scale
scw container function update <converter-id> --max-scale 20
scw container function update <ai-generator-id> --max-scale 20

# 4. Check Load Balancer metrics
scw lb backend get <backend-id>
```

#### Secondary Actions (5-15 minutes)

```bash
# 5. Enable rate limiting (if not already)
kubectl patch configmap onboarding-config -n onboarding --type='json' -p='[
  {"op": "replace", "path": "/data/RATE_LIMIT_ENABLED", "value": "true"}
]'

# 6. Check database connections
kubectl exec -it <db-pod> -- psql -c "SELECT count(*) FROM pg_stat_activity;"

# 7. Review error logs
kubectl logs -l app=rest-api -n onboarding --tail=1000 | grep -i error
```

#### Stabilization (15-30 minutes)

```bash
# 8. Monitor metrics
watch kubectl top pods -n onboarding

# 9. Check HPA status
kubectl get hpa -n onboarding

# 10. Verify error rate normalized
curl http://<LB_IP>/metrics | grep error_rate
```

### 4.2 Resource Exhaustion Response

**Trigger:** OOMKilled pods, node pressure, disk full

#### Memory Pressure

```bash
# 1. Check memory usage
kubectl top pods -n onboarding

# 2. Identify memory leaks
kubectl describe pod <pod-name> -n onboarding | grep -A 5 "Last State"

# 3. Increase memory limits temporarily
kubectl set resources deployment rest-api \
  -n onboarding \
  --requests=memory=512Mi \
  --limits=memory=1Gi

# 4. Restart pods
kubectl rollout restart deployment rest-api -n onboarding
```

#### CPU Throttling

```bash
# 1. Check CPU throttling
kubectl describe node <node-name> | grep -A 10 "Allocated resources"

# 2. Increase CPU limits
kubectl set resources deployment rest-api \
  -n onboarding \
  --requests=cpu=500m \
  --limits=cpu=1000m

# 3. Add more nodes
scw k8s pool update <pool-id> --size 5
```

#### Disk Pressure

```bash
# 1. Check disk usage
kubectl describe node <node-name> | grep -A 5 "Conditions"

# 2. Clean up old images
ssh <node-ip> "docker image prune -af"

# 3. Remove old logs
ssh <node-ip> "journalctl --vacuum-time=1d"

# 4. Add nodes with larger disks
terraform apply -target=scaleway_k8s_pool.default \
  -var 'node_root_volume_size=50'
```

---

## 5. Scheduled Scaling

### 5.1 Business Hours Scaling

For predictable traffic patterns (e.g., business hours 9AM-6PM):

#### CronJob Approach

```yaml
# k8s/cronjob-scale-up.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-up-business-hours
  namespace: onboarding
spec:
  schedule: "0 8 * * 1-5"  # 8AM weekdays
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: kubectl
            image: bitnami/kubectl:latest
            command:
            - kubectl
            - scale
            - deployment/rest-api
            - --replicas=5
            - -n
            - onboarding
          restartPolicy: OnFailure
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-down-evening
  namespace: onboarding
spec:
  schedule: "0 18 * * 1-5"  # 6PM weekdays
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: kubectl
            image: bitnami/kubectl:latest
            command:
            - kubectl
            - scale
            - deployment/rest-api
            - --replicas=2
            - -n
            - onboarding
          restartPolicy: OnFailure
```

#### Apply CronJobs

```bash
kubectl apply -f k8s/cronjob-scale-up.yaml
kubectl apply -f k8s/cronjob-scale-down.yaml

# Verify
kubectl get cronjobs -n onboarding
```

### 5.2 Weekend Scaling

```bash
# Scale down for weekends (Friday 6PM)
scw k8s pool update <pool-id> --min-size 1 --size 1

# Scale up for Monday (Monday 8AM)
scw k8s pool update <pool-id> --min-size 2 --size 3
```

---

## 6. Cost Optimization Scaling

### 6.1 Scale-to-Zero Configuration

Serverless Containers support true scale-to-zero (€0 when idle):

```bash
# Enable scale-to-zero for low-traffic periods
scw container function update image-converter --min-scale 0
scw container function update ai-alt-generator --min-scale 0

# Cold start mitigation: keep 1 instance during business hours
# See CronJob approach above
```

### 6.2 Node Pool Rightsizing

```bash
# Analyze actual resource usage
kubectl top nodes
kubectl top pods -n onboarding

# Downsize if over-provisioned
scw k8s pool update default-pool \
  --node-type DEV1-S  # Instead of DEV1-M
  --size 2
  --min-size 1

# Enable spot instances for cost savings
scw k8s pool update default-pool --placement-group-enabled
```

### 6.3 HPA Tuning for Cost

```yaml
# More conservative scaling (reduce costs)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rest-api-hpa
spec:
  minReplicas: 2
  maxReplicas: 5  # Lower max to reduce costs
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80  # Higher threshold = fewer pods
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 600  # Wait 10min before scaling down
      policies:
      - type: Percent
        value: 50
        periodSeconds: 300
```

---

## 7. Monitoring & Metrics

### 7.1 Key Metrics to Watch

| Metric | Source | Warning | Critical |
|--------|--------|---------|----------|
| **Pod CPU Usage** | Prometheus | >70% | >90% |
| **Pod Memory Usage** | Prometheus | >80% | >95% |
| **Node CPU Usage** | Prometheus | >75% | >90% |
| **Node Memory Usage** | Prometheus | >85% | >95% |
| **Request Latency p95** | Prometheus | >2s | >5s |
| **Error Rate** | Prometheus | >1% | >5% |
| **HPA Current Replicas** | Kubernetes | Max-1 | Max |
| **Serverless Cold Starts** | Scaleway API | >10/hour | >50/hour |

### 7.2 Grafana Dashboards

Access Grafana at `http://grafana.internal:3000`

| Dashboard | Purpose | URL |
|-----------|---------|-----|
| **Cluster Overview** | Node & pod metrics | `/d/cluster-overview` |
| **HPA Metrics** | Autoscaling status | `/d/hpa-metrics` |
| **Serverless Metrics** | Container scaling | `/d/serverless` |
| **Business Metrics** | Uploads, conversions | `/d/business` |

### 7.3 Alert Rules

```yaml
# k8s/alerting.yaml
groups:
- name: scaling
  rules:
  - alert: HighPodCPU
    expr: avg(rate(container_cpu_usage_seconds_total[5m])) > 0.8
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Pod CPU usage high"
      description: "Average CPU usage is {{ $value | humanizePercentage }}"
  
  - alert: HPAAtMaxReplicas
    expr: kube_hpa_status_current_replicas == kube_hpa_spec_max_replicas
    for: 10m
    labels:
      severity: critical
    annotations:
      summary: "HPA at maximum replicas"
      description: "HPA {{ $labels.hpa }} is at maximum capacity"
```

---

## 8. Testing Scaling Procedures

### 8.1 Load Test Scaling

```bash
# Install Hey (load testing tool)
go install github.com/rakyll/hey@latest

# Simulate traffic spike
hey -z 10m -c 100 http://<LB_IP>/upload

# Watch HPA scale up
watch kubectl get hpa -n onboarding

# Verify new pods spawn
watch kubectl get pods -n onboarding
```

### 8.2 Chaos Engineering

```bash
# Install Chaos Mesh (optional)
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace=chaos-testing \
  --create-namespace

# Create pod failure experiment
cat <<EOF | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: delete-rest-api-pod
  namespace: onboarding
spec:
  action: pod-failure
  mode: one
  duration: 2m
  selector:
    namespaces:
    - onboarding
    labelSelectors:
      app: rest-api
EOF

# Watch HPA replace the pod
kubectl get pods -n onboarding --watch
```

---

## 9. Troubleshooting

### 9.1 Common Issues

#### Pods Not Scaling Up

**Symptoms:** HPA shows desired replicas > current replicas, but no new pods

```bash
# Check node resources
kubectl describe nodes | grep -A 10 "Allocated resources"

# Check pod scheduling
kubectl get events -n onboarding --field-selector reason=FailedScheduling

# Check resource quotas
kubectl describe quota -n onboarding

# Solution: Add more nodes or increase quotas
```

#### Scale-to-Zero Not Working

**Symptoms:** Serverless container stays at min_scale=1

```bash
# Check container configuration
scw container function get <function-id>

# Verify no pending requests
scw container function logs <function-id>

# Check for health check configuration
# Health checks prevent scale-to-zero if failing

# Solution: Fix health checks or adjust min_scale
```

#### Oscillating Scaling (Flapping)

**Symptoms:** Pods constantly scaling up and down

```bash
# Check HPA behavior configuration
kubectl get hpa rest-api-hpa -n onboarding -o yaml

# Add stabilization window
kubectl patch hpa rest-api-hpa -n onboarding --type='merge' -p='
{
  "spec": {
    "behavior": {
      "scaleDown": {
        "stabilizationWindowSeconds": 300
      },
      "scaleUp": {
        "stabilizationWindowSeconds": 60
      }
    }
  }
}'
```

### 9.2 Emergency Contacts

| Issue | Contact | Escalation |
|-------|---------|------------|
| HPA not working | Platform Team | 15 minutes |
| Node pool exhausted | Platform Team | 15 minutes |
| Serverless scaling issues | API Team | 30 minutes |
| Cost concerns | FinOps Team | 1 hour |

---

## 10. Post-Scaling Review

### 10.1 After Action Report Template

After any significant scaling event, document:

```markdown
## Scaling Event Report

**Date:** YYYY-MM-DD HH:MM  
**Trigger:** (e.g., Traffic spike, scheduled event, emergency)  
**Duration:** X minutes  
**Impact:** (e.g., No downtime, 5% error rate for 2 minutes)

### Timeline

- HH:MM - Alert triggered
- HH:MM - Investigation started
- HH:MM - Scaling action taken
- HH:MM - Situation stabilized

### Metrics

| Metric | Before | Peak | After |
|--------|--------|------|-------|
| Replicas | 2 | 10 | 2 |
| CPU Usage | 30% | 95% | 40% |
| Error Rate | 0.1% | 5% | 0.1% |

### Lessons Learned

1. What worked well
2. What didn't work
3. Improvements needed

### Action Items

- [ ] Update HPA thresholds
- [ ] Add more monitoring
- [ ] Update runbook
```

---

## Appendix A: Quick Reference Commands

```bash
# === CHECK CURRENT STATE ===
kubectl get hpa -n onboarding
kubectl get pods -n onboarding
kubectl top nodes
kubectl top pods -n onboarding
scw k8s pool list
scw container function list

# === SCALE REST API ===
kubectl scale deployment rest-api --replicas=5 -n onboarding

# === SCALE NODE POOL ===
scw k8s pool update <pool-id> --size 4 --min-size 2 --max-size 6

# === SCALE SERVERLESS ===
scw container function update <function-id> --min-scale 0 --max-scale 10

# === MONITOR ===
watch kubectl get hpa -n onboarding
watch kubectl get pods -n onboarding
kubectl logs -l app=rest-api -n onboarding --tail=100 -f
```

---

## Appendix B: Scaling Limits

| Resource | Default Limit | Soft Limit | Hard Limit |
|----------|--------------|------------|------------|
| **K8s Pods per Cluster** | 150 | 500 | 1000 |
| **K8s Pods per Node** | 20 | 50 | 110 |
| **Serverless Containers** | 10 | 20 | 50 |
| **Serverless Concurrent Requests** | 100 | 500 | 1000 |
| **Load Balancer Backend** | 20 | 50 | 100 |

---

**Review Cycle:** Quarterly  
**Next Review:** 2025-04-09  
**Approved By:** Platform Team Lead