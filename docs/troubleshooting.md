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
- **`wait-for bootstrap-complete` dies after ~60 min with "bootstrap process
  timed out: context deadline exceeded" while the VM stayed up the whole
  time** (hit 2026-08-19). The install never actually started: assisted-service
  could not generate the install config, so the cluster looped `known →
  preparing-for-installation → preparing-successful → known` until the
  installer's deadline expired. The cause we hit was a **truncated
  `openshift-install` in assisted-service's installer cache inside the VM** —
  42,310,880 bytes of the real 695,627,960 — which segfaults instantly
  (`rc=139`, no output) on every attempt. That cache sits on the node's
  RAM-backed ephemeral overlay and is not size-checked on reuse, so a single
  short extraction poisons the whole boot. It is transient: the same release
  digest installs normally on a fresh VM.

  `okd-wait` now watches for this and aborts within a few minutes, printing the
  guest-side error instead of waiting out the deadline (tunable via
  `PREPARE_FAIL_LIMIT`, default 3). To confirm by hand:

  ```sh
  ssh -i okd/state/ssh/id_ed25519 core@<VM_IP> \
    'sudo journalctl -u assisted-service | grep -a "Failed to prepare installation" | tail -3'
  # → error running openshift-install manifests,  : signal: segmentation fault
  ```

  **Fix:** `just okd-teardown && just okd-install` — a fresh VM gets a fresh
  cache. Do not just re-run `just okd-wait`: the poisoned cache lives on the
  running node and survives until the VM is recreated.
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
- **`wait-for install-complete` fails with `Cluster operator authentication
  is not available` + `Cluster operator ingress is degraded`** (hit
  2026-08-20, `local` mode). These are the two operators that depend on the
  `*.apps` wildcard resolving **from inside the cluster**: ingress checks
  `canary-openshift-ingress-canary.apps.<domain>` and authentication
  health-checks `oauth-openshift.apps.<domain>` through the same router. So it
  is one fault, not two — authentication is collateral. Look for
  `error sending canary HTTP Request: Timeout` in the operator message; in
  Go's HTTP client that covers a hanging DNS lookup as well as a hanging
  connect. Diagnose the node's view, which is not what `getent`/`host-check`
  historically tested:

  ```sh
  dig +short test.apps.<cluster domain> @192.168.126.1   # node's resolver
  getent hosts test.apps.<cluster domain>                # host's resolver
  ```

  Anything other than the access IP from the first command is the cause —
  usually a rebind-protecting resolver (see
  [networking.md](networking.md#access-modes)). `net-setup` now refuses to
  install in that state instead of warning.

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

This is the harness's most deceptive failure mode, because a cluster in it
*looks* perfectly healthy: `oc get nodes` reports `Ready`, `oc get pods`
reports `Running`, and every cluster operator reports `Available`. All of it
is stale data being replayed out of etcd.

- **The 24-hour bootstrap certificate.** The kubelet client certificate
  written at install (`/var/lib/kubelet/pki/kubelet-client-current.pem`,
  issued by `kubelet-signer`) is valid for **24 hours**. It is rotated via CSR
  by `cluster-machine-approver` — which can only happen while the cluster is
  actually *running*. Keep the VM up through the first day after
  `just okd-install`.

- **If the node was down when it expired, the cluster does not recover by
  itself.** kubelet falls back to `system:anonymous`, so it can start only the
  five static control-plane pods (etcd, kube-apiserver,
  kube-controller-manager, kube-scheduler, kube-rbac-proxy-crio). Everything
  else — including `cluster-machine-approver`, the very thing that would
  approve kubelet's CSRs — never starts. It is a genuine deadlock: kubelet
  keeps submitting CSRs forever and nothing ever approves them. Meanwhile
  kube-apiserver serves the last state etcd recorded, which is why every read
  looks fine.

- **Fix:**

  ```sh
  just okd-doctor          # diagnose, then approve the pending kubelet CSRs
  just okd-doctor --check  # diagnose only, change nothing
  ```

  A second CSR round (`kubelet-serving`) follows the first; `okd-doctor` keeps
  approving until the node leases go fresh. Observed 2026-08-26: ~10 minutes
  from approval to 34/34 healthy cluster operators, with ChRIS pods returning
  on their own.

- **Recognising it by hand** — `okd-doctor` checks the first two itself (plus
  `/readyz`); the `crictl` inventory is yours to run:

  ```sh
  eval "$(just okd-env)"          # okd-env, NOT okd-kubeconfig: only okd-env
                                  # puts the pinned oc on PATH
  oc get lease -n kube-node-lease                 # kubelet renews every ~10s
  oc get csr | grep -c Pending                    # pile of node-bootstrapper CSRs
  ssh -i okd/state/ssh/id_ed25519 core@<VM_IP> 'sudo crictl pods'   # static pods only
  ```

  Do **not** treat the node's `Ready` condition or its `lastHeartbeatTime` as
  evidence of life: the condition is served from etcd and stays `True`
  indefinitely, and kubelet only rewrites `lastHeartbeatTime` every ~5 minutes
  even on a completely healthy node. The **node lease** is the only
  trustworthy liveness signal. `require_live_cluster` in
  [`scripts/lib/common.sh`](../scripts/lib/common.sh) asserts it and refuses
  to run: `chris-deploy`, `chris-seed`, `okd-postinstall`, `okd-verify` and
  `smoke`. `chris-teardown`/`chris-nuke` and `chris-status` use the advisory
  form instead — they warn and continue, because tearing down or inspecting a
  broken deployment is exactly what you want to be able to do. The steps
  inside `okd-install` that run before the cluster exists (`net-setup`,
  `okd-vm`, `okd-wait`) are necessarily unguarded.

- **The downstream symptom that usually surfaces first:** `just chris-nuke`
  failing with `Error: failed to delete release: chris` (hit 2026-08-26).
  Helm cannot resolve the chart's `Route` kind while `route.openshift.io`
  discovery is down — the openshift-apiserver pods are not really running —
  and it hides the underlying errors behind a generic message unless invoked
  with `--debug`. `chris-teardown` prints that hint whenever the uninstall
  itself fails, and distinguishes "release absent" from "helm could not answer"
  so a broken cluster is never reported as "nothing to uninstall". `--nuke`
  continues past all of it.

- **Autostart surprise:** the VM is created with `--autostart`, so a host
  reboot silently brings the cluster back — including straight back into the
  state above. Check with `virsh -c qemu:///system dominfo okd-sno`.

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
  `setfacl -m u:libvirt-qemu:x` each path component, or create a directory
  you own outside your home (`sudo install -d -o "$USER" -g "$(id -gn)"
  /var/lib/libvirt/images/okd`) and set `IMAGES_DIR=/var/lib/libvirt/images/okd`
  in `config.local.env`. It must be yours: `okd-create-vm` and `okd-teardown`
  create and delete there without sudo.
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

### `cluster-operators` fails

This check runs `oc adm wait-for-stable-cluster`, which requires **all ~34
cluster operators to report `Available=True, Progressing=False,
Degraded=False` simultaneously for `CLUSTER_STABLE_PERIOD` (30 s), within
`CLUSTER_STABLE_TIMEOUT` (20 m)**. One flapping operator resets the window for
the whole set, so this is the only check that can fail while the cluster is
perfectly usable — expect the other 11 to pass.

**First: just re-run it.** `just okd-verify` is idempotent and takes ~2 min.
Do *not* re-run `just okd-install`; it aborts at `render` while the VM exists.

The overwhelmingly common cause is losing a race with post-install churn:
`okd-postinstall` patches the OAuth CR, which re-rolls `oauth-openshift` and,
transitively, `console`. `okd-postinstall` now waits for the cluster to settle
before it returns, but on a slow host that wait can itself expire.

**Find the actual operator** — it is already in the detail log:

```sh
grep -E 'clusteroperators/' okd/state/reports/verify-report-<stamp>.log \
  | sort | uniq -c | sort -rn
sed -n '/cluster-operators:/,/scc-present:/p' okd/state/reports/verify-report-<stamp>.log
```

`wait-for-stable-cluster` logs `clusteroperators/<name> is <state> at <time>`
(states: `Unavailable`, `Progressing`, `Degraded`, `Stable`). On failure the
check then dumps each unstable operator's conditions **with reasons and
messages**, followed by a final operator table.

Against a live cluster:

```sh
eval "$(just okd-env)"
oc get co
oc get co -o json | jq -r '.items[]
  | select(([.status.conditions[]|select(.type=="Available" and .status=="True")]|length==0)
        or ([.status.conditions[]|select((.type=="Degraded" or .type=="Progressing") and .status=="True")]|length>0))
  | "\(.metadata.name): " + ([.status.conditions[]|select(.status=="True" and (.type=="Degraded" or .type=="Progressing"))|.message]|join(" | "))'
```

**Then read the answer:**

| Operator | Meaning | Action |
|---|---|---|
| `authentication` (± `console`) | The post-IdP re-roll — `OAuthServerDeploymentAvailable: no oauth-openshift... pods available` | Re-run verify; nothing is wrong |
| `monitoring` | Prometheus still starting; 15+ min on a small host | Re-run verify, or raise `CLUSTER_STABLE_TIMEOUT` |
| `etcd`, `kube-apiserver` | Disk too slow or CPU starved — see below | Real capacity problem |
| `machine-config` | A MachineConfig failed to apply | `oc get mcp,nodes`; `oc describe co machine-config` |
| `image-registry` | Unexpected: on `platform: none` it ships `managementState: Removed` and needs no storage | `oc get configs.imageregistry.operator.openshift.io cluster -o yaml` |
| `insights`, `openshift-samples`, `marketplace` | Egress-dependent, non-fatal | Check outbound reachability to quay.io |

**If it keeps timing out, it is capacity.** Under-provisioned hosts never get
one contiguous stable window. `host-check` warns when `VM_VCPUS`/`VM_RAM_MIB`/
`VM_DISK_GB` sit below the Minimum tier in [requirements.md](requirements.md),
but it cannot make a small box fast. Measure:

```sh
nproc; free -g | head -2
lsblk -d -o NAME,ROTA,SIZE,MODEL     # ROTA=1 is a spinning disk — fatal for etcd
oc adm top node
oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
  curl -s --data-urlencode 'query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))' \
  http://localhost:9090/api/v1/query
```

etcd WAL fsync p99 must stay under 10 ms. For reference, miami.local (10 vCPU,
NVMe) measures ~7.8 ms — the headroom is thin even on good hardware. If yours
is worse, move `IMAGES_DIR` to an NVMe. If `nproc` is small, raise
`CLUSTER_STABLE_TIMEOUT` in `config.local.env` and accept slower settling.


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
- **`Error: failed to delete release: chris`** on teardown → that is Helm's
  generic wrapper; the real errors are hidden unless you add `--debug`.
  `chris-teardown` prints the exact `--debug` command on failure. When it is
  caused by a broken cluster rather than a broken release (Helm cannot map
  the chart's `Route` kind because `route.openshift.io` discovery is down),
  the cure is [`just okd-doctor`](#certificates-and-long-lived-clusters), not
  anything ChRIS-side.

## Teardown

- `just chris-teardown` — uninstall the ChRIS release, keep PVCs (data) and
  the project for a fast redeploy.
- `just chris-nuke` — additionally delete PVCs, the `chris` project, and
  the bitnami tag mirror. Every step before the project delete is
  **best-effort**: a failing Helm uninstall becomes a warning and the run
  continues, because deleting the project removes the release and everything
  it created anyway. Only the project delete itself is fatal.
- `just okd-teardown` — destroy VM + cluster state, keep binaries/network.
  Anything ChRIS dies with the cluster.
- `just okd-nuke` — additionally remove the libvirt network, restore/stop
  HAProxy, delete all of `okd/state/`. Back to a clean machine.
- All are safe to run when things are half-created (idempotent, tolerate
  missing resources).
