#!/bin/sh
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/certs.d/192.168.100.206
cat > /var/lib/rancher/k3s/agent/etc/containerd/certs.d/192.168.100.206/hosts.toml << INNER_EOF
server = "http://192.168.100.206"

[host."http://192.168.100.206"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
INNER_EOF
