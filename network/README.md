# Phones as Kubernetes Nodes (k3s over USB)

A four-node k3s cluster built from a laptop and three old OnePlus phones —
connected entirely over USB.

- No Wi-Fi.
- No switch.
- No shared L2 between nodes.

Just point-to-point USB links, postmarketOS, and a lot of things that do not
behave like servers until you force them to.

---

## What This Repo Contains

This directory is the implementation layer behind the post
*[A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide][post]*.

- `udev` rules for stable USB interface naming
- `netplan` configs for `/30` point-to-point routing
- USB gadget setup scripts with fixed MAC addresses
- `nftables` flush + service-disable for postmarketOS
- MetalLB manifests with a single-node L2 speaker
- NAT systemd unit for outbound connectivity
- Device-tree patch for battery charge limiting
- A 4×4 ping matrix script that proves the overlay is alive

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
network/
├── README.md                                — this file
├── k3master/
│   ├── netplan-00-installer-config.yaml     — wan0 + 3× usb-one* /30
│   ├── udev-90-usb-phones.rules             — stable iface names by USB port path
│   ├── sysctl-90-k3s-network.conf           — ip_forward, rp_filter, bridge-nf off
│   ├── k3s-config.yaml                      — VXLAN, disable servicelb, tls-san
│   └── k3s-nat.service                      — POSTROUTING MASQUERADE oneshot
├── phones/
│   ├── setup-usb-gadget.sh                  — gadget bring-up + fixed MAC pinning
│   ├── macs.env                             — per-phone host_addr / dev_addr table
│   ├── nftables.nft                         — flush ruleset (default forward = drop)
│   ├── sysctl-90-k3s-network.conf           — same kernel knobs as the laptop
│   └── k3s-config.yaml.tmpl                 — agent config template
├── metallb/
│   ├── ipaddresspool-homelab.yaml           — 192.168.100.200–220
│   └── l2advertisement-k3master.yaml        — pinned to k3master only
├── tools/
│   └── dtb-voltage-cap.sh                   — DTC patch for ~3.8 V charge ceiling
└── validate/
    └── ping-matrix.sh                       — 4×4 pod-to-pod connectivity check
```

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

## Bring-up Order

The order matters. Most failures here are ordering bugs.

1. **Phones first.** Flash postmarketOS, drop `phones/setup-usb-gadget.sh`
   (with the per-phone MACs from `phones/macs.env`) into `/usr/local/bin/`,
   install `phones/nftables.nft` to `/etc/nftables.nft` and disable the
   service (`doas rc-update del nftables`). Apply `phones/sysctl-*.conf`.
   Patch the device tree with `tools/dtb-voltage-cap.sh` while you are at it.

2. **Laptop next.** Drop `k3master/udev-90-usb-phones.rules` into
   `/etc/udev/rules.d/`, plug the phones in, confirm the interfaces appear
   as `usb-one6t`, `usb-one62`, `usb-one61`. Apply `k3master/netplan-*.yaml`.

3. **NAT before k3s.** Install `k3master/k3s-nat.service`, enable it. The
   `Before=k3s.service` directive ensures phones can pull images on first
   agent start. Without it, agents come up but every pod hangs in
   `ContainerCreating` until the registry is reachable.

4. **k3s server.** Apply `k3master/k3s-config.yaml`, install k3s, capture
   the join token from `/var/lib/rancher/k3s/server/node-token`.

5. **k3s agents.** On each phone, write `phones/k3s-config.yaml.tmpl` with
   the per-host substitutions, then:
   ```
   doas sh -c 'INSTALL_K3S_SKIP_DOWNLOAD=true K3S_TOKEN=<token> \
     K3S_URL=https://10.0.1.1:6443 /tmp/k3s-install.sh'
   ```
   `doas` does not pass through `-E`. Set the env inline.

6. **MetalLB.** Apply the upstream manifest, then `metallb/*.yaml`.
   The `nodeSelectors` on the L2Advertisement is not optional.

7. **Verify.** Run `validate/ping-matrix.sh`. All 16 paths should return
   `ok`. If any fail, the post's *Things That Went Wrong* section is the
   first place to look.

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

## Notes on the Captured State

- `k3master/k3s-config.yaml` shows the cluster as it stands today, with
  flannel anchored on `wan0`. Initial bring-up used `flannel-iface: usb-one6t`
  with `node-ip: 10.0.1.1` — both work; the post describes the original
  build. ServiceLB is disabled either way so MetalLB owns LoadBalancer
  assignment.
- LAN IPs (`192.168.100.0/24`) are intentionally left as the originals —
  they match what the post shows in CLI output, and they are RFC1918.
- MAC addresses in `udev-90-usb-phones.rules` and `phones/macs.env` are
  locally-administered and carry no identifying value off this network.

## What is *Not* in This Directory

- The k3s join token — pull it once with
  `cat /var/lib/rancher/k3s/server/node-token`.
- The MetalLB upstream manifest — apply directly:
  ```
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
  ```
- Workload manifests — application deployments live under `../apps/`,
  monitoring under `../monitoring/`.

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

MIT — see the repository root.

## Contributing

If you improve stability, portability, or reduce the number of *invisible
failures* — PRs are welcome.
