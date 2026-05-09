# Face Recognition Stack — Double Take + CompreFace

Deployed 2026-05-09 on k3frigate (i5-6600, 1050Ti). CPU-only face recognition. Path B per V17.3 architecture decision (replaces Frigate native face_recognition).

## Apply order

```bash
# 1. Namespace + secret + PVCs
kubectl apply -f 00-namespace.yaml -f 10-postgres-secret.yaml -f 11-postgres-pvc.yaml
# Skip 11-models-pvc.yaml — known dead, see "Known issues" below.

# 2. Patch postgres password BEFORE applying (or use sealed-secrets):
#    Edit 10-postgres-secret.yaml: REPLACE_AT_DEPLOY_TIME_FROM_CREDENTIALS_MD_AGE → real pwd from ~/homelab-secrets/credentials.md
kubectl apply -f 10-postgres-secret.yaml

# 3. Postgres + wait
kubectl apply -f 12-postgres.yaml
kubectl -n face-recognition rollout status deploy/postgres --timeout=120s

# 4. CompreFace stack
kubectl apply -f 20-compreface-core.yaml -f 21-compreface-admin.yaml -f 22-compreface-api.yaml -f 23-compreface-fe.yaml
kubectl -n face-recognition rollout status deploy --timeout=300s

# 5. Ingress (LAN access via traefik IngressRoute → MetalLB IP 192.168.100.200)
kubectl apply -f 30-ingress.yaml

# 6. Daily Postgres backup CronJob (3 AM, 14-day retention, hostPath /mnt/frigate/compreface/postgres-backups)
kubectl apply -f 40-postgres-backup.yaml
```

## Bootstrap

1. Port-forward UI: `kubectl -n face-recognition port-forward --address 0.0.0.0 svc/compreface-fe 8001:80` (or LAN via /etc/hosts → http://compreface.lan)
2. Sign up — first user becomes superadmin
3. Create application named e.g. `frigate-faces`
4. Copy API key from app's "API key" tab
5. Apply key to Double Take config at `/mnt/frigate/double-take/config/config.yml` (NOT in this repo — see ~/homelab-config/apps/double-take/)

## Service URLs (in-cluster)

- Admin: `http://compreface-admin.face-recognition:8080`
- API: `http://compreface-api.face-recognition:8080`
- Core: `http://compreface-core.face-recognition:3000` (CPU mode, GPU_IDX=-1)
- FE: `http://compreface-fe.face-recognition:80`

## Resources (verified steady-state)

| Pod | Memory limit | CPU limit |
|-----|--------------|-----------|
| postgres | 512Mi | 500m |
| compreface-core | 4Gi | 1500m |
| compreface-admin | 512Mi | 500m |
| compreface-api | 512Mi | 500m |
| compreface-fe | 128Mi | 200m |

Liveness probes: TCP-socket on each port, initialDelaySeconds 60–180, periodSeconds 30, failureThreshold 3.

## Storage

- Postgres data: hostPath `/mnt/frigate/compreface/postgres` (PV `compreface-postgres-pv`, k3frigate-pinned)
- Postgres backups: hostPath `/mnt/frigate/compreface/postgres-backups` (PV `compreface-backups-pv`, daily 3am, 14-day retention)
- CompreFace models: NOT a PVC — image-bundled at `/app/ml/.models`. Do NOT mount empty PVC there (shadow-bug, see Known issues).

## Known issues

- **`11-models-pvc.yaml` is dead.** Initial deployment mounted an empty PVC at `/app/ml/.models` which shadowed image-bundled models (`facenet/calculator/20180402-114759/20180402-114759.pb` not found → CompreFace core 500 errors). PV + PVC + hostPath dir all deleted at runtime. Manifest kept for historical reference; do not apply.
- **CompreFace fe nginx env quirks:** template vars `CLIENT_MAX_BODY_SIZE` (use nginx-format `10M` not `10MB`), `PROXY_READ_TIMEOUT`, `PROXY_CONNECT_TIMEOUT` all required. Already set in `23-compreface-fe.yaml`.
- **Readiness probe 401/400/500 on Spring Boot endpoints:** removed at runtime — startup health endpoints require auth or differ from defaults. Liveness probes still active (TCP socket).

## Security

- `POSTGRES_PASSWORD` in `10-postgres-secret.yaml` is REDACTED (placeholder). Real value in `~/homelab-docs/credentials.md.age`.
- CompreFace API key for `frigate-faces` app is REDACTED in sibling repo `apps/double-take/10-config-cm.yaml`.
- Double Take has `SECURE=false` (no auth). Tighten before exposing externally via Cloudflare Tunnel.
