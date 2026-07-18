# Versions — Pinned and Validated

Pins live in [config.env](../config.env) and are bumped deliberately: change
the pin, recreate, re-run `just okd-verify` (and, from Phase 2 on, the
smoke test), then record the validated combination here.

## Current pins

| Component | Version | Where pinned |
|---|---|---|
| OKD | `4.22.0-okd-scos.6` (stable 2026-06-29, k8s 1.35, SCOS 10) | `OKD_VERSION` |
| local-path-provisioner | `v0.0.31` | `LOCAL_PATH_PROVISIONER_VERSION` |
| chris Helm chart (Phase 2) | `1.0.8` (appVersion CUBE 6.11.0) | `CHRIS_CHART_VERSION` |
| verify probe images | `ubi9/ubi-minimal:latest`, `ubi9/httpd-24:latest` | `scripts/okd-verify.sh` |

## Validated combinations

Each row is a full `okd-install` + `okd-verify` (Phase 2+: + `chris-deploy`
+ `smoke`) that passed end-to-end.

| Date | Host | Mode | OKD | Provisioner | Chart | Verify | Notes |
|---|---|---|---|---|---|---|---|
| 2026-07-15 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | `okd-install` → verify ≈ 42 min (warm caches: binaries + base ISO already downloaded). Report: `okd/state/reports/verify-report-20260715-171919.txt`. Required the three OKD/agent-installer fixes now built into the harness: amd64 release-image pin, dashed sslip.io base domain, wildcard-probe NXDOMAIN carve-out (see troubleshooting.md). |
| 2026-07-15 | miami.local | lan | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | **Clean-recreate proof** ([#129](https://github.com/FNNDSC/HARBOR-planning/issues/129)): `just okd-nuke` (all state, network, HAProxy, ISO cache removed) → `just okd-install` → verify, fully unattended, **41 min** wall clock, exit 0. |
| 2026-07-15 | miami.local | **local** | 4.22.0-okd-scos.6 | v0.0.31 | — | 12/12 | Default-mode path validated: nuke → recreate with `ACCESS_MODE=local` (domain `okd.192-168-126-10.sslip.io` on the VM IP; no HAProxy, no firewall changes; network redefined automatically for the new carve-out domain). 53 min unattended, exit 0. |

<!-- Template:
| YYYY-MM-DD | host | local/lan | okd version | provisioner | chart | 12/12 | clean-recreate Xh Ym; report okd/state/reports/verify-report-....txt |
-->
