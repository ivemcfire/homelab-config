# Post-Tailscale Collateral on the Homelab

Companion notes to the post *[The Tunnel Was Up. The Cameras Were 502.](https://ivemcfire.github.io/posts/cloudflared-ha-and-oob.html)* — specifically the sections *The Install That Almost Worked* and *The Subnet Router That Lost Its Default Route*.

Installing Tailscale on a k3s node is not free. The package pulls in `systemd-resolved`, and on at least one of our boxes (`.52` = `k3master`) it left the host with no default route and an empty `[Resolve]` upstream. Pods on that node could not pull images. Worse, the default k3s coredns Corefile started pointing into a black hole, breaking external DNS *from every pod in the cluster*, on every node.

This file documents the three rules learned the hard way.

## 1. `--accept-routes=false` on every LAN-resident node, including the subnet routers

If you have a node X advertising `192.168.100.0/24` as a Tailscale subnet route, every Tailscale-enabled peer that ALSO sits on `192.168.100.0/24` must have `--accept-routes=false`. That includes X itself.

The default `--accept-routes=true` installs `192.168.100.0/24 dev tailscale0 table 52` in the kernel routing table. The kernel prefers it over the direct LAN route. The result is that LAN-to-LAN packets between peers on the same Ethernet segment get pulled into the Tailscale tunnel and DERP-relayed back out. This masks every LAN issue with "Tailscale almost works."

In our mesh, `.52` and `.62` advertise `192.168.100.0/24`. `.52`, `.53`, and `.56` all sit on that LAN. All three need:

```
sudo tailscale set --accept-routes=false
```

Tailscale persists the preference in `/var/lib/tailscale/tailscaled.state`, so the setting survives reboot. Verify with:

```
sudo tailscale debug prefs | grep RouteAll
# "RouteAll": false,
```

Re-enable `--accept-routes=true` only when the laptop is genuinely off-LAN.

## 2. coredns Corefile must not forward to `/etc/resolv.conf` on systemd-resolved hosts

The default k3s Corefile, generated into the `coredns` ConfigMap in `kube-system`:

```
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa { ... }
    hosts /etc/coredns/NodeHosts { ... }
    prometheus :9153
    cache 30
    loop
    reload
    loadbalance
    import /etc/coredns/custom/*.override
    forward . /etc/resolv.conf
}
```

The last directive says: forward queries that do not match `cluster.local` to whatever name servers `/etc/resolv.conf` lists. On a host running `systemd-resolved`, that file lists `127.0.0.53` — the local stub resolver in the host's net namespace.

From inside the coredns pod, `127.0.0.53` is *the pod's own loopback*, where nothing is listening. coredns silently forwards every external query into a black hole. Symptoms: pods get `Try again` (EAI_AGAIN) for any non-cluster hostname. `pip install`, image pulls, anything that uses DNS dies.

**Fix:** edit the `coredns` ConfigMap directly, replace the `forward` line with hardcoded upstreams:

```
forward . 1.1.1.1 8.8.8.8
```

Then bounce the deployment so the new Corefile loads:

```
kubectl -n kube-system rollout restart deployment/coredns
```

Watch out for the secondary failure mode: if the rescheduler picks a node where the coredns image is not cached, the new pod will need DNS to pull its image — which it cannot do until itself is up. Cordon the phone workers (or any non-CP node where the image is not pre-pulled) before bouncing.

## 3. After installing Tailscale, verify the host's networking still works

Symptoms we hit on `.52` after the Tailscale install and a reboot:

- `ip route` had no `default via …` entry
- `resolvectl status` showed every interface with `Current Scopes: none`
- `/etc/systemd/resolved.conf` had an empty `[Resolve]` section
- `getent hosts cloudflare.com` from the host itself hung
- `nmcli` showed no connection profile for the WAN interface
- `networkctl list` showed it as `unmanaged`

The interface still had its IP — because netplan had matched it at boot by MAC. The route and DNS were collateral damage from systemd-resolved being newly installed without an upstream and the netplan re-apply not retriggering.

**Fix sequence on the affected host:**

```bash
# 1. Drop the --accept-routes hijack first
sudo tailscale set --accept-routes=false

# 2. Restore the default route (in-memory; netplan persists it on reboot)
sudo ip route add default via 192.168.100.1 dev wan0

# 3. Give systemd-resolved real upstream nameservers
sudo tee /etc/systemd/resolved.conf >/dev/null <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 192.168.100.1
FallbackDNS=9.9.9.9 149.112.112.112
EOF
sudo systemctl restart systemd-resolved

# 4. Reapply netplan to refresh networkd state for the interface
sudo netplan apply
```

After that, `networkctl list` should show the WAN interface as `routable configured` and `resolvectl status` should list the upstream DNS servers under "Global".

## Files in this section

- `tailscale-collateral.md` — this file.

The actual config files (`/etc/systemd/resolved.conf`, `/etc/netplan/00-installer-config.yaml`) are not committed here because they contain host-specific identifiers (interface MAC, hostname). Their contents are shown inline in the post body.
