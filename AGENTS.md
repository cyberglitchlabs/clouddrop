# Agent Guidelines for CloudDrop

This document provides essential information for AI coding agents working on the CloudDrop Kubernetes cluster.

## Project Overview

CloudDrop is a **Talos Linux Kubernetes cluster** managed with **GitOps using Flux v2**. It follows the `onedr0p/cluster-template` pattern for homelab/bare-metal deployments with Cilium CNI, Gateway API, and Cloudflare Tunnel for external access.

## Build, Test, and Deployment Commands

### Task Runner Commands

All operations use the `task` command (Go Task). Ensure you're running within the mise environment.

```bash
# List all available tasks
task

# Bootstrap cluster from scratch
task init                    # Generate config files from samples
task configure               # Template out Kubernetes and Talos configs
task bootstrap:talos         # Install Talos Linux on nodes
task bootstrap:apps          # Bootstrap cluster apps (CRDs, secrets, Helm charts, Flux)

# Talos operations
task talos:generate-config   # Generate Talos configuration from talconfig.yaml
task talos:apply-node IP=192.168.42.254 MODE=auto  # Apply config to specific node
task talos:upgrade-node IP=192.168.42.254          # Upgrade Talos version
task talos:upgrade-k8s       # Upgrade Kubernetes version
task talos:reset             # Reset nodes to maintenance mode (destructive!)

# GitOps operations
task reconcile               # Force Flux to sync from Git repository
```

### Kubernetes Operations

```bash
# Flux status checks
flux check
flux get sources git -A
flux get ks -A               # List all Kustomizations
flux get hr -A               # List all HelmReleases

# Debug specific HelmRelease
flux get hr -n <namespace> <app-name>
flux logs hr/<app-name> -n <namespace>

# Standard kubectl operations
kubectl get pods -n <namespace>
kubectl logs -n <namespace> <pod-name> -f
kubectl describe hr -n <namespace> <app-name>
kubectl get events -n <namespace> --sort-by='.metadata.creationTimestamp'
```

### No Testing/Linting Commands

This project does **not** have traditional test suites or lint commands. Validation is done through:
- `task configure` - Templates and validates configurations via makejinja
- `kubectl --dry-run` - Validates Kubernetes manifests
- Flux reconciliation - Live validation during deployment

## Code Style Guidelines

### File Formatting

**Indentation** (from `.editorconfig`):
- **YAML/JSON/most files**: 2 spaces
- **Shell scripts**: 4 spaces
- **Markdown**: 4 spaces
- **CUE files**: tabs (size 4)
- **Line endings**: LF (Unix)
- **Charset**: UTF-8
- **Trailing whitespace**: Remove (except Markdown)
- **Final newline**: Required

### YAML Conventions

```yaml
---
# yaml-language-server: $schema=<schema-url>
apiVersion: <version>
kind: <kind>
metadata:
  name: <name>
spec:
  # Use 2-space indentation
  # Use double quotes for strings with variables
  # Use single quotes for literal strings when needed
  # Boolean values: "true" or "false" as strings when needed by the app
```

### Naming Conventions

- **Directories**: lowercase with hyphens (e.g., `cloudflare-tunnel`, `cert-manager`)
- **Files**: lowercase with hyphens (e.g., `helmrelease.yaml`, `cluster-secrets.sops.yaml`)
- **Kubernetes resources**: lowercase with hyphens (e.g., `cloudflare-tunnel`, `external-dns`)
- **Variables**: UPPER_SNAKE_CASE for environment variables (e.g., `SECRET_DOMAIN`, `KUBECONFIG`)
- **Shell variables**: lowercase with underscores (e.g., `apps_dir`, `namespace`)

### Kubernetes Resource Organization

**Every application follows this structure:**

```
kubernetes/apps/{namespace}/{app-name}/
├── ks.yaml                          # Flux Kustomization (entrypoint)
└── app/
    ├── kustomization.yaml           # Lists all resources
    ├── helmrelease.yaml             # Helm chart deployment
    ├── ocirepository.yaml           # Optional: app-specific OCI chart source
    ├── secret.sops.yaml             # Optional: encrypted secrets
    └── {other-resources}.yaml       # Optional: HTTPRoute, ConfigMap, etc.
```

**Namespace-level** `kustomization.yaml` lists all `ks.yaml` files:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./app1/ks.yaml
  - ./app2/ks.yaml
```

### HelmRelease Pattern

**Standard pattern** (using OCIRepository with chartRef):

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrelease-helm-v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: app-name
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: bjw-s-app-template  # Must match OCIRepository metadata.name
  install:
    remediation:
      retries: -1
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    controllers:
      app-name:
        strategy: RollingUpdate
        containers:
          app:
            image:
              repository: ghcr.io/owner/repo
              tag: v1.0.0
            resources:
              requests:
                cpu: 10m
              limits:
                memory: 256Mi
```

**Important**: Each `HelmRelease` must have an associated `OCIRepository` in the same namespace. The `chartRef.name` must match the `OCIRepository`'s `metadata.name`.

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
route:
  app:
    hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
    parentRefs:
      - name: external
        namespace: kube-system
        sectionName: https
```

### Secrets Management (SOPS)

**Encryption rules** (`.sops.yaml`):
- Specific path rules FIRST, general rules AFTER (order matters!)
- Talos secrets: `mac_only_encrypted: true` (integrity only)
- Kubernetes secrets: `encrypted_regex: "^(data|stringData)$"`

**Always encrypt secrets before committing:**

```bash
# Encrypt a new secret file
sops --encrypt --in-place path/to/secret.sops.yaml

# Edit encrypted secret
sops path/to/secret.sops.yaml

# Verify encryption
grep -q "sops:" path/to/secret.sops.yaml && echo "Encrypted" || echo "NOT ENCRYPTED!"
```

### Resource Limits

**ALWAYS** set resource requests and limits:

```yaml
resources:
  requests:
    cpu: 10m           # Required
  limits:
    memory: 256Mi      # Required
```

### Security Context

**Always** include security context:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true  # Preferred, use false if app needs write
  capabilities: { drop: ["ALL"] }

defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
```

## Error Handling

### Common Issues and Solutions

**HelmRelease stuck/failing:**
```bash
flux get hr -A  # Check all HelmReleases
kubectl -n <namespace> describe hr <name>
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

**Talos config errors:**
- "missing path" errors: Parent path doesn't exist in patch (check `talos/patches/` examples)
- Version mismatches: Verify `talenv.yaml` matches actual cluster

**SOPS decryption failures:**
- Check `age.key` exists and matches `.sops.yaml` recipient
- Verify `sops-age` secret: `kubectl -n flux-system get secret sops-age`

**DNS not resolving:**
- Check k8s_gateway pod: `kubectl -n network get pods`
- Test: `dig @<cluster-dns-ip> echo.${SECRET_DOMAIN}`

**Flux not syncing:**
- Force reconcile: `task reconcile`
- Check webhook: `kubectl -n flux-system get receiver github-webhook`

## Critical Guidelines

1. **Never commit unencrypted secrets** - Always verify `.sops.yaml` files are encrypted
2. **Always test with `task configure`** before pushing changes
3. **Use `dependsOn` in Flux Kustomizations** to enforce ordering
4. **Namespace hardcoding**: Flux repositories must use `namespace: flux-system` for Renovate
5. **No empty commits**: Check for actual changes before committing
6. **Talos patches**: Use RFC6902 JSON Patch format, create parent paths before using `-` (array append)
7. **Git workflow**: Edit → `task configure` → `git add` → `git commit` → `git push` → `task reconcile`
8. **OCIRepository naming**: `chartRef.name` must exactly match `OCIRepository` metadata name

## Environment Setup

This project uses **mise** to manage all dependencies. All tools are installed via aqua/pipx.

```bash
# Initial setup
mise trust
mise install

# Tools are automatically available in mise-managed shell
# Environment variables set by mise:
# - KUBECONFIG={{config_root}}/kubeconfig
# - SOPS_AGE_KEY_FILE={{config_root}}/age.key
# - TALOSCONFIG={{config_root}}/talos/clusterconfig/talosconfig
```

## Additional Notes

- This repository uses Renovate for automatic dependency updates
- Cloudflare Tunnel provides external access (tunnel ID: 14a65ddb-18a2-4d42-898e-52cd9cacde45)
- Cilium Gateway API provides internal/external gateways
- Split-horizon DNS via k8s_gateway and external-dns
- All secrets encrypted with SOPS + age (key: `age.key`)
