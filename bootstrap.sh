#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - kubeadm Kubernetes on AWS EC2
#
#   Phase 1 (--infra)    CloudFormation. Declarative, idempotent by construction.
#   Phase 2 (--cluster)  Bash over SSH. Imperative, idempotent by artifact guard,
#                        because kubeadm's own state lives on disk.
#
# The two phases are deliberately different. See README for the reasoning.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=config.env
source "${REPO_ROOT}/config.env"
# Local overrides, uncommitted. Sourced second so it wins.
# shellcheck source=/dev/null
[[ -f "${REPO_ROOT}/config.env.local" ]] && source "${REPO_ROOT}/config.env.local"
# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

TEMPLATE="${REPO_ROOT}/infra/infra.yaml"

usage() {
  cat <<EOF
Usage: ./bootstrap.sh [FLAG]

  --infra      Deploy VPC, security group, key pair, EIP, and 3 EC2 instances
  --cluster    Install and configure Kubernetes with kubeadm on those instances
  --all        Run --infra then --cluster
  --status     Show what currently exists
  --destroy    Delete the CloudFormation stack and all resources
  --help       This message

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
  # 'deploy' is a no-op when the template and parameters are unchanged, which is
  # where phase 1 gets its idempotency for free.
  # CAPABILITY_IAM is required because the template creates a node role and
  # instance profile for SSM. Without it, deploy fails with an "Requires
  # capabilities" error that does not name the resource responsible.
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
# Phase 2 - placeholder until the node scripts land
# =============================================================================
cmd_cluster() {
  step "Phase 2: Kubernetes"
  require_cmd aws ssh scp
  require_aws_auth
  stack_exists || die "no infrastructure found. Run: ./bootstrap.sh --infra"
  fetch_private_key

  local cp_public cp_private w1_public w2_public
  cp_public="$(stack_output ControlPlanePublicIp)"
  cp_private="$(stack_output ControlPlanePrivateIp)"
  w1_public="$(stack_output Worker1PublicIp)"
  w2_public="$(stack_output Worker2PublicIp)"

  for h in "${cp_public}" "${w1_public}" "${w2_public}"; do
    wait_for_ssh "${h}"
  done

  warn "phase 2 node scripts not yet wired up"
  log  "control plane : ${cp_public} (private ${cp_private})"
  log  "worker01      : ${w1_public}"
  log  "worker02      : ${w2_public}"
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

  local cp_public cp_private w1 w2
  cp_public="$(stack_output ControlPlanePublicIp)"
  cp_private="$(stack_output ControlPlanePrivateIp)"
  w1="$(stack_output Worker1PublicIp)"
  w2="$(stack_output Worker2PublicIp)"

  cat <<EOF

  control plane : ${cp_public}  (private ${cp_private})
  worker01      : ${w1}
  worker02      : ${w2}

  ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${cp_public}

  Add to your laptop /etc/hosts so the API certSAN matches:
    ${cp_public}  ${CP_ENDPOINT}

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

# =============================================================================
# Dispatch
# =============================================================================
main() {
  case "${1:-}" in
    --infra)   cmd_infra ;;
    --cluster) cmd_cluster ;;
    --all)     cmd_infra; cmd_cluster ;;
    --status)  cmd_status ;;
    --destroy) cmd_destroy ;;
    --help|-h) usage ;;
    "")        usage; exit 1 ;;
    *)         printf 'unknown flag: %s\n\n' "$1"; usage; exit 1 ;;
  esac
}

main "$@"
