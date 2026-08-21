# HAProxy configuration managed by miniChRIS-OKD (marker: miniChRIS-OKD).
# Rendered from okd/haproxy.cfg.tpl by scripts/net-setup.sh (lan mode only).
#
# Plain TCP passthrough of the three OpenShift entry ports from the host's
# LAN address into the SNO VM. TLS terminates inside the cluster (API server
# and router), never here.

global
    log /dev/log local0
    maxconn 4000
    daemon

defaults
    mode    tcp
    log     global
    option  tcplog
    timeout connect 10s
    timeout client  5m
    timeout server  5m

# Backends carry a -be suffix: HAProxy 3.3 drops support for a backend
# sharing its frontend's name (3.2 warns about it at config check).
frontend okd-api
    bind *:6443
    default_backend okd-api-be

backend okd-api-be
    server sno ${VM_IP}:6443 check

frontend okd-https
    bind *:443
    default_backend okd-https-be

backend okd-https-be
    server sno ${VM_IP}:443 check

frontend okd-http
    bind *:80
    default_backend okd-http-be

backend okd-http-be
    server sno ${VM_IP}:80 check
