#!/usr/bin/env bash
# File: bootstrap.sh
# Desc: Dispatcher. Each flag maps to one command in libs/cluster-lib.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/libs/boot-lib.sh"

case "${1:-}" in
  --infra)         cmd_infra ;;
  --cluster)       cmd_cluster ;;
  --all)           cmd_infra; cmd_cluster ;;
  --status)        cmd_status ;;
  --reset)         cmd_reset ;;
  --deploy-gitops) cmd_deploy_gitops ;;
  --destroy)       cmd_destroy ;;
  --help|-h)       usage ;;
  "")              usage; exit 1 ;;
  *)               warn "unknown flag: $1"; usage; exit 1 ;;
esac
