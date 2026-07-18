#!/usr/bin/env bash
# okd-wait.sh — follow the unattended agent install to completion:
# bootstrap-complete (SCOS installed, control plane bootstrapping), then
# install-complete (cluster operators rolled out). Expect 45–70 minutes
# total. Safe to re-run if interrupted or timed out.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd openshift-install
[[ -d "${INSTALL_DIR}" ]] || die "no install dir at ${INSTALL_DIR} — run okd-render/okd-create-iso first"

log "waiting for bootstrap-complete (VM installs SCOS, reboots, bootstraps the control plane)…"
openshift-install --dir "${INSTALL_DIR}" agent wait-for bootstrap-complete --log-level=info

log "bootstrap complete — waiting for install-complete (operators rolling out)…"
openshift-install --dir "${INSTALL_DIR}" agent wait-for install-complete --log-level=info

log "cluster installed"
log "  console:            ${CONSOLE_URL}"
log "  kubeadmin password: ${KUBEADMIN_PASSWORD_FILE}"
log "  kubeconfig:         ${ADMIN_KUBECONFIG}"
log "next: 'just okd-postinstall' (storage class + developer user), then 'just okd-verify'"
