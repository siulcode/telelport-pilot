#!/usr/bin/env bash
# bootstrap.sh - kubeadm Kubernetes on AWS EC2
#   --infra    CloudFormation, idempotent by construction
#   --cluster  bash over SSH, idempotent by artifact guard
# See docs/DESIGN.md for why the two phases differ.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=config.env
source "${REPO_ROOT}/config.env"
# Local overrides, uncommitted. Sourced second so it wins.
# shellcheck source=/dev/null
[[ -f "${REPO_ROOT}/config.env.local" ]] && source "${REPO_ROOT}/config.env.local"
# common must come first: the others use its logging and preflight helpers.
for _lib in common platform cluster; do
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/libs/${_lib}-lib.sh"
done
unset _lib

# Make repo-relative paths absolute so anything printed here survives a cd --
# an exported relative KUBECONFIG breaks as soon as you change directory.
for _p in SSH_KEY_DIR SSH_KEY_PATH KUBECONFIG_LOCAL KUBECONFIG_DIRECT BUILD_DIR LOG_DIR; do
  [[ "${!_p}" == /* ]] || printf -v "${_p}" '%s/%s' "${REPO_ROOT}" "${!_p#./}"
done
unset _p

usage() {
  cat <<EOF
Usage: ./bootstrap.sh [FLAG]

  --infra      Deploy VPC, security group, key pair, EIP, and 3 EC2 instances
  --cluster    kubeadm + CNI, then cert-manager, Traefik, and the demo namespace
  --all        Run --infra then --cluster
  --status     Show what currently exists
  --reset      kubeadm reset all three nodes, leaving the instances up
  --destroy    Delete the CloudFormation stack and all resources
  --help       This message

Every flag is safe to re-run. Configuration lives in config.env.
EOF
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
    --reset)   cmd_reset ;;
    --destroy) cmd_destroy ;;
    --help|-h) usage ;;
    "")        usage; exit 1 ;;
    *)         printf 'unknown flag: %s\n\n' "$1"; usage; exit 1 ;;
  esac
}

main "$@"
