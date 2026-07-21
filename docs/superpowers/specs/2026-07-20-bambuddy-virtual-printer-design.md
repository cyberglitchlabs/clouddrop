# Design: bambuddy Virtual Printer networking

## Goal

Enable the Virtual Printer feature on the already-deployed `bambu-buddy`
HelmRelease (`kubernetes/apps/3d-printing/bambu-buddy/`) so a single Print
Queue-mode virtual printer, emulating an X1 Carbon, can be created and
reached by Bambu Studio / OrcaSlicer on the LAN.

## Scope

- One virtual printer, Print Queue mode, X1 Carbon model.
- SSDP auto-discovery is explicitly out of scope (see "Why no SSDP" below).
  Slicer connects via manually-entered IP, same as bambuddy's own documented
  VPN/remote fallback path.
- Multiple virtual printers / Proxy mode are out of scope; this design's
  port allocation (10-port FTP passive range) assumes a single non-proxy VP.

## Current state

`bambu-buddy` runs as one bjw-s `app-template` controller/pod in the
`3d-printing` namespace, exposed only via a ClusterIP `service.app` (port
8000) behind the `internal` Gateway HTTPRoute. No LoadBalancer Service,
no extra capabilities, no VP-related ports are configured today.

## Design

### Networking: add a second Service on the same pod

Add `service.vp`, `type: LoadBalancer`, targeting the same `bambu-buddy`
controller — the existing `service.app`/Gateway path for the web UI is
untouched. This mirrors the precedent set by `esphome-builder`, the only
other app in this repo needing a real LAN-routable IP instead of the
Gateway path.

Pin the IP with the `lbipam.cilium.io/ips: "192.168.42.16"` annotation
(next free slot after `.11`–`.15`, already in use by k8s-gateway/internal
gateway/external gateway/alloy/esphome-builder; avoids `.250`–`.254` which
are Talos node IPs). Pinning matters here specifically because this IP is
typed manually into slicer software — it must not change across pod
restarts.

No new `CiliumLoadBalancerIPPool` or `CiliumL2AnnouncementPolicy` needed;
the existing cluster-wide pool/policy already covers this.

### Ports (single non-proxy VP, Print Queue mode)

| Port(s) | Proto | Purpose |
|---|---|---|
| 3000, 3002 | TCP | bind/detect handshake |
| 2021 | UDP | SSDP port (bound by the app regardless; see below) |
| 8883 | TCP | MQTT/TLS |
| 990 | TCP | FTPS control (privileged port) |
| 6000 | TCP | file transfer tunnel |
| 322 | TCP | RTSP camera stream |
| 2024–2026 | TCP | A1/P1S proprietary protocol |
| 50000–50009 | TCP | FTP passive data (10 ports for one non-proxy VP) |

### Security context: NET_BIND_SERVICE capability

Port 990 is privileged (<1024). The pod already runs as non-root (uid
568) per `defaultPodOptions`. Add to the `bambu-buddy` container's
`securityContext.capabilities`:

```yaml
capabilities:
  drop: ["ALL"]
  add: ["NET_BIND_SERVICE"]
```

`allowPrivilegeEscalation: false` stays as-is — capability grants for
binding privileged ports don't require privilege escalation.

### Persistence

No changes. VP configuration (access code, mode, bind IP selection, CA
cert) is created and stored through the bambuddy UI under `/app/data`,
already covered by the existing `bambu-buddy-data` PVC.

### Why no SSDP

SSDP discovery works by the slicer sending an `M-SEARCH` query to the
multicast address `239.255.255.250`; the printer replies by unicast. A
Kubernetes Service — including a Cilium `LoadBalancer` with L2
announcement — only matches traffic addressed to its own IP; it cannot
intercept a query sent to a multicast group address. This is a structural
limitation of the Service model, not a missing config option. Cilium has
a beta "Multicast Support" feature, but it isn't installed on this
cluster and is out of scope for the value it would provide here, given
bambuddy itself documents manual IP entry as a fully-supported fallback.

## What stays manual (post-merge, not automated by this change)

1. In the bambuddy UI (Settings → Virtual Printer): create the VP with
   Mode = Print Queue, Model = X1 Carbon, an 8-character access code, and
   Bind IP = `192.168.42.16`. Enable it.
2. Download bambuddy's self-signed CA certificate from the UI and append
   it to OrcaSlicer/Bambu Studio's `printer.cer` on the workstation(s)
   that will slice to this VP (path is OS/slicer-specific per bambuddy's
   docs).

## Verification

1. `flux get hr -n 3d-printing bambu-buddy` healthy after the change.
2. `kubectl -n 3d-printing get svc` shows the new `bambu-buddy-vp` (or
   equivalent) Service with `EXTERNAL-IP` = `192.168.42.16`.
3. After manual VP creation in the UI, use bambuddy's own "Setup Check"
   diagnostic (stethoscope button) to confirm bind interface, ports, and
   TLS certs are all green.
4. From a workstation on the LAN: `nc -zv 192.168.42.16 3000` (and spot-
   check 8883/990/322) to confirm the ports are reachable outside the
   cluster.
5. Add the VP manually in Bambu Studio/OrcaSlicer via IP entry, install
   the CA cert, and confirm a test print job can be sent and shows up in
   bambuddy's print queue.
