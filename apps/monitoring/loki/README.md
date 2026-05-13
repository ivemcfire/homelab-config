# Loki (single-binary, monitoring ns)

Installed via helm:

```
helm install loki grafana/loki --namespace monitoring -f values.yaml --version 6.53.0
```

To upgrade:

```
helm upgrade loki grafana/loki --namespace monitoring -f values.yaml --version 6.53.0
```

Data path: /var/loki (5 Gi PVC, local-path on k3master).
In-cluster URL: http://loki.monitoring.svc.cluster.local:3100/
