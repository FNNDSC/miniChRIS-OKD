# agent-config.yaml.tpl — rendered by scripts/okd-render.sh.
#
# Deliberately minimal: the VM gets deterministic addressing from a static
# libvirt DHCP reservation (VM_MAC -> VM_IP) plus DNS/gateway from the
# libvirt network, so no nmstate networkConfig is needed here — which would
# require the nmstatectl binary on the host (not packaged for Ubuntu).
# rendezvousIP designates the single node as node zero.
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${VM_IP}
