#!/usr/bin/env bash
# File: libs/boot-lib.sh
# Desc: Sourced first by both drivers. Resolves the repo, loads configuration
#       and every library, and makes repo-relative paths absolute so an
#       exported KUBECONFIG survives a cd.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=../config.env
source config.env
# Local overrides, uncommitted, sourced second so they win.
# shellcheck source=/dev/null
[[ -f config.env.local ]] && source config.env.local

# common first: everything else uses its logging and preflight helpers.
for _lib in common platform cluster users gitops; do
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/libs/${_lib}-lib.sh"
done
unset _lib

for _p in SSH_KEY_DIR SSH_KEY_PATH KUBECONFIG_LOCAL KUBECONFIG_DIRECT BUILD_DIR LOG_DIR; do
  [[ "${!_p}" == /* ]] || printf -v "${_p}" '%s/%s' "${REPO_ROOT}" "${!_p#./}"
done
unset _p
