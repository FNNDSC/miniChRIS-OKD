# Troubleshooting

Ordered roughly by install-lifecycle stage. When in doubt:
`just okd-teardown && just okd-install` is ~1 h and always safe.

## Where the logs are

| What | Where |
|---|---|
| Install-time state & logs | `okd/state/install/.openshift_install.log` |
| Agent installer progress (bootstrap) | `curl http://<VM_IP>:8090/api/assisted-install/v2/...` or VM console |
| VM console (graphical) | `virsh -c qemu:///system domdisplay okd-sno` → VNC on the host (tunnel: `ssh -L 5900:127.0.0.1:5900 <host>`) |
| Node shell after SCOS is on disk | `ssh -i okd/state/ssh/id_ed25519 core@<VM_IP>` |
| Node journal | on the node: `journalctl -b` (agent phase: `journalctl -u assisted-service -u agent`) |
| Full diagnostic bundle | `openshift-install --dir okd/state/install agent gather logs` |
| Verify report + detail log | `okd/state/reports/` |

## SSH session dropped during `okd-install`

The cluster-side install is unaffected: once the VM boots from the agent
ISO, everything runs inside the VM and completes without the host session.
Only the host-side chain dies with your terminal — typically the wait,
post-install, and verify steps. Reconnect and resume with:

```sh
just okd-wait && just okd-postinstall && just okd-verify
```

(All idempotent. Do **not** rerun `just okd-install` — it refuses while the
VM exists, to protect a live cluster.) To see where things stand without a
session: `virsh -c qemu:///system list`, `tail -f
okd/state/install/.openshift_install.log`, or `curl -k
https://api.<cluster domain>:6443/healthz`. For long runs, start inside
`tmux` or with `nohup just okd-install > install.log 2>&1 &`.

## Install stalls

- **`wait-for bootstrap-complete` times out** — re-run `just okd-wait`
  (safe). Check the VM is running (`virsh -c qemu:///system list`) and that
  `api.<domain>:6443` is reachable from the host (`lan` mode: is HAProxy
  up? `systemctl status haproxy`).
- **ISO boots but nothing happens for a long time** — first boot writes
  SCOS to disk and reboots; 10–15 quiet minutes are normal. Watch via VNC.
- **Cluster registration loops: "release image … does not support requested
  CPU architecture multi"** (hit on 4.22.0-okd-scos.6, 2026-07-15). OKD's
  release digest is a multi-arch manifest list (amd64+arm64) while the
  installer's embedded metadata declares x86_64 only; on the node,
  `agent-register-cluster.service` requests `cpu_architecture=multi` and
  assisted-service rejects it, retrying every 30 s forever. Symptoms: agent
  REST API (`:8090`) up but no cluster ever registered;
  `wait-for bootstrap-complete` times out with "Waiting for cluster install
  to initialize". **Fix (automated in `okd-create-iso.sh`):** build the ISO
  with `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` pinned to the amd64 child
  digest (`oc image info --filter-by-os linux/amd64 -o json <release> | jq -r
  .digest`), so client and server agree on x86_64. Requires rebuilding the
  ISO and reinstalling the VM (`just okd-teardown && just okd-install`).
- **Cluster registration loops: "DNS format mismatch: … not be in dotted
  decimal format"** (hit 2026-07-15). assisted-service rejects base domains
  that embed a dotted-decimal IP, which rules out sslip.io's dotted form
  (`10.0.0.33.sslip.io`). The harness therefore derives the dashed form
  (`10-0-0-33.sslip.io`) in `scripts/lib/common.sh`. If you override
  `BASE_DOMAIN`, keep it free of dotted-decimal segments.
- **Host validation fails: "DNS wildcard configuration was detected …
  dns-wildcard-not-configured"** (hit 2026-07-15). The installer probes
  `validateNoWildcardDNS.<cluster domain>` and blocks while it resolves —
  which, under sslip.io, it always does. Fixed structurally by the dnsmasq
  carve-out in the libvirt network (see
  [networking.md](networking.md)); `net-setup` re-applies and verifies it.
  If you see this, the network definition predates the carve-out: run
  `just okd-teardown`, then `just okd-install` (net-setup redefines the
  network).
- **Known agent-installer workarounds from older OKD releases** (4.18-era,
  documented at remote-lab.net; *not expected* on the pinned 4.22):
  - bootstrap ISO override needed when the SCOS bootimage lagged the
    release payload;
  - assisted-service PostgreSQL failing to start on the rendezvous host —
    nudge with `systemctl restart assisted-service` on the node.
- **`create image` fails downloading the boot image** — network/proxy
  problem; the image caches under `~/.cache/agent/` once fetched.

## DNS

- **`host-check` DNS failure / names don't resolve** — your resolver
  filters private-IP answers (DNS rebind protection, common on home
  routers). Fix the router (whitelist `sslip.io`) or use the dnsmasq
  fallback in [networking.md](networking.md).
- **Names resolve on the host but not from your Mac** (`lan` mode) — the
  Mac's resolver has the same rebind issue, or you installed in `local`
  mode (base domain on `192.168.126.x`, unreachable from the LAN —
  reinstall in `lan` mode).

## Certificates and long-lived clusters

- **24-hour certificate rotation:** a fresh cluster rotates its bootstrap
  certificates ~24 h after install. Keep the VM running through the first
  day if you can; if it was down across the window, boot it and wait —
  recovery is automatic but can take 15+ minutes.
- **Pending CSRs after a long shutdown** (`x509: certificate has expired`
  from kubelet, node `NotReady`):

  ```sh
  eval "$(just okd-kubeconfig)"
  oc get csr -o name | xargs -r oc adm certificate approve
  ```

- **Dormant >2 weeks:** recreate (`just okd-teardown && just okd-install`)
  instead of resurrecting — it's faster than certificate archaeology.
- **Desktop suspend/resume (`local` mode):** big clock jumps confuse etcd
  and kube certs; prefer leaving the VM running or shutting it down cleanly
  (`virsh -c qemu:///system shutdown okd-sno`) before suspending the host.

## libvirt / VM

- **`cannot talk to qemu:///system`** — you're not in the `libvirt` group
  yet; re-login (host-setup adds you).
- **qemu can't open the disk image** (`Permission denied`) — the qemu user
  can't traverse to `IMAGES_DIR` (e.g. `0700` home directories). Either
  `setfacl -m u:libvirt-qemu:x` each path component, or set
  `IMAGES_DIR=/var/lib/libvirt/images/okd` in `config.local.env`.
- **`--osinfo centos-stream10` rejected** — old libosinfo; the script
  auto-falls-back to `generic` (harmless: all devices are explicitly
  virtio).

## HAProxy / ports (`lan` mode)

- **HAProxy won't start / can't bind `:6443` on a Fedora/RHEL host** —
  SELinux blocks the non-standard port: `sudo setsebool -P
  haproxy_connect_any 1` (see [requirements.md](requirements.md#distro-support)).
- **`host-check` reports 80/443 busy** — usually docker or another proxy on
  the host. Stop it or move it; the harness needs the standard ports so
  Routes work without port suffixes.
- **API reachable but Routes aren't** — check both HAProxy backends:
  `echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock` or simply
  `curl -vk https://console-openshift-console.apps.<domain>`.
- **Cluster-internal weirdness after host firewall changes** — remember the
  hairpin: the node dials `HOST_IP:6443` for `api-int`. The ufw/firewalld
  allow rules must remain in place.

## Verify checklist failures

Each check's full output is in `okd/state/reports/verify-report-*.log`.
Typical causes:

- `cluster-operators` fails right after an install with the `authentication`
  operator unavailable → the oauth stack re-rolls after `okd-postinstall`'s
  identity-provider patch; the check now waits for sustained stability
  (`oc adm wait-for-stable-cluster`), so on current scripts simply re-run
  `just okd-verify`.

- `route-edge` fails but everything else passes → router/HAProxy/DNS path
  (see above), not the cluster.
- `pvc-bind-write` fails → local-path provisioner: `oc -n local-path-storage
  get pods,events`; the helper pod needs the `privileged` SCC grant
  (re-run `just okd-postinstall`, it's idempotent).
- `restricted-pod` image-pull timeouts → registry.access.redhat.com
  reachability; re-run `just okd-verify`.

## ChRIS deployment (Phase 2)

First stop for anything ChRIS: `just chris-status`, then
`just chris-logs <component>` (components listed in `just -l`).

- **Bitnami pods in `ImagePullBackOff`** (`postgresql`, `rabbitmq`, `nats`,
  or heart's `wait-db` init container) → Broadcom removed the versioned
  `docker.io/bitnami/*` tags the chart pins; the harness redirects them to
  `docker.io/bitnamilegacy` with an `ImageTagMirrorSet`
  ([chris/bitnami-mirror.yaml](../chris/bitnami-mirror.yaml), applied by
  `chris-deploy`). Check `oc get imagetagmirrorset` and
  `oc get mcp master` — the machine-config operator needs a minute to
  propagate the mirror into CRI-O's `registries.conf` (no reboot). Pods
  retry pulls on their own once it lands.
- **heart stuck in `Init:*`** → look at the specific init container:
  `oc -n chris logs deploy/chris-heart -c wait-db` (database not up),
  `-c migratedb` (Django migrations), `-c create-incluster-cr`
  (compute-resource/plugin registration — needs egress to
  `cube.chrisproject.org`), `-c wait-rabbitmq`.
- **seed job failed** → `just chris-logs seed`; the rendered config is at
  `okd/state/render/chrisomatic.yml`. chrisomatic is idempotent — fix and
  re-run `just chris-seed`. Plugin registration needs egress to the peer
  CUBE (`cube.chrisproject.org`).
- **plugin instance goes `cancelled` seconds after `scheduled`** →
  `just chris-logs worker-mains`. If pfcon rejected the submission with
  `Missing required parameter in the post body: args`, the instance was
  created with **zero parameter values** — CUBE 6.11.0 submits an empty
  `args` that pfcon 5.2.3 refuses (observed 2026-07-18). Workaround:
  always pass at least one explicit parameter (e.g. `prefix` for
  `pl-simpledsapp`); worth an upstream issue.
- **plugin instance stuck/errored** (Phase 3 smoke test) →
  `just chris-logs plugins` for the job pods pman created, and
  `just chris-logs pman` for why they didn't schedule (node selector,
  SCC, volume).
- **redeploy fails with an immutable-PVC or "cannot set pfcon..." error**
  → you changed storage-affecting values on a live release; the chart
  guards against self-destruction. `just chris-nuke && just chris-deploy`.

## Teardown

- `just chris-teardown` — uninstall the ChRIS release, keep PVCs (data) and
  the project for a fast redeploy.
- `just chris-nuke` — additionally delete PVCs, the `chris` project, and
  the bitnami tag mirror.
- `just okd-teardown` — destroy VM + cluster state, keep binaries/network.
  Anything ChRIS dies with the cluster.
- `just okd-nuke` — additionally remove the libvirt network, restore/stop
  HAProxy, delete all of `okd/state/`. Back to a clean machine.
- All are safe to run when things are half-created (idempotent, tolerate
  missing resources).
