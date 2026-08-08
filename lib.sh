#!/usr/bin/env bash
# Shared helpers. Sourced by bootstrap.sh. Not meant to be run directly.

# --- Logging -----------------------------------------------------------------
_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_green=$'\033[32m'
_c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_bold=$'\033[1m'

log()   { printf '%s==>%s %s\n' "${_c_blue}"   "${_c_reset}" "$*"; }
ok()    { printf '%s  ok%s %s\n' "${_c_green}"  "${_c_reset}" "$*"; }
warn()  { printf '%swarn%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2; }
die()   { printf '%s ERR%s %s\n' "${_c_red}"    "${_c_reset}" "$*" >&2; exit 1; }
step()  { printf '\n%s%s%s\n' "${_c_bold}" "$*" "${_c_reset}"; }

# --- Preflight ---------------------------------------------------------------
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

require_aws_auth() {
  aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null 2>&1 \
    || die "AWS credentials not configured or expired for region ${AWS_REGION}"
}

# --- Admin CIDR detection ----------------------------------------------------
detect_admin_cidr() {
  local ip
  ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')" \
    || die "could not detect your public IP; set ADMIN_CIDR manually"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "unexpected IP response: ${ip}"
  printf '%s/32' "$ip"
}

# --- CloudFormation ----------------------------------------------------------
stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1
}

stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST"
}

# Read a single named Output. This replaces a hand-rolled state file:
# CloudFormation owns the state, so it cannot drift out of sync.
stack_output() {
  local key="$1" val
  val="$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null)"
  [[ -n "$val" && "$val" != "None" ]] || die "stack output '${key}' not found. Run: ./bootstrap.sh --infra"
  printf '%s' "$val"
}

# --- SSH ---------------------------------------------------------------------
# StrictHostKeyChecking is disabled because instances are rebuilt constantly and
# host keys change every time. Acceptable for an ephemeral POC; called out as a
# tradeoff in the design document.
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)

ssh_node() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" -i "${SSH_KEY_PATH}" "${SSH_USER}@${host}" "$@"
}

scp_node() {
  local src="$1" host="$2" dst="$3"
  scp "${SSH_OPTS[@]}" -i "${SSH_KEY_PATH}" -r "${src}" "${SSH_USER}@${host}:${dst}"
}

wait_for_ssh() {
  local host="$1" tries="${2:-40}" i
  log "waiting for SSH on ${host}"
  for ((i = 1; i <= tries; i++)); do
    if ssh_node "${host}" true 2>/dev/null; then
      ok "ssh ready: ${host}"
      return 0
    fi
    sleep 10
  done
  die "SSH never came up on ${host}"
}

# --- Private key retrieval ---------------------------------------------------
# CloudFormation put the private half in SSM as a SecureString. Fetch once,
# lock it to 0600, and never commit it.
fetch_private_key() {
  local key_id
  if [[ -f "${SSH_KEY_PATH}" ]]; then
    ok "private key already present: ${SSH_KEY_PATH}"
    return 0
  fi
  key_id="$(stack_output KeyPairId)"
  mkdir -p "${SSH_KEY_DIR}"
  aws ssm get-parameter \
    --name "/ec2/keypair/${key_id}" \
    --with-decryption \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' --output text > "${SSH_KEY_PATH}" \
    || die "could not read private key from SSM"
  chmod 600 "${SSH_KEY_PATH}"
  ok "private key written: ${SSH_KEY_PATH}"
}
