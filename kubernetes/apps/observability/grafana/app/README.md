# Grafana App - UniFi Dashboard Provisioning

## UniFi Dashboards (UnPoller)

UniFi dashboards are provisioned via Kubernetes ConfigMaps using Kustomize's configMapGenerator for reliable datasource substitution and automatic updates.

- **Source:** Dashboards are synced from [unpoller/dashboards](https://github.com/unpoller/dashboards/tree/master/v2.0.0) using a GitHub Action.
- **Provisioning:** Dashboards are stored as JSON files in `app/dashboards/` and converted to ConfigMaps via `configMapGenerator` in `kustomization.yaml`.
- **Automation:** The dashboard JSON files are managed by automation. Do not edit them manually.
- **Why:** This approach ensures that Grafana's sidecar can substitute datasource variables (the JSON files contain datasource UIDs that get replaced with actual datasource names) and that dashboards remain up-to-date with upstream changes.

### How it works

1. The GitHub Action fetches the latest dashboards and saves them to `app/dashboards/`.
2. Kustomize's `configMapGenerator` creates ConfigMaps from these JSON files with proper labels and annotations.
3. Flux applies the generated ConfigMaps to the cluster.
4. Grafana sidecar (configured with `label: grafana_dashboard`) loads dashboards from these ConfigMaps into the `UniFi` folder.

### Manual Update (if needed)

Run the following commands from the repository root:

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
```

---

**Note:** UniFi dashboards are provisioned via `configMapGenerator` in `kustomization.yaml`, not via static ConfigMap YAML files.
