#!/usr/bin/env bash
# okd-postinstall.sh — cluster configuration after install-complete:
#
#   1. local-path-provisioner as the default StorageClass (SNO ships none),
#      with the 'privileged' SCC its hostPath helper pods need.
#   2. An htpasswd identity provider with a non-admin 'developer' user —
#      kubeadmin bypasses too much to represent developer reality (developer
#      login + project creation was a requirement).
#
# Idempotent; safe to re-run.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd oc envsubst openssl
require_cluster

DEVELOPER_USER=developer
OAUTH_LOGIN_TIMEOUT=900  # seconds; the oauth stack redeploys after the IdP patch

# --- 1. default StorageClass: local-path-provisioner --------------------------
log "applying local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION} (default StorageClass)"
render_template "${REPO_ROOT}/okd/local-path-storage.yaml.tpl" "${RENDER_DIR}/local-path-storage.yaml"
admin_oc apply -f "${RENDER_DIR}/local-path-storage.yaml"
admin_oc adm policy add-scc-to-user privileged \
  -z local-path-provisioner-service-account -n local-path-storage >/dev/null
admin_oc -n local-path-storage rollout status deployment/local-path-provisioner --timeout=300s

# --- 2. htpasswd identity provider with a 'developer' user --------------------
log "configuring htpasswd identity provider (user: ${DEVELOPER_USER})"
mkdir -p "${AUTH_DIR}"
chmod 700 "${AUTH_DIR}"
if [[ ! -f "${DEVELOPER_PASSWORD_FILE}" ]]; then
  openssl rand -base64 16 >"${DEVELOPER_PASSWORD_FILE}"
  chmod 600 "${DEVELOPER_PASSWORD_FILE}"
  log "generated developer password → ${DEVELOPER_PASSWORD_FILE}"
fi
developer_password="$(cat "${DEVELOPER_PASSWORD_FILE}")"

# apr1 (htpasswd MD5) via openssl: no apache2-utils dependency.
htpasswd_file="${AUTH_DIR}/htpasswd"
printf '%s:%s\n' "${DEVELOPER_USER}" "$(openssl passwd -apr1 "${developer_password}")" >"${htpasswd_file}"
chmod 600 "${htpasswd_file}"

admin_oc create secret generic minichris-htpasswd -n openshift-config \
  --from-file="htpasswd=${htpasswd_file}" \
  --dry-run=client -o yaml | admin_oc apply -f - >/dev/null

admin_oc patch oauth cluster --type merge -p '{
  "spec": {
    "identityProviders": [{
      "name": "minichris-htpasswd",
      "mappingMethod": "claim",
      "type": "HTPasswd",
      "htpasswd": {"fileData": {"name": "minichris-htpasswd"}}
    }]
  }
}' >/dev/null

# The oauth deployment re-rolls after the patch; poll an actual login rather
# than guessing at rollout timing.
log "waiting for '${DEVELOPER_USER}' login to succeed (oauth rollout can take a few minutes)"
rm -f "${DEVELOPER_KUBECONFIG}"
deadline=$((SECONDS + OAUTH_LOGIN_TIMEOUT))
until oc login "${API_URL}" \
    --kubeconfig="${DEVELOPER_KUBECONFIG}" \
    --username="${DEVELOPER_USER}" --password="${developer_password}" \
    --insecure-skip-tls-verify=true >/dev/null 2>&1; do
  [[ ${SECONDS} -lt ${deadline} ]] || die "developer login did not succeed within ${OAUTH_LOGIN_TIMEOUT}s"
  sleep 15
done

# --- 3. let the cluster settle before handing off to okd-verify ---------------
# The IdP patch above re-rolls oauth-openshift (and, transitively, console),
# so the cluster is guaranteed to be mid-rollout right here. The login poll is
# a weaker signal than it looks: 'oc login' starts working as soon as one
# oauth pod serves, well before the authentication operator reports itself
# rolled out. Absorb that churn here rather than leaving okd-verify's
# cluster-operators check to race it (FNNDSC/HARBOR-planning#128).
#
# Advisory: post-install's own work is done either way, and okd-verify is the
# real gate — a slow settle should not fail this step.
log "waiting for cluster operators to settle (period ${CLUSTER_STABLE_PERIOD}, timeout ${CLUSTER_STABLE_TIMEOUT})"
if admin_oc adm wait-for-stable-cluster \
    --minimum-stable-period="${CLUSTER_STABLE_PERIOD}" \
    --timeout="${CLUSTER_STABLE_TIMEOUT}"; then
  log "cluster operators are stable"
else
  warn "operators did not stabilise within ${CLUSTER_STABLE_TIMEOUT} — continuing anyway"
  warn "'just okd-verify' re-checks and reports which operators are unsettled"
fi

log "post-install complete"
log "  developer login: oc login ${API_URL} -u ${DEVELOPER_USER} -p \$(cat ${DEVELOPER_PASSWORD_FILE}) --insecure-skip-tls-verify"
log "next: 'just okd-verify'"
