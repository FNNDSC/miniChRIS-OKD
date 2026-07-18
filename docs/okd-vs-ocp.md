# OKD vs. Supported Red Hat OpenShift — Living Gap Log

The harness validates against **OKD 4.22 (SCOS)**. OKD is built from the
same `openshift/*` payload as OCP — Routes, SCCs, Projects, OAuth, console,
OLM are the same code paths — but it is *not* supported Red Hat OpenShift.
Everything below must be re-verified (or is known to differ) when HARBOR
work is promoted to a supported OCP environment.

Add entries as they are discovered; date them.

## Platform-level differences (inherent to OKD)

| Area | OKD (this harness) | Supported OCP | Impact |
|---|---|---|---|
| Base OS | SCOS (CentOS Stream CoreOS 10) | RHCOS (RHEL CoreOS) | kernel/package drift *ahead* of RHEL; behavior may lead OCP |
| Operator content | community catalogs only | Red Hat catalog, Marketplace, certified operators | no supported ODF/LVMS path here; anything needing entitled images |
| Support surface | none (community) | Red Hat support, Insights | different must-gather expectations |
| Release cadence | stable tags, not 1:1 with OCP z-streams | z-streams | CVE timing differs |
| Pull secret | placeholder works | real pull secret required | install-config differs on OCP |

## Harness-specific deltas (choices we made; re-verify on real OCP)

| Delta | Here | Production OCP would use | Re-validate |
|---|---|---|---|
| DNS + certs | sslip.io wildcard + self-signed router/API certs | corporate DNS + PKI | Route TLS, CUBE `ALLOWED_HOSTS`/CORS, client `--ca-bundle` paths |
| Topology | single node — no HA scheduling, single router replica | multi-node | pod affinity workarounds (chart's RWO settings), disruption behavior |
| Storage | `local-path` hostPath StorageClass (RWO, `WaitForFirstConsumer`) | ODF / LVMS / cloud CSI | fsGroup semantics, RWX availability, volume expansion, performance |
| Identity | htpasswd IdP, `developer` user | enterprise SSO (OIDC/LDAP) | login flows, group-based RBAC |
| Ingress | HAProxy TCP passthrough in front of the router (`lan` mode) | cloud LB / VIP | client source IPs, timeouts, websockets |
| Install path | agent-based installer, `platform: none` | IPI/UPI or agent per site standards | — (agent skills transfer directly) |

## Observed OKD quirks (dated findings)

- **2026-07-15 — agent installer arch mismatch on `4.22.0-okd-scos.6`:**
  OKD release digests are multi-arch manifest lists without matching
  "multi" release metadata; agent-based cluster registration deadlocks.
  Harness pins the amd64 child digest via
  `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` at ISO build
  (`scripts/okd-create-iso.sh`; details in
  [troubleshooting.md](troubleshooting.md)). OCP release payloads carry
  consistent arch metadata — this override should be unnecessary there;
  verify and drop on real OCP.

## ChRIS-specific (feeds Phase 2, issue [#130](https://github.com/FNNDSC/HARBOR-planning/issues/130))

- **pfcon/pman compute path** is internal to chart 1.0.8. We treat the
  chart as a black box; the smoke test touches only the CUBE REST API.
  → Re-validate after any chart compute-backend swap (2026-07: pending).
- **Plugin images under `restricted-v2`** validated only against OKD 4.22
  SCC admission with `pl-dircopy` / `pl-simpledsapp`; other plugins may
  assume writable HOME or fixed UIDs.
- **Bitnami subcharts** (PostgreSQL, RabbitMQ) rely on
  `global.compatibility.openshift.adaptSecurityContext: auto`; behavior
  should be identical on OCP but is worth one explicit check.

## How to use this log

1. Anything OKD-specific or surprising discovered during harness work gets
   an entry here (date + what + why it might differ on OCP).
2. When supported OCP access arrives, walk the tables top to bottom; each
   row becomes either "verified same" (note the date) or a real finding.
