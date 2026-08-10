#!/usr/bin/env bash
# File: libs/node/10-control-plane.sh
# Desc: kubeadm init on cp01. Idempotent by artifact guard: admin.conf is written
# by kubeadm itself, so its presence is the only honest signal init succeeded.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/node-env.sh"

log() { printf '  [%s] %s\n' "$(hostname -s)" "$*"; }
CONFIG=/etc/kubernetes/kubeadm-config.yaml

# certSANs carries three names: the hostname clients dial, the private IP nodes
# use inside the VPC, and the Elastic IP your laptop uses. Miss the public one
# and the cluster builds fine, then rejects you from outside with a cert error
# -- fixable only by regenerating the API server cert.
log "rendering ${CONFIG}"
mkdir -p /etc/kubernetes
cat > "${CONFIG}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CP_PRIVATE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${CP_HOSTNAME}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
# Set even for a single control plane: adding one later otherwise means
# regenerating every certificate and kubeconfig.
controlPlaneEndpoint: "${CP_ENDPOINT}:6443"
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - ${CP_ENDPOINT}
    - ${CP_PRIVATE_IP}
    - ${CP_PUBLIC_IP}
    - ${CP_HOSTNAME}
    - 127.0.0.1
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ${KUBE_PROXY_MODE}
EOF

if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "already initialised (admin.conf present)"
else
  log "pulling images"
  kubeadm config images pull --config "${CONFIG}"
  log "kubeadm init"
  kubeadm init --config "${CONFIG}" --upload-certs
fi

# admin.conf is cluster-admin with no audit trail -- fine for the operator's own
# shell, and exactly what the CSR workflow exists to avoid handing to anyone else.
install -d -o "${SSH_USER}" -g "${SSH_USER}" -m 0700 "/home/${SSH_USER}/.kube"
install -o "${SSH_USER}" -g "${SSH_USER}" -m 0600 \
  /etc/kubernetes/admin.conf "/home/${SSH_USER}/.kube/config"

export KUBECONFIG=/etc/kubernetes/admin.conf
log "waiting for the API server"
for i in $(seq 1 60); do
  kubectl get --raw='/readyz' >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && { echo "API server never became ready" >&2; exit 1; }
  sleep 5
done

log "control plane ready (nodes stay NotReady until the CNI lands)"
kubectl get nodes -o wide
