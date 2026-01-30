# CloudDrop Monitoring & Alerting Stack

## Overview

Modern monitoring stack for homelab/self-hosted Kubernetes using:
- **Prometheus** - Metrics collection and storage
- **Alertmanager** - Alert routing and management
- **Grafana** - Visualization and dashboards
- **Loki** - Log aggregation
- **Discord** - Notification channel with ChatOps

## Quick Start

### 1. Fix Prometheus CrashLoopBackOff

The Prometheus startup probe timeout has been increased to 30 minutes to handle large WAL replay:

```bash
# Apply the configuration
task configure
git add kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml
git commit -m "fix: increase Prometheus startup probe timeout"
git push
task reconcile

# Monitor recovery (may take up to 30 minutes)
kubectl logs -n observability prometheus-kube-prometheus-stack-0 -c prometheus -f
```

### 2. Set Up Discord Webhooks

#### Create Discord Webhook:
1. Go to your Discord server settings → Integrations → Webhooks
2. Click "New Webhook"
3. Name it "CloudDrop Alerts"
4. Select the channel for alerts
5. Copy the webhook URL

#### Configure Alertmanager:
```bash
# Edit the alertmanager secret
sops kubernetes/apps/observability/kube-prometheus-stack/app/alertmanager-secret.sops.yaml

# Replace ALL instances of 'DISCORD_WEBHOOK_URL_PLACEHOLDER' with your webhook URL
# Save and encrypt
```

### 3. Deploy Configuration

```bash
# Encrypt secrets
sops --encrypt --in-place kubernetes/apps/observability/kube-prometheus-stack/app/alertmanager-secret.sops.yaml

# Verify encryption
grep -q "sops:" kubernetes/apps/observability/kube-prometheus-stack/app/alertmanager-secret.sops.yaml && echo "✅ Encrypted" || echo "❌ NOT ENCRYPTED!"

# Apply changes
task configure
git add kubernetes/apps/observability/
git commit -m "feat: add Discord alerting with homelab rules"
git push
task reconcile
```

### 4. Verify Alertmanager

```bash
# Check Alertmanager status
kubectl get pods -n observability -l app.kubernetes.io/name=alertmanager

# Check configuration
kubectl logs -n observability alertmanager-kube-prometheus-stack-0 | grep -i "discord\|loaded"

# Test alert (fire a test alert)
kubectl run test-alert --rm -it --restart=Never --image=curlimages/curl:latest -- \
  curl -X POST http://alertmanager-operated.observability.svc:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"info"},"annotations":{"summary":"Test alert from kubectl"}}]'
```

## Alert Rules

The following alert rules are configured:

### Critical Alerts (🚨)
- **NodeDown** - Node unavailable for 5+ minutes
- **NodeDiskSpaceCritical** - Disk space < 5%
- **PersistentVolumeErrors** - Storage reporting errors
- **PrometheusNotIngestingSamples** - Prometheus stopped collecting metrics

### Infrastructure Alerts (🏗️)
- **NodeHighCPU** - CPU usage > 85% for 15 minutes
- **NodeHighMemory** - Available memory < 10%
- **NodeDiskSpaceLow** - Disk space < 15%
- **KubePodCrashLooping** - Pod restarting repeatedly
- **KubePodNotReady** - Pod not ready for 15+ minutes
- **KubeDeploymentReplicasMismatch** - Deployment replicas not matching
- **KubeStatefulSetReplicasMismatch** - StatefulSet replicas not matching

### GitOps Alerts (🔄)
- **FluxReconciliationFailure** - Flux resource failing to reconcile
- **FluxSuspendedResource** - Flux resource suspended for 1+ hour

### Storage Alerts (💾)
- **KubePersistentVolumeFillingUp** - PVC < 15% available space

### Application Alerts
- **ContainerOOMKilled** - Container killed due to out of memory
- **ContainerHighMemoryUsage** - Container using > 90% of memory limit

## Discord Alert Channels

Alerts are routed to different Discord channels based on severity:

| Channel | Severity | Examples |
|---------|----------|----------|
| **discord-critical** | Critical | Node down, disk full, Prometheus down |
| **discord-infra** | Infrastructure | High CPU/memory, pod crashes |
| **discord-gitops** | GitOps | Flux reconciliation failures |
| **discord-storage** | Storage | PVC filling up |
| **discord** | Default | All other alerts |

## Accessing UIs

```bash
# Prometheus
open https://prometheus.${SECRET_DOMAIN}

# Alertmanager
open https://alertmanager.${SECRET_DOMAIN}

# Grafana
open https://grafana.${SECRET_DOMAIN}
```

## Grafana Dashboards

Pre-installed dashboards:
- **Node Exporter Full** - Detailed node metrics
- **Kubernetes Cluster Monitoring** - Cluster overview
- **Kubernetes Pods** - Pod metrics and logs
- **Flux Control Plane** - GitOps monitoring
- **Prometheus Stats** - Prometheus internal metrics

## ChatOps Commands (Future)

Once the Discord bot is configured:
- `/alerts` - List active alerts
- `/silence <alertname> <duration>` - Silence an alert
- `/ack <alertname>` - Acknowledge an alert
- `/status prometheus` - Check Prometheus status
- `/status flux` - Check Flux status

## Customization

### Add Custom Alert Rules

Create a new PrometheusRule in `kubernetes/apps/observability/kube-prometheus-stack/app/`:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: custom-alerts
  namespace: observability
spec:
  groups:
    - name: custom
      interval: 1m
      rules:
        - alert: MyCustomAlert
          expr: my_metric > threshold
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "My alert summary"
            description: "Detailed description"
```

### Modify Alert Routing

Edit `alertmanager-secret.sops.yaml` to change routing logic, add new receivers, or modify inhibition rules.

### Change Retention Period

Edit `helmrelease.yaml`:
```yaml
prometheus:
  prometheusSpec:
    retention: 30d  # Default: 14d
    retentionSize: 80GB  # Default: 40GB
```

## Troubleshooting

### Prometheus Still Crashing
```bash
# Check logs for specific error
kubectl logs -n observability prometheus-kube-prometheus-stack-0 -c prometheus --tail=100

# If WAL is corrupted, you may need to delete and recreate
kubectl delete pod -n observability prometheus-kube-prometheus-stack-0
```

### Alerts Not Arriving in Discord
```bash
# Check Alertmanager logs
kubectl logs -n observability alertmanager-kube-prometheus-stack-0

# Verify webhook URL is correct
kubectl get secret -n observability alertmanager-secret -o yaml | grep webhook

# Test webhook manually
curl -X POST 'YOUR_WEBHOOK_URL' \
  -H 'Content-Type: application/json' \
  -d '{"content": "Test from curl"}'
```

### High Memory Usage
```bash
# Reduce retention or sample rate
# Edit helmrelease.yaml and reduce retention period
# Or reduce scrape frequency in ServiceMonitors
```

## Next Steps

1. ✅ Fix Prometheus CrashLoopBackOff
2. ✅ Configure Discord webhooks
3. ✅ Deploy alert rules
4. 🔲 Add custom Grafana dashboards
5. 🔲 Configure Loki log retention
6. 🔲 Set up Uptime Kuma for external monitoring
7. 🔲 Implement Discord ChatOps bot

## Resources

- [Prometheus Operator Docs](https://prometheus-operator.dev/)
- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
- [Discord Webhooks Guide](https://discord.com/developers/docs/resources/webhook)
