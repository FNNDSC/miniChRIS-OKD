#!/usr/bin/env bash
# chris-status.sh — read-only picture of the ChRIS deployment.
#
#   (default) : release, pods, storage, route, seed job, URLs + credentials
#   url       : just the CUBE URL (for scripting)
#   open      : print the CUBE URL and open it when a GUI opener exists

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib/chris.sh"

case "${1:-}" in
  url)
    echo "${CUBE_URL}"
    exit 0
    ;;
  open)
    echo "${CUBE_URL}"
    for opener in open xdg-open; do  # macOS, Linux
      command -v "${opener}" >/dev/null 2>&1 && exec "${opener}" "${CUBE_URL}"
    done
    exit 0
    ;;
esac

require_cmd oc helm
require_cluster

if ! admin_oc get namespace "${CHRIS_NAMESPACE}" >/dev/null 2>&1; then
  die "project '${CHRIS_NAMESPACE}' not found — run 'just chris-deploy'"
fi

echo "release:"
helm_c list -n "${CHRIS_NAMESPACE}" --filter "^${CHRIS_RELEASE}\$"
echo
echo "pods:"
chris_oc get pods
echo
echo "storage:"
chris_oc get pvc
echo
echo "routes:"
chris_oc get routes
echo
echo "seed job:"
chris_oc get job "${SEED_JOB}" 2>/dev/null || echo "  (not run yet — 'just chris-seed')"
echo
echo "cube api:   ${CUBE_URL}"
if password="$(chris_secret_value "${CHRIS_BACKEND_SECRET}" CHRIS_SUPERUSER_PASSWORD 2>/dev/null)"; then
  echo "superuser:  ${CHRIS_SUPERUSER} / ${password}"
fi
if [[ -f "${CHRIS_TEST_PASSWORD_FILE}" ]]; then
  echo "test user:  ${CHRIS_TEST_USER} / $(cat "${CHRIS_TEST_PASSWORD_FILE}")"
else
  echo "test user:  (not seeded yet — 'just chris-seed')"
fi
