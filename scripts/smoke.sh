#!/usr/bin/env bash
# smoke.sh — Phase 3 (issue #131): run the functional smoke test against the
# deployed ChRIS, wiring harness state (URL, seeded credentials, router CA,
# admin kubeconfig for failure diagnostics) into the smoke/ Python package.
#
#   smoke.sh [args...]     create/reuse the venv, then run `python -m chris_smoke`
#   smoke.sh --setup-only  stop after the venv is ready (CI image pre-bake)
#
# The package itself is harness-agnostic — everything is passed via env vars,
# so the same test runs from any shell that can reach the Route (see
# smoke/README.md). Extra args go straight through (e.g. --keep, --verbose).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Everything before the final exec is bootstrap: a failure here means the
# invocation or harness state is wrong, never that ChRIS is broken — so it
# must exit 2, matching the Python CLI's contract (0 pass / 1 product
# failure / 2 configuration) that docs/ci.md tells CI to rely on. Override
# lib/common.sh's die() (which exits 1) and route unexpected command
# failures the same way; the exec'd Python process is unaffected.
die() { printf '%s[%s] error:%s %s\n' "${_C_ERR}" "${SCRIPT_NAME}" "${_C_OFF}" "$*" >&2; exit 2; }
trap 'exit 2' ERR

source "${SCRIPT_DIR}/lib/chris.sh"

SETUP_ONLY=no
if [[ "${1:-}" == "--setup-only" ]]; then
  SETUP_ONLY=yes
  shift
fi

require_cmd python3

# --- virtualenv: created once, reinstalled when pyproject.toml changes -------
SMOKE_SRC="${REPO_ROOT}/smoke"
VENV_DIR="${STATE_DIR}/smoke-venv"
VENV_PY="${VENV_DIR}/bin/python"
STAMP_FILE="${VENV_DIR}/.pyproject-sha256"

pyproject_hash="$(python3 -c \
  'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
  "${SMOKE_SRC}/pyproject.toml")"

if [[ ! -x "${VENV_PY}" || "$(cat "${STAMP_FILE}" 2>/dev/null)" != "${pyproject_hash}" ]]; then
  log "setting up smoke test virtualenv in ${VENV_DIR}"
  if command -v uv >/dev/null 2>&1; then
    uv venv --quiet --allow-existing "${VENV_DIR}"
    uv pip install --quiet --python "${VENV_PY}" -e "${SMOKE_SRC}"
  else
    python3 -m venv "${VENV_DIR}"
    "${VENV_PY}" -m pip install --quiet --upgrade pip
    "${VENV_PY}" -m pip install --quiet -e "${SMOKE_SRC}"
  fi
  echo "${pyproject_hash}" >"${STAMP_FILE}"
fi

if [[ "${SETUP_ONLY}" == yes ]]; then
  log "smoke test environment ready: ${VENV_PY}"
  exit 0
fi

# --- credentials: the Phase 2 seeded test user -------------------------------
if [[ -z "${CHRIS_SMOKE_PASSWORD:-}" && -z "${CHRIS_SMOKE_PASSWORD_FILE:-}" ]]; then
  [[ -f "${CHRIS_TEST_PASSWORD_FILE}" ]] \
    || die "no test-user password at ${CHRIS_TEST_PASSWORD_FILE} — run 'just chris-seed'"
  export CHRIS_SMOKE_PASSWORD_FILE="${CHRIS_TEST_PASSWORD_FILE}"
fi
export CHRIS_SMOKE_USER="${CHRIS_SMOKE_USER:-${CHRIS_TEST_USER}}"

# --- TLS: router CA by default; skipping verification must be an explicit
# operator choice (SMOKE_INSECURE=1), never a silent downgrade ----------------
if [[ -z "${SMOKE_CA_BUNDLE:-}" && "${SMOKE_INSECURE:-}" != 1 ]]; then
  ROUTER_CA_FILE="${AUTH_DIR}/router-ca.crt"
  if [[ ! -f "${ROUTER_CA_FILE}" ]]; then
    "${SCRIPT_DIR}/router-ca.sh" >/dev/null || true
  fi
  [[ -f "${ROUTER_CA_FILE}" ]] \
    || die "router CA unavailable ('just router-ca' failed — fix cluster access, or explicitly opt out of TLS verification with SMOKE_INSECURE=1)"
  export SMOKE_CA_BUNDLE="${ROUTER_CA_FILE}"
fi

# --- diagnostics + artifact wiring -------------------------------------------
[[ -f "${ADMIN_KUBECONFIG}" ]] && export SMOKE_KUBECONFIG="${SMOKE_KUBECONFIG:-${ADMIN_KUBECONFIG}}"
export SMOKE_NAMESPACE="${SMOKE_NAMESPACE:-${CHRIS_NAMESPACE}}"
export SMOKE_ARTIFACTS_DIR="${SMOKE_ARTIFACTS_DIR:-${STATE_DIR}/smoke-artifacts}"

# CUBE_URL is exported by lib/chris.sh; SMOKE_TIMEOUT/SMOKE_POLL_INTERVAL come
# from config.env (all sourced with set -a).
exec "${VENV_PY}" -m chris_smoke "$@"
