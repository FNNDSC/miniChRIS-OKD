#!/usr/bin/env bash
# host-setup.sh — install everything the harness needs on an apt-based
# Linux host: the libvirt/KVM stack, virt-install, envsubst, jq, just,
# helm (Phase 2), and haproxy (lan mode only). Idempotent; safe to re-run.
#
# The pinned oc/openshift-install binaries are NOT installed here — they
# come from the OKD release via scripts/okd-download.sh (part of
# `just okd-install`), so the version pin lives in exactly one place.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

[[ "$(uname -s)" == Linux ]] || die "host-setup must run on the Linux harness host (this is $(uname -s))"
command -v apt-get >/dev/null 2>&1 \
  || die "only apt-based distros are automated; install the packages listed in docs/requirements.md manually"

SUDO="sudo"
[[ ${EUID} -eq 0 ]] && SUDO=""

packages=(
  libvirt-daemon-system  # system libvirt daemon (qemu:///system)
  libvirt-clients        # virsh
  virtinst               # virt-install
  qemu-system-x86        # KVM/QEMU
  qemu-utils             # qemu-img
  gettext-base           # envsubst
  bind9-dnsutils         # dig (net-setup DNS assertions)
  python3-venv           # smoke test virtualenv (Phase 3, scripts/smoke.sh)
  jq
  curl
)
[[ "${ACCESS_MODE}" == lan ]] && packages+=(haproxy)

log "installing apt packages: ${packages[*]}"
${SUDO} apt-get update -q
${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${packages[@]}"

# just: in Ubuntu's universe repo since 24.04; fall back to the official
# prebuilt-binary installer.
if ! command -v just >/dev/null 2>&1; then
  log "installing just"
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y -q just \
    || curl --proto '=https' --tlsv1.2 -fsSL https://just.systems/install.sh \
       | ${SUDO} bash -s -- --to /usr/local/bin
fi

# helm: needed by Phase 2 (issue #130); official installer script.
if ! command -v helm >/dev/null 2>&1; then
  log "installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

log "enabling libvirt daemon"
${SUDO} systemctl enable --now libvirtd

if ! id -nG "${USER}" | grep -qw libvirt; then
  ${SUDO} usermod -aG libvirt "${USER}"
  warn "added ${USER} to the 'libvirt' group — start a new login session (or 'newgrp libvirt') before 'just okd-install'"
fi

log "host setup complete — next: 'just host-check'"
