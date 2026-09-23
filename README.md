# Homelab High Availability k3s cluster — phones, control planes, build farm

A five-node k3s cluster built from a laptop, a mini-PC and three old OnePlus
phones, with a 2011 netbook as the third etcd member. Two amd64 servers plus
an etcd-only member give a 3-member quorum; three arm64 phone agents run on
USB tether. Mixed-arch, real workloads, running 24/7.

- No Wi-Fi between cluster members.
- No shared L2 between phones and the LAN.
- No cloud.

Just routed USB links to the phones, gigabit Ethernet between the servers,
postmarketOS + Ubuntu + Debian side by side, and a lot of things that do not
visually look like servers until you make them into a fully functional HA
Kubernetes cluster.

Built as a learning project with heavy AI assistance (mostly Claude Opus,
sometimes Gemini as a second opinion). Every change here was applied and
verified on the real hardware.

---

## What This Repo Contains

Every manifest the cluster runs lives here — this repo is the single source
of truth (consolidated 2026-07-12). Changes are applied with `kubectl apply`;
there is no GitOps controller reconciling it yet.

It is also the implementation layer behind these posts:

1. *[A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide][post-phones]*
   — the original phones-as-workers build.
2. *[What broke during a k3s sqlite → embedded etcd HA migration][post-ha]*
   — adding control planes and rebuilding the cluster around them.
3. *[Empty Logs and a Burning Core: Tracing a Silent k3s Failure Three Layers Down][post-goroutine]*
   — a silently failing backup, a leaked etcd goroutine, and profiling stripped binaries in production.
4. *[The Tunnel Was Up. The Cameras Were 502.][post-tunnel]* and
   *[Every Light Was Green. The Cluster Was Dead.][post-green]*
   — HA ingress, out-of-band access, and moving the watchers outside the cluster they watch.

Directory map:

- **`network/`** — post #1 companion: udev, netplan, USB gadget scripts,
  nftables overrides, MetalLB manifests, NAT, DTB battery patch, ping-matrix
  validation. Start here if you came from post #1.
- **`cluster/containerd-mirrors/`** — post #2 companion: the systemd drop-in
  + `fix-gitea-hosts.sh` that works around the k3s 1.35 hosts.toml synthesis
  bug. Applied on every node.
- **`frigate-backup/`** — post #3 companion: the rebuilt nightly rsync
  CronJob (dependencies baked into the image, no runtime apk) plus the
  Alertmanager routing that emails on `KubeJobFailed`.
- **`apps/`** — the workloads, listed below.
- **`jumphost/`** — the admin bastion: hardened sshd, fail2ban, and the
  Grafana dashboards that run outside the cluster.

[post-phones]: https://ivemcfire.github.io/posts/k3s-phone-cluster.html
[post-ha]: https://ivemcfire.github.io/posts/k3s-ha-migration.html
[post-goroutine]: https://ivemcfire.github.io/posts/k3s-leaked-goroutine.html
[post-tunnel]: https://ivemcfire.github.io/posts/cloudflared-ha-and-oob.html
[post-green]: https://ivemcfire.github.io/posts/every-light-was-green.html

---

## Architecture

- **Control plane (3-member embedded etcd quorum, all amd64):**
  - `k3master` — Lenovo laptop, .52 — server
  - `k3frigate` — i5-6600 mini-PC with GTX 1050 Ti, .56 — server, GPU node
  - `jumphost` — 2011 AMD C-50 netbook, .62 — **etcd-only** member
    (`--disable-apiserver --disable-controller-manager --disable-scheduler
    --disable-agent`), so it has no Node object and never appears in
    `kubectl get nodes`. Failover tested: k3s stopped on `.52`, the API stayed up.
- **Workers (arm64, on USB tether):** 3× OnePlus 6 / 6T phones running
  postmarketOS — `one6t` (10.0.1.2), `one62` (10.0.2.2), `one61` (10.0.3.2).
  Tainted `node-role/phone=true:NoSchedule` — see design decisions.
- **Networking:**
  - Gigabit Ethernet between the servers (LAN `192.168.100.0/24`)
  - Routed `/30` USB-tether link from `k3master` to each phone — phones do
    not reach the LAN; they reach the API server through the local peer IP
    (`10.0.X.1`) on `--flannel-iface usb0`
  - Flannel VXLAN for the pod overlay
- **Ingress / access:** Traefik; public hostnames through Cloudflare Tunnel
  (2 `cloudflared` replicas, no inbound ports) with Cloudflare Access SSO in
  front of admin UIs; admin access over a Tailscale mesh with two subnet routers.
- **Load balancing:** MetalLB L2 mode, pool `192.168.100.200-220`,
  advertisement pinned to the servers (phones cannot answer ARP on the LAN)
- **Registry:** self-hosted Gitea OCI at `192.168.100.206`, on a durable
  hostPath PVC pinned to `k3frigate`
- **Build infrastructure:** buildx kubernetes driver runs buildkitd pods
  natively on amd64 + arm64 nodes — no qemu emulation. App repos also build
  multi-arch images in GitHub Actions and push them to GHCR.

```
                  LAN 192.168.100.0/24
                          |
        +-------+---------+---------+-------+
        |       |                   |       |
     k3master k3frigate          jumphost gitea LB
       .52      .56                .62     .206
    (server)  (server, GPU)    (etcd-only)
        |
        +---USB tether (routed /30s)---+
        |          |          |
       one6t     one61      one62 (agents)
       10.0.1.2  10.0.3.2   10.0.2.2
```

---

## Workloads (`apps/`)

| Directory | What runs |
|---|---|
| `frigate/` | Frigate NVR (TensorRT object detection on the GTX 1050 Ti via the NVIDIA device plugin), its own MQTT broker, exporter |
| `cloudflared/` | Cloudflare Tunnel connectors for public hostnames |
| `hydroflow-backend/`, `hydroflow-frontend/`, `hydroflow-pg-*.yaml` | HydroFlow greenhouse IoT: ESP32 sensors → MQTT → TypeScript backend → Postgres → Angular dashboard, plus nightly `pg_dump` backup |
| `chickenflow/` | ChickenFlow coop automation backend + Postgres + nightly backup |
| `infra-mosquitto/` | Shared MQTT broker for HydroFlow, ChickenFlow and the inference worker |
| `gpu-inference/` | YOLOv8n chicken counting on a phone — **runs on the CPU** (~2.4 s/frame). The Adreno OpenCL stack is installed, but ONNX Runtime has no OpenCL execution provider, so this worker never used the GPU. Real acceleration needs a different engine (ncnn + Vulkan) |
| `smarter-device-manager/` | Exposes phone device nodes to pods |
| `gitea/` | Git + container registry |
| `buildkit/` | buildx kubernetes-driver builders (amd64 + arm64) |
| `monitoring/` | Alertmanager (hand-managed), custom alert rules, Loki, scrape config and patches over kube-prometheus-stack |
| `double-take/`, `face-recognition/` | **Retired** — face-recognition stack removed, namespaces deleted. Kept as a record only |

---

## Key Design Decisions

The non-obvious calls, with the trade-off implicit:

**Substrate / networking (post #1):**

- **USB instead of Wi-Fi** — radios introduce instability; USB is deterministic.
  Phones are physically tethered to the hub in exchange.
- **Routed `/30` links instead of a bridge** — Linux bridges with `br_netfilter`
  loaded silently drop pod traffic. The drops show up in no log and match no rule.
- **Flannel VXLAN instead of `host-gw`** — phones are not L2-adjacent.
  `host-gw` fails to install routes when nodes do not share a broadcast domain.
- **Disable nftables on phones** — postmarketOS's default forward chain drops
  every packet that does not match `usb*` / `wlan*`. Pod interfaces (`cni0`,
  `flannel.1`, `vethXXX`) match neither. None of this is visible from `iptables -L`.
- **Stable interface names via udev (by USB hub port path)** — gadget MACs
  randomise on every reboot; matching by MAC is fragile.
- **MetalLB advertisement pinned to the servers** — phones have no LAN
  interface; if the memberlist election hands a VIP to one of them, ARP
  black-holes silently.
- **Battery charge capped at ~3.8 V via DTB patch** — cells held at 100% on
  permanent AC swell. Cap is configuration, not hardware.
- **Powered USB hub is mandatory** — a laptop port (~0.5 A) cannot sustain
  a phone (~1 A) under cluster load.

**HA + workload placement:**

- **Embedded etcd over external Postgres** for the k3s datastore — fewer
  moving parts, no extra SPOF, ships with k3s. Trade-off: a node losing its
  disk means etcd has to be rebuilt from a snapshot.
- **An etcd-only third member instead of a third full server** — when the
  Surface Pro 4 (the original third control plane) was retired with a swollen
  battery, the cluster was left on 2-member etcd, which tolerates zero
  failures: worse than one member. The jumphost joined as etcd-only — quorum
  without a kubelet or workloads. Trade-off: it has ~1.5 GiB RAM, so etcd
  memory there is watched.
- **Phones tainted `NoSchedule` by power budget** — the scheduler saw the
  phones as idle and piled services onto them until one browned out on its
  2 A supply. Now only arm64-native workloads and DaemonSets tolerate the taint.
- **DNS-dependent workloads pinned off the phones** — in-pod DNS does not
  reach CoreDNS from the phone nodes. CronJobs and anything using `*.svc`
  names run on the servers; phone-pinned pods use LoadBalancer IPs.
- **Mosquitto moved off the phones** — the MQTT broker is critical for
  HydroFlow + ChickenFlow; phones are not reliable enough to host it.
- **buildx kubernetes driver over remote-SSH-to-phone** — buildkitd runs as a
  pod, kubelet handles privilege. Native amd64 + arm64 builds at ~30× the
  speed of qemu.
- **Gitea on a hostPath PVC pinned to `k3frigate`** — persistence over
  portability. Pre-migration emptyDir meant the registry vanished the moment
  the pod restarted.
- **`fix-gitea-hosts.sh` systemd drop-in on every node** — k3s 1.35
  synthesises `hosts.toml` with `server = "https://..."` even when
  `registries.yaml` specifies http; containerd silently ignores the mirror
  block. The drop-in overwrites the file after every k3s restart.

**Observability:**

- **Watchers outside the cluster they watch** — Grafana and Uptime Kuma run on
  the jumphost; alerts go out through Gmail SMTP, not a path that depends on
  the cluster's own network.
- **Patches, not full resources, for kube-prometheus-stack** — the release
  drifted out of Helm tracking; strategic-merge patches survive a future
  Helm re-adoption where full copies would diverge.

---

## Known Issues

- `k3master`'s LAN runs over a USB 2.5G adapter (RTL8156) that has wedged
  under USB power management. Mitigated with a `usbcore.quirks` entry and an
  auto-recovery watchdog; the real fix is hardware with an onboard NIC.
- One phone's supply is undersized — software-mitigated by the taint above.
- No GitOps controller yet; manifests are applied by hand.

---

## What You Should Expect

This setup works, but it is opinionated and constrained.

You will run into:

- non-obvious networking failures
- silent packet drops
- interface renaming after reboots
- power-delivery limits on hub ports
- hardware behaviour that was never meant for servers

The fixes are cheap. Finding them is the expensive part.

---

## What This Is Not

- Not a beginner Kubernetes guide
- Not a production recommendation
- Not plug-and-play

This is a systems exercise.

---

## Requirements

- Two Linux servers plus one small always-on box for the third etcd member
  (this build uses a Lenovo IdeaPad, an i5 mini-PC and a 2011 netbook)
- Two or three postmarketOS-capable phones (this build uses OnePlus 6 / 6T)
- A **powered** USB hub — this is not optional
- Working familiarity with: Linux networking, k3s, embedded etcd, systemd,
  netplan, udev, iptables / nftables, containerd registry config

---

## Why This Exists

Because unused hardware is still compute.
Because managed Kubernetes hides too much.
Because understanding failure modes is more valuable than avoiding them.

---

## Related Write-ups

Full narratives — design decisions, what broke, and what each fix taught:

→ [*A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide*][post-phones]
→ [*What broke during a k3s sqlite → embedded etcd HA migration*][post-ha]
→ [*Empty Logs and a Burning Core: Tracing a Silent k3s Failure Three Layers Down*][post-goroutine]
→ [*The Tunnel Was Up. The Cameras Were 502.*][post-tunnel]
→ [*Every Light Was Green. The Cluster Was Dead.*][post-green]

## License

MIT.

## Contributing

If you improve stability, portability, or reduce the number of *invisible
failures* — PRs are welcome.
