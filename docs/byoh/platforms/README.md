# BYOH platform guides

One guide per kind of platform. Each says whether the platform can run a BYOH data plane (VmHost), how VM addresses reach the host, and what differs from the common flow below. The driver is the same everywhere; only the machine, the KVM path and the site network work change. The overview, the end-to-end path and the virtualization options are in [README.md](../README.md).

**Status.** Only AWS (ap-south-1) has been run end to end: m8i with nested virtualization, and without KVM the `container`, `emulated` and `pvm` tiers ([VERIFY.md](../VERIFY.md) §5, §7, §8). Every other row is UNVERIFIED: the code path exists and matches a shape that was validated elsewhere, but nobody has registered a host there. Provider facts in the guides are labelled "provider docs, UNVERIFIED here" or "community report, UNVERIFIED here".

Problems on any platform: [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

---

## 1. Choose a platform

`model` is the pool's `delivery` + `exposure` ([NETWORKING.md](../NETWORKING.md) §3, [SETUP.md](../SETUP.md) §3). Every platform also takes VMs without IPv4, which need no pool and leave through the host NAT.

| Platform | Model | KVM path | IPs for VMs | Status | Guide |
|---|---|---|---|---|---|
| AWS EC2, m8i/c8i/r8i | `fabric` + `nat`; `fabric` + `internal` | Nested virtualization (`cpu_options`, AWS provider ≥ 6) | ENI secondary private IPs, each with a 1:1 Elastic IP | **Tested** 2026-10-11 and 2026-10-13 | [aws.md](aws.md) |
| AWS EC2 `.metal` | as above | Native | as above | Tested earlier (m5d.metal, tag `aws-mumbai-working-v1`) | [aws.md](aws.md) |
| AWS EC2 m6i/m7i (xlarge or larger) without nested, with PVM | as above | None: PVM, KVM in software on a third-party host kernel the control plane installs (experimental) | as above | Tested end to end on m6i.2xlarge 2026-10-17 ([VERIFY.md](../VERIFY.md) §8); guest-kernel pin rollout not run | [aws.md](aws.md) §2.1a |
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
| Hetzner Cloud, Linode/Akamai, any VPS without `/dev/kvm` | as the provider allows | None | — | **Not possible** for standard VMs; fine as control plane or tunnel endpoint. Experimental opt-in tiers, never chosen silently: system containers (`container`, near native, shared kernel), PVM (`pvm`, real VMs at CPU 97% of the host on AWS, a third-party host kernel) or emulation (`emulated`: CPU about 29% of the host) | [other-clouds-vps.md](other-clouds-vps.md) §1.3; [NO_KVM.md](../NO_KVM.md) |

Not sure whether a machine has usable KVM? `ubicloud-admin host preflight` (PF3) tells you without changing anything, or run `bin/byoh-virt probe --main-ip <IP> --ssh-key <key>` from the control plane before registering (packaged: `sudo ubicloud-admin run byoh-virt probe ...`; the host needs `ruby`). It prints the machine's rung on the virtualization ladder, why, the fix for its platform and, for clouds, whether a nested-capable type of the same size costs about the same ([NO_KVM.md](../NO_KVM.md) §4 fixes, §7 costs). Exit 0 means standard VMs will run.

**Fastest first.** Every fast VM monitor (Cloud Hypervisor, Firecracker, crosvm, QEMU-KVM) needs `/dev/kvm`, so the order is always:
1. KVM is there (bare metal, or nested virtualization on): register as today.
2. KVM can be switched on (firmware setting, CPU type `host`, the cloud's nested option, a nested-capable instance type): do that; the probe prints how. On AWS, GCP and Azure this is almost always the answer, at about the same price.
3. Neither (most VPS plans, Hetzner Cloud, AWS types without nested): register with `--virt-tier auto --accept-fallback` into a location that offers a lower tier. `auto` picks system containers before emulation. Both are experimental, single-project and visible to customers as separate sizes ([NO_KVM.md](../NO_KVM.md) §1, §12). Where VM isolation is required, PVM (KVM in software, real Cloud Hypervisor VMs on a third-party host kernel the control plane installs): `--virt-tier pvm --install-pvm-kernel --accept-fallback`, experimental, x86_64 CPUs that Meltdown does not affect only ([NO_KVM.md](../NO_KVM.md) §6.7; on AWS: [aws.md](aws.md) §2.1a). The comparison table is [README.md](../README.md) §2; the commands are [QUICKSTART.md](../QUICKSTART.md) §5.

Rules of thumb:
- Public IPv4 per VM without NAT or a cloud SDN: rented bare metal or a colo with a routed block.
- No public addresses at all: a LAN site with an `internal` pool, or VMs without IPv4.
- Anything nested (cloud VMs, hypervisor guests) suits labs, staging and internal clouds. A provider live migration or maintenance event can take the host and its VMs down.
- An address tied to its own virtual MAC (OVH vMAC, Hetzner separate MAC, Scaleway flexible-IP MAC) never works: rhizome routes every VM behind the host's MAC.

---

## 2. The common flow (every platform)

Each guide follows these six steps and links the [SETUP.md](../SETUP.md) section for the details. Only steps 1 and 5 really differ by platform.

**Since M4** steps 3-5 are two commands on the control plane: `ubicloud-admin site add` (step 4) and `ubicloud-admin host add --ssh <user>@<host> --ssh-key <key> --pool-file pools.yaml` (steps 3 and 5: preflight, root key, registration, bring-up, `pool verify`). With `install.sh` (step 2) these are the same three commands on every platform; [recipes/README.md](../recipes/README.md) has them and short recipes for AWS, Proxmox, bare metal and homelabs. The table below is the low-level path, which still works.

| # | Step | What you do | Details |
|---|---|---|---|
| 1 | Provision and choose the virtualization option | Create the data-plane machine: Ubuntu 24.04, a dedicated machine, only its main IP on the NIC, and KVM with `pdpe1gb` if at all possible (bare metal, nested virtualization, CPU type `host`). Create a control-plane machine (no KVM needed). Run the read-only host checks; PF3 names the virtualization rung. Without KVM, pick `container`, `pvm` or `emulated` now: each needs its own site settings and `host add` flags in step 5. | Platform guide §3.1; [PLATFORMS.md](../PLATFORMS.md) §1, §6.3; [README.md](../README.md) §2; [NO_KVM.md](../NO_KVM.md) |
| 2 | Control plane | Clone, then either `scripts/byoh/install.sh` (packaged: systemd, TLS front, backups; [INSTALL.md](../INSTALL.md); run on AWS, [VERIFY.md](../VERIFY.md) §7) or `scripts/byoh/bootstrap-dev-ctrl-plane.sh` (development and labs: put mise and Ruby on PATH, keep `RACK_ENV=development`). Leave `bin/monitor` off unless your hosts' disks suit it. | [SETUP.md](../SETUP.md) §4 |
| 3 | Data plane | `scripts/byoh/bootstrap-data-plane.sh` on the host (KVM check, root key login, `ruby-bundler`, `netcat-openbsd`). Install the control plane's Ed25519 key for root and test `ssh -o BatchMode=yes root@<main IP> true`. | [SETUP.md](../SETUP.md) §5 |
| 4 | Location | `bin/byoh-location create` once per site (underlay, overlay, `--cp-reach`, `--cp-source`, `--mgmt-allow`, rates). Restart `puma` and `respirate` (packaged: `systemctl restart ubicloud.target`). Set `CONTROL_PLANE_OUTBOUND_CIDRS`. On a packaged control plane every `bin/...` tool runs as `sudo ubicloud-admin run <tool>` ([SETUP.md](../SETUP.md) §4.3). | [SETUP.md](../SETUP.md) §6 |
| 5 | Pools and registration | Do the site network work so pool addresses reach the host but are **not** configured on it (C5). Write `pools.yaml`, run `bin/register-byoh-host` (a lower tier: offer it in the location with `bin/byoh-location rates` and `set --virt-tiers`, then add `--virt-tier` and `--accept-fallback`, plus `--install-pvm-kernel` for `pvm`), wait for `allocation_state = accepting` (one host reboot), then `bin/byoh-pool verify`. | Platform guide; [SETUP.md](../SETUP.md) §7-8; [POOL_OPERATIONS.md](../POOL_OPERATIONS.md) |
| 6 | VMs and gate | Create an account, `bin/byoh-location grant` its project, add an SSH key, create VMs (`-e internal`, `-6` or internet IPv4). Run `scripts/byoh/verify/m2-gate.sh` with the platform's settings. | [SETUP.md](../SETUP.md) §9-10; [VERIFY.md](../VERIFY.md) §1.4, §2.5 |

---

## 3. Which branch

Every guide clones `-b byoh-driver`, which carries all the code the guides use: the M2 network contract, the packaged control plane, M4 (`site add`, `host add`, preflight), the virtualization ladder (`bin/byoh-virt`, `--virt-tier`, the `container`, `pvm` and `emulated` tiers) and the API host. There is no other branch to pick.

A control plane installed from an older `byoh-driver` (such as 17d383a9c, the code of the 2026-10-13 live AWS window) gets all of this by upgrading: the release switch on a packaged one ([OPERATIONS.md](../OPERATIONS.md) §7), [MIGRATE_FROM_DEV.md](../MIGRATE_FROM_DEV.md) for a development one, then `install_rhizome` on every host. What an upgrade does not change by itself:
- A development `.env.rb` is never rewritten, so one written by an older bootstrap may lack `BILLING_RATES_EXTRA_DIR` and `BASE_URL`: add them by hand (VERIFY.md §1.1, SETUP.md §4.2).
- The egress table on a host is written at prep. Run `byoh-host setup-egress-nat --host vh...` to get the current one, which also drops VM traffic to `168.63.129.16`, `fd00:ec2::254` and `fd20:ce::254`.
- VMs created on older code keep their setup. The check that refuses a pool IP configured on the host ("is a local address of this host") runs only for new VMs: check `ip -br -4 addr` on old hosts.

---

## 4. Guides

- [aws.md](aws.md): AWS EC2 with `terraform/aws-byoh`. Tested.
- [bare-metal-dedicated.md](bare-metal-dedicated.md): rented dedicated servers (Hetzner, OVH, Leaseweb, others), RAID, BMCs, the single-IP case.
- [own-hardware.md](own-hardware.md): homelab, office rack, colo, BGP, CGNAT; firmware, router recipes, power and UPS.
- [proxmox.md](proxmox.md): Proxmox VE guests, plus libvirt, ESXi, Hyper-V and XCP-ng.
- [gcp-azure.md](gcp-azure.md): Google Cloud and Microsoft Azure.
- [other-clouds-vps.md](other-clouds-vps.md): OCI, Scaleway, Vultr, OVHcloud Public Cloud, DigitalOcean, Linode, Hetzner Cloud, and VPS plans without KVM.

Each guide has the same sections: Fit, Requirements, Step by step, Problems and solutions, Status.

Short recipes that end in the three M4 commands: [recipes/](../recipes/README.md) (`aws`, `proxmox`, `bare-metal`, `homelab`).
