# The virtualization ladder: fast first, emulation last

Status: 2026-10-15, branch `no-kvm` (from `byoh-driver` 9e22d71ec plus the QEMU-TCG work).
Labels used throughout:
- **SHIPPED**: code on this branch, covered by the spec gate.
- **VERIFIED**: executed here (the shared lab machine, AMD Ryzen 7 3800X, kernel 6.8).
- **SOURCE**: read in a cited document, with a confidence (high, medium, low).
- **UNVERIFIED**: not executed anywhere. Every real-infrastructure test in section 8 is UNVERIFIED.

## 1. The short answer

Every fast VM monitor needs KVM: Cloud Hypervisor (what Ubicloud runs), Firecracker, crosvm, Kata's
Dragonball and QEMU-KVM all open `/dev/kvm`. On a machine without KVM the only way to stay fast is
to **get KVM back**. You can do that in three ways: switch it on, use nested virtualization, or use
PVM, which provides KVM in software. Only when all three are impossible do you fall back, first to
a shared-kernel container and last to QEMU's emulator.

| Rung | The machine | What runs the guests | Speed vs native | Isolation | State |
|---|---|---|---|---|---|
| **L1** | `/dev/kvm` works (bare metal, or a VM with nested virtualization) | Cloud Hypervisor, exactly as today | ~95-100% on bare metal; nested typically 90% for CPU, less for page-fault-heavy work | Hardware VM | SHIPPED (today's product); detection SHIPPED |
| **L2** | The hardware can virtualize, but KVM is off or not exposed | nothing until fixed | n/a | n/a | Detection and the per-platform fix SHIPPED |
| **L3** | No hardware virtualization; a PVM host kernel (`kvm_pvm`) | Cloud Hypervisor on PVM's `/dev/kvm`, PVM guest kernel | Near L1 for CPU, close to or better than nested for memory-heavy work (SOSP'23); I/O close to KVM | VM, with a software world switch | Detection SHIPPED; running VMs is design only (section 5) |
| **L4** | No hardware virtualization, stock kernel | Unprivileged system containers (LXC/Incus-style), optionally gVisor | ~native | Shared kernel: weaker than a VM | Design only (section 6) |
| **L5** | Anything x86_64 | QEMU TCG (software CPU) | 5-30% (VERIFIED: CPU 26-29%, memory bandwidth ~2.5%) | Not a security boundary | Rhizome side on this branch; control plane not wired ([EMULATED_HOSTS.md](EMULATED_HOSTS.md)) |

Rules, carried over from U1 and the M2 contract:
- An L1 host behaves byte for byte as today. The ladder only adds a read-only probe, a record and a page.
- A host never falls down the ladder by itself. A lower rung is used only on a host the operator
  **declared** for that rung, and only for projects and VMs that **opted in** to its labelled family.
  Nothing falls back silently.
- No cloud-specific code path. Platforms are rows in `lib/byoh_virt_platforms.rb`, and their
  remediation is text in that table and in section 4.

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

UNVERIFIED: a real L1 bare-metal host, a nested VM, a PVM host, and the cloud VMs in section 8.

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

### 5.6 What Ubicloud would need (design, UNVERIFIED)

The detection exists: tiers `pvm` and `pvm_blocked`. To run VMs:
1. A PVM guest kernel artifact, versioned like CH and firmware (`config.rb`), downloaded at prep.
2. **Direct kernel boot.** Ubicloud boots cloud images through firmware (`hypervisor-fw`/CLOUDHV),
   which starts the image's own kernel. That kernel is not PVM-enabled, so a PVM VM must boot the
   PVM kernel with `--kernel` and `--cmdline root=...` (no UEFI, no Windows). In the CH unit that is
   a new `pvm` variant, gated by host tier exactly like the TCG unit (golden specs keep the L1 unit byte-identical).
3. Kernel modules: the image's `/lib/modules` will not match the PVM kernel. Use a module-free
   guest config (as cocoonstack does) or ship a modules overlay. Anything that needs the image's
   own kernel (DKMS, custom kernels, kexec) does not work.
4. A `pvm` instance family, opt-in and labelled "PVM: software-assisted virtualization; custom
   guest kernel", with its own billing rates. Allocation filters on host tier, like the emulated family.
5. Hosts: the operator installs a PVM host kernel. Ubicloud does not build kernels; the docs point to the artifacts in 5.2 with a checksum pin.

Recommendation: build L3 **after** L5 is wired end to end, and only if an operator needs it. It is
the only fast path on clouds without nested, but it costs two out-of-tree kernels.

## 6. L4: system containers (design, UNVERIFIED)

The near-native rung for any machine. The trade-off: one shared host kernel.

Shape (a parallel spike on this branch is measuring it in a `ubi-q-*` container; until its results
land, everything below is UNVERIFIED):
- **Runtime:** LXC (liblxc) driven by rhizome, not a full Incus daemon, to keep one control plane.
  Images: the `images:` cloud variants with cloud-init (`ubuntu/24.04/cloud`), whose default
  account is locked ([discuss.linuxcontainers.org][incus-cloud], medium).
- **Unprivileged with isolated idmaps:** each container gets its own 65,536-id range from
  `/etc/subuid`. That needs about 10M ids for root ([Arch wiki via Incus page][incus-arch], medium). A
  2026 Incus advisory shows a project could escape isolated idmaps by omitting
  `security.idmap.isolated` (CVE-2026-62313, fixed in Incus 7.3.0, [OpenCVE][cve-idmap], medium).
  Lesson: the control plane, not the user, sets the idmap.
- **Hardening:** AppArmor `lxc-container-default-cgns`; LXC's default seccomp (blocks `kexec`,
  `open_by_handle_at`, module loading); no nesting; `lxcfs` so `/proc/meminfo`, `cpuinfo` and
  `uptime` show the container's limits ([linuxcontainers.org][lxcfs], high); cgroup v2 limits:
  `cpu.max` from vCPUs, `memory.max` plus `memory.swap.max=0`, `pids.max`, and `io.max` per disk.
- **Network:** rhizome's per-VM netns stays as it is. The `tap` becomes a veth pair whose inner end
  is moved into the container (`lxc.net.0.type = phys`). nftables, dnsmasq, the anti-spoof rules and
  the egress NAT keep working, because they sit in the netns, not in the guest.
- **Disk:** a raw image on a loop device, opened through dm-crypt with the per-VM key, then ext4.
  That keeps encryption at rest and the "disk size" product. ubiblk (vhost-user) does not apply,
  since there is no virtio. A plain directory would be simpler but has no quota or encryption.
- **What cannot work:** custom kernels and kernel modules, `modprobe`, `sysctl`s outside the
  namespace, kernel-version-specific software, Docker-in-the-container without nesting, nested
  virtualization, non-Linux images, `swapon`, iptables-legacy with modules the host has not loaded,
  and FUSE without `/dev/fuse`. Serial console means `lxc-console`.
- **gVisor as hardening:** `runsc` with the systrap platform (the default since mid-2023) needs no
  KVM ([gVisor platforms][gvisor-platforms], high; [Systrap release][gvisor-systrap], high). It
  intercepts syscalls with seccomp `SECCOMP_RET_TRAP`, which costs a lot for syscall-heavy work.
  Third parties report 50-100%+ overhead for Redis and databases (low). systemd as PID 1 under
  gVisor is limited, so it suits a "sandboxed app" product better than a VM-like one. Verdict:
  optional hardening for a later container product, not for L4 v1.
- **Product:** a separate opt-in family, "System container: shared kernel, near-native speed, not a
  VM", with its own rates. Never offered for workloads that assume VM isolation (Kubernetes nodes,
  runners), the same rule as `extra_families` for emulated sizes.

## 7. L5: emulation, and options rejected

L5 is QEMU TCG: [EMULATED_HOSTS.md](EMULATED_HOSTS.md). Measured at 26-29% of native CPU per vCPU,
about 2.5% of native memory bandwidth, and 64-96 s to boot to SSH (VERIFIED). It is not a security
boundary. It stays the last resort, labelled "Emulated: slow, compatibility only".

| Option | Verdict | Why (source, confidence) |
|---|---|---|
| Firecracker, crosvm, Kata, CH on a machine without KVM | No | They all need `/dev/kvm` (high). With PVM (L3), Firecracker and Kata work through PVM's `/dev/kvm`. |
| Cloud Hypervisor's MSHV backend | No | It needs Linux running as the **root partition** of the Microsoft Hypervisor, with out-of-tree patches and `/dev/mshv` ([CH mshv.md][ch-mshv], high). An Azure or Hyper-V guest is not a root partition. |
| User Mode Linux | No | Its kernel runs as a host process: no cloud images, no firmware, its own kernel. Kernel-side SMP only arrived in 6.19 (2025-12) ([LKML][uml-smp], high), and syscalls trap through ptrace or seccomp. It is slower than L4 with no isolation gain over gVisor. |
| gVisor as the main no-KVM tier | No | It is not a VM, and support for systemd as PID 1 is limited. It is a possible hardening layer for L4. |

## 8. Decision matrix

Scores are relative (5 = best). Speed is against native.

| Rung | Speed | Isolation | Workload compatibility | Operational complexity (5 = simplest) | Maintenance risk (5 = lowest) | Use when |
|---|---|---|---|---|---|---|
| L1 bare metal KVM | 5 (~native) | 5 | 5 | 5 | 5 | Always, if you can |
| L1 nested KVM | 4 (≥90% CPU; page-fault-heavy work much worse) | 5 for guests, plus the provider's L0 | 5 | 4 (pick the instance type) | 4 (provider offerings change) | Cloud VMs that offer it |
| L3 PVM | 4 (near nested; slower syscalls and forks; I/O near KVM) | 4 (software world switch, little scrutiny) | 3 (Linux only, PVM kernel, no UEFI or Windows) | 2 (custom host and guest kernels) | 1 (out of tree since 2024) | No nested and you need VM-like isolation fast |
| L4 system containers | 5 (~native) | 2 (shared kernel; idmap, AppArmor, seccomp help) | 3 (no custom kernels or modules) | 3 (new runtime path, same network) | 4 (mainline LXC) | Trusted tenants, dev/test, cheap VPS |
| L4 + gVisor | 2-4 (depends on syscall rate) | 3 | 2 | 2 | 4 | Untrusted code that tolerates gVisor |
| L5 QEMU TCG | 1 (5-30%) | 1 (not a boundary) | 4 (any x86 image) | 4 (on this branch) | 4 (distro QEMU) | Nothing else possible; demos, CI |

## 9. Real-infrastructure tests (runnable, all UNVERIFIED)

These need machines this lab cannot provide. Each is a script to paste. Record the results in this section.

```bash
# T1 AWS without nested (expect none, platform aws): an m6i.large, Ubuntu 24.04
ssh ubuntu@$IP 'sudo apt-get install -y ruby' && bin/byoh-virt probe --main-ip $IP --user ubuntu --ssh-key $KEY; echo exit=$?   # expect exit=3, "fix: Use a .metal instance, or an 8th-generation Intel ..."
# T2 AWS with nested (expect kvm nested): an m8i.large with nested virtualization enabled
bin/byoh-virt probe --main-ip $IP --ssh-key $KEY; echo exit=$?   # expect exit=0 and the three nested caveats
# T3 a VPS (Hetzner Cloud CX22, DigitalOcean, Vultr): expect none with that platform's row
# T4 bare metal with VT-x disabled in the firmware: expect kvm_blocked "firmware has VT-x/AMD-V disabled"
# T5 a Proxmox VM with CPU type kvm64: expect kvm_blocked or none (platform qemu_kvm); after --cpu host: kvm nested
# T6 a PVM host (cocoonstack or CubeSandbox host kernel on a GCP E2 or AWS m6i):
#    before modprobe: pvm_blocked; after modprobe kvm_pvm: pvm, and the page names L3 as unsupported
# T7 a registered BYOH host in each state: bin/byoh-virt show --host vh...; a page ByohVirtTier exists only when not L1
```

## 10. Sources

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
