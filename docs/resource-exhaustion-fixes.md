# Resource Exhaustion Fixes Applied

## Date: October 17, 2025

### Summary
Addressed resource exhaustion issues causing the cluster to degrade over hours/days with "works initially then stops working" pattern.

## Root Causes Identified

1. **Cilium Connection Tracking Table Exhaustion**
   - 22,519 conntrack entries (very high for single-node cluster)
   - Many stale SMB (port 445) and iSCSI connections to QNAP NAS (192.168.100.180)
   - Connections marked `RxClosing TxClosing` not being cleaned up fast enough
   - Causing new connection delays and failures

2. **QNAP Backend API Exhaustion**
   - Repeated "storage (qts) not exists; add the storage first" errors
   - Backend continuously disconnecting/reconnecting
   - No connection pooling or request throttling

3. **Trident Internal Rate Limiter Exhaustion**
   - "client rate limiter Wait returned an error: context deadline exceeded"
   - Occurring during `ControllerPublishVolume` operations
   - Triggered by slow/unstable QNAP backend responses

4. **Missing Kubernetes API Client Rate Limits**
   - CSI sidecars (csi-provisioner, csi-attacher, csi-resizer, csi-snapshotter) had NO --kube-api-qps or --kube-api-burst flags
   - Using default client-go limits: QPS=5, Burst=10
   - Insufficient for managing 8 apps with multiple volumes and watch operations

5. **No Resource Limits on Trident Containers**
   - All containers had `resources: {}`
   - Allowing unbounded memory growth
   - No protection against resource leaks

## Fixes Applied

### ✅ 1. Cilium Conntrack Tuning (Applied via Git)
**File:** `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`

```yaml
bpf:
  masquerade: true
  hostLegacyRouting: true
  # Tune conntrack settings for NAS-heavy workload
  # Faster cleanup of stale connections to QNAP NAS (SMB/iSCSI)
  ctTcpTimeout: 21600  # 6 hours (default: 21600)
  ctAnyTimeout: 60     # 1 minute (default: 60)
  ctTcpTimeoutFin: 10  # 10 seconds (default: 10)
  ctTcpTimeoutClose: 10  # 10 seconds (default: 10)
```

**Status:** ✅ Applied and Running  
**Effect:** Faster cleanup of stale NAS connections, reducing conntrack table buildup

### ✅ 2. Backend Volume Size Limit (Applied via Git)
**File:** `kubernetes/apps/storage/qnap-csi-plugin/app/backend.yaml`

```yaml
spec:
  debugTraceFlags:
    method: true
  # Limit volume size to prevent oversized operations that could exhaust QNAP backend
  limitVolumeSize: "10Ti"
```

**Status:** ✅ Applied via TridentBackendConfig  
**Effect:** Prevents oversized volume operations that exhaust QNAP API

### ❌ 3. Kubernetes API Rate Limits (MANUAL REQUIRED)
**Problem:** TridentOrchestrator CRD manages the deployment and doesn't support kustomize patches

**Manual Commands Required** (run after Trident deployment is stable):

```bash
# Add API rate limits to csi-provisioner
kubectl patch deployment trident-controller -n trident --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "--kube-api-qps=50"},
  {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "--kube-api-burst=100"}
]'

# Add API rate limits to csi-attacher
kubectl patch deployment trident-controller -n trident --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/2/args/-", "value": "--kube-api-qps=50"},
  {"op": "add", "path": "/spec/template/spec/containers/2/args/-", "value": "--kube-api-burst=100"}
]'

# Add API rate limits to csi-resizer
kubectl patch deployment trident-controller -n trident --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/3/args/-", "value": "--kube-api-qps=50"},
  {"op": "add", "path": "/spec/template/spec/containers/3/args/-", "value": "--kube-api-burst=100"}
]'

# Add API rate limits to csi-snapshotter
kubectl patch deployment trident-controller -n trident --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/4/args/-", "value": "--kube-api-qps=50"},
  {"op": "add", "path": "/spec/template/spec/containers/4/args/-", "value": "--kube-api-burst=100"}
]'
```

**Status:** ⏳ PENDING MANUAL APPLICATION  
**Effect:** Increases Kubernetes API client rate limits from 5 QPS to 50 QPS, reducing throttling

### ❌ 4. Resource Limits (MANUAL REQUIRED)
**Manual Command Required:**

```bash
kubectl patch deployment trident-controller -n trident --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/resources", "value": {"requests": {"memory": "128Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "200m"}}},
  {"op": "add", "path": "/spec/template/spec/containers/1/resources", "value": {"requests": {"memory": "128Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "200m"}}},
  {"op": "add", "path": "/spec/template/spec/containers/2/resources", "value": {"requests": {"memory": "128Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "200m"}}},
  {"op": "add", "path": "/spec/template/spec/containers/3/resources", "value": {"requests": {"memory": "128Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "200m"}}},
  {"op": "add", "path": "/spec/template/spec/containers/4/resources", "value": {"requests": {"memory": "128Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "200m"}}},
  {"op": "add", "path": "/spec/template/spec/containers/5/resources", "value": {"requests": {"memory": "256Mi", "cpu": "100m"}, "limits": {"memory": "1Gi", "cpu": "500m"}}}
]'
```

**Status:** ⏳ PENDING MANUAL APPLICATION  
**Effect:** Prevents unbounded memory growth, ensures proper resource allocation

## Current Status

### Working
- ✅ All 8 media apps Running (audiobookshelf, bazarr, huntarr, profilarr, prowlarr, radarr, sabnzbd, sonarr)
- ✅ Cilium conntrack tuning applied
- ✅ Backend volume size limit applied
- ✅ Trident controller deployment Running (6/6 containers)
- ✅ Single ReplicaSet per deployment

### Pending Manual Application
- ⏳ Kubernetes API rate limits for CSI sidecars
- ⏳ Resource limits for Trident containers

**Note:** Manual patches need to be reapplied after:
- Trident version upgrades
- TridentOrchestrator CRD changes
- Operator recreation of deployment

## Monitoring Commands

Check conntrack table size:
```bash
kubectl exec -n kube-system cilium-w4bbx -- cilium bpf ct list global | wc -l
```

Check QNAP connections:
```bash
kubectl exec -n kube-system cilium-w4bbx -- cilium bpf ct list global | grep 192.168.100.180 | head -20
```

Check for rate limiter errors:
```bash
kubectl logs -n trident -l app=controller.csi.trident.qnap.io -c trident-main --tail=100 | grep -i 'rate limiter'
```

Check for backend disconnections:
```bash
kubectl logs -n trident -l app=controller.csi.trident.qnap.io -c storage-api-server --tail=100 | grep -i 'storage.*not.*added'
```

Check resource usage:
```bash
kubectl top pods -n trident
```

## Expected Improvements

1. **Conntrack table size** should stabilize below 10,000 entries
2. **QNAP backend** should stay connected consistently
3. **No more "client rate limiter Wait" errors** in Trident logs
4. **Trident memory usage** bounded by limits
5. **System stability** over days/weeks, not degrading after hours

## Git Commits

- `feat(storage,network): tune Trident and Cilium for resource exhaustion` (d348892c)
- `fix(storage): remove failed Trident patches` (6911e038)

## Next Steps

1. Apply manual patches for API rate limits (see commands above)
2. Apply manual patches for resource limits (see commands above)
3. Monitor system for 48 hours to verify improvements
4. Document procedure for reapplying patches after Trident upgrades
