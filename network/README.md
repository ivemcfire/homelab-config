# network/

Configuration for the four-node k3s cluster described in
[*A k3s Cluster Over USB Cables*](https://ivemcfire.github.io/posts/k3s-phone-cluster.html).

The cluster is one Lenovo laptop (`k3master`, amd64 control plane) plus three
OnePlus phones (`one6t`, `one62`, `one61`, arm64 workers running postmarketOS).
Every phone is connected to the laptop with a single USB-C cable through a
powered hub. There is no Ethernet switch involved — node-to-node traffic is
routed `/30` point-to-point per phone, with Flannel VXLAN providing the pod
overlay on top of it.

The post explains *why* each of these files looks the way it does. This README
is the operational view: what to apply, in what order, and where to look when
something refuses to come up.

```
network/
├── k3master/   # laptop side: netplan, udev, sysctl, k3s server, NAT
├── phones/     # per-phone: gadget MAC pinning, nftables flush, k3s agent
├── metallb/    # IPAddressPool + L2Advertisement pinned to k3master
├── tools/      # dtb-voltage-cap.sh — battery longevity for always-on phones
└── validate/   # ping-matrix.sh — 4×4 pod-to-pod connectivity proof
```

## Bring-up order

The order matters. Most failures on this build are ordering bugs.

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
   agent start. Without it the agents come up but every pod hangs in
   `ContainerCreating` until the registry is reachable.

4. **k3s server.** Apply `k3master/k3s-config.yaml`, install k3s, capture
   the join token from `/var/lib/rancher/k3s/server/node-token`.

5. **k3s agents.** On each phone, write `phones/k3s-config.yaml.tmpl` with
   the per-host substitutions, then:
   ```
   doas sh -c 'INSTALL_K3S_SKIP_DOWNLOAD=true K3S_TOKEN=<token> \
     K3S_URL=https://10.0.1.1:6443 /tmp/k3s-install.sh'
   ```
   `doas` does not pass through `-E`, so set the env inline.

6. **MetalLB.** Apply the upstream manifest, then `metallb/*.yaml`.
   The `nodeSelectors` on the L2Advertisement is not optional — without
   it, MetalLB's memberlist election can hand a VIP to a phone that has
   no LAN interface to ARP onto.

7. **Verify.** Run `validate/ping-matrix.sh`. All 16 paths should return
   `ok`. If any fail, the post's *Things That Went Wrong* section is the
   first place to look — most failures here are nftables on a phone, a
   bridge that should not be there on the laptop, or k3s-nat racing the
   k3s service start.

## Notes on the captured state

- `k3master/k3s-config.yaml` shows the cluster as it stands today, with
  flannel anchored on `wan0`. Initial bring-up used `flannel-iface: usb-one6t`
  with `node-ip: 10.0.1.1` — both work, the post describes the original
  build. ServiceLB is disabled either way so MetalLB owns LoadBalancer
  assignment.
- LAN IPs (`192.168.100.0/24`) are intentionally left as the originals —
  they match what the post shows in CLI output, and they are RFC1918.
- MAC addresses in `udev-90-usb-phones.rules` and `phones/macs.env`
  match what the post shows verbatim. They are locally-administered and
  carry no identifying value off this network.

## What is *not* in this directory

- The k3s join token. Pull it once from the server with
  `cat /var/lib/rancher/k3s/server/node-token` and pass it inline.
- The MetalLB upstream manifest. Apply directly:
  ```
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
  ```
- Workload manifests. Application deployments live under `../apps/`,
  monitoring under `../monitoring/`.
