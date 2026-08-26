#!/usr/bin/env bash
# chris-deploy.sh — deploy minimal ChRIS onto the OKD cluster (issue #130):
#
#   1. ImageTagMirrorSet docker.io/bitnami -> bitnamilegacy (see
#      chris/bitnami-mirror.yaml; without it every Bitnami pull 404s).
#   2. Project ${CHRIS_NAMESPACE} via 'oc adm new-project' (OpenShift
#      projects carry annotations Helm must not create).
#   3. helm upgrade --install fnndsc/chris at the pinned version with the
#      committed OKD values; host-specific values (Route host, RWO node
#      pin) injected here so chris/values-okd.yaml stays host-agnostic.
#   4. Wait for heart (migrations/provisioning gate), then everything else.
#
# Idempotent; re-running is a Helm upgrade.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib/chris.sh"

require_cmd oc helm jq
require_live_cluster

HEART_TIMEOUT=30m     # first run pulls every image and runs DB migrations
ROLLOUT_TIMEOUT=15m
MIRROR_SETTLE_TIMEOUT=600s

# --- 1. bitnami -> bitnamilegacy tag mirror -----------------------------------
mirror_result="$(admin_oc apply -f "${REPO_ROOT}/chris/bitnami-mirror.yaml")"
log "${mirror_result}"
if [[ "${mirror_result}" != *unchanged ]]; then
  log "waiting for the node's registry config to converge (no reboot involved)"
  # Catch the Updating=True edge if the machine-config operator reacts within
  # the window, then wait for it to settle. If MCO is slower than this, the
  # worst case is bounded anyway: first bitnami pulls 404 and kubelet's pull
  # backoff retries them after the mirror lands.
  admin_oc wait mcp master --for=condition=Updating=True --timeout=120s >/dev/null 2>&1 || true
  admin_oc wait mcp master --for=condition=Updating=False \
    --timeout="${MIRROR_SETTLE_TIMEOUT}" >/dev/null
fi

# --- 2. project ---------------------------------------------------------------
if ! admin_oc get namespace "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
  admin_oc adm new-project "${CHRIS_NAMESPACE}" \
    --description="ChRIS deployed by miniChRIS-OKD" >/dev/null
  log "project '${CHRIS_NAMESPACE}' created"
fi

# --- 3. helm install/upgrade --------------------------------------------------
node="$(admin_oc get nodes -o jsonpath='{.items[0].metadata.name}')"
helm_c repo add fnndsc https://fnndsc.github.io/charts --force-update >/dev/null

log "installing fnndsc/chris ${CHRIS_CHART_VERSION} as '${CHRIS_RELEASE}'"
log "  route: https://${CUBE_HOST}   node pin: ${node}"
helm_c upgrade --install "${CHRIS_RELEASE}" fnndsc/chris \
  --version "${CHRIS_CHART_VERSION}" \
  --namespace "${CHRIS_NAMESPACE}" \
  --values "${REPO_ROOT}/chris/values-okd.yaml" \
  --set-string "route.host=${CUBE_HOST}" \
  --set-string 'pfcon.nodeSelector.kubernetes\.io/hostname='"${node}" \
  --set-string "pfcon.pman.extraEnv.NODE_SELECTOR=kubernetes.io/hostname=${node}"

# --- 4. wait for readiness ----------------------------------------------------
log "waiting for heart (image pulls + DB migrations; first run takes a while)"
chris_oc rollout status "deploy/${CHRIS_RELEASE}-heart" --timeout="${HEART_TIMEOUT}"
for component in server worker-mains worker-periodic pfcon; do
  chris_oc rollout status "deploy/${CHRIS_RELEASE}-${component}" --timeout="${ROLLOUT_TIMEOUT}"
done
# Postgres/RabbitMQ are implicitly gated by heart's init containers; NATS is
# not gated by anything, so check all three explicitly.
for subchart in postgresql rabbitmq nats; do
  chris_oc rollout status "sts/${CHRIS_RELEASE}-${subchart}" --timeout="${ROLLOUT_TIMEOUT}"
done

log "ChRIS deployed"
log "  CUBE API:  ${CUBE_URL}"
log "  superuser: ${CHRIS_SUPERUSER} / $(chris_secret_value "${CHRIS_BACKEND_SECRET}" CHRIS_SUPERUSER_PASSWORD)"
log "next: 'just chris-seed'"
