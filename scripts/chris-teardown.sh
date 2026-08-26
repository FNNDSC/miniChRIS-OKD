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
# Teardown must work on a cluster that is itself unwell — that is often
# exactly why it is being run — so under --nuke every step before the project
# delete is best-effort: deleting the project removes the release and
# everything it created regardless. Only the project delete is fatal.
#
# Non-interactive when stdin is not a TTY (CI); otherwise asks once.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib/chris.sh"

require_cmd oc helm jq
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

# A stale cluster cannot really delete anything, but tearing down is a
# reasonable thing to attempt anyway — say what is wrong and carry on.
warn_unless_live_cluster

target="Helm release '${CHRIS_RELEASE}' + seeding resources"
[[ "${NUKE}" == true ]] && target="${target}, ALL PVCs, project '${CHRIS_NAMESPACE}', and the bitnami mirror"
confirm "Remove ${target}?" || die "aborted"

# best_effort WHAT CMD... — run CMD (stdout suppressed). Under --nuke a
# failure is a warning rather than the end of the run, because the project
# delete supersedes every step it guards; in default mode failures stay fatal.
# Always returns 0 so it is safe as a bare statement under set -e — which is
# why CMD, not the caller, reports its own success.
best_effort() {
  local what="$1"; shift
  "$@" >/dev/null && return 0
  [[ "${NUKE}" == true ]] \
    || die "${what} failed — 'just chris-nuke' removes the release by deleting the whole project"
  warn "${what} failed — continuing; deleting project '${CHRIS_NAMESPACE}' supersedes it"
}

# helm_uninstall_release — uninstall, surfacing why when it fails. Helm
# reports only "failed to delete release: <name>" and hides the underlying
# errors (an unresolvable kind, a failing API group) behind --debug, so name
# that command rather than leaving one useless line as the whole diagnosis.
helm_uninstall_release() {
  local status=0
  # Straight to stderr rather than captured: --wait can take a while, and
  # buffering helm's progress until it finishes looks like a hang. stderr
  # also survives best_effort's stdout suppression.
  helm_c uninstall "${CHRIS_RELEASE}" -n "${CHRIS_NAMESPACE}" --wait >&2 || status=$?
  if [[ ${status} -eq 0 ]]; then
    log "release '${CHRIS_RELEASE}' uninstalled"
  else
    warn "helm hides the underlying error behind --debug; to see it, run:"
    warn "  helm uninstall ${CHRIS_RELEASE} -n ${CHRIS_NAMESPACE} --debug"
  fi
  return "${status}"
}

# release_state — installed | absent | unknown. helm reports "no such release"
# and "could not talk to the cluster" the same way (non-zero), and reading the
# second as "nothing to uninstall" is exactly the misdiagnosis that made the
# 2026-08-26 incident so confusing — so tell them apart.
release_state() {
  local out
  if out="$(helm_c status "${CHRIS_RELEASE}" -n "${CHRIS_NAMESPACE}" 2>&1)"; then
    printf installed
  elif grep -qi 'release: not found' <<<"${out}"; then
    printf absent
  else
    printf unknown
  fi
}

# report_unqueryable_release — used as a best_effort target so an unanswerable
# helm gets the same warn-under-nuke / die-otherwise treatment as a failure.
report_unqueryable_release() {
  warn "helm could not report on release '${CHRIS_RELEASE}' — the cluster may be unwell ('just okd-doctor')"
  return 1
}

# delete_all_pvcs — reports its own success, like helm_uninstall_release, so
# best_effort never has to claim an outcome on a step's behalf.
delete_all_pvcs() {
  # --wait=false: mark every PVC for deletion and let the project delete below
  # do the waiting once. Blocking here too would double the timeout for no
  # gain, and would stall for minutes whenever pods are still mounting.
  chris_oc delete pvc --all --wait=false >/dev/null || return 1
  log "PVCs marked for deletion (they go with the project)"
}

if admin_oc get namespace "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
  case "$(release_state)" in
    installed) best_effort "uninstalling release '${CHRIS_RELEASE}'" helm_uninstall_release ;;
    absent)    log "release '${CHRIS_RELEASE}' not installed — nothing to uninstall" ;;
    unknown)   best_effort "querying release '${CHRIS_RELEASE}'" report_unqueryable_release ;;
  esac
  best_effort "deleting the seed Job" chris_oc delete job "${SEED_JOB}" --ignore-not-found
  best_effort "deleting the seed Secret" chris_oc delete secret "${SEED_CONFIG_SECRET}" --ignore-not-found
else
  log "project '${CHRIS_NAMESPACE}' not found — nothing to uninstall"
fi

if [[ "${NUKE}" != true ]]; then
  log "teardown complete (PVCs and project kept — 'just chris-nuke' removes them)"
  exit 0
fi

# --- nuke: plugin-instance jobs, PVCs, project --------------------------------
if admin_oc get namespace "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
  # In-flight plugin jobs keep the storebase PVC mounted; remove them first so
  # PVC deletion cannot stall on the pvc-protection finalizer.
  chris_oc delete jobs -l chrisproject.org/job=plugininstance >/dev/null 2>&1 || true
  best_effort "deleting PVCs" delete_all_pvcs

  # The authority: this removes the release secret, every workload, and any
  # PVC the step above could not. Waiting for full termination lets an
  # immediate chris-deploy recreate the project cleanly.
  admin_oc delete namespace "${CHRIS_NAMESPACE}" --timeout=300s >/dev/null \
    || die "could not delete project '${CHRIS_NAMESPACE}' — the cluster itself is unwell; try 'just okd-doctor'"
  log "project '${CHRIS_NAMESPACE}' deleted"
fi

best_effort "deleting the bitnami tag mirror" \
  admin_oc delete imagetagmirrorset minichris-bitnami-legacy --ignore-not-found
# The rendered seeder config embeds superuser/pfcon/test-user credentials —
# it must not outlive the deployment it belongs to.
rm -f "${CHRIS_TEST_PASSWORD_FILE}" "${RENDER_DIR}/chrisomatic.yml" "${RENDER_DIR}/seed-job.yaml"
log "chris-nuke complete — 'just chris-deploy' starts from a clean project"
