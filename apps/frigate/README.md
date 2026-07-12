# Frigate Storm-Load Hardening

Companion to the post *[The Tunnel Was Up. The Cameras Were 502.](https://ivemcfire.github.io/posts/cloudflared-ha-and-oob.html)* — specifically the section *What "No CPU Limit" Means When the Cameras All Move at Once*.

Full deployment manifests live in this directory (folded in from the retired `frigate-k8s` repo, 2026-07-12). `deployment-resources.yaml` is the storm-hardening patch snippet kept for the blog post below; the values are baked into `deployment.yaml`. NOTE: the ConfigMap is bootstrap-only — the authoritative Frigate config is the hostPath `/mnt/frigate/config/config.yml` on k3frigate (.56) and may drift ahead of git.

## What broke

`k3frigate` (i5-6600K, 4 cores, no HT, GTX 1050 Ti 4 GB, 16 GB RAM, `swap = 0`) is the only node Frigate runs on. During a rainstorm, all 8 cameras detected motion simultaneously. The Frigate pod had `requests.cpu: 1` and **no CPU limit**. Under load, ffmpeg + ONNX/TensorRT inference + recording consumed all 4 cores. There was no headroom left for the kubelet heartbeat, the etcd peer, or systemd. The node went silent at the CPU layer.

No kernel OOM lines — RAM was fine. k3s cold-restarted when systemd noticed kubelet had not pinged in 5 minutes. Twice in 48 hours.

## What changed

1. **Pod resources** — see `deployment-resources.yaml`. CPU limit `"3"`, mem requests `4Gi`, mem limits `6Gi`, shm `512Mi`.
2. **Node kubelet reservations** — see `k3s-config-kubelet-args.yaml`. `kube-reserved` and `system-reserved` reserve CPU and RAM for the OS and kubelet so the workload cannot starve them.
3. **zram on the node** — `zram-tools` Debian/Ubuntu package, `/etc/default/zramswap`:

   ```
   ALGO=zstd
   PERCENT=25
   PRIORITY=100
   ```

   `sudo systemctl enable --now zramswap.service` → `/dev/zram0` 3.9 G priority 100 on a 16 G machine. Compressed RAM, no disk involvement, never competes with Frigate I/O.

4. **Frigate `config.yml` two free wins**:
   - `cam21` and `cam22` `detect.width/height`: `1280x720` → `640x360`. The ONNX detector input is `320x320` — anything past `640x360` on the source stream is wasted decode and resize.
   - `cam19_yicam`: was a single RTSP input used for both `detect` and `record` roles, which forced Frigate to decode + re-encode internally. Split to a separate `cam19_sub` (yi-hack low-res stream) for the detect role; the main stream stays passthrough for record.

## Source of truth

Frigate has a `config-sync` sidecar that watches `/mnt/frigate/config/config.yml` on the host and writes changes back to the cluster's ConfigMap. The git-tracked `configmap.yaml` in `ivemcfire/frigate-k8s` is a downstream backup, not the source. It can lag by weeks. The hostPath is authoritative.

## How to apply

1. `kubectl -n frigate edit deploy/frigate` and patch `spec.template.spec.containers[?(@.name=='frigate')].resources` per `deployment-resources.yaml`. Plus the `shm` volume `sizeLimit`.
2. On `k3frigate`, append the contents of `k3s-config-kubelet-args.yaml` to `/etc/rancher/k3s/config.yaml`, then `sudo systemctl restart k3s` (etcd quorum holds with the other two CP nodes still up — verify with `kubectl get nodes` before restarting).
3. On `k3frigate`, `sudo apt-get install zram-tools`, write `/etc/default/zramswap` as above, `sudo systemctl enable --now zramswap.service`, verify with `swapon --show`.
4. Edit the live config at `/mnt/frigate/config/config.yml` directly. The sidecar will sync it back to the ConfigMap.

## What is *not* in this directory

- The full Frigate Deployment manifest (lives in `ivemcfire/frigate-k8s/deployment.yaml`)
- The full Frigate `config.yml` (lives at `/mnt/frigate/config/config.yml` on `k3frigate`; the snapshot in `ivemcfire/frigate-k8s/configmap.yaml` may be stale)
- RTSP credentials (in the `frigate-rtsp-creds` Secret)
- The `nvidia-device-plugin` DaemonSet (cluster-level, lives elsewhere)
