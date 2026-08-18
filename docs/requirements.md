# Host Requirements

The harness runs on any x86_64 Linux box with KVM. Nothing is host-specific:
sizing, IPs, and versions live in [config.env](../config.env), and
`just host-check` tells you *before* any state changes whether a box
qualifies and why not. macOS cannot host the harness (libvirt/KVM is
Linux-only) — Macs participate as clients (`oc`, console, smoke test over
the LAN against a `lan`-mode box).

## Sizing tiers

| Tier | Host minimum | VM sizing (`config.env`) | Expectation |
|---|---|---|---|
| **Minimum** | 10 threads, 32 GiB RAM, 250 GB free, KVM | 8 vCPU / 24 GiB / 150 GB | Cluster + ChRIS + smoke test pass; sluggish console |
| **Comfortable** | 12–16 threads, 64 GiB, 400 GB | 10 vCPU / 32 GiB / 200 GB (default) | Committed defaults |
| **Reference (miami.local)** | 16 threads, 123 GiB, ~880 GB NVMe | up to 12 vCPU / 64 GiB | Headroom for UI chart, load experiments |

Minimum-tier example override (`config.local.env`):

```sh
VM_VCPUS=8
VM_RAM_MIB=24576
VM_DISK_GB=150
```

The official SNO floor is 8 vCPU / 16 GiB / 120 GB; we size above it because
ChRIS (Phase 2) runs on top of the cluster.

### Hosts below the Minimum tier

`host-check` enforces two independent things: **relative headroom** (the host
needs `VM_VCPUS + 2` threads, `VM_RAM_MIB + 8 GiB`, `VM_DISK_GB + 50 GB`) and
**absolute floors**. Below the hard floor — 4 vCPU / 16 GiB / 120 GB — it fails
preflight, because SNO will not come up. Between the hard floor and the Minimum
tier it warns and continues.

An **8-thread host is the practical edge**: headroom caps you at `VM_VCPUS=6`,
two below the Minimum tier. Such a box does install and does run ChRIS, but
every operator rollout is slow — and the first casualty is the post-install
cluster-stability wait, because it needs one contiguous window in which *all*
~34 operators are simultaneously settled. If `okd-verify`'s
`cluster-operators` check times out, give it a bigger budget in
`config.local.env`:

```sh
VM_VCPUS=6
CLUSTER_STABLE_TIMEOUT=40m
```

[troubleshooting.md](troubleshooting.md#cluster-operators-fails) explains how
to tell a slow settle apart from a genuinely broken operator.

Notes:

- **Nested virtualization** (harness inside a cloud VM) works if the VM
  exposes VT-x/AMD-V; expect slower installs.
- **Disk:** point `IMAGES_DIR` at your big volume if the repo does not live
  on one. `host-check` measures free space at the actual target. Use **NVMe**
  — etcd needs WAL fsync p99 under 10 ms, and miami.local measures ~7.8 ms on
  a Micron 2300, so a spinning disk (`lsblk -o NAME,ROTA` → `ROTA=1`) is not
  viable.
- The host keeps working normally: default VM leaves >70% of the reference
  box free. Daily CUBE development stays on Docker Compose (miniChRIS-docker).

## Distro support

The harness itself is distro-neutral: every script beyond initial package
installation uses portable tools (`virsh`, `virt-install`, `qemu-img`,
`envsubst`, `jq`, `dig`, `openssl`), and `net-setup` handles both ufw and
firewalld. What differs per family:

| Family | Status |
|---|---|
| **Ubuntu / Debian** (apt) | Fully automated by `host-setup.sh`. **Validated:** Ubuntu 26.04 (see [versions.md](versions.md)). |
| **Fedora / RHEL / CentOS Stream** (dnf) | Works; install the package equivalents manually (below), then use the harness normally. Untested by us so far — expect rough edges, not design gaps. |
| Other Linux | Should work if you can supply the tool list below plus libvirt/KVM. |
| macOS | Not a harness host (no KVM); client only. |

Fedora/RHEL-family equivalents of what `host-setup.sh` installs:

```sh
sudo dnf install -y libvirt virt-install qemu-kvm qemu-img gettext \
    bind-utils jq curl just haproxy   # haproxy: lan mode only
sudo systemctl enable --now libvirtd  # or virtqemud.socket on modular setups
sudo usermod -aG libvirt "$USER"      # then re-login
# just/helm on RHEL proper: EPEL or the upstream installer scripts
```

RHEL-family caveats:

- **Modular libvirt daemons:** newer Fedora runs `virtqemud` instead of the
  monolithic `libvirtd`; `host-check` accepts either.
- **SELinux + HAProxy (`lan` mode):** enforcing hosts block HAProxy binding
  the non-standard `:6443` — `sudo setsebool -P haproxy_connect_any 1`.

## Software

Installed by `bash scripts/host-setup.sh` (apt-based distros; needs sudo):

- `libvirt-daemon-system`, `libvirt-clients`, `virtinst`,
  `qemu-system-x86`, `qemu-utils` — the VM stack
- `gettext-base` (envsubst), `jq`, `curl`
- `just` (apt or official installer), `helm` (Phase 2)
- `haproxy` — **lan mode only**
- Pinned `oc` / `kubectl` / `openshift-install` are fetched from the OKD
  release by `okd-download` into `okd/state/bin/` (never installed
  system-wide; the version pin lives only in `config.env`).

After host-setup, re-login once so `libvirt` group membership takes effect.

## Network

- Outbound internet: OKD release payload + SCOS boot image (several GiB on
  first install), container images, and sslip.io DNS resolution.
- A resolver that does **not** filter private-IP answers (DNS rebind
  protection breaks sslip.io — `host-check` catches this; fallback in
  [networking.md](networking.md)).
- `lan` mode only: ports 80/443/6443 free on the host.

## Time expectations

| Operation | Wall clock |
|---|---|
| `host-setup` | 2–5 min |
| `okd-download` + agent ISO | 5–15 min (first run; cached after) |
| VM install to `install-complete` | 25–60 min unattended |
| `okd-postinstall` + `okd-verify` | 5–10 min |
| `okd-nuke` → full reinstall (clean recreate) | **41 min measured** (2026-07-15, miami.local, cold caches) |

Measured times are recorded in [versions.md](versions.md) alongside each
validated combination; expect the upper ranges on minimum-tier hardware or
slow networks.
