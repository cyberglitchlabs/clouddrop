# Design: Rename public URLs for Audiobookshelf and BookLore

## Goal

Change the external hostnames:
- `audiobookshelf.${SECRET_DOMAIN}` → `audiobooks.${SECRET_DOMAIN}`
- `booklore.${SECRET_DOMAIN}` → `ebooks.${SECRET_DOMAIN}`

## Scope

URL/hostname only. App identity is unchanged: HelmRelease/Kustomization names,
directory names, PVC claim names, and internal Service DNS names stay
`audiobookshelf` / `booklore`.

## Changes

1. `kubernetes/apps/media/audiobookshelf/app/helmrelease.yaml`
   - `route.app.hostnames`: `["{{ .Release.Name }}.${SECRET_DOMAIN}"]` →
     `["audiobooks.${SECRET_DOMAIN}"]`
2. `kubernetes/apps/media/booklore/app/helmrelease.yaml`
   - `route.app.hostnames`: `["{{ .Release.Name }}.${SECRET_DOMAIN}"]` →
     `["ebooks.${SECRET_DOMAIN}"]`
   - No manual DNS work: `cloudflare-dns` (external-dns) runs with
     `policy: sync` and `sources: [gateway-httproute]`, so it creates the new
     CNAME and prunes the old one automatically from the HTTPRoute hostname
     change.
3. `kubernetes/apps/home/homepage/app/config/services.yaml`
   - Audiobookshelf `href`/nothing else → `https://audiobooks.${SECRET_DOMAIN}`
   - BookLore `href` and `siteMonitor` → `https://ebooks.${SECRET_DOMAIN}`
   - Widget internal service URL
     (`http://audiobookshelf.media.svc.cluster.local:80`) is unchanged —
     cluster-internal, tied to the (unchanged) Service name.
4. `kubernetes/apps/security/authentik/app/blueprints-configmap.yaml`
   - Audiobookshelf OAuth2 provider `redirect_uris[0].url`:
     `https://audiobookshelf.cyberglitch.systems/audiobookshelf/auth/openid/callback`
     → `https://audiobooks.cyberglitch.systems/audiobookshelf/auth/openid/callback`
     (host changes only; the `/audiobookshelf/...` callback path is app-internal
     and unrelated to the public hostname).
   - BookLore has no Authentik provider today — no change needed there.

## Out of scope / manual follow-up (not git-tracked)

- Audiobookshelf's own OIDC settings store the callback URL and use
  `matching_mode: strict` in Authentik — after cutover, the in-app redirect
  URI must be updated by hand to the new host or SSO login breaks.
- Bindery integrates with Audiobookshelf and BookLore; the source URLs for
  those integrations live in Bindery's own config/DB, not this repo, and need
  to be updated in Bindery's UI after the hostname change.

## Risk / rollback

Low risk, fully reversible by reverting the four file changes. Because
external-dns runs in `sync` mode, the old DNS records disappear once the old
hostnames are no longer referenced by any HTTPRoute — reverting the commit
restores them.
