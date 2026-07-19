#!/usr/bin/env bash
# chris-logs.sh — logs for one ChRIS component.
#
#   usage: chris-logs.sh [component] [oc-logs args...]      (default: heart)
#
#   components: heart server worker-mains worker-periodic pfcon pman
#               db rabbitmq nats seed plugins
#
#   examples:  chris-logs.sh heart -f
#              chris-logs.sh pman --since=10m
#              chris-logs.sh plugins        # pods of plugin-instance jobs

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib/chris.sh"

require_cmd oc
require_cluster

component="${1:-heart}"
[[ $# -gt 0 ]] && shift

container=()
case "${component}" in
  heart)           target="deploy/${CHRIS_RELEASE}-heart" ;;
  server)          target="deploy/${CHRIS_RELEASE}-server" ;;
  worker-mains)    target="deploy/${CHRIS_RELEASE}-worker-mains" ;;
  worker-periodic) target="deploy/${CHRIS_RELEASE}-worker-periodic" ;;
  pfcon)           target="deploy/${CHRIS_RELEASE}-pfcon"; container=(-c pfcon) ;;
  pman)            target="deploy/${CHRIS_RELEASE}-pfcon"; container=(-c pman) ;;
  db)              target="sts/${CHRIS_RELEASE}-postgresql" ;;
  rabbitmq)        target="sts/${CHRIS_RELEASE}-rabbitmq" ;;
  nats)            target="sts/${CHRIS_RELEASE}-nats" ;;
  seed)            target="job/${SEED_JOB}" ;;
  plugins)
    # Pods of the Jobs pman creates for plugin instances (chart-set label).
    chris_oc logs -l chrisproject.org/job=plugininstance --tail=-1 "$@"
    exit 0
    ;;
  *)
    die "unknown component '${component}' (heart server worker-mains worker-periodic pfcon pman db rabbitmq nats seed plugins)"
    ;;
esac

chris_oc logs "${target}" ${container[@]+"${container[@]}"} "$@"
