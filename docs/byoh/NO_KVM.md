# The virtualization ladder: fast first, emulation last

Status: 2026-10-16, branch `no-kvm` (from `byoh-driver` 9e22d71ec plus the QEMU-TCG work), design
revision 2, build plan WP1-WP8 done (section 15). Nothing is pushed or merged. This document replaces
[EMULATED_HOSTS.md](EMULATED_HOSTS.md) as the entry point for hosts without KVM. That file stays as the
detailed reference for rung L5.

What is offered at the end of the plan, in one line per rung: L1 as today; L2 detected and refused
with the fix; L3 `container` and L5 `emulated` registrable, experimental, opt-in per location, project
and VM size; L4 `pvm` **detected, not offered** (its build waits for a GO from the L4-T1 script).
Nothing below L1 has run on a real host yet (section 14).

Labels used throughout:
- **SHIPPED**: code on this branch, covered by the spec gate.
- **VERIFIED**: executed here (the shared lab machine, AMD Ryzen 7 3800X, kernel 6.8; a shared
  machine, so treat every timing as ±20%). The "lab spike" is the 2026-10-15 no-KVM spike, run in a
  `ubi-q-*` container without `/dev/kvm` and without `--privileged`.
- **SOURCE**: read in a cited document, with a confidence (high, medium, low). "From memory" means
  recalled, not checked against a document here.
- **PLANNED**: specified, not written. After WP8 this covers only the PVM build (sections 6.7, 6.8,
  waiting for an L4-T1 GO) and the items listed as "not built" in sections 5.5, 10.5 and 10.6.
- **UNVERIFIED**: not executed anywhere. Every real-infrastructure test in section 14 is UNVERIFIED.

Rung numbers changed in revision 2: the rungs are now ordered by **measured speed**, so system
containers are L3 and PVM is L4. The tier ids (`kvm`, `container`, `pvm`, `emulated`) are the stable
names in code and data; rung numbers are display only. The SHIPPED code prints the revision-2 numbers
since WP3.

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
| **L1** | `kvm` | `/dev/kvm` works and has the capabilities Cloud Hypervisor needs | Cloud Hypervisor exactly as today (QEMU-KVM for B200/B300 GPUs, unchanged) | ~native on bare metal; nested: CPU-bound ≥90%, page-fault-heavy work much less (section 3; own measurement planned, L1-T2) | Hardware VM | Today's product, SHIPPED; detection v2 SHIPPED (WP3) |
| **L2** | — | The hardware can virtualize, but KVM is off or hidden (firmware, module, hypervisor CPU model, cloud option) | Nothing until it is fixed | — | — | Detection, per-platform fix, and refusal at registration with a recommended plan SHIPPED (WP4) |
| **L3** | `container` | Any x86_64 Linux ≥ 5.12 with cgroup v2 | Unprivileged LXC system container in rhizome's per-VM network namespace | **CPU 95-99%, memory bandwidth 91-98%, 3.6-5.4 s to SSH** (VERIFIED, `dir` disk driver only) | Shared kernel: weaker than a VM | SHIPPED (WP5), experimental: `dir` disk VERIFIED end to end in the lab (section 5.5); `crypt-loop`, AppArmor, lxcfs and project quotas UNVERIFIED |
| **L4** | `pvm` | No hardware virtualization; a PVM host kernel (`kvm_pvm`) | Cloud Hypervisor with direct kernel boot of a PVM guest kernel | SOURCE only: near single-level KVM (paper); 57% of native for a kernel build on m6a (third party). No own number | VM, with a software world switch | **Detected, not offered.** Detection SHIPPED; host side VERIFIED under emulation, guest boot UNVERIFIED; the go/no-go script SHIPPED (WP7), never run; the build waits for its GO |
| **L5** | `emulated` | Anything x86_64 | QEMU TCG (software CPU) | CPU 26-29%, memory bandwidth ~2.5%, 64-96 s to SSH (VERIFIED) | Not a security boundary | SHIPPED (WP6), experimental: control plane spec-gated; the end-to-end lab (`run.sh l5`) and real hosts UNVERIFIED (section 8.1; [EMULATED_HOSTS.md](EMULATED_HOSTS.md)) |

**L3 or L4?** L3 is the speed fallback. L4 is chosen only when the operator needs VM-level isolation
without hardware virtualization and accepts a custom host kernel. On AWS, GCP and Azure the
recommended answer is almost always a nested-capable instance type of the same size (section 7),
not L3 or L4.

Rules (U1 and "never silent"):
1. **An L1 host behaves byte for byte as today**, pinned by golden specs captured from 9e22d71ec
   (section 15, "U1 proof"). The one known exception is closed: commit f1e99cdaa had switched the
   QEMU-KVM path *without* hugepages from `-m` to a shared memfd backend; WP2 restricts the memfd
   backend to emulated VMs and pins the 9e22d71ec unit (`qemu_kvm_nohugepages.service`).
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
| Probe | `rhizome/host/lib/virt_probe.rb`, `rhizome/host/bin/virt-probe` | Read-only fact collector (report v2). It also classifies, for the on-host text output. It needs no gems, no rhizome and no Ruby newer than 3.0, so it can be piped to a fresh host. `--root DIR` reads a fixture tree instead of the machine (below). |
| Ladder | `lib/byoh_virt_ladder.rb` | Parses a v1 or v2 report, **classifies the facts again** (never trusting the host's tier), maps the tier to a rung, matches the platform, and builds the fix, the cost hint, the caveats, the fallbacks and the recommendation. `preflight_check` is M4's PF3 (section 2.3). |
| Platforms | `lib/byoh_virt_platforms.rb` | Data table: DMI and `systemd-detect-virt` patterns, nested support, fix text, `cost_hint`, and per-platform `rules` (the AWS instance families). |
| Record | `migrate/20261015_vm_host_virt_probe.rb` | `vm_host.virt_probe jsonb` holds the sanitised report plus the verdict, or `{"error": ...}` when the probe failed. |
| Automatic probe | `prog/learn_virt.rb`; `prog/vm/host_nexus.rb` `prep` | BYOH hosts (`VmHost#byoh?`) probe at prep. A host off L1 gets a page (`ByohVirtTier`) carrying the fix; the page resolves when a later probe finds L1. **Fail-open:** any error is recorded, paged once, and the strand pops (section 10.5). |
| Operator CLI | `bin/byoh-virt` (`lib/byoh_virt_cli.rb`) | `probe --main-ip` (before registration, over SSH, under `sudo -n` for a non-root `--user`), `explain` (saved JSON), `script`, `show --host`, `refresh --host` or `refresh --all` (every generic host past prep, to back-fill v2 records). `probe`, `explain` and `show` exit 0 on L1 and 3 otherwise. |
| Installer | `scripts/byoh/bootstrap-data-plane.sh` step 1b | Prints the probe report, then applies the same KVM checks as before. |
| Fixtures | `rhizome/host/spec/fixtures/virt_probe/*.json`, `rhizome/host/spec/virt_probe_fixtures.rb` | 25 machines (every tier, every platform case below). The rhizome spec, the ladder spec and the lab harness all read them. |
| Lab harness | `scripts/byoh/test/nokvm/run.sh`, `inside.sh` | `run.sh probe`: the real probe in Ubuntu 24.04 and Alpine containers, and every fixture tree, under the rules of section 15 (VERIFIED, below). |

What did **not** change: `KvmCheck`, PrepHost, the allocator, VM creation, and every L1 code path.
A host off L1 is still refused by PrepHost exactly as before. The ladder adds the reason and the fix.

`VirtProbe.classify` (report v2) decides, in this order. `ByohVirtLadder.classify` is the same function
run on the control plane over sanitised facts, so the two cannot disagree (a parity spec runs every
fixture through both):

1. `systemd-detect-virt --container` names a container, or (without systemd) `/.dockerenv`,
   `/run/.containerenv` or `container=` in PID 1's environment: **`container`**, which is refused.
2. Opening `/dev/kvm` failed with `EACCES` or `EPERM`: **`unknown_permission`** ("probe as root"). It
   is never taken for a KVM problem.
3. `/dev/kvm` answers `KVM_GET_API_VERSION` with 12, or exists and was not opened (facts from a shell
   preflight):
   - `kvm_pvm` is loaded and neither `kvm_intel` nor `kvm_amd` is: **`pvm`**
   - the CPU model is a hypervisor's generic one (`kvm64`, `qemu64`, "Common KVM processor", "QEMU
     Virtual CPU"): **`kvm_blocked`**, cause `cpu_model`
   - `KVM_CREATE_VM` failed: **`kvm_blocked`**, cause `create_vm`
   - x86_64 and a capability Cloud Hypervisor requires is missing: **`kvm_blocked`**, cause `missing_caps`
   - otherwise: **`kvm`**. It is `nested` when the CPU has the `hypervisor` flag, systemd names a VM
     technology, or the DMI names a hypervisor.
4. There is no working `/dev/kvm`:
   - the kernel log says the firmware disabled virtualization: **`kvm_blocked`**, cause `firmware`. This
     comes **before** the flag checks, which fixes AMD with SVM disabled: Linux keeps `svm` in
     `/proc/cpuinfo` there, so the flags alone would point at `modprobe`.
   - a generic CPU model: **`kvm_blocked`**, cause `cpu_model` (Proxmox's default has no `vmx`, and
     v1 called it `none`)
   - `/dev/kvm` exists but does not answer: **`kvm_blocked`**, cause `unresponsive`
   - the facts do not say whether `/dev/kvm` exists, or lack the CPU flags or the architecture (facts
     from a shell preflight that skipped them; the probe always gathers them): **`unknown`**, cause
     `not_gathered`. Nothing below is decided from missing data.
   - x86 with `vmx` or `svm`: **`kvm_blocked`**, cause `module` (not loaded) or `no_device` (loaded
     without `/dev/kvm`). When the loaded modules or the kernel log were not gathered, the reason says
     so ("the kernel log was not read, so the firmware may have disabled it"): on AMD with SVM
     disabled in the firmware, `svm` stays in `/proc/cpuinfo` and only the log tells.
   - bare metal with neither flag: **`kvm_blocked`**, cause `firmware`. Bare metal means systemd says
     `none`, the `hypervisor` flag is absent, **and** no DMI string names a hypervisor (QEMU, VMware,
     VirtualBox, Xen, Bochs, Parallels, bhyve, OpenStack, Hyper-V's "Virtual Machine", SeaBIOS, and
     similar, after systemd-detect-virt's own table), so a hypervisor that hides its CPUID bit is not
     sent to the firmware setup. Since about Linux 5.6 the kernel drops `vmx` from `/proc/cpuinfo` when
     the firmware locks VMX off (SOURCE, medium; the kernel's "VMX feature" reporting).
   - the running kernel's `modules.dep` lists `kvm-pvm.ko`: **`pvm_blocked`**
   - otherwise: **`none`**

A fact that is missing (`nil`, or a v1 report) is unknown: it never makes a host L2. Without
`dev_kvm`, `cpu_flags` or `arch` the tier is `unknown` (rung "unknown"), which `preflight_check`
reports as `info`, never `fail`. On an L1 verdict the ladder lists the unknown checks as a caveat, and
LearnVirt checks again at prep. The probe leaves `bios_log` out when it could not read the kernel log
(`journalctl -k` and `dmesg` both failed, for example `dmesg_restrict` without root), so the
`firmware` check is `unknown`, not `pass`.

The control plane adds two refusals of its own on top of the tier: **`pdpe1gb`** missing on x86_64
means `standard_vms?` is false (fix: "give this VM the host's CPU model, or an instance type whose CPU
shows pdpe1gb"), since `Prog::SetupHugepages` needs 1G pages; and the fix and wording come from the
platform table (section 4).

**Facts gathered (v2)**, all read-only:
- arch, kernel release, effective UID, CPU vendor and model, the flags `vmx svm hypervisor pdpe1gb`,
  EPT/NPT (`kvm_intel`'s `ept`, `kvm_amd`'s `npt`, or `vmx flags`)
- `/dev/kvm`: mode and group; the answer to `KVM_GET_API_VERSION`; whether `KVM_CREATE_VM` succeeded (the
  VM fd has no memory and no vCPU and is closed at once); the missing capabilities of Cloud Hypervisor
  v46's list; the errno name of the step that failed
- the loaded modules `kvm kvm_intel kvm_amd kvm_pvm`, the `nested` module parameter, `kvm-pvm.ko` availability
- BIOS evidence: the first kernel-log line (`journalctl -k -b`, else `dmesg`) saying VT-x/AMD-V is
  locked off: "VMX (outside|inside TXT) disabled by BIOS", "VMX not enabled (disabled by BIOS)", "SVM
  disabled (by BIOS)" or "kvm: disabled by bios". Other features print the same phrase ("SGX disabled
  by BIOS"), so the pattern is anchored to virtualization. The key is left out when the log could not
  be read.
- `systemd-detect-virt --vm/--container`, and the DMI fields `sys_vendor product_name product_version
  bios_vendor board_vendor chassis_vendor chassis_asset_tag`. Never `*_serial` or `product_uuid` (a
  spec pins this).
- Secure Boot (efivars), `lockdown`, `/sys/devices/system/cpu/vulnerabilities/{meltdown,l1tf,mds,retbleed,spec_rstack_overflow}`,
  SMT control, `/var/run/reboot-required`
- container readiness: cgroup v2, AppArmor enabled, `kernel.apparmor_restrict_unprivileged_userns`
  (INFO only; Ubicloud never asks to change it), `prjquota` on the filesystem holding `/var/storage`
  (where rhizome keeps VM disks and boot images; `/vm/<name>` holds only configuration), and
  `lxc-start` and `lxcfs` installed
- emulation readiness: `qemu-system-x86_64` and OVMF installed

**Cloud Hypervisor's required capabilities** (SOURCE, high: `check_required_kvm_extensions` in
`hypervisor/src/kvm/x86_64/mod.rs` at tag v46.0, read 2026-10-15): AdjustClock, ExtCpuid, GetTscKhz,
ImmediateExit, Ioeventfd, Irqchip, Irqfd, IrqRouting, MpState, SetIdentityMapAddr, SetTssAddr,
SplitIrqchip, TscDeadlineTimer, UserMemory, UserNmi, VcpuEvents, Xcrs, Xsave. The numbers come from
`linux/kvm.h`. VERIFIED on the lab machine (AMD Ryzen 7 3800X, kernel 6.8) with a Python script
on the host: API 12, `KVM_CREATE_VM` returns an fd, and all 18 capabilities answer nonzero. The Ruby
ioctl path itself ran only against fakes and non-KVM nodes (rhizome spec): UNVERIFIED on a real
`/dev/kvm`.

**Fallbacks** (`possible`, `ready` and `unchecked` in the report): `container` is possible with cgroup
v2 and Linux ≥ 5.12, `emulated` on any x86_64 host, and `pvm` only on a `pvm_blocked` host; a fallback
is ready when its packages are installed. A fallback whose kernel facts were not gathered (no
`cgroup2` or `kernel`, as in a v1 report or shell facts; no `arch` for `emulated`) is `unchecked`,
never dropped: it still counts for `recommended`, and `preflight_check` answers `info` for it. A `pvm`
host offers only `pvm`; a container, an `unknown` and an `unknown_permission` host offer none. A `kvm`
host offers none, except one without `pdpe1gb`: it cannot take today's VMs, so it lists `container`
and `emulated` (the plan's "allowed with ack" row) while its fix asks for the CPU model first.
**`recommended`** is `pvm` on a PVM host, otherwise the fastest
*possible* fallback (container before emulated; `pvm` is never recommended unless `kvm_pvm` is loaded),
installed or not. The text says what to install. This deviates from the plan's "fastest ready" so that
an installed QEMU never outranks system containers: in the lab, containers ran about 3.5 times
faster than the emulator for CPU work and about 40 times faster for memory bandwidth (VERIFIED, section 5.1).
`kvm_blocked` and `unknown_permission` recommend fixing KVM and name no fallback. A fallback whose
tier is not in `ByohVirtTiers::SHIPPED` cannot be registered, so the text says so; for a shipped one
it points to `--virt-tier auto --accept-fallback` (WP4).

**Sanitising:** the control plane runs every host-supplied value through `VirtProbe.sanitize` (control
characters removed, invalid UTF-8 replaced, strings capped at 128 characters, arrays and hashes at 64
entries, nesting at four levels) before it classifies, prints, pages or stores anything. The reasons
are rebuilt from the sanitised facts, so a host cannot inject a line such as "fix: ...". The same goes
for SSH error text in `bin/byoh-virt` and LearnVirt.

**Fixture trees.** `virt-probe --root DIR` reads files under `DIR` and takes what commands and
`/dev/kvm` said from `DIR/.virt-probe/` (`uname`, `detect-virt-vm`, `detect-virt-container`,
`kernel-log`, `kvm.json`). Nothing runs and no device is opened, so a fixture classifies the same
anywhere. Cases: bare metal with KVM; VT-x off (kernel log, and no flags); AMD SVM disabled by the BIOS
(`svm` still in cpuinfo); `kvm_intel` not loaded; a hidden hypervisor bit (QEMU DMI, no flag); Proxmox
`kvm64` without and with `vmx`; host CPU without `pdpe1gb`; `EACCES`; a missing capability; a refused
`KVM_CREATE_VM`; AWS m8i nested on and off, m7i, `.metal` without the module, Xen t2; GCP E2; Hetzner
Cloud; an old kernel with cgroup v1; a PVM host; a PVM kernel with the module unloaded; a docker container.
The DMI strings in the fixtures are from memory (UNVERIFIED), like the platform table's.

VERIFIED on the lab machine (`scripts/byoh/test/nokvm/run.sh probe`, 2026-10-15): in an `ubuntu:24.04`
container with the distribution's Ruby 3.2.3, and in `ruby:4.0.2-alpine3.23`, the probe reports
`tier: container` for the container itself, and every one of the 23 fixture trees gives its expected
tier, cause, `nested` and `ready` (48 checks). That run found a real case: Docker's `--tmpfs` defaults to
`noexec`, and the probe correctly treats commands there as not installed, because `access(X_OK)` fails.

UNVERIFIED: a real L1 bare-metal host, a nested VM, a PVM host, every cloud VM in section 14, and the
exact kernel-log wording on each CPU vendor and kernel.

Using it: before registering, on the control plane (the host needs `ruby`, which the bootstrap installs):

```
bin/byoh-virt probe --main-ip 203.0.113.10 --ssh-key ~/.ssh/byoh_data [--user ubuntu]
# exit 0: L1, register it. exit 3: not L1; the output carries the fix and the plan.
```

With `--user` other than root the probe runs under `sudo -n`, because on Ubuntu `/dev/kvm` is
`root:kvm 0660`. When sudo wants a password, `bin/byoh-virt` says so and stops; it never reports such a
host as `kvm_blocked`. A probe that still cannot open `/dev/kvm` reports `unknown_permission`.

On the host itself: `scripts/byoh/bootstrap-data-plane.sh` (step 1b), or `sudo ruby rhizome/host/bin/virt-probe`.
After registration: `bin/byoh-virt show --host vh...`. After fixing the host:
`bin/byoh-virt refresh --host vh...`, then let PrepHost retry (a failed prep strand retries with backoff).

### 2.2 Detection v2: differences from the plan

Detection v2 shipped in WP3 as planned (section 15), with these differences:
- **One classifier, not two.** The plan had a separate control-plane `classify` plus a parity spec.
  `ByohVirtLadder.classify` instead runs `VirtProbe.classify` (the control plane already loads the
  probe file to pipe it to hosts, like `lib/net_ssh.rb` loads rhizome code) on sanitised facts. So
  parity holds by construction, and the parity spec still runs every fixture through both.
- **`recommended` is the fastest possible fallback**, not the fastest ready one (section 2.1, Fallbacks).
- **Registration commands only at registration.** The `--virt-tier` and `--accept-fallback` flags and
  `bin/byoh-location set --virt-tiers` are SHIPPED (WP4). `bin/byoh-virt probe` names the fallback and
  what to install; `bin/register-byoh-host` prints the exact commands when it refuses (section 11.2).
- **`pdpe1gb` is a control-plane refusal**, not a probe tier: the probe reports `kvm`, and
  `Verdict#standard_vms?` is false with its own fix.
- The harness checks the **bounding** capability set (`CapBnd`) rather than `CapEff`. This is stricter:
  a capability outside the bounding set can never be gained.

Platform table changes (`lib/byoh_virt_platforms.rb`, SHIPPED):
- A row `aws_xen`, before `xen`: `sys_vendor` "Xen" and `product_version` matching `amazon` (DMI strings
  from memory, UNVERIFIED) → "Xen-based EC2 instance type ...: move to a Nitro type (C8i/M8i/R8i with
  nested virtualization, or .metal)".
- AWS `rules` on the instance type in `product_name` (on Nitro the DMI product name is the instance type;
  from memory, UNVERIFIED), as an **explicit family list**: `c8i m8i r8i` → "stop the instance, enable
  nested virtualization in its CPU options, and start it again"; `*.metal` → "should be L1: check that
  the KVM module loads"; anything else, 7th generation and `-flex` included → "move to C8i, M8i or R8i
  ... or to a .metal type". No generation regex. `-flex` is left out because no source here says it
  supports nested virtualization.
- `cost_hint` on every row and the AWS rules (section 7): row-specific prices on `aws`, `aws_xen`, `gcp`,
  `azure`, `hetzner_cloud` and `oci`, and shared hints for the rest (`SELF_HOSTED_COST` for Hyper-V,
  VMware and VirtualBox, `ASK_COST` for the "ask" rows, `NO_NESTED_COST` for providers without nested
  virtualization). `Verdict#text` prints it as `cost:` only when the host is not L1. Every hint but the
  self-hosted one says "check current pricing".
- Wording by the row's `nested` value for a `none` host: `yes`/`some` → "Fixable by changing the instance
  type or a VM option: ...", `ask` → "Ask your provider whether nested virtualization can be enabled. ...",
  `no` → the row's fix. Only a `kvm_blocked` verdict is labelled "probably fixable" (`tier: kvm_blocked
  (L2 probably fixable)`).

Rungs as printed: `kvm` L1, `kvm_blocked` L2, `container` (the data plane) refused, `unknown_permission`
and `unknown` unknown, `none` and `pvm_blocked` L3-L5, `pvm` L4.

### 2.3 M4's host preflight (PF3), as merged

M4 owns host preflight (`scripts/byoh/host/ubicloud-host`, `lib/byoh_host_preflight.rb`, PF3). Since
the merge of M4 (2026-10-16) PF3 is the ladder's verdict (spec-covered and run on the container
fixtures; not on real hardware, UNVERIFIED there):

- **Facts, in the preflight's own session.** `ubicloud-host preflight` prints the fact `virt`:
  - `{"source":"probe","report":...}` when the host has ruby: the control plane sends
    `virt_probe.rb` ahead of the script (`ByohHostPreflight.script`, a quoted heredoc in
    `UBICLOUD_VIRT_PROBE`), and the script pipes it to `ruby - --json`. Every fact is there, the
    `/dev/kvm` ioctls and cloud-hypervisor's capabilities included. Tried in a container with ruby
    (the probe reported, the output parsed); never on a real host.
  - `{"source":"shell","facts":...}` otherwise (a fresh Ubuntu has no ruby): `arch`, `kernel`,
    `cpu_model`, `cpu_flags` (`vmx svm hypervisor pdpe1gb`), `dev_kvm`, `modules`, `virt_vm`,
    `virt_container` (systemd-detect-virt), `dmi`, `pvm_module_available`, `cgroup2`, `apparmor`,
    `commands`, `ovmf`, and the kernel log lines naming the BIOS as `bios_lines`, from which the
    control plane takes `bios_log` with the probe's own rule (`VirtProbe.bios_line`); the key is left
    out when neither journald nor dmesg could be read. `rhizome/host/spec/ubicloud_host_parity_spec.rb`
    keeps the lists equal to the probe's. The ioctl results are missing, so those checks are
    `unknown` and LearnVirt checks them at prep.
- **The check.** `ByohHostPreflight#evaluate(virt_tier:)` sets PF3 to
  `ByohVirtLadder.preflight_check(facts, declared_tier:)`:
  - `kvm`: pass or fail on the ladder; the detail is the script's words plus
    `ladder: <tier> (<rung>) on <platform>: <reasons>` and the caveats; the fix is the ladder's (the
    platform's fix, then the fallbacks). Where the ladder only says `info` (facts not gathered), the
    script's own status stands, so a working KVM host without ruby still passes and non-BYOH and KVM
    hosts register as before.
  - `container`, `pvm`, `emulated` (declared, or picked by `auto` from the same facts): the tier's
    readiness decides PF3 (PF-V1), `PF3-tier` fails unless the tier is shipped and the location
    offers and acknowledged it (with the `rates`/`set` commands as the fix), and PF4, PF5 and PF7 are
    info. `ubicloud-host --virt-tier <tier>` gives the same info lines on the host itself, which
    `bootstrap-data-plane.sh --tier` uses for its standalone preflight.
  - `--no-virt-probe` leaves the facts unused: PF3 is the script's, and registration notes that the
    host was not probed.
- **The decision.** `register-byoh-host` and `byoh-host add` (`ubicloud-admin host add`) pass
  preflight's verdict to `ByohVirtRegistration#decide!` (section 11.4); `--virt-tier`,
  `--accept-fallback` and `--no-virt-probe` mean the same in both. `--skip-preflight` registers on the
  declared tier with a note. `host add` keeps the decision in its state file between the prepare and
  register phases, and puts the three options in the arguments digest, so the register phase cannot
  change them.
- The ladder applies M4's `kvm64`/`qemu64` refusal as `kvm_blocked`, cause `cpu_model`, so PF3 and the
  ladder never disagree. It also refuses a missing `pdpe1gb` for `kvm`, which PF4 reports too.
- Where `KvmCheck` (PrepHost) and the ladder still differ: `KvmCheck` checks only the character device
  and the CPU flag, so it passes a host that the ladder refuses for a generic CPU model, a missing
  capability, a refused `KVM_CREATE_VM` or a missing `pdpe1gb`. On a PVM host, `KvmCheck` refuses for
  lacking `vmx`/`svm` and the ladder says `pvm`, which cannot take VMs yet.
- The merge's conflicts and their resolutions are in the merge commit message.

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
`Prog::SetupHugepages` (SHIPPED: since WP3 a refusal with its own fix, section 2.1).

## 4. L2: switch KVM on. Platform table

`ByohVirtPlatforms` matches the first row whose patterns all match. Keys are the anchors the code
records in `vm_host.virt_probe["platform"]`. Offerings change; this table was checked 2026-10-15.

| Key | Platform (DMI signal) | Nested | How to get KVM | Source, confidence |
|---|---|---|---|---|
| `aws` | AWS EC2 (`sys_vendor` "Amazon EC2"; the instance type in `product_name` picks a rule) | some | `.metal`, or 8th-generation Intel (C8i/M8i/R8i) with CPU option nested virtualization enabled; the instance must be stopped to change it. Available since 2026-02-12. Rules: `c8i`/`m8i`/`r8i` → switch the option on; `.metal` → check the module; anything else → move. | [AWS docs][aws-nested], high; [Classmethod][classmethod], medium. The AWS locales disagree on whether 7th-generation types are included: check the current list. |
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
| `aws_xen` | Xen-based EC2 type such as t2/m4 (`sys_vendor` "Xen", `product_version` containing "amazon"; DMI strings from memory, UNVERIFIED) | no | Move to a Nitro type: C8i/M8i/R8i with nested virtualization, or `.metal` | AWS docs, high for Xen types lacking VT-x (from memory) |
| `xen` | Xen | ask | `nestedhvm=1`, which Xen marks experimental | Xen docs, medium |

Every row has a `cost_hint` (section 7): its own for `aws`, `aws_xen`, `gcp`, `azure`, `hetzner_cloud`
and `oci`, and a shared one for the others (free on a hypervisor you run, provider-specific, or "bare
metal costs far more").

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

### 5.3 Design (SHIPPED in WP5, with the differences of section 5.5)

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
  - AppArmor: the profile LXC generates per container (`lxc.apparmor.profile = generated`) from `lxc-container-default-cgns`, whose static form denies the `rslave` mount of `/` that systemd 255 needs (found on the real AWS run); no nesting; no `/dev/kvm`, `/dev/fuse` or `/dev/net/tun`
    inside; lxcfs; the `cap.drop` list above.
  - Host checks at prep: `dmesg_restrict=1`, `kptr_restrict≥1`, `unprivileged_bpf_disabled≥1`,
    `perf_event_paranoid≥2`. Rhizome checks them and never sets them; a failure is a prep error that
    carries the fix.
  - Patch cadence: LearnVirt (and `bin/byoh-virt refresh`) pages `ByohKernelReboot` when
    `reboot-required` has been present on an L3 or L4 host for more than 7 days. The host kernel
    version is shown on the VM page. (SHIPPED in the final pass; section 10.5.)
  - gVisor is not used (section 8).
- **cgroups.** `lxc.cgroup.dir.monitor` and `lxc.cgroup.dir.container` are under `<vm>.service`
  (`Delegate=yes`). Limits: `cpu.max`, `memory.max`, `memory.swap.max = 0`, `pids.max`, `io.max`. A
  multi-tenant location (ack `container:multitenant`) requires whole-core `cpuset.cpus` per container,
  or SMT off. The harness asserts the payload's cgroup path, and that `systemctl stop` leaves no process.
- **Disk.** Two drivers; the location chooses one:
  - `crypt-loop` (default): a sparse file → LUKS2 → ext4, mounted at the rootfs with an idmapped mount
    (kernel ≥ 5.12). The data key is unwrapped through the same key-encryption path ubiblk uses, and
    passed with `cryptsetup --key-file=-` (never in argv, the environment or a file), with
    `--pbkdf pbkdf2` (or `luksFormat --volume-key-file -` from stdin). The mapping is closed at delete
    (as shipped it stays open across a stop: section 5.5).
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
- **User group.** The `create_unix_user` heredoc is unchanged for KVM and container hosts. Container
  host prep runs `groupadd -f -r kvm`, so `usermod -a -G kvm` cannot fail whether or not the group exists.
  Emulated hosts get their own heredoc (section 8.1).
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

### 5.5 What WP5 shipped, and where it differs from section 5.3

SHIPPED, spec-gated (100% line and branch coverage for rhizome and the control plane):

| Piece | Where |
|---|---|
| Id slots: `base = 1_000_000_000 + slot × 65536`, slots 0..49,999, a file per VM under `/var/lib/ubicloud/idmap/` (root 0700) and an `flock`; freed only after the disk is gone | `rhizome/host/lib/container_idmap.rb` |
| LXC configuration, seccomp policy, network hook, NoCloud seed, unit and stop command, all in `/var/lib/ubicloud/lxc/<vm>/` (root, 0711; config and policy 0600) | `rhizome/host/lib/container_setup.rb`, goldens `rhizome/host/spec/fixtures/golden/container_*` |
| The disk: `crypt-loop` (LUKS2 on a sparse file, ext4 owned by the slot's root, a random 512-bit key wrapped with the volume's KEK exactly like ubiblk's, given to `cryptsetup` on stdin) and `dir` (a project quota of the volume's size and 65,536 inodes per GiB of it, so empty files cannot exhaust the shared file system's inode table; refuses a file system without `prjquota` or mounted `nodev`/`nosuid`). The image is extracted by the container's own root (`lxc-usernsexec`, `dev/*` excluded), which also masks `sys-kernel-config.mount`, `sys-kernel-debug.mount` and `systemd-remount-fs.service`, pins every kernel package to priority -1 and limits cloud-init to NoCloud | `rhizome/host/lib/container_disk.rb` |
| `VmSetup` for `hypervisor: "lxc"`: no tap (LXC makes a veth whose host end is the tap), `bind-dynamic` dnsmasq, network-config by interface name, seed instead of CIDATA, `growpart` and `resize_rootfs` off, the nftables bootcmd only with `container:guest-firewall`, one disk, one NIC, no swap, no PCI devices | `rhizome/host/lib/vm_setup.rb` (the CH and QEMU goldens are unchanged) |
| `setup-vm net-up` (LXC's `script.up`), `stop-vm` (`lxc-stop --nowait` in the VM's netns), `vm-stats` from the `lxc.payload` cgroup | `rhizome/host/bin/`, `rhizome/host/lib/vm_stats.rb` |
| Host prep `prep_host.rb <host> <env> container`: x86_64, cgroup v2, Linux ≥ 5.12, systemd ≥ 254, the packages, AppArmor with `lxc-container-default-cgns` (the base of the generated profile) loaded, the four kernel settings, no other subordinate id range over the slots; then root's `/etc/subuid` and `/etc/subgid` entry, `SUB_UID_COUNT`/`SUB_GID_COUNT` 0, `groupadd -f -r kvm`, `lxc-net` off | `rhizome/host/lib/host_tier.rb` |
| Control plane: `container` in `ByohVirtTiers::SHIPPED` (and the bootstrap's `SHIPPED_TIERS`); prep.json `hypervisor: "lxc"` and `container: {nested_userns, guest_firewall}` for container hosts only (golden `spec/fixtures/golden/params_json_container.json`); the disk encrypted unless the location acknowledged `container:unencrypted-disk`; one disk per container VM; serial log from the console log; no hypervisor learned; `ubuntu-noble-container` 20260926 from cloud-images.ubuntu.com with its SHA256 (never from Ubicloud's blob storage, which has none) kept as `.tar.xz`; a container host downloads the tier's images unless registration names some of them, and refuses others; the API's VM create takes a `container-N` size with `boot_image` `ubuntu-noble-container`, or with none (the tier's first image), and refuses that image with any other size | `lib/byoh_virt_tiers.rb`, `helpers/vm.rb`, `lib/validation.rb`, `model/metal/vm.rb`, `prog/vm/nexus.rb`, `prog/learn_hypervisor.rb`, `prog/download_boot_image.rb`, `model/boot_image.rb`, `prog/vm/host_nexus.rb` |

VERIFIED in the lab (`NOKVM_L3_UNCONFINED=1 scripts/byoh/test/nokvm/run.sh l3`, 72 checks, 2026-10-15;
that run had AppArmor and seccomp unconfined on the shared lab machine, which section 15 forbids, and
the harness now refuses it: see the lab artifacts below):
two `container` VMs through the real `setup-vm prep`, the network hook, `stop-vm`, `vm-stats`,
`recreate-unpersisted`, `restart` and `delete` (twice), on ubuntu:24.04 with LXC 5.0.3 and the
`ubuntu-noble-container` 20260926 image, `dir` driver on tmpfs:
- SSH as `ubi` 17.5 to 18.1 s after `setup-vm prep` began, about 13 s of it extracting the image; DHCP,
  DNS through the VM's dnsmasq, `apt-get update`, cloud-init done, no failed units.
- The guest's root is host uid 1,000,000,000 (slot 0) and 1,000,065,536 (slot 1); `systemd-detect-virt`
  says lxc; no `/dev/kvm` or `/dev/fuse`; `/proc/sys` and the seed read-only; `dmesg` refused; the
  cgroup limits (1 GiB, 2 CPUs) seen from inside.
- Seccomp, from a probe run as the guest's root: `clone3` ENOSYS, `unshare(CLONE_NEWUSER)` EPERM, `keyctl`
  ENOSYS, `bpf`, `io_uring_setup`, `userfaultfd` and `perf_event_open` EPERM, a netfilter netlink
  socket EAFNOSUPPORT.
- The guest's processes sit in `system.slice/<vm>.service/lxc.payload`; after a stop no process of the
  slot's ids and no process in the unit's cgroups remain.
- Symlinks planted by the guest's root (`/x`, `/var/log/x`, `/etc/hostname`, pointing at host files)
  changed no host file across a stop, `recreate-unpersisted` and a restart.
- One VM cannot reach the other's private address or see its processes, and neither reaches another
  host of the test network.

Differences from section 5.3:
- **newuidmap.** With the `uidmap` package installed, LXC (and `lxc-usernsexec`) write the maps through
  `newuidmap` even as root, so the slots need `/etc/subuid` and `/etc/subgid` entries. Prep adds one
  entry for root covering every slot (`root:1000000000:3276800000`) and refuses any other entry that
  overlaps (VERIFIED: without it the map is refused). `usermod --del-subuids` is not needed: with
  `SUB_UID_COUNT 0` new users get no range, and ranges below 600,100,000 cannot reach the slots.
- **The LXC directory is 0711, not 0700** (`/var/lib/ubicloud/lxc` and `/var/lib/ubicloud/lxc/<vm>`):
  LXC's child already runs as the container's root when it bind-mounts the seed, so it must traverse
  the directory. Others may traverse but not list it; the config, seccomp policy (0600) and network hook
  (0700) stay root-only. The seed directory is `root:<slot base gid>` 0750 and its files 0640, so
  only root and the container's own root (which LXC bind-mounts it as) can read the user-data; no
  other host user, another VM's dnsmasq user or slot included, can (final pass; spec-gated, the l3 lab
  was not re-run, UNVERIFIED that LXC 5.0.3 bind-mounts it as the slot's root as section 5.1 found).
- **The `crypt-loop` mapping stays open across a stop.** A stopped container is started again by
  `systemctl start` alone (the control plane's start and `setup-vm restart`), without the key
  encryption key, so the mapping and the ext4 mount stay until `setup-vm delete` or a host reboot,
  after which `recreate-unpersisted` opens them again. The key is therefore in the host kernel from prep
  to delete, not only while the container runs.
- **Unencrypted (`dir`) disks** also get an inode limit, 65,536 per GiB, so empty files cannot exhaust
  the shared file system's inode table. **The console log** rotates at 4 MB with one old copy
  (`lxc.console.size`, `lxc.console.rotate`), since it lives on the host's root file system outside the
  disk's quota. Both UNVERIFIED in the lab. `lxc.log` (`-l WARN`) has no bound; only LXC writes to it.
- **The slot** is recorded only on the host (`/var/lib/ubicloud/idmap/<vm>`), not in `prep.json` or the
  control plane. Accepted: every action that needs it runs on that host and reads it there, and a
  second record could disagree with the first.
- **`/vm/<vm>`** stays owned by the VM's user, as for cloud-hypervisor: on a container host nothing runs
  as that user but dnsmasq, and nothing root writes for the container lives there (the console log
  and the seed are in the root-only LXC directory). Accepted.
- **cgroups.** The unit has `Delegate=yes` and `DelegateSubgroup=supervisor` (systemd ≥ 254), and the
  LXC paths are absolute from the cgroup root (`system.slice/<vm>.service/lxc.monitor` and
  `lxc.payload`), so `<vm>.service` itself holds no process when LXC enables controllers below it. Limits
  are `cpu.max` (the VM's vCPUs), `memory.max`, `memory.swap.max = 0` and `pids.max` (2048 per vCPU);
  `io.max` is not set (UNVERIFIED which device numbers a loop file would need). Accepted while every
  lower tier is single-project: the tier sizes carry no IO limits (`NO_IO_LIMITS`, like the standard
  sizes), so there is no limit to apply, and only one project's VMs share a location. It **blocks**
  `container:multitenant`, together with the whole-core cpuset or SMT-off check.
- **No explicit `/dev/fuse` deny.** An extra `lxc.cgroup2.devices.deny` entry made LXC 5.0.3 refuse
  `/dev/null` too (VERIFIED). The guest cannot create device files, and LXC creates none but its
  standard ones, so `/dev/fuse` is absent anyway (VERIFIED).
- **Network-config** names the interfaces (`eth0`): netplan matches a MAC address as the permanent
  one, which a veth lacks, so the guest never configured its network (VERIFIED).
- **Root file system mounts** must allow device files and setuid programs (VERIFIED: `nodev` broke
  `/dev/null`, `nosuid` broke `sudo`). `crypt-loop` mounts without either; `dir` refuses such a file system.
- **The network hook** starts in `/home/rhizome`, where bundler finds rhizome's Gemfile; LXC starts
  hooks in `/`.
- **Rhizome stays Ruby 3.0 syntax** (hosts run the distribution's Ruby; 3.2 on 24.04): the lab caught a
  Ruby 3.4 `it` in the slot allocator.
- **Not built in WP5**: the multi-tenant host checks and `io.max` (so `container:multitenant` stays
  refused and every location is single-project; `ByohVirtTiers::MULTITENANT_CHECKED` is empty, and these
  two block offering multi-project container locations), lxcfs-specific setup (accepted: Ubuntu's
  `lxcfs` package hooks itself into every LXC container through `common.conf.d`), and per-location DoS
  limit advice beyond this section (accepted while single-project: the tenant can only hurt its own
  VMs and the host, which `pids.max`, `memory.max` and the core kept for the host bound).
  `ByohKernelReboot` was added in the final pass (section 10.5). `container:nested-userns` lifts the `clone`/`unshare` rules and
  `clone3`'s ENOSYS together (one switch, simpler than 5.3's split).

Lab artifacts, each said in the lab's output (`scripts/byoh/test/nokvm/l3.sh`, `fake-systemctl`,
`lab-setup-vm`): no systemd (a shell emulation of the two units; `ip netns exec` instead of
`NetworkNamespacePath=`, because docker masks parts of `/sys` and LXC's sysfs mount needs a fully
visible one); no project quota (tmpfs) and no AppArmor (a container cannot load profiles); no lxcfs
(`/dev/fuse` is a host device); no `crypt-loop` (loop and device-mapper devices); the lab container runs
without docker's `no-new-privileges`, which would pass to every guest and break `sudo`, and needs
`mount` because LXC mounts proc, sysfs and cgroup2. The 2026-10-15 run used `NOKVM_L3_UNCONFINED=1`
(AppArmor and seccomp unconfined) on the shared machine. Since then `run.sh l3` runs only on a throwaway
VM (`BYOH_NOKVM_THROWAWAY_VM=1`, unconfined) or under an admin-loaded `ubi-q-nokvm` profile
(`NOKVM_L3_PROFILE=1`), keeps `/proc/sys` read-only but for `/proc/sys/net` in l3's mount namespace,
drops guest traffic to the gateway and every private address, and also asserts vm B's isolation and
under 1 GiB of scratch after the deletes. None of that has run yet (UNVERIFIED): no throwaway VM or
profile is available here.

UNVERIFIED until L3-T1 (section 14) runs on a real Ubuntu 24.04 host: the unit under systemd
(`DelegateSubgroup=`, `NetworkNamespacePath=`, `ExecStop`), AppArmor (the generated profile),
lxcfs, `crypt-loop`, project quotas, the host prep steps, and the time to SSH on a disk instead of tmpfs.

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

**Status (WP7, 2026-10-15): L4 is detected, not offered.** WP7 shipped the go/no-go test as
`scripts/byoh/test/real/pvm-go-no-go.sh` (section 14). Nobody has run it yet, so nobody has reported
a GO, and nothing below this paragraph is built. What that means today:
- A host whose probe says `pvm` or `pvm_blocked` is recorded and explained (`bin/byoh-virt probe`
  says Ubicloud cannot run VMs there yet). `pvm` is not in `ByohVirtTiers::SHIPPED`, so
  `--virt-tier pvm`, `bin/byoh-location set --virt-tiers ...,pvm` and `bootstrap-data-plane.sh --tier pvm`
  are refused (the last one unless `BYOH_ALLOW_UNSHIPPED_TIER=1`, for lab work only).
  `spec/lib/byoh_virt_tiers_pvm_spec.rb` fails if `pvm` is added to that list.
- `--virt-tier auto` never picks `pvm` on a `pvm_blocked` host, and on a `pvm` host it refuses
  rather than registering a tier that cannot run VMs.
- To unblock the build: run the script on a throwaway VM and send back `report.txt` with GO or
  NO-GO. On GO, the build follows this section; on NO-GO, L4 stays as it is.

**Go/no-go.** Run L4-T1 (section 14) once on a throwaway non-nested GCP e2 or AWS m6i VM, with Cloud
Hypervisor v46 **and** v53. GO means a guest reaches a login prompt (the script reports "GO, boot only"
when cloud-init then did not run, and plain GO with measurements when it did). If neither reaches a login prompt, WP7 delivers detection and docs only:
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
- **HostNexus walk** (built on `pvm-build`, PVM plan WP7; specs only, UNVERIFIED on a real host). It
  differs from the first design above in two ways. GRUB's default is never the PVM kernel (plan D2):
  `saved_entry` stays the stock kernel for good, and `ubicloud-pvm-boot.service`, which runs only on
  the PVM kernel (`ConditionKernelCommandLine=pti=off`), loads `kvm_pvm`, checks `/dev/kvm` and the stock
  entry, and only then arms the next boot with `grub-reboot`. So "commit" is a database state, not a
  GRUB write, and a boot that fails or hangs returns to stock on the next power cycle, also on a
  committed host. And the install runs after `patch`, so it pins the stock kernel the host runs after
  the apt full-upgrade. The walk of a host registered with `--install-pvm-kernel`:
  `wait_prep → verify_virt_tier → setup_storage_backend → download_boot_images →
  wait_download_boot_images → patch → install_pvm_host_kernel → prep_reboot → reboot →
  verify_pvm_boot → verify_tier_capacity → start_slices → start_vms`.
  - `verify_virt_tier` takes the stock probe (`accepts_probe?` with the `byoh_pvm_host` state), then
    runs rhizome's read-only `install-pvm-host-kernel preflight`. A refusal pages `ByohPvmInstall`
    with each reason and checks again every 5 minutes; the page resolves once preflight passes.
    The control plane passes no `unchecked_drivers`, so a host whose disk or NIC driver the tool
    cannot find a module for is refused until a knob for them exists (open; AWS ENA and NVMe have
    modules, so m6i passes in the specs' terms, UNVERIFIED on the instance).
  - `patch` records the installed `linux-image-*` packages before and after the upgrade in the strand
    frame (`bin/byoh-virt show` prints them), then hops to the install while the state is
    `install_pending`.
  - `install_pvm_host_kernel` (deadline 45 minutes to `prep_reboot`) first compares the location's
    host-deb pin with `byoh_pvm_host.host_deb_sha256`, the build the operator acknowledged; a
    different pin is refused before anything runs on the host, with the fix
    `bin/byoh-virt pvm retry --host <vh> --accept-host-deb <sha256>`. The install itself runs
    daemonized (`d_run`, checked every 30 s), so no strand run comes near respirate's ~91 s limit.
    Success records `armed`, the PVM and stock kernels and the stock entry. A refusal (nothing changed)
    or a failure (rhizome already un-armed the host) records `failed`, pages `ByohPvmInstall` with the
    tool's result and the last log lines, and waits at `pvm_install_failed`.
  - `prep_reboot` arms one PVM boot before every reboot of an install host (`install-pvm-host-kernel
    arm`, which also checks that the stock entry still boots). A host that cannot be armed is not
    rebooted: it pages `ByohPvmBoot`, stops taking VMs and waits at `pvm_boot_failed`.
  - `verify_pvm_boot` runs after `reboot` and after an out-of-band reboot (`check_boot_id` from `wait`
    and `unavailable`). It records a fresh probe and requires all of: the probe says `pvm` with none of
    PVM's hard refusals, KVM API 12, the running kernel is the installed PVM kernel, the boot unit is
    active and succeeded (it waits up to 5 minutes for a unit that has not run yet, since SSH comes up
    before `multi-user.target`), and `/dev/kvm` is a 0660 character device of group `kvm`. Then the
    state is `committed` and the VMs start. On any refusal it runs `disarm` first, pages `ByohPvmBoot`
    ("booted its stock kernel ..." when the host came back on stock, with the serial-console and
    power-cycle advice), drains an accepting host, never starts VMs, and waits at `pvm_boot_failed`.
    A host whose PVM kernel was installed before registration (`committed`, no install) gets the probe
    checks only and is never armed or disarmed.
  - Operator actions, each an operator-action row and a semaphore (`pvm_retry`, `pvm_uninstall`) that
    HostNexus acts on only on pvm hosts: `bin/byoh-virt pvm retry --host <vh>` installs again after a
    failed install (uninstalling first what a failed one left), or arms one more PVM boot and reboots
    after a failed boot. It refuses elsewhere. `bin/byoh-virt pvm uninstall --host <vh>` refuses while
    the host has VMs; HostNexus disarms and reboots a host on its PVM kernel to stock first, runs the
    daemonized `uninstall`, records `uninstalled`, pages `ByohPvmUninstalled` ("destroy and register it
    again as kvm, container or emulated") and stays at `pvm_uninstalled`. A stock kernel with `pti=off`
    on its own command line is not rebooted again (no reboot clears it, and rhizome's uninstall refuses
    it): HostNexus disarms, pages `ByohPvmInstall` with the fix (remove `pti=off` from
    `GRUB_CMDLINE_LINUX*`, `update-grub`, reboot, uninstall again) and waits at `pvm_install_failed`.
  - LearnVirt passes the install state, so a host on its stock kernel before the PVM boot gets no
    false `ByohVirtTier` page. On pvm the `ByohKernelReboot` page is replaced by `ByohPvmHostKernel`
    (warning): a committed host runs another kernel than its PVM kernel, or its PVM kernel is not the
    location's current host-deb pin. Moving a host to a new pin is plan WP9 (not built). Container
    keeps `ByohKernelReboot` unchanged.
  - `wait` pages `ByohPvmGuestKernelStale` (warning) with the VMs whose guest kernel is not the host's
    current one; the fix is to stop and start each (section 6.8).
  - `bin/byoh-host watch` knows the new labels: phase "pvm install" (45 minutes) for
    `install_pvm_host_kernel`, `pvm_install_failed` and `pvm_retry`; `verify_pvm_boot` and
    `pvm_boot_failed` in "reboot". `pvm_uninstall` ends a bring-up. A spec fails when a HostNexus label
    is in neither the phases nor the list of labels outside a bring-up.
  - U1: a golden walk (`spec/prog/vm/host_nexus_walk_golden_spec.rb`) runs kvm, container and emulated
    hosts from `patch` to `start_vms` and through an out-of-band reboot with every host command in
    order; it passes unchanged on the commit before WP7. The prep, the per-host ack and the `lockdown`
    record are WP4 and WP6.
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

Approximate and UNVERIFIED: check current pricing. Only the platform rows' `cost_hint` talks about
price (SHIPPED, WP3); `bin/byoh-virt` prints it as a `cost:` line for a host that is not L1.

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

### 8.1 What WP6 shipped

SHIPPED (spec-gated; nothing of it run on a real host, UNVERIFIED there):
- **Offered.** `emulated` joins `ByohVirtTiers::SHIPPED` (and `SHIPPED_TIERS` of
  `bootstrap-data-plane.sh`), so `bin/byoh-location set --virt-tiers kvm,emulated --accept emulated`,
  `bin/register-byoh-host --virt-tier emulated --accept-fallback` (or `auto` when no faster fallback is
  ready) and the VM API with an `emulated-*` size work, behind every gate of section 10.3.
- **Sizes.** `emulated-2` and `emulated-4` in `Option::TierVmSizes`, at **1 GiB per vCPU** (the other
  tiers keep 4 GiB): with the tier's 512 MiB per-VM overhead and 2 GiB host reserve an 8 GiB machine has
  a 4 GiB budget, which an `emulated-2` fits and a 4 GiB-per-vCPU size would not.
- **prep.json.** On an emulated host `Vm#params_json` sets `hypervisor: "qemu"`, `accel: "tcg"` and
  `hugepages: false` (golden `params_json_emulated.json`); every other host's JSON is unchanged.
- **Unix user.** `Prog::Vm::Metal::Nexus::EMULATED_UNIX_USER` (golden `create_unix_user_emulated.sh`):
  no `kvm` group, the home created by root as `root:<vm> 0750` (rhizome's `check_emulated_home` refuses
  anything else), `userdel` without `-r` and the old home removed by root with `rm -rf
  --one-file-system`, since `userdel -r` refuses a home its user does not own. `prep.json` is written
  by root (`sudo tee`) into that home, also when `Prog::Vm::UpdateIpv6` rewrites it (in place, without
  the `rm` that KVM hosts keep). The KVM heredoc and `sudo -u <vm> tee` are unchanged (goldens).
- **Timings** (`ByohVirtTiers::SLOW_TIMINGS`, only on emulated hosts): 30 minutes from allocation to
  `wait` before the deadline pages (KVM: 10), the BYOH netns SSH probe gives up after 28 minutes (KVM:
  8), and the soft stop (QMP `system_powerdown`) gets 180 s before the hard stop (KVM: 60). The KVM
  values stay pinned by `nexus_golden_spec.rb`.
- **Downloads.** `Prog::DownloadCloudHypervisor`, `Prog::DownloadFirmware` and the `VmHost` helpers
  that start them refuse hosts whose tier runs no cloud-hypervisor (`emulated` and `container`;
  `ByohVirtTiers.runs_cloud_hypervisor?`). A tier host downloads only the first of its tier's images
  (`ubuntu-noble`) unless registration names others (`--default-boot-image ubuntu-jammy`).
- **Refuse to start.** Before every `systemctl start` or `restart` of an emulated VM, rhizome checks
  that the home is root-owned and that the unit file is a regular file only root can write, runs
  `systemctl daemon-reload` (so systemd loads exactly the files it checks), and reads `systemctl cat`
  (the unit with every drop-in) the way systemd's parser does: comments skipped, continuation lines
  joined, whitespace around key and value stripped (`QemuTcg.check_unit!`). Only the `[Unit]` and
  `[Service]` keys the generated unit has may appear. Every line of `QemuTcg.hardening`
  (`ProtectSystem=strict`, `ReadWritePaths=/vm/<vm>`, `CapabilityBoundingSet=`, the syscall filter and
  the rest), `User=`/`Group=` of the VM, its `NetworkNamespacePath=` and the one `ExecStartPre=` (the
  QMP socket's `rm`) appear exactly once with their values; `Slice=`, `MemoryMax=<n>M` and a single
  `ExecStart=qemu-system-x86_64 ...` exactly once, with one `-accel tcg,...`, no `accel=` and one
  `-sandbox` with QEMU's filter; no other key repeats. A drop-in can therefore not reset `ExecStart=`,
  add an `ExecStartPre=+...` that runs outside the confinement, add `BindPaths=` or
  `AmbientCapabilities=`, or lift `MemoryMax=`. The checked paths are prep, recreate-unpersisted,
  `setup-vm restart`, and `setup-vm start`, which `Prog::Vm::Metal::Nexus#start_after_stop` runs on
  emulated hosts after a customer stop (KVM hosts keep `systemctl start`, pinned by
  `nexus_golden_spec.rb`). The golden units in `rhizome/host/spec/fixtures/qemu_tcg/` pin the text,
  and specs remove each line in turn and add each kind of drop-in.
- **Bootstrap.** `bootstrap-data-plane.sh --tier emulated` prints what the tier costs (speed, no
  security boundary, burstable credits), notes swap and a present `/dev/kvm`, installs `qemu-system-x86
  ovmf`, and checks that `qemu-system-x86_64 -accel help` lists `tcg` and that OVMF exists.
- **Lab.** `scripts/byoh/test/nokvm/run.sh l5` (`l5.sh`): one VM through the real `setup-vm`, ubiblk,
  `stop-vm` and `vm-stats`, with SSH within 420 s, QMP `query-kvm` false, no `/dev/kvm` among QEMU's
  descriptors, guest `systemd-detect-virt` = `qemu` without `vmx`/`svm`, the VM user unable to replace
  anything in its home, a swapped QMP socket that only makes `stop-vm` fall back, the hardening refusal
  on a weakened unit and on a `User = root` drop-in, QMP power-down, recreate-unpersisted, restart,
  `setup-vm start` after a stop, and delete twice. It needs mounts
  (`ip netns add`), so it runs only where `l3` may (a throwaway VM or the admin-loaded profile, section
  15) and **has not been run** (UNVERIFIED). `fake-systemctl` now runs units with `User=`, without a
  network namespace and with continuation lines, and answers `systemctl cat` with the `/etc/systemd/system/<unit>.d/*.conf` drop-ins; checked in a plain
  container, the l3 lab was not re-run.

Not shipped (deferred, as planned): the exit-reason diagnosis of EMULATED_HOSTS.md section 6.5, the
admin "Create VM" size list for emulated hosts, per-host instead of per-location tenancy (per location
is final, section 10.6), and RSS-based tuning of the 512 MiB overhead. The VM page and the API now
say what a lower-tier VM is (section 12).

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
| Declared tier | `vm_host.virt_tier text NOT NULL DEFAULT 'kvm'`, CHECK `IN ('kvm','pvm','container','emulated')` | `HostNexus.assemble(virt_tier:)` at registration only | Which backend the host runs. A `BEFORE UPDATE OF virt_tier` trigger raises when it changes: changing it means re-registering | SHIPPED (WP4) |
| Tier/family coupling | CHECK `(virt_tier = 'kvm') = (family NOT IN ('pvm','container','emulated'))` on `vm_host` | the migration | A KVM host never carries a lower-tier family, and vice versa; with the trigger, family changes across the boundary are blocked too | SHIPPED (WP4) |
| Location policy | `location.byoh_virt jsonb`: `{"tiers": ["kvm", ...], "acks": {"<tier>": [option, ...]}}` (a container's disk driver follows the `container:unencrypted-disk` ack, section 5.5), NULL meaning `{"tiers": ["kvm"]}`. CHECK: every non-kvm tier in `tiers` has its base ack | `bin/byoh-location create/set` (each change writes a `byoh_operator_action` row) | Which lower tiers may be offered in this location | SHIPPED (WP4) |
| Tier table | `lib/byoh_virt_tiers.rb` (data, like `ByohVirtPlatforms`) | code | Per lower-tier family: tier, accepted probe tiers, hypervisor, PrepHost argument, label, required acks, experimental, uses hugepages, storage | SHIPPED (WP4) |

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
| `pvm` | `pvm`; or `none`/`kvm_blocked` of a stock kernel with `--install-pvm-kernel` (re-checked after the reboot) | `pvm` | CH with direct kernel boot | `pvm` | no | yes |
| `emulated` | `none`, `kvm_blocked`, `pvm_blocked`; `kvm` with a failing check | `emulated` | QEMU TCG | `emulated` (the third argument of `rhizome/host/bin/prep_host.rb`, renamed from `tcg` in WP4) | no | yes |

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
- Callers that create service VMs get kvm only from the default `allowed_tiers: ["kvm"]`; as shipped
  they pass nothing (section 10.6).
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
  `--rollback-to` refuses non-kvm hosts. `MoveVm` refuses moves across tiers; GPUs are refused for
  every non-kvm family. `RolloutRhizome` is unchanged: it only selects hosts in the upstream
  locations, so it never meets a lower-tier host (section 10.6).
- Internal services stay on L1: they create VMs with kvm families and pass no `allowed_tiers`, so the
  kvm-only default applies. There is no per-service spec of that; the specs pin the shared paths
  instead: `validation_golden_spec.rb` (every tier size refused by `validate_vm_size`,
  `validate_vm_storage_size` and `Prog::Vm::Nexus.assemble` without `allowed_tiers`, a VM pool's
  size error, and no GitHub runner label on a tier family) and `vm_size_error_golden_spec.rb` (the
  Kubernetes and VM APIs refuse every tier size).

### 10.5 LearnVirt: fail-open (SHIPPED, WP3) and tier-aware (SHIPPED, WP4)

- SHIPPED (WP4): it compares the probe with `virt_tier` (`ByohVirtTiers.accepts_probe?`: a kvm host
  must take today's VMs, a lower-tier host must list its tier as `ready`), pages `ByohVirtTier` only on
  disagreement, and resolves the page on agreement. Agreement is a safety check, not an authorisation.
- SHIPPED: any exception (a parse error, an SSH failure, a probe crash) records `{"error": ...}`
  (sanitised), pages once under the same `ByohVirtTier` tag, and pops with "virt probe failed". It never
  retries forever and never blocks `wait_prep`; a later probe that finds L1 resolves the page.
  `bin/byoh-virt show` prints "the last probe failed: ..." and exits 3.
- SHIPPED in the final pass (spec-gated): on `container` and `pvm` hosts (`Prog::LearnVirt::KERNEL_TIERS`)
  LearnVirt keeps `virt_probe["reboot_required_since"]`, the first probe that saw
  `/var/run/reboot-required`, and pages `ByohKernelReboot` (with the kernel release and the fix: drain,
  reboot, `bin/byoh-virt refresh`) once that is 7 days old; a probe without the flag clears it and
  resolves the page. So that this happens without an operator, HostNexus `wait` starts LearnVirt on a
  lower-tier host whose `virt_probe["probed_at"]` is older than a day; KVM hosts are never re-probed
  and their record has neither field. Page text is sanitised.

### 10.6 What WP4 shipped, and where it differs from this plan

SHIPPED (spec-gated, never run on a real host): the migration, `ByohVirtTiers`, `Option::TierVmSizes`,
the policy gate, R2, the storage tier branch, the HostNexus labels `verify_virt_tier` and
`verify_tier_capacity`, the PrepHost argument, `HostTier` (rhizome), LearnVirt's tier comparison,
the `MoveVm` and `move-location` refusals, the location CLI (`--virt-tiers`, `--accept`, `--unaccept`,
`rates --family`), `ByohVirtRegistration` and its wiring, `bootstrap-data-plane.sh --tier`.

**As WP4 shipped, no lower tier could be used.** `ByohVirtTiers::SHIPPED` was empty: `bin/byoh-location
set` refuses to offer a tier, and registration refuses one, until the WP that ships its rhizome support
adds it. Container joined it in WP5 and emulated in WP6; pvm joins only in WP7 on a GO. Every
lower-tier path is also exercised in specs with the constant stubbed.

Differences from sections 10.3, 10.4 and 11.2, each stricter or equal:
- `Prog::Vm::Nexus.assemble(allowed_tiers:)` **defaults to `["kvm"]`**. Service callers (Kubernetes,
  Postgres, runners, VM pools, inference, MoveVm) pass nothing and so never get a lower tier; only
  the VM create API passes the tier of a size the customer picked. The web form offers none; the `ubi`
  CLI accepts the tier sizes (`ubi vm <loc>/<name> create -s container-2 ...`) without listing them in
  its help, and the server enforces the policy.
- **Tenancy is per location for every lower tier**, emulated included (the plan had per host for L5):
  the target host is unknown when `assemble` runs, and per location is the stricter rule. This is
  final, not a stopgap: EMULATED_HOSTS.md's "one project per host" is satisfied by it.
- **No lower tier can be shared between projects yet.** `<tier>:multitenant` would lift the
  per-location rule, but sharing needs per-host conditions (section 6.5 and section 12: SMT off or
  core scheduling and l1tf/mds "Not affected" for pvm; whole-core cpusets or SMT off for container)
  that nothing checks yet. `ByohVirtTiers::MULTITENANT_CHECKED` is empty, so `bin/byoh-location set
  --accept <tier>:multitenant` is refused and a stored ack has no effect; the WP that ships a tier
  adds that tier's host check (at registration, `verify_virt_tier` and LearnVirt) and lists it there.
  `emulated` has no `multitenant` option at all: it is not a security boundary.
- **PVM's hard refusals are enforced already** (section 6.5): `ByohVirtLadder.pvm_refusal` fails a
  `pvm` registration (`preflight_check`, `auto` included) and a `pvm` host's probe
  (`ByohVirtTiers.accepts_probe?`, so `verify_virt_tier` holds it and LearnVirt pages) when Secure
  Boot is on, or when the CPU's `vulnerabilities/meltdown` is not "Not affected". It fails closed: a
  Meltdown status that was not gathered (a version 1 probe) is refused too.
- `pvm` declared on a `pvm_blocked` probe is refused with the `modprobe kvm_pvm` fix (the plan said
  "ack with advice"): prep would refuse that host anyway.
- `auto` picks the fastest *possible* fallback; when that tier is not offered or not installed it
  refuses with the commands that fix it, rather than falling further down the ladder.
- The gate also requires a `VmStorage` rate for the family: billing charges VM storage by family
  (`Prog::Vm::Metal::Nexus`), and a missing rate would fail after the VM exists.
- `RolloutRhizome` is unchanged: it only selects hosts in the four upstream locations, never a BYOH
  location, so it never meets a lower-tier host.
- `bin/byoh-virt show` prints the registered tier and judges a lower-tier host by its tier's
  prerequisites.

## 11. Operator experience

### 11.1 Before registration: `bin/byoh-virt probe` (SHIPPED)

It prints the verdict and exits 0 on L1 and 3 otherwise. The format is `ByohVirtLadder::Verdict#text`.
These are real outputs for fixture machines (section 2.1; VERIFIED as program output, while the
machines' DMI strings and kernel-log lines are from memory, UNVERIFIED). Long lines are cut here with
"...".

```
# AWS m8i.2xlarge with nested virtualization on (fixture aws_m8i_nested)
tier: kvm (L1) nested
platform: AWS EC2
why: /dev/kvm answers KVM_GET_API_VERSION 12
caveat: nested virtualization: CPU-bound work typically loses 10% or more, ...
caveat: the provider may stop or restart this VM for maintenance, ...
caveat: the clocksource is often not tsc and disks are virtual, ...
recommended: register it as it is (L1)

# Proxmox VM with the default CPU type (fixture proxmox_kvm64)
tier: kvm_blocked (L2 probably fixable)
platform: QEMU/KVM (Proxmox VE, libvirt, KVM-based VPS)
why: the CPU model is the hypervisor's generic "Common KVM processor", not the host's
fix: Give this VM the host's CPU model instead of the hypervisor's generic one, with VT-x/AMD-V
     exposed. Proxmox VE: qm set <vmid> --cpu host, with nested enabled on the node ...
fallbacks ready: none
fallbacks possible after installing their packages: container, emulated
recommended: apply the fix above and probe again

# AMD bare metal with SVM disabled in the firmware (fixture amd_svm_disabled_by_bios)
tier: kvm_blocked (L2 probably fixable)
platform: unknown platform
why: the kernel log says the firmware disabled virtualization: kvm_amd: SVM disabled (by BIOS) ...
fix: Enable Intel VT-x or AMD-V (SVM) in the BIOS/UEFI setup, then power the machine off and on.
...

# AWS m7i.large (fixture aws_m7i, with lxc and lxcfs installed)
tier: none (L3-L5)
platform: AWS EC2
why: this VM (amazon) gets no hardware virtualization from its hypervisor
fix: Fixable by changing the instance type or a VM option: This instance family does not expose
     VT-x. Move to C8i, M8i or R8i ... or to a .metal type. Without hardware virtualization the
     fallbacks, fastest first, are: L3 system containers ..., L4 PVM ..., L5 the QEMU emulator ...
cost: C8i, M8i and R8i cost about the same per vCPU as other current families of the same size; ...
fallbacks ready: container
fallbacks possible after installing their packages: emulated
recommended: L3 system containers (shared host kernel, near-native speed); fallbacks cannot be
     registered yet (docs/byoh/NO_KVM.md section 11)

# Probed as a user that cannot open /dev/kvm (fixture dev_kvm_eacces)
tier: unknown_permission (unknown)
platform: unknown platform
why: opening /dev/kvm was refused (EACCES); run the probe as root
fix: Probe as root: bin/byoh-virt probe --user root, or a --user with passwordless sudo (the probe runs sudo -n).
recommended: apply the fix above and probe again

# A Docker or OpenVZ "VPS" (VERIFIED on the lab machine through the harness)
tier: container (refused)
why: this is a docker container
fix: Run the data plane on a VM or bare metal, not in a container.
recommended: use a VM or bare metal as the data plane
```

SHIPPED (WP4): `bin/register-byoh-host` refuses such a host with the probe's text, a `refused:` line
and, when the fastest option is a shipped tier, the exact commands in the order they must run (`set`
refuses a tier that has no rates yet). The format comes from `ByohVirtRegistration#refusal` and is
spec-covered; the location and address here are examples:

```
refused: <the probe's fix>
to register it on its fastest option:
  bin/byoh-location rates --location fsn-cloud --family container --from standard --multiplier <X>
  bin/byoh-location set --location fsn-cloud --virt-tiers kvm,container --accept container
  bin/register-byoh-host --location fsn-cloud --main-ip 203.0.113.10 ... --virt-tier auto --accept-fallback
```

The two `bin/byoh-location` lines are left out when the location already offers the tier.

### 11.2 At registration (SHIPPED, WP4)

Flags on `bin/register-byoh-host`:
- `--virt-tier kvm|auto|container|pvm|emulated`. The default is `kvm`, so today's commands behave as
  today on an L1 host; a non-L1 host is refused, now with the fix and a recommended command line.
- `--accept-fallback`: required whenever the resulting tier is not `kvm`, including through `auto`.
- `--install-pvm-kernel` (built on `pvm-build`, WP6 of the PVM plan): the per-host
  acknowledgement that the control plane installs the location's pinned PVM host kernel (a
  third-party build) and reboots the host into it once. It goes only with `--virt-tier pvm` or
  `auto`, and needs the probe. Until `pvm` joins `ByohVirtTiers::SHIPPED` (WP8), `--virt-tier pvm`
  is still refused with "pvm hosts are not available yet" on every host, before the probe's
  preflight could ask for host work. With the flag, a probe of `none` or `kvm_blocked` is
  taken for `pvm` only when all of these hold (`ByohVirtLadder.pvm_install_problem`
  and `ByohVirtRegistration`):
  - the CPU is x86_64, without vmx or svm, and there is no `/dev/kvm` on the stock kernel;
  - the running kernel does not ship `kvm_pvm` (its `modules.dep` lists no `kvm-pvm.ko`): such a
    kernel is a PVM one already, and is refused with "modprobe kvm_pvm and register the host as pvm
    without --install-pvm-kernel". rhizome's install preflight refuses it too, and so does
    `bootstrap-data-plane.sh --tier pvm`;
  - none of PVM's hard refusals applies: Secure Boot is off, and Meltdown is "Not affected"
    (`pvm_refusal`, which fails closed);
  - the location offers and acknowledges `pvm` and pins both PVM kernels.
  PF3 judges the stock kernel for the install, and every refusal comes before any change on the
  host or in the database. A `kvm_blocked` host gets a note that switching KVM on is faster. A
  lockdown other than `none` gets a note: the PVM entry keeps the stock command line, and the
  unsigned `kvm_pvm` does not load under lockdown. The flag on a host that already runs a PVM
  kernel is refused, since it would record an install that never happens. The host-deb sha256
  the operator acknowledged is kept in `byoh_pvm_host.host_deb_sha256`, and registration refuses
  when the location's pin changed since the decision (between `byoh-host add --phase prepare` and
  `--phase register`, or at the confirmation prompt) with "run the registration again". The
  install (WP7) must check the location's pin against that column before it downloads anything.
  The shell facts of `ubicloud-host` now carry `secure_boot`, `lockdown` and `vulnerabilities`, so
  a host without ruby is judged too. Before that, `pvm_refusal` refused every such host as
  "Meltdown status was not gathered".
- `--no-virt-probe`: skip the pre-registration probe; LearnVirt checks at prep. A lower-tier host
  waits at `verify_virt_tier` until a probe agrees with its tier. A `kvm` host is not held: LearnVirt
  fails open, prep goes on, and LearnVirt pages with the fix if the host cannot run VMs (PrepHost
  then refuses a host without KVM as before).
- The location must already allow the tier. Otherwise the message prints the exact
  `bin/byoh-location rates --location <loc> --family <tier> ...` and
  `bin/byoh-location set --location <loc> --virt-tiers kvm,<tier> --accept <tier>` commands.
- A refusal prints the commands that would register the host on its fastest option only when that
  option can be registered: never for a tier missing from `ByohVirtTiers::SHIPPED`, whose text
  says instead that fallbacks cannot be registered yet. The platform fix of a `none` host names the
  tiers this control plane registers (`ByohVirtLadder.fallbacks_text`, from `SHIPPED`).
- `--default-boot-image` must name the tier's own images on a lower tier: `ByohVirtRegistration#decide!`
  refuses e.g. `ubuntu-noble` for `container` with the right name, before anything is written. Without
  the flag the host downloads the tier's first image; `bootstrap-data-plane.sh` prints the flag only
  for `kvm`. (Final pass; before it, the refusal came from `HostNexus.assemble` as a backtrace.)

The registration matrix (probe × declared tier). "ack" means allowed with `--accept-fallback`:

| Probe | `kvm` | `auto` | `container` | `pvm` | `emulated` |
|---|---|---|---|---|---|
| `kvm` (capabilities ok, `pdpe1gb`) | register | → kvm | refuse ("has KVM") | refuse | refuse |
| `kvm`, but a capability or `pdpe1gb` check fails | refuse, fix | refuse, fix | ack; the fix printed as advice | refuse | ack |
| `kvm_blocked` (firmware, module, BIOS log, or a `kvm64`-class CPU model with or without `vmx`) | refuse, L2 fix | refuse, L2 fix ("fix KVM, or declare a tier explicitly") | ack; fix printed | ack; fix printed; needs `--install-pvm-kernel` | ack |
| `unknown_permission` | refuse: "re-run the probe as root" | same | same | same | same |
| `none`, platform nested `yes`/`some`/`ask` | refuse, fix and cost hint | → recommended fallback, ack; fix printed as advice | ack | ack; needs `--install-pvm-kernel` | ack |
| `none`, platform nested `no` or unknown | refuse; lists the ready fallbacks | → recommended, ack | ack | ack; needs `--install-pvm-kernel` | ack |
| `pvm_blocked` | refuse | → recommended, ack | ack | ack (`modprobe kvm_pvm` advice); with `--install-pvm-kernel` refused, as the kernel is a PVM one | ack |
| `pvm` | refuse (firmware boot is impossible) | → pvm, ack | refuse ("register it as pvm") | ack | refuse |
| `container` (the data plane is a container) | refuse | refuse | refuse | refuse | refuse |

`auto` never picks `pvm` by a kernel install without `--install-pvm-kernel`. With the flag it does
so only on `none` (never `kvm_blocked`, where fixing KVM is the answer, nor `pvm_blocked`, a PVM kernel
whose fix is `modprobe kvm_pvm`), and only
where the install would pass in a location that offers, acknowledges and pins `pvm`. Anywhere else
`auto` picks exactly what it picks without the flag, and adds the note "--install-pvm-kernel was not
used: <why>". A spec pins `auto` per probe fixture, and that spec also passes on the commit before
the flag. Every outcome (probe tier, declared tier, acks) is recorded in the `byoh_operator_action`
args. For `pvm` the record also carries `install_pvm_kernel` and, for an install, the
acknowledged `host_deb_sha256`, plus the stock kernel's `lockdown` and the CPU's `meltdown`.
`HostNexus.assemble(pvm_install:)` writes `byoh_pvm_host` as `install_pending` (an install) or
`committed` (a host that runs a PVM kernel already), with that lockdown and Meltdown state. kvm,
container and emulated hosts get no row. `byoh-host add` shows the install among the changes it asks
to confirm. The flag joins the prepared-arguments digest only when given, so other prepared hosts
keep theirs.

### 11.3 Data-plane bootstrap (SHIPPED, WP4)

`scripts/byoh/bootstrap-data-plane.sh --tier kvm|auto|container|pvm|emulated`. It never changes
kernels, sysctls or GRUB.
- `kvm` (the default) refuses a host without usable KVM, as before. When the probe is at hand (a
  checkout), it also refuses a host the probe finds `kvm_blocked`, for example KVM without the
  capabilities cloud-hypervisor needs or a generic CPU model, which still passed the old `/dev/kvm`,
  vmx/svm and pdpe1gb checks but which registration refuses.
- `auto` makes the choice of `bin/register-byoh-host --virt-tier auto`: `kvm` on a `kvm` probe (the
  pdpe1gb check then refuses a host without 1G pages, as registration does), `pvm` on a PVM host,
  the fastest possible fallback (container, then emulated) on `none` or `pvm_blocked`, and a refusal
  with the probe's reasons otherwise, `kvm_blocked` included.
- A lower tier, declared or chosen by `auto`, is refused **before anything is installed** unless it
  is in the script's `SHIPPED_TIERS`, which a spec keeps equal to `ByohVirtTiers::SHIPPED` (`container`
  since WP5). `BYOH_ALLOW_UNSHIPPED_TIER=1` prepares it anyway, with a warning, for lab work only. A
  shipped tier skips only the KVM checks and installs only its userspace packages (`lxc lxcfs uidmap
  xz-utils quota cryptsetup-bin e2fsprogs`; `qemu-system-x86 ovmf`; nothing for pvm).
- `pvm` (PVM WP6) runs only read-only checks (`pvm_checks`), which are the install refusals that need
  no pins: x86_64, no vmx or svm, no `/dev/kvm` on a stock kernel, Secure Boot off, Meltdown "Not
  affected", GRUB present and `GRUB_SAVEDEFAULT` not true. It warns of a lockdown. It creates the
  `kvm` group and never changes kernels. On a stock kernel it prints `--virt-tier pvm
  --install-pvm-kernel --accept-fallback` as the next step. Where `kvm_pvm` is loaded already, it
  prints the flags without `--install-pvm-kernel`. A spec runs `pvm_checks` against fake host
  trees. On a real host this is UNVERIFIED.
- Ubuntu's `lxc` package enables `lxc-net` (an `lxcbr0` bridge with its own dnsmasq and NAT rules).
  Container host prep (`HostTier.container_host_setup`, WP5) writes `USE_LXC_BRIDGE="false"` to
  `/etc/default/lxc-net` and disables the unit, so it never runs beside the BYOH nftables and per-VM
  dnsmasq. UNVERIFIED on a host.

VERIFIED in a throwaway `ubuntu:24.04` container without `/dev/kvm`, with `sudo` stubbed and the probe
replaced by fixture reports (kvm, kvm_blocked with `missing_caps`, none, pvm, container): the default
path refuses `kvm_blocked` with the probe's reasons and otherwise refuses on the missing `/dev/kvm` as
before; `auto` refuses `kvm_blocked` and a container, picks kvm, pvm or container as above and then
refuses the unshipped pvm and container before any `apt-get`; `--tier emulated` is refused before any
`apt-get`; with `BYOH_ALLOW_UNSHIPPED_TIER=1` the emulated and container paths install their packages
(stubbed) and print `--virt-tier <tier> --accept-fallback`. (That run predates WP5 and WP6, which ship
container and emulated; the emulated additions of section 8.1 are UNVERIFIED); `--tier pvm` refused without `kvm_pvm` (before PVM WP6, which replaced that with `pvm_checks`);
`auto` outside a checkout and bad arguments are refused. On a real VM without KVM it is UNVERIFIED.

### 11.4 Where the registration code lives

SHIPPED (WP4), rewired in the M4 merge. All logic is in `lib/byoh_virt_registration.rb`:
`add_options(parser, options)`, `preflight_tier(facts)` (the tier PF3 judges: the declared one, or for
`auto` what the facts say), `unprobed_reason(report)`, `decide!(verdict, location:, main_ip:,
unprobed_reason:, boot_images:)` (the matrix of section 11.2, built on `ByohVirtLadder.preflight_check`)
and `recommended_commands`. The verdict is the one host preflight built from its own facts
(section 2.3), so no second SSH session opens; the separate `probe` over `Util.rootish_ssh` is gone.
`ByohRegistration#evaluate_preflight(virt:)` judges PF3 for the tier and switches the default boot image
to the tier's first image (`boot_images_for!`); `register!` passes `virt_tier:` to `assemble` and the
decision to the operator log.

Without a verdict (`--skip-preflight`, `--no-virt-probe`, a generated key with `--yes`, or a script
that reported no facts) a `kvm` registration goes on with a note, and LearnVirt checks the host at prep,
as before WP4. `auto` refuses without a verdict; a declared lower tier is registered and then held at
`verify_virt_tier` until a probe agrees.

### 11.5 After registration

- `bin/byoh-virt show --host vh...` prints both the declared tier and the latest probe.
- A `ByohVirtTier` page opens when the probe disagrees with the declared tier, and resolves when they agree.
- `bin/byoh-virt refresh --host vh...` (or `--all`, every BYOH host with rhizome installed) re-probes (SHIPPED).

## 12. Security policy, labels and billing per rung

| Rung | Label (`ByohVirtTiers` description) | Default tenancy | Location acks (`bin/byoh-location set --accept`) | Hard refusals |
|---|---|---|---|---|
| L1 | as today | as today | — | — |
| L3 `container` | "System container: shared host kernel, near-native speed. Not a VM." | One project per location | `container`; options `container:multitenant` (needs whole-core cpusets or SMT off; refused until that is checked, section 10.6), `container:unencrypted-disk`, `container:nested-userns`, `container:guest-firewall` | Host sysctl checks fail; `dir` driver without `prjquota` (any location) |
| L4 `pvm` | "PVM: software virtualization (experimental). Weaker isolation than standard VMs; Ubicloud-supplied guest kernel without AppArmor. Linux only." | One project per location | `pvm`; option `pvm:multitenant` only with SMT off or core scheduling and CPUs "Not affected" for l1tf and mds (refused until that is checked, section 10.6) | Secure Boot on; a Meltdown-affected CPU (any tenancy, section 6.5) |
| L5 `emulated` | "Emulated: slow, compatibility only. Not a security boundary." | One project per **host** (as shipped: per location, section 10.6; SHIPPED in WP6, section 8.1) | `emulated`; no options, so never shared | The unit's hardening directives missing |

Applies to every lower rung:
- Its families and sizes are separate (`Option::TierVmSizes`) and never chosen implicitly.
- A host must hold one VM of the tier's smallest size beside the core kept for the host
  (`verify_tier_capacity`, and early in `bootstrap-data-plane.sh`), or it never reaches `accepting`.
- A `container` VM is refused in a load balancer with SSL certificates (`LoadBalancer#check_cert_guard!`,
  on attach and on enabling certificates) unless the location acknowledged `container:guest-firewall`:
  without that the guest has no rule keeping non-root users off the cert server, which serves the load
  balancer's private key, so rhizome also leaves the cert server address off the container's interface.
  KVM and emulated guests keep the rule and are unaffected.
- The label is the tier's description in `ByohVirtTiers`. As shipped, operators see it when
  `bin/byoh-location set` asks for `--accept` and when registration asks for `--accept-fallback`, and
  `bin/byoh-location show` prints `<tier> (<rung>, experimental)`; customers see the size name
  (`container-2`, `emulated-2`) and the API's refusals. Since the final pass the API's VM object has a
  `virt_tier` object (`tier`, `description`, `experimental: true`, and in the detailed view
  `host_kernel` for container and PVM VMs) and the VM page shows a "Virtualization" row with the
  description and a "Host Kernel" row; a standard VM's output is unchanged (no key, no row). No badge
  with a tooltip in VM lists, and the web form offers no lower-tier size (section 10.6).
- Rates: `bin/byoh-location rates --location <loc> --family F --from standard --multiplier X` (X is required).
  `byoh-location set` refuses to add a tier without rates, and `Validation.validate_billing_rate` in
  `Prog::Vm::Nexus.assemble` refuses a VM whose family has no rate in its location. Rates follow the
  `resource_name` rule in POOL_OPERATIONS.md. Container rates may be lower than `standard` (about 35 MB
  overhead per container); emulated rates use a required multiplier.
- Every mutation writes a `byoh_operator_action` row. Restart web, respirate and monitor after a rates
  change (CLAUDE.md §8a).

## 13. Rollout

| Phase | WP | What changes for whom | Gate to move on | State (2026-10-16) |
|---|---|---|---|---|
| 0 | done | BYOH hosts are probed at prep; a page explains a host without KVM | SHIPPED, full spec gate green | Done |
| 1 | WP1 | This document | — | Done |
| 2 | WP2 | The QEMU-KVM-without-hugepages unit returns to its 9e22d71ec form; goldens for every L1 output | Full gate; `git diff 9e22d71ec` over the golden directories shows only added files | Done, gate green |
| 3 | WP3 | Detection v2: the probe identifies more causes, prints a recommended plan, `refresh --all` back-fills | L1-T1, L2-T1..T3 (section 14) on at least one cloud | Code done, spec gate green; the real-cloud gate is UNVERIFIED (not run) |
| 4 | WP4 | `virt_tier` and the location policy; every existing host becomes `kvm` by the column default; registration refuses with the plan | Full gate; goldens unchanged; an upgrade rehearsal on a copy of the live DB | Code done, gate green, goldens unchanged; the rehearsal on a live DB copy is UNVERIFIED (not run) |
| 5 | WP5 | `container` tier, experimental | The lab harness (dir driver); L3-T1 on a real Ubuntu 24.04 host (crypt-loop, AppArmor, lxcfs, escape probes) before the family is granted outside the operator's own org | Code done, gate green; the lab ran once before its safety rules were tightened (section 5.5); L3-T1 UNVERIFIED |
| 6 | WP6 | `emulated` tier end to end, experimental (SHIPPED, section 8.1) | The L5 harness (written, not run here: it needs a throwaway VM) and L5-T1 | Code done, gate green; `run.sh l5` and L5-T1 UNVERIFIED |
| 7 | WP7 | PVM: the go/no-go script always; the tier only on a reported GO | L4-T1 GO, then L4-T2 | Script done, never run on a real host; no GO, so L4 is "detected, not offered" |
| 8 | WP8 | Docs final: this file, EMULATED_HOSTS, PLATFORMS, the platform guides, TROUBLESHOOTING, COMPUTE, ROADMAP, CLAUDE.md | Every claim labelled; full gate | Done (the gate result is in the WP8 commit message) |

M4 (`byoh-driver` 14c5ddad5) was merged into this branch on 2026-10-16, and PF3 now takes the ladder's
verdict (section 2.3). Nothing is pushed; ROADMAP.md places the branch.

Upgrading the live control plane follows the existing window (CLAUDE.md §8): stop the services;
`pg_dump`; migrate (the `virt_probe` and `virt_tier` columns are additive, and their defaults keep
every host on L1); `install_rhizome` on every host, which ships `virt-probe`; `bin/byoh-virt refresh`.
Rollback: the WP4 migration's `down` refuses while it holds data; run `bin/byoh-host export-audit` first.

## 14. Real-infrastructure tests

**Run e2e1 on AWS, 2026-10-16** ([VERIFY.md](VERIFY.md) §7, harness `scripts/byoh/test/aws-e2e/`):

| Test | Instance | Result |
|---|---|---|
| L1-T2 | m8i.2xlarge, nested on | kvm; the host reached `accepting` and ran three VMs |
| L2 on AWS without nested | t3.xlarge, t3.large | `none (L3-L5) on AWS EC2`, with the move-to-C8i/M8i/R8i fix and the fallbacks |
| L3-T1 | t3.xlarge | pass: CPU 99.8%, memory 99.9% of the host; the guest-side refusals below; LUKS2; uid map; the generated AppArmor profile |
| L4-T1 | m6i.large | **GO** on CH 46.0 and 53.0: CPU 87%, memory 95-100%, syscalls 47%, fork+exec 32%, login prompt 140 s; recovery-check PASS. WP7 may now be built |
| L5 | t3.xlarge | pass: TCG confirmed, CPU 29%, memory 2%, create to running 2 min 16 s |

The tests below that are not in that table stay UNVERIFIED (GCP, Proxmox, VMware, Hyper-V, bare metal, other VPS).


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
bin/byoh-location rates --location $LOC --family container --from standard --multiplier 1
bin/byoh-location set --location $LOC --virt-tiers kvm,container --accept container   # refused before the rates exist
bin/register-byoh-host --location $LOC --main-ip $IP ... --virt-tier auto --accept-fallback   # expect: container chosen and printed
# Create a container-2 VM, then on the host:
sudo aa-status | grep -c 'lxc-<vm>_'                       # >= 1: the generated profile confines it (19 on e2e1)
sudo cryptsetup status ubi-<vm>-0 | grep -q LUKS2          # crypt-loop: encrypted at rest
pid=$(sudo nsenter --net=/run/netns/<vm> lxc-info -n <vm> -P /var/lib/ubicloud/lxc -p -H)   # the container's init; lxc-start is the monitor in
                                                           #   the initial user namespace (uid_map "0 0 4294967295")
sudo awk '{print $2}' /proc/$pid/uid_map                   # = 1000000000 + slot*65536, the slot recorded in
                                                           #   /var/lib/ubicloud/idmap/<vm>
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
# Two containers of two projects must not see each other's processes, files or traffic. This needs
#   container:multitenant, which is refused until its host checks exist (section 10.6), so it waits for them.
# Speed: the section 5.1 set, on crypt-loop and on dir, compared with the host.
```

### L4 PVM go/no-go

L4-T1 is a script, `scripts/byoh/test/real/pvm-go-no-go.sh` (SHIPPED in WP7, UNVERIFIED: never run
on a real host). It refuses to do anything unless `BYOH_REAL_HOST=1`. Run it on a **throwaway**
Ubuntu 24.04 x86_64 VM **without** nested virtualization (GCP e2-standard-4 or AWS m6i.large),
Secure Boot off, that you can power-cycle from the provider console. Never on a registered host.

```bash
# On the throwaway VM, from a copy of this repository (the script uses rhizome/host/lib/virt_probe.rb):
sudo BYOH_REAL_HOST=1 scripts/byoh/test/real/pvm-go-no-go.sh preflight       # read-only; all ok?
sudo BYOH_REAL_HOST=1 scripts/byoh/test/real/pvm-go-no-go.sh install         # kernel + one-shot entry
sudo reboot                                                                 # boots the PVM kernel once
sudo BYOH_REAL_HOST=1 scripts/byoh/test/real/pvm-go-no-go.sh boot-test       # exit 0 = GO, 1 = NO-GO
sudo reboot                                                                 # back to the stock kernel
sudo BYOH_REAL_HOST=1 scripts/byoh/test/real/pvm-go-no-go.sh recovery-check
# Send back /var/lib/byoh-pvm-test/report.txt with the verdict. Optional: ... uninstall
```

What each phase checks (the script's header lists the environment overrides):
- **preflight** (changes nothing): root, x86_64, Ubuntu 24.04, not a container, no `vmx`/`svm`
  (else this is L1; `PVM_ALLOW_HW_VIRT=1` runs anyway and says the result proves nothing for the
  no-hardware case), no `/dev/kvm` on the stock kernel, Secure Boot off, no `GRUB_SAVEDEFAULT=true`,
  the GRUB tools, about 4 GiB of memory, and free disk: 8 GiB for `PVM_WORK`, 1.5 GiB on `/` for the
  kernel's modules and 300 MiB in `/boot`, added up where they share a file system. It measures
  `PVM_WORK`'s nearest existing parent and creates nothing. A Meltdown-affected CPU is a note, not a
  refusal, on this throwaway VM; the product refuses it (section 6.5).
- **install**: downloads the release (default: [cocoonstack/pvm][cocoon-pvm] v0.1.0; third party, so
  fine for this test and never a default for registered hosts). Every file must be **listed** in
  `SHA256SUMS` (`sha256sum -c --ignore-missing` alone passes on an unlisted file) and match it, and
  match a sha256 pin: `SHA256SUMS` lives on the same mutable release as the `.deb` that runs as root,
  so it shows integrity, not authenticity. The script pins the v0.1.0 `.deb`, `vmlinux` and guest
  config (recorded 2026-10-15 from a download that matched `SHA256SUMS`); when `PVM_RELEASE_URL` or a
  file name is overridden, `PVM_HOST_DEB_SHA256`, `PVM_GUEST_KERNEL_SHA256` and
  `PVM_GUEST_CONFIG_SHA256` are required. It refuses a guest
  config without `=y` for VFAT, NLS 437 and ISO8859-1, PVM_GUEST, X86_PIE, virtio-blk/net/pci, ext4
  and the 8250 console. Then, in the order of section 6.7: `GRUB_DEFAULT=saved` in a `grub.d` drop-in,
  `grub-set-default` the running stock kernel, and checks that `grub.cfg` boots `${saved_entry}` and
  can clear `next_entry` (`save_env`), all **before** the `.deb`'s own `update-grub`. Preflight also
  refuses a `/boot/grub` that GRUB cannot write while booting (`grub-probe`: `diskfilter` or `lvm`, or
  btrfs, zfs, squash4 and the other file systems in `00_header`'s `check_writable`): there
  `grub.cfg` still has the `save_env` line, but GRUB never clears `next_entry`, so every power cycle
  would boot the PVM kernel again. Holds the stock
  `linux-image-$(uname -r)` and marks it manual (under the PVM kernel apt protects the running PVM
  kernel instead, so an autoremove could take the stock one and leave `saved_entry` naming nothing;
  `uninstall` restores both marks); installs and `apt-mark hold`s the `.deb`; refuses unless the PVM kernel has a module or built-in for every driver
  between this instance's disks and NICs and `/sys/devices` (ENA, NVMe, virtio, gVNIC...) and for the
  root file system. A driver on those paths that names no module or built-in of the running kernel is
  refused before anything changes (Xen's `vif` and `vbd` map to `xen_netfront` and `xen_blkfront`,
  USB's `usb` and `hub` to `usbcore`), except `pcieport` (built into every x86_64 kernel) and the sysfs
  names in `PVM_UNCHECKED_DRIVERS`, which you checked in the PVM kernel by hand; the report lists those; writes `/etc/grub.d/42_byoh_pvm_test` (one `--id ubicloud-pvm` entry, `pti=off`
  on that entry only) and checks `pti=off` appears exactly once in `grub.cfg`, inside that entry;
  then `grub-reboot ubicloud-pvm` and checks `next_entry` **and** the stock `saved_entry`.
- **boot-test** (on the PVM kernel): one-shot proven (`next_entry` cleared, `saved_entry` still
  stock and still a `grub.cfg` entry whose kernel is in `/boot`); `modprobe kvm_pvm`; `/dev/kvm` mode and owner recorded; `virt_probe.rb --json` must say
  `pvm` (a "DETECTION MISMATCH" line otherwise); Cloud Hypervisor v46.0 **and** v53.0
  (`cloud-hypervisor-static`, sha256 equal to rhizome's pins; the spec keeps them equal); the noble
  cloud image (listed in its `SHA256SUMS`) as raw, a vfat `CIDATA` seed like rhizome's, direct kernel
  boot `--kernel vmlinux-pvm-amd64 --cmdline "console=ttyS0 root=/dev/vda1 rw"`, no network, 2 vCPUs,
  2 GiB, `PVM_BOOT_TIMEOUT` (900 s) each. In the guest, cloud-init prints `BYOH_PVM_GUEST_UP`, the
  PVM lines of `dmesg`, and the same five measurements the script took on the host first (sha256 of
  1 GiB, an 8 GiB `dd` to `/dev/null`, 200k one-byte reads and writes, 2000 fork+exec, 512 MiB of
  direct writes), then powers off. boot-test checks free disk again first (6 GiB in `PVM_WORK`, 3 GiB
  when the raw disk is kept from an earlier run) and deletes each guest's disk once its result is
  recorded, keeping `guest-<version>.serial.log` and `.ch.log`. The verdict has three outcomes, the best over both CH
  versions: **GO** = `BYOH_PVM_GUEST_UP` (cloud-init's runcmd ran; the report gives each measurement as
  a percentage of the host's); **GO, boot only** = a login prompt but no `BYOH_PVM_GUEST_UP` (the PVM
  guest boots, which is the go/no-go question of section 6.7, but the CIDATA seed was not read, so
  there are no measurements; the serial log says why); **NO-GO** = neither. Both GOs exit 0. The
  report gives seconds to the login prompt and to user space. A NO-GO keeps the last serial and CH log lines.
- **recovery-check** (after the second reboot): the stock kernel, no `pti=off`, no `next_entry`.

If the instance does not come back after the first reboot, power-cycle it from the provider console:
it returns to the stock kernel, and `boot-test` then reports "NO-GO (host)". Save the provider's
serial console log.

Executed here (VERIFIED, 2026-10-15): the refusal without `BYOH_REAL_HOST=1`; `preflight` in a
`ubi-q-*` ubuntu:24.04 container (refuses: container, `vmx`/`svm`, no GRUB); and the helpers on
synthetic input (stock-entry path, the `pti=off` and `root=UUID` checks, driver-to-module lookup,
the `SHA256SUMS` listing check, the measurements on the lab host, the user-data YAML round trip,
the ratio report). That run caught a menu title that itself contained `pti=off`. Its small files
missed a pipe that died of SIGPIPE under `pipefail` on a real 860 KB `modules.dep`, so every loadable
module (ENA, NVMe, gVNIC) read as missing; `spec/lib/byoh_virt_tiers_pvm_spec.rb` now runs the
lookup against a `modules.dep` larger than a pipe buffer. Nothing else ran: no kernel was installed
and no GRUB was touched.

UNVERIFIED, to watch on the first real run:
- The menu path `Advanced options for Ubuntu>Ubuntu, with Linux <ver>` on GCP and AWS cloud images,
  and `GRUB_FORCE_PARTUUID` on cloud images (the PVM entry boots with an initrd and `root=UUID`).
- Whether noble's cloud-init waits long for a network that is not there (no NIC is given).
- Whether the guest's `/boot/efi` vfat mount (from memory: no `nofail`) passes with the CIDATA-style
  kernel config; the config check requires VFAT for this reason.

```bash
# L4-T2 (only after a GO and the WP7 build) the same kind of VM registered with --virt-tier pvm --install-pvm-kernel
#   --accept-fallback into a location with --virt-tiers kvm,pvm --accept pvm: the host reaches accepting
#   after one reboot, a pvm-2 VM reaches running, SSH works, and destroy cleans up.
```

### L5 emulated

```bash
# L5-T1 on a throwaway x86_64 Ubuntu 24.04 VM WITHOUT /dev/kvm (AWS m6i.large, a VPS), after WP6:
#   the lab first, which needs no control plane:
BYOH_NOKVM_THROWAWAY_VM=1 scripts/byoh/test/nokvm/run.sh l5     # expect "l5 ok"; record the SSH time
# Then the L-Q live gate of EMULATED_HOSTS.md section 7, with the shipped commands:
#   data plane:     sudo scripts/byoh/bootstrap-data-plane.sh --tier emulated
#   control plane:  bin/byoh-location rates --location <loc> --family emulated --from standard --multiplier <X>
#                   bin/byoh-location set --location <loc> --virt-tiers kvm,emulated --accept emulated
#                   (restart web, respirate and monitor)
#                   bin/register-byoh-host --location <loc> --main-ip <ip> ... --virt-tier emulated --accept-fallback --yes
#                   bin/byoh-location grant --location <loc> --project <ubid>
# Expect accepting after one reboot with total_hugepages_1g = the memory budget, then
#   an emulated-2 VM via the API (size emulated-2, boot_image ubuntu-noble): running, SSH, apt-get update,
#   stop/start/restart/delete, serial log, QMP query-kvm false; a standard-2 VM in the same location fails with 400.
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
- Mounts: only `rhizome/` and `scripts/byoh/test/nokvm/`, read-only, plus a container-local scratch
  tmpfs. Every entry of `.Mounts` must be one of the two binds; `--mount` and `--volumes-from` are
  refused.
- `HostConfig.SecurityOpt`: only `no-new-privileges` and `apparmor=ubi-q-nokvm`. So never
  `systempaths=unconfined`, never a `seccomp=` profile (Docker's default applies; a repo profile would
  have to be added to the allowlist by name), never `apparmor=unconfined`.
- The daemon: before any container is created, `docker info` must list `name=apparmor` and
  `name=seccomp` without `profile=unconfined`, since a daemon without AppArmor leaves the profile
  empty and the option checks alone would pass. Docker records the effective profile only at start, so
  the created container must show an empty (daemon default) or `ubi-q-nokvm` profile, and after the run
  it must show `docker-default` or `ubi-q-nokvm`.
- AppArmor is `docker-default`. The harness grants `SYS_ADMIN` in the initial user namespace (in the
  guest-running modes), so the AppArmor profile's mount denial is what stops container root from remounting `/sys` or `/proc/sys`
  read-write, or mounting a fresh sysfs, and writing host-global kernel state. The read-only checks below
  only observe; they enforce nothing.
- Modes that run LXC inside the container (`run.sh l3`) need `mount`, which `docker-default` denies. They
  refuse to start unless one of these holds:
  - A machine administrator has loaded the AppArmor profile `ubi-q-nokvm` (`NOKVM_L3_PROFILE=1`):
    `docker-default` plus the mounts LXC needs, with `remount` of `/sys` and `/proc/sys` denied, and
    `sysfs` and `proc` mounts allowed only under the container rootfs. It ships as
    `scripts/byoh/test/nokvm/ubi-q-nokvm.apparmor` (final pass); loading one is host kernel policy, so
    the harness never loads it, and the file says how an administrator does. UNVERIFIED: it passed
    `apparmor_parser -Q` (parse only, in a container), was never loaded, and LXC has never run under it,
    so `run.sh l3` and `run.sh l5` have still not run under the tightened rules.
  - `BYOH_NOKVM_THROWAWAY_VM=1` declares the machine a throwaway VM, where `apparmor=unconfined` and
    `seccomp=unconfined` are accepted for `ubi-q-nokvm-l3`.

  Without either, `l3` does not run on the shared lab machine. The 2026-10-15 spike (section 5.1) ran
  with AppArmor and seccomp unconfined on the shared machine; its safety rested on reading every script
  before running it, not on enforcement.
- Inside, **at start and again at teardown**: `/sys` and `/proc/sys` are mounted read-only (from
  `/proc/self/mountinfo`), and no other sysfs or proc mount exists; CapEff lacks `SYS_MODULE` and `SYS_RAWIO`.
- In l3's mount namespace (a fresh proc), `/proc/sys` is bind-mounted read-only again with only
  `/proc/sys/net` writable; `l3.sh` checks at start and end that `kernel.*`, `vm.*`, `fs.*` and the
  hugepage and THP files are not writable. `ip netns exec` still mounts a fresh sysfs in its own mount
  namespace, which only AppArmor or a throwaway VM contains.
- An nft drop toward the `ubi-test-net` subnet, the gateway (the docker host, with every port other
  projects publish) and every private or link-local address out of `eth0` is installed **before** any
  guest starts; the run aborts if it is missing, and each guest checks it cannot reach the gateway's
  ports 5432 and 22.
- `/proc/modules`, `vm.nr_hugepages` and selected `kernel.*` values (read through `/proc`) are
  snapshotted before and after; any change fails the run.
- A lint rejects `modprobe`, `insmod` and `sysctl -w` outside the TCG guest's initramfs.
- `df -h /` ≥ 7 GB before any pull; total usage < 2.5 GB; the cleanup trap removes only the `ubi-q-*`
  containers it created.
- The existing M3 harness in `scripts/byoh/test/` uses `--privileged` for systemd and is not reused.

**U1 proof, kept in every WP.** These golden specs must stay unchanged:
- `rhizome/host/spec/vm_setup_golden_spec.rb`, with the fixtures `ch_unit.service`, `ch_unit_nohugepages.service`, `ch_dnsmasq.service`, `qemu_kvm_hugepages*.service`, `qemu_kvm_nohugepages.service` (WP2)
- `spec/model/metal/vm_golden_spec.rb` (`params_json_ch*.json`; `params_json_qemu_gpu*.json`, WP2)
- `spec/scheduling/allocator_golden_spec.rb` (`allocator_*.json`, WP2): candidate hosts, scores, the
  logged query and filter counts, and what is booked, on an L1 fixture
- `spec/prog/vm/nexus_assemble_golden_spec.rb` (`nexus_assemble_families.json`, WP2): the VM row,
  volumes and strand for the first size of every family and architecture
- `spec/routes/web/vm_options_golden_spec.rb` (`vm_create_options.json`, WP2): the create form's
  option tree for a project without BYOH locations
- `spec/prog/vm/metal/nexus_golden_spec.rb` (`create_unix_user.sh`)
- `spec/prog/vm/prep_host_golden_spec.rb` (the PrepHost command)
- `spec/lib/validation_golden_spec.rb`
- `spec/routes/api/project/location/vm_size_error_golden_spec.rb`

A WP may add fixtures but never edit these.

### WP1: this document (docs only) (DONE)

The revised ladder: renumbered by speed, research and citations kept, measurements, cost table, PVM
lifecycle, gVisor rejected, registration matrix, security table, M4 hook, tests, build plan, critique
dispositions. Gate: `spec/lib/byoh_virt_platforms_spec.rb` (it reads this file).

### WP2: U1 repair, goldens first (DONE)

1. Goldens from 9e22d71ec, no code change, generated from a `git worktree` of 9e22d71ec:
   `qemu_kvm_nohugepages.service`; `params_json_qemu_gpu.json` (the B200/B300 path in
   `model/metal/vm.rb`); an allocator candidate-list golden for an L1 fixture; an options JSON golden
   for a non-BYOH project; a `Prog::Vm::Nexus.assemble` attribute golden for every existing family.
   They fail on HEAD only for the nohugepages unit.
2. Gate the memfd backend in `vm_setup.rb` on `emulated?`; every golden green.
- Done: `git diff 9e22d71ec -- '*golden*'` shows only added files; the full gate.
- Status: SHIPPED. Every WP2 golden was generated in a worktree of 9e22d71ec (which also needed
  this branch's `virt_probe` migration, only to share the test databases), and the pre-existing
  goldens regenerate byte for byte there. The assemble golden tries hetzner-fsn1, us-west-2,
  gcp-us-central1, github-runners and eu-central-1, so every family and architecture (including
  `premium` and the AWS m-families) is assembled in a location that bills it; a family that none
  of them bills fails the spec instead of going unpinned.

### WP3: detection v2 and the harness skeleton (DONE)

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
- Result: shipped as section 2.1 describes, with the differences of section 2.2. Gate and harness
  results are in the WP3 commit message.

### WP4: the tier framework (DONE)

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

### WP5: L3 system containers (DONE; real-host checks UNVERIFIED)

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

### WP6: L5 emulated hookup (slim) (DONE; lab and real host UNVERIFIED)

- The family and sizes in `TierVmSizes`, the policy gate rows, the `verify_tier_capacity` budget, the
  30-minute deadline and 180 s soft stop, refusal of the CH and firmware downloads on emulated hosts,
  the hardening golden unit and the refuse-to-start check, `INSTALL_HINT`/`KVM_AVAILABLE_HINT` text,
  `bootstrap-data-plane.sh --tier emulated`.
- Harness `run.sh l5`: SSH within 420 s, `query-kvm` false, symlink and chown-race probes, delete twice.
- Done: the full gate and the harness; the family experimental.

### WP7: PVM, go/no-go first (script DONE; build blocked on L4-T1)

Status 2026-10-15: the "always" part is SHIPPED (the script, `spec/lib/byoh_virt_tiers_pvm_spec.rb`,
section 14). No GO has been reported, so the build below has not started and L4 is
"detected, not offered".

- Always (this branch): `scripts/byoh/test/real/pvm-go-no-go.sh`, the L4-T1 script (never run here; it
  refuses unless `BYOH_REAL_HOST=1`), plus docs. Detection of `pvm` and `pvm_blocked` is already SHIPPED.
- Only if the user reports an L4-T1 GO: `pvm_kernel.rb` (operator-supplied URLs and sha256 in the
  location policy), `download-pvm-kernel` and its prog, `install-pvm-host-kernel` (section 6.7 checks,
  the grub drop-in, `grub-reboot`, `apt-mark hold`, the udev rule), `Prog::InstallPvmHostKernel`, the
  `verify_virt_tier` label, the pvm step list, direct boot in `build_ch_service` (a new
  `ch_unit_pvm.service` fixture; `ch_unit.service` unchanged), the `PVM_ROOT` table, image and GPU
  refusals, lifecycle pages. Optional: `run.sh pvm-hostside` (about 140 MB, disk-checked).
- On NO-GO, or no report: stop after the script and the docs; L4 is "detected, not offered".

### WP8: docs and final gate (DONE)

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
- Status 2026-10-16: done. The plan's `proxmox-and-hypervisors.md` is the existing
  `platforms/proxmox.md` (its "Other hypervisors" section covers libvirt, ESXi, Hyper-V and XCP-ng),
  and `bare-metal-dedicated.md` got the same probe pointer as `own-hardware.md`. Not done because the
  code does not exist: the PVM one-shot recovery for registered hosts (TROUBLESHOOTING covers only the
  L4-T1 test machine). The `ByohKernelReboot` page was added in the final pass.

### Final pass (2026-10-16)

Review findings fixed, all spec-gated and none run on a real host: the boot-image refusal at
registration (section 11.2), the fallback text that still said nothing could be registered, the
smallest-VM capacity check, `ubi vm create -s <tier size>`, the load balancer cert guard for
containers (section 12), the container seed readable only by the container's root (section 5.5),
`ByohKernelReboot` with a daily lower-tier probe (section 10.5), the tier description and host kernel
in the API and on the VM page (section 12), a `cost_hint` on every platform row, and the `ubi-q-nokvm`
AppArmor profile file (section 15, harness; parse-checked only). Accepted deviations: section 5.5
(slot location, `/vm/<vm>` owner, lxcfs, DoS advice; `io.max` and the multi-tenant checks block
multi-project container locations) and section 10.6 (per-location tenancy is final). Still not run:
`run.sh l3` and `run.sh l5` under the tightened rules (the profile needs an administrator to load it,
or a throwaway VM), WP7's PVM build (waits for an L4-T1 GO), and every real-host test of section 14.

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
