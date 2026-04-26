# Agent Brief: Deploy CrowdSec to clouddrop

## Goal

Add CrowdSec (community-driven IPS) to the cluster as a complement to Wazuh. CrowdSec handles real-time detection and IP-based blocking using community-shared blocklists; Wazuh remains the SIEM/forensic layer. They are not redundant — deploy both.

Scope of this brief:

1. Deploy the CrowdSec **engine** (agent + LAPI) to the `security` namespace.
2. Deploy at least one **bouncer** to enforce decisions. Required: **Cilium / Gateway-API bouncer** (block traffic at cluster ingress). Optional but recommended: **Cloudflare worker bouncer** (block at the CDN edge before traffic enters the tunnel) and **UniFi blocklist mirror** (subscribe the user's UDM/USG to CrowdSec community blocklists at the perimeter).
3. Wire CrowdSec log acquisition to Cilium gateway access logs and a few high-value app logs (Authentik, Wazuh manager, the *arr stack).

## Repository conventions

This is the same repo as `agent-brief-homepage-glance.md`. Re-read that brief's "Repository conventions you must follow" section before starting. Key reminders:

- bjw-s `app-template` chart is the default — but CrowdSec is a legitimate exception. The official `crowdsecurity/crowdsec` Helm chart is mature and handles the agent/LAPI/dashboard split cleanly. Use it. Add a `HelmRepository` resource if one doesn't already exist for `https://crowdsecurity.github.io/helm-charts`.
- Place under `kubernetes/apps/security/crowdsec/` mirroring `wazuh/`'s structure.
- Add to `kubernetes/apps/security/kustomization.yaml`.
- SOPS-encrypt all secrets. Renovate will manage chart and image versions after merge.

## Architecture

```
                    ┌──────────────────────────────────────────┐
                    │  CrowdSec LAPI (StatefulSet, 1 replica)  │
                    │  Stores decisions in Postgres (CNPG)     │
                    └──────────────────────────────────────────┘
                              ▲                 ▲
                  registers   │                 │  reads decisions
                              │                 │
       ┌──────────────────────┴──────┐   ┌──────┴────────────────────────┐
       │  CrowdSec Agent (DaemonSet) │   │  Bouncers                     │
       │  Parses logs from /var/log  │   │  - Cilium / Gateway-API       │
       │  on each node + ConfigMap   │   │  - Cloudflare worker (edge)   │
       │  acquisitions for app logs  │   │  - UniFi (blocklist mirror)   │
       └─────────────────────────────┘   └───────────────────────────────┘
```

The LAPI is the source of truth for blocked IPs. Agents push detections to it. Bouncers poll it for the active decision list and enforce.

## Component 1: CrowdSec engine (agent + LAPI)

### Backend storage

CrowdSec defaults to SQLite. For this cluster, **use Postgres via CNPG** so:

- The decision DB survives pod restarts on different nodes
- It can be backed up the same way other Postgres clusters are (when VolSync/CNPG backups land)

Create `postgres-cluster.yaml` mirroring `kubernetes/apps/home/mealie/app/postgres-cluster.yaml`. Cluster name: `crowdsec-postgres`. Cluster will create the secret `crowdsec-postgres-app` automatically.

### Helm values skeleton

```yaml
# kubernetes/apps/security/crowdsec/app/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: crowdsec
spec:
  interval: 1h
  chart:
    spec:
      chart: crowdsec
      version: <verify-latest>
      sourceRef:
        kind: HelmRepository
        name: crowdsec
        namespace: flux-system
  values:
    agent:
      acquisition:
        # Per-node file acquisitions for kubernetes audit + container runtime
        - namespace: kube-system
          podName: cilium-*
          program: cilium
        - namespace: security
          podName: authentik-*
          program: authentik
        - namespace: security
          podName: wazuh-manager-*
          program: wazuh
        # Pull *arr logs to feed http-cve scenarios
        - namespace: media
          podName: sonarr-*
          program: sonarr
        - namespace: media
          podName: radarr-*
          program: radarr
        - namespace: media
          podName: prowlarr-*
          program: prowlarr
      env:
        - name: COLLECTIONS
          value: >-
            crowdsecurity/linux
            crowdsecurity/http-cve
            crowdsecurity/whitelist-good-actors
            crowdsecurity/base-http-scenarios
            crowdsecurity/iptables
            crowdsecurity/sshd
        - name: PARSERS
          value: crowdsecurity/whitelists
      resources:
        requests: { cpu: 50m, memory: 128Mi }
        limits:   { memory: 512Mi }

    lapi:
      replicas: 1
      env:
        - name: USE_TLS
          value: "true"
        - name: DB_TYPE
          value: postgresql
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: crowdsec-postgres-app
              key: host
        - name: DB_PORT
          value: "5432"
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: crowdsec-postgres-app
              key: dbname
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: crowdsec-postgres-app
              key: username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: crowdsec-postgres-app
              key: password
        - name: DB_SSLMODE
          value: require
      persistentVolume:
        config:
          enabled: true
          storageClassName: qnap-nfs
          accessModes: [ReadWriteOnce]
          size: 1Gi
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits:   { memory: 1Gi }

    # Console enrollment — registers cluster with CrowdSec central
    # for community blocklists and a hosted dashboard.
    config:
      configs:
        config.yaml.local: |
          api:
            server:
              listen_uri: 0.0.0.0:8080
```

### Console enrollment (community blocklists)

The user must do this once after deployment to receive community blocklists:

```bash
# From within the LAPI pod
kubectl -n security exec -it deploy/crowdsec-lapi -- \
  cscli console enroll <enrollment-key-from-app.crowdsec.net>
```

Surface this as a post-deploy TODO in the PR.

### File checklist (engine)

- `kubernetes/apps/security/crowdsec/ks.yaml` — depends on `cloudnative-pg-operator`
- `kubernetes/apps/security/crowdsec/app/kustomization.yaml`
- `kubernetes/apps/security/crowdsec/app/helmrelease.yaml`
- `kubernetes/apps/security/crowdsec/app/postgres-cluster.yaml`
- `kubernetes/apps/security/crowdsec/app/helmrepository.yaml` — only if `flux-system` doesn't already define one for crowdsecurity (verify in `kubernetes/flux/repos/`)

## Component 2: Cilium / Gateway-API bouncer

CrowdSec doesn't ship an official Cilium bouncer, but two viable options exist:

**Option A (recommended): `crowdsec-firewall-bouncer` running as DaemonSet with iptables**
- Mature, official bouncer
- Adds drops via iptables/nftables on each node
- Works regardless of CNI

**Option B: Community Cilium bouncer using `CiliumNetworkPolicy`**
- Updates `CiliumNetworkPolicy` resources from CrowdSec decisions
- More cluster-native but less battle-tested
- Repo: `https://github.com/maxlerebourg/crowdsec-cilium-bouncer` (verify status before adopting)

**Pick Option A** unless the user explicitly asks for B. Deploy as a DaemonSet in the `security` namespace alongside CrowdSec. The bouncer needs:

- A bouncer API key registered in LAPI: `cscli bouncers add cilium-firewall -k <random-32-char>` — store in SOPS as `crowdsec-bouncer-firewall-key`.
- Capability `NET_ADMIN` and host network access to manage iptables rules on the node.
- Connection back to LAPI service inside cluster: `https://crowdsec-service.security.svc.cluster.local:8080`.

Provide a HelmRelease using bjw-s app-template wrapping the `crowdsecurity/crowdsec-firewall-bouncer` image, OR use the upstream chart if one exists. Image: `crowdsecurity/crowdsec-firewall-bouncer`.

## Component 3: Cloudflare worker bouncer (optional but recommended)

This is the highest-leverage bouncer because it blocks attackers at Cloudflare's edge — they never even reach your tunnel.

CrowdSec ships `cs-cloudflare-worker-bouncer`. It deploys a Cloudflare Worker that consults CrowdSec decisions before requests reach origin. Deploy in cluster as a Deployment that pushes decisions to a Cloudflare Worker KV store.

Required Cloudflare permissions on the existing API token (or a new dedicated one):

- `Account.Workers Scripts:Edit`
- `Account.Workers KV Storage:Edit`
- `Zone.Cache Purge:Purge` (for the protected zone)

Store token in SOPS as `crowdsec-cloudflare-bouncer-token`. Surface the Cloudflare permissions list as a TODO so the user generates the token.

Config (mounted as ConfigMap, then merged with secret env vars):
```yaml
crowdsec_lapi_url: https://crowdsec-service.security.svc.cluster.local:8080/
crowdsec_lapi_key: ${CS_LAPI_KEY}              # from secret
cloudflare_config:
  accounts:
    - id: ${CF_ACCOUNT_ID}                     # from secret
      token: ${CF_API_TOKEN}                   # from secret
      zones:
        - actions: [block]
          zone: ${SECRET_DOMAIN}
log_media: stdout
log_level: info
update_frequency: 30s
```

## Component 4: UniFi integration (CrowdSec blocklist mirror)

The user has a full UniFi setup. CrowdSec can be integrated at the perimeter without running a bouncer on the UDM itself. Two approaches:

**Approach A (preferred): Blocklist Mirror service**
CrowdSec ships `cs-blocklist-mirror`, a daemon that exposes the LAPI decision list as a static URL formatted for various firewall consumers. Deploy it as a small Deployment in `security` namespace, expose via internal HTTPRoute at `https://crowdsec-mirror.${SECRET_DOMAIN}/security/blocklist`. Then on the UniFi controller:

1. Settings → Internet Security → Threat Management → Custom IP Group: create a group named `CrowdSec Community`.
2. Use UniFi's "IP Group from URL" feature (UniFi OS 4.x+) to subscribe to the mirror URL. Refresh interval: 15 minutes.
3. Create a Traffic Rule blocking traffic from `CrowdSec Community` at the WAN.

**Approach B: Direct bouncer on UDM (advanced, requires UDM root)**
The `crowdsec-firewall-bouncer` can run directly on a UDM-Pro via `on-boot-script`. This survives firmware updates only with the boot script reapplied. Skip unless the user explicitly opts in.

Implement Approach A. File checklist:

- `kubernetes/apps/security/crowdsec/app/blocklist-mirror-deployment.yaml`
- `kubernetes/apps/security/crowdsec/app/blocklist-mirror-config.yaml` (ConfigMap)
- `kubernetes/apps/security/crowdsec/app/blocklist-mirror-httproute.yaml` (internal-only, parentRef `internal`)

Mirror config (ConfigMap):
```yaml
crowdsec_config:
  lapi_key: ${LAPI_KEY}
  lapi_url: https://crowdsec-service.security.svc.cluster.local:8080/

blocklists:
  - format: plain_text
    endpoint: /security/blocklist
    authentication:
      type: none
    filters:
      origins: ["CAPI", "lists", "crowdsec"]
      scope: ["ip"]
```

The endpoint is intentionally unauthenticated and internal-only (no Cloudflare exposure). UDM polls it from the LAN.

Surface the UniFi controller setup steps as a TODO.

## Verification steps

1. Engine pods Ready:
   ```bash
   kubectl -n security get pods -l app.kubernetes.io/name=crowdsec
   flux get hr -n security crowdsec
   ```

2. LAPI is responding:
   ```bash
   kubectl -n security exec deploy/crowdsec-lapi -- cscli decisions list
   ```

3. Agent is parsing logs (look for non-zero "lines read"):
   ```bash
   kubectl -n security exec ds/crowdsec-agent -- cscli metrics
   ```

4. Firewall bouncer is connected:
   ```bash
   kubectl -n security exec deploy/crowdsec-lapi -- cscli bouncers list
   # Should show cilium-firewall as `valid`
   ```

5. Trigger a test decision:
   ```bash
   kubectl -n security exec deploy/crowdsec-lapi -- cscli decisions add --ip 198.51.100.1 --duration 1h --reason "test"
   # Then on a node:
   talosctl read /proc/net/ip_tables_targets | grep DROP   # confirm chain populated
   ```

6. Cloudflare bouncer (if deployed) syncs decisions:
   ```bash
   kubectl -n security logs deploy/crowdsec-cloudflare-bouncer | grep -i "synced"
   ```

7. UniFi blocklist mirror returns IPs:
   ```bash
   curl -s https://crowdsec-mirror.${SECRET_DOMAIN}/security/blocklist | head
   ```

## Things to NOT do

- Do not expose the LAPI publicly. Internal traffic only.
- Do not run the agent without `whitelist-good-actors` — you will lock yourself out.
- Do not skip the `crowdsecurity/whitelists` parser — it whitelists private RFC1918 ranges by default; without it, internal traffic gets flagged.
- Do not deploy the firewall bouncer without `NET_ADMIN` capability — it will silently fail to install rules.
- Do not commit unencrypted bouncer keys, console enrollment tokens, or Cloudflare API tokens.

## Stretch goals

- Add a Grafana dashboard for CrowdSec metrics. CrowdSec exposes Prometheus metrics on `/metrics` from both LAPI and agents — add a `ServiceMonitor` mirroring `kubernetes/apps/observability/unpoller/app/servicemonitor.yaml`.
- Forward CrowdSec alerts into the existing Alertmanager → Discord pipeline.
- Add CrowdSec scenarios for traefik/nginx-style HTTP attacks against your Cilium gateway access logs (requires enabling Cilium L7 access logs).

## Deliverable

A single PR titled `feat(security): add crowdsec engine, firewall bouncer, cloudflare bouncer, and unifi blocklist mirror`. PR description must list:

- Console enrollment command for the user to run post-merge
- Cloudflare API token permissions required (if Cloudflare bouncer included)
- UniFi controller config steps for the blocklist mirror IP group
- Confirmation that all `*.sops.yaml` files are encrypted
