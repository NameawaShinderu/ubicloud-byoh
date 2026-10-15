# Emulated hosts (MQ): BYOH VMs on machines without KVM

> This is rung L5, the last resort, of the virtualization ladder in [NO_KVM.md](NO_KVM.md).
> Faster rungs come first: switch KVM on (L2), system containers (L3) and PVM (L4).
>
> Superseded control-plane design: sections 6.1, 6.2, 6.6-6.8 plan a `vm_host.accel` column, an
> `--accel tcg` flag and an `emulated_hosts` location key. None of that was built. The shipped hookup
> uses the tier framework instead (`virt_tier = 'emulated'`, `--virt-tier emulated`, the location's
> `byoh_virt` policy): see NO_KVM.md sections 8.1 and 10. The rhizome side (section 6.5), the security
> model (section 4) and the memory budget (section 6.4) hold as written.

Status: DESIGN (revision 2), 2026-10-15. Branch `qemu-tcg`, starting from `byoh-driver` 9e22d71ec (M0-M3).
File:line references are to 9e22d71ec. Re-read a file before relying on a line number.

Evidence labels:
- **VERIFIED**: executed in the local no-KVM container spike (2026-10-15, see section 3).
- **SOURCE**: read in the QEMU 8.2.2 source, the official docs, or this repository's code.
- **UNVERIFIED**: not executed anywhere. Everything in sections 6 and 7 that describes code not
  yet written is UNVERIFIED until the work package that builds it lands and its gate runs.

## 1. Problem

Every Ubicloud VM runs under Cloud Hypervisor (CH), and CH needs `/dev/kvm`.

A BYOH data plane therefore has to be one of these:
- bare metal
- a cloud VM type with nested virtualization (AWS m8i/c8i/r8i and the other types in section 2, GCP N2/C3 with nested, Azure Dv5/Ev5 with security type Standard)
- a hypervisor guest with `host` CPU passthrough

PrepHost aborts on any other machine (`rhizome/host/bin/prep_host.rb:27-29`, `rhizome/host/lib/kvm_check.rb`), and so does `scripts/byoh/bootstrap-data-plane.sh:54-77`.
`docs/byoh/platforms/README.md:33` lists "Hetzner Cloud, Linode/Akamai, any VPS without `/dev/kvm`" as **Not possible**.

That excludes the cheapest and most common machines:
- AWS m5, m6i, c6i, r6i and the AMD and Graviton non-metal types (T-family types too, but see 6.4)
- GCP E2 and most AMD types
- Azure sizes without nested support
- most VPS offerings

MQ adds an **emulated host** type for those machines. It runs guests under QEMU with TCG (software CPU emulation), so it needs no KVM and no nested virtualization. It is opt-in for each host and each VM, and it is labelled as slower and as no isolation boundary.

**Non-goal:** replacing CH anywhere. A host with KVM keeps CH and behaves byte-for-byte as today (rule U1).

## 2. Options and verdicts

| Option | Works without host KVM? | Verdict |
|---|---|---|
| **QEMU TCG** (this design) | Yes (VERIFIED) | **Build it** as the opt-in "emulated" tier. It runs on any x86_64 Linux machine and keeps ubiblk disk encryption, rhizome networking (netns, tap, nftables, dnsmasq) and cloud-init. Upstream already ships a QEMU backend, so most of the work is adding an `accel` parameter to it. Costs: about a quarter of native CPU speed at best, much slower memory, and no isolation boundary (section 4). |
| Nested-virt instance types: AWS M7i, M7i-flex, M8i, M8id, M8i-flex, C7i, C7i-flex, C8i, C8id, C8i-flex, R7i, R7iz, R8i, R8id, R8i-flex, X8i, I7i, I7ie (SOURCE: AWS nested-virtualization docs); GCP N2/C3/N4D with `--enable-nested-virtualization`; Azure nested sizes | KVM inside the VM | **Preferred wherever it is available.** CH runs at near-native speed and was validated on m8i.2xlarge (CLAUDE.md §10a). Note that **m7i/c7i/r7i support nested virtualization** and should use CH, not MQ. |
| `.metal` / bare metal / colo | Real KVM | Best performance. The cost is the problem (m5d.metal $5.86/h against m8i.2xlarge $0.45/h in ap-south-1; EXTERNAL, UNVERIFIED for the account). |
| PVM (pagetable-based VM; Ant Group/Alibaba RFC "KVM: x86/PVM", 73 patches, LKML 2024-02; SOSP 2023) | Yes, with an out-of-tree host module **and** a PVM-enabled guest kernel | **Superseded by [NO_KVM.md](NO_KVM.md) section 6:** PVM is rung L4 there, built without waiting for mainline but only after the go/no-go boot test L4-T1. The original verdict here was "no for now": not merged in mainline as far as public sources show (UNVERIFIED), custom kernels on every host and every image, and shadow paging that hurts fork-heavy guests. |
| Firecracker, Kata, Cloud Hypervisor | No: all need `/dev/kvm` (Firecracker: "requires read/write access to /dev/kvm") | **No.** |
| gVisor (systrap platform) | Yes, but it is a container sandbox, not a VM: no guest kernel, no cloud images, no block device for ubiblk | **No** for a VM product. It could back a separate "sandboxed container" product later. |
| LXC/Incus "VM-lite" | Yes | **Not as a VM substitute.** It shares the host kernel, cannot run arbitrary images or kernels, and needs all-new storage and image plumbing. It could be a separate "system container" product later; it is out of scope for MQ. |
| QEMU + KVM | Needs KVM | A bonus mode of the same backend (section 6.9), not an answer for hosts without KVM. |

## 3. Measured performance (VERIFIED, local spike)

**Setup:**
- container `ubi-q-spike` with no `--privileged`, no `/dev/kvm` and no `/dev/vhost-net`
- `--cpuset-cpus=12-15 --cpus=4 --memory=6g`
- host CPU AMD Ryzen 7 3800X, kernel 6.8
- QEMU 8.2.2 from Ubuntu 24.04 apt (`1:8.2.2+ds-0ubuntu1.18`), ovmf `2024.02-2ubuntu0.10`
- Ubuntu 24.04 **minimal** cloud image; 2 vCPU guests with 1 GiB

The machine is shared and swap was full during the run, so read every number as ±20%.

**Proof that KVM was not in use:**
- QMP `query-kvm` returned `{"enabled": false, "present": true}`.
- The guest dmesg had no `kvm-clock` lines.
- `systemd-detect-virt` printed `qemu`, and the CPU model was `QEMU TCG CPU version 2.5+`.

| Metric | Result |
|---|---|
| Boot to SSH (first boot, with cloud-init) | 64-96 s with OVMF; 74 s with SeaBIOS; 74 s from a ubiblk disk |
| CPU, `sysbench cpu`, 1 thread | 26-29% of native |
| CPU, 2 threads | 28% of native; MTTCG scales ×1.95 |
| Memory bandwidth, `sysbench memory` | 177 MiB/s against 7.1 GiB/s native (about 2.5%) |
| Disk: vhost-user-blk on ubiblk v0.4.2 (encrypted) | 349 MiB/s sequential write (1M, qd8); 10.9k IOPS 4k random read (qd32) |
| Disk: virtio-blk on qcow2 (comparison only) | 393 MiB/s sequential write; 6.5k IOPS random read |
| `apt-get update` / `apt-get install sysbench fio` | 49 s / 48 s |
| Clean shutdown through QMP `system_powerdown` | 3.7-4.7 s |

The disk numbers stay reasonable because the ubiblk backend runs natively; only the guest driver is emulated.
`sysbench cpu` is the best case for TCG, and `sysbench memory` the worst. Expect typical workloads at roughly **5-25% of native**, that is **typically 4-20× slower, memory-heavy work slower still** (EXTERNAL literature: Linaro measured TCG boots about 8× slower for x86_64 guests; UNVERIFIED here).

**Image caveat:** the spike booted the *minimal* cloud image. The product boots the *server* image that `download_boot_image` fetches. The container gate (WP10) measures the server image; the minimal image is used there only if the disk guard trips, and the log records which. A freshly booted server image keeps the guest busy for minutes after SSH works (snapd seeding, apt-daily); how long under TCG is UNVERIFIED until WP10 measures it.

**Memory overhead is the TCG translation cache:**
- The default `tb-size` is `min(1 GiB, host_physmem/8)` **per VM** (SOURCE `tcg/region.c:761-768`), and it fills up. RssAnon was about 1.15 GiB per VM (VERIFIED).
- With `tb-size=256`, RssAnon was about 340-350 MiB; with `tb-size=128`, about 185 MiB. Boot time stayed inside the noise band in both cases (VERIFIED).
- **Decision:** pin `tb-size=256`. It was tuned for boot and `apt` only; steady-state code-heavy workloads (JVMs, compilers) that churn the translation cache are UNVERIFIED.
- The per-VM host overhead the allocator reserves is set in 6.4 (`EMULATED_VM_OVERHEAD_MIB`); it covers QEMU **and** the per-VM ubiblk backend and dnsmasq.

**Positioning:** dev/test, CI, labs, demos, light services (bots, small web apps, control-plane daemons), and trying Ubicloud on a cheap VM.
It is not for databases, compiles, latency-sensitive services or anything that measures performance.
The guest clocksource is `hpet`, because the TSC is marked unstable under MTTCG (VERIFIED), so programs that read the clock often are slow.

## 4. Security model and product policy

### 4.1 TCG is not a security boundary

QEMU's security policy (https://www.qemu.org/docs/master/system/security.html; text from stable-8.2 `docs/system/security.rst`), verbatim:

> "The non-virtualization use case covers emulation using the Tiny Code Generator (TCG). In principle the TCG and device emulation code used in conjunction with the non-virtualization use case should meet the same security requirements as the virtualization use case. However, for historical reasons much of the non-virtualization use case code was not written with these security requirements in mind.
>
> Bugs affecting the non-virtualization use case are not considered security bugs at this time. Users with non-virtualization use cases must not rely on QEMU to provide guest isolation or any security guarantees."

**Threat model:** a guest that escapes TCG gets code execution as that VM's unix user on the host, inside that VM's network namespace. Everything below exists to keep that blast radius small. None of it turns TCG into a boundary between mutually untrusted tenants.

**What an escape actually reaches** (SOURCE, corrected in revision 2):
- **Packet filtering inside the VM netns does not bind it.** The anti-spoofing rules, the DHCP filter and the per-VM `fw_table` live inside the VM's network namespace (`rhizome/host/lib/vm_setup.rb:516-566`) and match prerouting and forward traffic. An escaped QEMU sends from the namespace's OUTPUT path and bypasses them. Only the host-side ByohEgressNat rules on the `vetho*` interface (and the host's own `host_guard`) still apply to it.
- **Disk encryption does not protect the VM's own disk from its own QEMU.** It protects data at rest and across VMs. The VM's ubiblk backend runs as the same unix user as QEMU, so an escaped QEMU can read that VM's `secrets.toml` and race the KEK FIFO. Other VMs' disks stay protected by their own uids.
- **Writable JIT memory.** The TCG JIT needs memory that is both writable and executable, so `MemoryDenyWriteExecute` cannot be set, which makes post-escape exploitation easier than under CH.
- **Root-trust paths into `/vm/<n>`.** Today `/vm/<n>` is the VM user's home and the VM user owns it. Several root-side operations read or write inside it (`VmPath#write`, `dnsmasq -C`, the `prep.json` parse, the serial-log `tail`), so the VM uid could plant symlinks there. On emulated hosts that directory becomes root-owned (4.2 item 5).
- **Root-trust paths into `/var/storage/<vm>/<idx>`.** `StorageVolume#prep` chowns that directory to the VM uid (`rhizome/host/lib/storage_volume.rb:77-78`), and root still writes inside it: on every storage start `KekPipe#with_kek_pipe` removes `kek.pipe`, `mkfifo`s it and `FileUtils.chown`s it by path (`rhizome/host/lib/kek_pipe.rb:12-14`), and `write_new_file`/`safe_write_to_file` open `<path>.tmp` and `<path>.tmp.lock` as root with `O_CREAT`, following symlinks. A VM-uid process running during a storage start can rename entries in its own directory and redirect that chown or write. Today's flows stop the VM before a storage start (`prog/vm/update_ipv6.rb:15`, host reboot), so the window needs an escaped QEMU that survives its own stop, but it is real. What closes it on emulated hosts is that QEMU cannot write under `/var` at all: `ProtectSystem=strict` (4.2 item 8) is **load-bearing** for this, not optional hardening.

### 4.2 Mitigations (defence in depth)

The policy's own guidance is: "QEMU processes must run as unprivileged users"; "Linux namespaces can be used…"; "Linux seccomp is available via the QEMU `--sandbox` option"; and a monitor "exposed over a UNIX domain socket backend to the local host only".

Items 5-8 apply to **emulated hosts only**. CH hosts are unchanged (U1); the equivalent CH hardening is offered upstream separately.

1. **Per-VM unprivileged user.** This already exists: `User=<vm>` in the unit footer (`rhizome/host/lib/vm_setup.rb:802-810`) and `adduser` per VM (`prog/vm/metal/nexus.rb:194-217`).
   - On emulated hosts the VM user is **not** added to the `kvm` group (`nexus.rb:211`), so it gets no access to `/dev/kvm` or `/dev/vhost-net`.
2. **Network namespace.** This already exists: `NetworkNamespacePath=` in the unit. QEMU owns only its tap. As 4.1 says, the filters inside the namespace do not bind an escaped QEMU; the host-side `vetho*` ByohEgressNat rules do.
3. **seccomp:** `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny` (VERIFIED working).
   - The sandbox kills `-daemonize` ("Bad system call"), so QEMU always runs in the foreground under systemd.
4. **Minimal device model:**
   - `-nodefaults -no-user-config -display none -vga none`; no USB, audio or VGA
   - `romfile=` on every PCI device
   - `-cpu max,-svm,-vmx`, so guests do not try nested KVM on an emulator. Plain `max` exposes `svm` (VERIFIED). QEMU accepted the masked spelling (VERIFIED), but no guest has booted with it yet (UNVERIFIED until WP10).
5. **Root-owned VM directory** (closes the root-trust paths in 4.1):
   - The VM user is created with `adduser --no-create-home`, then `install -d -o root -g <vm> -m 0750 /vm/<n>`. The home is `root:<vm> 0750`.
   - `/vm/<n>/run/` is `<vm>:<vm> 0700` and holds `qmp.sock`.
   - `serial.log` is pre-created as `root:<vm> 0660`. `cloudinit.img` stays owned by the VM user, which is safe because the directory is root-owned.
   - Every root-side read or write path (`VmPath#write`, `dnsmasq -C`, the `prep.json` parse, the serial-log `tail`) now sits in a root-owned directory, so the VM uid cannot plant a symlink there.
   - `metal_fetch_serial_log` additionally runs `sudo -u <vm> tail` on emulated hosts, as defence in depth.
   - `purge` removes `/vm/<n>` explicitly. Whether `deluser --remove-home` removes a root-owned home is UNVERIFIED, so it is not relied on.
6. **QMP** only on a unix socket at `/vm/<n>/run/qmp.sock`, inside the VM user's 0700 `run/` directory. `stop-vm` talks to it safely:
   - It `lstat`s the path first, as root: `run/` must be a directory owned by the VM uid, and `qmp.sock` must be a socket (not a symlink) owned by the VM uid. A VM user of uid or gid 0 is refused.
   - The connect happens in a forked child that drops to the VM uid and gid for good (`setgroups([])`, then `setresgid`, then `setresuid`, then the four ids are read back and checked), so a symlink swapped in after the `lstat` cannot reach another VM's 0700 `run/` (VERIFIED in a container: the dropped child got EACCES on the other VM's socket and connected to its own).
   - One deadline (10 s) covers connect, greeting and commands. Reads are non-blocking and buffered, and a message may be at most 65,536 bytes. Events are skipped; error replies, a reply with the wrong `id`, EOF, non-JSON and oversize messages raise. The parent kills the child if it is still running 5 s after that deadline. A stopped (SIGSTOP) QEMU made the soft stop fail after 10.1 s (VERIFIED, when that failure was still exit 1).
   - ENOENT or ECONNREFUSED (a missing `run/` or socket, or a stale socket after QEMU died) means "already stopped": it prints that and exits 0 (VERIFIED).
   - **Every failure is best effort and exits 0** (`EmulatedStop.run`): a refused path, a QMP timeout or error reply, a killed or failed child, a missing or root VM user. It prints `stop-vm: <reason>; leaving the stop to the hard-stop fallback` on stderr. A nonzero exit would raise `SshError` in `Metal::Nexus#soft_stop`, roll back the `stopping` semaphore and wedge the strand before `hard_stop` (see G4), and an escaped guest can force any of those failures. Exiting 0 keeps the `systemctl stop` fallback reachable whatever the guest does. Specs: `rhizome/host/spec/emulated_stop_spec.rb` (`.run`) and `rhizome/host/spec/stop_vm_spec.rb` (the `bin/stop-vm` contract, including the unchanged CH and QEMU+KVM paths).
7. **Disk access** goes only through the ubiblk vhost-user socket. The backend runs in its own hardened unit (`rhizome/host/lib/storage_volume.rb:177-240`), and QEMU never opens the encrypted data file.
8. **systemd hardening on the QEMU unit** (TCG only), the same class as the ubiblk unit:
   - `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectHome=yes`, `PrivateMounts=yes`
   - `ProtectSystem=strict` with `ReadWritePaths=/vm/<n>`. **Load-bearing** (4.1, `/var/storage/<vm>`): it keeps an escaped QEMU from writing under `/var/storage`, where root chowns and writes by path. It must not be removed at L-Q without a replacement that keeps `/var/storage` read-only for the QEMU unit (`ReadOnlyPaths=/var/storage` or `InaccessiblePaths=` on everything but the vhost-user socket). QEMU still has to `connect()` to the vhost-user socket on that read-only mount, which Linux allows for sockets (UNVERIFIED for this unit until L-Q). Making the storage root `root:<vm>` on emulated hosts, as for `/vm/<n>`, is a possible follow-up.
   - `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`, `ProtectControlGroups=yes`, `ProtectClock=yes`, `ProtectHostname=yes`
   - `ProtectProc=invisible`, `ProcSubset=pid`
   - `RestrictNamespaces=yes`, `RestrictRealtime=yes`, `RestrictSUIDSGID=yes`, `RemoveIPC=yes`, `LockPersonality=yes`
   - `SystemCallArchitectures=native`, `SystemCallFilter=@system-service seccomp`, `SystemCallErrorNumber=EPERM`, `CapabilityBoundingSet=`. `@system-service` does not contain `seccomp()`, which QEMU needs to install its `-sandbox` filter (VERIFIED by expanding the set with `systemd-analyze syscall-filter`, systemd 255 in Ubuntu 24.04). Without it an allow-list kills QEMU with SIGSYS at start. With `SystemCallErrorNumber=EPERM`, any other call outside the set fails instead of killing QEMU.
   - `RestrictAddressFamilies=AF_UNIX` (fallback `AF_UNIX AF_INET AF_INET6` if QEMU 8.2 needs it with a tap netdev; UNVERIFIED), `IPAddressDeny=any`
   - `DevicePolicy=closed` with `DeviceAllow=/dev/net/tun rw`
   - `UMask=0077`, `MemoryMax=<guest MiB + EMULATED_VM_OVERHEAD_MIB>`, `TasksMax=4096`
   - **Not** `MemoryDenyWriteExecute`: the TCG JIT needs W+X memory.
   - The container harness runs `systemd-analyze verify` and `systemd-analyze security --offline=yes` on the generated unit and records the exposure score. WP2 ran both once on the generated `emulated-2` unit (systemd 255): `verify` passes, and the offline exposure level is 1.2 ("OK"). It cannot run systemd itself without `--privileged`, so runtime enforcement is checked only at the live gate L-Q (UNVERIFIED). Each directive that breaks QEMU at L-Q is removed, and the removal is documented, **except** `ProtectSystem=strict`, which may only be swapped for an equivalent (above).
   - `TemporaryFileSystem=/var/storage` with `BindPaths` is deferred: other VMs' storage directories are already per-uid 0700, the VM's **own** storage directory is covered by `ProtectSystem=strict` above, and the mount-namespace interplay with ubiblk socket paths is UNVERIFIED.
9. **Host kernel attack surface:** smaller than under CH, because the KVM ioctl surface is gone.

### 4.3 Product policy

- **Emulated hosts live only in dedicated emulated locations** (`byoh_network.emulated_hosts = true`), and such a location holds **only** emulated hosts:
  - `bin/register-byoh-host` refuses `--accel tcg` into a location without the key, and a KVM host into a location with it.
  - `bin/byoh-host move-location` and `VmHost#move_to_location` (so also the admin "Move to Location" action) apply the same rule.
  - `bin/byoh-location set --emulated-hosts` is refused while KVM hosts are in the location.
- **An emulated location must be hidden;** projects get it through `bin/byoh-location grant`. The operator is asserting that every granted project is trusted at the same level: a private cloud, a team, or a lab.
- **Explicit acknowledgement.** `--accept-no-guest-isolation` is required on `byoh-location create --emulated-hosts` (refused together with `--visible`), `byoh-location set --emulated-hosts`, `register-byoh-host --accel tcg`, and **every** `grant` to an emulated location. The flag is recorded in the `byoh_operator_action` args.
- **Refused while tcg hosts or emulated VMs exist:** `--no-emulated-hosts`, `--unset emulated_hosts`, `--visible`, and `delete` of the location.
- **Not guarded in code, caught by a check:** the admin "Set Feature Flag visible_locations" action and admin edits of `location.visible`. A read-only `m2-checks emulated` gate flags a tcg host in a visible location or in a location without the key, a KVM host in an emulated location, and an emulated VM on a KVM host.
- **Hosts:** an operator registers an emulated host explicitly (`--accel tcg`). **It is never chosen automatically**, even when `/dev/kvm` is missing. `accel` is immutable after registration; switching needs a re-registration.
- **VMs:** a customer opts in per VM by choosing an `emulated-*` size in an emulated location. There is no fallback: a `standard` or `burstable` VM never lands on an emulated host, and an emulated VM never lands on a KVM host. Code enforces that in four places (section 6.7); the database only ties a host's `accel` to its own `family` (section 6.1).
- **Shared L2 is the operator's responsibility.** Because an emulated location serves one trust domain, the onlink proxy-ARP concern stays inside it. That an operator's L2 segment is not shared with other locations' hosts cannot be enforced in code; the docs say so (UNVERIFIED operator responsibility).
- **Labelling** (6.8): the family display name is "Emulated (no hardware virtualization; not an isolation boundary; typically 4-20× slower)", and the UI, API docs and CLI docs say "typically 4-20× slower; memory-heavy work slower still; not an isolation boundary".

## 5. What already exists (upstream QEMU backend)

Upstream commits 37e37caa9 (2025-10-22, "Add QEMU hypervisor support to data plane") and 9f4397cd9 added QEMU for B200/B300 GPU VMs.

| Piece | Where |
|---|---|
| Hypervisor choice | `model/metal/vm.rb:91`: `hypervisor ||= GPU ? "qemu" : "ch"`. It is written to prep.json and read by `rhizome/host/bin/setup-vm:29-36` |
| Unit builder dispatch | `rhizome/host/lib/vm_setup.rb:812-819` → `build_ch_service` (858-916) or `build_qemu_service` (918-994) |
| DB | `migrate/20260828_vm_hypervisor.rb`: table `hypervisor` with `name IN ('ch','qemu')`, and `vm.hypervisor_id`. `prog/learn_hypervisor.rb:19-23` matches `qemu-system-` in the unit |
| Reused unchanged | netns, veth and tap (`vm_setup.rb:265-313`, created `user <vm> multi_queue vnet_hdr`); nftables and ByohEgressNat; dnsmasq unit; cloud-init image (568-714); vhost-user-blk disks; `-serial file:<serial.log>`; unit footer with `User=`, Slice and CPUQuota |

**Gaps in it (all VERIFIED or SOURCE):**

| # | Gap | Where |
|---|---|---|
| G1 | Hard-wired to KVM: `-enable-kvm`, `-machine accel=kvm,type=q35`, `-cpu host[,topoext=on]`. `-cpu host` fails under TCG ("CPU model 'host' requires KVM or HVF", SOURCE `target/i386/cpu.c`) | `vm_setup.rb:949-954`, `qemu_cpu` at 1007 |
| G2 | `-bios /opt/fw/QEMU.fd`, which nothing in the repo installs | `vm_setup.rb:976-978` |
| G3 | Without hugepages it emits plain `-m NG`. vhost-user-blk needs fd-backed shared RAM, so the disk fails ("vhost start failed", and ubiblk exits; VERIFIED) | `vm_setup.rb:946` |
| G4 | No QMP socket. `stop-vm` exits 1 for any non-CH VM, so `soft_stop` raises `SshError` on every QEMU VM. That never reaches the 60 s `hard_stop` fallback: the label runs inside the strand's savepoint (`model/strand.rb`), so the exception rolls back `decr_stop` and `incr_stopping`, and the strand retries the soft stop forever while the VM keeps running (SOURCE). `hard_stop` itself is SIGTERM, which kills QEMU with no guest shutdown (VERIFIED: "terminating on signal 15") | `rhizome/host/bin/stop-vm:23-26`; `prog/vm/metal/nexus.rb:485-545, 806-812` |
| G5 | `VmSetup#initialize` requires CH and its firmware on disk even for QEMU VMs (`CloudHypervisor::Version::INSTALLED` checks `File.exist?`). On a `delete` with no `prep.json`, `setup-vm` defaults to `"ch"` (`setup-vm:20-31`), and `vm_setup.rb:26` then raises through `Version[nil]` on a host without CH | `vm_setup.rb:26-27`; `rhizome/host/lib/cloud_hypervisor.rb:26,48,89` |
| G6 | `vhost=on`, which needs `/dev/vhost-net` (root:kvm 0660) | `vm_setup.rb:958` |
| G7 | On arm64 it renders `qemu-system-aarch64` with `type=q35`, which is wrong for aarch64 | `vm_setup.rb:953,983` |

## 6. Architecture

### 6.1 Host attribute and the family tie

Migration `migrate/20261015_emulated_hosts.rb` (WP5):

```ruby
alter_table(:vm_host) do
  add_column :accel, :text, null: false, default: "kvm"
  add_constraint(:vm_host_accel_check, accel: %w[kvm tcg])
  # A tcg host is always a host of family "emulated", and only tcg hosts are.
  add_constraint(:vm_host_emulated_family_check, Sequel.lit("(accel = 'tcg') = (family = 'emulated')"))
end
```

- `accel` is the **CPU virtualization accelerator** (`kvm|tcg`). The hypervisor is derived: `tcg` → QEMU, `kvm` → CH. If a separate `hypervisor` column is ever added, QEMU+KVM is `(hypervisor=qemu, accel=kvm)`, so no rename is ever needed.
- `VmHost#emulated?` is `accel == "tcg"`.
- Existing rows become `kvm`, and every code path below is gated on `emulated?`, so CH hosts are unchanged.
- **What the CHECK constraint does and does not do (corrected in revision 2):** it ties two columns of one `vm_host` row together, so "a tcg host is always family emulated" holds in the database. It does **not** constrain which VMs land on the host. The VM-to-host rule is enforced in code by four guards (6.7).
- The `down` migration refuses while any `tcg` host exists.
- `accel` is immutable after registration; `bin/byoh-host` says so.

### 6.2 Registration and detection

- `bin/register-byoh-host --accel kvm|tcg` (default `kvm`).
  - `lib/byoh_registration_cli.rb` gains the flag. `lib/byoh_registration.rb` validates it and passes `accel:` to `HostNexus.assemble`, which gains `accel: "kvm"` (`prog/vm/host_nexus.rb:8,39`), forces family `emulated` for `tcg`, and refuses any other family with it.
  - `--accel tcg` is refused unless the location's profile has `emulated_hosts: true`, and `kvm` is refused into such a location (4.3).
  - `--accel tcg` requires `--accept-no-guest-isolation`.
  - The confirmation summary prints a warning block: emulated, slower, no isolation boundary.
- **Detection never switches modes; it only advises:**
  - **Before registration:** `scripts/byoh/bootstrap-data-plane.sh --emulated` (or `UBI_ACCEL=tcg`) skips the `/dev/kvm`, `vmx`/`svm` and `pdpe1gb` refusals, says why, **pre-installs `qemu-system-x86 ovmf`**, prints the swap and T-credit warnings, and suggests KVM if `/dev/kvm` is in fact present.
    - Without the flag, the refusal text gains one line: "or bootstrap with --emulated and register with --accel tcg (slow; not an isolation boundary; docs/byoh/EMULATED_HOSTS.md)".
  - **During prep** (`prep_host.rb` with accel `tcg`): if `/dev/kvm` and `vmx`/`svm` are present, it prints "KVM is available; register without --accel tcg to use cloud-hypervisor" and continues.
  - On a `kvm` host, `KvmCheck`'s abort and its message stay exactly as they are.
- **M4 preflight hooks.** M4 owns `ubicloud-admin host add`, the PF checks, LearnCpu, LearnStorage and the health checks; MQ does not edit them. The hooks M4 must call:
  1. **PF3** (`scripts/byoh/host/ubicloud-host` `pf3_kvm`, plus the verdict in `lib/byoh_host_preflight.rb`): becomes INFO for `tcg` ("KVM not required"), including the kvm64-class CPU model refusal. If KVM is present, the INFO line recommends `kvm`. For `kvm` a failure stays a failure, and its fix text may offer `--accel tcg` if the location allows emulated hosts.
  2. **PF4** (`pf4_pdpe1gb`): skipped for `tcg`, since emulated hosts use no hugepages (6.4).
  3. **PF15** (`PREP_PACKAGES`): adds `qemu-system-x86 ovmf` for `tcg`.
  4. **New PF-Q1:** `uname -m` is `x86_64`. Emulated arm64 is not supported in v1.
  5. **New PF-Q2:** at least 2 physical cores, a memory budget (6.4) above 0, and a warning when swap is configured.
  6. `ubicloud-admin host add --accel` passes straight through to `ByohRegistration(accel:)`.
  7. Unchanged: `KvmCheck` (`kvm_check_parity_spec.rb` holds), LearnCpu, LearnStorage, the health checks and the F5/PF14 clocksource check. TCG does not change the host clocksource; cloud VMs show `kvm-clock` or `xen` whether or not they are emulated hosts, which is F5's existing case.

### 6.3 HostNexus differences (only when `vm_host.emulated?`)

| Label | KVM host (unchanged) | Emulated host |
|---|---|---|
| `prep` (`host_nexus.rb:132-147`) | `Prog::Vm::PrepHost` runs `host/bin/prep_host.rb :ubid :rack_env` | The same prog appends a third argument `tcg`. The KVM command string stays byte-identical (WP1 golden pin) |
| prep_host.rb | KvmCheck abort; CH and firmware download; `apt-get install qemu-utils mtools acl` | A thin dispatcher over `EmulatedHost.prep_steps(accel)`. For `tcg`: abort unless `uname -m` is x86_64; skip the KvmCheck abort and the CH and firmware downloads; **verify, never install**: `dpkg-query -W qemu-system-x86 ovmf` and `qemu-system-x86_64 -accel help` listing `tcg`, otherwise abort with "run bootstrap-data-plane.sh --emulated (or apt-get install qemu-system-x86 ovmf)". Running no `apt` keeps the step far below respirate's ~89 s apoptosis clamp. Global sysctls, irdma, needrestart and timezone steps are unchanged. A spec pins the `kvm` step list to today's statement order |
| `wait_prep` (`:153-188`) | `accepts_slices = os == ubuntu-24.04` | `accepts_slices = false`; the LearnCpu-result reaper (in host_nexus, not M4-owned) also sets `used_cores = 1`, which reserves one core for ubiblk, dnsmasq and sshd. A dedicated slice books `memory_gib_for_vcpus` at 4 GiB per vCPU (`scheduling/allocator.rb:118-126,643`), which would waste a small host's budget; the VMs run in `system.slice` with `CPUQuota` |
| `setup_hugepages` (`:194-198`) | `push Prog::SetupHugepages` (GRUB, `pdpe1gb`) | `hop_setup_storage_backend`. No GRUB edit, no `pdpe1gb` needed |
| `setup_storage_backend` | Install vhost-block-backend | The same (VERIFIED: v0.4.2 works under TCG) |
| `prep_reboot` / `reboot` | Real reboot | The same (keeps the flow uniform; the irdma blacklist still applies) |
| `verify_hugepages` (`:295-338`) | Reads 1G hugepages | `hop_verify_emulated_capacity` (new label; 6.4) |
| `start_slices`, `start_vms`, `wait` | — | Unchanged. After a host reboot every emulated VM boots at once (a boot storm); staggering `start_vms` is deferred and documented |

`Prog::DownloadCloudHypervisor` and `Prog::DownloadFirmware`, together with their `VmHost` helpers (`model/vm_host.rb:269-289`), refuse emulated hosts with "emulated hosts run QEMU, not cloud-hypervisor".

`prep_host.rb` (WP4) runs the steps `EmulatedHost.prep_steps(accel)` lists, by name; the accel is its optional third argument and defaults to `kvm`. Facts behind its checks:
- The `kvm` list is the script's original statement order. A spec loads the script with every command and file write recorded and pins the whole trace; the same spec passed against the 9e22d71ec script, so KVM hosts run the same commands, with the same file contents, in the same order (VERIFIED in the rhizome specs).
- The package check reads `dpkg-query -W -f='${Package} ${db:Status-Abbrev}'` and accepts only `ii`. Listing alone is not enough: after `apt-get remove ovmf`, dpkg still lists `ovmf`, with status `un`. VERIFIED in an ubuntu:24.04 container without `/dev/kvm`: before the install both packages are reported missing and `-accel help` fails; after `apt-get install --no-install-recommends qemu-system-x86 ovmf` (8.2.2, ovmf 2024.02) the check passes and `/usr/share/ovmf/OVMF.fd` exists; after removing `ovmf` it is reported missing again.
- `EmulatedHost::BACKEND_RSS_MIB` (ubiblk plus dnsmasq per VM) is a provisional 64 MiB (UNVERIFIED). WP10 measures it, and the WP5/WP7 cross-spec checks `EMULATED_VM_OVERHEAD_MIB` against it.
- The tcg path still writes the global forwarding sysctls, the irdma blacklist and `update-initramfs`, as the kvm path does. The WP10 container harness therefore never runs `prep_host.rb`; it calls `EmulatedHost` directly.

### 6.4 Memory and CPU: no hugepages, a budget in the existing columns

Emulated hosts use **no 1G hugepages**:
- Many cloud VMs and VPSs lack `pdpe1gb` or GRUB control.
- Small hosts cannot afford a fixed reservation.
- The TB cache lives outside guest RAM anyway.

Guest RAM is `memory-backend-memfd,share=on`, which vhost-user needs (VERIFIED). memfd guest RAM is swappable; `bootstrap-data-plane.sh --emulated` and the guides warn about swap, and the capacity label logs `SwapTotal`. `prealloc=on` is not used in v1, because touching all guest RAM under TCG lengthens every boot and the budget already prevents overcommit.

`verify_emulated_capacity` (new label) reads `/proc/meminfo` and computes, in MiB unless named otherwise:

```
usable_mib = (MemTotal_MiB - HugePages_Total * Hugepagesize_MiB) * 42 / 43
max_vms    = total_cpus / 2                       # the smallest emulated size has 2 vCPUs
budget_gib = floor((usable_mib - EMULATED_HOST_RESERVE_MIB - EMULATED_VM_OVERHEAD_MIB * max_vms) / 1024)   # never below 0
total_hugepages_1g = budget_gib
used_hugepages_1g  = sum(memory_gib of active VMs)
```

- It fails on unparseable meminfo; with "Insufficient memory left for the host OS" if MemAvailable < 2 GiB (the same rule as `verify_hugepages`); with "emulated hosts need at least 2 physical cores" if `total_cores < 2` (so a 1-core T-type is refused); and with "Not enough memory budget for VMs" if `used > total`. It takes `lock!` before updating the columns, like `verify_hugepages`.
- If `HugePages_Total > 0`, it logs "remove the hugepage reservation to reclaim N GiB".
- `EMULATED_HOST_RESERVE_MIB = 2048`. It differs from COMPUTE.md's Flexible-tier 4 GiB because these hosts run no SPDK and no hugepage pools; a 4 GiB reserve would leave an 8 GiB VPS with no capacity. M5 reconciles the two.
- `EMULATED_VM_OVERHEAD_MIB` is charged **per VM** (not per core) and covers QEMU (`TB_SIZE_MIB` 256 plus ~90 MiB measured), the per-VM ubiblk backend RSS and the per-VM dnsmasq RSS, plus 15% headroom. **Provisional value: 512.** WP10 measures ubiblk and dnsmasq RSS for `emulated-2` and `emulated-4` and sets the final value. A cross-spec asserts `EMULATED_VM_OVERHEAD_MIB >= QemuTcg::TB_SIZE_MIB + 128 + EmulatedHost::BACKEND_RSS_MIB`, reading the rhizome constants from the rhizome files so the two sides cannot drift.

**The allocator needs no memory change.** It already books `vm.memory_gib` against `total_hugepages_1g - used_hugepages_1g` (`scheduling/allocator.rb:266-294,412`), and destroy releases it (`prog/vm/metal/nexus.rb:704`).
On an emulated host the columns mean "guest RAM budget in GiB". The admin page labels them that way only if a display hook exists; otherwise this doc is the reference.
This overlaps with the COMPUTE.md Flexible tier (M5): when M5 lands a general memory budget, MQ moves onto it.

**CPU:** each TCG vCPU is a host thread that runs flat out while the guest is busy (MTTCG; VERIFIED one thread per vCPU). Cores are accounted as today (vCPUs ÷ threads per core), with **no overcommit** in v1, and `used_cores` starts at 1 (the reserved core, 6.3). The sum of `CPUQuota = vCPUs × 100%` is therefore capped at `total_cores − 1` cores' worth of threads, which leaves a core's worth of CPU time for ubiblk, dnsmasq, sshd and SSH. Throttling stalls under `CPUQuota` (RCU stalls in the guest) are UNVERIFIED, because the container harness's systemctl stub has no cgroups; L-Q measures them.

**T-family burstable instances are demo only:** TCG burns CPU credits continuously, which on unlimited mode costs money.

Worked examples (UNVERIFIED on real instances; MemTotal assumed at about 96% of the nominal size; SMT hosts have 2 threads per core, so an `emulated-2` takes 1 core and an `emulated-4` 2 cores):

| Host | Cores (threads) | Budget | Cores for VMs | Fits |
|---|---|---|---|---|
| c6i.xlarge (8 GiB) | 2 (4) | 4 GiB | 1 | 1 × emulated-2 (core-bound) |
| m6i.xlarge (16 GiB) | 2 (4) | 12 GiB | 1 | 1 × emulated-2 (core-bound) |
| m6i.2xlarge (32 GiB) | 4 (8) | 26 GiB | 3 | 3 × emulated-2, or 1 × emulated-4 + 1 × emulated-2 |
| m6i.4xlarge (64 GiB) | 8 (16) | 54 GiB | 7 | 7 × emulated-2 |
| 4-vCPU VPS, no SMT (8 GiB) | 4 (4) | 4 GiB | 3 | 1 × emulated-2 (core-bound: 2 cores each) |

### 6.5 Rhizome: the QEMU unit with `accel`

`VmSetup.new(..., accel: nil)` raises on any value other than `nil`, `kvm` or `tcg`; `setup-vm` passes `params["accel"]`. That key is absent on every KVM host.

When `@hypervisor == "qemu"` and `@accel == "tcg"`, `build_qemu_service` emits the following. This is the spike's VERIFIED argv, apart from the items marked UNVERIFIED.

```
ExecStartPre=/usr/bin/rm -f /vm/<n>/run/qmp.sock
ExecStart=qemu-system-x86_64 \
-name <vm> -nodefaults -no-user-config \
-bios /usr/share/ovmf/OVMF.fd \
-object memory-backend-memfd,id=mem0,size=<M>G,share=on \  # hugetlb memfd when hugepages: true
-numa node,memdev=mem0 \
-m <M>G \
-smp cpus=..,maxcpus=..,threads=..,cores=..,dies=..,sockets=.. \
-cpu max,-svm,-vmx \                                         # spelling accepted; guest boot UNVERIFIED
-machine q35 \
-accel tcg,thread=multi,tb-size=256 \                        # never also "-machine accel=": QEMU rejects both together
-chardev socket,id=vhostblk0,path=<vhost.sock>,server=off \
-device vhost-user-blk-pci,chardev=vhostblk0,num-queues=..,queue-size=..,romfile= \
-drive if=none,file=<cloudinit.img>,format=raw,readonly=on,id=cidrive -device virtio-blk-pci,drive=cidrive,romfile= \
-netdev tap,id=net0,ifname=<tap>,script=no,downscript=no,queues=<2n+1>,vhost=off \
-device virtio-net-pci,mac=..,netdev=net0,mq=on,romfile= \
-device virtio-rng-pci \
-serial file:/vm/<n>/serial.log -display none -vga none \
-qmp unix:/vm/<n>/run/qmp.sock,server=on,wait=off \
-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
KillSignal=SIGTERM
TimeoutStopSec=30s
<hardening lines from 4.2 item 8>
```

Notes on the argv:
- `queues=2n+1` is kept from the KVM builder: the spike booted with `queues=5` for 2 vCPUs (VERIFIED). Correcting it to the pair count is a later clean-up, and it would change the KVM unit too.
- `vhost=off`: in-kernel vhost-net under TCG is UNVERIFIED, and the emulator is the bottleneck anyway.
- `TB_SIZE_MIB = 256` is a rhizome constant (`rhizome/host/lib/qemu_tcg.rb`), not a prep.json key.
- arm64 TCG raises "emulated hosts support x86_64 only" (gap G7 stays as it is for KVM).

**Emulated-host directory layout** (`prep` when `accel == "tcg"`; 4.2 item 5): the protection against the VM uid replacing `run/`, `serial.log`, `prep.json` or `dnsmasq.conf` comes only from the root-owned `root:<vm> 0750` home that WP7's `create_unix_user` makes. WP2 does not assume it: `check_emulated_home` makes `prep`, `recreate-unpersisted` and `reassign-ip6` of a tcg VM fail before any change unless `lstat` of `/vm/<n>` shows a real directory owned by uid 0 with no group or world write bit, so tcg VMs cannot start before WP7 lands. Then `install -d` of `run/` as `<vm> 0700` (refused if `run/` exists and is not a real directory); `serial.log` created as `root:<vm> 0660` only when absent, and otherwise kept (refused unless a regular file) with its owner and mode reset by `chown`/`chmod`, so a prep re-run while QEMU is already running never swaps the visible file out from under it; `purge` removes the home explicitly with `rm -rf --one-file-system`, which does not follow symlinks. It does so for a tcg VM, and also for any root-owned home. That second case covers a delete whose `prep.json` is already gone; CH homes are owned by the VM user, so it never fires on CH hosts.

**Changes outside the TCG branch:**
- **G5:** the CH binary and firmware are no longer looked up in `VmSetup#initialize`. A CH VM looks them up at the start of every non-delete action (`prep`, `recreate_unpersisted`, `reassign_ip6`, `restart`, `install_systemd_unit`), so those still fail with the same messages before any host state changes. A QEMU VM never looks them up, and the delete actions do not either. The CH unit text is unchanged. A `delete` with no `prep.json` on a host without CH now succeeds.
- **G3:** the shared memfd backend is used only for emulated VMs. Commit f1e99cdaa had also given it to **QEMU+KVM** without hugepages; that broke U1 and was reverted in WP2 of the ladder plan (`docs/byoh/NO_KVM.md`), so QEMU+KVM without hugepages emits plain `-m NG` again, exactly as upstream (golden `qemu_kvm_nohugepages.service`). Its vhost-user disk still fails to start there, as upstream; no production caller passes `hugepages: false` for QEMU+KVM. The CH builder and both QEMU+KVM units stay byte-identical, which the golden fixtures prove.
- `VmPath` gains `run_dir` and `qmp_sock` under it (`rhizome/host/lib/vm_path.rb:57`).
- `vm_stats` sets `with_memory: true` (plus RssAnon) when prep.json has `accel == "tcg"`; CH output is unchanged (`rhizome/host/lib/vm_stats.rb:20`).

**Stop:**
- `rhizome/host/bin/stop-vm` gets a branch for `hypervisor == "qemu"` with `accel == "tcg"` only. It calls `rhizome/host/lib/emulated_stop.rb`, which runs `QmpClient` (`rhizome/host/lib/qmp_client.rb`: `qmp_capabilities` then `system_powerdown`, events skipped, errors, timeouts, EOF and oversize replies raised) with the checks from 4.2 item 6, and always exits 0, so the stop window still ends in `hard_stop` when the soft stop fails (4.2 item 6).
- Today's QEMU+KVM GPU VMs keep the current message and exit 1. The CH branch is unchanged.
- The `stopped` label's fallback to `hard_stop` is 60 s on KVM hosts (unchanged) and **180 s** on emulated hosts. The guest shut down in 4 s (VERIFIED, idle); a guest under `stress-ng` load is measured in WP10.

**Exit-reason diagnosis** (`prog/vm/metal/nexus.rb:583-640`):
- QEMU exits with Result=`success` both on guest poweroff and on `systemctl stop`, so a guest poweroff is logged as "VM stopped by operator".
- v1 adds, only for VMs on emulated hosts, a journal grep for `terminating on signal`: with it the operator stopped the VM, without it the guest shut itself down. **It only picks the log message.** It never pages and never affects billing.

### 6.6 Control-plane VM path

- **`Metal::Vm#params_json`** (`model/metal/vm.rb:85-127`): when `vm_host.emulated?`, force `hypervisor = "qemu"` and `hugepages = false` before the hash is built, then add `params[:accel] = "tcg"` after it, using the same pattern as `byoh_host` (`:124`). For every other host the JSON is byte-identical (WP1 golden spec). Because the value comes from `vm_host`, `prog/vm/update_ipv6.rb:54` is covered too.
- **`create_unix_user`** (`prog/vm/metal/nexus.rb:194-217`): on emulated hosts, the heredoc omits `usermod -a -G kvm` and creates the root-owned home (4.2 item 5). The KVM heredoc is unchanged (WP1 golden pin).
- **Timings, only when `host.emulated?`** (CH values stay byte-identical, WP1 pins):
  - the start→`wait` deadline is 30 min (today `register_deadline("wait", 10 * 60)`, `nexus.rb:185`);
  - `NETNS_PROBE_SECONDS` is 28 min (today 8 min, `nexus.rb:22`);
  - the soft-stop window is 180 s (today 60 s, `nexus.rb:514`).
- **PCI and GPU:** emulated hosts have no vfio. The allocator's `non_gpu` filter already applies when `gpu_count` is 0. `Vm::Nexus.assemble` refuses `gpu_count > 0` with an `emulated-*` size.
- **LearnHypervisor:** it already records `qemu`. The accelerator is read from the host.
- **Unsupported, each with a clear error:**
  - **Resize/hotplug:** no metal VM resize exists today (no route or prog). COMPUTE.md's balloon controller (`ch-remote`, M11) must refuse emulated VMs with "resize and ballooning are not available for emulated VMs; recreate with a larger size".
  - **Services** (Postgres, Kubernetes, MinIO, VictoriaMetrics, inference endpoints, load-balancer VMs, GitHub runners, VM pools): they never request family `emulated`, `validate_vm_size` refuses emulated sizes for them (6.8), and the allocator guards keep them off emulated hosts (6.7).
  - MinIO net-thread pinning (`rhizome/host/lib/vm_net_pinner.rb`) is CH-only and stays that way.

### 6.7 Allocator and the placement guards

**Family isolation** already exists for normal placement: `family_filter = [vm.family]` (`prog/vm/metal/nexus.rb:138`; `scheduling/allocator.rb:337-338`). But `metal/nexus.rb:115` sends an **empty** family filter together with `force_host_id`, and `allocator.rb:399` copies the host's family onto the VM. So family alone does not stop a forced placement.

The VM-to-host rule ("an emulated VM only on a tcg host, every other VM only on a kvm host") is enforced by four guards:
1. **Allocator filter**, applied unconditionally, including under `force_host_id`, in `CandidateHosts#hosts`:
   `apply_filter(:accel) { ds = ds.where(Sequel[:vm_host][:accel] => (request.family == "emulated") ? "tcg" : "kvm") }`.
   - The block must **reassign** `ds`, like every other filter there (`allocator.rb:317-366`): `apply_filter` (`:183-187`) only records the dataset the block returns, so a block that just returns `ds.where(…)` adds a diagnostic count and filters nothing.
   - `request.family` is `vm.family` (`Request#family`, filled at `allocator.rb:60`); `vm` itself is not in scope in `CandidateHosts`.
   The same predicate goes into `host_capacity_summary` (`prog/vm/metal/nexus.rb:53-80`). For every existing host and VM the predicate is true, so placement is unchanged.
2. **`update_vm` guard** in the class method `Scheduling::Allocator::Allocation.update_vm` (`allocator.rb:389`), which `Allocation#update` (`:429-436`) calls for every placement: it fails with `NoSpaceLeft, "host accel does not match vm family"` when `(vm.family == "emulated") != vm_host.emulated?`. The check runs **before** `update_args[:family] = vm_host.family` (`:399`), in the same savepoint that sets `vm_host_id`.
   - It must **not** go in `VmHostSliceAllocation#update` (`:584`). That runs only when `request.use_slices && candidate_host[:accepts_slices]` (`:416`), and emulated hosts set `accepts_slices = false`, so a guard there would never run on them.
   - The WP7 spec places a VM on a host with `accepts_slices = false`.
3. **`MoveVm.assemble`** (`prog/vm/metal/move_vm.rb:10-18`, which has no such check today) fails with "VmHost accel does not match Vm" **before** it calls `Prog::Vm::Nexus.assemble`. The path that reaches it is a standard VM sent to a tcg host: the standard size validates, so only this guard stops it, and its spec uses that path.
   - **Moving an emulated VM is unsupported in v1.** `MoveVm` re-creates the VM with `size: vm.display_size` (`move_vm.rb:27-31`) and no `extra_families`, so `validate_vm_size` would refuse it with an unrelated size error. `MoveVm.assemble` therefore refuses `vm.family == "emulated"` first with "moving emulated VMs is not supported", and the operator docs say so.
4. **`VmHost#move_to_location`** refuses a tcg host into a location whose profile lacks `emulated_hosts?` and a kvm host into one that has it, which also covers the admin "Move to Location" action.

**Other paths that force a host** (`force_host_id`) and how each treats emulated hosts:
- **`Prog::RolloutRhizome`** (`prog/rollout_rhizome.rb:10-25, 90-100`) picks initial hosts by free cores, hugepages and IPv4, then forces a default-size (standard) VM onto each one. Guard 1 would refuse that VM on a tcg host, and the rollout would wait at `wait_vms_on_initial_hosts` forever. The rollout host query therefore adds `.where(accel: "kvm")`. Emulated hosts get new rhizome through the ordinary per-host install, not as rollout canaries. (Today the hugepage condition usually excludes them anyway, but hugepages are optional there, not absent.)
- **Admin "Create VM" on a host** (`clover_admin.rb:1050`) calls `Vm::Nexus.assemble(size:, force_host_id:)` with no `extra_families`. On an emulated host it passes `extra_families: ["emulated"]` and offers only `emulated-*` sizes in the size select; on every other host the action is unchanged (U1).
- **`MoveVm`**: see guard 3.

A BEFORE UPDATE trigger on `vm.vm_host_id` was considered and rejected: the guards above run in the transaction that sets `vm_host_id` and are specced, while a trigger on `vm` fires on every non-BYOH VM update (a U1 and performance risk for no additional coverage).

**Slices:** emulated hosts set `accepts_slices = false`. Placement then takes the `accepts_slices=false` branch at `allocator.rb:416` (`if request.use_slices && candidate_host[:accepts_slices]`), which keeps the plain host allocations; `use_slices` itself (`allocator.rb:61`) is unchanged.

**Memory:** see 6.4 (no change).

### 6.8 Customer opt-in, labels, billing

- **`lib/option.rb:220-238`:**
  - A family `VmFamily.new(name: "emulated", display_name: "Emulated (no hardware virtualization; not an isolation boundary; typically 4-20× slower)", …)` inside the existing literal, with `visible: false`. The display name carries the caveat into the API and CLI.
  - Sizes `emulated-2` (2 vCPU, 2 GiB, storage 20/40) and `emulated-4` (4 vCPU, 4 GiB, 40/80): x64 only, `visible: false`, `cpu_percent_limit` = vCPUs × 100, `cpu_burst_percent_limit` 0, and `vring_workers(it)` like the other entries.
  - The 1 GiB per vCPU ratio fits small hosts (the minimal Ubuntu image runs in 1 GiB; VERIFIED).
- **`Validation.validate_vm_size(size, arch, only_visible: false, extra_families: [])` always excludes family `emulated` unless it is listed in `extra_families`.**
  - The error text ("Available sizes: …") of all 12 existing callers is therefore unchanged (U1): `helpers/vm.rb:121`, `prog/vm/nexus.rb:39`, `helpers/kubernetes_cluster.rb:12,57`, `routes/project/location/kubernetes_cluster.rb:168`, `lib/github.rb:54`, `prog/vm/vm_pool.rb:55`, `prog/minio/minio_cluster_nexus.rb:21`, `prog/victoria_metrics/victoria_metrics_resource_nexus.rb:17`, `prog/ai/inference_endpoint_nexus.rb:53`, `model/project.rb:231`, and `validate_vm_storage_size` (`lib/validation.rb:116`). Kubernetes, MinIO, VictoriaMetrics, inference, GitHub runners and VM pools can never take an emulated size.
  - Only the `Vm::Nexus.assemble` path, when called from `helpers/vm.rb` for an emulated location, passes `extra_families: ["emulated"]`.
- **An emulated location offers only the emulated family.** Under 4.3 it never has KVM hosts, so `helpers/vm.rb` (form options) offers only `emulated` sizes there, and the API returns 400 for `standard` or `burstable` in an emulated location and for emulated sizes anywhere else. This is gated on the profile key, so other locations are unchanged (U1).
- **`views/vm/create.erb:6`** filters on `visible` today; it uses the same family filter, so `emulated-*` sizes are **enabled** in a gated location. A route spec covers this.
- **UI:**
  - Help text: "Runs without hardware virtualization on hosts that lack KVM. Typically 4-20× slower; memory-heavy work slower still. Not an isolation boundary between tenants; offered only in private locations."
  - The VM overview shows an "Emulated" badge with the same text as a tooltip when `vm.family == "emulated"`.
  - API and CLI docs carry the same wording.
- **Billing:**
  - `Vm::Nexus.assemble` checks the rate up front with `Validation.validate_billing_rate("VmVCpu", vm_size.family, location.name)` (`prog/vm/nexus.rb:40`), so a missing emulated rate is a validation error at create time.
  - `ByohPreflightWarnings` adds `VmVCpu/VmStorage emulated` to the required rate set **only** for locations with `emulated_hosts`. `MINIMUM_RATES` itself is unchanged, so existing locations are unaffected.
  - `bin/byoh-location rates --emulated-from-standard --emulated-multiplier X` writes them from the location's standard rates. **X is required.** Two factors pull in opposite directions: delivered speed (about 0.05-0.3 of a KVM vCPU) argues for a low X, while the 1 GiB per vCPU memory and the per-VM overhead argue for a higher one. The operator decides.
  - The CLI prints the reminder to restart web, respirate and monitor, as for any overlay change (CLAUDE.md §8a).

### 6.9 QEMU+KVM bonus mode (deferred)

Once `accel` is a parameter, a `kvm` QEMU VM is upstream's existing path. It would need:
- a `vm_host.hypervisor` column (`(hypervisor=qemu, accel=kvm)`, see 6.1)
- OVMF instead of `/opt/fw/QEMU.fd`
- QMP for KVM QEMU too, which changes the GPU unit; that is upstream's code, so offer it upstream first

It is useful only where CH misbehaves. It is **not in the MQ gate** and stays UNVERIFIED (no `/dev/kvm` testing allowed here).

### 6.10 Monitoring, serial log, operations

| Feature | Emulated host |
|---|---|
| VM pulse (`model/vm.rb:282-298`, `systemctl is-active`) | Unchanged |
| Host monitor | Unchanged. F5/PF14 apply to cloud VMs as they do to any nested host |
| Serial log (`model/metal/vm.rb:249-251`) | Same `serial.log` path (VERIFIED), read with `sudo -u <vm> tail` on emulated hosts (4.2 item 5). QEMU truncates it only on process start, not on an in-guest reboot (ROADMAP V1) |
| Stop / start / restart | QMP powerdown (180 s window) / `systemctl start` / `setup-vm restart` (a hard systemd restart, the same as CH) |
| Delete | `systemctl stop` + `setup-vm delete`; works with no `prep.json` and no CH installed (G5) |
| Metrics (`vm-stats`) | Reports QEMU RSS (RssAnon) for tcg VMs; CH output unchanged |
| Console (M6) | A second QEMU chardev is simpler than CH's. M6 decides |

## 7. Rollout and gates

1. **Code gate** (every WP): the full Ruby gate with 100% line and branch coverage, frozen specs, rubocop, rhizome specs, shellcheck. The WP1 golden fixtures (CH units, QEMU+KVM unit, CH `params_json`, PrepHost command, `create_unix_user` heredoc) and the WP1 pins (timings; `validate_vm_size` errors) must pass unchanged from WP2 on. The size-error pin computes the list from `Option::VmSizes` without family `emulated`, so an upstream merge that adds or renames a size does not break it, but an emulated size leaking into any caller does.
2. **Container gate** (`scripts/byoh/test/qemu/run.sh all`, WP10). In an `ubi-q-*` container with no `--privileged`, no `/dev/kvm` and no `/dev/vhost-net`, the **real** `host/bin/setup-vm prep` boots an `emulated-2` VM under TCG from the server cloud image, with ubiblk encryption, rhizome networking (including the real ByohEgressNat config) and cloud-init. It then checks:
   - SSH within 420 s, DNS and egress (`apt-get update`, timed); the guest cannot reach the test database
   - `query-kvm` enabled=false, no `/dev/kvm` among QEMU's file descriptors, guest `systemd-detect-virt` = `qemu`, no `svm`/`vmx` flags (proves `-cpu max,-svm,-vmx` boots)
   - `systemd-analyze verify` and `security --offline=yes` on the unit, with the score recorded
   - the symlink probes from 4.2 items 5 and 6
   - stop through the real `stop-vm` (QMP) idle and under load, start (data persists), restart, and delete twice (the second without `prep.json`), after which the netns, user, home and storage are gone
   - RSS of QEMU, ubiblk and dnsmasq for `emulated-2` and `emulated-4` (sets `EMULATED_VM_OVERHEAD_MIB`), idle CPU, and two concurrent boots under `--cpus=2` (checks the 30-min deadline)
   - Only host-global steps are stubbed: systemd, hugepages, PrepHost global sysctls, reboot. If the net procfs setup needs `--privileged`, that line of testing stops and is reported.
   - Docker's default seccomp profile is always kept. If `ip netns` or the net procfs bind needs `apparmor=unconfined` (docker-default denies `mount`), the run is reported as "CAP_SYS_ADMIN without AppArmor", never as unprivileged, and the fail-closed `docker inspect` check asserts `SecurityOpt` holds nothing else.
3. **Live gate L-Q (UNVERIFIED, operator window, never run from this workflow):**
   - Machine: a **non-nested** x86_64 machine (AWS m6i.xlarge or c6i.xlarge, or any non-nested x86_64 VPS) with Ubuntu 24.04 and at least a 100 GiB data volume at `/var/storage`. Check that `/dev/kvm` is absent.
   - Bootstrap: `bootstrap-data-plane.sh --emulated`.
   - Location: `bin/byoh-location create --name <loc> ... --emulated-hosts --accept-no-guest-isolation` (hidden), then `rates --emulated-from-standard --emulated-multiplier X`, and restart web, respirate and monitor.
   - Register with the same commands as any host plus `--accel tcg --accept-no-guest-isolation`.
   - Expect `accepting` in about 5-10 minutes, including one reboot (UNVERIFIED).
   - Grant a project (with the ack flag) and create an `emulated-2` VM with IPv4 from the pool.
   - Check: SSH over the pool address, DNS, `apt-get update`, stop/start/restart/delete, the serial log, billing records, and QMP `query-kvm` false.
   - Check the systemd hardening at runtime: the unit starts, and `systemd-analyze security <vm>` is recorded; also check `CPUQuota` throttling for guest RCU stalls.
   - A `standard-2` create in the same location must fail with a 400.
   - Stop (not terminate) the instance afterwards.
4. **Docs before release:** the ROADMAP MQ track, additive PLATFORMS rows (PF-Q1, PF-Q2, and an "emulated" note next to #18, F9 and PF3), the platform guides (aws, gcp-azure, other-clouds-vps, README chooser) with price/performance tables that say emulated mode wins **only** where nested virtualization is unavailable (the strongest case is a VPS without `/dev/kvm`: Hetzner Cloud, Linode, GCP E2, Azure B-series, quota-bound fleets; not AWS regions that offer m7i or m8i), T-types listed as "demo only; unlimited-mode credit cost", the 100 GiB data-volume minimum, TROUBLESHOOTING, COMPUTE, and CLAUDE.md.

## 8. Work packages (summary)

The full plan, with files, tests and done-checks, is in the MQ section of `docs/byoh/ROADMAP.md`, added in WP11.

| WP | Scope |
|---|---|
| WP1 | This document; golden specs that freeze today's CH and QEMU+KVM units, the CH `params_json`, the PrepHost command, the `create_unix_user` heredoc, the VM timings and the `validate_vm_size` messages |
| WP2 | Rhizome: `accel`, the TCG unit and its hardening, the memfd fix, the `run/` layout, lazy CH lookup, `vm_stats` RSS |
| WP3 | Rhizome: `QmpClient`, `EmulatedStop`, the `stop-vm` TCG branch |
| WP4 | Rhizome: `prep_host.rb` tcg mode (`EmulatedHost` lib; verify packages, never install) |
| WP5 | Migration `vm_host.accel` plus the family tie; model (`emulated?`, constants, `move_to_location`); schema cache |
| WP6 | HostNexus: PrepHost argument, skip hugepages, `verify_emulated_capacity`, `accepts_slices=false` and the reserved core, refuse CH download progs |
| WP7 | VM path: `params_json`, `create_unix_user`, timings, the four placement guards, exit-diagnosis label, GPU refusal |
| WP8 | Location, registration and host CLIs (dedicated locations, ack flag, rates), preflight warnings, `m2-checks emulated`, bootstrap `--emulated` |
| WP9 | Product surface: family and sizes, `extra_families`, gated form/API, labels, badge |
| WP10 | Container e2e harness `scripts/byoh/test/qemu/` |
| WP11 | Docs, CLAUDE.md, M4 hook note; final full gate |
