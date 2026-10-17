# CLAUDE.md — ubicloud, `byoh-driver` branch (BYOH / generic provider)

Facts below were checked against commit 9b0fbb948 unless another commit is named.
Line numbers move over time, so treat them as hints and re-read the file before relying on one.
Anything marked UNVERIFIED was never executed.

## 1. What this repo is

- **Upstream:** Ubicloud ("Clover"), an open-source IaaS control plane.
  - Ruby, using Roda for the web/API, Sequel for the database, and Rodauth for auth.
  - Postgres is the only state store.
  - A strand/prog state-machine engine called **respirate** drives all long-running work.
  - Data-plane code (`rhizome/`) is shipped to bare-metal hosts over SSH.
- **Our fork adds BYOH** ("bring your own host"). A `generic` hosting provider removes the hard dependency on Hetzner, so any Ubuntu 24.04 machine that the control plane can SSH into as root can become a VmHost.
  - The registration CLI is `bin/register-byoh-host`.
  - Optional Redfish BMC reset is supported.
  - Validated on AWS m5d.metal in ap-south-1: the host reached `accepting` and VMs booted through the UI.
  - Tags: `aws-mumbai-pre-eip` = 225ec3604, `aws-mumbai-working-v1` = aca70df27.

## 1a. Design docs (decided 2026-10-12; read before feature work)

| Doc | What it decides |
|---|---|
| `docs/byoh/README.md` | Start-here index: what BYOH is, the six steps to a first VM, the virtualization options (kvm/container/pvm/emulated) with measured speed and status, a one-line map of every doc, and what is verified |
| `docs/byoh/ROADMAP.md` | Master build order M0–M12, the browser console design, the OpenStack feature map, easy deployment, and open decisions D-1…D-13 |
| `docs/byoh/NETWORKING.md` | One host network contract for all platforms (`delivery` routed/onlink/fabric × `exposure` public/nat/internal), `host_guard`, `public_ip4`, real locations |
| `docs/byoh/COMPUTE.md` | Dedicated vs Flexible tiers, custom shapes, overcommit and balloon gates, usage-based placement |
| `docs/byoh/PLATFORMS.md` | Platform compatibility, 54 verified portability findings (F1–F10), host preflight PF1–PF21 |
| `docs/byoh/VERIFY.md` | M2 canary gate G0–G17 (`scripts/byoh/verify/m2-gate.sh`), live window L0–L4, rollback R1–R3, backup checklist; §6 the M4 gates G-M4-1…6 (`m4-e2.sh`, `m4-f5-soak.sh`) |
| `docs/byoh/POOL_OPERATIONS.md` | pools.yaml v2, `bin/byoh-pool`, billing `resource_name` rule, location egress keys |
| `docs/byoh/platforms/` | Operator guides per platform (AWS, rented bare metal, own hardware/colo, Proxmox and other hypervisors, GCP/Azure, other clouds/VPS); `README.md` has the chooser table, the common 6-step flow and which branch carries which fix. Only AWS is tested |
| `docs/byoh/TROUBLESHOOTING.md` | One Symptom/Cause/Fix catalogue by phase (install, bring-up labels, allocation, VM networking, DNS, billing, upgrades, monitor/BMC), with platform pointers; covers both control-plane layouts |
| `docs/byoh/recipes/` | M4: one recipe per platform (`aws`, `proxmox`, `bare-metal`, `homelab`), each a machine plus a `pools.yaml`, then the same three commands (`README.md`) |
| `docs/byoh/NO_KVM.md` | The virtualization ladder, ordered by measured speed (L1 KVM, L2 fix KVM, L3 system containers, L4 PVM, L5 QEMU TCG; tier ids `kvm`/`container`/`pvm`/`emulated`): detection (`bin/byoh-virt`, `Prog::LearnVirt`, `vm_host.virt_probe`), the per-platform fix and cost tables, research, the decision matrix, the declared `virt_tier` model and policy gate, the registration matrix, security per rung, the M4 preflight hook, real-infra tests and the build plan WP1-WP8 (all done on branch `no-kvm`, which merged M4 on 2026-10-16, not pushed; `container` and `emulated` registrable and experimental, `pvm` detected but not offered there). Branch `pvm-build` (from `byoh-driver` f515eb9e8) builds L4 `pvm` after the L4-T1 GO on AWS m6i.large (2026-10-16): offered and experimental, spec-gated, its end-to-end run `scripts/byoh/test/real/pvm-e2e.sh` (L4-T2) UNVERIFIED; §6.7 there lists where the build differs from the first design. Since that merge PF3 is the ladder's verdict (§2.3 there). `EMULATED_HOSTS.md` is the L5 detail; its `accel` design is superseded |
| `docs/byoh/INSTALL.md`, `OPERATIONS.md`, `MIGRATE_FROM_DEV.md` | M3: the packaged control plane (`install.sh` flags, env reference, TLS fronts, production differences), day-2 operation (`ubicloud-admin`, backups, restore, release switch, the 2027-01-01 partition deadline), and the live move from tmux/`clover_test` |

Product direction from the user:
- production-grade
- platform-agnostic
- easy to deploy
- OpenStack-level features with simple UX
- no per-platform patchwork

## 2. Remotes, branches, drift

| Ref | Commit | Notes |
|---|---|---|
| `origin` | github.com/ubicloud/ubicloud | upstream |
| `byoh-fork` | github.com/NameawaShinderu/ubicloud-byoh | our fork; push here |
| local `main` | 43a2241e2 (2026-04-10) | old merge base; stale since the M1 merge |
| local `byoh-driver` | tracks `byoh-fork/byoh-driver` | contains the M1 merge of origin/main fad16215c (§8) and M2 (§8a); `m2-network` was merged into it at 17d383a9c, which runs live since 2026-10-13 |
| `byoh-fork/dependabot/*` | fae63fb24, a20708ee0 | only Gemfile.lock bumps on top of 06f359de4 |
| `origin/main` | fad16215c (committed 2026-10-09) | fetched 2026-10-11 |

- The fork has **no `main` branch**.
- `m3-packaging` (worktree `.claude/worktrees/m3`, from `m2-network` fc693b1e0) carries M3, the packaged control plane; not pushed or merged yet.
- `m4-site-host` (worktree `.claude/worktrees/m4`, from `byoh-driver` 9e22d71ec, which has M0-M3) carries M4: `site add`, `host add`, preflight, F4/F5/F6/F9/F10. Not pushed or merged yet.
- The GitHub fork is the source of truth. Local `byoh-driver` tracks `byoh-fork/byoh-driver`.
- Ask before pushing.
- Authors:
  - The 13 local commits are by `byoh-dev <byoh-dev@example.com>`.
  - The 2 fork-only commits are by Dinanshu Biswas.
  - The git user here is NameawaShinderu.
- Most driver code landed in squashed commit 225ec3604 ("phases 1-6", 18 of the 35 files).
- 9a5dc7d56 later added `--default-boot-image` to `bin/register-byoh-host`, `lib/byoh_registration.rb`, and its spec.
- The rest of the commits are scripts, docs, terraform, and `.gitignore`.

## 3. Upstream architecture essentials

- **Boot:** every process goes through `loader.rb`, which uses Rack::Unreloader with a "directory = module, file = class" rule.
  - Example: `prog/vm/host_nexus.rb` defines `Prog::Vm::HostNexus`. Models are flat under `model/`.
  - `config.rb` defines mandatory env vars: `CLOVER_DATABASE_URL`, `CLOVER_COLUMN_ENCRYPTION_KEY` (base64), `CLOVER_SESSION_SECRET` (base64), `RACK_ENV`. `CLOVER_RUNTIME_TOKEN_SECRET` is optional, but the bootstrap writes it.
  - `.env.rb` is optional Ruby that sets those env vars.
- **Processes** (`Procfile`):
  - `web` is puma via `puma_config.rb`, port `$PORT` or 3000.
  - `respirate` runs `bin/restarter bin/respirate`.
  - `monitor` runs `bin/monitor`, which does host/VM pulse checks and sets `checkup`.
- **IDs:** UBID is 26 characters with a 2-character type prefix (`vh` = VmHost, `vm`, `st` = Strand).
  - A VmHost, its Sshable, its HostProvider, and its Strand all **share one UUID**. A VM's strand id is the VM id.
  - Look records up with `Model["<ubid>"]` or `UBID.decode`, not `Model[ubid: …]`.
- **Strand/Prog model** (`model/strand.rb`, `prog/base.rb`):
  - Write labels as `label def x`. Every label must end in one of `hop_*`, `nap n`, `pop`, `push`, `bud`, or `reap`. Returning normally raises an error.
  - `push` is a same-strand subroutine call, and its result comes back in `retval`. `bud` starts a child strand that runs in parallel.
  - `register_deadline(target, secs)` creates a Page when the target isn't reached in time.
  - A model's `incr_<sem>` wakes its strand. Example: `vm_host.incr_reboot`.
  - The `prog` column is stored without the `Prog::` prefix.
- **Lease and retry:**
  - The lease lasts 120s.
  - Retry backoff after an exception is `least(5,try)` seconds in development; outside development it is exponential up to 600s.
- **Dispatcher apoptosis:** a single strand run longer than about 91s calls `Kernel.exit! 2` on the whole respirate process.
  - Long host work must therefore be daemonized (`common/bin/daemonizer`).
- **Host commands:** `sshable.cmd("sudo host/bin/x :arg", arg:)`.
  - Rhizome lives in `/home/rhizome` on the host.
  - To push new rhizome code to an existing host, run `vm_host.install_rhizome` from `bin/pry`.
- **`Model#delete` raises unless `force: true`.** Use `destroy`.
- **Key directories:**
  - `prog/` holds the state machines.
  - `scheduling/` holds `dispatcher.rb` and `allocator.rb`.
  - `rhizome/host/` holds the data-plane code; `lib/vm_setup.rb` builds VM networking.
  - `migrate/` holds Sequel TimestampMigrator migrations named `YYYYMMDD_name.rb`.
  - `routes/` holds the Roda hash branches.
  - `clover_admin.rb` is the admin UI.

## 4. BYOH design

### Code map (everything we added or changed)

| Path | Status | Role |
|---|---|---|
| `lib/hosting/capability_missing.rb` | A | `Hosting::CapabilityMissing`. (`Hosting::Base` was deleted on 2026-10-12; `GenericApis` is standalone with its own `IpInfo` Struct `(ip_address, source_host_ip, is_failover)`, like HetznerApis.) |
| `lib/hosting/generic_apis.rb` | A | Driven by config; never calls a remote API (see the methods below). |
| `lib/hosting/redfish_client.rb` | A | Excon client: GET Systems, then the Reset target, then POST ResetType. Also `power_state`. Timeouts: connect 5s, read/write 20s. |
| `lib/byoh_registration.rb` | A | Validation, `provider_config` builder, keypair handling, and the call to `HostNexus.assemble`. |
| `bin/register-byoh-host` | A | OptionParser CLI with no extension. Defaults RACK_ENV to development. |
| `prog/vm/host_nexus.rb` | M | `assemble` gains `provider_config:` and `ssh_private_key:` kwargs plus a generic branch; `setup_ssh_keys` skips the root-key bootstrap for generic hosts; `check_ip_reachability` is skipped for generic hosts. |
| `model/host_provider.rb` | M | Adds `GENERIC_PROVIDER_NAME = "generic"` and the `config` annotation. |
| `migrate/20260412_add_generic_provider.rb` | A | Inserts `provider('generic')` and adds `host_provider.config jsonb NULL`. Renamed from the 14-digit name in M1 (§8 step 3 for existing DBs). |
| `cache/schema.cache` | M | Regenerated binary. |
| `.gitignore` | M | `/backups/` |
| `spec/lib/hosting/{generic_apis,redfish_client}_spec.rb`, `spec/lib/byoh_registration_spec.rb`, `spec/lib/byoh_registration_end_to_end_spec.rb` | A | BYOH specs; every BYOH file is at 100% line and branch coverage. |
| `spec/prog/vm/host_nexus_spec.rb` | M | Adds a "generic (BYOH) provider" block (+10 `it` blocks, 81 in total). |
| `scripts/byoh/bootstrap-dev-ctrl-plane.sh` (renamed in M3; `bootstrap-ctrl-plane.sh` is now a shim that runs it), `bootstrap-data-plane.sh`, `README.md` | A | Platform-neutral ops tooling; the control-plane bootstrap is development/labs only. `providers/aws-routed-network-setup.sh` is retired and broken. |
| `scripts/byoh/install.sh`, `packaging/{systemd,caddy,cloudflared,bin}/*` | A (M3) | Packaged control plane: root-owned releases in `/opt/ubicloud`, units as user `ubicloud`, DB `ubicloud` with peer auth, `/etc/ubicloud/env`, TLS front, `ubicloud-admin` (bash). `docs/byoh/INSTALL.md`, `OPERATIONS.md` |
| `scripts/byoh/migrate-from-dev.sh`, `scripts/byoh/migrate-*.sql` | A (M3) | Phased move of a tmux/`clover_test` control plane (preflight, install, copy-db, start, flip-production, rollback, retire). `docs/byoh/MIGRATE_FROM_DEV.md` |
| `lib/byoh_{account_cli,config_check,smtp_url}.rb`, `bin/byoh-{account,config-check,smtp-url}` | A (M3) | Verified accounts without mail; settings, role-isolation and partition-runway checks; SMTP URL to env lines. 100% covered |
| `config.rb`, `puma_config.rb`, `bin/restarter`, `bin/pry`, `prog/download_boot_image.rb`, `prog/deleted_record_archiver.rb` | M (M3) | Opt-ins with upstream defaults: `BIND`, `RESTART_MAX_SLEEP`, `BOOT_IMAGE_SOURCE` (auto/public), `DELETED_RECORD_DROP_UNARCHIVED`, `PRY_ALLOW_UNAUDITED` (console session only); restarter signals only a live child |
| `scripts/byoh/test/` | A (M3) | Container harness (systemd in `ubi-m3-*` containers), §7 |
| `lib/byoh_virt_{ladder,platforms,cli}.rb`, `bin/byoh-virt`, `rhizome/host/{bin/virt-probe,lib/virt_probe.rb}`, `prog/learn_virt.rb`, `migrate/20261015_vm_host_virt_probe.rb` | A (`no-kvm`) | Virtualization detection: read-only facts over SSH (`/proc/cpuinfo`, `/dev/kvm` ioctls and CH's 18 capabilities, modules, kernel-log BIOS lines, DMI, systemd-detect-virt), `classify` into `kvm`/`kvm_blocked`/`none`/`pvm`/`pvm_blocked`/`container`/`unknown`/`unknown_permission`, the platform fix and cost rows, `preflight_check(facts, declared_tier:)` (the M4 PF3 hook), `vm_host.virt_probe` jsonb. LearnVirt fails open and pages `ByohVirtTier` |
| `lib/byoh_virt_{tiers,registration}.rb`, `migrate/20261016_byoh_virt_tier.rb`, `Option::TierVmSizes` | A (`no-kvm`) | `vm_host.virt_tier` (`kvm` default, immutable by trigger; the CHECK only separates kvm from the lower-tier families: the per-tier family is set by `HostNexus.assemble` and checked by `Allocator.update_vm`), `location.byoh_virt` policy, `--virt-tier`/`--accept-fallback`, the policy gate in `Prog::Vm::Nexus.assemble` (no-op for kvm families), single-project tenancy, `ByohVirtTiers::SHIPPED = container emulated` (`container pvm emulated` on `pvm-build`) |
| `prog/vm/{host_nexus,nexus,prep_host}.rb`, `prog/vm/metal/{nexus,move_vm}.rb`, `scheduling/allocator.rb`, `model/{vm_host,metal/vm,location}.rb`, `helpers/vm.rb`, `lib/{byoh_location_cli,byoh_host_cli,validation}.rb` | M (`no-kvm`) | Tier hooks: `verify_virt_tier`, `verify_tier_capacity` (memory budget in the hugepage columns, COMPUTE §9a), R2 tier guard in `update_vm`, kvm-only moves, `--virt-tiers`/`--accept`, API-only tier sizes. U1 goldens pin every kvm output to 9e22d71ec |
| `rhizome/host/lib/{host_tier,container_setup,container_idmap,container_disk,qemu_tcg,qmp_client,emulated_stop}.rb`, `setup-vm`/`stop-vm`/`prep_host.rb` branches | A/M (`no-kvm`) | Per-tier host prep (checks, never installs), LXC system containers in the per-VM netns (idmap slots from 1e9, `dir`/`crypt-loop` disks), the QEMU TCG unit with hardening and QMP soft stop |
| `scripts/byoh/test/nokvm/run.sh`, `scripts/byoh/test/real/pvm-go-no-go.sh`, `bootstrap-data-plane.sh --tier` | A/M (`no-kvm`) | Fail-closed lab harness (`ubi-q-nokvm-*`, no `/dev/kvm`, no `--privileged`, but the guest modes `l3`/`l5` add CAP_SYS_ADMIN/NET_ADMIN/NET_RAW and `/dev/net/tun`, and run only under an admin-loaded `ubi-q-nokvm` AppArmor profile (`NOKVM_L3_PROFILE=1`) or, AppArmor- and seccomp-unconfined, on a throwaway VM (`BYOH_NOKVM_THROWAWAY_VM=1`), never unconfined on this machine); the PVM go/no-go for a throwaway real VM (refuses without `BYOH_REAL_HOST=1`, never run); bootstrap tier selection |
| `lib/byoh_pvm_policy.rb`, `lib/byoh_artifact_fetch.rb`, `migrate/20261017_byoh_pvm{,_upgrade}.rb`, `model/byoh_{pvm_host,pvm_guest_kernel,vm_guest_kernel}.rb`, `prog/download_pvm_guest_kernel.rb` | A (`pvm-build`) | PVM kernel pins in `location.byoh_virt["pvm_kernel"]` (`host_deb`, `guest_kernel`, optional `guest_config`, each `{url, sha256}`; https only; `bin/byoh-location set --pvm-*` downloads and checks them before storing, unless `--no-verify-download` (then only each host checks them and the guest is recorded unchecked); no default pin in code); `byoh_pvm_host` (state `install_pending → installing → armed → committed`, or `failed`/`upgrade_pending`/`uninstalled`; the acknowledged host-deb sha256, PVM and stock kernels, stock entry, lockdown, Meltdown), `byoh_pvm_guest_kernel` per host and sha256 (`downloading`/`ready`/`refused`, console `ttyS0`/`hvc0`), `byoh_vm_guest_kernel` per VM. Pages `ByohPvmGuestKernel`, `ByohPvmGuestKernelFailing` |
| `prog/vm/host_nexus.rb` (`install_pvm_host_kernel`, `verify_pvm_boot`, `pvm_install_failed`, `pvm_boot_failed`, `pvm_retry`, `pvm_upgrade`, `pvm_uninstall`, `pvm_uninstalled`, `pvm_guest_kernel_refused`), `prog/learn_virt.rb`, `prog/vm/metal/nexus.rb`, `scheduling/allocator.rb`, `lib/byoh_virt_{cli,registration,ladder,tiers}.rb`, `lib/byoh_host_watch.rb`, `serializers/vm.rb`, `views/vm/overview.erb`, `cli-commands/vm/post/show.rb` | M (`pvm-build`) | Walk of an `--install-pvm-kernel` host: `verify_virt_tier` (preflight, `ByohPvmInstall`) → … → `patch` → `install_pvm_host_kernel` (daemonized, 45 min) → `prep_reboot` (arm) → `reboot` → `verify_pvm_boot` (`ByohPvmBoot`) → `verify_tier_capacity`. GRUB's default stays stock; `ubicloud-pvm-boot.service` re-arms each good PVM boot. `bin/byoh-virt pvm retry\|uninstall\|upgrade\|refetch-guest` (refetch-guest: a host that lost its guest kernel; the same pin in `byoh-location set` starts nothing). `ByohPvmHostKernel` replaces `ByohKernelReboot` on pvm; `ByohPvmGuestKernelStale` lists VMs on an old guest kernel (stop/start applies a new pin; restart keeps it). Allocator: a `pvm` VM needs a host with a ready guest kernel. API/CLI/VM page: `virt_tier.guest_kernel` |
| `rhizome/host/lib/{pvm_host_kernel,pvm_guest_kernel}.rb`, `rhizome/host/bin/{install-pvm-host-kernel,download-pvm-guest-kernel}`, `vm_setup.rb` (`pvm:`), `host_tier.rb` (`PVM_STEPS`) | A/M (`pvm-build`) | `install-pvm-host-kernel preflight\|install\|arm\|disarm\|status\|upgrade\|uninstall` (JSON on stdin; exit 0 ok, 2 refused, 3 failed and un-armed); `download-pvm-guest-kernel download\|show\|gc` into `/opt/pvm-guest/<sha256>`; direct kernel boot (`--kernel vmlinux --cmdline "console=<hvc0\|ttyS0> root=/dev/vda1 rw"`, no hugepages, CH ≥ 46.0) and a per-start refusal without `pti=off`, Meltdown "Not affected" or `/dev/kvm` 0660 kvm. Goldens `ch_unit_pvm_{hvc0,ttys0}.service`, `params_json_pvm.json` |
| `scripts/byoh/test/real/pvm-e2e.sh`, `scripts/byoh/test/pvm-e2e-{stubs,fake}.sh` | A (`pvm-build`) | L4-T2 for one throwaway AWS m6i.2xlarge (aws-e2e role `pvme`; refuses without `BYOH_REAL_E2E=1`): location, neg-sha, host-add, …, teardown; report `var/pvm-e2e/pvm-e2e-report.txt`, ending with every check a phase skipped (NOT RUN) or simulated. Checks the guest kernel in the VM's unit, its running cloud-hypervisor and `uname -r`. Never run on a real host. A pvm host's `wait` naps 5 min and compares its boot id itself (`check_pvm_boot_id`), since no `bin/monitor` sets checkup on BYOH |
| `terraform/aws-byoh/*` | A | VPC 10.98.0.0/16; t3.medium control plane; m5d.metal data plane with `source_dest_check=false`; 3 secondary IPs + EIPs. |
| `docs/byoh/{QUICKSTART,SETUP,SETUP_PROXMOX}.md`, `docs/providers/generic.md` | A | Docs, rewritten for M2 on 2026-10-13 and for the M4 commands: SETUP is platform-neutral with an "AWS-specific (optional)" section; SETUP_PROXMOX is the Proxmox runbook (UNVERIFIED). `SETUP_PROXMOX_LOWTIER.md` and `docs/byoh/deploy-scripts/` were deleted in M4 (git history only); `docs/byoh/recipes/` replaces them. |
| `scripts/byoh/host/ubicloud-host` | A (M4) | Bash, runs as root on a would-be host, sent on stdin (`bash -s`). `preflight [--json] [--standalone] [--virt-tier T]`: read-only facts and host-local verdicts (PF1-PF19), `UBIPF:<nonce>` JSON lines. Fact `virt` (no-kvm merge): the ladder's facts, from `virt_probe.rb` itself when the host has ruby (`ByohHostPreflight.script` sends it in `UBICLOUD_VIRT_PROBE`), else gathered in shell under the probe's keys (parity spec); `--virt-tier` below kvm makes PF3/PF4/PF5/PF7 info. `storage-disk --by-id ID [--allow-shared-transport]`: formats one blank whole disk as ext4 `ubi-diskN` at `/var/storage/devices/diskN`, never wipes. Fixture mode: `--fixture-root` plus `UBICLOUD_HOST_TEST_ROOT` |
| `lib/byoh_host_preflight.rb` | A (M4) | `ByohHostPreflight`: judges the facts on the control plane (PF17/C5 with the pools, PF20 boot images, PF21 services, PF-min-cpu), `--accept-check` (only `PF8-hybrid`, `PF10-btrfs`, `PF16-{docker,ufw,tailscaled,k3s,libvirtd}`). PF3 = `ByohVirtLadder.preflight_check(virt facts, declared_tier:)` (rung and fix in the detail; for kvm, facts the shell could not gather leave the script's status); a lower tier adds `PF3-tier` (location offers it) and makes PF4/PF5/PF7 info |
| `lib/byoh_host_add.rb`, `lib/byoh_host_watch.rb`, `lib/byoh_host_cli.rb` | A/M (M4) | `byoh-host add\|preflight\|watch` (form A): prepare (operator login, preflight, host keys, confirm, tagged root key, sshd drop-in only if needed, PF2, `--storage-disk`) and register (`register!` pinned, watch, `pool verify`). Exit 0/1/2/3/4/130. Resumes on the main IP. Refuses under `RACK_ENV=test` without injected runners. `--virt-tier`/`--accept-fallback`/`--no-virt-probe` as `register-byoh-host`: the tier is decided from prepare's preflight, kept in the state file for the register phase, and part of the args digest; the watch knows `verify_virt_tier`/`verify_tier_capacity` |
| `lib/byoh_operator_ssh.rb`, `lib/byoh_root_probe.rb` | A (M4) | The operator's system `ssh` (hardened flags, temp known_hosts, exit 255 kept apart); `ByohRootProbe` = PF2 as root with Net::SSH, verifying the pinned keys |
| `lib/byoh_device_identity.rb`, `lib/byoh_health_probe.rb` | A (M4) | F5: disk ids from the mount down (`findmnt`, `lsblk -s`, best by-id link, kernel name; ZFS refused), one SSH exec per pulse for SMART/nvme/clocksource/virt; used only when `vm_host.byoh?` |
| `prog/learn_cpu.rb`, `prog/learn_numa_node.rb`, `prog/learn_pci.rb`, `prog/vm/host_nexus.rb`, `prog/bootstrap_rhizome.rb`, `lib/util.rb`, `model/vm_host.rb`, `scheduling/allocator.rb`, `rhizome/host/lib/storage_volume.rb` | M (M4) | F4 online CPUs; F9 `vfio-pci` IOMMU-group filter and allocator exemption; F5 checks; the `pin_host_keys` frame flag → `Util.rootish_ssh(known_hosts:)`; F6 `write_through_device?` rescue (ungated no-op where sysfs has the entry). All other changes gated on `vm_host.byoh?` |
| `packaging/bin/ubicloud-admin` (site, host, pool), `lib/byoh_location_cli.rb` (`add`, `--display`) | M (M4) | `site add\|...`, `host add` in two invocations (staged keys deleted after prepare), `pool ...`; `--dev` for a development checkout |
| `scripts/byoh/verify/m4-e2.sh`, `m4-f5-soak.sh`, `m2-checks health` | A (M4) | Real-infra gates G-M4-1…5 (VERIFY.md §6), UNVERIFIED; tested against stubs (`scripts/byoh/test/m4-gate-scripts.sh`) |

**GenericApis methods** (`lib/hosting/generic_apis.rb`):

- `pull_ips` returns `IpInfo`s for the declared IPv4 `routed_networks`, preceded by the management `/32` (`host_only?`, claimed by the host) unless a declared block covers it.
- `reimage` always raises `CapabilityMissing`.
- `hardware_reset`, `power_on` (skipped when already on) and `power_status` use Redfish when a BMC is configured; otherwise the first two raise `CapabilityMissing` and `power_status` says so.
- No `pull_data_center`, `pull_inventory` or `set_server_name`: `assemble` never calls them for generic hosts.
- `bmc_password`:
  - If `password_env` is set, it returns `ENV[that]`, even when that is nil. It does **not** fall back.
  - It uses `bmc.password` only when `password_env` is absent.
  - The env var is checked only at registration, so the respirate process must also have it in its environment.

### Dispatch

`VmHost#{create_addresses,reimage,hardware_reset,power_on,power_status,…}` → `HostProvider#api` → `Hosting::ProviderApis.for` → `Hosting::#{provider_name.split("-").first.capitalize}Apis`. Provider names must not contain `-` beyond an org suffix.
The file and class names are load-bearing: `"generic"` must resolve to `Hosting::GenericApis`.

### `host_provider.config` (jsonb)

`{main_ip4, location_label, routed_networks:[{cidr, source_host_ip?, is_failover?}], bmc?:{protocol:"redfish", endpoint, username, password_env|password, system_id?, reset_type?, verify_ssl?}}`

### Registration (one DB transaction in `HostNexus.assemble`)

1. Create the `Sshable` with host = main IP and `raw_private_key_1` = the operator key, preloaded to avoid a race with `setup_ssh_keys`.
2. Create the `VmHost`:
   - `location_id` = the BYOH location named by the required `--location` (create it first with `bin/byoh-location create`). Before M2 every generic host landed in `Location::HETZNER_FSN1_ID`; such legacy hosts keep M1 behaviour until `bin/byoh-host move-location`.
   - `family` = "standard"; `ndp_needed` = false.
   - `net6` = the first IPv6 routed network. If none is given, `ByohRegistration` draws an unused /64 from the location's `ula48`.
   - Because `net6` is set, `LearnNetwork` is skipped (`host_nexus.rb:116`), and `ip6` stays NULL.
3. Create the `HostProvider`:
   - `provider_name` = "generic"; `server_identifier` defaults to `byoh-<vm_host uuid>` (the help text wrongly says "random").
   - `config` = `provider_config`.
   - The primary key is `(provider_name, server_identifier)`.
4. Run `create_addresses`, which goes through `GenericApis#pull_ips`.
   - It creates `Address` and `AssignedHostAddress` rows.
   - `Address#after_create` fills `ipv4_address` with **every** IP in each CIDR, network and broadcast included. Only leaseweb strips those.
   - A CIDR is skipped only when its network address equals `sshable.host`, which in practice means the management `/32`.
5. Create the `Strand` `Vm::HostNexus` at `start`, with stack `{vhost_block_backend_version, default_boot_images}`.
6. `set_data_center` and `set_server_name` are **not** called for generic hosts, so `vm_host.data_center` stays NULL.

- The default Hetzner root-key overwrite in `setup_ssh_keys` runs only when the provider is nil or hetzner (`host_nexus.rb:91-94`).
- As a result, generic hosts never receive `Config.operator_ssh_public_keys`.
- Side effect: leaseweb hosts now skip that step too, which is an unannounced behaviour change.

### HostNexus label walk (generic)

`start → setup_ssh_keys → bootstrap_rhizome → check_ip_reachability (skipped for generic) → prep → wait_prep → setup_hugepages → setup_storage_backend → download_boot_images → wait_download_boot_images → prep_reboot → reboot → [verify_spdk if SPDK installs exist] → verify_hugepages → start_slices → start_vms → configure_metrics → wait`

- **`bootstrap_rhizome`:**
  - This is the first SSH, as root using the sshable key.
  - Runs `apt-get update`, then installs `ruby-bundler`, then **userdel/adduser rhizome**.
  - Writes `/etc/ssh/sshd_config.d/10-clover.conf` (publickey only) and installs rhizome.
  - Has a 10-minute deadline to reach `download_boot_images`.
- **`prep`:** buds PrepHost, LearnMemory, LearnOs, LearnCpu, LearnStorage, LearnPci, InstallDnsmasq, SetupSysstat, SetupNftables, and SetupNodeExporter.
  - PrepHost downloads cloud-hypervisor and htcat from the internet, so **the data plane needs outbound internet**.
  - It also sets the forwarding, proxy_arp, and proxy_ndp sysctls.
- **`wait_prep`:** sets `accepts_slices = (os == "ubuntu-24.04")`.
- **`setup_storage_backend`:** installs **vhost-block-backend** (ubiblk, `config.rb` v0.2.2). This is **not** SPDK.
- **`download_boot_images`:** downloads only the images in `--default-boot-image`.
  - In non-production, ubuntu-noble and ubuntu-jammy come from cloud-images.ubuntu.com.
  - With `RACK_ENV=production`, **every** image comes from R2/MinIO, which we don't have.
- **`reboot`:** **really reboots the data-plane host**, so operator network state must survive a reboot. The deadline is 15 minutes.
- **`start_vms`:** sets `allocation_state` from unprepared to **accepting**.
- **`wait`:** naps 6h and can hop to `unavailable` or `configure_metrics`. Watch `allocation_state`, not `exitval`.
- **Deadlines:** `download_boot_images` → `prep_reboot` has a 4h deadline; `prep_reboot` → `wait` has a 15-minute deadline.

### Allocation requirements (`scheduling/allocator.rb`, `prog/vm/metal/nexus.rb`)

- The VM must be created in the host's BYOH location (its `ui_name`; the project needs `bin/byoh-location grant` while the location is hidden). Before M2, and for legacy hosts still in hetzner-fsn1, that was `eu-central-h1` / "Germany".
- Host requirements:
  - `allocation_state = 'accepting'`
  - family `standard`
  - architecture matches
  - a `boot_image` with that name and `activated_at` set
  - free hugepages and cores
  - **enabled `storage_devices` rows with enough `available_storage_gib`** (INNER JOIN)
  - `accepts_slices` matches
- **The allocator LEFT JOINs `available_ipv4`** and filters on it only when the VM asks for IPv4 (`scheduling/allocator.rb`). A host with no pool takes IPv6-only VMs, whose IPv4 egress goes through the host NAT. An IPv4 VM needs a free address whose pool exposure matches its `ip4_exposure` (`internet` → `public`/`nat`, `internal` → `internal`).
- `Config.default_boot_image_name` = **ubuntu-noble** (`config.rb`, since the M1 merge, upstream 697fb6d66). Download jammy only if customers will pick it.
- `enable_ip4` defaults to false.
- Failure message: `"no space left on any eligible host"`. The VM sets `waiting_for_capacity` and pages after 10 minutes.

### Routing model: the operator owns L3

- The driver **never** configures upstream routing.
- On the host, rhizome adds:
  - `ip route replace <vm-ip>/32 dev vetho<vm>` plus proxy_arp
  - netns DNAT public→private, and SNAT only toward non-RFC1918 destinations (`rhizome/host/lib/vm_setup.rb`)
  - the nftables allowed set
- `wait_sshable` TCP-connects from the control plane to `cp_reach_ip4:22`: the pool address with `cp_reach: onhost`, the public address with `public`. A VM with no address the control plane can reach (internal with `cp_reach: public`, or no IPv4) is probed from the host with `ip netns exec` instead. If nothing connects, the VM stays at `wait_sshable` and pages after 10 minutes.

| Environment | Operator pre-work |
|---|---|
| Real bare-metal providers (Hetzner, OVH, Leaseweb…) | Order a routed block; `routed` + `public` |
| AWS (`terraform/aws-byoh`) | ENI secondary private IPs as `/32`s with 1:1 EIPs, `fabric` + `nat`; the cloud-init C5 fix. `--main-ip` = the data plane's **private** IP. `aws-routed-network-setup.sh` and in-VPC route-table routes are retired |
| Homelab or pfSense router | Static route for the block → the data-plane IP (on Proxmox, the data-plane **VM**), `routed` |
| Proxmox / LAN (SETUP_PROXMOX.md) | Pool range on the LAN outside DHCP, `onlink` + `internal`, or `onlink` + `nat` via pfSense 1:1 NAT; proxy_arp answers (UNVERIFIED on any platform) |
| Single IP only | IPv6-only VMs work, with IPv4 egress through the host NAT; IPv4 VMs need a pool |

## 5. Deployment flow (real commands)

### Control plane, packaged (M3, `m3-packaging`; UNVERIFIED outside the container harness)

`sudo bash ~/ubicloud/scripts/byoh/install.sh --version V --source-git ~/ubicloud --ref <rev> --url https://HOST --tls <acme|provided|tunnel|none> --admin-email E --backup-recipient age1...` (`docs/byoh/INSTALL.md`).
- Idempotent, no markers; a flag that would change an existing setting exits 2 unless `--update-env KEY`. Exit 0/1/2.
- Default `--rack-env production` with `BOOT_IMAGE_SOURCE=public`, `MAIL_DRIVER=logger`, `DELETED_RECORD_DROP_UNARCHIVED=true`, `ALLOW_UNSPREAD_SERVERS=true`, `BIND=127.0.0.1`. The **E1 canary** (a production-mode VM boot) has not run.
- Operate with `sudo ubicloud-admin status|smoke|backup|restore|env|logs|account|run <tool>|console|release` (`docs/byoh/OPERATIONS.md`). Tools run as `ubicloud-admin run byoh-location ...`; DB access `sudo -u postgres psql -d ubicloud`.
- **API / `ubi` CLI host:** `clover.rb` routes only hosts starting with `api.` to the API, so `UBI_URL=https://<host>/cli` gets the web UI's HTML login page (first real AWS run). The front also serves `--api-host` (default `api.<--url host>`, `API_HOST` in the env file; `--no-api` opts out, `API_HOST='none'`). `acme`: one Caddy site for both names, so `api.<host>` needs its own DNS record (`<ip>.sslip.io` names resolve by themselves). `provided`: served only when the certificate covers it, else a warning. `tunnel`: route the public hostname `api.<host>` to `http://127.0.0.1:3000` yourself. `none`: `UBI_URL=http://api.localhost:3000/cli` over `ssh -L`. `status`/`smoke` expect a JSON 401 from `GET https://api.<host>/project`. Use `UBI_URL=https://api.<host>/cli`. A real ACME issuance for `api.<host>` is UNVERIFIED.
- Refuses to start the units while `~/.ubi-bootstrap` exists: a dev control plane moves with `migrate-from-dev.sh` (`docs/byoh/MIGRATE_FROM_DEV.md`), window A (layout) then window B (production, after the E1 canary). Rollback = the R0 tmux commands on the untouched `clover_test`.

### Control plane, development (live today)

Ubuntu 24.04, run as a non-root sudo user.

1. `git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud`
   - **The bootstrap does not clone.** Step 5 exits 1 if the repo is missing.
2. `bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh` (the old name `bootstrap-ctrl-plane.sh` is a shim since M3; terraform user data and `curl | bash` keep working)
   - Since M3 it refuses `UBI_RACK_ENV=production`, `UBI_DB_NAME=ubicloud`, and a machine with `/etc/ubicloud/env` or an active/enabled `ubicloud.target` (`UBI_FORCE_DEV=1` overrides the last).
   - Env overrides: `UBI_REPO_DIR`, `UBI_RUBY_VERSION` (4.0.7), `UBI_NODE_VERSION` (24.12.0), `UBI_DB_NAME` (**clover_test**), `UBI_RACK_ENV` (development), `UBI_START_SERVICES`, `UBI_START_MONITOR` (0), `UBI_BILLING_RATES_DIR` (`~/ubicloud-billing-rates.d`).
   - It installs PG16 and creates roles `clover` (superuser) and `clover_password`.
   - It sets **pg_hba to trust** for local and loopback connections.
   - It writes `.env.rb` (chmod 600; never overwritten if it exists), including `BILLING_RATES_EXTRA_DIR`, and runs `bin/rake-task-runner migrate "" 0`.
   - It starts tmux sessions **`puma`** and **`respirate`**. Logs go to `/tmp/{puma,respirate}.{log,err}`.
   - Markers live in `~/.ubi-bootstrap/`. The `migrations` and `caches-refreshed` markers are permanent, so **delete them after pulling new migrations**.
   - `bin/monitor` starts only with `UBI_START_MONITOR=1` (leave it off for EBS/virtio hosts, PLATFORMS F5); `bin/restarter` is not used, and nothing survives a reboot.
3. Ruby is not on the interactive PATH. `export PATH=~/.local/bin:~/.local/share/mise/installs/ruby/4.0.7/bin:$PATH`. `~/.local/bin` (mise) is needed by `bundle install`.
4. Open the UI at `http://<ctrl>:3000/create-account`. **No admin account is seeded.**
   - The verification email goes to the logger, so look in `/tmp/puma.log`, not the tmux pane.

### The three commands (M4, `m4-site-host`; UNVERIFIED on real infrastructure)

Every platform: `install.sh` (above), then on the control plane

```
sudo ubicloud-admin site add <site> --display "<UI name>" --underlay <CIDRs> --overlay 172.20.0.0/14 \
  --cp-reach onhost|public --cp-source <cp>/32 --mgmt-allow <CIDRs> --rates-from hetzner-fsn1
sudo ubicloud-admin host add --site <site> --ssh <user>@<main IP> --ssh-key <operator key> --pool-file pools.yaml \
  [--registration-key F] [--storage-disk <by-id>] [--accept-check PF8-hybrid] [--uplink-ip IP] [--expect-host-key SHA256:...] [--yes]
```

- Development layout: `packaging/bin/ubicloud-admin --dev ...` from the checkout, no sudo, restarts nothing.
- `host add` needs only a login with passwordless sudo on the host; it installs its own root key (tagged line) and needs no `bootstrap-data-plane.sh`. `--ssh-key` (any type) is never stored; `--registration-key` (Ed25519) is generated when absent and then lives only in the DB.
- `--main-ip` defaults to the `--ssh` host. `--uplink-ip` (stored as `provider_config["uplink_ip"]`) is detected from the default route; give it only with several default routes. No pool may contain the uplink IP, main IP or gateway (PF17, never acceptable). `pull_ips` still skips on `main_ip` until M8.
- Default boot image `ubuntu-noble` for both `host add` and `register-byoh-host` (`--default-boot-image` replaces it).
- Exit 0 only at `accepting` with no `pool verify` FAIL; a re-run resumes; Ctrl-C after registration stops only the watch (`host watch` resumes it).
- Recipes: `docs/byoh/recipes/`; details: SETUP.md §6, §8.1; TROUBLESHOOTING §2.1a (one `#pfN` anchor per check), §2.3.

### Data plane

Ubuntu 24.04 with KVM, outbound internet, and root SSH from the control plane (low-level `register-byoh-host` path; `host add` sets up root SSH itself).

- Run `scripts/byoh/bootstrap-data-plane.sh`, or use terraform's `user-data-data.sh`.
  - It does openssh, `PermitRootLogin prohibit-password`, and pre-installs ruby-bundler and netcat-openbsd (the gate's netns proxy).
- Put the control plane's **public** key into `/root/.ssh/authorized_keys` **before** registering.
- Do the L3 pre-work from §4.

### Register (on the control plane, from the repo root)

```
RACK_ENV=development bundle exec bin/register-byoh-host \
  --location <byoh location> --main-ip <v4> \
  (--pool-file pools.yaml | --routed-network <cidr>[,key=value...] ...) [--ipv6-mode gua|ula] \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble [--default-boot-image ubuntu-jammy] \
  [--server-identifier ID] \
  [--bmc-endpoint URL --bmc-user U --bmc-pass-env VAR [--bmc-system-id ID] [--bmc-reset-type ForceRestart] [--bmc-verify-ssl]] \
  [--virt-tier kvm|auto|container|pvm|emulated [--accept-fallback] [--install-pvm-kernel]] [--no-virt-probe] \
  --yes
```

- The virtualization tier (NO_KVM.md §11) comes from the same preflight session: PF3 judges the host for the declared tier (`auto`: what the facts say), then `ByohVirtRegistration#decide!` refuses or registers. A lower tier needs `--accept-fallback` and a location that offers it (`bin/byoh-location set --virt-tiers`); without `--default-boot-image` such a host downloads its tier's first image (`ubuntu-noble-container` for `container`). `host add` takes the same three options.
- PVM (`pvm-build` only; NO_KVM.md §6.7): on a stock Ubuntu 24.04 x86_64 host without `vmx`/`svm`, Secure Boot off and Meltdown "Not affected", `--virt-tier pvm --install-pvm-kernel --accept-fallback` (also on `host add`; `bootstrap-data-plane.sh --tier pvm` runs the read-only checks). The location needs `rates --family pvm`, then `set --virt-tiers kvm,pvm --accept pvm --pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX [--pvm-guest-config URL --pvm-guest-config-sha256 HEX]`. pvm is single-project: **keep the location hidden and `grant` it to one project.** Example pins, the cocoonstack/pvm v0.1.0 release that L4-T1 booted (**third party; Januscape fix inclusion UNVERIFIED; for testing only, not a recommended production pin**), base `https://github.com/cocoonstack/pvm/releases/download/v0.1.0/`: host deb `linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb` sha256 `a02e2555c0ae65c2007dc9db2a92b14b63a61c86b3eb796d5a25868f3701ffd1`; guest `vmlinux-pvm-amd64` sha256 `84dcf08143ce7e945a770ff1b6d25e0505c1da69d674831b470cabc139598acb`; guest config `guest-pvm-amd64.config` sha256 `51ce5c264373e18817bf94816cfb08c365eaee36cfa624045ccbb7c17aad90f5`. Its guest has no 8250 serial driver, so its console is `hvc0`. AWS: m6i/m7i xlarge or larger (m6i.large fails `verify_tier_capacity`); t3 only if the probe passes (`platforms/aws.md` §2.1a).

- `--ssh-key` must be an unencrypted OpenSSH Ed25519 key.
- Run the CLI from the repo root with a working `.env.rb`; it loads `db.rb` and `loader.rb`.
- `--location` is **required** and must name a BYOH location created with `bin/byoh-location create` (§8a). Pools are optional: `--pool-file` and `--routed-network` add to each other; with none, only IPv6-only VMs place.
- Terraform: SSH ingress comes from `var.operator_ssh_cidr`, and ports 3000 and 443 from `var.web_ui_cidr`. Both are required since M4 (no default); set both to your /32. Outputs `byoh_location_create_command` (`ubicloud-admin site add`) and `host_add_command` (`scp`, `host add --ssh`, `shred`, `host watch`); never applied (UNVERIFIED).
- Boot images live only in the strand stack. To add one later, run `vm_host.download_boot_image("name")` in `bin/pry`.

- There is **no `--provider` flag**; passing one aborts with InvalidOption. Several docs still pass it.
- Before M2, `--location` was only a label and the host landed in eu-central-h1. From M2 the host lands in the named location.
- Without `--ssh-key`, the CLI generates a key and prints the public key to install.
- If any BMC flag is given, `verify_ssl` is forced to false unless `--bmc-verify-ssl` is passed.
- Prefer `--bmc-pass-env`. `--bmc-password` is stored in plaintext in jsonb.
- IPv4 rules:
  - Each block must be ≤ /24 and network-aligned.
  - Keep the management IP **outside** declared blocks.
  - IPv6 must be /64.
- Bring-up to `accepting` takes about 15–25 minutes on bare metal (about 4 on a nested-virt VM), including one host reboot.
- Runbooks: `docs/byoh/SETUP.md` (any platform), `SETUP_PROXMOX.md`, `QUICKSTART.md`.

### Change the IP pool later

From M2, use `bin/byoh-pool` (list, export, add, remove [--drain], remap, annotate, ipv6 set, verify, trace); see `docs/byoh/POOL_OPERATIONS.md`.
The old `scripts/byoh-ops/reconfigure-routed-networks.rb` was deleted on 2026-10-12: it destroyed every VM on the host and had no spec.
It is still in git history (`git show 0a24426cc:scripts/byoh-ops/reconfigure-routed-networks.rb`) for an emergency.

### Re-registering the same IP

- The unique indexes `sshable.host`, `address.cidr`, and `vm_host.net6` will collide.
- Destroy the old VmHost first with `incr_destroy`:
  - `HostNexus#destroy` drains the host and waits until it has **no VMs**, so delete the VMs first.
  - Dependents are destroyed when the strand pops.
  - The generic driver is not called on destroy, so there is no BMC or provider cleanup.
- **Never delete `location` rows.** The row is the shared hetzner-fsn1.

## 6. Debugging playbook

The operator-facing catalogue is `docs/byoh/TROUBLESHOOTING.md`; keep it consistent with this section. The commands below are for the development layout; on a packaged control plane use `sudo -u postgres psql -d ubicloud`, `sudo ubicloud-admin logs respirate`, `sudo ubicloud-admin console` and `sudo ubicloud-admin status` (TROUBLESHOOTING §0).

- **Host state** (use the `vm_host` id = strand id):
  `SELECT prog,label,try,schedule,stack FROM strand WHERE id='<uuid>';`
  `SELECT allocation_state,os_version,total_cores,total_hugepages_1g,accepts_slices,net6 FROM vm_host;`
- **Children:** `SELECT prog,label,try FROM strand WHERE parent_id='<uuid>';`
- **Errors:**
  - `/tmp/respirate.log`/`.err` show `"exception terminates strand run"`.
  - Expired deadlines create `page` rows ("has an expired deadline!").
- **REPL:** `RACK_ENV=development bundle exec bin/pry`, then `VmHost.first`, `vm_host.install_rhizome`, `vm_host.download_boot_image("ubuntu-jammy")`.

| Symptom | Cause / fix |
|---|---|
| Stuck at `bootstrap_rhizome` (BootstrapRhizome) | Root SSH is failing: the key isn't in root's authorized_keys, or there's no route from the control plane to the main IP |
| PrepHost fails | No outbound internet (cloud-hypervisor and htcat downloads) |
| LearnMemory "unexpected dmidecode unit" | Non-GB DIMM sizes (common in nested VMs) on builds without a0259a997 (the published `byoh-driver`); on `m2-network` only an unknown unit |
| `verify_hugepages` fails | Not enough RAM for 1G hugepages |
| VM "no space left on any eligible host" | Wrong location (use the host's BYOH location; eu-central-h1 only for a legacy host not yet moved); no activated boot image of that name; no free `ipv4_address`; cores/hugepages; slices mismatch on low-core hosts (scope the fix: `DB[:vm_host].where(id: …).update(accepts_slices: false)`) |
| VM stuck at `wait_sshable` | The control plane can't reach `<vm ip4>:22`. This is a missing operator L3 route, not a driver bug |
| Strand stuck at `hardware_reset` | Admin "Hardware Reset" on a host with no BMC raises `CapabilityMissing` forever (or on a host with VMs that isn't draining); VMs show as "rebooting". **Don't click it** without a BMC |
| Redfish reset fails with an auth error after a control-plane restart | The `--bmc-pass-env` variable is missing from respirate's environment, so the call goes out with a nil password |
| `host add` / `register-byoh-host` stops at preflight | The `fail` line names the check; TROUBLESHOOTING §2.1a `#pfN`. Only `PF8-hybrid`, `PF10-btrfs`, `PF16-<service>` are `--accept-check`able; PF3 (no KVM, kvm64 model), PF10-zfs, PF16-pve (a Proxmox node), PF16-rhizome-user, PF17 (pool holds uplink/main IP/gateway) and PF-min-cpu never |
| `host add` exits 3 | The watch gave up (phase deadline, respirate down, `--timeout`, host outside bring-up); the strand keeps running. Fix and re-run, or `host watch` |
| Monitor marks a pre-M4 BYOH host down ("stale storage device id", "is not a whole disk") | Disk ids learned before M4: `bin/byoh-host relearn-device-ids --host vh... --yes` |
| `pgrep -a cloud-hypervisor` shows nothing | The name is longer than 15 chars. Use `pgrep -af cloud-hypervisor` |
| Health / `unavailable` never triggers | `bin/monitor` isn't running |
| (`no-kvm`) Registration refused with "refused: …" and "to register it on its fastest option:" | The probe found no usable KVM. Apply the printed fix (the fast answer), or run the printed `rates`/`set`/`--virt-tier auto --accept-fallback` commands. TROUBLESHOOTING §2.1 |
| (`no-kvm`) Lower-tier host retries at `verify_virt_tier` | No probe, or the probe disagrees with the tier: install the tier's packages, then `bin/byoh-virt refresh --host vh…` |
| (`no-kvm`) `container-*`/`emulated-*`/`pvm-*` VM create 400 | Usually "\"<size>\" is not a valid virtual machine size": the location is not BYOH, its policy does not list the tier, or the tier is `pvm` (not shipped before `pvm-build`). On `pvm-build` a `pvm-*` VM of any image but `ubuntu-noble` is refused (direct kernel boot). With the size accepted: another project already uses the single-project tier there, or no rate for the family (restart all three processes after `rates`). The other `ByohVirtTiers.check_vm!` texts reach only Ruby callers of `Prog::Vm::Nexus.assemble` |
| (`pvm-build`) PVM host pages `ByohPvmInstall` / waits at `pvm_install_failed` | Preflight refused (fix it; rechecked every 5 min), the location's host-deb pin is not the acknowledged one (`bin/byoh-virt pvm retry --host vh… --accept-host-deb <sha>`), or the install was refused (nothing changed) or failed (un-armed, boots stock): `pvm retry` or `pvm uninstall`. TROUBLESHOOTING §2.2 |
| (`pvm-build`) PVM host pages `ByohPvmBoot` / waits at `pvm_boot_failed`, VMs not started | "booted its stock kernel": the PVM boot failed or hung and GRUB fell back (keep the serial console log; `pvm retry`). "/dev/kvm is 600 root" or the boot unit failed: check the `kvm` group and `journalctl -b -u ubicloud-pvm-boot`. Meltdown no longer "Not affected" after an instance-type change: move back to m6i/m7i. A host that does not come back at all: the EC2 serial console GRUB menu, or detach the root volume and repair the stock kernel from a rescue instance (`unset next_entry` does nothing there; `set saved_entry=<a working entry>` boots it meanwhile, then set the recorded stock entry back) |
| (`pvm-build`) `pvm-*` VM never places, or `ByohPvmGuestKernel*` pages | No host holds a ready guest kernel: a refused pin (pin another with `bin/byoh-location set --pvm-guest-kernel …`) or a download that keeps failing (host egress to the URL). Empty serial log: the console recorded for the kernel is wrong (pin its `--pvm-guest-config`, recreate the VM) |

- **Nested or virtual hosts:** upstream health checks require the `tsc` clocksource and smartctl, and handle `sd*` without wwn badly. Since M4 a BYOH host (`vm_host.byoh?`) gets its own checks (F5); a generic host still in hetzner-fsn1 keeps upstream's. The 24-hour soak (VERIFY.md G-M4-3…5) is UNVERIFIED, so the monitor stays off.

## 7. Running tests on THIS machine (shared machine)

- Ruby, bundle, and mise are **not installed on the host**. Host node is v22, which is too old. Run everything in docker.
- **Never touch other projects' containers:** `vdi_project-*` (5432/6379), `lms2-*`, `cms-demo-db`, `skg-booth-*`, `srpl-billing-*`, `code-furnace-*`, `devops-*`, `searxng*`, `caldera`, `coder-*`, `dsp-*`.
- Ours:
  - network `ubi-test-net`
  - container `ubi-pg-test` (postgres:16-alpine, **no host ports**, currently Exited)
  - image `ubi-bundler` (`docker build --target bundler -t ubi-bundler .`)
- Only run `psql` via `docker exec ubi-pg-test psql -U clover -d clover_test`.
- The local `.env.rb` sets `RACK_ENV ||= "test"` and a DB URL of `ubi-pg-test:5432/clover_test`.

```
docker start ubi-pg-test    # only our container
docker run --rm --network ubi-test-net -v "$PWD:/app" -w /app -e RACK_ENV=test ubi-bundler sh -c 'bundle exec bin/rake-task-runner migrate "" 0'
docker run --rm --network ubi-test-net -v "$PWD:/app" -w /app -e RACK_ENV=test -e FORCE_AUTOLOAD=1 ubi-bundler sh -c 'bundle exec bin/rake-task-runner refresh_sequel_caches'
docker run --rm --network ubi-test-net -v "$PWD:/app" -w /app -e RACK_ENV=test ubi-bundler sh -c 'apk add --quiet bash openssh-client && bundle exec rspec spec/lib/hosting spec/lib/byoh_registration_spec.rb spec/lib/byoh_registration_end_to_end_spec.rb spec/prog/vm/host_nexus_spec.rb'
```

- The containers run as root, so `var/` ends up root-owned.
- The earlier session's results: BYOH specs, 80 examples, 0 failures; a 1911-example subset, 0 failures.
- **Full-suite recipe (upstream's real gate; all green since 2026-10-12):**
  - Upstream gates on the **parallel** run (`rake coverage_pspec`, turbo_tests, results merged). A serial `coverage_sspec` always reports `config.rb` as uncovered, because `spec/config_spec.rb` re-`load`s it and Ruby resets that file's counters. That is not a real gap.
  - Use a clean worktree, so the gitignored `backups/*.rb` are not counted.
  - In the worktree, write a test-only `.env.rb` (gitignored) with random `CLOVER_*` secrets and `CLOVER_DATABASE_URL = postgres://clover@ubi-pg-test:5432/clover_cov_test#{ENV["TEST_ENV_NUMBER"]}`.
  - turbo_tests numbers processes **1..N** (not "", 2..N). Create `clover_cov_test1`..`clover_cov_test6` in `ubi-pg-test` with `citext` and `btree_gist`, and migrate each with `TEST_ENV_NUMBER=n`.
  - Run with `docker run --cpuset-cpus=0-5 ...` so `Etc.nprocessors` gives 6 processes on this shared machine: `bundle exec rake coverage_pspec`, then `bundle exec rake frozen_pspec`, then `bundle exec rubocop`.
  - Specs cannot mock core classes like `File` (frozen mode raises "does not implement").
  - Since M1, use the image `ubi-bundler-m1` (Ruby 4.0.7) and databases `clover_m1_test1..6`. Rhizome specs need an Ubuntu `/etc/os-release`, so add `-v /etc/os-release:/etc/os-release:ro` for `rake rhizome_spec`.
  - Inherited, environment-only failures that also fail on pure `origin/main` here: `spec/db_spec.rb:189,193` (superuser test DB), `spec/routes/web/admin/model/resource_discount_spec.rb:13` (upstream bug), and `rhizome/postgres/spec/disk_full_check_spec.rb` (29 examples, Alpine).
  - M1 result (2026-10-12): 9151 examples with only those 3 failing; excluding the two affected files, 9102 examples, 0 failures, and the only coverage gaps are lines exercised by the excluded `db_spec`. Frozen: 9127 examples, same 3. Rubocop clean.
  - If a run is interrupted, `coverage/` stays root-owned; clean it up from inside a container.
  - 2026-10-12 (`cov-100`): 100.0% line (20425/20425), 100.0% branch (6126/6126), 5485 examples; frozen 5465 examples; rubocop clean; all 0 failures.
- Upstream's gate is **100% line and 100% branch coverage per file** (`spec/coverage_helper.rb`). Every new file needs full specs; prefer deleting dead code over `# :nocov:`.
- **Spec conventions:**
  - Mock `Sshable#_cmd`, never `#cmd`. `RACK_ENV=test` raises `NetSsh::MissingMock` on real SSH.
  - Use the `hop`/`nap`/`exit` matchers.
  - Run `rake test_up` or refresh caches after a migration.
- **Lint:** rubocop + standard. Multiline literals need trailing commas (`diff_comma`). The whole repo is rubocop-clean since 2026-10-12; keep it that way.
- **Never run `RACK_ENV=test` on a real control plane.** It disables SSH.
- **Never run `rake setup_database[test]` on a control plane.** It drops `clover_test`, which is the deployment DB.
- **M3 (2026-10-14):** image `ubi-bundler-m1`, databases `clover_m2_test1..6` (the worktree's `.env.rb`). Gate order: `rake coverage_pspec`, `frozen_pspec`, `rubocop`, then `rake rhizome_spec` with `/etc/os-release` mounted when `rhizome/` changes. `bash -n` and shellcheck (`docker run --rm --name ubi-m3-shellcheck --network ubi-test-net -v $WT:/mnt:ro koalaman/shellcheck-alpine shellcheck -x <files>`) on every shell script.
- **M4 (2026-10-15):** runner `rt_m4.sh` (same image and `clover_m2_test1..6`, `RACK_ENV=test`). Containers `ubi-m4-*` only (`UBI_TEST_PREFIX`; image `ubi-m4-fakehost`: ubuntu:24.04 sshd as PID 1, no systemd, no `/dev/kvm`, a `systemctl` shim). The plan's `rt_m4_dev` became the `ubi-m4-cp` container of `scripts/byoh/test/m4-host-add.sh` (`RACK_ENV=development`, `TEST_ENV_NUMBER=6` = `clover_m2_test6`; `m4-db-state` snapshots and restores that DB, refuses `clover_test`; never run it during a pspec). Other M4 harness scripts: `m4-fakehost-check.sh`, `preflight-fixtures.sh` (fixture hosts in `fixtures/host/`), `storage-disk-fixtures.sh`, `m4-install-key-cases.sh`, `m4-admin.sh`, `bootstrap-preflight.sh`, `m4-gate-scripts.sh`. Shellcheck as `ubi-m4-shellcheck`.
- **Container harness** (`scripts/byoh/test/run.sh`, README there): systemd 255 as PID 1 in `--privileged` containers with a private cgroup namespace (never bind-mount `/sys/fs/cgroup`). Every container is `ubi-m3-*`, joins only `ubi-test-net`, publishes no port; a run removes only its own (`UBI_M3_KEEP=1` keeps them). Images: `ubi-m3-systemd` (`--prepare-image`), `ubi-m3-tools` (`--prepare-tools`: `install.sh --stage tools`), `ubi-m3-release` (`--prepare-release`: the working tree installed as release `t1`); re-prepare the release after a change to code or install.sh's release steps. Scenarios: `parity envfmt verify fresh rerun flags smoke kill restart reboot tls-provided tunnel backup admin devshim gate-journal migrate migrate-preM1 upgrade-manual` (`all`). It never reaches a real server; ACME, a real tunnel and a real reboot stay UNVERIFIED.

## 8. Upstream merge (M1, 2026-10-12)

`byoh-driver` merged `origin/main` fad16215c (2298 commits) as a merge commit, not a rebase, so the published fork history and the `aws-mumbai-*` tags stay valid. Stay close from now on: merge upstream at least once per milestone.

How the 22 conflicts were resolved:
- **Provider layer.** Upstream replaced `Hosting::Apis` with `Hosting::ProviderApis.for(provider)`. `GenericApis < Hosting::ProviderApis` now has:
  - `IpInfo = Data.define(:ip_address, :source_host_ip)`, where the management `/32` is `host_only?` (an `AssignedHostAddress`) and declared blocks are VM pools
  - `reimage` (always `CapabilityMissing`)
  - `hardware_reset`, `power_on` and `power_status`, all through Redfish (`RedfishClient#power_state`; timeouts 5s connect and 20s read/write, kept under respirate's ~91s apoptosis)
- **`HostNexus.assemble`** keeps our `provider_config:`/`ssh_private_key:` kwargs and the `byoh-<id>` default, and takes upstream's `install_os` (false for generic). The provider list is `[HETZNER, *LEASEWEB_PROVIDER_NAMES, GENERIC]`.
  - `setup_ssh_keys` skips the root-key bootstrap **only** for generic hosts, which restores upstream behaviour for leaseweb.
  - **Generic hosts skip `check_ip_reachability`.** It would put pool IPs on `lo` (contract C5), and it loops forever behind NAT or without ICMP. PrepHost's downloads prove egress instead.
- **IO CPUs.** Upstream renamed `vm_host_cpu.spdk` to `io` and added `numa_node`. The generic override (`io_cpu_count = 0`, in the LearnCpu reaper) now writes `io`.
- **Storage.** `Metal::Vm#storage_volumes` takes upstream's version: `allowed_cpus` is set only for slices, which supersedes our M0 "cpus unset" fix.
  - Rhizome `DeviceResolver` (upstream) gained `NoPersistentDeviceId`.
  - `StorageVolume#io_limit_device` falls back to the storage path.
  - `CryptSwapSetup` falls back to `/dev/disk/by-partuuid` for EBS/virtio swap partitions, and skips when fstab has no swap entry. Upstream failed both cases, which blocked cloud-image hosts.
- **Allocator.** Upstream's `CandidateHosts`, NUMA-aware `select_cpuset`, `score_offset`, `os_filter` and reserved storage are taken. On top of them we re-applied:
  - grow-on-reuse shared slices
  - `CounterDrift`
  - capacity-only `CheckConstraintViolation` conversion
  - `host_capacity_summary`, which now also applies the data-center and OS filters
- **Hugepages:** ours, which already contains every upstream hugepage commit, plus upstream's `MemAvailable ≥ 2 GiB` and `lock!` in `verify_hugepages`.
- **LearnStorage:** our relearn refusal runs **before** upstream's `format_storage`.
- **Migration** renamed `20260412000000_add_generic_provider.rb` → `20260412_add_generic_provider.rb`, inside upstream's date validation.
- **Registration** rejects an IPv4 pool block that contains `--main-ip`; `<main-ip>/32` itself is allowed.
- **Ruby 4.0.7** (`mise.toml`). The bootstrap default is bumped; the test image is `ubi-bundler-m1` (`docker build --target bundler -t ubi-bundler-m1 .`).
- Upstream's read-only **Serial Log** (tab, API, `ubi vm … serial-log`) arrives with the merge, covering C0.

**Known failures inherited from upstream** (they fail identically on pure `origin/main` here):
- `spec/db_spec.rb:189,193` (Rodauth role isolation). Our `ubi-pg-test` superuser is `clover`; upstream CI uses a non-superuser app role.
- `spec/routes/web/admin/model/resource_discount_spec.rb:13`. `resource_discount.name` defaults to `''`, so `admin_label` renders an empty link; this is an upstream bug.

**Upgrading an existing control plane to the merge** (the live AWS one, a planned window):
1. Stop the `puma` and `respirate` tmux sessions. Back up with `pg_dump` and `.env.rb`.
2. Pull the code, install Ruby 4.0.7 via mise, run `bundle install` and `npm ci`, and fix the hard-coded mise Ruby path in PATH.
3. **Before migrating**, exactly once (Sequel aborts on an applied file that no longer exists):
   `UPDATE schema_migrations SET filename='20260412_add_generic_provider.rb' WHERE filename='20260412000000_add_generic_provider.rb';`
4. Delete `~/.ubi-bootstrap/{migrations,caches-refreshed}`. Run `bin/rake-task-runner migrate "" 0`, then `FORCE_AUTOLOAD=1 bin/rake-task-runner refresh_sequel_caches`.
5. Verify:
   - `assigned_host_address` holds only management IPs (upstream 20260731 deletes stale pool rows).
   - The `ipv4_address` count is unchanged.
   - `vm_host_cpu` has `io` and no `spdk`.
   - `host_provider.config` is intact.
   - Put `~/.local/bin` (mise) on PATH first, or `bundle install` fails with "No such file or directory - mise" (live, 2026-10-13).
6. Start the services, then run `VmHost.all.each(&:install_rhizome)` in pry. Existing hosts keep running VMs; recreate VMs only if they need the new rhizome behaviour.
   - **Upgrade vhost-block-backend** on hosts registered before M1: they have v0.2.2, new VMs need `version_code >= 401`, and without it every VM create fails with "No capacity left" (live, 2026-10-13): `VmHost.all.each { Prog::Storage::SetupVhostBlockBackend.assemble(it.id, Config.vhost_block_backend_version, allocation_weight: 100) }`. Resolve the stale "No capacity left" page by hand afterwards.
7. SSH host keys are now TOFU-pinned on first connect. Reinstalling a host's OS requires destroying and re-registering the VmHost.

**Moving a control plane to M4** (after the M3 steps; UNVERIFIED on a live host):
1. `VmHost.all.each(&:install_rhizome)` (F6: the btrfs/ZFS `write_through_device?` rescue reaches existing hosts only this way).
2. For each BYOH host registered before M4, before ever enabling the monitor: `bin/byoh-host relearn-device-ids --host vh...` (shows old → new), then with `--yes` (packaged: `sudo ubicloud-admin run byoh-host ...`). Needs SSH to the host. OPERATIONS.md §7 steps 9-10, §9.
3. BYOH hosts with an NVIDIA GPU: `bin/byoh-host relearn-pci --host vh...`.
4. Hosts learned before M4 keep their CPU rows (offline CPUs included); only re-registration relearns them.

## 8a. M2 network contract (branch `m2-network`)

Plan: WP1–WP10. Runbooks: `docs/byoh/VERIFY.md`, `docs/byoh/POOL_OPERATIONS.md`. Live since 2026-10-13 (VERIFY.md §5).

- **Migration** `migrate/20261013_byoh_network_contract.rb`. **Never rename an applied migration** (a rename is what forced §8 step 3). Its `down` refuses while M2 data exists.
  - **Run `bin/byoh-host export-audit --out backups/audit-<ts>.jsonl` before any `down`**; the guard trusts only the table comment that export writes.
- **Operator CLIs** (each mutation writes a `byoh_operator_action` row):
  - `bin/byoh-location` (create/list/show/set/rates/grant/revoke/delete),
  - `bin/register-byoh-host` (`--location` required, `--pool-file`, `--ipv6-mode`),
  - `bin/byoh-host` (move-location, setup-egress-nat, relearn-device-ids, relearn-pci, export-audit),
  - `bin/byoh-pool` (list/export/add/remove/remap/annotate/ipv6 set/verify/trace),
  - `scripts/byoh/verify/m2-checks` (read-only gate checks) and `m2-gate.sh`. The gate reaches VMs with `ssh -n -o ProxyCommand="ssh root@<host> ip netns exec <inhost> nc %h %p" ubi@<private_ipv4>` (`m2-checks info` prints both), never over IPv6 (§10 #7). Platform knobs: `GATE_IPV6_MODE`, `GATE_EXPECT_MONITOR` (default 0), `GATE_VM_A_EXPOSURE` (nat/public). A moved host's missing register audit row is INFO.
- **Billing overlay:** `BILLING_RATES_EXTRA_DIR` (no `CLOVER_` prefix) in `.env.rb`. **web, respirate and monitor all need it**; restart all three after `byoh-location create --rates-from` or `rates`. Back the directory up with the DB.
- **Gating (C14):** `VmHost#byoh?` = generic provider **and** BYOH location. A generic host still in hetzner-fsn1 behaves exactly like M1.
- **Egress NAT:** the flat prog `prog/setup_byoh_egress_nat.rb` (`Prog::SetupByohEgressNat`, no namespace module) installs `/etc/nftables.d/1-byoh-egress.conf` (table `inet byoh_egress`) on BYOH hosts, or removes it from a host that left BYOH. HostNexus `prep` buds it for BYOH hosts; `bin/byoh-host move-location` starts it for a host past prep (and, with `--rollback-to`, to remove it, after resetting the host's pools to `routed`/`public`); `bin/byoh-location set` starts it on every host past prep when the egress keys change; `bin/byoh-host setup-egress-nat` reinstalls it by hand. The table also has an input chain that drops VM connections to the host's own deny4 addresses.
- **Never `terraform apply` in `company-mumbai` before M7.** The live SG has drifted from `main.tf` and state does not match the live EIPs; build the live pool file with `bin/byoh-pool export --external-map` from `aws ec2 describe-addresses`.

## 9. Secrets and sensitive local files (gitignored — never print or commit)

- `.env.rb` (mode 664 here)
- `backups/**`: DB dumps and control-plane tarballs that contain the AWS `.env.rb`. The README there wrongly says "Nothing sensitive".
- `terraform/aws-byoh/terraform.tfstate*` (the backups hold the TLS private key) and `terraform.tfvars`
- `.claude/settings.local.json`
- Terraform state suggests a messy destroy, and the ad-hoc 10.99 environment (instances + 3 EIPs) has no teardown record. **AWS resources may be orphaned. UNVERIFIED**; check the console.

## 10. Known bugs / discrepancies (fix list)

Code:
1. ~~A management IP inside a declared v4 block enters the VM pool~~: registration rejects such blocks since M1 (configs registered earlier are not re-checked).
2. ~~Network and broadcast addresses of declared blocks are allocatable~~: by design for `routed`/`fabric` (each VM IP is a /32 route); `onlink` pools reserve the segment's network, broadcast and gateway (M2).
3. Every BYOH host lands in hetzner-fsn1 and `data_center` is NULL. M2 fixes the location (`bin/byoh-location`, required `--location`, `bin/byoh-host move-location`); `data_center` is still NULL.
4. The BMC password can be stored in plaintext despite the comment in `byoh_registration.rb`.
5. Hardware Reset without a BMC wedges the strand (`CapabilityMissing` retried forever), and admin "Power On" without a BMC returns a 500. Still open after M1.
6. ~~The leaseweb `setup_ssh_keys` behaviour changed~~: fixed in M1 (only generic hosts skip the root-key bootstrap).
7. Default ULA net6 plus the in-netns `2000::/3` route. **Verified (live, 2026-10-13):** the host cannot reach a VM over IPv6 on a ULA host ("No route to host"), because the VM namespace routes only `2000::/3` back. Reach VMs with `ip netns exec <inhost> nc` instead (VERIFY.md §1.4). Private IPsec between VMs on ULA hosts is likely broken for the same reason (UNVERIFIED).
8. Validation gaps:
   - No IPv4 size/overlap check (more than /24 fails late in `Address#validate`).
   - Host-bit CIDRs are probably silently normalized by NetAddr (UNVERIFIED).
   - Only the first v6 is used.
9. ~~Dead code~~: removed on 2026-10-12.
10. The `host_provider` annotation is missing `config`; the migration name is 14 digits. (RedfishClient timeouts were added on 2026-10-12.)
11. Upstream gap, not ours to fix (U1 forbids changing non-BYOH output): an IPv6-only load balancer accepts a VM without IPv4 on non-BYOH hosts. Report it upstream.

12. **Audit partitions end 2027-01-01** (upstream `migrate/20260331_2026_partitions.rb`, `20260325_authentication_audit_logs.rb`, no DEFAULT partition): every login and audited action fails after that. `bin/byoh-config-check` (so `ubicloud-admin status`) warns under 90 days and fails from 2026-12-02. Fix by merging upstream (which brings 2027 partitions) and deploying before 2026-12-02; no fork migration (it would break the next merge). The live dev control plane has the same deadline (OPERATIONS.md §8).
13. The packaged backup timer never prunes; `ubicloud-admin backup prune --keep N` is manual (OPERATIONS.md §6.1).

Scripts (the development bootstrap; `install.sh` fixes each for packaged control planes, the dev script keeps them for labs):
- The bootstrap DB is named `clover_test` while running in development.
- pg_hba is set to trust.
- Monitor is opt-in (`UBI_START_MONITOR=1`); no restarter.
- Migration markers are permanent.
- `aws-routed-network-setup.sh` (retired; nothing recommends it any more):
  - reads the region before installing aws-cli
  - doesn't install `unzip`
  - assumes a /24 subnet
  - can leak EIPs
- reconfigure:
  - isn't atomic
  - doesn't update net6
  - prints the global pool

Docs: SETUP.md, QUICKSTART.md, SETUP_PROXMOX.md and `docs/providers/generic.md` were rewritten for M2 on 2026-10-13 (the old errors: `--provider`, no location, invented labels and outputs, SPDK/NVMe claims, the route-via-Proxmox-node next hop), and for the M4 commands on 2026-10-15. Still stale: NETWORKING §4 packet walks (AWS values, labelled). SETUP_PROXMOX.md and `docs/byoh/recipes/` have never been run on Proxmox, bare metal or a homelab (UNVERIFIED).

The fork's `docs/byoh/deploy-scripts/` (06f359de4) and `SETUP_PROXMOX_LOWTIER.md` were deleted in M4; `docs/byoh/recipes/proxmox.md` replaces them (git history keeps them).

## 10a. Validated deployment: AWS with nested virtualization (2026-10-11)

**No live environment since 2026-10-15:** the long-lived AWS control plane and data plane were torn down to save cost (backups in `backups/teardown-20261015/`; the test VPC, subnet and key pair remain). Real-machine runs use `scripts/byoh/test/aws-e2e/` (`up.sh`, `ssh.sh`, `down.sh`; everything tagged `Project=ubicloud-byoh-test` and `E2E=<run>`), which creates throwaway instances in that VPC and removes them; run e2e1 (2026-10-16) is VERIFY.md §7. The 2026-10-13 window results are in VERIFY.md §5.

The full flow was proven on non-metal EC2: register → `accepting` in about 4 minutes, VM create and destroy, host reboot recovery, Elastic IP ingress, egress, DNS, apt, and web login.

- **Data plane needs no `.metal` instance.**
  - 8th-gen Intel instances (m8i/c8i/r8i) support `cpu_options.nested_virtualization = "enabled"`, which needs AWS provider ≥ 6.x.
  - m8i.2xlarge (8 vCPU / 32 GiB) gives 4 cores and 26 × 1G hugepages, and runs 2–3 standard-2 VMs.
  - Price is $0.45/hr in ap-south-1, against $5.86/hr for m5d.metal.
  - In `terraform/aws-byoh`: set `data_plane_nested_virtualization = true`.
- **Bug found and fixed in `user-data-data.sh`: cloud-init puts the pool IPs on the host NIC.**
  - The EC2 datasource writes every ENI secondary IP into `/etc/netplan/50-cloud-init.yaml`.
  - The host then answers for the VM IPs itself. `wait_sshable` passes against the host's own sshd, and users get "Permission denied (publickey)" from the host instead of reaching the VM.
  - Fix: `/etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg` (`apply_full_imds_network_config: false`), strip `addresses:` from the netplan, then `ip addr del` with `promote_secondaries=1`.
  - Check after deploy: `ip -br -4 addr` on the data plane must show **only** the primary IP. This survives reboots.
- **Bug found and fixed: guest DNS fails on IPv6-less hosts.**
  - Per-VM dnsmasq forwarded only to IPv6 upstreams.
  - Backported upstream 7191118e6 as 971a3d608: an IPv4 upstream plus a netns SNAT for dnsmasq's port-53 traffic.
  - This affects every BYOH host without IPv6 egress (AWS VPCs, homelabs).
  - Existing VMs converge only on recreate.
- **Updating rhizome on a live host:**
  1. Copy the changed files into the control plane checkout.
  2. Run `VmHost.first.install_rhizome` (it runs the `InstallRhizome` strand).
  3. Recreate the VMs.
- **Creating a UI account without email** (in pry or `ruby -e 'require_relative "loader"'`):
  ```ruby
  require "argon2"
  a = Account.create(email:, status_id: 2)
  DB[:account_password_hashes].insert(id: a.id, password_hash: Argon2::Password.new(secret: Config.clover_session_secret).create(pw))
  a.create_project_with_default_policy("name")
  ```
  `argon2_secret` is the session secret (`clover.rb:749`).
- **Login is two-step:** POST `login`, then POST `login` + `password` with the new `_csrf`.
- **Creating a VM from Ruby:**
  ```ruby
  Prog::Vm::Nexus.assemble(pubkey, project.id, name:, size: "standard-2", location_id: Location["<byoh location ubid>"].id, boot_image: "ubuntu-noble", enable_ip4: true)
  ```
  (This validation ran before M2 with `Location::HETZNER_FSN1_ID`.)
  The VM user is `ubi`.
- **`terraform/aws-byoh` changes:**
  - Provider `~> 6.0`.
  - `web_ui_cidr` variable, so ports 3000/443 are no longer hard-coded to 0.0.0.0/0.
  - Per-workspace key name and `.generated/<workspace>/`.
  - `lifecycle { ignore_changes = [user_data] }`, so editing first-boot scripts never stops a registered host.
  - Use one Terraform workspace plus one `<name>.tfvars` (gitignored) per environment.
  - M4 (files only, never applied, UNVERIFIED): `operator_ssh_cidr` and `web_ui_cidr` are required; `byoh_location_create_command` prints `sudo ubicloud-admin site add ...`; `host_add_command` prints the `get-console-output` fingerprint parse (`--expect-host-key`), the `scp` of `pools.yaml` and the EC2 key, `host add --no-wait && shred -u && host watch`, and an optional step that drops the EC2 key from root's logins. `user-data-data.sh` still copies the EC2 key into root's `authorized_keys` (for `register-byoh-host`) and runs no preflight; `host add` runs it. `docs/byoh/recipes/aws.md`.

## 11. Conventions

- Follow `COMMIT_MESSAGES.md`:
  - imperative subject ≤ ~50 chars, no type prefixes
  - body wrapped at 72 that explains *why*
  - commit messages, not comments, carry design history
- Our branch's `path:` prefixes and the squashed 225ec3604 violate this; don't repeat it.
- Every Ruby file needs `# frozen_string_literal: true`.
- Ask before pushing. Push only to `byoh-fork`, never `origin`.
- Clone repos into the current working directory.
- Never commit lockfile churn from `npm install`; use `npm ci`.
