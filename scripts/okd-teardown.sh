#!/usr/bin/env bash
# okd-teardown.sh — destroy the cluster.
#
#   default : stop + undefine the VM, delete its disk and the install state
#             (kubeconfig/passwords die with the cluster). Keeps downloaded
#             binaries, the libvirt network, and HAProxy — a following
#             'just okd-install' reuses them.
#   --nuke  : also undefine the libvirt network, restore/stop HAProxy
#             (lan mode), and delete okd/state/ entirely — back to a clean
#             machine.
#
# Non-interactive when stdin is not a TTY (CI); otherwise asks once.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

NUKE=false
for arg in "$@"; do
  case "${arg}" in
    --nuke) NUKE=true ;;
    # shellcheck disable=SC2034  # read by confirm() in lib/common.sh
    --yes) CONFIRM=yes ;;
    *) die "unknown argument: ${arg} (usage: okd-teardown.sh [--nuke] [--yes])" ;;
  esac
done

target="VM '${VM_NAME}' + cluster state"
[[ "${NUKE}" == true ]] && target="${target}, libvirt network, HAProxy config, and ALL of okd/state/"
confirm "Destroy ${target}?" || die "aborted"

# --- VM + disk ----------------------------------------------------------------
if vm_exists; then
  virsh_c destroy "${VM_NAME}" >/dev/null 2>&1 || true
  virsh_c undefine "${VM_NAME}" --nvram >/dev/null 2>&1 || virsh_c undefine "${VM_NAME}" >/dev/null
  log "VM '${VM_NAME}' destroyed and undefined"
else
  log "VM '${VM_NAME}' not defined — nothing to destroy"
fi
rm -f "${IMAGES_DIR}/${VM_NAME}.qcow2"

# --- install state (kubeconfig, ISO, rendered configs for this cluster) --------
rm -rf "${INSTALL_DIR}"
log "install state removed (${INSTALL_DIR})"

[[ "${NUKE}" == true ]] || { log "teardown complete — 'just okd-install' brings up a fresh cluster"; exit 0; }

# --- nuke: libvirt network ------------------------------------------------------
if virsh_c net-info "${VM_NET_NAME}" >/dev/null 2>&1; then
  virsh_c net-destroy "${VM_NET_NAME}" >/dev/null 2>&1 || true
  virsh_c net-undefine "${VM_NET_NAME}" >/dev/null
  log "libvirt network '${VM_NET_NAME}' removed"
fi

# --- nuke: HAProxy (lan mode artifacts, regardless of current ACCESS_MODE) -----
if grep -qs 'miniChRIS-OKD' /etc/haproxy/haproxy.cfg 2>/dev/null; then
  sudo systemctl disable --now haproxy >/dev/null 2>&1 || true
  if [[ -f /etc/haproxy/haproxy.cfg.pre-minichris ]]; then
    sudo mv /etc/haproxy/haproxy.cfg.pre-minichris /etc/haproxy/haproxy.cfg
    log "HAProxy stopped; original config restored"
  else
    log "HAProxy stopped (harness config left in place, service disabled)"
  fi
fi

# --- nuke: all state (binaries, ISO cache in state, ssh keys, reports) ---------
rm -rf "${STATE_DIR}"
log "okd/state/ removed — host is back to a clean slate ('just okd-install' rebuilds everything)"
