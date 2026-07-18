#!/usr/bin/env bash
# okd-download.sh — fetch the pinned openshift-install and oc client binaries
# from the OKD GitHub release into okd/state/bin/, verifying sha256 checksums
# against the release's sha256sum.txt. Skips work if the pinned versions are
# already in place.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd curl tar sha256sum

RELEASE_URL="https://github.com/okd-project/okd/releases/download/${OKD_VERSION}"
CLIENT_TAR="openshift-client-linux-${OKD_VERSION}.tar.gz"
INSTALL_TAR="openshift-install-linux-${OKD_VERSION}.tar.gz"

# has_pinned_version BIN — true if the binary exists and reports OKD_VERSION.
has_pinned_version() {
  [[ -x "${BIN_DIR}/$1" ]] || return 1
  case "$1" in
    oc) "${BIN_DIR}/oc" version --client 2>/dev/null | grep -qF "${OKD_VERSION}" ;;
    openshift-install) "${BIN_DIR}/openshift-install" version 2>/dev/null | grep -qF "${OKD_VERSION}" ;;
  esac
}

if has_pinned_version oc && has_pinned_version openshift-install; then
  log "oc and openshift-install ${OKD_VERSION} already in ${BIN_DIR} — nothing to do"
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

log "downloading ${OKD_VERSION} release binaries (client + installer)"
for asset in "${CLIENT_TAR}" "${INSTALL_TAR}" sha256sum.txt; do
  curl -fSL --retry 3 -o "${workdir}/${asset}" "${RELEASE_URL}/${asset}"
done

log "verifying sha256 checksums"
(cd "${workdir}" && grep -E "(${CLIENT_TAR}|${INSTALL_TAR})\$" sha256sum.txt | sha256sum -c --quiet -)

mkdir -p "${BIN_DIR}"
tar -xzf "${workdir}/${CLIENT_TAR}" -C "${BIN_DIR}" oc kubectl
tar -xzf "${workdir}/${INSTALL_TAR}" -C "${BIN_DIR}" openshift-install
chmod +x "${BIN_DIR}/oc" "${BIN_DIR}/kubectl" "${BIN_DIR}/openshift-install"

log "installed $("${BIN_DIR}/openshift-install" version | head -1) → ${BIN_DIR}"
