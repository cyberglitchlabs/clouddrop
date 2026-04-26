# Agent Brief: Deploy LiteLLM Proxy to clouddrop

## Goal

Add LiteLLM as a unified, OpenAI-compatible LLM gateway sitting in front of the existing in-cluster Ollama and any future remote providers (Anthropic, OpenAI, Mistral, etc.). Outcome:

- A single internal endpoint `https://litellm.${SECRET_DOMAIN}/v1` that speaks the OpenAI API
- Per-key budgets, rate limits, and cost tracking (Postgres-backed)
- Ollama models (`llama3.1`, etc.) routed locally; remote models routed to upstream providers using user-supplied API keys
- A web UI at `/ui` for managing virtual keys
- Open-WebUI and n8n reconfigured (optional, in a follow-up) to point at LiteLLM instead of directly at Ollama

## Repository conventions

Re-read `agent-brief-homepage-glance.md`'s "Repository conventions you must follow" section. Reminders:

- Place under `kubernetes/apps/ai/litellm/` mirroring `kubernetes/apps/ai/n8n/`.
- Use bjw-s `app-template` chart.
- Postgres via CloudNative-PG (`cloudnative-pg-operator` is the dependency in `ks.yaml`).
- SOPS-encrypt all secrets.
- Internal-only HTTPRoute; do not expose externally.

## Image

LiteLLM ships several images. Use:

- `ghcr.io/berriai/litellm-database:<tag>` — includes Prisma migration tooling required for Postgres.

Verify the latest stable tag at https://github.com/BerriAI/litellm/releases. Avoid `:main-latest` (rolling). Avoid `litellm-non_root` for this deployment because we want the embedded Prisma migrate.

Listening port: `4000`.

## Database

Mirror `kubernetes/apps/home/mealie/app/postgres-cluster.yaml`:

- Cluster name: `litellm-postgres`
- 1 instance is fine (matches mealie/n8n posture)
- CNPG creates secret `litellm-postgres-app` with keys `username`, `password`, `dbname`, `host`, `port`, `uri`
- LiteLLM expects a `DATABASE_URL` env in the form `postgresql://USER:PASSWORD@HOST:PORT/DB`. Either:
  - Map from the CNPG-generated `uri` key directly, OR
  - Build it from the individual keys via env construction in the HelmRelease

The cleaner path is using `uri`:
```yaml
env:
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: litellm-postgres-app
        key: uri
```

## Secrets

Create `secret.sops.yaml` with the following keys (encrypt before commit):

- `LITELLM_MASTER_KEY` — random 32+ char string, prefix with `sk-` (e.g. `sk-$(openssl rand -hex 24)`). This is the admin API key.
- `LITELLM_SALT_KEY` — random 32 char string, used to encrypt provider keys at rest in Postgres.
- `UI_USERNAME` — admin UI login.
- `UI_PASSWORD` — admin UI password.
- (Optional, leave as placeholder values for the user to fill) `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`.

The user will run `sops --encrypt --in-place secret.sops.yaml` after generation. Surface this as a TODO. Do NOT commit any plaintext key values.

## Configuration

LiteLLM reads its model list from `config.yaml`. Mount via ConfigMap projected to `/app/config.yaml` and pass `--config /app/config.yaml` as a startup arg.

```yaml
# config.yaml (in ConfigMap)
model_list:
  # In-cluster Ollama
  - model_name: llama3.1
    litellm_params:
      model: ollama/llama3.1
      api_base: http://ollama.ai.svc.cluster.local:11434
  - model_name: llama3.1:70b
    litellm_params:
      model: ollama/llama3.1:70b
      api_base: http://ollama.ai.svc.cluster.local:11434
  - model_name: qwen2.5-coder
    litellm_params:
      model: ollama/qwen2.5-coder
      api_base: http://ollama.ai.svc.cluster.local:11434
  - model_name: nomic-embed-text
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: http://ollama.ai.svc.cluster.local:11434

  # Anthropic (active only if ANTHROPIC_API_KEY is set in the secret)
  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY
  - model_name: claude-opus
    litellm_params:
      model: anthropic/claude-opus-4-6
      api_key: os.environ/ANTHROPIC_API_KEY
  - model_name: claude-haiku
    litellm_params:
      model: anthropic/claude-haiku-4-5
      api_key: os.environ/ANTHROPIC_API_KEY

  # OpenAI (active only if OPENAI_API_KEY is set)
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY

litellm_settings:
  drop_params: true
  set_verbose: false
  cache: true
  cache_params:
    type: redis-semantic
    similarity_threshold: 0.95
  json_logs: true
  request_timeout: 600

router_settings:
  routing_strategy: simple-shuffle
  num_retries: 2
  timeout: 600
  fallbacks:
    - claude-sonnet: ["claude-haiku", "llama3.1"]
    - gpt-4o: ["claude-sonnet", "llama3.1"]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true
  alerting: ["slack"]
  alert_types: ["llm_exceptions", "spend_reports"]
```

Verify model names against current Ollama tags before committing — pull `ollama list` output from the live cluster. Do NOT include models the user doesn't have pulled; LiteLLM will route to them and 404. The agent should query Ollama at deploy time:

```bash
kubectl -n ai exec deploy/ollama -- ollama list
```

and prune the `model_list` to match.

### Note on Redis cache

The `cache_params.type: redis-semantic` requires a Redis backend. The `mcp-context-forge` app already has a Redis Deployment in the `ai` namespace (`kubernetes/apps/ai/mcp-context-forge/app/redis-deployment.yaml`). **Do not share it** — it's owned by mcp-context-forge and a key collision could cause subtle bugs. Either:

- Add a dedicated Redis Deployment for LiteLLM (small, ~64Mi memory), OR
- Drop semantic cache and use `type: local` (in-memory, per-pod) for the first iteration.

Recommend the second for v1 — simpler, no extra moving parts. Upgrade to dedicated Redis if cache hit rate matters later.

## HelmRelease values skeleton

```yaml
controllers:
  litellm:
    strategy: RollingUpdate
    initContainers:
      prisma-migrate:
        image:
          repository: ghcr.io/berriai/litellm-database
          tag: <verified-tag>
        command: ["/bin/sh", "-c"]
        args:
          - |
            cd /app && prisma migrate deploy --schema=schema.prisma
        env:
          DATABASE_URL:
            valueFrom:
              secretKeyRef:
                name: litellm-postgres-app
                key: uri
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
    containers:
      app:
        image:
          repository: ghcr.io/berriai/litellm-database
          tag: <verified-tag>
        args:
          - "--config"
          - "/app/config.yaml"
          - "--port"
          - "4000"
          - "--num_workers"
          - "1"
        env:
          TZ: America/Chicago
          DATABASE_URL:
            valueFrom:
              secretKeyRef:
                name: litellm-postgres-app
                key: uri
          STORE_MODEL_IN_DB: "True"
        envFrom:
          - secretRef:
              name: litellm-secrets
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /health/liveliness, port: 4000 }
              initialDelaySeconds: 30
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 5
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet: { path: /health/readiness, port: 4000 }
              initialDelaySeconds: 20
              periodSeconds: 15
              timeoutSeconds: 5
              failureThreshold: 5
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false   # Prisma writes a query engine binary at startup
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits:   { memory: 1Gi }
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
    controller: litellm
    ports:
      http: { port: 4000 }
persistence:
  config:
    type: configMap
    name: litellm-config
    globalMounts:
      - path: /app/config.yaml
        subPath: config.yaml
route:
  app:
    annotations:
      external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"
    hostnames: ["litellm.${SECRET_DOMAIN}"]
    parentRefs:
      - name: internal
        namespace: kube-system
        sectionName: https
```

## File checklist

- `kubernetes/apps/ai/litellm/ks.yaml` — `dependsOn: [cloudnative-pg-operator]`
- `kubernetes/apps/ai/litellm/app/kustomization.yaml` — include `configMapGenerator` for `litellm-config`
- `kubernetes/apps/ai/litellm/app/helmrelease.yaml`
- `kubernetes/apps/ai/litellm/app/postgres-cluster.yaml`
- `kubernetes/apps/ai/litellm/app/secret.sops.yaml`
- `kubernetes/apps/ai/litellm/app/config/config.yaml` — referenced by `configMapGenerator`

Update `kubernetes/apps/ai/kustomization.yaml` to add `./litellm/ks.yaml`.

## Verification steps

1. Postgres cluster healthy:
   ```bash
   kubectl -n ai get cluster.postgresql.cnpg.io litellm-postgres
   ```
2. Prisma init container completed without error:
   ```bash
   kubectl -n ai logs deploy/litellm -c prisma-migrate
   ```
3. App pod Ready and healthy:
   ```bash
   kubectl -n ai get pods -l app.kubernetes.io/name=litellm
   curl -s https://litellm.${SECRET_DOMAIN}/health/readiness
   ```
4. Test a chat completion against Ollama via LiteLLM:
   ```bash
   curl -s https://litellm.${SECRET_DOMAIN}/v1/chat/completions \
     -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model": "llama3.1", "messages":[{"role":"user","content":"say hi"}]}'
   ```
5. UI loads at `https://litellm.${SECRET_DOMAIN}/ui` and accepts the UI credentials.
6. Spend tracking populated: log in, generate a few requests, confirm the spend dashboard updates.

## Things to NOT do

- Do not point Open-WebUI or n8n at LiteLLM in the same PR. Verify LiteLLM works in isolation first; cutover is a follow-up.
- Do not enable `LITELLM_LICENSE_KEY` features unless a license has been purchased — the open-source version is sufficient for this use case.
- Do not share the `mcp-context-forge` Redis instance.
- Do not commit any provider API keys (Anthropic/OpenAI) unencrypted.
- Do not list models in `config.yaml` that aren't actually pulled in Ollama — LiteLLM will route blindly and surface confusing 404s.
- Do not enable `read_only_root_filesystem: true` — Prisma writes a query engine to /app at startup.

## Stretch goals

- Add a `ServiceMonitor` for LiteLLM's Prometheus metrics endpoint (`/metrics`) — feeds into the existing kube-prometheus-stack.
- Add a Grafana dashboard for spend by model / by API key.
- Wire alerting into the existing Discord bot for cost overruns.

## Deliverable

A single PR titled `feat(ai): add litellm proxy with postgres backend`. PR description must:

- List the SOPS encryption command the user must run before merge
- List which models in `config.yaml` were verified against the live Ollama instance
- Note that Open-WebUI / n8n integration is intentionally deferred
