#!/usr/bin/env bash
# host-survey.sh — survey a *candidate* host before anything is cloned or
# installed. Answers "could this box run the harness, and in which mode?"
# from a bare shell: no repo checkout, no libvirt, no sudo, nothing sourced.
#
#   ssh somebox 'bash -s' < scripts/host-survey.sh      # remote candidate
#   scripts/host-survey.sh [ssh-args…]                  # same, via ssh (user@box, -p 2222, …)
#   scripts/host-survey.sh                              # this box
#   just host-survey [ssh-args…]
#
# The survey's knobs (IMAGES_DIR, CLUSTER_NAME, VM_NET_CIDR, VM_IP) are read
# from the environment; in ssh mode they are forwarded to the remote side:
#   IMAGES_DIR=/data/okd just host-survey user@box
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

# ssh mode: run this same file on the remote host, forwarding the knobs.
if [[ $# -gt 0 ]]; then
  remote_cmd="bash -s"
  for v in IMAGES_DIR CLUSTER_NAME VM_NET_CIDR VM_IP; do
    [[ -n "${!v:-}" ]] && remote_cmd="${v}=$(printf '%q' "${!v}") ${remote_cmd}"
  done
  exec ssh "$@" "${remote_cmd}" < "${BASH_SOURCE[0]}"
fi

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
# Disk figures are GiB, as host-check's `df -BG` reports them.
CPU_HEADROOM=2; RAM_HEADROOM_MIB=8192; DISK_HEADROOM_GB=50
DEF_VCPUS=10; DEF_RAM_MIB=32768; DEF_DISK_GB=200       # Comfortable (defaults)
MIN_VCPUS=8;  MIN_RAM_MIB=24576; MIN_DISK_GB=150       # Minimum tier
HARD_VCPUS=4; HARD_RAM_MIB=16384; HARD_DISK_GB=120     # SNO will not come up below

CLUSTER_NAME="${CLUSTER_NAME:-okd}"
VM_NET_CIDR="${VM_NET_CIDR:-192.168.126.0/24}"
VM_IP="${VM_IP:-192.168.126.10}"
VM_BRIDGE="virbr-okd"                                  # okd/libvirt-net.xml.tpl
USER="${USER:-$(id -un)}"

printf '%sminiChRIS-OKD host survey%s — %s, %s\n' "${C_HDR}" "${C_OFF}" "$(uname -n)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- platform ---------------------------------------------------------------
hdr "platform"
if [[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]]; then
  ok "Linux x86_64, kernel $(uname -r)"
else
  # Nothing below means anything elsewhere (no /proc, no KVM, no getent).
  bad "need Linux x86_64, got $(uname -s)/$(uname -m) (macOS participates as a client only)"
  hdr "summary"
  bad "not a harness host"
  exit 1
fi

distro_id=""; distro_like=""; distro_name="$(uname -s)"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  distro_id="$(. /etc/os-release; echo "${ID:-}")"
  # shellcheck disable=SC1091
  distro_like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
  # shellcheck disable=SC1091
  distro_name="$(. /etc/os-release; echo "${PRETTY_NAME:-${ID:-?}}")"
fi
if have apt-get; then
  ok "distro: ${distro_name} — apt family, host-setup.sh is automated (validated: Ubuntu)"
elif have dnf || have yum; then
  note "distro: ${distro_name} — dnf family; install packages by hand per docs/requirements.md"
else
  note "distro: ${distro_name} (${distro_id:-?}${distro_like:+, like ${distro_like}}) — not apt/dnf; supply the tool list in docs/requirements.md manually"
fi

virt=""
if have systemd-detect-virt && v="$(systemd-detect-virt --vm 2>/dev/null)" && [[ "${v}" != none ]]; then
  virt="${v}"
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
# Only presence matters: qemu:///system opens /dev/kvm as the qemu user, not as you.
if [[ -e /dev/kvm ]]; then
  ok "/dev/kvm present"
else
  bad "/dev/kvm missing — KVM unavailable"
fi

# --- resources --------------------------------------------------------------
hdr "resources"
threads="$(nproc 2>/dev/null || echo 0)"
ram_mib=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024))
ok "threads: ${threads}"
ok "RAM: ${ram_mib} MiB MemTotal (runs ~4% under nameplate — this is the figure host-check uses)"

# The VM disk needs an SSD/NVMe — etcd fsync latency on spinning media is not
# viable (docs/requirements.md). Candidates: IMAGES_DIR if given, $HOME (a
# clone's default IMAGES_DIR is <clone>/okd/state/images), then every other
# local block-device mount with room for at least the hard floor.

# classify SOURCE FSTYPE → sets media, grade (2 SSD/NVMe, 1 unknown, 0 not viable)
classify() {
  local dev="${1%%\[*}" rota=""   # btrfs subvolumes read /dev/sda2[/@home]
  case "$2" in
    nfs|nfs4|cifs|smb3|smbfs|ceph|lustre|gpfs|beegfs|afs|glusterfs|fuse.*|9p|virtiofs|overlay|tmpfs)
      media="$2, network/virtual"; grade=0; return ;;
  esac
  [[ "${dev}" == /dev/* ]] && have lsblk && rota="$(lsblk -dno ROTA "${dev}" 2>/dev/null | tr -d ' ')"
  case "${rota}" in
    0) media="SSD/NVMe"; grade=2 ;;
    1) if [[ -n "${virt}" ]]; then
         # Paravirtual disks (virtio-scsi, Hyper-V, pvscsi, emulated SATA)
         # report rotational whatever backs them.
         media="virtual disk reporting rotational — check what backs it"; grade=1
       else
         media="spinning"; grade=0
       fi ;;
    *) media="unknown media"; grade=1 ;;
  esac
}

# disk_rank GIB → 3 defaults fit, 2 Minimum tier, 1 above the hard floor, 0 below
disk_rank() {
  local give=$(($1 - DISK_HEADROOM_GB))
  if   [[ ${give} -ge ${DEF_DISK_GB} ]]; then echo 3
  elif [[ ${give} -ge ${MIN_DISK_GB} ]]; then echo 2
  elif [[ ${give} -ge ${HARD_DISK_GB} ]]; then echo 1
  else echo 0; fi
}

cands=()
[[ -n "${IMAGES_DIR:-}" ]] && cands+=("${IMAGES_DIR}")
cands+=("${HOME}")
if have findmnt; then
  while read -r tgt src fstype avail; do
    [[ "${src}" == /dev/* ]] || continue
    case "${fstype}" in squashfs|iso9660|udf|vfat) continue ;; esac
    [[ $(( ${avail:-0} / 1073741824 )) -ge $((HARD_DISK_GB + DISK_HEADROOM_GB)) ]] || continue
    cands+=("$(printf '%b' "${tgt}")")             # -r escapes blanks as \x20
  done < <(findmnt -rn -b -o TARGET,SOURCE,FSTYPE,AVAIL 2>/dev/null)
else
  bad "findmnt (util-linux) missing — cannot assess the disks"
fi

best_dir=""; best_mnt=""; best_gb=0; best_grade=0; best_rank=-1; best_writable=false; chosen=false
seen=" "
for d in "${cands[@]}"; do
  probe="${d}"
  while [[ ! -d "${probe}" ]]; do probe="$(dirname "${probe}")"; done
  read -r mnt src fstype avail < <(findmnt -rn -b -o TARGET,SOURCE,FSTYPE,AVAIL -T "${probe}" 2>/dev/null) || continue
  mnt="$(printf '%b' "${mnt}")"; src="$(printf '%b' "${src}")"
  key="${src%%\[*}"                                # one entry per device (subvolumes, bind mounts)
  [[ "${seen}" == *" ${key} "* ]] && continue
  seen+="${key} "
  gb=$(( ${avail:-0} / 1073741824 ))
  classify "${src}" "${fstype}"

  # Where the images would go on this volume. okd-create-vm mkdirs and
  # okd-teardown deletes in IMAGES_DIR as you, so it must be yours to write.
  dir="${d}"; writable=false
  if [[ "${d}" == "${mnt}" && "${d}" != "${HOME}" && "${d}" != "${IMAGES_DIR:-}" ]]; then
    if [[ -w "${mnt}" ]]; then dir="${mnt%/}/okd-images"; writable=true
    elif [[ -d "${mnt%/}/${USER}" && -w "${mnt%/}/${USER}" ]]; then dir="${mnt%/}/${USER}/okd-images"; writable=true
    else dir="${mnt%/}/okd-images"; fi
  elif [[ -w "${probe}" ]]; then
    writable=true
  elif [[ -d "${d}" ]]; then
    dir="${d%/}/okd"                               # never chown a shared dir; use one below it
  fi

  label="holds ${d}"; [[ "${d}" == "${mnt}" ]] && label="mount point"
  [[ "${probe}" == "${d}" ]] || label="${label} (→ ${probe})"
  if [[ ${grade} -gt 0 ]]; then
    ok "disk: ${gb} GB free on ${mnt} (${src}, ${media}) — ${label}"
    rank="$(disk_rank "${gb}")"
    # An IMAGES_DIR you chose is the one assessed. Otherwise known SSD beats
    # unknown media, then the bigger tier; ties keep the earlier candidate
    # ($HOME: no override needed).
    if [[ "${chosen}" != true ]] \
        && [[ ${grade} -gt ${best_grade} || ( ${grade} -eq ${best_grade} && ${rank} -gt ${best_rank} ) ]]; then
      best_dir="${dir}"; best_mnt="${mnt}"; best_gb="${gb}"
      best_grade="${grade}"; best_rank="${rank}"; best_writable="${writable}"
    fi
    if [[ "${d}" == "${IMAGES_DIR:-}" ]]; then
      chosen=true
      [[ "${writable}" == true ]] || note "      IMAGES_DIR=${d} isn't writable by ${USER} — okd-create-vm and okd-teardown work there as you; use ${dir}"
    fi
  else
    note "disk: ${gb} GB free on ${mnt} (${src}, ${media}) — ${label} — not viable for the VM disk/etcd"
    [[ "${d}" == "${HOME}" ]] && note "      the clone's default IMAGES_DIR is <clone>/okd/state/images — clone outside \$HOME or set IMAGES_DIR"
  fi
done
[[ -n "${best_dir}" ]] || bad "no SSD/NVMe-backed volume found — set IMAGES_DIR to one and re-run"

# Tier placement, per resource. What the host can give the VM after headroom:
give_vcpus=$((threads - CPU_HEADROOM))
give_ram=$((ram_mib - RAM_HEADROOM_MIB))
give_disk=$((best_gb - DISK_HEADROOM_GB))
res_rank() {  # GIVE DEF MIN HARD → 3 defaults fit, 2 Minimum, 1 below Minimum, 0 below the floor
  if   [[ $1 -ge $2 ]]; then echo 3
  elif [[ $1 -ge $3 ]]; then echo 2
  elif [[ $1 -ge $4 ]]; then echo 1
  else echo 0; fi
}
cpu_r="$(res_rank "${give_vcpus}" "${DEF_VCPUS}" "${MIN_VCPUS}" "${HARD_VCPUS}")"
ram_r="$(res_rank "${give_ram}" "${DEF_RAM_MIB}" "${MIN_RAM_MIB}" "${HARD_RAM_MIB}")"
disk_r="$(res_rank "${give_disk}" "${DEF_DISK_GB}" "${MIN_DISK_GB}" "${HARD_DISK_GB}")"
tier_r=$(( cpu_r < ram_r ? cpu_r : ram_r )); tier_r=$(( disk_r < tier_r ? disk_r : tier_r ))
limits=()
[[ ${cpu_r}  -eq ${tier_r} ]] && limits+=("CPU")
[[ ${ram_r}  -eq ${tier_r} ]] && limits+=("RAM")
[[ ${disk_r} -eq ${tier_r} ]] && limits+=("disk")
limited_by="limited by ${limits[*]}"
tiers=(not-viable below-minimum minimum comfortable)
tier="${tiers[${tier_r}]}"

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
      ok "tier: Minimum (${limited_by}) — installs and runs ChRIS with overrides; sluggish console"
    else
      note "tier: between the hard floor and the Minimum tier (${limited_by}) — installs at the reduced size"
    fi
    # Slow operator settling is a CPU symptom; a smaller disk or VM RAM does not cause it.
    if [[ ${cpu_r} -le 1 ]]; then
      note "      too few vCPUs for operators to settle in time: add CLUSTER_STABLE_TIMEOUT=40m"
      note "      (docs/requirements.md: 'Hosts below the Minimum tier')"
      overrides+=("CLUSTER_STABLE_TIMEOUT=40m")
    fi ;;
  not-viable)
    bad "tier: below the hard floor (${limited_by}; VM needs ${HARD_VCPUS} vCPU / ${HARD_RAM_MIB} MiB / ${HARD_DISK_GB} GB + headroom) — SNO will not come up" ;;
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

# Routes covering the VM address, plus any inside the VM subnet. The harness's
# own network (an earlier install; okd-teardown keeps it) is not a clash.
if have ip; then
  routes="$( { ip -4 route show match "${VM_IP}"; ip -4 route show root "${VM_NET_CIDR}"; } 2>/dev/null \
             | grep -v '^default' | sort -u)"
  clash="$(grep -v " dev ${VM_BRIDGE} " <<<"${routes}" | head -1)"
  if [[ -n "${clash}" ]]; then
    bad "subnet ${VM_NET_CIDR} collides with an existing route (${clash% proto*}) — override VM_NET_CIDR/VM_IP"
  elif [[ -n "${routes}" ]]; then
    note "subnet ${VM_NET_CIDR} is the harness's own libvirt network (${VM_BRIDGE}) — left by an earlier install"
  else
    ok "subnet ${VM_NET_CIDR} free for the libvirt network"
  fi
fi

busy=""
if have ss; then
  busy="$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eo ':(80|443|6443)$' | tr -d ':' | sort -un | tr '\n' ' ')"
  if [[ -z "${busy}" ]]; then
    ok "ports 80/443/6443 free (lan mode runs HAProxy on them)"
  else
    note "ports in use: ${busy}— lan mode needs 80/443/6443; local mode does not (docker? another proxy?)"
  fi
fi

# ufw.service is a oneshot that stays "active" even with ufw disabled, so ask
# ufw.conf (world-readable) rather than systemd.
fws=()
systemctl is-active --quiet ufw 2>/dev/null && grep -qsE '^ENABLED=yes' /etc/ufw/ufw.conf && fws+=("ufw")
systemctl is-active --quiet firewalld 2>/dev/null && fws+=("firewalld")
systemctl is-active --quiet nftables 2>/dev/null && fws+=("nftables")
if [[ ${#fws[@]} -eq 0 ]]; then
  ok "firewall: none active"
elif [[ " ${fws[*]} " == *" ufw "* || " ${fws[*]} " == *" firewalld "* ]]; then
  ok "firewall: ${fws[*]} active — net-setup opens 80/443/6443 (lan mode)"
  [[ " ${fws[*]} " == *" nftables "* ]] && note "      nftables.service also loads its own rules — check they don't drop 80/443/6443"
else
  note "firewall: nftables active — net-setup only automates ufw/firewalld; open 80/443/6443 yourself in lan mode"
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
# The verdict rests on public (is sslip.io reachable at all), the VM address
# (local mode) and this host's address (lan mode); the 10.x line is context for
# hosts whose own address is 192.168.x, and doesn't feed the verdict.
public_ok=false; priv_ok=false; lan_ok=false
dns_probe "public  " 8.8.8.8          && public_ok=true
dns_probe "10.x    " 10.0.0.1         || true
dns_probe "192.168 " "${VM_IP}"       && priv_ok=true
if [[ -n "${lan_ip}" ]]; then
  dns_probe "this box" "${lan_ip}"    && lan_ok=true
fi

mode_advice=""
if [[ "${public_ok}" != true ]]; then
  bad "sslip.io is unreachable through this resolver — use the dnsmasq fallback or your own BASE_DOMAIN (docs/networking.md)"
elif [[ "${lan_ok}" == true && "${priv_ok}" == true ]]; then
  if [[ -z "${busy}" ]]; then
    ok "resolver passes private answers: ACCESS_MODE=local or lan both viable"
    mode_advice="either (local is the default; lan if other machines need to reach it)"
  else
    ok "resolver passes private answers: ACCESS_MODE=local works; lan resolves too but needs ports ${busy}freed"
    mode_advice="local (lan once ports ${busy}are free)"
  fi
elif [[ "${lan_ok}" == true ]]; then
  if [[ -z "${busy}" ]]; then
    ok "resolver filters 192.168.x but passes this host's address: use ACCESS_MODE=lan"
    mode_advice="lan"
  else
    bad "resolver filters 192.168.x, so only lan mode resolves — but ports ${busy}are in use; free them first"
  fi
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
# Bounded search: home directories can be big or network-mounted.
while IFS= read -r f; do
  [[ -n "${f}" ]] && note "existing clone at ${f%/okd/libvirt-net.xml.tpl}"
done < <(timeout 5 find -L "${HOME}" /opt /srv -maxdepth 6 \
           \( -name .git -o -name node_modules -o -name .cache -o -name state \) -prune \
           -o -type f -name libvirt-net.xml.tpl -path '*/okd/*' -print 2>/dev/null | sort -u)

# --- summary -----------------------------------------------------------------
hdr "summary"
if [[ "${FAILURES}" -gt 0 ]]; then
  bad "${FAILURES} blocking finding(s) above — not a viable harness host as-is"
  exit 1
fi
ok "viable harness host (tier: ${tier})"
[[ -n "${mode_advice}" ]] && note "ACCESS_MODE: ${mode_advice}"
if [[ "${best_dir}" != "${HOME}" ]]; then
  if [[ "${best_writable}" != true ]]; then
    note "${best_dir} (on ${best_mnt}) needs to be yours to write — create it first:"
    note "      sudo install -d -o ${USER} -g $(id -gn) ${best_dir}"
  fi
  overrides=("IMAGES_DIR=${best_dir}" ${overrides[@]+"${overrides[@]}"})
fi
if [[ ${#overrides[@]} -gt 0 ]]; then
  note "suggested config.local.env:"
  for o in "${overrides[@]}"; do printf '      %s\n' "${o}"; done
fi
note "next: git clone https://github.com/FNNDSC/miniChRIS-OKD && cd miniChRIS-OKD && bash scripts/host-setup.sh && just host-check"
exit 0
