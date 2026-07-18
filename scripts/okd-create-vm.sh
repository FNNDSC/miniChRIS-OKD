#!/usr/bin/env bash
# okd-create-vm.sh — create and boot the SNO VM from the agent ISO.
#
# Boot order is disk-then-cdrom: the empty disk falls through to the ISO on
# first boot; the agent installer writes SCOS to disk and reboots into it.
# The install then proceeds unattended — follow it with okd-wait.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd virt-install virsh

ISO="${INSTALL_DIR}/agent.x86_64.iso"
[[ -f "${ISO}" ]] || die "agent ISO not found at ${ISO} — run okd-create-iso first"
vm_exists && die "VM '${VM_NAME}' already exists — 'just okd-teardown' first"

DISK="${IMAGES_DIR}/${VM_NAME}.qcow2"
[[ -e "${DISK}" ]] && die "stale disk image at ${DISK} — 'just okd-teardown' cleans it up"
mkdir -p "${IMAGES_DIR}"

create_vm() {
  virt-install \
    --connect qemu:///system \
    --name "${VM_NAME}" \
    --memory "${VM_RAM_MIB}" \
    --vcpus "${VM_VCPUS}" \
    --cpu host-passthrough \
    --osinfo "$1" \
    --disk "path=${DISK},size=${VM_DISK_GB},format=qcow2,bus=virtio,cache=none,discard=unmap" \
    --disk "path=${ISO},device=cdrom,readonly=on" \
    --network "network=${VM_NET_NAME},mac=${VM_MAC},model=virtio" \
    --graphics vnc,listen=127.0.0.1 \
    --boot hd,cdrom \
    --import \
    --autostart \
    --noautoconsole
}

log "creating VM '${VM_NAME}' (${VM_VCPUS} vCPU, ${VM_RAM_MIB} MiB, ${VM_DISK_GB} GB)"
if ! create_vm "${VM_OS_VARIANT}"; then
  warn "virt-install failed with --osinfo ${VM_OS_VARIANT}; retrying with 'generic'"
  create_vm generic
fi

log "VM booted from the agent ISO — install proceeds unattended"
log "  watch:   just okd-wait"
log "  console: virsh -c qemu:///system domdisplay ${VM_NAME}  (VNC, via SSH tunnel)"
