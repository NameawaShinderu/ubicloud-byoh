# BYOH on other clouds and VPS providers

This page covers DigitalOcean, Vultr (VPS and bare metal), Linode/Akamai, Oracle Cloud (OCI), Scaleway (Instances, Elastic Metal, Dedibox/Online), Hetzner Cloud and OVHcloud Public Cloud. For each one it says whether the provider can run a BYOH data plane, how to get the extra IPs the VMs need, and which `delivery` × `exposure` model ([NETWORKING.md](../NETWORKING.md) §3) applies. It also covers the case of a VPS without KVM.

> **Status: everything on this page is UNVERIFIED.** BYOH has been tested end to end only on AWS (m8i nested virtualization, ap-south-1). Nobody has registered a host on any provider listed here. Provider facts come from provider documentation or community posts. They are marked *(provider docs, UNVERIFIED here)* or *(community report, UNVERIFIED here)*. This page gives no prices or quotas beyond what those sources state.

Related pages:
- [SETUP.md](../SETUP.md): the full runbook, the same on every platform.
- [PLATFORMS.md](../PLATFORMS.md): host requirements (§1) and the compatibility table (§2).
- [NETWORKING.md](../NETWORKING.md): the models (§3), the runbooks for rented bare metal, GCP and Azure (§9.5, §9.7, §9.8), the tunnel recipe (§9.4) and troubleshooting (§11).
- [POOL_OPERATIONS.md](../POOL_OPERATIONS.md): the `pools.yaml` format and the `bin/byoh-pool` commands.
- [VERIFY.md](../VERIFY.md) §2.5: the gate on platforms other than AWS.
- Rented bare metal from Hetzner Robot, OVH dedicated servers and Leaseweb is covered in [bare-metal-dedicated.md](bare-metal-dedicated.md) and NETWORKING §9.5; your own hardware and colo in [own-hardware.md](own-hardware.md). Neither is covered here. All platforms: [README.md](README.md).

---

## 1. Fit

### 1.1 Two questions decide everything

1. **Does the machine have KVM?** cloud-hypervisor requires `/dev/kvm`, and so do Firecracker, crosvm and QEMU-KVM. Without it there are only experimental, opt-in fallbacks (§1.3, [NO_KVM.md](../NO_KVM.md)). `scripts/byoh/bootstrap-data-plane.sh` (default `--tier kvm`) refuses a host without `/dev/kvm`, without the `vmx`/`svm` flag or without `pdpe1gb`. PrepHost refuses it again after registration (`rhizome/host/lib/kvm_check.rb`). A VPS qualifies only when the provider exposes nested virtualization. A bare-metal server always qualifies once VT-x/AMD-V is on.
2. **How do extra IPv4 addresses reach the machine?** Rhizome routes every VM behind the host's own MAC address (NETWORKING §9.5):
   - Addresses **routed** to the host's main IP work (`routed`).
   - Addresses that a cloud SDN delivers to the host's NIC work (`fabric`).
   - Addresses the provider **1:1 NATs** onto a private address of the host work (`nat`).
   - Addresses tied to a separate virtual MAC do **not** work.

   An address the provider tells you to configure on the NIC still has to stay off the host. Declare it as a pool and leave it unconfigured (contract C5). Since M2, VM setup on a BYOH host fails with "is a local address of this host" when you forget (`VmSetup#check_ip4_not_local`).

### 1.2 Verdict table

| Provider / product | KVM for the data plane | Extra IPv4 for VMs | Model | Verdict | Why |
|---|---|---|---|---|---|
| **Oracle Cloud (OCI) bare-metal shapes** | Native | Secondary private IPs on the VNIC, each with a reserved public IP *(provider docs, UNVERIFIED here)* | `fabric` + `nat` (like AWS) | **Works with caveats** | Same shape as the validated AWS setup. Unknown: whether the Ubuntu image's network setup puts secondary IPs on the NIC (C5), and which physical NIC secondary VNICs use on two-NIC shapes. |
| **OCI VM shapes** (VM.Standard.E5.Flex, VM.Standard3.Flex) | Nested virtualization worked on these two shapes in an Oracle blog post; Ampere (Arm) VMs did not support it *(provider blog, UNVERIFIED here)* | As above | `fabric` + `nat` | **Works with caveats** | As above. Nested virtualization is shown in a tutorial, not in a support statement. |
| **Scaleway Elastic Metal** | Native | Flexible IPs: single IPv4 /32 or IPv6 /64, routable to any Elastic Metal server in the same zone, up to 64 per server *(provider docs, UNVERIFIED here)* | `routed` + `public` | **Works with caveats** | Same shape as Hetzner and OVH routed IPs. Never attach a virtual MAC to a flexible IP. |
| **Vultr Bare Metal** | Native | Reserved IPs attached to the instance; Vultr says to restart the instance to apply the new IP configuration *(provider docs, UNVERIFIED here)* | `routed` + `public` if the IP is routed to the main IP; unknown otherwise | **Works with caveats** | It is not documented whether an attached IP is routed or on-link. If Vultr's restart writes the IP into the OS network config, remove it (C5). Test one /32 first (§3.6). |
| **OVHcloud Public Cloud instances** | OVH's FAQ says instances get the `vmx` flag, but a live migration can happen at any time and the guest kernel may panic *(provider docs, UNVERIFIED here)* | Additional IPs, up to 256 per instance, configured as /32 with no gateway; they move only within the same project *(provider docs, UNVERIFIED here)* | `routed` + `public` (assumed from the /32-without-gateway setup) | **Works with caveats: lab only** | A live migration can kill the host and every VM on it. OVH's page does not say how Additional IPs are delivered. |
| **DigitalOcean Droplets** | Not officially supported. Staff said nested KVM works on Intel hosts but advised against it for performance, and a feature request says AMD hosts lack it *(community report, UNVERIFIED here)* | One reserved IP per Droplet, NATed to the Droplet's anchor IP. The default limit is 3 reserved IPs per account *(provider docs, UNVERIFIED here)* | `onlink` + `nat` on the anchor IP for **one** VM (theory, §3.6), or the single-IP case (§3.7) | **Works with caveats: lab only** | No support statement for nested virtualization, and at most one VM with internet IPv4 per host. |
| **Vultr cloud compute (VPS)** | Unknown. 2021 mailing-list reports disagree *(community report, UNVERIFIED here)* | Reserved IPs (as for bare metal) | as Vultr Bare Metal | **Check `/dev/kvm` first** | If the bootstrap's virtualization check passes, treat it like Vultr Bare Metal, lab only. Otherwise see §1.3. |
| **Scaleway Instances** | Anecdotal only: nested VMX on some instance types and hypervisors; Arm types reportedly lack KVM *(community report, UNVERIFIED here)* | Flexible IPs (Instances: not researched) | unknown | **Check `/dev/kvm` first** | Use Elastic Metal instead for anything beyond a test. |
| **Linode / Akamai compute instances** | Staff replies say nested virtualization is not supported, because it breaks live migration; they point to bare metal instead *(community report, UNVERIFIED here)* | IPv4: not researched. IPv6: a routed /64 or /56 per data center, which needs Network Helper disabled *(provider docs, UNVERIFIED here)* | IPv6 routed /64 → `gua` | **Not possible** as a data plane unless `/dev/kvm` is present | No KVM. A routed IPv6 /64 would fit if KVM were available. |
| **Hetzner Cloud** | Community reports say Cloud servers expose no KVM *(community report, UNVERIFIED here)* | Floating IPs, assigned to one server at a time and configured as /32 on `eth0` *(provider docs, UNVERIFIED here)* | n/a as data plane; `routed` (WireGuard) as a tunnel endpoint | **Not possible** as a data plane | No KVM. Hetzner dedicated servers (Robot, including the server auction) are the Hetzner data-plane option (NETWORKING §9.5). Hetzner Cloud is still a good **control plane** or **tunnel VPS** (§1.3). |
| **Scaleway Dedibox / Online** | Native (dedicated servers) | Not researched | probably `routed` + `public` | **UNVERIFIED** | Not researched. Apply the bare-metal rules in NETWORKING §9.5. |
| **Any VPS without `/dev/kvm`** | none | as the provider allows | as the provider allows | **Not possible** for standard VMs; experimental `container`, `pvm` or `emulated` tier | §1.3 |
| **OpenVZ, LXC or Docker "VPS"** (a container, not a VM) | none | — | — | **Not possible**, on any branch: the probe refuses a data plane that is itself a container | §1.3 |

"Works with caveats" means the code path exists and matches a shape that was validated elsewhere, but on this provider nothing has been run.

### 1.3 The KVM-less VPS

A VPS that shows no `/dev/kvm` cannot run standard Ubicloud VMs.

- `bootstrap-data-plane.sh` stops with `ERROR: /dev/kvm is missing, so KVM is unavailable.` (or the `vmx`/`svm` or `pdpe1gb` errors).
- If you register it anyway on the default `kvm` tier, preflight (PF3) refuses it, and without preflight PrepHost fails its KVM check and the host never reaches `accepting`.

**First, find out why:** `ubicloud-admin host preflight` (PF3), or `bin/byoh-virt probe --main-ip <IP> --ssh-key <key>` on the
control plane (packaged: `sudo ubicloud-admin run byoh-virt probe ...`). It names the provider when it can (the DMI strings for Linode, Vultr and Scaleway are
guesses, UNVERIFIED), says whether that provider offers nested virtualization, and prints the fix: often
a different plan or the provider's bare-metal line. Prefer that: every option below is slower or
isolates less.

**If KVM is impossible there** (experimental, opt-in per location, never chosen silently; [NO_KVM.md](../NO_KVM.md); comparison in [README.md](../README.md) §2):

| Tier | What customers get | Speed (lab, VERIFIED) | Isolation | Status |
|---|---|---|---|---|
| `container` (L3) | Unprivileged LXC system containers with systemd, SSH and cloud-init, as `container-2..16` sizes | Lab: CPU 95-99%, memory bandwidth 91-98% of native, SSH in 3.6-5.4 s. AWS t3.xlarge: CPU 99.8%, memory 99.9% ([VERIFY.md](../VERIFY.md) §7) | Shared host kernel: not a VM | Registrable; one project per location; run on AWS (VERIFY.md §7), not on a VPS |
| `pvm` (L4) | Cloud Hypervisor VMs on KVM in software (a PVM host kernel the control plane installs), as `pvm-2..16` sizes, `ubuntu-noble` only | AWS m6i.2xlarge: CPU 97%, memory about 100%, 4k random I/O 93%, syscalls 48%, fork+exec 32% of the host ([VERIFY.md](../VERIFY.md) §8) | VM, weaker than hardware | Registrable with `--virt-tier pvm --install-pvm-kernel --accept-fallback`; x86_64 CPUs Meltdown does not affect, Secure Boot off, a plain (not md or LVM) `/boot`; one project per location; run end to end on AWS (VERIFY.md §8), not on a VPS |
| `emulated` (L5) | QEMU TCG VMs, as `emulated-2/4` sizes | Lab: CPU 26-29%, memory bandwidth about 2.5%, 64-96 s to SSH. AWS t3.xlarge: CPU 29%, memory 2% (VERIFY.md §7) | Not a security boundary | Registrable; one project per location; run on AWS (VERIFY.md §7), not on a VPS |

The commands, in order (the probe and a refused registration print them with your names filled in):

```bash
# data plane: install the tier's packages; --tier auto picks container before emulated
sudo scripts/byoh/bootstrap-data-plane.sh --tier auto
# control plane: price the tier, then offer it (set refuses a tier without rates)
bin/byoh-location rates --location <loc> --family container --from standard --multiplier <X>
bin/byoh-location set --location <loc> --virt-tiers kvm,container --accept container
#   restart web, respirate and monitor after a rates change (CLAUDE.md §8a)
bin/register-byoh-host --location <loc> --main-ip <IP> ... --virt-tier auto --accept-fallback --yes
bin/byoh-location grant --location <loc> --project <ubid>
```

On a packaged control plane the same steps are `sudo ubicloud-admin site rates|set|grant <loc> ...` and `sudo ubicloud-admin host add --site <loc> --ssh <user>@<IP> ... --virt-tier auto --accept-fallback`. PVM takes the kernel pins on `site set` and `--virt-tier pvm --install-pvm-kernel --accept-fallback` on `host add`; [QUICKSTART.md](../QUICKSTART.md) §5 has both.

Leave out `--default-boot-image` for a lower tier: the host downloads its tier's image
(`ubuntu-noble-container` for `container`), and registration refuses an image the tier cannot boot.
Size the VPS for at least one VM of the smallest size beside the core and memory kept for the host
(`bootstrap-data-plane.sh` and `verify_tier_capacity` check it): about 4 vCPUs without SMT and 12 GiB
for `container` (a `container-2` VM has 8 GiB), about 4 vCPUs and 6 GiB for `emulated`. A 2-vCPU plan
can never place a VM.

Customers then create a `container-2` (or `emulated-2`) VM through the API or with
`ubi vm <loc>/<name> create -s container-2 "<public key>"`; the web form offers no lower-tier size, and
the VM page says what the VM is. Nothing on this list has run on a real VPS (UNVERIFIED; NO_KVM.md §14, L3-T1 and L5-T1).

A VPS without KVM is also useful in two roles on any branch:

| Role | Works? | Notes |
|---|---|---|
| **Control plane** | Yes, in principle | The control plane needs no KVM: Ubuntu 24.04, Postgres, `puma`, `respirate` ([SETUP.md](../SETUP.md) §4). It must reach every data-plane host's main IP over SSH (C0). The live AWS environment uses a t3.large (terraform default t3.medium). |
| **Tunnel endpoint** for a data plane behind CGNAT or with a single IP | Recipe only | NETWORKING §9.4: the VPS gets a routed block or floating IPs and routes them into a WireGuard `wg0` to the data plane. The data plane declares the block `routed` + `public`. The scripts `scripts/byoh/providers/wireguard-tunnel/*` are **PLANNED and do not exist**, so you set up WireGuard yourself. The pools file `uplink: wg0` key is stored but never used. Pool-sourced traffic needs your own policy routing on the data plane (`ip rule add to <block> lookup main priority 999`, `ip rule add from <block> lookup 100 priority 1000`, `default dev wg0` in table 100), and it must survive reboots. UNVERIFIED end to end. |

To run standard VMs, move the data plane to a provider with nested virtualization (AWS m8i/c8i/r8i, GCP N2/C3, some Azure sizes, OCI E5/Standard3 VMs) or to bare metal (OCI bare metal, Scaleway Elastic Metal, Vultr Bare Metal, Hetzner Robot, OVH dedicated).

### 1.4 Nested virtualization and live migration

Several providers say nested virtualization conflicts with live migration: OVH Public Cloud (guest kernel panic) and Linode (the reason it is not supported) *(provider docs and community report, UNVERIFIED here)*. On a nested-virt VPS, assume a provider maintenance event can kill the data plane and every VM on it without warning. Use these hosts for labs and tests, and bare metal for anything customers rely on.

---

## 2. Requirements

### 2.1 Host

The same rules as every platform (PLATFORMS.md §1, SETUP.md §2). These matter most on VPS plans:

| Requirement | Check | Typical VPS problem |
|---|---|---|
| Ubuntu 24.04 LTS, x86_64 | `lsb_release -rs`; `uname -m` | Arm plans (OCI Ampere, Scaleway Arm types) are reported to lack nested KVM *(UNVERIFIED here)* |
| KVM | `test -c /dev/kvm`; `grep -Ewc 'vmx\|svm' /proc/cpuinfo` | Missing on most VPS plans; see §1.3 |
| 1G hugepages | `grep -qw pdpe1gb /proc/cpuinfo` | Some virtual CPU models hide `pdpe1gb`; pick a newer instance family |
| RAM | 14 GiB or more, 16+ recommended. Hugepages = `total_mem_gib*42/43 - 5` (`prog/setup_hugepages.rb`), and the smallest slice books 8 | Small VPS plans cannot host one VM |
| Memory size readable | `sudo dmidecode -t memory` | Fixed in M2: LearnMemory now sums kB/MB/GB/TB sizes and falls back to `MemTotal` when a virtual board lists no memory devices (a0259a997) |
| CPUs | ≥ 2 physical cores beyond CPUs 0-1, uniform threads per core, all online (`lscpu -e`) | 2-vCPU plans are too small |
| Disk | VM disks live under `/var/storage` on ext4 or xfs. Mount extra volumes at `/var/storage/devices/<name>` **before** registration | Block-storage volumes have no SMART or `wwn-` links: **do not start `bin/monitor`** (PLATFORMS F5) |
| Dedicated machine | Nothing else on it: no Docker, ufw, Tailscale, k3s or libvirt | Their nftables rules are flushed on every VM create and destroy |
| One uplink address | `ip -br -4 addr` shows only the main IP (on OCI with the control plane outside the VCN: only the primary private IP, §3.6) | Provider agents and cloud-init add extra IPs to the NIC (C5) |

### 2.2 Network

| Item | Requirement |
|---|---|
| Outbound internet | HTTPS to github.com and cloud-images.ubuntu.com, and HTTP (80) to cloud-images-archive.ubuntu.com (the pinned Ubuntu releases redirect there), for PrepHost and boot images. On clouds where egress is not the default (Azure after 2025-09-30, private OCI subnets), add a NAT gateway or a public IP. |
| Pool addresses | At least one free IPv4 address of the right exposure per VM with IPv4. A VM without IPv4 (`ubi vm … create -6`) needs no pool. |
| Provider firewall | Allow all traffic to the pool addresses (DigitalOcean Cloud Firewall, Vultr firewall group, OCI security list / NSG, Scaleway security group, OVH network firewall). Allow SSH to the host's main IP only from the control plane and your admin IPs. |
| Virtual MACs | None on any pool address (Scaleway flexible IP virtual MAC, OVH vMAC). |
| IPv6 | Optional. A routed /64 is `gua` with `ndp=false`, and an on-link /64 needs `,ndp`. A provider /56 or /48: declare one /64 of it, because registration accepts only /64. Otherwise the host gets a ULA /64 (`ula`). |
| Guest MTU | Guests always get MTU 1400 from DHCP. `--guest-mtu` is stored but not applied. 1400 fits common cloud MTUs and WireGuard. |

### 2.3 Control-plane reachability

- **C0:** the control plane SSHes to the host's main IP as root. If the control plane runs at another provider, the main IP is the host's public IP. Allow port 22 from the control plane's egress IP only.
- **`--cp-reach`:**
  - `public` when the control plane is elsewhere. It dials internet VMs at their public or external address, and probes `internal` and no-IPv4 VMs from inside their namespace on the host.
  - `onhost` only when the control plane sits in the same VPC or private network and can reach the pool addresses directly. For example, on OCI the control plane can be in the same VCN.

---

## 3. Step by step

### 3.1 Provision the machine

| Provider | What to order |
|---|---|
| OCI | A bare-metal shape, or VM.Standard.E5.Flex / VM.Standard3.Flex, with Canonical Ubuntu 24.04, in a **public** subnet. Then, on the primary VNIC, add one secondary private IP per VM, and assign a reserved public IP to each *(provider docs, UNVERIFIED here)*. |
| Scaleway Elastic Metal | An Elastic Metal server with Ubuntu 24.04, then flexible IPv4s (and optionally a flexible IPv6 /64) attached to it, **without** a virtual MAC. |
| Vultr Bare Metal | A bare-metal instance with Ubuntu 24.04, then reserved IPs attached to it. |
| OVHcloud Public Cloud | An instance with Ubuntu 24.04, then Additional IPs attached to it, in the same project. Lab only (§1.4). |
| DigitalOcean | An Intel Droplet with Ubuntu 24.04 large enough for §2.1. Check `/dev/kvm` **before** anything else. Optionally assign one reserved IP. Lab only. |
| Vultr VPS, Scaleway Instances, Linode | Create the smallest plan, run the §3.2 check, and destroy it if the check fails. |
| Hetzner Cloud | Not as a data plane (§1.3). |

**Do not configure pool addresses in the OS.** Several providers' guides tell you to add Additional, Floating or Reserved IPs to netplan, or do it themselves (Hetzner Cloud floating IP guide, the OVH Additional IP guide, the Vultr restart). For BYOH, skip that step. If an agent or cloud-init added them, remove them, and keep them from coming back after a reboot (the AWS fix is in SETUP.md §12).

### 3.2 Data-plane bootstrap

On the host, as a sudo user:

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

Which branch carries the code this page describes: [README.md](README.md) "Which branch". Step "1b. hardware virtualization" is the KVM test. If it prints `ERROR: /dev/kvm is missing`, stop here (§1.3); on branch `no-kvm`, `--tier auto` prepares the fastest fallback instead. The script also enables root public-key login and installs `ruby-bundler` and `netcat-openbsd`. It does not touch the network.

Then check that the host has only its main IPv4:

```bash
ip -br -4 addr                   # only the main IP (plus lo); OCI: only the primary private IP
ip route show table local | grep -v '127\.'   # no pool addresses
```

On the control plane:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
ssh <admin user>@<host main IP> "sudo tee -a /root/.ssh/authorized_keys" < ~/.ssh/byoh_data.pub
ssh -i ~/.ssh/byoh_data root@<host main IP> true && echo ok
```

### 3.3 Control plane

Follow [SETUP.md](../SETUP.md) §4. The control plane may run on any of these providers, including a KVM-less VPS or Hetzner Cloud, because it needs no KVM. Keep `RACK_ENV=development`.

### 3.4 Create the BYOH location

One location per site. Choose `--underlay` to cover the provider-private networks the host sits in, and the control plane's address. VMs may not open connections into these networks through the host NAT.

```bash
cd ~/ubicloud
bundle exec bin/byoh-location create --name <site> --ui-name "<Name shown to customers>" \
  --underlay <VPC/VCN or private-network CIDRs> \
  --overlay 172.20.0.0/14 \
  --cp-reach public \
  --cp-source <control plane egress IP>/32 \
  --mgmt-allow <control plane IP>/32,<admin IP>/32 \
  --rates-from hetzner-fsn1
```

Notes for this page's providers:

| Provider | `--underlay` | `--cp-reach` |
|---|---|---|
| OCI | The VCN CIDR | `public`; `onhost` if the control plane is in the same VCN |
| Scaleway Elastic Metal, Vultr, OVH Public Cloud, DigitalOcean | The provider's private network (VPC) CIDR if the host is attached to one. Otherwise the host's own main IP as a /32. | `public` |

- `--overlay` must be RFC 1918 and must not overlap the underlay. Pick another /14 if your VPC uses 172.20.0.0/14.
- `--ula48` is generated at random; pass one only to match an existing host's `net6`.
- `BILLING_RATES_EXTRA_DIR` must be set in `.env.rb` (`bootstrap-dev-ctrl-plane.sh` writes it; VERIFY.md §1.1); a packaged control plane has it in `/etc/ubicloud/env`. Restart `puma`, `respirate` and, if it runs, `bin/monitor` (packaged: `systemctl restart ubicloud.target`), so they load the copied rates. Check with `bundle exec bin/byoh-location show --location <site>`, which also prints the `Rate file` it uses. Grant your project in §3.9, once the account exists.

### 3.5 pools.yaml for each provider

The format and rules are in POOL_OPERATIONS.md §1. Replace every `<...>`. The file refuses documentation ranges such as 203.0.113.0/24 as external IPs.

**OCI (secondary private IPs + reserved public IPs), `fabric` + `nat`** (UNVERIFIED):

```yaml
version: 2
uplink: <primary VNIC interface, e.g. from ip -br link>   # informational
routed_networks:
  - cidr: <secondary private IP 1>/32       # assigned to the VNIC in OCI, absent from the OS
    delivery: fabric
    exposure: nat
    external:
      <secondary private IP 1>: <reserved public IP 1>
  - cidr: <secondary private IP 2>/32
    delivery: fabric
    exposure: nat
    external:
      <secondary private IP 2>: <reserved public IP 2>
  # - cidr: <secondary private IP 3>/32    # without a public IP: reachable in the VCN only
  #   delivery: fabric
  #   exposure: internal
```

**Scaleway Elastic Metal flexible IPs, Vultr Bare Metal reserved IPs and OVH Public Cloud Additional IPs, `routed` + `public`** (UNVERIFIED):

```yaml
version: 2
uplink: <uplink interface>
routed_networks:
  - cidr: <flexible / reserved / additional IPv4 1>/32
    delivery: routed
    exposure: public
  - cidr: <flexible / reserved / additional IPv4 2>/32
    delivery: routed
    exposure: public
  # - cidr: <flexible IPv6 /64>              # Scaleway flexible IPv6; routed, so no ndp
```

**DigitalOcean reserved IP on the anchor IP, `onlink` + `nat`, one VM** (theory, UNVERIFIED). The risks: nobody has tried it; cloud-init re-adds the anchor IP to `eth0` after a reboot unless you stop it (C5, as on AWS); and the host must answer ARP for the anchor IP on the anchor segment through proxy_arp, which DigitalOcean's network may not accept:

```yaml
version: 2
uplink: eth0
routed_networks:
  - cidr: <anchor IP>/32                    # removed from eth0 first (C5)
    delivery: onlink
    exposure: nat
    segment: <anchor network, e.g. from ip -4 addr show eth0>
    gateway: <anchor gateway>
    external:
      <anchor IP>: <reserved IP>
```

**Linode routed IPv6** (only if KVM is available). Add one entry, and register with `--ipv6-mode gua`:

```yaml
  - cidr: <routed /64 from your range>
```

**Single public IP, no extra addresses:** no pool file. See §3.7.

### 3.6 Register the host

```bash
bundle exec bin/register-byoh-host \
  --location <site> \
  --main-ip <host main IPv4> \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble \
  --yes
```

- `--main-ip` is the address the control plane SSHes to:
  - OCI: the primary private IP, with the control plane in the VCN or reaching it through a site VPN (as AWS does). The instance's public IP is 1:1 NATed by OCI and is not on the NIC, so registering it as `--main-ip` is an untested case (UNVERIFIED): the NIC carries only the private IP, the "only the main IP" checks (§2.1, §3.2, §3.8) cannot hold, and gate `g5` reports "other addresses on the host: … <private IP>".
  - Elsewhere: the public IP.
- Other flags: `--routed-network CIDR[,key=value...]` (inline pools, repeatable), `--ipv6-mode gua|ula`, `--server-identifier`, a second `--default-boot-image ubuntu-jammy`. There is no `--provider` and no `--uplink` flag. The BMC flags do not apply to cloud hosts.
- Bring-up reboots the host once. It took about 4 minutes on a nested-virtualization AWS instance and 15-25 minutes on bare metal. Watch the state with `psql -U clover -d clover_test -c "SELECT allocation_state FROM vm_host WHERE id='<uuid>'"` or `bundle exec scripts/byoh/verify/m2-checks host --host vh...` until `allocation_state = accepting`; keep `/tmp/respirate.log` for errors.

**First IP on a provider whose delivery is unknown** (Vultr, OVH Public Cloud): register with one pool address, create one VM, and run the checks in §3.9 before you add the rest with `bin/byoh-pool add --host vh... --pool <ip>/32,delivery=routed,exposure=public`. If inbound to that VM never arrives while egress works, the provider does not route the IP to the main IP. Remove it with `bundle exec bin/byoh-pool remove --host vh... --pool <ip>/32 --drain`. (The DigitalOcean anchor is not part of this test: a Droplet holds one reserved IP, so there is nothing to add after it.)

### 3.7 Single public IP (no extra IPv4)

This is the usual case on a VPS that has KVM but no extra IPs. Register with only `--main-ip` and no pool:

```bash
bundle exec bin/register-byoh-host --location <site> --main-ip <public IP> \
  --ssh-key ~/.ssh/byoh_data --default-boot-image ubuntu-noble --yes
```

- VMs **without IPv4** (`ubi vm <site>/<name> create -6 ...`) place fine. Their outbound IPv4 leaves through the host NAT (`--vm-egress-nat4` is on by default). On a `ula` host their IPv6 is not reachable from the internet.
- An `internal` pool works too. Declare a private block, for example `--routed-network 10.250.0.0/28,delivery=routed,exposure=internal`. It is reachable only from the host, and by default it leaves through the host NAT (`internal_egress: host_nat`).
- No VM can get internet IPv4.
- Inbound access today is operator-only, through the VM's namespace on the host:

```bash
bundle exec scripts/byoh/verify/m2-checks info --vm vm...     # prints private_ip4= and inhost=
ssh -o "ProxyCommand=ssh -i ~/.ssh/byoh_data root@<main IP> ip netns exec <inhost> nc %h %p" ubi@<private_ip4>
```

- The customer access tunnel (`ubi vm … ssh --tunnel`) is PLANNED (milestone M6). Port forwards on the host IP are lab helpers only (NETWORKING §3.3).
- For internet ingress, use the tunnel recipe (§1.3, NETWORKING §9.4).

### 3.8 Verify the pools

```bash
bundle exec bin/byoh-pool verify --host vh...                                  # no FAIL lines
bundle exec bin/byoh-pool list --host vh...
ssh -i ~/.ssh/byoh_data root@<main IP> nft list table inet byoh_egress        # loaded
ssh -i ~/.ssh/byoh_data root@<main IP> ip -br -4 addr                         # only the main IP
```

### 3.9 Create VMs and run the gate

Create an account and an SSH key in the UI, grant its project access to the location, and create VMs in the location (SETUP.md §9):

```bash
bundle exec bin/byoh-location grant --location <site> --project <project ubid>
```


```bash
ubi vm <site>/vm1 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"               # internet IPv4 (public or nat pool)
ubi vm <site>/vm2 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"   # internal IPv4
ubi vm <site>/vm3 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"            # no IPv4
```

Run the gate with the settings in VERIFY.md §1.4 and §2.5. For this page's providers:

```bash
export GATE_LOCATION=<site> GATE_HOST=vh... GATE_MAIN_IP=<main IP> GATE_EXPECT_MONITOR=0
export GATE_HOST_KEY=~/.ssh/byoh_data GATE_VM_KEY=~/.ssh/id_ed25519 GATE_VM_B=vm... GATE_VM_C=vm...
# g9b targets (UNVERIFIED on these providers): the deny set is underlay + cp_source + mgmt_allow + egress_deny
export GATE_CTRL_PRIV=<an address inside --cp-source: the control plane's egress IP when it is at another provider>
export GATE_UNDERLAY_PROBE=<a VPC host with SSH open; with only the host's own /32 as underlay, the main IP>
export GATE_SMTP_PROBE=<an internet host that accepts TCP 25>
# routed + public (Scaleway, Vultr, OVH):
GATE_VM_A=vm... GATE_VM_A_EXPOSURE=public scripts/byoh/verify/m2-gate.sh g1 g2 g3 g4 g5 g6 g7 g8 g9 g9b g13
# fabric + nat (OCI) or the DigitalOcean anchor: the same steps with GATE_VM_A_EXPOSURE=nat (the default)
# add g10 (needs GATE_VM_D, once every internet address is taken) and g11 (needs GATE_NEW_EXTERNAL, nat only) when they apply
# single IP, no internet pool:
scripts/byoh/verify/m2-gate.sh g1 g2 g3 g4 g5 g7 g8 g9 g9b
```

Then G12-G15 ([VERIFY.md](../VERIFY.md) §2.5): `g12 g13`, `g15-before`/`g15-after` around 20 VM create/destroy cycles, and `g14` after an admin reboot. `g8` and `g14` need `GATE_VM_C`, so they need an `internal` pool; without one, leave out `g8` and run `g5 g7 g9` instead of `g14`. The main IP as `GATE_UNDERLAY_PROBE` works because the host's `input` chain drops VM connections to its own `deny4` addresses (`rhizome/host/lib/byoh_egress_nat.rb`). On OCI with a NAT'd public `--main-ip`, `g5` reports the private IP (§3.6).

- `GATE_EXPECT_MONITOR=0`, because cloud block storage has no SMART.
- G11 (remap) needs a `nat` pool and a second external IP. G17 is "remove the machines".
- The gate has been run only on AWS, so on these providers it is UNVERIFIED.

---

## 4. Problems and solutions

| Symptom | Cause | Fix |
|---|---|---|
| `bootstrap-data-plane.sh` stops: `ERROR: /dev/kvm is missing, so KVM is unavailable.` | The VPS plan exposes no nested virtualization (Hetzner Cloud, Linode, most VPS plans) | Use bare metal or a nested-virt instance type (§1.3), or keep the VPS as control plane or tunnel endpoint. On branch `no-kvm`: `bin/byoh-virt probe` for the provider's fix, or the experimental `container`/`emulated` tiers (§1.3) |
| `ERROR: the CPU has neither the vmx nor the svm flag.` although `/dev/kvm` exists | The plan or the CPU vendor lacks nested support (DigitalOcean AMD hosts per a feature request, UNVERIFIED) | Pick an Intel plan or another family; on DigitalOcean check `cat /sys/module/kvm_intel/parameters/nested` |
| `ERROR: the CPU lacks the pdpe1gb flag` | The virtual CPU model hides 1G pages | Pick a newer instance family. For standard VMs there is no workaround until the `flexible` host profile (COMPUTE.md, PLANNED). The `container` and `emulated` tiers (branch `no-kvm`) use no hugepages |
| Host and all VMs vanish, then the host comes back rebooted | The provider live-migrated a nested-virt guest, which can panic the kernel (OVH Public Cloud FAQ) | Expected on nested-virt VPS. Use bare metal for real workloads (§1.4). |
| VM setup fails: "X is a local address of this host, so the host answers for the VM" | The provider's agent, cloud-init or your netplan put the pool IP on the NIC (OVH, Hetzner Cloud and Vultr IP guides all add it) | Remove the address from netplan and the interface, stop the agent from re-adding it, then retry. `ip -br -4 addr` must show only the main IP. |
| SSH to a VM's public IP gives "Permission denied (publickey)" | As above, on a VM created before M2 | As above, then recreate the VM |
| Inbound to a `routed` /32 times out; VM egress works | The provider does not route the IP to the host's main IP: it is on-link, needs a virtual MAC, or is still unassigned in the console | Check the provider console. Remove any virtual MAC (Scaleway, OVH). Without a routed delivery it cannot work (NETWORKING §9.5): `bundle exec bin/byoh-pool remove --host vh... --pool <ip>/32 --drain`. |
| Inbound times out on every pool IP on OCI | The secondary private IP has no reserved public IP, or the security list / NSG blocks it | Assign the public IP to the secondary private IP and allow all traffic to the pool private IPs |
| PrepHost fails on OCI or DigitalOcean; the host never reaches `accepting` | The host itself has no egress: no public IP (private subnet) and no NAT gateway | Put the host in a public subnet or add a NAT gateway; check `curl -sI https://cloud-images.ubuntu.com` on the host |
| A VM answers on IPv4 but its outbound fails, while the host's own egress works (OCI) | The pool private IPs have no egress path: no NAT gateway route or security-list egress rule for them (UNVERIFIED) | Allow egress for the pool private IPs in the security list / NSG, and check the route table |
| PrepHost fails right after registration | No outbound internet, or the provider firewall blocks egress | Allow outbound HTTPS; rerun |
| `bin/byoh-pool verify` warns about a `public` pool, or registration refuses `exposure: public` | The address is RFC 1918 (OCI and DO private addresses) | Use `fabric`/`onlink` + `nat` with the public IP as `external`, or `internal` |
| VM creation waits for capacity: "no space left on any eligible host" | No free address of the requested exposure (single-IP hosts have none for internet VMs), no `ubuntu-noble` image, too few cores or hugepages on a small plan | Create with `-6` or `-e internal`; add pools with `bin/byoh-pool add`; size the plan per §2.1 |
| Pool IP lost after the provider moved it | Floating/flexible/reserved IPs can be moved in the console (Scaleway, OVH within a project, DigitalOcean) | Treat the console as the source of truth: `bin/byoh-pool remove --drain`, or `remap` for a `nat` external |
| VM stuck at `wait_sshable` | `--cp-reach onhost` but the control plane is at another provider | `bin/byoh-location set --location <site> --cp-reach public` |
| Health checks fail or the host goes `unavailable` | `bin/monitor` was started on a host with cloud block storage | Stop `bin/monitor`. It is one global process with no per-host switch, so do not run it while any host uses cloud block storage (PLATFORMS F5) |
| Two VMs on a DigitalOcean host want internet IPv4 | A Droplet holds one reserved IP *(provider docs, UNVERIFIED here)* | Only one `nat` address per Droplet; other VMs use `-6` or `internal` |

Common problems that are not specific to these providers are in NETWORKING.md §11, SETUP.md §11, PLATFORMS.md §7 and [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

---

## 5. Status

- **Tested:** nothing on this page. The only end-to-end validation of BYOH is on AWS (m8i nested virtualization and `.metal`, ap-south-1).
- **UNVERIFIED:**
  - Every provider row, including the nested-virtualization reports.
  - How each provider delivers extra IPs (routed or on-link).
  - The DigitalOcean anchor-IP mapping.
  - The tunnel recipe.
  - Branch `no-kvm` on any of these providers: the probe's provider rows (L2-T6) and the `container` and `emulated` tiers on a real VPS (NO_KVM.md §14, L3-T1, L5-T1).
- **Known gaps:**
  - Virtual/separate MACs are not supported.
  - The pools file `uplink` key is stored but never used, so pools on a second interface or `wg0` need operator policy routing.
  - `--guest-mtu` is not applied.
  - `,ndp` needs a single-device default route.
  - There is no customer access tunnel until M6.
  - Health checks on cloud block storage are OPEN (F5).
  - The WireGuard tunnel scripts are PLANNED.
- **Not researched:** Leaseweb, extra IPv4 on Linode, Scaleway Dedibox/Online and Scaleway Instances IPs, and how Vultr delivers its IPs.

Sources (provider docs and community posts, UNVERIFIED here):
- **DigitalOcean:**
  - [nested KVM question](https://digitalocean.com/community/questions/does-digitalocean-support-kvm-or-nested-virtulzation)
  - [nested KVM on AMD (feature request)](https://ideas.digitalocean.com/core-compute-platform/p/enable-nested-kvm-in-amd-servers)
  - [reserved IPs](https://docs.digitalocean.com/products/networking/reserved-ips/how-to)
  - [reserved IP limits](https://docs.digitalocean.com/products/networking/reserved-ips/details/limits)
- **Vultr:**
  - [bare metal IPv4](https://docs.vultr.com/products/compute/instances/bare-metal/networking/ipv4)
  - [bare metal reserved IPs](https://docs.vultr.com/products/compute/instances/bare-metal/networking/reserved-ips)
  - [NANOG 2021 thread](https://mailman.nanog.org/pipermail/nanog/2021-January/211590.html)
- **Linode/Akamai:**
  - [nested virtualization question](https://www.linode.com/community/questions/19459/do-any-linode-regionsinstances-support-nested-vmvirtualization)
  - [IPv6 overview](https://techdocs.akamai.com/cloud-computing/docs/an-overview-of-ipv6-on-linode)
- **Oracle:**
  - [KVM nested virtualization in OCI](https://blogs.oracle.com/linux/post/kvm-nested-virtualization-in-oci)
  - [private IP addresses](https://docs.oracle.com/iaas/Content/Network/Tasks/managingIPaddresses.htm)
- **Scaleway:**
  - [order a flexible IP](https://www.scaleway.com/en/docs/elastic-metal/how-to/order-flexible-ip/)
  - [attach or detach a flexible IP](https://www.scaleway.com/en/docs/elastic-metal/how-to/attach-detach-flexible-ip/)
  - [LowEndTalk thread](https://lowendtalk.com/discussion/comment/3265827/)
- **Hetzner:**
  - [Cloud Floating IPs](https://docs.hetzner.com/cloud/floating-ips/getting-started/adding-a-floating-ip/)
  - [Floating IP FAQ](https://docs.hetzner.com/cloud/floating-ips/faq)
  - [nested virtualization blog post](https://blog.wirelessmoves.com/2022/05/nested-virtualization.html)
- **OVHcloud:**
  - [Public Cloud FAQ](https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/faq-pci)
  - [buy an Additional IP](https://docs.ovhcloud.com/en/guides/public-cloud/network-services/buy-additional-ip)
  - [configure an Additional IP](https://docs.ovhcloud.com/en/guides/public-cloud/network-services/configure-additional-ip)
