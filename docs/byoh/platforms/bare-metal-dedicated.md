# BYOH on rented dedicated servers (Hetzner, OVH, Leaseweb, others)

This guide covers turning a rented dedicated server into a BYOH data-plane host (VmHost). It applies to Hetzner Robot, OVH / So you Start / Kimsufi, Leaseweb, and any other provider that rents whole machines.

**Status: UNVERIFIED.** Only AWS (m8i with nested virtualization, ap-south-1) has been tested end to end. Nothing on this page has run on a rented dedicated server. Provider facts are labelled "provider docs, UNVERIFIED here" or "forum reports, UNVERIFIED here". Leaseweb was not researched. No prices or limits are given, because none were checked.

The steps match [SETUP.md](../SETUP.md). This page adds what differs on rented bare metal: installing the OS, the provider's address products, RAID, BMCs, and the single-IP case. Design background: [NETWORKING.md](../NETWORKING.md) §3 and §9.5. Host requirements and preflight: [PLATFORMS.md](../PLATFORMS.md) §1 and §6.

---

## 1. Fit

Rented bare metal is the setup upstream Ubicloud was built for: native KVM, real disks with `wwn-`/`nvme-eui` links, and a provider that routes extra addresses to the server's main IP.

| Provider product | NETWORKING §3 model | Notes |
|---|---|---|
| Hetzner additional subnet | `routed` + `public` | Hetzner routes subnets to the main IP (provider docs, UNVERIFIED here) |
| Hetzner single additional IP **without** a separate MAC | `routed` + `public`, as a `/32` | |
| Hetzner failover IP or subnet | `routed` + `public` | Belongs to one host at a time; moving it means moving the pool (§4, row 10) |
| Hetzner vSwitch public subnet (VLAN) | `onlink` + `public` | Needs operator policy routing (this page §3.6 B). UNVERIFIED end to end |
| OVH / So you Start Additional IP or IP block, **routed mode** (no vMAC) | `routed` + `public` | OVH: no virtual MAC may be set on the IP (provider docs, UNVERIFIED here) |
| Kimsufi | single public IP (this page §3.7) | Forum reports say Kimsufi servers cannot have additional IPs (forum reports, UNVERIFIED here) |
| Leaseweb routed block | `routed` + `public` | Not researched. If Leaseweb needs an address of the block on the NIC, `reserve=` it (this page §3.6 A) |
| Any provider: a block routed to the main IP | `routed` + `public` | The normal case |
| Any provider: an IP tied to its own MAC (OVH vMAC, Hetzner "separate MAC") | **not supported** | Rhizome routes every VM behind the host's MAC. Remove the vMAC or separate MAC, or order a routed block |
| One public IP only | no IPv4 pool, or an `internal` pool | this page §3.7 |

Use a rented dedicated server when you want public IPv4 per VM with no NAT and no cloud SDN. Don't use one if the only address product available is bridged/vMAC, or if you need VM IPs that move between hosts: pools are tied to a host.

---

## 2. Requirements

### 2.1 Host

| Requirement | Check | Notes for rented servers |
|---|---|---|
| Ubuntu 24.04 LTS, x86_64 | `lsb_release -rs` | Install it from the provider's installer or rescue system (§3.1) |
| KVM | `test -c /dev/kvm`; `grep -Ewc 'vmx\|svm' /proc/cpuinfo` | Native on bare metal. If missing, VT-x/AMD-V is off in the firmware; ask the provider's support. `bootstrap-data-plane.sh` refuses the host without it |
| `pdpe1gb` CPU flag | `grep -qw pdpe1gb /proc/cpuinfo` | Needed for 1G hugepages |
| Not a hybrid P+E-core CPU; SMT on; all CPUs online | `lscpu -e` | Some rental lines use Intel 12th–14th gen desktop CPUs with P and E cores; every VM then fails with `BUG` (PLATFORMS #5, OPEN). Check `lscpu` before you order or register |
| RAM ≥ 14 GiB, 16+ recommended | `dmidecode -t memory` | Since M2 LearnMemory accepts kB/MB/GB/TB sizes and falls back to `MemTotal` when there are no entries |
| GRUB with a `GRUB_CMDLINE_LINUX="..."` line | `grep ^GRUB_CMDLINE_LINUX= /etc/default/grub` | Hugepage arguments are appended there |
| `/var/storage` on ext4 or xfs | `mkdir -p /var/storage; findmnt -no FSTYPE --target /var/storage` | Not btrfs or ZFS (PLATFORMS #25) |
| Nothing else managing nftables | `systemctl is-active docker ufw tailscaled k3s libvirtd` | Their rules are flushed on every VM create and destroy |
| Dedicated machine | | Registration reboots the host, recreates the `rhizome` user, rewrites the sshd config and allocates hugepages |

### 2.2 Network

| Requirement | Notes |
|---|---|
| Main IPv4 configured by the installer, and nothing else | `ip -br -4 addr` shows only the main IP. **Never put pool IPs on the NIC (C5)**, even when the provider's own docs tell you to add an additional or failover IP to the network config. Since M2, VM setup on a BYOH host fails with "… is a local address of this host" when you do |
| Pool addresses routed to the main IP | Provider-side. The driver never changes upstream routing |
| Outbound HTTPS | PrepHost downloads cloud-hypervisor and htcat; boot images come from cloud-images.ubuntu.com |
| Provider firewall open for the pools | Hetzner Robot firewall: off, or allow everything to the pool addresses (NETWORKING §9.5). Any other provider-side firewall in front of the server: the same (UNVERIFIED) |
| IPv6 (optional) | One /64. Hetzner routes the server's /64 to the NIC's link-local address (provider docs, UNVERIFIED here), so declare it without `ndp`. OVH: an on-link /64 needs `,ndp`. OVH High Grade and Scale servers get a /56, so declare one /64 out of it. Kimsufi gets a single /128, so no /64 can be declared (provider docs, UNVERIFIED here) |

### 2.3 Control-plane reachability

- The control plane must SSH to the main IP as root (port 22). On rented bare metal the control plane is usually somewhere else, which means `--cp-reach public`.
- With `cp_reach: public`, the control plane checks internet VMs at their public address and probes the other VMs from their namespace on the host. A `public` pool VM must therefore be reachable on port 22 from the control plane, so the provider firewall must allow it.
- Add the control plane's egress IP to `--cp-source`, and to `Config.control_plane_outbound_cidrs` if you narrow that from its `0.0.0.0/0,::/0` default (NETWORKING §6.6).

---

## 3. Step by step

### 3.1 Provision the machine and install Ubuntu 24.04

Pick a machine that passes §2.1. Then install Ubuntu 24.04 with a layout that suits Ubicloud (§3.2).

**Hetzner (Robot).** Provider docs, UNVERIFIED here:
1. In Robot, activate the Rescue System for the server, optionally with your SSH key, and reset the server so it boots into rescue. Log in as root.
2. If the server has a hardware RAID controller, create the array first. If an OS is already installed, stop any active software RAID and wipe the partition tables.
3. Run `installimage`, choose the Ubuntu 24.04 image, and edit the config in the editor (`mcedit`): drives, `SWRAID`/`SWRAIDLEVEL`, partitions, hostname. A file at `/autosetup` in rescue skips the menu.
4. Save with F10, wait for "Installimage done", then `reboot`. The installed system's root password is the rescue password.

**OVH / So you Start / Kimsufi.** Reinstall from the control panel with an Ubuntu 24.04 template and custom partitioning if offered. For recovery, OVH offers a rescue mode in the control panel. Not researched here: follow the provider's current guide.

**Leaseweb and others.** Use the provider's OS installer or rescue/PXE flow. Not researched.

After the first boot, as root:

```bash
lsb_release -rs                      # 24.04
ip -br -4 addr; ip route show default
grep -E '^GRUB_CMDLINE_LINUX=' /etc/default/grub
```

Remove any additional or failover IPs the installer or you added to netplan. Keep only the main IP and the provider's IPv6 host address, if it set one.

### 3.2 Disk and RAID layout

| Layout | Works? | Notes |
|---|---|---|
| Software RAID (mdadm) with ext4 `/` | Yes, the upstream layout | LearnStorage expands `/dev/mdN` to its member disks through `/proc/mdstat`, and IO limits and crypt swap resolve `md-uuid-` links. Health checks look at the member disks, which have `wwn-`/`nvme-eui` links |
| RAID1 vs RAID0 | Both work | RAID1 halves capacity and survives a disk loss; RAID0 doubles capacity and loses everything on one disk failure. Ubicloud does not replicate VM disks |
| Hardware RAID virtual disk | Probably | The virtual `sdX` may have no `wwn-` link. IO limits fall back to the path (e6f5e328e); health checks then fail (F5), so don't start `bin/monitor`. UNVERIFIED |
| LVM root | Yes for VMs | `dm-uuid-` links serve IO limits; health checks do not (F5) |
| btrfs or ZFS for `/var/storage` | **No** | `Errno::ENOENT` on every VM prep (PLATFORMS #25) |
| Extra disks or arrays | Only when mounted **before** registration | Mount each at `/var/storage/devices/<name>` (`UUID=` in fstab). Disks that aren't mounted are ignored (STOR-3). Never mount anything over `/var/storage` after registration |
| Swap | Optional | With a swap partition (also on md), prep moves it to dm-crypt. With no fstab swap entry, prep skips that step |

Give most of the space to the filesystem that holds `/var/storage`. That is `/` unless you mount `/var/storage` separately before registration. The host keeps 5 GiB of it back.

### 3.3 Data-plane bootstrap

On the host:

```bash
apt-get update && apt-get install -y git      # minimal provider images may lack git (UNVERIFIED for installimage and OVH templates)
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

The script is self-contained, so copying only `scripts/byoh/bootstrap-data-plane.sh` to the host (scp) works too. Which branch carries the code this page describes: [README.md](README.md) "Which branch". The script checks Ubuntu 24.04, `/dev/kvm`, `vmx`/`svm` and `pdpe1gb`. It enables `PermitRootLogin prohibit-password` and installs `ruby-bundler` and `netcat-openbsd`. It does not touch the network.

Run the read-only preflight from [PLATFORMS.md](../PLATFORMS.md) §6.3 as well. On bare metal, PF12–PF14 (by-id links, SMART, `tsc` clocksource) normally pass. That is the only case where `bin/monitor` might suit the host, and it is UNVERIFIED with BYOH.

### 3.4 Control plane

Follow [SETUP.md](../SETUP.md) §4. The control plane can run anywhere that can SSH to the server's main IP: a second rented server, a cloud VM, or an office machine.

Create the control plane key, then install it as root on the host. The control plane has no root access to the host yet: the installer or rescue system put **your workstation's** key (or a root password) on root, and the bootstrap (§3.3) has already set `PermitRootLogin prohibit-password`, which blocks root password login. So append the key from the machine that already has root:

```bash
# on the control plane
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
cat ~/.ssh/byoh_data.pub                        # copy this line
# on the operator workstation, with the key installimage/rescue put on root
ssh root@<main IP> "cat >> /root/.ssh/authorized_keys" < byoh_data.pub
# or paste the line into /root/.ssh/authorized_keys on the host console (KVM/IPMI console, provider web console)
# back on the control plane
ssh -i ~/.ssh/byoh_data -o BatchMode=yes root@<main IP> true && echo ok
```

### 3.5 Create the location

Use one location per provider site, for example per Hetzner datacenter. Run this on the control plane from the repo root:

```bash
bundle exec bin/byoh-location create --name hetzner-byoh-1 \
  --ui-name "Hetzner (BYOH)" \
  --underlay <main IP>/32[,<vSwitch private subnet>] \
  --overlay 172.20.0.0/14 \
  --cp-reach public \
  --cp-source <control plane egress IP>/32 \
  --mgmt-allow <your operator IP>/32 \
  --rates-from hetzner-fsn1
```

| Option | Value on rented bare metal |
|---|---|
| `--cp-reach` | `public` when the control plane is outside the provider network (the usual case). Use `onhost` only when the control plane reaches the pool addresses directly, for example over the same vSwitch |
| `--underlay` | The host itself and any private vSwitch or vRack subnet. It goes into the host's deny set `deny4`, together with `--egress-deny`, `--cp-source` and `--mgmt-allow` (`ByohNetworkProfile#egress_nat4_params`). `deny4` is enforced in three places (`rhizome/host/lib/byoh_egress_nat.rb`): **every** VM, `public` ones included, cannot open connections to the host's own addresses in `deny4` (such as the main IP; `input` chain), nor to the RFC 1918 parts of `deny4` (such as a vSwitch private subnet; `forward` chain); host-NAT VMs (no IPv4, `internal`) cannot open connections to any `deny4` address. So the control plane's egress IP and your operator IP are unreachable from host-NAT VMs |
| `--mgmt-allow` | Who manages the hosts, for example your operator IP. **In M2 it is only added to `deny4`**, which keeps host-NAT VMs away from those addresses. It does **not** restrict SSH to the host: `host_guard` is PLANNED (NETWORKING §6.2). Limit host SSH with the provider firewall (Hetzner Robot firewall, OVH network firewall) |
| `--egress-deny` | Optional extra IPv4 CIDRs to keep host-NAT VMs away from |
| `--[no-]egress-smtp` | Outbound TCP 25 through the host NAT is off by default. Leave it off: abuse reports go to your server |
| `--guest-mtu` | Accepted but **not applied**: guests always get MTU 1400 through DHCP. That already fits a Hetzner vSwitch VLAN (1400) |

Then restart `puma` and `respirate` (and `bin/monitor`, if it runs), so they load the rates. Check the result:

```bash
bundle exec bin/byoh-location show --location hetzner-byoh-1
bundle exec bin/byoh-location grant --location hetzner-byoh-1 --project <pj... ubid>   # after you create your account
```

### 3.6 pools.yaml for this platform

Replace every `<...>`. Documentation ranges such as 203.0.113.0/24 are refused for `public`. Full rules: [POOL_OPERATIONS.md](../POOL_OPERATIONS.md) §1.

**A. Routed block and single routed IPs (Hetzner subnet or additional IP without separate MAC, OVH routed mode, Leaseweb, others):**

```yaml
version: 2
uplink: <NIC name, informational>
routed_networks:
  - cidr: <routed block, e.g. a.b.c.d/29>     # /24 or smaller, no host bits
    delivery: routed
    exposure: public
  - cidr: <additional single IP>/32           # one entry per routed single IP
    delivery: routed
    exposure: public
  - cidr: <IPv6 /64>                          # optional
    ndp: false                                # Hetzner: routed /64. OVH on-link /64: ndp: true
```

- `routed` pools use every address of the block, network and broadcast included, because each VM address is a /32 route. If your provider says otherwise for a block, hold addresses back with `reserve: [<ip>, ...]`.
- If the provider needs one address of the block on the host NIC, `reserve` that address. It is then never given to a VM, and C5 still holds for the rest.
- Never include the main IP's own subnet. A block that contains `--main-ip` is refused ("contains main_ip").

**B. Hetzner vSwitch public subnet on a VLAN. UNVERIFIED end to end:**

```yaml
version: 2
uplink: <vlan interface>              # stored, but Ubicloud does not act on it
routed_networks:
  - cidr: <vSwitch public subnet, e.g. a.b.c.48/29>
    delivery: onlink
    exposure: public
    segment: <the same subnet>/29
    gateway: <Hetzner's gateway in it, e.g. a.b.c.49>
    # reserve: [<address the host takes on the VLAN, if any>]
```

An `onlink` pool reserves the segment's network, broadcast and gateway (`usable: auto`). Ubicloud does not route the pool out of the VLAN. VM egress follows the main routing table, so you must add policy routing yourself and make it survive the reboot during bring-up:

```bash
ip rule add to <block> lookup main priority 999
ip rule add from <block> lookup 100 priority 1000
ip route add default via <vSwitch gateway> dev <vlan> table 100
```

The `to <block>` rule keeps traffic to the VMs on their `vetho*` routes. Persist all three: netplan `routing-policy` and `routes` with `table:` on the VLAN, or a systemd unit (UNVERIFIED). Hetzner documents a separate routing table for vSwitch public subnets and MTU 1400 on the VLAN (provider docs, UNVERIFIED here).

**C. Single public IP:** see §3.7.

### 3.7 The single-public-IP case (Kimsufi, a server with no extra IPs)

Register with only `--main-ip` and no IPv4 pool. Every location has a `ula48`, so the host gets a ULA /64 when you declare no IPv6.

| What VMs can do | How |
|---|---|
| VMs without IPv4 | Create them with `-6`. Their outbound IPv4 goes through the host NAT (`vm_egress_nat4`, default on) |
| Public IPv6 per VM | Only with a provider /64 (Hetzner, OVH; not Kimsufi's /128). Declare it with `--routed-network <v6>/64` (Hetzner) or `--routed-network <v6>/64,ndp` (OVH) |
| VMs with a private IPv4 | Declare an RFC 1918 `routed` + `internal` pool that only this host routes, for example `--routed-network 10.250.0.0/28,delivery=routed,exposure=internal`. It must not overlap `--overlay` (refused) and should not overlap `--underlay` (not checked). UNVERIFIED |
| VMs with internet IPv4 | Not possible; they wait for capacity. Add a block later with `bin/byoh-pool add`, or use the tunnel recipe (NETWORKING §9.4, PLANNED) |
| Inbound SSH to a VM | Jump through the host: `ssh -o "ProxyCommand=ssh -i <host key> root@<main IP> ip netns exec <inhost> nc %h %p" ubi@<private_ip4>` ([VERIFY.md](../VERIFY.md) §1.4). The customer access tunnel is milestone M6. Port forwards on the main IP are lab helpers only (NETWORKING §3.3) |

### 3.8 Register

```bash
bundle exec bin/register-byoh-host \
  --location hetzner-byoh-1 \
  --main-ip <main IPv4> \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble \
  --yes
```

- `ubuntu-noble` is `Config.default_boot_image_name` (`config.rb`), the image used when a VM names none. Add `--default-boot-image ubuntu-jammy` only if customers will pick jammy explicitly.
- `--routed-network CIDR[,key=value...]` is the inline form of a pool and may repeat; `--ipv6-mode gua|ula` overrides the derived mode; `--server-identifier` is optional (default `byoh-<uuid>`). There is no `--provider` flag.

**BMC / IPMI / Redfish.** These flags are optional. Use them only when the BMC speaks **Redfish** and the control plane can reach it:

```bash
  --bmc-endpoint https://<bmc address> \
  --bmc-user <user> \
  --bmc-pass-env BYOH_BMC_PASS \
  [--bmc-system-id <SystemId>] [--bmc-reset-type ForceRestart] [--bmc-verify-ssl]
```

| Fact | Consequence |
|---|---|
| Only `protocol: redfish` | An IPMI-only BMC (no Redfish) cannot be used. Many rented servers give customers no BMC at all. Check with your provider |
| `--bmc-pass-env VAR` is read **at call time** by respirate | `VAR` must be in the environment of the `respirate` process (for example via `.env.rb`), not only in your shell. Otherwise resets go out with a nil password |
| `--bmc-password` | Stored in plain text in `host_provider.config`. Prefer `--bmc-pass-env` |
| TLS verification off unless `--bmc-verify-ssl` | BMC certificates are usually self-signed |
| A BMC with several systems | Discovery fails with "returned multiple systems; set bmc.system_id explicitly". Pass `--bmc-system-id` |
| No BMC | **Never** click admin "Hardware Reset": it raises `CapabilityMissing` forever and wedges the host strand. Admin "Power On" returns an error (both OPEN; [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §8). Use the provider panel's reset (Robot, OVH control panel) instead; Ubicloud does not call provider reset APIs for generic hosts |
| Automated reimage | Never supported for generic hosts. Reinstall through the rescue system, then destroy and re-register the VmHost (host keys are pinned on first connect) |

Bring-up takes about 15–25 minutes on bare metal and **reboots the server once**. Everything the host needs (netplan, policy routing, mounts) must survive that reboot. Watch it:

```bash
tail -f /tmp/respirate.log
psql -U clover -d clover_test -c "SELECT allocation_state, os_version, total_cores, total_hugepages_1g FROM vm_host"
```

During prep, PrepHost pins the uplink in netplan by MAC. It skips the pin when a VLAN, bond, bridge or VRF names the NIC, and when the default route is multipath (since M2).

### 3.9 Verify the pools

```bash
bundle exec bin/byoh-pool list   --host vh...
bundle exec bin/byoh-pool verify --host vh...        # exit 0, no FAIL lines
ssh -i ~/.ssh/byoh_data root@<main IP> ip -br -4 addr                 # only the main IP
ssh -i ~/.ssh/byoh_data root@<main IP> nft list table inet byoh_egress
```

Change pools later with `bin/byoh-pool add`, `remove [--drain]` and `annotate`, with no re-registration ([POOL_OPERATIONS.md](../POOL_OPERATIONS.md)).

### 3.10 Create VMs

Follow [SETUP.md](../SETUP.md) §9. On a `routed` + `public` host, a VM with IPv4 gets a pool address that is directly reachable: `ssh ubi@<pool IP>`.

```bash
ubi vm <location>/vm1 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"               # public IPv4
ubi vm <location>/vm2 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"            # no IPv4
ubi vm <location>/vm3 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"   # needs an internal pool
```

### 3.11 Gate checks

Run `scripts/byoh/verify/m2-gate.sh` on the control plane with the "other platforms" settings ([VERIFY.md](../VERIFY.md) §1.4, §2.5):

| Site | Settings | Steps |
|---|---|---|
| Routed block (`public`) | `GATE_VM_A_EXPOSURE=public`, `GATE_IPV6_MODE` set to what you registered (or unset), `GATE_EXPECT_MONITOR=0` | `g1 g2 g3 g4 g5 g6 g7 g9 g9b`, plus `g8` with an internal pool. `g10` only once every public pool address is allocated (with a /29, 8 VMs before VM-D waits), or with a pool of 3 addresses or fewer. Then `g12`, `g13`, `g15-before`/`g15-after` around the create/destroy loop, and after the admin reboot `g14` (with an internal pool) or `g5 g7 g9` (without) |
| Single IP, no internet pool | as above | `g1 g2 g3 g4 g5 g7 g9 g9b`, plus `g8` with an internal pool; then `g12`, `g13`, `g15-before`/`g15-after`, and after the admin reboot `g14` with an internal pool, else `g5 g7 g9` |

- `g14` reruns `g5 g7 g8 g9`, and `g8` needs `GATE_VM_C` (an `internal` VM): without an internal pool the script exits 2 after `g7` and never runs `g9`.
- `g9b` targets on this platform (UNVERIFIED): `GATE_CTRL_PRIV=<control plane egress IP>`, which is in `deny4` through `--cp-source`; `GATE_UNDERLAY_PROBE=<main IP>`, whose sshd is open and which the `input` chain rule `iifname "vetho*" ip daddr @deny4` drops (the gate's counter includes it); or a vSwitch peer with SSH open, if there is one. `GATE_SMTP_PROBE` is any internet host that accepts TCP 25.
- G11 (remap) applies only to `nat` pools, which rented bare metal normally does not use. G14 reboots the host from the admin page; never use "Hardware Reset" without a BMC.

---

## 4. Problems and solutions

Common problems for every platform are in [TROUBLESHOOTING.md](../TROUBLESHOOTING.md), [NETWORKING.md](../NETWORKING.md) §11 and [PLATFORMS.md](../PLATFORMS.md) §7. These are the ones specific to rented dedicated servers:

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Host strand stuck at `bootstrap_rhizome` | The control plane key is not in root's `authorized_keys` (installimage and OVH templates set their own root login), or a provider firewall blocks port 22 from the control plane | Install the key (§3.4); test `ssh -i ~/.ssh/byoh_data -o BatchMode=yes root@<main IP> true`; open 22 for `--cp-source` |
| 2 | VM setup fails with "`<ip>` is a local address of this host" | A pool IP is on the NIC, often because the provider's guide says to add every additional or failover IP to the network config | Remove it from netplan and the interface (`ip -br addr`; `ip route show table local`), then recreate the VM. VMs use pool IPs; the host must not |
| 3 | `register-byoh-host` fails with "contains main_ip" | The declared block is the main IP's own subnet | Declare only the routed extra block(s). The main subnet is not a pool |
| 4 | Fails with "is not globally routable, so it cannot be public" | An RFC 1918 or documentation range declared as `public` | Use `exposure=internal` for private ranges; use your real block for `public` |
| 5 | VM boots, egress works, inbound to its public IP times out | Hetzner Robot firewall or another provider firewall in front of the server; or (OVH) the Additional IP still has a vMAC, so traffic goes to that MAC, not the host | Allow everything to the pool, or turn the provider firewall off. Remove the vMAC so the IP is in routed mode. `bin/byoh-pool trace <ip>` shows the VM and the netns commands to run |
| 6 | An IP with its own MAC (Hetzner separate MAC, OVH vMAC) never reaches its VM | Rhizome routes every VM behind the host's MAC; a separate-MAC IP needs a bridged guest | Not supported. Drop the separate MAC and use the IP routed to the main IP, or order a routed subnet |
| 7 | Provider sends a MAC-abuse email | A foreign MAC reached the switch, for example from a bridge or a leftover Proxmox/libvirt install. Hetzner forum posts report such emails for MACs not registered in Robot (forum reports, UNVERIFIED here) | BYOH VMs never appear on the wire with their own MAC. Remove any bridge that enslaves the uplink, and don't run other hypervisors on the host |
| 8 | VMs on a vSwitch subnet get no replies, or lose them after the bring-up reboot | No policy routing, so VM traffic leaves through the main uplink; or the rules were not persisted | Add the `ip rule`/table 100 setup of §3.6 B and persist it. The pools file `uplink` key is not used by Ubicloud |
| 9 | Large transfers hang on a vSwitch subnet | VLAN MTU too high | Set the VLAN MTU to 1400, as Hetzner documents. Guests already get 1400 from DHCP |
| 10 | Failover IP switched to another server and its VMs went dark | Pools are per host. The failover IP now routes to a host that has no such pool | Plan the switch: `bin/byoh-pool remove --host <old> --pool <cidr> --drain` (destroys the VMs on it), switch it in Robot (Hetzner says 90–110 s, provider docs, UNVERIFIED here), then `bin/byoh-pool add --host <new> --pool <cidr>,delivery=routed,exposure=public`, and recreate the VMs. VMs cannot move with the IP |
| 11 | VM IPv6 dead on OVH | On-link /64 declared without `ndp`; or the default route is multipath, which NDP proxying cannot handle | `bin/byoh-pool ipv6 set --host vh... --cidr <v6>/64,ndp` (empty host only); give NDP proxying a single-device default route |
| 12 | Only a /128 IPv6 (Kimsufi), registration wants a /64 | Registration accepts only a /64 | Declare no IPv6; the host uses a ULA /64 from the location's `ula48` and VMs get no public IPv6 |
| 13 | Every VM fails with `RuntimeError "BUG"` | Hybrid P+E-core CPU, SMT disabled, or offlined CPUs | Choose a non-hybrid CPU; boot with SMT on (PLATFORMS #5, #24) |
| 14 | `verify_hugepages` fails or the host has too few hugepages | Too little RAM, or a GRUB layout without `GRUB_CMDLINE_LINUX="..."` | ≥ 16 GiB RAM; restore the standard GRUB line (PF5, PF7) |
| 15 | Host does not come back after the bring-up `reboot` | Network config, mounts or GRUB break on reboot | Boot the provider's rescue system, fix netplan, fstab or GRUB, reset from the provider panel. The strand resumes once SSH works, within the 15-minute deadline; otherwise it pages |
| 16 | Admin "Hardware Reset" leaves the host stuck; VMs show "rebooting" | No Redfish BMC configured, so `CapabilityMissing` retries forever | Don't use it without a BMC. No command adds a BMC to a registered host. Recovery (UNVERIFIED): in `bin/pry`, `Strand[VmHost["vh..."].id].update(label: "prep_reboot", try: 0)`; the host then reboots over SSH and `start_vms` restarts the VMs. Otherwise destroy and re-register the host with the `--bmc-*` flags ([TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §8) |
| 17 | Redfish reset fails with an auth error after a control-plane restart | `--bmc-pass-env` variable missing from respirate's environment | Set it in `.env.rb` and restart respirate |
| 18 | Capacity smaller than the disks | RAID1 halves it; extra disks were not mounted under `/var/storage/devices/` before registration; 5 GiB is kept back | Plan the layout before registering (§3.2). Disks cannot be added to a registered host by mounting over `/var/storage` |
| 19 | `bin/monitor` marks the host `unavailable` | Hardware RAID or LVM devices without `wwn-`/`nvme-eui` links, so SMART checks fail (F5) | Don't run the monitor for such hosts |

---

## 5. Status

| Item | Status |
|---|---|
| Whole page | **UNVERIFIED.** No run on Hetzner, OVH, So you Start, Kimsufi or Leaseweb |
| `routed` + `public` path in code | Same code as the tested AWS path. Registration validation and pool commands are covered by unit specs |
| M2 fixes relevant here (LearnMemory units, uplink MAC pin skip for VLAN/bond/multipath, local-address check, KVM check in bootstrap, platform service deny list) | Unit specs only; never run on a real host |
| Provider facts | Provider docs or forum reports, UNVERIFIED here. Leaseweb not researched |

Known gaps:
- Virtual or separate MACs (OVH vMAC, Hetzner separate MAC) are not supported.
- The pools file `uplink` key is stored but never used. Pools on a second interface (vSwitch, vRack, `wg0`) need operator policy routing that survives reboots.
- `--guest-mtu` is accepted but not applied; guests always get MTU 1400, and IPv6 router advertisements carry no MTU.
- NDP proxying (`,ndp`) needs a single-device default route.
- IPv6 must be exactly one /64.
- VM public IPs cannot move between hosts without recreating the VMs.
- No provider API is used: there is no automatic failover-IP switching, no reimage, and no Robot/OVH reset.
- Hardware Reset without a BMC wedges the host strand; Power On without one returns an error.
- `bin/monitor` health checks on hardware RAID or LVM devices are OPEN (F5).
- Hybrid CPUs, SMT off, NVIDIA with IOMMU, btrfs/ZFS, and Docker/ufw rules being flushed are OPEN (PLATFORMS §4).
- A single-IP host cannot offer internet IPv4 to VMs until the tunnel recipe (NETWORKING §9.4) or the access tunnel (M6) lands.

Sources (provider docs, UNVERIFIED here):
- [Hetzner installimage](https://docs.hetzner.com/robot/dedicated-server/operating-systems/installimage/)
- [Hetzner additional IPs](https://docs.hetzner.com/robot/dedicated-server/ip/additional-ip-adresses/)
- [Hetzner failover](https://docs.hetzner.com/robot/dedicated-server/ip/failover/)
- [Hetzner vSwitch](https://docs.hetzner.com/robot/dedicated-server/network/vswitch)
- [OVH network bridging](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/network-bridging)
- [OVH IPv6 on dedicated servers](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/network-ipv6)
- [OVH Proxmox HG/Scale](https://docs.ovhcloud.com/fr/guides/bare-metal-cloud/dedicated-servers/proxmox-network-hg-scale)
- [Hetzner MAC forum thread](https://forum.proxmox.com/threads/proxmox-with-hetzner-what-a-love-story.127065/latest)
- [OVH community: Kimsufi / So you Start additional IPs](https://community.ovhcloud.com/t/ip-additionnel-kimsufi-ou-so-you-start/9942)
