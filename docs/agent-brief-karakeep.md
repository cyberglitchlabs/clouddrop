# Agent Brief: Deploy Karakeep to clouddrop

## Goal

Add Karakeep (formerly Hoarder) — a self-hosted bookmark manager with built-in AI tagging, full-text search, and screenshot/snapshot capture. Outcome:

- Web UI at `https://karakeep.${SECRET_DOMAIN}`
- AI auto-tagging using the existing in-cluster Ollama
- Full-text search via a **dedicated** Meilisearch instance (do not share the existing `meilisearch` deployment — see "Why a dedicated Meilisearch" below)
- Browserless/Chromium for clean URL snapshots
- Postgres backend via CloudNative-PG

## Repository conventions

Re-read `agent-brief-homepage-glance.md`'s "Repository conventions" section. Place under `kubernetes/apps/ai/karakeep/` (it slots naturally with the other AI-adjacent apps and shares Ollama). Use bjw-s `app-template`. SOPS-encrypt all secrets.

## Architecture

Karakeep is a multi-component app. You will deploy four containers across two HelmReleases (or one HR with multiple controllers):

```
┌────────────────────────────────────────────────────────────────────┐
│ HelmRelease: karakeep                                              │
│  ┌────────────────────┐   ┌────────────────────┐                   │
│  │ Controller: web    │   │ Controller: worker │                   │
│  │ ghcr.io/karakeep-  │   │ ghcr.io/karakeep-  │                   │
│  │   app/karakeep     │   │   app/karakeep     │   (same image,    │
│  │ Cmd: web (default) │   │ Cmd: workers       │    different cmd) │
│  └────────────────────┘   └────────────────────┘                   │
│  ┌────────────────────┐   ┌────────────────────┐                   │
│  │ Controller:        │   │ Controller:        │                   │
│  │   meilisearch      │   │   browserless      │                   │
│  │ getmeili/          │   │ ghcr.io/browser-   │                   │
│  │   meilisearch      │   │   less/chromium    │                   │
│  └────────────────────┘   └────────────────────┘                   │
└────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ karakeep-postgres   │
                 │  (CNPG cluster)     │
                 └─────────────────────┘
                            │
                            ▼
                 http://ollama.ai.svc.cluster.local:11434  (existing)
```

### Why a dedicated Meilisearch (not the existing one)

The existing `meilisearch` deployment in `kubernetes/apps/ai/meilisearch/` is a general-purpose instance. Sharing it across apps means:

1. Index name collisions are possible.
2. The existing instance has its own master key tied to its consumers.
3. Karakeep's reindex operations could blow up unrelated indexes.
4. It uses a `wipe-on-version-mismatch` init container that would also wipe Karakeep's indexes if the versions diverge.

Cost of dedicated Meilisearch: ~256Mi memory, ~5Gi disk. Worth it for isolation.

### Why Browserless

Karakeep can use a built-in Chromium for snapshots, but in a container that's flaky (memory limits, missing fonts, no /dev/shm sizing). The recommended path is to run Browserless (a managed Chromium) as a sidecar service, and point Karakeep at it via the `BROWSER_WEB_URL` env. This is the upstream-recommended deployment shape.

## Images and verification

Verify these against upstream before committing:

- `ghcr.io/karakeep-app/karakeep:<tag>` — verify at https://github.com/karakeep-app/karakeep/pkgs/container/karakeep
- `getmeili/meilisearch:<tag>` — match the major version Karakeep declares as compatible in its release notes (Meilisearch v1.x is sensitive to version drift)
- `ghcr.io/browserless/chromium:<tag>` (Browserless v2 line)

## Database

Mirror `kubernetes/apps/home/mealie/app/postgres-cluster.yaml`. Cluster name: `karakeep-postgres`. CNPG-generated secret: `karakeep-postgres-app`.

Karakeep expects a `DATABASE_URL` in standard Postgres URI form. Use the CNPG-generated `uri` key directly.

## Secrets

`secret.sops.yaml` with these keys (encrypt before commit):

- `NEXTAUTH_SECRET` — random 32+ char string. Used to sign session cookies.
- `MEILI_MASTER_KEY` — random 32+ char string. Master key for the dedicated Meilisearch.
- `OAUTH_CLIENT_SECRET` — placeholder, left blank for now (user can wire up Authentik OIDC later).

## Configuration via env vars

Karakeep is configured entirely via env. Key vars for this deployment:

```yaml
env:
  TZ: America/Chicago

  # Database
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: karakeep-postgres-app
        key: uri

  # Auth
  NEXTAUTH_URL: https://karakeep.${SECRET_DOMAIN}
  NEXTAUTH_SECRET:
    valueFrom:
      secretKeyRef:
        name: karakeep-secrets
        key: NEXTAUTH_SECRET
  DISABLE_SIGNUPS: "true"     # invite-only after first user

  # Search
  MEILI_ADDR: http://karakeep-meilisearch:7700
  MEILI_MASTER_KEY:
    valueFrom:
      secretKeyRef:
        name: karakeep-secrets
        key: MEILI_MASTER_KEY

  # Browserless / Chrome
  BROWSER_WEB_URL: http://karakeep-browserless:3000
  CRAWLER_FULL_PAGE_SCREENSHOT: "true"
  CRAWLER_STORE_SCREENSHOT: "true"

  # AI tagging via existing Ollama
  OLLAMA_BASE_URL: http://ollama.ai.svc.cluster.local:11434
  INFERENCE_TEXT_MODEL: llama3.1     # verify against `ollama list` output
  INFERENCE_IMAGE_MODEL: llava       # only if pulled; else omit
  INFERENCE_LANG: english
  INFERENCE_JOB_TIMEOUT_SEC: "120"
  CRAWLER_NUM_WORKERS: "2"
  INFERENCE_NUM_WORKERS: "1"

  # Storage paths
  DATA_DIR: /data
```

The agent must `kubectl -n ai exec deploy/ollama -- ollama list` and confirm the model named in `INFERENCE_TEXT_MODEL` is actually pulled. If `llava` isn't pulled, omit `INFERENCE_IMAGE_MODEL` entirely (image tagging will be skipped, not errored — but the env var being set to a missing model causes log noise).

## Persistence

Karakeep stores uploaded assets, screenshots, and full-page archives on disk. Use a PVC backed by `qnap-nfs` (consistent with the rest of the cluster's pattern for non-critical persistent data):

```yaml
persistence:
  data:
    enabled: true
    type: persistentVolumeClaim
    storageClass: qnap-nfs
    accessMode: ReadWriteOnce
    size: 50Gi
    advancedMounts:
      karakeep:
        web:
          - path: /data
        worker:
          - path: /data
  meili-data:
    enabled: true
    type: persistentVolumeClaim
    storageClass: qnap-nfs
    accessMode: ReadWriteOnce
    size: 5Gi
    advancedMounts:
      karakeep:
        meilisearch:
          - path: /meili_data
```

Karakeep's web and worker controllers must mount `/data` to the SAME PVC (RWO is fine because both pods can be co-scheduled to the same node — pin them together via pod affinity, OR use ReadWriteMany on NFS which is what `qnap-nfs` already supports). Confirm `qnap-nfs` storage class actually supports RWX before relying on that; if it doesn't, switch the access mode to `ReadWriteOnce` and add `podAffinity` to keep web and worker on the same node.

## HelmRelease structure

This is the most complex bjw-s app-template values block in the repo. Use a single controller with multiple containers OR (cleaner) one HelmRelease with multiple controllers as shown in the architecture diagram. The controllers approach is cleaner because the four components have different scaling characteristics and probes.

Sketch:

```yaml
controllers:
  karakeep:
    strategy: RollingUpdate
    containers:
      web:
        image: { repository: ghcr.io/karakeep-app/karakeep, tag: <verified> }
        env: { ... see above ... }
        envFrom:
          - secretRef: { name: karakeep-secrets }
        probes:
          liveness:  { custom: true, spec: { httpGet: { path: /api/health, port: 3000 }, initialDelaySeconds: 60, periodSeconds: 30 } }
          readiness: { custom: true, spec: { httpGet: { path: /api/health, port: 3000 }, initialDelaySeconds: 30, periodSeconds: 15 } }
      worker:
        image: { repository: ghcr.io/karakeep-app/karakeep, tag: <verified> }
        command: ["/bin/sh", "-c", "node --experimental-specifier-resolution=node packages/workers/index.js"]
        env: { ... same env block ... }
        envFrom:
          - secretRef: { name: karakeep-secrets }
        # No HTTP probe; use exec or rely on container restart
      meilisearch:
        image: { repository: getmeili/meilisearch, tag: <verified> }
        env:
          MEILI_NO_ANALYTICS: "true"
          MEILI_ENV: production
        envFrom:
          - secretRef: { name: karakeep-secrets }    # provides MEILI_MASTER_KEY
        probes:
          liveness:  { custom: true, spec: { httpGet: { path: /health, port: 7700 } } }
          readiness: { custom: true, spec: { httpGet: { path: /health, port: 7700 } } }
      browserless:
        image: { repository: ghcr.io/browserless/chromium, tag: <verified> }
        env:
          TIMEOUT: "60000"
          CONCURRENT: "5"
          TOKEN: "" # browserless v2 supports unauthenticated when bound to localhost / cluster-internal
        probes:
          liveness:  { custom: true, spec: { httpGet: { path: /pressure, port: 3000 } } }

service:
  web:
    controller: karakeep
    ports:
      http: { port: 3000, targetPort: 3000 }
  meilisearch:
    controller: karakeep
    ports:
      http: { port: 7700, targetPort: 7700 }
  browserless:
    controller: karakeep
    ports:
      http: { port: 3000, targetPort: 3000 }
```

The `karakeep-meilisearch` and `karakeep-browserless` services need to resolve the URLs in the env block. Verify the bjw-s app-template generates services named `karakeep-<service-key>` — if naming differs, update the env URLs to match.

## Route

```yaml
route:
  web:
    annotations:
      external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"
    hostnames: ["karakeep.${SECRET_DOMAIN}"]
    parentRefs:
      - name: internal
        namespace: kube-system
        sectionName: https
    rules:
      - backendRefs:
          - identifier: web
            port: 3000
```

Internal-only. Do not expose externally — bookmark archives can contain sensitive content.

## File checklist

- `kubernetes/apps/ai/karakeep/ks.yaml` — `dependsOn: [cloudnative-pg-operator]`
- `kubernetes/apps/ai/karakeep/app/kustomization.yaml`
- `kubernetes/apps/ai/karakeep/app/helmrelease.yaml`
- `kubernetes/apps/ai/karakeep/app/postgres-cluster.yaml`
- `kubernetes/apps/ai/karakeep/app/secret.sops.yaml`

Update `kubernetes/apps/ai/kustomization.yaml` to include `./karakeep/ks.yaml`.

## Verification steps

1. CNPG cluster Ready:
   ```bash
   kubectl -n ai get cluster.postgresql.cnpg.io karakeep-postgres
   ```
2. All four containers in the karakeep pod Running and Ready:
   ```bash
   kubectl -n ai get pods -l app.kubernetes.io/name=karakeep
   ```
3. Web UI loads:
   ```bash
   curl -sI https://karakeep.${SECRET_DOMAIN} | head -1   # expect 200 or 307
   ```
4. First-user signup — sign up via the UI, then immediately set `DISABLE_SIGNUPS: "true"` (already set; verify no further accounts can be created).
5. Add a bookmark:
   - Web UI → Add → paste a URL
   - Worker should pick it up within ~30s
   - Confirm screenshot is generated (visible on the bookmark detail page)
6. AI tagging works:
   - Bookmark detail → check that tags were auto-generated
   - If not, check worker logs:
     ```bash
     kubectl -n ai logs deploy/karakeep -c worker | grep -i "inference\|ollama"
     ```
7. Search works (Meilisearch):
   - UI search bar should return results within a second
   - Verify Meilisearch indexed: `kubectl -n ai exec deploy/karakeep -c meilisearch -- curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" localhost:7700/indexes`

## Things to NOT do

- Do not point Karakeep at the existing shared `meilisearch` service in the `ai` namespace. Use a dedicated instance (see rationale above).
- Do not expose externally. Bookmark archives are private.
- Do not skip the Browserless container. Karakeep's built-in Chromium is unreliable in resource-limited pods.
- Do not commit `NEXTAUTH_SECRET` or `MEILI_MASTER_KEY` unencrypted.
- Do not pin `INFERENCE_TEXT_MODEL` to a model not pulled in Ollama. Verify with `ollama list` first.
- Do not enable `DISABLE_SIGNUPS=false` permanently — only during initial user creation.

## Stretch goals

- Wire OAuth via Authentik OIDC (if other apps in the repo demonstrate the pattern).
- Add a CronJob that triggers periodic re-archiving of bookmarks (Karakeep has an internal scheduler; only do this if it's missing in the deployed version).
- Add Karakeep to Homepage's discovery annotations once Homepage is deployed (per `agent-brief-homepage-glance.md`).

## Deliverable

A single PR titled `feat(ai): add karakeep with dedicated meilisearch and ollama-backed ai tagging`. PR description must:

- List which Ollama model was verified for `INFERENCE_TEXT_MODEL`
- Note the SOPS encryption step
- List the post-deploy steps: sign up first user, then verify `DISABLE_SIGNUPS` enforcement
- Confirm `qnap-nfs` access mode investigation outcome (RWX vs RWO + pod affinity)
