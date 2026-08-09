#!/usr/bin/env bash
# Optional GitOps layer: ./bootstrap.sh --deploy-gitops
#
# Deliberately NOT part of --cluster or --all. The core requirement -- nginx
# deployed by a certificate-authenticated user with a namespaced Role -- must
# stand on its own, and must keep standing if this layer is never installed or
# is deleted five minutes before a demo.
#
# Argo is installed namespace-scoped (namespace-install.yaml), which creates no
# ClusterRoles. Its only reach outside its own namespace is the Role in
# apps/gitops/project.yaml. See docs/DESIGN.md.

# Argo needs an https URL it can fetch anonymously; the local remote is ssh.
gitops_repo_url() {
  local url="${GITOPS_REPO_URL:-}"
  [[ -n "${url}" ]] || url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "${url}" ]] || die "no git remote and GITOPS_REPO_URL is unset"
  url="${url/git@github.com:/https://github.com/}"
  [[ "${url}" == *.git ]] || url="${url}.git"
  printf '%s' "${url}"
}

gitops_install_argocd() {
  if kubectl get ns argocd >/dev/null 2>&1; then
    ok "argocd namespace already present"
  else
    local ver="${ARGOCD_VERSION:-}"
    [[ -n "${ver}" ]] || ver="$(curl -fsSL \
      https://api.github.com/repos/argoproj/argo-cd/releases/latest \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    [[ -n "${ver}" ]] || die "could not resolve an argo-cd version"
    log "installing argo cd ${ver} (namespace-scoped: no ClusterRoles)"
    kubectl create namespace argocd >/dev/null
    kubectl -n argocd apply -f \
      "https://raw.githubusercontent.com/argoproj/argo-cd/${ver}/manifests/namespace-install.yaml" >/dev/null
  fi
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m >/dev/null
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m >/dev/null 2>&1 \
    || kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=5m >/dev/null
  ok "argo cd ready"
}

# The namespace is created here, as admin, so Argo never needs the power to
# create namespaces -- one less cluster-scoped verb in its grant.
gitops_scope() {
  kubectl create namespace "${GITOPS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f apps/gitops/project.yaml >/dev/null
  ok "namespace ${GITOPS_NAMESPACE}, scoped Role, and AppProject applied"
}

gitops_application() {
  local repo; repo="$(gitops_repo_url)"
  log "pointing argo at ${repo} (${GITOPS_REPO_BRANCH}:${GITOPS_REPO_PATH})"
  kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitops-site
  namespace: argocd
spec:
  project: demo-gitops
  source:
    repoURL: ${repo}
    targetRevision: ${GITOPS_REPO_BRANCH}
    path: ${GITOPS_REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${GITOPS_NAMESPACE}
  syncPolicy:
    automated:
      prune: true      # delete what git no longer declares
      selfHeal: true   # revert manual kubectl edits -- git is the source of truth
EOF
  ok "application created"
}

# The demo beat: what the controller can actually do, straight from the API
# server rather than from Argo's own opinion of itself.
gitops_show_grant() {
  local sa=system:serviceaccount:argocd:argocd-application-controller
  printf '\n  Controller permissions, as the API server sees them:\n'
  printf '    cluster-admin anywhere    : %s\n' "$(kubectl auth can-i '*' '*' --all-namespaces --as="${sa}" 2>/dev/null)"
  printf '    create clusterrolebinding : %s\n' "$(kubectl auth can-i create clusterrolebindings --as="${sa}" 2>/dev/null)"
  printf '    read secrets in %-9s : %s\n' "${GITOPS_NAMESPACE}" "$(kubectl auth can-i get secrets -n "${GITOPS_NAMESPACE}" --as="${sa}" 2>/dev/null)"
  printf '    read secrets in demo      : %s\n' "$(kubectl auth can-i get secrets -n "${APP_NAMESPACE}" --as="${sa}" 2>/dev/null)"
  printf '    deploy in %-15s : %s\n' "${GITOPS_NAMESPACE}" "$(kubectl auth can-i create deployments -n "${GITOPS_NAMESPACE}" --as="${sa}" 2>/dev/null)"
  printf '    deploy in demo            : %s\n' "$(kubectl auth can-i create deployments -n "${APP_NAMESPACE}" --as="${sa}" 2>/dev/null)"
  printf '\n'
}

cmd_deploy_gitops() {
  step "GitOps layer (optional)"
  require_cmd aws kubectl git
  require_aws_auth
  stack_exists || die "no infrastructure found. Run: ./bootstrap.sh --infra"
  [[ -s "${KUBECONFIG_DIRECT}" ]] || die "no cluster kubeconfig. Run: ./bootstrap.sh --cluster"
  export KUBECONFIG="${KUBECONFIG_DIRECT}"

  gitops_install_argocd
  gitops_scope
  gitops_application
  gitops_show_grant

  log "waiting for the first sync"
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
    application/gitops-site --timeout=5m >/dev/null 2>&1 || true
  kubectl -n "${GITOPS_NAMESPACE}" rollout status deploy/gitops-nginx --timeout=5m >/dev/null 2>&1 \
    || warn "gitops-nginx did not roll out; check: kubectl -n argocd get application gitops-site -o yaml"

  kubectl -n argocd get application gitops-site \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers \
    | sed 's/^/  /'

  local ingress; ingress="$(stack_output IngressPublicIp)"
  cat <<EOF

  Add to /etc/hosts, then browse the GitOps-delivered site:
    ${ingress}  ${GITOPS_SITE_HOSTNAME}

    curl --cacert ${BUILD_DIR}/ca.crt https://${GITOPS_SITE_HOSTNAME}

  Nothing above was applied by hand. Change apps/gitops/manifests and push;
  Argo reconciles. Try editing the live Deployment with kubectl and watch
  selfHeal revert it -- git is the source of truth for this namespace.

EOF
}
