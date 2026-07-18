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

frontend okd-api
    bind *:6443
    default_backend okd-api

backend okd-api
    server sno ${VM_IP}:6443 check

frontend okd-https
    bind *:443
    default_backend okd-https

backend okd-https
    server sno ${VM_IP}:443 check

frontend okd-http
    bind *:80
    default_backend okd-http

backend okd-http
    server sno ${VM_IP}:80 check
