Phones as Kubernetes Nodes (k3s over USB)

A four-node k3s cluster built from a laptop and three old OnePlus phones — connected entirely over USB.

No Wi-Fi.
No switch.
No shared L2 network.

Just point-to-point USB links, postmarketOS, and a lot of things that don’t behave like servers until you force them to.

What This Repo Contains

This repository is the implementation layer behind the blog post:

→ udev rules for stable USB interface naming
→ netplan configs for /30 point-to-point routing
→ USB gadget setup scripts (fixed MAC addresses)
→ nftables overrides (disable default forward drops)
→ MetalLB manifests (single-node L2 speaker)
→ NAT configuration for outbound connectivity
→ Device Tree patches for battery charge limiting

This is not a one-command setup. It’s a collection of working parts that make the system stable.

Architecture Overview
Control plane: Lenovo laptop (k3master)
Workers: 3× OnePlus phones (postmarketOS, arm64)
Networking:
USB-C cables via powered hub
/30 routed links per phone
No shared L2 between nodes
Flannel VXLAN for pod networking
Load balancing: MetalLB (L2, pinned to control plane)
Outbound traffic: NAT via control plane
Phones <-> USB <-> Laptop <-> LAN
         (routed)     (NAT + LB)
Key Design Decisions
USB instead of Wi-Fi
Radios introduce instability. USB is deterministic.
Routed /30 links instead of bridging
Linux bridges + br_netfilter silently break pod traffic.
Flannel VXLAN instead of host-gw
Nodes are not L2-adjacent. host-gw fails.
Disable nftables on phones
Default forward policy drops pod interfaces.
Stable interface naming via udev (by USB path)
MAC addresses randomise on every boot.
Pin MAC addresses on USB gadget (phone side)
Required for deterministic matching.
MetalLB pinned to control plane
Phones cannot speak ARP on the LAN.
Battery charge capped (~70%) via DTB patch
Prevents long-term cell damage.
Powered USB hub required
Laptop ports alone cannot sustain multiple phones under load.
Repository Structure (example)
.
├── netplan/
│   └── 01-usb-links.yaml
├── udev/
│   └── 99-usb-net.rules
├── gadget/
│   └── setup-usb-gadget.sh
├── nftables/
│   └── disable-forward-drop.nft
├── metallb/
│   ├── ipaddresspool.yaml
│   └── l2advertisement.yaml
├── nat/
│   └── iptables-nat.sh
├── dtb/
│   └── battery-cap.patch
└── docs/
    └── topology.md

(Adjust paths to match actual repo)

What You Should Expect

This setup works, but it is opinionated and constrained.

You will run into:

Non-obvious networking failures
Silent packet drops
Interface renaming issues
Power delivery limits
Hardware behavior that was never meant for servers

The fixes are usually simple.
Finding them is not.

What This Is Not
Not a beginner Kubernetes guide
Not a production recommendation
Not plug-and-play

This is a systems exercise.

Requirements (High-Level)
Linux laptop (control plane)
2–3 supported phones (postmarketOS-capable)
Powered USB hub (critical)
Basic familiarity with:
Linux networking
k3s
systemd / netplan / udev
iptables / nftables
Related Write-Up

Full breakdown, decisions, and failure modes:

→ A k3s Cluster Over USB Cables: What postmarketOS and Linux Bridges Hide

Why This Exists

Because unused hardware is still compute.
Because managed Kubernetes hides too much.
Because understanding failure modes is more valuable than avoiding them.

License

MIT

Contributing

If you improve stability, portability, or reduce the number of “invisible failures” — PRs are welcome.
