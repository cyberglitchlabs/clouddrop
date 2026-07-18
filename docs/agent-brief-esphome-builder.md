# Agent Brief: Deploy ESPHome Device Builder (remote build server) to clouddrop

## Goal

Add a headless ESPHome **remote build server** — a dedicated compile worker
that an existing, separately-run ESPHome instance (currently on a Raspberry
Pi 4) can pair with and offload firmware compiles to. This is *not* a
dashboard deployment: no device configs live here, no one browses to it, and
no OTA/serial flashing happens from this pod (flashing always runs on the
sending host, since that's where the device is physically attached or
reachable). Its only job is lending CPU for PlatformIO/ESP-IDF builds and
shipping compiled artefacts back.

Outcome:

- A pod in-cluster running `esphome-device-builder --remote-build-only`
- Reachable from the existing ESPHome instance's LAN segment on port 6055
  (the peer-link WebSocket) for one-time pairing and ongoing build traffic
- Persistent server identity/build-queue state and a persistent PlatformIO
  toolchain cache (so toolchains aren't re-downloaded on every pod restart)

## Repository conventions

Re-read `agent-brief-homepage-glance.md`'s "Repository conventions" section
and `AGENTS.md` at the repo root. Place under
`kubernetes/apps/home/esphome-builder/` (alongside `emqx`, the other
home-automation-adjacent app). Use the bjw-s `app-template` chart via the
existing `bjw-s-app-template` OCIRepository (see `mealie` or `meshmonitor`
for the canonical `chartRef` pattern). SOPS is **not** needed for this app —
there's no static credential; auth is a one-time pairing key + Noise
handshake done interactively post-deploy (see "Pairing" below).

## Why no hostNetwork / no mDNS

ESPHome's dashboard normally discovers peers over mDNS, but this cluster's
pod network (Cilium overlay) doesn't carry LAN multicast, and no app in this
repo uses `hostNetwork`. That's fine here: headless remote-build-only servers
are paired via **manual hostname:port entry** anyway (this is explicitly
documented as the intended flow for HA-add-on and cross-subnet pairing), so
mDNS was never going to be used regardless of networking mode.

## Why a LoadBalancer Service (not a Gateway HTTPRoute)

Every other app in this repo is exposed via the `internal`/`external`
Gateway HTTPRoutes. This one is different: it isn't a browser-facing web
app, it's a raw WebSocket peer-link (`/remote-build/peer-link` over TCP
6055) dialed directly by the ESPHome software on the sending host, using a
literal `hostname:port` the user types into the Send-builds pairing dialog.
Terminating that through the Envoy Gateway / Cloudflare tunnel path adds
complexity for no benefit since this is LAN-only traffic anyway.

Instead, expose it as a `LoadBalancer` Service and let the cluster's existing
`CiliumLoadBalancerIPPool` (`192.168.42.0/24`) + `CiliumL2AnnouncementPolicy`
(see `kubernetes/apps/kube-system/cilium/app/networks.yaml`) hand it a real,
ARP-announced LAN IP — reachable directly from the Pi 4 or wherever the
primary ESPHome instance runs, no ingress/proxy involved. No other app
currently consumes this pool; this would be the first.

## Image and entrypoint — verified against upstream source

- Image: `ghcr.io/esphome/esphome`, tag `>= 2026.6.0` (verify latest at
  https://github.com/esphome/esphome/pkgs/container/esphome — this is the
  first version where `esphome-device-builder` is bundled).
- **Do not rely on the image's default entrypoint/CMD.** Its
  `docker_entrypoint.sh` only special-cases the `dashboard` subcommand,
  routing it to `esphome-device-builder`; every other argument falls through
  to the classic `esphome` CLI, which does not understand
  `--remote-build-only`. There is no passthrough for headless mode in the
  stock entrypoint. Override the container's `command` entirely to call the
  `esphome-device-builder` binary directly, bypassing `/entrypoint.sh`, and
  manually replicate the cache-dir env vars the stock entrypoint would have
  set (so PlatformIO toolchains land on the persistent `/cache` volume
  instead of being re-downloaded every restart):

```yaml
command: ["/bin/sh", "-c"]
args:
  - |
    export PLATFORMIO_PLATFORMS_DIR=/cache/platformio/platforms
    export PLATFORMIO_PACKAGES_DIR=/cache/platformio/packages
    export PLATFORMIO_CACHE_DIR=/cache/platformio/cache
    export ESPHOME_ESP_IDF_PREFIX=/cache/idf
    export ESPHOME_SDK_NRF_PREFIX=/cache/sdk-nrf
    exec esphome-device-builder --remote-build-only /var/lib/esphome-builder
```

- Verify the container's default user/UID before finalizing
  `securityContext` (couldn't check locally — no Docker daemon available in
  this session). Try `docker run --rm ghcr.io/esphome/esphome:<tag> id` or
  inspect the `ghcr.io/esphome/docker-base` image it's built from. Compiling
  toolchains typically needs a writable home dir; don't fight the image's
  expected UID if it isn't 1000 — match it instead. `readOnlyRootFilesystem`
  should be `false` (PlatformIO writes all over its cache/build dirs at
  runtime).

## Persistence

Two PVCs, `qnap-nfs`, `ReadWriteOnce` (single replica, no need for RWX):

```yaml
persistence:
  identity:
    enabled: true
    type: persistentVolumeClaim
    storageClass: qnap-nfs
    accessMode: ReadWriteOnce
    size: 1Gi
    globalMounts:
      - path: /var/lib/esphome-builder
  cache:
    enabled: true
    type: persistentVolumeClaim
    storageClass: qnap-nfs
    accessMode: ReadWriteOnce
    size: 20Gi
    globalMounts:
      - path: /cache
```

`identity` holds the server's Noise keypair/fingerprint and the persistent
build queue — losing it means re-pairing from scratch. `cache` holds
PlatformIO platforms/packages/toolchains (ESP-IDF, Arduino cores, etc.) —
sized generously since ESP-IDF toolchains are large and you want them
downloaded once, not on every pod restart.

## Networking

```yaml
service:
  app:
    controller: esphome-builder
    type: LoadBalancer
    ports:
      peer-link:
        port: 6055
        targetPort: 6055
        protocol: TCP
```

No `annotations` block is required to pull from the pool — confirm this
cluster's Cilium LB-IPAM is configured to auto-assign from the sole
`CiliumLoadBalancerIPPool` (`pool`) without a per-Service selector annotation
(check `kubernetes/apps/kube-system/cilium/app/networks.yaml` — the pool has
no `serviceSelector`, so it should match all `LoadBalancer` Services
cluster-wide by default). After applying, confirm with
`kubectl -n home get svc esphome-builder` that an
`EXTERNAL-IP` in `192.168.42.0/24` gets assigned.

No HTTPRoute, no Gateway, no external-dns annotation — this is intentionally
off the Gateway path (see rationale above).

## Resources

No `nodeSelector`/node affinity — any cluster node comfortably beats a Pi 4,
so let the scheduler place it wherever fits. Compiling (especially ESP-IDF
targets) is CPU- and memory-heavy and bursty, so size generously but let
limits, not pinning, do the work:

```yaml
resources:
  requests:
    cpu: "1"
    memory: 1Gi
  limits:
    memory: 6Gi
```

(Deliberately no CPU limit — let it burst across idle cores during a
compile; the requests value is what the scheduler uses for bin-packing.)

## Probes

Port 6055 is a raw WebSocket endpoint, not a simple HTTP health path — use a
TCP socket check rather than an HTTP probe:

```yaml
probes:
  liveness:
    enabled: true
    custom: true
    spec:
      tcpSocket:
        port: 6055
      initialDelaySeconds: 30
      periodSeconds: 30
      timeoutSeconds: 5
      failureThreshold: 3
  readiness:
    enabled: true
    custom: true
    spec:
      tcpSocket:
        port: 6055
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 3
```

## File checklist

- `kubernetes/apps/home/esphome-builder/ks.yaml` — no special `dependsOn`
- `kubernetes/apps/home/esphome-builder/app/kustomization.yaml`
- `kubernetes/apps/home/esphome-builder/app/helmrelease.yaml`

Update `kubernetes/apps/home/kustomization.yaml` to include
`./esphome-builder/ks.yaml`.

No `secret.sops.yaml` — nothing to encrypt for this app.

## Verification steps

1. Kustomization and HelmRelease healthy:
   ```bash
   flux get ks -n flux-system esphome-builder
   flux get hr -n home esphome-builder
   ```
2. Pod running, check startup logs for the printed fingerprint + one-time
   pairing key:
   ```bash
   kubectl -n home logs deploy/esphome-builder -f
   ```
   Look for the emoji fingerprint block and the pairing key
   (format like `8MC5-KAXV-NN6N-PWAA`).
3. Confirm LoadBalancer IP assignment:
   ```bash
   kubectl -n home get svc esphome-builder
   ```
4. From the existing ESPHome instance (the Pi 4): open
   **Settings → Send builds → Pair with a build server**, enter the
   LoadBalancer IP and port `6055`, submit. Compare the emoji fingerprint
   shown there against the one in the pod's logs — **do not accept if they
   don't match**. Enter the one-time pairing key when prompted.
5. Confirm pairing persisted: restart the `esphome-builder` pod
   (`kubectl -n home rollout restart deploy/esphome-builder`) and confirm
   the primary ESPHome instance still shows it as a known/paired build
   server afterward (proves the `identity` PVC is actually persisting
   state, not just the pairing key still being valid in memory).
6. Trigger a real build: from the primary instance, install/update any
   device config with **Auto-route installs to remote build** enabled (or
   pick "Build on esphome-builder" explicitly in the install dialog) and
   confirm the "Building on `esphome-builder`" sub-line appears and the
   compile completes.
7. Confirm the cache is actually being used: after the first build,
   `kubectl -n home exec deploy/esphome-builder -- du -sh /cache` should
   show non-trivial size (PlatformIO packages/toolchains); a second build of
   the same platform should be noticeably faster than the first.

## Things to NOT do

- Do not rely on the image's default `dashboard` CMD or leave the entrypoint
  unoverridden — it silently falls through to the classic `esphome` CLI and
  `--remote-build-only` will be rejected or misparsed.
- Do not put this behind the internal/external Gateway — it's a raw
  peer-link socket dialed by hostname:port, not a browsed app.
- Do not skip the fingerprint comparison during pairing — it's the only
  thing preventing an unintended device from pairing as your build server.
- Do not size the `cache` PVC too small — ESP-IDF toolchains alone can run
  several GB; running out of space mid-compile is worse than over-provisioning.
- Do not add a `secret.sops.yaml` for this app — there's nothing to encrypt.

## Deliverable

A single PR titled
`feat(home): add esphome-builder remote build server for offloaded compiles`.
PR description must:

- Note the verified image tag and confirmed entrypoint override
- Confirm the container's actual UID/securityContext (verified against the
  real image, not assumed)
- Confirm LoadBalancer IP assignment from the existing Cilium pool
- List the manual pairing step as a required post-merge action (this cannot
  be automated — it requires human fingerprint verification)
