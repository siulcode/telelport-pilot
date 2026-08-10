#!/usr/bin/env bash
# File: libs/node/00-common.sh
# Desc: Host prep on all three nodes: swap, modules, sysctl, containerd,
#       kubelet/kubeadm/kubectl.
# Idempotent by guard -- every expensive step checks for what it would create.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/node-env.sh"

log() { printf '  [%s] %s\n' "$(hostname -s)" "$*"; }
export DEBIAN_FRONTEND=noninteractive

wait_for_apt() {
  local i
  for ((i = 0; i < 60; i++)); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
    sleep 5
  done
  echo "apt lock never released" >&2; exit 1
}

# Racing cloud-init costs apt lock contention and a node name that can change
# after kubeadm has already registered it.
if command -v cloud-init >/dev/null 2>&1; then
  log "waiting for cloud-init"
  cloud-init status --wait >/dev/null 2>&1 || true
fi

# --- Swap --------------------------------------------------------------------
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  log "disabling swap"
  swapoff -a
fi
grep -qE '^[^#].*\sswap\s' /etc/fstab 2>/dev/null \
  && sed -i.bak -E 's|^([^#].*[[:space:]]swap[[:space:]].*)$|#\1|' /etc/fstab
systemctl mask swap.target >/dev/null 2>&1 || true

# --- Modules and sysctl ------------------------------------------------------
# br_netfilter is what makes bridged traffic visible to iptables, which is how
# kube-proxy and NetworkPolicy work at all.
log "kernel modules and sysctl"
{
  echo overlay
  echo br_netfilter
  # Without these, kube-proxy in ipvs mode silently falls back to iptables.
  [[ "${KUBE_PROXY_MODE}" == "ipvs" ]] \
    && printf 'ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\nnf_conntrack\n'
} > /etc/modules-load.d/k8s.conf
while read -r m; do [[ -n "$m" ]] && modprobe "$m" 2>/dev/null || true; done \
  < /etc/modules-load.d/k8s.conf

cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# --- containerd --------------------------------------------------------------
# Docker's repo, not Ubuntu's (older build). The cgroup driver must be systemd
# to match kubelet -- a mismatch is the most common kubeadm init failure, and it
# fails late and confusingly.
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
  log "installing containerd"
  wait_for_apt && apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg apt-transport-https

  install -m 0755 -d /etc/apt/keyrings
  [[ -f /etc/apt/keyrings/docker.gpg ]] || {
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  }
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list

  wait_for_apt && apt-get update -qq
  apt-get install -y -qq containerd.io

  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  # containerd 2.x writes version=3 and moves the CRI plugin path, but the
  # SystemdCgroup key name is unchanged.
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
    || { echo "failed to set SystemdCgroup" >&2; exit 1; }

  systemctl restart containerd
  systemctl enable containerd >/dev/null 2>&1
else
  log "containerd already configured"
fi

cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# --- kubelet / kubeadm / kubectl ---------------------------------------------
# pkgs.k8s.io only; the old apt.kubernetes.io repo is retired and returns nothing.
if [[ "$(kubeadm version -o short 2>/dev/null || true)" != "${K8S_VERSION}" ]]; then
  log "installing kubernetes ${K8S_VERSION}"
  [[ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]] || {
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  }
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  wait_for_apt && apt-get update -qq
  # Unhold first, or a version change silently no-ops.
  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  apt-get install -y -qq --allow-change-held-packages \
    "kubelet=${K8S_PATCH}" "kubeadm=${K8S_PATCH}" "kubectl=${K8S_PATCH}"
  apt-mark hold kubelet kubeadm kubectl >/dev/null
  systemctl enable kubelet >/dev/null 2>&1
else
  log "kubernetes ${K8S_VERSION} already installed"
fi

# kubelet crashloops until init or join runs. Expected -- don't chase it.
log "host prep complete"
