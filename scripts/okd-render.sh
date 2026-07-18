#!/usr/bin/env bash
# okd-render.sh — render install-config.yaml and agent-config.yaml from the
# committed templates and assemble a fresh install directory for
# `openshift-install agent create image`.
#
# Rendered copies are kept in okd/state/render/ for reference, because
# openshift-install consumes (deletes) the ones in the install dir.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd envsubst ssh-keygen

if vm_exists; then
  die "VM '${VM_NAME}' already exists — a cluster is (or was) running. 'just okd-teardown' first."
fi

# --- SSH key for core@node debugging access ----------------------------------
if [[ -z "${SSH_PUB_KEY_FILE}" ]]; then
  SSH_PUB_KEY_FILE="${SSH_DIR}/id_ed25519.pub"
  if [[ ! -f "${SSH_PUB_KEY_FILE}" ]]; then
    mkdir -p "${SSH_DIR}"
    ssh-keygen -q -t ed25519 -N '' -C 'miniChRIS-OKD harness' -f "${SSH_DIR}/id_ed25519"
    log "generated debug SSH keypair at ${SSH_DIR}/id_ed25519"
  fi
fi
[[ -r "${SSH_PUB_KEY_FILE}" ]] || die "SSH_PUB_KEY_FILE not readable: ${SSH_PUB_KEY_FILE}"
SSH_PUB_KEY="$(cat "${SSH_PUB_KEY_FILE}")"
export SSH_PUB_KEY

# --- render ------------------------------------------------------------------
render_template "${REPO_ROOT}/okd/install-config.yaml.tpl" "${RENDER_DIR}/install-config.yaml"
render_template "${REPO_ROOT}/okd/agent-config.yaml.tpl" "${RENDER_DIR}/agent-config.yaml"

rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cp "${RENDER_DIR}/install-config.yaml" "${RENDER_DIR}/agent-config.yaml" "${INSTALL_DIR}/"

log "rendered install configs for cluster '${CLUSTER_NAME}.${BASE_DOMAIN}' (mode: ${ACCESS_MODE})"
log "  api:     ${API_URL}"
log "  apps:    *.${APPS_DOMAIN}"
log "  install: ${INSTALL_DIR}"
