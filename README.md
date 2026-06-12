# Homelab High Availability k3s cluster — phones, control planes, build farm

A six-node k3s cluster built from laptops, a Surface tablet, and three
old OnePlus phones. Three control planes with embedded etcd, three arm64 phone
agents on USB tether. Mixed-arch, real workloads.

- No Wi-Fi between cluster members.
- No shared L2 between phones and the LAN.
- No cloud.

Just routed USB links to the phones, gigabit Ethernet between control planes,
postmarketOS + Ubuntu side by side, and a lot of things that do not visually look
like servers until you make them into fully functional HA kubernetis cluster.

---

## What This Repo Contains

The implementation layer behind three posts:

1. *[A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide][post-phones]*
   — the original phones-as-workers build.
2. *[What broke during a k3s sqlite → embedded etcd HA migration][post-ha]*
   — adding two control planes and rebuilding the cluster around them.
3. *[Empty Logs and a Burning Core: Tracing a Silent k3s Failure Three Layers Down][post-goroutine]*
   — a silently failing backup, a leaked etcd goroutine, and profiling stripped binaries in production.

Plus the workloads that run on top.

- **`network/`** — post #1 companion: udev, netplan, USB gadget scripts,
  nftables overrides, MetalLB manifests, NAT, DTB battery patch, ping-matrix
  validation. Start here if you came from post #1.
- **`cluster/containerd-mirrors/`** — post #2 companion: the systemd drop-in
  + `fix-gitea-hosts.sh` that works around the k3s 1.35 hosts.toml synthesis
  bug. Applied on all 6 nodes.
- **`frigate-backup/`** — post #3 companion: the rebuilt nightly rsync
  CronJob (dependencies baked into the image, no runtime apk) plus the
  Alertmanager routing that emails on `KubeJobFailed`.
- **`apps/`** — current workloads: Gitea (registry + Git, durable PVC),
  HydroFlow (Express + Postgres + MQTT for greenhouse IoT), ChickenFlow
  (Angular SSR + Postgres), Frigate companions (Double Take + CompreFace
  face-recognition), GPU-inference worker (ONNX on Adreno 630 via Rusticl),
  Loki + uptime-kuma in `apps/monitoring/`, plus buildkit and
  smarter-device-manager infrastructure.

This is not a one-command setup. It is a collection of working parts that
make the system stable.

[post-phones]: https://ivemcfire.github.io/posts/k3s-phone-cluster.html
[post-ha]: https://ivemcfire.github.io/posts/k3s-ha-migration.html
[post-goroutine]: https://ivemcfire.github.io/posts/k3s-leaked-goroutine.html

---

## Architecture

- **Control plane (3-member embedded etcd quorum, all amd64):**
  - `k3master` — Lenovo laptop, .52
  - `k3frigate` — i5-6600 mini-PC with GTX 1050Ti, .56 (also GPU node)
  - `k3sp4` — Surface Pro 4, .53
- **Workers (arm64, on USB tether):** 3× OnePlus 6 / 6T phones running
  postmarketOS — `one6t` (10.0.1.2), `one62` (10.0.2.2), `one61` (10.0.3.2)
- **Networking:**
  - Gigabit Ethernet between the three control planes (LAN `192.168.100.0/24`)
  - Routed `/30` USB-tether link from `k3master` to each phone — phones do
    not reach the LAN; they reach the API server through the local peer IP
    (`10.0.X.1`) on `--flannel-iface usb0`
  - Flannel VXLAN for the pod overlay
- **Load balancing:** MetalLB L2 mode, advertisement pinned to the control
  planes (phones cannot answer ARP on the LAN)
- **Registry:** self-hosted Gitea OCI at `192.168.100.206`, on a durable
  hostPath PVC pinned to `k3frigate`
- **Build infrastructure:** buildx kubernetes driver provisions buildkitd
  pods natively on amd64 + arm64 cluster nodes — no qemu emulation

```
                  LAN 192.168.100.0/24
                          |
        +-------+---------+---------+-------+
        |       |                   |       |
     k3master k3frigate          k3sp4   gitea LB
       .52      .56                .53     .206
    (CP+etcd) (CP+etcd, GPU)    (CP+etcd)
        |
        +---USB tether (routed /30s)---+
        |          |          |
       one6t     one61      one62 (agents)
       10.0.1.2  10.0.3.2   10.0.2.2
```

---

## Repository Structure

```
.
├── network/                    — post #1 companion: USB bring-up, validation, DTB tools
│   ├── k3master/               — netplan, udev, nftables on the control-plane laptop
│   ├── phones/                 — postmarketOS gadget setup, battery DTB patch
│   ├── metallb/                — IPAddressPool + L2Advertisement
│   ├── tools/                  — DTB extract/patch scripts
│   └── validate/               — 4×4 ping-matrix sanity script
├── cluster/
│   └── containerd-mirrors/     — post #2 companion: k3s 1.35 hosts.toml workaround
│                                  (drop-in + fix-gitea-hosts.sh)
├── apps/
│   ├── gitea/                  — Git + container registry, durable PVC on k3frigate
│   ├── buildkit/               — buildx kubernetes-driver namespace, RBAC, config
│   ├── hydroflow-backend/      — Express API for greenhouse IoT
│   ├── hydroflow-mosquitto/    — MQTT broker, repinned to k3frigate
│   ├── chickenflow/            — Angular SSR + Postgres on k3frigate
│   ├── double-take/            — face-rec orchestration (consumes Frigate events)
│   ├── face-recognition/       — CompreFace stack + Postgres
│   ├── gpu-inference/          — ONNX worker on Adreno 630 via Rusticl (arm64)
│   ├── smarter-device-manager/ — Adreno GPU device plugin for phones
│   └── monitoring/
│       ├── loki/               — log aggregation (helm values)
│       └── uptime-kuma.yaml    — uptime probe + dashboard
└── README.md                   — this file
```

The substrate deep-dive — USB bring-up order, design decisions, what is
captured and what is not — lives in [`network/README.md`](network/README.md).
The HA migration narrative — outage planning, restore mechanics, k3s 1.35
hosts.toml workaround — is the second blog post above.

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
- **MetalLB advertisement pinned to the control planes** — phones have no
  LAN interface; if the memberlist election hands a VIP to one of them, ARP
  black-holes silently.
- **Battery charge capped at ~3.8 V via DTB patch** — cells held at 100% on
  permanent AC swell. Cap is configuration, not hardware.
- **Powered USB hub is mandatory** — a laptop port (~0.5 A) cannot sustain
  a phone (~1 A) under cluster load.

**HA + workload placement (post #2):**

- **Embedded etcd over external Postgres** for the k3s datastore — fewer
  moving parts, no extra SPOF, ships with k3s. Trade-off: a node losing its
  disk means etcd has to be rebuilt from a snapshot.
- **Surface Pro 4 as CP3** — already in the house, 8 GB RAM is enough for
  kubelet plus light workloads. Trade-off: lid-switch / sleep / NIC
  power-save quirks to mask before joining.
- **Mosquitto re-pinned from a phone to `k3frigate`** during the reroll.
  The MQTT broker is critical for HydroFlow + ChickenFlow + Frigate events;
  phones are not reliable enough to host critical brokers.
- **buildx kubernetes driver over remote-SSH-to-phone** — no doas-passwordless
  setup needed for the build path itself; buildkitd runs as a pod, kubelet
  handles privilege. Native amd64 + arm64 builds at ~30× the speed of qemu.
- **Gitea on a hostPath PVC pinned to `k3frigate`** — persistence over
  portability. Pre-migration emptyDir meant the registry vanished the moment
  the pod restarted.
- **`fix-gitea-hosts.sh` systemd drop-in on all 6 nodes** — k3s 1.35
  synthesises `hosts.toml` with `server = "https://..."` even when
  `registries.yaml` specifies http; containerd silently ignores the mirror
  block. The drop-in overwrites the file after every k3s restart.

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

- Three Linux hosts for the control plane (any mix of laptops, mini-PCs, or
  tablets — this build uses a Lenovo IdeaPad, an i5 mini-PC, and a Surface
  Pro 4)
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

## License

MIT.

## Contributing

If you improve stability, portability, or reduce the number of *invisible
failures* — PRs are welcome.
