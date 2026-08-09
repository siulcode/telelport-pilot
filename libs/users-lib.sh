#!/usr/bin/env bash
# User onboarding through the certificates.k8s.io CSR API. Sourced, not run.
#
# Each function is one step of the manual workflow, in the order a human would
# perform it. Kept granular on purpose: the toil is the point, and the demo
# walks through these one at a time.

u_step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
u_info() { printf '   %s\n' "$*"; }
u_die()  { printf ' ERR %s\n' "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
user_preflight() {
  local ns="$1"
  command -v openssl >/dev/null || u_die "openssl not found"
  command -v kubectl >/dev/null || u_die "kubectl not found"
  kubectl get ns "${ns}" >/dev/null 2>&1 \
    || u_die "namespace ${ns} missing -- kubectl apply -f apps/rbac/rbac.yaml"
  kubectl auth can-i create certificatesigningrequests.certificates.k8s.io >/dev/null 2>&1 \
    || u_die "current kubeconfig cannot create CSRs -- use the admin kubeconfig"
}

# Per-user output directory. 0700 because a private key lands here.
user_workdir() {
  local user="$1" dir="users/$1"
  mkdir -p "${dir}"; chmod 700 "${dir}"
  printf '%s' "${dir}"
}

# --- 1. Key ------------------------------------------------------------------
# Generated locally and never transmitted. The cluster only ever sees the public
# half, inside the CSR.
user_keypair() {
  local key="$1"
  ( umask 077; openssl genrsa -out "${key}" 2048 2>/dev/null )
  u_info "${key}"
}

# --- 2. CSR ------------------------------------------------------------------
# CN becomes the username and O becomes the group. Kubernetes reads identity
# straight out of this subject; there is no user database to consult.
user_csr() {
  local key="$1" csr="$2" user="$3" group="$4"
  openssl req -new -key "${key}" -out "${csr}" -subj "/CN=${user}/O=${group}"
  openssl req -in "${csr}" -noout -subject | sed 's/^/   /'
}

# --- 3. Submit ---------------------------------------------------------------
# signerName is what makes this the CSR API rather than hand-signing with a copy
# of the cluster CA key. Same resulting certificate, completely different
# auditability -- this one is an object you can kubectl get.
user_submit_csr() {
  local user="$1" csr="$2" days="$3"
  kubectl delete csr "${user}" >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF >/dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${user}
spec:
  request: $(base64 < "${csr}" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $(( days * 86400 ))
  usages: ["client auth"]
EOF
  kubectl get csr "${user}" | sed 's/^/   /'
}

# --- 4. Approve --------------------------------------------------------------
# A separate, deliberate act -- and the only gate there will ever be, since
# nothing downstream can revoke what this authorises.
user_approve_csr() {
  kubectl certificate approve "$1" | sed 's/^/   /'
}

# --- 5. Collect --------------------------------------------------------------
user_fetch_cert() {
  local user="$1" crt="$2" b64 i
  for i in $(seq 1 30); do
    b64="$(kubectl get csr "${user}" -o jsonpath='{.status.certificate}')"
    [[ -n "${b64}" ]] && break
    [[ $i -eq 30 ]] && u_die "signer never issued a certificate for ${user}"
    sleep 1
  done
  echo "${b64}" | base64 -d > "${crt}"
  openssl x509 -in "${crt}" -noout -subject -issuer -enddate | sed 's/^/   /'
}

# --- 6. Kubeconfig -----------------------------------------------------------
# The cluster CA is embedded so the user can verify the server, and the client
# cert plus key so the server can verify the user. Both directions, one file.
user_kubeconfig() {
  local kcfg="$1" crt="$2" key="$3" user="$4" ns="$5" cluster="$6"
  local ca; ca="$(mktemp)"
  kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | base64 -d > "${ca}"
  local server; server="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')"

  rm -f "${kcfg}"
  kubectl config --kubeconfig="${kcfg}" set-cluster "${cluster}" \
    --server="${server}" --certificate-authority="${ca}" --embed-certs=true >/dev/null
  kubectl config --kubeconfig="${kcfg}" set-credentials "${user}" \
    --client-certificate="${crt}" --client-key="${key}" --embed-certs=true >/dev/null
  kubectl config --kubeconfig="${kcfg}" set-context "${user}" \
    --cluster="${cluster}" --user="${user}" --namespace="${ns}" >/dev/null
  kubectl config --kubeconfig="${kcfg}" use-context "${user}" >/dev/null
  rm -f "${ca}"; chmod 600 "${kcfg}"
  u_info "${kcfg}"
}

# --- 7. Verify ---------------------------------------------------------------
# Proves the grant from the user's own credentials rather than by reading the
# Role back as admin.
user_verify() {
  local kcfg="$1" ns="$2"
  _can() { kubectl --kubeconfig="${kcfg}" auth can-i "$@" 2>/dev/null; }
  printf '   create deployments : %s\n' "$(_can create deployments -n "${ns}")"
  printf '   read secrets       : %s\n' "$(_can get secrets -n "${ns}")"
  printf '   list nodes         : %s\n' "$(_can list nodes -A)"
}

# --- Closing note ------------------------------------------------------------
# The three properties that make this workflow the argument against itself.
user_caveats() {
  local kcfg="$1" days="$2"
  cat <<EOF

  export KUBECONFIG=${kcfg}

  Valid ${days} days and NOT revocable -- the API server supports no CRL and no
  OCSP. Offboarding means rotating the cluster CA, invalidating everyone at once.
  The group is fixed in the cert, so changing access means reissuing. And none
  of it is a Kubernetes object: there is no user to list, audit, or delete.

EOF
}
