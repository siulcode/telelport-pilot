#!/usr/bin/env bash
# Cluster platform: cert-manager, the issuer chain, Traefik, and the RBAC
# scaffolding. Sourced by bootstrap.sh and run as part of --cluster.
#
# All admin-owned. The restricted user deploys only the application itself,
# which is why apps/nginx is deliberately NOT applied here.

# --- cert-manager ------------------------------------------------------------
platform_cert_manager() {
  if kubectl get ns cert-manager >/dev/null 2>&1; then
    ok "cert-manager already installed"
  else
    local ver="${CERT_MANAGER_VERSION:-}"
    # Resolve latest when unpinned rather than guessing a tag that may not exist.
    [[ -n "${ver}" ]] || ver="$(curl -fsSL \
      https://api.github.com/repos/cert-manager/cert-manager/releases/latest \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    [[ -n "${ver}" ]] || die "could not resolve a cert-manager version"
    log "installing cert-manager ${ver}"
    kubectl apply -f \
      "https://github.com/cert-manager/cert-manager/releases/download/${ver}/cert-manager.yaml" >/dev/null
  fi
  # The webhook rejects Issuer objects until it is serving, and the failure is a
  # connection refused rather than anything mentioning readiness.
  kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=5m >/dev/null
  ok "cert-manager ready"
}

# --- issuer chain ------------------------------------------------------------
platform_issuers() {
  kubectl apply -f apps/cert-manager/issuers.yaml >/dev/null
  kubectl wait --for=condition=Ready certificate/demo-ca -n cert-manager --timeout=2m >/dev/null
  kubectl wait --for=condition=Ready clusterissuer/demo-ca --timeout=2m >/dev/null
  ok "issuer chain ready (selfsigned -> CA)"
}

# --- traefik -----------------------------------------------------------------
platform_traefik() {
  kubectl apply -f apps/traefik/traefik.yaml >/dev/null
  kubectl -n traefik rollout status daemonset/traefik --timeout=3m >/dev/null
  ok "traefik ready on hostPort 80/443"
}

# --- namespace and roles -----------------------------------------------------
# Applied here because they are cluster configuration, not application code.
# Onboarding an actual user stays manual -- see ./onboard-user.sh.
platform_rbac() {
  kubectl apply -f apps/rbac/rbac.yaml >/dev/null
  ok "namespace ${APP_NAMESPACE} with deployer/viewer roles"
}

# --- CA bundle ---------------------------------------------------------------
# The CA's public certificate only, never the key. Needed for curl --cacert.
platform_ca_bundle() {
  mkdir -p "${BUILD_DIR}"
  kubectl -n cert-manager get secret demo-ca-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "${BUILD_DIR}/ca.crt"
  [[ -s "${BUILD_DIR}/ca.crt" ]] || die "failed to export the CA certificate"
  ok "CA certificate: ${BUILD_DIR}/ca.crt"
}

platform_install() {
  step "Platform (cert-manager, issuers, Traefik, RBAC)"
  require_cmd kubectl
  # The EIP-based copy, so this works before /etc/hosts is set up.
  export KUBECONFIG="${KUBECONFIG_DIRECT}"
  platform_cert_manager
  platform_issuers
  platform_traefik
  platform_rbac
  platform_ca_bundle
}
