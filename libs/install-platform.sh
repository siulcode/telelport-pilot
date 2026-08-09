#!/usr/bin/env bash
# Install the platform pieces the demo app depends on: cert-manager, the issuer
# chain, and Traefik. All admin-owned cluster infrastructure -- the restricted
# user deploys only the application itself.
#
#   ./libs/install-platform.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "${REPO_ROOT}"
# shellcheck source=../config.env
source config.env
[[ -f config.env.local ]] && source config.env.local

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

kubectl auth can-i create clusterissuers.cert-manager.io >/dev/null 2>&1 \
  || kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
  || { echo "needs admin kubeconfig -- export KUBECONFIG=${PWD}/.kube/config" >&2; exit 1; }

# --- cert-manager ------------------------------------------------------------
step "1. cert-manager"
if kubectl get ns cert-manager >/dev/null 2>&1; then
  echo "   already installed"
else
  VER="${CERT_MANAGER_VERSION:-}"
  # Resolve latest rather than pinning a version that may not exist. Pin it in
  # config.env once you have seen a release work.
  [[ -n "${VER}" ]] || VER="$(curl -fsSL https://api.github.com/repos/cert-manager/cert-manager/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  [[ -n "${VER}" ]] || { echo "could not resolve a cert-manager version" >&2; exit 1; }
  echo "   installing ${VER}"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${VER}/cert-manager.yaml"
fi

# The webhook rejects Issuer objects until it is serving, and the error is a
# confusing connection refused rather than anything about readiness.
echo "   waiting for the webhook"
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=5m

# --- issuer chain ------------------------------------------------------------
step "2. Issuer chain (selfsigned -> CA -> leaf)"
kubectl apply -f apps/cert-manager/issuers.yaml
kubectl wait --for=condition=Ready certificate/demo-ca -n cert-manager --timeout=2m
kubectl wait --for=condition=Ready clusterissuer/demo-ca --timeout=2m
kubectl get clusterissuer

# --- traefik -----------------------------------------------------------------
step "3. Traefik"
kubectl apply -f apps/traefik/traefik.yaml
kubectl -n traefik rollout status daemonset/traefik --timeout=3m

# --- CA bundle for the demo --------------------------------------------------
# Needed for `curl --cacert`. It is the CA's public certificate only, never the
# key -- safe to hand out, which is the whole point of a CA.
step "4. Export the CA certificate"
mkdir -p "${BUILD_DIR:-.build}"
kubectl -n cert-manager get secret demo-ca-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > "${BUILD_DIR:-.build}/ca.crt"
openssl x509 -in "${BUILD_DIR:-.build}/ca.crt" -noout -subject -enddate | sed 's/^/   /'

cat <<EOF

  Platform ready. Deploy the app as the restricted user:

    kubectl --kubeconfig=users/app-deploy/kubeconfig apply -f apps/nginx/nginx.yaml
    curl --cacert ${BUILD_DIR:-.build}/ca.crt https://${SITE_HOSTNAME}

EOF
