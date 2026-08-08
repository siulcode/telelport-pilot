#!/usr/bin/env bash
# Install the CNI. cp01 only. Nothing works until this lands: CoreDNS sits
# Pending and every node stays NotReady.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/node-env.sh"

log()  { printf '  [%s] %s\n' "$(hostname -s)" "$*"; }
warn() { printf '  [%s] warn: %s\n' "$(hostname -s)" "$*" >&2; }

export KUBECONFIG=/etc/kubernetes/admin.conf
ARCH="$(dpkg --print-architecture)"

fetch_bin() {  # url, binary name
  curl -fsSL "$1" | tar xzC /usr/local/bin "$2"
}

install_cilium() {
  command -v cilium >/dev/null 2>&1 || {
    log "installing cilium CLI"
    local v; v="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
    fetch_bin "https://github.com/cilium/cilium-cli/releases/download/${v}/cilium-linux-${ARCH}.tar.gz" cilium
  }
  command -v hubble >/dev/null 2>&1 || {
    log "installing hubble CLI"
    local v; v="$(curl -fsSL https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)"
    fetch_bin "https://github.com/cilium/hubble/releases/download/${v}/hubble-linux-${ARCH}.tar.gz" hubble
  }

  if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
    log "cilium already installed"
  else
    log "installing cilium (pod CIDR ${POD_CIDR})"
    # chainingMode=portmap gives hostPort support while kube-proxy stays in
    # place. The alternative, kubeProxyReplacement=true, replaces the whole
    # service dataplane and with it the troubleshooting story.
    # shellcheck disable=SC2086
    cilium install \
      ${CILIUM_VERSION:+--version "${CILIUM_VERSION}"} \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}" \
      --set cni.chainingMode=portmap \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true
  fi

  log "waiting for cilium"
  cilium status --wait --wait-duration 5m

  # Without portmap in the chain, hostPort silently does nothing: the pod
  # schedules and the port never binds.
  if grep -lq portmap /etc/cni/net.d/*.conflist 2>/dev/null; then
    log "portmap present in the CNI chain (hostPort supported)"
  else
    warn "portmap NOT in /etc/cni/net.d -- hostPort will not work."
    warn "Use kubeProxyReplacement, or switch Traefik to hostNetwork."
  fi
}

install_calico() {
  if kubectl get installation default >/dev/null 2>&1; then
    log "calico already installed"
  else
    log "installing calico ${CALICO_VERSION} (pod CIDR ${POD_CIDR})"
    # The old docs.projectcalico.org manifest is dead; it is the operator now.
    kubectl create -f \
      "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
    kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
  fi
  log "waiting for calico"
  kubectl -n calico-system wait --for=condition=Ready pods --all --timeout=5m 2>/dev/null || true
}

case "${CNI}" in
  cilium) install_cilium ;;
  calico) install_calico ;;
  *)      echo "unknown CNI: ${CNI}" >&2; exit 1 ;;
esac

log "waiting for nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=5m
log "waiting for CoreDNS"
kubectl -n kube-system rollout status deployment/coredns --timeout=3m

echo; kubectl get nodes -o wide
echo; kubectl get pods -A
