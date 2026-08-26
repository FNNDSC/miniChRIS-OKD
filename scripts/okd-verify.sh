#!/usr/bin/env bash
# okd-verify.sh — the recorded validation checklist.
#
# Exercises the OpenShift behaviors ChRIS needs — developer login, project
# lifecycle, restricted pods, PVC dynamics, service accounts, Routes — as
# the non-admin 'developer' user wherever possible, with a few admin-side
# assertions (operators, SCCs, default StorageClass).
#
# Output: one PASS/FAIL line per check on stdout, mirrored to
# okd/state/reports/verify-report-<timestamp>.txt, with full command output
# in the sibling .log file. Exit 0 only if every check passes.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd oc curl getent jq
require_live_cluster
[[ -f "${DEVELOPER_PASSWORD_FILE}" ]] || die "developer credentials missing — run okd-postinstall first"

PROJECT=harness-verify
# Probe images from registry.access.redhat.com: anonymous pulls, no rate
# limits, and (httpd-24) built to run under restricted-v2's arbitrary UIDs.
UBI_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
HTTPD_IMAGE="registry.access.redhat.com/ubi9/httpd-24:latest"
POD_TIMEOUT=300s

mkdir -p "${REPORT_DIR}"
stamp="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_DIR}/verify-report-${stamp}.txt"
DETAIL_LOG="${REPORT_DIR}/verify-report-${stamp}.log"

dev_oc() { oc --kubeconfig "${DEVELOPER_KUBECONFIG}" "$@"; }

# --- check runner -------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

report() { printf '%s\n' "$*" | tee -a "${REPORT_FILE}"; }

# run_check ID DESCRIPTION FN — run FN (output → detail log), record verdict.
run_check() {
  local id="$1" desc="$2" fn="$3" started verdict
  started=${SECONDS}
  printf '\n───── %s: %s\n' "${id}" "${desc}" >>"${DETAIL_LOG}"
  if "${fn}" >>"${DETAIL_LOG}" 2>&1; then
    verdict=PASS
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    verdict=FAIL
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  report "$(printf '%-4s  %-22s %s  (%ss)' "${verdict}" "${id}" "${desc}" "$((SECONDS - started))")"
}

# --- checks --------------------------------------------------------------------

check_dns() {
  local api_ip apps_ip
  api_ip="$(getent hosts "api.${CLUSTER_DOMAIN}" | awk '{print $1; exit}')"
  apps_ip="$(getent hosts "probe.${APPS_DOMAIN}" | awk '{print $1; exit}')"
  echo "api → ${api_ip}, apps → ${apps_ip}, expected ${ACCESS_IP}"
  [[ "${api_ip}" == "${ACCESS_IP}" && "${apps_ip}" == "${ACCESS_IP}" ]]
}

# The Ready condition alone is not evidence: kube-apiserver serves it from
# etcd, so a node whose kubelet has stopped talking keeps reporting Ready
# indefinitely. The node lease is the liveness signal — kubelet renews it every
# ~10s (see node_lease_problems in lib/common.sh).
#
# require_live_cluster already rejected that state before this file got here,
# so this is defence in depth: it catches a cluster that degrades *during* the
# run, which is otherwise a long checklist reported against stale data.
check_node_ready() {
  admin_oc get nodes -o wide
  admin_oc wait node --all --for=condition=Ready --timeout=120s
  local problems
  problems="$(node_lease_problems)"
  if [[ -n "${problems}" ]]; then
    echo "kubelet is not reporting: ${problems}"
    echo "the Ready condition above is stale etcd data; run 'just okd-doctor'"
    return 1
  fi
  echo "node lease is fresh — kubelet is really running"
}

# dump_unstable_operators — every operator that is not Available, or that is
# Progressing/Degraded, with the reason and message behind each condition.
# wait-for-stable-cluster names the unsettled operators but never says why,
# which is precisely what a reader of the detail log needs.
dump_unstable_operators() {
  local out
  out="$(admin_oc get clusteroperators -o json | jq -r '
    .items[]
    | select(
        ([.status.conditions[]? | select(.type == "Available" and .status == "True")] | length == 0)
        or ([.status.conditions[]? | select((.type == "Degraded" or .type == "Progressing") and .status == "True")] | length > 0)
      )
    | "\(.metadata.name):\n" + (
        [ .status.conditions[]?
          | select(.type != "Upgradeable" and .type != "EvaluationConditionsDetected")
          | "  \(.type)=\(.status)  reason=\(.reason // "-")\n    \(.message // "-")"
        ] | join("\n")
      )')"
  echo "--- operators not in a stable state (reasons) ---"
  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}"
  else
    echo "(none — every operator was already stable again by the time this dump ran)"
  fi
}

check_cluster_operators() {
  admin_oc get clusteroperators
  # Operators can be legitimately mid-rollout when verify starts — e.g. the
  # oauth stack re-rolls right after okd-postinstall's IdP patch — so wait
  # for sustained stability instead of snapshotting. okd-postinstall now
  # absorbs that settle itself; this stays as the standalone-run gate.
  if admin_oc adm wait-for-stable-cluster \
      --minimum-stable-period="${CLUSTER_STABLE_PERIOD}" \
      --timeout="${CLUSTER_STABLE_TIMEOUT}"; then
    return 0
  fi
  # Capture *why* while it is still true — the wait above only logs
  # "clusteroperators/<name> is <state>" lines.
  dump_unstable_operators
  echo "--- final operator table ---"
  admin_oc get clusteroperators
  return 1
}

check_scc_present() {
  admin_oc get scc restricted-v2 privileged
}

check_default_storageclass() {
  local default_sc
  default_sc="$(admin_oc get storageclass \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
  echo "default StorageClass: '${default_sc}'"
  [[ "${default_sc}" == local-path ]]
}

check_developer_login() {
  rm -f "${DEVELOPER_KUBECONFIG}"
  oc login "${API_URL}" \
    --kubeconfig="${DEVELOPER_KUBECONFIG}" \
    --username=developer --password="$(cat "${DEVELOPER_PASSWORD_FILE}")" \
    --insecure-skip-tls-verify=true
  [[ "$(dev_oc whoami)" == developer ]]
}

check_project_create() {
  dev_oc new-project "${PROJECT}" --description='miniChRIS-OKD harness verification (transient)'
}

check_restricted_pod() {
  dev_oc -n "${PROJECT}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: verify-restricted
spec:
  restartPolicy: Never
  containers:
    - name: sleeper
      image: ${UBI_IMAGE}
      command: ["sleep", "600"]
EOF
  dev_oc -n "${PROJECT}" wait --for=condition=Ready pod/verify-restricted --timeout="${POD_TIMEOUT}"
  local scc
  scc="$(dev_oc -n "${PROJECT}" get pod verify-restricted \
    -o jsonpath='{.metadata.annotations.openshift\.io/scc}')"
  echo "pod admitted under SCC: '${scc}'"
  [[ "${scc}" == restricted-v2 ]]
}

check_pvc_bind_write() {
  dev_oc -n "${PROJECT}" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: verify-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: verify-pvc-writer
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: ${UBI_IMAGE}
      command: ["sh", "-c", "echo harness-pvc-ok > /data/probe && cat /data/probe"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: verify-pvc
EOF
  dev_oc -n "${PROJECT}" wait --for=jsonpath='{.status.phase}'=Succeeded \
    pod/verify-pvc-writer --timeout="${POD_TIMEOUT}"
  local phase
  phase="$(dev_oc -n "${PROJECT}" get pvc verify-pvc -o jsonpath='{.status.phase}')"
  echo "PVC phase: ${phase}"
  [[ "${phase}" == Bound ]]
}

check_serviceaccount_token() {
  dev_oc -n "${PROJECT}" create serviceaccount verify-sa --dry-run=client -o yaml \
    | dev_oc -n "${PROJECT}" apply -f -
  local token
  token="$(dev_oc -n "${PROJECT}" create token verify-sa)"
  [[ -n "${token}" ]]
}

check_route_edge() {
  dev_oc -n "${PROJECT}" create deployment verify-web --image="${HTTPD_IMAGE}" --port=8080
  dev_oc -n "${PROJECT}" expose deployment verify-web --port=8080
  dev_oc -n "${PROJECT}" create route edge verify-web --service=verify-web
  dev_oc -n "${PROJECT}" wait deployment/verify-web --for=condition=Available --timeout="${POD_TIMEOUT}"

  local host code attempt phase reached=false
  host="$(dev_oc -n "${PROJECT}" get route verify-web -o jsonpath='{.spec.host}')"
  echo "route host: ${host}"

  # Leg 1 — from the host, i.e. how a developer reaches the Route.
  echo "--- leg 1: from the host (outside the cluster) ---"
  # Router config propagation can lag the Route object briefly; -k because
  # the default router certificate is self-signed.
  for attempt in {1..12}; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/" || true)"
    echo "attempt ${attempt}: HTTP ${code}"
    # 200 (welcome page) or 403 (no index) both prove routing into the pod.
    if [[ "${code}" == 200 || "${code}" == 403 ]]; then reached=true; break; fi
    sleep 10
  done
  [[ "${reached}" == true ]] || { echo "host-side probe never succeeded"; return 1; }

  # Leg 2 — from inside the cluster. Different DNS (CoreDNS -> the node's
  # resolver) and a different network path, and it is the leg the ingress
  # canary and the oauth route depend on. A cluster can pass leg 1 and still
  # degrade on ingress/authentication (FNNDSC/HARBOR-planning#129).
  echo "--- leg 2: from inside the cluster (ingress canary / oauth path) ---"
  dev_oc -n "${PROJECT}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: verify-incluster
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${UBI_IMAGE}
      command:
        - sh
        - -c
        - |
          for i in \$(seq 1 12); do
            code=\$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/" || true)
            echo "attempt \$i: HTTP \$code"
            case "\$code" in 200|403) exit 0 ;; esac
            sleep 10
          done
          echo "in-cluster probe never reached the route"
          exit 1
EOF
  # Poll for a terminal phase rather than 'wait --for', so a genuine failure
  # reports promptly instead of burning the full timeout.
  phase=""
  for attempt in {1..48}; do
    phase="$(dev_oc -n "${PROJECT}" get pod verify-incluster -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 5
  done
  dev_oc -n "${PROJECT}" logs verify-incluster 2>&1 || true
  echo "in-cluster probe pod phase: ${phase:-<none>}"
  [[ "${phase}" == Succeeded ]]
}

check_project_delete() {
  dev_oc delete project "${PROJECT}" --wait=true
  admin_oc wait namespace "${PROJECT}" --for=delete --timeout=300s
}

# --- main -----------------------------------------------------------------------

# Clean debris from a previous (possibly aborted) run.
if admin_oc get namespace "${PROJECT}" >/dev/null 2>&1; then
  log "cleaning up leftover '${PROJECT}' namespace from a previous run"
  admin_oc delete namespace "${PROJECT}" --wait=true >/dev/null
  admin_oc wait namespace "${PROJECT}" --for=delete --timeout=300s >/dev/null 2>&1 || true
fi

okd_version="$(admin_oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo unknown)"
{
  echo "miniChRIS-OKD verification report — FNNDSC/HARBOR-planning#129 checklist"
  echo "date:            $(date -u +'%Y-%m-%d %H:%M:%SZ')"
  echo "host:            $(hostname) (${ACCESS_MODE} mode)"
  echo "cluster:         ${CLUSTER_DOMAIN}"
  echo "okd version:     ${okd_version}"
  echo "─────────────────────────────────────────────────────────────"
} | tee "${REPORT_FILE}"

run_check dns-wildcard      "sslip.io resolves api + apps to access IP"   check_dns
run_check node-ready        "single node is Ready"                        check_node_ready
run_check cluster-operators "all operators Available, none Degraded"      check_cluster_operators
run_check scc-present       "SCC admission present (restricted-v2)"       check_scc_present
run_check storageclass      "local-path is the default StorageClass"      check_default_storageclass
run_check dev-login         "developer can 'oc login' via htpasswd IdP"   check_developer_login
run_check project-create    "developer can create a project"              check_project_create
run_check restricted-pod    "unprivileged pod runs under restricted-v2"   check_restricted_pod
run_check pvc-bind-write    "PVC binds dynamically and is writable"       check_pvc_bind_write
run_check sa-token          "ServiceAccount created and token issued"     check_serviceaccount_token
run_check route-edge        "edge Route reachable through *.apps"         check_route_edge
run_check project-delete    "developer can delete the project"            check_project_delete

{
  echo "─────────────────────────────────────────────────────────────"
  echo "result: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
} | tee -a "${REPORT_FILE}"

log "report:  ${REPORT_FILE}"
log "details: ${DETAIL_LOG}"
[[ "${FAIL_COUNT}" -eq 0 ]] || die "verification failed (${FAIL_COUNT} check(s))"
