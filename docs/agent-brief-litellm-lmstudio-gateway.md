# Agent Brief: Connect LiteLLM to the LM Studio Gateway (OAuth)

## Goal

Wire the in-cluster LiteLLM proxy (deployed per `agent-brief-litellm.md`) to the user's existing LM Studio Gateway at `https://ai.rebelscum.network/v1`. The gateway is OpenAI-compatible but sits behind an Authentik forward-auth perimeter using OAuth2 ROPC (Resource Owner Password Credentials, `grant_type=password`). Outcome:

- LiteLLM exposes the LM Studio gateway models alongside Ollama and any remote API providers.
- Token rotation is automatic — no human-in-the-loop refresh.
- Auth credentials are SOPS-encrypted.
- Open-WebUI, n8n, Karakeep, and any other downstream app reaches the gateway purely by selecting a model alias on the LiteLLM endpoint.

## Source of truth — the user's working script

The user already runs a verified bash script on their workstation that successfully authenticates against the gateway. Its behavior is the canonical spec for this integration. Key details from that script:

```bash
TOKEN_URL="https://auth.rebelscum.network/application/o/token/"
CLIENT_ID="<from user's existing script — paste at deploy time, do not commit>"

# Token exchange uses grant_type=password (ROPC), NOT client_credentials.
# Only client_id, username, and password are sent. No client_secret.
curl -X POST \
  -d "grant_type=password" \
  -d "client_id=$CLIENT_ID" \
  -d "username=$OAC_USERNAME" \
  -d "password=$OAC_PASSWORD" \
  "$TOKEN_URL"
```

The returned `access_token` is then used as a static `Authorization: Bearer <token>` header against `https://ai.rebelscum.network/v1`. No `client_secret` exists in this flow — the OAuth2 client is **public**, identification is by `username` + `password`.

This is important because **LiteLLM's proposed `custom_oauth` provider (BerriAI/litellm#12367) speaks `client_credentials`, not `password` grant**. Using it natively would require either creating a separate confidential OAuth2 provider in Authentik (Path B below) or a code-level fork. The pragmatic primary path is a sidecar that mirrors the working script.

## Repository conventions

Re-read `agent-brief-homepage-glance.md`'s "Repository conventions you must follow" section. This brief edits files inside `kubernetes/apps/ai/litellm/` — it does not create a new app folder.

## Choose your path

Two paths are documented. The agent must pick one based on user preference; surface the choice in the PR description.

**Path A — Sidecar with `grant_type=password` (recommended).**

- Mirrors the user's working script exactly
- Reuses the existing `CLIENT_ID` from the user's working script — already on the gateway allowlist, zero Authentik admin work
- Reuses the user's existing username + app password — no new credentials to provision
- Adds one small Python container to the LiteLLM pod
- Works on any LiteLLM version

**Path B — Native `custom_oauth` + new confidential OAuth2 provider in Authentik.**

- Requires creating a new OAuth2 provider in Authentik (admin UI work)
- Requires adding the auto-generated service account `ak-<provider-name>-client_credentials` to the gateway's allowlist (admin UI work)
- Uses LiteLLM's native OAuth handling — no sidecar
- Requires LiteLLM image with `custom_oauth` provider merged (~v1.83.x or later — verify before relying on it)
- Cleaner long-term once running, but more setup friction

Default to Path A unless the user has explicitly asked for Path B. Both paths are documented in full below.

---

## Path A — Sidecar with `grant_type=password`

### New SOPS secret

Create `kubernetes/apps/ai/litellm/app/secret-lmstudio.sops.yaml` (separate from existing secrets so rotations are isolated):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: litellm-lmstudio-oauth
  namespace: ai
type: Opaque
stringData:
  LMSTUDIO_GATEWAY_TOKEN_URL: "https://auth.rebelscum.network/application/o/token/"
  LMSTUDIO_GATEWAY_BASE_URL: "https://ai.rebelscum.network/v1"
  LMSTUDIO_GATEWAY_CLIENT_ID: "<paste from user's working script at deploy time>"
  LMSTUDIO_GATEWAY_USERNAME: "<user fills in — Authentik username>"
  LMSTUDIO_GATEWAY_PASSWORD: "<user fills in — Authentik App Password>"
```

App Password generation (surface as TODO):

```
Authentik → User Settings → Tokens & App Passwords → Create
  Intent: App Password
  Expiration: leave blank (non-expiring)
  Description: "LiteLLM cluster — LM Studio gateway"
```

After populating values, run `sops --encrypt --in-place secret-lmstudio.sops.yaml`. Add to `kubernetes/apps/ai/litellm/app/kustomization.yaml`'s resources list. The PR description must call out the encryption step explicitly.

### Sidecar — `grant_type=password` proxy

Create `kubernetes/apps/ai/litellm/app/lmstudio-auth-proxy/proxy.py`:

```python
import os, time, asyncio
from fastapi import FastAPI, Request, Response
import httpx

CLIENT_ID = os.environ["LMSTUDIO_GATEWAY_CLIENT_ID"]
USERNAME = os.environ["LMSTUDIO_GATEWAY_USERNAME"]
PASSWORD = os.environ["LMSTUDIO_GATEWAY_PASSWORD"]
TOKEN_URL = os.environ["LMSTUDIO_GATEWAY_TOKEN_URL"]
UPSTREAM = os.environ["LMSTUDIO_GATEWAY_BASE_URL"].rstrip("/")

# Mirrors the working bash script:
#   grant_type=password, client_id, username, password (no client_secret)

app = FastAPI()
_lock = asyncio.Lock()
_token: str | None = None
_expires_at: float = 0.0

async def _refresh() -> None:
    global _token, _expires_at
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.post(
            TOKEN_URL,
            data={
                "grant_type": "password",
                "client_id": CLIENT_ID,
                "username": USERNAME,
                "password": PASSWORD,
            },
        )
        r.raise_for_status()
        body = r.json()
        _token = body["access_token"]
        _expires_at = time.time() + body.get("expires_in", 3600) - 60

async def _get_token() -> str:
    async with _lock:
        if _token is None or time.time() >= _expires_at:
            await _refresh()
        return _token

@app.get("/healthz")
async def healthz():
    return {"ok": True, "has_token": _token is not None,
            "expires_in_s": max(0, int(_expires_at - time.time()))}

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(path: str, request: Request):
    token = await _get_token()
    body = await request.body()
    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host", "authorization", "content-length")
    }
    headers["Authorization"] = f"Bearer {token}"
    async with httpx.AsyncClient(timeout=600) as c:
        upstream = await c.request(
            request.method,
            f"{UPSTREAM}/{path}",
            content=body,
            headers=headers,
            params=request.query_params,
        )
    excluded = {"content-encoding", "transfer-encoding", "connection"}
    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        headers={k: v for k, v in upstream.headers.items() if k.lower() not in excluded},
        media_type=upstream.headers.get("content-type"),
    )
```

### Sidecar — wiring

Edit `kubernetes/apps/ai/litellm/app/helmrelease.yaml`. Add a second container under `controllers.litellm.containers`:

```yaml
controllers:
  litellm:
    containers:
      app:
        # ...existing LiteLLM container — unchanged...
        envFrom:
          - secretRef:
              name: litellm-secrets             # existing
      lmstudio-auth-proxy:
        image:
          repository: python
          tag: "3.12-slim"
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            pip install --quiet --no-cache-dir fastapi uvicorn httpx
            exec uvicorn proxy:app --host 127.0.0.1 --port 4001 --app-dir /scripts
        envFrom:
          - secretRef:
              name: litellm-lmstudio-oauth
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /healthz, port: 4001, host: 127.0.0.1 }
              initialDelaySeconds: 30
              periodSeconds: 30
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /healthz, port: 4001, host: 127.0.0.1 }
              initialDelaySeconds: 15
              periodSeconds: 15
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: 25m, memory: 64Mi }
          limits:   { memory: 256Mi }
```

The sidecar binds to `127.0.0.1:4001` so it is **only** reachable from the LiteLLM container in the same pod. Do not expose via a Service.

Mount the script via ConfigMap. Add to `kubernetes/apps/ai/litellm/app/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: litellm-config
    files:
      - config.yaml=./config/config.yaml
  - name: litellm-lmstudio-proxy
    files:
      - proxy.py=./lmstudio-auth-proxy/proxy.py
generatorOptions:
  disableNameSuffixHash: true
```

And in the HelmRelease's `persistence` block:

```yaml
persistence:
  config:
    # ...existing entry — unchanged...
  lmstudio-proxy-script:
    type: configMap
    name: litellm-lmstudio-proxy
    advancedMounts:
      litellm:
        lmstudio-auth-proxy:
          - path: /scripts/proxy.py
            subPath: proxy.py
```

### Path A — `config.yaml` model entries

The agent must list the gateway's actual model catalog before pinning specific entries. Use the user's working script (or replicate it) to fetch a token, then:

```bash
curl -H "Authorization: Bearer $TOKEN" https://ai.rebelscum.network/v1/models | jq -r '.data[].id'
```

Capture those IDs. Pin two or three of the most-used ones explicitly and let the wildcard handle the rest. Append to `kubernetes/apps/ai/litellm/app/config/config.yaml` `model_list`:

```yaml
# LM Studio Gateway via in-pod auth sidecar
- model_name: lmstudio-qwen-coder
  litellm_params:
    model: openai/qwen2.5-coder-32b-instruct        # <-- replace with actual ID from /v1/models
    api_base: http://127.0.0.1:4001/v1
    api_key: "unused"

- model_name: lmstudio-llama
  litellm_params:
    model: openai/llama-3.3-70b-instruct            # <-- replace
    api_base: http://127.0.0.1:4001/v1
    api_key: "unused"

# Wildcard for any other model the gateway exposes
- model_name: "lmstudio/*"
  litellm_params:
    model: "openai/*"
    api_base: http://127.0.0.1:4001/v1
    api_key: "unused"
```

### Path A — fallback ladder

Update `router_settings.fallbacks`:

```yaml
router_settings:
  routing_strategy: simple-shuffle
  num_retries: 2
  timeout: 600
  fallbacks:
    - claude-sonnet:        ["claude-haiku", "lmstudio-qwen-coder", "llama3.1"]
    - gpt-4o:               ["claude-sonnet", "lmstudio-qwen-coder", "llama3.1"]
    - lmstudio-qwen-coder:  ["llama3.1"]   # if gateway down, fall to local Ollama
    - lmstudio-llama:       ["llama3.1"]
```

---

## Path B — Native `custom_oauth` (alternative)

Use this only if the user has explicitly asked for a sidecar-free deployment and is willing to do the Authentik admin work.

### Step 1 — Verify `custom_oauth` is available in the deployed LiteLLM image

```bash
kubectl -n ai exec deploy/litellm -c app -- \
  python -c "from litellm.llms import custom_oauth" \
  2>&1 || echo "custom_oauth NOT available — use Path A"
```

(Exact import path may differ — check `litellm/llms/` in the running image.) If unavailable, fall back to Path A.

### Step 2 — Create a confidential OAuth2 provider in Authentik (manual)

In `https://auth.rebelscum.network` admin UI:

1. **Applications → Providers → Create → OAuth2/OpenID Provider.**
   - Name: `litellm-lmstudio-gateway`
   - Authorization flow: implicit consent
   - **Client type: `Confidential`**
   - **Copy client_id and client_secret** (secret shown once)
   - Scopes: `openid`, `profile`, `email`, `ak_proxy`
2. **Applications → Applications → Create.**
   - Name: `LiteLLM → LM Studio Gateway`
   - Provider: the one just created
3. **Add the auto-generated service account** (`ak-litellm-lmstudio-gateway-client_credentials`) to the existing gateway forward-auth allowlist. Without this step, valid tokens get 403.

### Step 3 — SOPS secret (Path B variant)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: litellm-lmstudio-oauth
  namespace: ai
type: Opaque
stringData:
  LMSTUDIO_GATEWAY_TOKEN_URL: "https://auth.rebelscum.network/application/o/token/"
  LMSTUDIO_GATEWAY_BASE_URL: "https://ai.rebelscum.network/v1"
  LMSTUDIO_GATEWAY_CLIENT_ID: "<from-authentik>"
  LMSTUDIO_GATEWAY_CLIENT_SECRET: "<from-authentik>"
```

Encrypt with SOPS before commit.

### Step 4 — `config.yaml` entries (Path B variant)

```yaml
- model_name: lmstudio-qwen-coder
  litellm_params:
    model: openai/qwen2.5-coder-32b-instruct
    litellm_provider: custom_oauth
    base_url: os.environ/LMSTUDIO_GATEWAY_BASE_URL
    auth_type: oauth
    client_id: os.environ/LMSTUDIO_GATEWAY_CLIENT_ID
    client_secret: os.environ/LMSTUDIO_GATEWAY_CLIENT_SECRET
    token_url: os.environ/LMSTUDIO_GATEWAY_TOKEN_URL
    verify_ssl: true

- model_name: "lmstudio/*"
  litellm_params:
    model: "openai/*"
    litellm_provider: custom_oauth
    base_url: os.environ/LMSTUDIO_GATEWAY_BASE_URL
    auth_type: oauth
    client_id: os.environ/LMSTUDIO_GATEWAY_CLIENT_ID
    client_secret: os.environ/LMSTUDIO_GATEWAY_CLIENT_SECRET
    token_url: os.environ/LMSTUDIO_GATEWAY_TOKEN_URL
    verify_ssl: true
```

Mount the secret via `envFrom` on the LiteLLM container only (no sidecar in Path B). Same fallback ladder as Path A.

---

## Verification (applies to both paths)

1. LiteLLM pod healthy after restart:
   ```bash
   kubectl -n ai rollout restart deploy/litellm
   kubectl -n ai get pods -l app.kubernetes.io/name=litellm
   ```

2. **Path A only** — sidecar healthy and has a token:
   ```bash
   kubectl -n ai exec deploy/litellm -c lmstudio-auth-proxy -- \
     curl -s http://127.0.0.1:4001/healthz
   # Expect: {"ok": true, "has_token": true, "expires_in_s": <positive number>}
   ```

3. **Path B only** — LiteLLM logs show OAuth token fetch on first call:
   ```bash
   kubectl -n ai logs deploy/litellm -c app | grep -iE "oauth|token"
   ```

4. List models via LiteLLM:
   ```bash
   kubectl -n ai port-forward svc/litellm 4000:4000 &
   curl -s http://localhost:4000/v1/models \
     -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     | jq '.data[] | select(.id | startswith("lmstudio")) | .id'
   ```

5. Test a chat completion through the gateway:
   ```bash
   curl -s http://localhost:4000/v1/chat/completions \
     -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model": "lmstudio-qwen-coder",
          "messages":[{"role":"user","content":"reply with the single word: hello"}]}'
   ```
   Expect: a chat completion with `hello` in the response.

6. Token refresh works automatically:
   - **Path A:** Note the `expires_in_s` from `/healthz`. Wait until that expires + 30s. Re-run the chat completion. Then re-check `/healthz` — `has_token` should still be `true` and `expires_in_s` should reset to ~3600.
   - **Path B:** Same idea but check LiteLLM's internal token cache — restart-test by deleting the cached token via UI/admin if exposed, or by waiting beyond TTL.

7. Spend tracking:
   - Visit `https://litellm.${SECRET_DOMAIN}/ui` → Spend → confirm requests routed to `lmstudio-qwen-coder` show up under that model name.

8. Failover under upstream failure:
   - Temporarily flip `LMSTUDIO_GATEWAY_BASE_URL` to `https://example.invalid/v1` and reconcile.
   - Send a `claude-sonnet` request — confirm fallback to `llama3.1` per the router config and that LiteLLM logs the upstream failure cleanly.
   - Revert the change.

---

## Things to NOT do

- Do not commit username, password, or any token unencrypted. SOPS-encrypt the secret file before `git add`.
- Do not bind the Path A sidecar to anything other than `127.0.0.1`. It must not be reachable from outside the pod.
- Do not enumerate every gateway model in `model_list`. Pin two or three for the fallback ladder; let the wildcard handle the rest.
- Do not enable `verify_ssl: false`. The gateway uses a public-trust cert via Cloudflare so verification should always succeed.
- Do not mix Path A and Path B in the same deployment — pick one and remove the other's config blocks. The two paths use the same env-var names but different shapes (password vs client_secret).
- Do not assume Path B `custom_oauth` works without the Step 1 verification. The feature was proposed in BerriAI/litellm#12367 and the merge state across image tags is unclear; if the running image doesn't have it, the proxy will start but model calls will fail with `unknown provider`.
- Do not bypass the gateway by giving LiteLLM the LM Studio host's LAN IP directly. The OAuth perimeter exists for a reason.

## Stretch goals

- After verification, retire any direct Ollama references in Open-WebUI / n8n / Karakeep that have been replaced by superior LM Studio gateway models. Track this in `agent-brief-integration-wiring.md`'s Phase 3.
- Add a Prometheus alert for sustained token-refresh failures:
  - **Path A:** instrument `proxy.py` with a `/metrics` endpoint exposing `last_refresh_timestamp`, `consecutive_failure_count`, `token_expires_in`. Add a `ServiceMonitor`.
  - **Path B:** scrape LiteLLM's auth metrics if exposed.
- Document the gateway model catalog in `docs/lmstudio-gateway-models.md` so users know which aliases are pinned. Renovate won't track these — the user owns the list.
- Migrate to Path B once the Authentik admin work has been done in another PR — this lets the sidecar be retired.

## Deliverable

A single PR titled `feat(ai): connect litellm to lm studio gateway via authentik oauth (path A: sidecar)` (or `path B: native custom_oauth`). PR description must:

- State which path was chosen and why.
- Confirm SOPS encryption ran on the new secret file.
- Capture the actual model IDs returned from `/v1/models` at the time of authoring, with a note that Renovate won't auto-update them — the user owns this list.
- For Path B: confirm the Authentik admin steps (provider creation, allowlist update) were completed.
- For Path A: include the user's Authentik App Password creation as a TODO (only the user can do this in their account settings).
- Document the rollback plan: revert the commit, `kubectl rollout restart deploy/litellm`, original `model_list` is back.
