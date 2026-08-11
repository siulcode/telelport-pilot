#!/usr/bin/env bash
# File: libs/cluster-lib.sh
# Desc: Implementations behind each bootstrap.sh flag, plus its usage text.

TEMPLATE="${REPO_ROOT}/infra/infra.yaml"

usage() {
  cat <<EOF
Usage: ./bootstrap.sh [FLAG]

  --infra      Deploy VPC, security group, key pair, EIPs, and 3 EC2 instances
  --cluster    kubeadm + CNI, then cert-manager, Traefik, and the demo namespace
  --all        Run --infra then --cluster
  --status     Show what currently exists
  --reset      kubeadm reset all three nodes, leaving the instances up
  --destroy    Delete the CloudFormation stack and all resources
  --help       This message

Optional, and deliberately outside --all:

  --deploy-gitops   Argo CD, scoped to a single namespace. The core RBAC
                    deployment does not depend on it.

Every flag is safe to re-run. Configuration lives in config.env.
EOF
}

# =============================================================================
# Phase 1
# =============================================================================
cmd_infra() {
  step "Phase 1: infrastructure"
  require_cmd aws curl
  require_aws_auth

  local admin_cidr="${ADMIN_CIDR:-}"
  if [[ -z "${admin_cidr}" ]]; then
    admin_cidr="$(detect_admin_cidr)"
    log "detected admin CIDR: ${admin_cidr}"
  fi

  # Guard against a stack wedged in a state that deploy cannot recover from.
  local status; status="$(stack_status)"
  case "${status}" in
    ROLLBACK_COMPLETE|CREATE_FAILED)
      die "stack is in ${status} and cannot be updated. Run: ./bootstrap.sh --destroy" ;;
    *_IN_PROGRESS)
      die "stack is busy (${status}). Wait for it to settle." ;;
  esac

  log "deploying stack: ${STACK_NAME}"
  # 'deploy' no-ops when nothing changed -- that is phase 1's idempotency.
  # CAPABILITY_IAM is required by the SSM node role.
  aws cloudformation deploy \
    --template-file "${TEMPLATE}" \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides \
      ProjectName="${PROJECT_NAME}" \
      AdminCidr="${admin_cidr}" \
      PublicIngressCidr="${PUBLIC_INGRESS_CIDR}" \
      ControlPlaneInstanceType="${CP_INSTANCE_TYPE}" \
      WorkerInstanceType="${WORKER_INSTANCE_TYPE}" \
      RootVolumeSize="${ROOT_VOLUME_SIZE}" \
      VpcCidr="${VPC_CIDR}" \
      SubnetCidr="${SUBNET_CIDR}" \
      ControlPlanePrivateIp="${CP_PRIVATE_IP}" \
      Worker1PrivateIp="${WORKER1_PRIVATE_IP}" \
      Worker2PrivateIp="${WORKER2_PRIVATE_IP}" \
      ApiEndpointName="${CP_ENDPOINT}" \
      ControlPlaneHostname="${CP_HOSTNAME}" \
      Worker1Hostname="${WORKER1_HOSTNAME}" \
      Worker2Hostname="${WORKER2_HOSTNAME}"

  ok "stack deployed"
  fetch_private_key
  cmd_status
}

# =============================================================================
# Phase 2 - Kubernetes. Idempotent by artifact guard, not reconciliation:
# only the files kubeadm writes can say whether init succeeded.
# =============================================================================
# Shared by --cluster and --reset. Populates CP, W1, W2, HOSTS.
cluster_preflight() {
  require_cmd aws ssh scp kubectl
  require_aws_auth
  stack_exists || die "no infrastructure found. Run: ./bootstrap.sh --infra"
  fetch_private_key
  CP="$(stack_output ControlPlanePublicIp)"
  W1="$(stack_output Worker1PublicIp)"
  W2="$(stack_output Worker2PublicIp)"
  HOSTS=("${CP}" "${W1}" "${W2}")
}

# The two units run_parallel drives.
_prep_host() { push_node_bundle "$1" && run_node_script "$1" 00-common.sh; }
_join_host() { scp_node "${JOIN_FILE}" "$1" "${NODE_STAGE}/join-command" \
                 && run_node_script "$1" 20-worker-join.sh; }

# Three independent apt runs of several minutes each; serialising them triples
# the wall clock for no benefit.
cluster_prepare_hosts() {
  render_node_env "${CP}" >/dev/null
  local h; for h in "${HOSTS[@]}"; do wait_for_ssh "${h}"; done
  step "Host preparation (parallel, logging to ${LOG_DIR})"
  run_parallel _prep_host prepare "${HOSTS[@]}" \
    || die "host preparation failed; full logs in ${LOG_DIR}"
}

cluster_init_control_plane() {
  step "Control plane"
  run_node_script "${CP}" 10-control-plane.sh
}

# The join command embeds a bootstrap token: written 0600, shredded after use,
# never passed on a command line where ps would expose it.
cluster_join_workers() {
  step "Joining workers"
  JOIN_FILE="${BUILD_DIR}/join-command"
  ( umask 077; ssh_node "${CP}" "sudo kubeadm token create --print-join-command" \
      > "${JOIN_FILE}" )
  [[ -s "${JOIN_FILE}" ]] || die "could not generate a join command"

  local rc=0
  run_parallel _join_host join "${W1}" "${W2}" || rc=$?
  rm -f "${JOIN_FILE}"
  (( rc == 0 )) || die "worker join failed; full logs in ${LOG_DIR}"
}

cluster_install_cni() {
  step "CNI (${CNI})"
  run_node_script "${CP}" 30-cni.sh
}

cmd_cluster() {
  step "Phase 2: Kubernetes"
  cluster_preflight
  cluster_prepare_hosts
  cluster_init_control_plane
  cluster_join_workers
  cluster_install_cni
  fetch_kubeconfig "${CP}"
  platform_install
  cmd_status
}

# admin.conf references the private IP, unreachable from a laptop. Two copies are
# written from it:
#   KUBECONFIG_LOCAL  points at the split-horizon hostname -- for you, and needs
#                     the /etc/hosts entry --status prints
#   KUBECONFIG_DIRECT points at the Elastic IP -- for the rest of this script, so
#                     --all works on a machine whose /etc/hosts is not set up yet
# Both are valid: the hostname and the EIP are in certSANs.
fetch_kubeconfig() {
  local cp="$1" raw
  raw="$(ssh_node "${cp}" "sudo cat /etc/kubernetes/admin.conf")"
  [[ -n "${raw}" ]] || die "failed to retrieve admin.conf"

  mkdir -p "$(dirname "${KUBECONFIG_LOCAL}")" "${BUILD_DIR}"
  ( umask 077
    sed "s|server: https://.*|server: https://${CP_ENDPOINT}:6443|" <<<"${raw}" \
      > "${KUBECONFIG_LOCAL}"
    sed "s|server: https://.*|server: https://${cp}:6443|" <<<"${raw}" \
      > "${KUBECONFIG_DIRECT}" )
  ok "kubeconfig written: ${KUBECONFIG_LOCAL}"
}

# =============================================================================
# Reset - tear the cluster down without destroying the machines, so a clean
# rebuild can be rehearsed before the demo.
# =============================================================================
cmd_reset() {
  step "Reset cluster"
  cluster_preflight

  printf '\n  This runs kubeadm reset on all three nodes. The EC2 instances stay up.\n'
  read -r -p "  Type 'reset' to confirm: " reply
  [[ "${reply}" == "reset" ]] || die "aborted"

  render_node_env "${CP}" >/dev/null
  local h; for h in "${W1}" "${W2}" "${CP}"; do
    push_node_bundle "${h}"
    run_node_script "${h}" 90-reset.sh
  done
  rm -f "${KUBECONFIG_LOCAL}"
  ok "cluster reset; run --cluster to rebuild"
}

# =============================================================================
# Status
# =============================================================================
cmd_status() {
  step "Status"
  require_cmd aws
  require_aws_auth

  local status; status="$(stack_status)"
  printf '  stack   : %s (%s)\n' "${STACK_NAME}" "${status}"

  if [[ "${status}" == "DOES_NOT_EXIST" ]]; then
    printf '\n  Nothing deployed. Run: ./bootstrap.sh --infra\n\n'
    return 0
  fi

  local cp_public cp_private w1 w2 ingress
  cp_public="$(stack_output ControlPlanePublicIp)"
  cp_private="$(stack_output ControlPlanePrivateIp)"
  w1="$(stack_output Worker1PublicIp)"
  w2="$(stack_output Worker2PublicIp)"
  ingress="$(stack_output IngressPublicIp)"

  cat <<EOF

  control plane : ${cp_public}  (private ${cp_private})
  worker01      : ${w1}  (ingress)
  worker02      : ${w2}

  ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${cp_public}

  Add to your laptop /etc/hosts -- the first line makes the API certSAN match,
  the second points the site hostname at the ingress:
    ${cp_public}  ${CP_ENDPOINT}
    ${ingress}  ${SITE_HOSTNAME}

  export KUBECONFIG=${KUBECONFIG_LOCAL}

EOF

  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name]' \
    --output table
}

# =============================================================================
# Destroy
# =============================================================================
cmd_destroy() {
  step "Destroy"
  require_cmd aws
  require_aws_auth

  stack_exists || { ok "nothing to destroy"; return 0; }

  printf '\n  This deletes the entire %s stack: VPC, instances, EIP, key pair.\n' "${STACK_NAME}"
  read -r -p "  Type the stack name to confirm: " reply
  [[ "${reply}" == "${STACK_NAME}" ]] || die "aborted"

  log "deleting stack (this takes a few minutes)"
  aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    || die "delete did not complete cleanly; check stack events in the console"

  rm -f "${SSH_KEY_PATH}"
  ok "stack deleted, local private key removed"
}
