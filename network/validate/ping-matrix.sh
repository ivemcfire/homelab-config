#!/bin/sh
# Deploy a busybox pod on every node, then run a 4x4 ping matrix between
# their pod IPs. If all 16 paths come back ok, the routed-/30 + Flannel-VXLAN
# overlay is alive. Anything missing points at one of:
#   - nftables on a phone (forward chain default-drop, invisible from iptables -L)
#   - br_netfilter on the laptop (do not bridge USB interfaces)
#   - MetalLB or k3s-nat.service ordering
#
# Usage: KUBECONFIG=... ./ping-matrix.sh

set -eu
KUBECTL="${KUBECTL:-sudo kubectl}"

NODES="k3master one6t one62 one61"

for n in $NODES; do
  $KUBECTL run nettest-$n --image=alpine:3.20 \
    --overrides="{\"spec\":{\"nodeName\":\"$n\"}}" \
    -- sleep 3600 >/dev/null
done

sleep 8

for src in $NODES; do
  for dst in $NODES; do
    dst_ip=$($KUBECTL get pod nettest-$dst -o jsonpath='{.status.podIP}')
    if $KUBECTL exec nettest-$src -- ping -c 1 -W 3 "$dst_ip" >/dev/null 2>&1; then
      echo "$src -> $dst ($dst_ip) ok"
    else
      echo "$src -> $dst ($dst_ip) FAIL"
    fi
  done
done

for n in $NODES; do
  $KUBECTL delete pod nettest-$n --wait=false >/dev/null
done
