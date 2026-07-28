# PosterPilot: curated posters for Jellyfin (design)

Date: 2026-07-28

## Goal

Posterizarr (`kubernetes/apps/media/posterizarr`) already generates consistent
overlay-based posters/backgrounds/title cards for the Jellyfin library. That
covers every title, but the result is Posterizarr's own generated style, not
the hand-curated poster sets community designers publish on ThePosterDB and
MediUX. The goal here is to layer curated posters in wherever they're
available, while keeping Posterizarr as the fallback for everything else.

## Why not Kometa

The obvious community answer for "curated posters + overlays" is Kometa, but
Kometa's overlay/collection engine is Plex-only in practice: every config
example in its docs requires a `plex:` connection block, and there is no
working Jellyfin server integration. (A web search surfaced a "Jellyfin"
option in Kometa's docs site — that turned out to be a documentation-site
color theme, not a media server integration.) Since this cluster runs
Jellyfin only, with no Plex anywhere in the repo, Kometa is not viable here.

## Tool choice: PosterPilot

Evaluated two Jellyfin-native options that don't need Plex:

| | PosterPilot | JellyfinUpdatePoster |
|---|---|---|
| Mechanism | Auto-discovers posters/backgrounds from MediUX, ThePosterDB, Fanart.tv, TMDB; uploads directly via Jellyfin API | You drop images/`.zip` exports into a `RawCover` folder matched by naming convention; it pushes them to Jellyfin |
| Fit to "mostly automated" | Good | Poor — still a manual-curation workflow |
| Maturity (verified via `gh repo view`) | Created 2026-06-23 (~5 weeks old), 8 stars, actively pushed (2 days before this doc) | Created 2024-06-20 (~2 years old), 40 stars, but no push since 2025-11-12 (~8 months stale) |
| Deployment precedent | None found (zero GitHub/grep.app hits for "posterpilot" in any casing) | None found either |

**Decision: PosterPilot.** It best matches the desired automated workflow.
The user was shown the maturity trade-off explicitly (very young project, no
k8s deployment precedent anywhere to crib from) and chose to proceed anyway,
accepting early-adopter risk. This is a deliberate, informed call — not an
oversight.

## Deployment shape

New app at `kubernetes/apps/media/posterpilot/`, following the same layout
Posterizarr already uses in this repo:

- `ks.yaml` — Flux `Kustomization`, `targetNamespace: media`,
  `dependsOn: [jellyfin]` (needs Jellyfin reachable), `wait: false`,
  `interval: 30m`.
- `app/kustomization.yaml` — references the `helmrelease-defaults` component
  plus `pvc-config-juicefs.yaml`, `secret.sops.yaml`, `helmrelease.yaml`.
- `app/helmrelease.yaml` — HelmRelease using the shared `bjw-s-app-template`
  OCIRepository chart (same chart Posterizarr/Jellyfin/etc. use). Single
  container, image `ghcr.io/diegopeixoto/posterpilot` pinned to a specific
  tag (not `latest`) once a release is picked during implementation.
- `app/pvc-config-juicefs.yaml` — PVC for `/data` (SQLite db, settings,
  logs), `storageClassName: juicefs`, `ReadWriteMany`, ~10Gi — matching the
  convention already used by `radarr-juicefs`/`sonarr-juicefs` for
  SQLite-backed config, **not** the `qnap-nfs-db-sync` NFS class (NFS file
  locking is unreliable for SQLite, which is why Radarr/Sonarr moved off it).
- `app/secret.sops.yaml` — SOPS-encrypted secret holding `JELLYFIN_URL`, a
  **dedicated** `JELLYFIN_API_KEY` (not reused from Posterizarr's config, so
  it can be revoked independently later), `TMDB_API_KEY`, and optionally
  `FANART_KEY`. Wired into the HelmRelease via `env`/`valueFrom.secretKeyRef`,
  same convention as Radarr/Sonarr/Posterizarr.
- Exposed via the same Gateway API `external` route pattern as Posterizarr,
  at `posterpilot.${SECRET_DOMAIN}`, so the UI (dry-run preview, revert
  function) is reachable.
- Register `./posterpilot/ks.yaml` in `kubernetes/apps/media/kustomization.yaml`'s
  resource list, next to the existing `posterizarr` entry.

No Plex token needed anywhere in this config — Jellyfin-only.

## Scheduling & coexistence with Posterizarr

PosterPilot has no confirmed built-in cron scheduler and no documented public
"trigger a scan" API endpoint (only `/api/health` is documented) — it's
primarily a UI/manually-triggered tool, with incremental repeat syncs. Its
Plex-specific safeguard ("locks the field so agents won't overwrite it") has
no documented Jellyfin equivalent.

This means the original collision risk is real and unresolved on paper:
Posterizarr's own asset cache doesn't know about posters PosterPilot sets
directly via the Jellyfin API, so Posterizarr's nightly `RUN_TIME` run (see
`kubernetes/apps/media/posterizarr/app/helmrelease.yaml`, currently `03:00`)
could in theory re-push its own cached generated poster over a PosterPilot
pick.

Rather than pre-engineer a fix for unconfirmed behavior, the plan is:

1. Run PosterPilot syncs manually via its UI (dry-run preview, then apply).
2. Empirically validate the collision risk after deployment (see rollout
   plan below) instead of guessing at undocumented scheduling internals.
3. Treat any fix for a confirmed collision (reordering, an exclusion list,
   or an upstream issue/PR) as a fast-follow, not a blocker for this rollout.

## Rollout & validation plan

1. Deploy PosterPilot via Flux; complete its first-run wizard or pre-seed
   credentials via the SOPS secret; confirm it reaches Jellyfin.
2. Run one manual sync against a small test scope (a handful of movies)
   using the dry-run preview first, then apply; confirm the posters look
   right in Jellyfin.
3. Expand the manual sync to the full Movies + TV libraries.
4. Let Posterizarr's next scheduled `03:00` run happen, then check the next
   morning whether curated posters survived or got clobbered — this is the
   empirical test of the coexistence risk above.
5. If Posterizarr clobbers curated picks, follow up with a fix; if not,
   this is done as designed.

## Out of scope / explicitly deferred

- Automating the PosterPilot trigger via CronJob — deferred until we
  confirm a real trigger-scan endpoint exists (fast-follow, not blocking).
- JellyfinUpdatePoster — kept in mind as a manual-curation option for
  specific titles PosterPilot's auto-matching misses, not part of this
  rollout.
