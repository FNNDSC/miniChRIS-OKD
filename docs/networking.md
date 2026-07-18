# Networking and DNS

OpenShift requires `api.<cluster>.<base>` and `*.apps.<cluster>.<base>` to
resolve before, during, and after the install. The harness gets this with
**zero DNS infrastructure** via [sslip.io](https://sslip.io): any hostname
with an embedded IP resolves to that IP
(`api.okd.10-0-0-33.sslip.io → 10.0.0.33`), for any client, with no
configuration.

The harness uses sslip.io's **dashed** IP form (`10-0-0-33.sslip.io`, not
`10.0.0.33.sslip.io`): the assisted-service that drives the agent-based
install rejects base domains embedding a dotted-decimal IP ("DNS format
mismatch … not be in dotted decimal format", observed 2026-07-15 on
4.22.0-okd-scos.6).

**The wildcard-probe carve-out:** the installer also verifies that
`validateNoWildcardDNS.<cluster>.<base>` does **not** resolve (a guard
against overly-broad wildcard zones) — but with sslip.io, everything under
the base domain resolves by construction. The libvirt network therefore
carries a dnsmasq passthrough option
(`local=/validatenowildcarddns.<cluster domain>/`, see
[okd/libvirt-net.xml.tpl](../okd/libvirt-net.xml.tpl)) so the node's
resolver answers NXDOMAIN for exactly that one probe name. `net-setup`
asserts both sides of the node's DNS view (probe blocked, `api.` resolving)
before any install starts. Clients outside the libvirt network are
unaffected.

The VM sits on a dedicated libvirt NAT network (default
`192.168.126.0/24`, name `okd-net`) with a **static DHCP reservation**
`VM_MAC → VM_IP` — that reservation is what makes the node's address
deterministic without nmstate config baked into the agent ISO (nmstate
would require `nmstatectl` on the host, which Ubuntu doesn't package).

## Access modes

### `local` (default) — developer's own box

The base domain derives from the **VM IP**: `okd.192-168-126-10.sslip.io`.
sslip.io resolves it straight to the VM, which the host reaches natively
over the libvirt bridge. No HAProxy, no firewall changes, no extra install
set. This matches the canonical SNO pattern (DNS pointing at the node).
Other machines on your LAN cannot reach the cluster (they can't route to
`192.168.126.x`).

**Escape hatch — reaching a `local`-mode cluster from another machine:**
not a supported day-to-day path (that's what `lan` mode is for), but handy
for spot checks. Tunnel through the harness host, which *can* route to the
VM:

```sh
# Option A: SOCKS proxy (no extra tools)
ssh -D 1080 <user>@<harness-host>
#   browser → SOCKS5 localhost:1080 → console URL works as-is
#   oc      → HTTPS_PROXY=socks5h://localhost:1080 oc login ...

# Option B: transparent routing (brew install sshuttle)
sshuttle -r <user>@<harness-host> 192.168.126.0/24
#   then use console/oc URLs directly
```

sslip.io names resolve to `192.168.126.10` on any machine; the tunnel just
makes that address reachable.

### `lan` — remote/headless box (e.g. miami.local)

The base domain derives from the **host's LAN IP**:
`okd.10-0-0-33.sslip.io`. Every client — your Mac, the host itself, even
pods inside the cluster (hairpin) — resolves cluster names to the host,
where HAProxy TCP-passthrough forwards into the VM:

```text
:6443 → VM_IP:6443   Kubernetes/OpenShift API (TLS terminates in cluster)
:443  → VM_IP:443    secure Routes, console
:80   → VM_IP:80     insecure Routes / HTTPS redirects
```

`net-setup` renders [okd/haproxy.cfg.tpl](../okd/haproxy.cfg.tpl) into
`/etc/haproxy/haproxy.cfg` (backing up any pre-existing config once, to
`haproxy.cfg.pre-minichris`) and opens 80/443/6443 in ufw/firewalld when
one is active.

**Ordering constraint:** HAProxy and the firewall openings must be up
*before* the agent install runs — install-time validations resolve and dial
`api.<domain>`, which loops through the host. `just okd-install` sequences
`net-setup` before everything else.

**Hairpin:** the node itself resolves `api-int.<domain>` to the host IP and
dials back through HAProxy into itself. This is why the firewall must
accept 6443 from the libvirt subnet too (the blanket allow rules cover it).

### Choosing and switching

The base domain is **immutable after install**. `local` vs `lan` is an
up-front choice per cluster; switching means
`just okd-nuke && just okd-install` (~1 h), not a config flip.

## Port table

| Port | Where | Purpose | Mode |
|---|---|---|---|
| 6443/tcp | host → VM | OpenShift API | forwarded in `lan`; direct in `local` |
| 443/tcp | host → VM | Routes (edge TLS), console | same |
| 80/tcp | host → VM | insecure Routes, redirects | same |
| 8090/tcp | host → VM (direct) | agent installer progress during bootstrap | both (libvirt bridge, not forwarded) |
| 22/tcp | host → VM (direct) | `ssh core@VM_IP` debugging | both (not forwarded) |

## Assumptions

- The host can resolve public DNS (sslip.io) — only *resolution* leaves the
  LAN; traffic never does.
- The resolver does not filter RFC1918 answers ("DNS rebind protection").
  Some router/dnsmasq setups do; `host-check` fails fast on it.
- `lan` mode: the host's LAN IP is stable (DHCP reservation or static).

## Fallback: local dnsmasq instead of sslip.io

If sslip.io is unreachable (egress-filtered network) or rebind-filtered,
serve the two records yourself on the harness box:

```sh
sudo apt-get install dnsmasq
cat <<EOF | sudo tee /etc/dnsmasq.d/okd.conf
# replace 10.0.0.33 with ACCESS_IP, okd.10-0-0-33.sslip.io with your domain
address=/api.okd.10-0-0-33.sslip.io/10.0.0.33
address=/apps.okd.10-0-0-33.sslip.io/10.0.0.33
EOF
sudo systemctl restart dnsmasq
```

Point clients (and the host's own resolver) at that dnsmasq, or set
`BASE_DOMAIN` in `config.local.env` to a domain you control. Per-client
resolver changes are the friction that made sslip.io the default.
