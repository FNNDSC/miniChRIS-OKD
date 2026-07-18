#!/usr/bin/env bash
# okd-create-iso.sh — generate the agent installer ISO from the rendered
# configs. First run downloads the SCOS boot image (several GiB, cached
# under ~/.cache/agent/).

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd openshift-install oc jq

[[ -f "${INSTALL_DIR}/install-config.yaml" && -f "${INSTALL_DIR}/agent-config.yaml" ]] \
  || die "no rendered configs in ${INSTALL_DIR} — run 'just render' (okd-render) first"

ISO="${INSTALL_DIR}/agent.x86_64.iso"
if [[ -f "${ISO}" ]]; then
  log "agent ISO already present: ${ISO}"
  exit 0
fi

# OKD quirk: the release digest embedded in openshift-install is a
# multi-arch manifest list (amd64+arm64), but the installer's release
# metadata declares x86_64 only. On the node, the agent's register client
# inspects the list and requests cpu_architecture=multi, which
# assisted-service then rejects against its x86_64-only RELEASE_IMAGES
# entry — cluster registration loops forever ("release image ... does not
# support requested CPU architecture multi"). Pinning the override to the
# amd64 child digest makes both sides agree on x86_64.
# See docs/troubleshooting.md ("cluster registration loops").
release_image="$(openshift-install version | awk '/release image/ {print $3}')"
amd64_digest="$(oc image info --filter-by-os linux/amd64 -o json "${release_image}" | jq -r '.digest')"
[[ -n "${amd64_digest}" ]] || die "could not resolve the amd64 digest of ${release_image}"
if [[ "${release_image}" != *"${amd64_digest}"* ]]; then
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${release_image%%@*}@${amd64_digest}"
  log "release image is a multi-arch list — pinning amd64 child: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
fi

log "creating agent ISO (downloads the SCOS boot image on first run — be patient)"
openshift-install agent create image --dir "${INSTALL_DIR}" --log-level=info

[[ -f "${ISO}" ]] || die "openshift-install finished but ${ISO} is missing"
log "agent ISO ready: ${ISO}"
