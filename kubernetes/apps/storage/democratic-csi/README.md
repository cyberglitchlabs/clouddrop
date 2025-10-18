# Democratic CSI Setup for QNAP NAS (NFS)

## Overview

Democratic-csi configured for **NFS v4.1** with QNAP NAS. QNAP does not support the FreeNAS/TrueNAS API required for iSCSI auto-provisioning, so we use the generic NFS client driver instead.

## Why NFS Instead of iSCSI?

- **QNAP Limitation**: QNAP doesn't expose ZFS/API for democratic-csi iSCSI driver
- **NFS Benefits**:
  - Works with any NFS server (no special API needed)
  - NFSv4.1 provides good performance and features
  - ReadWriteMany support (multiple pods can share same volume)
  - Simpler setup and more reliable

## Prerequisites

### 1. Create NFS Share on QNAP

**Via QNAP Web UI:**
1. Log into QNAP: http://192.168.100.180:8080
2. Go to Control Panel > Shared Folders
3. Create folder: `/kubernetes/volumes`
4. Go to Control Panel > Network & File Services > NFS
5. Enable NFS v4.1
6. Add NFS rule for `/kubernetes/volumes`:
   - Access: Read/Write
   - Clients: 192.168.42.0/24 (your Kubernetes node subnet)
   - Squash: No root squash
   - Security: sys

**Via SSH (Alternative):**
```bash
ssh talos@192.168.100.180

# Create directory
mkdir -p /share/kubernetes/volumes

# Configure NFS export (check QNAP docs for exact path)
# Usually in /etc/exports or via QNAP CLI
```

### 2. Verify NFS Connectivity

From your Kubernetes node:
```bash
# Test NFS mount
talosctl --talosconfig talos/clusterconfig/talosconfig \
  --nodes 192.168.42.254 \
  read /proc/mounts | grep nfs

# Or test manually
showmount -e 192.168.100.180
```

### 3. No Secrets Needed!

Unlike iSCSI setup, NFS client driver doesn't need credentials. The secret file can be removed or left empty.

## Configuration Files

- **ks.yaml**: Flux Kustomization for democratic-csi
- **helmrepository.yaml**: Helm chart repository
- **helmrelease.yaml**: Helm release configuration (NFS driver)
- **secret.sops.yaml**: Not needed for NFS (can delete)

## Current Settings

- **QNAP NAS**: 192.168.100.180 (NFS Server)
- **NFS Version**: 4.1
- **Share Path**: /kubernetes/volumes
- **Storage Class**: qnap-nfs-democratic
- **NFS Path**: /kubernetes/volumes
- **Storage Class**: qnap-nfs-democratic
- **Mount Options**: nfsvers=4.1, nolock, hard, rsize/wsize=1M

## Deployment Steps

1. **Create NFS share on QNAP** (see Prerequisites above)
2. **Verify NFS export** is accessible from Kubernetes node
3. **Update helmrelease.yaml** if needed:
   - Adjust `shareBasePath` if using different path
   - Verify `shareHost` IP address (192.168.100.180)
   - Modify mount options if needed
4. **Add to storage kustomization**:
   ```bash
   # Edit kubernetes/apps/storage/kustomization.yaml
   # Add: - ./democratic-csi/ks.yaml
   ```
5. **Commit and push**:
   ```bash
   git add kubernetes/apps/storage/democratic-csi/
   git commit -m "feat: add democratic-csi for QNAP NAS"
   git push origin main
   ```
6. **Let Flux deploy**:
   ```bash
   flux reconcile source git flux-system
   flux reconcile kustomization democratic-csi -n kube-system
   ```

## Migration from QNAP CSI Plugin (iSCSI)

### Important: NFS vs iSCSI

- **Old**: QNAP CSI Plugin with iSCSI (ReadWriteOnce only)
- **New**: Democratic-CSI with NFS v4.1 (ReadWriteMany supported!)

### 1. Create New PVCs with Democratic-CSI

Update your PVC definitions to use the new storage class:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-config
spec:
  storageClassName: qnap-nfs-democratic  # New NFS storage class
  accessModes:
    - ReadWriteOnce  # Or ReadWriteMany if needed
  resources:
    requests:
      storage: 5Gi
```

### 2. Test First

Test with a non-critical application before migrating all volumes:
```bash
# Create test PVC
kubectl apply -f test-pvc.yaml

# Verify it provisions
kubectl get pvc test-pvc
kubectl get pv
```

### 3. Gradual Migration

Migrate applications one at a time:
1. Scale down deployment
2. Delete old PVC
3. Create new PVC with democratic-csi storage class
4. Scale up deployment
5. Verify data/functionality

### 4. Eventually Remove QNAP CSI Plugin

Once all volumes are migrated:
```bash
# Remove from storage kustomization
# Delete QNAP CSI plugin resources
kubectl delete kustomization qnap-csi-plugin -n trident
```

## Troubleshooting

### Check Democratic-CSI Logs
```bash
# Controller logs
kubectl logs -n kube-system -l app=democratic-csi-controller --tail=100

# Node logs
kubectl logs -n kube-system -l app=democratic-csi-node --tail=100
```

### Verify API Connectivity
```bash
# From controller pod
kubectl exec -n kube-system deployment/democratic-csi-controller -- \
  curl -H "Authorization: Bearer YOUR_API_KEY" \
  http://192.168.100.180:8080/api/v2/storage/pools
```

### Check Storage Class
```bash
kubectl get sc qnap-nfs-democratic -o yaml
```

### Check NFS Mount on Node
```bash
talosctl --talosconfig talos/clusterconfig/talosconfig \
  --nodes 192.168.42.254 \
  read /proc/mounts | grep nfs
```

### Check PV Provisioning
```bash
kubectl describe pvc <pvc-name>
kubectl get events --sort-by='.lastTimestamp'
```

## Benefits Over QNAP CSI Plugin

1. **Active Development**: Regular updates and bug fixes
2. **Better Error Handling**: More detailed error messages
3. **Community Support**: Larger user base and documentation
4. **Multiple Backends**: Works with TrueNAS, QNAP, generic NFS/iSCSI
5. **Snapshot Support**: Built-in volume snapshot capabilities
6. **Resource Limits**: Configurable sidecar resource limits

## References

- [Democratic-CSI GitHub](https://github.com/democratic-csi/democratic-csi)
- [Democratic-CSI Helm Charts](https://democratic-csi.github.io/charts/)
- [QNAP Configuration Guide](https://github.com/democratic-csi/democratic-csi/blob/master/docs/qnap.md)
