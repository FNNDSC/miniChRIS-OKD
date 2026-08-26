# Versions — Pinned and Validated

Pins live in [config.env](../config.env) and are bumped deliberately: change
the pin, recreate, re-run `just okd-verify` (and, from Phase 2 on, the
smoke test), then record the validated combination here.

## Current pins

| Component | Version | Where pinned |
|---|---|---|
| OKD | `4.22.0-okd-scos.6` (stable 2026-06-29, k8s 1.35, SCOS 10) | `OKD_VERSION` |
| local-path-provisioner | `v0.0.31` | `LOCAL_PATH_PROVISIONER_VERSION` |
| chris Helm chart | `1.0.8` (appVersion CUBE 6.11.0) | `CHRIS_CHART_VERSION` |
| chrisomatic | `ghcr.io/fnndsc/chrisomatic:1.0.0` | `CHRISOMATIC_IMAGE` |
| python-chrisclient (smoke test transport) | `2.15.0` | `smoke/pyproject.toml` |
| seeded plugins | `pl-dircopy 3.0.0`, `pl-simpledsapp 2.1.5` (resolved from cube.chrisproject.org) | `chris/chrisomatic.yml.tpl` |
| verify probe images | `ubi9/ubi-minimal:latest`, `ubi9/httpd-24:latest` | `scripts/okd-verify.sh` |
| node-lease staleness gate | `120` s | `NODE_LEASE_MAX_AGE` |

Images the chart brings along (chart-internal, listed for the record):
CUBE `ghcr.io/fnndsc/cube:6.11.0`, pfcon `ghcr.io/fnndsc/pfcon:5.2.3`,
pman `ghcr.io/fnndsc/pman:6.1.0`, `ghcr.io/fnndsc/aiochris:0.10.0`,
`quay.io/curl/curl:8.10.1`, PostgreSQL 17.5.0 / RabbitMQ 4.1.1 /
NATS 2.11.4 (Bitnami tags, pulled via the `docker.io/bitnami →
bitnamilegacy` ImageTagMirrorSet — see
[okd-vs-ocp.md](okd-vs-ocp.md)). Two more are hard-coded in chart
templates and not settable by values: the heart `wait-db` init container
`docker.io/bitnami/postgresql:16.4.0-debian-12-r12` (a *different*
PostgreSQL version than the subchart's — also covered by the mirror) and
the unpinned `quay.io/prometheus/busybox:latest` used by every CUBE
deployment's `wait-for-server` init container.

## Validated combinations

Each row is a full `okd-install` + `okd-verify` (Phase 2+: + `chris-deploy`
+ `smoke`) that passed end-to-end. Host for all rows so far: miami.local —
Ubuntu 26.04 LTS, 16 threads / 123 GiB RAM / NVMe (the reference tier in
[requirements.md](requirements.md)).

| Date | Host | Mode | OKD | Provisioner | Chart | Verify | Notes |
|---|---|---|---|---|---|---|---|
| 2026-07-15 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | `okd-install` → verify ≈ 42 min (warm caches: binaries + base ISO already downloaded). Report: `okd/state/reports/verify-report-20260715-171919.txt`. Required the three OKD/agent-installer fixes now built into the harness: amd64 release-image pin, dashed sslip.io base domain, wildcard-probe NXDOMAIN carve-out (see troubleshooting.md). |
| 2026-07-15 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | **Clean-recreate proof** ([#129](https://github.com/FNNDSC/HARBOR-planning/issues/129)): `just okd-nuke` (all state, network, HAProxy, ISO cache removed) → `just okd-install` → verify, fully unattended, **41 min** wall clock, exit 0. |
| 2026-07-15 | miami.local | **local** | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | Default-mode path validated: nuke → recreate with `ACCESS_MODE=local` (domain `okd.192-168-126-10.sslip.io` on the VM IP; no HAProxy, no firewall changes; network redefined automatically for the new carve-out domain). 53 min unattended, exit 0. |
| 2026-07-18 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | — | **Phase 2 ([#130](https://github.com/FNNDSC/HARBOR-planning/issues/130)) first deploy**: `chris-deploy` (ImageTagMirrorSet → project → helm → rollouts) ≈ 4 min with cold images, `chris-seed` (chrisomatic 1.0.0, 0 failures) < 1 min. Full user journey verified from a LAN Mac through the Route: token auth as seeded `smoke` user → upload → `pl-dircopy` → chained `pl-simpledsapp` (with `prefix` arg — zero-arg runs get cancelled, see troubleshooting.md) → output download, sha256 identical. |
| 2026-07-18 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | — | **Clean-namespace proof ([#130](https://github.com/FNNDSC/HARBOR-planning/issues/130))**: `chris-nuke` (release+PVCs+project+mirror) → `chris-deploy` → `chris-seed`, **2 min 00 s** wall clock (warm node image cache), exit 0; abbreviated journey re-verified against the fresh instance (upload → dircopy → simpledsapp `finishedSuccessfully`). |
| 2026-08-20 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | — | **Phase 3 ([#131](https://github.com/FNNDSC/HARBOR-planning/issues/131)) wiring restored + full re-validation** on a freshly rebuilt cluster: `chris-deploy` → `chris-seed` → `just smoke` **PASS 14–26 s across runs**, exit 0 (TLS verified via the auto-extracted router CA; cleanup converges). Exit contract re-verified live: wrong password → exit **2** at `authenticate`; forced `SMOKE_TIMEOUT=1` → exit **1** with the feed kept and the full diagnostics tree (`trace.jsonl`, `state.json`, `instances.json`, `oc/` snapshots + per-deployment logs). The `(3) test` justfile group, `SMOKE_*` config.env budgets, and `python3-venv` host dependency — lost from tracked files by a repo sync — were restored this date. Independently re-reviewed the same day and hardened on its findings (bootstrap exit-2 coverage incl. lib config validation, wrapper JSON verdict, diagnostics I/O guards, environment-over-`config.local.env` precedence); every fix re-verified live, 54/54 offline unit tests. Full-repo review re-check on the standing cluster the same day: `okd-verify` 12/12, `smoke` PASS 17 s. |
| 2026-08-26 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | 12/12 | **Cluster-liveness hardening**, prompted by a live incident: after a host reboot, `just chris-nuke` died with `Error: failed to delete release: chris`. Root cause was not ChRIS — the node had been off across the 24-hour bootstrap-certificate rotation, so kubelet had no valid client certificate, ran only the five static pods, and kube-apiserver was replaying stale etcd (every node `Ready`, every pod `Running`, 34/34 operators `Available`). `cluster-machine-approver` is itself an ordinary pod, so the CSR backlog (25 pending) could never self-approve: a true deadlock. Recovered by approving the kubelet CSRs — ~10 min to 34/34 healthy. Harness changes validated the same day: new `just okd-doctor` (diagnose + repair, `--check` read-only); `require_live_cluster` / `warn_unless_live_cluster` in `lib/common.sh` keyed on the **node lease** (kubelet renews every ~10s) rather than `Ready.lastHeartbeatTime` (which lags ~5 min even when healthy — measured 4m15s on a live node); `okd-verify` gained the same guard at entry (its `node-ready` check had previously passed on a dead cluster), plus a lease assertion inside `node-ready` as defence in depth against a cluster degrading mid-run; `chris-teardown --nuke` made best-effort before the project delete. Re-validated end-to-end on the recovered cluster: `okd-verify` **12/12**, `chris-deploy` **1 m 25 s**, `chris-seed` **19 s** (0 failures), `just smoke` **PASS 21 s**, `chris-nuke` **41 s**, 54/54 offline unit tests. Fault injection with a `helm` shim that always fails `uninstall`: `chris-teardown` still exits 1 (now printing helm's hidden `--debug` hint), while `chris-nuke` warns and completes in **43 s**, leaving no namespace, release record, PV or mirror behind. |
| 2026-08-26 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | 12/12 | **Independent review + hardening of the row above.** shellcheck 0.11.0 wired in (`.shellcheckrc` sets `source-path`/`external-sources` so the dynamically-sourced libs resolve): **zero findings across all 22 scripts**, after fixing a `# shellcheck disable=SC2046` in `render_template` that named the wrong check and had therefore never suppressed anything. Review found four defects the first pass missed, all now fixed: (1) **the gate failed open** — `NODE_LEASE_MAX_AGE=120s`, a natural typo beside the duration-valued `CLUSTER_STABLE_*` knobs, made every lease query fail, and since empty output meant "healthy" it silently disabled the whole feature on that host (now validated at load); (2) `.items[]` **aborts the jq stream at the first throwing item**, so one unparseable timestamp hid every node after it — fatal on a single-node cluster (now `try/catch` per item, and every read/parse failure emits a problem instead of silence); (3) `approve_kubelet_csrs` **reported CSRs approved when the approve had failed**, because `set -e` does not reach inside `$( )` without `inherit_errexit` (verified live under bash 5.3), sending the operator to the node journal for a harness-side failure; (4) `chris-teardown` logged "PVCs marked for deletion" unconditionally after a `best_effort` that had just warned it failed, and deleted the bitnami mirror as a bare command after the project delete, so a failure there skipped the credential cleanup. Also: `helm status` failing is no longer reported as "release not installed"; helm's uninstall output streams instead of buffering; `chris-status` gained the advisory guard (it is the documented first stop and renders the "everything Running" fiction). New **`just test-liveness`** — 26 offline assertions against the real jq programs with `admin_oc` stubbed, no cluster needed; verified to fail 10/26 against the pre-fix code, i.e. genuine regression tests for (1) and (2). Docs corrected: the Minimum tier's "32 GiB RAM" is unreachable because `host-check` reads `MemTotal`, ~3.7 % under nameplate (measured: a 128 GiB box reports 126 189 MiB, so a 32 GiB box reports ~31 550 and misses the 32 768 MiB bar); coverage claims narrowed to the recipes that actually block; `okd-doctor`'s header no longer claims equivalence with `cluster-machine-approver` (it approves by signerName alone). Re-validated live: `okd-verify` **12/12**, `just smoke` **PASS**, 26/26 liveness + 54/54 pytest. |

<!-- Template:
| YYYY-MM-DD | host | local/lan | okd version | provisioner | chart | 12/12 | clean-recreate Xh Ym; report okd/state/reports/verify-report-....txt |
-->
