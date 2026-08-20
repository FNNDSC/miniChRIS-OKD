#!/usr/bin/env bash
# okd-wait.sh — follow the unattended agent install to completion:
# bootstrap-complete (SCOS installed, control plane bootstrapping), then
# install-complete (cluster operators rolled out). Expect 45–70 minutes
# total. Safe to re-run if interrupted or timed out.
#
# The agent phase runs entirely inside the VM, and openshift-install reports
# only "bootstrap process timed out: context deadline exceeded" when it
# wedges — after burning its full 60-minute deadline. This script therefore
# watches the node itself: it aborts early on a repeating prepare failure and
# always dumps the guest-side reason when a wait fails
# (FNNDSC/HARBOR-planning#128).

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd openshift-install ssh
[[ -d "${INSTALL_DIR}" ]] || die "no install dir at ${INSTALL_DIR} — run okd-render/okd-create-iso first"

# How many failed install-config generations before we stop waiting, and how
# often to look. The node needs a few minutes to boot before it answers ssh;
# unreachable polls simply count as zero.
PREPARE_FAIL_LIMIT="${PREPARE_FAIL_LIMIT:-3}"
NODE_POLL_SECONDS="${NODE_POLL_SECONDS:-60}"

NODE_KEY="${SSH_DIR}/id_ed25519"

# node_ssh CMD — run CMD on the SNO node as 'core'. The node's host key
# changes on every rebuild, so this deliberately does not use known_hosts.
node_ssh() {
  [[ -r "${NODE_KEY}" ]] || return 1
  ssh -i "${NODE_KEY}" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR \
      "core@${VM_IP}" "$@"
}

# prepare_failures — how many times the node failed to generate the install
# config. Prints 0 while the node is still booting (ssh not up yet).
prepare_failures() {
  local n
  n="$(node_ssh 'sudo journalctl -u assisted-service --no-pager 2>/dev/null \
        | grep -ac "Failed to prepare installation"' 2>/dev/null)" || n=0
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "${n}"
}

# dump_node_diagnostics — the guest-side reason a wait failed. Without this
# the operator gets only the installer's opaque timeout message.
dump_node_diagnostics() {
  if ! node_ssh true 2>/dev/null; then
    warn "node ${VM_IP} unreachable over ssh — inspect the console instead:"
    warn "  virsh -c qemu:///system domdisplay ${VM_NAME}"
    return
  fi
  log "agent-phase diagnostics from ${VM_IP}:"
  {
    printf -- '----- assisted-service errors -----\n'
    node_ssh 'sudo journalctl -u assisted-service --no-pager 2>/dev/null \
      | grep -aE "level=(error|warning)" | grep -avE "msg=.Request:" \
      | tail -25' 2>/dev/null || printf '(none — the agent phase is already over)\n'
    printf -- '-----------------------------------\n'
  } >&2
}

# --- bootstrap ----------------------------------------------------------------
log "waiting for bootstrap-complete (VM installs SCOS, reboots, bootstraps the control plane)…"
openshift-install --dir "${INSTALL_DIR}" agent wait-for bootstrap-complete --log-level=info &
bootstrap_pid=$!

# assisted-service retries 'openshift-install create manifests' forever when
# it cannot generate the install config — e.g. a truncated binary in its
# installer cache, which segfaults on every attempt. Left alone, the wait
# above would sit through its whole deadline for a failure visible in minutes.
while kill -0 "${bootstrap_pid}" 2>/dev/null; do
  sleep "${NODE_POLL_SECONDS}"
  kill -0 "${bootstrap_pid}" 2>/dev/null || break
  fails="$(prepare_failures)"
  if [[ "${fails}" -ge "${PREPARE_FAIL_LIMIT}" ]]; then
    warn "node failed to prepare the installation ${fails} times — not waiting out the deadline"
    kill "${bootstrap_pid}" 2>/dev/null || true
    wait "${bootstrap_pid}" 2>/dev/null || true
    dump_node_diagnostics
    die "agent install is looping on a failed prepare step (see above); 'just okd-teardown && just okd-install' rebuilds the VM with clean state"
  fi
done

if ! wait "${bootstrap_pid}"; then
  dump_node_diagnostics
  die "bootstrap-complete failed — see the diagnostics above and ${INSTALL_DIR}/.openshift_install.log"
fi

# --- install ------------------------------------------------------------------
log "bootstrap complete — waiting for install-complete (operators rolling out)…"
if ! openshift-install --dir "${INSTALL_DIR}" agent wait-for install-complete --log-level=info; then
  dump_node_diagnostics
  die "install-complete failed — see the diagnostics above and ${INSTALL_DIR}/.openshift_install.log"
fi

log "cluster installed"
log "  console:            ${CONSOLE_URL}"
log "  kubeadmin password: ${KUBEADMIN_PASSWORD_FILE}"
log "  kubeconfig:         ${ADMIN_KUBECONFIG}"
log "next: 'just okd-postinstall' (storage class + developer user), then 'just okd-verify'"
