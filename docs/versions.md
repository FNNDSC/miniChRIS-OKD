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
| seeded plugins | `pl-dircopy 3.0.0`, `pl-simpledsapp 2.1.5` (resolved from cube.chrisproject.org) | `chris/chrisomatic.yml.tpl` |
| verify probe images | `ubi9/ubi-minimal:latest`, `ubi9/httpd-24:latest` | `scripts/okd-verify.sh` |

Images the chart brings along (chart-internal, listed for the record):
CUBE `ghcr.io/fnndsc/cube:6.11.0`, pfcon `ghcr.io/fnndsc/pfcon:5.2.3`,
pman `ghcr.io/fnndsc/pman:6.1.0`, PostgreSQL 17.5.0 / RabbitMQ 4.1.1 /
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
+ `smoke`) that passed end-to-end.

| Date | Host | Mode | OKD | Provisioner | Chart | Verify | Notes |
|---|---|---|---|---|---|---|---|
| 2026-07-15 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | `okd-install` → verify ≈ 42 min (warm caches: binaries + base ISO already downloaded). Report: `okd/state/reports/verify-report-20260715-171919.txt`. Required the three OKD/agent-installer fixes now built into the harness: amd64 release-image pin, dashed sslip.io base domain, wildcard-probe NXDOMAIN carve-out (see troubleshooting.md). |
| 2026-07-15 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | **Clean-recreate proof** ([#129](https://github.com/FNNDSC/HARBOR-planning/issues/129)): `just okd-nuke` (all state, network, HAProxy, ISO cache removed) → `just okd-install` → verify, fully unattended, **41 min** wall clock, exit 0. |
| 2026-07-15 | miami.local | **local** | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | Default-mode path validated: nuke → recreate with `ACCESS_MODE=local` (domain `okd.192-168-126-10.sslip.io` on the VM IP; no HAProxy, no firewall changes; network redefined automatically for the new carve-out domain). 53 min unattended, exit 0. |
| 2026-07-18 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | — | **Phase 2 ([#130](https://github.com/FNNDSC/HARBOR-planning/issues/130)) first deploy**: `chris-deploy` (ImageTagMirrorSet → project → helm → rollouts) ≈ 4 min with cold images, `chris-seed` (chrisomatic 1.0.0, 0 failures) < 1 min. Full user journey verified from a LAN Mac through the Route: token auth as seeded `smoke` user → upload → `pl-dircopy` → chained `pl-simpledsapp` (with `prefix` arg — zero-arg runs get cancelled, see troubleshooting.md) → output download, sha256 identical. |
| 2026-07-18 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | — | **Clean-namespace proof ([#130](https://github.com/FNNDSC/HARBOR-planning/issues/130))**: `chris-nuke` (release+PVCs+project+mirror) → `chris-deploy` → `chris-seed`, **2 min 00 s** wall clock (warm node image cache), exit 0; abbreviated journey re-verified against the fresh instance (upload → dircopy → simpledsapp `finishedSuccessfully`). |
| 2026-08-20 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | 1.0.8 | — | **Phase 3 ([#131](https://github.com/FNNDSC/HARBOR-planning/issues/131)) wiring restored + full re-validation** on a freshly rebuilt cluster: `chris-deploy` → `chris-seed` → `just smoke` **PASS 20–26 s**, exit 0 (TLS verified via the auto-extracted router CA; cleanup converges). Exit contract re-verified live: wrong password → exit **2** at `authenticate`; forced `SMOKE_TIMEOUT=1` → exit **1** with the feed kept and the full diagnostics tree (`trace.jsonl`, `state.json`, `instances.json`, `oc/` snapshots + per-deployment logs). 40/40 offline unit tests. The `(3) test` justfile group, `SMOKE_*` config.env budgets, and `python3-venv` host dependency — lost from tracked files by a repo sync — were restored this date. |

<!-- Template:
| YYYY-MM-DD | host | local/lan | okd version | provisioner | chart | 12/12 | clean-recreate Xh Ym; report okd/state/reports/verify-report-....txt |
-->
