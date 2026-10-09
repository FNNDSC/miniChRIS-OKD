# miniChRIS-OKD

Run ChRIS on a single-node OKD (OpenShift) cluster — a reproducible,
`just`-driven validation harness for HARBOR's OpenShift-dependent work
(epic [FNNDSC/HARBOR-planning#128](https://github.com/FNNDSC/HARBOR-planning/issues/128)).

The harness stands up **single-node OKD (SNO) inside a libvirt/KVM VM** via
the official agent-based installer, deploys minimal ChRIS through the real
`FNNDSC/charts` Helm path, and proves the deployment with a functional smoke
test. It is a validation instrument, not production infrastructure.

| Phase | Issue | Status |
|---|---|---|
| 1 — OKD dev harness (`just okd-install`) | [#129](https://github.com/FNNDSC/HARBOR-planning/issues/129) | ✅ implemented |
| 2 — ChRIS via FNNDSC/charts (`just chris-deploy`) | [#130](https://github.com/FNNDSC/HARBOR-planning/issues/130) | ✅ implemented |
| 3 — functional smoke test (`just smoke`) | [#131](https://github.com/FNNDSC/HARBOR-planning/issues/131) | ✅ implemented |

## Quickstart (clean Linux box)

Requirements: x86_64 Linux with KVM, sudo, outbound internet. `host-check`
sizes the host against the VM *plus* headroom (2 threads / 8 GiB / 50 GB), so
the committed defaults (10 vCPU / 32 GiB / 200 GB) want **12 threads / 40 GiB
/ 250 GB free**, and the Minimum tier still wants **10 threads / >32 GiB /
200 GB** even with its VM overrides applied. Both RAM figures are `MemTotal`,
which runs ~4 % under nameplate — so a nominally 32 GiB box misses the Minimum
tier by about 1 GiB, and a 40 GiB box misses the default. Sizing tiers and the
overrides: [docs/requirements.md](docs/requirements.md).
Any modern distro works; the automated `host-setup.sh` covers apt-based distros
(Ubuntu/Debian) — Fedora/RHEL users install the package equivalents manually
first ([docs/requirements.md](docs/requirements.md#distro-support)).

Not sure a box qualifies? Survey it first, from anywhere, before cloning
anything on it — it reports the sizing tier, whether the VM volume is
SSD-backed, the distro path, and which `ACCESS_MODE` its resolver allows:

```sh
ssh user@candidate 'bash -s' < scripts/host-survey.sh    # or: just host-survey user@candidate
```

```sh
git clone https://github.com/FNNDSC/miniChRIS-OKD && cd miniChRIS-OKD

# 1. one-time host preparation (installs libvirt/KVM, just, jq, helm)
bash scripts/host-setup.sh     # afterwards: re-login (libvirt group)

# 2. optional: per-host overrides (gitignored)
#    e.g. remote headless box driven from your desk:
echo 'ACCESS_MODE=lan' > config.local.env

# 3. bring up the cluster (~45-70 min unattended)
just okd-install

# 4. access details (console URL, kubeadmin + developer credentials)
just okd-console
```

`okd-install` chains: preflight → libvirt network (+ HAProxy in `lan` mode)
→ pinned binary download → config render → agent ISO → VM boot → install
wait → post-install (default StorageClass + `developer` user) → recorded
verification checklist.

## Everyday commands

```text
just host-survey [h]  survey a candidate box (remote via ssh) before cloning on it
just host-check       preflight — does this box qualify?
just okd-install      full cluster bring-up (idempotent steps)
just okd-verify       re-run the validation checklist (HARBOR-planning#129)
just okd-doctor       diagnose/repair a cluster that answers but isn't live
just okd-console      URLs + credentials
just okd-env          eval "$(just okd-env)" → pinned oc on PATH + admin KUBECONFIG
just okd-teardown     destroy VM + cluster (keeps binaries/network)
just okd-nuke         back to a clean machine
just versions         pinned + live versions
```

Configuration knobs (VM sizing, IPs, version pins) live in
[config.env](config.env); override per-host in `config.local.env` or
one-off via environment (`VM_RAM_MIB=24576 just okd-install`).

**Leave the VM running for its first 24 hours.** The kubelet certificate
issued at install expires after a day and is rotated only while the cluster
is up; a node that was off across that window comes back serving stale data —
`oc` reports every node `Ready` and every pod `Running` while nothing but the
static control-plane pods is actually there. `just okd-doctor` recognises that
state and repairs it, and the recipes that deploy or verify (`chris-deploy`,
`chris-seed`, `okd-verify`, `smoke`, `okd-postinstall`) refuse to run against
it rather than failing confusingly later; `chris-teardown`/`chris-nuke` and
`chris-status` only warn, so you can still tear down or inspect. Details:
[docs/troubleshooting.md](docs/troubleshooting.md#certificates-and-long-lived-clusters).

## ChRIS on the cluster (Phase 2)

With the cluster up, deploy minimal ChRIS through the pinned
[FNNDSC/charts](https://github.com/FNNDSC/charts) release and seed it for
the smoke test:

```sh
just chris-deploy     # bitnami tag mirror → project → helm install → wait (~5 min)
just chris-seed       # chrisomatic Job: 'smoke' test user + smoke-test plugins
just chris-status     # pods, storage, Route, URLs + credentials
```

The deployment is CUBE (API server, heart, celery workers) + PostgreSQL,
RabbitMQ, NATS and the in-cluster pfcon/pman compute path, exposed at
`https://cube.apps.<cluster domain>/api/v1/` through an edge-TLS Route.
The committed OKD-specific chart values live in
[chris/values-okd.yaml](chris/values-okd.yaml); host-specific bits (Route
host, RWO node pin) are injected at deploy time. Seeding is declarative:
[chris/chrisomatic.yml.tpl](chris/chrisomatic.yml.tpl) run as an in-cluster
Job (idempotent — re-run `just chris-seed` any time).

```text
just chris-logs <c>   logs: heart server worker-mains worker-periodic
                      pfcon pman db rabbitmq nats seed plugins
just chris-open       print (and open) the CUBE URL
just chris-teardown   uninstall the release; keeps PVCs + project
just chris-nuke       also delete PVCs, the project, and the tag mirror
```

Note: the chart's Bitnami images are pulled through a
`docker.io/bitnami → bitnamilegacy` `ImageTagMirrorSet`
([chris/bitnami-mirror.yaml](chris/bitnami-mirror.yaml), applied
automatically) because Broadcom removed the pinned tags from Docker Hub —
see [docs/okd-vs-ocp.md](docs/okd-vs-ocp.md).

## Functional smoke test (Phase 3)

One command proves the deployment *works*, not merely that pods started:
auth → upload → `pl-dircopy` (fs) → chained `pl-simpledsapp` (ds, the full
worker → compute path) → bounded poll → download → checksum verification —
through the Route with verified TLS, as the seeded non-admin `smoke` user:

```sh
just smoke            # ~25 s; exit 0 pass / 1 product failure / 2 setup error
just smoke --keep     # leave the feed + upload in place for inspection
just smoke --verbose  # stream every API call
just smoke-setup      # prepare the virtualenv only (e.g. CI pre-bake)
```

Two offline suites need no cluster and no network, so they run anywhere:
`just test-liveness` (26 assertions over the cluster-liveness helpers, with
`oc` stubbed) and `pytest smoke/tests` (54 tests over the smoke package).
`shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh` is clean and reads
`.shellcheckrc` automatically.

The last stdout line is always a machine-readable JSON verdict. On failure
the run writes diagnostics (API trace, journey state, `oc` dumps) under
`okd/state/smoke-artifacts/<timestamp>/` and keeps the feed as evidence.
TLS is verified against the ingress CA, extracted automatically
(`just router-ca`) — never silently downgraded.

The package is harness-agnostic: any machine that can reach the Route can
run it with four env vars — see [smoke/README.md](smoke/README.md) for the
standalone invocation and the full env/flag table, and
[docs/ci.md](docs/ci.md) for CI wiring notes.

## Access modes

- **`local`** (default) — you work on the harness box itself. DNS derives
  from the VM's IP (`okd.192-168-126-10.sslip.io`); no HAProxy, no firewall
  changes.
- **`lan`** — the harness box is remote/headless (e.g. `ssh miami.local`)
  and you drive it from your own machine. DNS derives from the box's LAN IP
  and HAProxy forwards `80/443/6443` into the VM.

The mode is baked into the cluster's base domain at install time — switching
means `just okd-nuke && just okd-install`. Details:
[docs/networking.md](docs/networking.md).

## Documentation

- [docs/requirements.md](docs/requirements.md) — host requirements + sizing tiers
- [docs/networking.md](docs/networking.md) — DNS/sslip.io, HAProxy, port table, fallbacks
- [docs/troubleshooting.md](docs/troubleshooting.md) — install stalls, certs, CSRs, libvirt
- [docs/okd-vs-ocp.md](docs/okd-vs-ocp.md) — living gap log vs. supported Red Hat OpenShift
- [docs/versions.md](docs/versions.md) — pinned + validated version record
- [docs/ci.md](docs/ci.md) — CI wiring notes for the smoke test
- [smoke/README.md](smoke/README.md) — smoke test usage, env/flag table, diagnostics

## Repository layout

```text
justfile          thin orchestration (just -l)
config.env        all tunables; config.local.env overrides (gitignored)
scripts/          host-side bash, one concern per file; shared lib in scripts/lib/
okd/              committed templates (install/agent config, HAProxy, storage)
okd/state/        gitignored: rendered configs, binaries, ISO, kubeconfigs, VM disks
docs/             requirements, networking, troubleshooting, gap log, versions
chris/            Phase 2 (HARBOR-planning#130): chart values, chrisomatic seed config
smoke/            Phase 3 (HARBOR-planning#131): functional smoke test package
tests/            offline bash tests for the shared libs (just test-liveness)
```
