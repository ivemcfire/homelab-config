# frigate-backup/ — a CronJob that can fail out loud

Companion to *[Empty Logs and a Burning Core: Tracing a Silent k3s Failure
Three Layers Down](https://ivemcfire.github.io/posts/k3s-leaked-goroutine.html)*.
The original version of this backup installed rsync at runtime with the output
sent to `/dev/null`, and failed silently for 28 days. This directory is the
rebuilt version: no runtime dependencies, and a failure emails within a minute.

## Repository structure

```
frigate-backup/
├── README.md                  # this file
├── backup-cronjob.yaml        # nightly rsync mirror of Frigate data, 02:00
└── alertmanager-config.yaml   # routing: KubeJobFailed → email, noise → blackhole
```

## Key design decisions

- rsync + ssh are baked into the image (`instrumentisto/rsync-ssh`), not
  installed at runtime — the backup depends on nothing that is not the data
- `KubeJobFailed` is whitelisted for email instead of un-blackholing all
  warnings — alert on what is actionable, keep the rest quiet
- `--bwlimit=20000` + `--partial` so a 42 GB initial sync does not saturate
  the LAN and survives interruption
- `concurrencyPolicy: Forbid` + `activeDeadlineSeconds: 14400` — long syncs
  may not overlap, and a hung ssh cannot park a Job forever

## Bring-up order

1. Create the ssh key secret the job mounts:
   `kubectl -n frigate create secret generic jumphost-ssh-key --from-file=id_ed25519=<key>`
2. `kubectl apply -f backup-cronjob.yaml`
3. `kubectl apply -f alertmanager-config.yaml` (replace `user@example.com`
   and the smtp secret with your own), then
   `kubectl -n monitoring rollout restart deploy alertmanager`
4. Smoke-test without waiting for 02:00:
   `kubectl -n frigate create job backup-smoke --from=cronjob/frigate-backup`

## Notes on the captured state

This is current production as of 2026-06, not the original build. The original
used `alpine:3.20` + `apk add` at runtime and a different destination host —
both changed after the incident in the post. The destination IP and paths are
the real homelab values, consistent with the post body.

## What is not in this directory

- The ssh private key and smtp password (Kubernetes Secrets, never committed)
- The Frigate deployment itself (see `apps/`)
- The kube-prometheus-stack install that provides the `KubeJobFailed` rule
