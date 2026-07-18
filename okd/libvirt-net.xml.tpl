<!-- libvirt-net.xml.tpl — dedicated NAT network for the OKD SNO VM.
     Rendered by scripts/net-setup.sh. The static DHCP reservation
     (VM_MAC -> VM_IP) is what makes the node's address deterministic
     without nmstate config in the agent ISO.

     The dnsmasq option answers NXDOMAIN for the assisted-installer's
     wildcard-DNS probe (validateNoWildcardDNS.<cluster domain>), which
     would otherwise resolve via sslip.io and block the install with
     "dns-wildcard-not-configured" — see docs/networking.md. Only that one
     name is carved out; api/api-int/*.apps still resolve normally. -->
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${VM_NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='virbr-okd' stp='on' delay='0'/>
  <ip address='${VM_GATEWAY}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${VM_DHCP_START}' end='${VM_DHCP_END}'/>
      <host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='local=/validatenowildcarddns.${CLUSTER_DOMAIN}/'/>
  </dnsmasq:options>
</network>
