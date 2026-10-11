# Longhorn restore drill and upgrade gate

## Restore drill (do once before relying on backups)

1. Create a 1Gi test PVC with `storageClassName: longhorn` and write a file
   into it from a throwaway pod.
2. In the Longhorn UI (`longhorn.<domain>`): Volume → the test volume →
   **Create Backup**. Wait until it appears under **Backup**.
3. Backup → the backup → **Restore** into a new volume, then **Create
   PV/PVC** for it.
4. Mount the restored PVC in a pod and read the file back. Expected: same
   contents.
5. Delete the test pods, PVCs and the restored volume.

If the backup target shows unavailable, check the export first:
`kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}'`
(expected `true`), then the `longhorn-backups` NFS share on the QNAP.

## Node upgrades (tuppr) are gated manually

`TalosUpgrade` health checks run a CEL expression per object and a detached
Longhorn volume reports a non-healthy robustness, so a blanket volume check
could block every upgrade. Until that is proven safe, gate by hand:

- Before an upgrade run:
  `kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness`
  and require every **attached** volume to be `healthy`.
- During an upgrade, wait for rebuilds to finish between nodes. With only two
  storage nodes a volume is `degraded` while a node is down, and the drain of
  the second node blocks until the replica on the first has rebuilt (drain
  policy `block-if-contains-last-replica`).
- tuppr treats `Failed` as terminal and needs a manual reset annotation, so do
  not start an upgrade while any attached volume is `degraded`.
