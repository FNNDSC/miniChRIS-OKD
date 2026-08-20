# miniChRIS-OKD — single-node OKD harness for ChRIS/OpenShift validation.
#
# Run `just -l` to list recipes. All configuration lives in config.env
# (persistent per-host overrides: config.local.env, gitignored; one-off:
# `ACCESS_MODE=lan just okd-install`).
#
# Recipes stay thin — anything longer than a few lines lives in scripts/,
# one concern per file, sharing scripts/lib/common.sh.

set shell := ["bash", "-euo", "pipefail", "-c"]

_default:
    @just --list

# Install host dependencies: libvirt/KVM stack, just, jq, helm (+ haproxy in lan mode). Needs sudo.
[group('(1) harness')]
host-setup:
    @scripts/host-setup.sh

# Preflight: can this host run the harness? (CPU/RAM/disk/KVM/tools/DNS/ports)
[group('(1) harness')]
host-check:
    @scripts/host-check.sh

# Bring up the OKD cluster end-to-end (~45-70 min unattended).
[group('(1) harness')]
okd-install: host-check net-setup okd-download render okd-iso okd-vm okd-wait okd-postinstall okd-verify
    @scripts/okd-info.sh console

# Run the recorded validation checklist; report lands in okd/state/reports/.
[group('(1) harness')]
okd-verify:
    @scripts/okd-verify.sh

# Print console/API URLs and credentials.
[group('(1) harness')]
okd-console:
    @scripts/okd-info.sh console

# Shell setup: eval "$(just okd-env)" puts the pinned oc/kubectl on PATH + admin KUBECONFIG.
[group('(1) harness')]
okd-env:
    @scripts/okd-info.sh env

# Print an eval-able admin kubeconfig export:  eval "$(just okd-kubeconfig)"
[group('(1) harness')]
okd-kubeconfig:
    @scripts/okd-info.sh kubeconfig

# Destroy the VM + cluster state (keeps binaries/network/HAProxy for reinstall).
[group('(1) harness')]
okd-teardown *args:
    @scripts/okd-teardown.sh {{ args }}

# Full clean-slate: teardown + libvirt network + HAProxy + all of okd/state/.
[group('(1) harness')]
okd-nuke *args:
    @scripts/okd-teardown.sh --nuke {{ args }}

# Deploy minimal ChRIS onto the cluster via the pinned FNNDSC/charts release.
[group('(2) chris')]
chris-deploy:
    @scripts/chris-deploy.sh

# Seed the test user + smoke-test plugins via a chrisomatic Job (idempotent).
[group('(2) chris')]
chris-seed:
    @scripts/chris-seed.sh

# Release, pods, storage, Route, seed job, URLs and credentials.
[group('(2) chris')]
chris-status:
    @scripts/chris-status.sh

# Logs for one component: heart server worker-mains worker-periodic pfcon pman db rabbitmq nats seed plugins.
[group('(2) chris')]
chris-logs *args:
    @scripts/chris-logs.sh {{ args }}

# Print the CUBE URL (and open it when a GUI opener exists).
[group('(2) chris')]
chris-open:
    @scripts/chris-status.sh open

# Uninstall the ChRIS release (keeps PVCs and the project for redeploys).
[group('(2) chris')]
chris-teardown *args:
    @scripts/chris-teardown.sh {{ args }}

# Full ChRIS clean-slate: release + PVCs + project + bitnami mirror.
[group('(2) chris')]
chris-nuke *args:
    @scripts/chris-teardown.sh --nuke {{ args }}

# Functional end-to-end smoke test: auth → upload → run plugins → verify output.
[group('(3) test')]
smoke *args:
    @scripts/smoke.sh {{ args }}

# Prepare the smoke test virtualenv without running the test (CI pre-bake).
[group('(3) test')]
smoke-setup:
    @scripts/smoke.sh --setup-only

# Render install-config/agent-config templates into okd/state/.
[group('helper')]
render:
    @scripts/okd-render.sh

# Show pinned versions (and the live cluster version when reachable).
[group('helper')]
versions:
    @scripts/okd-info.sh versions

# Extract the ingress router CA so clients can verify Route TLS (used by smoke).
[group('helper')]
router-ca:
    @scripts/router-ca.sh

# --- private steps of okd-install (callable individually when debugging) ----

[private]
net-setup:
    @scripts/net-setup.sh

[private]
okd-download:
    @scripts/okd-download.sh

[private]
okd-iso:
    @scripts/okd-create-iso.sh

[private]
okd-vm:
    @scripts/okd-create-vm.sh

[private]
okd-wait:
    @scripts/okd-wait.sh

[private]
okd-postinstall:
    @scripts/okd-postinstall.sh
