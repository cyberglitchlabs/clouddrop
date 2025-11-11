# Copilot Instructions for CloudDrop

## Architecture Overview

This is a **Talos Linux Kubernetes cluster** managed with **GitOps using Flux**. The repository follows the `onedr0p/cluster-template` pattern for homelab/bare-metal deployments.

**Core Stack:**
- **OS**: Talos Linux (immutable, API-driven Kubernetes OS)
- **GitOps**: Flux v2 with OCIRepository support
- **CNI**: Cilium with Gateway API (internal/external gateways)
- **Ingress**: Cilium Gateway API routes, Cloudflare Tunnel for external access
- **DNS**: CoreDNS + k8s_gateway (split-horizon DNS)
- **Secrets**: SOPS with age encryption
- **Cert Management**: cert-manager with Let's Encrypt

## Directory Structure

```
├── talos/                    # Talos configuration (talhelper-based)
│   ├── talconfig.yaml        # Main cluster config (nodes, IPs, patches)
│   ├── talenv.yaml           # Versions (Talos, K8s) - Renovate managed
│   ├── talsecret.sops.yaml   # Encrypted cluster secrets
│   └── patches/              # Talos machine config patches (RFC6902)
│       ├── global/           # Applied to all nodes
│       ├── controller/       # Control plane only
│       └── {hostname}/       # Node-specific patches
├── kubernetes/
│   ├── apps/                 # Application deployments (namespace dirs)
│   │   ├── {namespace}/
│   │   │   ├── kustomization.yaml  # Lists ks.yaml files
│   │   │   └── {app}/
│   │   │       ├── ks.yaml         # Flux Kustomization (entrypoint)
│   │   │       └── app/
│   │   │           ├── helmrelease.yaml
│   │   │           ├── kustomization.yaml
│   │   │           ├── ocirepository.yaml  # Optional: app-specific OCI chart source
│   │   │           └── {other-resources}.yaml
│   ├── components/common/    # Shared resources (repos, sops secrets)
│   │   ├── repos/            # Shared HelmRepository/OCIRepository definitions
│   │   └── sops/             # cluster-secrets.sops.yaml
│   └── flux/                 # Flux bootstrap configs
│       ├── cluster/ks.yaml   # Entry point (cluster-meta, cluster-apps)
│       └── meta/             # Flux system metadata
├── bootstrap/                # Initial cluster bootstrap resources
│   ├── sops-age.sops.yaml    # SOPS decryption secret
│   ├── github-deploy-key.sops.yaml
│   └── helmfile.d/           # Initial Helm charts (cilium, coredns, etc.)
│       ├── 00-crds.yaml
│       ├── 01-apps.yaml
│       └── templates/values.yaml.gotmpl
└── scripts/                  # Bootstrap and helper scripts
    └── bootstrap-apps.sh     # Orchestrates initial cluster setup
```

## Critical Workflows

### 1. Talos Configuration Changes

**Talos uses talhelper** to generate configs from `talconfig.yaml` + patches.

```bash
# Generate configs after editing talconfig.yaml or patches
task talos:generate-config

# Apply config to specific node (MODE: auto|reboot|staged)
task talos:apply-node IP=192.168.42.254 MODE=auto

# Upgrade Talos version (updates talenv.yaml first)
task talos:upgrade-node IP=192.168.42.254

# Upgrade Kubernetes version (updates talenv.yaml first)
task talos:upgrade-k8s
```

**Talos patches** (`talos/patches/`) use RFC6902 JSON Patch format:
- Must create parent paths before using `-` (array append)
- Use `op: add`, `op: replace`, `op: remove`
- Patches apply in order: global → role-specific → node-specific

### 2. Application Deployment Pattern

**Every app follows this structure:**

1. **Namespace-level** `kustomization.yaml` lists `ks.yaml` files
2. **App-level** `ks.yaml` is the Flux Kustomization (targets `./app/`)
3. **App directory** contains:
   - `helmrelease.yaml` - Helm chart deployment with `chartRef`
   - `kustomization.yaml` - Lists all resources in this directory
   - `ocirepository.yaml` - Optional: app-specific OCI chart source (name matches `chartRef.name`)
   - Other resources as needed (secrets, configmaps, routes, etc.)

**Example app creation:**
```bash
mkdir -p kubernetes/apps/{namespace}/{app-name}/app
# Create ks.yaml, helmrelease.yaml, kustomization.yaml
# Add ocirepository.yaml if not using shared OCI repo
# Add reference to namespace kustomization.yaml
```

**Shared vs. per-app OCIRepository:**
- Shared: `kubernetes/apps/{namespace}/shared/ocirepository-{name}.yaml` (used by multiple apps in same namespace)
- Per-app: `kubernetes/apps/{namespace}/{app}/app/ocirepository.yaml` (app-specific, often just a name alias)

### 3. Secrets Management (SOPS)

**Encryption rules** (`.sops.yaml`):
- Specific rules FIRST (e.g., `talos/talsecret.sops.yaml`)
- General rules after (e.g., `talos/.*\.sops\.ya?ml`)
- `mac_only_encrypted: true` = integrity checks only (no confidentiality)
- `encrypted_regex` targets YAML keys (e.g., `^(data|stringData)$`)

**Common operations:**
```bash
# Encrypt file
sops --encrypt --in-place path/to/secret.sops.yaml

# Edit encrypted file
sops path/to/secret.sops.yaml

# Decrypt to stdout
sops --decrypt path/to/secret.sops.yaml
```

**Cluster secrets** (`kubernetes/components/common/sops/cluster-secrets.sops.yaml`) are substituted via `postBuild.substituteFrom` in Flux Kustomizations.

### 4. Flux Operations

```bash
# Force reconcile (after git push)
task reconcile

# Check Flux status
flux check
flux get sources git -A
flux get ks -A
flux get hr -A

# View specific HelmRelease
flux get hr -n {namespace} {app-name}
flux logs hr/{app-name} -n {namespace}
```

### 5. Bootstrap Flow

**Initial deployment** (from scratch):
```bash
task init              # Generate config files from samples
task configure         # Template out configs
task bootstrap:talos   # Install Talos + generate secrets
task bootstrap:apps    # Apply CRDs, secrets, helmfile charts, start Flux
```

**Bootstrap script** (`scripts/bootstrap-apps.sh`) order:
1. Wait for nodes (Ready=False)
2. Create namespaces
3. Apply SOPS secrets (sops-age, cluster-secrets, github-deploy-key)
4. Apply CRDs (external-dns, gateway-api, prometheus-operator)
5. Helmfile sync (cilium → coredns → cert-manager → flux-operator → flux-instance)

## Project Conventions

### HelmRelease Patterns

**OCIRepository with chartRef** (standard pattern for most apps):
```yaml
chartRef:
  kind: OCIRepository
  name: bjw-s-app-template  # References OCIRepository in same namespace
```

**Each app defines its own OCIRepository** resource in the `app/` directory (e.g., `app/ocirepository.yaml`) or shares one from a common directory (e.g., `media/shared/ocirepository-bjw-s.yaml`). The `chartRef.name` must match the OCIRepository's `metadata.name`.

**Traditional chart spec** (legacy, used for bootstrap helmfile only):
```yaml
chart:
  spec:
    chart: cilium
    sourceRef:
      kind: HelmRepository
      name: cilium
```

### Gateway API Routes

**Internal routes** (home network only):
```yaml
route:
  app:
    hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
    parentRefs:
      - name: internal
        namespace: kube-system
        sectionName: https
```

**External routes** (public via Cloudflare Tunnel):
```yaml
parentRefs:
  - name: external
    namespace: kube-system
    sectionName: https
```

### Kustomization Dependencies

Use `dependsOn` to enforce ordering:
```yaml
spec:
  dependsOn:
    - name: cert-manager
      namespace: cert-manager
```

### Namespace Hardcoding

**Flux repositories** must have `namespace: flux-system` hardcoded for Renovate lookups to work.

### Resource Limits

Always set `requests.cpu` and `limits.memory` for workloads (not optional in this cluster).

## Tool Environment

**Mise** manages all CLI tools (`.mise.toml`):
- Runs in virtualenv at `.venv/`
- Sets `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, `TALOSCONFIG` automatically
- All tools (kubectl, flux, talosctl, etc.) installed via aqua/pipx
- Includes Python 3.14, Go Task, Helm, Helmfile, Kustomize, and more

**Run `mise trust && mise install`** after cloning or when `.mise.toml` changes.

**Common task commands** (see `Taskfile.yaml` for all):
- `task` - List all available tasks
- `task reconcile` - Force Flux to sync from Git
- `task init` - Generate config files from samples
- `task configure` - Template out Kubernetes and Talos configs
- `task bootstrap:talos` - Install Talos
- `task bootstrap:apps` - Bootstrap cluster apps
- `task talos:*` - Various Talos operations

## Debugging Common Issues

### 1. HelmRelease stuck or failing
```bash
flux get hr -A  # Check status
kubectl -n {namespace} describe hr {name}
kubectl -n {namespace} get events --sort-by='.metadata.creationTimestamp'
```

### 2. Talos config errors
- **"missing path" errors**: Parent path doesn't exist in patch (see talos/patches examples)
- **Version mismatches**: Check `talenv.yaml` vs actual cluster versions

### 3. SOPS decryption failures
- Verify `age.key` exists and matches `.sops.yaml` recipient
- Check `sops-age` secret exists in namespace: `kubectl -n flux-system get secret sops-age`

### 4. DNS not resolving
- Check k8s_gateway pod: `kubectl -n network get pods`
- Verify split-horizon DNS forwarding on router/DNS server
- Test: `dig @{cluster_dns_gateway_addr} echo.${SECRET_DOMAIN}`

### 5. Flux not syncing
- Check webhook: `kubectl -n flux-system get receiver github-webhook`
- Force reconcile: `task reconcile`
- Check git credentials: `kubectl -n flux-system get secret github-deploy-key`

## Key Files Reference

- `talconfig.yaml` - Node definitions, VIP, network config, patch references
- `talenv.yaml` - Version declarations (auto-updated by Renovate)
- `.sops.yaml` - Encryption rules (order matters!)
- `Taskfile.yaml` - Main task runner (includes `.taskfiles/`)
- `bootstrap/helmfile.d/01-apps.yaml` - Initial Helm releases (must match app versions)
- `kubernetes/flux/cluster/ks.yaml` - Entry point for Flux GitOps
- `kubernetes/components/common/repos/` - Shared OCIRepository/HelmRepository definitions

## Renovate Integration

Renovate auto-updates:
- Helm chart versions in `HelmRelease`
- Container images in `HelmRelease` values
- `talenv.yaml` versions (Talos, Kubernetes)
- Tool versions in `.mise.toml`
- CRD URLs in `bootstrap-apps.sh` comments

**Comment format for Renovate to detect:**
```yaml
# renovate: datasource=docker depName=ghcr.io/owner/repo
talosVersion: v1.11.2
```

## Flux MCP Server

The Flux Operator MCP Server is configured to provide AI-assisted GitOps capabilities. See `.github/flux-mcp-instructions.md` for detailed guidelines on analyzing and troubleshooting Flux resources.
