#!/usr/bin/env bash
# host-survey.sh — survey a *candidate* host before anything is cloned or
# installed. Answers "could this box run the harness, and in which mode?"
# from a bare shell: no repo checkout, no libvirt, no sudo, nothing sourced.
#
#   ssh somebox 'bash -s' < scripts/host-survey.sh      # remote candidate
#   scripts/host-survey.sh                              # this box
#   just host-survey [host]
#
# This is deliberately *not* host-check: host-check runs inside a prepared
# clone and gates an install against the configured VM size. The survey runs
# earlier — on a machine nobody has touched yet — and reports what host-check
# cannot: which sizing tier the box lands in and what overrides it needs,
# whether the volume that would hold the VM is spinning (etcd needs NVMe/SSD),
# whether the distro is on the automated host-setup path, and whether the
# resolver passes 10.x *and* 192.168.x sslip.io answers — i.e. which
# ACCESS_MODE is safe to choose, before the choice becomes immutable at
# install time (docs/networking.md; FNNDSC/HARBOR-planning#129).
#
# Read-only. Exit 0 = viable (possibly with overrides), 1 = not viable.
# Things host-setup fixes (missing packages, inactive libvirt, group
# membership) are reported as notes, not failures.

set -uo pipefail

if [[ -t 1 ]]; then
  C_OK=$'\033[32m' C_BAD=$'\033[31m' C_NOTE=$'\033[33m' C_HDR=$'\033[1;34m' C_OFF=$'\033[0m'
else
  C_OK='' C_BAD='' C_NOTE='' C_HDR='' C_OFF=''
fi
FAILURES=0
hdr()  { printf '\n%s== %s%s\n' "${C_HDR}" "$*" "${C_OFF}"; }
ok()   { printf '  %s✓%s %s\n' "${C_OK}" "${C_OFF}" "$*"; }
bad()  { printf '  %s✗%s %s\n' "${C_BAD}" "${C_OFF}" "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf '  %s·%s %s\n' "${C_NOTE}" "${C_OFF}" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Sizing, kept in step with config.env defaults, host-check's headroom and
# floors, and the tiers in docs/requirements.md. Host figures = VM + headroom.
CPU_HEADROOM=2; RAM_HEADROOM_MIB=8192; DISK_HEADROOM_GB=50
DEF_VCPUS=10; DEF_RAM_MIB=32768; DEF_DISK_GB=200       # Comfortable (defaults)
MIN_VCPUS=8;  MIN_RAM_MIB=24576; MIN_DISK_GB=150       # Minimum tier
HARD_VCPUS=4; HARD_RAM_MIB=16384; HARD_DISK_GB=120     # SNO will not come up below

CLUSTER_NAME="${CLUSTER_NAME:-okd}"
VM_NET_CIDR="${VM_NET_CIDR:-192.168.126.0/24}"
VM_IP="${VM_IP:-192.168.126.10}"

printf '%sminiChRIS-OKD host survey%s — %s, %s\n' "${C_HDR}" "${C_OFF}" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- platform ---------------------------------------------------------------
hdr "platform"
if [[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]]; then
  ok "Linux x86_64, kernel $(uname -r)"
else
  bad "need Linux x86_64, got $(uname -s)/$(uname -m) (macOS participates as a client only)"
fi

distro_id=""; distro_like=""; distro_name="$(uname -s)"
if [[ -r /etc/os-release ]]; then
  distro_id="$(. /etc/os-release; echo "${ID:-}")"
  distro_like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
  distro_name="$(. /etc/os-release; echo "${PRETTY_NAME:-${ID:-?}}")"
fi
if have apt-get; then
  ok "distro: ${distro_name} — apt family, host-setup.sh is automated (validated: Ubuntu)"
elif have dnf || have yum; then
  note "distro: ${distro_name} — dnf family; install packages by hand per docs/requirements.md"
else
  note "distro: ${distro_name} (${distro_id:-?}${distro_like:+, like ${distro_like}}) — not apt/dnf; supply the tool list in docs/requirements.md manually"
fi

if have systemd-detect-virt && virt="$(systemd-detect-virt 2>/dev/null)" && [[ "${virt}" != none ]]; then
  note "this host is itself a VM (${virt}) — nested virtualization; expect slower installs"
fi

# --- virtualization ---------------------------------------------------------
hdr "virtualization"
cpu_model="$(awk -F: '/^model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
if grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo 2>/dev/null; then
  ok "CPU: ${cpu_model:-?} — VT-x/AMD-V present"
else
  bad "CPU: ${cpu_model:-?} — no vmx/svm flag; enable VT-x/AMD-V in firmware (nested virt if this is a VM)"
fi
if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ok "/dev/kvm present and accessible to ${USER}"
  else
    note "/dev/kvm present but not accessible to ${USER} (host-setup adds the kvm/libvirt groups; re-login after)"
  fi
else
  bad "/dev/kvm missing — KVM unavailable"
fi

# --- resources --------------------------------------------------------------
hdr "resources"
threads="$(nproc 2>/dev/null || echo 0)"
ram_mib=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024))
ok "threads: ${threads}"
ok "RAM: ${ram_mib} MiB MemTotal (runs ~4% under nameplate — this is the figure host-check uses)"

# Candidate volumes for the VM image: IMAGES_DIR if given, else the usual
# suspects. The VM disk needs an SSD/NVMe — etcd fsync latency on spinning
# media is not viable (docs/requirements.md).
best_dir=""; best_gb=0
declare -A seen_mount=()
for d in "${IMAGES_DIR:-}" "${HOME}" /var/lib/libvirt/images /; do
  [[ -n "${d}" ]] || continue
  probe="${d}"
  while [[ ! -d "${probe}" ]]; do probe="$(dirname "${probe}")"; done
  read -r src fstype mnt avail_gb < <(df -BG --output=source,fstype,target,avail "${probe}" 2>/dev/null | tail -1 | tr -d 'G') || continue
  [[ -n "${mnt:-}" && -z "${seen_mount[${mnt}]:-}" ]] || continue
  seen_mount["${mnt}"]=1
  rota="?"
  if [[ "${src}" == /dev/* ]] && have lsblk; then
    rota="$(lsblk -dno ROTA "${src}" 2>/dev/null | tr -d ' ' || true)"
  fi
  case "${fstype}" in
    nfs|nfs4|cifs|smb3|fuse.*|9p|virtiofs|overlay|tmpfs)
       media="${fstype}, network/virtual"; usable=false ;;
    *) case "${rota}" in
         0) media="SSD/NVMe"; usable=true ;;
         1) media="spinning"; usable=false ;;
         *) media="unknown media"; usable=true ;;
       esac ;;
  esac
  label="${d}"; [[ "${probe}" == "${d}" ]] || label="${d} (→ ${probe})"
  if [[ "${usable}" == true ]]; then
    ok "disk: ${avail_gb} GB free on ${mnt} (${src}, ${media}) for ${label}"
    if [[ "${avail_gb}" -gt "${best_gb}" ]]; then best_gb="${avail_gb}"; best_dir="${d}"; fi
  else
    note "disk: ${avail_gb} GB free on ${mnt} (${src}, ${media}) for ${label} — not viable for the VM disk/etcd"
    [[ "${d}" == "${HOME}" ]] && note "      the clone's default IMAGES_DIR is <clone>/okd/state/images — clone outside \$HOME or set IMAGES_DIR"
  fi
done
[[ -n "${best_dir}" ]] || bad "no SSD/NVMe-backed volume found among the candidate paths — set IMAGES_DIR to one"

# Tier placement. What the host can give the VM after headroom:
give_vcpus=$((threads - CPU_HEADROOM))
give_ram=$((ram_mib - RAM_HEADROOM_MIB))
give_disk=$((best_gb - DISK_HEADROOM_GB))
tier=""
if   [[ ${give_vcpus} -ge ${DEF_VCPUS}  && ${give_ram} -ge ${DEF_RAM_MIB}  && ${give_disk} -ge ${DEF_DISK_GB}  ]]; then tier="comfortable"
elif [[ ${give_vcpus} -ge ${MIN_VCPUS}  && ${give_ram} -ge ${MIN_RAM_MIB}  && ${give_disk} -ge ${MIN_DISK_GB}  ]]; then tier="minimum"
elif [[ ${give_vcpus} -ge ${HARD_VCPUS} && ${give_ram} -ge ${HARD_RAM_MIB} && ${give_disk} -ge ${HARD_DISK_GB} ]]; then tier="below-minimum"
else tier="not-viable"; fi

overrides=()
case "${tier}" in
  comfortable)
    ok "tier: Comfortable — the committed defaults (${DEF_VCPUS} vCPU / ${DEF_RAM_MIB} MiB / ${DEF_DISK_GB} GB) fit" ;;
  minimum|below-minimum)
    vcpus=$(( give_vcpus < DEF_VCPUS ? give_vcpus : DEF_VCPUS ))
    ram=$(( give_ram < DEF_RAM_MIB ? give_ram : DEF_RAM_MIB ))
    disk=$(( give_disk < DEF_DISK_GB ? give_disk : DEF_DISK_GB ))
    [[ ${vcpus} -lt ${DEF_VCPUS}  ]] && overrides+=("VM_VCPUS=${vcpus}")
    [[ ${ram}   -lt ${DEF_RAM_MIB} ]] && overrides+=("VM_RAM_MIB=${ram}")
    [[ ${disk}  -lt ${DEF_DISK_GB} ]] && overrides+=("VM_DISK_GB=${disk}")
    if [[ "${tier}" == minimum ]]; then
      ok "tier: Minimum — installs and runs ChRIS with overrides; sluggish console"
    else
      note "tier: between the hard floor and the Minimum tier — installs, but operator settling is slow;"
      note "      add CLUSTER_STABLE_TIMEOUT=40m (docs/requirements.md: 'Hosts below the Minimum tier')"
      overrides+=("CLUSTER_STABLE_TIMEOUT=40m")
    fi ;;
  not-viable)
    bad "tier: below the hard floor (VM needs ${HARD_VCPUS} vCPU / ${HARD_RAM_MIB} MiB / ${HARD_DISK_GB} GB + headroom) — SNO will not come up" ;;
esac

# --- network ----------------------------------------------------------------
hdr "network"
lan_ip=""; lan_dev=""
if have ip; then
  read -r lan_dev lan_ip < <(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="src")s=$(i+1)}; print d, s; exit}') || true
fi
if [[ -n "${lan_ip}" ]]; then
  ok "primary address: ${lan_ip} on ${lan_dev} (lan mode: needs to be stable — DHCP reservation or static)"
else
  note "could not determine a primary IPv4 address (no default route?) — lan mode needs one"
fi

if have ip && ip -4 route 2>/dev/null | grep -q "^${VM_NET_CIDR%/*}" ; then
  bad "subnet ${VM_NET_CIDR} already routed on this host — collides with the libvirt network (override VM_NET_CIDR/VM_IP)"
else
  ok "subnet ${VM_NET_CIDR} free for the libvirt network"
fi

if have ss; then
  busy="$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eo ':(80|443|6443)$' | tr -d ':' | sort -u | tr '\n' ' ')"
  if [[ -z "${busy}" ]]; then
    ok "ports 80/443/6443 free (lan mode runs HAProxy on them)"
  else
    note "ports in use: ${busy}— lan mode needs 80/443/6443; local mode does not (docker? another proxy?)"
  fi
fi

fw="none"
for svc in ufw firewalld nftables; do
  systemctl is-active --quiet "${svc}" 2>/dev/null && fw="${svc}"
done
if [[ "${fw}" == none ]]; then
  ok "firewall: none active"
elif [[ "${fw}" == nftables ]]; then
  note "firewall: nftables active — net-setup only automates ufw/firewalld; open 80/443/6443 yourself in lan mode"
else
  ok "firewall: ${fw} active — net-setup opens 80/443/6443 (lan mode) and accepts the libvirt subnet"
fi

# --- DNS: which ACCESS_MODE is safe? ----------------------------------------
# The harness names its cluster <name>.<dashed-ip>.sslip.io. 'local' mode puts
# the VM's 192.168.x address in public DNS; 'lan' mode the host's LAN address.
# Rebind-protecting resolvers strip one or both. host-check only tests the
# mode already configured; probing every class here lets you choose first.
hdr "DNS (sslip.io through this host's resolver)"
resolvers="$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
if have resolvectl; then
  r2="$(resolvectl status 2>/dev/null | awk -F': ' '/DNS Servers/ {print $2}' | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  [[ -n "${r2}" ]] && resolvers="${r2}"
fi
note "resolver(s): ${resolvers:-unknown}"

# resolve NAME → first IPv4 or empty; bounded, never aborts the script.
resolve() {
  timeout 10 getent hosts "$1" 2>/dev/null | awk '{print $1; exit}' || true
}
dns_probe() {  # LABEL IP
  local label="$1" ip="$2" name got
  name="test.apps.${CLUSTER_NAME}.${ip//./-}.sslip.io"
  got="$(resolve "${name}")"
  if [[ "${got}" == "${ip}" ]]; then ok "${label}: ${name} → ${got}"; return 0
  else note "${label}: ${name} → '${got:-<nothing>}' (expected ${ip})"; return 1; fi
}
public_ok=false; priv_ok=false; lan_ok=false
dns_probe "public  " 8.8.8.8          && public_ok=true
dns_probe "10.x    " 10.0.0.33        || true
dns_probe "192.168 " "${VM_IP}"       && priv_ok=true
if [[ -n "${lan_ip}" ]]; then
  dns_probe "this box" "${lan_ip}"    && lan_ok=true
fi

mode_advice=""
if [[ "${public_ok}" != true ]]; then
  bad "sslip.io is unreachable through this resolver — use the dnsmasq fallback or your own BASE_DOMAIN (docs/networking.md)"
elif [[ "${lan_ok}" == true && "${priv_ok}" == true ]]; then
  ok "resolver passes private answers: ACCESS_MODE=local or lan both viable"
  mode_advice="either (local is the default; lan if other machines need to reach it)"
elif [[ "${lan_ok}" == true ]]; then
  ok "resolver filters 192.168.x but passes this host's address: use ACCESS_MODE=lan"
  mode_advice="lan"
elif [[ "${priv_ok}" == true ]]; then
  ok "resolver passes 192.168.x: ACCESS_MODE=local works; lan would not resolve this host's address"
  mode_advice="local"
else
  bad "resolver strips private-IP answers (rebind protection) — neither mode works without the dnsmasq fallback"
fi

# --- tooling and existing state --------------------------------------------
hdr "tooling"
missing=()
for cmd in virsh virt-install qemu-img envsubst jq curl ss getent openssl dig just helm python3; do
  if have "${cmd}"; then ok "tool: ${cmd}"; else note "tool: ${cmd} missing"; missing+=("${cmd}"); fi
done
if have haproxy; then ok "tool: haproxy (lan mode)"; else note "tool: haproxy missing (lan mode only)"; missing+=("haproxy"); fi
if have python3 && python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
  ok "python3 venv + ensurepip (smoke test)"
else
  note "python3 venv/ensurepip missing (apt: python3-venv) — needed by 'just smoke'"
fi
[[ ${#missing[@]} -eq 0 ]] || note "host-setup.sh installs the above on apt hosts; see docs/requirements.md otherwise"

hdr "existing state"
if systemctl is-active --quiet libvirtd 2>/dev/null \
    || systemctl is-active --quiet virtqemud.service 2>/dev/null \
    || systemctl is-active --quiet virtqemud.socket 2>/dev/null; then
  ok "libvirt daemon active"
else
  note "no libvirt daemon active (host-setup enables it)"
fi
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then
  ok "${USER} is in the libvirt group"
else
  note "${USER} not in the libvirt group (host-setup adds it; re-login after)"
fi
if have virsh && virsh -c qemu:///system list --all >/dev/null 2>&1; then
  vms="$(virsh -c qemu:///system list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
  nets="$(virsh -c qemu:///system net-list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
  ok "libvirt reachable — VMs: ${vms:-none}; networks: ${nets:-none}"
  [[ " ${vms} " == *" okd-sno "* ]] && note "a VM named okd-sno already exists — an earlier harness install? ('just okd-teardown' to reuse the box)"
fi
if grep -qs 'miniChRIS-OKD' /etc/haproxy/haproxy.cfg 2>/dev/null; then
  note "/etc/haproxy/haproxy.cfg carries the harness marker — a previous lan-mode install configured HAProxy here"
fi
for d in "${HOME}/miniChRIS-OKD" "${HOME}/src/miniChRIS-OKD" /opt/miniChRIS-OKD; do
  [[ -d "${d}/.git" ]] && note "existing clone at ${d}"
done

# --- summary -----------------------------------------------------------------
hdr "summary"
if [[ "${FAILURES}" -gt 0 ]]; then
  bad "${FAILURES} blocking finding(s) above — not a viable harness host as-is"
  exit 1
fi
ok "viable harness host (tier: ${tier})"
[[ -n "${mode_advice}" ]] && note "ACCESS_MODE: ${mode_advice}"
[[ -n "${best_dir}" && "${best_dir}" != "${HOME}" ]] && overrides=("IMAGES_DIR=${best_dir}" "${overrides[@]}")
if [[ ${#overrides[@]} -gt 0 ]]; then
  note "suggested config.local.env:"
  for o in "${overrides[@]}"; do printf '      %s\n' "${o}"; done
fi
note "next: git clone https://github.com/FNNDSC/miniChRIS-OKD && cd miniChRIS-OKD && bash scripts/host-setup.sh && just host-check"
exit 0
