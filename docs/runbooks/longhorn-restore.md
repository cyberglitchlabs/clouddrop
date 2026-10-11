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

## Restored volumes take the default replica count

A volume restored from the UI, or created outside the StorageClass, uses the
`default-replica-count` setting, not the StorageClass parameter. It must be
`{"v1":"2","v2":"2"}`: a v1-only value is rejected as "mismatched data
engines" and the live default stays at 3. With two storage nodes a 3-replica
volume stays `degraded` forever. Also note that chart `defaultSettings` apply
only on first install; change the live value with
`kubectl -n longhorn-system patch settings.longhorn.io default-replica-count --type merge -p '{"value":"{\"v1\":\"2\",\"v2\":\"2\"}"}'`.

## Node upgrades (tuppr)

The `TalosUpgrade` carries a CEL health check on `longhorn.io/v1beta2 Volume`
(`status.state != "attached" || status.robustness == "healthy"`, 45m), so the
next node is not started until attached volumes are healthy again. Detached
volumes report robustness `unknown` and are skipped. If the check times out,
tuppr goes `Failed`, which is terminal and needs the manual reset annotation.
Still worth checking by hand before approving a Talos bump:

- Before an upgrade run:
  `kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness`
  and require every **attached** volume to be `healthy`.
- During an upgrade, wait for rebuilds to finish between nodes. With only two
  storage nodes a volume is `degraded` while a node is down, and the drain of
  the second node blocks until the replica on the first has rebuilt (drain
  policy `block-if-contains-last-replica`).
- tuppr treats `Failed` as terminal and needs a manual reset annotation, so do
  not start an upgrade while any attached volume is `degraded`.
