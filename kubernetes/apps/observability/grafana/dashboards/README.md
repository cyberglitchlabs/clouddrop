# Grafana Dashboard Files

This directory contains dashboard JSON files that are converted to ConfigMaps by Kustomize's `configMapGenerator`.

## Directory Structure

```text
dashboards/
├── README.md                                          # This file
├── jellyfin-monitoring.json                           # Custom Jellyfin dashboard
├── nvidia-gtx-monitoring.json                         # Custom NVIDIA GPU dashboard
├── UniFi-Poller_-Client-DPI---Prometheus.json        # UniFi dashboards (6 total)
├── UniFi-Poller_-Client-Insights---Prometheus.json
├── UniFi-Poller_-Network-Sites---Prometheus.json
├── UniFi-Poller_-UAP-Insights---Prometheus.json
├── UniFi-Poller_-USG-Insights---Prometheus.json
└── UniFi-Poller_-USW-Insights---Prometheus.json
```

## UniFi Dashboards

The UniFi dashboards are automatically synced from the [unpoller/dashboards](https://github.com/unpoller/dashboards/tree/master/v2.0.0) repository.

### Automatic Updates

A GitHub Actions workflow (`.github/workflows/update-unifi-dashboards.yml`) runs daily to:

1. Download the latest dashboard JSON files from upstream
2. Rename files to replace `%20` with `-` (ConfigMap key naming requirement)
3. Create a pull request with any updates

### Manual Update

To manually update the UniFi dashboards:

```bash
cd kubernetes/apps/observability/grafana/app/dashboards
base_url="https://raw.githubusercontent.com/unpoller/dashboards/refs/heads/master/v2.0.0"
dashboards=(
  "UniFi-Poller_%20Client%20Insights%20-%20Prometheus.json"
  "UniFi-Poller_%20Client%20DPI%20-%20Prometheus.json"
  "UniFi-Poller_%20Network%20Sites%20-%20Prometheus.json"
  "UniFi-Poller_%20UAP%20Insights%20-%20Prometheus.json"
  "UniFi-Poller_%20USG%20Insights%20-%20Prometheus.json"
  "UniFi-Poller_%20USW%20Insights%20-%20Prometheus.json"
)
for dash in "${dashboards[@]}"; do
  echo "Downloading $dash..."
  curl -fsSLO "$base_url/$dash"
done

# Rename files to replace %20 with dashes
for file in *%20*.json; do
  newname=$(echo "$file" | sed 's/%20/-/g')
  mv "$file" "$newname"
  echo "Renamed: $file -> $newname"
done
```

## How ConfigMaps Are Generated

The `../app/kustomization.yaml` file uses `configMapGenerator` to create ConfigMaps from these JSON files:

```yaml
configMapGenerator:
  - name: unifi-client-insights-dashboard
    files:
      - dashboards/UniFi-Poller_-Client-Insights---Prometheus.json
    options:
      labels:
        grafana_dashboard: "1"
      annotations:
        grafana_folder: "UniFi"
        kustomize.toolkit.fluxcd.io/substitute: disabled
```

**Important:** The `kustomize.toolkit.fluxcd.io/substitute: disabled` annotation prevents Flux from trying to substitute Grafana template variables (like `${VAR_NAME}`) which would cause postBuild failures.

## Grafana Sidecar

The Grafana sidecar container watches for ConfigMaps with the `grafana_dashboard: "1"` label and automatically loads them into Grafana. The `grafana_folder` annotation determines which folder the dashboard is placed in.

To verify dashboards are loaded, check the sidecar logs:

```bash
kubectl logs -n observability deployment/grafana -c grafana-sc-dashboard --tail=50
```
