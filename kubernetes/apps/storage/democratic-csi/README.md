# Democratic CSI Setup for QNAP NAS

## Overview

Democratic-csi is a more robust and community-supported CSI driver for NAS storage. It supports QNAP, TrueNAS, and other NAS systems.

## Prerequisites

### 1. Generate QNAP API Key

**Option A: Via Web Interface (if available)**
1. Log into QNAP web interface at http://192.168.100.180:8080
2. Go to Control Panel > Applications > API Keys
3. Generate a new API key with admin privileges
4. Save the API key securely

**Option B: Via SSH (if web interface doesn't have API key option)**
1. SSH into QNAP NAS: `ssh talos@192.168.100.180`
2. Generate API token using QNAP CLI or check existing credentials

### 2. Configure ZFS Dataset

Democratic-csi expects a ZFS dataset structure:
```bash
# On QNAP NAS, create dataset for Kubernetes volumes
# Path: qts/kubernetes/volumes
# This should match the datasetParentName in helmrelease.yaml
```

### 3. Encrypt and Store API Key

```bash
# Edit the secret file with SOPS
sops kubernetes/apps/storage/democratic-csi/app/secret.sops.yaml

# Replace PLACEHOLDER_ENCRYPTED_API_KEY with your actual API key
# SOPS will encrypt it automatically
```

## Configuration Files

- **ks.yaml**: Flux Kustomization for democratic-csi
- **helmrepository.yaml**: Helm chart repository
- **helmrelease.yaml**: Helm release configuration
- **secret.sops.yaml**: Encrypted API credentials

## Current Settings

- **QNAP NAS**: 192.168.100.180:8080 (HTTP), :3260 (iSCSI)
- **Storage Pool**: qts
- **Dataset Path**: qts/kubernetes/volumes
- **Storage Class**: qnap-iscsi-xfs-democratic
- **Username**: talos (for reference only - API key is used)

## Deployment Steps

1. **Generate QNAP API key** (see above)
2. **Update secret.sops.yaml** with API key:
   ```bash
   sops kubernetes/apps/storage/democratic-csi/app/secret.sops.yaml
   ```
3. **Update helmrelease.yaml** if needed:
   - Adjust `datasetParentName` to match your QNAP dataset
   - Verify `targetPortal` IP address
   - Adjust `namePrefix` and `nameSuffix` if desired
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

## Migration from QNAP CSI Plugin

### 1. Create New PVs with Democratic-CSI

Update your PVC definitions to use the new storage class:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-config
spec:
  storageClassName: qnap-iscsi-xfs-democratic  # New storage class
  accessModes:
    - ReadWriteOnce
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
kubectl get sc qnap-iscsi-xfs-democratic -o yaml
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
