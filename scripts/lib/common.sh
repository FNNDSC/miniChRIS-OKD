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

# harden_install_auth — keep the installer-written credentials (auth/
# kubeconfig, kubeadmin-password) private to the invoking user; helm warns
# on group-readable kubeconfigs. openshift-install writes them at ISO
# creation and again at install-complete, so both steps call this.
harden_install_auth() {
  [[ -d "${INSTALL_DIR}/auth" ]] || return 0
  chmod 700 "${INSTALL_DIR}/auth"
  # find, not a glob: an empty auth/ would hand chmod a literal '*' and, under
  # set -e, take the caller down with it.
  find "${INSTALL_DIR}/auth" -maxdepth 1 -type f -exec chmod 600 {} +
}

# --- cluster liveness ---------------------------------------------------------
# A cluster that was powered off across the 24-hour bootstrap certificate
# rotation comes back half-dead: kubelet's client certificate has expired, so
# it authenticates as system:anonymous and can start only the static
# control-plane pods, while kube-apiserver keeps serving the last state etcd
# recorded. Every read then lies — nodes report Ready, workloads report
# Running — and the real symptom surfaces much later as something unrelated
# (a Helm uninstall that cannot resolve Route, an operator wait that never
# settles). See docs/troubleshooting.md; 'just okd-doctor' diagnoses + repairs.
#
# Everything below FAILS CLOSED. Empty output is how these helpers say
# "healthy", so an error that produced silence would disable precisely the
# check that exists to catch a cluster lying about itself.

# The staleness threshold is NODE_LEASE_MAX_AGE (config.env). The node lease
# is used rather than the Ready condition's lastHeartbeatTime because kubelet
# only rewrites that every ~5 minutes when nothing has changed, so a perfectly
# healthy node routinely looks minutes stale there — whereas it renews its
# lease every ~10s.
#
# Validated here because the value is passed to jq as JSON: a duration-style
# typo (NODE_LEASE_MAX_AGE=120s — the neighbouring CLUSTER_STABLE_* knobs are
# durations, so it is the natural mistake) would make every lease query fail,
# and a failed query that returned silence would read as "healthy" forever.
[[ "${NODE_LEASE_MAX_AGE}" =~ ^[0-9]+$ ]] \
  || die "NODE_LEASE_MAX_AGE must be a whole number of seconds (got '${NODE_LEASE_MAX_AGE}')"

# count_lines TEXT — non-empty lines in TEXT (0 for the empty string).
count_lines() { [[ -n "$1" ]] && grep -c . <<<"$1" || printf 0; }

# cluster_api_ok — true when kube-apiserver answers its readiness endpoint.
# Retried briefly on purpose: this gates whole installs and deploys, and a
# single dropped probe (router blip, apiserver mid-restart) must not fail one.
cluster_api_ok() {
  local attempt
  for attempt in 1 2 3; do
    admin_oc get --raw /readyz --request-timeout=10s >/dev/null 2>&1 && return 0
    [[ "${attempt}" -eq 3 ]] || sleep 3
  done
  return 1
}

# node_lease_problems — one complete, human-readable line per node whose
# kubelet is not renewing its lease; nothing at all when every kubelet is live.
# Callers only indent what comes back, so the phrasing lives here.
#
# Every failure path emits a problem line instead of staying silent: an
# unreadable lease list, an unparseable list, no leases at all, or a timestamp
# jq cannot read. The jq try/catch matters especially — '.items[]' aborts the
# whole stream at the first throwing item, which on a single-node cluster
# means one bad timestamp would hide the only node there is.
node_lease_problems() {
  local json count
  json="$(admin_oc get leases -n kube-node-lease -o json --request-timeout=15s 2>/dev/null)" \
    || { printf 'could not read node leases (kube-node-lease is unreadable)\n'; return 0; }

  count="$(jq -r '.items | length' <<<"${json}" 2>/dev/null)" || count=""
  [[ "${count}" =~ ^[0-9]+$ ]] \
    || { printf 'could not parse the node lease list\n'; return 0; }
  [[ "${count}" -gt 0 ]] \
    || { printf 'no node leases exist — no kubelet has ever registered\n'; return 0; }

  jq -r --argjson max "${NODE_LEASE_MAX_AGE}" '
      .items[]
      | (.metadata.name // "<unnamed>") as $node
      | (try ((.spec.renewTime // "") | sub("\\.[0-9]+"; "") | fromdateiso8601)
         catch null) as $renew
      | if $renew == null then
          "node \($node) has no usable lease renewTime"
        else
          ((now - $renew) | floor) as $age
          | if $age > $max then
              "node \($node) has not renewed its lease in \($age)s (a live kubelet renews every ~10s)"
            else empty end
        end' <<<"${json}" 2>/dev/null \
    || printf 'could not evaluate node lease ages\n'
}

# pending_kubelet_csrs — names of unapproved kubelet client/serving CSRs. They
# pile up when kubelet has lost its credentials: it keeps requesting a new
# certificate, but cluster-machine-approver is an ordinary pod that a
# credential-less kubelet cannot start, so nothing ever approves them.
#
# A query failure yields no names, which makes okd-doctor decline to repair
# rather than repair the wrong thing — the safe direction for this one.
pending_kubelet_csrs() {
  admin_oc get csr -o json --request-timeout=15s 2>/dev/null \
    | jq -r '
        .items[]
        | select((.status.conditions // []) | length == 0)
        | select((.spec.signerName // "")
                 | test("^kubernetes\\.io/(kube-apiserver-client-kubelet|kubelet-serving)$"))
        | .metadata.name' 2>/dev/null || true
}

# cluster_liveness_problem — why the cluster cannot be trusted right now, or
# nothing when it is healthy. The fatal guard (require_live_cluster) and the
# advisory guard (warn_unless_live_cluster) render exactly this text, so the
# diagnosis itself lives in one place; okd-doctor and okd-verify add their own
# framing around it for their own output formats.
cluster_liveness_problem() {
  local problems pending line
  if ! cluster_api_ok; then
    printf 'kube-apiserver at %s is not answering /readyz\n' "${API_URL}"
    printf "  is the VM running? 'virsh -c qemu:///system list'"
    return 0
  fi
  problems="$(node_lease_problems)"
  if [[ -n "${problems}" ]]; then
    # One retry before blocking: this gate stops installs and deploys, and a
    # lease can read briefly stale across an apiserver restart or a slow read.
    sleep 5
    problems="$(node_lease_problems)"
  fi
  [[ -n "${problems}" ]] || return 0

  printf 'kubelet is not reporting — the API is serving stale data:\n'
  while IFS= read -r line; do
    [[ -z "${line}" ]] || printf '  %s\n' "${line}"
  done <<<"${problems}"
  pending="$(pending_kubelet_csrs)"
  [[ -z "${pending}" ]] \
    || printf '  %s kubelet CSR(s) pending — kubelet has lost its client certificate\n' \
         "$(count_lines "${pending}")"
  printf "  until this is fixed, 'oc get nodes/pods' reports Ready/Running for workloads that are not running"
}

# require_live_cluster — installed, serving, and kubelet actually reporting.
# Use in anything that changes cluster state: the reads it protects would
# otherwise succeed against stale data and fail confusingly much later.
require_live_cluster() {
  local problem
  require_cluster
  problem="$(cluster_liveness_problem)"
  [[ -z "${problem}" ]] || die "${problem}
  run 'just okd-doctor' to diagnose and repair"
}

# warn_unless_live_cluster — advisory form for commands that must still work
# against a broken cluster (teardown, status): say what is wrong, then let the
# caller decide. Silent when the cluster was never installed.
warn_unless_live_cluster() {
  local problem
  [[ -f "${ADMIN_KUBECONFIG}" ]] || return 0
  problem="$(cluster_liveness_problem)"
  [[ -n "${problem}" ]] || return 0
  warn "${problem}"
  warn "continuing anyway — 'just okd-doctor' repairs the cluster itself"
}

# render_template SRC DST — envsubst SRC into DST, substituting exactly the
# ${VARS} the template references and dying if any of them is unset/empty.
render_template() {
  local src="$1" dst="$2" var vars subst missing=()
  [[ -f "${src}" ]] || die "template not found: ${src}"
  # '|| true': under pipefail a variable-free template would otherwise kill
  # the script here instead of reaching the plain-copy branch below.
  # shellcheck disable=SC2016  # '${...}' here is the pattern being matched
  vars="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "${src}" | tr -d '${}' | sort -u || true)"
  if [[ -z "${vars}" ]]; then
    cp "${src}" "${dst}"
    return
  fi
  for var in ${vars}; do
    [[ -n "${!var:-}" ]] || missing+=("${var}")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "unset variable(s) for $(basename "${src}"): ${missing[*]}"
  # shellcheck disable=SC2016,SC2086  # literal '${...}' for envsubst; word-splitting of ${vars} is intentional
  subst="$(printf '${%s} ' ${vars})"
  mkdir -p "$(dirname "${dst}")"
  envsubst "${subst}" <"${src}" >"${dst}"
}
