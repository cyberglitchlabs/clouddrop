# Democratic-CSI Migration Plan

## Current Status (October 17, 2025)

### System State
- **Node**: Recently rebooted, Talos sysctls active (tcp_keepalive_time=600)
- **Cilium**: Updated with eBPF map sizing (512k conntrack entries)
- **SMB Mounts**: Updated to `cache=loose`, `actimeo=60`, `noatime` ✅
- **QNAP CSI Plugin**: Experiencing persistent backend disconnects
- **Media Pods**: 3/8 running (sabnzbd, sonarr, profilarr)

### Problems with Current QNAP CSI Plugin
1. **Backend Disconnects**: `storage (qts) not exists` errors
2. **Stuck Volume Attachments**: Requires manual cleanup
3. **Poor Error Recovery**: Needs Trident controller restarts
4. **Limited Community Support**: Less active development

## Democratic-CSI Advantages

1. **Better Stability**: More robust error handling
2. **Active Development**: Regular updates and bug fixes
3. **Community Support**: Larger user base, better docs
4. **Multiple Backends**: QNAP, TrueNAS, generic NFS/iSCSI
5. **Resource Controls**: Sidecar resource limits pre-configured
6. **Snapshot Support**: Built-in volume snapshots

## Implementation Steps

### Phase 1: Setup (Do Not Deploy Yet)
✅ Created democratic-csi configuration files:
- `/kubernetes/apps/storage/democratic-csi/ks.yaml`
- `/kubernetes/apps/storage/democratic-csi/app/helmrelease.yaml`
- `/kubernetes/apps/storage/democratic-csi/app/helmrepository.yaml`
- `/kubernetes/apps/storage/democratic-csi/app/secret.sops.yaml` (needs API key)
- `/kubernetes/apps/storage/democratic-csi/README.md`

### Phase 2: Create NFS Share on QNAP
**Required before deployment:**

**Via QNAP Web UI:**
1. Navigate to http://192.168.100.180:8080
2. Go to Control Panel > Shared Folders
3. Create folder: `/kubernetes/volumes` (or use existing share)
4. Go to Control Panel > Network & File Services > NFS
5. Enable NFS v4 (and v4.1 if available)
6. Add NFS rule for `/kubernetes/volumes`:
   - Access: Read/Write
   - Clients: 192.168.42.0/24 (your Kubernetes node subnet)
   - Squash: No root squash
   - Security: sys

**Via SSH (Alternative):**
```bash
ssh talos@192.168.100.180

# Create directory (adjust path for your QNAP)
mkdir -p /share/kubernetes/volumes

# NFS export should be configured via QNAP web UI or CLI
```

**Verify NFS is accessible:**
```bash
# From any machine
showmount -e 192.168.100.180

# Should show: /kubernetes/volumes  192.168.42.0/24
```

### Phase 3: No Secrets Needed!
**NFS client driver doesn't require authentication.** The secret.sops.yaml file has been removed.

### Phase 4: Test Deployment
```bash
# Add to storage kustomization
# Edit kubernetes/apps/storage/kustomization.yaml
# Add: - ./democratic-csi/ks.yaml

# Commit and push
git add kubernetes/apps/storage/democratic-csi/
git commit -m "feat: add democratic-csi for QNAP NAS"
git push origin main

# Monitor deployment
flux reconcile source git flux-system
flux reconcile kustomization democratic-csi -n kube-system

# Check pods
kubectl get pods -n kube-system -l app=democratic-csi-controller
kubectl get pods -n kube-system -l app=democratic-csi-node

# Verify storage class
kubectl get sc qnap-iscsi-xfs-democratic
```

### Phase 5: Test with Single Application
Create test PVC:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-democratic-csi
  namespace: default
spec:
  storageClassName: qnap-iscsi-xfs-democratic
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

Test:
```bash
kubectl apply -f test-pvc.yaml
kubectl get pvc test-democratic-csi
kubectl describe pvc test-democratic-csi

# If successful, create test pod to mount it
```

### Phase 6: Migrate One Media App
Start with a non-critical app (e.g., huntarr):

1. **Scale down**:
   ```bash
   kubectl scale deployment huntarr -n media --replicas=0
   ```

2. **Backup important data** (if any)

3. **Delete old PVC**:
   ```bash
   kubectl delete pvc huntarr -n media
   ```

4. **Update PVC definition** to use `qnap-iscsi-xfs-democratic`

5. **Apply new PVC**:
   ```bash
   kubectl apply -f kubernetes/apps/media/huntarr/app/pvc.yaml
   ```

6. **Scale up**:
   ```bash
   kubectl scale deployment huntarr -n media --replicas=1
   ```

7. **Verify**:
   ```bash
   kubectl get pods -n media -l app.kubernetes.io/name=huntarr
   kubectl logs -n media -l app.kubernetes.io/name=huntarr
   ```

### Phase 7: Gradual Migration
Migrate remaining apps one at a time:
1. profilarr
2. prowlarr
3. bazarr
4. radarr
5. sonarr
6. audiobookshelf
7. sabnzbd (last, most critical)

### Phase 8: Remove QNAP CSI Plugin
After all volumes migrated:
```bash
# Remove from storage kustomization
# Delete QNAP CSI plugin
kubectl delete kustomization qnap-csi-plugin -n trident

# Clean up old resources
kubectl delete tridentbackend -n trident --all
kubectl delete tridentbackendconfig -n trident --all
```

## Rollback Plan

If democratic-csi doesn't work:
1. Keep QNAP CSI plugin installed during testing
2. Can revert PVCs to use `qnap-iscsi-xfs` storage class
3. Old volumes should still be available on QNAP NAS

## Decision Point

**Do NOT proceed with deployment until:**
1. ✅ QNAP NFS share created (`/kubernetes/volumes`)
2. ✅ NFS v4.1 enabled on QNAP
3. ✅ NFS export configured for 192.168.42.0/24 subnet
4. ✅ Verified with `showmount -e 192.168.100.180`

**Next Steps:**
1. Create NFS share on QNAP (see Phase 2 options)
2. Verify NFS export is accessible
3. Optionally test manual NFS mount from Kubernetes node
4. Enable deployment in kustomization.yaml
5. Test with non-production app first

## Files Created

All files are ready but not yet added to kustomization.yaml:
- Configuration files: Complete ✅ (NFS driver, not iSCSI)
- Secret file: Removed (not needed for NFS) ✅
- Documentation: Updated for NFS ✅
- Kustomization entry: Not added yet (intentional)

## Important Notes

### Why NFS Instead of iSCSI?

**QNAP Limitation**: QNAP does not support the FreeNAS/TrueNAS REST API that democratic-csi requires for iSCSI auto-provisioning. The `freenas-iscsi` driver needs ZFS API access which QNAP doesn't expose.

**NFS Benefits**:
- ✅ Works with any NFS server (no special API)
- ✅ NFSv4.1 provides good performance
- ✅ **ReadWriteMany support** (multiple pods can share volumes)
- ✅ Simpler setup, more reliable
- ✅ No authentication/secrets needed

**Trade-offs**:
- NFS vs iSCSI performance is comparable for most workloads
- NFS is network filesystem (already using SMB for media)
- Can coexist with existing iSCSI volumes during migration

## Current Media Pod Status

Working (3/8):
- ✅ sabnzbd
- ✅ sonarr
- ✅ profilarr

Stuck on QNAP backend (5/8):
- ❌ audiobookshelf (ContainerCreating - iSCSI volumes)
- ❌ bazarr (ContainerCreating - iSCSI volumes)
- ❌ huntarr (ContainerCreating - iSCSI volumes)
- ❌ prowlarr (ContainerCreating - iSCSI volumes)
- ❌ radarr (ContainerCreating - iSCSI volumes)

All have SMB media volumes ready, but can't attach iSCSI config volumes.
