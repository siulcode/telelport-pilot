#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/libs/boot-lib.sh"

[[ $# -ge 2 ]] || { user_usage; exit 1; }
user_onboard "$@"
