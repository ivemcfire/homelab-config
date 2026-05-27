# jumphost (.62)

Bastion host for the homelab cluster. Single canonical SSH entry point from
outside the LAN. The k3 control planes (`k3master`, `k3frigate`, `k3sp4`) sit
behind it via `ProxyJump`; the bastion itself runs no cluster workloads.

Tailscale subnet router (redundant with `k3master`), advertises
`192.168.100.0/24`. Holds the age decryption key for `homelab-docs/credentials.md.age`.

## Files in this directory

| Repo path | Installed at | Purpose |
|---|---|---|
| `sshd_config.d/10-hardening.conf` | `/etc/ssh/sshd_config.d/10-hardening.conf` | Key-only auth, modern crypto, MaxAuthTries 3, verbose logging. |
| `fail2ban/jail.d/sshd-bastion.local` | `/etc/fail2ban/jail.d/sshd-bastion.local` | sshd jail: 3 retries / 10 min → 1 h ban via nftables. Ignores LAN + Tailscale CGNAT. |
| `etc/network/interfaces` | `/etc/network/interfaces` | Static `192.168.100.62/24` on `enp1s0`. Dual-IP residue from old install removed (issue #21, 2026-05-27). |

## Admin toolkit on .62

Installed out-of-band (not in this repo, intentionally — apt + binary releases):

- `kubectl`, `helm`, `jq`, `yq` (apt)
- `age` 1.2.1 (apt) — decrypts `credentials.md.age` with `~/.age/key.txt`
- `k9s` v0.50.18 (`.deb` from github.com/derailed/k9s)
- `~/.kube/config` points at `https://k3master:6443`

## Apply on a rebuild

```bash
# As root on a fresh Debian 13 jumphost:
install -m 644 sshd_config.d/10-hardening.conf /etc/ssh/sshd_config.d/
install -m 644 fail2ban/jail.d/sshd-bastion.local /etc/fail2ban/jail.d/
install -m 644 etc/network/interfaces /etc/network/interfaces
sshd -t && systemctl reload ssh
systemctl enable --now fail2ban
systemctl restart networking
```

Validation: `ssh -o BatchMode=yes user@<jumphost-ip> true` from a trusted
client; `fail2ban-client status sshd` should show the jail enabled.
