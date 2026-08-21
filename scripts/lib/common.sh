# shellcheck shell=bash
# shellcheck disable=SC2034  # paths/creds below are consumed by sourcing scripts
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
# die MSG... — print and exit. Scripts with a different exit-code contract may
# pre-set DIE_STATUS before sourcing this lib (smoke.sh: every bootstrap
# failure, config validation below included, must exit 2).
die()  { printf '%s[%s] error:%s %s\n' "${_C_ERR}" "${SCRIPT_NAME}" "${_C_OFF}" "$*" >&2; exit "${DIE_STATUS:-1}"; }

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
# config.local.env holds plain assignments (like config.env, minus the
# ${VAR:-default} guards), so sourcing it would clobber values passed via the
# environment — save any variable the file assigns that the caller already
# set, and restore those after sourcing. config.env then fills the remaining
# gaps, since every value there is ${VAR:-default}-guarded.
_load_config() {
  local local_env="${REPO_ROOT}/config.local.env" var i
  local preset_vars=() preset_vals=()
  if [[ -f "${local_env}" ]]; then
    while IFS= read -r var; do
      if [[ -n "${!var+x}" ]]; then
        preset_vars+=("${var}")
        preset_vals+=("${!var}")
      fi
    done < <(sed -nE 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "${local_env}")
    # shellcheck source=/dev/null
    source "${local_env}"
    for i in "${!preset_vars[@]}"; do
      printf -v "${preset_vars[$i]}" '%s' "${preset_vals[$i]}"
    done
  fi
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/config.env"
}
set -a
_load_config
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
