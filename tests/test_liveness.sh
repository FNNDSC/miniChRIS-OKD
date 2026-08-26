#!/usr/bin/env bash
# tests/test_liveness.sh — offline tests for the cluster-liveness helpers in
# scripts/lib/common.sh. No cluster and no network: admin_oc is stubbed with
# canned API responses, so these exercise the *real* jq programs and the real
# bash control flow rather than copies of them.
#
#   just test-liveness        (or ./tests/test_liveness.sh)   exit 0 = all pass
#
# These helpers encode "healthy" as empty output, which makes every silent
# failure a fail-open — the one thing this check must never do. Most of what
# follows is therefore about what happens when something goes wrong.
#
# Not covered here (needs a cluster, or a refactor to be reachable):
# chris-teardown's best_effort matrix, okd-doctor's approve/repair loop, and
# the guards' exit codes. `just okd-verify` and `just smoke` cover those live.

set -uo pipefail   # deliberately not -e: these tests assert on failures

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
set +e   # common.sh turns on -e; the assertions below need it off

PASSED=0 FAILED=0

# ok NAME EXPECTED ACTUAL — substring match, so tests stay readable.
ok() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${actual}" == *"${expected}"* ]]; then
    PASSED=$((PASSED + 1))
    printf '  \033[32m✓\033[0m %s\n' "${name}"
  else
    FAILED=$((FAILED + 1))
    printf '  \033[31m✗\033[0m %s\n      expected to contain: %q\n      got:                 %q\n' \
      "${name}" "${expected}" "${actual}"
  fi
}

# empty NAME ACTUAL — asserts "healthy" (no problems reported).
empty() {
  local name="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    PASSED=$((PASSED + 1))
    printf '  \033[32m✓\033[0m %s\n' "${name}"
  else
    FAILED=$((FAILED + 1))
    printf '  \033[31m✗\033[0m %s\n      expected no output, got: %q\n' "${name}" "${actual}"
  fi
}

# absent NAME NEEDLE HAYSTACK — asserts NEEDLE is *not* present.
absent() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    PASSED=$((PASSED + 1))
    printf '  \033[32m✓\033[0m %s\n' "${name}"
  else
    FAILED=$((FAILED + 1))
    printf '  \033[31m✗\033[0m %s\n      expected NOT to contain: %q\n      got:                     %q\n' \
      "${name}" "${needle}" "${haystack}"
  fi
}

# --- admin_oc stub ------------------------------------------------------------
STUB_LEASES='{"items":[]}' STUB_CSRS='{"items":[]}' STUB_LEASE_RC=0
admin_oc() {
  case "$*" in
    *"get leases"*)
      [[ "${STUB_LEASE_RC}" -eq 0 ]] || return "${STUB_LEASE_RC}"
      printf '%s' "${STUB_LEASES}" ;;
    *"get csr"*) printf '%s' "${STUB_CSRS}" ;;
    *) return 0 ;;
  esac
}

# ago SECONDS — an RFC3339 UTC timestamp that many seconds in the past.
ago() { jq -rn --argjson s "$1" 'now - $s | todateiso8601'; }

echo "node_lease_problems — healthy"
STUB_LEASES="$(jq -n --arg t "$(ago 5 | sed 's/Z$/.123456Z/')" '{items:[{metadata:{name:"okd-sno"},spec:{renewTime:$t}}]}')"
empty "fresh lease (5s, microsecond precision) reports nothing" "$(node_lease_problems)"

STUB_LEASES="$(jq -n --arg t "$(ago 5)" '{items:[{metadata:{name:"okd-sno"},spec:{renewTime:$t}}]}')"
empty "fresh lease with no fractional seconds" "$(node_lease_problems)"

echo "node_lease_problems — stale"
STUB_LEASES="$(jq -n --arg t "$(ago 600 | sed 's/Z$/.123456789Z/')" '{items:[{metadata:{name:"okd-sno"},spec:{renewTime:$t}}]}')"
ok "stale lease is reported with the node name" "node okd-sno has not renewed its lease" "$(node_lease_problems)"
ok "nanosecond precision still parses (age ~600s)" "600s" "$(node_lease_problems)"

echo "node_lease_problems — fails closed"
STUB_LEASES="$(jq -n '{items:[{metadata:{name:"okd-sno"},spec:{}}]}')"
ok "missing renewTime is a problem, not silence" "no usable lease renewTime" "$(node_lease_problems)"

# M2 regression: '.items[]' aborts the stream at the first throwing item, so an
# unparseable timestamp FIRST would otherwise hide every node after it — and on
# a single-node cluster, that is the only node there is.
STUB_LEASES="$(jq -n --arg bad "2020-01-01T00:00:00+00:00" --arg t "$(ago 600)" \
  '{items:[{metadata:{name:"bad-node"},spec:{renewTime:$bad}},
           {metadata:{name:"okd-sno"},spec:{renewTime:$t}}]}')"
out="$(node_lease_problems)"
ok "unparseable timestamp does not abort the stream (bad node reported)" "bad-node" "${out}"
ok "  ...and the node after it is still reported" "okd-sno" "${out}"

STUB_LEASE_RC=1
ok "unreadable lease list is a problem, not silence" "could not read node leases" "$(node_lease_problems)"
STUB_LEASE_RC=0

STUB_LEASES='{"items":[]}'
ok "no leases at all is a problem, not silence" "no node leases exist" "$(node_lease_problems)"

STUB_LEASES='not json at all'
ok "unparseable lease list is a problem, not silence" "could not parse the node lease list" "$(node_lease_problems)"

echo "pending_kubelet_csrs"
STUB_CSRS='{"items":[
 {"metadata":{"name":"pending-client"},"spec":{"signerName":"kubernetes.io/kube-apiserver-client-kubelet"},"status":{}},
 {"metadata":{"name":"pending-serving"},"spec":{"signerName":"kubernetes.io/kubelet-serving"},"status":{"conditions":[]}},
 {"metadata":{"name":"pending-nostatus"},"spec":{"signerName":"kubernetes.io/kubelet-serving"}},
 {"metadata":{"name":"approved"},"spec":{"signerName":"kubernetes.io/kube-apiserver-client-kubelet"},"status":{"conditions":[{"type":"Approved"}],"certificate":"eA=="}},
 {"metadata":{"name":"denied"},"spec":{"signerName":"kubernetes.io/kubelet-serving"},"status":{"conditions":[{"type":"Denied"}]}},
 {"metadata":{"name":"other-signer"},"spec":{"signerName":"kubernetes.io/legacy-unknown"},"status":{}}
]}'
csrs="$(pending_kubelet_csrs)"
ok "pending client CSR listed"                "pending-client"   "${csrs}"
ok "pending CSR with empty conditions listed" "pending-serving"  "${csrs}"
ok "pending CSR with no status key listed"    "pending-nostatus" "${csrs}"
ok "exactly three pending"                    "3"                "$(count_lines "${csrs}")"
absent "approved CSR excluded"     "approved"     "${csrs}"
absent "denied CSR excluded"       "denied"       "${csrs}"
absent "other-signer CSR excluded" "other-signer" "${csrs}"

# A CSR with no signerName must not abort the stream either.
STUB_CSRS='{"items":[
 {"metadata":{"name":"no-signer"},"spec":{},"status":{}},
 {"metadata":{"name":"pending-after"},"spec":{"signerName":"kubernetes.io/kubelet-serving"},"status":{}}
]}'
ok "null signerName does not abort the stream" "pending-after" "$(pending_kubelet_csrs)"

echo "count_lines"
ok "empty string counts 0"  "0" "$(count_lines "")"
ok "three lines count 3"    "3" "$(count_lines "$(printf 'a\nb\nc')")"

# C1 regression: the threshold is handed to jq as JSON. A duration-style typo
# ("120s") used to make every lease query fail — and a failed query that
# returned silence read as "healthy", disabling the gate on that host forever.
echo "NODE_LEASE_MAX_AGE validation"
for bad in 120s abc 1.5 ' '; do
  out="$(NODE_LEASE_MAX_AGE="${bad}" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'" 2>&1)"
  ok "rejects NODE_LEASE_MAX_AGE=$(printf %q "${bad}")" "must be a whole number of seconds" "${out}"
done
out="$(NODE_LEASE_MAX_AGE=300 bash -c "source '${REPO_ROOT}/scripts/lib/common.sh' && echo OK:\${NODE_LEASE_MAX_AGE}" 2>&1)"
ok "accepts a plain integer" "OK:300" "${out}"
out="$(bash -c "unset NODE_LEASE_MAX_AGE; source '${REPO_ROOT}/scripts/lib/common.sh' && echo OK:\${NODE_LEASE_MAX_AGE}" 2>&1)"
ok "defaults to 120 when unset" "OK:120" "${out}"

printf '\n%s passed, %s failed\n' "${PASSED}" "${FAILED}"
[[ "${FAILED}" -eq 0 ]]
