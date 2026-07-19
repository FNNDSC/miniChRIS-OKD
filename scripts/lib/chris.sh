# shellcheck shell=bash
# scripts/lib/chris.sh — Phase 2 (issue #130) shared plumbing: derived ChRIS
# values and helpers on top of lib/common.sh.
#
# Source lib/common.sh first, then this file; do not execute directly.

# Chart resource names below assume every chart "fullname" collapses to the
# release name. The parent chart collapses when the release name contains
# "chris"; each subchart collapses when the release name contains ITS name
# (e.g. release 'chris-nats' would name the NATS StatefulSet 'chris-nats',
# not 'chris-nats-nats') — so require the former and reject the latter.
[[ "${CHRIS_RELEASE}" == *chris* ]] \
  || die "CHRIS_RELEASE must contain 'chris' (got '${CHRIS_RELEASE}'); chart resource names depend on it"
for _subchart in pfcon postgresql rabbitmq nats; do
  [[ "${CHRIS_RELEASE}" != *"${_subchart}"* ]] \
    || die "CHRIS_RELEASE must not contain subchart name '${_subchart}' (got '${CHRIS_RELEASE}'); it would change that subchart's resource names"
done
unset _subchart

# --- CUBE endpoints -----------------------------------------------------------
CUBE_HOST="cube.${APPS_DOMAIN}"                # OpenShift Route host
CUBE_URL="https://${CUBE_HOST}/api/v1/"
# In-cluster endpoint (bypasses the Route) used for seeding.
CUBE_INTERNAL_URL="http://${CHRIS_RELEASE}-server.${CHRIS_NAMESPACE}.svc:8000/api/v1/"

# --- chart-created resources --------------------------------------------------
CHRIS_SUPERUSER=chris                          # username is fixed by the chart
CHRIS_BACKEND_SECRET="${CHRIS_RELEASE}-chris-backend"   # CHRIS_SUPERUSER_PASSWORD
PFCON_SECRET="${CHRIS_RELEASE}-pfcon"                   # PFCON_USER / PFCON_PASSWORD
# Compute-resource identity: name/description must mirror the chart's
# .Values.pfcon.name / .Values.pfcon.description defaults; the URL is the
# pfcon subchart's Service. chris-seed.sh reads the matching credentials
# from PFCON_SECRET at seed time.
PFCON_NAME=innetwork
PFCON_DESCRIPTION="Kubernetes cluster compute resource"
PFCON_URL="http://${CHRIS_RELEASE}-pfcon.${CHRIS_NAMESPACE}.svc:5005/api/v1/"

# --- harness-created seeding resources ----------------------------------------
SEED_JOB="${CHRIS_RELEASE}-seed"
SEED_CONFIG_SECRET="${CHRIS_RELEASE}-seed-config"
CHRIS_TEST_PASSWORD_FILE="${AUTH_DIR}/chris-test-user-password"

export CUBE_HOST CUBE_URL CUBE_INTERNAL_URL

# helm_c ARGS... — helm against the cluster as admin. Pins the installer's
# 'admin' context for the same reason admin_oc does.
helm_c() { KUBECONFIG="${ADMIN_KUBECONFIG}" helm --kube-context admin "$@"; }

# chris_oc ARGS... — admin oc scoped to the ChRIS namespace.
chris_oc() { admin_oc -n "${CHRIS_NAMESPACE}" "$@"; }

# chris_secret_value SECRET KEY — decoded value of one key in a namespace secret.
chris_secret_value() { chris_oc get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }

# require_chris_release — die unless the Helm release is installed.
require_chris_release() {
  helm_c status "${CHRIS_RELEASE}" -n "${CHRIS_NAMESPACE}" >/dev/null 2>&1 \
    || die "Helm release '${CHRIS_RELEASE}' not found in '${CHRIS_NAMESPACE}' (run 'just chris-deploy')"
}
