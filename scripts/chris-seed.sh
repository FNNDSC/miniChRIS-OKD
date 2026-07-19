#!/usr/bin/env bash
# chris-seed.sh — seed the deployed ChRIS with everything the smoke test
# needs, via a chrisomatic Job (the project-standard declarative seeder):
#
#   - non-admin test user ${CHRIS_TEST_USER} (password generated once into
#     okd/state/auth/, like the cluster's developer user)
#   - plugins pl-dircopy + pl-simpledsapp on the in-cluster compute resource
#
# The chart's heart pod already registers the compute resource and CUBE's
# hard-dependency plugins; chrisomatic re-declares them with the same
# chart-generated credentials, so the rendered chrisomatic.yml is the full
# description of the seeded state. Idempotent; safe to re-run.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib/chris.sh"

require_cmd oc envsubst openssl
require_cluster
require_chris_release

SEED_TIMEOUT=900  # seconds; also rendered into the Job's activeDeadlineSeconds

umask 077  # credential-bearing files below must never be world-readable

# Seeding needs a ready CUBE (no-op when chris-deploy just waited for it).
chris_oc rollout status "deploy/${CHRIS_RELEASE}-heart" --timeout=10m >/dev/null

# --- credentials --------------------------------------------------------------
mkdir -p "${AUTH_DIR}"
chmod 700 "${AUTH_DIR}"
if [[ ! -f "${CHRIS_TEST_PASSWORD_FILE}" ]]; then
  openssl rand -base64 16 >"${CHRIS_TEST_PASSWORD_FILE}"
  log "generated ${CHRIS_TEST_USER} password → ${CHRIS_TEST_PASSWORD_FILE}"
fi

# PFCON_NAME / PFCON_DESCRIPTION / PFCON_URL come from scripts/lib/chris.sh.
export CHRIS_SUPERUSER SEED_TIMEOUT
export CHRIS_SUPERUSER_PASSWORD CHRIS_TEST_PASSWORD \
  PFCON_NAME PFCON_URL PFCON_USER PFCON_PASSWORD PFCON_DESCRIPTION
CHRIS_SUPERUSER_PASSWORD="$(chris_secret_value "${CHRIS_BACKEND_SECRET}" CHRIS_SUPERUSER_PASSWORD)"
CHRIS_TEST_PASSWORD="$(cat "${CHRIS_TEST_PASSWORD_FILE}")"
PFCON_USER="$(chris_secret_value "${PFCON_SECRET}" PFCON_USER)"
PFCON_PASSWORD="$(chris_secret_value "${PFCON_SECRET}" PFCON_PASSWORD)"

# --- render config + job ------------------------------------------------------
render_template "${REPO_ROOT}/chris/chrisomatic.yml.tpl" "${RENDER_DIR}/chrisomatic.yml"
render_template "${REPO_ROOT}/chris/seed-job.yaml.tpl" "${RENDER_DIR}/seed-job.yaml"

# --- run the Job --------------------------------------------------------------
chris_oc create secret generic "${SEED_CONFIG_SECRET}" \
  --from-file="chrisomatic.yml=${RENDER_DIR}/chrisomatic.yml" \
  --dry-run=client -o yaml | chris_oc apply -f - >/dev/null
chris_oc delete job "${SEED_JOB}" --ignore-not-found >/dev/null
chris_oc apply -f "${RENDER_DIR}/seed-job.yaml" >/dev/null
log "chrisomatic running against ${CUBE_INTERNAL_URL}"

deadline=$((SECONDS + SEED_TIMEOUT))
while :; do
  succeeded="$(chris_oc get job "${SEED_JOB}" -o jsonpath='{.status.succeeded}')"
  failed="$(chris_oc get job "${SEED_JOB}" -o jsonpath='{.status.failed}')"
  [[ "${succeeded:-0}" -ge 1 ]] && break
  if [[ "${failed:-0}" -ge 1 || ${SECONDS} -ge ${deadline} ]]; then
    warn "seed job did not succeed — diagnostics follow"
    chris_oc get pods -l "job-name=${SEED_JOB}" >&2 || true
    chris_oc logs "job/${SEED_JOB}" --tail=200 >&2 || true
    die "seeding failed (re-run with 'just chris-seed'; config: ${RENDER_DIR}/chrisomatic.yml)"
  fi
  sleep 5
done

# The chrisomatic log is the record of what was seeded.
chris_oc logs "job/${SEED_JOB}"

log "seeding complete"
log "  test user: ${CHRIS_TEST_USER} / ${CHRIS_TEST_PASSWORD}"
log "  CUBE API:  ${CUBE_URL}"
log "next: 'just smoke' (Phase 3)"
