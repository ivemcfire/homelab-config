# Grafana dashboards (jumphost .62)

Dashboards for the standalone Docker Grafana running on `.62:3000`
(see `../README.md` for the wider jumphost role).

## Files

| Dashboard | UID | Purpose |
|---|---|---|
| `homelab-overview.json` | `homelab-overview` | At-a-glance: 7 square up/down tiles + 7-day state-timeline graph + 24h time-series for CPU/Mem/Disk/Load. Each tile links to Node Detail. Set as home dashboard. |
| `node-detail.json` | `node-detail` | Drill-down per node. `$instance` variable, header strip (name/up/uptime/load/cpus), per-core CPU, memory breakdown, disk per mount, network per interface. |

## Grafana image version

**Pin to `grafana/grafana:11.5.2` — do NOT use `:latest` or `:12.x` on `.62`.**

Grafana 12 introduced a Kubernetes-style internal apiserver ("unified
storage") that needs more CPU and RAM than the AMD C-50 / 1.5 GiB can
provide. Tested on 2026-05-28: `12.4.0` saturated 384 MiB and every
request timed out at ~47 s.

Container is started with:

```bash
docker run -d \
  --name grafana \
  --restart unless-stopped \
  --memory 384m \
  --memory-swap 512m \
  -p 3000:3000 \
  -v /home/user/grafana/data:/var/lib/grafana \
  -v /home/user/grafana/provisioning:/etc/grafana/provisioning:ro \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD=<see credentials.md.age "Grafana .62"> \
  -e GF_AUTH_ANONYMOUS_ENABLED=false \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  -e GF_PLUGINS_PREINSTALL= \
  grafana/grafana:11.5.2
```

Idle footprint on the C-50: ~210 MiB RAM, ~5–25 % CPU.

## Datasource

Both dashboards reference the Prometheus datasource by UID baked into the
JSON at export. The datasource is provisioned via
`~/grafana/provisioning/datasources/cluster-prom.yaml` on `.62`:

```
name: cluster-prometheus
type:  prometheus
url:   http://192.168.100.202:9090   (monitoring/prometheus-lan k8s svc)
```

The UID is auto-generated on first provisioning. Re-imports into a fresh
Grafana need a UID rewrite — see *Re-importing* below.

## Re-importing after a Grafana rebuild

This is also the recovery path if a Grafana version upgrade/downgrade
wipes the dashboards (G12 → G11 will: G12 stores dashboards in unified
storage which G11 can't read).

```bash
PW=homelab   # or whatever is set on this Grafana
DS_UID=$(curl -sS -u admin:$PW http://192.168.100.62:3000/api/datasources/name/cluster-prometheus | jq -r .uid)
for f in homelab-overview.json node-detail.json; do
  sed -i "s/\"uid\":\"[A-Za-z0-9]\\{15,\\}\"/\"uid\":\"$DS_UID\"/g" "$f"
  python3 -c "import json,sys; d=json.load(open('$f')); print(json.dumps({'dashboard':d,'overwrite':True}))" \
    | curl -sS -u admin:$PW -H "Content-Type: application/json" -X POST -d @- \
      http://192.168.100.62:3000/api/dashboards/db
done
curl -sS -u admin:$PW -H "Content-Type: application/json" -X PUT \
  -d '{"homeDashboardUID":"homelab-overview"}' \
  http://192.168.100.62:3000/api/org/preferences
```

## Re-export after UI edits

```bash
# on .62
PW=homelab
for uid in homelab-overview node-detail; do
  curl -sS -u admin:$PW http://localhost:3000/api/dashboards/uid/$uid \
    | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['dashboard'], indent=2))" \
    > ~/grafana/exported/$uid.json
done
# then scp to .52:~/homelab-config/jumphost/grafana-dashboards/ and commit
```

## Known limitations

- Prometheus retention is 7d (kube-prometheus-stack default). The 7-day
  state-timeline is calibrated to match. Bump retention by editing the
  `Prometheus` CR: `spec.retention: 30d`. Disk impact ~3-5 GB additional
  on the prometheus PVC.
- No GPU panels yet. Adding a DCGM/nvidia exporter on `.56` (for the 1050Ti)
  + a GPU row in node-detail would close that gap. Adreno on the phones
  has no good exporter.
- Hardware ceiling: the C-50 / 1.5 GiB on `.62` means single-user, light
  dashboards only. Don't add heavy plugins, browser-side rendering, or
  long time ranges with hundreds of series.
