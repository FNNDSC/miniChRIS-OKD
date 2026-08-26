#!/usr/bin/env bash
# okd-doctor.sh — diagnose (and repair) a cluster that is serving but not live.
#
# The failure mode this exists for: a node powered off across the 24-hour
# bootstrap certificate rotation comes back with an expired kubelet client
# certificate. kubelet then authenticates as system:anonymous, so it can start
# only the static control-plane pods, and cluster-machine-approver — an
# ordinary pod — never runs to approve the CSRs kubelet keeps submitting. The
# deadlock does not clear itself. Meanwhile kube-apiserver serves the last
# state etcd recorded, so every 'oc get' reports a healthy cluster and the
# first real symptom is something unrelated failing much later.
#
# The repair approves the pending kubelet CSRs using the admin kubeconfig,
# whose client certificate is long-lived and therefore still valid. kubelet
# then gets a certificate, registers, and starts every workload; a second CSR
# round (kubelet-serving) follows and is approved the same way.
#
# Note this is deliberately WEAKER than cluster-machine-approver, which also
# validates the requester identity, the CSR subject and the SANs against the
# node object. Here we approve by signerName alone. That is acceptable for a
# single-user lab VM whose only node is the one asking; it would not be on a
# cluster where anything else can submit CSRs.
#
#   okd-doctor.sh          diagnose, then repair (asks first)
#   okd-doctor.sh --check  diagnose only, change nothing; exit 1 if unhealthy
#   okd-doctor.sh --yes    repair without asking (CI)
#
# Exit 0 when the cluster is live (or was repaired), 1 when it is not.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd oc jq
require_cluster

# How long to wait for kubelet to come back after approving, and how often to
# look. Recovery is fast (kubelet retries within seconds) but the follow-on
# serving CSR needs a round or two.
RECOVER_TIMEOUT="${RECOVER_TIMEOUT:-600}"
RECOVER_POLL=10
[[ "${RECOVER_TIMEOUT}" =~ ^[0-9]+$ ]] \
  || die "RECOVER_TIMEOUT must be a whole number of seconds (got '${RECOVER_TIMEOUT}')"

CHECK_ONLY=false
for arg in "$@"; do
  # shellcheck disable=SC2034  # CONFIRM is read by confirm() in lib/common.sh
  case "${arg}" in
    --check) CHECK_ONLY=true ;;
    --yes) CONFIRM=yes ;;
    *) die "unknown argument: ${arg} (usage: okd-doctor.sh [--check] [--yes])" ;;
  esac
done

# approve_kubelet_csrs — approve every pending kubelet CSR; prints how many.
# Returns non-zero if the approve itself failed. That has to be explicit:
# callers read this through $( ), and bash does not apply set -e inside a
# command substitution unless inherit_errexit is set (it is not), so a failed
# approve would otherwise fall through and report the full count as approved.
approve_kubelet_csrs() {
  local names=()
  mapfile -t names < <(pending_kubelet_csrs)
  [[ ${#names[@]} -gt 0 ]] || { printf 0; return 0; }
  admin_oc adm certificate approve "${names[@]}" >/dev/null || return 1
  printf '%s' "${#names[@]}"
}

# --- diagnose -----------------------------------------------------------------
log "cluster:  ${CLUSTER_DOMAIN} (${ACCESS_MODE} mode via ${ACCESS_IP})"

if ! cluster_api_ok; then
  log "api:      kube-apiserver at ${API_URL} is NOT answering"
  # Nothing below can help: the repair approves CSRs, which needs a live API.
  die "the API is unreachable — start the VM ('virsh -c qemu:///system start ${VM_NAME}') and re-run"
fi
log "api:      kube-apiserver is serving (/readyz ok)"

problem="$(cluster_liveness_problem)"
if [[ -z "${problem}" ]]; then
  log "kubelet:  every node lease is fresh — the cluster is live"
  pending="$(pending_kubelet_csrs)"
  [[ -z "${pending}" ]] \
    || log "csr:      $(count_lines "${pending}") kubelet CSR(s) pending (harmless while kubelet is live)"
  log "healthy — nothing to repair ('just okd-verify' is the full checklist)"
  exit 0
fi

warn "${problem}"

if [[ "${CHECK_ONLY}" == true ]]; then
  die "cluster is not live (--check: nothing was changed)"
fi

pending_count="$(count_lines "$(pending_kubelet_csrs)")"
if [[ "${pending_count}" -eq 0 ]]; then
  # Stale leases with no CSR to approve is a different fault — the node may be
  # off, or kubelet may be down for an unrelated reason. Say so instead of
  # pretending the CSR repair applies.
  die "no pending kubelet CSRs, so this is not the certificate deadlock — check the node itself:
  virsh -c qemu:///system list
  ssh -i ${SSH_DIR}/id_ed25519 core@${VM_IP} 'systemctl status kubelet'"
fi

# --- repair -------------------------------------------------------------------
confirm "Approve ${pending_count} pending kubelet CSR(s) to let kubelet re-authenticate?" \
  || die "aborted"

approved="$(approve_kubelet_csrs)" \
  || die "approving the kubelet CSRs failed — see oc's error above (RBAC? apiserver rejecting?)"
log "approved ${approved} kubelet CSR(s)"
log "waiting for kubelet to report (up to ${RECOVER_TIMEOUT}s; a second CSR round follows)"

deadline=$((SECONDS + RECOVER_TIMEOUT))
while :; do
  # kubelet requests its serving certificate only after the client one lands,
  # so keep approving each round rather than approving once and hoping.
  approved="$(approve_kubelet_csrs)" \
    || die "approving the follow-on kubelet CSRs failed — see oc's error above"
  [[ "${approved}" -eq 0 ]] || log "approved ${approved} follow-on CSR(s)"

  if [[ -z "$(node_lease_problems)" ]]; then
    log "kubelet is reporting again — every node lease is fresh"
    break
  fi
  [[ ${SECONDS} -lt ${deadline} ]] \
    || die "kubelet still not reporting after ${RECOVER_TIMEOUT}s — see 'ssh core@${VM_IP} journalctl -u kubelet'"
  sleep "${RECOVER_POLL}"
done

log "repair complete"
log "  workloads are restarting; cluster operators take several minutes to re-converge"
log "next: 'just okd-verify' (the full checklist) — ChRIS pods come back on their own"
