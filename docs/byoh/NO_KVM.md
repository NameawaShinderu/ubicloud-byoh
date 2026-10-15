# The virtualization ladder: fast first, emulation last

Status: 2026-10-15, branch `no-kvm` (from `byoh-driver` 9e22d71ec plus the QEMU-TCG work), design
revision 2. This document replaces [EMULATED_HOSTS.md](EMULATED_HOSTS.md) as the entry point for hosts
without KVM. That file stays as the detailed reference for rung L5.

Labels used throughout:
- **SHIPPED**: code on this branch, covered by the spec gate.
- **VERIFIED**: executed here (the shared lab machine, AMD Ryzen 7 3800X, kernel 6.8; a shared
  machine, so treat every timing as ±20%). The "lab spike" is the 2026-10-15 no-KVM spike, run in a
  `ubi-q-*` container without `/dev/kvm` and without `--privileged`.
- **SOURCE**: read in a cited document, with a confidence (high, medium, low). "From memory" means
  recalled, not checked against a document here.
- **PLANNED**: specified in the build plan (section 15), not written yet.
- **UNVERIFIED**: not executed anywhere. Every real-infrastructure test in section 14 is UNVERIFIED.

Rung numbers changed in revision 2: the rungs are now ordered by **measured speed**, so system
containers are L3 and PVM is L4. The tier ids (`kvm`, `container`, `pvm`, `emulated`) are the stable
names in code and data; rung numbers are display only. The SHIPPED code (`lib/byoh_virt_ladder.rb`)
still prints the revision-1 numbers ("L3 PVM", "L4 system containers") until WP3 renumbers them.

## 1. The short answer

Every fast VM monitor needs KVM: Cloud Hypervisor (what Ubicloud runs), Firecracker, crosvm, Kata's
Dragonball and QEMU-KVM all open `/dev/kvm` (SOURCE, high). Swapping Cloud Hypervisor for Firecracker
or crosvm gains nothing on a machine without KVM. There are only three ways to stay fast:
1. **Get KVM**: it is there (L1), or it can be switched on (the L2 fix).
2. **Share the kernel**: a system container (L3), near native, weaker isolation.
3. **Get KVM in software**: PVM (L4), VM isolation, but a custom host kernel.

When none of them is possible, the last resort is QEMU's emulator (L5).

| Rung | Tier id | The machine | What runs the guests | Speed vs native | Isolation | State |
|---|---|---|---|---|---|---|
| **L1** | `kvm` | `/dev/kvm` works and has the capabilities Cloud Hypervisor needs | Cloud Hypervisor exactly as today (QEMU-KVM for B200/B300 GPUs, unchanged) | ~native on bare metal; nested: CPU-bound ≥90%, page-fault-heavy work much less (section 3; own measurement planned, L1-T2) | Hardware VM | Today's product, SHIPPED; detection v1 SHIPPED, v2 PLANNED (WP3) |
| **L2** | — | The hardware can virtualize, but KVM is off or hidden (firmware, module, hypervisor CPU model, cloud option) | Nothing until it is fixed | — | — | Detection and per-platform fix SHIPPED; refusal at registration with a recommended plan PLANNED (WP4) |
| **L3** | `container` | Any x86_64 Linux ≥ 5.12 with cgroup v2 | Unprivileged LXC system container in rhizome's per-VM network namespace | **CPU 95-99%, memory bandwidth 91-98%, 3.6-5.4 s to SSH** (VERIFIED, `dir` disk driver only) | Shared kernel: weaker than a VM | Feasibility VERIFIED (section 5); backend PLANNED (WP5), experimental |
| **L4** | `pvm` | No hardware virtualization; a PVM host kernel (`kvm_pvm`) | Cloud Hypervisor with direct kernel boot of a PVM guest kernel | SOURCE only: near single-level KVM (paper); 57% of native for a kernel build on m6a (third party). No own number | VM, with a software world switch | Detection SHIPPED; host side VERIFIED under emulation, guest boot UNVERIFIED; build gated on a go/no-go test (WP7) |
| **L5** | `emulated` | Anything x86_64 | QEMU TCG (software CPU) | CPU 26-29%, memory bandwidth ~2.5%, 64-96 s to SSH (VERIFIED) | Not a security boundary | Rhizome side on this branch; control-plane hookup PLANNED (WP6), experimental ([EMULATED_HOSTS.md](EMULATED_HOSTS.md)) |

**L3 or L4?** L3 is the speed fallback. L4 is chosen only when the operator needs VM-level isolation
without hardware virtualization and accepts a custom host kernel. On AWS, GCP and Azure the
recommended answer is almost always a nested-capable instance type of the same size (section 7),
not L3 or L4.

Rules (U1 and "never silent"):
1. **An L1 host behaves byte for byte as today**, pinned by golden specs captured from 9e22d71ec
   (section 15, "U1 proof"). One known exception is open: the QEMU-KVM path *without* hugepages
   switched from `-m` to a shared memfd backend on this branch (commit f1e99cdaa,
   `rhizome/host/lib/vm_setup.rb` "vhost-user devices need guest RAM ..."). WP2 restricts that
   change to emulated VMs and pins the old unit with a golden fixture. Open until WP2.
2. **A host's tier is set once, at registration**: declared, or `auto` (chosen from the probe and
   printed, and only with `--accept-fallback`). It never changes afterwards (a database trigger). A
   later probe can page, but never moves a host.
3. **A lower-tier VM exists only if** the location allows the tier, the project holds the grant, the
   customer picked a lower-tier size explicitly, and the tenancy rules hold (section 12). Internal
   services (Postgres, Kubernetes, runners, load balancers) are `kvm`-only.
4. **No cloud-specific code path.** Platforms are rows in `lib/byoh_virt_platforms.rb`, and their
   remediation is text in that table and in section 4.

What the user gets on each kind of machine, fastest option first:

| Machine | Best rung | What to do |
|---|---|---|
| Bare metal (any provider, own hardware) | L1 | Nothing, or switch VT-x/AMD-V on in the firmware (L2 fix) |
| Cloud VM with nested support (AWS C8i/M8i/R8i, GCP Intel series, Azure Dv3+, OCI Standard3/E5) | L1 nested | Switch nested virtualization on (section 4); same size, about the same price (section 7) |
| Proxmox, VMware, Hyper-V, VirtualBox, libvirt VM | L1 nested | Expose VT-x to the VM, CPU type `host` (section 4) |
| Cloud VM without nested (other AWS families, Hetzner Cloud, most VPS) | L3, or L4 if VM isolation is required | Move to bare metal or a nested-capable type if you can; otherwise `--virt-tier auto --accept-fallback` (picks L3), or declare `pvm` |
| Anything else that runs Linux on x86_64 | L5 | Demos, CI, compatibility only |
| A container (OpenVZ, LXC or Docker VPS) | none | Refused: run the data plane on a VM or on metal |

## 2. Detection

### 2.1 What ships on this branch (SHIPPED)

| Piece | File | What it does |
|---|---|---|
| Probe | `rhizome/host/lib/virt_probe.rb`, `rhizome/host/bin/virt-probe` | Read-only. Gathers facts and prints a tier (`--json` or text). It needs no gems and no rhizome, so it can be piped to a fresh host. |
| Ladder | `lib/byoh_virt_ladder.rb` | Parses a report, maps the tier to a rung, matches the platform, and builds the fix text and the caveats. |
| Platforms | `lib/byoh_virt_platforms.rb` | Data table: DMI and `systemd-detect-virt` patterns, nested support, fix text. |
| Record | `migrate/20261015_vm_host_virt_probe.rb` | `vm_host.virt_probe jsonb` holds the report plus the rung, platform, fix and caveats. |
| Automatic probe | `prog/learn_virt.rb`; `prog/vm/host_nexus.rb` `prep` | BYOH hosts (`VmHost#byoh?`) probe at prep. A host off L1 gets a page (`ByohVirtTier`) carrying the fix; the page resolves when a later probe finds KVM. |
| Operator CLI | `bin/byoh-virt` (`lib/byoh_virt_cli.rb`) | `probe --main-ip` (before registration, over SSH), `explain` (saved JSON), `script`, `show --host`, `refresh --host`. |
| Installer | `scripts/byoh/bootstrap-data-plane.sh` step 1b | Prints the probe report, then applies the same KVM checks as before. |

What did **not** change: `KvmCheck`, PrepHost, the allocator, VM creation, and every L1 code path.
A host off L1 is still refused by PrepHost exactly as before. The ladder adds the reason and the fix.

`VirtProbe.classify` (rhizome, report v1) decides, in this order:

1. `systemd-detect-virt --container` names a container, or (without systemd) `/.dockerenv`,
   `/run/.containerenv` or `container=` in PID 1's environment: **`container`**, which is refused.
2. `/dev/kvm` is a character device:
   - it does not answer `KVM_GET_API_VERSION` with 12: **`kvm_blocked`**
   - `kvm_pvm` is loaded and neither `kvm_intel` nor `kvm_amd` is: **`pvm`**
   - otherwise: **`kvm`**. It is `nested` when the CPU has the `hypervisor` flag or systemd names a VM technology.
3. There is no `/dev/kvm`:
   - x86 with `vmx` or `svm`: **`kvm_blocked`** (module not loaded, or loaded without `/dev/kvm`)
   - bare metal with neither flag: **`kvm_blocked`**, because the firmware disabled VT-x. Since about
     Linux 5.6 the kernel drops `vmx` from `/proc/cpuinfo` when the firmware locks VMX off (SOURCE,
     medium; the kernel's "VMX feature" reporting). AMD does not do this for SVM (see 2.2).
   - the running kernel's `modules.dep` lists `kvm-pvm.ko`: **`pvm_blocked`**
   - otherwise: **`none`**

Facts gathered (v1): arch, kernel release, CPU vendor and model, the flags `vmx svm hypervisor pdpe1gb`,
`/dev/kvm` and its API answer, the loaded modules `kvm kvm_intel kvm_amd kvm_pvm`, the `nested`
module parameter, `kvm-pvm.ko` availability, `systemd-detect-virt --vm/--container`, and the DMI
fields `sys_vendor product_name product_version bios_vendor board_vendor chassis_vendor chassis_asset_tag`.

VERIFIED on the lab machine:
- inside a docker container without `/dev/kvm`, through the real bootstrap step 1b on Ubuntu 24.04 (Ruby 3.2): `tier: container`
- inside an Alpine container without systemd: `tier: container`, from `/.dockerenv`

UNVERIFIED: a real L1 bare-metal host, a nested VM, a PVM host, and the cloud VMs in section 14.

Using it today: before registering, on the control plane (the host needs `ruby`, which the bootstrap installs):

```
bin/byoh-virt probe --main-ip 203.0.113.10 --ssh-key ~/.ssh/byoh_data
# exit 0: L1, register it. exit 3: not L1; the output carries the fix.
```

`--user` must be root (the default), or a user in group `kvm`, until WP3 adds `sudo -n`. Today the
probe runs as the given user without sudo. On Ubuntu `/dev/kvm` is `root:kvm 0660`, so for any other
user opening it fails with `EACCES`, and a working L1 host is reported as `kvm_blocked` ("/dev/kvm
exists but does not answer KVM_GET_API_VERSION (Permission denied ...)"), exit 3.

On the host itself: `scripts/byoh/bootstrap-data-plane.sh` (step 1b), or `sudo ruby rhizome/host/bin/virt-probe`.
After registration: `bin/byoh-virt show --host vh...`. After fixing the host:
`bin/byoh-virt refresh --host vh...`, then let PrepHost retry (a failed prep strand retries with backoff).

### 2.2 Detection v2 (PLANNED, WP3)

**Facts and classification are split.** `rhizome/host/lib/virt_probe.rb` becomes a fact collector
(report v2; the parser accepts v1 and v2). `ByohVirtLadder.classify(facts)` is a pure control-plane
function, so M4's shell preflight can feed it facts gathered its own way (section 2.3). The rhizome
`VirtProbe.classify` stays for the on-host text output; a shared spec feeds the same fixtures to both
and requires equal results.

New facts, all read-only:
- **BIOS evidence in the kernel log** (`journalctl -k -b`, falling back to `dmesg`): "VMX (outside TXT)
  disabled by BIOS", "SVM disabled (by BIOS)", `kvm: disabled by bios`. It **takes precedence over the
  flag path**. That fixes AMD with SVMDIS set: Linux keeps `svm` in `/proc/cpuinfo`, so v1 would print a
  `modprobe` fix where the firmware is the cause (SOURCE, medium, kernel behaviour from memory).
- **A functional KVM check:** open `/dev/kvm`, `KVM_GET_API_VERSION`, `KVM_CREATE_VM`, then
  `KVM_CHECK_EXTENSION` for each capability Cloud Hypervisor v46 requires at start. The list is read
  from CH v46's `hypervisor/src/kvm` `check_required_extensions` when WP3 is written, and recorded per
  capability. A missing capability fails L1 with its name. EPT/NPT (`vmx_flags`, the `ept`/`npt` module
  parameters) are recorded. The check creates a VM fd and closes it; it changes nothing.
- **The errno of each step.** `EACCES`/`EPERM` gives the class **`unknown_permission`** ("re-run as
  root"), never `kvm_blocked`.
- `/dev/kvm` mode and group (L4's udev rule check).
- **CPU model:** `kvm64`, `qemu64`, "Common KVM processor" or "QEMU Virtual CPU" gives tier
  **`kvm_blocked`** (L2), reason `cpu_model`, fix "set the VM's CPU type to host". The rule applies
  with or without `vmx` and whether or not `/dev/kvm` answers:
  - Without `vmx` (Proxmox's default "Common KVM processor"), v1 says `none`.
  - With `vmx` and a working `/dev/kvm`, v1 says `kvm`.
  v2 overrides both, so `auto` refuses with the fix (the `kvm_blocked` row of section 11.2) instead of
  falling back to a lower tier. This is the same rule as M4's PF3, so the two never disagree.
- **`pdpe1gb`:** missing means `standard_vms?` is false for `kvm`, with its own fix ("expose 1G pages,
  CPU type host"). It is only a caveat for tiers that do not use 1G hugepages (L3, L4, L5).
- **DMI naming a VM vendor overrides a `bare_metal` verdict** (a hypervisor that hides its CPUID bit).
- Secure Boot (`mokutil --sb-state` or efivars), `lockdown`, `/sys/devices/system/cpu/vulnerabilities/*`
  (meltdown, l1tf, mds, retbleed, srso), SMT state.
- Kernel release and `/var/run/reboot-required` (the L3/L4 patch-cadence page, section 5.3).
- **Container readiness:** cgroup v2, kernel ≥ 5.12 (idmapped mounts), AppArmor enabled,
  `kernel.apparmor_restrict_unprivileged_userns` (INFO only; Ubicloud never asks to change it),
  `lxc-start`, `lxcfs`, `prjquota` on the VM filesystem.
- **Emulation readiness:** `qemu-system-x86_64`, OVMF.
- **PVM readiness:** `kvm-pvm.ko` in `modules.dep`, `kvm_pvm` loaded.
- **`ready:`** the tiers whose prerequisites are present. **`recommended:`** the fastest ready tier
  (L3 before L5; L4 is listed only as "isolation option").
  - Exception: on a `pvm` probe, `recommended` is always `pvm`, and `container` and `emulated` are never
    listed as ready. That matches `auto` and the refusals in the `pvm` row of section 11.2, so the
    printed plan is never one that registration refuses.
- Never read: `*_serial`, `product_uuid`. Every host-supplied string is sanitised (control characters
  stripped, length capped at 128) before it reaches `Verdict#text`, a page or the database.

Running the probe: `bin/byoh-virt probe` runs `sudo -n ruby - --json` when `--user` is not root, and
says so when sudo fails instead of misclassifying. LearnVirt runs `sudo host/bin/virt-probe --json`,
as today.

Platform table changes (`lib/byoh_virt_platforms.rb`, WP3):
- A new row `aws_xen`, before `xen`: `sys_vendor` "Xen" and `product_version` matching `amazon` (DMI
  strings from memory, UNVERIFIED) → "Xen-based instance: move to a Nitro type (C8i/M8i/R8i with nested
  virtualization, or .metal)".
- AWS sub-rules on the instance type in `product_name`, as an **explicit family list** with its source:
  `c8i m8i r8i` → "stop the instance and enable nested virtualization in the CPU options"; `*.metal` →
  "should be L1: check the module"; anything else → "move to C8i/M8i/R8i (same size, similar price) or
  .metal". No generation regex: 7th-generation support is not assumed (section 4).
- Each row carries a `cost_hint` (data for section 7).
- Wording by the row's `nested` value: only a `kvm_blocked` probe is "probably fixable (L2)". `none` on a
  `yes`/`some` platform is "fixable by changing the instance type or option"; on `ask`, "ask your
  provider whether nested virtualization can be enabled".

### 2.3 Hook for M4's host preflight

M4 owns host preflight (`scripts/byoh/host/ubicloud-host`, `lib/byoh_host_preflight.rb`, PF3). The
contract between them:

- **Today (SHIPPED):** in the same SSH session, pipe `ByohVirtLadder.remote_script` to `ruby - --json`
  and pass the output to `ByohVirtLadder.parse`. Use `Verdict#fix` as PF3's fix text, `Verdict#caveats`
  as PF3 INFO lines, and `Verdict#standard_vms?` as PF3's pass condition. It agrees with `KvmCheck`
  except in two cases:
  - On a PVM host, `KvmCheck` refuses it for lacking `vmx`/`svm`, and the ladder refuses it as "not supported yet".
  - When `/dev/kvm` exists but the `KVM_GET_API_VERSION` ioctl fails, the ladder says `kvm_blocked`
    while `KvmCheck`, which checks only the character device and the CPU flag, passes. This includes
    every probe run as a non-root user outside group `kvm` (section 2.1).
- **After WP3 (PLANNED), one rule:** PF3 delegates the virtualization verdict to
  `ByohVirtLadder.preflight_check(facts, declared_tier:)`, which returns
  `{status: pass|fail|info, fix:, caveats:}`.
  - M4's bash preflight emits the raw facts it already gathers in its pinned session (flags,
    `/dev/kvm`, modules, DMI, `systemd-detect-virt`, CPU model). Facts it does not gather (the ioctl
    results, the capabilities) give `unknown` for that check, never L2; LearnVirt re-checks at prep.
  - The ladder adopts M4's `kvm64`/`qemu64` refusal as `kvm_blocked`, reason `cpu_model` (section 2.2).
  - `declared_tier` other than `kvm`: PF3 becomes INFO for the KVM checks, the tier's own readiness
    facts gate instead, and PF4 (hugepages) is skipped.
- **Expected merge conflicts with M4**, each planned as additive hunks: `bin/register-byoh-host`, the
  registration files (section 11.4), `lib/byoh_location_cli.rb`, `model/vm_host.rb`,
  `prog/vm/host_nexus.rb` (`assemble`, `prep`, `wait_prep`), `scheduling/allocator.rb`, PLATFORMS.md,
  TROUBLESHOOTING.md, and `cache/schema.cache` (regenerate it; never merge the binary).

## 3. L1 and nested virtualization

L1 is today's product; its code is unchanged. The probe adds three caveats when the host is itself a VM (`nested`):

1. **Speed.** Google documents "a 10% or greater decrease in performance for CPU-bound workloads"
   for nested VMs, more for I/O-bound ones (SOURCE, high, [GCP nested overview][gcp-nested]). The
   PVM paper measured nested KVM (EPT-on-EPT) on Alibaba Cloud at up to about 5× slower than
   single-level KVM for a 16-way kernel build, and about 550× for SPECjbb under contention, because
   every guest page-table change traps to both hypervisors (SOURCE, high, [SOSP'23][pvm-paper] figure 2).
   Light, CPU-bound work is near native; fork- and memory-heavy work suffers most. Our own numbers on
   an m8i, measured the same way as L3 in section 5.1, are test L1-T2 (UNVERIFIED until run).
2. **Host lifetime.** The provider's maintenance can stop or reboot the L1 VM, taking every guest
   down. AWS does not support hibernation with nested virtualization (SOURCE, high, [AWS][aws-nested]).
3. **Health checks.** The clocksource and disks are virtual, so `bin/monitor` may misfire (PLATFORMS F5).

The probe also warns when `pdpe1gb` is missing: without it there are no 1G hugepages for
`Prog::SetupHugepages` (SHIPPED as a caveat; a refusal with its own fix from WP3).

## 4. L2: switch KVM on. Platform table

`ByohVirtPlatforms` matches the first row whose patterns all match. Keys are the anchors the code
records in `vm_host.virt_probe["platform"]`. Offerings change; this table was checked 2026-10-15.

| Key | Platform (DMI signal) | Nested | How to get KVM | Source, confidence |
|---|---|---|---|---|
| `aws` | AWS EC2 (`sys_vendor` "Amazon EC2") | some | `.metal`, or 8th-generation Intel (C8i/M8i/R8i and variants) with CPU option nested virtualization enabled; the instance must be stopped to change it. Available since 2026-02-12. | [AWS docs][aws-nested], high; [Classmethod][classmethod], medium. The AWS locales disagree on whether 7th-generation types are included: check the current list. |
| `gcp` | Google Compute Engine | some | `--enable-nested-virtualization` on Intel series, or AMD N4D; not E2, memory-optimized or Arm; the org policy must allow it | [GCP][gcp-nested], high |
| `azure` | Azure (`chassis_asset_tag` 7783-7084-3265-9085-8269-3286-77) | some | Dv3/Ev3 and newer general-purpose and memory families; not B or A series; check the size page | [Azure blog][azure-nested], high for Dv3/Ev3; newer families medium |
| `hyperv` | Hyper-V guest | yes | `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true`, with the VM off | Microsoft docs, high (from memory, well known) |
| `vmware` | VMware | yes | "Expose hardware assisted virtualization to the guest OS" (`vhv.enable`) | VMware docs, high (from memory, well known) |
| `virtualbox` | VirtualBox | yes | `VBoxManage modifyvm <vm> --nested-hw-virt on` | VirtualBox manual, high |
| `oci` | Oracle Cloud (`chassis_asset_tag` OracleCloud.com) | some | VM.Standard3.Flex (Intel) or VM.Standard.E5.Flex (AMD); not Ampere | [Oracle blog][oci-nested], medium |
| `hetzner_cloud` | Hetzner Cloud (`sys_vendor` Hetzner) | no | Use a Hetzner dedicated server | user reports ([r/incus][hetzner-reddit], [wirelessmoves][wirelessmoves]), medium |
| `digitalocean` | DigitalOcean | no (unsupported) | Some Intel Droplets expose VT-x, but it is not supported and is slow | [DO community][do-nested], medium |
| `linode` | Akamai Cloud (Linode) | no | Not offered; staff cite live migration | [Linode community][linode-nested], low-medium (dated) |
| `vultr` | Vultr | no | Vultr Bare Metal | [NANOG thread][vultr-nanog], low (2021) |
| `scaleway` | Scaleway | ask | Some instance types reportedly expose it; Elastic Metal does | [LowEndTalk][scaleway-let], low |
| `openstack` | OpenStack (OVHcloud Public Cloud and others) | ask | Depends on the cloud operator's nova `cpu_mode` and the compute nodes' `nested=1` | OpenStack docs, high for the mechanism; per-provider unknown |
| `qemu_kvm` | QEMU/KVM: Proxmox VE, libvirt, KVM VPS | ask | Proxmox: `qm set <vmid> --cpu host`, with `nested=Y` on the node; libvirt: `host-passthrough` | Proxmox and libvirt docs, high (from memory, well known) |
| `xen` | Xen | ask | `nestedhvm=1`, which Xen marks experimental | Xen docs, medium |

PLANNED rows and sub-rules (WP3, section 2.2): `aws_xen` (Xen-based AWS types such as t2/m4), the
explicit AWS family list, and a `cost_hint` per row.

The DMI strings for Linode, Vultr and Scaleway are UNVERIFIED guesses, so a miss falls back to the
generic fix. Bare metal matches no row: the fix there is the firmware setting (power the machine off
and on afterwards), or `modprobe`.

## 5. L3: system containers (`container`)

The near-native rung for any Linux machine. The trade-off is one shared host kernel.

### 5.1 What the lab spike ran (VERIFIED)

Test bed:
- Container `ubi-q-sc`, ubuntu:24.04: no `/dev/kvm`, no `--privileged`.
- Capabilities `NET_ADMIN`, `SYS_ADMIN` and `NET_RAW`; `/dev/net/tun`; AppArmor and seccomp unconfined.
- `--cpuset-cpus=12-15 --memory=6g`.

Setup:
- **Runtime:** LXC 5.0.3, unprivileged.
  - `lxc.idmap = u 0 100000 65536` (and the same for `g`), so container root is host uid 100000.
  - `common.conf` plus `userns.conf`: the default seccomp profile, and `cap.drop` of `mac_admin mac_override sys_time sys_module sys_rawio`.
  - `lxc.init.cmd = /sbin/init` (systemd 255).
- **Limits:** cgroup v2 `memory.max = 1G`, `cpuset.cpus` (2 CPUs), `pids.max = 2048`.
- **Network:** rhizome's layout.
  - The "host" namespace links to the per-VM netns through the `vetho`/`vethi` pair.
  - Inside the per-VM netns, the **host end of an LXC veth, named `tapc1`, takes the place of the tap**.
  - The container end is `eth0`, carrying the VM's MAC.
  - dnsmasq runs in the netns for DHCP and DNS. The host NATs egress.
- **Root filesystem:** ubuntu-base 24.04.5 plus `systemd-sysv openssh-server cloud-init netplan.io sudo`.
  It was extracted inside the user namespace, so the files belong to 100000+ and setuid bits survive.
- **cloud-init:** a NoCloud seed in `/var/lib/cloud/seed/nocloud/` (`meta-data`, `user-data`,
  `network-config`). This is the content rhizome already writes to the CIDATA image, as files.

Native is the same container pinned to the same 2 CPUs:

| Metric | Native | System container | Ratio | L5 TCG |
|---|---|---|---|---|
| Start to SSH, first boot with cloud-init | — | **5.42 s**; **3.61 s** after `cloud-init clean` | — | 64-96 s |
| Clean stop (`lxc-stop`, systemd shutdown) | — | 0.23 s | — | ~4 s (QMP powerdown) |
| sysbench cpu, 1 / 2 threads (events/s) | 2082 / 4070 | 2056 / 3852 | **98.8% / 94.7%** | 26-29% |
| sysbench memory, 1 / 2 threads (MiB/s) | 6071 / 9566 | 5940 / 8677 | **97.8% / 90.7%** | ~2.5% |
| fio 1M sequential write, QD8 (directory rootfs on overlayfs) | 396 MiB/s | 432 MiB/s | ≈1 (noise) | 349 MiB/s (ubiblk) |
| fio 4k random read, QD32 | 98.8k IOPS | 113k IOPS | ≈1 (noise) | 10.9k IOPS |
| 4M one-byte syscalls / 2000 fork+exec | 4.91 s / 2394 ms | 5.68 s / 1992 ms | within noise | — |
| `apt-get update` | — | 6.6 s | — | 49 s |
| Idle memory (`memory.current`, page cache included) | — | **35 MB** (peak 76 MB) | — | ~384 MiB overhead per VM |

These numbers are for the `dir` disk driver. The default `crypt-loop` driver (section 5.3) adds
dm-crypt and is unmeasured (UNVERIFIED; fio on crypt-loop is part of L3-T1).

These checks passed inside the container, as root through `sudo`:
- The uid map is `0 100000 65536`, and the host sees the container's systemd as uid 100000.
- Seccomp mode 2 is active.
- `/proc/sys` and `/sys` are read-only, so `touch /proc/sys/kernel/panic` is denied.
- There is no `/dev/kvm` and no block device.
- `systemd-detect-virt` says `lxc`.
- `uname -r` is the host's kernel.

SSH as `ubi`, DHCP, DNS, `apt-get install`, `sudo`, and a clean stop and restart all worked.

**Not tested here:** these need host devices or writes to host kernel state, which the lab rules forbid.
- AppArmor profiles (loading one writes host kernel state)
- lxcfs (needs `/dev/fuse`)
- a disk on loop plus dm-crypt (needs loop and dm devices)
- the host sysctl checks of section 5.3

Also checked (VERIFIED, `ubi-q-grpchk`, ubuntu:24.04 image): `/etc/login.defs` has `SUB_UID_MIN 100000`,
`SUB_UID_MAX 600100000`, `SUB_UID_COUNT 65536`, and `/etc/subuid` exists. The minimal image has no `kvm`
group (it has no systemd); whether a real 24.04 server without the KVM module has it is UNVERIFIED, and
the design no longer depends on it (section 5.3, "User group").

### 5.2 What the spike changes in the design

| # | Finding | Design consequence |
|---|---|---|
| P2 | `ip netns exec` remounts `/sys`, hiding cgroup2; systemd in the container then fails | The rhizome launcher starts `lxc-start` under `ip netns exec` in a private mount namespace that mounts `cgroup2` at `/sys/fs/cgroup` again (VERIFIED fix) |
| P3 | `lxc.net.0.type = phys` with a pre-made veth: the pair is destroyed at stop, and the next start fails | Use `type = veth`, `veth.pair = tap<vm>` and a `script.up` hook. The hook runs the same address and route setup that rhizome applies to a tap today (`setup_taps_6` in `vm_setup.rb`) |
| P4 | dnsmasq `--bind-interfaces` fails when the link does not exist yet | Container VMs start dnsmasq with `--bind-dynamic`. The CH dnsmasq unit stays byte-identical (golden `ch_dnsmasq.service`) |
| P6 | ubuntu-base is too bare: no `dbus`, `systemd-resolved` or `lsb-release`; cloud-init's apt module fails | Container images come from cloud-images.ubuntu.com root tarballs (section 5.3, "Images"). They are separate boot images (`ubuntu-noble-container`), never the VM `.raw` images |
| P7 | `sys-kernel-config.mount` and `sys-kernel-debug.mount` fail | Mask them in the image, as Incus images do |
| P8 | `/proc/meminfo` shows host RAM | lxcfs is required on L3 hosts (UNVERIFIED here) |
| P1, P5 | `/proc` masking; netns SNAT | Lab-only artefacts; nothing to change |

### 5.3 Design (PLANNED, WP5)

- **Runtime.** liblxc driven by rhizome, not an Incus daemon, so there is one control plane.
  `lxc-start -F` runs **as root** from `<vm>.service` with an explicit `lxc.idmap`; never as the VM
  user. There is no `newuidmap` or `/etc/subuid` requirement, and Ubuntu's unprivileged-userns
  restriction stays on (the probe reports it as INFO). systemd-nspawn would also work
  (`--network-namespace-path`, `--private-users=pick`; UNVERIFIED), but LXC brings the mature
  unprivileged seccomp profile, idmap handling and AppArmor templates.
- **Root-trust paths.** Root never writes into a tree the guest controls:
  - LXC config, hooks and console log live in `/var/lib/ubicloud/lxc/<vm>/` (root:root 0700), not under `/vm/<vm>`.
  - `/vm/<vm>` is root-owned on every lower tier (EMULATED_HOSTS.md §4.2 item 5, extended).
  - The NoCloud seed is a root-owned, read-only bind mount (`/var/lib/ubicloud/lxc/<vm>/seed` →
    `/var/lib/cloud/seed/nocloud`, `lxc.mount.entry ... ro,bind,create=dir`).
  - Rhizome never writes into the guest rootfs after the first extraction, and the extraction runs as
    the mapped root (`lxc-usernsexec`) into a fresh directory.
  - The harness plants symlinks at the seed path and in the rootfs, restarts, and asserts that no host file changed.
- **Identity.** Each container gets a 65,536-id slot from a host-local allocator in
  `/var/lib/ubicloud/idmap/` (under `flock`): `base = 1_000_000_000 + slot × 65536`, slots 0..50,000.
  - Every slot lies above `SUB_UID_MAX` (600,100,000, VERIFIED above), so it can never collide with a
    range `useradd` hands out.
  - At start, rhizome refuses if `/etc/subuid` or `/etc/subgid` overlaps the range.
  - Container-host prep sets `SUB_UID_COUNT 0` and `SUB_GID_COUNT 0` in `/etc/login.defs` (container
    hosts only) and strips subuid entries from VM users (`usermod --del-subuids`), outside the golden
    `create_unix_user` heredoc.
  - A slot is freed only after the rootfs and disk are verified deleted. It is recorded in `prep.json`
    and in `vm.params_json`.
  - Neither the user nor the image can choose the range: the 2026 Incus advisory CVE-2026-62313
    ([OpenCVE][cve-idmap]) is the reason.
- **Hardening:**
  - LXC's default seccomp, plus denial of `keyctl bpf userfaultfd perf_event_open kexec_* open_by_handle_at
    io_uring_setup io_uring_enter io_uring_register`.
  - New user namespaces are denied by default.
    - `clone3` is denied outright with `ENOSYS`, because seccomp cannot read its flags: they sit in a
      `struct clone_args` pointer, and seccomp-BPF cannot dereference pointers. glibc then falls back
      to `clone`, as it does under Docker's and LXC's own profiles.
    - `clone` and `unshare` are denied when their flags argument has `CLONE_NEWUSER`.
    - Opt-in per location: ack `container:nested-userns` lifts the `clone`/`unshare` rule; `clone3`
      stays `ENOSYS`. Guest systemd units with `PrivateUsers=` fail without that ack
      (documented; which units is UNVERIFIED).
  - `socket(AF_NETLINK, *, NETLINK_NETFILTER)` denied by default: no in-guest nftables or iptables-nft,
    which also reduces nf_tables exposure. Opt-in ack `container:guest-firewall`. The guest keeps
    `CAP_NET_ADMIN` for netplan.
  - AppArmor `lxc-container-default-cgns`; no nesting; no `/dev/kvm`, `/dev/fuse` or `/dev/net/tun`
    inside; lxcfs; the `cap.drop` list above.
  - Host checks at prep: `dmesg_restrict=1`, `kptr_restrict≥1`, `unprivileged_bpf_disabled≥1`,
    `perf_event_paranoid≥2`. Rhizome checks them and never sets them; a failure is a prep error that
    carries the fix.
  - Patch cadence: LearnVirt (and `bin/byoh-virt refresh`) pages `ByohKernelReboot` when
    `reboot-required` has been present on an L3 or L4 host for more than 7 days. The host kernel
    version is shown on the VM page.
  - gVisor is not used (section 8).
- **cgroups.** `lxc.cgroup.dir.monitor` and `lxc.cgroup.dir.container` are under `<vm>.service`
  (`Delegate=yes`). Limits: `cpu.max`, `memory.max`, `memory.swap.max = 0`, `pids.max`, `io.max`. A
  multi-tenant location (ack `container:multitenant`) requires whole-core `cpuset.cpus` per container,
  or SMT off. The harness asserts the payload's cgroup path, and that `systemctl stop` leaves no process.
- **Disk.** Two drivers; the location chooses one:
  - `crypt-loop` (default): a sparse file → LUKS2 → ext4, mounted at the rootfs with an idmapped mount
    (kernel ≥ 5.12). The data key is unwrapped through the same key-encryption path ubiblk uses, and
    passed with `cryptsetup --key-file=-` (never in argv, the environment or a file), with
    `--pbkdf pbkdf2` (or `luksFormat --volume-key-file -` from stdin). The mapping is closed at stop.
    Disclosure: keys live in the shared kernel. UNVERIFIED in the lab (loop and dm are host devices).
  - `dir`: a plain directory. It requires `prjquota` on the VM filesystem in **every** location, with a
    project quota per VM sized to its storage volume; prep refuses otherwise. There is no mode without a
    quota: one guest could otherwise fill the host's VM filesystem, and rhizome, journald, dnsmasq leases
    and the other VMs on the host would fail with it. The label says "not encrypted", and the location
    needs the ack `container:unencrypted-disk`. It is the only driver the lab harness can run.
  - ubiblk (vhost-user-blk) cannot serve a container; ublk might later (UNVERIFIED).
- **Storage allocation.** `allocate_storage_volume_associations` gets an explicit tier branch: on a
  `container` host a volume gets neither a vhost-block backend nor an SPDK installation (nil/nil,
  `use_bdev_ubi = false`). The kvm path is untouched and golden-pinned. Container hosts skip
  `setup_storage_backend`. Machine images, `track_written` and remote storage are refused for container
  sizes by the policy gate (section 10.3).
- **Network.** Rhizome's per-VM netns, nftables, dnsmasq, anti-spoofing, DNAT/SNAT and
  `ByohEgressNat` stay exactly as they are. The guest end changes from a tap to an LXC veth named
  `tap<vm>`, with the `script.up` hook of P3; dnsmasq uses `--bind-dynamic` (P4); `lxc-start` runs as in
  P2. IPv6 RA and DHCPv6 in the netns are UNVERIFIED.
- **cloud-init.** The same content as `cloudinit` in `vm_setup.rb`, written by a NoCloud directory
  writer. The CIDATA image path stays byte-identical for VMs. Swap, `growpart` and `resizefs` are
  disabled for containers.
- **Images.** `noble-server-cloudimg-amd64-root.tar.xz` from cloud-images.ubuntu.com, verified against
  `SHA256SUMS` (and its gpg signature when available); boot image name `ubuntu-noble-container`.
  linuxcontainers.org is a documented mirror alternative only. Image prep masks
  `sys-kernel-config.mount` and `sys-kernel-debug.mount`, and holds or diverts `linux-image-*` and
  `linux-modules-*` so unattended-upgrades never installs kernels the container cannot use. The refresh
  cadence is documented with the image.
- **User group.** The `create_unix_user` heredoc is unchanged for every tier. Container (and emulated)
  host prep runs `groupadd -f -r kvm`, so `usermod -a -G kvm` cannot fail whether or not the group exists.
- **Serial log** from `lxc.console.logfile` (no early kernel messages). **Metrics** from cgroup
  `cpu.stat`, `memory.current` and `io.stat` instead of the per-PID reads in `rhizome/host/lib/vm_stats.rb`.
- **Unsupported on L3** (the API refuses, or the docs say so):
  - custom kernels and kernel modules, `modprobe`, kernel upgrades inside the guest, eBPF/kprobes
  - sysctls outside the namespace
  - Docker or Kubernetes inside (no nesting)
  - nested virtualization
  - Windows and other non-Linux images, FIPS kernels
  - GPUs
  - swap, memory balloon and live resize as a VM does them, live migration
  - UEFI, `/dev/vda`-based tooling, machine images, remote storage
  - The guest sees the host's kernel version.
- **Denial of service through shared kernel state** (documented, with per-location limit advice):
  the global `nf_conntrack_max`, `aio-max-nr`, dentry cache and inotify limits.

### 5.4 Why L3 is built before L4, and what stays experimental

- The spike ran the whole path without host devices, so the runtime, network, cloud-init and
  lifecycle can be built and tested end to end in the lab harness (`scripts/byoh/test/nokvm/`) with the
  `dir` driver, on a throwaway VM, or on the shared lab machine only with the `ubi-q-nokvm` AppArmor
  profile loaded (section 15, lab harness rules). PVM's guest could not be booted here at all (section 6.6).
- The pieces the lab cannot run (`crypt-loop`, AppArmor, lxcfs, the host sysctl checks) sit in their
  own modules with rhizome specs only. They stay UNVERIFIED until L3-T1 (section 14) passes.
- Until then the `container` family is **experimental**: hidden, granted per project, and labelled.

## 6. L4: PVM, KVM without hardware virtualization (`pvm`)

### 6.1 What it is

PVM (Pagetable-based Virtual Machine) comes from Ant Group and Alibaba. It is a KVM "flavor" module
(`kvm-pvm.ko`, beside `kvm.ko`) that runs the guest's kernel and user space both in hardware ring 3.
It switches worlds through a small "switcher" mapped at the same address in host and guest, and it
virtualizes memory with optimized shadow paging (PCID mapping, prefault, fine-grained locks).
Because it needs no VT-x, it runs inside an ordinary cloud VM. Because it is still KVM, any VMM
that speaks the KVM API sees a `/dev/kvm`. (SOURCE, high: [SOSP'23 paper][pvm-paper] §3, [LPC 2024][pvm-lpc].)

### 6.2 Status and maintenance risk

- **Not in mainline.** It was posted as an RFC to LKML on 2024-02-26 (73 patches, about 7,000
  lines) ([Phoronix][phoronix-pvm], high). No later merge is visible in public sources up to
  2026-10 (SOURCE, medium: searches found none; the Kata blog of 2026-09 still says "out-of-tree", [Kata][kata-pvm]).
- **Kernel trees:** [`virt-pvm/linux`][virt-pvm], default branch `pvm-612`, based on Linux 6.12 LTS
  (medium: inferred from the branch name and [cocoonstack/pvm][cocoon-pvm]). An earlier 6.7-based
  tree was used in [Alex Ellis's write-up][ellis-pvm].
- **Prebuilt artifacts** (third-party; none from the PVM authors):
  - [cocoonstack/pvm][cocoon-pvm] builds Ubuntu host-kernel `.deb`s (Ubuntu's `linux-gcp` config plus `CONFIG_KVM_PVM=m`) and a guest `vmlinux-pvm-amd64` (`CONFIG_X86_PIE`, `CONFIG_PVM_GUEST`). It is tiny and new (1 star). Medium.
  - [TencentCloud/CubeSandbox][cube-pvm] ships OpenCloudOS-based host kernels as `.rpm` and `.deb`, plus a guest `vmlinux-pvm`, and documents `modprobe kvm_pvm`. Medium.
- **Production use:** Alibaba Cloud reports more than 100k secure containers and 400k vCPUs a day on
  PVM (SOURCE, high: [paper][pvm-paper] §4.4). Kata Containers demoed PVM in 2026 ([Kata][kata-pvm]).
- **Risk:** high. An out-of-tree kernel on every host, and a second guest kernel; no security
  backports unless we follow a tree; x86_64 only; Secure Boot must be off or the module signed.

### 6.3 VMM compatibility

| VMM | With PVM | Source, confidence |
|---|---|---|
| Cloud Hypervisor | Boots a PVM guest with stock CH via `--kernel vmlinux-pvm --cmdline ... --disk ...` | [cocoonstack][cocoon-pvm], medium (third party; not executed here, section 6.6) |
| Firecracker | A fork ([loopholelabs `main-live-migration-pvm`][ellis-pvm]) | medium |
| QEMU | "needs a one-line patch" | [Alex Ellis][ellis-pvm], low |
| Dragonball (Kata runtime-rs) | Used in the PVM-enabled Kata demos | [Kata][kata-pvm], medium |

### 6.4 Performance (SOURCE, high: [SOSP'23][pvm-paper] §4, Intel Xeon 8269CY on Alibaba Cloud)

- VM exits: PVM inside a VM ("pvm (NST)") cut exit/entry latency by more than 75% against nested KVM (Table 1).
- Syscalls are PVM's weak spot: up to 7× slower than hardware without "direct switching", and about 1.3× with it (Table 2).
- `fork`/`exec`/`sh` microbenchmarks are slower than nested KVM; most other LMbench rows are better (Table 3).
- Applications: kernel build, Blogbench, SPECjbb and fluidanimate are "close to single-level virtualization", and much better than nested KVM at 16-way concurrency (Figure 11).
- Third party ([Alex Ellis][ellis-pvm], medium): a kernel build in a PVM Firecracker guest on an AWS m6a.xlarge took 2m2s, against 1m10s on the host (about 57% of native). I/O-heavy work showed "noticeable overhead".
- No number of our own: L4-T1 measures it (UNVERIFIED). That is why L4 sits below L3, which is measured near native.

### 6.5 Security

- Guest user and guest kernel live in separate page tables. The host keeps KPTI-style isolation for
  the switcher, and the switcher clears guest registers on exit (SOURCE, high, paper §3.2).
- The authors argue the attack surface is smaller than a container's (about 10 hypercalls against
  250+ syscalls), and that the L0 cloud hypervisor stays thin. That is the authors' claim, not an
  independent audit. PVM has had far less scrutiny than VT-x KVM. Treat it as weaker than L1 and
  stronger than L3 for kernel-level isolation.
- The host kernel is custom, so the host's kernel CVE response becomes ours (section 6.8).
- The PVM kernel needs `pti=off`, which removes Meltdown protection on CPUs that need it. PVM guests
  run in hardware ring 3, so on such a CPU any guest could read host kernel memory: the other VMs'
  dm-crypt and ubiblk keys, the host's credentials and rhizome state. "Single-project" does not make
  that safe when the operator and the project are different parties. Hence:
  - A CPU whose `vulnerabilities/meltdown` is not "Not affected" is **refused for PVM outright**, in
    every location. There is no ack and no override.
  - Multi-tenant PVM also requires SMT off or core scheduling, and "Not affected" for l1tf and mds;
    otherwise the location is single-project. There is no override flag for multi-tenant.

### 6.6 What the lab spike showed (VERIFIED, partial)

Artifacts: [cocoonstack/pvm][cocoon-pvm] v0.1.0, released 2026-08-02:
- host kernel `linux-image-6.12.33-pvm` (`.deb`, 104 MB)
- guest kernel `vmlinux-pvm-amd64` (30 MB)

Both sha256 sums matched the release's `SHA256SUMS`. Cloud Hypervisor v46.0 (`cloud-hypervisor-static`)
matched the sha256 that rhizome pins for 46.0. The PVM host kernel ran as a guest of QEMU TCG with
`-cpu max,-vmx,-svm`, inside a container without `/dev/kvm`. The machine's own kernel was never touched.

| Step | Result |
|---|---|
| PVM host kernel boots without `vmx`/`svm` (only `hypervisor` in `/proc/cpuinfo`) | Works |
| `insmod kvm-pvm.ko` | Works |
| `/dev/kvm` appears (`crw------- 10,232`) | Works |
| Stock CH 46 opens it, creates the VM and starts vCPU 0 | Works (0.41 s) |
| The PVM guest prints anything | **No**, in 4 CPU-model variants (130-500 s each). KVM counters show a page fault that never resolves: about 19.5k `pf_taken`/s with `pf_fixed` stuck at 29, no I/O exits |
| `kvm-pvm cpuid_intercept=1` | "Operation not supported": it needs CPUID faulting, which TCG does not emulate |

Conclusion:
- The host side works without hardware virtualization, and it exposes a KVM API that stock Cloud
  Hypervisor accepts. Detection must therefore record `pvm` as its own tier: treated as L1, every
  VM boot would fail, because UEFI firmware cannot run under PVM.
- **Guest boot is UNVERIFIED.** The stall may come from TCG fidelity (PCID/INVPCID, PKU-based SMAP
  emulation) or from the v0.1.0 build. The branch reworked its 5-level page-table handling on
  2026-09-15, after v0.1.0 was built. Only real hardware can tell them apart: the go/no-go test L4-T1
  (section 14) decides whether WP7 builds L4 at all.

More constraints found by the spike (SOURCE, medium: cocoonstack and virt-pvm docs and issues):
- The host kernel needs `pti=off` (also used by [Slicer][slicer-pvm]), Secure Boot off (the kernel is
  unsigned), and `kvm_intel`/`kvm_amd` not loaded, because they cannot coexist with `kvm_pvm`.
- The guest kernel is module-free and has no initramfs. It has virtio-blk, virtio-net, ext4, overlayfs,
  netfilter and IPv6 built in. It has **no AppArmor, XFS or Btrfs** (VERIFIED by reading `guest-pvm-amd64.config`).
- **CVE-2026-53359 ("Januscape")**, a guest-triggerable use-after-free in the shadow MMU, affected
  PVM. It was fixed on the branch in July 2026. A PVM host must track that branch for security fixes.
- An "out-of-tree module" mode that builds `kvm-pvm.ko` against a stock distro kernel is in
  progress (virt-pvm issues #26 and #29, open). It would remove the host-kernel swap. Not usable yet.
- Upstream reports a CH virtio-pmem root-disk issue ([virt-pvm #1][virt-pvm-issue1]); virtio-blk is
  fine, and that is what Ubicloud uses.

### 6.7 Design (PLANNED, WP7; built only on a GO from L4-T1)

**Go/no-go.** Run L4-T1 (section 14) once on a throwaway non-nested GCP e2 or AWS m6i VM, with Cloud
Hypervisor v46 **and** v53. If neither reaches a login prompt, WP7 delivers detection and docs only:
`pvm` stays a recorded fact, and L4 is "detected, not offered". If GO:

- **Artifacts.** No default third-party pin. The operator supplies the host `.deb` URL and sha256 and the
  guest `vmlinux` URL and sha256 in the location policy. A default pin is allowed only if WP7 verifies
  that (a) the Januscape fix commit is an ancestor of the build's commit, and (b) the build is
  reproducible from virt-pvm source. Preferred: the operator's CI builds from virt-pvm and records the commit.
- **Guest kernel checks** (the kernel is refused otherwise): `CONFIG_VFAT_FS=y`,
  `CONFIG_NLS_CODEPAGE_437=y`, `CONFIG_NLS_ISO8859_1=y` (the CIDATA seed is vfat), virtio-blk and
  virtio-net, ext4, `CONFIG_PVM_GUEST`, `CONFIG_X86_PIE`. The guest image's `/boot/efi` vfat mount is
  checked (from memory: noble mounts it without `nofail`, so a kernel without vfat would hang boot).
- **Host kernel checks before install:** the kernel config contains the drivers the running platform
  uses (`lsmod`, `/sys/class/net/*/device/driver`; for example `CONFIG_ENA_ETHERNET`,
  `CONFIG_BLK_DEV_NVME`); otherwise refuse. AWS is UNVERIFIED separately from GCP.
- **Install** (`rhizome/host/bin/install-pvm-host-kernel`) refuses, before changing anything, when
  Secure Boot is on, on non-x86_64, on a sha256 mismatch, on a Meltdown-affected CPU (any tenancy,
  section 6.5), and when `GRUB_SAVEDEFAULT=true` is set (booting the PVM entry would then save it as
  the default). Then, in this order:
  - **It pins the running stock kernel before installing anything.** It writes
    `/etc/default/grub.d/98-ubicloud-pvm.cfg` with only `GRUB_DEFAULT=saved`, runs
    `grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux $(uname -r)"` and `update-grub`,
    and checks that `grub-editenv list` shows that `saved_entry`. Without the pin, the `.deb`'s own
    `update-grub` would make the PVM kernel the persistent default: Ubuntu's `10_linux` puts the newest
    kernel version in the top entry (6.12-pvm sorts above noble's 6.8), and `GRUB_DEFAULT=0`, or `saved`
    with no `saved_entry`, boots that top entry.
  - It installs the `.deb` and `apt-mark hold`s it.
  - It writes `/etc/grub.d/42_ubicloud_pvm`: one menu entry, `--id ubicloud-pvm`, for the PVM kernel with
    the stock command line plus `pti=off`. `pti=off` goes on that entry only. `GRUB_CMDLINE_LINUX_DEFAULT`
    is never touched, because `10_linux` applies it to every entry, including the stock kernel that is
    the recovery path. It never edits `/etc/default/grub`. After `update-grub` it checks that `pti=off`
    appears in `grub.cfg` exactly once, in the `ubicloud-pvm` entry.
  - It blacklists `kvm_intel` and `kvm_amd`, and loads `kvm_pvm` at boot.
  - It ships a udev rule `KERNEL=="kvm", GROUP="kvm", MODE="0660"`.
  - It runs `grub-reboot ubicloud-pvm`, then checks that `grub-editenv list` shows
    `next_entry=ubicloud-pvm` **and** the stock `saved_entry`. Only then is the boot **one-shot**.
- **HostNexus walk.** `prep` buds PrepHost with the pvm step list (without the KVM check when
  installing) and `Prog::InstallPvmHostKernel`; `wait_prep` accepts a probe of `none`/`pvm_blocked` for
  such a host; `reboot`; a new `verify_virt_tier` label requires LearnVirt to say `pvm`, `/dev/kvm` 0660
  group kvm, API 12 and the capabilities, and only then runs `grub-set-default ubicloud-pvm`. On
  failure it pages "power-cycle the instance from the provider console; it returns to the stock
  kernel". That holds only because the install asserted the stock `saved_entry` before the reboot;
  a host whose assertion failed never reboots. Back on the stock kernel, prep checks that
  `/proc/cmdline` lacks `pti=off`. The per-host ack and the `lockdown` state are recorded in
  `byoh_operator_action`.
- **Capacity.** No hugepages on PVM (shadow paging; this also avoids the `pdpe1gb` requirement); a
  nohugepages-style CH unit; the budget comes from `verify_tier_capacity` (section 10.4).
- **Direct boot.** `--kernel <vmlinux>` and `--cmdline root=<PVM_ROOT[image]> rw console=ttyS0`. The
  guest kernel has no initramfs, so `root=LABEL=` cannot resolve; the root device comes from a per-image
  table (Ubuntu cloud images: `/dev/vda1`). XFS and Btrfs images (AlmaLinux) are refused at VM creation.
  The minimum CH version is recorded per tier. The L1 CH unit stays byte-identical (golden `ch_unit.service`).
- **Unsupported on L4:** anything that needs the image's own kernel (custom kernels, DKMS, kexec,
  kernel updates inside the guest), AppArmor inside the guest, XFS and Btrfs roots, Windows and UEFI,
  GPUs, snapshot, migration, memory hotplug and balloon (untested upstream).

### 6.8 PVM lifecycle (PLANNED)

- **Watching for CVEs.** The operator who enables `pvm` in a location owns watching virt-pvm (the
  branch, its issues, and kernel CVEs against 6.12) for both kernels. The docs name this in the
  location ack text; Ubicloud ships no feed.
- **Host-kernel rollout:** drain the host, then a per-host reboot through HostNexus (the same one-shot
  boot and `verify_virt_tier`), one host at a time.
- **Guest-kernel rollout:** a new pin applies at the VM's next stop/start. A page lists the VMs still on
  an old kernel. The guest kernel version is shown on the VM.
- **Patch cadence:** the `ByohKernelReboot` page of section 5.3 covers L4 hosts too.
- **Recommendation:** on a cloud, a nested-capable instance type (section 7) is almost always cheaper to
  operate than owning a custom kernel on every host.

## 7. Cost guidance

Approximate and UNVERIFIED: check current pricing. The probe's fix text says "same size, about the
same price" only where the platform row's `cost_hint` says so (PLANNED, WP3).

| Cloud | Non-nested type you may be on | Nested-capable type, same size | Delta |
|---|---|---|---|
| AWS | m6i/m7i/c6i/r6i, t3 | m8i/c8i/r8i with the nested CPU option, or `.metal` | similar per-vCPU price (UNVERIFIED) |
| GCP | e2, t2d, AMD and Arm series | n2/c3 (Intel) with `--enable-nested-virtualization` | no nested surcharge (SOURCE, [GCP][gcp-nested]) |
| Azure | B-series | Dv5/Ev5 | similar (UNVERIFIED) |
| Hetzner Cloud | CX/CPX | Robot dedicated (AX/EX) | monthly price comparable for 8+ cores (UNVERIFIED) |
| Typical VPS | any | provider-specific; often none | — |

Two reference points:
- An m8i.2xlarge with nested virtualization was $0.45/h in ap-south-1, against $5.86/h for an
  m5d.metal (VERIFIED on our account, CLAUDE.md §10a).
- A Hetzner A102 dedicated server was about $100 a month, against about $3,500 a month for an AWS
  m7i.metal-24xl on demand ([Alex Ellis][ellis-pvm], medium).

## 8. L5: emulation, and options rejected

L5 is QEMU TCG, described in [EMULATED_HOSTS.md](EMULATED_HOSTS.md). Measured (VERIFIED):
- 26-29% of native CPU per vCPU
- about 2.5% of native memory bandwidth
- 64-96 s to boot to SSH

Estimated, not measured: typical workloads at roughly 5-25% of native (UNVERIFIED, EXTERNAL;
[EMULATED_HOSTS.md](EMULATED_HOSTS.md) section 3).

`tb-size` is pinned to 256, which costs about 384 MiB of overhead per VM. ubiblk works under TCG with
`memory-backend-memfd,share=on`. TCG is not a security boundary.

L5 stays the last resort, **experimental**, labelled "Emulated: slow, compatibility only. Not a
security boundary." It uses the same tier framework as L3 and L4 (`virt_tier = 'emulated'`, section 10)
instead of the separate `vm_host.accel` column that EMULATED_HOSTS.md §6 planned; that migration was
never written, so nothing is renamed. WP6 hooks it up: the family and sizes, the policy gate, the
`verify_tier_capacity` budget, labels and rates; hardening pinned by a golden unit
(`ProtectSystem=strict`, root-owned `/vm/<vm>`), and rhizome refuses to start an emulated VM whose unit
lacks them. Tenancy: one project per **host** by default. Deferred: tuning `EMULATED_VM_OVERHEAD_MIB`
beyond the measured 384 MiB, and further timing tuning.

### Options rejected

| Option | Verdict | Why (source, confidence) |
|---|---|---|
| Firecracker, crosvm, Kata, CH on a machine without KVM | No | They all need `/dev/kvm` (SOURCE, high). With PVM (L4), Firecracker (a fork) and Kata work through PVM's `/dev/kvm` |
| Cloud Hypervisor's MSHV backend | No | It needs Linux running as the **root partition** of the Microsoft Hypervisor, with out-of-tree patches and `/dev/mshv` ([CH mshv.md][ch-mshv], high). An Azure or Hyper-V guest is not a root partition |
| User Mode Linux | No | Its kernel runs as a host process: no cloud images, no firmware, its own kernel. Kernel-side SMP only arrived in 6.19 (2025-12) ([LKML][uml-smp], high), and syscalls trap through ptrace or seccomp. Slower than L3, with no isolation gain over L3's hardening |
| gVisor, as a tier or as a hardening layer for L3 | No | Measured below: CPU and memory near native, but syscalls 13× and fork+exec 5.1× slower, and random-read IOPS halved. It is an application sandbox with limited support for systemd as PID 1 ([gVisor platforms][gvisor-platforms], [systrap][gvisor-systrap]; SOURCE, medium), so it cannot run a cloud image the way L3 does |
| Automatic nested enablement by Ubicloud | No | It needs provider API calls or hypervisor settings outside the host, which breaks "platform-agnostic". The probe prints the exact fix instead |
| Automatic PVM kernel swap (`auto` picking `pvm` on a stock kernel) | No | A kernel swap is never silent: `auto` picks `pvm` only when `kvm_pvm` is already loaded (section 11.2) |

gVisor measurements (VERIFIED in the lab spike: runsc release-20261005.0, systrap platform, same
container and CPUs as section 5.1):

| Metric | Native | gVisor | Ratio |
|---|---|---|---|
| sysbench cpu 1t / 2t | 2082 / 4070 | 2064 / 3999 | 99% / 98% |
| sysbench memory | 6071 / 9566 | 6281 / 9571 | ≈100% |
| 4M one-byte syscalls | 4.91 s | **64.36 s** | **13.1× slower** |
| 2000 fork+exec | 2394 ms | **12281 ms** | **5.1× slower** |
| fio 4k random read | 98.8k IOPS | 51.7k IOPS | 0.52× |

## 9. Decision matrix

Ordered by speed. Scores are relative (5 = best). "Measured" means VERIFIED here; the rest is SOURCE.

| Rung | Speed (numbers) | Isolation | Workload compatibility | Operational complexity (5 = simplest) | Maintenance risk (5 = lowest) | Use when |
|---|---|---|---|---|---|---|
| L1 bare-metal KVM | 5: ~native (today's product) | 5 | 5 | 5 | 5 | Always, if you can |
| L1 nested KVM | 4: CPU-bound ≥90% (GCP: "10% or greater decrease"); page-table-heavy work up to ~5× slower under contention (PVM paper fig. 2) | 5 for guests, plus the provider's L0 | 5 | 4: pick the instance type, switch nested on | 4: provider offerings change | Cloud VMs that offer it |
| L3 system containers | 5: **measured CPU 95-99%, memory 91-98%, SSH in 3.6-5.4 s, 35 MB idle** (`dir` driver) | 2: shared kernel; idmaps, AppArmor, seccomp and cgroups help | 3: no custom kernels, modules, swap or GPUs | 3: a new runtime path; the network is unchanged | 4: mainline LXC and kernel | Speed matters, tenants trusted or one per location; dev/test; cheap VPS |
| L4 PVM | 3-4: near single-level KVM for kernel build, SPECjbb and Blogbench at 16-way; syscalls ~1.3× with direct switching; a third party measured 57% of native for a kernel build on m6a. **No own number** | 4: software world switch, little scrutiny, a 2026 shadow-MMU CVE | 3: Linux only, a Ubicloud- or operator-supplied kernel, no UEFI, Windows, XFS or AppArmor | 2: custom host kernel, `pti=off`, Secure Boot off | 1: out of tree since 2024; third-party builds | No nested, and VM-level isolation is required |
| L5 QEMU TCG | 1: **measured CPU 26-29%, memory bandwidth 2.5%, 64-96 s to SSH** | 1: not a boundary | 4: any x86 image | 4: distro QEMU | 4 | Nothing else possible: demos, CI |

Ranking for "fast on a machine without hardware virtualization": L3 (measured near native), then L4
(near native by its authors' numbers, unproven here, heavy to operate), then L5. For "VM-level
isolation without hardware virtualization", L4 is the only option. Both stay experimental until their
real-infrastructure tests pass.

## 10. Data model, gating and allocator

### 10.1 What is detected vs what is declared

| Record | Where | Written by | Meaning | State |
|---|---|---|---|---|
| Probe report | `vm_host.virt_probe jsonb` (`migrate/20261015_vm_host_virt_probe.rb`) | `Prog::LearnVirt`, `bin/byoh-virt refresh` | The facts, the detected tier, the rung, the platform key, the fix and the caveats. Refreshable; **never changes behaviour** | SHIPPED |
| Declared tier | `vm_host.virt_tier text NOT NULL DEFAULT 'kvm'`, CHECK `IN ('kvm','pvm','container','emulated')` | `HostNexus.assemble(virt_tier:)` at registration only | Which backend the host runs. A `BEFORE UPDATE OF virt_tier` trigger raises when it changes: changing it means re-registering | PLANNED (WP4) |
| Tier/family coupling | CHECK `(virt_tier = 'kvm') = (family NOT IN ('pvm','container','emulated'))` on `vm_host` | the migration | A KVM host never carries a lower-tier family, and vice versa; with the trigger, family changes across the boundary are blocked too | PLANNED (WP4) |
| Location policy | `location.byoh_virt jsonb`: `{"tiers": ["kvm", ...], "acks": [...], "container_disk": "crypt-loop" or "dir"}`, NULL meaning `{"tiers": ["kvm"]}`. CHECK: every non-kvm tier in `tiers` has its base ack | `bin/byoh-location create/set` (each change writes a `byoh_operator_action` row) | Which lower tiers may be offered in this location | PLANNED (WP4) |
| Tier table | `lib/byoh_virt_tiers.rb` (data, like `ByohVirtPlatforms`) | code | Per lower-tier family: tier, accepted probe tiers, hypervisor, PrepHost argument, label, required acks, experimental, uses hugepages, storage | PLANNED (WP4) |

The migration (`migrate/20261016_byoh_virt_tier.rb`) has a `down` that refuses while any non-kvm host
or any non-NULL `byoh_virt` exists; run `bin/byoh-host export-audit` first (CLAUDE.md §8a).
`cache/schema.cache` is regenerated.

Why `virt_tier` and not `accel`:
- The rhizome QEMU work uses `accel` (`kvm`/`tcg`) as a QEMU accelerator inside a VM's `prep.json`
  (`VmSetup#initialize` in `rhizome/host/lib/vm_setup.rb`). It stays there with that meaning.
- The host-level choice is broader than an accelerator: it also covers PVM and containers.
- `vm_host.accel` (EMULATED_HOSTS.md §6) was never applied anywhere, so it is dropped, not renamed.
  The CLAUDE.md §8a rule "never rename an applied migration" is respected.
- "Nested" is a fact in `virt_probe`, not a tier: a nested L1 host runs exactly the L1 code.

### 10.2 The tier table

The lower-tier families are a closed set. `tier_for_family(f)` returns the lower tier for those three
families and `kvm` for every other family, including all upstream AWS, GCP and GPU families (they are
many, so raising on an unknown family would break U1; the CHECK binds hosts to the closed set, so
`kvm` for unknown families cannot fail open).

| `virt_tier` | Accepted probe tiers | Families | Guest backend | PrepHost argument | Uses 1G hugepages | Experimental |
|---|---|---|---|---|---|---|
| `kvm` | `kvm` | `standard`, `premium`, `burstable` and every upstream family (as today) | CH, or QEMU-KVM for B200/B300 GPUs (`model/metal/vm.rb`, unchanged) | none (golden-pinned command) | yes | no |
| `container` | `none`, `kvm_blocked`, `pvm_blocked`; `kvm` with a failing capability/`pdpe1gb`/CPU-model check | `container` | LXC | `container` | no | yes |
| `pvm` | `pvm`; or `none`/`kvm_blocked`/`pvm_blocked` with `--install-pvm-kernel` (re-checked after the reboot) | `pvm` | CH with direct kernel boot | `pvm` | no | yes |
| `emulated` | `none`, `kvm_blocked`, `pvm_blocked`; `kvm` with a failing check | `emulated` | QEMU TCG | `tcg` (the existing third argument of `rhizome/host/bin/prep_host.rb`) | no | yes |

### 10.3 Sizes and the policy gate

- **Sizes** live in a separate constant, `Option::TierVmSizes`. `Validation.validate_vm_size` without
  `extra_families:` never sees them, so Kubernetes, runners, VM pools, inference, VictoriaMetrics and
  the web form refuse them. The existing vm_size error golden stays unchanged.
- **One policy gate** in `Prog::Vm::Nexus.assemble`, a no-op for kvm families (golden: identical
  `assemble` for every existing family). For a lower-tier family it requires:
  - a BYOH location whose `byoh_virt.tiers` lists the tier, and the tier's acks
  - a project grant on the location
  - billing rates for the family in the location
  - no GPU; a boot image allowed for the tier; for `container`, no machine image and no remote storage
  - **tenancy, inside the create transaction:** lock the location row (`SELECT ... FOR UPDATE`) and
    refuse if another project has a VM of a lower-tier family in the location (L3, L4) or on the
    target host (L5), unless the location holds the tier's `multitenant` ack.
- Callers that create service VMs pass `allowed_tiers: ["kvm"]` explicitly (belt and braces).
- `bin/byoh-location grant` refuses a second project for a location whose tiers include a lower tier
  without `<tier>:multitenant`, and `set --visible` is refused likewise. A private location
  (`Location.project_id`) is the recommended default.

### 10.4 Allocator and HostNexus

- **No new allocator filter.** The family filter (`prog/vm/metal/nexus.rb`, the allocator's family
  match) plus the CHECK already keep tiers apart: `standard` never meets a container host, and
  `container` never meets a KVM host. A revision-1 tier filter ("R1") was dropped as redundant: it
  would perturb L1 diagnostics such as `host_capacity_summary`.
- **Defence in depth ("R2"):** `Allocation#update_vm` refuses when `tier_for_family(vm.family)` differs
  from the host's `virt_tier`. That covers `force_host_id` (which passes an empty family filter) and
  admin "Create VM".
- **Storage:** the explicit tier branch of section 5.3, golden-pinned for kvm.
- `HostNexus.assemble(virt_tier:)`: non-kvm only in a BYOH location (`VmHost#byoh?` semantics); the
  family comes from the tier table.
- `prep`: LearnVirt is budded for BYOH hosts (as today); PrepHost gets the tier argument only when it
  is not `kvm` (the kvm command is golden-pinned).
- `wait_prep`: `accepts_slices = os_supports_slices?(os) && virt_tier == "kvm"`. A nil `virt_probe` is
  acceptable only for `kvm`; a non-kvm tier requires the probe to agree (the PVM install exception of
  section 6.7).
- `verify_tier_capacity` replaces `setup_hugepages`/`verify_hugepages` for non-kvm tiers. It writes the
  memory budget into `total_hugepages_1g`/`used_hugepages_1g`, a documented overload (COMPUTE.md).
  Container: `MemTotal` minus a host reserve; emulated: the EMULATED_HOSTS.md §6.4 budget; pvm: as
  container, minus guest overhead.
- `bin/byoh-host move-location` refuses to move a non-kvm host into a location without its tier, and
  `--rollback-to` refuses non-kvm hosts. `MoveVm` refuses moves across tiers; `RolloutRhizome` rolls
  out per tier; GPUs are refused for every non-kvm family.
- Internal services stay on L1: they create VMs with kvm families and pass `allowed_tiers: ["kvm"]`. A
  spec pins this for each service's `assemble`.

### 10.5 LearnVirt: fail-open and tier-aware (PLANNED, WP3/WP4)

- It compares the probe with `virt_tier`, pages `ByohVirtTier` only on disagreement, and resolves the
  page on agreement. Agreement is a safety check, not an authorisation.
- Any exception (a parse error, an SSH failure, a probe crash) records `{"error": ...}`, pages once and
  pops. It never retries forever, and never blocks `wait_prep` for a kvm host.
- It pages `ByohKernelReboot` per section 5.3. Page text is sanitised.

## 11. Operator experience

### 11.1 Before registration: `bin/byoh-virt probe` (SHIPPED; plan output PLANNED, WP3)

It prints the verdict and exits 0 on L1 and 3 otherwise. The format is `ByohVirtLadder::Verdict#text`;
the values below are illustrative and UNVERIFIED except the container case.

```
# AWS m8i.2xlarge, nested on                         # Proxmox VM with cpu=kvm64 (after WP3)
tier: kvm (L1) nested                                 tier: kvm_blocked (L2)
platform: AWS EC2                                     platform: QEMU/KVM (Proxmox VE, libvirt, KVM VPS)
why: /dev/kvm answers KVM_GET_API_VERSION 12          why: cpu_model: "Common KVM processor" (kvm64): the
caveat: nested virtualization: CPU-bound work ...          hypervisor does not expose hardware virtualization
caveat: the provider may stop or restart this VM ...  fix: Proxmox: qm set <vmid> --cpu host, then stop and
caveat: the clocksource is often not tsc ...               start the VM; the node needs nested=Y ...

# Bare metal, Intel VT-x off in the firmware (v1)     # A Docker or OpenVZ "VPS"  (VERIFIED: container case)
tier: kvm_blocked (L2)                                tier: container (refused)
platform: unknown platform                            why: this is a docker container
why: bare metal without the vmx or svm flag: the      fix: Run the data plane on a VM or bare metal, not in
     firmware has VT-x/AMD-V disabled                      a container.
fix: Enable Intel VT-x or AMD-V (SVM) in the BIOS/UEFI
     setup, then reboot.
```

After WP3 the bare-metal case takes its reason from the kernel log when the log has one ("VMX (outside
TXT) disabled by BIOS"), and its fix tells the operator to power the machine off and on.

After WP3 a host without KVM also gets a **recommended plan** with the exact commands:

```
tier: none (no hardware virtualization)       platform: Hetzner Cloud
fastest option: a Hetzner dedicated server (L1). Cost: see docs/byoh/NO_KVM.md §7.
ready fallbacks (fastest first): container (L3, shared kernel, ~native) · emulated (L5, slow)
recommended:
  bin/byoh-location set fsn-cloud --virt-tiers kvm,container --accept container
  bin/byoh-location rates fsn-cloud --family container --from standard --multiplier <X>
  bin/register-byoh-host --location fsn-cloud --main-ip 203.0.113.10 ... --virt-tier auto --accept-fallback
```

### 11.2 At registration (PLANNED, WP4)

Flags on `bin/register-byoh-host`:
- `--virt-tier kvm|auto|container|pvm|emulated`. The default is `kvm`, so today's commands behave as
  today on an L1 host; a non-L1 host is refused, now with the fix and a recommended command line.
- `--accept-fallback`: required whenever the resulting tier is not `kvm`, including through `auto`.
- `--install-pvm-kernel`: only if WP7 goes ahead.
- `--no-virt-probe`: skip the pre-registration probe; LearnVirt checks at prep, and `wait_prep` fails
  with the fix when the probe disagrees with the declared tier.
- The location must already allow the tier. Otherwise the message prints the exact
  `bin/byoh-location set <loc> --virt-tiers kvm,<tier> --accept <tier>` command.

The registration matrix (probe × declared tier). "ack" means allowed with `--accept-fallback`:

| Probe | `kvm` | `auto` | `container` | `pvm` | `emulated` |
|---|---|---|---|---|---|
| `kvm` (capabilities ok, `pdpe1gb`) | register | → kvm | refuse ("has KVM") | refuse | refuse |
| `kvm`, but a capability or `pdpe1gb` check fails | refuse, fix | refuse, fix | ack; the fix printed as advice | refuse | ack |
| `kvm_blocked` (firmware, module, BIOS log, or a `kvm64`-class CPU model with or without `vmx`) | refuse, L2 fix | refuse, L2 fix ("fix KVM, or declare a tier explicitly") | ack; fix printed | ack; fix printed; needs `--install-pvm-kernel` | ack |
| `unknown_permission` | refuse: "re-run the probe as root" | same | same | same | same |
| `none`, platform nested `yes`/`some`/`ask` | refuse, fix and cost hint | → recommended fallback, ack; fix printed as advice | ack | ack; needs `--install-pvm-kernel` | ack |
| `none`, platform nested `no` or unknown | refuse; lists the ready fallbacks | → recommended, ack | ack | ack; needs `--install-pvm-kernel` | ack |
| `pvm_blocked` | refuse | → recommended, ack | ack | ack (`modprobe kvm_pvm` advice) | ack |
| `pvm` | refuse (firmware boot is impossible) | → pvm, ack | refuse ("register it as pvm") | ack | refuse |
| `container` (the data plane is a container) | refuse | refuse | refuse | refuse | refuse |

`auto` never picks `pvm` unless `kvm_pvm` is already loaded: no automatic kernel swap. Every outcome
(probe tier, declared tier, acks) is recorded in the `byoh_operator_action` args.

### 11.3 Data-plane bootstrap (PLANNED, WP4)

`scripts/byoh/bootstrap-data-plane.sh`: the default path stays byte-identical, KVM refusal included.
`--tier auto|container|emulated|pvm` runs the probe, prints the chosen tier, installs only that tier's
userspace packages (`lxc lxcfs uidmap`; `qemu-system-x86 ovmf`; nothing for pvm), and skips only the
checks that tier does not need. It never changes kernels, sysctls or GRUB.

### 11.4 Where the registration code lives (M4 collision)

All logic goes into a new `lib/byoh_virt_registration.rb` (`add_options(parser)`,
`check!(facts, declared:, acks:)`, `recommended_commands`). `lib/byoh_registration_cli.rb` and
`lib/byoh_registration.rb` get one isolated commit with the minimum hunks: register the options, call
`check!`, pass `virt_tier:` to `assemble`. On the M4 merge that commit is re-applied on top of M4's
`#preflight`, and the facts come from M4's pinned session (no second SSH session). Until then it uses
the existing registration SSH path.

### 11.5 After registration

- `bin/byoh-virt show --host vh...` prints both the declared tier and the latest probe.
- A `ByohVirtTier` page opens when the probe disagrees with the declared tier, and resolves when they agree.
- `bin/byoh-virt refresh --host vh...` (or `--all`, PLANNED) re-probes.

## 12. Security policy, labels and billing per rung

| Rung | Customer label (UI and API family description) | Default tenancy | Location acks (`bin/byoh-location set --accept`) | Hard refusals |
|---|---|---|---|---|
| L1 | as today | as today | — | — |
| L3 `container` | "System container: shared host kernel, near-native speed. Not a VM." | One project per location | `container`; options `container:multitenant` (needs whole-core cpusets or SMT off), `container:unencrypted-disk`, `container:nested-userns`, `container:guest-firewall` | Host sysctl checks fail; `dir` driver without `prjquota` (any location) |
| L4 `pvm` | "PVM: software virtualization (experimental). Weaker isolation than standard VMs; Ubicloud-supplied guest kernel without AppArmor. Linux only." | One project per location | `pvm`; option `pvm:multitenant` only with SMT off or core scheduling and CPUs "Not affected" for l1tf and mds | Secure Boot on; a Meltdown-affected CPU (any tenancy, section 6.5) |
| L5 `emulated` | "Emulated: slow, compatibility only. Not a security boundary." | One project per **host** | `emulated` | The unit's hardening directives missing |

Applies to every lower rung:
- Its families and sizes are separate (`Option::TierVmSizes`) and never chosen implicitly.
- The VM overview shows the label as a badge with a tooltip.
- Rates: `bin/byoh-location rates <loc> --family F --from standard --multiplier X` (X is required).
  `byoh-location set` refuses to add a tier without rates, and `Validation.validate_billing_rate` in
  `Prog::Vm::Nexus.assemble` refuses a VM whose family has no rate in its location. Rates follow the
  `resource_name` rule in POOL_OPERATIONS.md. Container rates may be lower than `standard` (about 35 MB
  overhead per container); emulated rates use a required multiplier.
- Every mutation writes a `byoh_operator_action` row. Restart web, respirate and monitor after a rates
  change (CLAUDE.md §8a).

## 13. Rollout

| Phase | WP | What changes for whom | Gate to move on |
|---|---|---|---|
| 0 | done | BYOH hosts are probed at prep; a page explains a host without KVM | SHIPPED, full spec gate green |
| 1 | WP1 | This document | — |
| 2 | WP2 | The QEMU-KVM-without-hugepages unit returns to its 9e22d71ec form; goldens for every L1 output | Full gate; `git diff 9e22d71ec` over the golden directories shows only added files |
| 3 | WP3 | Detection v2: the probe identifies more causes, prints a recommended plan, `refresh --all` back-fills | L1-T1, L2-T1..T3 (section 14) on at least one cloud |
| 4 | WP4 | `virt_tier` and the location policy; every existing host becomes `kvm` by the column default; registration refuses with the plan | Full gate; goldens unchanged; an upgrade rehearsal on a copy of the live DB |
| 5 | WP5 | `container` tier, experimental | The lab harness (dir driver); L3-T1 on a real Ubuntu 24.04 host (crypt-loop, AppArmor, lxcfs, escape probes) before the family is granted outside the operator's own org |
| 6 | WP6 | `emulated` tier end to end, experimental | The L5 harness |
| 7 | WP7 | PVM: the go/no-go script always; the tier only on a reported GO | L4-T1 GO, then L4-T2 |
| 8 | WP8 | Docs final | Every claim labelled; full gate |

Upgrading the live control plane follows the existing window (CLAUDE.md §8): stop the services;
`pg_dump`; migrate (the `virt_probe` and `virt_tier` columns are additive, and their defaults keep
every host on L1); `install_rhizome` on every host, which ships `virt-probe`; `bin/byoh-virt refresh`.
Rollback: the WP4 migration's `down` refuses while it holds data; run `bin/byoh-host export-audit` first.

## 14. Real-infrastructure tests (runnable, all UNVERIFIED)

These need machines the lab cannot provide. Each is a script to paste; record the results here.
They need `$IP`, `$KEY` and a throwaway machine, and never touch a registered host unless the test says so.

### L1 and L2 (detection)

```bash
# L1-T1 bare metal with VT on: expect "tier: kvm (L1)", exit 0, no caveats except possibly pdpe1gb
bin/byoh-virt probe --main-ip $IP --ssh-key $KEY; echo exit=$?
# L1-T2 AWS m8i.large with nested virtualization enabled: expect kvm nested, exit 0, the three nested caveats.
#   Then run the benchmark set of section 5.1 inside a CH guest and on the host:
#   sysbench cpu and memory (1 and 2 threads), fio 1M write and 4k random read, 2000 fork+exec,
#   apt-get update, time to SSH. This is the nested-KVM number to compare with L3.
# L1-T3 GCP n2-standard-4 created with --enable-nested-virtualization: expect kvm nested, platform gcp
# L2-T1 AWS m6i.large (no nested on the family): expect none, platform aws, exit 3, "move to C8i/M8i/R8i ... or .metal"
ssh ubuntu@$IP 'sudo apt-get install -y ruby' && bin/byoh-virt probe --main-ip $IP --user ubuntu --ssh-key $KEY; echo exit=$?
#   (after WP3 the probe runs under sudo -n for a non-root --user)
# L2-T2 AWS m8i.large with nested virtualization left off: expect none, platform aws, "stop the instance and enable nested virtualization"
# L2-T3 Proxmox VM with cpu=kvm64 (the default "Common KVM processor", no vmx): v1 says none; after WP3 expect
#   kvm_blocked (L2), reason cpu_model, platform qemu_kvm, "qm set <vmid> --cpu host"; after the change and a stop/start: kvm nested
# L2-T4 bare metal with VT-x off in the firmware: expect kvm_blocked, "firmware has VT-x/AMD-V disabled"
# L2-T5 VMware VM without "expose hardware assisted virtualization": expect none, platform vmware
# L2-T6 Hetzner Cloud CX22 / DigitalOcean / Vultr: expect none with that platform's row, the ready fallbacks listed
# L2-T7 a registered BYOH host: bin/byoh-virt show --host vh...; a ByohVirtTier page exists only when not L1
# L2-T8 AMD bare metal with SVM disabled in the firmware: expect kvm_blocked with the firmware fix taken
#   from the kernel log ("SVM disabled (by BIOS)"), not a modprobe fix
# L2-T9 AWS Xen-based type (t2 or m4): expect platform aws_xen, "move to a Nitro type"
# L2-T10 Proxmox VM with cpu=kvm64,+vmx and nested=Y on the node (/dev/kvm works): v1 says kvm; after WP3 expect
#   kvm_blocked (L2), reason cpu_model, "set the CPU type to host"
```

### L3 system containers

```bash
# L3-T1 a real Ubuntu 24.04 host (any cloud VM without nested), after WP5:
bin/byoh-location set $LOC --virt-tiers kvm,container --accept container
bin/byoh-location rates $LOC --family container --from standard --multiplier 1
bin/register-byoh-host --location $LOC --main-ip $IP ... --virt-tier auto --accept-fallback   # expect: container chosen and printed
# Create a container-2 VM, then on the host:
sudo aa-status | grep -c lxc-container-default            # >= 1: AppArmor confines it
sudo cryptsetup status <vm>-root | grep -q LUKS2           # crypt-loop: encrypted at rest
pid=$(sudo lxc-info -n <vm> -P /var/lib/ubicloud/lxc -p -H)   # the container's init; lxc-start is the monitor in
                                                           #   the initial user namespace (uid_map "0 0 4294967295")
sudo awk '{print $2}' /proc/$pid/uid_map                   # = 1000000000 + slot*65536, the slot recorded in
                                                           #   /vm/<vm>/prep.json (key name fixed in WP5)
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns # unchanged by Ubicloud
sudo systemctl stop <vm>.service; ps -eo uid= | awk '$1 >= 1000000000' | wc -l   # 0: nothing of the container left
# Plant a symlink at the seed path and in the rootfs, restart, and check that no host file changed.
# In the guest (as ubi via sudo):
free -g                                                    # shows the size's memory (lxcfs), not the host's
sudo modprobe dummy; echo $?                               # != 0
sudo mount -t proc proc /mnt; echo $?                      # != 0
sudo sh -c 'echo 1 > /proc/sys/kernel/panic'; echo $?      # != 0
sudo unshare -U true; echo $?                              # != 0 (no nested userns without the ack)
python3 -c 'import ctypes,os,struct; l=ctypes.CDLL(None,use_errno=True); a=ctypes.create_string_buffer(struct.pack("8Q",0x10000000,0,0,0,17,0,0,0)); r=l.syscall(435,a,64); r==0 and os._exit(0); print(r,ctypes.get_errno())'
                                                           # "-1 38": clone3 (syscall 435, CLONE_NEWUSER) is ENOSYS
python3 -c 'import ctypes,os; l=ctypes.CDLL(None,use_errno=True); r=l.syscall(56,0x10000000|17,0,0,0,0); r==0 and os._exit(0); print(r,ctypes.get_errno())'
                                                           # "-1 ...": clone (syscall 56) with CLONE_NEWUSER is denied
sudo nft list ruleset; echo $?                             # != 0 (no guest firewall without the ack)
ls /dev/kvm /dev/fuse /dev/sda 2>&1 | grep -c 'No such'    # 3
# Two containers of two projects (multitenant ack) must not see each other's processes, files or traffic.
# Speed: the section 5.1 set, on crypt-loop and on dir, compared with the host.
```

### L4 PVM go/no-go

```bash
# L4-T1 PVM host side + a bare CH guest, on a throwaway Ubuntu 24.04 VM WITHOUT nested virtualization
#   (GCP e2-standard-4 or AWS m6i.large), Secure Boot OFF. Not a registered host. WP7 ships this as
#   scripts/byoh/test/real/pvm-go-no-go.sh, which refuses to run unless BYOH_REAL_HOST=1.
grep -cwE 'vmx|svm' /proc/cpuinfo                       # expect 0
mokutil --sb-state                                      # expect: SecureBoot disabled
R=https://github.com/cocoonstack/pvm/releases/download/v0.1.0
mkdir pvm && cd pvm
for f in SHA256SUMS linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb vmlinux-pvm-amd64 guest-pvm-amd64.config; do curl -fLO "$R/$f"; done
sha256sum -c --ignore-missing SHA256SUMS
grep -E '^CONFIG_(VFAT_FS|NLS_CODEPAGE_437|NLS_ISO8859_1|PVM_GUEST|X86_PIE)=y' guest-pvm-amd64.config   # expect all 5
# Pin the running stock kernel as GRUB's saved default BEFORE the .deb runs update-grub: that makes 6.12-pvm the
#   top entry, which GRUB_DEFAULT=0 (or saved without a saved_entry) would boot from then on.
grep -sE '^GRUB_SAVEDEFAULT=.?true' /etc/default/grub /etc/default/grub.d/*.cfg && echo 'STOP: GRUB_SAVEDEFAULT would make the PVM boot permanent'
STOCK="Advanced options for Ubuntu>Ubuntu, with Linux $(uname -r)"
echo 'GRUB_DEFAULT=saved' | sudo tee /etc/default/grub.d/98-pvm-test.cfg
sudo grub-set-default "$STOCK" && sudo update-grub
sudo grub-editenv list                                  # expect saved_entry=$STOCK; stop here if it is not
sudo apt-get install -y ./linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb
for l in /sys/class/net/*/device/driver /sys/block/*/device/driver /sys/block/*/device/device/driver; do
  [ -e "$l" ] && basename "$(readlink -f "$l")"; done | sort -u | while read -r d; do
  echo "$d: $(grep -ciE "_$(echo "$d" | tr - _)(_|=)" /boot/config-6.12.33-pvm)"; done   # approximate: every driver the instance uses (ena, nvme, virtio...) must show > 0; check the =y/=m lines by eye
# pti=off on the PVM entry only: GRUB_CMDLINE_LINUX_DEFAULT would also strip PTI from the stock recovery kernel.
sudo tee /etc/grub.d/42_pvm_test >/dev/null <<'EOF'
#!/bin/sh
set -e
. /usr/share/grub/grub-mkconfig_lib
k=/boot/vmlinuz-6.12.33-pvm
[ -f "$k" ] || exit 0
echo "menuentry 'Ubuntu, with Linux 6.12.33-pvm (pti=off)' --id ubicloud-pvm {"
prepare_grub_to_access_device "$(${grub_probe} --target=device "$k")" | sed 's/^/  /'
echo "  linux $(make_system_path_relative_to_its_root "$k") root=UUID=${GRUB_DEVICE_UUID} ro ${GRUB_CMDLINE_LINUX} ${GRUB_CMDLINE_LINUX_DEFAULT} pti=off"
echo "  initrd $(make_system_path_relative_to_its_root /boot/initrd.img-6.12.33-pvm)"
echo "}"
EOF
sudo chmod 755 /etc/grub.d/42_pvm_test && sudo update-grub
grep -c 'pti=off' /boot/grub/grub.cfg                   # expect 1: the ubicloud-pvm entry only
sudo grub-reboot ubicloud-pvm
sudo grub-editenv list                                  # expect next_entry=ubicloud-pvm AND saved_entry=$STOCK; do not reboot otherwise
sudo reboot
# after the reboot
uname -r; grep -o 'pti=off' /proc/cmdline               # 6.12.33-pvm, pti=off
sudo grub-editenv list                                  # next_entry gone, saved_entry still the stock kernel:
                                                        #   only now does a power cycle return to the stock kernel
sudo modprobe -r kvm_intel kvm_amd 2>/dev/null; sudo modprobe kvm-pvm && ls -l /dev/kvm
sudo ruby virt_probe.rb                                 # copy of rhizome/host/bin/virt-probe: expect tier: pvm
curl -fLo ch46 https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v46.0/cloud-hypervisor-static
echo "00b5cf2976847d2f21d2b7266038c8fc40bd14f2a542115055e9e214867edc9e  ch46" | sha256sum -c && chmod +x ch46
curl -fLo ch53 https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v53.0/cloud-hypervisor-static
sha256sum ch53 && chmod +x ch53                        # record the sum against the release page; no pin exists yet
curl -fLO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
sudo apt-get install -y qemu-utils dosfstools mtools
qemu-img convert -O raw noble-server-cloudimg-amd64.img disk.raw
printf '#cloud-config\npassword: ubuntu\nchpasswd: {expire: false}\nssh_pwauth: true\n' > user-data
printf 'instance-id: pvm-test\nlocal-hostname: pvm-test\n' > meta-data
mkdosfs -n CIDATA -C seed.img 128 && mcopy -oi seed.img user-data meta-data ::   # the same seed format rhizome builds
for ch in ./ch46 ./ch53; do
  time sudo $ch --kernel vmlinux-pvm-amd64 --cmdline "console=ttyS0 root=/dev/vda1 rw" \
    --disk path=disk.raw path=seed.img,readonly=on --serial tty --console off --cpus boot=2 --memory size=2048M
done
# GO: a login prompt with at least one CH version. In the guest: dmesg | grep -i pvm; the section 5.1
#   benchmark set; compare with the host itself. Report GO/NO-GO, the CH versions, and the numbers.
# Recovery check, last: sudo reboot. Expect the stock kernel (uname -r) and no pti=off in /proc/cmdline.
# L4-T2 (only after a GO and WP7) the same kind of VM registered with --virt-tier pvm --install-pvm-kernel
#   --accept-fallback into a location with --virt-tiers kvm,pvm --accept pvm: the host reaches accepting
#   after one reboot, a pvm-2 VM reaches running, SSH works, and destroy cleans up.
```

### L5 emulated

```bash
# L5-T1 the L-Q live gate of EMULATED_HOSTS.md on a host without /dev/kvm, after WP6.
```

## 15. Build plan (sequential on `no-kvm`)

Every WP ends with the full gate, in this order:
1. `coverage_pspec`: 100.0% line and branch; only `db_spec:189,193` and `resource_discount_spec:13` may fail
2. `frozen_pspec`
3. rubocop
4. `rake rhizome_spec`, when `rhizome/` changed
5. `bash -n` and shellcheck on changed scripts

No `:nocov:`. Commits follow COMMIT_MESSAGES.md. Nothing is pushed.

**Lab harness rules** (`scripts/byoh/test/nokvm/run.sh`). It refuses to start (fails closed) unless,
for every container it creates:
- `docker inspect` shows `Privileged=false`; Devices ⊆ {`/dev/net/tun`}; CapAdd ⊆ {NET_ADMIN, SYS_ADMIN,
  NET_RAW}; no port bindings; network `ubi-test-net`; a bind allowlist (no `docker.sock`, `/lib/modules`,
  `/dev`, `/sys`, the main checkout or `.env.rb`); `CpusetCpus=12-15`, `NanoCpus=4000000000`, `Memory=6g`;
  a `ubi-q-*` name.
- Mounts: only `rhizome/` and `scripts/byoh/test/nokvm/`, read-only, plus a container-local scratch volume.
- `HostConfig.SecurityOpt`: never `systempaths=unconfined`; seccomp is Docker's default, or a custom
  profile file from the repo named explicitly, never `seccomp=unconfined`; AppArmor is `docker-default`,
  never `apparmor=unconfined`. The harness grants `SYS_ADMIN` in the initial user namespace, so the
  AppArmor profile's mount denial is what stops container root from remounting `/sys` or `/proc/sys`
  read-write, or mounting a fresh sysfs, and writing host-global kernel state. The read-only checks below
  only observe; they enforce nothing.
- Modes that run LXC inside the container (`run.sh l3`) need `mount`, which `docker-default` denies. They
  refuse to start unless one of these holds:
  - A machine administrator has loaded the AppArmor profile `ubi-q-nokvm`, shipped in
    `scripts/byoh/test/nokvm/apparmor/`: `docker-default` plus the mounts LXC needs, with `remount` of
    `/sys` and `/proc/sys` denied, and `sysfs` and `proc` mounts allowed only under the container rootfs.
    Loading a profile is host kernel policy, so the harness never loads it. UNVERIFIED: that LXC runs
    under this profile.
  - `BYOH_NOKVM_THROWAWAY_VM=1` declares the machine a throwaway VM, where `apparmor=unconfined` is accepted.

  Without either, `l3` does not run on the shared lab machine. The 2026-10-15 spike (section 5.1) ran
  with AppArmor and seccomp unconfined on the shared machine; its safety rested on reading every script
  before running it, not on enforcement.
- Inside, **at start and again at teardown**: `/sys` and `/proc/sys` are mounted read-only (from
  `/proc/self/mountinfo`), and no other sysfs or proc mount exists; CapEff lacks `SYS_MODULE` and `SYS_RAWIO`.
- An nft drop toward the `ubi-test-net` subnet (except the gateway's egress) is installed **before** any
  guest starts; the run aborts if it is missing.
- `/proc/modules`, `vm.nr_hugepages` and selected `kernel.*` values (read through `/proc`) are
  snapshotted before and after; any change fails the run.
- A lint rejects `modprobe`, `insmod` and `sysctl -w` outside the TCG guest's initramfs.
- `df -h /` ≥ 7 GB before any pull; total usage < 2.5 GB; the cleanup trap removes only the `ubi-q-*`
  containers it created.
- The existing M3 harness in `scripts/byoh/test/` uses `--privileged` for systemd and is not reused.

**U1 proof, kept in every WP.** These golden specs must stay unchanged:
- `rhizome/host/spec/vm_setup_golden_spec.rb`, with the fixtures `ch_unit.service`, `ch_unit_nohugepages.service`, `ch_dnsmasq.service`, `qemu_kvm_hugepages*.service`
- `spec/model/metal/vm_golden_spec.rb` (`params_json_ch*.json`)
- `spec/prog/vm/metal/nexus_golden_spec.rb` (`create_unix_user.sh`)
- `spec/prog/vm/prep_host_golden_spec.rb` (the PrepHost command)
- `spec/lib/validation_golden_spec.rb`
- `spec/routes/api/project/location/vm_size_error_golden_spec.rb`

A WP may add fixtures but never edit these.

### WP1: this document (docs only)

The revised ladder: renumbered by speed, research and citations kept, measurements, cost table, PVM
lifecycle, gVisor rejected, registration matrix, security table, M4 hook, tests, build plan, critique
dispositions. Gate: `spec/lib/byoh_virt_platforms_spec.rb` (it reads this file).

### WP2: U1 repair, goldens first

1. Goldens from 9e22d71ec, no code change, generated from a `git worktree` of 9e22d71ec:
   `qemu_kvm_nohugepages.service`; `params_json_qemu_gpu.json` (the B200/B300 path in
   `model/metal/vm.rb`); an allocator candidate-list golden for an L1 fixture; an options JSON golden
   for a non-BYOH project; a `Prog::Vm::Nexus.assemble` attribute golden for every existing family.
   They fail on HEAD only for the nohugepages unit.
2. Gate the memfd backend in `vm_setup.rb` on `emulated?`; every golden green.
- Done: `git diff 9e22d71ec -- '*golden*'` shows only added files; the full gate.

### WP3: detection v2 and the harness skeleton

- `virt_probe.rb` v2 facts (section 2.2), `sudo -n` in `lib/byoh_virt_cli.rb`, the EACCES class,
  sanitisation; `ByohVirtLadder.classify(facts)`, `preflight_check(facts, declared_tier:)`, the
  recommended plan, the renumbered rungs, the kvm64 rule, the `pdpe1gb` rule, BIOS-log precedence, the
  DMI override; `ByohVirtPlatforms` `aws_xen`, the explicit AWS family table, `cost_hint`, the `ask` wording.
- `prog/learn_virt.rb` fail-open (it compares with `kvm` until WP4).
- `scripts/byoh/test/nokvm/run.sh` with the safety preamble above; `run.sh probe` runs the real probe in
  ubuntu:24.04 and alpine (expect `container`) and over the fixture trees.
- Tests: JSON fixtures per platform row and per case (AMD SVMDIS, hidden hypervisor bit, kvm64 with
  vmx, kvm64 without vmx (Proxmox's default "Common KVM processor"; both kvm64 cases expect
  `kvm_blocked` with reason `cpu_model`), missing `pdpe1gb`, EACCES, a missing capability, Xen AWS,
  m7i vs m8i); the recommended plan per probe tier, including `pvm` (recommends `pvm`); rhizome specs through
  `--root` trees; a rhizome/control-plane classify parity spec; a sanitisation spec; the LearnVirt error path.
- Done: the full gate; the harness probe green; `bin/byoh-virt explain` prints a fix for every fixture.

### WP4: the tier framework

- The migration (section 10.1) with the schema cache and annotations; `lib/byoh_virt_tiers.rb`;
  `Option::TierVmSizes`; `Validation.validate_vm_size(extra_families:)`; the policy gate; R2 in
  `update_vm`; the storage tier branch; HostNexus (`assemble(virt_tier:)`, the prep argument,
  `wait_prep` acceptance and `accepts_slices`, `verify_tier_capacity`); the PrepHost argument;
  `rhizome/host/lib/host_tier.rb` (`emulated_host.rb` renamed and keyed on the tier; `KvmCheck`
  untouched); LearnVirt tier comparison; `MoveVm`; `RolloutRhizome`; the `move-location` refusals;
  `lib/byoh_location_cli.rb` (`--virt-tiers`, `--accept <tier>[:option]`, the grant and visible
  refusals, rates); `lib/byoh_virt_registration.rb` plus the isolated registration wiring commit
  (section 11.4); `bootstrap-data-plane.sh --tier`.
- Tests: the migration up, down, CHECKs and trigger on `clover_q_test1`; a mixed-tier allocator
  fixture; `force_host_id` across tiers gives NoSpaceLeft; every validator caller refuses tier sizes;
  Kubernetes, runner and VM pool specs; a tenancy race spec (two creates, the second refused); the
  grant and visible refusals; every cell of the registration matrix, and for each probe tier that the
  printed `recommended` tier is accepted by `auto` and by an explicit declaration (a `pvm` probe
  recommends `pvm`); `accepts_slices` and capacity per
  tier; every WP2 golden unchanged.
- Done: the full gate; goldens unchanged; in a spec, `wait_prep` of a kvm BYOH host with a crashing
  probe still reaches `setup_hugepages`.

### WP5: L3 system containers

- 5a rhizome: `container_setup.rb` (lifecycle, the idmap slot allocator, the root-owned config dir, the
  seed bind mount, cgroup dirs, seccomp/AppArmor/caps config), `container_net.rb` (the veth hook reusing
  `setup_taps_6`), `container_disk.rb` (`dir` with the `prjquota` check; `crypt-loop` with a stdin key),
  `setup-vm`/`stop-vm` dispatch, `vm_stats.rb` cgroup stats, the NoCloud directory writer (CIDATA path
  byte-identical), `host_tier.rb` container steps (packages, AppArmor, `groupadd -f -r kvm`,
  `login.defs` SUB_* 0, sysctl checks).
- 5b control plane: the family and sizes, `params_json` keys for container hosts only, the serial log,
  the container boot image download (cloud-images root tarball plus `SHA256SUMS`), kernel package
  masking in image prep, labels, refusals.
- 5c harness `run.sh l3` (dir driver): the real `setup-vm prep` of a container VM; SSH as `ubi` within
  30 s; DHCP, DNS, `apt-get update`; isolation and symlink probes; the cgroup path and a clean stop; two
  containers isolated from each other and from `ubi-pg-test`; stop, start, restart, delete twice;
  metrics; no leftovers; usage under 1 GB.
- Done: the full gate and the harness; crypt-loop, AppArmor, lxcfs and the sysctl checks marked
  UNVERIFIED; the family experimental.

### WP6: L5 emulated hookup (slim)

- The family and sizes in `TierVmSizes`, the policy gate rows, the `verify_tier_capacity` budget, the
  30-minute deadline and 180 s soft stop, refusal of the CH and firmware downloads on emulated hosts,
  the hardening golden unit and the refuse-to-start check, `INSTALL_HINT`/`KVM_AVAILABLE_HINT` text,
  `bootstrap-data-plane.sh --tier emulated`.
- Harness `run.sh l5`: SSH within 420 s, `query-kvm` false, symlink and chown-race probes, delete twice.
- Done: the full gate and the harness; the family experimental.

### WP7: PVM, go/no-go first (blocked on L4-T1)

- Always (this branch): `scripts/byoh/test/real/pvm-go-no-go.sh`, the L4-T1 script (never run here; it
  refuses unless `BYOH_REAL_HOST=1`), plus docs. Detection of `pvm` and `pvm_blocked` is already SHIPPED.
- Only if the user reports an L4-T1 GO: `pvm_kernel.rb` (operator-supplied URLs and sha256 in the
  location policy), `download-pvm-kernel` and its prog, `install-pvm-host-kernel` (section 6.7 checks,
  the grub drop-in, `grub-reboot`, `apt-mark hold`, the udev rule), `Prog::InstallPvmHostKernel`, the
  `verify_virt_tier` label, the pvm step list, direct boot in `build_ch_service` (a new
  `ch_unit_pvm.service` fixture; `ch_unit.service` unchanged), the `PVM_ROOT` table, image and GPU
  refusals, lifecycle pages. Optional: `run.sh pvm-hostside` (about 140 MB, disk-checked).
- On NO-GO, or no report: stop after the script and the docs; L4 is "detected, not offered".

### WP8: docs and final gate

- This file: each PLANNED becomes SHIPPED or VERIFIED as it lands. EMULATED_HOSTS.md: a header pointer,
  and its `accel` plan marked superseded by section 10.
- PLATFORMS.md: the PF3 delegation note and PF-V rows. `platforms/README.md`, `aws.md`,
  `gcp-azure.md`, `other-clouds-vps.md`, `own-hardware.md`, `proxmox-and-hypervisors.md`: the fix per
  platform and a pointer to the cost table.
- TROUBLESHOOTING.md: each refusal of section 11.2, the tier-mismatch page, the kernel-reboot page,
  container cgroup2 under netns, lxcfs, idmap overlap, PVM one-shot boot recovery.
- COMPUTE.md (the capacity overload), ROADMAP.md (a row and the M4 dependency), CLAUDE.md (code map and
  symptom rows).
- Done: the full gate; every claim labelled; nothing pushed.

## 16. Sources

[gcp-nested]: https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview
[aws-nested]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html
[classmethod]: https://dev.classmethod.jp/en/articles/ec2-nested-virtualization-support-non-bare-metal/
[azure-nested]: https://azure.microsoft.com/en-us/blog/nested-virtualization-in-azure/
[oci-nested]: https://blogs.oracle.com/linux/post/kvm-nested-virtualization-in-oci
[hetzner-reddit]: https://redlib.hbubli.cc/r/incus/comments/1kbgo7q/vms_and_bare_metal
[wirelessmoves]: https://blog.wirelessmoves.com/2022/05/nested-virtualization.html
[do-nested]: https://www.digitalocean.com/community/questions/is-nested-kvm-enabled-on-digital-ocean-servers-can-i-run-kvm-in-a-droplet
[linode-nested]: https://www.linode.com/community/questions/19459/do-any-linode-regionsinstances-support-nested-vmvirtualization
[vultr-nanog]: https://mailman.nanog.org/pipermail/nanog/2021-January/211590.html
[scaleway-let]: https://lowendtalk.com/discussion/comment/3265827/
[pvm-paper]: https://dl.acm.org/doi/10.1145/3600006.3613158
[pvm-lpc]: https://lpc.events/event/18/contributions/1766/attachments/1498/3306/LPC-PVM.pdf
[phoronix-pvm]: https://www.phoronix.com/news/PVM-Hypervisor-Linux-RFC
[kata-pvm]: https://katacontainers.io/blog/kata-sandbox-demo-on-kubecon-jp-2026/
[virt-pvm]: https://github.com/virt-pvm/linux
[cocoon-pvm]: https://github.com/cocoonstack/pvm
[cube-pvm]: https://cubesandbox.com/guide/pvm-deploy
[slicer-pvm]: https://docs.slicervm.com/tasks/pvm/
[virt-pvm-issue1]: https://github.com/virt-pvm/linux/issues/1
[ellis-pvm]: https://blog.alexellis.io/how-to-run-firecracker-without-kvm-on-regular-cloud-vms/
[cve-idmap]: https://app.opencve.io/cve/CVE-2026-62313
[gvisor-platforms]: https://gvisor.dev/docs/architecture_guide/platforms
[gvisor-systrap]: https://gvisor.dev/blog/2023/04/28/systrap-release/
[ch-mshv]: https://git.phyllo.me/External/cloud-hypervisor/src/tag/v42.0/docs/mshv.md
[uml-smp]: https://lkml.iu.edu/2510.3/02642.html

The reference definitions above render as links in the text, and are the complete list of external
sources for this document. Three earlier definitions (`incus-cloud`, `incus-arch`, `lxcfs`) were never
cited in the text and are dropped.

## Appendix A. Critique dispositions

Revision 2 answers three critic passes over revision 1 (57 items). "Accepted" items are reflected in
the section named.

**Critic set 1 (26 items).** 1 accepted (11.2). 2 accepted (6.7 HostNexus walk). 3 accepted
(`grub-reboot`, the grub drop-in, `apt-mark hold`). 4 accepted (guest config checks; the CIDATA vfat
seed in L4-T1). 5 accepted (udev rule and its check). 6 accepted (`verify_tier_capacity`; no hugepages
on PVM). 7 accepted (storage tier branch and refusals). 8 accepted (`TierVmSizes` and one central
gate). 9 accepted (R1 dropped; an unknown family maps to `kvm`). 10 accepted (WP2 goldens from
9e22d71ec first, including the QEMU-GPU `params_json`). 11 accepted (WP2; the U1 note in section 1).
12 accepted (10.5). 13 accepted (10.4). 14 accepted. 15 accepted (`sudo -n`, the EACCES class).
16 accepted (`aws_xen`; DMI strings UNVERIFIED). 17 accepted (explicit AWS family list). 18 accepted
(BIOS-log precedence, DMI override, fixtures). 19 accepted. 20 accepted (the `KVM_CHECK_EXTENSION` list
comes from CH source in WP3). 21 accepted (PF3 delegates; the ladder adopts the kvm64 rule;
`declared_tier:`). 22 partially accepted: the facts/classify split, the hook API and additive hunks are
accepted; "don't touch the registration files at all before M4 merges" is rejected, because the user's
core ask is that registration identifies and falls back. Instead, one isolated minimal commit is
re-applied on merge (11.4). 23 accepted (merged with set 2 #2). 24 accepted (LXC run as root; the
userns restriction stays on; INFO only). 25 accepted, with `groupadd -f -r kvm` in tier prep, because
the lab image showed no `kvm` group and its presence on real hosts is UNVERIFIED. 26 accepted (slots
above `SUB_UID_MAX`, the overlap check, SUB_* 0).

**Critic set 2 (16 items).** 1 accepted (10.3). 2 accepted (placement lock plus grant/visible refusals;
the EMULATED_HOSTS.md wording resolved as one project per host for L5). 3 partially accepted: the
trigger on `virt_tier` (family is covered by the CHECK), the location ack CHECK, and acks re-checked at
create and prep are accepted; **"`tier_for_family` must raise on an unknown family" is rejected**,
because upstream has many kvm families (AWS, GCP, GPU) outside the tier table, so raising breaks U1;
the lower-tier family set is closed and the CHECK binds hosts to it, so `kvm` for an unknown family
cannot fail open (10.2). 4 accepted (5.3 root-trust paths). 5 accepted. 6 accepted (io_uring, userns,
NETLINK_NETFILTER, sysctl checks, patch-cadence page, the DoS note); `user.max_user_namespaces=0` inside
the userns is kept as an UNVERIFIED alternative. 7-15 accepted. 16 accepted (the harness rules in
section 15). Note on 16c: `rt_q.sh` mounts the worktree read-write for spec runs only; those containers
run no guest code, so that is unchanged; guest-running harness containers use the read-only mounts.

**Critic set 3 (15 items).** 1 accepted (rungs renumbered by speed). 2 accepted (PVM last, behind a
go/no-go). 3 accepted (CH v46 and v53; minimum CH version per tier). 4 accepted (6.8 lifecycle; the
cloud recommendation in section 1). 5 accepted. 6 accepted, with prices marked UNVERIFIED (no current
price data here; section 7). 7 accepted (`auto`, one `--accept-fallback`, merged location acks,
recommended commands). 8 accepted. 9 accepted (cloud-images root tarball). 10-11 accepted.
12 partially accepted: heavy L5 extras are deferred and `emulated` is marked experimental; **cutting
L5's control-plane hookup entirely is rejected**: the task requires every rung to have gating, opt-in,
labels and capacity, and with the generic tier framework L5's hookup is small; without it the existing
TCG rhizome code is unreachable. 13 accepted (WP2 is the first code WP; WP1 is docs-only). 14 accepted
(L1-T2 benchmarks). 15 accepted.
