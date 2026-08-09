#!/usr/bin/env bash
# Onboard a Kubernetes user through the CSR API.
#   ./libs/onboard-user.sh <username> <group> [valid-days]
#
# Deliberately not wired into bootstrap.sh: every step is manual toil repeated
# per user, per access change, per expiry -- and that toil is the answer to
# "what is wrong with managing access this way". Meant to be read while it runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "${REPO_ROOT}"
# shellcheck source=../config.env
source config.env
[[ -f config.env.local ]] && source config.env.local
# shellcheck source=lib-users.sh
source libs/lib-users.sh

USER_NAME="${1:-}"; GROUP="${2:-}"; DAYS="${3:-30}"
[[ -n "${USER_NAME}" && -n "${GROUP}" ]] || {
  echo "usage: $0 <username> <group> [valid-days]"
  echo "       groups: demo-deployers | demo-viewers"; exit 1; }

user_preflight "${APP_NAMESPACE}"
DIR="$(user_workdir "${USER_NAME}")"
KEY="${DIR}/${USER_NAME}.key"; CSR="${DIR}/${USER_NAME}.csr"
CRT="${DIR}/${USER_NAME}.crt"; KCFG="${DIR}/kubeconfig"

u_step "1. Private key -- never leaves this machine, never sent to the cluster"
user_keypair "${KEY}"

u_step "2. Certificate signing request -- CN=${USER_NAME}, O=${GROUP}"
user_csr "${KEY}" "${CSR}" "${USER_NAME}" "${GROUP}"

u_step "3. Submit to the certificates.k8s.io API"
user_submit_csr "${USER_NAME}" "${CSR}" "${DAYS}"

u_step "4. Approve"
user_approve_csr "${USER_NAME}"

u_step "5. Extract the signed certificate"
user_fetch_cert "${USER_NAME}" "${CRT}"

u_step "6. Assemble a kubeconfig"
user_kubeconfig "${KCFG}" "${CRT}" "${KEY}" "${USER_NAME}" "${APP_NAMESPACE}" "${PROJECT_NAME}"

u_step "7. Verify the grant"
user_verify "${KCFG}" "${APP_NAMESPACE}"

user_caveats "${REPO_ROOT}/${KCFG}" "${DAYS}"
