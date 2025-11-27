# UniFi Dashboards (UnPoller)

This directory is managed by GitHub Actions.

Dashboards are automatically downloaded from:
https://github.com/unpoller/dashboards/tree/master/v2.0.0

If you need to update manually, run:

```
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
  curl -fsSLO "$base_url/$dash"
done
```

Do not edit dashboard JSON files in this directory by hand.
