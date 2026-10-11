# Migrating an app's SQLite volume to Longhorn

Design: `docs/superpowers/specs/2026-10-10-longhorn-storage-design.md`.
Every migration is a cold copy: the app is stopped, data is copied, the
HelmRelease is repointed, and the old PVC is kept until the new volume has a
successful snapshot and backup.

Use the repo-local kubeconfig (the default `~/.kube/config` is stale):

```bash
export KUBECONFIG=/Users/jsievert/personal/clouddrop/kubeconfig
```

## Procedure

1. **Confirm it is SQLite.** Check the image docs and the volume contents
   (`find /config \( -name '*.db' -o -name '*.sqlite*' \)`). If the app has no
   SQLite database in this volume, stop and skip it.
2. **Create the new PVC** (template below) in the app's `kustomization.yaml`,
   merge, and let Flux create it.
3. **Scale to 0:**
   `flux suspend hr -n <ns> <app>` then `kubectl -n <ns> scale deploy/<app> --replicas=0`.
4. **Run the copy Job** (template below). Require the `files` and `bytes` lines
   to match and the `ls -ln` UID/GID to match the old tree.
5. **Repoint** `persistence.<name>.existingClaim` in the HelmRelease to the new
   claim. In the same commit remove the old PVC manifest from
   `kustomization.yaml` and delete the file, so Flux does not recreate it.
6. **Resume and verify:** `flux resume hr -n <ns> <app>`, check the pod is
   Ready and the app shows its data.
7. **Confirm protection:** a Longhorn snapshot and a backup exist for the new
   volume (`kubectl -n longhorn-system get snapshots.longhorn.io,backups.longhorn.io`);
   trigger a manual backup from the UI if the schedule has not fired yet.
8. **Delete the old PVC and PV** only after step 7.

## Adding a storage node

1. Add the `longhorn` `UserVolumeConfig` and the
   `node.longhorn.io/create-default-disk: config` label patch to the node in
   `talos/talconfig.yaml`, then apply it to the node.
2. Longhorn does not reliably create the default disk for a node it already
   knows about (observed on first install: the `Node` object existed before the
   `create-default-disk-labeled-nodes` setting was applied). If
   `kubectl -n longhorn-system get nodes.longhorn.io <node> -o jsonpath='{.spec.disks}'`
   is `{}`, add the disk by hand:
   ```bash
   kubectl -n longhorn-system patch nodes.longhorn.io <node> --type merge -p \
     '{"spec":{"disks":{"default-disk-<node>":{"path":"/var/mnt/longhorn","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":[],"diskType":"filesystem"}}}}'
   ```
3. Confirm `.status.diskStatus` shows the disk `Ready` and `Schedulable`.

## Rollback

Until step 8: set `existingClaim` back to the old claim and resume the
HelmRelease. The old PVCs are `Retain` and the copy never modifies the source.

## New PVC template

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: APP-config
  namespace: NS
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: SIZE
```

## Copy Job template

Replace `APP`, `NS`, `OLD_CLAIM`, `NEW_CLAIM`. Apply only while the app is
scaled to 0. For old volumes that are node-pinned hostPath PVs, the Job is
scheduled onto that node through the PV's node affinity.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate-APP
  namespace: NS
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: copy
          image: alpine:3.22
          command:
            - sh
            - -c
            - |
              set -eu
              cp -a /old/. /new/
              echo "files old=$(find /old | wc -l) new=$(find /new | wc -l)"
              echo "bytes old=$(du -sb /old | cut -f1) new=$(du -sb /new | cut -f1)"
              ls -ln /new | head -20
          volumeMounts:
            - name: old
              mountPath: /old
              readOnly: true
            - name: new
              mountPath: /new
      volumes:
        - name: old
          persistentVolumeClaim:
            claimName: OLD_CLAIM
            readOnly: true
        - name: new
          persistentVolumeClaim:
            claimName: NEW_CLAIM
```
