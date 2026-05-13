# containerd hosts.toml fix for Gitea registry (HTTP, no TLS)

## Why
k3s 1.35 writes hosts.toml from registries.yaml with `server = "https://<host>/v2"`
even when the registries.yaml endpoint is plain `http://`. Gitea has no :443
listener, so pulls from 192.168.100.206 fail with "no route to host".

## Files
- `fix-gitea-hosts.sh` -> /usr/local/bin/fix-gitea-hosts.sh (mode 755)
- `10-gitea-hosts.conf` -> systemd drop-in (path depends on role)

## Install (CP = k3master/.52, k3frigate/.56, k3sp4/.53)
```
sudo install -m 755 fix-gitea-hosts.sh /usr/local/bin/fix-gitea-hosts.sh
sudo mkdir -p /etc/systemd/system/k3s.service.d
sudo install -m 644 10-gitea-hosts.conf /etc/systemd/system/k3s.service.d/10-gitea-hosts.conf
sudo systemctl daemon-reload
sudo /usr/local/bin/fix-gitea-hosts.sh   # apply now without restarting k3s
```

## Install (worker/phone = one61/one62/one6t)
Same as above but use `k3s-agent.service.d/` instead of `k3s.service.d/`.
