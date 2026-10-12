# BYOH roadmap: from today's fork to a production IaaS on any infrastructure

Status: master plan, 2026-10-12. Branch `byoh-driver` @ e6f5e328e (plus uncommitted `terraform/aws-byoh/{main,variables}.tf`).

This page ties the other BYOH design pages into one ordered build plan. It does not repeat their detail. Where a rule or a file list lives in another page, this page links to it.

| Page | Owns |
|---|---|
| [NETWORKING.md](NETWORKING.md) | Host network contract, pools, exposure, `host_guard`, IPv6, verification, networking phases **NET-P0..P7**, live steps **L0..L10**, access tiers (§12) |
| [COMPUTE.md](COMPUTE.md) | Capacity accounting, tiers, overcommit, gates **G0..G6**, compute phases **CMP-P0..P5** |
| [PLATFORMS.md](PLATFORMS.md) | Per-platform support, ranked findings, fix groups **F1..F10**, host preflight **PF1..PF21** |
| this page | Goals, current state, milestones **M0..M12**, console and access (**C0..C5**), OpenStack map, easy deployment (**E0..E5**), rebase strategy, decisions |
| [QUICKSTART.md](QUICKSTART.md) | Today's manual AWS setup, step by step |

Readers: operators who run the platform and developers who build it.

## Tags

| Tag | Meaning |
|---|---|
| **[TODAY]** | True of the code on `byoh-driver` or of the live deployment now |
| **[UPSTREAM]** | On `origin/main` only. Arrives with the rebase (M1) |
| **[PLANNED Mn]** | Built in milestone *n* of this page (§3) |
| **[PLANNED NET-Pn / CMP-Pn / Fn / Cn / En]** | Built in that phase of the owning design. The milestone table says which Mn carries it |
| **UNVERIFIED** | Not proven in code or on a live host |
| **EXTERNAL** | General knowledge about a third-party product (AWS, Cloudflare, Cloud Hypervisor, Puma, cloud-init, OpenSSH). Not checked against this repo |
| **OPEN** | Needs a decision from the user. Collected in §8 |

`file:line` refers to the `byoh-driver` working tree. `origin/main:<path>` refers to upstream. Line numbers drift; re-read the file before relying on one.

---

## 1. Product goals

| # | Goal | What it means in practice |
|---|---|---|
| G-1 | **Production IaaS, high performance** | Correct capacity accounting, a protected host, observable usage, backups and upgrades. No "full after 3 VMs" surprises. |
| G-2 | **Platform-agnostic end to end** | AWS, Proxmox, bare metal and a homelab meet one host contract and run the same code. Platform-specific work is limited to recipes that deliver addresses and a machine. |
| G-3 | **Very easy to deploy** | One command for the control plane, one for a site, one for a host, one for an upgrade. Preflight stops bad hosts before registration. |
| G-4 | **OpenStack-level features, easy to understand** | Networks, firewalls, load balancers, volumes, images, snapshots, quotas, console, usage. One simple UX per concept (§5). No floating-IP or port objects. |
| G-5 | **Customer-chosen shapes, overcommit, usage-based management** | Free vCPU/RAM/disk on a Flexible tier, CPU/memory/storage overcommit with balloon when proven, per-VM usage graphs, memory and storage quotas and billing. |
| G-6 | **See and reach every VM without a public IP** | Browser serial console for every VM, and SSH to VMs with no public IP through the platform itself (works the same on every platform), with one networking model and no per-platform patchwork. |

---

## 2. Where we are today

### 2.1 Live environment (AWS ap-south-1) [TODAY]. Do not touch outside a planned window.

| Part | State |
|---|---|
| Control plane | t3.large. puma and respirate in tmux. `RACK_ENV=development`, DB `clover_test` (`scripts/byoh/bootstrap-ctrl-plane.sh:28-29`). cloudflared tunnel `https://ubicust.dinanshubiswas.org` → `:3000`. |
| Data plane | One m8i.2xlarge with nested virtualization (8 threads, 4 cores, 32 GiB). `accepting`. Registered into `hetzner-fsn1` like every BYOH host (`prog/vm/host_nexus.rb:6`). |
| Addresses | 8 pool IPs 10.98.1.128-135, each with an Elastic IP. Pool IPs are no longer on the host NIC [FIXED 003f2800d]. |
| VMs | 3 customer VMs running. |
| Terraform | `company-mumbai.tfvars` has `data_plane_open_ingress = false` and a narrowed `operator_ssh_cidr`. No `*.tfplan` files exist (checked 2026-10-12). `terraform.tfvars` (not the live workspace) still has `operator_ssh_cidr = "0.0.0.0/0"`. |

### 2.2 What works [TODAY]

| Area | Works | Caveat |
|---|---|---|
| Register a host | `bin/register-byoh-host` → `accepting` in about 4 min (CLAUDE.md §10a) | No preflight; `--location` is a label only; manual boot-image flag |
| VM lifecycle | Create, start, stop, restart, destroy; host reboot recovery | Fixed catalog sizes only (`lib/option.rb:92-110`) |
| Networking | EIP ingress, egress, DNS, apt for VMs with a pool IPv4 | UI/API show 10.98.1.x, not the EIP (`serializers/vm.rb:15`, `views/vm/overview.erb:17-21`) |
| Firewall, LB, private subnets | Code exists (upstream) | LB membership change drops DNS SNAT (`prog/vnet/update_load_balancer_node.rb:95-131,168-185`); private networking on ULA hosts likely broken (UNVERIFIED live) |
| Capacity | 2-3 standard-2 VMs per m8i | Accounting causes in [COMPUTE.md §1](COMPUTE.md) |
| Console | `serial.log` written on the host only (`rhizome/host/lib/vm_setup.rb:788`) | No UI, API or CLI |

### 2.3 Commits on `byoh-driver` so far

| Commit | What it fixed | Left open |
|---|---|---|
| 971a3d608 | Per-VM dnsmasq gets an IPv4 upstream plus netns SNAT (backport of upstream 7191118e6) | VMs without IPv4; LB node NAT rebuild drops it again |
| 003f2800d | Terraform nested-virt data plane; cloud-init no longer puts pool IPs on the host NIC | Non-terraform AWS script still broken (retired at L10) |
| b13872889 | `persistent_device_id` accepts LVM `dm-uuid-` links (upstream backport) | Control-plane health checks on LVM (F5) |
| e6f5e328e | IO limits fall back to the storage path on EBS/virtio/SCSI | Control-plane device identity and SMART/clocksource checks (F5) |

Full per-commit detail: [PLATFORMS.md §3](PLATFORMS.md).

### 2.4 Distance from upstream [TODAY]

`origin/main` is **2298 commits ahead**; `byoh-driver` has 19 commits upstream lacks (merge base 43a2241e2, upstream head fad16215c of 2026-10-09). A dry merge reports 7 conflicts (CLAUDE.md §8).

---

## 3. Unified build plan (milestones M0..M12)

### 3.1 Rules for every milestone

| Rule | Detail |
|---|---|
| Shippable alone | Each milestone leaves the platform working and gives operators or customers something new. |
| Gated, behaviour-identical rhizome changes | Every data-plane divergence is gated on a BYOH-only parameter whose absence reproduces today's output byte for byte (NETWORKING P6 as restated by the critic). |
| 100% coverage | Line and branch coverage per file (`spec/coverage_helper.rb`). Full `rake` per PR. Budget about +40% spec effort on flagged steps ([COMPUTE.md §12](COMPUTE.md)). |
| Canary first | Gates run on a **disposable** canary host and, for web changes, a **separate dev control plane**. Never on the live env. |
| Live env | Changes reach ap-south-1 only in the named live windows (L-steps in NETWORKING §14.9, "Live" rows below). |
| Migrations | 8-digit fork dates that sort after upstream's newest (CLAUDE.md §8). |

### 3.2 Order at a glance

| Group | Milestones | Why this order |
|---|---|---|
| A. Correctness that hurts the live env now | M0 capacity fixes, M1 rebase, M2 honest addresses + no-public-IP egress | The 2nd-4th VM fails with an opaque error; the UI shows the wrong IP; VMs without IPv4 have no internet. M2's model changes touch files upstream rewrote, so the rebase sits between M0 and M2. |
| B. Easy-deploy foundations | M3 packaged control plane, M4 one-command site and host + preflight | Systemd, production mode, real locations in the CLI, preflight. |
| C. Flexible tier | M5 | Core user ask (custom shapes, overcommit groundwork). |
| D. Console and access | M6 | User ask; needs no Cloud Hypervisor change for its first phases. |
| E. The rest | M7 host security + verification, M8 management overlay, M9 usage and monitoring, M10 private networking, M11 balloon/resize + interactive console, M12 images/backups/move + releases | Production hardening and OpenStack-gap features. |

**Dependency graph** (an arrow means "needs"):

```
M0 ──► M1 ──► M2 ──► M4 ──► M7 ──► M8
              │      ▲      │
              ├──► M3┘      ├──► M10
              ├──► M5 ──► M9 ──► M11
              ├──► M6 (C1,C2,C4) ──► M11 (C3)
              └──► M12 (images, MoveVm, releases; also needs M3)
```

M3 does not depend on the rebase and can start in parallel with M0 (E0 note in §6). M6 (C1/C2) only needs M1 for the C0 snapshot tab; C1/C2 themselves could start after M0.

### 3.3 Milestones

Each row block gives scope, the owning design sections, key files, gates and what changes for customers. File lists are the main ones; the owning section has the full list.

#### M0. Live capacity correctness (fork, before the rebase) [PLANNED M0]

| Item | Detail |
|---|---|
| Scope | CMP-P0 steps 1-4, 6-8 ([COMPUTE.md §12 Phase 0](COMPUTE.md)): `display_size` fallback; `NoSpaceLeft` (cherry-pick upstream 0a8bb6324); IO-CPU port (cherry-pick 808be1ce6 and the two `20260831_*` migrations) **plus** the generic override `io_cpu_count = 0`; right-size new burstable slices (all three grow-on-reuse changes); idempotent grub hugepage tokens; `LearnStorage` refuses with volumes; `NoCapacity` lists every dimension. F1, F2, the part of F3 that CMP-P0 owns, F3 remainder (`pdpe1gb`, GRUB line, ≥ 8 usable pages on dedicated hosts), F9 KVM check in `prep_host.rb`. Port 02e47743d (CP-5) now if the IPv4-less allocator bug blocks anyone; otherwise it arrives in M1. |
| Docs | [COMPUTE.md §1, §12](COMPUTE.md); [PLATFORMS.md §4 #2, #3, #6, #18, #19, #22, #23, #28; §5 F1-F3, F9](PLATFORMS.md) |
| Key files | `model/vm.rb:151-159`; `scheduling/allocator.rb:84-94,205-224,429-435,484,519`; `prog/vm/metal/nexus.rb:91-92,104-105`; `prog/vm/host_nexus.rb:154-160`; `model/vm_host.rb:173-178`; `prog/setup_hugepages.rb:14-19`; `prog/learn_storage.rb`; `rhizome/host/bin/prep_host.rb`; `migrate/20261012000000_byoh_io_cpu.rb` (new) |
| Gates | Full `rake` green. Canary m8i: 4 usable cores (`vm_host.used_cores`, `vm_host_cpu.io` rows); create/destroy ×20 with no counter drift; a 4th slice on a full host gives `NoSpaceLeft` and waits, not an error loop; a 2 GiB burstable books 2 GiB. |
| Live window | Deploy the control-plane change; existing VMs untouched. Check counters with the pry snippet in COMPUTE.md §1. |
| Customer can | Create the 4th VM on the live host; get a "no capacity" state instead of a stuck `creating`. |
| Open | CMP-P0 frees IO CPUs; compute critic hole 11 suggests keeping 1 thread out on hosts with < 16 threads. Size from G3 (M5). |

#### M1. Upstream rebase (NET-P0) and the serial-log snapshot (C0) [PLANNED M1]

| Item | Detail |
|---|---|
| Scope | Rebase `byoh-driver` onto `origin/main` (§7). Move `GenericApis` to `Hosting::ProviderApis.for` with `host_only?` / `host_connectivity?`. Take upstream `create_addresses`, the allocator IPv4 LEFT JOIN (8e295c4d2, 02e47743d), `SetupNftables` host-address exclusion, `SetupNdpProxy`, `NoSpaceLeft`, `score_offset`, `RESERVED_STORAGE_GIB`, hugepage MemAvailable clamp, and the `RunCommand` serial log (**C0**). Gate `CheckIpReachability` for generic hosts (skip allocated IPs, no retry-forever) because it puts pool IPs on `lo` and breaks contract C5. Drop 971a3d608 if identical to 7191118e6. Ruby to upstream's version via `mise.toml`. |
| Docs | [NETWORKING.md §14.1, §8.2](NETWORKING.md); CLAUDE.md §8; §7 of this page |
| Key files | `lib/hosting/generic_apis.rb`, `lib/hosting/apis.rb` (deleted upstream), `prog/vm/host_nexus.rb` (conflict trap: keep our kwargs, default, `install_os=false`), `config.rb`, `cache/schema.cache` (regenerate), fork migration renamed to an 8-digit date |
| Gates | Full `rake`. Fresh canary host: register → `accepting` with the generic skip policy; VM create/destroy; `ip -4 addr` on the host never shows a pool IP; serial-log tab returns the last 64 KiB. Rehearse the live DB migration on a dump of `clover_test`. |
| Live window | Stop respirate, back up the DB (`pg_dump` as postgres) and `.env.rb`, deploy, migrate, restart. Re-register is **not** needed; upstream TOFU host-key pinning starts on first connect (CLAUDE.md §8). |
| Customer can | See a "Serial Log" tab and `ubi vm … serial-log` (64 KiB snapshot, fetched by respirate). Hosts without a free IPv4 can place IPv6-only VMs. |

#### M2. Honest addresses, real locations, no-public-IP egress [PLANNED M2]

| Item | Detail |
|---|---|
| Scope | NET-P1 in full: `external_ip`, `Vm#public_ip4`/`cp_reach_ip4`, exposure `public`/`nat`/`internal`, `reserved` rows, pool validation, one real `Location` per site (`bin/byoh-location`, `bin/byoh-pool`), billing rows for **every** resource type per BYOH location, `pools.yaml` terraform output, base-URL and `control_plane_outbound_cidrs` warnings. Pulled forward from NET-P6/F8: **egress-only NAT for VMs without a pool IPv4** (gated), and dnsmasq IPv4 upstream for them. Pulled forward from F8.2: `wait_sshable` falls back to a **host-netns probe** when `cp_reach_ip4` is nil (PLATFORMS §8 item 2). |
| Docs | [NETWORKING.md §5, §10, §14.2, §14.7 first bullet](NETWORKING.md); [PLATFORMS.md §4 #7-#9, #17, #33](PLATFORMS.md) |
| Key files | `migrate/<date>_byoh_network_contract.rb`; `model/{address,assigned_vm_address,location,vm}.rb`; `lib/byoh_registration.rb`; `bin/register-byoh-host`; `bin/byoh-location`, `bin/byoh-pool` (new); `scheduling/allocator.rb`; `prog/vm/metal/nexus.rb:179-198`; `serializers/vm.rb`; `views/vm/{overview,index}.erb`; `config/billing_rates.yml`; `rhizome/host/lib/vm_setup.rb:386` (gated egress-only path); `terraform/aws-byoh/outputs.tf` |
| Gates | Specs per NETWORKING §14.2. Canary: an `internal` VM with no IPv4 pool reaches apt and DNS; a VM on a `nat` pool shows its EIP in UI, API and CLI; registration refuses a pool containing the uplink IP. |
| Interim decision | NETWORKING puts the egress masquerade of 169.254.0.0/16 in the `host_guard` file (P2). Until M7, ship it as its own gated `/etc/nftables.d/` file, then fold it into `host_guard`. OPEN (§8 D-8). |
| Live window | NET L1-L4: create location `byoh-aws-aps1`; move the host while empty (the 3 VMs are recreated; OPEN §8 D-3); `pools.yaml` annotate. |
| Customer can | See the real public IPv4 (EIP); choose "Public IP" or "No public IP (outbound only)"; pick a real region per site; get correct bills per location. |

#### M3. Packaged control plane and production mode (E0 + E1) [PLANNED M3]

| Item | Detail |
|---|---|
| Scope | `install.sh` (idempotent, no marker files); systemd units under user `ubicloud` (`ubicloud-web`, `ubicloud-respirate` = `bin/restarter bin/respirate`, `ubicloud-monitor` installed **disabled**, backup timer, `ubicloud.target`); DB `ubicloud` with peer/ident auth, non-superuser roles; TLS choice `acme`/`tunnel`/`provided`/`none`; `BIND` in `puma_config.rb`; `ubicloud-admin status/backup/restore/account create/logs`. Production mode: `Config.boot_image_source` replaces `Config.production?` in `prog/download_boot_image.rb:23,34`; SMTP or logger; `BASE_URL`; `bin/production_check`. Rename the old bootstrap to a dev-only script so `clover_test` can never be a production DB. |
| Docs | §6 of this page; new `docs/byoh/INSTALL.md`, `OPERATIONS.md` |
| Key files | `scripts/byoh/install.sh`, `packaging/systemd/*`, `packaging/{caddy,cloudflared}/*`, `bin/ubicloud-admin`, `lib/byoh/admin/*.rb`, `puma_config.rb:5`, `prog/download_boot_image.rb`, `config.rb` |
| Gates | E0/E1 exit tests (§6.7): fresh Ubuntu 24.04 → UI over HTTPS in one command; `kill -9` respirate → back in 10 s; reboot → all up; backup → wipe → restore → hosts still SSH-able; `RACK_ENV=production` VM boot on a canary with `ubuntu-noble` from the public URL. |
| Live window | Separate window after the gates (§6.8): dump `clover_test` → `ubicloud`, copy `.env.rb` secrets verbatim, stop tmux, start units, point cloudflared at `127.0.0.1:3000`. Rollback = restart tmux on the untouched old DB. |
| Customer can | Nothing new visible; the platform survives restarts and reboots, mail works, and HTTPS cookies are secure. |

#### M4. One-command site and host, with preflight (E2 + F4/F5/F6/F9/F10) [PLANNED M4]

| Item | Detail |
|---|---|
| Scope | `ubicloud-admin site add` (NET `byoh-location` logic, billing overlay in `/etc/ubicloud/billing_rates.d/`, visibility and Postgres choice) and `host add --ssh` (form A): preflight PF1-PF21 → register → stream HostNexus labels → `pool verify` (prints UNVERIFIED for pool checks until M7). Register CLI: `--location` resolution, `--uplink-ip`, `--pool-file`, default boot image `ubuntu-noble`, preflight by default. Remaining portability fixes: F4 CPU topology (online CPUs, non-uniform SMT), F5 control-plane device identity and health checks, F6 storage safety (`--storage-disk`, btrfs/ZFS error), F9 GPU `vfio-pci` filter and LearnMemory units, F10 Proxmox recipe rewrite (delete `deploy-scripts/02-05,99`), terraform `host_add_command` output. |
| Docs | [PLATFORMS.md §5, §6](PLATFORMS.md); §6.2-§6.3 of this page |
| Key files | `bin/register-byoh-host:60-157`; `lib/byoh_registration.rb`; `lib/billing_rate.rb:14`; `scripts/byoh/host/ubicloud-host` (`preflight`); `prog/learn_cpu.rb`; `prog/learn_pci.rb`; `model/storage_device.rb:24-33`; `model/vm_host.rb:286-296,351-361,383-394`; `model/location.rb:36-38`; `terraform/aws-byoh/*`; `docs/byoh/recipes/*` |
| Gates | E2 exit test: AWS canary and one Proxmox VM with the **same three commands**. Preflight catches `kvm64` (no `/dev/kvm`), a pool containing the uplink IP, and a hybrid CPU. F5: health checks pass on EBS, virtio and LVM for 24 h with `bin/monitor` run by hand. |
| Customer can | Nothing directly; operators add sites and hosts in minutes on any platform. |

#### M5. Flexible tier (CMP-P1) [PLANNED M5]

| Item | Detail |
|---|---|
| Scope | The ten mergeable steps of [COMPUTE.md §12](COMPUTE.md) from step 4: migrations (`flexible_tier`, `thin_storage`), `flexpool.slice` and `kind='vm'` filters, physical storage guard on **every** tier, rhizome CH flags (`shared=on`, `1:N:1:1` topology), per-backend limits, `setup-flex-host`, hugepage profiles, custom shapes and up to 4 data disks, `VmMemory` billing and invoice labels, `VmMemoryGib`/`VmStorageGib` quotas with the real vCPU count, stop-and-release, UI/API/CLI, minimal `HostUsageMonitor` (node_exporter `:9100`, not `done/`). Flag `Config.flexible_tier_enabled`. Memory ratio 1.0, no balloon. |
| Docs | [COMPUTE.md §2-§10, §12 Phase 1](COMPUTE.md) |
| Key files | `lib/option.rb`, `lib/validation.rb`, `prog/vm/nexus.rb`, `model/metal/vm.rb`, `scheduling/allocator.rb`, `prog/vm/metal/nexus.rb`, `prog/setup_hugepages.rb`, `prog/setup_flex_host.rb` (new), `prog/vm/host_usage_monitor.rb` (new), `rhizome/host/lib/{vm_setup,storage_volume,slice_setup}.rb`, `config/{billing_rates,default_quotas}.yml`, `helpers/vm.rb`, `views/vm/create.erb`, `openapi/openapi.yml`, `cli-commands/vm/post/create.rb`, `bin/set-host-ratios` |
| Gates | G0, G2, G3, G4 between steps 6 and 10. m8i allocator fixture: 5 / 10 / 14 VMs (2c/4g, 1c/2g, 1c/1g). Canary soak 7 days with no non-capacity critical page (COMPUTE.md §10). |
| Live window | COMPUTE.md §12 "Rollout on the live AWS host": deploy flag-off; cutover via one HostNexus reboot; option A (recreate the 3 VMs, profile `flexible`) or B (`mixed`). OPEN §8 D-3. |
| Customer can | Pick vCPU 1-32, RAM in 256 MiB steps, boot and data disks; see a live price; stop-and-release to pay storage only; see memory and storage quotas. |

#### M6. Console and access without a public IP (C1, C2, C4) [PLANNED M6]

| Item | Detail |
|---|---|
| Scope | §4 of this page. C1: host account `ubiconsole`, `vm-access-relay`/`vm-access-helper` (`serial-tail` only), `Prog::SetupConsoleAccess`, `vm_host_console` with pinned host key. C2: puma full-hijack websocket bridge, tickets, `Vm:console`, audit, `vm_console_session`, xterm.js tab with a **live read-only** stream for every existing VM, admin kill, flag `console_enabled`. C4: `tcp` relay mode, `Vm:connect`, `connect/ws` on the API host, `ubi vm ssh --tunnel`, per-VM toggle. |
| Docs | §4 of this page; [NETWORKING.md §12](NETWORKING.md); new `docs/byoh/CONSOLE_AND_ACCESS.md` |
| Key files | §4.8 |
| Gates | G-CON2 (puma 7 hijack under Unreloader and `WEB_CONCURRENCY > 1`) and G-CON3 (2 h through the Cloudflare tunnel) on a **separate dev control plane**. Relay/helper injection specs. |
| Customer can | Watch the live boot log of any VM in the browser; SSH to a VM that has no public IP with `ubi vm <loc/name> ssh --tunnel`, on every platform the same way. |

#### M7. Host security, data-path correctness and verification (NET-P2 + NET-P3) [PLANNED M7]

| Item | Detail |
|---|---|
| Scope | `host_guard` (90 s rollback, fresh-SSH confirm, `/etc/nftables.d/1-host-guard.conf`); NH-6 (`flush ruleset` wiping Docker/Tailscale rules) assigned here; `check-pool-not-local`; netns egress chain in the critic's order (`ct state new` deny); **shared NAT generator** used by `vm_setup.rb` and `update_load_balancer_node.rb` (fixes the LB DNS bug); `@ubicloud_peer4` SNAT exemption (VM → LAN/VPC/hairpin); APIPA exclusion; overlay range validation for new and existing subnets; IMDS deny. Fold M2's interim egress file into `host_guard`. NET-P3: extended `CheckIpReachability`, `vm_host.network_check`, `byoh-pool verify`, `VERIFY.md`. E2's `pool verify` becomes a hard check. |
| Docs | [NETWORKING.md §4.3, §4.6, §4.7, §6, §8, §14.3, §14.4](NETWORKING.md) |
| Key files | `rhizome/host/bin/setup-host-guard` (new), `prog/setup_host_guard.rb` (new), `rhizome/host/bin/setup-nftables.rb:42-50`, `rhizome/host/lib/vm_setup.rb`, `prog/vnet/update_load_balancer_node.rb`, `prog/vnet/rekey_nic_tunnel.rb:91-95`, `model/vm_host.rb`, `model/private_subnet.rb`, `prog/check_ip_reachability.rb` |
| Gates | Mandatory two-host live test (peer-set updates vs xfrm). Host-guard rollback test. LB add/remove keeps guest DNS. |
| Live window | NET L5-L8: `install_rhizome`, bud `SetupHostGuard`, then and only then `data_plane_open_ingress = true`; recreate VMs; verify all 8 EIPs. |
| Customer can | Put VMs behind load balancers without losing DNS; reach the site LAN/VPC from a VM; rely on a protected host. |

#### M8. Management overlay and NAT-friendly host join (E3) [PLANNED M8]

| Item | Detail |
|---|---|
| Scope | `ubimgmt` WireGuard hub on the control plane, hosts dial out; `sshable.host` = mgmt address; `cp_reach: mgmt`; `host invite` + one-line `join` (form B); `byoh_mgmt_peer`, `byoh_join_token`; `host_guard` rules close uplink port 22; relay-hub recipe for a control plane behind NAT. Resolves the CP↔site transport hole (NETWORKING C0/Q1) — OPEN §8 D-1. |
| Docs | §6.4 of this page |
| Key files | `migrate/<date>_byoh_mgmt.rb`, `routes/byoh_join.rb`, `prog/byoh/sync_mgmt_hub.rb`, `lib/byoh_registration.rb` (`uplink_ip` vs mgmt), `lib/hosting/generic_apis.rb` (skip keyed on `uplink_ip`), `rhizome/host/bin/setup-host-guard` |
| Gates | Homelab host behind a consumer router joins with one line; the control plane manages a PG VM there; host reboot completes HostNexus; handshake loss pages. Security review of `/byoh/join`. Two-host test of pool routing through AllowedIPs. |
| Customer can | Use hosts at sites the control plane cannot route to (home, CGNAT, another cloud) exactly like any other site. |

#### M9. Usage, observability and monitoring (CMP-P2 + E5 monitor) [PLANNED M9]

| Item | Detail |
|---|---|
| Scope | `usage-probe` textfile collector; full `HostUsageMonitor`; OOM detection → VM restart → HostOOM page; nightly `bin/check-capacity-drift`; enable `ubicloud-monitor` (needs F5 from M4); customer usage graphs via `query_range`; CH 53.0; alert routing (email/webhook). |
| Docs | [COMPUTE.md §7, §10, §12 Phase 2](COMPUTE.md); §6.7 E5 |
| Key files | `rhizome/host/bin/usage-probe`, `rhizome/host/bin/setup-node-exporter`, `prog/vm/host_usage_monitor.rb`, `model/vm_host.rb` (`perform_health_checks`), `views/vm/overview.erb`, `lib/victoria_metrics/client.rb:63` |
| Gates | Monitor runs 7 days on AWS and Proxmox with no false `unavailable`. |
| Customer can | See CPU, memory and disk usage graphs per VM; usage-based alerts. |

#### M10. Private networking that works on every host (NET-P4, NET-P5) [PLANNED M10]

| Item | Detail |
|---|---|
| Scope | Netns ULA route (same-host VM-to-VM); new host-gated guest-IPv6-off flag (not `ipv6_disabled`); co-location for `ula_underlay: none`; WireGuard underlay mesh with computed guest MTU (about 1320-1360); IPv6 GUA spikes (AWS /80, GCP /96). |
| Docs | [NETWORKING.md §7, §14.5, §14.6](NETWORKING.md) |
| Gates | Two-host private-subnet ping/iperf on AWS and Proxmox; `tracepath` MTU check. |
| Customer can | Run multi-VM apps over private networks across hosts. |

#### M11. Balloon, overcommit, resize, interactive console (CMP-P3 + C3 + C5) [PLANNED M11]

| Item | Detail |
|---|---|
| Scope | Balloon controller with free-page reporting, memory ratio 1.25 → 1.5, systemd-oomd on `flexpool.slice` (if G2), soft live RAM, cold CPU/RAM resize (`prog/vm/metal/resize.rb`), cold disk grow (after G6). Console C3: `serial-mux` + CH `--serial socket=` (gated per new VM), rw console with single-writer lease, optional console password; C5: `ubi vm console`. |
| Gates | G1/G1b, G6, G-CON1 (CH 35.1 and 46.0/53.0 socket behaviour), G-CON4 (noble ttyS0 getty). |
| Customer can | Resize a VM (brief stop); type into the console of a new VM; pay less for idle memory. |

#### M12. Images, snapshots, backups, host drain, releases (CMP-P4 + E4 + BUILD items) [PLANNED M12]

| Item | Detail |
|---|---|
| Scope | ubiblk v0.4.2; port upstream machine images (`machine-image` API, `assemble_from_url`, `assemble_from_vm`) with an operator-supplied S3 store (e.g. MinIO); offline scheduled backups; port `MoveVm` with explicit shape fields; rebalance page; G5 → storage ratio 3.0. E4: release workflow, `ubicloud-admin upgrade` / `--rollback`, rolling rhizome. BUILD: spread group (`host_exclusion_filter`), zone label (`data_center`), full `#cloud-config` with a higher limit, `dns_servers` location field, rescue boot. |
| Gates | v0.1 → v0.2 upgrade on a canary with 3 VMs; image import → VM boot; backup → restore on another host; MoveVm of a stopped VM. |
| Customer can | Import images, save a stopped VM as an image, schedule backups, spread VMs; operators evacuate hosts and upgrade with one command. |

### 3.4 Where every input item lands

| Input item | Milestone |
|---|---|
| CMP-P0 | M0 (fork-only steps), M1 (upstream ports arrive) |
| CMP-P1 / P2 / P3 / P4 / P5 | M5 / M9 / M11 / M12 / after M12 |
| NET-P0 / P1 / P2 / P3 / P4-P5 / P6 / P7 | M1 / M2 / M7 / M7 / M10 / M2 (egress-only) + M12 recipes / optional after M7 |
| F1, F2, F3 | M0 (+ upstream parts in M1) |
| F4, F5, F6, F9, F10 | M4 (F9 KVM check in M0) |
| F7 | M1 (host-address exclusion), M2 (validation), M7 (`host_guard`, NH-6) |
| F8 | M2 (display, egress, host-netns probe), M6 (access tunnel replaces Tier 1), M10 (VM-to-VM) |
| C0 / C1, C2, C4 / C3, C5 | M1 / M6 / M11 |
| E0, E1 / E2 / E3 / E4 / E5 | M3 / M4 / M8 / M12 / M9 |
| OpenStack BUILD items | M12 |

---

## 4. Console and access

Detail for M6 and M11. NETWORKING §12 carries a condensed copy; this section is the full design.

Tags in this section: **[UPSTREAM]**, **[PLANNED Cn]** (console phase *n*, §4.9), UNVERIFIED, EXTERNAL.

### 4.1 Facts this design depends on

| # | Fact | Evidence |
|---|---|---|
| V1 | CH runs with `--console off --serial file=/vm/<inhost>/serial.log`; QEMU uses `-serial file:`. CH re-creates the file on each in-guest reboot (truncates). | `rhizome/host/lib/vm_setup.rb:788`, `:860-861`; upstream 9b236a8e2 |
| V2 | The CH unit runs as user `<inhost>` inside the VM netns. `serial.log` is deleted with the VM home on purge. | `vm_setup.rb:702-704`, `:798`, `:175-179` |
| V3 | `delete-old-serial-logs` cleans only `/var/log/ubicloud/serials` (GitHub runners). | `rhizome/host/bin/delete-old-serial-logs:6-25`, `prep_host.rb:103-106` |
| V4 | Upstream read-only serial log: `run_command` table, `RunCommand` (64 KiB tail, encrypted, ANSI strip), `Prog::Vm::RunCommandNexus` with an allow-list. Runs in **respirate**, never in web (750026634). | `origin/main:model/run_command.rb`, `prog/vm/run_command_nexus.rb`; `model/metal/vm.rb:246-248` |
| V5 | Upstream surfaces: `GET …/vm/<ref>/serial-log` (`Vm:view`, 202 while fetching, 60 s cooldown), "Serial Log" tab, `ubi vm … serial-log`, admin action; opt-in `append_serial_console` for runners. | `origin/main:routes/project/location/vm.rb`, `views/vm/serial_log.erb` |
| V6 | `byoh-driver` has none of V4/V5; cherry-pick is not clean (633e22298 touches `model/gcp/vm.rb`). | `routes/project/location/vm.rb:53` |
| V7 | No websocket support in the app. `websocket-driver 0.8.0` is locked only via `ferrum`. puma 7.1.0, rack 3.2.6, roda 3.102.0, net-ssh 7.3.2; puma `threads 15, 15`. | `Gemfile.lock`; `puma_config.rb` |
| V8 | CSP `connect_src :self`; `script_src` is a jsdelivr allow-list with SRI. | `clover.rb:180-189`, `views/layouts/app.erb:10-18` |
| V9 | Cookie session `_Clover.session`, secure outside dev/test; rodauth `active_sessions`. | `clover.rb:145,161-165,356` |
| V10 | Authz via `authorize("Vm:view"/…)`; new action types via the `20260309_audit_log_permissions.rb` pattern; `Member` holds every non-Project `*:all` tag. | `routes/project/location/vm.rb:26,36,56`; `migrate/20241215_authorization_refactor.rb` |
| V11 | `audit_log` accepts only `SUPPORTED_ACTIONS`. | `helpers/general.rb:104,153` |
| V12 | Host SSH uses `verify_host_key: :accept_new` with empty known_hosts: no host key is pinned on this branch. `sshable.host` is UNIQUE. | `model/sshable.rb:193-245,293` |
| V13 | `rhizome` has `NOPASSWD:ALL`; bootstrap writes `/etc/ssh/sshd_config.d/10-clover.conf`. | `prog/bootstrap_rhizome.rb:76-82` |
| V14 | **The host root namespace has no route to a VM's private IPv4.** It routes only the pool IP P via `vetho`. IPv6 return path only covers `2000::/3` (inferred, UNVERIFIED live). | `vm_setup.rb:330-352`, `:268-290` |
| V15 | Guest user-data sets no password and `ssh_pwauth: false`, so a ttyS0 getty has no usable login by default. | `vm_setup.rb:582-591` |
| V16 | CH 35.1 (old VMs) and 46.0 (default). `--serial socket=` behaviour on both is UNVERIFIED. | `rhizome/host/lib/cloud_hypervisor.rb:113-124` |

**Correction to portability F8 Tier 0** (also wrong in [PLATFORMS.md §5 F8](PLATFORMS.md)): `ssh -J root@<host> ubi@<private_ipv4>` cannot work (V14). Valid forms: `ssh -J <host> ubi@<P>` for VMs with a pool IPv4, or operator-only `ProxyCommand ssh root@<host> ip netns exec <inhost> nc %h 22`. The old "host cloudflared reaches every private IP" (F8 Tier 1) has the same problem.

### 4.2 Architecture

```
Browser (xterm.js)                    Control plane (puma)                         Data-plane host
POST …/vm/<v>/console/session ─CSRF─► authorize, audit_log,
   ◄── {ws_url, token 30 s, 1-use}    vm_console_session(issued)
GET wss://<base>/…/console/ws?t= ───► Origin == base_url, cookie == token account
   (through the Cloudflare tunnel)    rack.hijack (full) → puma thread freed
                                      Console::Bridge thread:
                                        websocket-driver ⇄ Net::SSH ──SSH──► user ubiconsole (key only)
                                        ping 25 s, idle/abs timeout,           ForceCommand vm-access-relay
                                        re-auth every 60 s                     sudo -n vm-access-helper
                                                                                 serial-tail → tail -F serial.log
                                                                                 serial ro|rw → serial-mux.sock
                                                                                 tcp 22 → ip netns exec → private_ip:22
                                                                               <v>-serial-mux ⇄ CH --serial socket=
```

| Decision | Choice | Rejected alternative |
|---|---|---|
| Websocket termination | In puma with full `rack.hijack`, one Ruby thread per session [PLANNED C2] | Separate `bin/console-gateway` (second cloudflared ingress rule; breaks easy deploy). Deferred to C5 if G-CON2 fails. |
| Websocket library | Promote `websocket-driver` to a direct gem (already locked at 0.8.0) | Hand-written RFC 6455 framing |
| How web reaches the host | New restricted account `ubiconsole` with a per-host Ed25519 key, ForceCommand, no shell | Reusing the rhizome Sshable (full sudo). Honest limit: the web process can already decrypt every column, so this narrows the path, not key custody. OPEN §8 D-6. |
| Fan-out and write arbitration | On the host, in `<v>-serial-mux` | Coordination between puma workers |
| Console type | Serial text only | VNC/graphical: CH has no display device (EXTERNAL) |
| No-public-IP SSH | Same bridge, relay mode `tcp22` | Per-host cloudflared (old F8 Tier 1) |

### 4.3 Host-side pieces [PLANNED C1/C3]

| Piece | Behaviour |
|---|---|
| user `ubiconsole` | `adduser --disabled-password`; `/etc/ssh/sshd_config.d/20-ubiconsole.conf`: `Match User ubiconsole` → `ForceCommand /home/rhizome/host/bin/vm-access-relay`, `PermitTTY no`, `AllowTcpForwarding no`, `X11Forwarding no`, `AllowAgentForwarding no`, `PermitTunnel no`; key line carries `restrict`. |
| `vm-access-relay` | Parses `SSH_ORIGINAL_COMMAND` = `serial-ro`, `serial-rw` or `serial-tail <inhost>` or `tcp <inhost> 22`; `inhost` must match the `ubid_to_name` format (regex UNVERIFIED) and `/vm/<inhost>` must exist; else exit 2. Then `exec sudo -n vm-access-helper …`. |
| `/etc/sudoers.d/97-ubiconsole` | `NOPASSWD` for the helper binary only. |
| `vm-access-helper` (root) | Re-validates. `serial-tail`: `tail -c 65536 -F serial.log`. `serial-ro/rw`: connect to `serial-mux.sock` with a hello. `tcp`: `ip netns exec <v> socat - TCP:<private_ipv4>:22`; IP from `/vm/<v>/prep.json`, never from the caller; port allow-list `{22}`. |
| `<v>-serial-mux.service` | Ruby `IO.select` loop, `User=<v>`, bound to `<v>.service`. Connects to the CH serial socket, reconnects after guest reboot, appends `serial.log` (1 MiB cap, rotate), keeps a 64 KiB replay ring, socket 0660 group ubiconsole. At most one rw client; takeover demotes the old writer; ro input dropped. |
| CH args (gated) | prep.json `serial_mode: "mux"` → `--console off --serial socket=/vm/<v>/serial.sock`. Absent → today's `file=` byte for byte. QEMU path deferred. |

### 4.4 Websocket protocol and session lifecycle [PLANNED C2]

| Step | Detail |
|---|---|
| 1. Ticket | `POST …/vm/<v>/console/session`, `mode=ro` or `mode=rw`, CSRF. `Vm:view` for ro, `Vm:console` for rw. Insert `vm_console_session(issued)`; `audit_log(vm, "console")`; token = HMAC-SHA256(key from `clover_session_secret`, `session|vm|account|mode|exp`), TTL 30 s. |
| 2. Upgrade | `GET …/console/ws?t=…`: Origin == `Config.base_url`; cookie account == token account; row `issued`, unexpired → `open` with `client_ip`; then `rack.hijack`. |
| 3. Bridge | `Net::SSH.start(host, "ubiconsole", pinned host key)`; `exec("serial-rw <inhost>")`; binary frames ⇄ channel; text frames carry JSON control (`takeover`, `ping`, `status`). |
| 4. Keepalive | Websocket ping every 25 s (Cloudflare idles at about 100 s, EXTERNAL). |
| 5. Re-auth | Every 60 s: VM exists and not destroying; permission still held; rodauth session key still present. Failure → close 4001. |
| 6. Timeouts | Idle 15 min, absolute 4 h (`Config.console_idle_timeout`, `console_max_duration`). |
| 7. Close | `ended_at`, `end_reason`, `bytes_in/out`. Keystrokes are not recorded. |
| Limits | Per VM 1 rw + 5 ro; per account 10; per puma process `console_max_sessions` (64). Over limit → 429 at ticket time. |
| Resize | Serial has no window size; UI hints `stty rows R cols C`. |

### 4.5 Security

| Control | Mechanism | Status |
|---|---|---|
| Permissions | New `Vm:console` (rw) and `Vm:connect` (tunnel); ro uses `Vm:view`. Added to `Vm:all` by migration, which gives them to `Member` (OPEN §8 D-5). | PLANNED C2/C4 |
| Audit | `SUPPORTED_ACTIONS += console connect` (`helpers/general.rb:104`) plus `vm_console_session` rows. | PLANNED C2 |
| No shell on host | ForceCommand + `restrict` + one sudoers entry + double validation. | PLANNED C1 |
| Host key pinning | `vm_host_console.host_key`, `verify_host_key: :always`. | PLANNED C1 (gap on this branch; upstream TOFU arrives in M1, §8 D-11) |
| CSWSH / CSRF | CSRF POST ticket, Origin check, single-use 30 s token. | PLANNED C2 |
| Revocation | 60 s re-auth; "log out other sessions" (`clover.rb:679-723`) ends consoles within 60 s. | PLANNED C2 |
| Guest login | Optional console password at create, stored only as a SHA-512 crypt hash in user-data with `lock_passwd: false`; `ssh_pwauth` stays false. | PLANNED C3; UNVERIFIED |
| Blast radius | Per-host console key: one leaked key reaches one host's VMs, console and port 22 only. | PLANNED C1 |
| Customer firewall | The `tcp` relay connects from inside the netns (OUTPUT, not FORWARD), so `forward_ingress` (`prog/vnet/metal/update_firewall_rules.rb:102`) does not apply. Treated as a separately permissioned path (like GCP IAP, EXTERNAL) with per-VM toggle `vm.access_tunnel_enabled`. Stated exception to NETWORKING P4. | PLANNED C4; OPEN §8 D-4 |
| `host_guard` | Console SSH arrives at host :22 from the control plane, already allowed. No new host or VM port. | consistent with M7 |

### 4.6 Read-only fallback

| Layer | What | Status |
|---|---|---|
| R0 | Upstream "Serial Log" snapshot (64 KiB, respirate) | [UPSTREAM], M1 |
| R1 | Live read-only stream: relay `serial-tail` through the bridge. Works on every running VM, because CH already writes `serial.log`. | PLANNED C2 (M6) |
| R2 | Mux mode: ro sessions attach to the mux; mux keeps appending `serial.log`, so R0/R1 keep working; supersedes upstream `append_serial_console` (keep the flag, map both values to mux). | PLANNED C3 (M11) |
| UI order | mux (rw/ro) → tail stream (ro) → snapshot; status line names which. | PLANNED C2/C3 |

### 4.7 Behind the Cloudflare tunnel

| Item | Requirement |
|---|---|
| Websocket proxying | Passed by default (EXTERNAL); path stays on :3000, no ingress change. |
| `Config.base_url` | Must equal the public URL or the Origin check fails. Default is `http://localhost:9292` (`config.rb:86`); live value UNVERIFIED. M3 installer sets it. |
| Client IP | `ip_from_header` = `CF-Connecting-IP` (EXTERNAL header name). |
| Edge restarts | Client reconnects with jittered backoff and a new ticket; mux replay hides the gap. |
| Cloudflare Access | Browser sends `CF_Authorization` (EXTERNAL); CLI tunnel then needs `cloudflared access` service tokens. |
| `RACK_ENV=development` | Unreloader wraps the app; full hijack UNVERIFIED there (G-CON2 on a separate dev CP). Moot after M3 moves live to production. |
| Assets | Vendor xterm.js 5.x into `assets/` (air-gapped sites) or jsdelivr with SRI (OPEN §8 D-7). |

### 4.8 VM access without a public IP

| Tier | Path | Who | Needs | Works on | Status |
|---|---|---|---|---|---|
| T0 operator | `ssh -J <host> ubi@<P>` (VM has a pool IPv4) or `ProxyCommand="ssh root@<host> ip netns exec <inhost> nc %h 22"` | operator (root on host) | host SSH | all | [TODAY] |
| **T1 access tunnel** (recommended) | `ubi vm <loc/name> ssh --tunnel`: SDK opens `wss …/vm/<v>/connect/ws` with a PAT; CLI is the `ProxyCommand`; CP → `ubiconsole` → `tcp <inhost> 22` → `ip netns exec` → private IP. Guest key still required end to end. | customer with `Vm:connect` | only the CP URL. No VM egress, no public IP, no per-host cloudflared. | every platform identically, because it rides CP → host management | PLANNED C4 (M6) |
| T2 guest cloudflared / tailscale | Customer installs in the guest; opt-in cloud-init snippet | customer | VM IPv4 egress (M2 egress-only NAT) | all, after M2 | PLANNED |
| ~~Host cloudflared per host~~ | old F8 Tier 1 | — | per-host config + netns access | — | Replaced by T1; operator lab helper at most (NETWORKING §3.3) |

Notes:
- T1 rides CP → host SSH, which M8's overlay (or the operator VPN) already provides. It adds no reachability requirement.
- T1 does not fix `wait_sshable`; M2's host-netns probe does. Share the helper's validation code.
- Browser "Web SSH" is rejected (it would hold the guest private key in the browser or server). Use the console with a console password, or the CLI tunnel.
- T1 runs on the `api.` host with a PAT bearer token (`clover.rb:325`) plus a single-use ticket; same bridge class.

### 4.9 Data model

| Table / column | Purpose |
|---|---|
| `vm_host_console` (`id` = vm_host id, encrypted `private_key`, `public_key`, `host_key`, `ready_at`) | Per-host console key and pinned host key (separate from Sshable because `sshable.host` is UNIQUE) |
| `vm_console_session` (`id`, `vm_id` FK cascade, `account_id`, `pat_id`, `kind` serial/tcp, `mode` ro/rw, `status`, `client_ip`, timestamps, `end_reason`, `bytes_in/out`) | Ticket, active-session list, audit |
| `action_type` `Vm:console`, `Vm:connect` + `applied_action_tag` into `Vm:all` | Permissions |
| `vm.access_tunnel_enabled bool default true` | Per-VM T1 toggle |
| prep.json `serial_mode: "mux"` | Rhizome gate |

### 4.10 Files to touch

| File | Change | Phase |
|---|---|---|
| `rhizome/host/bin/vm-access-relay`, `vm-access-helper`, `setup-console-access` (new) | Relay, helper, host setup (`sshd -t`, `visudo -c`) | C1 (tcp: C4) |
| `rhizome/host/bin/prep_host.rb` | Install `socat` | C4 |
| `prog/setup_console_access.rb` (new) | Keygen, run setup over rhizome Sshable, store `vm_host_console`, verify; budded from `host_nexus` `prep`; existing hosts via `bin/pry` | C1 |
| `model/vm_host_console.rb`, `model/vm_console_session.rb` (new), `model/vm_host.rb` | Models | C1/C2 |
| `migrate/<date>_vm_console.rb` | Tables, action types, tags | C1/C2 |
| `lib/console/bridge.rb`, `lib/console/ticket.rb` (new) | Bridge loop (injectable IO and SSH factory), HMAC tickets | C2 |
| `routes/project/location/vm.rb` | `console/session`, `console/ws`, `connect/session`, `connect/ws`; add `console` to `show_object` (`:53`) | C2/C4 |
| `helpers/general.rb:104`, `helpers/vm.rb` | Audit actions; ticket and limit helpers | C2 |
| `views/vm/console.erb` (new), `views/vm/show.erb`, `assets/js/console.js` + vendored xterm.js | UI | C2 |
| `Gemfile`, `config.rb` | `websocket-driver`; console settings and `console_enabled` flag | C2 |
| `clover_admin.rb` | List/kill sessions; key status per host | C2 |
| `rhizome/host/lib/vm_setup.rb:788`, `:582-591`, `rhizome/host/bin/setup-vm`, `rhizome/host/bin/serial-mux` (new), `model/metal/vm.rb` | Gated `--serial socket=`, mux unit, optional hashed console password | C3 |
| `prog/vm/nexus.rb`, `views/vm/create.erb`, `openapi/openapi.yml` | `console_password` (hashed server-side) | C3 |
| `sdk/ruby/lib/ubicloud/model/vm.rb`, `cli-commands/vm/post/ssh.rb`, `cli-commands/vm/post/console.rb` (new) | `--tunnel`; `ubi vm console` | C4/C5 |

### 4.11 Phases and gates

| Phase | Content | Customer effect | Depends on | Milestone |
|---|---|---|---|---|
| C0 | Upstream read-only Serial Log via rebase | 64 KiB snapshot tab, API, CLI | NET-P0 | M1 |
| C1 | `ubiconsole`, relay/helper (`serial-tail`), `SetupConsoleAccess`, host key pin | none (plumbing) | — | M6 |
| C2 | Hijack bridge, tickets, permissions, audit, xterm.js live read-only stream, admin kill | live boot log for **all existing VMs** | C1 | M6 |
| C4 | `tcp` relay, `Vm:connect`, `connect/ws`, `ubi vm ssh --tunnel`, toggle | SSH to VMs without a public IP, any platform | C1 | M6 |
| C3 | Serial mux, gated CH socket, rw console, console password | interactive console for new VMs (existing VMs after stop/start) | C2, G-CON1 | M11 |
| C5 | `ubi vm console`; optional split gateway; Sshable pinning (may be moot after M1, §8 D-11) | — | C2 | M11 |

| Gate | Test (disposable canary, never live) | If it fails |
|---|---|---|
| G-CON1 | CH `--serial socket=` on 35.1 and 46.0: accepts the mux, guest not blocked with no client, reconnect after reboot | `--serial pty` with mux on the pty (UNVERIFIED), or ro only |
| G-CON2 | Puma 7 full hijack under development + Unreloader, and with `WEB_CONCURRENCY > 1` | Split process (C5) |
| G-CON3 | 2 h session through Cloudflare, edge reconnect, 25 s pings | Tune intervals |
| G-CON4 | Noble ttyS0 getty, console-password login, `ssh_pwauth` still rejects passwords | View-only for that image |

Specs (100% rule): `spec/lib/console/{bridge,ticket}_spec.rb`; web and API route specs (CSRF, Origin, 403/429, PAT, toggle); `spec/prog/setup_console_access_spec.rb`; model specs; `spec/model/metal/vm_spec.rb` (`serial_mode` behind the flag); `rhizome/host/spec/{vm_access_relay,vm_access_helper,serial_mux,vm_setup}_spec.rb` (injection rejection, byte-identical unit without the param); authorization spec for `Vm:all`.

---

## 5. OpenStack feature map

How to read it: **Rec** = ALREADY (ship as is), PLANNED (a design covers it), BUILD (no design yet), SKIP. **Pri** = 1 needed for production IaaS, 2 within months, 3 nice to have, – skip. **M** = milestone in §3.

### 5.1 Nova (compute)

| OpenStack | Ubicloud today | Plan | Rec | Simple UX | Pri | M |
|---|---|---|---|---|---|---|
| Flavors | [TODAY] `standard-{2..60}`, `burstable-1/2` (`lib/option.rb:92-110`) | Dedicated tier keeps the catalog | ALREADY | "Dedicated" size picker | 1 | — |
| Custom vCPU/RAM/disk | No; `display_size` raises on non-catalog shapes (`model/vm.rb:151-159`); quota treats custom shapes as 2 vCPU (`helpers/vm.rb:91`) | CMP-P0 step 1 + CMP-P1 Flexible tier; reuse `hugepages:` flag (`prog/vm/nexus.rb:13,172`); invoice label fix (`lib/billing_rate.rb:47-48`) | PLANNED | vCPU stepper, RAM slider, disk table, live price | **1** | M0, M5 |
| Resize | No (not upstream either) | CMP-P3 cold CPU/RAM; disk grow gated on G6 (metadata extension not written yet); no shrink | PLANNED | "Change size" (brief stop) | 2 | M11 |
| Cold migrate / drain | No; [UPSTREAM] `prog/vm/metal/move_vm.rb` (admin, stopped VM, single volume) | CMP-P4 port with explicit shape fields; ubiblk v0.4.2 (`config.rb:164` is v0.2.2) | PLANNED | Operator "Evacuate host" | 2 | M12 |
| Live migrate | No | CH does not migrate local block storage (EXTERNAL) | SKIP | Maintenance window | – | — |
| Shelve | No; stopped VM keeps reservations (`prog/vm/metal/nexus.rb:525-531`) | CMP-P1 stop-and-release; restart only on the same host (needs headroom or a "capacity unavailable" state) | PLANNED | "Stop and release (cheaper)" | 2 | M5 |
| Rescue | No | none | BUILD (later) | "Boot rescue image" | 3 | M12 |
| Console | `serial.log` on host only (`vm_setup.rb:788`) | C0 snapshot, C2 live ro, C3 interactive; no VNC | PLANNED, pulled earlier | "Console" tab | **1** | M1, M6, M11 |
| Server groups / anti-affinity | Internal `host_exclusion_filter` (`scheduling/allocator.rb:4`); BYOH `data_center` is NULL | none | BUILD (small) | "Spread group" at create | 2 | M12 |
| Metadata / user-data | `init_script` ≤ 2000 chars appended to `runcmd` (`model/vm_init_script.rb:10`, `vm_setup.rb:577-580`); NoCloud disk; no metadata HTTP service | NET-P2 denies VM egress to 169.254.169.254 | BUILD (small) | "Startup script / cloud-config" | 2 | M12 |
| Key pairs | [TODAY] project SSH keys | — | ALREADY | "SSH keys" | 1 | — |
| Start/stop/restart | [TODAY] `routes/project/location/vm.rb:55` | — | ALREADY | Buttons | 1 | — |

### 5.2 Neutron (networking)

| OpenStack | Ubicloud today | Plan | Rec | Simple UX | Pri | M |
|---|---|---|---|---|---|---|
| Networks/subnets | [TODAY] `private_subnet` + IPsec; ULA hosts likely break VM-to-VM (NH-2, UNVERIFIED live) | NET-P4 netns ULA route; NET-P5 mesh (MTU ~1320-1360); NET-P2 overlay validation for new and existing subnets; new host-gated guest-IPv6 flag | PLANNED | "Private network" | **1** | M7, M10 |
| Routers | Partial: subnet connect; implicit per-VM SNAT | NET-P2 `@ubicloud_peer4` SNAT exemption; egress-only NAT for no-IPv4 VMs | PLANNED | "Connect networks", "Outbound internet: on" | **1** | M2, M7 |
| Floating IPs | `enable_ip4` at create; IP fixed to the host pool; UI shows 10.98.x not the EIP (`serializers/vm.rb:15`) | NET-P1 `public_ip4`/`external_ip`/exposure; IPs cannot move between hosts by design | PLANNED | "Public IP" toggle; no floating-IP object | **1** | M2 |
| Security groups | [TODAY] `firewall` + rules, ingress only (`update_firewall_rules.rb:102`) | NET-P2 `host_guard`, operator egress deny (`ct state new` only). Customer egress rules not planned | ALREADY (+P2) | "Firewall" | 1 | M7 |
| Ports | Internal `nic`, one per VM | — | SKIP | — | – | — |
| LBaaS | [TODAY] round-robin/hash, TCP/HTTP/HTTPS checks, DNS-01 TLS. **Bug**: LB node rebuild drops DNS SNAT (`update_load_balancer_node.rb:95-131,168-185`) | NET-P2 shared NAT generator; LB DNS uses `public_ip4`; certs for internal LBs are a product choice; LB hostnames need `dns_zone` on BYOH (UNVERIFIED) | ALREADY + fix | "Load balancer" | 2 | M2, M7 |
| VPN site-to-site | None for customers | Operator-only WireGuard recipe | SKIP (doc: run WireGuard in a VM) | — | – | — |
| DNS | Internal `dns_zone`; guest resolvers hard-coded to `8.8.8.8` and public IPv6 resolvers (`vm_setup.rb:509-523`) | `dns_servers` in the location profile | SKIP DNSaaS; BUILD the field | — | 3 | M7/M12 |
| VM access without public IP | T0 only | T1 access tunnel (§4.8), egress NAT, host-netns readiness probe, "Internal IPv4" exposure | PLANNED, pulled forward | "No public IP (access via tunnel)" + copyable command | **1** | M2, M6 |

### 5.3 Cinder (block storage)

| OpenStack | Ubicloud today | Plan | Rec | Simple UX | Pri | M |
|---|---|---|---|---|---|---|
| Volumes | Boot disk only via API (`helpers/vm.rb:62-65`); assemble already accepts several (`prog/vm/nexus.rb:37-40`); encrypted; billed per volume | CMP-P1 up to 4 data disks; thin accounting 1.5 → 3.0; physical guard on all tiers | PLANNED | "Disks" table | **1** | M5 |
| Attach/detach | No (local storage) | — | SKIP (needs network storage) | — | – | — |
| Snapshots | No | CMP-P4 via machine images | PLANNED | "Snapshot" = capture image | 2 | M12 |
| Backups | No for VMs | CMP-P4 offline scheduled backups (ubiblk 0.4.x + S3 store) | PLANNED | "Daily backup" | 2 | M12 |
| Volume types / QoS | Catalog `io_limits` (`lib/option.rb:106`) | CMP-P1 per-tier IO limits sized in G3 | PLANNED | Implicit in tier | 3 | M5 |

### 5.4 Glance (images)

| OpenStack | Ubicloud today | Plan | Rec | Simple UX | Pri | M |
|---|---|---|---|---|---|---|
| Images | Fixed `BootImages` (`lib/option.rb:65-67`); only images passed at registration; production pulls from R2 only | F10 default `ubuntu-noble`; `boot_image_source` | ALREADY + fix | OS picker | 1 | M3, M4 |
| Custom images | No; [UPSTREAM] `machine-image` API, `assemble_from_url` | CMP-P4 port; operator S3 store (e.g. MinIO) | PLANNED | "Import from URL" | 2 | M12 |
| Snapshot-as-image | No routes; [UPSTREAM] `assemble_from_vm` (stopped, one encrypted volume) | CMP-P4 | PLANNED | "Save as image" | 2 | M12 |

### 5.5 Keystone (identity)

| OpenStack | Ubicloud today | Rec | Simple UX | Pri | M |
|---|---|---|---|---|---|
| Projects | [TODAY] projects, invitations | ALREADY | Projects | 1 | — |
| Users / roles | [TODAY] access-control entries with tags; OIDC SSO | ALREADY | Members + roles | 1 | — |
| App credentials | [TODAY] personal access tokens, restrictable | ALREADY | API tokens | 1 | — |
| Quotas | [TODAY] `VmVCpu` only (`config/default_quotas.yml`) | PLANNED CMP-P1 `VmMemoryGib`, `VmStorageGib` (`model/project.rb:152-176`) | Usage vs limit bars | 2 | M5 |

### 5.6 Other services

| OpenStack | Ubicloud today | Plan | Rec | Simple UX | Pri | M |
|---|---|---|---|---|---|---|
| Heat | [TODAY] OpenAPI, `ubi` CLI; Terraform provider is a separate upstream repo (UNVERIFIED against this fork) | CMP-P1 adds fields to OpenAPI and CLI | ALREADY / SKIP Heat | "Use Terraform" page | 2 | M5 |
| Horizon | [TODAY] web console, `clover_admin.rb`; more admin views upstream | NET-P1 identity fixes; CMP-P1 create form | ALREADY | — | 1 | M1, M2, M5 |
| Ceilometer | Billing [TODAY]; no per-VM metrics (`vm_stats.rb:17`); `bin/monitor` not running | CMP-P2 usage probe, graphs via `query_range` (`routes/project/location/postgres.rb:634`); monitor reads `:9100`, not `done/` | PLANNED | "Usage" graphs | **1** | M9 |
| Placement / overcommit | None: hugepages 1:1, whole-core slices, full disk reservation | CMP-P0 fixes; CMP-P1 ratios; dedicated is disjoint, not exclusive; `flexpool.slice` naming; `kind='vm'` filters | PLANNED | Operator ratios; customers see tiers | **1** | M0, M5, M11 |
| Host aggregates / AZs | Every BYOH host in hetzner-fsn1 (`prog/vm/host_nexus.rb:6`) | NET-P1 one Location per site; CMP-P1 `capacity_profile`; billing rows per location (`lib/billing_rate.rb:14`); Postgres on BYOH UNVERIFIED | PLANNED; BUILD zone label | Region picker; zone label | 2 | M2, M12 |
| Ironic | Operator onboarding via `register-byoh-host` + Redfish | Host preflight PF1-PF21 | SKIP (customer) / PLANNED (preflight) | `host add` | 1 | M4 |

### 5.7 Notes

- **Rebase first** for anything upstream already has: serial log, machine images, MoveVm, `NoSpaceLeft`, `CheckIpReachability`, `SetupNdpProxy`. Upstream `CheckIpReachability` temporarily adds pool IPs to the host (`origin/main:rhizome/host/lib/ip_reachability_check.rb` `with_address`), which breaks contract C5 and retries forever; gate it for generic hosts (M1).
- **No floating-IP object.** Pools are pre-provisioned per host; the honest UX is a create-time "Public IP" toggle or "Internal IP". `byoh-pool remap` changes E, not which VM owns it.
- **Firewall is ingress only.** Customer egress rules are a later BUILD if asked.
- **SKIP list:** live migrate, VNC, ports/multi-NIC, DNSaaS, VPNaaS, Heat, customer Ironic, movable floating IPs.

---

## 6. Easy deployment

Detail for M3, M4, M8, M12 (E4) and M9 (E5).

### 6.1 Decisions

| # | Decision | Why |
|---|---|---|
| D1 | One operator CLI, `ubicloud-admin` in `/usr/local/bin`; NET's `byoh-location`/`byoh-pool` become its `site`/`pool` subcommands (old names stay as aliases) | Fixes the Ruby PATH problem (`bootstrap-ctrl-plane.sh:45-49`); one entry point |
| D2 | systemd units under user `ubicloud`, release dirs `/opt/ubicloud/releases/<ver>` + `current` symlink | Replaces tmux (`:217-236`); restart-on-exit; journald; clean upgrades |
| D3 | DB `ubicloud`, roles `ubicloud` and `ubicloud_password` (not superuser), Unix-socket peer auth with a pg_ident map; no passwords, no `trust` | Replaces `clover_test`, `trust`, `--superuser` (`:28,112,133-138`); the test suite drops `clover_test` (`Rakefile:85-96`) |
| D4 | TLS chosen at install: `acme` (Caddy), `tunnel` (cloudflared), `provided`, `none` (lab, loopback) | Secure cookies outside development (`clover.rb:163`) |
| D5 | Management overlay always on: WireGuard hub on the CP, hosts dial out; `sshable.host` = overlay address; `direct` kept as escape hatch | One model for every platform, NAT/CGNAT included; closes "one CP needs every site's underlay". Conflicts with NETWORKING Q1 (operator VPN) — OPEN §8 D-1 |
| D6 | Adding a host is one command (`host add --ssh` or `host invite` + one `join` line), one code path; preflight mandatory; exit 0 only at `accepting` + `pool verify` | PLATFORMS §6, F10, NET-P3 |
| D7 | Platform-specific material only in recipes, each ending with the same three commands | NETWORKING P1, P7 |
| D8 | Upgrades release-tag to release-tag: pre-upgrade dump, Sequel versioned migrations, symlink flip, optional rolling rhizome | Bootstrap's `migrations` marker never re-migrates (`:201-206`) |
| D9 | Backups include the column-encryption key, stored separately | Sshable keys are encrypted columns (`model/sshable.rb:15`) |

### 6.2 Audit of current deploy paths [TODAY]

| Path | file:line | Problem | Sev | Fixed in |
|---|---|---|---|---|
| ctrl bootstrap | `scripts/byoh/bootstrap-ctrl-plane.sh:28,38` | DB `clover_test` = the name the test suite drops | blocker | M3 (D3) |
| ctrl bootstrap | `:112`, `:120-141` | App role is superuser; `pg_hba` `trust` | major | M3 |
| ctrl bootstrap | `:29,189` | `RACK_ENV=development` (fast retry, self-signed LB certs, insecure cookies, `use_agent`) | major | M3 (E1) |
| ctrl bootstrap | `:42-55,201-215` | Marker files: migrations run once; `refresh_sequel_caches` dirties git-tracked `cache/*.cache` | major | M3 |
| ctrl bootstrap | `:217-236` | tmux, logs in `/tmp`, no restarter, no boot persistence | major | M3 |
| ctrl bootstrap | — | No TLS, no backups, puma on `0.0.0.0` (`puma_config.rb:5`), default `BASE_URL` (`config.rb:86`), no SMTP | major | M3 |
| data bootstrap | `bootstrap-data-plane.sh:121-127` | No `--default-boot-image`; hard-coded `fd00:aa55::/64` (same net6 for every host) | major | M2, M4 |
| data bootstrap | whole file; README | No preflight; "no shared network required" claim is false (`wait_sshable` needs CP → VM) | major | M2, M4, M8 |
| register CLI | `bin/register-byoh-host:73,116-124,138-141` | `--location` label only; no preflight; interactive ENTER | major | M2, M4 |
| terraform | `variables.tf:28` | `operator_ssh_cidr` default `0.0.0.0/0` | major | M4 |
| terraform | `outputs.tf:43-52` | No `pools.yaml`, no host-add command | medium | M2, M4 |
| Proxmox scripts | `docs/byoh/deploy-scripts/04-register-host.sh:58-62` | Unscoped `accepts_slices:false` on every host | major | M4 (delete) |
| Proxmox scripts | `04:35-44,52,59,21-22`; `02:21`; `03:12,21`; `00:57`, `01:52-54,71-73` | /29 split into 3 /32s, `.first` host, no key, `PermitRootLogin yes`, `curl \| bash` of branch head, MASQUERADE over the pool, two NICs | major | M4 (recipe rewrite) |
| cross-recipe | `01-create-vms.sh` vs `variables.tf:16-22` | Both default to 10.98.1.0/24; one CP managing both collides | major | M4 (distinct defaults), M8 (unique mgmt addresses) |

### 6.3 Target operator experience

Identical on AWS, Proxmox, bare metal and homelab.

```bash
# Control plane (M3). Ubuntu 24.04; sizing UNVERIFIED (live uses t3.large)
curl -fsSLO https://github.com/<org>/<repo>/releases/download/v0.1.0/install.sh
curl -fsSL  https://github.com/<org>/<repo>/releases/download/v0.1.0/SHA256SUMS | sha256sum -c --ignore-missing
sudo bash install.sh --version v0.1.0 --url https://cloud.example.com \
  --tls acme|tunnel|provided|none --admin-email ops@example.com \
  [--cloudflared-token-file F] [--cert F --key F] [--smtp URL] \
  [--mgmt-endpoint cp.example.com:51820] [--backup-target DIR|s3://…]
sudo ubicloud-admin account create --email ops@example.com
sudo ubicloud-admin status

# Site (M4; needs M2)
sudo ubicloud-admin site add aws-aps1 --display "AWS Mumbai (BYOH)" \
  --underlay 10.98.0.0/16 --overlay 172.20.0.0/14 --cp-reach mgmt --mgmt wireguard \
  --rates-from hetzner-fsn1 [--mgmt-allow <op>/32] [--dns 10.80.0.1] [--ula-underlay none|operator|mesh]

# Host, form A (M4): CP can SSH with a credential the operator holds
sudo ubicloud-admin host add --site aws-aps1 --ssh ubuntu@10.98.1.30 --ssh-key ~/aws.pem --pool-file pools.yaml

# Host, form B (M8): behind NAT/CGNAT
sudo ubicloud-admin host invite --site homelab --pool-file pools.yaml --ttl 1h
#   → prints one line to run on the host:
#   curl -fsSL https://cloud.example.com/byoh/ubicloud-host -o /tmp/ubicloud-host && sudo bash /tmp/ubicloud-host join --token ubj_…

# Day 2
sudo ubicloud-admin host preflight --ssh ubuntu@IP     # dry run
sudo ubicloud-admin host drain <ubid>                   # state name UNVERIFIED
sudo ubicloud-admin host remove <ubid>                  # refuses with VMs
sudo ubicloud-admin upgrade --to v0.2.0 [--hosts none|rolling]   # M12; --rollback
sudo ubicloud-admin backup now|list|prune --keep 14
sudo ubicloud-admin restore <id> --key-file /secure/ubicloud-keys.age
```

`--cp-reach mgmt` and `--mgmt wireguard` exist only after M8. Until then `site add` uses NETWORKING's `onhost`/`public` and the operator's own route or VPN.

**What `install.sh` does** (every step checks real state; re-run with the same version is a no-op; a different version points to `upgrade`):

| Step | Action |
|---|---|
| 1 | Checks: Ubuntu 24.04, ≥ 1 CPU / 4 GiB, clock synced, :80/:443 free for `acme` |
| 2 | Packages: `postgresql-16`, `wireguard-tools`, Caddy or cloudflared, build deps (no tmux) |
| 3 | Ruby and Node via mise into `/opt/ubicloud/tools` (versions from upstream `mise.toml` after M1; §8 D-11) |
| 4 | Release tarball with prebuilt assets, CI-generated `cache/*.cache`, vendored gems → `releases/<ver>`; `bundle install --deployment` |
| 5 | DB roles, `citext`, `btree_gist`, pg_ident peer map, `listen_addresses='localhost'` |
| 6 | `/etc/ubicloud/env` (0600): production mode, generated secrets, `BASE_URL`, `BIND=127.0.0.1`, mail, `CONTROL_PLANE_OUTBOUND_CIDRS`; never overwritten |
| 7 | Migrate with `bin/rake-task-runner` (ph migrations only when tables are missing, `:54-73`) |
| 8 | `ubimgmt` WireGuard hub (M8) |
| 9-10 | systemd units; TLS front |
| 11 | Backup timer and key-backup README |
| 12 | Smoke: `bin/production_check`, `GET /` through TLS, respirate active |
| 13 | Print URL and next commands |

**What `host add` does** (forms A and B share it):

| Step | Where | Action | Blocks on fail |
|---|---|---|---|
| 1 | host | `ubicloud-host preflight --json`: PF1-PF19 plus C5 (no pool IP on the host), one default route, `wireguard` module, UDP to the hub (form B) | any `fail` |
| 2 | host | Install WireGuard; key generated on the host | |
| 3 | CP | Validate token and pools (no uplink IP or gateway inside, size limit, no DB overlap, `nat` needs E); allocate mgmt address | validation |
| 4 | host | `wg-quick@ubimgmt`; CP key in `authorized_keys` with `from=`; `PermitRootLogin prohibit-password` | |
| 5 | CP | PF20 (location, boot image), PF21 (CP units healthy), SSH over overlay | fail |
| 6 | CP | `ByohRegistration#register!` with `location_id`, `main_ip` = mgmt, `uplink_ip`, pools, `ubuntu-noble` | |
| 7 | CP | Stream HostNexus labels with timeouts; `pool verify`; exit 0 only at `accepting` + hard checks | |

Re-running resumes; never registers twice (keyed on WG pubkey or uplink IP).

### 6.4 Control plane ↔ site connectivity (M8)

| Option | Host behind NAT | CP → VM reach | Extra box per site | Uniform | Verdict |
|---|---|---|---|---|---|
| Direct underlay (today) | no | only if CP is on the underlay | no | no | escape hatch |
| Public SSH per host | no | public pool only | no | partial | rejected |
| WireGuard site gateway | yes | yes | **yes** | needs a box | rejected |
| **WireGuard hub, host dials out** | **yes** | **yes**, via host AllowedIPs | **no** | **yes** | **chosen (D5)** |
| Tailscale / headscale | yes | yes | no | external dependency | recipe only |
| Reverse SSH tunnel | yes | awkward | no | brittle | rejected |

| Item | Spec |
|---|---|
| Addressing | ULA `/64` `mgmt_cidr` generated at install; CP `::1`, hosts `::N`. IPv6-only inner addresses never collide with IPv4 underlays. |
| Hub | `wg-quick@ubimgmt` on UDP 51820; peers rendered from `byoh_mgmt_peer`, `wg syncconf`. |
| Spoke | `Endpoint=<mgmt-endpoint>`, `PersistentKeepalive=25`; needs outbound UDP only. |
| Hub AllowedIPs per host | host mgmt `/128` + host pool IPv4 prefixes + host `net6` (all DB-unique). |
| Host AllowedIPs | CP mgmt `/128` only; no host or VM egress through the CP. |
| `sshable.host` | mgmt address; `uplink_ip` kept for pool validation and `pull_ips` skip logic. |
| `cp_reach` | New value `mgmt`; default for BYOH sites. |
| `control_plane_outbound_cidrs` | Always `<cp mgmt>/128` + CP egress: one global value is correct (resolves NETWORKING Q5 structurally). |
| `host_guard` | Allow UDP to hub, `iifname ubimgmt tcp dport 22` from CP mgmt, forward `ubimgmt → vetho*`; close uplink 22 once confirmed; break-glass `/32`. |
| VM isolation | `mgmt_cidr` in `vm_egress_deny` defaults (replies only). |
| MTU | 1420 for `ubimgmt`; guest MTU unchanged. |
| CP behind NAT | Relay hub on a small VPS (`ubicloud-admin mgmt relay-config`), UNVERIFIED. |
| Security | Private keys never leave their machine; DB holds public keys only; join tokens hashed, single-use, scoped, expiring. `/byoh/join` is the only new unauthenticated route: security review required. |
| Upstream impact | Gated on `provider_name == "generic"`. |
| Not solved | Inbound probe of E for `nat` pools (overlay bypasses E). Optional external `probe-agent` (E5, UNVERIFIED). |

### 6.5 Production control-plane layout (M3)

| Unit | ExecStart (cwd `/opt/ubicloud/current`, `EnvironmentFile=/etc/ubicloud/env`, `User=ubicloud`) | Notes |
|---|---|---|
| `ubicloud-web` | `bundle exec puma -C puma_config.rb` | binds 127.0.0.1 |
| `ubicloud-respirate` | `bin/restarter bin/respirate` | systemd is the outer supervisor (`bin/restarter:4,58-65`); covers apoptosis `exit! 2` |
| `ubicloud-monitor` | `bin/monitor` | **installed disabled** until F5 (M4) and `HostUsageMonitor` reads `:9100` (M5); enabled in M9 |
| `ubicloud-backup` + timer | `ubicloud-admin backup now` | nightly, `Persistent=true` |
| `wg-quick@ubimgmt` | stock | M8 |
| `caddy` / `cloudflared` | stock | per `--tls` |
| `ubicloud.target` | Wants all | |

**Gates for `RACK_ENV=production`** (M3 E1):

| Gate | file:line | Change |
|---|---|---|
| Boot images via R2 only | `prog/download_boot_image.rb:23,34` | `Config.boot_image_source` (`public` default for BYOH) |
| Mail required for sign-up | `config.rb:75-84`, `clover.rb:406-425` | `--smtp` or logger + `account create` (pre-verified; Argon2 insert as in CLAUDE.md §10a; approach UNVERIFIED as a product path) |
| Secure cookies | `clover.rb:163` | D4; `--tls none` over `ssh -L` is lab-only (browser behaviour UNVERIFIED) |
| LB certs need a DnsZone | `prog/vnet/cert_nexus.rb:12,26,142` | Document; optional `--dns-zone` (E5) |
| Strand retry backoff to 600 s | `model/strand.rb:90-94` | Document |
| `allow_unspread_servers=false` | `config.rb:119` | Single-host sites cannot run HA Postgres |
| `BASE_URL` | `config.rb:86` | Installer sets it |

**Backups:** `pg_dump -Fc` **as postgres** (role `ubicloud` cannot read `account_password_hashes`, `migrate/ph/20230315_tables.rb:22`) + `pg_dumpall --globals-only`; secrets (`/etc/ubicloud/env`, `ubimgmt.conf`) age-encrypted to an operator recipient and stored separately; 14 daily by default; `status` warns after 36 h. WAL/PITR later (E5).

### 6.6 Platform recipes (optional; they only produce a machine and a `pools.yaml`)

| Recipe | Produces | Fixes folded in |
|---|---|---|
| `terraform/aws-byoh` | CP instance (optional auto-install), nested-virt data instances, ENI secondary IPs + EIPs, `pools.yaml`, `host_add_command` | no `0.0.0.0/0` default for `operator_ssh_cidr`; `data_plane_open_ingress=false` until `host_guard`; src/dst check per NETWORKING §9.1 |
| `docs/byoh/recipes/proxmox` (replaces `deploy-scripts/`) | data VM `--cpu host`, memory multiple of 1024 MiB, one vmbr1 uplink, pfSense notes, `pools.yaml` example | no MASQUERADE over the pool; no `PermitRootLogin yes`; addressing that does not reuse 10.98.1.0/24 |
| `docs/byoh/recipes/bare-metal` | BIOS VT, storage mount before registration (F6) | |
| `docs/byoh/recipes/homelab` | router static route or tunnel; form B join | hybrid-CPU warning (F4) |
| `docs/byoh/recipes/relay-hub` | VPS relay for a CP behind NAT | |

### 6.7 Phases

| Phase | Content | Depends on | Exit test (disposable canary) | M |
|---|---|---|---|---|
| E0 | `install.sh`, units, DB peer auth, TLS, `BIND`, backup/restore/status, INSTALL/OPERATIONS docs | none | one command → HTTPS UI; `kill -9` respirate → back in 10 s; reboot; backup → wipe → restore, hosts SSH-able | M3 |
| E1 | `boot_image_source`, `account create`, SMTP/logger, `BASE_URL`, `production_check` | E0; M0 | production-mode VM boot with `ubuntu-noble` from the public URL | M3 |
| E2 | `site add`, `host add --ssh`, register CLI fixes, terraform outputs, Proxmox recipe | NET-P1 (M2); NET-P3 for hard `pool verify` (M7) | same three commands on AWS and Proxmox; preflight catches `kvm64`, pool containing uplink IP, hybrid CPU | M4 |
| E3 | `ubimgmt`, `cp_reach: mgmt`, invite/join, host_guard rules, relay recipe | E2; NET-P2 (M7) | homelab host joins with one line; CP manages a PG VM there; uplink 22 closed | M8 |
| E4 | Release workflow, `upgrade`/`--rollback`, rolling rhizome | NET-P0 (M1) | v0.1 → v0.2 with migrations, 3 VMs undisturbed, rollback works | M12 |
| E5 | Enable monitor, alert routing, probe agent, WAL/PITR, DNS zone | F5 (M4), CMP-P2 | 7 days, no false `unavailable` | M9 |

### 6.8 Live AWS environment and deployment changes

- Nothing in §6 is applied to ap-south-1 until its own window. The live CP keeps tmux, `clover_test` and `development` until M3's window.
- M3 window: `pg_dump clover_test` → restore into `ubicloud`; copy `.env.rb` secrets **verbatim** (the column-encryption key must match); stop tmux; start units; cloudflared → `127.0.0.1:3000`; site stays `--mgmt direct` (CP is in the same VPC); move to the overlay only after M8 is proven on a canary. Rollback: restart tmux on the untouched old DB.
- Terraform hazard is closed today: `company-mumbai.tfvars` has `data_plane_open_ingress = false` and no `*.tfplan` exists. Opening ingress waits for M7 (L6).

---

## 7. Upstream rebase strategy

### 7.1 When

| Option | For | Against | Choice |
|---|---|---|---|
| Rebase first, before M0 | No duplicate work at all | Delays relief for the live "full after 3 VMs" problem by the length of a 2298-commit rebase; larger first live change | no |
| **Small fork fixes (M0), then rebase (M1), then everything else** | Live relief in about a week; M0 is mostly cherry-picks of upstream commits (0a8bb6324, 808be1ce6, 02e47743d) that git drops as already-applied during the rebase; every later milestone builds on upstream's current code | Some M0 conflict resolution in `allocator.rb` and `host_nexus.rb` during M1 | **yes** (OPEN §8 D-2 to confirm) |
| Never rebase, keep porting | Smaller steps | Every feature here already exists upstream in a newer form; drift only grows; releases (E4) cannot be promised | no |

After M1, stay close: merge or rebase upstream at least once per milestone, before cutting a release tag (E4). M3's `install.sh` can be written before M1 but cuts its first release only after M1.

### 7.2 Known conflicts and traps (CLAUDE.md §8)

| Area | What to do |
|---|---|
| `lib/hosting/apis.rb` (modify/delete) | Move `GenericApis` to `Hosting::ProviderApis.for`; `provider_name` without `-`; methods without `server_id`; `IpInfo` with `host_only?`, `host_connectivity?` |
| `prog/vm/host_nexus.rb` + spec | Keep our kwargs and default; keep upstream `install_os` (false for generic); `[HETZNER, *LEASEWEB_PROVIDER_NAMES, GENERIC]`; watch `effective_server_identifier` defined inside our hunk |
| `config.rb`, `.gitignore`, `package-lock.json`, `cache/schema.cache` | Drop our `generic_*` config; take theirs; regenerate the cache |
| Fork migration `20260412000000` | Rename to an 8-digit date (fix `schema_migrations` on existing DBs, including live) or set `validate_migration_dates=false` |
| New `check_ip_reachability` label | Generic skip policy before any BYOH host is re-prepped (contract C5; retry-forever) |
| `verify_hugepages` MemAvailable ≥ 2 GiB | Hurts low-tier Proxmox; profile-aware in M5 |
| SSH host keys TOFU-pinned upstream | Reinstalling a host requires re-registering it; affects the console's own pinning plan (§8 D-11) |
| Ruby 4.0.7 via `mise.toml` | Update bootstrap and installer; `.tool-versions` is gone upstream |
| Address semantics (07a15651e) | `after_create` no longer fills the pool; obsolete reconfigure comments |

### 7.3 Port, don't build

| Upstream feature | Use in | Notes |
|---|---|---|
| `NoSpaceLeft`, IO-CPU reservation, `score_offset`, `RESERVED_STORAGE_GIB`, IPv4 LEFT JOIN, CandidateHosts diagnostics, hugepage clamp | M0/M1 | Add the generic `io_cpu_count = 0` override on top |
| `RunCommand` serial log (tab, API, CLI, admin) | M1 (C0) | Cherry-pick is not clean before the rebase (GCP file) |
| `SetupNftables` host-address exclusion, `create_addresses`, `SetupNdpProxy` | M1 | Closes NH-1 self-lockout; NH-7 on-link /64 |
| `CheckIpReachability` | M1 gated, M7 extended | Must not put allocated pool IPs on the host |
| Machine images, `VersionMetalNexus`, `MoveVm`, `RemoteStorageServer`, ubiblk v0.4.2 | M12 | Needs an S3-compatible store on BYOH |
| CH 53.0 | M9 (before balloon) | `origin/main:rhizome/host/lib/cloud_hypervisor.rb:127-131` |
| Admin usage views (`views/admin/{vm_host_usage,customer_usage,…}.erb`) | M9 | |
| `20260914_vm_maintenance_period` | after M12 | Maintenance-window UX instead of live migration |
| `append_serial_console` | M11 | Superseded by the mux; keep the flag |

---

## 8. Risks and open decisions for the user

### 8.1 Decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D-1 | CP ↔ site transport | (a) operator-provided VPN/route, verified as contract C0 (NETWORKING Q1, current text); (b) Ubicloud-managed WireGuard management overlay (§6.4, D5) | (b) as the default from M8, (a) kept as `--mgmt direct`. NETWORKING §4.5/§15 must then be updated. |
| D-2 | Rebase timing | before M0 / after M0 / never | After M0 (§7.1) |
| D-3 | The 3 live customer VMs | They are recreated in NET L3 (location move), M5 cutover option A and L7 | Confirm they are test VMs. If not, batch L3 + L7 + M5 cutover into one announced window per VM. |
| D-4 | Access tunnel vs customer firewall | (a) T1 bypasses `forward_ingress`, separately permissioned + per-VM toggle; (b) route tunnel traffic through `forward_ingress` (harder, UNVERIFIED) | (a), documented as the one exception to NETWORKING P4 |
| D-5 | `Vm:console`/`Vm:connect` for `Member` | via `Vm:all` / explicit grant | Explicit grant for `Vm:connect`; `Vm:all` for `Vm:console` is acceptable |
| D-6 | Web process opening restricted host SSH | accept (diverges from upstream's respirate-only stance, 750026634) / separate gateway process | Accept for C2; split only if G-CON2 fails |
| D-7 | xterm.js | vendored / CDN with SRI | Vendored (air-gapped homelabs) |
| D-8 | Interim egress-only NAT before `host_guard` | own nft file in M2 / wait for M7 | Own gated file in M2 (needed for no-public-IP VMs) |
| D-9 | Default tier for BYOH | Dedicated / Flexible | Flexible for new BYOH locations after the 7-day soak; Dedicated stays for Postgres, K8s, runners |
| D-10 | Order of host security (M7) vs flexible tier and console (M5, M6) | as planned / M7 first | As planned while the live env has only test traffic and closed ingress; **move M7 before M5 the day any real customer traffic or open ingress is needed** |
| D-11 | Host-key pinning | console-only column (C1) / rely on upstream TOFU after M1 for Sshable | Use upstream TOFU for Sshable; keep the C1 column for `ubiconsole` only; drop the C5 "extend pinning to Sshable" item |
| D-12 | Overcommit ratios | CPU 2.0, memory 1.0, storage 1.5 at M5; higher only after gates | As stated in COMPUTE.md; no memory overcommit before G1 |
| D-13 | IO CPUs on small hosts | free both (CMP-P0) / keep 1 thread reserved under 16 threads | Free in M0; set the reserve from G3 in M5 |

### 8.2 Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Rebase size (2298 commits, 7 conflicts) | Weeks of work; regressions in BYOH paths | M1 gate on a fresh canary; rehearse the live migration on a DB dump |
| Live env changes | Customer-visible downtime | Live windows only (L-steps, M3 window); rollback written for each |
| Coverage rule | Flagged steps cost about +40% spec effort | Few flag check points (COMPUTE §12) |
| Puma hijack under Unreloader | Console fails on the live CP | G-CON2 on a dev CP; M3 moves live to production first |
| `CheckIpReachability` after rebase | Hosts stuck before `prep` forever; pool IPs briefly local | Generic skip policy ships inside M1 |
| Balloon with vhost-user `shared=on` | Memory not actually returned | G1/G1b gate; Flexible ships without balloon |
| `/byoh/join` | Only unauthenticated route added | Hashed single-use tokens, rate limit, security review before M8 |
| Postgres on BYOH locations | `Location.postgres_locations` may filter `generic` out (UNVERIFIED) | Decide in M2/M4 (`--postgres yes` or `no`) |
| Terraform provider compatibility with this fork | "Use Terraform" UX may not work | UNVERIFIED; test before documenting |

### 8.3 Cost (EXTERNAL prices, ap-south-1, UNVERIFIED for the account)

| Item | Cost | Note |
|---|---|---|
| Live data plane m8i.2xlarge | about $0.45/h (CLAUDE.md §10a) vs $5.86/h for m5d.metal | Nested virt keeps cost low |
| Live control plane t3.large | small (EXTERNAL list price) | |
| 8 Elastic IPs | AWS charges for every public IPv4 (EXTERNAL) | Scale pools only with demand |
| Canary host for gates (M0-M12) | one more m8i.2xlarge **while a gate runs** | Create and destroy per gate with terraform; never keep it idle |
| Separate dev control plane (M6 gates) | one small instance while testing | Can share the canary VPC |

### 8.4 Contradictions between the design pages

Status 2026-10-12: X-1, X-3, X-5, X-10, X-11 and X-12 are now fixed in the owning pages (PLATFORMS §5 F3/F8 and §8, COMPUTE header and §11, NETWORKING §12). X-2 stays OPEN (D-1). X-4, X-6 to X-9 are resolved by the text below.

| # | Where | Contradiction | Resolution here |
|---|---|---|---|
| X-1 | PLATFORMS.md §5 F8 | Says `ssh -J root@<host> ubi@<vm-private-ipv4>` works today | Wrong (V14, `vm_setup.rb:330-352`). Use §4.8 T0 forms. |
| X-2 | NETWORKING.md §4.5, Q1 vs §6.1 D5 | Operator VPN vs Ubicloud WireGuard overlay for CP ↔ site | D-1 |
| X-3 | COMPUTE.md header and §11 | "Browser console (serial and graphical)" | Serial only; graphical is not planned (CH has no display device, EXTERNAL) |
| X-4 | COMPUTE §12 P0 step 3 vs portability F1 / upstream 808be1ce6 | Free IO CPUs vs charge them to `used_cores` | Take upstream's charge, then generic `io_cpu_count = 0` (D-13) |
| X-5 | COMPUTE P0 vs PLATFORMS F3 | Both own the grub hugepage fix | M0 owns it once; use the grub.d drop-in |
| X-6 | Easy-deploy research vs repo | Claims live tfvars `data_plane_open_ingress = true` and a saved `sg2.tfplan` | Checked 2026-10-12: tfvars `false`, no `*.tfplan`. NETWORKING L0 is right. |
| X-7 | Easy-deploy research | Installer reads Ruby 4.0.2 from `.tool-versions` | Upstream uses Ruby 4.0.7 and `mise.toml` (CLAUDE.md §8); installer is built after M1 |
| X-8 | Console research C5 | "Extend host key pinning to Sshable" | Upstream already TOFU-pins Sshable (CLAUDE.md §8); D-11 |
| X-9 | PLATFORMS §8 #9 vs NET-P1 | Max IPv4 block /24 vs /22 | Keep /24 until `Address#validate` changes |
| X-10 | PLATFORMS §8 #4 | NH-6 `flush ruleset` has no networking owner | Assigned to M7 with `host_guard` |
| X-11 | PLATFORMS §8 #6 | CP-5 fix cited as 02e47743d and 8e295c4d2 | Both are upstream; 02e47743d in M0 if needed, 8e295c4d2 with M1 |
| X-12 | NETWORKING §14.10 vs this page | `docs/byoh/CONSOLE_AND_ACCESS.md` planned as a separate page | §4 here is the design; split it out when C1 ships |
