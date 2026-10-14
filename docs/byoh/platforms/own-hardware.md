# BYOH on your own hardware: homelab, office rack, colo

This guide covers BYOH data-plane hosts on machines you own or rent as plain hardware:

- a homelab machine behind a consumer router;
- an office rack behind a company firewall (pfSense, OPNsense, MikroTik or similar);
- a colo server with a routed public block;
- a colo with BGP;
- a site with one dynamic IP, or behind CGNAT.

> **Status: UNVERIFIED.** Nothing on this page has been run on owned hardware in this project. The same code was validated end to end only on AWS (m8i nested virtualization, ap-south-1; [VERIFY.md](../VERIFY.md) §5). Everything below is derived from the code at branch `m2-network` and from [NETWORKING.md](../NETWORKING.md) §9.3-§9.6 and [PLATFORMS.md](../PLATFORMS.md). Router and vendor menu paths come from vendor docs and forum posts and are UNVERIFIED here. Record what you find in VERIFY.md §5.

The driver is the same on every platform. What changes on your own hardware is the firmware settings, the router work that brings pool addresses to the host, and power handling.

---

## 1. Fit

Use this guide when you control the machine, its firmware and the router in front of it. Pick the row that matches your site. The `delivery` × `exposure` terms are defined in NETWORKING §3.

| Site | What the VMs get | delivery + exposure | Section |
|---|---|---|---|
| **H1** Homelab or office LAN, no public addresses, control plane on the LAN | Internal IPv4 on the LAN | `onlink` + `internal` | §3.5 H1 |
| **H2** As H1, but the pool is a separate RFC 1918 block that the router routes to the host | Internal IPv4 | `routed` + `internal` | §3.5 H2 |
| **O1** Office firewall with N extra public IPs, 1:1 NATed onto LAN addresses | Public IPv4 (the external IP) | `onlink` + `nat` | §3.5 O1 |
| **O2** ISP routes a public block to your firewall, and the firewall routes it on to the host | Public IPv4 | `routed` + `public` | §3.5 O2 |
| **C1** Colo: the provider routes a block to your server's main IP | Public IPv4 | `routed` + `public` | §3.5 C1 |
| **C2** Colo: the provider puts a block on-link on your VLAN (it ARPs for each address) | Public IPv4 | `onlink` + `public` | §3.5 C2 |
| **C3** Colo with BGP: your router or the ToR announces your prefix and routes a per-host block to each host | Public IPv4 | `routed` + `public` | §3.5 C3 |
| **T1** One dynamic IP, or CGNAT, but you need internet ingress | Public IPv4 from a rented routed block, delivered over WireGuard | `routed` (via `wg0`) + `public` | §3.5 T1 (PLANNED, operator-owned) |

A VM without IPv4 needs no pool on any of these sites. Its outbound IPv4 goes through the host NAT.

Port forwards on a shared WAN IP, Tailscale on the host and `cloudflared` on the host are lab helpers, not product modes (NETWORKING §3.3).

---

## 2. Requirements

### 2.1 Host

The data plane must be a **dedicated machine**. Registration logs in as root, recreates the `rhizome` user, rewrites the sshd config, allocates 1G hugepages, flushes the nftables ruleset on every VM create and destroy (NH-6), and **reboots the machine**. Never register your NAS, your router, a Proxmox node or a desktop you also use.

| Requirement | Check (as root on the host) | Notes |
|---|---|---|
| Ubuntu 24.04 LTS, x86_64 (aarch64 is listed in PLATFORMS but UNVERIFIED) | `lsb_release -rs; uname -m` | Only 24.04 accepts VM slices |
| Booted with GRUB | `test -f /etc/default/grub && command -v update-grub` | Hugepage kernel arguments go in `/etc/default/grub.d/99-ubicloud-hugepages.cfg` (`prog/setup_hugepages.rb`). Do not edit that file; put your own kernel arguments in another drop-in. |
| KVM | `test -c /dev/kvm; grep -Ewo 'vmx\|svm' /proc/cpuinfo \| head -1` | `bootstrap-data-plane.sh` refuses the host without them (§2.2) |
| 1G hugepages | `grep -qw pdpe1gb /proc/cpuinfo` | Present on server and desktop CPUs of the last decade; the bootstrap checks it |
| Not a hybrid CPU | `lscpu` | Intel 12th-14th gen Core and Core Ultra (P+E cores) fail every VM with `BUG` (PLATFORMS HW-6, OPEN). Disable the E-cores in the firmware if your board allows it. |
| SMT on, all CPUs online | `lscpu -Jy -e=CPU,SOCKET,CORE,ONLINE` | `nosmt` or offlined CPUs give wrong totals and `BUG` (HW-7, OPEN) |
| RAM ≥ 14 GiB, 16+ recommended | `dmidecode -t memory \| grep -E '^\s+Size: [0-9]'` | Hugepages = `GiB*42/43 - 5`. Since M2, LearnMemory accepts kB/MB/GB/TB and rounds down to whole GiB; a board that reports no memory devices falls back to `MemTotal`. |
| Root filesystem ext4 or xfs | `mkdir -p /var/storage; findmnt -no FSTYPE --target /var/storage` (without the `mkdir`, `findmnt` prints nothing and exits 1 on a fresh host) | btrfs and ZFS make every VM prep fail with `ENOENT` (STOR-5, OPEN) |
| Extra disks mounted **before** registration | `findmnt /var/storage/devices/<name>` | Mount each at `/var/storage/devices/<name>` with `UUID=` in fstab. Never mount anything over `/var/storage` afterwards (OPS-9). |
| Wired uplink with a static address | `ip -br -4 addr; ip route show default` | Only the main IP is local (contract C5). DHCP on the host is fine only with a reservation; the main IP must not change. Wi-Fi uplinks are UNVERIFIED. |
| Outbound HTTPS, and HTTP to cloud-images-archive.ubuntu.com | `curl -sfI https://github.com && curl -sfI https://cloud-images.ubuntu.com`, plus the image URL of [PLATFORMS.md](../PLATFORMS.md) PF15 with `-L` | PrepHost and boot image downloads (the pinned Ubuntu releases redirect to the archive host over plain HTTP) |
| No other firewall manager | `systemctl is-active docker ufw tailscaled k3s libvirtd` | Their rules are wiped on every VM create and destroy (NH-6, OPEN) |
| No NVIDIA GPU in an IOMMU group (unless you want GPU VMs only) | `lspci -vnmm -d 10de:: \| grep IOMMUGroup` | LearnPci records NVIDIA devices that have an IOMMU group, and the allocator then excludes the host from every non-GPU VM (`scheduling/allocator.rb`, `non_gpu` filter; VR-4, OPEN) |

The full read-only check list is PLATFORMS §6.3 (PF1-PF21).

### 2.2 Firmware (BIOS/UEFI)

Menu names differ by vendor; these are the usual ones. UNVERIFIED on any specific board.

| Setting | Value | Why |
|---|---|---|
| Intel Virtualization Technology (VT-x) / AMD SVM Mode | **Enabled** | Without it there is no `/dev/kvm`, and the bootstrap stops with "/dev/kvm is missing" or "the CPU has neither the vmx nor the svm flag" |
| VT-d / AMD-Vi / IOMMU | Not needed for normal VMs. Leave it at the default unless the host has an NVIDIA GPU. | With an NVIDIA GPU, an IOMMU group removes the host from non-GPU placement (§2.1). To use such a host for normal VMs, remove the GPU or turn the IOMMU off (firmware, or a GRUB drop-in with `intel_iommu=off` / `amd_iommu=off`), then confirm `lspci -vnmm -d 10de::` shows no `IOMMUGroup` line before registration. UNVERIFIED. |
| Hyper-Threading / SMT | **Enabled** | §2.1 |
| E-cores (hybrid Intel) | Disabled, if the board offers it | §2.1 |
| Restore on AC power loss | **Power On** or **Last State** | The host comes back by itself after an outage (§3.10) |
| Boot mode | UEFI or legacy, as long as Ubuntu boots with GRUB | §2.1 |

### 2.3 Network

| Need | Detail |
|---|---|
| A management IPv4 for the host (`--main-ip`) | The address the control plane SSHes to. Never inside a pool. |
| Pool addresses | Delivered to the host by your router or provider (routed), or on the host's LAN segment (onlink). **Never configured on the host** (C5). Since M2, VM setup on a BYOH host fails with "X is a local address of this host" if one is. |
| IPv4 block size | Each pool is /24 or smaller, network-aligned |
| IPv6 (optional) | Exactly one /64 per host. From a /56 or /48, declare one /64. Routed /64: plain entry. On-link /64: add `,ndp` (needs a single-device default route, §3.5 C3). Without one, the host gets a ULA /64 from the location's `ula48`. |
| Control-plane reachability (C0) | TCP 22 from the control plane to the main IP. With `--cp-reach onhost`, also from the control plane to the pool addresses. With `--cp-reach public`, TCP 22 from the control plane to each internet VM's public or external IP (`Vm#cp_reach_ip4`; an internal VM is not dialled): on O1 with the control plane inside the site and NAT reflection off, that address is unreachable, so use `onhost` there. An off-site control plane needs a routed path (site VPN); Ubicloud does not build it (NETWORKING §4.5). |

---

## 3. Step by step

### 3.1 Provision the machine

1. Set the firmware options (§2.2).
2. Install Ubuntu 24.04 LTS Server. Use ext4. The installer's default LVM-on-ext4 layout works for VMs, but it rules out `bin/monitor` (device-mapper root, F5), so outage recovery stays manual (§3.10). For a host that needs automatic outage recovery, use plain ext4 partitions instead (UNVERIFIED that the monitor then suits the host).
3. Give the uplink a static address in netplan, for example `192.168.1.20/24` with gateway `192.168.1.1`. Put **only** the main IP on it.
4. Mount extra data disks at `/var/storage/devices/<name>` now, if you have any.
5. Run the PLATFORMS §6.3 checks.

PrepHost later rewrites the netplan entry of the default-route NIC to match it by its permanent MAC (`rhizome/host/lib/uplink_mac_pin.rb`). It skips that step when the default route is multipath, when the NIC is matched by `match:` already, or (since M2) when a VLAN, bond, bridge or VRF names the NIC. The original file is archived.

### 3.2 Data-plane bootstrap

On the host:

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

Which branch carries the code this page describes: [README.md](README.md) "Which branch". It checks Ubuntu 24.04, `/dev/kvm`, `vmx`/`svm` and `pdpe1gb`; enables root public-key login (`PermitRootLogin prohibit-password`); and installs `ruby-bundler` and `netcat-openbsd`. It does not touch the network.

On the control plane, create the host key and install it for root on the host:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
scp ~/.ssh/byoh_data.pub <admin>@<main IP>:/tmp/
ssh -t <admin>@<main IP> "sudo sh -c 'cat /tmp/byoh_data.pub >> /root/.ssh/authorized_keys && rm /tmp/byoh_data.pub'"
ssh -i ~/.ssh/byoh_data root@<main IP> true && echo ok
```

The installer's admin user needs its password for `sudo`, so the command needs a terminal (`-t`); piping the key into `sudo tee` over a non-interactive SSH stops with "a terminal is required to read the password". Alternatively, run `register-byoh-host` without `--ssh-key`: it generates a key and prints the `echo '<pubkey>' >> /root/.ssh/authorized_keys` lines to run on the host.

### 3.3 Control plane

Follow [SETUP.md](../SETUP.md) §4. On your own hardware:

- Put the control plane on a separate machine or VM, never on the data-plane host.
- On a LAN site (H1, H2, O1, O2), run it on the same LAN and use `--cp-reach onhost`.
- For a colo (C1-C3) or a tunnel site (T1) with the control plane elsewhere, use `--cp-reach public`.
- On **every** site, set `ENV["CONTROL_PLANE_OUTBOUND_CIDRS"] ||= "<the --cp-source CIDRs>"` in `.env.rb`: the control plane's LAN IP for H1, H2, O1 and O2, its egress IP for C1-C3 (NETWORKING §6.6). The variable sets which sources the SSH firewall rules of Postgres and Kubernetes VMs allow. Its default `0.0.0.0/0,::/0` (`config.rb`) makes `bin/byoh-location show` warn "CONTROL_PLANE_OUTBOUND_CIDRS includes 0.0.0.0/0, ::/0, so Postgres and Kubernetes firewalls allow SSH from anywhere"; setting it removes that warning. If you set it and leave a `--cp-source` CIDR out, `show` warns "cp_source_cidrs ... is not in CONTROL_PLANE_OUTBOUND_CIDRS" instead.
- Do not start `bin/monitor` until you have read §3.10 and §4.

### 3.4 Create the BYOH location (once per site)

Run on the control plane, from `~/ubicloud`. Pick the block for your site.

**H1, H2, O1, O2 (LAN `192.168.1.0/24`, control plane at `192.168.1.10`):**

```bash
bundle exec bin/byoh-location create --name byoh-home \
  --ui-name "Home lab (BYOH)" \
  --underlay 192.168.1.0/24 \
  --overlay 172.20.0.0/14 \
  --cp-reach onhost \
  --cp-source 192.168.1.10/32 \
  --mgmt-allow 192.168.1.0/24 \
  --rates-from hetzner-fsn1
```

**C1, C2, C3 (control plane elsewhere, colo management network `10.10.0.0/24`):**

```bash
bundle exec bin/byoh-location create --name byoh-colo-1 \
  --ui-name "Colo 1 (BYOH)" \
  --underlay 10.10.0.0/24 \
  --overlay 172.20.0.0/14 \
  --cp-reach public \
  --cp-source <control plane egress IP>/32 \
  --mgmt-allow <control plane egress IP>/32,<admin VPN CIDR> \
  --rates-from hetzner-fsn1
```

**T1:** as H1 if the control plane is on the home LAN; but see §3.5 T1 for `--cp-reach`.

Notes:

- `--underlay`: your LAN, office and VPN ranges. VMs may not open connections into them through the host (deny list). Office clients can still connect to `internal` VMs. Keep **routed** pool blocks out of `--underlay`.
- `--overlay` must be RFC 1918 and must not overlap the underlay. Change it if your LAN or VPN already uses `172.20.0.0/14`.
- `--egress-allow` is stored but nothing reads it yet (PLANNED P2); a VM cannot reach your NAS on the underlay. The only lever today is to leave that range out of `--underlay`, `--cp-source` and `--mgmt-allow`.
- Leave `--guest-mtu` unset: it is stored but never applied, and guests always get MTU 1400 from DHCP.
- `--ula48` is random; pass one only to fit an existing host.

Then restart `puma` and `respirate` so they load the rates, and check. Grant your project in §3.8, once the account exists:

```bash
tmux kill-session -t puma; tmux kill-session -t respirate
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh  # restarts them, skips finished steps
# packaged control plane (install.sh): sudo systemctl restart ubicloud.target
bundle exec bin/byoh-location show --location byoh-home
```

### 3.5 Router work and pools.yaml

`uplink` is informational: it is stored and shown, and nothing acts on it. Replace every `<...>` placeholder. Registration refuses documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) as `public` or as external IPs.

#### H1: LAN only, `onlink` + `internal`

Router work:
1. Shrink the router's DHCP range so the pool (here `192.168.1.200`-`.207`) is outside it.
2. Make sure no static route, VPN route or WireGuard route on the LAN covers the pool range. With `proxy_arp` on, the host would answer ARP for it (NETWORKING §3.4).

```yaml
version: 2
uplink: eno1
routed_networks:
  - cidr: 192.168.1.200/29
    delivery: onlink
    exposure: internal
    segment: 192.168.1.0/24
    gateway: 192.168.1.1
```

All 8 addresses are usable; `usable: auto` reserves only the segment's `.0`, `.255` and `.1`.

#### H2: router static route, `routed` + `internal`

Router work: a static route `192.168.50.0/27` via `192.168.1.20` (the host). On a consumer router this is usually under "Static routing" or "Advanced routing"; not every consumer router has it. LAN clients then reach VMs through the router. The return path goes straight from the host to the client, so routers with a strict stateful LAN firewall may drop it; if that happens, add the same route on the clients or use H1. UNVERIFIED.

```yaml
version: 2
uplink: eno1
routed_networks:
  - cidr: 192.168.50.0/27
    delivery: routed
    exposure: internal
```

Outbound traffic from internal VMs goes through the host NAT (the location default `internal_egress: host_nat`), so the router does not need to NAT `192.168.50.0/27`.

#### O1: extra public IPs, 1:1 NAT, `onlink` + `nat`

Each pool address P on the LAN is mapped 1:1 to one public IP E. Required for every pair: inbound to E reaches P unmodified apart from the destination (C1), the source is preserved (C2), all ports and protocols pass (C3), and P's outbound traffic leaves as E (C6). NAT reflection must be **off** for these entries.

| Router | Steps (vendor docs / forum posts, UNVERIFIED here) |
|---|---|
| pfSense | Firewall → Virtual IPs: add E on WAN (IP Alias or Proxy ARP). Firewall → NAT → 1:1: WAN, external E, internal P. Firewall → Rules → WAN: pass any protocol to P. Reflection off. Same as [SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §6.3. |
| OPNsense | Interfaces → Virtual IPs: add E on WAN. Firewall → NAT → One-to-One: type BINAT, external E, internal P. Firewall → Rules → WAN: pass any to P. Reflection off. |
| MikroTik RouterOS | Add E to the WAN interface if the ISP delivers it on-link (`/ip address add address=<E>/32 interface=<wan>`). Then one pair of rules per address, placed **above** the masquerade rule: `/ip firewall nat add chain=dstnat dst-address=<E> action=dst-nat to-addresses=<P>` and `/ip firewall nat add chain=srcnat src-address=<P> action=src-nat to-addresses=<E>`. Allow forwarding to P in `/ip firewall filter`. |
| Linux router (nftables) | `ip daddr <E> dnat to <P>` in prerouting and `ip saddr <P> snat to <E>` in postrouting, before any masquerade; forward accept to P |

```yaml
version: 2
uplink: eno1
routed_networks:
  - cidr: 192.168.1.208/30
    delivery: onlink
    exposure: nat
    segment: 192.168.1.0/24
    gateway: 192.168.1.1
    external:
      192.168.1.208: <public IP 1>
      192.168.1.209: <public IP 2>
      192.168.1.210: <public IP 3>
      192.168.1.211: <public IP 4>
```

An address you have no public IP for goes in `reserve: [...]`. With consecutive public IPs, `external_cidr: <public /30>` maps by offset instead.

#### O2: ISP-routed block through your firewall, `routed` + `public`

Router work:
1. Static route `<block>` via the host's LAN IP. pfSense: System → Routing → Gateways (add the host as a LAN gateway), then Static Routes. OPNsense: System → Gateways, then System → Routes. MikroTik: `/ip route add dst-address=<block> gateway=192.168.1.20`.
2. WAN rule: pass any protocol to the block.
3. Outbound NAT: the block must **not** be masqueraded. pfSense/OPNsense: hybrid outbound NAT with a "Do not NAT" rule for source = block. MikroTik: an `action=accept` srcnat rule for `src-address=<block>` above the masquerade rule.

(All UNVERIFIED here.)

```yaml
version: 2
uplink: eno1
routed_networks:
  - cidr: <your block, e.g. a.b.c.8/29>
    delivery: routed
    exposure: public
```

#### C1: colo, block routed to the main IP, `routed` + `public`

Ask the provider to route the block to your server's main IP (not on-link). Nothing to do on the host. `--main-ip` is the server's public address, outside the block. Turn off any provider-side firewall for the block, or allow everything to it (C3).

```yaml
version: 2
uplink: eno1
routed_networks:
  - cidr: <routed block>
    delivery: routed
    exposure: public
  # - cidr: <routed IPv6 /64>     # optional
```

#### C2: colo, block on-link on your VLAN, `onlink` + `public`

The provider's gateway sits inside the segment and ARPs for each address; the host answers through proxy_arp. Example: segment `<a.b.c.0/28>`, provider gateway `.1`, server main IP `.2`. Declare a sub-block that excludes the main IP:

```yaml
version: 2
uplink: eno1
routed_networks:
  - cidr: <a.b.c.8/29>
    delivery: onlink
    exposure: public
    segment: <a.b.c.0/28>
    gateway: <a.b.c.1>
```

Here `a.b.c.15`, the /28's broadcast, falls inside the /29 and is reserved by `usable: auto`, so 7 addresses are usable, not 8. Some providers filter frames by MAC or lock each port to one MAC; proxy_arp uses the host's own MAC, which should be the case that works (UNVERIFIED: no colo has been tested). A provider that wants each address on a **separate** MAC does not work: rhizome routes every VM behind the host's MAC (NETWORKING §9.5).

#### C3: colo with BGP, `routed` + `public`

- Run BGP on your router (or let the provider's ToR do it). Announce your prefix there and route a per-host block, and a per-host IPv6 /64 from your /48, to each host's main IP. Declare each host's block as in C1.
- Running FRR or BIRD on the data-plane host is out of scope for the driver and UNVERIFIED. If you do, do not redistribute kernel routes: the host holds a `/32` route per VM on `vetho*`.
- A multipath (ECMP) default route on the host is accepted: PrepHost skips the uplink MAC pin. NDP proxying (`,ndp`) fails with a multipath default route, so use a **routed** /64 (`ndp` false, the default).
- Bonds and VLAN uplinks are accepted by the uplink pin since M2 (UNVERIFIED on hardware).
- If the pools must leave through a different interface than the host's default route, you need your own policy routing (§3.5 T1 pattern); `uplink` does nothing.

#### T1: one dynamic IP or CGNAT, tunnel recipe (`routed` via `wg0` + `public`)

This is NETWORKING §9.4. It is **PLANNED and operator-owned**: the helper scripts `scripts/byoh/providers/wireguard-tunnel/*` do not exist, and Ubicloud never configures `wg0` or policy routing. Everything here is UNVERIFIED.

1. Rent a server or VPS whose provider **routes** an additional block to its main IP (Hetzner or OVH routed mode, for example; provider docs, UNVERIFIED here). Enable `net.ipv4.ip_forward=1` there, and do not NAT the block.
2. WireGuard, with the home host dialing out (so CGNAT and a dynamic IP are fine): on the VPS, the home peer gets `AllowedIPs = <block>`, so the VPS routes the block into the tunnel. On the home host, the VPS peer gets `AllowedIPs = 0.0.0.0/0` with `Table = off` (so wg-quick does not take over the default route) and `PersistentKeepalive = 25`.
3. On the home host, send pool-sourced traffic back through the tunnel, in `PostUp` so it survives the registration reboot:
   ```
   PostUp = ip rule add to <block> lookup main priority 999
   PostUp = ip rule add from <block> lookup 100 priority 1000
   PostUp = ip route add default dev wg0 table 100
   PostDown = ip rule del to <block> lookup main priority 999
   PostDown = ip rule del from <block> lookup 100 priority 1000
   ```
   `ip rule add` accepts duplicates, so without the `PostDown` lines every `systemctl restart wg-quick@wg0` adds another copy of each rule.
   The `to <block>` rule keeps traffic to VMs on the host's `vetho*` routes. Enable `wg-quick@wg0`.
4. The block and every `wg0` route must stay outside the home LAN segment (proxy_arp, NETWORKING §3.4).
5. MTU: `wg0` is about 1420; guests get 1400 from DHCP, which fits.
6. `--main-ip` is the host's LAN address. Use `--cp-reach public` unless the control plane also has a route to the block that returns symmetrically.

```yaml
version: 2
uplink: wg0                    # informational only
routed_networks:
  - cidr: <block routed to the VPS>
    delivery: routed
    exposure: public
```

If you only need SSH to VMs (no public service), skip the tunnel: create VMs without IPv4 or with `internal` IPv4. The browser console and access tunnel are PLANNED (NETWORKING §12, M6); today, reach a VM with the netns ProxyCommand in §3.9.

### 3.6 Register the host

```bash
bundle exec bin/register-byoh-host \
  --location byoh-home \
  --main-ip 192.168.1.20 \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble \
  --yes
```

With a Redfish BMC (§3.11), first add `ENV["BYOH_BMC_PASS_HOST1"] ||= "..."` to `.env.rb` and restart `puma` and `respirate` (§3.11): registration only warns when the variable is missing. Then add:

```bash
  --bmc-endpoint https://192.168.2.11 \
  --bmc-user admin \
  --bmc-pass-env BYOH_BMC_PASS_HOST1 \
  [--bmc-system-id <id>] [--bmc-reset-type ForceRestart] [--bmc-verify-ssl]
```

- There is no `--provider` flag.
- Pools can also be given inline: `--routed-network 192.168.1.200/29,delivery=onlink,exposure=internal,segment=192.168.1.0/24,gateway=192.168.1.1`; an IPv6 /64 as `--routed-network <v6>/64` or `<v6>/64,ndp`.
- `ubuntu-noble` is the default image for VMs that name none. Add `--default-boot-image ubuntu-jammy` only if customers will pick jammy explicitly.
- Keep `RACK_ENV=development` (the default).

Bring-up takes about 15-25 minutes on bare metal and **reboots the host once**. Watch the labels in the log and the state in the database:

```bash
tail -f /tmp/respirate.log
psql -U clover -d clover_test -c "SELECT allocation_state, os_version, total_cores, total_hugepages_1g FROM vm_host"
```

The host is ready at `allocation_state = accepting`.

### 3.7 Verify the pools

```bash
bundle exec bin/byoh-pool list   --host vh...
bundle exec bin/byoh-pool verify --host vh...                                   # exit 0, no "fail:" lines
ssh -i ~/.ssh/byoh_data root@<main IP> nft list table inet byoh_egress         # host NAT table loaded
ssh -i ~/.ssh/byoh_data root@<main IP> ip -br -4 addr                          # only the main IP (C5)
```

- On an H1/H2 host, `verify` warns "no free public or nat IPv4 address". That is expected on a site with only internal pools.
- `verify` checks the control-plane records only. It does not probe the router; the gate (§3.9) and a test from outside do that.
- If the egress table is missing: `bundle exec bin/byoh-host setup-egress-nat --host vh...`.

### 3.8 Create VMs

Create an account at `http://<control plane>:3000/create-account` (the verification email is in `/tmp/puma.log`), grant its project (`bundle exec bin/byoh-location grant --location byoh-home --project pj...`; repeat for `byoh-colo-1`), and add an SSH key. Then, in the UI or with the `ubi` CLI as set up in [SETUP.md](../SETUP.md) §9:

```bash
ubi vm byoh-home/vm1 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"   # H1, H2
ubi vm byoh-home/vm2 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"               # O1, O2, T1 (internet)
ubi vm byoh-colo-1/vm2 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"             # C1-C3 (internet)
ubi vm byoh-home/vm3 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"            # no IPv4, any site
```

An internet VM places only on a host with a free `public` or `nat` address. The VM user is `ubi`.

### 3.9 Gate checks

Run `scripts/byoh/verify/m2-gate.sh` as in [VERIFY.md](../VERIFY.md) §2.5 ("The gate on other platforms"):

```bash
export GATE_LOCATION=byoh-home GATE_HOST=vh... GATE_MAIN_IP=192.168.1.20
export GATE_HOST_KEY=~/.ssh/byoh_data GATE_VM_KEY=~/.ssh/id_ed25519
export GATE_EXPECT_MONITOR=0
export GATE_VM_B=vm... GATE_VM_C=vm...                 # -6 and -e internal
export GATE_CTRL_PRIV=<control plane LAN IP> GATE_UNDERLAY_PROBE=<another LAN host with SSH open>
export GATE_SMTP_PROBE=<an internet host that accepts TCP 25>

scripts/byoh/verify/m2-gate.sh g1 g2 g3 g4 g5 g7 g8 g9 g9b          # every site
GATE_VM_A=vm... GATE_VM_A_EXPOSURE=public scripts/byoh/verify/m2-gate.sh g6    # O2, C1-C3, T1
GATE_VM_A=vm... GATE_EXTERNAL_SSH_VIA=<user@host outside the site> scripts/byoh/verify/m2-gate.sh g6   # O1 (reflection off)
```

Then G12-G15 (VERIFY.md §2.4). The script covers most of them; only the admin reboot, `add` and `remove --drain` (G13) and the create/destroy loop (G15) are manual:

```bash
scripts/byoh/verify/m2-gate.sh g12 g13
# admin page: Reboot the host (not Hardware Reset), wait for it to come back
scripts/byoh/verify/m2-gate.sh g14            # reruns g5 g7 g8 g9; the important one on owned hardware
scripts/byoh/verify/m2-gate.sh g15-before     # then create and destroy a VM 20 times
scripts/byoh/verify/m2-gate.sh g15-after
```

For G11 on O1, change the router's 1:1 mapping first, then:

```bash
bundle exec bin/byoh-pool remap --host vh... --ip <P> --external <new E>
GATE_VM_A=vm... GATE_NEW_EXTERNAL=<new E> scripts/byoh/verify/m2-gate.sh g11
```

To reach a VM by hand on any site:

```bash
bundle exec scripts/byoh/verify/m2-checks info --vm vm...     # prints private_ip4= and inhost=
ssh -o "ProxyCommand=ssh -i ~/.ssh/byoh_data root@<main IP> ip netns exec <inhost> nc %h %p" ubi@<private_ip4>
```

### 3.10 Power, UPS and outages

| Topic | What happens | What to do |
|---|---|---|
| Registration reboot | The host reboots once during bring-up (15-minute deadline) | Nothing; your router and BIOS settings must survive a reboot. Only `wg0` (T1) lives on the host, so enable it as a systemd unit. |
| Power returns after an outage | VMs are systemd units started by the control plane, not enabled at boot. The control plane notices an out-of-band reboot only through the `checkup` semaphore, which `bin/monitor` sets. Without the monitor, **VMs stay stopped** after an outage. | Set "Restore on AC power loss" (§2.2). After the host is back, use admin **Reboot** for the host (not Hardware Reset): it reboots once more and then restarts every VM (`start_vms`). UNVERIFIED on owned hardware. |
| `bin/monitor` | Detects reboots and unreachable hosts and restarts VMs | Start it only if all three hold: PF12 passes (a `wwn-`/`nvme-eui` link for the disk under `/var/storage`), PF14 passes (`tsc` clocksource), **and** `findmnt -no SOURCE --target /var/storage` is not `/dev/mapper/*` (no LVM or device-mapper). PF12 walks down to the physical disk, so an LVM root on a disk with a `wwn-` link passes it, yet the control-plane health checks still fail on the device-mapper root and the host flaps to `unavailable` (F5, OPEN). UNVERIFIED on owned hardware. |
| UPS | Ubicloud has no UPS integration | Use your UPS software (for example NUT) to shut the host down cleanly on low battery. Put the control plane and the router on the UPS too. UNVERIFIED. |
| Control plane after its own reboot | With the development bootstrap, `puma` and `respirate` run in tmux and do not restart | Run `bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh` again; it restarts them and skips finished steps. A packaged control plane (`install.sh`) starts them at boot under systemd |

### 3.11 BMC: Redfish only, no IPMI

`lib/hosting/redfish_client.rb` speaks Redfish over HTTPS (Basic auth): `GET /redfish/v1/Systems`, the system's `#ComputerSystem.Reset` target, then `POST {"ResetType": ...}`. **IPMI over LAN is not implemented.** A BMC that speaks only IPMI cannot be registered; use `ipmitool` by hand.

| Item | Detail |
|---|---|
| Test first | `curl -sk -u <user>:<pass> https://<bmc>/redfish/v1/Systems`. Exactly one member, or pass `--bmc-system-id` ("multiple systems; set bmc.system_id explicitly"). |
| Network | The control plane must reach the BMC endpoint. Keep the BMC on a management network, never on the internet. |
| TLS | Verification is off unless you pass `--bmc-verify-ssl` (BMC certificates are usually self-signed) |
| Password | Prefer `--bmc-pass-env VAR`. `--bmc-password` is stored in plain text in `host_provider.config`. The variable is read when the BMC is used, by respirate (Hardware Reset) and by puma (admin Power On and Power Status). Set it in `.env.rb` (`ENV["BYOH_BMC_PASS_HOST1"] ||= "..."`, mode 600), which every process loads. |
| Timeouts | 5 s connect, 20 s read/write |
| What it is used for | Admin **Hardware Reset** (`ForceRestart` by default; refused while the host has VMs and is not draining), **Power On** (skipped when already on) and **Power Status** |
| Without a BMC | **Never click Hardware Reset**: it raises `CapabilityMissing` and the host strand retries forever. Power On returns an error. (OPEN; [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §8.) Use admin **Reboot**, which works over SSH. If Hardware Reset was clicked, see §4. |
| Reimage | Not supported for BYOH hosts (no PXE). Reinstall by hand, then destroy and re-register the VmHost (host keys are pinned on first connect). |

---

## 4. Problems and solutions

| Symptom | Cause | Fix |
|---|---|---|
| `bootstrap-data-plane.sh`: "/dev/kvm is missing" or "neither the vmx nor the svm flag" | VT-x / AMD SVM disabled in the firmware | Enable it (§2.2), power-cycle, rerun the bootstrap |
| Bootstrap: "the CPU lacks the pdpe1gb flag" | Very old CPU | Use another machine; a `flexible` profile without hugepages is PLANNED ([COMPUTE.md](../COMPUTE.md)) |
| Every VM fails with `RuntimeError BUG` in `write_params_json` | Hybrid Intel CPU (P+E cores), or SMT off / CPUs offline | Disable E-cores in the firmware, enable SMT, remove `nosmt`; then re-register (PLATFORMS HW-6, HW-7) |
| Internet and internal VMs wait for capacity on a host with an NVIDIA GPU | GPU in an IOMMU group; the allocator excludes the host from non-GPU VMs | Remove the GPU or turn the IOMMU off, then re-register (§2.2); UNVERIFIED |
| VM prep fails with `Errno::ENOENT` | `/var/storage` on btrfs or ZFS | Reinstall with ext4 or xfs (STOR-5) |
| A second data disk is never used | Mounted after registration, or not under `/var/storage/devices/<name>` | Mount it there and re-register (STOR-3); never mount over `/var/storage` |
| Host flaps to `unavailable` and pages | `bin/monitor` running with an LVM root or a disk without `wwn-`/`nvme-eui` links | Stop the monitor (§3.10) |
| VMs stay stopped after a power outage | No `bin/monitor`, so the out-of-band reboot is not noticed | Admin **Reboot** of the host (§3.10) |
| Host strand stuck at `hardware_reset`; VMs show "rebooting" | Hardware Reset clicked on a host with no BMC, or with VMs while not draining | No command adds a BMC to a registered host, and the strand keeps retrying the label whatever happens on the host. Recovery (UNVERIFIED): in `bin/pry`, `Strand[VmHost["vh..."].id].update(label: "prep_reboot", try: 0)`. The semaphore was already cleared in `prep_hardware_reset`, so the host reboots over SSH and `start_vms` restarts the VMs. Otherwise destroy and re-register the host with `--bmc-*` |
| Redfish reset fails with 401 after a control-plane restart | The `--bmc-pass-env` variable is not in respirate's or puma's environment | Put it in `.env.rb` and restart both |
| BMC cannot be registered | IPMI-only BMC | Not supported; manage power by hand |
| H1: internal VM unreachable from the LAN | Pool inside the router's DHCP range or used by another device (`arping` shows two MACs); a VPN or static route covers the pool; stale ARP on the router | Move the pool or shrink DHCP; remove the overlapping route; clear the router's ARP cache |
| H2: VMs reachable from the host but not from LAN clients | Router has no static route, or drops the asymmetric return path | Add the route; add it on clients too, or switch to H1 |
| O1: VM unreachable at E from the internet | Missing 1:1 entry, missing WAN pass rule, or (MikroTik) the src-nat rule below the masquerade rule | Fix the router; test from outside the site |
| O1: VM unreachable at E from inside the site | NAT reflection is off by design (C2) | Test from outside (`GATE_EXTERNAL_SSH_VIA`); split DNS for office clients; hairpin is PLANNED (NETWORKING §4.6) |
| O2/C1: customer firewall rules by source IP never match, or VM egress shows the router's IP | The router masquerades the block | "Do not NAT" / srcnat accept rule for the block |
| C2: some pool IPs unreachable | Provider port security allows only known MACs or IPs, or wants a separate MAC per IP | Ask the provider to route the block to the main IP (C1) instead |
| PrepHost fails "no default route to identify the uplink interface" | No default route on the host when PrepHost runs | Fix netplan; the host needs a single or multipath default route |
| `,ndp` IPv6 setup fails on a BGP host | Multipath default route | Use a routed /64 without `ndp` |
| T1: VMs reachable by ping but TCP sessions hang | Path MTU over the tunnel | Keep `wg0` at 1420 or lower; guests already use 1400 |
| T1: public VMs unreachable after the host reboots | `wg0` or the `ip rule` lines were not persistent | `systemctl enable wg-quick@wg0`, with the rules in `PostUp` |
| VM cannot reach the NAS or other LAN hosts | The underlay is in the VM deny list by design; `--egress-allow` is not read by any code yet | Expected; reach LAN services through an internet path, leave that range out of `--underlay`/`--cp-source`/`--mgmt-allow`, or wait for P2 |
| VMs resolve no names on an office network (O1, O2) | Per-VM dnsmasq forwards to `8.8.8.8`, `2001:4860:4860::8888` and `2606:4700:4700::1111` (`rhizome/host/lib/vm_setup.rb`); the office firewall blocks UDP/TCP 53 except to its own resolver | Allow DNS from the host (and the pool) to those resolvers. The location's `dns_servers` is stored but not applied |
| Docker, ufw or Tailscale on the host stop working | `flush ruleset` on every VM create and destroy (NH-6) | Do not run them on the data-plane host |
| VM setup fails "X is a local address of this host" | A pool IP is configured on the host (netplan or another agent) | Remove it from netplan and `ip addr`; only the main IP may be local (C5) |

Common problems on every platform (stuck at `bootstrap_rhizome`, PrepHost download failures, "No capacity left", `wait_sshable`, guest DNS): [TROUBLESHOOTING.md](../TROUBLESHOOTING.md), [NETWORKING.md](../NETWORKING.md) §11, [SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §10 and [PLATFORMS.md](../PLATFORMS.md) §7.

---

## 5. Status

**UNVERIFIED.** No owned-hardware site has run this guide or the gate. Tested end to end: AWS only.

Known gaps that matter on owned hardware:

- Hybrid Intel CPUs, SMT off, NVIDIA + IOMMU, btrfs/ZFS and Docker/ufw/Tailscale on the host are OPEN (PLATFORMS §4).
- `bin/monitor` health checks fail on LVM roots and some disks (F5), so outage recovery is manual (§3.10).
- Only Redfish BMCs; no IPMI. Hardware Reset without a BMC wedges the host strand, and no command adds a BMC to a registered host (recover with the `bin/pry` strand reset in §4, UNVERIFIED, or re-register).
- The pools file `uplink` is never used; pools on a second interface (`wg0`, a VLAN) need your own policy routing.
- The tunnel recipe (T1) is PLANNED and has no scripts.
- `guest_mtu`, `dns_servers` and `egress_allow` are stored but not applied.
- Separate-MAC public IPs cannot work.
- VMs cannot reach the site LAN, by design (NH-8).
- Cross-host traffic between internal VM addresses is UNVERIFIED (NETWORKING §4.4, §7.3).
