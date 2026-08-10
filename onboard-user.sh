#!/usr/bin/env bash
# File: onboard-user.sh
# Desc: Issue a client certificate and kubeconfig for a user via the CSR API.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/libs/boot-lib.sh"

[[ $# -ge 2 ]] || { user_usage; exit 1; }
user_onboard "$@"
