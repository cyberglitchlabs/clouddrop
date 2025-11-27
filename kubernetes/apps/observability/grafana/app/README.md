# Grafana App - UniFi Dashboard Provisioning

## UniFi Dashboards (UnPoller)

UniFi dashboards are now provisioned via Kubernetes ConfigMaps for reliable datasource substitution and automatic updates.

- **Source:** Dashboards are synced from [unpoller/dashboards](https://github.com/unpoller/dashboards/tree/master/v2.0.0) using a GitHub Action.
- **Provisioning:** Each dashboard is stored as a ConfigMap in this directory (see `unifi-*-configmap.yaml`).
- **Automation:** The dashboard JSON is managed by automation. Do not edit these ConfigMaps manually.
- **Why:** This approach ensures that Grafana's sidecar can substitute datasource variables and that dashboards remain up-to-date with upstream changes.

### How it works
- The GitHub Action fetches the latest dashboards and updates the ConfigMaps.
- Flux applies the updated ConfigMaps to the cluster.
- Grafana sidecar loads dashboards from these ConfigMaps into the `UniFi` folder.

### Manual Update (if needed)
See `../dashboards/unifi-dashboards/README.md` for manual update instructions.

---

**Note:** Remove any URL-based provisioning for UniFi dashboards from the HelmRelease. Only ConfigMap-based provisioning is supported for UniFi dashboards.
