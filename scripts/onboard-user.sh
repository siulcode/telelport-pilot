#!/usr/bin/env bash
# Onboard a Kubernetes user through the CSR API.
#   ./scripts/onboard-user.sh <username> <group> [valid-days]
#
# Deliberately not wired into bootstrap.sh: every step is manual toil repeated
# per user, per access change, per expiry -- and that toil is the answer to
# "what is wrong with managing access this way". Meant to be read while it runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "${REPO_ROOT}"
# shellcheck source=../config.env
source config.env
[[ -f config.env.local ]] && source config.env.local

USER_NAME="${1:-}"; GROUP="${2:-}"; DAYS="${3:-30}"
[[ -n "${USER_NAME}" && -n "${GROUP}" ]] || {
  echo "usage: $0 <username> <group> [valid-days]"
  echo "       groups: demo-deployers | demo-viewers"; exit 1; }

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
kubectl get ns "${APP_NAMESPACE}" >/dev/null 2>&1 \
  || { echo "namespace ${APP_NAMESPACE} missing -- apply apps/rbac/rbac.yaml" >&2; exit 1; }

OUT="users/${USER_NAME}"; mkdir -p "${OUT}"; chmod 700 "${OUT}"
KEY="${OUT}/${USER_NAME}.key"; CSR="${OUT}/${USER_NAME}.csr"
CRT="${OUT}/${USER_NAME}.crt"; KCFG="${OUT}/kubeconfig"
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "1. Private key -- never leaves this machine, never sent to the cluster"
umask 077
openssl genrsa -out "${KEY}" 2048 2>/dev/null
echo "   ${KEY}"

# CN becomes the username, O becomes the group. Kubernetes reads identity
# straight out of the subject; there is nothing else to consult.
step "2. Certificate signing request -- CN=${USER_NAME}, O=${GROUP}"
openssl req -new -key "${KEY}" -out "${CSR}" -subj "/CN=${USER_NAME}/O=${GROUP}"
openssl req -in "${CSR}" -noout -subject | sed 's/^/   /'

step "3. Submit to the certificates.k8s.io API"
kubectl delete csr "${USER_NAME}" >/dev/null 2>&1 || true
kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: $(base64 < "${CSR}" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $(( DAYS * 86400 ))
  usages: ["client auth"]
EOF
kubectl get csr "${USER_NAME}" | sed 's/^/   /'

# A separate, auditable act -- and the only gate, since there is no revocation.
step "4. Approve"
kubectl certificate approve "${USER_NAME}" | sed 's/^/   /'

step "5. Extract the signed certificate"
for i in $(seq 1 30); do
  CERT_B64="$(kubectl get csr "${USER_NAME}" -o jsonpath='{.status.certificate}')"
  [[ -n "${CERT_B64}" ]] && break
  [[ $i -eq 30 ]] && { echo "signer never issued a certificate" >&2; exit 1; }
  sleep 1
done
echo "${CERT_B64}" | base64 -d > "${CRT}"
openssl x509 -in "${CRT}" -noout -subject -issuer -enddate | sed 's/^/   /'

step "6. Assemble a kubeconfig"
CA="$(mktemp)"; trap 'rm -f "${CA}"' EXIT
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "${CA}"
SERVER="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
rm -f "${KCFG}"
kubectl config --kubeconfig="${KCFG}" set-cluster "${PROJECT_NAME}" \
  --server="${SERVER}" --certificate-authority="${CA}" --embed-certs=true >/dev/null
kubectl config --kubeconfig="${KCFG}" set-credentials "${USER_NAME}" \
  --client-certificate="${CRT}" --client-key="${KEY}" --embed-certs=true >/dev/null
kubectl config --kubeconfig="${KCFG}" set-context "${USER_NAME}" \
  --cluster="${PROJECT_NAME}" --user="${USER_NAME}" --namespace="${APP_NAMESPACE}" >/dev/null
kubectl config --kubeconfig="${KCFG}" use-context "${USER_NAME}" >/dev/null
chmod 600 "${KCFG}"; echo "   ${KCFG}"

step "7. Verify the grant"
k() { kubectl --kubeconfig="${KCFG}" auth can-i "$@" 2>/dev/null; }
printf '   create deployments : %s\n' "$(k create deployments -n "${APP_NAMESPACE}")"
printf '   read secrets       : %s\n' "$(k get secrets -n "${APP_NAMESPACE}")"
printf '   list nodes         : %s\n' "$(k list nodes -A)"

cat <<EOF

  export KUBECONFIG=${REPO_ROOT}/${KCFG}

  Valid ${DAYS} days and NOT revocable -- the API server supports no CRL and no
  OCSP. Offboarding means rotating the cluster CA, invalidating everyone at once.
  The group is fixed in the cert, so changing access means reissuing. And none
  of it is a Kubernetes object: there is no user to list, audit, or delete.

EOF
