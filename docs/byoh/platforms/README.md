# BYOH platform guides

One guide per kind of platform. Each says whether the platform can run a BYOH data plane (VmHost), how VM addresses reach the host, and what differs from the common flow below. The driver is the same everywhere; only the machine, the KVM path and the site network work change.

**Status.** Only AWS (m8i with nested virtualization, ap-south-1) has been run end to end ([VERIFY.md](../VERIFY.md) §5). Every other row is UNVERIFIED: the code path exists and matches a shape that was validated elsewhere, but nobody has registered a host there. Provider facts in the guides are labelled "provider docs, UNVERIFIED here" or "community report, UNVERIFIED here".

Problems on any platform: [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

---

## 1. Choose a platform

`model` is the pool's `delivery` + `exposure` ([NETWORKING.md](../NETWORKING.md) §3, [SETUP.md](../SETUP.md) §3). Every platform also takes VMs without IPv4, which need no pool and leave through the host NAT.

| Platform | Model | KVM path | IPs for VMs | Status | Guide |
|---|---|---|---|---|---|
| AWS EC2, m8i/c8i/r8i | `fabric` + `nat`; `fabric` + `internal` | Nested virtualization (`cpu_options`, AWS provider ≥ 6) | ENI secondary private IPs, each with a 1:1 Elastic IP | **Tested** 2026-10-11 and 2026-10-13 | [aws.md](aws.md) |
| AWS EC2 `.metal` | as above | Native | as above | Tested earlier (m5d.metal, tag `aws-mumbai-working-v1`) | [aws.md](aws.md) |
| Rented dedicated server (Hetzner Robot, OVH / So you Start, Leaseweb) | `routed` + `public`; Hetzner vSwitch `onlink` + `public` | Native (VT-x/AMD-V in firmware) | A block or single IPs routed to the main IP; no virtual MACs | UNVERIFIED | [bare-metal-dedicated.md](bare-metal-dedicated.md) |
| Dedicated server with one IP (Kimsufi, no extra IPs) | none, or `routed` + `internal` | Native | None from the provider; `-6` or internal VMs only | UNVERIFIED | [bare-metal-dedicated.md](bare-metal-dedicated.md) §3.7 |
| Homelab or office LAN | `onlink` + `internal`; `routed` + `internal`; `onlink` + `nat` (router 1:1 NAT); `routed` + `public` (ISP block) | Native | LAN addresses outside DHCP, a routed RFC 1918 block, or public IPs on the firewall | UNVERIFIED | [own-hardware.md](own-hardware.md) |
| Colo (routed block, on-link block, BGP) | `routed` + `public`; `onlink` + `public` | Native | The colo's block | UNVERIFIED | [own-hardware.md](own-hardware.md) §3.5 C1-C3 |
| One dynamic IP or CGNAT | `routed` (via `wg0`) + `public` | Native | A block routed to a rented VPS, carried over WireGuard | PLANNED recipe, operator-owned, UNVERIFIED | [own-hardware.md](own-hardware.md) §3.5 T1 |
| Proxmox VE guest | `onlink` + `internal`; `onlink` + `nat` (pfSense 1:1); `routed` + `public` | Nested, CPU type `host` | LAN pool, or public IPs on the router | UNVERIFIED | [proxmox.md](proxmox.md), [SETUP_PROXMOX.md](../SETUP_PROXMOX.md) |
| libvirt/KVM, VMware ESXi, Hyper-V guest | as Proxmox | Nested (`host-passthrough`, "Expose hardware assisted virtualization", `ExposeVirtualizationExtensions`) | as Proxmox | UNVERIFIED | [proxmox.md](proxmox.md) "Other hypervisors" |
| XCP-ng / Xen guest | as Proxmox | Nested (`exp-nested-hvm`) | as Proxmox | UNVERIFIED, lab only | [proxmox.md](proxmox.md) "Other hypervisors" |
| Google Cloud | `routed` + `public` (protocol forwarding); `fabric` + `internal` (alias IP range) | Nested (`--enable-nested-virtualization`, N2/C3) | Regional external IPs behind forwarding rules; alias ranges | UNVERIFIED | [gcp-azure.md](gcp-azure.md) |
| Microsoft Azure | `fabric` + `nat` | Nested (a size that supports it, security type Standard) | Secondary ipconfigs, each with a Standard Public IP | UNVERIFIED | [gcp-azure.md](gcp-azure.md) |
| Oracle Cloud (OCI) | `fabric` + `nat` | Native (bare-metal shapes); nested on E5/Standard3 Flex VMs per a blog post | Secondary private IPs with reserved public IPs | UNVERIFIED | [other-clouds-vps.md](other-clouds-vps.md) |
| Scaleway Elastic Metal, Vultr Bare Metal | `routed` + `public` | Native | Flexible / reserved IPs | UNVERIFIED (Vultr delivery not researched) | [other-clouds-vps.md](other-clouds-vps.md) |
| OVHcloud Public Cloud | `routed` + `public` (assumed) | `vmx` exposed; a live migration can kill the host | Additional IPs | UNVERIFIED, lab only | [other-clouds-vps.md](other-clouds-vps.md) |
| DigitalOcean Droplet | `onlink` + `nat` for one VM (theory), or single IP | Nested on Intel, not officially supported | One reserved IP per Droplet | UNVERIFIED, lab only | [other-clouds-vps.md](other-clouds-vps.md) |
| Hetzner Cloud, Linode/Akamai, any VPS without `/dev/kvm` | — | None | — | **Not possible** as a data plane; fine as control plane or tunnel endpoint | [other-clouds-vps.md](other-clouds-vps.md) §1.3 |

Rules of thumb:
- Public IPv4 per VM without NAT or a cloud SDN: rented bare metal or a colo with a routed block.
- No public addresses at all: a LAN site with an `internal` pool, or VMs without IPv4.
- Anything nested (cloud VMs, hypervisor guests) suits labs, staging and internal clouds. A provider live migration or maintenance event can take the host and its VMs down.
- An address tied to its own virtual MAC (OVH vMAC, Hetzner separate MAC, Scaleway flexible-IP MAC) never works: rhizome routes every VM behind the host's MAC.

---

## 2. The common flow (every platform)

Each guide follows these six steps and links the [SETUP.md](../SETUP.md) section for the details. Only steps 1 and 5 really differ by platform.

| # | Step | What you do | Details |
|---|---|---|---|
| 1 | Provision | Create the data-plane machine: Ubuntu 24.04, KVM, `pdpe1gb`, a dedicated machine, only its main IP on the NIC. Create a control-plane machine (no KVM needed). Run the read-only host checks. | Platform guide §3.1; [PLATFORMS.md](../PLATFORMS.md) §1, §6.3 |
| 2 | Control plane | Clone, `scripts/byoh/bootstrap-ctrl-plane.sh`, put mise and Ruby on PATH. Keep `RACK_ENV=development`. Leave `bin/monitor` off unless your hosts' disks suit it. | [SETUP.md](../SETUP.md) §4 |
| 3 | Data plane | `scripts/byoh/bootstrap-data-plane.sh` on the host (KVM check, root key login, `ruby-bundler`, `netcat-openbsd`). Install the control plane's Ed25519 key for root and test `ssh -o BatchMode=yes root@<main IP> true`. | [SETUP.md](../SETUP.md) §5 |
| 4 | Location | `bin/byoh-location create` once per site (underlay, overlay, `--cp-reach`, `--cp-source`, `--mgmt-allow`, rates). Restart `puma` and `respirate`. Set `CONTROL_PLANE_OUTBOUND_CIDRS`. | [SETUP.md](../SETUP.md) §6 |
| 5 | Pools and registration | Do the site network work so pool addresses reach the host but are **not** configured on it (C5). Write `pools.yaml`, run `bin/register-byoh-host`, wait for `allocation_state = accepting` (one host reboot), then `bin/byoh-pool verify`. | Platform guide; [SETUP.md](../SETUP.md) §7-8; [POOL_OPERATIONS.md](../POOL_OPERATIONS.md) |
| 6 | VMs and gate | Create an account, `bin/byoh-location grant` its project, add an SSH key, create VMs (`-e internal`, `-6` or internet IPv4). Run `scripts/byoh/verify/m2-gate.sh` with the platform's settings. | [SETUP.md](../SETUP.md) §9-10; [VERIFY.md](../VERIFY.md) §1.4, §2.5 |

---

## 3. Which branch

The guides describe branch `m2-network`. It is **not pushed yet**: the published `byoh-fork/byoh-driver` is at 17d383a9c, the code of the live AWS window. Every guide clones `-b byoh-driver`, so until `m2-network` is merged and pushed you get 17d383a9c. It has every operator command the guides use (`bin/byoh-location`, `bin/byoh-pool`, `bin/byoh-host`, `register-byoh-host --location/--pool-file`, the gate), but not these later commits:

| Commit | What it adds | On 17d383a9c instead |
|---|---|---|
| a0259a997 | LearnMemory accepts kB/MB/GB/TB sizes and falls back to `MemTotal` | Any DIMM size that is not whole GB fails "unexpected dmidecode unit". Give guests a multiple of 1024 MiB |
| a092f1b8b | VM setup refuses a pool IP that is local on the host ("is a local address of this host") | No error: the host answers for the VM and customers get "Permission denied (publickey)". Check that `ip -br -4 addr` shows only the main IP |
| c73f96ddc | The uplink MAC pin skips NICs named by a VLAN, bond, bridge or VRF | PrepHost can break such a netplan. Keep VLANs and bonds off the data-plane host's uplink (tag on the hypervisor or switch) |
| 9d85a6e3c | VMs cannot reach `168.63.129.16`, `fd00:ec2::254` and `fd20:ce::254` | Only `169.254.0.0/16` is dropped |
| 105b6439b | `bootstrap-data-plane.sh` checks `/dev/kvm`, `vmx`/`svm` and `pdpe1gb` | Run those checks by hand (PLATFORMS PF3, PF4); PrepHost still aborts without KVM |
| 237202b07, 8a9b271c7 | The control-plane bootstrap writes `BILLING_RATES_EXTRA_DIR` and `BASE_URL`, and knows `UBI_START_MONITOR` and `UBI_BASE_URL` | Add both lines to `.env.rb` by hand (VERIFY.md §1.1, SETUP.md §4) |
| 71988157c, 3774f5837, 04f4f7ddc, a75747755 | Gate reaches VMs through their namespace; G9 without internet pools; `GATE_EXTERNAL_SSH_VIA`; clearer `verify` warning | The gate jumps to VMs over IPv6, which fails on ULA hosts |

The commits after 29fe8c799 (the first five rows) are covered by unit specs only and have not run on a host.

---

## 4. Guides

- [aws.md](aws.md): AWS EC2 with `terraform/aws-byoh`. Tested.
- [bare-metal-dedicated.md](bare-metal-dedicated.md): rented dedicated servers (Hetzner, OVH, Leaseweb, others), RAID, BMCs, the single-IP case.
- [own-hardware.md](own-hardware.md): homelab, office rack, colo, BGP, CGNAT; firmware, router recipes, power and UPS.
- [proxmox.md](proxmox.md): Proxmox VE guests, plus libvirt, ESXi, Hyper-V and XCP-ng.
- [gcp-azure.md](gcp-azure.md): Google Cloud and Microsoft Azure.
- [other-clouds-vps.md](other-clouds-vps.md): OCI, Scaleway, Vultr, OVHcloud Public Cloud, DigitalOcean, Linode, Hetzner Cloud, and VPS plans without KVM.

Each guide has the same sections: Fit, Requirements, Step by step, Problems and solutions, Status.
