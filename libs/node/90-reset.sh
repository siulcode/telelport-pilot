#!/usr/bin/env bash
# File: libs/node/90-reset.sh
# Desc: Return a node to pre-kubeadm state so a clean rebuild can be rehearsed.
# Leaves containerd and the k8s packages alone -- re-running 00-common.sh after
# this is a no-op and only the cluster is rebuilt.
set -euo pipefail

log() { printf '  [%s] %s\n' "$(hostname -s)" "$*"; }

log "kubeadm reset"
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock >/dev/null 2>&1 || true

log "removing cluster state"
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/cni /etc/cni/net.d \
       /var/run/kubernetes /root/.kube "/home/${SUDO_USER:-ubuntu}/.kube" 2>/dev/null || true

# Policies to ACCEPT before flushing: flushing a DROP-policy chain would cut the
# SSH session running this script. The security group does the real filtering.
log "flushing iptables"
for t in filter nat mangle; do
  for c in INPUT FORWARD OUTPUT; do iptables -t "$t" -P "$c" ACCEPT 2>/dev/null || true; done
  iptables -t "$t" -F 2>/dev/null || true
  iptables -t "$t" -X 2>/dev/null || true
done
ipvsadm -C 2>/dev/null || true

# kubeadm reset leaves these behind; stale endpoints poison the next install.
log "removing CNI interfaces and eBPF state"
for i in cilium_host cilium_net cilium_vxlan; do ip link delete "$i" 2>/dev/null || true; done
rm -rf /sys/fs/bpf/tc/globals/cilium_* /var/run/cilium 2>/dev/null || true

systemctl restart containerd 2>/dev/null || true
log "reset complete"
