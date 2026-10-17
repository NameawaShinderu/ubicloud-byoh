# BYOH on Proxmox VE (and other hypervisors)

This page is a short guide. The shortest path, with the M4 commands, is [recipes/proxmox.md](../recipes/proxmox.md). The full runbook is [SETUP_PROXMOX.md](../SETUP_PROXMOX.md); each step below links to its section there and does not repeat it. Other hypervisors (VMware ESXi, Hyper-V, XCP-ng, plain libvirt/KVM) are covered at the end, under "Other hypervisors".

> **Status: UNVERIFIED on Proxmox and on every hypervisor on this page.** The flow was run end to end only on AWS (m8i nested virtualization, ap-south-1; [VERIFY.md](../VERIFY.md) §5). Settings here come from the code, [NETWORKING.md](../NETWORKING.md) §9.2 and [PLATFORMS.md](../PLATFORMS.md). Statements about third-party hypervisors are marked "vendor docs, UNVERIFIED here".

---

## 1. Fit

Use Proxmox when you already run a Proxmox VE cluster and want a private or company cloud on it. The data plane is always a **guest VM** with nested virtualization. Never register the Proxmox node itself: registration recreates the `rhizome` user, rewrites sshd, allocates hugepages, flushes nftables on every VM change and reboots the machine ([SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §0).

| Site | delivery x exposure (NETWORKING §3) | Runbook |
|---|---|---|
| LAN only, no public block | `onlink` + `internal` | SETUP_PROXMOX §6.2 (variant A) |
| Router with extra public IPs, 1:1 NAT (pfSense) | `onlink` + `nat` | SETUP_PROXMOX §6.3 (variant B) |
| ISP routes a block to the router | `routed` + `public` | SETUP_PROXMOX §6.4 (variant C) |
| One WAN IP, internet ingress needed | tunnel recipe | NETWORKING §9.4 (PLANNED) |

Nested virtualization costs performance. A Proxmox guest suits an internal cloud, labs and staging. For heavy production loads, register bare metal instead.

### 1.1 Without KVM in the guest

Fix KVM first: almost every Proxmox guest without a working `/dev/kvm` has nested virtualization off on the node or a CPU type other than `host`, and `host add` preflight (PF3) reports that as `kvm_blocked` with the `qm set <vmid> --cpu host` fix (§4). Only when the node cannot expose VT-x/AMD-V at all (a node that is itself a cloud VM without nested support, for example) can the guest use one of the experimental, single-project lower tiers ([NO_KVM.md](../NO_KVM.md)):

| Tier | What the guest needs | `host add` flags |
|---|---|---|
| `container` | x86_64 Linux 5.12 or newer with cgroup v2, and the LXC packages (`apt-get install lxc lxcfs uidmap xz-utils quota cryptsetup-bin e2fsprogs`) | `--virt-tier auto` or `container`, with `--accept-fallback` |
| `pvm` | x86_64 without `vmx`/`svm`, a CPU that Meltdown does not affect, Secure Boot off (OVMF guests: check), GRUB | `--virt-tier pvm --install-pvm-kernel --accept-fallback` |
| `emulated` | `apt-get install qemu-system-x86 ovmf`; demos and CI only | `--virt-tier emulated --accept-fallback` |

Each tier must be offered in the site first (`ubicloud-admin site rates` and `site set --virt-tiers`); [QUICKSTART.md](../QUICKSTART.md) §5 has the commands and [README.md](../README.md) §2 the measured speed and isolation. None of them has run on Proxmox (UNVERIFIED); the measurements are from AWS.

---

## 2. Requirements

| Area | Requirement | Where checked |
|---|---|---|
| Node | VT-x/AMD-V on, nested virtualization on (`kvm-intel nested=Y` or `kvm-amd nested=1`), not a hybrid P+E core CPU, SMT on | SETUP_PROXMOX §2 |
| Guest OS | Ubuntu 24.04 LTS, x86_64 | `bootstrap-data-plane.sh` step 1 |
| Guest CPU | Type `host`, so the guest sees `vmx`/`svm` and `pdpe1gb`. 8 cores recommended, 4 minimum (UNVERIFIED) | `bootstrap-data-plane.sh` step 1b; PrepHost KVM check |
| Guest memory | 32 GiB recommended, 16 GiB minimum (UNVERIFIED). Ballooning off (`--balloon 0`). **A multiple of 1024 MiB**, as in SETUP_PROXMOX §3.1: required on the published `byoh-driver` (17d383a9c), whose LearnMemory crashes on MB sizes. Only builds with a0259a997 (`m2-network`, not yet published; [README.md](README.md) "Which branch") accept other sizes and round down to whole GiB (unit specs only) | PLATFORMS PF6, PF7 |
| Disk | One virtual disk on the VM's own storage, 200 GB or more, ext4 or xfs at `/var/storage`. No shared or passed-through disks | PLATFORMS §1; `mkdir -p /var/storage; findmnt -no FSTYPE --target /var/storage`; SETUP_PROXMOX §3.1 for size and placement |
| Network | **One** virtio NIC on the LAN bridge with `firewall=0`, a static management IP, outbound HTTP and HTTPS. Pool addresses must never be on the NIC or in netplan (contract C5) | SETUP_PROXMOX §3.1, §6.1 |
| Control plane | SSH (TCP 22) to the guest's management IP as root. On the LAN, or with a routed path into it (C0) | SETUP_PROXMOX §4.1 |

---

## 3. Step by step

Every command below exists on `m2-network` and on the published `byoh-driver` (17d383a9c): `bin/byoh-location`, `bin/register-byoh-host`, `bin/byoh-pool`, `bin/byoh-host`, `scripts/byoh/*`. Three fixes this page relies on are only on `m2-network`, which is not pushed yet: a0259a997 (LearnMemory units), a092f1b8b ("is a local address of this host") and c73f96ddc (uplink MAC pin skip). [README.md](README.md) "Which branch" lists the workaround for each. The example values are those of SETUP_PROXMOX: bridge `vmbr1`, LAN `10.80.0.0/24`, router `10.80.0.1`, data plane `10.80.0.20`.

**Since M4, steps 2, 3's key install, 6 and 7 are one command**, `ubicloud-admin host add --site <site> --ssh ubuntu@<guest> --ssh-key <key> --pool-file pools.yaml`, which runs host preflight (it refuses a Proxmox node, PF16-pve), installs its own root key, registers the guest and waits until it accepts VMs ([recipes/proxmox.md](../recipes/proxmox.md) §4, SETUP_PROXMOX §7.2). Step 4 is `ubicloud-admin site add`. The steps below are the low-level path.

1. **Provision the guest.** Run the read-only node checks in SETUP_PROXMOX §2. Create the VM with `qm create ... --cpu host --balloon 0 --net0 virtio,bridge=vmbr1,firewall=0` as in §3.2, then run the in-guest checks in §3.3.
2. **Data-plane bootstrap.** In the guest (SETUP_PROXMOX §5):

   ```bash
   git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
   bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
   ```

   On `m2-network` (105b6439b) it refuses the guest if `/dev/kvm`, `vmx`/`svm` or `pdpe1gb` is missing, and prints `qm set <vmid> --cpu host` as the fix.
3. **Control plane.** Install it with `scripts/byoh/install.sh` ([INSTALL.md](../INSTALL.md)) or, for a lab, the development bootstrap `scripts/byoh/bootstrap-dev-ctrl-plane.sh` ([SETUP.md](../SETUP.md) §4, SETUP_PROXMOX §4.2). Keep `UBI_START_MONITOR=0` (the default): virtio disks have no by-id links or SMART (PLATFORMS F5). Install the control plane's Ed25519 key in the guest's `/root/.ssh/authorized_keys` (SETUP_PROXMOX §5).
4. **Location** (once per site, SETUP_PROXMOX §7.1):

   ```bash
   bundle exec bin/byoh-location create --name byoh-pve-office \
     --ui-name "Office Proxmox (BYOH)" \
     --underlay 10.80.0.0/24 --overlay 172.20.0.0/14 \
     --cp-reach onhost --cp-source <control plane IP>/32 \
     --mgmt-allow 10.80.0.0/24 --rates-from hetzner-fsn1
   ```

   The `grant` comes in step 8, once your account and project exist.

   Use `--cp-reach public` when the control plane is off the site LAN. Restart `puma` and `respirate` afterwards so they load the rates.
5. **pools.yaml.** First shrink the router's DHCP range so the pool is outside it (SETUP_PROXMOX §6.1). Variant A:

   ```yaml
   version: 2
   uplink: ens18        # enp6s18 on q35; stored and shown only
   routed_networks:
     - cidr: 10.80.0.200/29
       delivery: onlink
       exposure: internal
       segment: 10.80.0.0/24
       gateway: 10.80.0.1
   ```

   For variant B, add a `nat` pool with an `external:` map (SETUP_PROXMOX §6.3).
6. **Register** (SETUP_PROXMOX §7.2):

   ```bash
   bundle exec bin/register-byoh-host --location byoh-pve-office \
     --main-ip 10.80.0.20 --pool-file pools.yaml \
     --ssh-key ~/.ssh/byoh_data --default-boot-image ubuntu-noble --yes
   ```

   The guest reboots once. Wait for `allocation_state = accepting`.
7. **Verify the pools** (SETUP_PROXMOX §7.3): `bundle exec bin/byoh-pool verify --host vh...`. On a variant A host it warns that no internet VM with IPv4 can be placed; that is expected. Check the egress table as root on the guest:

   ```bash
   ssh -i ~/.ssh/byoh_data root@10.80.0.20 nft list table inet byoh_egress
   ```

   If the table is missing (`nft` exits with "No such file or directory"), run `bundle exec bin/byoh-host setup-egress-nat --host vh...`.
8. **Create VMs** (SETUP_PROXMOX §8). Create your account, then grant its project: `bundle exec bin/byoh-location grant --location byoh-pve-office --project pj...`. On variant A, pick IPv4 exposure **internal** (`ubi vm byoh-pve-office/vm1 create -e internal ...`), or leave IPv4 off (`-6`).
9. **Gate** ([VERIFY.md](../VERIFY.md) §2.5, SETUP_PROXMOX §9). First export the variables in SETUP_PROXMOX §9: `GATE_LOCATION`, `GATE_HOST`, `GATE_MAIN_IP`, `GATE_HOST_KEY`, `GATE_VM_KEY`, `GATE_VM_B`, `GATE_VM_C`, and for `g9b` `GATE_CTRL_PRIV`, `GATE_UNDERLAY_PROBE` and `GATE_SMTP_PROBE`. `GATE_EXPECT_MONITOR=0` is the default. Then:

   ```bash
   scripts/byoh/verify/m2-gate.sh g1 g2 g3 g4 g5 g7 g8 g9 g9b                                        # variant A
   GATE_VM_A=vm... GATE_EXTERNAL_SSH_VIA=<user@host outside the site> scripts/byoh/verify/m2-gate.sh g6   # variant B, NAT reflection off
   ```

   Then G12-G15 (VERIFY §2.5): `g12 g13`, `g15-before`/`g15-after` around the create/destroy loop, and `g14` after an admin reboot.

---

## 4. Problems and solutions

| Symptom | Cause | Fix |
|---|---|---|
| `bootstrap-data-plane.sh`: "/dev/kvm is missing" or "neither the vmx nor the svm flag" | Nested virtualization off on the node, or the CPU type is not `host` | Ask the node owner to enable nested virtualization (node reboot); `qm set <vmid> --cpu host`, then `qm shutdown` and `qm start` |
| `bootstrap-data-plane.sh`: "lacks the pdpe1gb flag" | A named CPU model, such as `kvm64` or the PVE default, hides 1G pages (UNVERIFIED which models do) | `qm set <vmid> --cpu host` |
| `bin/byoh-virt probe` or registration: `tier: kvm_blocked`, reason "the CPU model is the hypervisor's generic ..." | The guest's CPU type is `kvm64`/`qemu64` (the PVE default "Common KVM processor"), even with `+vmx` and a working `/dev/kvm`: it hides features cloud-hypervisor's guests need | `qm set <vmid> --cpu host`, nested on the node, then `qm shutdown` and `qm start`; probe again. M4's preflight PF3 gives the same verdict (PLATFORMS §6.2) |
| `verify_hugepages` fails, or few hugepages | Memory too small, or ballooning reclaims it | `qm set <vmid> --memory 32768 --balloon 0`, then `qm shutdown <vmid>` and `qm start <vmid>`: a guest reboot does not apply it |
| LearnMemory "unexpected dmidecode unit" | Memory not a multiple of 1024 MiB on a build without a0259a997 (the published `byoh-driver`) | Set the memory to a multiple of 1024 MiB (`qm set <vmid> --memory 32768`) and restart from Proxmox (`qm shutdown`, `qm start`). Respirate retries; do not re-register |
| Every VM fails with `BUG` | Hybrid P+E core node CPU (PLATFORMS HW-6) on a data plane whose CPUs were learned before M4 | Re-register the data plane on M4 code with `--accept-check PF8-hybrid` (a BYOH host then counts every CPU as a core; UNVERIFIED on hybrid hardware), or disable E-cores in the BIOS |
| Internal VM unreachable from the LAN | Proxmox NIC firewall (`ipfilter`/`macfilter`) drops proxy-ARP replies or pool-sourced packets; pool inside the DHCP range; an overlapping route or VPN | `firewall=0` on the data plane's NIC; shrink DHCP; `arping` the pool IP from another LAN host (two MACs means a conflict) |
| VM setup fails "X is a local address of this host" (`m2-network`); on the published `byoh-driver`, `wait_sshable` passes but SSH to the VM gives "Permission denied (publickey)" from the guest itself | A pool address was put on the guest NIC (cloud-init `ipconfig0`, netplan, or by hand) | Keep only the management IP on the NIC (`ip -br -4 addr`); remove the pool address from netplan and cloud-init, then recreate the VM. The explicit check is new in a092f1b8b (unit specs only) |
| PrepHost fails | No outbound HTTP/HTTPS from the guest | Allow the Ubuntu apt mirrors (`archive.ubuntu.com`, `security.ubuntu.com`; ports 80 and 443), github.com and its release-asset host (`*.githubusercontent.com`) through the router (exact allowlist hostnames UNVERIFIED) |
| Boot image download never finishes (`download_boot_images`, 4 h deadline) | cloud-images.ubuntu.com or cloud-images-archive.ubuntu.com blocked (the pinned releases redirect to the archive over plain HTTP) | Allow HTTPS to cloud-images.ubuntu.com and HTTP (80) to cloud-images-archive.ubuntu.com |
| VM stuck at `wait_sshable` | `--cp-reach onhost`, but the control plane cannot reach the pool address | Put the control plane on the LAN, or `bin/byoh-location set --location <name> --cp-reach public` |
| Host flaps to `unavailable` | `bin/monitor` was started on a host registered before M4 (stale disk ids), or on a generic host still in hetzner-fsn1 (upstream checks, which do not fit virtio disks) | `bin/byoh-host relearn-device-ids --host vh... --yes`, or `bin/byoh-host move-location`; meanwhile stop `bin/monitor` ([TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §8) |
| VMs lose their disks or capacity looks wrong after adding a disk | A new disk was mounted over `/var/storage` after registration (OPS-9) | Never do that. Extra disks are dedicated virtual disks given to `host add --storage-disk` **before** the host is added ([SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §3.4) |
| Other guests on the node lose network, or the Proxmox firewall rules vanish | Ubicloud scripts ran on the node itself, and rhizome flushed its nftables ruleset (NH-6) | Never run Ubicloud scripts on, or register, the node (SETUP_PROXMOX §0); run `pve-firewall restart` on the node to reload its rules (UNVERIFIED) |
| A guest-side VLAN or bond on the uplink broke `netplan generate` in PrepHost | The uplink MAC pin renamed an interface that a VLAN `link:` or bond `interfaces:` names (builds without c73f96ddc, including the published `byoh-driver`) | Tag the VLAN on the Proxmox NIC (`--net0 ...,tag=<id>`), not in the guest. `m2-network` skips the pin in that case once it is published |

Common problems (root SSH, boot images, capacity, DNS, the egress deny list) are in [TROUBLESHOOTING.md](../TROUBLESHOOTING.md), NETWORKING §11 and PLATFORMS §7. SETUP_PROXMOX §10 has the full Proxmox table.

---

## 5. Status

- **Proxmox:** UNVERIFIED. No run is recorded in this project (VERIFY.md §5). The virtualization probe on Proxmox (`kvm64` with and without `vmx`, NO_KVM.md §14 L2-T3, L2-T10) and on VMware (L2-T5) is UNVERIFIED too. The `onlink` data path has not run on any platform yet.
- **Known gaps:** the monitor's health checks fit virtio disks since M4 (F5), but the 24-hour soak (VERIFY.md G-M4-4) has not run, so leave `bin/monitor` off; SMT off and hybrid CPUs are unsupported; Docker, ufw, Tailscale or libvirt on the data-plane guest get their nftables rules flushed (NH-6); the pools file `uplink` key and the profile `guest_mtu` are stored but not applied (guests always get MTU 1400 by DHCP); a same-site hairpin for `nat` VMs is PLANNED (NETWORKING §4.6).
- **Deleted in M4:** `SETUP_PROXMOX_LOWTIER.md` and `docs/byoh/deploy-scripts/`, replaced by [recipes/proxmox.md](../recipes/proxmox.md).

---

## Other hypervisors

The data plane is a guest VM on these hypervisors too. Everything in sections 2-4 applies; only the knobs differ. The common rules:

- **Expose hardware virtualization and 1G pages to the guest.** `bootstrap-data-plane.sh` checks `/dev/kvm`, `vmx`/`svm` and `pdpe1gb` and refuses the guest if any is missing. That is the quickest test on a new hypervisor. `bin/byoh-virt probe --main-ip <IP> --ssh-key <key>` from the control plane (or `host add` preflight, PF3) goes further (KVM capabilities, generic CPU models, `KVM_CREATE_VM`) and names the hypervisor (Proxmox/libvirt as `qemu_kvm`, `vmware`, `hyperv`, `virtualbox`, `xen`) with its fix ([NO_KVM.md](../NO_KVM.md) §4). If the hypervisor cannot expose VT-x at all, the experimental `container`, `pvm` or `emulated` tier is the fallback (§1.1, NO_KVM.md §1).
- **Turn off dynamic memory and ballooning.** Most guest memory becomes 1G hugepages.
- **One NIC, static management IP, no pool addresses on it.** VMs are routed behind the guest's own MAC: the guest answers ARP for `onlink` pool addresses with proxy_arp, and every VM packet leaves with the guest's MAC. So MAC spoofing or promiscuous mode should not be needed (inferred from `rhizome/host/lib/vm_setup.rb`, UNVERIFIED). What can break the path is an **IP** filter on the virtual switch that drops packets whose source is not the guest's own address.
- **Leave `bin/monitor` off for now.** Virtual disks have no `wwn-`/`nvme-eui` links or SMART; since M4 the checks of a BYOH host allow for that (F5), but no soak has run on any hypervisor (UNVERIFIED).

| Hypervisor | Enable nested virtualization (vendor docs, UNVERIFIED here) | Things to check | Status |
|---|---|---|---|
| **libvirt / KVM** (Ubuntu, Debian, RHEL hosts) | On the host, `kvm_intel nested=1` or `kvm_amd nested=1`. In the domain XML, `<cpu mode='host-passthrough'/>`, which passes `vmx`/`svm` and `pdpe1gb` | libvirt adds a virtio memballoon by default: set `<memballoon model='none'/>` in the domain XML (vendor docs, UNVERIFIED here); set `<memory unit='GiB'>`. Do not attach the `clean-traffic` nwfilter (or any `no-ip-spoofing` filter) to the guest NIC: it drops packets sourced from pool addresses. On the default NAT network `virbr0` (192.168.122.0/24), libvirt's dnsmasq hands out most of the subnet, so shrink its DHCP range before you declare an `onlink` pool there, or use a bridge (`br0`) on the LAN. Do not put the data plane on a `macvtap` NIC if the control plane runs on the same host: macvtap guests cannot talk to their own host. Never register the libvirt host itself (`libvirtd` rules are flushed, NH-6) | UNVERIFIED |
| **VMware ESXi / vSphere** | VM setting "Expose hardware assisted virtualization to the guest OS" (writes `vhv.enable = "TRUE"` to the `.vmx`); VT-x/AMD-V on in the BIOS. Broadcom/Dell KBs: not supported in production, and not combinable with PCI passthrough or vGPU on the same VM | Whether the guest sees `pdpe1gb` depends on the VM's CPU compatibility (EVC) mode; the bootstrap check tells you. Memory reservation of the full size avoids ESXi ballooning. Standard and distributed vSwitches filter MACs, not IPs, so the routed-behind-the-guest-MAC model should pass with the default security policy (UNVERIFIED) | UNVERIFIED |
| **Microsoft Hyper-V** (Windows Server, Windows) | With the VM off: `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true`. Intel VT-x with EPT needs Windows Server 2016 / Windows 10 or later and VM configuration version 8.0+; AMD EPYC/Ryzen needs Windows Server 2022 / Windows 11 or later and configuration version 9.3+. VBS cannot be combined with it | Disable Dynamic Memory. Microsoft's networking advice (MAC address spoofing on the guest NIC, or NAT inside it) is for nested guests with their own MACs; BYOH VMs use the guest's MAC, so try without spoofing first (UNVERIFIED). Whether Hyper-V exposes `pdpe1gb` is UNVERIFIED; the bootstrap check tells you. Azure VMs are Hyper-V guests: see NETWORKING §9.8 | UNVERIFIED |
| **XCP-ng / Xen** | `xe vm-param-set uuid=<uuid> platform:exp-nested-hvm=true`, with the VM halted. XCP-ng's docs say nested virtualization is for tests and labs only, and forum users report nested Linux guests crashing the nested host | Treat as lab only. Whether `pdpe1gb` reaches the guest is UNVERIFIED; the bootstrap check tells you. Memory: set static min = static max (no dynamic memory) | UNVERIFIED, lab only |

Problems specific to these hypervisors:

| Symptom | Cause | Fix |
|---|---|---|
| Bootstrap refuses the guest: no `/dev/kvm` or no `vmx`/`svm` | Nested virtualization not exposed for this VM | Use the "Enable" column above, then fully power off and on |
| Bootstrap refuses the guest: no `pdpe1gb` | The virtual CPU model hides 1G pages (libvirt named models, ESXi EVC baselines) | libvirt `host-passthrough`; a newer or no EVC baseline on ESXi. If the hypervisor cannot pass it, this host cannot run dedicated VMs until the `flexible` profile ([COMPUTE.md](../COMPUTE.md), PLANNED P1) |
| Internal VMs unreachable, the host itself fine | An IP anti-spoofing filter on the virtual switch (libvirt `clean-traffic`; check port security on others) | Remove the filter from the data plane's NIC |
| Pool addresses answer from another machine | The pool overlaps a DHCP range (libvirt `virbr0`, the LAN router) | Shrink the DHCP range; see SETUP_PROXMOX §6.1 |
| Hugepage count lower than expected, or falls after a while | Dynamic memory, ballooning or memory overcommit on the hypervisor | Fixed memory with a full reservation |

Sources (vendor docs, UNVERIFIED here): [Microsoft: nested virtualization in Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/enable-nested-virtualization), [XCP-ng: XCP-ng in a VM](https://docs.xcp-ng.org/guides/xcpng-in-a-vm/), [Broadcom KB 437651: VHV and passthrough](https://knowledge.broadcom.com/external/article/437651/unable-to-enable-expose-hardware-assiste), [Dell KB 000204766: VHV support](https://www.dell.com/support/kbdoc/en-bb/000204766/nested-virtualization-support-on-vxrack-systems). The older docs.vmware.com vSphere 6.5 page on exposing VHV was retired with Broadcom's move to techdocs.broadcom.com; its current location is UNVERIFIED here, so use the Broadcom KB above.
