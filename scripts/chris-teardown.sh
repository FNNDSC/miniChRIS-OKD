#!/usr/bin/env bash
# chris-teardown.sh — remove the ChRIS deployment.
#
#   default : helm uninstall + seeding Job/Secret. Keeps the PVCs (Bitnami
#             StatefulSet PVCs survive uninstall by design — data outlives
#             the release) and the project; 'just chris-deploy' reuses both.
#   --nuke  : also delete leftover plugin-instance jobs, all PVCs, the
#             project, the bitnami tag mirror, and the generated test-user
#             password — back to a ChRIS-free cluster.
#
# Non-interactive when stdin is not a TTY (CI); otherwise asks once.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib/chris.sh"

require_cmd oc helm
require_cluster

NUKE=false
for arg in "$@"; do
  # shellcheck disable=SC2034  # CONFIRM is read by confirm() in lib/common.sh
  case "${arg}" in
    --nuke) NUKE=true ;;
    --yes) CONFIRM=yes ;;
    *) die "unknown argument: ${arg} (usage: chris-teardown.sh [--nuke] [--yes])" ;;
  esac
done

target="Helm release '${CHRIS_RELEASE}' + seeding resources"
[[ "${NUKE}" == true ]] && target="${target}, ALL PVCs, project '${CHRIS_NAMESPACE}', and the bitnami mirror"
confirm "Remove ${target}?" || die "aborted"

if admin_oc get namespace "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
  if helm_c status "${CHRIS_RELEASE}" -n "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
    helm_c uninstall "${CHRIS_RELEASE}" -n "${CHRIS_NAMESPACE}" --wait
    log "release '${CHRIS_RELEASE}' uninstalled"
  else
    log "release '${CHRIS_RELEASE}' not installed — nothing to uninstall"
  fi
  chris_oc delete job "${SEED_JOB}" --ignore-not-found >/dev/null
  chris_oc delete secret "${SEED_CONFIG_SECRET}" --ignore-not-found >/dev/null
else
  log "project '${CHRIS_NAMESPACE}' not found — nothing to uninstall"
fi

if [[ "${NUKE}" != true ]]; then
  log "teardown complete (PVCs and project kept — 'just chris-nuke' removes them)"
  exit 0
fi

# --- nuke: plugin-instance jobs, PVCs, project --------------------------------
if admin_oc get namespace "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
  # In-flight plugin jobs keep the storebase PVC mounted; remove them first
  # so the PVC delete below cannot hang on the pvc-protection finalizer.
  chris_oc delete jobs -l chrisproject.org/job=plugininstance >/dev/null 2>&1 || true
  chris_oc delete pvc --all --timeout=300s >/dev/null
  log "PVCs deleted"
  # Wait for full termination so an immediate chris-deploy can recreate it.
  admin_oc delete namespace "${CHRIS_NAMESPACE}" --timeout=300s >/dev/null
  log "project '${CHRIS_NAMESPACE}' deleted"
fi

admin_oc delete imagetagmirrorset minichris-bitnami-legacy --ignore-not-found >/dev/null
# The rendered seeder config embeds superuser/pfcon/test-user credentials —
# it must not outlive the deployment it belongs to.
rm -f "${CHRIS_TEST_PASSWORD_FILE}" "${RENDER_DIR}/chrisomatic.yml" "${RENDER_DIR}/seed-job.yaml"
log "chris-nuke complete — 'just chris-deploy' starts from a clean project"
