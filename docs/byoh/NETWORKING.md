# BYOH Networking: how VM traffic and addresses work on any platform

Status: decided architecture, 2026-10-12, with all review corrections applied. It applies to the `byoh-driver` branch and to everything rebased from it.

Who this is for:
- **Operators** who put a host on AWS, Proxmox, bare metal or a homelab and need to know what the network must do.
- **Developers** who change the data plane, the control plane or this design.

Tags used in this document:

| Tag | Meaning |
|---|---|
| **[TODAY]** | Exists in the code or the live deployment now. |
| **[UPSTREAM]** | On `origin/main` only. Arrives with the P0 rebase. |
| **[PLANNED Pn]** | Decided. Built in networking phase *n* (§14). |
| **[PLANNED Cn]** | Decided. Built in console/access phase *n* (§12.7). |
| **UNVERIFIED** | Not proven in code or on a live system. |
| **[EXT]** | General knowledge about a third-party product (AWS, Cloudflare, pfSense, OpenSSH, Cloud Hypervisor, cloud-init). Not checked against this repo. |
| **OPEN** | Needs a product or design decision. Listed again in §15. |

Other pages call the networking phases **NET-P0..NET-P7**. [ROADMAP.md](ROADMAP.md) §3 maps them to milestones M0-M12; where it pulls an item into an earlier phase, this page says so.

See also: [ROADMAP.md](ROADMAP.md) (build order, console and access design in §4, open decisions in §8) · [COMPUTE.md](COMPUTE.md) (capacity, tiers, overcommit) · [PLATFORMS.md](PLATFORMS.md) (per-platform support, host preflight) · [QUICKSTART.md](QUICKSTART.md).

Citations:
- `file:line` refers to the `byoh-driver` working tree (commit e6f5e328e plus uncommitted terraform changes).
- `origin/main:<path>` refers to upstream.

---

## 0. Summary

**Who owns what.**

| Part | Owner | What it means |
|---|---|---|
| Delivering pool addresses to the host's uplink | Operator (or the operator's own tooling) | The only platform-specific work. |
| Everything from the uplink inward: per-VM network namespace, DNAT/SNAT to the pool address, per-VM nftables firewall, host firewall | Ubicloud | Same code on every platform. |
| Checking that the delivery works | Ubicloud | Preflight and continuous checks (§8). |
| Cloud, router or firewall APIs with write credentials | Nobody in the control plane | Ubicloud never holds them. |

**One contract, three shapes.** AWS, Proxmox behind pfSense, a homelab, Hetzner, BGP colo, GCP and Azure all meet the same host contract (§2). They differ only in:
- how a packet reaches the uplink (`delivery`), and
- what the internet sees (`exposure`).

**How the "public IP" works on AWS.**
- The VM's on-host address is an ENI secondary private IP, for example 10.98.1.129.
- AWS translates the Elastic IP 43.204.120.21 to that address 1:1 at its edge.
- This is the same shape as pfSense 1:1 NAT on Proxmox, a GCP external IP, or an Azure Public IP.
- Ubicloud records both addresses. Rhizome uses the on-host address. Customers see the external address in the UI, API, DNS, billing and abuse lookup [PLANNED P1].

**Filtering.**
- The customer's Ubicloud firewall is the only filter on VM traffic.
- Infrastructure filters (AWS security groups, pfSense WAN rules, NSGs, the Proxmox VM firewall) must pass all traffic to pool addresses.
- The host protects itself with a mandatory Ubicloud-managed host firewall, `host_guard` [PLANNED P2].

**Reaching VMs without a public IP.** One platform-native path (the Ubicloud access tunnel over the existing control-plane-to-host SSH path) works the same on every platform. See §12.

---

## 1. Principles

| # | Principle |
|---|---|
| P1 | **One data plane.** No platform-specific code in rhizome or progs. Platform differences live only in operator recipes, operator tooling and the pool declaration. |
| P2 | **The operator delivers; Ubicloud verifies.** The control plane holds no provider write credentials. Ubicloud runs preflight and continuous checks and refuses to mark a host `accepting` while hard checks fail. Optional automation (the AWS pool sync in P7) is operator tooling that writes the same pool rows; it never forks the data model. |
| P3 | **Honest identity.** Customers see the address the internet uses, or an address explicitly labelled *Internal*. A ULA is never shown as "public IPv6". Transit or on-host addresses are never shown as public. This matches upstream's native AWS/GCP convention (`origin/main:prog/vm/aws/nexus.rb:307`, `origin/main:prog/vm/gcp/nexus.rb:190`). |
| P4 | **One customer filter.** The netns `forward_ingress` chain (policy drop, `prog/vnet/metal/update_firewall_rules.rb:102`) runs after DNAT and matches the real client source and port. Anything in front that filters or source-NATs breaks it. Stated exception: the access tunnel (§12.4), which has its own permission. |
| P5 | **Hosts protect themselves.** A provider filter cannot express "open for the pool, closed for the host" on AWS, because security groups are per ENI. `host_guard` is therefore mandatory on every BYOH host. |
| P6 | **Behaviour-identical upstream, gated.** Every data-path divergence is gated on a BYOH-only parameter. When the parameter is absent, upstream behaviour applies. Hetzner and Leaseweb hosts keep their behaviour. Rhizome output is byte-identical where practical. Two changes are deliberately not byte-identical but are behaviour-safe everywhere: the APIPA picker exclusions (§6.4) and the shared NAT generator that fixes the load-balancer NAT rebuild (§4.7). |
| P7 | **Not patchwork.** No AWS, Proxmox or GCP special case exists in Ruby or rhizome. A new platform needs only a recipe page and a pool file. |

---

## 2. The host network contract (identical for every platform)

### 2.1 IPv4

For every **allocatable** pool address **P** declared on host **H**:

| | Requirement | Checked by |
|---|---|---|
| C0 Control-plane reach | The control plane can reach H's management address on TCP 22, and (for `cp_reach: onhost`) the pool addresses. On a site that is not in the control plane's network, the operator provides a routed path (site VPN or routed link). Ubicloud does not build it. | preflight from the CP [PLANNED P3]. **OPEN**: see §4.5. |
| C1 Delivery | Packets with `dst = P` reach H's declared uplink. They arrive unmodified, or with only the destination translated by a stable 1:1 NAT (external E → P). | inbound probe [PLANNED P3]; for `nat` only an external vantage point proves it (§8.3) |
| C2 Source preserved | No inbound SNAT, proxy, load balancer or NAT reflection in front. The client address reaches the VM netns. | probe compares observed peer with probe source [PLANNED P3]; same `nat` caveat |
| C3 No infra filtering | All protocols and ports pass to P in both directions (SG, NSG, VPC firewall, pfSense, Proxmox VM firewall, provider firewall). | probe on two ports plus ICMP [PLANNED P3] |
| C4 Source acceptance | Upstream accepts `src = P` from H, with no uRPF or anti-spoof drop. Replies to P return to H. Per delivery: `routed` and out-of-VPC tunnels need AWS src/dst check off or GCP `can_ip_forward`; `fabric` does **not** need src/dst check off, because P is assigned to the ENI; pfSense needs outbound NAT for `nat`/`internal`. | egress check per IP (extended upstream `CheckIpReachability`, §8.2) [PLANNED P0/P3] |
| C5 Hands off | **Allocatable** pool IPs are never configured on any host interface. Host-anchored addresses (the management IP, or an address a provider requires on the NIC) are excluded from the pool. | `check-pool-not-local`, run on every `SetupNftables` and in preflight; hard fail [PLANNED P2] |
| C6 Mapping | For `exposure: nat`, the E ↔ P mapping is 1:1 and stable, and egress from P leaves the edge as E. | egress-IP echo; inbound to E from an external vantage point (§8.3) [PLANNED P3] |

**Why C5 matters.** If P is configured on the host, the host's own kernel answers for it.
- That was the EC2 cloud-init bug: `wait_sshable` passed against the *host's* sshd, and users got "Permission denied (publickey)" (CLAUDE.md §10a).
- Upstream does put some addresses on the NIC: `origin/main:lib/hosting/leaseweb_netplan.rb` (around `:50-56`, `public_addresses`) configures the address of each IPv4 block. That is compatible with C5 only because that address is not allocatable. Our rule is therefore "allocatable pool IPs are never local", not "no block address is ever local".

### 2.2 IPv6 (only when `ipv6_mode = gua`)

For the host block N6:

| | Requirement |
|---|---|
| C7a | N6 is GUA (inside 2000::/3). |
| C7b | N6 is routed to H, or on-link with `ndp: true` so the host answers NDP. |
| C7c | N6 is reachable from the other hosts of the same location. |
| C7d | IP protocol 50 (ESP) passes, and the path MTU is at least 1500. |

---

## 3. Canonical models

### 3.1 Two attributes per pool

**`delivery`: how packets for P reach the host.** Rhizome code is identical for all three. The attribute drives validation, defaults and preflight expectations.

| delivery | Meaning | Host requirement | Examples |
|---|---|---|---|
| `routed` | Upstream routes P (or its block) to the host's uplink IP or MAC. No ARP for P. | none | Hetzner subnets and additional IPs, OVH routed mode, Leaseweb blocks, colo static route or BGP, pfSense static route, home-router static route, WireGuard tunnel from a VPS |
| `onlink` | P sits on the uplink L2 segment. Upstream ARPs for P and the host answers through proxy_arp. | `proxy_arp=1` on the veth (`rhizome/host/lib/vm_setup.rb:339`) and in prep (`rhizome/host/bin/prep_host.rb:76`) [TODAY]; no MAC/IP filter on the bridge port; the **segment's** network, broadcast and gateway reserved; no overlapping routes (§3.4) | Proxmox vmbr1, homelab LAN, Hetzner vSwitch, pfSense 1:1 onto LAN IPs |
| `fabric` | A cloud SDN delivers P to the NIC it is *assigned* to. | P assigned to the uplink NIC in the cloud API and absent from the OS (C5) | AWS ENI secondary IPs, GCP alias IPs, Azure secondary ipconfigs |

**`exposure`: what the internet sees.**

| exposure | Customer-visible IPv4 | UI label | Public DNS (PG/LB/MinIO) | IPv4 billing |
|---|---|---|---|---|
| `public` | P | Public IPv4 | P | yes |
| `nat` | E (declared per P) | Public IPv4 | E | yes |
| `internal` | P | **Internal IPv4 (reachable only from the `<location>` network)** | none for VM addresses (`private.` records only). The PG hostname is P, with a UI warning. | no |

### 3.2 Valid combinations

All of these run the same code path.

| | public | nat | internal |
|---|---|---|---|
| **routed** | Hetzner, OVH routed, Leaseweb, colo/BGP, pfSense-routed ISP block, WireGuard tunnel | pfSense BINAT block → routed RFC1918 block | pfSense/home-router static route to RFC1918 |
| **onlink** | Hetzner vSwitch public subnet; ISP block bridged to the LAN | **pfSense 1:1 onto vmbr1 IPs** | **Company Proxmox vmbr1 today**, homelab LAN |
| **fabric** | n/a | **AWS secondary IP + EIP (live env)**, GCP alias + external, Azure ipconfig + Public IP | AWS secondary IPs without EIPs |

### 3.3 Not product modes

These remain available as operator lab-access helpers only. They are not supported customer networking.

| Helper | Why it is not a product mode |
|---|---|
| PAT / port forwarding on a shared WAN IP | Violates C2 and C3: the operator, not the customer, chooses the open ports, and reflection rewrites the source. |
| Tailscale or VPN subnet routers on the host | Host-level patchwork; bypasses the customer firewall model. |
| Jumping through the control plane | Lab access only. |
| Per-host `cloudflared` on the data-plane host (portability F8 Tier 1) | **Replaced by the Ubicloud access tunnel (§12.4).** Also, the host cannot reach a VM's private IP without entering the VM netns (§12.1). |

The Proxmox setup docs (`docs/byoh/SETUP_PROXMOX*.md`) describe several of these as setup options. They move to a "lab access" appendix in P6.

Sites with no public block choose one of:
- `internal` pools;
- the **tunnel recipe** (§9.4), which becomes `routed` + `public`;
- obtaining a 1:1-NATable or routed block.

Customers on any of these can still reach their VMs through the access tunnel (§12.4) without a public IP.

### 3.4 Rules for `onlink` pools [PLANNED P1]

| Rule | Why |
|---|---|
| `usable` strips only the **segment's** network address, broadcast address and gateway, not the first and last address of the declared block. Example: `10.80.0.200/29` inside `10.80.0.0/24` keeps `.200` and `.207`. | The declared block is a sub-range of the LAN, not its own segment. |
| Pool, tunnel (`wg0`) and overlay routes must not overlap the LAN segment except for the declared pool IPs. Registration rejects overlaps. | With `proxy_arp=1`, the host answers ARP for anything it routes out another interface (veth /32s, wg0 pools, VPN routes). An overlap would steal LAN addresses. |
| The pool range must be outside the LAN's DHCP range. | Otherwise DHCP hands out a VM's address to another machine. Preflight warns with `arping` [PLANNED P3]. |

---

## 4. Packet walks

The walks use the live AWS values:

| Name | Value |
|---|---|
| VM private address | 10.x.y.z (customer private subnet) |
| P (on-host pool IP) | 10.98.1.129 |
| E (Elastic IP) | 43.204.120.21 |
| Host primary | 10.98.1.138 on `ens5` |

### 4.1 Inbound IPv4 [TODAY on AWS]

```
client ──► E 43.204.120.21 ──(AWS edge 1:1, dst E→P)──► ENI ens5, dst 10.98.1.129
  host prerouting  inet drop_unused_ip_packets: P ∈ @allowed_ipv4_addresses → accept
                   (rhizome/host/bin/setup-nftables.rb:19-38)
  host FIB         10.98.1.129/32 dev vetho<vm>          (vm_setup.rb:338, proxy_arp :339)
  VM netns         nat prerouting: dnat 10.98.1.129 → 10.x.y.z        (vm_setup.rb:399)
                   forward_ingress (CUSTOMER firewall, policy drop):
                   ip saddr . dport ∈ @allowed_ipv4_port_tuple        (update_firewall_rules.rb:135-136; IPv6 is :137-138)
  tap ──► guest (the guest only knows its private address)
```

Customer source-CIDR rules work only because AWS EIP NAT preserves the client source (C2).

### 4.2 Egress IPv4 [TODAY]

1. The guest sends `src = 10.x.y.z`.
2. The netns SNATs to P (`vm_setup.rb:404`).
3. The host forwards the packet out `ens5` unchanged.
4. The AWS edge rewrites P → E.

DNS from the per-VM dnsmasq is SNATed to P (`vm_setup.rb:406-407`, backport 971a3d608).

### 4.3 Egress to RFC1918 destinations, and the egress policy

**[TODAY] defect.** `vm_setup.rb:404` skips SNAT for 10/8, 172.16/12 and 192.168/16. VM traffic to the VPC, the office LAN or another VM's P therefore leaves with the customer's private source, and replies have no route back. Inferred; UNVERIFIED live.

**[PLANNED P2] fix.** A gated egress chain in the VM netns, evaluated in this order for traffic from the VM's tap:

| Order | Rule | Why |
|---|---|---|
| 1 | `ct state established,related accept` | Replies to office clients of an `internal` service, and replies to inbound customer traffic, must never hit the deny rules. |
| 2 | `ip daddr @ubicloud_peer4 accept` | Private-subnet traffic to connected peers (IPsec). `Prog::Vnet::RekeyNicTunnel` keeps the set current (`prog/vnet/rekey_nic_tunnel.rb:91-95`). |
| 3 | `ip daddr @overlay drop` (the location's `overlay_ipv4_cidrs`) | Traffic to an **unconnected** private subnet would otherwise be SNATed and leak to the underlay default route. |
| 4 | `ip daddr @egress_allow accept` | Operator allow-list (`vm_egress_allow`). |
| 5 | `ct state new ip daddr @egress_deny drop` | Metadata services and the underlay (§6.5). Only new connections from the VM are denied. |
| 6 | postrouting: `ip daddr @ubicloud_peer4` no SNAT; everything else `snat to P` | Hairpin to another VM's P then works, and replies come back through conntrack. |

IPv6 uses the same order with the `*6` sets. The exact hook and priority are UNVERIFIED and must be proven by the two-host live test in P2.

### 4.4 Private networking (IPsec) [TODAY; same-host behaviour UNVERIFIED with ULA]

- Inner traffic is customer private-to-private. The outer header is IPv6 ESP `clover_A → clover_B`, carved from `vm_host.net6` (`rekey_nic_tunnel.rb:74-75`).
- The netns routes the outer packet only via `2000::/3` (`vm_setup.rb:289`).
- With a ULA net6 there is no route, even on the same host. CLAUDE.md §10 #7 records this as likely broken.
- [PLANNED P4]:
  - add `route <location ula48> via vetho_ll` in the netns for `ula` hosts;
  - for cross-host traffic, the ULA /64s must be routed between hosts (§7.3).

### 4.5 Control plane to host and to VM

| Item | Detail | Status |
|---|---|---|
| CP → host | Rhizome SSH to the host's management IP (`model/sshable.rb`). | [TODAY] |
| CP → VM | `wait_sshable` dials `vm.ip4` from the control plane (`prog/vm/metal/nexus.rb:189-195`); `sshable.host` = `vm.ip4` (`scheduling/allocator.rb:296`). Works only when the CP shares the underlay (AWS VPC, Proxmox LAN). | [TODAY] |
| `cp_reach` | Location setting `onhost | public` chooses P or E for CP → VM. | [PLANNED P1] |
| VMs with no CP route | `wait_sshable` probes from the host instead: `ip netns exec <vm> timeout 2 bash -c ':>/dev/tcp/<private_ipv4>/22'` (portability F8 step 2). Needed for `internal` VMs on remote sites and for VMs without IPv4. | [PLANNED P1] |
| CP ↔ site transport | **Design hole.** `cp_reach: onhost` assumes the CP sits in each site's underlay. A single CP in AWS cannot reach a Proxmox site's `10.80.0.0/24` (host SSH, `wait_sshable`, Postgres management) without a site VPN. Decision: the operator provides a routed path (site-to-site VPN or WireGuard from the CP to the site router) and declares it; Ubicloud verifies it as contract item C0. A Ubicloud-managed CP↔site WireGuard is a possible later phase; [ROADMAP.md](ROADMAP.md) §6.4 proposes it as the default from M8 (decision D-1). | **OPEN** |

### 4.6 Same-site hairpin for `nat` [PLANNED P2]

**Problem.** With `exposure: nat` behind pfSense, NAT reflection must be off (C2). Then VM A cannot reach `E_B`, or an LB's DNS name that resolves to E, at the same site. On AWS, EIP hairpin from inside the VPC is UNVERIFIED.

**Fix (platform-neutral).** Ubicloud stores every E ↔ P mapping, so each BYOH host installs, in the gated egress chain, `ip daddr E_x dnat to P_x` for every `nat` mapping in the location. VM-to-E traffic then never leaves the site.

| Client | Result |
|---|---|
| A VM at the same site | Works through the host DNAT. |
| An office or LAN client at the site (not a VM) | Ubicloud cannot fix this. Use split-horizon DNS on the site resolver, or accept it. Turning pfSense reflection on breaks C2 for everyone. **OPEN** |

### 4.7 Load-balancer node NAT [TODAY bug; fix PLANNED P2]

`prog/vnet/update_load_balancer_node.rb:95-131` and `:168-185` run `delete table ip nat` / `delete table inet nat` inside the VM netns and rebuild NAT from their own templates.

| Problem | Effect |
|---|---|
| The rebuilt rules omit the DNS port-53 SNAT rules from `vm_setup.rb:406-407` (971a3d608). `origin/main` has the same templates. | After a VM is added to or removed from a load balancer on an IPv6-less BYOH host, the guest's DNS breaks. Inferred from code; UNVERIFIED live. |
| The LB variant builds `table inet nat`, not `ip nat`. | The planned `ubicloud_peer4` set and egress chain (§4.3) would be wiped, and `nft add element ip nat ubicloud_peer4` would fail. |
| Both templates hard-code the RFC1918 SNAT exemption. | The §4.3 fix would be silently undone. |

Fix: one shared NAT generator used by `vm_setup.rb` and `update_load_balancer_node.rb`, so both produce the same base rules plus the LB rules. This file is **in** P2's scope.

---

## 5. Addresses, data model and what customers see

### 5.1 Three roles of a VM's IPv4

| Role | Accessor | Used by |
|---|---|---|
| A. on-host (after edge NAT) | `Vm#ip4` (**unchanged**) = `assigned_vm_address.ip` | rhizome `public_ipv4` (`model/metal/vm.rb:98`), host allowed set, LB node nft (`prog/vnet/update_load_balancer_node.rb:33,43-44`; that file still changes in P2 for §4.7) |
| B. control-plane reach | `Vm#cp_reach_ip4` = A when `cp_reach=onhost`, else C | `allocator.rb:296`, `wait_sshable` |
| C. customer-facing | `Vm#public_ip4` = `assigned_vm_address.external_ip` or A | serializer, views, CLI, PG/LB/MinIO/VictoriaMetrics DNS and SANs, billing `resource_name`, `Vm.from_ips` |

IPv6 follows the same pattern:
- `Vm#ip6` is unchanged and is what rhizome uses.
- `Vm#public_ip6` = `ip6` when the host's `ipv6_mode == "gua"`, otherwise nil.
- Customer-facing call sites move to `public_ip6`. `Vm#ip6` itself is **not** set to nil, so no unaudited caller changes; for example the `model/load_balancer_vm_port.rb:47` health checks keep working.

### 5.2 Schema [PLANNED P1]

| Table.column | Type, default | Meaning |
|---|---|---|
| `address.delivery` | text `'routed'`, CHECK in (routed, onlink, fabric) | §3.1 |
| `address.exposure` | text `'public'`, CHECK in (public, nat, internal) | §3.1 |
| `ipv4_address.external_ip` | inet NULL, unique where not null | E for `nat` |
| `ipv4_address.reserved` | bool false | never allocated (mgmt IP, gateway, network/broadcast, operator holdback) |
| `assigned_vm_address.external_ip` | inet NULL, unique where not null | copied at allocation. Changes only through `byoh-pool remap`, which updates both tables. |
| `location.byoh_network` | jsonb NULL | site profile (§5.3) |
| `vm_host.ipv6_mode` | text `'gua'`, CHECK in (gua, ula) | §7 |
| `vm_host.network_check` | jsonb NULL | last preflight and continuous-check result |

The defaults reproduce today's rows (routed, public, not reserved), so the migration is a no-op for upstream and Hetzner.

### 5.3 Location profile (`location.byoh_network`)

Each BYOH site is a real `Location` with its own name, display name and billing rates. This replaces the `HETZNER_FSN1_ID` default at `prog/vm/host_nexus.rb:6`.

```json
{
  "underlay_cidrs":     ["10.98.0.0/16"],
  "overlay_ipv4_cidrs": ["172.20.0.0/14"],
  "vm_egress_deny":     ["10.98.0.0/16"],
  "vm_egress_allow":    [],
  "cp_reach":           "onhost",
  "cp_source_cidrs":    ["10.98.1.10/32"],
  "host_mgmt_allow":    ["10.98.1.0/24", "<operator>/32"],
  "ula48":              "fdXX:XXXX:XXXX::/48",
  "ula_underlay":       "none | operator | mesh",
  "guest_mtu":          1400,
  "dns_servers":        []
}
```

| Field | Notes |
|---|---|
| `overlay_ipv4_cidrs` | Customer private subnets are drawn only from here. Upstream draws random ranges from 10/8, 172.16/12 and 192.168/16 (`model/private_subnet.rb:17-19`), and `172.20.0.0/14` sits inside 172.16/12. Validation must cover **existing** project subnets too, not only new ones (§10). |
| `vm_egress_deny` | Metadata addresses are always added (§6.5). Default: `underlay_cidrs` minus the pools. |
| `cp_source_cidrs` | The CP's source address as this site sees it. Feeds `host_mgmt_allow` checks and the union for `control_plane_outbound_cidrs` (§6.6). New field from the review. |
| `ula48` | Generated with SecureRandom when the location is created. |
| `ula_underlay` | §7.3. |
| `guest_mtu` | Lowered only for `mesh` over a 1500-byte underlay (§7.3). |
| `dns_servers` | Optional site resolvers for guests. Today the guest resolvers are hard-coded: dnsmasq forwards to `8.8.8.8` plus public IPv6 resolvers (`vm_setup.rb:519-523`), or hands out `8.8.8.8` directly when `ipv6_disabled` (`:509-511`), so `internal` sites that require company DNS have no hook. New field from the review [PLANNED P2]. |

**Location visibility** (UNVERIFIED, to resolve in P1):
- A `generic`-provider location maps to the `metal` dispatcher, which is fine (`origin/main:model/location.rb:72-79`).
- `Location.postgres_locations` filters by provider (`origin/main:model/location.rb:39-42`), so BYOH locations may not offer Postgres.
- `visible` and `project_id` scoping for BYOH locations is unspecified. **OPEN**

### 5.4 Pool declaration (`routed_networks` v2, `pools.yaml`) [PLANNED P1]

```yaml
uplink: ens5
routed_networks:
  - cidr: 10.98.1.128/29          # or a list of /32s
    delivery: fabric
    exposure: nat
    external:                     # required for every usable IP when exposure=nat
      10.98.1.129: 43.204.120.21
      # ...
    # external_cidr: 203.0.113.8/29   # alternative: block-to-block BINAT, mapped by offset
    usable: all                   # onlink default: strip segment network/broadcast/gateway only (§3.4)
    reserve: []
  - cidr: 2a01:db8:1:2::/64       # optional; absent => ipv6_mode=ula
    ndp: false
```

Bare strings and `{cidr}` keep their current meaning (`routed`/`public`).

### 5.5 Customer surfaces [PLANNED P1]

| Surface | Value |
|---|---|
| API `ip4` (`serializers/vm.rb:15`) | `public_ip4`. New field `ip4_scope` (`public`/`internal`). Detailed view only: `ip4_internal` (role A) when it differs from `ip4`. |
| API `ip6` | `public_ip6`; nil for ULA hosts |
| UI (`views/vm/overview.erb:17-21`, `views/vm/index.erb:26`) | "Public IPv4" or "Internal IPv4 (reachable only from `<location>` network)". The SSH hint uses `public_ip4`, and offers `ubi vm ssh --tunnel` when there is no public address (§12). |
| `ubi vm ssh` (`lib/ubi_cli.rb:285-296`) | API value; no change needed. `--tunnel` added in C4. |
| Postgres hostname, connection string, A record | `public_ip4`. Replication stays on role A. `internal` gets no public A record and a warning. |
| LB DNS (`prog/vnet/load_balancer_nexus.rb:157-198`) | Members' `public_ip4`/`public_ip6`. |
| LB certificates for `internal` | **Technically possible.** DNS-01 writes the challenge into Ubicloud's own `dns_zone` (`prog/vnet/cert_nexus.rb:44-45`) and does not depend on the VM addresses being public. Whether to offer them is a product choice. **OPEN** |
| MinIO / VictoriaMetrics / k8s SANs and DNS | `public_ip4`. Intra-cluster hosts stay on role A or private IPs. |
| Billing (`prog/vm/metal/nexus.rb:226-231`) | `resource_name` = `public_ip4`. No IPv4 record for `internal`. Rates come from `config/billing_rates.yml` (`lib/billing_rate.rb:14`), each row with a fixed UUID. `BillingRate.from_resource_properties(...)["id"]` raises NoMethodError when the location has no row, so **every** resource type and family (VmVCpu per family, VmStorage, IPAddress, and so on) needs a row per BYOH location before the first VM. |
| Abuse lookup (`Vm.from_ips`, `clover_admin.rb:975`) | matches `ip` OR `external_ip` |
| Admin VmHost page | pools with delivery, exposure, external, reserved, allocated VM, last check |

The VM create request gains `ip4_exposure`:
- `internet` (default) or `internal`.
- In a location that has only internal pools, the UI offers only "Internal IPv4" and labels it as such.
- In a location with mixed pools, a default request never silently receives an internal address.

---

## 6. Security model

### 6.1 Layers

| Layer | Owner | Policy | Status |
|---|---|---|---|
| Provider/edge filter (SG, NSG, GCP FW, pfSense WAN/LAN, Proxmox NIC firewall, provider firewall) | operator | **Allow everything** to and from pool IPs and externals, plus ESP and the v6 block. May restrict the host management IP only where rules can match the destination (GCP, Azure, pfSense, AWS split-ENI). | recipe |
| Host prerouting `drop_unused_ip_packets` | Ubicloud | drops traffic to unallocated or reserved pool IPs | [TODAY]; reserved rows [P1] |
| Host `host_guard` input | Ubicloud | policy drop; SSH only from `host_mgmt_allow`; VMs cannot reach the host | [PLANNED P2] |
| Host `host_guard` forward | Ubicloud | traffic from `vetho*` to 169.254.0.0/16 or fe80::/10 (not on-link) is dropped | [PLANNED P2] |
| VM netns egress chain (§4.3) | operator via location profile | metadata always; underlay per profile; unconnected overlay | [PLANNED P2] |
| VM netns anti-spoof | Ubicloud | `vm_setup.rb:413-428`, applied at `:442` | [TODAY] |
| VM netns `forward_ingress` | **customer** | the only VM ingress filter, keyed on real client source and port, IPv4 and IPv6 | [TODAY] |
| Access tunnel (§12.4) | customer (`Vm:connect`) | separately permissioned path that does not pass `forward_ingress` | [PLANNED C4] |

### 6.2 `host_guard` [PLANNED P2]

The table is `inet host_guard`. It is installed only on BYOH hosts.

```
table inet host_guard {
  chain input  { type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto ipv6-icmp accept        # ND/RA/PMTU, incl. on vetho* (needed for vethi↔vetho link-local routing)
    iifname "vetho*" drop                # VMs never talk to the host
    meta l4proto icmp accept
    udp dport { 68, 546 } accept         # DHCP/DHCPv6 client on cloud uplinks
    ip  saddr @mgmt_allow4 tcp dport 22 accept
    ip6 saddr @mgmt_allow6 tcp dport 22 accept
  }
  chain forward { type filter hook forward priority filter - 1; policy accept;
    iifname "vetho*" ip  daddr 169.254.0.0/16 drop
    iifname "vetho*" ip6 daddr fe80::/10    drop
  }
}
```

Notes:
- The ICMPv6 accept must come **before** the `vetho*` drop. The netns routes IPv6 via `vetho_ll` (`vm_setup.rb:289`), so NDP on the veth must reach the host.
- Forwarded VM traffic, including ESP to clover addresses, never hits `input`, so the guard cannot break VMs.
- Node exporter listens only on 127.0.0.1 (`rhizome/host/bin/setup-node-exporter:38`), so it is unaffected.
- The console and access tunnel (§12) use host TCP 22 from the control plane, which `host_mgmt_allow` already permits. No new host port is opened.
- P6 egress-only VMs add a host `masquerade` rule for 169.254.0.0/16 to this same file. [ROADMAP.md](ROADMAP.md) M2 ships that rule earlier as its own gated `/etc/nftables.d/` file and folds it in here at P2 (OPEN, ROADMAP D-8).
- P2 also owns NH-6: Ubuntu's `/etc/nftables.conf` starts with `flush ruleset`, so every reload wipes Docker, ufw, Tailscale, k3s or libvirt rules on the host ([PLATFORMS.md](PLATFORMS.md) #11). The fix is not designed yet.

**Persistence.**
- The host loads `/etc/nftables.conf` (Ubuntu's default starts with `flush ruleset`), and `setup-nftables.rb:42-50` appends an include of `/etc/nftables.d/*.conf`.
- A separate systemd unit would be flushed whenever `nftables.service` (re)starts after it. **Do not ship `host_guard` as its own unit.**
- Ship it as `/etc/nftables.d/1-host-guard.conf`, written only after the rollback timer confirms (below).

**Lockout safety:**

| Step | Action |
|---|---|
| 1 | Registration refuses an empty `host_mgmt_allow`. |
| 2 | Registration refuses an allow-list that does not contain `cp_source_cidrs` (the CP's source as the host sees it). |
| 3 | `Prog::SetupHostGuard` loads the ruleset with `nft -f` (not the file yet) and starts `systemd-run --on-active=90 nft delete table inet host_guard`. |
| 4 | It opens a **new** SSH session. Only if that succeeds does it cancel the timer and write `/etc/nftables.d/1-host-guard.conf`. |
| 5 | Recovery path: AWS SSM or EC2 serial console, Proxmox console, BMC. |
| 6 | A periodic check pages and sets the host non-accepting if `host_guard` is missing on a host whose profile declares the infra filter open. |

### 6.3 The open infra filter

With `host_guard` live, "infra filter open to everything" (C3) is safe on every platform, AWS's single ENI included.

**Live AWS state** [TODAY, verified 2026-10-12]:

| Item | State |
|---|---|
| `aws_security_group.data` (`terraform/aws-byoh/main.tf:170-216`, uncommitted) | Drafted. The open-ingress rule is a `dynamic` block gated on `data_plane_open_ingress`. |
| `variables.tf:77-81` default for `data_plane_open_ingress` | `false` |
| `company-mumbai.tfvars` (live workspace) | `data_plane_open_ingress = false`, `operator_ssh_cidr = 142.44.142.129/32` |
| Stale saved plan files (`*.tfplan`) | Deleted |
| `terraform.tfvars` (non-live example workspace) | Still `operator_ssh_cidr = "0.0.0.0/0"`. Fix before anyone applies it. |

So any terraform apply before P2 leaves the SG closed. The flag is flipped to `true` only in live step L6 (§14.9), after `host_guard` is confirmed.

Optional hardened posture for shared AWS accounts (split-ENI), documented, not the default:
- ENI0: management, restrictive SG.
- ENI1: pool, open SG.
- The host needs policy routing for traffic sourced from pool IPs. Operator-configured; UNVERIFIED.
- `host_guard` stays mandatory.

### 6.4 Veth link-local addresses (APIPA) [PLANNED P2]

The veth APIPA picker (`model/vm_host.rb:162-167`) picks a random pair and, on collision, walks forward with `ip = ip.next.next` (`:165`).
- It must never return an address in 169.254.0.0/24, 169.254.169.0/24, 169.254.170.0/24 or 169.254.255.0/24, so a veth /32 can never shadow a cloud link-local service.
- The exclusion check must sit **inside** the collision loop, because the walk can step into an excluded /24.
- This change applies to all hosts (not gated). It only removes candidate addresses, so it is behaviour-safe (P6).

### 6.5 VM egress deny list [PLANNED P2, BYOH hosts only]

`@egress_deny` always contains:

| Address | Service |
|---|---|
| 169.254.169.254, 169.254.170.2 | AWS/GCP/Azure metadata, ECS |
| 168.63.129.16 | Azure wireserver |
| fd00:ec2::254 | AWS IMDS over IPv6 |

It also contains the location's `vm_egress_deny`. The ordering in §4.3 ensures replies to established connections are never dropped.

Related hardening:
- AWS hosts also set `metadata_options { http_tokens = "required", http_put_response_hop_limit = 1 }`. Absent from `main.tf` today.
- Whether a VM can reach the host's IMDS today is UNVERIFIED.

### 6.6 Platform-managed firewalls and `control_plane_outbound_cidrs`

Postgres and k8s internal firewalls allow `Config.control_plane_outbound_cidrs` on port 22.
- It is **one global setting** (`config.rb:120`, default `0.0.0.0/0,::/0`), not per location.
- A CP serving AWS (`onhost`, underlay /32), Proxmox (another underlay) and Hetzner (public egress) must list **the union** of all its source addresses: every location's `cp_source_cidrs`, plus the public egress IP for `cp_reach: public` sites.
- [PLANNED P1] Preflight warns while it is `0.0.0.0/0`, and warns when a location's `cp_source_cidrs` is missing from it. A per-location value is a possible later change. **OPEN**

---

## 7. IPv6

### 7.1 Modes (per host)

| `ipv6_mode` | When | Customer sees | Private networking |
|---|---|---|---|
| `gua` | A real routed GUA /64 (or AWS /80, GCP /96 after their spikes) satisfying C7. `ndp: true` for on-link prefixes uses upstream `Prog::SetupNdpProxy` (`origin/main:prog/setup_ndp_proxy.rb`, `origin/main:doc/ndp_proxy.md`). | real IPv6, AAAA records | cross-host over the underlay, as upstream |
| `ula` | No routable IPv6 | **No IPv6.** `public_ip6` is nil, no AAAA records, and the guest gets no IPv6, via a **new host-gated parameter** (below). Clover addresses still exist. | same host after the netns ULA route; cross-host per §7.3 |

**Why not reuse upstream `ipv6_disabled`.** It does not work for this:

| Problem | Evidence |
|---|---|
| It is a *project* feature flag, not a per-host setting. | `model/metal/vm.rb:97,121` |
| When on, rhizome's `gua` becomes `nic.private_subnet.random_private_ipv6`, but the xfrm templates still come from `vm.ephemeral_net6`, so clover addresses no longer match. | `model/metal/vm.rb:97`; `rekey_nic_tunnel.rb:74-75` |
| It sets guest and clover to `::/0`, so the firewall template emits `ip6 daddr ::/0 accept` and `ip6 saddr ::/0 accept`, accepting every forwarded IPv6 packet. | `update_firewall_rules.rb:16` |

[PLANNED P4] Instead: a new parameter (for example `guest_ipv6: false`) emitted only for `ula` BYOH hosts. It keeps clover space from `vm_host.net6`, removes the guest's IPv6 address and RA, and leaves the firewall rules keyed to real addresses. Spec plus live test.

[TODAY] the host gets a random ULA via `rand` (`lib/byoh_registration.rb:141-147,207-211`), and the UI shows it as IPv6. That is wrong.

[PLANNED P1/P4]:
- the ULA /64 is carved deterministically from the location's SecureRandom `ula48`;
- it is hidden from customers;
- the hard-coded `fd00:aa55::/64` in `scripts/byoh/providers/aws-routed-network-setup.sh:200` is removed.

### 7.2 Prefix sizes

| Prefix | Per VM | Status |
|---|---|---|
| /64 | /79 | supported [TODAY] |
| /80 (AWS ENI prefix) | /95 split into two /96s (`model/vm_host.rb:83-129`, `vm_setup.rb:263-267`; math checked) | UNVERIFIED end to end; spike in P4 |
| /96 (GCP) | /111 | UNVERIFIED |

### 7.3 Cross-host private networking in `ula` mode

| `ula_underlay` | Meaning |
|---|---|
| `none` | Single-host location, or cross-host private subnets not offered. The scheduler places all VMs of a private subnet on one host [P4]. |
| `operator` | The operator routes each host's /64 to that host (same L2 with IPv6 on the underlay, or pfSense static routes). Preflight verifies it. |
| `mesh` | [PLANNED P5] Ubicloud-managed WireGuard mesh between the location's hosts. Carries **only** the ULA /48 (outer IPsec), never VM IPv4. Keys generated on each host; only public keys stored. |

**Mesh MTU.** The earlier figure of 1360 is too high over a 1500-byte underlay:

| Layer | Bytes |
|---|---|
| Underlay MTU | 1500 |
| WireGuard overhead | 60 over IPv4, 80 over IPv6 [EXT] |
| Outer IPv6 header for ESP | 40 |
| ESP overhead (cipher-dependent, including padding and ICV) | about 40-60 [EXT] |
| **Guest MTU left** | **about 1320-1360**, lower over an IPv6 underlay |

Rule: compute the value, confirm with `tracepath` in preflight, and pass it via DHCP option 26 (`vm_setup.rb:545`). Start at 1320 until measured. Over the AWS VPC (MTU 9001) the guest stays at 1400.

**AWS preference:** GUA via ENI /80 (P4 spike). The mesh is the fallback.

---

## 8. Verification (identical on every platform)

### 8.1 Hard checks (block `accepting`) [PLANNED P3]

- C5: no allocatable pool IP local on the host.
- Exactly one uplink carries the default route.
- Required sysctls are present.
- Egress per `public`/`nat` IP (§8.2).
- `host_guard` present.
- `ula`/`operator` routes present.
- C0: CP reaches the host management IP.

### 8.2 Reusing upstream `CheckIpReachability`

This extends upstream `Prog::CheckIpReachability` and `host/bin/check-ip-reachability` (`origin/main:prog/check_ip_reachability.rb`, `origin/main:rhizome/host/lib/ip_reachability_check.rb`); it is not a parallel prog. It conflicts with C5 as written upstream:

| Upstream behaviour | Conflict | Required change |
|---|---|---|
| `with_address` adds each pool IP to `lo` while it pings out. | Run on a host with VMs, it takes over traffic for allocated IPs, and `check-pool-not-local` would flag it. | Skip allocated IPs. Use a scratch netns, never `lo` in the root namespace. |
| Runs only before `prep` (`origin/main:prog/vm/host_nexus.rb:84-87`). | Fine for registration; not a continuous check. | Continuous checks use the scratch-netns probe only. |
| On failure it naps forever and pages after 5 tries. | Blocks `internal` and no-egress sites forever. | Per-exposure policy: `internal` pools skip the internet egress check; `nat` checks egress-IP echo = E. |

### 8.3 Inbound probe per IP

1. The host binds P in a scratch netns with a nonce listener.
2. The control plane connects to the `cp_reach` address. The listener records the peer address, and the result checks C2 against `cp_source_cidrs`.

**What this proves, honestly:**

| Exposure | What the CP probe covers | What it does not |
|---|---|---|
| `public` with `cp_reach: public` | C1, C2, C3 along the real path | — |
| `nat` or `onlink` with `cp_reach: onhost` | Delivery of P on the local network | The CP dials P directly over the VPC/LAN and **bypasses the EIP or 1:1 edge**. C1, C2 and C6 for E are not checked. |

A hard check for E needs an **external vantage point**: a small probe service outside the site [PLANNED P3, optional]. Until it exists, E checks are operator-run (`verify --from-outside`) and failures page but do not block.

**Operator-side drift** (EIP disassociated, pfSense rule changed, Proxmox ipfilter re-enabled) only surfaces through probes that cross the edge. Without the external prober, the continuous checks will not see it. Known gap.

### 8.4 Continuous and operator-run checks

Continuous:
- `check-pool-not-local` on every `SetupNftables` run.
- Periodic `host_guard` presence check.

Operator-run:
- `bin/byoh-pool verify --from-outside` prints `nc`/`curl` commands per E to run from an internet machine.
- `bin/byoh-pool trace <external-ip>` prints the declared mapping, host, VM, netns NAT rules and conntrack entries.
- Optional **read-only** verifiers, run by operator tooling with read-only credentials: AWS describe-only (src/dst check, IMDS, EIP associations, per-ENI IP limit, EIP quota); pfSense rule and NAT export check; Proxmox NIC `firewall`/`ipfilter` check.

### 8.5 `docs/byoh/VERIFY.md` checklist [PLANNED P3]

1. `ip -br addr` on the host shows only the host's own addresses.
2. Every pool IP and E is reachable from outside.
3. **Negative firewall test**: open 80 only from one /32; reachable from that /32, not from another source.
4. Egress, DNS and apt work.
5. VM → underlay is denied by default; an office client can still use an `internal` service (reply path).
6. VM → 169.254.169.254 is blocked.
7. VM ↔ VM private subnet works on the same host, and across hosts where offered. VM → unconnected private subnet is dropped.
8. VM A → E of VM B at the same site works (hairpin, §4.6).
9. DNS still works after adding the VM to a load balancer (§4.7).
10. Host SSH from a non-allowed source is refused.
11. After a host reboot, everything above passes again, and `nft list table inet host_guard` shows the table.

---

## 9. Platform runbooks

Each platform gets a page under `docs/byoh/platforms/`. The Ubicloud side is identical everywhere [PLANNED P1]:

```
bin/byoh-location create --name <site> --display "<Name>" --underlay <cidrs> --overlay 172.20.0.0/14 \
    --cp-reach onhost|public --cp-source <cidr> --mgmt-allow <cidrs> [--ula-underlay none|operator|mesh]
bin/register-byoh-host --location <site> --main-ip <host ip> --uplink <if> --pool-file pools.yaml [--ipv6 <cidr>[,ndp]|none]
bin/byoh-pool verify --host <ubid> [--from-outside]
```

[TODAY] `bin/register-byoh-host` has `--main-ip`, `--routed-network`, a label-only `--location`, BMC flags, `--ssh-key`, `--server-identifier`, `--default-boot-image` and `--yes` (`bin/register-byoh-host:60-103`). There is no `--provider` flag; docs that pass one are wrong.

### 9.1 AWS EC2 (matches `terraform/aws-byoh`): fabric + nat

| Item | Value |
|---|---|
| Network | VPC `10.98.0.0/16`, subnet `10.98.1.0/24`, ap-south-1a (`variables.tf:13-22`) |
| Control plane | t3.large (live; terraform default t3.medium is stale), SG `byoh` |
| Data plane | m8i.2xlarge, `data_plane_nested_virtualization=true`. The `variables.tf` default `m5d.metal` is stale. |
| Uplink | primary ENI `ens5`, 10.98.1.138, own public IP for operator SSH (`main.tf:276`) |
| src/dst check | Today `source_dest_check = false` (`main.tf:284`). **Not needed for `fabric`** (C4): pool IPs are assigned to the ENI. Leaving the check off widens the spoofing surface. Recommendation: turn it back on when all pools are `fabric`; keep it off only for `routed` or tunnel pools. UNVERIFIED on the live host; change only in a planned window. |
| Pool | `byoh_secondary_private_ips` 10.98.1.128-135 (`main.tf:292`), each with an EIP (`main.tf:329-344`) |
| C5 | `user-data-data.sh` (~`:50-69`: cloud-init `apply_full_imds_network_config: false`, netplan strip, `ip addr del`). Preflight enforces it from P2. |
| Filter | `aws_security_group.data`; `data_plane_open_ingress=true` **only after `host_guard`** (§6.3) |
| IMDS | `metadata_options { http_tokens="required", http_put_response_hop_limit=1 }` [PLANNED P2] |
| Pool file | [PLANNED P1] terraform output `.generated/<ws>/pools.yaml` (`delivery: fabric`, `exposure: nat`, `external` from `aws_eip.byoh`). Replaces the display-only `byoh_eip_to_private_ip` output (`outputs.tf`). |
| Profile | underlay `10.98.0.0/16`, overlay `172.20.0.0/14`, `cp_reach: onhost`, `cp_source_cidrs` = control-plane private /32, mgmt_allow = that /32 + the operator /32 (`operator_ssh_cidr` must not be `0.0.0.0/0`), `ula_underlay: none` until GUA |
| IPv6 | `ula` today. [P4 spike] VPC `assign_generated_ipv6_cidr_block`, subnet /64, `::/0` via the IGW, `ipv6_prefix_count=1` on the ENI, register `--ipv6 <the /80>`. SG adds `::/0`. |
| Limits | EIP quota defaults to 5 per region [EXT]. About $0.005/h per public IPv4 [EXT]. m8i.2xlarge per-ENI IP limit UNVERIFIED; terraform must validate the count. |
| Customer view | IPv4 = EIP. SSH, PG and LB DNS use the EIP. Firewall rules fully effective. |
| Retired | `scripts/byoh/providers/aws-routed-network-setup.sh` (EIP leak at `:164-172`, /24 assumption, fixed ULA). The VPC route-table method for CIDRs inside the VPC (`docs/providers/generic.md:81-123`). |

### 9.2 Company Proxmox behind pfSense (vmbr1 10.80.0.0/24, pfSense 10.80.0.1)

**Common setup:**

| Item | Value |
|---|---|
| Data-plane VM | `cpu: host`, nested virtualization |
| NIC | **one** NIC on vmbr1, for example 10.80.0.20/24, gateway 10.80.0.1. Do not dual-home: the vmbr0 DHCP + vmbr1 layout in the current Proxmox docs causes asymmetric egress (UNVERIFIED). |
| Proxmox firewall | Off on that NIC, or `ipfilter`/`macfilter` disabled, so proxy-ARP replies for pool IPs are not dropped. PVE default UNVERIFIED. |
| Control plane | If the CP is not on 10.80.0.0/24 (for example, the AWS CP), the site needs a routed path to the CP (C0, §4.5). |
| `underlay_cidrs` | `[10.80.0.0/24, <office LANs>, <VPN pool>]` |
| `overlay_ipv4_cidrs` | `[172.20.0.0/14]`, must not clash with office ranges |
| `cp_reach` | `onhost` (requires C0) |
| `vm_egress_deny` | = underlay. VMs cannot open connections to the company LAN unless `vm_egress_allow` permits it. Office clients can still use services on `internal` VMs (§4.3 order). |
| `host_mgmt_allow` | `[10.80.0.0/24 or the CP /32, admin VPN]` |
| `dns_servers` | company resolvers, if guests must use them |

**Variant A: no public block (today). onlink + internal.**
1. Shrink the pfSense DHCP range so 10.80.0.200-10.80.0.239 is free.
2. Declare `10.80.0.200/29,…`, `delivery: onlink`, `exposure: internal`. All 8 addresses of each /29 are usable (§3.4).
3. The pfSense default outbound NAT already masquerades 10.80.0.0/24 (C4). LAN rules must pass traffic from the pool IPs.
4. Customers see **Internal IPv4**, reachable from the office and VPN. No internet ingress. IPv6 is `ula`.

This is a valid internal-cloud product, not a degraded public one.

**Variant B: the ISP provides N extra public IPs. onlink + nat.**
1. pfSense: Firewall → Virtual IPs. Add each public IP (type IP Alias or Proxy ARP).
2. Firewall → NAT → 1:1: WAN, external `E_i` → internal `10.80.0.20x`.
3. WAN rule: pass any protocol to each internal target (C3).
4. NAT reflection **off** for these entries (C2). VM-to-E at the site works through the Ubicloud hairpin DNAT (§4.6). Office clients need split-horizon DNS.
5. Declare `exposure: nat` with an `external:` map.

Same shape as AWS.

**Variant C: the ISP routes a block to the pfSense WAN. routed + public.**
1. pfSense: gateway object `10.80.0.20` on LAN, then static route `<block> → that gateway`.
2. WAN rule: pass any to the block.
3. Hybrid outbound NAT: a **"Do not NAT"** rule for source = block.
4. Declare `delivery: routed`, `exposure: public`.

Best option when the ISP agrees to route.

**Variant D: one WAN IP but internet ingress needed.** Tunnel recipe (§9.4).

**IPv6:** if the ISP delegates a prefix (DHCPv6-PD) to pfSense, route a /64 to 10.80.0.20 and use `gua` (or `ndp` when on-link). Otherwise `ula`.

### 9.3 Homelab behind a consumer router

| Need | Option |
|---|---|
| LAN-only | Like Proxmox variant A (`onlink`/`internal`), or `routed` via a router static route `192.168.50.0/27 → host` |
| Internet ingress | Tunnel recipe (§9.4). Under CGNAT there is no other option. |
| SSH to VMs from anywhere without ingress | Access tunnel (§12.4) |
| IPv6 | ISP /56 via PD plus a router static route of a /64 to the host gives `gua` [EXT] |
| Router port forwards | Lab helpers only (§3.3) |

### 9.4 Tunnel recipe (single IP, CGNAT, homelab) [PLANNED P6, operator-owned]

1. Rent a VPS or dedicated server with a **routed** additional subnet (for example Hetzner or OVH routed mode).
2. Run a WireGuard tunnel from the host to it. The VPS routes the block into `wg0`.
3. The host sends pool-sourced traffic back the same way: `ip rule from <pool> lookup 100`, with `default dev wg0` in table 100.
4. Declare the block `delivery: routed`, `exposure: public`, pool uplink `wg0`. Preflight accepts a per-pool uplink.
5. The `wg0` routes must not overlap the host's LAN segment (§3.4, proxy_arp).
6. MTU: WireGuard leaves about 1420, so guest MTU 1400 fits.

Scripts: `scripts/byoh/providers/wireguard-tunnel/{vps.sh,host.sh}`.

### 9.5 Bare metal: routed + public

| Provider | Notes |
|---|---|
| Hetzner Robot | Additional subnets and IPs are routed to the main IP. Failover IPs are `routed`; switching them is operator-side. vSwitch public subnets are `onlink`. IPv6: server /64 is `gua`, `ndp: false` as upstream (whether Hetzner needs NDP is UNVERIFIED). Robot firewall off, or allow all to the pool. |
| OVH | Additional IPs in **routed mode** only. vMAC/bridged mode does not fit rhizome, because guest MACs never reach the uplink. IPv6 is an on-link /64: `--ipv6 <cidr>,ndp` (needs P0 `SetupNdpProxy`). |
| Leaseweb and others | Routed blocks. When the provider requires an address of the block on the NIC (as `origin/main:lib/hosting/leaseweb_netplan.rb` does), that address is reserved, never allocatable (C5). |
| Everywhere | Never put allocatable pool IPs in netplan (C5). `cp_reach: public` when the CP is elsewhere, and add its egress IP to `control_plane_outbound_cidrs` (union, §6.6). |

### 9.6 Colo with BGP: routed + public

- Static route, or ToR BGP, of a per-host block to each host's main IP.
- IPv6: a routed /64 per host from your /48.
- Running FRR on the host is out of scope for the driver. Operator-owned recipe in `docs/byoh/platforms/colo-bgp.md`.

### 9.7 GCP (experimental, UNVERIFIED)

- N2/C3 with nested virtualization, `can_ip_forward=true`.
- Per-VM public IPv4 via **protocol forwarding** (forwarding rule → target instance), which delivers dst unchanged: `routed` + `public`, with the externals as the pool.
- Or alias ranges as `fabric` + `internal`.
- The guest agent must not add local routes for forwarded or alias IPs (C5).
- VPC firewall: allow all with destination = pool. SSH-only for the host IP.
- IPv6: dual-stack /96 as `gua` (after the P4 spike).

### 9.8 Azure (experimental, UNVERIFIED)

- Dv3/Ev3 or newer with nested virtualization; NIC IP forwarding on.
- Secondary ipconfigs, each with a Public IP: `fabric` + `nat`. The agent and cloud-init must not configure them.
- NSG: allow all to the pool private IPs.
- IPv6: Azure NATs IPv6, so use `ula`.

### 9.9 Summary

| Platform | delivery | exposure | IPv6 | Infra filter | No-public-IP access |
|---|---|---|---|---|---|
| AWS (live) | fabric | nat | ula → gua /80 (P4) | SG open + host_guard (optional split-ENI) | access tunnel |
| Proxmox/pfSense today | onlink | internal | ula / PD gua | pfSense LAN pass | access tunnel |
| Proxmox + extra IPs | onlink | nat | as above | WAN pass, reflection off | access tunnel |
| Proxmox, routed block | routed | public | as above | WAN pass, no-NAT rule | access tunnel |
| Single IP / CGNAT / homelab ingress | routed (wg0) | public | ula / PD | VPS: none | access tunnel |
| Hetzner / OVH / Leaseweb | routed (vSwitch: onlink) | public | gua (OVH: ndp) | provider firewall off | access tunnel |
| Colo BGP | routed | public | gua | own | access tunnel |
| GCP | routed (proto-fwd) / fabric | public / internal | gua /96 | VPC FW by destination | access tunnel |
| Azure | fabric | nat | ula | NSG | access tunnel |

---

## 10. Pool lifecycle [PLANNED P1]

`bin/byoh-pool` replaces `scripts/byoh-ops/reconfigure-routed-networks.rb`, which destroys every VM (`:93-123`).

| Command | Behaviour |
|---|---|
| `list --host` | pool IPs, external, exposure, allocated VM |
| `add` (`--pool`, `--pool-file`) | same validation as registration; additive; re-runs SetupNftables and checks; **no VM touched** |
| `remove` | refuses allocated IPs unless `--drain`, which destroys only the affected VMs and waits for completion |
| `remap --ip P --external E` | updates both tables, refreshes PG/LB DNS and the hairpin DNAT sets (§4.6) |
| `annotate` | sets delivery, exposure and externals on existing rows (migration) |
| `ipv6 set` | changes net6 on an empty host only |
| `verify [--from-outside]`, `trace <ip>` | §8 |

Every command writes an audit log row.

**Registration validation** [PLANNED P1]:

| Check | Rule |
|---|---|
| Syntax | CIDRs parse and are aligned. IPv4 blocks no larger than /22. |
| Uniqueness | No overlap within the host or anywhere in the database. |
| Management IP | Never in a pool; auto-reserved with a warning. |
| `public` | Refuses RFC1918, 100.64/10 and special-use addresses. |
| `nat` | Needs a globally routable, database-unique E for every usable IP. |
| IPv6 | A ULA is refused as `gua`. |
| Overlay | Pools must not overlap `overlay_ipv4_cidrs`; existing project subnets in the location must not overlap underlay or pools. |
| `onlink` | Strips the segment's network, broadcast and gateway only; rejects overlapping routes (§3.4). |
| Host-anchored addresses | Addresses the provider requires on the NIC are reserved. |

---

## 11. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| SSH to the VM gives "Permission denied (publickey)", or `wait_sshable` passes but customers cannot log in | Pool IP configured on the host (C5): the host answers instead of the VM | `ip -br -4 addr` on the host; cloud-init/netplan |
| Inbound times out, egress works | Infra filter (C3), or a missing EIP/1:1 mapping. On live AWS today: expected, the SG is closed until L6. | probe; SG/pfSense rules; `byoh-pool trace E` |
| Customer allow-from-CIDR rule never matches | Source not preserved (C2): NAT reflection, port forward, LB | probe peer check; `conntrack -L` in the netns |
| VM cannot reach VPC/LAN or another VM's public IP | RFC1918 SNAT exemption [TODAY], or egress deny [P2] | `nft list table ip nat` in the netns; profile `vm_egress_allow` |
| VM cannot reach E of another VM at the same pfSense site | Reflection off, hairpin DNAT not yet installed | §4.6 |
| Guest DNS fails on an IPv6-less host | VM created before the 971a3d608 backport, **or** the VM was added to/removed from a load balancer (§4.7) | `nft list ruleset` in the netns: look for the `dport 53` SNAT rules; recreate the VM |
| Private subnet ping fails | ULA net6 without the netns route or cross-host routing | `ip -n <vm> -6 route`; `ip xfrm state` |
| Host unreachable after a guard change | `host_mgmt_allow` is wrong | wait 90 s for the rollback; console/SSM; `nft delete table inet host_guard`; remove `/etc/nftables.d/1-host-guard.conf` |
| `host_guard` gone after a reboot or `systemctl restart nftables` | Guard installed outside `/etc/nftables.d/` | §6.2 persistence |
| Proxmox pool IPs unreachable | Proxmox `ipfilter`/MAC filter, stale pfSense ARP, IP in the DHCP range, overlapping route answered by proxy_arp | `arping` from pfSense; PVE NIC firewall settings; `ip route` on the host |
| VM stuck at `wait_sshable` | CP cannot reach the `cp_reach` address (C0); `control_plane_outbound_cidrs` | `nc -vz <ip> 22` from the CP |
| Large transfers hang across hosts on a mesh site | Guest MTU too high | `tracepath` between VMs; §7.3 |

---

## 12. Reaching VMs without a public IP

Goal: a customer can see a VM's console in the browser, and SSH to it, even when the VM has no public IPv4, on every platform, without per-platform setup. The full console and access design is [ROADMAP.md](ROADMAP.md) §4 (it may move to `docs/byoh/CONSOLE_AND_ACCESS.md` when C1 ships); this section is the networking view. Console phases C1, C2 and C4 ship in milestone M6; C3 and C5 in M11.

Phase tags here are **[PLANNED Cn]** (§12.7). Upstream work is **[UPSTREAM]**.

### 12.1 Facts this depends on

| # | Fact | Evidence |
|---|---|---|
| V1 | Cloud Hypervisor runs with `--console off --serial file=/vm/<inhost>/serial.log`, recreated (truncated) on each in-guest reboot. | `rhizome/host/lib/vm_setup.rb:788`, `:860-861` |
| V2 | The CH unit runs as user `<inhost>` inside the VM netns; serial.log is deleted with the VM's home on purge. | `vm_setup.rb:702-704`, `:798`, `:175-179` |
| V3 | Upstream has a read-only 64 KiB serial log (`RunCommand`, `Prog::Vm::RunCommandNexus`), fetched by respirate, never by the web process; plus a "Serial Log" tab, API, CLI and admin action. | `origin/main:model/run_command.rb`, `origin/main:prog/vm/run_command_nexus.rb`, `origin/main:routes/project/location/vm.rb` |
| V4 | `byoh-driver` has none of V3. A cherry-pick is not clean (it touches `model/gcp/vm.rb`, absent here). | `routes/project/location/vm.rb:53` |
| V5 | No websocket support exists in the app. `websocket-driver 0.8.0` is locked only through `ferrum` (via `cuprite`, Gemfile `:development` group). Puma runs 15 threads. | `Gemfile.lock`; `puma_config.rb` |
| V6 | Host SSH uses `verify_host_key: :accept_new` with empty known_hosts, so no host key is pinned. `sshable.host` is UNIQUE. | `model/sshable.rb:193-196,202-245,293` |
| V7 | **The host's root namespace has no route to a VM's private IPv4.** It routes only the pool IP P via `vetho` (`ip route replace #{vm} dev vetho`). Private subnet routes exist only inside the netns. Host → netns IPv6 is routed, but the netns returns only `2000::/3`, so a ULA host source gets no reply (inferred; UNVERIFIED live). | `vm_setup.rb:330-352`, `:268-290` |
| V8 | Guest user-data sets no password and `ssh_pwauth: false`, so a serial login has no usable credential by default. | `vm_setup.rb:582-591` |
| V9 | CH versions 35.1 and 46.0. Whether `--serial socket=` behaves as needed on both is UNVERIFIED. | `rhizome/host/lib/cloud_hypervisor.rb:113-124` |

**Correction to portability F8 Tier 0.** `ssh -J root@<host> ubi@<private_ipv4>` cannot work, because of V7. Valid forms are in §12.3 (T0).

### 12.2 Architecture

```
Browser (xterm.js)                      Control plane (puma, web host)                    Data-plane host
 POST …/vm/<v>/console/session  ──CSRF──► authorize, audit_log,
   ◄── {ws_url, token(30s, 1-use)}        insert vm_console_session(issued)
 GET wss://<base>/…/console/ws?t=… ─────► Origin==base_url, cookie account==token account
   (via Cloudflare tunnel)                rack.hijack (full) → puma thread freed
                                          Console::Bridge thread:
                                            websocket ⇄ Net::SSH channel ──────SSH:22──► user ubiconsole (key-only)
                                            ping 25s, timeouts, re-auth 60s               ForceCommand vm-access-relay
                                                                                          sudo -n vm-access-helper
                                                                                            serial-tail → tail -F serial.log
                                                                                            serial ro|rw → serial-mux.sock
                                                                                            tcp 22 → ip netns exec <v>
                                                                                                     → private_ip:22
```

| Decision | Choice | Why |
|---|---|---|
| Where websockets end | In puma, full `rack.hijack`, one Ruby thread per session | Nothing extra to deploy; the existing cloudflared → :3000 route keeps working; puma threads are freed [EXT]. A separate gateway process is deferred (C5). |
| How the CP reaches the host | New restricted host account `ubiconsole` with a per-host Ed25519 key. Not the rhizome key. | The key can only run the relay: no shell, no forwarding, one sudo helper. Honest limit: the web process can already decrypt rhizome keys, so this narrows the *path*, not key custody. |
| Network path | The existing CP → host management SSH (port 22, already in `host_mgmt_allow`) | **No new port on the host or VM, no VM egress, no VM public IP.** Works wherever the CP can manage the host (C0). |
| Console type | Serial text console only | CH has no display device here; VNC is not planned. |
| One mechanism for console and SSH | Yes: relay mode `tcp` | One permission model, one audit trail. |

### 12.3 Access tiers

| Tier | Path | Who | Needs | Works on | Status |
|---|---|---|---|---|---|
| **T0 operator** | `ssh -J <host> ubi@<P>` (VM has a pool IPv4; P is on-host and DNATed in the netns), or `ssh -o ProxyCommand="ssh root@<host> ip netns exec <inhost> nc %h 22" ubi@<private_ip>` | operator (root on host) | host SSH | all | [TODAY] |
| **T1 Ubicloud access tunnel** (recommended) | `ubi vm <loc/name> ssh --tunnel`. The CLI opens `wss …/vm/<v>/connect/ws` with a PAT and acts as `ProxyCommand`. CP → `ubiconsole` → `tcp <inhost> 22` → `ip netns exec` → private_ip:22. The guest SSH key is still used end to end (raw TCP; no man-in-the-middle). | customer with `Vm:connect` | only the CP URL; **no VM egress, no public IP, no per-host cloudflared** | every platform identically (AWS, Proxmox, homelab, CGNAT) | [PLANNED C4] |
| **T2 guest cloudflared / tailscale** | Customer installs it in the guest; opt-in cloud-init snippet | customer | VM IPv4 egress. A VM without a pool IPv4 has none until P6 egress-only NAT (`vm_setup.rb:386` returns early) | after P6 egress-only NAT (pulled into milestone M2, ROADMAP §3.3) | [PLANNED P6] |
| Browser serial console | §12.2, live read-only first, then interactive | customer with `Vm:view` (ro) / `Vm:console` (rw) | only the CP URL | all | [PLANNED C2/C3] |
| ~~Per-host cloudflared~~ | Former F8 Tier 1 | — | per-host Cloudflare config plus netns access | — | **Replaced by T1** (§3.3) |

Notes:
- **T1 and `cp_reach`.** T1 rides CP → host SSH, the reachability C0 already requires. It adds no requirement and needs no CP → VM route.
- **T1 and `wait_sshable`.** T1 does not fix `wait_sshable`. The host-side probe (§4.5) is still needed for `internal` and no-IPv4 VMs; it reuses the helper's validation code.
- **Browser "web SSH" rejected.** It would hold the guest private key in the browser or on the server. Use the serial console with a console password, or the CLI tunnel.
- **API host.** T1 runs on the `api.` host with a PAT bearer token (`clover.rb:325`, rodauth `:api`) plus a single-use ticket POST → WS. No cookies, so no CSRF ticket.

### 12.4 How T1 relates to the customer firewall

| Point | Detail |
|---|---|
| Path | The `tcp` relay connects from inside the netns. Locally generated traffic goes through OUTPUT, not FORWARD, so the customer's `forward_ingress` (`update_firewall_rules.rb:102`) **does not apply**. |
| Decision | The tunnel is a separately permissioned path (`Vm:connect`), like GCP IAP or EC2 Instance Connect Endpoint [EXT]. It is the one stated exception to P4. |
| Customer control | Per-VM toggle `vm.access_tunnel_enabled` (default true), shown on the Networking tab. |
| Reach | Only the VM's private IP from `/vm/<v>/prep.json`, only port 22 (allow-list). Never an address supplied by the caller. |
| `host_guard` | Unaffected: no new host port. Egress deny (§6.5) is unaffected: relay traffic goes VM-ward, not out. |
| Alternative | Route tunnel traffic through `forward_ingress` instead: harder, UNVERIFIED. **OPEN** |

### 12.5 Host-side pieces [PLANNED C1/C3]

| Piece | Behaviour |
|---|---|
| user `ubiconsole` | `adduser --disabled-password`. `/etc/ssh/sshd_config.d/20-ubiconsole.conf`: `Match User ubiconsole` → `ForceCommand /home/rhizome/host/bin/vm-access-relay`, `PermitTTY no`, `AllowTcpForwarding no`, `X11Forwarding no`, `AllowAgentForwarding no`, `PermitTunnel no`. The authorized_keys line carries `restrict`. |
| `vm-access-relay` | Parses `SSH_ORIGINAL_COMMAND` = `serial-ro|serial-rw|serial-tail <inhost>` or `tcp <inhost> 22`. `inhost` must match the `ubid_to_name` format (regex UNVERIFIED) and `/vm/<inhost>` must exist. Anything else exits 2. Then `exec sudo -n vm-access-helper …`. |
| `/etc/sudoers.d/97-ubiconsole` | That one helper only. |
| `vm-access-helper` (root) | Re-validates arguments. `serial-tail`: `tail -c 65536 -F serial.log`. `serial-ro/rw`: connect to `/vm/<v>/serial-mux.sock`. `tcp`: `ip netns exec <v> socat - TCP:<private_ipv4>:22`, IP from prep.json. Needs `socat` (prep_host, C4). |
| `<v>-serial-mux.service` | Owns the CH serial socket; appends serial.log (1 MiB cap); 64 KiB replay ring; at most one writer, takeover demotes the old writer. |
| CH args (gated) | prep.json `serial_mode: "mux"` → `--serial socket=/vm/<v>/serial.sock`. Absent → today's `file=` output byte for byte (P6). |

### 12.6 Security and operations

| Control | Mechanism | Status |
|---|---|---|
| Permissions | New action types `Vm:console` (interactive serial) and `Vm:connect` (T1). Read-only console uses `Vm:view`, as upstream's serial log does. Adding them to `Vm:all` gives them to `Member` automatically (pattern `migrate/20260309_audit_log_permissions.rb`). | [PLANNED C2]; **OPEN** whether Member gets them |
| Audit | `SUPPORTED_ACTIONS += console connect` (`helpers/general.rb:104`), plus a `vm_console_session` row (account, PAT, mode, client IP, start/end, byte counts, end reason). Keystrokes are not recorded. | [PLANNED C2] |
| Host key pinning | `vm_host_console.host_key`, `verify_host_key: :always`. Today no SSH path pins host keys (V6). | [PLANNED C1] |
| CSWSH / CSRF | CSRF-protected ticket POST, Origin == `Config.base_url`, single-use 30 s token | [PLANNED C2] |
| Revocation | Re-check every 60 s: VM exists, permission held, rodauth session key still present. Idle 15 min, absolute 4 h. | [PLANNED C2] |
| Limits | Per VM 1 rw + 5 ro; per account 10; per puma process 64 (configurable) | [PLANNED C2] |
| Blast radius | Per-host console key: one leaked key reaches one host's VMs, console and port 22 only | [PLANNED C1] |
| Guest login on console | Optional console password at VM create, stored only as a SHA-512 crypt hash in user-data; `ssh_pwauth` stays false | [PLANNED C3]; UNVERIFIED |

**Behind the Cloudflare tunnel** (live CP is reached via cloudflared → :3000):

| Item | Requirement |
|---|---|
| Websocket proxying | Passed by default [EXT]. No ingress change. |
| `Config.base_url` | Must equal the public URL or the Origin check fails. Default `http://localhost:9292` (`config.rb:86`). Live value UNVERIFIED; preflight should warn. |
| Client IP | Set `ip_from_header` to `CF-Connecting-IP` [EXT], or audit records 127.0.0.1. |
| Keepalive | Websocket ping every 25 s (Cloudflare idles out around 100 s [EXT]). Client reconnects with a new ticket; the mux replays 64 KiB. |
| Air-gapped sites | Vendor xterm.js into `assets/` rather than adding CDN entries to the CSP (`clover.rb:180-189`). |
| Testing | `RACK_ENV=development` + Unreloader with full hijack is UNVERIFIED. Test on a separate dev CP, **never the live env**. |

### 12.7 Console and access phases

| Phase | Content | Customer effect | Depends on |
|---|---|---|---|
| C0 | Upstream read-only Serial Log via the P0 rebase (or a hand-port without GCP) | 64 KiB snapshot tab, API, CLI | P0 |
| C1 | `ubiconsole`, relay and helper (`serial-tail` only), `Prog::SetupConsoleAccess`, `vm_host_console`, host key pin | none (plumbing) | nothing; safe beside P2 `host_guard` |
| C2 | Puma hijack bridge, tickets, permissions, audit, session table, xterm.js tab with live read-only stream, admin kill; flag `console_enabled` | Live boot log in the browser for all existing VMs | C1 |
| C3 | Serial mux + CH `--serial socket=` for new VMs; interactive console with single-writer lease; console password | Interactive console for new VMs (existing VMs after stop/start, or ro) | C2; gate G-CON1 |
| C4 | `tcp` relay, `Vm:connect`, `connect/ws` on the API host, `ubi vm ssh --tunnel`, per-VM toggle | SSH to VMs with no public IP on any platform | C1 |
| C5 | `ubi vm console` CLI; optional separate console gateway. (Extending host-key pinning to Sshable is dropped: upstream TOFU-pins Sshable after the P0 rebase, ROADMAP D-11.) | — | C2 |

The console is no longer part of the compute phases (COMPUTE.md points here and to ROADMAP §4). C1, C2 and C4 come before C3 because they need no CH change.

**Gates** (on a disposable canary host, never the live AWS env):

| Gate | Test | If it fails |
|---|---|---|
| G-CON1 | CH 46.0 and 35.1: `--serial socket=` works with the mux; guest output is not blocked with no client; mux reconnects after guest reboot | `--serial pty` (UNVERIFIED), or keep C2 read-only |
| G-CON2 | Puma 7 full hijack under development + Unreloader, and with `WEB_CONCURRENCY` > 1 | separate bridge process (C5) |
| G-CON3 | Through the Cloudflare tunnel: 2 h session, edge reconnect, 25 s pings | tune ping and backoff |
| G-CON4 | Ubuntu noble image: ttyS0 getty present, console-password login works, `ssh_pwauth` still rejects passwords | view-only console for that image |

---

## 13. Limits and known gaps

**[TODAY]:**
- The UI shows the on-host 10.98.1.x instead of the EIP.
- All BYOH hosts are in hetzner-fsn1 / eu-central-h1 (`prog/vm/host_nexus.rb:6`).
- The allocator INNER JOINs free IPv4 (`scheduling/allocator.rb:135`), so a host without a v4 pool hosts nothing.
- A management IP inside a declared block is allocatable, and the block containing it is dropped at prerouting (`prog/setup_nftables.rb:7`).
- Network and broadcast addresses are allocatable.
- A random ULA is shown as IPv6.
- No host input firewall; the live AWS SG is kept closed to VM ingress until `host_guard` exists.
- RFC1918 SNAT exemption.
- Load-balancer membership changes drop the DNS SNAT rules (§4.7).
- Private networking with ULA is likely broken.
- No browser console, no serial log, no way for customers to reach a VM without a public IP.
- No SSH host key is pinned anywhere (V6).

**After the plan (by design):**
- No PAT product mode.
- On `ula` hosts, VMs have no IPv6.
- `internal` VMs get no public DNS or IPv4 billing; LB certificates are a product choice.
- Public IPs are pre-provisioned per host; they cannot move between hosts without recreating the VM.
- A VM without a pool IPv4 has no IPv4 egress until P6 egress-only NAT lands (`vm_setup.rb:386`). It is still reachable through the access tunnel (C4).
- Abuse attribution for shared egress (P6) relies on a conntrack log.
- The access tunnel bypasses the customer firewall by design (§12.4).
- Office clients at a `nat` site cannot hairpin to E without split DNS (§4.6).
- Without an external prober, E-side drift is not continuously detected (§8.3).

**UNVERIFIED:**
- VM reachability of IMDS today.
- AWS /80 and GCP /96 prefixes with rhizome.
- Proxmox proxy-ARP and ipfilter defaults.
- m8i per-ENI IP limits.
- The clover path with the new guest-IPv6-off parameter.
- EIP hairpin from inside the VPC.
- The exact mesh MTU.
- Turning AWS src/dst check back on for `fabric` on the live host.
- BYOH locations offering Postgres (`Location.postgres_locations`).
- GCP and Azure behaviour as a whole.
- `--serial socket=` on CH 35.1/46.0; puma hijack under Unreloader.

---

## 14. Implementation phases (networking)

Every phase ships independently. All Ruby changes keep 100% spec coverage. Every rhizome divergence is gated on a BYOH-only parameter whose absence reproduces upstream behaviour (P6).

### 14.1 Phase 0: rebase onto origin/main

| Item | Detail |
|---|---|
| Provider dispatch | Port `lib/hosting/generic_apis.rb` to `Hosting::ProviderApis.for`, which resolves `Hosting::<Prefix>Apis` from `provider_name.split("-").first` (`origin/main:lib/hosting/provider_apis.rb`). |
| `GenericApis#pull_ips` | Emit records with `host_only?` (management /32) and `host_connectivity?`, following `origin/main:lib/hosting/hetzner_apis.rb:100-105`. |
| Brought in from upstream | `create_addresses`, `populate_ipv4_addresses` out of `after_create`, allocator `left_join :available_ipv4` / `ip4_enabled`, `SetupNftables` host-address exclusion, `CheckIpReachability`, `SetupNdpProxy`, `RunCommand` serial log (console C0). |
| Gate | `CheckIpReachability` for generic hosts until the P3 changes (§8.2) land. |
| Backports | Drop 971a3d608 if identical to upstream 7191118e6. |
| Result | Management IP never allocatable; no self-lockout via the blocked set; IPv4-less hosts usable. |

### 14.2 Phase 1: identity, locations, pools (control plane only)

| Area | Files |
|---|---|
| Migration | `migrate/<8-digit date>_byoh_network_contract.rb`, sorting after upstream's newest (CLAUDE.md §8). §5.2 columns. |
| Models | `model/address.rb` (delivery/exposure, §3.4 `usable` rules, reserved rows, `external_ip`), `model/assigned_vm_address.rb`, `model/location.rb` (`byoh_network`, `byoh?`), `model/vm.rb` (`public_ip4`, `public_ip4_scope`, `cp_reach_ip4`, `public_ip6`; `from_ips` matches `external_ip`) |
| Registration | `lib/byoh_registration.rb` (v2 schema, §10 validations, location required, ULA from `ula48`, `ipv6_mode`), `bin/register-byoh-host` (new flags; `--routed-network` stays as alias), new `bin/byoh-location`, `bin/byoh-pool` |
| Location | `prog/vm/host_nexus.rb:6` default removed for generic; reuse the `generic` provider row; resolve `visible`/`project_id` and Postgres availability (§5.3) |
| Allocation | `scheduling/allocator.rb` (exclude `reserved`, filter by `ip4_exposure`, copy `external_ip`, `sshable.host = cp_reach_ip4`), `prog/vm/nexus.rb` (`ip4_exposure`), `prog/vm/metal/nexus.rb` (`wait_sshable` via `cp_reach_ip4` or host-side probe; billing via `public_ip4`) |
| Billing | `config/billing_rates.yml`: rows for **every** resource type and family per BYOH location (§5.5) |
| Customer surfaces | `serializers/vm.rb`, `views/vm/overview.erb`, `views/vm/index.erb`, `views/kubernetes-cluster/nodes.erb`, Postgres resource model and prog, `prog/vnet/load_balancer_nexus.rb`, MinIO, VictoriaMetrics, Kubernetes progs, `clover_admin.rb` |
| Unchanged in P1 | `model/metal/vm.rb:98` (role A). `update_load_balancer_node.rb` keeps role A but changes in P2. |
| Config | Preflight warning for `control_plane_outbound_cidrs` (§6.6); `base_url` warning |
| Terraform | `outputs.tf`: `pools.yaml` via `local_file` into `.generated/<ws>/` |
| Result | Live AWS UI and API show EIPs; each site has its own location. |

### 14.3 Phase 2: security and data-path correctness

| Area | Change |
|---|---|
| Host guard | `rhizome/host/bin/setup-host-guard` (new), `prog/setup_host_guard.rb` (new): `nft -f`, 90 s rollback timer, fresh-SSH confirm, then write `/etc/nftables.d/1-host-guard.conf` (§6.2). Budded after `prep` for BYOH hosts; re-run on `host_mgmt_allow` change. Periodic presence check pages and clears `accepts_slices`. |
| Pool not local | `rhizome/host/bin/check-pool-not-local` (new), invoked from `setup-nftables.rb`; `prog/setup_nftables.rb` passes the allocatable pool list. |
| Netns egress chain | `rhizome/host/lib/vm_setup.rb`, gated: §4.3 order (established, peers, overlay drop, allow, `ct state new` deny), SNAT-all-except-peers, hairpin DNAT for the location's `nat` map (§4.6), `dns_servers` |
| Shared NAT generator | Used by `vm_setup.rb` **and** `prog/vnet/update_load_balancer_node.rb` (§4.7). Fixes the DNS SNAT loss and keeps the peer set and egress chain intact. |
| Params | `model/metal/vm.rb` `params_json`: `nat4_peer_set`, `egress_deny4/6`, `egress_allow4/6`, `overlay4`, `hairpin4`, initial `ubicloud_peer4` (BYOH only) |
| Peer set updates | `prog/vnet/rekey_nic_tunnel.rb:91-95` also adds to the netns peer set. UNVERIFIED interaction with xfrm; mandatory two-host live test. |
| Address hygiene | `model/vm_host.rb` APIPA exclusions inside the collision loop (§6.4); `model/private_subnet.rb`, `prog/vnet/subnet_nexus.rb`: draw from `overlay_ipv4_cidrs`, validate new and existing subnets |
| Terraform | `metadata_options` on `aws_instance.data`; SG stays as drafted with `data_plane_open_ingress=false` until L6; src/dst check per §9.1; fix stale header and defaults (`main.tf:9-16`, `variables.tf:31-41`); fix `terraform.tfvars` `operator_ssh_cidr` |
| Specs | `rhizome/host/spec/vm_setup_spec.rb` (absent param → identical output), `spec/prog/setup_host_guard_spec.rb`, `spec/prog/setup_nftables_spec.rb`, `spec/prog/vnet/rekey_nic_tunnel_spec.rb`, `spec/prog/vnet/update_load_balancer_node_spec.rb`, `spec/model/vm_host_spec.rb`, `spec/model/private_subnet_spec.rb` |

### 14.4 Phase 3: verification

- Extend `prog/check_ip_reachability.rb` and `rhizome/host/bin/check-ip-reachability` per §8.2 (skip allocated IPs, scratch netns, per-exposure policy), plus C5, uplink/default-route and C0 checks, and the nonce probe (C2).
- Store results in `vm_host.network_check`. Hard failures block `accepting` for BYOH hosts only.
- Optional external prober for E checks (§8.3).
- `bin/byoh-pool verify --from-outside` and `trace`; read-only verifiers under `scripts/byoh/verify/`.
- `docs/byoh/VERIFY.md` (§8.5).

### 14.5 Phase 4: IPv6

- Netns `route <ula48> via vetho_ll` for `ula` hosts (`vm_setup.rb` `setup_veths_6`, gated).
- Guest IPv6 off in `ula` mode via a **new host-gated parameter**, not `ipv6_disabled` (§7.1). Verify clover addresses and firewall rules.
- Scheduler: co-locate a private subnet's VMs for `ula_underlay: none`.
- `ula_underlay: operator` preflight check.
- Spikes: AWS /80 and GCP /96. Relax validation only after a spike passes.

### 14.6 Phase 5: ULA underlay mesh

- `rhizome/host/bin/setup-underlay-mesh` (WireGuard, keys generated on the host), `prog/byoh/setup_underlay_mesh.rb`.
- Computed `guest_mtu` (§7.3) into `vm_setup.rb:545`, confirmed by preflight `tracepath`.
- Conntrack-size check.

### 14.7 Phase 6: sites without a public block, and operator tooling

- Egress-only VMs (no pool IPv4) on BYOH hosts (pulled forward into milestone M2 with P1, ROADMAP §3.3): netns SNAT to the vethi address; host `masquerade` of 169.254.0.0/16 out the uplink in the `host_guard` file; gated; UI text "No inbound IPv4 (outbound via shared NAT)"; conntrack log. Enables T2 (§12.3).
- `scripts/byoh/providers/wireguard-tunnel/{vps.sh,host.sh}`; per-pool uplink and policy routing in preflight.
- Proxmox `docs/byoh/deploy-scripts/*`: single vmbr1 uplink; emit `pools.yaml`; fix the /29 vs 3×/32 mismatch.
- Experimental `terraform/gcp-byoh`, `terraform/azure-byoh`.

### 14.8 Phase 7 (optional): AWS pool sync

- `bin/byoh-pool sync-aws`: operator tooling with operator-held credentials; idempotent via tags; EIP-quota and ENI-limit headroom checks.
- Writes the same pool rows through `byoh-pool add/remove/remap`. No control-plane reconciler.

### 14.9 Live AWS environment migration (ap-south-1)

Order: protect first, open last. Do not touch the live env outside these steps.

| Step | When | Action | Rollback |
|---|---|---|---|
| L0 | **done** | `data_plane_open_ingress` default `false` (`variables.tf:77-81`) and `false` in `company-mumbai.tfvars`; `operator_ssh_cidr` narrowed there; stale `*.tfplan` files deleted. Any apply now keeps the SG closed. | n/a |
| L1 | after P0 + P1 deploy | Run migrations; defaults leave rows `routed`/`public`. | none needed |
| L2 | P1 | `bin/byoh-location create --name byoh-aws-aps1 --display "AWS Mumbai (BYOH)" --underlay 10.98.0.0/16 --overlay 172.20.0.0/14 --cp-reach onhost --cp-source <ctrl private>/32 --mgmt-allow <ctrl private>/32,<operator>/32`. Check that no existing private subnet uses 172.20/14. Add billing rows for the location. | delete the empty location |
| L3 | P1 | Move the host: confirm the 3 VMs are test-only (`Vm.where(vm_host_id:)`), destroy them, `bin/byoh-host move-location --empty-only`, recreate. | reverse move while empty |
| L4 | P1 | `terraform apply` for the `pools.yaml` output (safe: the open-ingress flag is false; review the plan for any SG change), then `bin/byoh-pool annotate --host <ubid> --pool-file .generated/<ws>/pools.yaml`. UI shows 43.204.120.21. | clear `external_ip` |
| L5 | P2 | `install_rhizome` (CLAUDE.md §10a), bud `SetupHostGuard`; confirm a fresh CP SSH, `nft list table inet host_guard`, and the file in `/etc/nftables.d/`. | 90 s auto-rollback, or delete the table and file |
| L6 | P2, after L5 | Set `data_plane_open_ingress = true`, add `metadata_options`, apply. Optionally re-enable src/dst check (§9.1) in the same window, after testing on a disposable host. | `data_plane_open_ingress=false` |
| L7 | P2 | Recreate VMs so they get the new netns rules. | recreate on the old rhizome |
| L8 | P3 | `bin/byoh-pool verify` and `--from-outside` for all 8 EIPs; full VERIFY.md checklist. | n/a |
| L9 | P4, separate window | IPv6 spike on a **second disposable host** first; then VPC/subnet IPv6, ENI /80, drain, `byoh-pool ipv6 set`, recreate. | stay `ula` |
| L10 | after L4 | Delete `scripts/byoh/providers/aws-routed-network-setup.sh` and `scripts/byoh-ops/reconfigure-routed-networks.rb`. | git |

Console phases (§12.7) are tested on a separate dev control plane and a canary host before any live rollout.

### 14.10 Documentation (lands with P1, updated each phase)

| Kind | Files |
|---|---|
| New | `docs/byoh/VERIFY.md`, `docs/byoh/POOL_OPERATIONS.md`, `docs/byoh/CONSOLE_AND_ACCESS.md`, `docs/byoh/platforms/{aws,proxmox-pfsense,homelab,wireguard-tunnel,hetzner,ovh,leaseweb,colo-bgp,gcp,azure}.md` |
| Rewrite | `docs/providers/generic.md` (link here; drop single-IP, route-via-Proxmox-IP, in-VPC route-table method, ULA claims); `docs/byoh/SETUP.md` (EIP FAQ → `exposure: nat`); `docs/byoh/SETUP_PROXMOX.md`, `SETUP_PROXMOX_LOWTIER.md` (options → platform page; drop `--provider`; lab-access appendix); `docs/byoh/QUICKSTART.md` (10.99 → 10.98) |
| Update | CLAUDE.md §4 routing model and §10 fixed items; portability "Networking rules" (fix the `ssh -J` line, §12.1); memory note `project_byoh_routing_model` |

---

## 15. Open questions

| # | Question | Section |
|---|---|---|
| Q1 | CP ↔ site transport: operator-provided VPN (current decision) or a Ubicloud-managed CP↔site WireGuard later? | §4.5 |
| Q2 | Office/LAN clients reaching E at a `nat` site: split DNS, or accept the limit? | §4.6 |
| Q3 | Offer LB certificates for `internal` load balancers? | §5.5 |
| Q4 | BYOH location visibility, project scoping, and Postgres availability | §5.3 |
| Q5 | `control_plane_outbound_cidrs`: keep one global union, or make it per location? | §6.6 |
| Q6 | Should `Member` get `Vm:console`/`Vm:connect` through `Vm:all`, or require an explicit grant? | §12.6 |
| Q7 | Should the access tunnel bypass the customer firewall (toggleable exception to P4), or go through `forward_ingress`? | §12.4 |
| Q8 | Accept that the web process opens restricted host SSH sessions, unlike upstream's respirate-only stance? | §12.2 |
| Q9 | Vendor xterm.js (recommended for air-gapped sites) or load it from a CDN with SRI? | §12.6 |
| Q10 | Build the optional external prober to hard-check E (C1/C2/C6)? | §8.3 |
