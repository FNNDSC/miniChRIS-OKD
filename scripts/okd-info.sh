#!/usr/bin/env bash
# okd-info.sh — read-only access details and version pins.
#
#   console    : URLs and credentials for humans
#   env        : eval-able exports — eval "$(just okd-env)" puts the pinned
#                oc/kubectl on PATH and points KUBECONFIG at the admin config
#   kubeconfig : eval-able KUBECONFIG export only
#   versions   : pinned versions (+ live cluster version when reachable)

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

cmd="${1:-console}"
case "${cmd}" in
  console)
    echo "cluster:    ${CLUSTER_DOMAIN} (${ACCESS_MODE} mode via ${ACCESS_IP})"
    echo "console:    ${CONSOLE_URL}"
    echo "api:        ${API_URL}"
    if [[ -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
      echo "kubeadmin:  $(cat "${KUBEADMIN_PASSWORD_FILE}")"
    else
      echo "kubeadmin:  (no password file yet — cluster not installed?)"
    fi
    if [[ -f "${DEVELOPER_PASSWORD_FILE}" ]]; then
      echo "developer:  $(cat "${DEVELOPER_PASSWORD_FILE}")"
    else
      echo "developer:  (not provisioned yet — run okd-postinstall)"
    fi
    echo
    echo "shell setup — pinned oc on PATH + admin kubeconfig:"
    echo "  eval \"\$(just okd-env)\""
    echo
    echo "after the eval above:"
    echo "  oc get nodes                    # cluster admin"
    echo "  oc login ${API_URL} -u developer --insecure-skip-tls-verify"
    echo "                                  # switches this kubeconfig to developer;"
    echo "  oc config use-context admin     # ...and this switches back"
    ;;
  env)
    # shellcheck disable=SC2016  # ${PATH} must stay literal in eval-able output
    printf 'export PATH=%q:"${PATH}"\n' "${BIN_DIR}"
    if [[ -f "${ADMIN_KUBECONFIG}" ]]; then
      printf 'export KUBECONFIG=%q\n' "${ADMIN_KUBECONFIG}"
    fi
    ;;
  kubeconfig)
    require_cluster
    printf 'export KUBECONFIG=%q\n' "${ADMIN_KUBECONFIG}"
    ;;
  versions)
    echo "OKD_VERSION:                     ${OKD_VERSION}"
    echo "LOCAL_PATH_PROVISIONER_VERSION:  ${LOCAL_PATH_PROVISIONER_VERSION}"
    echo "CHRIS_CHART_VERSION:             ${CHRIS_CHART_VERSION}"
    echo "CHRISOMATIC_IMAGE:               ${CHRISOMATIC_IMAGE}"
    if [[ -f "${ADMIN_KUBECONFIG}" ]]; then
      live="$(admin_oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
      echo "cluster (live):                  ${live:-unreachable}"
    fi
    ;;
  *)
    die "usage: okd-info.sh {console|env|kubeconfig|versions}"
    ;;
esac
