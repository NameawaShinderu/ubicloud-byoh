# BYOH platforms: compatibility and host preflight

This page answers two questions:
1. Will a given machine work as a BYOH data-plane host (VmHost)?
2. Which known bugs block which platforms, and where is each fix planned?

Readers: operators deciding where to run a host, and developers fixing the gaps.

Base: branch `byoh-driver` at e6f5e328e. `origin/main:` means upstream Ubicloud. Line numbers are hints; re-read the file before relying on one.

## Tags

| Tag | Meaning |
|---|---|
| **[TODAY]** | True of the code or the live deployment now |
| **[FIXED &lt;commit&gt;]** | Fixed by a commit already on `byoh-driver` |
| **[PLANNED NET-Pn]** | Owned by phase *n* of the networking plan ([NETWORKING.md](NETWORKING.md) §14, where it is written `Pn`) |
| **[PLANNED CMP-Pn]** | Owned by phase *n* of the compute plan ([COMPUTE.md](COMPUTE.md) §12, where it is written `Pn`) |
| **[PLANNED F*n*]** | Owned by this page's fix group F*n* (section 5), with no networking or compute phase |
| **UNVERIFIED** | Not proven in code or on a live host |

Preflight checks are numbered **PF1–PF21** on this page so they do not clash with phase numbers. They are the checks P1–P21 of the portability plan.

Networking and compute rules are not repeated here. Where a finding belongs to one of those designs, this page names the phase and stops. [ROADMAP.md](ROADMAP.md) §3 says which milestone (M0-M12) carries each phase and fix group.

See also: [ROADMAP.md](ROADMAP.md) · [NETWORKING.md](NETWORKING.md) · [COMPUTE.md](COMPUTE.md) · [QUICKSTART.md](QUICKSTART.md).

---

## 1. Hard requirements

These are the rules a host must meet **today**. The right-hand column shows how a planned change relaxes or tightens the rule.

| Requirement | How to check | Why (code) | Changes later |
|---|---|---|---|
| Ubuntu 24.04, x86_64 or aarch64 | `lsb_release -rs`; `uname -m` | `wait_prep` sets `accepts_slices = (os == "ubuntu-24.04")`; LearnOs | none |
| KVM present | `test -c /dev/kvm` and `vmx` or `svm` in `/proc/cpuinfo` | cloud-hypervisor needs it. **Nothing checks it today** (`rhizome/host/bin/prep_host.rb`), so a KVM-less host still reaches `accepting` | prep check [PLANNED F9] |
| 1 GiB hugepage CPU flag (x86) | `grep -qw pdpe1gb /proc/cpuinfo` | dedicated VMs are backed by 1G hugepages (`prog/setup_hugepages.rb:16`) | not needed for a `flexible` profile host [PLANNED CMP-P1] |
| RAM ≥ 14 GiB (16+ recommended) | sum of `dmidecode -t memory` sizes | hugepages = `total_mem_gib*42/43 - 5` (`prog/setup_hugepages.rb:14`); the smallest slice books 8 | `flexible` profile uses 0 hugepages, so smaller hosts become usable [PLANNED CMP-P1] |
| Every DIMM reported in `GB` | `dmidecode -t memory \| grep -E '^\s+Size: [0-9]'` | `fail "BUG: unexpected dmidecode unit" unless $2 == "GB"` (`prog/learn_memory.rb:10`). Proxmox memory must be a multiple of 1024 MiB | accept MB/GB/TB [PLANNED F9] |
| ≥ 2 physical cores **beyond** CPUs 0-1 | `lscpu -e` | CPUs 0-1 are marked `spdk` on every host with ≤ 64 CPUs (`model/vm_host.rb:173-178`, `prog/vm/host_nexus.rb:154-160`), even though SPDK is never installed | generic hosts get 0 IO CPUs [PLANNED CMP-P0 step 3] |
| Uniform threads per core, all CPUs online | `lscpu -Jy -e=CPU,SOCKET,CORE,ONLINE` | `fail "BUG" unless r.zero?` (`model/metal/vm.rb:29-30`); offline CPUs are counted (`prog/learn_cpu.rb:15-23`) | [PLANNED F4] |
| cgroup v2 with `cpuset` | `stat -fc %T /sys/fs/cgroup`; `/sys/fs/cgroup/cgroup.controllers` | VM slices (`rhizome/host/lib/slice_setup.rb`) | none |
| GRUB boot with a `GRUB_CMDLINE_LINUX="..."` line | `/etc/default/grub` | hugepage args are appended with `sed` (`prog/setup_hugepages.rb:16`). The `sed` exits 0 even when nothing matches | [PLANNED F3] |
| `/var/storage` on ext4 or xfs | `findmnt -no FSTYPE --target /var/storage` | btrfs/ZFS make `write_through_device?` raise `ENOENT` on every VM prep (`rhizome/host/lib/storage_volume.rb:470-478`) | rescue [PLANNED F6] |
| Root SSH from the control plane with the registration key | `ssh -o BatchMode=yes root@<host> true` | `bootstrap_rhizome` | none |
| Outbound HTTPS (github.com, cloud-images.ubuntu.com) | `curl -sfI` | PrepHost downloads cloud-hypervisor and htcat; boot images download from the internet | none |
| No other firewall manager on the host | `systemctl is-active docker ufw tailscaled k3s libvirtd` | every reload of `/etc/nftables.conf` (Ubuntu default starts with `flush ruleset`) wipes their rules (`rhizome/host/bin/setup-nftables.rb:42-50`) | [PLANNED NET-P2] with `host_guard` (milestone M7); fix not designed yet |
| Pool IPs delivered to the host but **not** configured on it | `ip -br -4 addr` shows only the host's own address | if the host owns a pool IP, it answers for the VM | networking contract C5 [PLANNED NET-P2] |

---

## 2. Per-platform notes

"Network shape" uses the `delivery` + `exposure` terms from `docs/byoh/NETWORKING.md` §3. Networking setup steps for each platform live there (§9), not here.

| Platform | Status [TODAY] | Compute / KVM | Disk and health checks | Network shape (see NETWORKING §9) | Blockers today | Fix hint on failure |
|---|---|---|---|---|---|---|
| **AWS, nested virt (m8i/c8i/r8i)** | **Validated** in ap-south-1 (m8i.2xlarge: host `accepting` in ~4 min, VM create/destroy, reboot recovery, EIP ingress, egress, DNS) | `cpu_options.nested_virtualization = "enabled"`, AWS provider ≥ 6 [FIXED 003f2800d] | EBS has only `nvme-Amazon_Elastic_Block_Store_*` by-id links. IO limits now fall back to the path [FIXED e6f5e328e]. Health checks still resolve a bogus device and fail SMART and clocksource checks: **do not start `bin/monitor`** until F5 | `fabric` + `nat` (ENI secondary IP + EIP) | UI shows the 10.98.x address, not the EIP (NH-5) [PLANNED NET-P1]; IMDS hop limit absent [PLANNED NET-P2] | use an m8i/c8i/r8i type with nested virt, or `.metal` |
| **AWS `.metal`** (m5d.metal) | Validated earlier (tag `aws-mumbai-working-v1`) | native VT-x | Instance store NVMe has `nvme-eui` links; EBS root as above. Extra instance-store disks are ignored (STOR-3) | as above | as above | — |
| **AWS without terraform** (`aws-routed-network-setup.sh`) | **Broken** | — | — | as above | cloud-init puts pool IPs back on the NIC at the bootstrap reboot (OPS-5). The script is retired at NET L10 | use `terraform/aws-byoh` |
| **GCP** | UNVERIFIED (never run) | `--enable-nested-virtualization` (N2/C3) | PD disks: same by-id and SMART caveats as EBS | `routed` (protocol forwarding) + `public`, or alias `fabric` + `internal` (NETWORKING §9.7) | same as AWS nested; guest agent must not add pool IPs locally | `gcloud ... --enable-nested-virtualization` |
| **Azure** | UNVERIFIED (never run) | Dv3/Ev3 or newer with nested virt | same caveats as EBS (UNVERIFIED) | `fabric` + `nat`; IPv6 `ula` (NETWORKING §9.8) | same as AWS nested | pick a nested-virt-capable size |
| **Proxmox guest** | Supported with caveats; the automated deploy scripts are broken (below) | CPU type `host` (gives `vmx` and `pdpe1gb`). Memory a multiple of 1024 MiB (OPS-16) | virtio `vd*` disks have no by-id link or SMART: do not start `bin/monitor` until F5. **Never mount a new disk over `/var/storage` after registration** (OPS-9) | `onlink` + `internal` (no public block) or `onlink` + `nat` (pfSense 1:1). One NIC on vmbr1; Proxmox NIC firewall / ipfilter off (UNVERIFIED default) | `04-register-host.sh` sets `accepts_slices=false` on **every** host (OPS-1) and cannot SSH ctrl→data (OPS-11) | `qm set <id> --cpu host` |
| **Homelab mini PC / desktop** | Supported if the CPU is not hybrid | Enable VT-x/AMD-V in BIOS. Intel 12th-14th gen and Core Ultra (P+E cores) fail every VM with `BUG` (HW-6/VR-3) | SATA/NVMe usually have `wwn-`/`nvme-eui` links. Ubuntu's default LVM root has only `dm-uuid` links: IO limits work [FIXED b13872889], health checks do not (F5) | `onlink` + `internal`, `routed` via router static route, or the tunnel recipe (NETWORKING §9.3-9.4) | hybrid CPU; an NVIDIA GPU with IOMMU removes the host from normal placement (VR-4); Docker/Tailscale rules get flushed (NH-6) | disable E-cores or SMT in BIOS; bind the GPU to `vfio-pci`; stop other firewall managers |
| **Bare metal, rented** (Hetzner, OVH, Leaseweb) | Supported (upstream's native shape) | native | `wwn-`/`nvme-eui` links and SMART work. Mount extra disks at `/var/storage/devices/<name>` (`UUID=` in fstab) **before** registration (STOR-3) | `routed` + `public`; OVH routed mode only; vSwitch is `onlink` (NETWORKING §9.5) | management IP inside a declared block is self-blocking (NH-1) [PLANNED NET-P0/P1] | enable VT-x/AMD-V |
| **Colo with BGP / static routes** | Supported (UNVERIFIED end to end) | native | as bare metal | `routed` + `public`, a per-host block and a routed /64 (NETWORKING §9.6). FRR on the host is operator-owned | as bare metal | — |
| **SMT off (`nosmt`) or offlined CPUs** | **Not supported** | offline CPUs are counted (HW-7/VR-8) | — | — | wrong totals, `BUG`, slices marked down | boot with SMT on [PLANNED F4] |
| **Any host also running Docker, ufw, Tailscale, k3s, libvirt** | **Not recommended** | — | — | — | `flush ruleset` on VM create/destroy wipes their rules (NH-6) | dedicate the host |

---

## 3. Already fixed on `byoh-driver`

| Commit | What it fixes | Findings it closes | What it does **not** fix |
|---|---|---|---|
| **971a3d608** (backport of upstream 7191118e6) | Per-VM dnsmasq used only IPv6 upstreams, so guests on IPv6-less hosts (AWS VPC, homelab, Proxmox) had no DNS. Now one upstream per family, with a netns SNAT of port-53 traffic to the VM's IPv4 (`rhizome/host/lib/vm_setup.rb:406-407`) | DNS half of NH-3, **for VMs that have an IPv4** | VMs **without** IPv4 still forward only to IPv6 upstreams and have no egress (NH-3) [PLANNED NET-P6]. Existing VMs converge only on recreate. `prog/vnet/update_load_balancer_node.rb` rebuilds the netns NAT without these rules, so adding or removing a VM from a load balancer breaks its DNS again (networking critic, item 1) [PLANNED NET-P2] |
| **003f2800d** | `terraform/aws-byoh`: nested-virt data plane (no `.metal` needed); cloud-init no longer puts ENI secondary IPs on the host NIC (`/etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg`, netplan strip, `ip addr del`) | OPS-5 on the **terraform** path only | the non-terraform `aws-routed-network-setup.sh` path (OPS-5); `systemctl reload ssh` under `set -eu` still runs before the cleanup (`terraform/aws-byoh/user-data-data.sh:29,47`), so a reload failure skips it (OPS-6, UNVERIFIED at runtime) |
| **b13872889** (upstream cherry-pick) | `persistent_device_id` accepts `dm-uuid-` links, so IO limits work on LVM/device-mapper storage | IO-limit prep failure on LVM hosts (not a numbered finding) | health checks on LVM (STOR-1/CP-3) |
| **e6f5e328e** | `persistent_device_id` falls back to the storage path when no stable by-id link exists; systemd resolves the path to the backing disk (`rhizome/host/lib/storage_volume.rb:271-294`). Before this, every VM with IO limits (all burstable sizes) failed `setup-vm prep` with "No persistent device ID found" on EBS, virtio and WWN-less SCSI | IO-limit prep failure on EBS/virtio/SCSI. This is the storage half of F5's last bullet | the control-plane side: `StorageDevice.convert_device_name_to_device_id` (`model/storage_device.rb:24-33`) and the health checks in `model/vm_host.rb:287-294,351-361,393` (STOR-1/CP-3) |

---

## 4. Ranked findings and status

Duplicates are merged; the canonical ID comes first. Severity is for BYOH hosts. "Owner" says which plan fixes it.

| # | Sev | IDs | Where | Platforms hit | Symptom | Owner | Status |
|---|---|---|---|---|---|---|---|
| 1 | blocker | NH-1, OPS-2 | `prog/setup_nftables.rb:7`; `model/address.rb:35`; `lib/byoh_registration.rb:155-164`; `lib/hosting/generic_apis.rb:46` | LAN/Proxmox/homelab, bare-metal /29 that contains the main IP | host IP lands in the blocked set, so SSH from the control plane is dropped; host IP or gateway can be given to a VM | F7 → NET-P0 (upstream host-address exclusion) + NET-P1 (validation, reserved rows) | OPEN |
| 2 | blocker (≤ 2 cores) / major | CP-1, HW-1, VR-1 | `prog/vm/host_nexus.rb:154-160`; `model/vm_host.rb:173`; `scheduling/allocator.rb:511-519`; `prog/vm/metal/nexus.rb:90-91` | all hosts ≤ 64 CPUs; live m8i | `failed to allocate cpus`, VM stuck in `creating`; a 2-core host never places a VM | F1 → CMP-P0 steps 2-3 | OPEN |
| 3 | major | HW-2, CP-2, VR-2 | `scheduling/allocator.rb:214,221,304-305,476-506` | all; 16 GiB hosts after 1 VM | `Sequel::CheckConstraintViolation hugepages_allocation_limit`, VM stuck in `creating` | F2 → CMP-P0 step 4 (with compute critic holes 1-2) | OPEN |
| 4 | major | STOR-1, CP-3 | `model/storage_device.rb:24-33`; `prog/learn_storage.rb:16,35-43`; `model/vm_host.rb:286-296,351-361,383-394` | EBS, PD, virtio, WWN-less sd*, LVM, `/dev/root`; non-tsc guests | once `bin/monitor` runs: `failed smartctl check`, `unexpected clock source`, host flaps to `unavailable` and pages | F5 (must land **before** CMP-P2 starts `bin/monitor`) | PARTLY FIXED (rhizome IO-limit side: b13872889, e6f5e328e) |
| 5 | major | HW-6, VR-3, CP-4 | `model/metal/vm.rb:29-30`; `prog/learn_cpu.rb:15-23` | Intel hybrid (12th-14th gen, Core Ultra) | `RuntimeError "BUG"` at `write_params_json`; every VM stuck | F4. CMP-P1 flexible VMs use topology `1:N:1:1` and avoid this path; dedicated VMs still need F4 | OPEN |
| 6 | major | CP-5 | `scheduling/allocator.rb:135,161-166` | all BYOH; exhausted pool | VM without IPv4 (the default) gets "no space left" | F2 → upstream 02e47743d, via NET-P0 rebase or CMP-P0 step 5 | OPEN |
| 7 | major | NH-3 | `rhizome/host/lib/vm_setup.rb:386` (`return unless ip4`) | all ULA hosts | VM without IPv4 has no internet and no DNS, so apt, cloudflared and tailscale fail | F8.1 → NET-P6 egress-only VMs, pulled forward into milestone M2 | PARTLY FIXED (DNS for VMs **with** IPv4: 971a3d608) |
| 8 | major | NH-4, VR-5 | `prog/vm/metal/nexus.rb:179-198` | NAT/RFC1918 pools; control plane outside the site; VMs without IPv4 | with IPv4: stuck in `wait_sshable`, page at 10 min. Without IPv4: marked `running` with no boot check | F8.2 → NET-P1 (`cp_reach_ip4`), with a host-netns probe fallback for the no-IPv4 case (milestone M2, section 8 item 2) | OPEN |
| 9 | major | NH-5, OPS-8 | `lib/hosting/generic_apis.rb:30-55`; `serializers/vm.rb:15`; `views/vm/overview.erb:17,21` | AWS EIP, GCP/Azure 1:1, pfSense 1:1 | UI shows 10.x and an SSH command that cannot work; the EIP exists only in terraform output | F8.4 → NET-P1 (`external_ip`, `Vm#public_ip4`) | OPEN |
| 10 | major | NH-2 | `rhizome/host/lib/vm_setup.rb:289`; `prog/vnet/rekey_nic_tunnel.rb:74-75` | every host without a routed global /64 | VM-to-VM private traffic times out silently | F8.5 → NET-P4 (same host), NET-P4/P5 (cross host) | OPEN |
| 11 | major | NH-6 | `rhizome/host/bin/setup-nftables.rb:42-50`; `vm_setup.rb:145-146,157` | hosts that also run Docker, ufw, Tailscale, k3s, libvirt | other host firewall and NAT rules wiped on every reload | F7 → NET-P2 with `host_guard` (milestone M7, section 8 item 4); fix not designed yet | OPEN |
| 12 | major | VR-4 | `scheduling/allocator.rb:247`; `prog/learn_pci.rb:13,22` | NVIDIA + IOMMU | host never a candidate for non-GPU VMs; generic "no space" | F9 (backport 2bf64a34c, extend to `generic`) | OPEN |
| 13 | major | OPS-1 | `docs/byoh/deploy-scripts/04-register-host.sh:58-62` | Proxmox low tier | unscoped `update(accepts_slices:false)` makes every burstable request unplaceable on every host | F10 | OPEN |
| 14 | major | OPS-3 | `scripts/byoh/bootstrap-data-plane.sh:121-127`; `bin/register-byoh-host:49,78` | all | host `accepting` with no boot image; every VM gets "no space left" | F10 (default `ubuntu-noble`) + PF20 | OPEN |
| 15 | major | OPS-5, OPS-6 | `scripts/byoh/providers/aws-routed-network-setup.sh:134-150`; `terraform/aws-byoh/user-data-data.sh:29,47` | AWS | pool IPs on the host NIC | F7 + NET L10 (retire the script) + PF17/PF18 | PARTLY FIXED (terraform path: 003f2800d) |
| 16 | major | OPS-11 | `docs/byoh/deploy-scripts/04-register-host.sh:14-22` | Proxmox automated deploy | `Permission denied (publickey)` ctrl→data | F10 | OPEN |
| 17 | major | OPS-14 (+ location) | `bin/register-byoh-host:125-155`; `lib/byoh_registration.rb:51-57`; `prog/vm/host_nexus.rb:6` | all | no host preflight; every host lands in `HETZNER_FSN1_ID` | preflight: F10 (section 6). Location: NET-P1 (`bin/byoh-location`) and CMP-P1 (registration) | OPEN |
| 18 | major/mod | HW-4, VR-6 | `rhizome/host/bin/prep_host.rb` | AWS without nested, GCP without nested, Proxmox `kvm64`, BIOS VT off | host reaches `accepting`; VMs never boot | F9 + PF3 | OPEN |
| 19 | major (small) | HW-8, OPS-12 | `prog/setup_hugepages.rb:14` | hosts under 14 GiB | 0-7 hugepages, host still `accepting`, nothing fits | F3 → CMP-P0 step 5 (upstream MemAvailable clamp) + CMP-P1 (profile) | OPEN |
| 20 | medium | OPS-9 | `docs/byoh/SETUP_PROXMOX.md:2132-2142` | Proxmox disk passthrough | mount hides `/var/storage/images`; capacity stale | F6 (docs) | OPEN |
| 21 | medium | OPS-17 | `scripts/byoh/bootstrap-ctrl-plane.sh:217-242` | all | no `bin/monitor`, no restarter | F10; monitor only after F5 and with compute critic hole 5 resolved | OPEN |
| 22 | minor | HW-3 | `prog/setup_hugepages.rb:16-19` | CPU models without `pdpe1gb`; edited grub | fails late at `verify_hugepages` after a reboot | F3 + PF4/PF5 | OPEN |
| 23 | minor | VR-7 | `prog/setup_hugepages.rb:16` | re-registered hosts; CMP-P1 profile changes | duplicate `hugepages=` tokens | F3 → CMP-P0 step 6 (same as compute critic hole 9) | OPEN |
| 24 | minor/mod | HW-7, VR-8 | `prog/learn_cpu.rb:15-23` | `nosmt`, offlined CPUs | wrong totals, `BUG`, slice `down` | F4 | OPEN |
| 25 | minor | STOR-5 | `rhizome/host/lib/storage_volume.rb:470-478` | btrfs, ZFS | `Errno::ENOENT` on every VM prep | F6 + PF10 | OPEN |
| 26 | minor | STOR-4 | `prog/learn_storage.rb:14-16` | single root FS (live host, Proxmox, homelab) | ENOSPC while the DB shows free space | CMP-P1 physical guard + ballast + 80/85/92% thresholds (supersedes F6's reserve change) | OPEN |
| 27 | minor | STOR-3 | `prog/learn_storage.rb:19` | multi-disk, instance store | extra disks ignored | F6 (`--storage-disk`) | OPEN |
| 28 | minor | STOR-6, CP-6 | `scheduling/allocator.rb:39`; `prog/vm/metal/nexus.rb:90-91` | all | opaque "no space left"; other errors loop | F2 → CMP-P0 steps 2 and 8 | OPEN |
| 29 | minor | HW-5 | `scheduling/allocator.rb:511-519` | x86 SMT | slices span two physical cores | F4 (later: `core_id`) | OPEN |
| 30 | minor | NH-7 | `lib/byoh_registration.rb:104-118` | on-link global /64 | VM IPv6 dead | NET-P0 (`SetupNdpProxy`) + NET-P1 (`--ipv6 <cidr>,ndp`) | OPEN |
| 31 | minor | NH-8 | `rhizome/host/lib/vm_setup.rb:404` | AWS VPC, LANs | VM cannot reach LAN/VPC/control plane | NET-P2 (`@ubicloud_peer4` SNAT exemption) | OPEN |
| 32 | minor | NH-9 | `origin/main:prog/check_ip_reachability.rb` | pools without ICMP egress | after rebase: stuck before `prep` forever | NET-P0 brings it in; NET-P3 extends it (section 8 item 7) | LATENT (rebase hazard) |
| 33 | minor | OPS-4, OPS-7, OPS-10, OPS-13, OPS-15, OPS-16, CP-7 | as cited in each finding | various | hardcoded `fd00:aa55::/64` (2nd host crashes on `vm_host_net6_key`); 10.99 vs 10.98; wrong storage docs; reconfigure destroys VMs before validating; /24 assumption; LearnMemory MB; R2 in production | OPS-4 → NET-P1 (ULA from `ula48`); OPS-13 → NET-P1 (`bin/byoh-pool`); OPS-15 → NET L10; OPS-16 → F9; others → F10 | OPEN |

---

## 5. Fix groups F1-F10 and who owns them

| Fix | Findings | Owner | What this page still adds |
|---|---|---|---|
| **F1** CPU reservation and accounting | #2 | **CMP-P0** step 2 (`NoSpaceLeft` from `select_cpuset`) and step 3 (port upstream 808be1ce6 / e0741bddb, generic `io_cpu_count = 0`, backfill migration) | nothing. CMP-P0 replaces the portability plan's "charge `used_cores` for IO CPUs" with "free the IO CPUs on generic hosts". See section 8 item 1 |
| **F2** Allocator capacity and diagnostics | #3, #6, #28 | **CMP-P0** steps 2, 4, 5, 8 | the CP-5 fix commit is 02e47743d (see section 8 item 6) |
| **F3** Hugepage sizing and minimum host | #19, #22, #23 | **CMP-P0** step 5 (upstream MemAvailable clamp, ≥ 2 GiB check), **CMP-P0** step 6 (idempotent grub tokens via a `/etc/default/grub.d/90-ubicloud-hugepages.cfg` drop-in) and **CMP-P1** (`hugepage_target_1g`, `flexible` profile) | the parts no compute phase lists: require `pdpe1gb` on x86; require the `GRUB_CMDLINE_LINUX` line; clamp at ≥ 0; fail when usable pages < 8 on a `dedicated`/`mixed` host [PLANNED F3]. Must land before any CMP-P1 profile change (compute critic hole 9) |
| **F4** CPU topology learning | #5, #24, #29 | this page | `lscpu -Jy -e=CPU,NODE,SOCKET,CORE,ONLINE`, keep `online == true`; non-uniform threads per core → `total_cores = total_cpus`; VmHostCpu rows for online CPUs only; later `core_id` and sibling groups [PLANNED F4]. CMP-P1 flexible topology `1:N:1:1` avoids the `BUG` for flexible VMs only |
| **F5** Storage identity and health checks | #4 | this page | rhizome side done (b13872889, e6f5e328e). Control-plane side [PLANNED F5]: resolve `/dev/root` with `findmnt`; walk `lsblk -s` to TYPE=disk; by-id preference `wwn-`, `nvme-eui.`, `nvme-<model>_<serial>`, `ata-`/`scsi-`/`virtio-`, bare name; never store `""`; skip SMART when `smart_support.available != true` or the model is "Amazon Elastic Block Store"; accept `tsc` anywhere in the list, or `kvm-clock` on hosts flagged virtual; drop the per-pulse migrate. **Prerequisite for CMP-P2 "start `bin/monitor`".** |
| **F6** Storage safety | #20, #25, #26, #27 | split | CMP-P0 step 7 (LearnStorage refuses to run with volumes) and CMP-P1 (physical guard, ballast, thresholds) replace the "proportional reserve" idea. Still here [PLANNED F6]: `write_through_device?` rescues `SystemCallError` → false; opt-in `--storage-disk <by-id>` that mounts at `/var/storage/devices/<n>` with `UUID=…,nofail`, refuses root/boot/signature-bearing disks, never wipes; fix SETUP_PROXMOX P4 |
| **F7** Host network safety | #1, #11, #15, #32 | **NET-P0** (upstream host-address exclusion in `SetupNftables`, management IP never allocatable), **NET-P1** (registration validation, `reserved` rows), **NET-P2** (`check-pool-not-local`, `host_guard`), **NET L10** (retire `aws-routed-network-setup.sh`) | NH-6 (`flush ruleset`) is assigned to NET-P2 with `host_guard` (section 8 item 4) |
| **F8** VM reachability without a public IP | #7, #8, #9, #10 | 8.1 egress → **NET-P6**; 8.2 readiness → **NET-P1** (`cp_reach_ip4`); 8.4 display → **NET-P1**; 8.5 VM-to-VM → **NET-P4/P5** | 8.3 access: the old Tier 0 `ssh -J root@<host> ubi@<vm-private-ipv4>` does **not** work: the host root namespace has no route to a VM's private IPv4 (`rhizome/host/lib/vm_setup.rb:330-352`). Working operator forms [TODAY]: `ssh -J <host> ubi@<pool IPv4>`, or `ProxyCommand="ssh root@<host> ip netns exec <inhost> nc %h 22"`. Per-host `cloudflared` (old Tier 1) is replaced by the access tunnel (console phase C4, milestone M6); in-guest `cloudflared` (Tier 2) needs egress-only NAT (milestone M2). Browser console → console phases C0-C3 ([ROADMAP.md](ROADMAP.md) §4), not a compute phase |
| **F9** KVM, GPU, memory units | #12, #18, OPS-16 | this page | `prep_host.rb` KVM check (`File.chardev?("/dev/kvm")` + `vmx`/`svm`); LearnPci records only `vfio-pci`-bound GPUs (backport 2bf64a34c, extend to `generic`); LearnMemory accepts kB/MB/GB/TB and sums in MiB [PLANNED F9] |
| **F10** Ops scripts and docs | #13-17, #21, #33 | split | Location → NET-P1 / CMP-P1. Still here [PLANNED F10]: remove the `accepts_slices` hack; default boot image `ubuntu-noble`; the preflight (section 6); systemd units for web, `bin/restarter bin/respirate` and monitor (monitor enabled only after F5); Proxmox key distribution; terraform `host_add_command` output (ROADMAP §6.6); decouple R2 from `RACK_ENV` |

**Order.** CMP-P0 (F1, F2, part of F3) first: it is the most likely reason a second or fourth VM fails on the live host. Then F3 remainder, F9 KVM check and the preflight (cheap, prevent bad hosts). F5 before anything starts `bin/monitor`. Networking items follow NET-P0..P6.

---

## 6. Host preflight

### 6.1 Design [PLANNED F10]

| Entry point | Behaviour |
|---|---|
| `scripts/byoh/host/ubicloud-host preflight [--json]` ([ROADMAP.md](ROADMAP.md) M4; earlier drafts called it `scripts/byoh/preflight-data-plane.sh`) | Runs as root on the host. Read-only. Prints one JSON line per check: `{check, status: pass\|warn\|fail, detail, fix}` |
| `bin/register-byoh-host` (and `ubicloud-admin host add`, which wraps it in M4) | Runs the preflight by default (`--skip-preflight` to opt out). SSHes as root with the registration key, uploads and runs the script, aborts on any `fail` **before** `register!`, and prints the resolved Location |
| `scripts/byoh/bootstrap-data-plane.sh` | Runs the same script at the end |

The networking contract checks (C1-C7, `host_guard`, inbound probes) are **not** part of this preflight. They extend upstream `CheckIpReachability` in NET-P3 and block `accepting` there. PF17 and PF18 below are the subset that can run before registration.

### 6.2 Checks

Each `fail` prints a platform hint: Proxmox `qm set <id> --cpu host`; AWS a nested-virt instance type or `.metal`; GCP `--enable-nested-virtualization`; bare metal "enable VT-x / AMD-V in BIOS".

| # | Check | Command | Pass rule | Fail / warn | Rule changes when | Derived from |
|---|---|---|---|---|---|---|
| PF1 | OS | `lsb_release -rs`; `uname -m` | `24.04`; `x86_64` or `aarch64` | fail | — | LearnOs; `prog/learn_cpu.rb:9` |
| PF2 | Root SSH | from the CLI: `ssh -i KEY -o BatchMode=yes root@IP true` | exit 0, no forced command | fail | — | `bootstrap_rhizome` |
| PF3 | KVM | `test -c /dev/kvm`; `grep -Ewo 'vmx\|svm' /proc/cpuinfo \| head -1`; `cat /sys/module/kvm_{intel,amd}/parameters/nested 2>/dev/null` | char device present and a flag found | fail | — | HW-4 |
| PF4 | 1G pages (x86) | `grep -qw pdpe1gb /proc/cpuinfo` | present | fail | warn only on a `flexible` profile host [CMP-P1] | `prog/vm/host_nexus.rb:272` |
| PF5 | GRUB | `grep -Eq '^GRUB_CMDLINE_LINUX=".*"$' /etc/default/grub && command -v update-grub && test -d /boot/grub` | all true | fail | — | `prog/setup_hugepages.rb:16-17` |
| PF6 | RAM units | `dmidecode -t memory \| grep -E '^\s+Size: [0-9]'` | every line ends in `GB` | fail | dropped after F9 | `prog/learn_memory.rb:10` |
| PF7 | Hugepage yield | G = sum of GB from PF6; `G*42/43 - 5` (integer math) | ≥ 8 (fail below), ≥ 16 (warn below) | fail / warn | after CMP-P0 step 5 also check MemAvailable ≥ 2 GiB; after CMP-P1 only for `dedicated`/`mixed` profiles | `prog/setup_hugepages.rb:14`; `scheduling/allocator.rb:84-93` |
| PF8 | CPU topology | `lscpu -Jy -e=CPU,SOCKET,CORE,ONLINE` | all online; uniform threads per core; cores beyond CPUs 0-1 ≥ 2 | fail | after CMP-P0 step 3 the "beyond CPUs 0-1" part drops on generic hosts without SPDK; after F4 offline CPUs become a warn | `model/metal/vm.rb:29-30`; `prog/learn_cpu.rb`; `model/vm_host.rb:173` |
| PF9 | cgroup v2 cpuset | `stat -fc %T /sys/fs/cgroup` = `cgroup2fs`; `grep -w cpuset /sys/fs/cgroup/cgroup.controllers` | both | fail | — | `rhizome/host/lib/slice_setup.rb:50` |
| PF10 | Storage mount | `mkdir -p /var/storage`; `findmnt -no SOURCE,FSTYPE --target /var/storage`; `df -BG --output=avail /var/storage` | FSTYPE not btrfs/zfs; avail ≥ 5 + 4 × images + planned VM disk | fail; warn if same source as `/` | after F6 btrfs/zfs no longer crash (still warn); after CMP-P1 also warn when physical free is under `max(RESERVED_STORAGE_GIB, 15%)` | `prog/learn_storage.rb:9-27`; `rhizome/host/lib/storage_volume.rb:470-478` |
| PF11 | Extra disks | `lsblk -dno NAME,TYPE,MOUNTPOINTS`; `findmnt -lno TARGET \| grep ^/var/storage/devices/` | — | warn on unmounted non-root disks ("not counted") | — | `lib/system_parser.rb:69` |
| PF12 | Device identity | `lsblk -sno NAME,TYPE $(findmnt -no SOURCE --target /var/storage)`; for each TYPE=disk `d`: `ls -l /dev/disk/by-id \| grep -E "(wwn-\|nvme-eui\.).* -> ../../$d$"` | link exists | warn ("health checks will fail; do not start `bin/monitor`") | IO limits no longer need this [FIXED e6f5e328e]; after F5 a missing link is fine | `model/storage_device.rb:24-33` |
| PF13 | SMART | `smartctl -j -i /dev/$d \| jq .smart_support.available`; `smartctl -j -H /dev/$d \| jq .smart_status.passed` | `true` / `true` | warn "no SMART (virtual disk)"; fail if SMART says failed | — | `model/vm_host.rb:286-296` |
| PF14 | Clocksource | `cat /sys/devices/system/clocksource/clocksource0/available_clocksource` | starts with `tsc` | warn (blocks only once `bin/monitor` runs) | after F5 `tsc` anywhere, or `kvm-clock` on virtual hosts | `model/vm_host.rb:351-361` |
| PF15 | Packages and egress | `apt-get install -s ruby-bundler qemu-utils mtools acl smartmontools nvme-cli jq libaio-dev sysstat nftables dmidecode pciutils`; `curl -sfI https://github.com`; `curl -sfI https://cloud-images.ubuntu.com` | resolves; 2xx/3xx | fail | — | `prep_host.rb`; `cloud_hypervisor.rb`; `download_boot_image.rb` |
| PF16 | Firewall coexistence | `systemctl is-active docker ufw tailscaled k3s libvirtd`; `nft list tables` | none active | warn (NH-6) | until the NET-P2 NH-6 fix ships | `rhizome/host/bin/setup-nftables.rb:42-50` |
| PF17 | Addressing | `ip -4 -o addr`; `ip route show default` | main IP is local; **no** pool IPv4 is local (contract C5); no block contains the main IP or the gateway; each block within the size limit; CIDRs and net6 not already in `address`/`vm_host` (control-plane DB) | fail | NET-P1 moves the overlap/size/reserved rules into registration validation; NET-P2 adds `check-pool-not-local` on every `SetupNftables` | NH-1, OPS-2, OPS-4, OPS-5 |
| PF18 | AWS extras (when IMDS answers) | IMDSv2 token; `test -f /etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg`; `test -f /var/log/user-data.done`; from the CLI `aws ec2 describe-network-interfaces` → pool IPs assigned to the ENI | all | fail | `SourceDestCheck=false` is required only for routed CIDRs, not for ENI secondary IPs (section 8 item 5); NET-P2 adds the IMDS hop-limit check | OPS-5, OPS-6 |
| PF19 | IOMMU GPU | `lspci -Dnd 10de::`; `readlink /sys/bus/pci/devices/$s/driver`; `test -e /sys/bus/pci/devices/$s/iommu_group` | no NVIDIA GPU in an IOMMU group, or bound to `vfio-pci` | warn "host excluded from non-GPU VMs" | dropped after F9 | VR-4 |
| PF20 | CLI arguments | — | `--default-boot-image` non-empty; `--location` resolves to an existing Location id | fail | NET-P1 makes `--location` a real Location (`bin/byoh-location`) | OPS-3, OPS-14 |
| PF21 | Control plane | on the control plane: units exist for `bin/monitor` and `bin/restarter bin/respirate` | present | warn | do not enable `bin/monitor` before F5; CMP-P2 must also stop `bin/monitor` from deleting the metric files that HostUsageMonitor reads (compute critic hole 5) | OPS-17 |

### 6.3 Running the host-side checks by hand [TODAY]

There is no preflight script yet. These commands are read-only; run them as root on the candidate host. The block as a whole is UNVERIFIED as a script; each command is standard.

```bash
lsb_release -rs; uname -m                                                    # PF1
test -c /dev/kvm && echo kvm-ok; grep -Ewo 'vmx|svm' /proc/cpuinfo | head -1 # PF3
grep -qw pdpe1gb /proc/cpuinfo && echo pdpe1gb-ok                            # PF4
grep -E '^GRUB_CMDLINE_LINUX=".*"$' /etc/default/grub; command -v update-grub # PF5
dmidecode -t memory | grep -E '^\s+Size: [0-9]'                              # PF6 (all must end in GB)
G=$(dmidecode -t memory | awk '/^\s+Size: [0-9]+ GB/{s+=$2} END{print s}'); echo "hugepages=$(( G*42/43 - 5 ))"  # PF7 (need >= 8)
lscpu -Jy -e=CPU,SOCKET,CORE,ONLINE                                          # PF8
stat -fc %T /sys/fs/cgroup; cat /sys/fs/cgroup/cgroup.controllers            # PF9
mkdir -p /var/storage; findmnt -no SOURCE,FSTYPE --target /var/storage; df -BG --output=avail /var/storage  # PF10
lsblk -dno NAME,TYPE,MOUNTPOINTS                                             # PF11
ls -l /dev/disk/by-id/                                                       # PF12
cat /sys/devices/system/clocksource/clocksource0/available_clocksource       # PF14
curl -sfI https://github.com >/dev/null && curl -sfI https://cloud-images.ubuntu.com >/dev/null && echo egress-ok  # PF15
systemctl is-active docker ufw tailscaled k3s libvirtd 2>/dev/null           # PF16 (want all inactive/unknown)
ip -br -4 addr; ip route show default                                        # PF17 (no pool IP listed)
lspci -Dnd 10de:: 2>/dev/null                                                # PF19
```

---

## 7. Troubleshooting "the second VM will not create"

The allocator error does not say which resource ran out (STOR-6), and storage is rarely the cause: VM disks are sparse (`rhizome/host/lib/storage_volume.rb:660`) and the allocator subtracts exactly `size_gib` (`scheduling/allocator.rb:754-759`). Check in this order.

| Cause | How it shows | Status |
|---|---|---|
| IO-CPU over-count (#2) | `RuntimeError failed to allocate cpus` in respirate logs, VM stuck in `creating` | OPEN, CMP-P0 |
| Burstable hugepage CHECK (#3) | `Sequel::CheckConstraintViolation hugepages_allocation_limit` | OPEN, CMP-P0 |
| IPv4 pool exhausted (#6) | VM without IPv4 gets "no space left" | OPEN, CMP-P0 / NET-P0 |
| No boot image (#14) | "no space left" on a fresh host | OPEN, pass `--default-boot-image ubuntu-noble` |
| No persistent device id (EBS, virtio, LVM) | "No persistent device ID found for storage path" in `setup-vm prep` | [FIXED e6f5e328e, b13872889]; requires `install_rhizome` on existing hosts |

On the control plane (`RACK_ENV=development bundle exec bin/pry`):

```ruby
h = VmHost.first
h.values.slice(:total_cores,:used_cores,:total_cpus,:total_hugepages_1g,:used_hugepages_1g,:accepts_slices,:allocation_state)
StorageDevice.where(vm_host_id: h.id).select_map([:name,:total_storage_gib,:available_storage_gib,:unix_device_list])
BootImage.where(vm_host_id: h.id).select_map([:name,:version,:activated_at,:size_gib])
DB[:ipv4_address].where(routed_to_host_id: h.id).exclude(ip: DB[:assigned_vm_address].select(:ip)).count
Strand.where(prog: "Vm::Metal::Nexus").exclude(label: "wait").select_map([:id,:label,:try])   # exception loops
```

On the host: `df -BG /var/storage /` and `ls -ls /var/storage/*/*/disk.raw` (the first column is the real allocated size).

---

## 8. Open contradictions between the designs

These must be decided before the affected phase ships.

| # | Topic | Conflict | Proposed resolution |
|---|---|---|---|
| 1 | IO CPUs on generic hosts | Portability F1 charges the 2 IO CPUs to `used_cores`. CMP-P0 step 3 frees them (`io_cpu_count = 0`). Compute critic hole 11 warns that this puts sshd, IRQs and every vhost backend on overcommitted CPUs, and suggests keeping 1 thread reserved on hosts with fewer than 16 threads | CMP-P0 wins; size the reserve from the G3 test |
| 2 | Readiness check for VMs without IPv4 | Portability F8.2 probes from the host netns (`ip netns exec <vm> ... /dev/tcp/<private_ipv4>/22`). NET-P1 switches `wait_sshable` to `cp_reach_ip4`, which still skips VMs without IPv4 (they are marked `running` unchecked, VR-5) | add the host-netns probe as the fallback when `cp_reach_ip4` is nil. **Adopted**: milestone M2 (ROADMAP §3.3) |
| 3 | SSH over a Cloudflare tunnel | The product direction asks for VM access without a public IP. Portability F8.3 proposes a per-host `cloudflared` (Tier 1). NETWORKING §3.3 lists tunnels and VPN routers on the host as "lab-access helpers only", and in-guest `cloudflared` (Tier 2) needs NET-P6 egress, the last networking phase | **Resolved** in [ROADMAP.md](ROADMAP.md) §4.8: per-host `cloudflared` is dropped; the Ubicloud access tunnel (`ubi vm ssh --tunnel`, console phase C4, milestone M6) rides the existing CP → host SSH, so `host_guard` needs no new port. Egress-only NAT moves to M2 so in-guest tunnels work |
| 4 | `flush ruleset` (NH-6) | Portability F7 wants a dedicated nftables unit without `flush`. NETWORKING has no phase for it, and the networking critic proposes shipping `host_guard` as `/etc/nftables.d/1-host-guard.conf`, which keeps the flush model | **Adopted**: NH-6 is assigned to NET-P2 with `host_guard` (milestone M7); the fix itself is not designed yet |
| 5 | AWS source/dest check | Portability PF18 requires `SourceDestCheck=false`. The networking critic says it is not needed for ENI secondary IPs (`fabric`) and widens the spoofing surface. Terraform sets it false today (`terraform/aws-byoh/main.tf:284`) | UNVERIFIED live; test on a second host before changing the live one |
| 6 | Upstream commit for CP-5 | Portability cites 02e47743d ("Fix allocator excluding hosts without available IPv4 for IPv6-only VMs"). The compute plan cites 8e295c4d2 ("Stop keeping a pre-assigned IPv4 address in the allocator") as "IPv4 LEFT join". Both exist on origin/main and neither is in HEAD | port 02e47743d first; take 8e295c4d2 with the allocator rebase |
| 7 | `CheckIpReachability` after the rebase | Portability says skip it or make it advisory for generic hosts. NET-P0 brings it in and NET-P3 extends it. The networking critic notes it adds every pool IP to `lo`, which violates C5, and naps forever on failure, which blocks `internal` sites | NET-P0 must ship a generic skip policy; NET-P3 must skip allocated IPs |
| 8 | Network and broadcast addresses | Portability F7 drops them for any block larger than /31. The networking critic says an `onlink` sub-block (e.g. 10.80.0.200/29 inside a /24) must keep them and strip only the segment's network, broadcast and gateway | networking rule wins |
| 9 | Maximum IPv4 block size | Portability PF17: ≤ 256 addresses. NET-P1: no larger than /22. CLAUDE.md §4: blocks larger than /24 fail late in `Address#validate` today | keep /24 until `Address#validate` is changed |
| 10 | Minimum host RAM | 14 GiB is a hugepage rule. A `flexible` profile host (CMP-P1) has 0 hugepages, so the minimum becomes `host_reserved_mem_gib` + VM memory | PF7 becomes profile-aware in CMP-P1 |
| 11 | Terraform `data_plane_open_ingress` | The networking critic says the `variables.tf` default is `true` and the live tfvars sets `true`. The current uncommitted working tree shows `default = false`, and `company-mumbai.tfvars` (live workspace) sets `data_plane_open_ingress = false` (checked 2026-10-12; no `*.tfplan` files exist) | confirm before any `terraform apply` on the live environment; the security group must open only after `host_guard` (NETWORKING L5/L6) |
| 12 | Dedicated VMs and physical disk rails | CMP-P1 gives dedicated disks thin storage but applies the physical guard and freeze only to flexible VMs (compute critic hole 4); F6/STOR-4 assumed every tier is protected | apply the physical guard to every tier |
