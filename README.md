# Phones as Kubernetes Nodes (k3s over USB)

A four-node k3s cluster built from a laptop and three old OnePlus phones —
connected entirely over USB.

- No Wi-Fi.
- No switch.
- No shared L2 network.

Just point-to-point USB links, postmarketOS, and a lot of things that do not
behave like servers until you force them to.

---

## What This Repo Contains

The implementation layer behind the post
*[A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide][post]*,
plus the workloads that run on top of it.

- **`network/`** — the post's companion: udev, netplan, USB gadget scripts,
  nftables overrides, MetalLB manifests, NAT, DTB battery patch, and a 4×4
  ping-matrix validation script. Start here.
- **`apps/`** — application workloads that actually run on the phones
  (Gitea, guitar-app, open-webui, uptime-kuma).
- **`monitoring/`** — Fluent Bit configuration shipping logs into the
  Loki + Prometheus stack.

This is not a one-command setup. It is a collection of working parts that
make the system stable.

[post]: https://ivemcfire.github.io/posts/k3s-phone-cluster.html

---

## Architecture

- **Control plane:** Lenovo laptop (`k3master`, amd64)
- **Workers:** 3× OnePlus phones running postmarketOS (`one6t`, `one62`, `one61`, arm64)
- **Networking:**
  - USB-C cables via a powered hub
  - Routed `/30` link per phone
  - No shared L2 between nodes
  - Flannel VXLAN for the pod overlay
- **Load balancing:** MetalLB (L2 mode, pinned to control plane)
- **Outbound:** NAT (`MASQUERADE`) on `k3master` for `10.0.0.0/8`

```
Phones  <->  USB  <->  Laptop  <->  LAN
            (routed /30s)  (NAT + LB)
```

---

## Repository Structure

```
.
├── network/        — post companion: bring-up, validation, DTB tools (read README inside)
├── apps/           — application manifests scheduled across the phones
├── monitoring/     — Fluent Bit log shipping config
└── README.md       — this file
```

The deep-dive on the cluster substrate — bring-up order, design decisions,
what is captured and what is not — lives in [`network/README.md`](network/README.md).

---

## Key Design Decisions

The non-obvious calls, with the trade-off implicit:

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
- **Pin MAC addresses on the gadget side too** — gives the laptop udev a
  stable identifier to match against, instead of a moving target.
- **MetalLB advertisement pinned to `k3master`** — phones have no LAN
  interface; if the memberlist election hands a VIP to one of them, ARP
  black-holes silently.
- **Battery charge capped at ~3.8 V via DTB patch** — cells held at 100% on
  permanent AC swell. Cap is configuration, not hardware.
- **Powered USB hub is mandatory** — a laptop port (~0.5 A) cannot sustain
  a phone (~1 A) under cluster load. Two of three phones brown out without it.

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

- A Linux laptop for the control plane
- Two or three postmarketOS-capable phones (this build uses OnePlus 6 / 6T)
- A **powered** USB hub — this is not optional
- Working familiarity with: Linux networking, k3s, systemd, netplan, udev,
  iptables / nftables

---

## Why This Exists

Because unused hardware is still compute.
Because managed Kubernetes hides too much.
Because understanding failure modes is more valuable than avoiding them.

---

## Related Write-up

Full narrative — design decisions, what broke, and what each fix taught:

→ [*A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide*][post]

## License

MIT.

## Contributing

If you improve stability, portability, or reduce the number of *invisible
failures* — PRs are welcome.
