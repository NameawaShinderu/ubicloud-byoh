# The virtualization ladder: fast first, emulation last

Status: 2026-10-15, branch `no-kvm` (from `byoh-driver` 9e22d71ec plus the QEMU-TCG work).
This document replaces [EMULATED_HOSTS.md](EMULATED_HOSTS.md) as the entry point for hosts without KVM.
That file stays as the detailed reference for rung L5.
Labels used throughout:
- **SHIPPED**: code on this branch, covered by the spec gate.
- **VERIFIED**: executed here (the shared lab machine, AMD Ryzen 7 3800X, kernel 6.8; a shared
  machine, so treat every timing as ±20%). The "lab spike" is the 2026-10-15 no-KVM spike, run in a
  `ubi-q-*` container without `/dev/kvm` and without `--privileged`.
- **SOURCE**: read in a cited document, with a confidence (high, medium, low).
- **PLANNED**: specified in the build plan (section 14), not written yet.
- **UNVERIFIED**: not executed anywhere. Every real-infrastructure test in section 13 is UNVERIFIED.

## 1. The short answer

Every fast VM monitor needs KVM: Cloud Hypervisor (what Ubicloud runs), Firecracker, crosvm, Kata's
Dragonball and QEMU-KVM all open `/dev/kvm`. On a machine without KVM the only way to keep real VMs
fast is to **get KVM back**. You can do that in three ways: switch it on, use nested virtualization, or
use PVM, which provides KVM in software. When none of them is possible, the fast fallback is a
shared-kernel system container, and the last resort is QEMU's emulator.

| Rung | The machine | What runs the guests | Speed vs native | Isolation | State |
|---|---|---|---|---|---|
| **L1** | `/dev/kvm` works (bare metal, or a VM with nested virtualization) | Cloud Hypervisor, exactly as today | ~95-100% on bare metal; nested ≥90% for CPU-bound work, much less for page-fault-heavy work (section 3) | Hardware VM | SHIPPED (today's product); detection SHIPPED |
| **L2** | The hardware can virtualize, but KVM is off or not exposed | Nothing until it is fixed | n/a | n/a | Detection and the per-platform fix SHIPPED; refusal at registration PLANNED (WP1) |
| **L3** | No hardware virtualization; a PVM host kernel (`kvm_pvm`) | Cloud Hypervisor on PVM's `/dev/kvm`, with a PVM guest kernel booted directly | Near nested KVM or better under load; slower syscalls and forks (SOURCE) | VM, with a software world switch | Detection SHIPPED. Host side VERIFIED under emulation; guest boot UNVERIFIED (section 5.6). Running VMs PLANNED (WP3), experimental |
| **L4** | No hardware virtualization, stock kernel | Unprivileged LXC system containers in Ubicloud's per-VM network namespace | **CPU 95-99%, memory bandwidth 91-98%, 3.6-5.4 s to SSH** (VERIFIED, lab spike) | Shared kernel: weaker than a VM | Feasibility VERIFIED (section 6). Backend PLANNED (WP4), experimental |
| **L5** | Anything x86_64 | QEMU TCG (software CPU) | CPU 26-29%, memory bandwidth ~2.5%, 64-96 s to SSH (VERIFIED) | Not a security boundary | Rhizome side on this branch; control plane PLANNED (WP5) ([EMULATED_HOSTS.md](EMULATED_HOSTS.md)) |

Rules, carried over from U1 and the M2 contract:
- An L1 host behaves byte for byte as today. The ladder adds a read-only probe, a record and a page;
  later rungs add code paths that run only on hosts declared for them. Golden specs prove it (section 14, "U1 proof").
- **A host never falls down the ladder by itself.** The probe *detects*; the operator *declares* a
  lower rung at registration, and the declaration must agree with the probe. A lower-rung family is
  offered only in a location that allows that rung, only to projects granted that location, and only
  when the customer picks that family. Nothing falls back silently.
- No cloud-specific code path. Platforms are rows in `lib/byoh_virt_platforms.rb`, and their
  remediation is text in that table and in section 4.

What the user gets on each kind of machine, fastest option first:

| Machine | Best rung | What to do |
|---|---|---|
| Bare metal (any provider, own hardware) | L1 | Nothing, or switch VT-x/AMD-V on in the firmware (L2 fix) |
| Cloud VM with nested support (AWS C8i/M8i/R8i, GCP Intel series, Azure Dv3+, OCI Standard3/E5) | L1 nested | Switch nested virtualization on (section 4) |
| Proxmox, VMware, Hyper-V, VirtualBox, libvirt VM | L1 nested | Expose VT-x to the VM (section 4) |
| Cloud VM without nested (AWS outside the list, Hetzner Cloud, most VPS) | L3 if you accept a custom host kernel; otherwise L4 | Move to bare metal or a nested-capable type if you can; otherwise declare `pvm` (experimental) or `container` |
| Anything else that runs Linux on x86_64 | L5 | Demos, CI, compatibility only |
| A container (OpenVZ, LXC or Docker VPS) | none | Refused: run the data plane on a VM or on metal |

## 2. What ships on this branch (SHIPPED)

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

### 2.1 Tiers and how they are detected

`VirtProbe.classify` (rhizome) decides, in this order:

1. `systemd-detect-virt --container` names a container, or (without systemd) `/.dockerenv`,
   `/run/.containerenv` or `container=` in PID 1's environment: **`container`**, which is refused.
2. `/dev/kvm` is a character device:
   - it does not answer `KVM_GET_API_VERSION` with 12: **`kvm_blocked`** (permissions, a broken module, a passed-through node)
   - `kvm_pvm` is loaded and neither `kvm_intel` nor `kvm_amd` is: **`pvm`**
   - otherwise: **`kvm`**. It is `nested` when the CPU has the `hypervisor` flag or systemd names a VM technology.
3. There is no `/dev/kvm`:
   - x86 with `vmx` or `svm`: **`kvm_blocked`** (module not loaded, or loaded without `/dev/kvm`)
   - bare metal with neither flag: **`kvm_blocked`**, because the firmware disabled VT-x/AMD-V. Since about Linux 5.6, the kernel drops `vmx` from `/proc/cpuinfo` when the firmware locks VMX off (SOURCE, medium; the kernel's "VMX feature" reporting).
   - the running kernel's `modules.dep` lists `kvm-pvm.ko`: **`pvm_blocked`**
   - otherwise: **`none`**

The facts gathered: arch, kernel release, CPU vendor, model, the flags `vmx svm hypervisor pdpe1gb`,
`/dev/kvm` and its API answer, the loaded modules `kvm kvm_intel kvm_amd kvm_pvm`, the `nested`
module parameter, `kvm-pvm.ko` availability, `systemd-detect-virt --vm/--container`, and the DMI
fields `sys_vendor product_name product_version bios_vendor board_vendor chassis_vendor chassis_asset_tag`.

VERIFIED on the lab machine:
- inside a docker container without `/dev/kvm`, through the real bootstrap step 1b on Ubuntu 24.04 (Ruby 3.2): `tier: container`
- inside an Alpine container without systemd: `tier: container`, from `/.dockerenv`

UNVERIFIED: a real L1 bare-metal host, a nested VM, a PVM host, and the cloud VMs in section 13.

### 2.2 Using it

Before registering (on the control plane; the host needs `ruby`, which the bootstrap installs):

```
bin/byoh-virt probe --main-ip 203.0.113.10 --ssh-key ~/.ssh/byoh_data
# exit 0: L1, register it. exit 3: not L1; the output carries the fix.
```

On the host itself: `scripts/byoh/bootstrap-data-plane.sh` (step 1b), or `sudo ruby rhizome/host/bin/virt-probe`.

After registration: `bin/byoh-virt show --host vh...`. After fixing the host: `bin/byoh-virt refresh --host vh...`,
then let PrepHost retry. It retries on its own, since a failed prep strand retries with backoff.

### 2.3 Hook for M4's host preflight

M4 owns host preflight (`scripts/byoh/host/ubicloud-host`, `lib/byoh_host_preflight.rb`, PF3). It
can use the ladder without new code here:
- In the same SSH session, pipe `ByohVirtLadder.remote_script` to `ruby - --json` and pass the
  output to `ByohVirtLadder.parse`.
- Use `Verdict#fix` as PF3's fix text, and `Verdict#caveats` as PF3 INFO lines for nested hosts.
- `Verdict#standard_vms?` is PF3's pass condition. It agrees with `KvmCheck` except for a PVM host,
  which `KvmCheck` refuses for lacking `vmx`/`svm`, and the ladder refuses as "not supported yet".
- For an emulated (L5) registration, PF3 is INFO and PF4 is skipped (EMULATED_HOSTS.md §A.14).

## 3. L1 and nested virtualization

L1 is today's product. The probe adds three caveats when the host is itself a VM (`nested`):

1. **Speed.** Google documents "a 10% or greater decrease in performance for CPU-bound workloads"
   for nested VMs, more for I/O-bound ones (SOURCE, high, [GCP nested overview][gcp-nested]). The
   PVM paper measured nested KVM (EPT-on-EPT) on Alibaba Cloud at up to about 5× slower than
   single-level KVM for a 16-way kernel build, and about 550× for SPECjbb under contention, because
   every guest page-table change traps to both hypervisors (SOURCE, high, [SOSP'23][pvm-paper] figure 2).
   Light, CPU-bound work is near native, and fork- and memory-heavy work suffers most.
2. **Host lifetime.** The provider's maintenance can stop or reboot the L1 VM, taking every guest
   down. AWS does not support hibernation with nested virtualization (SOURCE, high, [AWS][aws-nested]).
3. **Health checks.** The clocksource and disks are virtual, so `bin/monitor` may misfire (PLATFORMS F5).

The probe also warns when `pdpe1gb` is missing. Without it there are no 1G hugepages for `Prog::SetupHugepages`.

## 4. L2: switch KVM on. Platform table

`ByohVirtPlatforms` matches the first row whose patterns all match. Keys are the anchors the code
records in `vm_host.virt_probe["platform"]`. Offerings change; this table was checked 2026-10-15.

| Key | Platform (DMI signal) | Nested | How to get KVM | Source, confidence |
|---|---|---|---|---|
| `aws` | AWS EC2 (`sys_vendor` "Amazon EC2") | some | `.metal`, or 8th-generation Intel (C8i/M8i/R8i and variants) with CPU option nested virtualization enabled; the instance must be stopped to change it. Available since 2026-02-12. | [AWS docs][aws-nested], high; [Classmethod][classmethod], medium. The AWS locales disagree on whether 7th-generation types are included: check the current list. |
| `gcp` | Google Compute Engine | some | `--enable-nested-virtualization` on Intel series, or AMD N4D; not E2, memory-optimized or Arm; the org policy must allow it | [GCP][gcp-nested], high |
| `azure` | Azure (`chassis_asset_tag` 7783-7084-3265-9085-8269-3286-77) | some | Dv3/Ev3 and newer general-purpose and memory families; not B or A series; check the size page | [Azure blog][azure-nested], high for Dv3/Ev3; newer families medium |
| `hyperv` | Hyper-V guest | yes | `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true`, with the VM off | Microsoft docs, high (well known) |
| `vmware` | VMware | yes | "Expose hardware assisted virtualization to the guest OS" (`vhv.enable`) | VMware docs, high (well known) |
| `virtualbox` | VirtualBox | yes | `VBoxManage modifyvm <vm> --nested-hw-virt on` | VirtualBox manual, high |
| `oci` | Oracle Cloud (`chassis_asset_tag` OracleCloud.com) | some | VM.Standard3.Flex (Intel) or VM.Standard.E5.Flex (AMD); not Ampere | [Oracle blog][oci-nested], medium |
| `hetzner_cloud` | Hetzner Cloud (`sys_vendor` Hetzner) | no | Use a Hetzner dedicated server | user reports ([r/incus][hetzner-reddit], [wirelessmoves][wirelessmoves]), medium |
| `digitalocean` | DigitalOcean | no (unsupported) | Some Intel Droplets expose VT-x, but it is not supported and is slow | [DO community][do-nested], medium |
| `linode` | Akamai Cloud (Linode) | no | Not offered; staff cite live migration | [Linode community][linode-nested], low-medium (dated) |
| `vultr` | Vultr | no | Vultr Bare Metal | [NANOG thread][vultr-nanog], low (2021) |
| `scaleway` | Scaleway | ask | Some instance types reportedly expose it; Elastic Metal does | [LowEndTalk][scaleway-let], low |
| `openstack` | OpenStack (OVHcloud Public Cloud and others) | ask | Depends on the cloud operator's nova `cpu_mode` and the compute nodes' `nested=1` | OpenStack docs, high for the mechanism; per-provider unknown |
| `qemu_kvm` | QEMU/KVM: Proxmox VE, libvirt, KVM VPS | ask | Proxmox: `qm set <vmid> --cpu host`, with `nested=Y` on the node; libvirt: `host-passthrough` | Proxmox and libvirt docs, high (well known) |
| `xen` | Xen | ask | `nestedhvm=1`, which Xen marks experimental | Xen docs, medium |

The DMI strings for Linode, Vultr and Scaleway are UNVERIFIED guesses, so a miss falls back to the
generic fix. Bare metal matches no row: the fix there is the firmware setting, or `modprobe`.

Prices for the cheapest L1 path change often. Two reference points: an m8i.2xlarge with nested
virtualization was $0.45/h in ap-south-1, against $5.86/h for an m5d.metal (CLAUDE.md §10a). A
Hetzner A102 dedicated server was about $100 a month, against about $3,500 a month for an AWS
m7i.metal-24xl on demand ([Alex Ellis][ellis-pvm], medium).

## 5. L3: PVM, KVM without hardware virtualization

### 5.1 What it is

PVM (Pagetable-based Virtual Machine) comes from Ant Group and Alibaba. It is a KVM "flavor" module
(`kvm-pvm.ko`, beside `kvm.ko`) that runs the guest's kernel and user space both in hardware ring 3.
It switches worlds through a small "switcher" mapped at the same address in host and guest, and it
virtualizes memory with optimized shadow paging (PCID mapping, prefault, fine-grained locks).
Because it needs no VT-x, it runs inside an ordinary cloud VM. Because it is still KVM, any VMM
that speaks the KVM API sees a `/dev/kvm`. (SOURCE, high: [SOSP'23 paper][pvm-paper] §3, [LPC 2024][pvm-lpc].)

### 5.2 Status and maintenance risk

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

### 5.3 VMM compatibility

| VMM | With PVM | Source, confidence |
|---|---|---|
| Cloud Hypervisor | Boots a PVM guest with stock CH via `--kernel vmlinux-pvm --cmdline ... --disk ...` | [cocoonstack][cocoon-pvm], medium (third party, not executed here) |
| Firecracker | A fork ([loopholelabs `main-live-migration-pvm`][ellis-pvm]) | medium |
| QEMU | "needs a one-line patch" | [Alex Ellis][ellis-pvm], low |
| Dragonball (Kata runtime-rs) | Used in the PVM-enabled Kata demos | [Kata][kata-pvm], medium |

### 5.4 Performance (SOURCE, high: [SOSP'23][pvm-paper] §4, Intel Xeon 8269CY on Alibaba Cloud)

- VM exits: PVM inside a VM ("pvm (NST)") cut exit/entry latency by more than 75% against nested KVM (Table 1).
- Syscalls are PVM's weak spot: up to 7× slower than hardware without "direct switching", and about 1.3× with it (Table 2).
- `fork`/`exec`/`sh` microbenchmarks are slower than nested KVM; most other LMbench rows are better (Table 3).
- Applications: kernel build, Blogbench, SPECjbb and fluidanimate are "close to single-level virtualization", and much better than nested KVM at 16-way concurrency (Figure 11).
- Third party ([Alex Ellis][ellis-pvm], medium): a kernel build in a PVM Firecracker guest on an AWS m6a.xlarge took 2m2s, against 1m10s on the host (about 57% of native). I/O-heavy work showed "noticeable overhead".

### 5.5 Security

- Guest user and guest kernel live in separate page tables. The host keeps KPTI-style isolation for
  the switcher, and the switcher clears guest registers on exit (SOURCE, high, paper §3.2).
- The authors argue the attack surface is smaller than a container's (about 10 hypercalls against
  250+ syscalls), and that the L0 cloud hypervisor stays thin. That is the authors' claim, not an
  independent audit. PVM has had far less scrutiny than VT-x KVM. Treat it as weaker than L1 and
  stronger than L4.
- The host kernel is custom, so the host's kernel CVE response becomes ours.

### 5.6 What the lab spike showed (VERIFIED, partial)

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
  2026-09-15, after v0.1.0 was built. Only real hardware can tell them apart: test L3-T1 in section 13.

More constraints found by the spike (SOURCE, medium: cocoonstack and virt-pvm docs and issues):
- The host kernel needs `pti=off` (also used by [Slicer][slicer-pvm]), Secure Boot off (the kernel is unsigned), and `kvm_intel`/`kvm_amd`
  not loaded, because they cannot coexist with `kvm_pvm`.
- `pti=off` removes Meltdown protection on CPUs that need it.
- The guest kernel is module-free and has no initramfs. It has virtio-blk, virtio-net, ext4, overlayfs,
  netfilter and IPv6 built in. It has **no AppArmor, XFS or Btrfs** (VERIFIED by reading `guest-pvm-amd64.config`).
- **CVE-2026-53359 ("Januscape")**, a guest-triggerable use-after-free in the shadow MMU, affected
  PVM. It was fixed on the branch in July 2026. A PVM host must track that branch for security fixes.
- An "out-of-tree module" mode that builds `kvm-pvm.ko` against a stock distro kernel is in
  progress (virt-pvm issues #26 and #29, open). It would remove the host-kernel swap. Not usable yet.
- The CH, QEMU and Firecracker notes are in section 5.3. Upstream reports a CH virtio-pmem root-disk
  issue ([virt-pvm #1][virt-pvm-issue1]); virtio-blk is fine, and that is what Ubicloud uses.

### 5.7 What Ubicloud needs for L3 (design; built in WP3)

1. **Host kernel, as an opt-in.** The operator registers the host with `--virt-tier pvm`. Then either
   the operator installs a PVM host kernel, or `--install-pvm-kernel` lets HostNexus do it:
   - `prep` buds `Prog::InstallPvmHostKernel`, which runs `host/bin/install-pvm-host-kernel`. That script:
     - refuses when Secure Boot is on (`mokutil --sb-state`)
     - refuses when `/sys/devices/system/cpu/vulnerabilities/meltdown` is not "Not affected", unless the operator passed `--accept-meltdown-exposure`
     - installs the pinned, sha256-checked `.deb`
     - makes it the GRUB default with `pti=off`
     - blacklists `kvm_intel` and `kvm_amd`, and loads `kvm_pvm` at boot
   - The existing `prep_reboot` → `reboot` labels (`prog/vm/host_nexus.rb`) boot into it.
   - A new check after the reboot runs `Prog::LearnVirt` and requires tier `pvm`; otherwise the strand fails with the fix.
   - Ubicloud never builds kernels. It pins a third-party build by version and sha256, the same way `config.rb` pins Cloud Hypervisor.
2. **Guest kernel artifact.** `vmlinux-pvm-amd64`, pinned by version and sha256 in a new rhizome table
   (`rhizome/host/lib/pvm_kernel.rb`), and downloaded at prep by `Prog::DownloadPvmKernel`, the same
   way `Prog::DownloadFirmware` works.
3. **Direct kernel boot.** Today `build_ch_service` (`rhizome/host/lib/vm_setup.rb:986`) passes
   `--kernel #{firmware_version.path}` (`:1024`), so the firmware starts the image's own kernel.
   - A PVM VM instead passes the PVM `vmlinux` and `--cmdline "root=<root> rw console=ttyS0 ..."`.
   - The guest kernel has no initramfs, so `root=LABEL=` cannot resolve. The root device comes from
     a per-image data table: Ubuntu cloud images use `/dev/vda1`.
   - Images whose root filesystem is XFS (AlmaLinux) cannot boot, and are refused at VM creation.
   - The CH unit for L1 stays byte-identical; the golden fixture `ch_unit.service` pins it.
4. **Unsupported on L3:**
   - anything that needs the image's own kernel: custom kernels, DKMS, kexec, kernel updates inside the guest
   - AppArmor inside the guest
   - XFS and Btrfs roots
   - Windows and UEFI
   - GPUs
   - snapshot, migration, memory hotplug and balloon, which upstream has not tested
5. **Family** `pvm`, labelled "PVM: software virtualization (experimental). Linux only; Ubicloud
   supplies the guest kernel." It has its own rates. The security policy is in section 11.

Recommendation:
- Build L3 because it is the only way to get real VMs fast on clouds without nested virtualization.
- Keep it **experimental**: hidden, single-project by default, and off by default.
- Promote it only after L3-T1 and L3-T2 pass on real hardware.

## 6. L4: system containers

The near-native rung for any Linux machine. The trade-off is one shared host kernel.

### 6.1 What the lab spike ran (VERIFIED)

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

### 6.2 What the spike changes in the design

| # | Finding | Design consequence |
|---|---|---|
| P2 | `ip netns exec` remounts `/sys`, hiding cgroup2; systemd in the container then fails | The rhizome launcher starts `lxc-start` under `ip netns exec` in a private mount namespace that mounts `cgroup2` at `/sys/fs/cgroup` again (VERIFIED fix) |
| P3 | `lxc.net.0.type = phys` with a pre-made veth: the pair is destroyed at stop, and the next start fails | Use `type = veth`, `veth.pair = tap<vm>` and a `script.up` hook. The hook runs the same address and route setup that rhizome applies to a tap today (`setup_taps_6`, `vm_setup.rb:470`) |
| P4 | dnsmasq `--bind-interfaces` fails when the link does not exist yet | Container VMs start dnsmasq with `--bind-dynamic`. The CH dnsmasq unit stays byte-identical (golden `ch_dnsmasq.service`) |
| P6 | ubuntu-base is too bare: no `dbus`, `systemd-resolved` or `lsb-release`; cloud-init's apt module fails | Container images are built from the linuxcontainers.org `cloud` variants, which are sha-pinned, or from ubuntu-base plus that package list. They are separate boot images (`ubuntu-noble-container`), never the VM `.raw` images |
| P7 | `sys-kernel-config.mount` and `sys-kernel-debug.mount` fail | Mask them in the image, as Incus images do |
| P8 | `/proc/meminfo` shows host RAM | lxcfs is required on L4 hosts (UNVERIFIED here) |
| P1, P5 | `/proc` masking; netns SNAT | Lab-only artefacts; nothing to change |

### 6.3 Design

- **Runtime:** LXC (liblxc), driven by rhizome, not an Incus daemon, so there is one control plane.
  systemd-nspawn would also work (`--network-namespace-path`, `--private-users=pick`; UNVERIFIED), but
  LXC brings the mature unprivileged seccomp profile, idmap handling and AppArmor templates.
- **Unit:** `<vm>.service` in the VM's slice, `ExecStart=` the launcher in the foreground (`lxc-start -F`),
  `ExecStop=` `lxc-stop`. Limits are cgroup v2:
  - `cpu.max` from vCPUs and the CPU percent limit
  - `memory.max`, plus `memory.swap.max = 0`
  - `pids.max`
  - `io.max` from the size's IO limits
- **Identity:** each container gets its own 65,536-id range, derived by rhizome from the VM's unix user's
  uid: `base = uid × 65536`. That is unique per host and needs no new column. uids 1000-65000 give bases from
  65,536,000 up to below 2³², so a range never overlaps a real uid, root's default 100000 range, or
  another VM's range. Neither the user nor the image can choose it: the 2026 Incus advisory CVE-2026-62313
  ([OpenCVE][cve-idmap]) is the reason.
- **Hardening:**
  - AppArmor `generated` (`lxc-container-default-cgns`)
  - LXC's default seccomp, plus denial of `keyctl`, `bpf`, `userfaultfd`, `perf_event_open`, `kexec_*` and `open_by_handle_at`
  - no nesting
  - no `/dev/kvm`, `/dev/fuse` or `/dev/net/tun` inside
  - lxcfs
  - `cap.drop` as above
  - gVisor is optional and later (section 6.4)
- **Network:** rhizome's per-VM netns, nftables, dnsmasq, anti-spoofing, DNAT/SNAT and `ByohEgressNat`
  stay exactly as they are. Only the guest end changes from a tap to a veth, keeping the name `tap<vm>`.
  IPv6 RA and DHCPv6 in the netns are UNVERIFIED.
- **cloud-init:** the same content as `cloudinit` (`vm_setup.rb:695`), written as NoCloud files into the
  rootfs. The CIDATA image path stays byte-identical for VMs. Swap, `growpart` and `resizefs` are
  disabled for containers.
- **Disk.** Two drivers; the location chooses one:
  - `crypt-loop` (default): a sparse image file, `cryptsetup` LUKS2 with the VM's existing storage key,
    ext4, mounted at the rootfs and idmapped (`lxc.rootfs.options = idmap=container`, kernel ≥ 5.12). It keeps
    encryption at rest and a hard disk size, as Ubicloud promises for VMs today. UNVERIFIED in the lab,
    because loop and dm devices are host devices.
  - `dir`: a plain directory. It has no encryption and no hard size limit, so it needs the location ack
    `--accept-unencrypted-container-disks`. It is the only driver the lab harness can run.
  - ubiblk (vhost-user-blk) cannot serve a container. ublk might later (UNVERIFIED).
- **Serial log:** `lxc.console.logfile` takes the place of CH's `--serial file=` (`vm_setup.rb:1018`), so the
  serial log tab keeps working. There are no early kernel messages.
- **Metrics:** cgroup `cpu.stat`, `memory.current` and `io.stat` take the place of the per-PID reads in
  `rhizome/host/lib/vm_stats.rb:15`.
- **Unsupported on L4** (the API refuses or the docs say so):
  - custom kernels and kernel modules, `modprobe`, kernel upgrades inside the guest, eBPF/kprobes
  - sysctls outside the namespace
  - Docker or Kubernetes inside without nesting
  - nested virtualization
  - Windows and other non-Linux images
  - FIPS kernels
  - GPUs (`vm_setup.rb:861`)
  - swap
  - memory balloon and live resize as a VM does them
  - live migration
  - UEFI
  - `/dev/vda`-based tooling
  - The guest sees the host's kernel version.

### 6.4 gVisor (VERIFIED in the lab spike: runsc release-20261005.0, systrap platform)

| Metric | Native | gVisor | Ratio |
|---|---|---|---|
| sysbench cpu 1t / 2t | 2082 / 4070 | 2064 / 3999 | 99% / 98% |
| sysbench memory | 6071 / 9566 | 6281 / 9571 | ≈100% |
| 4M one-byte syscalls | 4.91 s | **64.36 s** | **13.1× slower** |
| 2000 fork+exec | 2394 ms | **12281 ms** | **5.1× slower** |
| fio 4k random read | 98.8k IOPS | 51.7k IOPS | 0.52× |

gVisor is an application sandbox: support for systemd as PID 1 is limited (SOURCE, gVisor docs). It may
become an optional "hardened" runtime for single-service L4 workloads later. It is not part of L4 v1,
and never a VM substitute.

### 6.5 Why L4 is built now (WP4), and what stays experimental

- The spike ran the whole path without host devices, so the runtime, network, cloud-init and lifecycle
  can be built and tested end to end in the lab harness (`scripts/byoh/test/nokvm/`), with the `dir` driver.
- The three pieces the lab cannot run sit in their own modules, with rhizome specs only. They stay
  UNVERIFIED until L4-T1 in section 13 passes:
  - the `crypt-loop` disk driver
  - AppArmor
  - lxcfs
- Until then the `container` family is **experimental**: hidden, granted per project, and labelled.

## 7. L5: emulation, and options rejected

L5 is QEMU TCG, described in [EMULATED_HOSTS.md](EMULATED_HOSTS.md). Measured (VERIFIED):
- 26-29% of native CPU per vCPU
- about 2.5% of native memory bandwidth
- 64-96 s to boot to SSH
- typical workloads at 5-20% of native

`tb-size` is pinned to 256, which costs about 384 MiB of overhead per VM. ubiblk works under TCG with
`memory-backend-memfd,share=on`. TCG is not a security boundary. L5 stays the last resort, labelled
"Emulated: slow, compatibility only". It now uses the same tier framework as L3 and L4 (`virt_tier = 'emulated'`,
section 9), instead of the separate `vm_host.accel` column that EMULATED_HOSTS.md §6 planned. That
migration was never written, so nothing is renamed.

| Option | Verdict | Why (source, confidence) |
|---|---|---|
| Firecracker, crosvm, Kata, CH on a machine without KVM | No | They all need `/dev/kvm` (high). With PVM (L3), Firecracker (a fork) and Kata work through PVM's `/dev/kvm` |
| Cloud Hypervisor's MSHV backend | No | It needs Linux running as the **root partition** of the Microsoft Hypervisor, with out-of-tree patches and `/dev/mshv` ([CH mshv.md][ch-mshv], high). An Azure or Hyper-V guest is not a root partition |
| User Mode Linux | No | Its kernel runs as a host process: no cloud images, no firmware, its own kernel. Kernel-side SMP only arrived in 6.19 (2025-12) ([LKML][uml-smp], high), and syscalls trap through ptrace or seccomp. It is slower than L4 with no isolation gain over gVisor |
| gVisor as the main no-KVM tier | No | 13× slower syscalls and 5.1× slower fork+exec (VERIFIED), and limited systemd. A possible hardening layer for L4 |
| Automatic nested enablement by Ubicloud | No | It needs provider API calls or hypervisor settings outside the host, which breaks "platform-agnostic". The probe prints the exact fix instead |

## 8. Decision matrix

Scores are relative (5 = best). Speed is against native. "Measured" means VERIFIED here; the rest is SOURCE.

| Rung | Speed (numbers) | Isolation | Workload compatibility | Operational complexity (5 = simplest) | Maintenance risk (5 = lowest) | Use when |
|---|---|---|---|---|---|---|
| L1 bare-metal KVM | 5: ~native (today's product) | 5 | 5 | 5 | 5 | Always, if you can |
| L1 nested KVM | 4: CPU-bound ≥90% (GCP: "10% or greater decrease"); page-table-heavy work up to ~5× slower under contention (PVM paper fig. 2) | 5 for guests, plus the provider's L0 | 5 | 4: pick the instance type, switch nested on | 4: provider offerings change | Cloud VMs that offer it |
| L3 PVM | 4: near single-level KVM for kernel build, SPECjbb and Blogbench at 16-way; syscalls ~1.3× with direct switching; a third party measured 57% of native for a kernel build on m6a | 4: software world switch, little scrutiny, a 2026 shadow-MMU CVE | 3: Linux only, a Ubicloud-supplied kernel, no UEFI, Windows, XFS or AppArmor | 2: custom host kernel, `pti=off`, Secure Boot off | 1: out of tree since 2024; third-party builds | No nested, and VM-level isolation is needed fast |
| L4 system containers | 5: **measured CPU 95-99%, memory 91-98%, SSH in 3.6-5.4 s, 35 MB idle** | 2: shared kernel; idmaps, AppArmor and seccomp help | 3: no custom kernels, modules, swap or GPUs | 3: a new runtime path; the network is unchanged | 4: mainline LXC and kernel | Trusted tenants, dev/test, cheap VPS |
| L4 + gVisor | 2-4: **measured CPU ≈100%, syscalls 13× slower, fork+exec 5.1× slower** | 3 | 2 | 2 | 4 | Untrusted single-service code (later) |
| L5 QEMU TCG | 1: **measured CPU 26-29%, memory bandwidth 2.5%, 64-96 s to SSH** | 1: not a boundary | 4: any x86 image | 4: distro QEMU | 4 | Nothing else possible: demos, CI |

Ranking for "fast on a machine without hardware virtualization":
1. L4: measured near native.
2. L3: near native by its authors' numbers, but unproven here and heavy to operate.
3. L5: last.

For "VM-level isolation without hardware virtualization", L3 is the only option.
Hence the ladder order is L3 above L4: better isolation at close to the same speed. The build order puts both behind
detection, and both stay experimental until their real-infrastructure tests pass.

## 9. Data model and allocator rules

### 9.1 What is detected vs what is declared

| Record | Where | Written by | Meaning | State |
|---|---|---|---|---|
| Probe report | `vm_host.virt_probe jsonb` (`migrate/20261015_vm_host_virt_probe.rb`) | `Prog::LearnVirt`, `bin/byoh-virt refresh` | The facts, the detected tier, the rung, the platform key, the fix and the caveats. Refreshable; **never changes behaviour** | SHIPPED |
| Declared tier | `vm_host.virt_tier text NOT NULL DEFAULT 'kvm'`, CHECK `IN ('kvm','pvm','container','emulated')` | `HostNexus.assemble(virt_tier:)` at registration only | Which backend the host runs. Immutable: changing it means re-registering the host | PLANNED (WP2) |
| Tier/family coupling | CHECK `(virt_tier = 'kvm') = (family NOT IN ('pvm','container','emulated'))` on `vm_host` | the migration | A KVM host never carries a lower-tier family, and vice versa | PLANNED (WP2) |
| Location policy | `location.byoh_virt jsonb`: `{"tiers": ["kvm", ...], "acks": [...], "container_disk": "crypt-loop" or "dir"}`, NULL meaning `{"tiers": ["kvm"]}` | `bin/byoh-location create/set` (each change writes a `byoh_operator_action` row) | Which lower tiers may be offered in this location | PLANNED (WP2) |
| Tier table | `lib/byoh_virt_tiers.rb` (data, like `ByohVirtPlatforms`) | code | Per tier: its families, the probe tiers it accepts, the hypervisor, the PrepHost argument, the label, the required acks, and whether it is experimental | PLANNED (WP2) |

Why `virt_tier` and not `accel`:
- The rhizome QEMU work uses `accel` (`kvm`/`tcg`) as a QEMU accelerator inside a VM's `prep.json`
  (`rhizome/host/lib/vm_setup.rb:28`). It stays there with that meaning.
- The host-level choice is broader than an accelerator: it also covers PVM and containers.
- `vm_host.accel` (EMULATED_HOSTS.md §6) was never applied anywhere, so it is dropped, not renamed.
  The CLAUDE.md §8a rule "never rename an applied migration" is respected.
- "Nested" is a fact in `virt_probe`, not a tier: a nested L1 host runs exactly the L1 code.

The tier table (WP2):

| `virt_tier` | Accepted probe tiers | Families | Guest backend | PrepHost argument | Experimental |
|---|---|---|---|---|---|
| `kvm` | `kvm` | `standard`, `premium`, `burstable` (as today) | CH, or QEMU-KVM for B200/B300 GPUs (`model/metal/vm.rb:91`, unchanged) | none (golden-pinned command) | no |
| `pvm` | `pvm`; or `none`/`pvm_blocked` when `--install-pvm-kernel` is given (the tier is re-checked after the reboot) | `pvm` | CH with direct kernel boot | `pvm` | yes |
| `container` | `none`, `kvm_blocked` | `container` | LXC | `container` | yes |
| `emulated` | `none`, `kvm_blocked` | `emulated` | QEMU TCG | `tcg` (the existing `ARGV[2]` of `rhizome/host/bin/prep_host.rb:28`) | no (but labelled) |

A probe tier of `container` (the data plane is itself a container) is refused for every declared tier.
A probe tier of `kvm` is refused for every lower tier, so a fast host is never wasted on a slow backend
by mistake.

### 9.2 Allocator and placement rules (WP2)

- **R1, tier filter.** `scheduling/allocator.rb` gets an unconditional filter next to the family filter (`:337-338`):
  - `ds.where(Sequel[:vm_host][:virt_tier] => ByohVirtTiers.tier_for_family(vm.family))`
  - Every existing family maps to `kvm`, so every existing allocation keeps its result. Golden specs pin the
    candidate list for a mixed fixture: L1 hosts plus one host of each lower tier.
- **R2, defence in depth.** `Allocation.update_vm` (near `:399`, before the family is copied from the host)
  fails when the host's tier does not serve the VM's family. This covers `force_host_id` and admin "Create VM".
- **R3, location gating.** A lower-tier family is offered only:
  - in a location whose `byoh_virt.tiers` includes its tier
  - to projects granted that location (the existing `bin/byoh-location grant`)
  - as an explicit choice
  
  How the gating is implemented:
  - These families are `visible: false` in `Option::VmFamilies` (`lib/option.rb:220-224`).
  - They reach validation only through `extra_families:` (the mechanism planned for emulated sizes in
    EMULATED_HOSTS.md §6). The options JSON for every non-BYOH project stays byte-identical (golden).
- **R4, mixed locations are allowed.** A location may hold L1 hosts and lower-tier hosts. The family picks
  the tier (R1), so `standard` never lands on a container host, and `container` never lands on a KVM host.
- **R5, internal services stay on L1.** Postgres, Kubernetes, runners and load balancers create VMs with
  L1 families, so R1 already keeps them off lower tiers. A spec pins this for each service's `assemble`.
- **R6, other paths:**
  - `prog/vm/metal/move_vm.rb` refuses a move between tiers.
  - `prog/rollout_rhizome.rb` rolls out per tier.
  - GPUs are refused for every non-`kvm` family.
- **R7, capacity:**
  - Lower tiers have no 1G hugepages. Their memory budget is computed at prep (EMULATED_HOSTS.md §6.4 for L5; cgroup headroom for L4; hugepages are optional for L3) and stored in the existing capacity columns.
  - The overloading of `total_hugepages_1g` as "budget GiB" on those hosts is documented in COMPUTE.md.
  - `accepts_slices = false` on every lower tier.

## 10. Operator experience

### 10.1 Before registration: `bin/byoh-virt probe` (SHIPPED)

It prints the verdict and exits 0 on L1 and 3 otherwise. Example outputs below. The format is
`ByohVirtLadder::Verdict#text` (`lib/byoh_virt_ladder.rb:65`); the values are illustrative and UNVERIFIED
except the container case.

```
# AWS m8i.2xlarge, nested on                         # Proxmox VM with cpu=kvm64 (after the WP1 rung fix)
tier: kvm (L1) nested                                 tier: none (L2)
platform: AWS EC2                                     platform: QEMU/KVM (Proxmox VE, libvirt, KVM VPS)
why: /dev/kvm answers KVM_GET_API_VERSION 12          why: this is a kvm VM whose hypervisor does not expose
caveat: nested virtualization: CPU-bound work ...          hardware virtualization
caveat: the provider may stop or restart this VM ...  fix: Proxmox: qm set <vmid> --cpu host, then stop and
caveat: the clocksource is often not tsc ...               start the VM; the node needs nested=Y ...

# AWS m6i.large (no nested on this family)          # Hetzner Cloud CX22
tier: none (no hardware virtualization)              tier: none (no hardware virtualization)
platform: AWS EC2                                     platform: Hetzner Cloud
fix: Use a .metal instance, or an 8th-generation     fix: Use a Hetzner dedicated server. Without hardware
     Intel instance (C8i, M8i, R8i ...) with ...           virtualization the fallbacks, fastest first, are:
     Without hardware virtualization the fallbacks,        L3 PVM ..., L4 system containers ..., L5 ...
     fastest first, are: L3 PVM ..., L4 ..., L5 ...
ready: container (cgroup2, userns), emulated (qemu, ovmf)   # "ready:" is new in WP1 (probe report v2)

# Bare metal, Intel VT-x off in the firmware          # A Docker or OpenVZ "VPS"  (VERIFIED: container case)
tier: kvm_blocked (L2)                                tier: container (refused)
platform: unknown platform                            why: this is a docker container
why: bare metal without the vmx or svm flag: the      fix: Run the data plane on a VM or bare metal, not in
     firmware has VT-x/AMD-V disabled                      a container.
fix: Enable Intel VT-x or AMD-V (SVM) in the BIOS/UEFI setup, then power the machine off and on.
```

### 10.2 At registration (PLANNED, WP1 and WP2)

`bin/register-byoh-host` runs the same probe over SSH before `HostNexus.assemble`, prints it, and compares it with
`--virt-tier` (default `kvm`):

| Probe | `--virt-tier kvm` (default) | `--virt-tier pvm` | `--virt-tier container` | `--virt-tier emulated` |
|---|---|---|---|---|
| `kvm` | Registers (today's path); caveats printed | Refused: "this host has KVM; register it as kvm" | Refused, same | Refused, same |
| `kvm_blocked`, or `none` on a platform with nested `yes`/`some`/`ask` | **Refused, exit 3, with the fix.** Adds: "or declare a fallback tier: --virt-tier container / emulated" | Refused: "fix KVM instead (fix text)" | Allowed only with `--accept-slower-tier`, after printing the fix | Allowed only with `--accept-slower-tier` |
| `none` on a platform with nested `no`, or an unknown platform | Refused, exit 3; lists the ready fallbacks | Needs `--install-pvm-kernel` | Allowed | Allowed |
| `pvm_blocked` | Refused | Fix: `modprobe kvm_pvm` (printed); or `--install-pvm-kernel` | Allowed | Allowed |
| `pvm` | Refused (PVM hosts cannot run firmware-booted VMs) | Registers | Refused: "register it as pvm" | Refused |
| `container` | Refused | Refused | Refused | Refused |

Also:
- The location must list the declared tier (R3). Otherwise the message names
  `bin/byoh-location set <loc> --virt-tiers kvm,<tier> --accept-...` with that tier's ack flag (section 11).
- `--no-virt-probe` skips the SSH probe when the host is not reachable yet. `Prog::LearnVirt` then checks
  at prep, and `wait_prep` fails with the fix when the probe disagrees with the declared tier.
- `bootstrap-data-plane.sh` keeps its KVM refusal byte for byte by default. `--tier container|emulated|pvm`
  installs that tier's packages (`lxc lxcfs uidmap`; `qemu-system-x86 ovmf`; nothing for pvm) and skips only
  the checks that tier does not need.

### 10.3 After registration

- `bin/byoh-virt show --host vh...` prints both the declared tier and the latest probe.
- A `ByohVirtTier` page opens when the probe disagrees with the declared tier. It resolves when they agree.
- `bin/byoh-virt refresh --host vh...` (or `--all`) re-probes.

## 11. Security policy, labels and billing per rung

| Rung | Customer label (UI and API `family` description) | Who may use it | Host requirements checked at prep | Location ack (`bin/byoh-location set`) | Billing |
|---|---|---|---|---|---|
| L1 | as today | as today | `KvmCheck` (unchanged) | none | today's `standard`/`burstable`/`premium` rates |
| L3 `pvm` | "PVM: software virtualization (experimental). Linux only; Ubicloud supplies the guest kernel." | Granted projects. **One project per location** unless `--accept-multi-tenant-pvm` | `kvm_pvm` loaded, `/dev/kvm` API 12, no vendor KVM module; Meltdown "Not affected" or the ack | `--accept-experimental-pvm` | `pvm` rates per location; `byoh-location rates --family pvm --from standard --multiplier X` (X required) |
| L4 `container` | "System container: shared host kernel, near-native speed. Not a VM." | Granted projects. **One project per location** unless `--accept-shared-kernel-multitenant` | cgroup v2, AppArmor enabled, unprivileged user namespaces allowed, `newuidmap`, lxcfs running, kernel ≥ 5.12 (idmapped mounts) | `--accept-shared-kernel`, plus `--accept-unencrypted-container-disks` for the `dir` driver | `container` rates; they may be lower than `standard` because the overhead is about 35 MB per container |
| L5 `emulated` | "Emulated: slow, compatibility only. Not a security boundary." | Granted projects; single tenant per host by default (EMULATED_HOSTS.md threat model) | QEMU and OVMF present; x86_64 | `--accept-no-guest-isolation` | `emulated` rates with a required multiplier, as EMULATED_HOSTS.md §6 plans |

Applies to every lower rung:
- Its families are hidden (`visible: false`) and never chosen implicitly.
- The VM overview shows the label as a badge with a tooltip.
- `prog/vm/nexus.rb:40` (`Validation.validate_billing_rate("VmVCpu", family, location)`) refuses a VM
  whose family has no rate in that location. `byoh-location set` refuses to add a tier without rates.
  Rates follow the `resource_name` rule in POOL_OPERATIONS.md.
- Every mutation writes a `byoh_operator_action` row. Restart web, respirate and monitor after a rates
  change (CLAUDE.md §8a).

## 12. Rollout

| Phase | WP | What changes for whom | Gate to move on |
|---|---|---|---|
| 0 | done | BYOH hosts are probed at prep; a page explains a host without KVM | SHIPPED, full spec gate green |
| 1 | WP1 | Registration probes first and refuses a non-L1 host with the fix. `bin/byoh-virt refresh --all` back-fills `virt_probe` on existing BYOH hosts | L1-T1, L2-T1..T3 (section 13) on at least one cloud |
| 2 | WP2 | `virt_tier` column; every existing host becomes `kvm` by the column default. No behaviour changes for L1: golden specs | Full gate; the upgrade rehearsal on a copy of the live DB (migrate, `vm_host` row counts, allocator golden) |
| 3 | WP3 | `pvm` tier available, experimental, behind its location ack | L3-T1 and L3-T2 pass on a real cloud VM; otherwise it stays hidden and the docs say UNVERIFIED |
| 4 | WP4 | `container` tier available, experimental | The lab harness passes (dir driver); L4-T1 passes on a real Ubuntu 24.04 host (crypt-loop, AppArmor, lxcfs, escape probes) before the family is granted to anyone outside the operator's own org |
| 5 | WP5 | `emulated` tier end to end | The L5 harness (EMULATED_HOSTS.md WP10 checks) passes |
| 6 | WP6 | Docs final | Every claim labelled; full gate |

Upgrading the live control plane follows the existing window (CLAUDE.md §8):
- Stop the services.
- `pg_dump`.
- Migrate. The `virt_probe` and `virt_tier` columns are additive, and their defaults keep every host on L1.
- `install_rhizome` on every host, which ships `virt-probe`.
- `bin/byoh-virt refresh --all`.

Rollback:
- The WP2 migration's `down` refuses while any host has `virt_tier <> 'kvm'` or any location has `byoh_virt`.
- Before any `down`, run `bin/byoh-host export-audit` (CLAUDE.md §8a).

## 13. Real-infrastructure tests (runnable, all UNVERIFIED)

These need machines the lab cannot provide. Each one is a script to paste; record the results here.
They need `$IP`, `$KEY` and a throwaway machine, and never touch a registered host unless the test says so.

### L1 and L2 (detection; WP1)

```bash
# L1-T1 bare metal with VT on: expect "tier: kvm (L1)", exit 0, no caveats except possibly pdpe1gb
bin/byoh-virt probe --main-ip $IP --ssh-key $KEY; echo exit=$?
# L1-T2 AWS m8i.large with nested virtualization enabled: expect kvm nested, exit 0, the three nested caveats
# L1-T3 GCP n2-standard-4 created with --enable-nested-virtualization: expect kvm nested, platform gcp
# L2-T1 AWS m6i.large (no nested on the family): expect none, platform aws, exit 3, "Use a .metal instance, or an 8th-generation Intel ..."
ssh ubuntu@$IP 'sudo apt-get install -y ruby' && bin/byoh-virt probe --main-ip $IP --user ubuntu --ssh-key $KEY; echo exit=$?
# L2-T2 AWS m8i.large with nested virtualization left off: expect none, platform aws, the same fix (WP1 adds the family sub-rule: "enable the CPU option")
# L2-T3 Proxmox VM with cpu=kvm64: expect none (L2 after WP1), platform qemu_kvm, "qm set <vmid> --cpu host"; after the change and a stop/start: kvm nested
# L2-T4 bare metal with VT-x off in the firmware: expect kvm_blocked, "firmware has VT-x/AMD-V disabled"
# L2-T5 VMware VM without "expose hardware assisted virtualization": expect none, platform vmware
# L2-T6 Hetzner Cloud CX22 / DigitalOcean / Vultr: expect none with that platform's row, the fallbacks listed
# L2-T7 a registered BYOH host: bin/byoh-virt show --host vh...; a ByohVirtTier page exists only when not L1
```

### L3 PVM (WP3)

```bash
# L3-T1 PVM host side + a bare CH guest, on a throwaway Ubuntu 24.04 VM WITHOUT nested virtualization
#   (GCP e2-standard-4 or AWS m6i.large), Secure Boot OFF. Not a registered host.
grep -cwE 'vmx|svm' /proc/cpuinfo                       # expect 0
R=https://github.com/cocoonstack/pvm/releases/download/v0.1.0
mkdir pvm && cd pvm
for f in SHA256SUMS linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb vmlinux-pvm-amd64; do curl -fLO "$R/$f"; done
sha256sum -c --ignore-missing SHA256SUMS
sudo apt-get install -y ./linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&pti=off /' /etc/default/grub
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.12.33-pvm"/' /etc/default/grub
sudo update-grub && sudo reboot
# after the reboot
uname -r                                                # 6.12.33-pvm
sudo modprobe -r kvm_intel kvm_amd 2>/dev/null; sudo modprobe kvm-pvm && ls -l /dev/kvm
sudo ruby virt_probe.rb                                 # copy of rhizome/host/bin/virt-probe: expect tier: pvm
curl -fLo ch https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v46.0/cloud-hypervisor-static
echo "00b5cf2976847d2f21d2b7266038c8fc40bd14f2a542115055e9e214867edc9e  ch" | sha256sum -c && chmod +x ch
curl -fLO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
sudo apt-get install -y qemu-utils cloud-image-utils
qemu-img convert -O raw noble-server-cloudimg-amd64.img disk.raw
printf '#cloud-config\npassword: ubuntu\nchpasswd: {expire: false}\nssh_pwauth: true\n' > ud && cloud-localds seed.img ud
time sudo ./ch --kernel vmlinux-pvm-amd64 --cmdline "console=ttyS0 root=/dev/vda1 rw" \
  --disk path=disk.raw path=seed.img,readonly=on --serial tty --console off --cpus boot=2 --memory size=2048M
# PASS: a login prompt. In the guest: dmesg | grep -i pvm; sysbench cpu and memory, fio, and
#   `time (for i in $(seq 5000); do /bin/true; done)`. Compare with the host itself.
# L3-T2 (after WP3) the same kind of VM registered with --virt-tier pvm --install-pvm-kernel into a
#   location with --virt-tiers kvm,pvm: the host reaches accepting after one reboot, a pvm-2 VM reaches
#   running, SSH works, and destroy cleans up. Record the time to SSH and the numbers above.
```

### L4 system containers (WP4)

```bash
# L4-T1 a real Ubuntu 24.04 host (any cloud VM without nested), registered with --virt-tier container
#   into a location with --virt-tiers kvm,container --accept-shared-kernel (crypt-loop driver).
# Create a container-2 VM, then on the host:
sudo aa-status | grep -c lxc-container-default            # >= 1: AppArmor confines it
sudo lxc-info -n <vm> -P /vm/<vm>/lxc                      # RUNNING
sudo cryptsetup status <vm>-root | grep -q LUKS2           # disk encrypted at rest
grep -c ' 65536$' /proc/$(pgrep -f "lxc-start.*<vm>")/uid_map   # its own range
# In the guest (as ubi via sudo):
free -g                                                    # shows the size's memory (lxcfs), not the host's
sudo modprobe dummy; echo $?                               # != 0
sudo mount -t proc proc /mnt; echo $?                      # != 0
sudo sh -c 'echo 1 > /proc/sys/kernel/panic'; echo $?      # != 0
ls /dev/kvm /dev/fuse /dev/sda 2>&1 | grep -c 'No such'    # 3
# Two containers on the same host must not see each other's processes, files or traffic (ping the other's private IP: blocked).
# Speed: sysbench cpu/memory, fio and apt-get update in the guest, compared with the host. Expect the 6.1 ratios.
```

### L5 emulated (WP5)

```bash
# L5-T1 the L-Q live gate of EMULATED_HOSTS.md on a host without /dev/kvm, after WP5.
```

## 14. Build plan (sequential on `no-kvm`)

Every WP ends with the full gate, in this order:
1. `coverage_pspec`: 100.0% line and branch; only `db_spec:189,193` and `resource_discount_spec:13` may fail
2. `frozen_pspec`
3. rubocop
4. `rake rhizome_spec`, when `rhizome/` changed
5. `bash -n` and shellcheck on changed scripts

No `:nocov:`. Commits follow COMMIT_MESSAGES.md.

Container tests go in `scripts/byoh/test/nokvm/` and follow these rules:
- containers are named `ubi-q-*`, on `ubi-test-net` only, with no ports
- `--cpuset-cpus=12-15 --cpus=4 --memory=6g`
- only `NET_ADMIN`, `SYS_ADMIN` and `NET_RAW`, `/dev/net/tun`, and AppArmor/seccomp unconfined when needed
- never `--privileged` or `/dev/kvm`
- a `df -h /` guard of 7 GB

The harness asserts these rules with `docker inspect` before each run, and fails closed. The existing
M3 harness in `scripts/byoh/test/` uses `--privileged` for systemd and is not reused.

**U1 proof, kept in every WP.** These golden specs must stay unchanged:
- `rhizome/host/spec/vm_setup_golden_spec.rb`, with the fixtures `ch_unit.service`, `ch_unit_nohugepages.service`, `ch_dnsmasq.service`, `qemu_kvm_hugepages*.service`
- `spec/model/metal/vm_golden_spec.rb` (`params_json_ch*.json`)
- `spec/prog/vm/metal/nexus_golden_spec.rb` (`create_unix_user.sh`)
- `spec/prog/vm/prep_host_golden_spec.rb` (the PrepHost command)
- `spec/lib/validation_golden_spec.rb`
- `spec/routes/api/project/location/vm_size_error_golden_spec.rb`

A WP may add fixtures but never edit these, except for the one U1 repair in WP2.

### WP1: detection that cannot be wrong, at registration (value 1)

Files:
- `rhizome/host/lib/virt_probe.rb`: probe report version 2. The parser accepts 1 and 2.
  - New facts:
    - BIOS evidence from the kernel log (`journalctl -k -b`, falling back to `dmesg`): "VMX (outside TXT) disabled by BIOS", "SVM disabled (by BIOS)", "HYP mode not available", "started at EL1"
    - `vmx_flags` `ept`/`unrestricted_guest`, and the `ept`/`npt` module parameters
    - a functional `KVM_CREATE_VM` check (open, create, close; changes nothing)
    - Secure Boot state
    - `/sys/devices/system/cpu/vulnerabilities/meltdown`
    - cgroup2, AppArmor, `user.max_user_namespaces`, `newuidmap`, `lxc-start`, `lxcfs`
    - `qemu-system-x86_64` and OVMF presence
  - New report key: `ready` (the fallback tiers whose prerequisites are present).
  - Never read `*_serial` or `product_uuid`.
- `lib/byoh_virt_ladder.rb`:
  - The rung for tier `none` comes from the platform's `nested`: `yes`/`some`/`ask` → `L2` ("probably fixable"); `no`/unknown → "no hardware virtualization".
  - The firmware fix says "power the machine off and on".
  - Nested caveats are added for missing EPT/NPT.
  - `Verdict#ready` lists the ready fallbacks.
- `lib/byoh_virt_platforms.rb`: an optional `sub_rules` per row, matched on `product_name`. On AWS the instance type is in the DMI:
  - a listed family (`/\A[cmr][78]i/`, plus `.metal`) → "stop the instance and enable the CPU option nested virtualization"
  - any other family → "move to ..."
- `lib/byoh_registration_cli.rb`, `lib/byoh_registration.rb`:
  - probe over SSH before `assemble`, reusing `ByohVirtLadder.remote_script` (the same session as the existing key handling)
  - print the verdict
  - exit 3 with the fix unless the probe says `kvm`
  - `--no-virt-probe`
  - record the verdict in the `byoh_operator_action` args
- `lib/byoh_virt_cli.rb`: `refresh --all`.
- `prog/learn_virt.rb`: unchanged behaviour. It accepts report v2.

Tests:
- one JSON fixture per row of the section 10.1 table and per platform row (`spec/fixtures/virt/*.json`), each with its expected verdict
- the registration CLI matrix for the `kvm` column of section 10.2
- rhizome specs for each new fact, through `--root` fixture trees (`virt_probe.rb` already reads under a root)
- harness: `scripts/byoh/test/nokvm/run.sh probe` runs the real `virt-probe` in `ubuntu:24.04` and `alpine` and expects `container`; it also runs the fixture trees through the real binary

Done-check:
- the gate
- `bin/byoh-virt explain` on every fixture prints its fix
- the existing `host_nexus_virt_spec` and `learn_virt_spec` still pass unchanged

### WP2: one tier framework, built on the TCG work (value 2)

Files:
- `migrate/20261016_vm_host_virt_tier.rb`:
  - `vm_host.virt_tier`, with its two CHECKs (section 9.1)
  - `location.byoh_virt jsonb`
  - a `down` that refuses while it holds data
  - plus `cache/schema.cache` and the model annotations
- `lib/byoh_virt_tiers.rb`: the tier table (section 9.1) and `tier_for_family`.
- `model/vm_host.rb`: `virt_tier` helpers. `move_to_location` refuses a host into a location that does not list its tier.
- `prog/vm/host_nexus.rb`:
  - `assemble(virt_tier: "kvm")` sets the family from the table
  - `prep` passes the tier to PrepHost
  - `wait_prep` fails with the fix when `virt_probe` disagrees with `virt_tier`
  - hugepage labels are skipped for tiers that do not use them
- `prog/vm/prep_host.rb`: appends the tier argument only when it is not `kvm`. The kvm command stays golden-pinned.
- `rhizome/host/lib/emulated_host.rb` → `rhizome/host/lib/host_tier.rb`:
  - `HostTier.prep_steps(tier)` keys on `kvm`/`pvm`/`container`/`tcg`
  - `EmulatedHost` keeps only the TCG checks
  - `prep_host.rb:28-31` dispatches on the tier
  - `KvmCheck` is unchanged
- `rhizome/host/lib/vm_setup.rb`, U1 repair. Commit f1e99cdaa changed QEMU-KVM without hugepages from `-m` to `memory-backend-memfd,share=on` (`:1070-1082`). Gate the memfd change on `emulated?`, and add the golden fixture `qemu_kvm_nohugepages.service`, generated from 9e22d71ec.
- `model/metal/vm.rb`: `params_json` (`:85`) adds tier keys only for non-kvm hosts. `params_json_ch*.json` stay byte-identical.
- `scheduling/allocator.rb`:
  - R1, the tier filter (`:337`)
  - R2, the `update_vm` guard (`:399`)
  - `host_capacity_summary` takes the tier
- `prog/vm/metal/move_vm.rb`, `prog/rollout_rhizome.rb` and `prog/vm/nexus.rb`: R6.
- `lib/option.rb`: the hidden families `pvm`, `container` and `emulated`, with their sizes (`visible: false`). Their availability in production is gated per tier in later WPs.
- `lib/validation.rb`: `extra_families:`.
- `helpers/vm.rb`, `views/vm/create.erb`, and the API: R3 and the badges.
- `lib/byoh_location_cli.rb`:
  - `create`/`set --virt-tiers` with the acks from section 11
  - `rates --family F --from standard --multiplier X`
  - refuses a tier without rates
- `lib/byoh_registration_cli.rb`:
  - `--virt-tier`, `--accept-slower-tier`, `--install-pvm-kernel`
  - the full matrix of section 10.2
- `scripts/byoh/bootstrap-data-plane.sh`: `--tier`. The default path stays byte for byte.

Tests (new spec files where possible):
- the migration up, down and CHECKs, on `clover_q_test1`
- allocator: a mixed-tier fixture; each family lands only on its tier; `force_host_id` across tiers gives NoSpaceLeft; the candidate list golden for L1
- `MoveVm` and `RolloutRhizome` tier refusals
- options JSON byte-identical for a non-BYOH project
- each `validate_vm_size` caller refuses a hidden family without `extra_families`
- every cell of the registration matrix
- the location CLI acks and rates
- the new QEMU-KVM golden fixture

Done-check:
- the gate
- every pre-existing golden unchanged
- `git diff 9e22d71ec -- rhizome/host/spec/fixtures/golden spec/fixtures/golden` shows only added files

### WP3: PVM (value 3)

Files:
- `rhizome/host/lib/pvm_kernel.rb`: pinned guest and host artifacts (version, URL, sha256 taken from the release's `SHA256SUMS` when the WP is written).
- `rhizome/host/bin/download-pvm-kernel` and `prog/download_pvm_kernel.rb`, modelled on `Prog::DownloadFirmware`.
- `rhizome/host/bin/install-pvm-host-kernel`: the checks and steps of section 5.7. It refuses before any change when a check fails.
- `prog/install_pvm_host_kernel.rb`:
  - budded by HostNexus `prep` only for `virt_tier == "pvm"` with the install option
  - the existing reboot labels boot the new kernel
  - a new `verify_virt_tier` label after `reboot` runs `Prog::LearnVirt` and fails unless the tier is `pvm`
- `rhizome/host/lib/host_tier.rb`: the `pvm` step list. `kvm_check` is replaced by `pvm_check`: `kvm_pvm` loaded, API 12, no vendor module.
- `rhizome/host/lib/vm_setup.rb` `build_ch_service`, when `boot == "pvm"`:
  - `--kernel <vmlinux-pvm>`
  - `--cmdline` from `PVM_ROOT` (a data table per boot image)
  - otherwise the same arguments
- `model/metal/vm.rb`: `boot: "pvm"` and the guest kernel version in `params_json`, for pvm hosts only.
- `prog/vm/nexus.rb`: refuses boot images without a `PVM_ROOT` entry (AlmaLinux, XFS root), and GPUs.

Tests:
- golden `ch_unit.service` unchanged
- new fixture `ch_unit_pvm.service`
- install-script specs with mocked commands, including each refusal (Secure Boot, Meltdown, wrong arch, sha mismatch)
- HostNexus pvm walk: prep → reboot → verify_virt_tier → accepting, plus the failure page
- the download prog

Local e2e (optional, about 140 MB):
- `scripts/byoh/test/nokvm/run.sh pvm-hostside` repeats the spike's host-side proof: QEMU TCG, `insmod kvm-pvm`, `/dev/kvm`, CH creates the VM.
- Guest boot cannot be shown here (section 5.6).

Done-check:
- the gate
- the family stays hidden behind `--accept-experimental-pvm`
- L3-T1 and L3-T2 written up as UNVERIFIED until they run

### WP4: system containers (value 4)

Built in three parts; section 6.5 explains why it is built now and not left at a skeleton.

**WP4a, rhizome runtime:**
- `rhizome/host/lib/container_setup.rb`: prep, start, stop, delete, and the idmap from the unix uid.
- `rhizome/host/lib/container_net.rb`: the veth `script.up` hook, reusing `setup_taps_6`'s address and route code. The tap path stays byte-identical.
- `rhizome/host/lib/container_disk.rb`: the `dir` driver, and the `crypt-loop` driver (WP4c).
- `rhizome/host/bin/setup-vm`: dispatches on the `container` hypervisor (`vm_setup.rb:940-947`).
- `stop-vm`: `lxc-stop`.
- `vm_stats.rb`: cgroup stats.
- cloud-init content factored so the CIDATA image stays byte-identical, with a NoCloud directory writer.
- `rhizome/host/lib/host_tier.rb`: the `container` steps: lxc, lxcfs and uidmap present; AppArmor enabled; `/etc/subuid` entries.

**WP4b, control plane and product:**
- the `container` family and sizes
- `params_json` keys, for container hosts only
- `create_unix_user` without `usermod -G kvm` (`prog/vm/metal/nexus.rb:211`); the kvm heredoc is golden-pinned
- the serial log from `lxc.console.logfile`
- container boot images (`ubuntu-noble-container`, sha-pinned) through `Prog::DownloadBootImage`
- labels, rates, the location acks and the `dir` driver ack
- refusals: GPU, images without a container build

**WP4c, `crypt-loop` disk:**
- LUKS2 with the VM's storage key, ext4, and an idmapped mount
- rhizome specs only. Runtime is UNVERIFIED until L4-T1, because the lab forbids loop and dm devices.

Tests:
- rhizome specs for all of the above
- the golden CH and QEMU units, dnsmasq, and cloud-init ISO unchanged
- `spec/prog/vm/metal/nexus_container_spec.rb`
- harness `scripts/byoh/test/nokvm/run.sh l4`: the spike's container setup, with the **real** `setup-vm prep` of a container VM and the `dir` driver. It checks:
  - SSH as `ubi` within 30 s
  - DHCP, DNS and `apt-get update`
  - the isolation probes of section 6.1
  - two containers cannot reach each other's private IPs, nor `ubi-pg-test`
  - stop, start, restart, and delete twice
  - cgroup metrics
  - nothing left over

Done-check:
- the gate and the harness green
- the disk usage of the harness under 1 GB (rootfs about 640 MB)
- AppArmor, lxcfs and crypt-loop marked UNVERIFIED
- the family experimental

### WP5: finish the TCG rung (value 5)

EMULATED_HOSTS.md / qemu-plan WP5-WP10, recast onto `virt_tier = 'emulated'` (no `accel` column):
- `verify_emulated_capacity` and the memory budget; the timings: the 30-minute deadline and 180 s soft stop
- the `create_unix_user` emulated heredoc
- refusals of the CH and firmware downloads on emulated hosts
- `bootstrap-data-plane.sh --tier emulated`; `EmulatedHost::INSTALL_HINT` and `KVM_AVAILABLE_HINT` updated to name the flags that now exist
- the harness `scripts/byoh/test/nokvm/run.sh l5`, with the checks of qemu-plan WP10: SSH within 420 s, `query-kvm` false, the fd listing, symlink probes, stop timings, delete twice, the RSS measurements that set `EMULATED_VM_OVERHEAD_MIB`

Done-check:
- the gate and the harness
- the unit's hardening directives marked UNVERIFIED at runtime

### WP6: docs and final gate (value 6)

- This file: switch each PLANNED to SHIPPED or VERIFIED as it lands.
- EMULATED_HOSTS.md: header pointer only; its §6 `accel` plan is marked superseded by section 9.
- PLATFORMS.md PF3 (`:160`, `:166`, `:192`): use `ByohVirtLadder`, and add the new PF-V rows for the lower tiers.
- `platforms/README.md:33` and `aws.md:62`: the "Not possible" row becomes "L3/L4/L5 with these trade-offs"; `other-clouds-vps.md:21`.
- TROUBLESHOOTING.md: install phase (each refusal of section 10.2), allocation (a hidden family refused, tier mismatch), runtime (container cgroup2 under netns, lxcfs missing, PVM stall).
- COMPUTE.md: lower-tier capacity and budget.
- ROADMAP.md: an additive row and the dependency on M4 (section 2.3 hook).
- CLAUDE.md: code-map rows and symptom rows.

Done-check:
- the full gate
- every claim labelled
- nothing pushed

## 15. Sources

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
[incus-cloud]: https://discuss.linuxcontainers.org/t/how-to-create-an-unprivileged-container-in-incus/25023
[incus-arch]: https://wikipedia.jakami.de/content/archlinux_en_all_maxi_2026-04/Incus
[cve-idmap]: https://app.opencve.io/cve/CVE-2026-62313
[lxcfs]: https://linuxcontainers.org
[gvisor-platforms]: https://gvisor.dev/docs/architecture_guide/platforms
[gvisor-systrap]: https://gvisor.dev/blog/2023/04/28/systrap-release/
[ch-mshv]: https://git.phyllo.me/External/cloud-hypervisor/src/tag/v42.0/docs/mshv.md
[uml-smp]: https://lkml.iu.edu/2510.3/02642.html

The reference definitions above render as links in the text. They are also the complete list of
external sources for this document.
