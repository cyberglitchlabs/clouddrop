# Performance Tuning Summary

**Date**: October 17, 2025
**Commit**: 713ec92d

## Overview

Comprehensive performance optimizations applied to the cluster for NAS-heavy workloads. These changes complement the earlier resource exhaustion fixes and provide long-term performance improvements.

---

## Applied Changes

### 1. ✅ Cilium eBPF Map Sizing

**Status**: Applied via Flux (HelmRelease upgraded successfully)

**Configuration** (`kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`):
```yaml
bpf:
  mapMax:
    ct:
      tcp: 524288  # 512k TCP entries (up from 256k default)
      any: 262144  # 256k non-TCP entries (up from 128k default)
    nat: 262144    # 256k NAT entries (up from 128k default)
```

**Benefits**:
- Prevents eBPF map exhaustion under high connection load
- Prepares cluster for connection spikes beyond current ~4,500 entries
- Minimal memory overhead (~50MB additional per node)

**Verification**:
```bash
kubectl get helmrelease cilium -n kube-system
# Should show Ready status with chart version 1.18.2
```

---

### 2. ✅ Talos Linux System Tuning

**Status**: Configured (requires node upgrade/reboot to apply)

**Configuration** (`talos/patches/global/machine-sysctls.yaml`):
```yaml
# TCP tuning for long-lived NAS connections
net.ipv4.tcp_keepalive_time: "600"       # Send keepalive after 10min (down from 2h)
net.ipv4.tcp_keepalive_intvl: "60"       # Retry every 60s
net.ipv4.tcp_keepalive_probes: "3"       # 3 failed probes = dead connection
net.ipv4.tcp_fin_timeout: "30"           # Faster FIN-WAIT-2 cleanup (down from 60s)

# Network capacity
net.core.netdev_max_backlog: "5000"      # Increase packet queue
net.ipv4.tcp_max_syn_backlog: "8192"     # Increase SYN queue

# File descriptors for storage operations
fs.file-max: "2097152"                   # Increase max file descriptors (2M)
```

**Benefits**:
- Faster detection of dead NAS connections (10 minutes vs 2 hours)
- Complements Cilium conntrack tuning at the kernel level
- Improved capacity for concurrent connections and file operations

**Apply Changes**:
```bash
# Option 1: Upgrade Talos (applies new machine config)
talosctl --talosconfig talos/clusterconfig/talosconfig \
  --nodes 192.168.42.254 upgrade

# Option 2: Simple reboot (if config is already updated)
talosctl --talosconfig talos/clusterconfig/talosconfig \
  --nodes 192.168.42.254 reboot
```

**Verification**:
```bash
# After reboot, check sysctls
talosctl --talosconfig talos/clusterconfig/talosconfig \
  --nodes 192.168.42.254 read /proc/sys/net/ipv4/tcp_keepalive_time
# Should return: 600
```

---

### 3. ⏳ SMB Mount Optimizations

**Status**: Configured in Git (requires PV recreation to apply)

**Configuration** (all media app PVs):
```yaml
mountOptions:
  - cache=loose      # Change from strict (better read/write performance)
  - actimeo=60       # Cache file attributes for 60 seconds
  - noatime          # Don't update access timestamps
```

**Benefits**:
- **cache=loose**: Allows local caching, better for read-heavy workloads
- **actimeo=60**: Reduces metadata operations to QNAP NAS by caching attributes
- **noatime**: Reduces write load on NAS (no timestamp updates on reads)

**Trade-offs**:
- Slightly weaker consistency if multiple pods modify same files (acceptable for media apps)
- Media workloads are mostly sequential reads/writes, minimal conflict risk

**Apply Changes**:
```bash
# Use the provided script (handles all PVs automatically)
./scripts/update-smb-pvs.sh

# Or manually for testing one app:
kubectl delete pod <pod-name> -n media
kubectl delete pvc <pvc-name> -n media
kubectl delete pv <pv-name>
flux reconcile kustomization <app-name> -n media
```

**Verification**:
```bash
# Check mount options on recreated PV
kubectl get pv sabnzbd-media-smb -o yaml | grep -A 5 "mountOptions:"
# Should show cache=loose, actimeo=60, noatime

# Verify pod is running
kubectl get pods -n media -l app.kubernetes.io/name=sabnzbd
```

---

## Rollout Plan

### Phase 1: Low-Risk (Completed)
- ✅ Cilium eBPF map sizing (auto-applied via Flux)
- ✅ Git commits pushed (all changes version-controlled)

### Phase 2: Node-Level Changes
- ⏳ Apply Talos sysctls via node upgrade or reboot
- ⏳ Verify sysctls active with `talosctl read`

### Phase 3: Storage Layer Changes
- ⏳ Run `./scripts/update-smb-pvs.sh` to recreate all PVs with new mount options
- ⏳ Monitor first app (sabnzbd) for 24-48 hours before declaring success
- ⏳ Watch for:
  - File corruption (verify downloads complete successfully)
  - Lock conflicts (check app logs)
  - Mount failures (check CSI driver logs)

---

## Monitoring

### Cilium eBPF Maps
```bash
# Check current conntrack table usage
kubectl exec -n kube-system ds/cilium -- cilium bpf ct list global | wc -l
# Target: <5,000 entries under normal load

# Check for map exhaustion
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium --tail=100 | grep "map full"
# Should be empty
```

### TCP Connection Health
```bash
# Check for stale connections to QNAP (192.168.100.180)
kubectl exec -n kube-system ds/cilium -- cilium bpf ct list global | \
  grep "192.168.100.180" | grep -E "RxClosing|TxClosing" | wc -l
# Target: 0 stale connections
```

### SMB Mount Performance
```bash
# Check mount points on node
talosctl --talosconfig talos/clusterconfig/talosconfig \
  --nodes 192.168.42.254 read /proc/mounts | grep cifs

# Check CSI driver logs for mount errors
kubectl logs -n kube-system -l app=csi-smb-node --tail=100 | grep -i error

# Monitor app logs for file I/O errors
kubectl logs -n media -l app.kubernetes.io/name=sabnzbd --tail=100 | grep -i "input/output error"
```

---

## Rollback Procedures

### Cilium eBPF Maps
```bash
# Revert helmrelease.yaml changes
git revert 713ec92d -- kubernetes/apps/kube-system/cilium/app/helmrelease.yaml
git commit -m "revert: cilium eBPF map sizing"
git push origin main
flux reconcile helmrelease cilium -n kube-system
```

### Talos Sysctls
```bash
# Revert machine-sysctls.yaml changes
git revert 713ec92d -- talos/patches/global/machine-sysctls.yaml
git commit -m "revert: talos TCP tuning"
git push origin main
# Then upgrade Talos or reboot node
```

### SMB Mount Options
```bash
# Revert all PV changes
git revert 713ec92d -- kubernetes/apps/media/*/app/pv-*.yaml
git commit -m "revert: SMB mount optimizations"
git push origin main
# Then run update-smb-pvs.sh script again to apply reverted settings
```

---

## Performance Expectations

### Before Tuning
- Cilium conntrack: ~22,000 entries with hundreds of stale connections
- TCP keepalive: 2 hour timeout (stale connections persist)
- SMB caching: Strict (every operation hits NAS)
- eBPF maps: 256k limit (could exhaust under load)

### After Tuning
- Cilium conntrack: ~4,000 entries, zero stale connections
- TCP keepalive: 10 minute detection of dead connections
- SMB caching: Loose with 60s attribute cache (reduced NAS load)
- eBPF maps: 512k limit (2x headroom)

### Expected Improvements
- **Stability**: Faster detection and cleanup of stale connections
- **Performance**: Reduced NAS metadata operations, better local caching
- **Capacity**: Higher connection limits prevent future exhaustion
- **Recovery**: Faster automatic recovery from NAS hiccups

---

## Related Documentation

- [Resource Exhaustion Fixes](./resource-exhaustion-fixes.md) - Original troubleshooting and emergency fixes
- [Cilium BPF Configuration](https://docs.cilium.io/en/stable/configuration/bpf/) - Official documentation
- [CIFS Mount Options](https://linux.die.net/man/8/mount.cifs) - Linux mount.cifs man page
- [Talos Sysctls](https://www.talos.dev/v1.11/reference/configuration/v1alpha1/config/#machine-sysctls) - Talos configuration reference
