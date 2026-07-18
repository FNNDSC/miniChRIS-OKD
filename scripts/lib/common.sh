# shellcheck shell=bash
# scripts/lib/common.sh — shared plumbing for every harness script:
# config loading, derived values, logging, template rendering, preconditions.
#
# Source this at the top of each script; do not execute it directly.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_COMMON_LIB_DIR}/../.." && pwd)"

# --- state layout (everything gitignored under okd/state/) ------------------
STATE_DIR="${REPO_ROOT}/okd/state"
BIN_DIR="${STATE_DIR}/bin"          # pinned oc / openshift-install / kubectl
RENDER_DIR="${STATE_DIR}/render"    # rendered templates (kept for reference)
INSTALL_DIR="${STATE_DIR}/install"  # openshift-install working dir + auth/
SSH_DIR="${STATE_DIR}/ssh"          # generated debug keypair for core@node
AUTH_DIR="${STATE_DIR}/auth"        # developer credentials/kubeconfig
REPORT_DIR="${STATE_DIR}/reports"   # okd-verify PASS/FAIL reports

ADMIN_KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
KUBEADMIN_PASSWORD_FILE="${INSTALL_DIR}/auth/kubeadmin-password"
DEVELOPER_PASSWORD_FILE="${AUTH_DIR}/developer-password"
DEVELOPER_KUBECONFIG="${AUTH_DIR}/developer.kubeconfig"

# Pinned binaries win over anything already on the host.
export PATH="${BIN_DIR}:${PATH}"

# --- logging -----------------------------------------------------------------
if [[ -t 2 ]]; then
  _C_INFO=$'\033[1;34m' _C_WARN=$'\033[1;33m' _C_ERR=$'\033[1;31m' _C_OFF=$'\033[0m'
else
  _C_INFO='' _C_WARN='' _C_ERR='' _C_OFF=''
fi
log()  { printf '%s[%s]%s %s\n' "${_C_INFO}" "${SCRIPT_NAME}" "${_C_OFF}" "$*" >&2; }
warn() { printf '%s[%s] warning:%s %s\n' "${_C_WARN}" "${SCRIPT_NAME}" "${_C_OFF}" "$*" >&2; }
die()  { printf '%s[%s] error:%s %s\n' "${_C_ERR}" "${SCRIPT_NAME}" "${_C_OFF}" "$*" >&2; exit 1; }

# require_cmd CMD... — die with a hint if any command is missing.
require_cmd() {
  local cmd missing=()
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required command(s): ${missing[*]} (run 'just host-setup')"
}

# confirm PROMPT — interactive yes/no; auto-yes when not a TTY or CONFIRM=yes.
confirm() {
  [[ "${CONFIRM:-}" == yes || ! -t 0 ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "${reply}" == y || "${reply}" == Y ]]
}

# --- configuration -----------------------------------------------------------
# Precedence: environment > config.local.env > config.env defaults.
# (config.env guards every value with ${VAR:-default}; config.local.env is
# sourced first so its plain assignments act as pre-set environment.)
set -a
# shellcheck source=/dev/null
[[ -f "${REPO_ROOT}/config.local.env" ]] && source "${REPO_ROOT}/config.local.env"
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"
set +a

_detect_host_ip() {
  command -v ip >/dev/null 2>&1 || return 0
  ip route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

# --- derived values ----------------------------------------------------------
[[ -n "${HOST_IP}" ]] || HOST_IP="$(_detect_host_ip)"

case "${ACCESS_MODE}" in
  local) ACCESS_IP="${VM_IP}" ;;
  lan)
    [[ -n "${HOST_IP}" ]] || die "HOST_IP auto-detection failed; set HOST_IP in config.local.env"
    ACCESS_IP="${HOST_IP}"
    ;;
  *) die "ACCESS_MODE must be 'local' or 'lan' (got '${ACCESS_MODE}')" ;;
esac

# Dashed sslip.io form (10-0-0-33.sslip.io): assisted-service rejects base
# domains that embed a dotted-decimal IP ("DNS format mismatch").
[[ -n "${BASE_DOMAIN}" ]] || BASE_DOMAIN="${ACCESS_IP//./-}.sslip.io"
CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
API_URL="https://api.${CLUSTER_DOMAIN}:6443"
APPS_DOMAIN="apps.${CLUSTER_DOMAIN}"
CONSOLE_URL="https://console-openshift-console.${APPS_DOMAIN}"

VM_NET_BASE="${VM_NET_CIDR%/*}"          # 192.168.126.0
VM_NET_PREFIX="${VM_NET_CIDR#*/}"        # 24
_VM_NET_DOT3="${VM_NET_BASE%.*}"         # 192.168.126
VM_GATEWAY="${VM_GATEWAY:-${_VM_NET_DOT3}.1}"
VM_DHCP_START="${_VM_NET_DOT3}.100"
VM_DHCP_END="${_VM_NET_DOT3}.199"

[[ -n "${IMAGES_DIR}" ]] || IMAGES_DIR="${STATE_DIR}/images"

export ACCESS_IP BASE_DOMAIN CLUSTER_DOMAIN API_URL APPS_DOMAIN CONSOLE_URL \
  HOST_IP VM_NET_BASE VM_NET_PREFIX VM_GATEWAY VM_DHCP_START VM_DHCP_END \
  IMAGES_DIR

# --- shared helpers ----------------------------------------------------------

# virsh_c ARGS... — virsh against the system libvirt daemon.
virsh_c() { virsh --connect qemu:///system "$@"; }

# vm_exists — true if the harness VM is defined (running or not).
vm_exists() { virsh_c dominfo "${VM_NAME}" >/dev/null 2>&1; }

# admin_oc ARGS... — oc as cluster admin. Pins the installer's 'admin'
# context: an `oc login` against this kubeconfig switches its current
# context, which must never redirect harness scripts.
admin_oc() { oc --kubeconfig "${ADMIN_KUBECONFIG}" --context admin "$@"; }

# require_cluster — die unless the admin kubeconfig exists.
require_cluster() {
  [[ -f "${ADMIN_KUBECONFIG}" ]] \
    || die "no admin kubeconfig at ${ADMIN_KUBECONFIG} — is the cluster installed? (just okd-install)"
}

# render_template SRC DST — envsubst SRC into DST, substituting exactly the
# ${VARS} the template references and dying if any of them is unset/empty.
render_template() {
  local src="$1" dst="$2" var vars subst missing=()
  [[ -f "${src}" ]] || die "template not found: ${src}"
  vars="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "${src}" | tr -d '${}' | sort -u)"
  if [[ -z "${vars}" ]]; then
    cp "${src}" "${dst}"
    return
  fi
  for var in ${vars}; do
    [[ -n "${!var:-}" ]] || missing+=("${var}")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "unset variable(s) for $(basename "${src}"): ${missing[*]}"
  # shellcheck disable=SC2046  # word-splitting of ${vars} is intentional
  subst="$(printf '${%s} ' ${vars})"
  mkdir -p "$(dirname "${dst}")"
  envsubst "${subst}" <"${src}" >"${dst}"
}
