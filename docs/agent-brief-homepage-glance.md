# Agent Brief: Deploy Homepage and Glance to clouddrop

## Goal

Add two dashboard apps to the `clouddrop` Talos+Flux cluster:

1. **Homepage** (`gethomepage/homepage`) — Kubernetes-aware service dashboard. Should auto-discover services from `HTTPRoute` annotations across namespaces.
2. **Glance** (`glanceapp/glance`) — personal landing page with feeds (RSS, GitHub releases, Hacker News, weather, etc.). Static config-driven.

Both should be reachable on the **internal** Cilium gateway only (no Cloudflare exposure). Authentik forward-auth is a stretch goal — wire it up if patterns for other apps already do this; otherwise skip and leave a TODO.

## Repository conventions you must follow

This repo is a fork of `onedr0p/cluster-template`. Read these existing apps before touching anything — they are the template for what you produce:

- `kubernetes/apps/home/mealie/` — full app with postgres + SOPS secret + external HTTPRoute
- `kubernetes/apps/home/actual-budget/` — simpler app, internal-only HTTPRoute, uses existing PVC
- `kubernetes/apps/home/emqx/` — has a separate `httproute.yaml` file (alternative to inline `route` block)
- `kubernetes/apps/home/kustomization.yaml` — bucket-level index that lists each app's `ks.yaml`

### Directory layout per app

```
kubernetes/apps/home/<app>/
  ks.yaml                       # Flux Kustomization, lives in flux-system ns, targets home ns
  app/
    kustomization.yaml          # kustomize, includes ../../../../components/helmrelease-defaults
    helmrelease.yaml            # bjw-s app-template HelmRelease
    pvc.yaml                    # if persistence needed (use storageClass: qnap-nfs)
    rbac.yaml                   # Homepage only — needs cluster-wide read access
    secret.sops.yaml            # if any secrets needed (encrypt with SOPS, see below)
```

### Cluster-specific values you will use

- Helm chart: `bjw-s-app-template` via `OCIRepository` in `flux-system` namespace (use `chartRef`, not `chart`/`version` — see mealie for exact form)
- Default storage class: `qnap-nfs` (NFS to QNAP at 192.168.100.180)
- Domain variable: `${SECRET_DOMAIN}` (envsubst-resolved by Flux)
- Internal gateway parentRef:
  ```yaml
  parentRefs:
    - name: internal
      namespace: kube-system
      sectionName: https
  ```
- For internal-only routes, also add this annotation on the `route`:
  `external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"`
- Timezone env: `TZ: America/Chicago`
- Standard pod security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`, `seccompProfile.type: RuntimeDefault`
- Container security context: `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`

### SOPS

The repo uses SOPS with age. `.sops.yaml` at the root governs encryption rules. Any file ending in `.sops.yaml` MUST be SOPS-encrypted before commit. You can produce the plaintext file and run `sops --encrypt --in-place <file>` (the user will run this — surface the command, do not assume sops/age key availability in your environment). Verify after encryption that the `data:` and `stringData:` fields show `ENC[...]` payloads.

### Renovate

Renovate manages image and chart updates. Use a real, current image tag in your initial commit (don't pin to `latest`). Renovate will keep it current after merge.

---

## App 1: Homepage

### Image and chart

- Container: `ghcr.io/gethomepage/homepage`
- Helm chart: use the bjw-s `app-template` (consistent with rest of repo) — do NOT use the upstream homepage chart.
- Listening port: `3000`
- Verify the latest stable image tag at https://github.com/gethomepage/homepage/releases before committing.

### What's special about Homepage

It needs **cluster-wide RBAC** to auto-discover services. You must create:

- A `ServiceAccount` named `homepage` in the `home` namespace
- A `ClusterRole` with read on `services`, `ingresses` (networking.k8s.io), `httproutes` (gateway.networking.k8s.io), `pods`, `nodes`, `namespaces`
- A `ClusterRoleBinding` tying them together
- The pod must run as that ServiceAccount (`defaultPodOptions.serviceAccountName: homepage` in the HelmRelease values)

### Required environment

```yaml
env:
  TZ: America/Chicago
  HOMEPAGE_ALLOWED_HOSTS: homepage.${SECRET_DOMAIN}
```

`HOMEPAGE_ALLOWED_HOSTS` is mandatory in recent Homepage versions — without it the app refuses requests with the configured hostname.

### Configuration

Homepage reads its config from files in `/app/config`. There are several files: `settings.yaml`, `services.yaml`, `bookmarks.yaml`, `widgets.yaml`, `kubernetes.yaml`, `docker.yaml`. Mount these via a `ConfigMap` projected to `/app/config`.

Minimum starting config:

**`settings.yaml`**
```yaml
title: Homepage
theme: dark
color: slate
headerStyle: clean
language: en
target: _blank
hideVersion: false
providers:
  longhorn:
    url: https://longhorn.${SECRET_DOMAIN}  # remove if Longhorn not deployed
```

**`kubernetes.yaml`** (enables auto-discovery from annotations)
```yaml
mode: cluster
```

**`services.yaml`** — empty list `[]`. Services will populate from `HTTPRoute` annotations (see "Auto-discovery wiring" below).

**`bookmarks.yaml`** — start with one example group, e.g. Dev Tools with a couple of links. User can edit later.

**`widgets.yaml`** — include at minimum:
```yaml
- resources:
    cpu: true
    memory: true
    disk: /
    label: System
- kubernetes:
    cluster:
      show: true
      cpu: true
      memory: true
      showLabel: true
      label: cluster
    nodes:
      show: true
      cpu: true
      memory: true
      showLabel: true
- search:
    provider: duckduckgo
    target: _blank
```

**`docker.yaml`** — empty `{}`.

### Persistence

Homepage's config can live in a ConfigMap (declarative, edits via Git) OR a PVC (edits via the UI). Recommendation: **ConfigMap** to stay GitOps-pure. The UI editor is convenient but breaks reproducibility. Use the bjw-s `persistence` block with `type: configMap` and bind the keys to `/app/config/<file>`.

### HelmRelease values skeleton

```yaml
controllers:
  homepage:
    strategy: RollingUpdate
    containers:
      app:
        image:
          repository: ghcr.io/gethomepage/homepage
          tag: <verified-tag>
        env:
          TZ: America/Chicago
          HOMEPAGE_ALLOWED_HOSTS: homepage.${SECRET_DOMAIN}
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /, port: 3000 }
              initialDelaySeconds: 30
              periodSeconds: 30
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /, port: 3000 }
              initialDelaySeconds: 10
              periodSeconds: 10
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: 50m, memory: 128Mi }
          limits:   { memory: 512Mi }
defaultPodOptions:
  serviceAccountName: homepage
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: { type: RuntimeDefault }
service:
  app:
    controller: homepage
    ports:
      http: { port: 3000 }
persistence:
  config:
    type: configMap
    name: homepage-config
    globalMounts:
      - path: /app/config/settings.yaml
        subPath: settings.yaml
      - path: /app/config/services.yaml
        subPath: services.yaml
      - path: /app/config/widgets.yaml
        subPath: widgets.yaml
      - path: /app/config/bookmarks.yaml
        subPath: bookmarks.yaml
      - path: /app/config/kubernetes.yaml
        subPath: kubernetes.yaml
      - path: /app/config/docker.yaml
        subPath: docker.yaml
  logs:
    type: emptyDir
    globalMounts:
      - path: /app/config/logs
route:
  app:
    annotations:
      external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"
    hostnames: ["homepage.${SECRET_DOMAIN}"]
    parentRefs:
      - name: internal
        namespace: kube-system
        sectionName: https
```

The `homepage-config` ConfigMap is generated by kustomize via a `configMapGenerator` in `app/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: homepage-config
    files:
      - settings.yaml=./config/settings.yaml
      - services.yaml=./config/services.yaml
      - widgets.yaml=./config/widgets.yaml
      - bookmarks.yaml=./config/bookmarks.yaml
      - kubernetes.yaml=./config/kubernetes.yaml
      - docker.yaml=./config/docker.yaml
generatorOptions:
  disableNameSuffixHash: true
```

Place the actual config files under `kubernetes/apps/home/homepage/app/config/`.

### Auto-discovery wiring (do this on representative HTTPRoutes)

Pick 5-10 high-value services and add Homepage discovery annotations to their existing `HTTPRoute` manifests so the dashboard isn't empty on first boot. Suggested set: Jellyfin, Sonarr, Radarr, SABnzbd, Seerr, Grafana, Open-WebUI, Immich, Mealie, Authentik.

Annotation pattern (example for Sonarr):
```yaml
metadata:
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Sonarr"
    gethomepage.dev/group: "Media"
    gethomepage.dev/icon: "sonarr.png"
    gethomepage.dev/description: "TV PVR"
    gethomepage.dev/href: "https://sonarr.${SECRET_DOMAIN}"
    gethomepage.dev/widget.type: "sonarr"
    gethomepage.dev/widget.url: "http://sonarr.media.svc.cluster.local:8989"
    gethomepage.dev/widget.key: "{{ENV_VAR}}"
```

Widget API keys must come from secrets. The cleanest pattern: create a single SOPS-encrypted secret `homepage-widget-keys` in the `home` namespace, project it as env vars on the homepage pod, and reference them via `{{HOMEPAGE_VAR_*}}` in annotations. See https://gethomepage.dev/configs/kubernetes/#using-secrets-in-the-config-files for the official approach. **Do not commit plaintext API keys** — leave the `secret.sops.yaml` with placeholder values and surface a TODO listing which keys the user must fill in (Sonarr, Radarr, Lidarr, Prowlarr, SABnzbd, Bazarr, Jellyfin API key, Jellyseerr, Immich, Grafana service-account token).

### File checklist for Homepage

- `kubernetes/apps/home/homepage/ks.yaml`
- `kubernetes/apps/home/homepage/app/kustomization.yaml`
- `kubernetes/apps/home/homepage/app/helmrelease.yaml`
- `kubernetes/apps/home/homepage/app/rbac.yaml` (ServiceAccount + ClusterRole + ClusterRoleBinding)
- `kubernetes/apps/home/homepage/app/secret.sops.yaml` (widget keys, encrypted)
- `kubernetes/apps/home/homepage/app/config/{settings,services,widgets,bookmarks,kubernetes,docker}.yaml`

---

## App 2: Glance

### Image and chart

- Container: `glanceapp/glance` (Docker Hub) or check `ghcr.io/glanceapp/glance` for OCI mirror
- Helm chart: bjw-s `app-template` again
- Listening port: `8080`
- Verify the latest stable tag at https://github.com/glanceapp/glance/releases

### Configuration

Glance reads `/app/config/glance.yml`. Mount via ConfigMap.

Starter config (`glance.yml`):
```yaml
server:
  host: 0.0.0.0
  port: 8080

theme:
  background-color: 225 14 15
  primary-color: 50 98 73
  contrast-multiplier: 1.1

pages:
  - name: Home
    columns:
      - size: small
        widgets:
          - type: calendar
          - type: weather
            location: <city>, <country>   # TODO user must set
            units: imperial
            hour-format: 12h
      - size: full
        widgets:
          - type: hacker-news
          - type: releases
            repositories:
              - siderolabs/talos
              - fluxcd/flux2
              - cilium/cilium
              - gethomepage/homepage
              - glanceapp/glance
      - size: small
        widgets:
          - type: rss
            limit: 15
            collapse-after: 5
            cache: 12h
            feeds:
              - url: https://www.talos.dev/blog/index.xml
                title: Talos Blog
              - url: https://fluxcd.io/blog/index.xml
                title: Flux Blog
              - url: https://kubernetes.io/feed.xml
                title: Kubernetes Blog
```

### HelmRelease values skeleton

Same shape as Homepage but simpler — no RBAC, no secrets needed for the starter set, no widget keys.

```yaml
controllers:
  glance:
    containers:
      app:
        image:
          repository: glanceapp/glance
          tag: <verified-tag>
        env:
          TZ: America/Chicago
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /, port: 8080 }
              initialDelaySeconds: 20
              periodSeconds: 30
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /, port: 8080 }
              initialDelaySeconds: 10
              periodSeconds: 10
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: 25m, memory: 64Mi }
          limits:   { memory: 256Mi }
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: { type: RuntimeDefault }
service:
  app:
    controller: glance
    ports:
      http: { port: 8080 }
persistence:
  config:
    type: configMap
    name: glance-config
    globalMounts:
      - path: /app/config/glance.yml
        subPath: glance.yml
  cache:
    type: emptyDir
    globalMounts:
      - path: /app/cache
route:
  app:
    annotations:
      external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"
    hostnames: ["start.${SECRET_DOMAIN}"]
    parentRefs:
      - name: internal
        namespace: kube-system
        sectionName: https
```

### File checklist for Glance

- `kubernetes/apps/home/glance/ks.yaml`
- `kubernetes/apps/home/glance/app/kustomization.yaml`
- `kubernetes/apps/home/glance/app/helmrelease.yaml`
- `kubernetes/apps/home/glance/app/config/glance.yml`

---

## Wiring into the bucket

Edit `kubernetes/apps/home/kustomization.yaml` to add both apps:

```yaml
resources:
  - ./mealie/ks.yaml
  - ./emqx/ks.yaml
  - ./actual-budget/ks.yaml
  - ./homepage/ks.yaml
  - ./glance/ks.yaml
```

The `ks.yaml` files themselves should mirror `mealie/ks.yaml` — `targetNamespace: home`, `path: ./kubernetes/apps/home/<app>/app`, `wait: false`, `interval: 1h`, `retryInterval: 1m`. Homepage does NOT depend on `cloudnative-pg-operator`; Glance does NOT either. Drop the `dependsOn` block for both.

---

## Verification steps (run after PR is merged and Flux has reconciled)

1. Flux picked up the new Kustomizations:
   ```
   flux get ks -A | grep -E "homepage|glance"
   ```
   Both should be `Ready=True`.

2. HelmReleases are deployed:
   ```
   flux get hr -n home | grep -E "homepage|glance"
   ```

3. Pods are running:
   ```
   kubectl -n home get pods -l app.kubernetes.io/name=homepage
   kubectl -n home get pods -l app.kubernetes.io/name=glance
   ```

4. Homepage RBAC works (no `Forbidden` errors):
   ```
   kubectl -n home logs deploy/homepage | grep -iE "forbidden|error"
   ```

5. Routes resolve internally:
   ```
   dig @<cluster_dns_gateway_addr> homepage.${SECRET_DOMAIN}
   dig @<cluster_dns_gateway_addr> start.${SECRET_DOMAIN}
   ```

6. Browse to `https://homepage.${SECRET_DOMAIN}` and `https://start.${SECRET_DOMAIN}` from inside the home network. Confirm Homepage shows the cluster widget populated with node CPU/memory; confirm Glance renders the Hacker News and releases widgets.

7. If you added Homepage discovery annotations to existing HTTPRoutes, confirm those services appear in the right groups on the Homepage UI.

---

## Things to NOT do

- Do not expose either dashboard via the `external` gateway. Both are admin tools.
- Do not commit unencrypted secrets. Anything in `secret.sops.yaml` must be SOPS-encrypted before `git add`.
- Do not pin to image tag `latest`. Use specific versions; Renovate will update.
- Do not skip the bjw-s `app-template` chart in favor of upstream homepage/glance Helm charts — this repo is uniformly app-template based and mixing chart sources hurts maintainability.
- Do not add `dependsOn: cloudnative-pg-operator` for these apps — they don't use Postgres.
- Do not edit Homepage's config through its UI for the GitOps version — all changes go via Git.

## Stretch goals (only if time permits and cleanly applicable)

- Wire Authentik forward-auth on both routes if other apps in the repo already demonstrate the pattern (look for `extensionRef` filters on existing HTTPRoutes pointing at an authentik proxy outpost).
- Pre-populate Homepage discovery annotations on the full *arr stack (Sonarr, Radarr, Lidarr, Bazarr, Prowlarr, SABnzbd, Seerr) with placeholder API key references in the secret.

## Deliverable

A single PR titled something like `feat(home): add homepage and glance dashboards` containing:

- All new files listed above
- The bucket `kustomization.yaml` updated
- Any HTTPRoute files touched for Homepage discovery annotations (clearly listed in the PR description)
- A PR description that calls out the SOPS-encryption step the user must run before merge if you generated any `secret.sops.yaml` files in plaintext form
- A list of TODOs the user must complete post-merge: fill in widget API keys, set Glance weather location, optionally enable Authentik forward-auth
