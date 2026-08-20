#!/usr/bin/env bash
# router-ca.sh — extract the cluster's ingress (router) CA certificate so
# clients can verify Route TLS (the harness router cert is self-signed).
#
# Prints the CA file path on stdout for scripting:
#   just smoke uses it as the smoke test's --ca-bundle; LAN clients can scp it.
#
# The default-ingress-cert ConfigMap in openshift-config-managed is published
# by OpenShift for exactly this purpose.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd oc
require_cluster

ROUTER_CA_FILE="${AUTH_DIR}/router-ca.crt"
mkdir -p "${AUTH_DIR}"

admin_oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' >"${ROUTER_CA_FILE}.tmp"
[[ -s "${ROUTER_CA_FILE}.tmp" ]] \
  || { rm -f "${ROUTER_CA_FILE}.tmp"; die "default-ingress-cert ConfigMap is empty or missing"; }
mv "${ROUTER_CA_FILE}.tmp" "${ROUTER_CA_FILE}"

log "ingress CA written (verifies https://*.${APPS_DOMAIN})"
echo "${ROUTER_CA_FILE}"
