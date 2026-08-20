#!/usr/bin/env bash
# host-check.sh — preflight. Verifies the host can run the harness *before*
# anything changes state: CPU/RAM/disk headroom over the configured VM size,
# KVM, required tools, libvirt, sslip.io DNS resolution, and (lan mode)
# free ports for HAProxy. Prints one line per check; exits non-zero if any
# hard check fails.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

FAILURES=0
ok()     { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()    { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note()   { printf '  \033[33m·\033[0m %s\n' "$*"; }

# Headroom the host keeps for itself beyond the VM's allocation.
CPU_HEADROOM=2       # threads
RAM_HEADROOM_MIB=8192
DISK_HEADROOM_GB=50  # over VM_DISK_GB, for ISO + boot image cache

# Absolute VM sizing floors, independent of how big the host is. The headroom
# checks above are relative — on an 8-thread box they happily pass VM_VCPUS=2.
#   HARD : below this SNO does not come up at all — fail preflight.
#   MIN  : the documented Minimum tier (docs/requirements.md). Between HARD and
#          MIN the cluster installs but settles slowly, and the post-install
#          operator-stability wait is the first casualty
#          (FNNDSC/HARBOR-planning#128) — advise rather than block.
VM_VCPUS_HARD=4;      VM_VCPUS_MIN=8
VM_RAM_MIB_HARD=16384; VM_RAM_MIB_MIN=24576
VM_DISK_GB_HARD=120;   VM_DISK_GB_MIN=150

log "preflight for ACCESS_MODE=${ACCESS_MODE}, cluster domain ${CLUSTER_DOMAIN}"

# --- platform ---------------------------------------------------------------
if [[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]]; then
  ok "platform: Linux x86_64"
else
  bad "platform: need Linux x86_64, got $(uname -s)/$(uname -m) (macOS participates as a client only)"
fi

if [[ -e /dev/kvm ]]; then
  ok "KVM available (/dev/kvm)"
else
  bad "KVM not available — enable VT-x/AMD-V in firmware (nested virt if this is itself a VM)"
fi

# --- resources ---------------------------------------------------------------
threads="$(nproc 2>/dev/null || echo 0)"
need_threads=$((VM_VCPUS + CPU_HEADROOM))
if [[ "${threads}" -ge "${need_threads}" ]]; then
  ok "CPU: ${threads} threads (VM wants ${VM_VCPUS} + ${CPU_HEADROOM} headroom)"
else
  bad "CPU: ${threads} threads < ${need_threads} required (lower VM_VCPUS or use a bigger box)"
fi

ram_mib=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024))
need_ram=$((VM_RAM_MIB + RAM_HEADROOM_MIB))
if [[ "${ram_mib}" -ge "${need_ram}" ]]; then
  ok "RAM: ${ram_mib} MiB (VM wants ${VM_RAM_MIB} + ${RAM_HEADROOM_MIB} headroom)"
else
  bad "RAM: ${ram_mib} MiB < ${need_ram} MiB required (lower VM_RAM_MIB or use a bigger box)"
fi

# Nearest existing ancestor of IMAGES_DIR (it may not exist yet).
probe_dir="${IMAGES_DIR}"
while [[ ! -d "${probe_dir}" ]]; do probe_dir="$(dirname "${probe_dir}")"; done
free_gb="$(df -BG --output=avail "${probe_dir}" | tail -1 | tr -dc '0-9')"
need_gb=$((VM_DISK_GB + DISK_HEADROOM_GB))
if [[ "${free_gb}" -ge "${need_gb}" ]]; then
  ok "disk: ${free_gb} GB free at ${probe_dir} (need ${need_gb} GB)"
else
  bad "disk: ${free_gb} GB free at ${probe_dir} < ${need_gb} GB (point IMAGES_DIR at a bigger volume)"
fi

# floor_check LABEL VALUE MIN HARD UNIT — hard-fail below HARD, advise below MIN.
floor_check() {
  local label="$1" value="$2" min="$3" hard="$4" unit="$5"
  if [[ "${value}" -lt "${hard}" ]]; then
    bad "${label}: ${value}${unit} below the hard floor of ${hard}${unit} — SNO will not come up"
  elif [[ "${value}" -lt "${min}" ]]; then
    note "${label}: ${value}${unit} below the documented minimum of ${min}${unit} — installs, but"
    note "         expect slow operator settling and a sluggish Phase 2; if okd-verify's"
    note "         cluster-operators check times out, raise CLUSTER_STABLE_TIMEOUT (now ${CLUSTER_STABLE_TIMEOUT})"
  else
    ok "${label}: ${value}${unit} meets the documented minimum (${min}${unit})"
  fi
}
floor_check "VM vCPUs" "${VM_VCPUS}"   "${VM_VCPUS_MIN}"   "${VM_VCPUS_HARD}"   ""
floor_check "VM RAM"   "${VM_RAM_MIB}" "${VM_RAM_MIB_MIN}" "${VM_RAM_MIB_HARD}" " MiB"
floor_check "VM disk"  "${VM_DISK_GB}" "${VM_DISK_GB_MIN}" "${VM_DISK_GB_HARD}" " GB"

# --- tooling ----------------------------------------------------------------
for cmd in virsh virt-install qemu-img envsubst jq curl ss getent openssl; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "tool: ${cmd}"
  else
    bad "tool: ${cmd} missing (run 'just host-setup')"
  fi
done
for cmd in oc openshift-install; do
  command -v "${cmd}" >/dev/null 2>&1 \
    && ok "tool: ${cmd} ($(command -v "${cmd}"))" \
    || note "tool: ${cmd} not present yet — fetched by okd-download during okd-install"
done

if systemctl is-active --quiet libvirtd 2>/dev/null \
    || systemctl is-active --quiet virtqemud.service 2>/dev/null \
    || systemctl is-active --quiet virtqemud.socket 2>/dev/null; then
  ok "libvirt daemon active (libvirtd or virtqemud)"
else
  bad "no libvirt daemon active (run 'just host-setup'; Fedora: enable virtqemud.socket)"
fi

if command -v virsh >/dev/null 2>&1; then
  if virsh_c list >/dev/null 2>&1; then
    ok "libvirt access (qemu:///system) as ${USER}"
  else
    bad "cannot talk to qemu:///system — is ${USER} in the 'libvirt' group? (re-login after host-setup)"
  fi
fi

# --- DNS: sslip.io must resolve the cluster domain to the access IP ----------
check_dns() {
  local fqdn="$1" resolved
  resolved="$(getent hosts "${fqdn}" | awk '{print $1; exit}' || true)"
  if [[ "${resolved}" == "${ACCESS_IP}" ]]; then
    ok "DNS: ${fqdn} → ${resolved}"
  else
    bad "DNS: ${fqdn} → '${resolved:-<nothing>}', expected ${ACCESS_IP} (rebind-protecting resolver? see docs/networking.md)"
  fi
}
check_dns "api.${CLUSTER_DOMAIN}"
check_dns "test.${APPS_DOMAIN}"

# The two checks above are the *host's* view. The cluster lives by the *node's*
# view, which resolves through the libvirt network's dnsmasq — a different path,
# and the one that silently breaks when an upstream resolver strips private-IP
# answers. A host that passes above can still build a cluster whose ingress and
# authentication operators cannot resolve their own '*.apps' routes
# (FNNDSC/HARBOR-planning#129). On a first run the network does not exist yet;
# net-setup asserts the same thing right after it creates it.
if command -v dig >/dev/null 2>&1 && command -v virsh >/dev/null 2>&1 \
    && [[ "$(virsh_c net-info "${VM_NET_NAME}" 2>/dev/null | awk '/^Active:/ {print $2}')" == yes ]]; then
  # dig exits 9 when the resolver does not reply — tolerate it and report below.
  node_api="$(dig +short "api.${CLUSTER_DOMAIN}" "@${VM_GATEWAY}" 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | tail -1 || true)"
  node_apps="$(dig +short "test.${APPS_DOMAIN}" "@${VM_GATEWAY}" 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | tail -1 || true)"
  if [[ "${node_api}" == "${ACCESS_IP}" && "${node_apps}" == "${ACCESS_IP}" ]]; then
    ok "DNS (node view via ${VM_GATEWAY}): api + *.apps → ${ACCESS_IP}"
  else
    bad "DNS (node view via ${VM_GATEWAY}): api → '${node_api:-<nothing>}', *.apps → '${node_apps:-<nothing>}', expected ${ACCESS_IP}"
    bad "  a resolver that filters private-IP answers breaks sslip.io; 192.168.x.x is"
    bad "  filtered more often than 10.x.x.x, so ACCESS_MODE=local hits it first (docs/networking.md)"
  fi
else
  note "DNS (node view): libvirt network '${VM_NET_NAME}' not up yet — net-setup asserts it before installing"
fi

# --- lan mode: HAProxy ports must be free (or already ours) ------------------
if [[ "${ACCESS_MODE}" == lan ]]; then
  haproxy_is_ours=false
  grep -qs 'miniChRIS-OKD' /etc/haproxy/haproxy.cfg 2>/dev/null && haproxy_is_ours=true
  for port in 80 443 6443; do
    if [[ -z "$(ss -Hltn "sport = :${port}")" ]]; then
      ok "port ${port} free"
    elif [[ "${haproxy_is_ours}" == true ]]; then
      ok "port ${port} in use by the harness HAProxy"
    else
      bad "port ${port} already in use (docker? another proxy?) — lan mode needs 80/443/6443"
    fi
  done
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  log "all checks passed"
else
  die "${FAILURES} check(s) failed"
fi
