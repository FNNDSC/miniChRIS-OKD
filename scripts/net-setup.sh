#!/usr/bin/env bash
# net-setup.sh — prepare the network path to the cluster. Idempotent.
#
#   both modes : define/start the dedicated libvirt NAT network with a
#                static DHCP reservation VM_MAC -> VM_IP.
#   lan mode   : additionally render + install the HAProxy TCP passthrough
#                (host:6443/443/80 -> VM) and open firewall ports. This must
#                happen BEFORE the agent install runs: install-time
#                validations dial api.<domain>, which loops through the host.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd virsh envsubst

[[ "${VM_NET_PREFIX}" == 24 ]] || die "VM_NET_CIDR must be a /24 (got ${VM_NET_CIDR})"

# --- libvirt NAT network ------------------------------------------------------
render_template "${REPO_ROOT}/okd/libvirt-net.xml.tpl" "${RENDER_DIR}/libvirt-net.xml"

if virsh_c net-info "${VM_NET_NAME}" >/dev/null 2>&1; then
  # Redefine when the definition drifted from the template (e.g. the
  # wildcard-DNS carve-out below, or a changed cluster domain). dnsmasq
  # options only apply at network start, so this needs a bounce — refuse
  # while the VM is up rather than yank its bridge.
  if virsh_c net-dumpxml "${VM_NET_NAME}" | grep -q "validatenowildcarddns.${CLUSTER_DOMAIN}"; then
    log "libvirt network '${VM_NET_NAME}' already defined and current"
  else
    vm_exists && die "network '${VM_NET_NAME}' needs redefining but VM '${VM_NAME}' exists — 'just okd-teardown' first"
    virsh_c net-destroy "${VM_NET_NAME}" >/dev/null 2>&1 || true
    virsh_c net-undefine "${VM_NET_NAME}" >/dev/null
    virsh_c net-define "${RENDER_DIR}/libvirt-net.xml"
    log "redefined libvirt network '${VM_NET_NAME}' from template"
  fi
else
  virsh_c net-define "${RENDER_DIR}/libvirt-net.xml"
  log "defined libvirt network '${VM_NET_NAME}' (${VM_NET_CIDR}, ${VM_MAC} → ${VM_IP})"
fi
virsh_c net-autostart "${VM_NET_NAME}" >/dev/null
if [[ "$(virsh_c net-info "${VM_NET_NAME}" | awk '/^Active:/ {print $2}')" != yes ]]; then
  virsh_c net-start "${VM_NET_NAME}"
  log "started libvirt network '${VM_NET_NAME}'"
fi

# The node must see NXDOMAIN for the installer's wildcard probe while still
# resolving the API name — assert both through the network's own dnsmasq.
if command -v dig >/dev/null 2>&1; then
  probe_rc=0
  dig +short "validatenowildcarddns.${CLUSTER_DOMAIN}" "@${VM_GATEWAY}" | grep -q . && probe_rc=1
  api_ip="$(dig +short "api.${CLUSTER_DOMAIN}" "@${VM_GATEWAY}" | tail -1)"
  if [[ "${probe_rc}" -eq 0 && "${api_ip}" == "${ACCESS_IP}" ]]; then
    log "node DNS view OK: wildcard probe → NXDOMAIN, api → ${api_ip}"
  else
    warn "node DNS view unexpected (probe blocked: $((1 - probe_rc)), api → '${api_ip}'); install validations may fail"
  fi
fi

# --- lan mode: HAProxy + firewall ---------------------------------------------
if [[ "${ACCESS_MODE}" != lan ]]; then
  log "ACCESS_MODE=local — no HAProxy/firewall changes needed; done"
  exit 0
fi

require_cmd haproxy
render_template "${REPO_ROOT}/okd/haproxy.cfg.tpl" "${RENDER_DIR}/haproxy.cfg"
haproxy -c -f "${RENDER_DIR}/haproxy.cfg" >/dev/null

if ! cmp -s "${RENDER_DIR}/haproxy.cfg" /etc/haproxy/haproxy.cfg; then
  # Preserve a distro/original config once, before our first take-over.
  if [[ -f /etc/haproxy/haproxy.cfg ]] && ! grep -qs 'miniChRIS-OKD' /etc/haproxy/haproxy.cfg; then
    sudo cp -n /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.pre-minichris
    log "backed up existing config to /etc/haproxy/haproxy.cfg.pre-minichris"
  fi
  sudo install -m 644 "${RENDER_DIR}/haproxy.cfg" /etc/haproxy/haproxy.cfg
  log "installed HAProxy config (:80/:443/:6443 → ${VM_IP})"
fi
sudo systemctl enable --now haproxy >/dev/null 2>&1
sudo systemctl reload-or-restart haproxy

# Firewall: open the three forwarded ports if a firewall is active. This also
# covers the hairpin path — the VM itself dials HOST_IP:6443 for api-int.
if command -v ufw >/dev/null 2>&1 && sudo ufw status | head -1 | grep -q 'Status: active'; then
  for port in 80 443 6443; do sudo ufw allow "${port}/tcp" >/dev/null; done
  log "ufw: allowed 80,443,6443/tcp"
elif command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  for port in 80 443 6443; do sudo firewall-cmd -q --permanent --add-port="${port}/tcp"; done
  sudo firewall-cmd -q --reload
  log "firewalld: allowed 80,443,6443/tcp"
else
  log "no active ufw/firewalld detected — ensure 80/443/6443 are reachable on ${HOST_IP}"
fi

log "network setup complete — cluster will be reachable at *.${CLUSTER_DOMAIN} via ${ACCESS_IP}"
