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
  local ver="${ARGOCD_VERSION:-}" base
  [[ -n "${ver}" ]] || ver="$(curl -fsSL \
    https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  [[ -n "${ver}" ]] || die "could not resolve an argo-cd version"
  base="https://raw.githubusercontent.com/argoproj/argo-cd/${ver}/manifests"

  # CRDs are cluster-scoped, so namespace-install.yaml deliberately omits them.
  # Installing the API types is an admin act, and separate from granting Argo
  # any authority over workloads -- which is the whole point of this layer.
  log "installing argo cd CRDs (cluster-scoped, admin)"
  local crd
  for crd in application-crd appproject-crd applicationset-crd; do
    kubectl apply --server-side -f "${base}/crds/${crd}.yaml" >/dev/null
  done
  kubectl wait --for=condition=Established --timeout=60s \
    crd/applications.argoproj.io crd/appprojects.argoproj.io >/dev/null

  log "installing argo cd ${ver} (namespace-scoped: creates no ClusterRoles)"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n argocd apply -f "${base}/namespace-install.yaml" >/dev/null

  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m >/dev/null
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m >/dev/null
  kubectl -n argocd rollout status deploy/argocd-server      --timeout=5m >/dev/null
  ok "argo cd ready"
}

# The namespace is created here, as admin, so Argo never needs the power to
# create namespaces -- one less cluster-scoped verb in its grant.
gitops_scope() {
  kubectl create namespace "${GITOPS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f apps/gitops/project.yaml >/dev/null
  ok "namespace ${GITOPS_NAMESPACE}, scoped Role, and AppProject applied"
}

# Argo's controller caches live state so it can compute drift, and by default it
# tries to list EVERY api kind in EVERY namespace. Against a namespace-scoped
# grant that fails on the first kind it is not allowed to read (podtemplates,
# as it happens) and the app never leaves Unknown.
#
# The fix is not to widen RBAC. It is to narrow what Argo watches so the cache
# mirrors the grant exactly:
#   cluster Secret   -> only the demo-gitops namespace, no cluster-scoped kinds
#   resource.inclusions -> only the kinds the Role actually permits
gitops_bound_cache() {
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
  namespaces: ${GITOPS_NAMESPACE}
  clusterResources: "false"
  config: '{"tlsClientConfig":{"insecure":false}}'
EOF
  kubectl -n argocd patch configmap argocd-cm --type merge -p "$(cat <<'EOF'
{"data":{"resource.inclusions":"- apiGroups: [\"\", \"apps\", \"networking.k8s.io\", \"cert-manager.io\"]\n  kinds: [\"ConfigMap\", \"Service\", \"Pod\", \"Deployment\", \"ReplicaSet\", \"Ingress\", \"Certificate\"]\n  clusters: [\"*\"]\n"}}
EOF
)" >/dev/null
  # The controller reads both at startup.
  kubectl -n argocd rollout restart statefulset/argocd-application-controller >/dev/null
  kubectl -n argocd rollout status  statefulset/argocd-application-controller --timeout=4m >/dev/null
  ok "cache bounded to ${GITOPS_NAMESPACE} and to the kinds the Role permits"
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
  gitops_bound_cache
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
