# PosterPilot Jellyfin Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy PosterPilot into the `media` namespace of this Flux-managed cluster so it can pull curated ThePosterDB/MediUX/Fanart.tv posters and apply them directly to Jellyfin, with Posterizarr staying in place as the fallback generator for anything PosterPilot doesn't have a curated set for.

**Architecture:** A new Flux `Kustomization` + `HelmRelease` at `kubernetes/apps/media/posterpilot/`, using the same `bjw-s-app-template` OCIRepository chart every other app in this repo uses (see `kubernetes/apps/media/posterizarr/app/helmrelease.yaml` as the closest sibling). PosterPilot talks to Jellyfin over its HTTP API (`JELLYFIN_URL`/`JELLYFIN_API_KEY`) — no shared filesystem hand-off with Posterizarr, no Plex, no Kometa.

**Tech Stack:** Flux v2 (`kustomize.toolkit.fluxcd.io/v1`, `helm.toolkit.fluxcd.io/v2`), `bjw-s-app-template` Helm chart, SOPS + age for secrets, `juicefs` CSI storage class, Gateway API `HTTPRoute` via the existing `external` Gateway.

## Global Constraints

- Image: `ghcr.io/diegopeixoto/posterpilot`, pinned tag `0.10.0` (verified via `gh release list --repo diegopeixoto/posterpilot`; this repo's convention is bare semver tags, no `v` prefix — confirmed from its `docker-publish.yml` workflow, which tags `ghcr.io/diegopeixoto/posterpilot:${{ inputs.version }}` with `version` values like `0.10.0`). Do not use `latest`.
- Namespace: `media`.
- Container port: `3000` (from the project's own README config table and Dockerfile `EXPOSE 3000`).
- Health check path: `GET /api/health`, returns `{ "status": "ok", "version": "x.y.z" }` with HTTP 200.
- Required env vars for Jellyfin mode: `SERVER_TYPE=jellyfin`, `JELLYFIN_URL`, `JELLYFIN_API_KEY`, `TMDB_KEY`. Optional: `FANART_KEY` (enables the Fanart.tv provider).
- Persistent state lives at `/data` (SQLite db at `/data/posterpilot.db` by default, plus rotating logs at `/data/logs`) — this is the only volume that must survive restarts.
- `/kometa` (`KOMETA_ASSETS_DIR`, default `/kometa`) is where PosterPilot would write a Kometa-compatible YAML export if the "Kometa export" apply method is ever used. This cluster does not run Kometa (see the design doc's "Why not Kometa" section — Kometa is Plex-only and this cluster is Jellyfin-only), so this directory is never read by anything; mount it as an `emptyDir`, not a persistent volume.
- SQLite-backed app state in this repo uses `storageClassName: juicefs` (see `kubernetes/apps/media/radarr/app/pvc-config-juicefs.yaml`), **not** the NFS-backed `qnap-nfs-db-sync` class — NFS file locking is unreliable for SQLite.
- Secrets are SOPS-encrypted with age, following `.sops.yaml`'s rule for `(bootstrap|kubernetes)/.*\.sops\.ya?ml` — only the `stringData` key is encrypted (`encrypted_regex: "^(data|stringData)$"`), the rest of the file stays plaintext. Age key file is at `age.key` in the repo root (`SOPS_AGE_KEY_FILE` env in `Taskfile.yaml`).
- This app's UI is exposed externally via the same Gateway API `external` route pattern as every other media app (`kube-system/external` Gateway, `https` section). Since it's internet-reachable (behind the existing cloudflare-tunnel setup, same as Posterizarr/Jellystat), set `AUTH_MODE=enabled` so PosterPilot enforces its own login rather than relying on network position — mirrors why Posterizarr's own `WebUI.basicAuthEnabled` is `true`.
- HelmRelease `dependsOn` should include both `cloudflare-tunnel` (namespace `network`) and `jellyfin`, matching Posterizarr's own HelmRelease (`kubernetes/apps/media/posterizarr/app/helmrelease.yaml:13-16`) — not just `jellyfin` alone.
- Follow the `bjw-s-app-template` conventions already used throughout `kubernetes/apps/media/*`: `defaultPodOptions.securityContext` with `runAsNonRoot: true`, and since PosterPilot's own Dockerfile has no `USER` directive (so the image defaults to root unless Kubernetes forces otherwise), use the same non-linuxserver-image convention Posterizarr uses: `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch` (not Radarr/Sonarr's `568`, which is the linuxserver.io-specific `abc` user and doesn't apply to this custom Bun image).
- No manual YAML/JSON test suite exists for this repo's Kubernetes manifests. "Tests" in this plan mean: `kubectl kustomize` builds cleanly, the SOPS file round-trips (`ENC[` present, `sops --decrypt` recovers plaintext), and — once committed — Flux actually reconciles the `Kustomization`/`HelmRelease` to `Ready` and the pod reaches `Running 1/1` with a passing health probe. This repo already has live cluster access via `kubectl`/`flux` in this environment; use it to verify each task rather than treating this as unverifiable infra.

---

### Task 1: PVC for PosterPilot's persistent `/data`

**Files:**
- Create: `kubernetes/apps/media/posterpilot/app/pvc-config-juicefs.yaml`

**Interfaces:**
- Produces: a PVC named `posterpilot-juicefs` in namespace `media` that Task 3's HelmRelease references via `persistence.data.existingClaim: posterpilot-juicefs`.

- [ ] **Step 1: Create the PVC manifest**

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: posterpilot-juicefs
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: juicefs
```

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('kubernetes/apps/media/posterpilot/app/pvc-config-juicefs.yaml')))" && echo OK`
Expected: `OK` (no exception)

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/media/posterpilot/app/pvc-config-juicefs.yaml
git commit -m "feat(posterpilot): add juicefs PVC for persistent /data"
```

---

### Task 2: SOPS-encrypted secret for PosterPilot credentials

**Files:**
- Create: `kubernetes/apps/media/posterpilot/app/secret.sops.yaml`

**Interfaces:**
- Produces: a Secret named `posterpilot-secret` in namespace `media` with keys `JELLYFIN_URL`, `JELLYFIN_API_KEY`, `TMDB_KEY`, `FANART_KEY`, referenced by Task 3's HelmRelease via `secretKeyRef.name: posterpilot-secret`.
- Consumes: a Jellyfin API key. Mint a **dedicated** key for PosterPilot (Jellyfin → Dashboard → API Keys → "+") rather than reusing the one already embedded in Posterizarr's `config.json` (`ApiPart.JellyfinAPIKey`), so it can be revoked independently later. `TMDB_KEY` and `FANART_KEY` can reuse the same values already in Posterizarr's `config.json` `ApiPart` block (`tmdbtoken`, `FanartTvAPIKey`) — same provider accounts, no reason to mint new ones.

- [ ] **Step 1: Write the plaintext secret**

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: posterpilot-secret
  namespace: media
type: Opaque
stringData:
  JELLYFIN_URL: https://jellyfin.${SECRET_DOMAIN}
  JELLYFIN_API_KEY: "REPLACE_WITH_DEDICATED_JELLYFIN_API_KEY"
  TMDB_KEY: "REPLACE_WITH_TMDB_KEY"
  FANART_KEY: "REPLACE_WITH_FANART_KEY"
```

Save this to `kubernetes/apps/media/posterpilot/app/secret.sops.yaml`, then replace the three `REPLACE_WITH_*` placeholders with real values before encrypting (mint the Jellyfin key in Jellyfin's dashboard; copy `TMDB_KEY`/`FANART_KEY` from Posterizarr's live config via `kubectl exec -n media <posterizarr-pod> -- cat /config/config.json` if you don't have them on hand separately).

- [ ] **Step 2: Encrypt in place**

Run: `sops --encrypt --in-place kubernetes/apps/media/posterpilot/app/secret.sops.yaml`
Expected: command exits 0; the file's `stringData` block now contains `ENC[...]` values and a `sops:` metadata block is appended.

- [ ] **Step 3: Verify encryption took effect**

Run: `grep -q 'ENC\[' kubernetes/apps/media/posterpilot/app/secret.sops.yaml && echo ENCRYPTED`
Expected: `ENCRYPTED` (this is the exact check `.github/scripts/check-sops-encrypted.sh` runs in pre-commit)

- [ ] **Step 4: Verify it decrypts back correctly**

Run: `sops --decrypt kubernetes/apps/media/posterpilot/app/secret.sops.yaml | grep -A1 JELLYFIN_API_KEY`
Expected: shows the real (non-`REPLACE_WITH_`) value you set in Step 1

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/media/posterpilot/app/secret.sops.yaml
git commit -m "feat(posterpilot): add encrypted Jellyfin/TMDB/Fanart credentials"
```

---

### Task 3: HelmRelease

**Files:**
- Create: `kubernetes/apps/media/posterpilot/app/helmrelease.yaml`

**Interfaces:**
- Consumes: `posterpilot-juicefs` PVC (Task 1), `posterpilot-secret` Secret (Task 2).
- Produces: a `HelmRelease` named `posterpilot` in namespace `media`, a `Service` on port `3000`, and an `HTTPRoute` at `posterpilot.${SECRET_DOMAIN}` — referenced by Task 4's kustomization and Task 5's Flux `Kustomization`.

- [ ] **Step 1: Write the HelmRelease**

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrelease-helm-v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: posterpilot
  namespace: media
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: bjw-s-app-template
    namespace: flux-system
  dependsOn:
    - name: cloudflare-tunnel
      namespace: network
    - name: jellyfin
  values:
    controllers:
      posterpilot:
        strategy: RollingUpdate
        containers:
          app:
            image:
              repository: ghcr.io/diegopeixoto/posterpilot
              tag: "0.10.0"
            env:
              TZ: America/Chicago
              SERVER_TYPE: jellyfin
              AUTH_MODE: enabled
              JELLYFIN_URL:
                valueFrom:
                  secretKeyRef:
                    name: posterpilot-secret
                    key: JELLYFIN_URL
              JELLYFIN_API_KEY:
                valueFrom:
                  secretKeyRef:
                    name: posterpilot-secret
                    key: JELLYFIN_API_KEY
              TMDB_KEY:
                valueFrom:
                  secretKeyRef:
                    name: posterpilot-secret
                    key: TMDB_KEY
              FANART_KEY:
                valueFrom:
                  secretKeyRef:
                    name: posterpilot-secret
                    key: FANART_KEY
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/health
                    port: 3000
                  initialDelaySeconds: 20
                  periodSeconds: 30
                  timeoutSeconds: 5
                  failureThreshold: 3
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/health
                    port: 3000
                  initialDelaySeconds: 20
                  periodSeconds: 15
                  timeoutSeconds: 5
                  failureThreshold: 3
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: false
              capabilities: { drop: ["ALL"] }
            resources:
              requests:
                cpu: 50m
                memory: 256Mi
              limits:
                memory: 1Gi
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
    service:
      app:
        controller: posterpilot
        ports:
          http:
            port: 3000
    persistence:
      data:
        type: persistentVolumeClaim
        existingClaim: posterpilot-juicefs
        globalMounts:
          - path: /data
      kometa:
        type: emptyDir
        globalMounts:
          - path: /kometa
    route:
      app:
        hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
        parentRefs:
          - name: external
            namespace: kube-system
            sectionName: https
        rules:
          - backendRefs:
              - identifier: app
                port: 3000
```

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('kubernetes/apps/media/posterpilot/app/helmrelease.yaml')))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/media/posterpilot/app/helmrelease.yaml
git commit -m "feat(posterpilot): add HelmRelease for Jellyfin curated-poster app"
```

---

### Task 4: App kustomization wiring

**Files:**
- Create: `kubernetes/apps/media/posterpilot/app/kustomization.yaml`

**Interfaces:**
- Consumes: `pvc-config-juicefs.yaml` (Task 1), `secret.sops.yaml` (Task 2), `helmrelease.yaml` (Task 3).
- Produces: a buildable Kustomize root at `kubernetes/apps/media/posterpilot/app` that Task 5's Flux `Kustomization` points `spec.path` at.

- [ ] **Step 1: Write the kustomization**

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
components:
  - ../../../../components/helmrelease-defaults
resources:
  - ./pvc-config-juicefs.yaml
  - ./secret.sops.yaml
  - ./helmrelease.yaml
```

- [ ] **Step 2: Validate the kustomization builds**

Run: `kubectl kustomize kubernetes/apps/media/posterpilot/app | head -5`
Expected: prints rendered YAML starting with `---` and a `PersistentVolumeClaim` (or similar), no errors. If `sops` isn't invoked automatically by `kubectl kustomize` in this environment and it errors on the encrypted secret, confirm instead with `kustomize build --enable-alpha-plugins kubernetes/apps/media/posterpilot/app` or fall back to validating the other two resources individually with `kubectl apply --dry-run=client -f kubernetes/apps/media/posterpilot/app/pvc-config-juicefs.yaml -f kubernetes/apps/media/posterpilot/app/helmrelease.yaml`.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/media/posterpilot/app/kustomization.yaml
git commit -m "feat(posterpilot): wire up app kustomization"
```

---

### Task 5: Flux Kustomization + registration in the media tree

**Files:**
- Create: `kubernetes/apps/media/posterpilot/ks.yaml`
- Modify: `kubernetes/apps/media/kustomization.yaml`

**Interfaces:**
- Consumes: `kubernetes/apps/media/posterpilot/app` (Task 4's buildable path).
- Produces: registers `posterpilot` as a Flux-managed app under the `media` Kustomization tree, the same way `posterizarr` already is.

- [ ] **Step 1: Write the Flux Kustomization**

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app posterpilot
  namespace: media
spec:
  targetNamespace: media
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/media/posterpilot/app
  wait: false
  interval: 30m
  retryInterval: 1m
  dependsOn:
    - name: jellyfin
```

Save to `kubernetes/apps/media/posterpilot/ks.yaml`.

- [ ] **Step 2: Register it in the media Kustomization**

In `kubernetes/apps/media/kustomization.yaml`, add `./posterpilot/ks.yaml` to the `resources` list, alongside the existing `./posterizarr/ks.yaml` entry:

```yaml
resources:
  - ./shared
  - ./audiobookshelf/ks.yaml
  - ./bazarr/ks.yaml
  - ./bindery/ks.yaml
  - ./booklore/ks.yaml
  - ./immich/ks.yaml
  - ./jellyfin/ks.yaml
  - ./jellystat/ks.yaml
  - ./profilarr/ks.yaml
  - ./posterizarr/ks.yaml
  - ./posterpilot/ks.yaml
  - ./prowlarr/ks.yaml
  - ./rangarr/ks.yaml
  - ./radarr/ks.yaml
  - ./sabnzbd/ks.yaml
  - ./seerr/ks.yaml
  - ./slskd/ks.yaml
  - ./sonarr/ks.yaml
  - ./soulsync/ks.yaml
```

- [ ] **Step 3: Validate the whole media tree still builds**

Run: `kubectl kustomize kubernetes/apps/media | grep -A2 "kind: Kustomization" | grep -i posterpilot`
Expected: shows the `posterpilot` Flux `Kustomization` object present in the rendered output alongside the others.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/media/posterpilot/ks.yaml kubernetes/apps/media/kustomization.yaml
git commit -m "feat(posterpilot): register app in media Kustomization tree"
```

---

### Task 6: Push and verify Flux reconciliation

**Files:** none (verification only, no new files)

**Interfaces:**
- Consumes: everything from Tasks 1–5, once pushed to the branch Flux tracks.

- [ ] **Step 1: Push the branch** (only if working on a branch other than `main`, or after merging — confirm with the user which applies before running `git push`, since pushing is a step that affects shared state)

- [ ] **Step 2: Force Flux to pull immediately**

Run: `task reconcile`
Expected: completes without error (this runs `flux --namespace flux-system reconcile kustomization flux-system --with-source`)

- [ ] **Step 3: Watch the app-level Kustomization become Ready**

Run: `flux get kustomization -n media posterpilot`
Expected: `READY` column shows `True` within a couple minutes. If not, run `flux logs --kind=Kustomization --name=posterpilot -n media` to see why.

- [ ] **Step 4: Watch the HelmRelease become Ready**

Run: `flux get helmrelease -n media posterpilot`
Expected: `READY` column shows `True`, message like "Helm install succeeded" or "Helm upgrade succeeded"

- [ ] **Step 5: Confirm the pod is healthy**

Run: `kubectl get pods -n media -l app.kubernetes.io/name=posterpilot`
Expected: one pod, `1/1 Running`

- [ ] **Step 6: Confirm the health endpoint responds**

Run: `kubectl exec -n media deploy/posterpilot -- bun -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.text()).then(console.log)"`
Expected: prints `{"status":"ok","version":"0.10.0"}` (version should match the pinned tag)

- [ ] **Step 7: Confirm it can reach Jellyfin**

Run: `kubectl logs -n media deploy/posterpilot --tail=50`
Expected: no repeated connection errors to the `JELLYFIN_URL`; if this is the very first boot before any library sync, absence of errors is enough — a full sync happens in Task 7.

No commit for this task — it's pure verification of what's already committed.

---

### Task 7: First-run wizard, test sync, and Posterizarr coexistence check

**Files:** none (manual UI verification — this cannot be scripted, per the design doc's rollout plan)

**Interfaces:**
- Consumes: the running PosterPilot instance from Task 6, plus the existing `posterizarr` deployment in `kubernetes/apps/media/posterizarr`.

- [ ] **Step 1: Open the UI**

Browse to `https://posterpilot.${SECRET_DOMAIN}` (substitute your real domain). Expected: PosterPilot's first-run wizard appears (language → server → TMDB → providers → libraries → first sync) with **no login prompt**, even though `AUTH_MODE=enabled` is set — PosterPilot fails open when `AUTH_MODE=enabled` but no username/hash has been stored yet (`src/lib/server/config/index.ts:612` upstream), so on a fresh install the app is reachable without authentication until credentials are set.

**Before doing anything else in the UI** (including the wizard itself), go to Settings → Security and set an admin username and password. This is the very first action to take on first boot, not an incidental step of the wizard — until it's done, the app (including Settings, holding the Jellyfin API key, TMDB token, and Fanart key) is unauthenticated.

- [ ] **Step 2: Confirm Jellyfin connection in the wizard**

The `SERVER_TYPE=jellyfin`/`JELLYFIN_URL`/`JELLYFIN_API_KEY` env vars should pre-fill this step. Expected: wizard reports a successful connection test to Jellyfin.

- [ ] **Step 3: Run a small dry-run sync**

In Settings, scope `INCLUDED_SECTIONS` (via the UI or by adding an env var in `helmrelease.yaml` and re-running Task 3/6) to a single small library, or just limit which items you apply to a handful of titles. Use the dry-run preview before applying. Expected: preview shows planned uploads/skips with no errors.

- [ ] **Step 4: Apply to a handful of titles and confirm in Jellyfin**

Apply the "Media server API" method for a few movies. Expected: Jellyfin shows the new curated poster for those titles immediately.

- [ ] **Step 5: Expand to full Movies + TV libraries**

Once step 4 looks right, run a full sync scoped to both libraries (per the approved design — both movies and TV from the start).

- [ ] **Step 6: Validate the Posterizarr coexistence risk**

Wait for Posterizarr's next scheduled `RUN_TIME` run (`03:00`, per `kubernetes/apps/media/posterizarr/app/helmrelease.yaml`). The next morning, check whether the titles you applied curated posters to in Step 4/5 still show the curated art in Jellyfin, or got reverted to Posterizarr's generated style.
  - If curated posters survived: done, no further action needed.
  - If they got clobbered: this confirms the open risk flagged in the design doc. Next step is either re-running the PosterPilot apply after each Posterizarr run (manual, for now), or filing this as a follow-up investigation (not part of this plan) — do not attempt to fix it speculatively without first confirming which failure mode actually occurred (check `kubectl logs -n media <posterizarr-pod>` from that run for clues).

No commit for this task.
