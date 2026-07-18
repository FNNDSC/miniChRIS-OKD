# install-config.yaml.tpl — single-node OKD shape for the agent-based
# installer. Rendered by scripts/okd-render.sh into okd/state/install/
# (openshift-install consumes it; the rendered copy stays in okd/state/render/).
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  name: master
  replicas: 1
  architecture: amd64
  hyperthreading: Enabled
compute:
  - name: worker
    replicas: 0
    architecture: amd64
    hyperthreading: Enabled
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: ${VM_NET_CIDR}
platform:
  none: {}
# OKD requires no Red Hat pull secret; a well-formed placeholder suffices.
pullSecret: '{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'
sshKey: '${SSH_PUB_KEY}'
