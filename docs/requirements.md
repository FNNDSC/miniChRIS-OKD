# Host Requirements

The harness runs on any x86_64 Linux box with KVM. Nothing is host-specific:
sizing, IPs, and versions live in [config.env](../config.env), and
`just host-check` tells you *before* any state changes whether a box
qualifies and why not. macOS cannot host the harness (libvirt/KVM is
Linux-only) — Macs participate as clients (`oc`, console, smoke test over
the LAN against a `lan`-mode box).

## Surveying a candidate host

`host-check` needs a prepared clone. To find out whether a box is worth
preparing at all, run the survey against it from any machine — it is a
single self-contained script with no repo, sudo or libvirt dependency:

```sh
ssh user@candidate 'bash -s' < scripts/host-survey.sh
just host-survey user@candidate        # same thing; extra ssh options pass through
just host-survey                       # this box
IMAGES_DIR=/data/okd just host-survey user@candidate   # assess a specific images dir
```

It reports the sizing tier the box lands in, which resource limits it (and the
`config.local.env` overrides it would need), and whether the volume that would
hold the VM image is SSD/NVMe-backed. It looks at `$HOME` (the default
`IMAGES_DIR` lives inside the clone) and every other local volume with room for
the VM, flags network filesystems and spinning disks, and suggests an
`IMAGES_DIR` on the best volume — one you can write to, since `okd-create-vm`
and `okd-teardown` work there as you. It also reports whether the distro is on
the automated `host-setup.sh` path, free ports and firewall state for `lan`
mode, and —
the part `host-check` cannot tell you before you commit to a mode — whether
the resolver passes `10.x` *and* `192.168.x` sslip.io answers, i.e. which
`ACCESS_MODE` is safe ([networking.md](networking.md)). Exit 0 means viable
(possibly with overrides); things `host-setup` fixes are notes, not failures.

## Sizing tiers

| Tier | Host minimum | VM sizing (`config.env`) | Expectation |
|---|---|---|---|
| **Minimum** | 10 threads, >32 GiB RAM (see note), 200 GB free, KVM | 8 vCPU / 24 GiB / 150 GB | Cluster + ChRIS + smoke test pass; sluggish console |
| **Comfortable** | 12 threads, >40 GiB RAM (see note), 250 GB free, KVM | 10 vCPU / 32 GiB / 200 GB (default) | Committed defaults |
| **Reference (miami.local)** | 16 threads, 123 GiB, ~880 GB NVMe | up to 12 vCPU / 64 GiB | Headroom for UI chart, load experiments |

Each "host minimum" is the VM sizing beside it plus `host-check`'s fixed
headroom (2 threads, 8 GiB, 50 GB) — so the **defaults need 12 threads /
40 GiB / 250 GB free**, and reaching the Minimum tier's host figures means
applying the Minimum VM overrides below as well.

**The RAM figures are `MemTotal`, not nameplate.** `host-check` reads
`/proc/meminfo`, which reports a few percent below nominal once firmware and
the kernel have taken their share — measured 3.7 % on miami.local (a 128 GiB
box reports 126 189 MiB). So a nominally **32 GiB machine reports ~31 550 MiB
and misses the Minimum tier's 32 768 MiB by about 1.2 GiB**. On such a box
either accept a smaller VM (`VM_RAM_MIB=22528`, below the documented minimum —
expect slow operator settling) or use the next size up. The same 4 % applies to
the defaults: 40 GiB nominal is not enough, 48 GiB is.

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
~34 operators are simultaneously settled.

Note that **RAM, not CPU, is usually what actually blocks you** on a box this
size. The headroom checks are hard failures, and an 8-thread desktop typically
has 32 GiB — which reports ~31 550 MiB, so it cannot host the default 32 GiB VM
(needs 40 960 MiB) *or* the Minimum tier's 24 GiB VM (needs 32 768 MiB). Drop
`VM_RAM_MIB` as well or preflight fails outright:

```sh
VM_VCPUS=6
VM_RAM_MIB=22528          # 22 GiB + 8 GiB headroom fits under ~31 550 MiB
VM_DISK_GB=150
CLUSTER_STABLE_TIMEOUT=40m
```

Both `VM_VCPUS=6` and `VM_RAM_MIB=22528` sit between the hard floor and the
Minimum tier, so `host-check` advises and continues rather than failing. The
enlarged `CLUSTER_STABLE_TIMEOUT` is the one that matters in practice: a slow
box passes preflight and installs, then fails `okd-verify`'s
`cluster-operators` check on the default 20 m budget.

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
    bind-utils python3 jq curl just haproxy   # haproxy: lan mode only
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
- `gettext-base` (envsubst), `bind9-dnsutils` (dig — node-view DNS
  assertions), `jq`, `curl`
- `python3-venv` — smoke test virtualenv (Phase 3)
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
