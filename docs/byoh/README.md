# BYOH: start here

BYOH ("bring your own host") lets this fork of Ubicloud run its VMs on any Ubuntu 24.04 machine the control plane can reach over SSH: rented bare metal, your own hardware, a hypervisor guest or a cloud VM.
A `generic` hosting provider replaces the Hetzner API, so nothing on the host side depends on one provider.
You install one control plane, add a site (a BYOH location) and its hosts, and customers create VMs in the web UI or with the `ubi` CLI.

Everything below is on branch `byoh-driver`. The shortest set of commands is [QUICKSTART.md](QUICKSTART.md). When something goes wrong: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 1. From nothing to a first VM

| # | Step | What you do | Details |
|---|---|---|---|
| 1 | Machines | A control plane (Ubuntu 24.04 x86_64, about 4 GiB, no KVM needed) and one data-plane host (Ubuntu 24.04, a dedicated machine with outbound internet and one uplink address), plus the addresses VMs will use | [platforms/README.md](platforms/README.md), [PLATFORMS.md](PLATFORMS.md) |
| 2 | Control plane | `sudo bash scripts/byoh/install.sh ...` from a clone: systemd units, PostgreSQL, a TLS front, the API host `api.<host>`, backups and `ubicloud-admin` | [INSTALL.md](INSTALL.md) |
| 3 | First account | `sudo ubicloud-admin account create --email ...`, which prints the password and the project ubid | [OPERATIONS.md](OPERATIONS.md) §5 |
| 4 | Site | `sudo ubicloud-admin site add <site> ...` once per site: the network profile, billing rates and which project may use it | [SETUP.md](SETUP.md) §6 |
| 5 | Host | Pick the virtualization option (§2), write `pools.yaml`, then `sudo ubicloud-admin host add --site <site> --ssh <user>@<host> ...`. It runs preflight, registers the host and waits until it accepts VMs | [SETUP.md](SETUP.md) §7-§8, [POOL_OPERATIONS.md](POOL_OPERATIONS.md), [NO_KVM.md](NO_KVM.md) |
| 6 | First VM | In the web UI, or with `bin/ubi` and `UBI_URL=https://api.<host>/cli` plus a personal access token | [QUICKSTART.md](QUICKSTART.md) §6, [INSTALL.md](INSTALL.md) §3.1 |

Day-2 work (units, backups, restore, release switch, settings) is in [OPERATIONS.md](OPERATIONS.md).

---

## 2. Which virtualization option

Use KVM whenever the machine can have it: it is the only option with hardware isolation, full features and no extra steps. The other three exist for machines without KVM; each is opt-in per site, single-project, and offered to customers only as its own VM sizes, never chosen silently. `host add` preflight (check PF3) tells you which one a machine can run and how to switch KVM on when that is possible.

| Option (`--virt-tier`) | Use it when | Measured speed, guest vs host | Isolation | Sizes, image | Status |
|---|---|---|---|---|---|
| `kvm` (default) | `/dev/kvm` works: bare metal, a cloud VM with nested virtualization (AWS m8i/c8i/r8i), a hypervisor guest with CPU type `host` | No own guest-vs-host benchmark. Nested m8i.2xlarge: three VMs running about a minute after create (VERIFY.md §7). Nested CPU-bound work is reported at 90% or more (NO_KVM.md §1, SOURCE) | Hardware VM | The standard sizes; `ubuntu-noble` by default | **Verified** on AWS (m5d.metal; m8i.2xlarge nested), VERIFY.md §5, §7 |
| `container` | No KVM, speed matters, and a shared host kernel is acceptable | AWS t3.xlarge: CPU 99.8%, memory 99.9% (VERIFY.md §7). Lab: SSH 3.6-5.4 s after create (NO_KVM.md §1) | System container (LXC): shared host kernel, not a VM | `container-2` to `container-16`; `ubuntu-noble-container` | **Verified** on AWS (run e2e1, VERIFY.md §7); experimental tier |
| `pvm` | No KVM, VM isolation is required, the CPU is x86_64 and not affected by Meltdown, Secure Boot is off, and you accept a third-party host kernel the control plane installs | AWS m6i.2xlarge: CPU 97%, memory about 100%, 4k random I/O on ubiblk 93%, syscalls 48%, fork+exec 32%; VM running 20 s after create (VERIFY.md §8) | VM with a software world switch: weaker than hardware virtualization | `pvm-2` to `pvm-16`; `ubuntu-noble` | **Experimental.** One end-to-end run passed on AWS (run pvm1, VERIFY.md §8); the guest-kernel pin rollout was not run |
| `emulated` | Nothing else is possible; demos, CI, compatibility | AWS t3.xlarge: CPU 29%, memory 2%, 2 min 16 s from create to running (VERIFY.md §7) | QEMU TCG: not a security boundary | `emulated-2`, `emulated-4`; `ubuntu-noble`, `ubuntu-jammy` | **Experimental.** One run on AWS (VERIFY.md §7) |

How to choose, fastest first:
1. KVM is there: register as is.
2. KVM can be switched on (firmware VT-x/AMD-V, CPU type `host`, the cloud's nested option, a nested-capable instance type of the same size): do that. On AWS, GCP and Azure this is almost always the answer at about the same price ([NO_KVM.md](NO_KVM.md) §4, §7).
3. Otherwise `--virt-tier auto --accept-fallback` takes the fallback the probe recommends (`container` before `emulated`), which the site must offer. Choose `pvm` explicitly (`--virt-tier pvm --install-pvm-kernel --accept-fallback`) when you need VM isolation.

A machine that is itself a container (OpenVZ, LXC or Docker "VPS") is refused on every tier. Commands for each option: [QUICKSTART.md](QUICKSTART.md) §5. Design, refusals and the per-platform fixes: [NO_KVM.md](NO_KVM.md).

---

## 3. What has been run, and what has not

Only AWS (ap-south-1) has been run end to end. On real AWS machines:
- `install.sh` in production mode with `--tls acme`, `ubicloud-admin account create`, the release switch, backup and restore, and a reboot of the control plane (VERIFY.md §7).
- `site add` and `host add` on an m8i.2xlarge with nested virtualization, to `accepting`, and the M2 gate steps G1-G5, G7-G9b and G12-G14 (VERIFY.md §6.2, §7). Earlier, the low-level `register-byoh-host` path on m5d.metal and m8i (VERIFY.md §5).
- A `container` host and VM, an `emulated` host and VM, the PVM go/no-go on m6i.large and the PVM tier end to end on m6i.2xlarge (VERIFY.md §7, §8).
- The API host: a certificate for `api.<host>`, and `bin/ubi vm list` against `https://api.<host>/cli` (VERIFY.md §8).

Not run anywhere (UNVERIFIED):
- Proxmox and every other hypervisor, rented bare metal other than AWS `.metal`, own hardware, homelabs, GCP, Azure and the other clouds. Their guides follow the code and shapes validated on AWS.
- The PVM guest-kernel pin rollout (no second guest build), and the `multitenant` options of the lower tiers, which are refused until their checks exist.
- The `bin/monitor` 24-hour soak on EBS, virtio and LVM hosts (G-M4-3 to G-M4-5), so leave the monitor off.
- A real Cloudflare tunnel (`--tls tunnel`), and gate steps G6, G10 and G11.

---

## 4. Every page in docs/byoh

Getting started:
- [README.md](README.md): this page.
- [QUICKSTART.md](QUICKSTART.md): the packaged flow with exact commands, from `install.sh` to a first VM.
- [SETUP.md](SETUP.md): the full runbook for any platform, both control-plane layouts and the low-level registration path.
- [INSTALL.md](INSTALL.md): `install.sh`, its flags, the TLS fronts and the API host.
- [recipes/README.md](recipes/README.md): the three commands, with short recipes for [AWS](recipes/aws.md), [Proxmox](recipes/proxmox.md), [bare metal](recipes/bare-metal.md) and a [homelab](recipes/homelab.md).

Platforms:
- [platforms/README.md](platforms/README.md): the platform chooser table, the common flow and the per-platform guides ([AWS](platforms/aws.md), [rented bare metal](platforms/bare-metal-dedicated.md), [own hardware](platforms/own-hardware.md), [Proxmox and other hypervisors](platforms/proxmox.md), [GCP and Azure](platforms/gcp-azure.md), [other clouds and VPS](platforms/other-clouds-vps.md)).
- [SETUP_PROXMOX.md](SETUP_PROXMOX.md): the full Proxmox runbook (UNVERIFIED).
- [PLATFORMS.md](PLATFORMS.md): platform compatibility, portability findings and host preflight PF1-PF21.

Operating:
- [OPERATIONS.md](OPERATIONS.md): a packaged control plane day to day: `ubicloud-admin`, settings, accounts, backups, restore and the release switch.
- [POOL_OPERATIONS.md](POOL_OPERATIONS.md): `pools.yaml` and changing a host's pools with `byoh-pool`.
- [MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md): moving a development control plane to the packaged layout.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): symptoms, causes and fixes by phase.
- [VERIFY.md](VERIFY.md): the gates, the live windows, rollback and the recorded results of the real AWS runs.

Design:
- [NO_KVM.md](NO_KVM.md): the virtualization ladder (kvm, container, pvm, emulated), detection, the PVM kernel pins and `--install-pvm-kernel`.
- [EMULATED_HOSTS.md](EMULATED_HOSTS.md): the detailed reference for the `emulated` tier.
- [NETWORKING.md](NETWORKING.md): the host network contract (`delivery` and `exposure`), the egress NAT and the per-platform network shapes.
- [COMPUTE.md](COMPUTE.md): how CPU, memory and disk are booked, and the planned compute tiers.
- [ROADMAP.md](ROADMAP.md): the build order M0-M12 and the open decisions.

The provider driver itself is described in [docs/providers/generic.md](../providers/generic.md).
