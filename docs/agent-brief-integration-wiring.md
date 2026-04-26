# Agent Brief: Cross-System Integration & Wiring

## Goal

After the four prior briefs (`agent-brief-homepage-glance.md`, `agent-brief-crowdsec.md`, `agent-brief-litellm.md`, `agent-brief-karakeep.md`) are deployed and verified, this brief wires everything together so the parts act as one system rather than five disconnected ones.

In scope:

1. **UniFi → Wazuh** — forward UniFi syslog into the existing Wazuh manager for SIEM coverage of network events.
2. **UniFi → CrowdSec** — feed UniFi syslog as a CrowdSec log source so CrowdSec scenarios can act on UniFi-detected events.
3. **CrowdSec → UniFi** — verify the blocklist mirror loop set up in the CrowdSec brief is closed (UniFi consuming CrowdSec decisions).
4. **Open-WebUI and n8n cutover to LiteLLM** — route AI traffic through the new gateway instead of directly at Ollama.
5. **Homepage discovery audit and gap-fill** — ensure every reachable service has the right annotations.
6. **Observability wiring** — ServiceMonitors and Discord alerts for CrowdSec and LiteLLM.
7. **Authentik forward-auth** — investigate, and only proceed if a clean pattern is achievable.

Out of scope: anything that would substantially change the four base apps' deployments. If a wiring step requires changes there, surface it as a separate PR.

## Prerequisite check

Before starting, verify all four prior PRs are merged and reconciled:

```bash
flux get hr -n home homepage glance
flux get hr -n security crowdsec
flux get hr -n ai litellm karakeep
```

All five HelmReleases must be `Ready=True`. If any are not, stop and fix that first.

## Phase 1 — UniFi → Wazuh (SIEM detection)

### What's already in place

`kubernetes/apps/security/wazuh/app/manager.yaml` already configures the Wazuh manager to listen for syslog on port 514 (TCP and UDP) with `<allowed-ips>0.0.0.0/0</allowed-ips>`. So the manager is ready — only the cluster-side network exposure and UniFi-side config are missing.

### Work to do

**Step 1: Expose Wazuh syslog port via Cilium L2 announcement (LoadBalancer service).**

The Cilium gateway is HTTP-only, so syslog needs its own LB. Create:

`kubernetes/apps/security/wazuh/app/service-syslog.yaml`

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: wazuh-syslog
  namespace: security
  annotations:
    lbipam.cilium.io/ips: "192.168.42.250"  # CHOOSE an IP from the user's existing LB pool
    external-dns.alpha.kubernetes.io/hostname: wazuh-syslog.${SECRET_DOMAIN}
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"
spec:
  type: LoadBalancer
  selector:
    app: wazuh-manager   # match the manager pod's selector — VERIFY against existing manager.yaml
  ports:
    - name: syslog-udp
      port: 514
      targetPort: 514
      protocol: UDP
    - name: syslog-tcp
      port: 514
      targetPort: 514
      protocol: TCP
```

Before committing, the agent MUST:

1. Read the existing `manager.yaml` to confirm the pod selector label.
2. Inspect the existing Cilium L2 announcement / IP pool config (look in `kubernetes/apps/kube-system/cilium/app/networks.yaml` or similar) to pick an IP that is in-pool but not already assigned. If unsure, leave a clear placeholder and surface it as a TODO.

Add to `kubernetes/apps/security/wazuh/app/kustomization.yaml`:
```yaml
resources:
  - ./service-syslog.yaml
  # ... existing entries
```

**Step 2: UniFi controller config (manual, surface as TODO).**

Document, do not automate. UniFi config lives in the controller, not Git.

```
UniFi Controller → Settings → System → Application Configuration → Remote Logging
  Enable: Syslog Server
  Host: 192.168.42.250         (the LB IP from Step 1)
  Port: 514
  Protocol: UDP
  Include: Network Events, Threat Detection (if licensed), Admin Activity
```

For UDM/UDR units, repeat under each device's settings if they aren't already covered by the controller-level log forwarding (modern UniFi OS does aggregate, but verify in the device's syslog config).

**Step 3: Add Wazuh decoders for UniFi (optional but high-value).**

Wazuh's generic syslog decoders capture UniFi events but don't pull out structured fields. Add a custom decoder ConfigMap mounted to `/var/ossec/etc/decoders/local_decoder.xml`.

`kubernetes/apps/security/wazuh/app/manager-custom-decoders.yaml`

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: wazuh-manager-custom-decoders
  namespace: security
data:
  unifi_decoders.xml: |
    <decoder name="unifi">
      <prematch>^[A-Za-z]{3} \d+ \d\d:\d\d:\d\d \S+ </prematch>
    </decoder>

    <decoder name="unifi-firewall">
      <parent>unifi</parent>
      <prematch>kernel: \[[A-Z_]+\] </prematch>
      <regex>kernel: \[(\S+)\] IN=(\S+) OUT=(\S*) MAC=\S* SRC=(\S+) DST=(\S+).*PROTO=(\S+)</regex>
      <order>action, in_iface, out_iface, srcip, dstip, protocol</order>
    </decoder>

    <decoder name="unifi-threat">
      <parent>unifi</parent>
      <prematch>THREAT</prematch>
      <regex>THREAT signature_id="(\S+)" signature="([^"]+)" src=(\S+) dst=(\S+)</regex>
      <order>signature_id, signature, srcip, dstip</order>
    </decoder>
  unifi_rules.xml: |
    <group name="unifi,">
      <rule id="100100" level="5">
        <decoded_as>unifi</decoded_as>
        <description>UniFi: generic event</description>
      </rule>
      <rule id="100101" level="7">
        <if_sid>100100</if_sid>
        <field name="action">DROP</field>
        <description>UniFi firewall: $(srcip) → $(dstip) blocked</description>
      </rule>
      <rule id="100102" level="10">
        <if_sid>100100</if_sid>
        <decoded_as>unifi-threat</decoded_as>
        <description>UniFi IDS: $(signature) from $(srcip)</description>
        <group>ids,</group>
      </rule>
    </group>
```

The exact regex needs validation against actual log lines. The agent should:

1. After Step 1+2 are applied, capture 30 minutes of real UniFi syslog into Wazuh.
2. Inspect samples: `kubectl -n security exec deploy/wazuh-manager -- tail -100 /var/ossec/logs/archives/archives.log`
3. Adjust the regex if it doesn't match. Surface the ConfigMap content in the PR with a note that it is a starter set and will need tuning.

Mount the ConfigMap by patching the existing manager Deployment/StatefulSet:

```yaml
volumes:
  - name: custom-decoders
    configMap:
      name: wazuh-manager-custom-decoders
volumeMounts:
  - name: custom-decoders
    mountPath: /var/ossec/etc/decoders/local_decoder.xml
    subPath: unifi_decoders.xml
  - name: custom-decoders
    mountPath: /var/ossec/etc/rules/local_rules.xml
    subPath: unifi_rules.xml
```

Restart the manager pod so it re-reads rules.

### Phase 1 verification

1. UniFi LB endpoint reachable from a workstation:
   ```bash
   nc -zv -u 192.168.42.250 514     # UDP
   nc -zv 192.168.42.250 514        # TCP
   ```
2. Logs flowing into Wazuh archives:
   ```bash
   kubectl -n security exec deploy/wazuh-manager -- tail -f /var/ossec/logs/archives/archives.log
   # Trigger a UniFi event (block a test client, etc.) and confirm it appears
   ```
3. Decoded events visible in Wazuh dashboard:
   - Open `https://wazuh.${SECRET_DOMAIN}` → Discover → filter `rule.groups: unifi`
4. Rule 100102 fires on UniFi IDS events (if user has the appropriate UniFi subscription).

## Phase 2 — UniFi → CrowdSec (closed-loop prevention)

### Architecture

UniFi already forwards syslog to Wazuh after Phase 1. To get CrowdSec to act on UniFi events too, add a second syslog destination — CrowdSec's agent listening on a different port.

```
            ┌───────► Wazuh syslog 514/UDP   (SIEM, alerting)
UniFi ──────┤
            └───────► CrowdSec agent 1515/UDP  (parse, decide, push to LAPI)
                                │
                                ▼
                         CrowdSec LAPI
                                │
                                ▼
                       Blocklist mirror URL
                                │
                                ▼
                       UniFi IP Group from URL  (enforce at WAN)
```

### Work to do

**Step 1: Configure the CrowdSec agent for syslog input.**

Edit `kubernetes/apps/security/crowdsec/app/helmrelease.yaml` to add a syslog acquisition. Append to the `agent.acquisition` list:

```yaml
- source: syslog
  listen_addr: 0.0.0.0
  listen_port: 1515
  labels:
    type: syslog
    source: unifi
```

And add a corresponding service so syslog can reach the agent pods. Because the agent runs as a DaemonSet, expose the syslog port via a `Service` of type `LoadBalancer` selecting the agent pods:

`kubernetes/apps/security/crowdsec/app/service-syslog.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: crowdsec-agent-syslog
  namespace: security
  annotations:
    lbipam.cilium.io/ips: "192.168.42.251"   # next free LB IP
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local       # preserves source IP (critical for CrowdSec)
  selector:
    app.kubernetes.io/name: crowdsec
    app.kubernetes.io/component: agent
  ports:
    - name: syslog-udp
      port: 1515
      targetPort: 1515
      protocol: UDP
```

`externalTrafficPolicy: Local` is mandatory here — without it, CrowdSec sees the cluster CNI's masquerade IP for every event and decisions are useless.

**Step 2: Install a CrowdSec collection for syslog/firewall scenarios.**

Add to the agent's `COLLECTIONS` env in the HelmRelease values:

```
crowdsecurity/syslog-logs
crowdsecurity/iptables    # already present from base brief, keep
```

If the user's UniFi USG/UDM threat detection events are flowing in (Phase 1 Step 2), also consider parsers from the community hub. Surface as TODO: `cscli parsers list --remote` and look for unifi-tagged parsers; `cscli parsers install <name>` if any exist. As of this writing the official hub doesn't ship a UniFi-specific parser, so initial value is in the generic syslog/iptables scenarios applied to UniFi traffic.

**Step 3: Add UniFi as a second syslog target on the controller.**

Manual step, surface as TODO. UniFi only allows one syslog server in the GUI. Workaround:

- **Preferred:** run a tiny syslog forwarder (rsyslog or syslog-ng) inside the cluster as a fan-out: UniFi sends to one IP, the forwarder copies to both Wazuh and CrowdSec.
- **Alternative:** Some UniFi controllers support multiple destinations via `config.gateway.json` overrides. Skip this — too brittle across firmware updates.

**Run the syslog fan-out.** Add a small `syslog-relay` Deployment in the `security` namespace using the upstream `syslog-ng` image:

`kubernetes/apps/security/syslog-relay/`

- `ks.yaml`
- `app/kustomization.yaml`
- `app/helmrelease.yaml` (bjw-s app-template wrapping `linuxserver/syslog-ng` or `balabit/syslog-ng`)
- `app/configmap.yaml` with config:

```
@version: 4.4
@include "scl.conf"

source s_unifi {
  network(
    transport("udp")
    port(514)
    flags(no-parse)
  );
};

destination d_wazuh {
  network("wazuh-manager.security.svc.cluster.local"
    transport("udp")
    port(514)
  );
};

destination d_crowdsec {
  network("crowdsec-agent-syslog.security.svc.cluster.local"
    transport("udp")
    port(1515)
  );
};

log {
  source(s_unifi);
  destination(d_wazuh);
  destination(d_crowdsec);
};
```

Expose the relay via its own LB IP (`192.168.42.252`). Update the UniFi controller's syslog target from `192.168.42.250` (direct Wazuh) to `192.168.42.252` (relay). The Phase 1 Wazuh LB service can stay — useful for testing — but UniFi now points at the relay.

**Step 4: Confirm the CrowdSec → UniFi blocklist mirror is operating.**

This was implemented in the CrowdSec brief. Verify it now:

- `curl -s https://crowdsec-mirror.${SECRET_DOMAIN}/security/blocklist | wc -l` — non-zero
- UniFi controller → Network → Settings → IP Groups → "CrowdSec Community" → confirm IP count matches the mirror output
- UniFi → Traffic Rules → confirm a blocking rule references the IP group

### Phase 2 verification

1. CrowdSec agent reports syslog acquisition is active:
   ```bash
   kubectl -n security exec ds/crowdsec-agent -- cscli metrics | grep syslog
   ```
2. Inject a known-bad IP via UniFi (block a known scanner IP, generate a fake threat event):
   - Confirm decision appears: `cscli decisions list | grep <ip>`
3. Closed loop test:
   - Add a test decision: `cscli decisions add --ip 198.51.100.42 --duration 1h`
   - Wait ≤15 minutes for UniFi blocklist refresh
   - Confirm IP appears in UniFi IP Group
4. End-to-end:
   - Trigger a CrowdSec scenario (e.g., scan repeatedly from a controlled IP against the cluster ingress)
   - Confirm the IP gets blocked at CrowdSec → blocklist mirror updates → UniFi pulls update → IP blocked at WAN

## Phase 3 — Open-WebUI and n8n cutover to LiteLLM

### Why

Currently both apps talk directly to Ollama. Routing through LiteLLM gives unified key management, spend tracking, fallbacks (Ollama → Anthropic → OpenAI), and a single place to add new models.

### Work to do

**Step 1: Generate a LiteLLM virtual key for each consumer.**

After LiteLLM is deployed, create dedicated keys via the UI or CLI:

```bash
curl -X POST https://litellm.${SECRET_DOMAIN}/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias": "open-webui", "models": ["llama3.1", "claude-sonnet"], "max_budget": 50.0}'
```

Repeat for `n8n`. Save the returned `key` values to SOPS — one secret update per app.

**Step 2: Open-WebUI cutover.**

Edit `kubernetes/apps/ai/open-webui/app/helmrelease.yaml`. Replace direct Ollama config with OpenAI-compatible config pointing at LiteLLM:

Current:
```yaml
env:
  OLLAMA_BASE_URL: "http://ollama.ai.svc.cluster.local:11434"
```

After:
```yaml
env:
  ENABLE_OPENAI_API: "true"
  OPENAI_API_BASE_URL: "http://litellm.ai.svc.cluster.local:4000/v1"
  OPENAI_API_KEY:
    valueFrom:
      secretKeyRef:
        name: open-webui-secrets
        key: LITELLM_KEY
  # Optional: keep direct Ollama as a fallback discovery path
  ENABLE_OLLAMA_API: "true"
  OLLAMA_BASE_URL: "http://ollama.ai.svc.cluster.local:11434"
```

Add the `LITELLM_KEY` to `kubernetes/apps/ai/open-webui/app/secret.sops.yaml` (re-encrypt with SOPS).

After deploy, log into Open-WebUI as admin → Settings → Connections → confirm `OpenAI API` shows the LiteLLM endpoint and that `Models` lists the LiteLLM model aliases (`llama3.1`, `claude-sonnet`, etc.).

**Step 3: n8n cutover.**

n8n uses LiteLLM via its OpenAI/Anthropic credentials objects. The change is at the credential level inside n8n, not in YAML. Document as a TODO:

```
n8n → Credentials → New
  Type: OpenAI
  API Key: <LITELLM virtual key for n8n>
  Base URL: http://litellm.ai.svc.cluster.local:4000/v1

Then update existing AI workflow nodes to use this credential.
```

### Phase 3 verification

1. Open-WebUI connection test passes (Settings → Connections → Test).
2. Send a chat message in Open-WebUI; confirm it routes through LiteLLM:
   ```bash
   kubectl -n ai logs deploy/litellm | grep "model=llama3.1"
   ```
3. LiteLLM spend tracking shows requests under the `open-webui` key alias.
4. n8n test workflow with an OpenAI/Anthropic node executes successfully.

## Phase 4 — Homepage discovery audit

### Existing state to discover

**Important:** Before touching anything, the agent must `grep -r "gethomepage.dev" kubernetes/` to enumerate which HTTPRoutes already have annotations. Open-WebUI is known to have them. There may be others. Do not duplicate.

### Work to do

**Step 1: Build a coverage matrix.**

Produce a list of every HTTPRoute in `kubernetes/apps/**` and mark which have homepage annotations and which don't. Surface this matrix in the PR description.

**Step 2: Add annotations to high-value gaps.**

Priority list — annotate these if not already annotated:

- *arr stack: Sonarr, Radarr, Lidarr, Bazarr, Prowlarr (use the `*arr` widget types)
- Download: SABnzbd, slskd
- Request: Seerr
- Library: Jellyfin (widget: jellyfin), Audiobookshelf, BookLore, Immich
- Stats: Jellystat
- AI: LiteLLM (widget: glances or generic), Karakeep, n8n, Meilisearch (no widget — bookmark only)
- Home: Mealie, EMQX (no widget — bookmark only), Actual Budget
- Security: Authentik (no widget — bookmark only), Wazuh, CrowdSec dashboard (if the upstream chart exposes one)
- Observability: Grafana, Prometheus (Alertmanager UI), Thanos
- 3D Printing: Bambu Buddy
- Games: RomM
- Radio: MeshMonitor

Each annotation block follows the pattern in the Homepage brief. Widget API keys go through the `homepage-widget-keys` secret created in the Homepage brief — if a key isn't already in that secret, add it (and update the SOPS file).

**Step 3: Group order in `settings.yaml`.**

Update Homepage's `settings.yaml` (in `kubernetes/apps/home/homepage/app/config/`) to declare a stable group order so the dashboard isn't a random sort:

```yaml
layout:
  Media:
    style: row
    columns: 4
  AI:
    style: row
    columns: 3
  Home:
    style: row
    columns: 3
  Security:
    style: row
    columns: 3
  Observability:
    style: row
    columns: 3
  Infrastructure:
    style: row
    columns: 3
  Other:
    style: row
    columns: 3
```

### Phase 4 verification

1. Reload `https://homepage.${SECRET_DOMAIN}` — every annotated service appears in the right group.
2. Widgets show live data (queue depth, free space, etc.) for the *arr stack and Jellyfin.
3. No 401/403 errors in the homepage pod logs:
   ```bash
   kubectl -n home logs deploy/homepage | grep -iE "unauthorized|forbidden"
   ```

## Phase 5 — Observability wiring

### CrowdSec ServiceMonitor

CrowdSec exposes Prometheus metrics on the LAPI and on each agent. Add `kubernetes/apps/security/crowdsec/app/servicemonitor.yaml` mirroring `kubernetes/apps/observability/unpoller/app/servicemonitor.yaml`. Two ServiceMonitor resources — one for LAPI, one for the agent DaemonSet.

### LiteLLM ServiceMonitor

LiteLLM exposes metrics at `/metrics` on port 4000. Add `kubernetes/apps/ai/litellm/app/servicemonitor.yaml`.

### Grafana dashboards

Import (manually, surface as TODO):

- **CrowdSec Overview** — official dashboard ID 19011 (verify current ID at grafana.com)
- **LiteLLM Overview** — community dashboard from BerriAI's repo
- **UniFi Threat Events** — derive from existing unpoller dashboard, add a panel for `rule.groups:unifi` events from Wazuh's indexer if a Wazuh data source is configured in Grafana (check existing data sources first)

### Alertmanager → Discord rules for CrowdSec

The repo already has `alertmanager-discord-bot` in `kubernetes/apps/observability/`. Add a new `PrometheusRule`:

`kubernetes/apps/security/crowdsec/app/prometheusrule.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: crowdsec-rules
  namespace: security
spec:
  groups:
    - name: crowdsec
      rules:
        - alert: CrowdSecLAPIDown
          expr: up{job="crowdsec-lapi"} == 0
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "CrowdSec LAPI is down"
        - alert: CrowdSecHighDecisionRate
          expr: rate(cs_active_decisions[5m]) > 10
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "CrowdSec is making decisions at >10/min — possible attack in progress"
        - alert: CrowdSecBouncerDisconnected
          expr: cs_bouncer_last_pull_seconds > 300
          for: 5m
          labels: { severity: warning }
          annotations:
            summary: "CrowdSec bouncer {{ $labels.bouncer }} hasn't pulled decisions in 5+ min"
```

### Phase 5 verification

1. Both ServiceMonitors picked up by Prometheus:
   ```bash
   kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090 &
   curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | test("crowdsec|litellm")) | .health'
   ```
2. Metrics scraping (non-zero values):
   ```
   curl -s "localhost:9090/api/v1/query?query=cs_active_decisions"
   curl -s "localhost:9090/api/v1/query?query=litellm_total_requests"
   ```
3. Trigger a test alert (stop the LAPI pod for >5min) and confirm Discord receives notification.

## Phase 6 — Authentik forward-auth (investigate first)

### What we know

Authentik is deployed at `kubernetes/apps/security/authentik/` and serves as an OIDC provider. Apps like Mealie consume it via OIDC client (see `mealie-oidc-secret` env in `kubernetes/apps/home/mealie/app/helmrelease.yaml`).

There is **no current pattern** in the repo for HTTPRoute-level forward-auth using Authentik's proxy outpost. A `grep -r "extensionRef\|HTTPRouteFilter\|forward.*auth" kubernetes/` returned nothing.

### Decision rule for the agent

This phase is **conditional**. Do NOT invent a new pattern. Specifically:

- **If** Cilium Gateway-API supports `HTTPRouteFilter` with `extensionRef` to an Authentik proxy outpost (verify against Cilium's current docs for the version pinned in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`), AND a working community example exists for this exact stack, THEN proceed with a single high-value pilot — pick **Wazuh dashboard** as the pilot (it currently has no auth-on-the-edge protection beyond its own login).
- **Otherwise**, document a Plan B: deploy Authentik's proxy outpost as an `oauth2-proxy`-style sidecar in front of selected services, OR convert the relevant apps to native OIDC clients (preferred long-term but more per-app work).

In either case, do not silently apply a half-working setup. Surface findings in the PR description with a recommendation.

### If proceeding

Pilot scope (one app only): Wazuh. Reasons: highly sensitive, not currently behind any external auth at the gateway level, easy to test.

Steps (only if the prereq research passed):

1. Create an Authentik proxy provider for `https://wazuh.${SECRET_DOMAIN}` in the Authentik admin UI. Surface this as a manual step.
2. Deploy an Authentik outpost of type `proxy` in the cluster (Authentik docs: `https://goauthentik.io/docs/outposts`).
3. Add the `extensionRef` filter to Wazuh's HTTPRoute pointing at the outpost.
4. Verify accessing `https://wazuh.${SECRET_DOMAIN}` redirects to Authentik for auth, and that authenticated users land back on the Wazuh dashboard.

If this works, leave a follow-up issue for rolling out to other admin tools (Grafana, Homepage, Karakeep, Authentik admin itself, Wazuh manager API). Do NOT batch-apply to all of them in this PR.

## PR strategy

This is too much for one PR. Split into:

1. **PR 1 — UniFi → Wazuh.** Phase 1 only. Smallest, lowest risk.
2. **PR 2 — Syslog relay + UniFi → CrowdSec.** Phase 2. Depends on PR 1 to flip UniFi target.
3. **PR 3 — Homepage discovery audit.** Phase 4. Independent, low risk.
4. **PR 4 — Open-WebUI / n8n LiteLLM cutover.** Phase 3. Independent.
5. **PR 5 — CrowdSec + LiteLLM observability.** Phase 5.
6. **PR 6 — Authentik forward-auth pilot.** Phase 6, only if research passed.

Open all six with clear descriptions linking back to this brief. Tag each with `integration` so they're easy to find as a cohort.

## Things to NOT do

- Do not point UniFi at the cluster's pod network directly. Use LB IPs.
- Do not skip `externalTrafficPolicy: Local` on the CrowdSec syslog service — source IPs matter.
- Do not enable both old (`OLLAMA_BASE_URL`) and new (`OPENAI_API_BASE_URL`) endpoints in Open-WebUI without testing — model lists may collide and confuse the UI's model picker.
- Do not commit LiteLLM virtual keys unencrypted in app secrets.
- Do not invent an Authentik forward-auth pattern that doesn't exist in upstream docs. If the pattern doesn't exist cleanly, stop and document.
- Do not bulk-apply Homepage annotations to apps that already have them. Audit first.
- Do not alter the Wazuh manager pod selector — many things depend on it; only add a new Service that selects it.

## Memory note

This brief assumes the cluster state captured in the project memory file `project_clouddrop.md` (read at start of conversation). If anything has materially changed since then — new namespaces, new gateways, removed apps — re-read the cluster state before applying.

## Deliverable

Six PRs as listed under "PR strategy", each with:

- Self-contained scope (no cross-PR dependencies that aren't already merged)
- Verification output captured in the PR description (commands run, results)
- Explicit list of manual/UI steps the user must perform (UniFi controller config, Authentik admin, n8n credential creation)
- Encrypted SOPS files only
