#!/usr/bin/env bash
# File: libs/node/20-worker-join.sh
# Desc: Join a worker. Idempotent by artifact guard on kubelet.conf.
# The join command is read from a 0600 file, not argv -- it embeds a bearer
# token, and anything in argv is visible to every user via ps.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/node-env.sh"

log() { printf '  [%s] %s\n' "$(hostname -s)" "$*"; }
JOIN_FILE="${SELF_DIR}/join-command"

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  log "already joined"
  exit 0
fi
[[ -f "${JOIN_FILE}" ]] || { echo "no join command at ${JOIN_FILE}" >&2; exit 1; }

log "joining cluster"
set +x   # in case this was invoked with bash -x; deliberately not restored
bash "${JOIN_FILE}" --node-name "$(hostname -s)" >/dev/null

[[ -f /etc/kubernetes/kubelet.conf ]] \
  || { echo "join reported success but kubelet.conf is missing" >&2; exit 1; }

shred -u "${JOIN_FILE}" 2>/dev/null || rm -f "${JOIN_FILE}"
log "joined"
