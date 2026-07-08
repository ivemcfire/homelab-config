# WP3 migration — hydroflow: gitea→ghcr multi-arch images, frontend first deploy

Apply order for the orchestrator. Nothing here has been applied to the
cluster; `sha-PLACEHOLDER` in both Deployments must be pinned first.

## 0. Prerequisite — first CI build on main

Merging the hydroflow WP3 branch to `main` triggers
`.github/workflows/build.yml` (hydroflow repo), which pushes:

- `ghcr.io/ivemcfire/hydroflow-backend:sha-<shortsha>`
- `ghcr.io/ivemcfire/hydroflow-frontend:sha-<shortsha>`

Both multi-arch (linux/amd64 + linux/arm64), sha-tags only, no `:latest`.
Pin the real tag in `apps/hydroflow-backend/deploy.yaml` and
`apps/hydroflow-frontend/deploy.yaml` (replace `sha-PLACEHOLDER`), commit
the pin.

Assumption carried from chickenflow: ghcr.io/ivemcfire packages are
**public**, so no imagePullSecrets anywhere. Verify once on the first pull;
if the package defaults to private, flip its visibility in GitHub package
settings (do NOT add registry creds to manifests).

## 1. gemini-api secret (new — hydroflow ns needs its own copy)

Secrets don't cross namespaces; chickenflow's `gemini-api` can't be reused.

```sh
kubectl create secret generic gemini-api \
  --namespace hydroflow \
  --from-literal=GEMINI_API_KEY='<REPLACE_WITH_REAL_KEY>'
```

The Deployment references it `optional: true` — the backend starts without
it (AI insights disabled), so ordering vs. step 2 is not strict, but do it
first anyway so insights work from the first rollout.

## 2. Backend image swap (gitea → ghcr) + unpin from one6t

```sh
kubectl apply -f apps/hydroflow-backend/deploy.yaml
kubectl -n hydroflow rollout status deploy/hydroflow-backend
```

What changes on rollout:
- image `192.168.100.206/...:20260513-0554` → `ghcr.io/ivemcfire/hydroflow-backend:sha-<pinned>`
- nodeSelector one6t + `node-role/phone` toleration removed — pod moves off
  the phone to a regular node (phones remain excluded by their taint)
- `imagePullSecrets: gitea-registry` removed
- probes: liveness+readiness both `GET /healthz :3000` (503-when-MQTT-dead
  semantics; liveness 30s×5 so broker blips don't hair-trigger restarts)
- `envFrom` gemini-api (optional)

Verify: `kubectl -n hydroflow get pod -o wide` (node is NOT one61/one62/one6t),
then `curl http://192.168.100.208:3000/healthz` → 200 with `mqtt.connected: true`.

Rollback: `kubectl -n hydroflow rollout undo deploy/hydroflow-backend`
(previous ReplicaSet still points at the gitea image, which stays pullable).

## 3. Frontend — FIRST deploy

```sh
kubectl apply -f apps/hydroflow-frontend/deploy.yaml
kubectl apply -f apps/hydroflow-frontend/svc.yaml
kubectl -n hydroflow rollout status deploy/hydroflow-frontend
```

Verify: `kubectl -n hydroflow get svc hydroflow-frontend` shows
EXTERNAL-IP `192.168.100.214`, then `curl -I http://192.168.100.214/` → 200.

## Untouched by WP3

`postgres-new`, the nightly backup CronJob (`hydroflow-pg-backup.yaml`),
namespace, and the backend Service (LB .208) are unchanged. The
`gitea-registry` secret in the namespace becomes unused (marked LEGACY in
secrets-stub.yaml) — leave it in place until a later cleanup pass.
