# Grafana dashboards (jumphost .62)

Dashboards for the standalone Docker Grafana running on `.62:3000`
(see `../README.md` for the wider jumphost role).

## Files

| Dashboard | UID | Purpose |
|---|---|---|
| `homelab-overview.json` | `homelab-overview` | At-a-glance: 7 square up/down tiles + 7-day state-timeline graph + 24h time-series for CPU/Mem/Disk/Load. Each tile links to Node Detail. Set as home dashboard. |
| `node-detail.json` | `node-detail` | Drill-down per node. `$instance` variable, header strip (name/up/uptime/load/cpus), per-core CPU, memory breakdown, disk per mount, network per interface. |

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

```bash
PW=homelab
DS_UID=$(curl -sS -u admin:$PW http://192.168.100.62:3000/api/datasources/name/cluster-prometheus | jq -r .uid)
for f in homelab-overview.json node-detail.json; do
  # rewrite the datasource UID in the dashboard JSON
  sed -i "s/\"uid\":\"[A-Za-z0-9]\\{15,\\}\"/\"uid\":\"$DS_UID\"/g" "$f"
  python3 -c "import json,sys; d=json.load(open('$f')); print(json.dumps({'dashboard':d,'overwrite':True}))" \
    | curl -sS -u admin:$PW -H "Content-Type: application/json" -X POST -d @- \
      http://192.168.100.62:3000/api/dashboards/db
done
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
