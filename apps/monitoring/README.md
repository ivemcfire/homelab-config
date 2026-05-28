# monitoring/ — observability stack

Cluster-side observability built on the `kube-prometheus-stack` helm chart
(release name was `monitoring`, namespace `monitoring`). The original Helm
release record has been lost — `helm list -n monitoring` shows only `loki`.
The deployed objects (Prometheus, Grafana, Alertmanager, node-exporter,
kube-state-metrics, prometheus-operator, ServiceMonitors, PrometheusRules)
are still running but not currently tracked by Helm.

**Practical implication:** this directory does NOT reproduce the full stack.
It only source-controls the pieces that have been edited or added by hand
since deployment, plus a few standalone items that aren't in the chart.

## What's in this directory

| File | Purpose |
|---|---|
| `alertmanager.yaml` | Standalone Alertmanager Deployment + ConfigMap. NOT the kube-prometheus one — separate deploy, pinned to k3master. Routes critical+warning to email (Gmail SMTP). Secret `alertmanager-email` applied separately (see Secrets below). |
| `prometheus-lan-svc.yaml` | LoadBalancer Service exposing Prometheus on `192.168.100.202:9090` so `.62` Grafana can query it from outside the cluster. Added 2026-05-28. |
| `additional-scrape-configs.yaml` | Plaintext form of the `additional-scrape-configs` Secret. Defines the `node-exporter-jumphost` scrape (target `192.168.100.62:9100`). Apply procedure inside the file. |
| `patch-node-exporter-resources.yaml` | Strategic-merge patch removing the CPU limit on node-exporter (fixes the kube-prometheus CPUThrottlingHigh false positive: scrape bursts > 200m → 85 % CFS throttle, but useless throttle since usage is ~10m avg). Apply with `kubectl patch ds -n monitoring node-exporter --patch-file ... --type=merge`. |
| `homelab-alerts-prometheusrule.yaml` | The homelab-specific PrometheusRule (frigate-cameras, frigate-service, frigate-storage, backup-alerts, node-health groups). Existed pre-source-control; checked in 2026-05-28. |
| `loki/` | Loki-stack helm-managed. See `helm list -n monitoring`. |

## Secrets — applied out-of-band

These secrets are referenced by the manifests above but **NOT in this repo**.
Apply them on a rebuild before applying the manifests.

| Secret | Contents | Source of truth |
|---|---|---|
| `alertmanager-email` | `smtp-password` key (Gmail App Password, 16 chars) | `homelab-docs/credentials.md.age` section "Gmail App Password (alertmanager)" |
| `jumphost-ssh-key` | `id_ed25519` for cluster→jumphost SSH (used by per-app postgres-backup CronJobs) | Pre-existing; key on `.62:~/.ssh/authorized_keys` |
| `alertmanager-telegram` | Legacy Telegram bot token. Deployed but no longer referenced by alertmanager-config as of 2026-05-28 (switch to email). Safe to delete. | |

## Re-tracking the rest with Helm (future work)

To bring `kube-prometheus-stack` back under Helm management:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Adopt without re-deploying: install with same release name + same values,
# rely on helm's "skip if exists / update if changed" behavior.
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --version <pin-to-current-chart-version> \
  -f values.yaml \
  --reuse-values
```

This isn't done yet. Pick this up when you have time to draft `values.yaml`
that matches current cluster state (resource requests, ServiceMonitor labels,
Alertmanager external config, etc.).
