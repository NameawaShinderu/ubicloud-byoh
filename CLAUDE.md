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
| `docs/byoh/ROADMAP.md` | Master build order M0–M12, the browser console design, the OpenStack feature map, easy deployment, and open decisions D-1…D-13 |
| `docs/byoh/NETWORKING.md` | One host network contract for all platforms (`delivery` routed/onlink/fabric × `exposure` public/nat/internal), `host_guard`, `public_ip4`, real locations |
| `docs/byoh/COMPUTE.md` | Dedicated vs Flexible tiers, custom shapes, overcommit and balloon gates, usage-based placement |
| `docs/byoh/PLATFORMS.md` | Platform compatibility, 54 verified portability findings (F1–F10), host preflight PF1–PF21 |

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
| local `main` | 43a2241e2 (2026-04-10) | this is the merge base; it is 2298 commits behind origin/main |
| local `byoh-driver` | tracks `byoh-fork/byoh-driver` | fast-forwarded to 06f359de4 on 2026-10-11, then 971a3d608 (backported upstream DNS fix, see §10a) |
| `byoh-fork/dependabot/*` | fae63fb24, a20708ee0 | only Gemfile.lock bumps on top of 06f359de4 |
| `origin/main` | fad16215c (committed 2026-10-09) | fetched 2026-10-11 |

- The fork has **no `main` branch**.
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
| `lib/hosting/apis.rb` | M | Adds `DELEGATING_PROVIDERS = [hetzner, generic]`; leaseweb or a nil provider still raises "unknown provider". Also adds `require_relative "base"`. |
| `lib/hosting/base.rb` | A | `Hosting::Base` and `Hosting::CapabilityMissing`, plus an `IpInfo` Struct `(ip_address, source_host_ip, is_failover)`. HetznerApis does **not** inherit from it. |
| `lib/hosting/generic_apis.rb` | A | Driven by config; never calls a remote API (see the methods below). |
| `lib/hosting/redfish_client.rb` | A | Excon client: GET Systems, then the Reset target, then POST ResetType. Sets no timeouts. `set_next_boot_pxe` is unused. |
| `lib/byoh_registration.rb` | A | Validation, `provider_config` builder, keypair handling, and the call to `HostNexus.assemble`. |
| `bin/register-byoh-host` | A | OptionParser CLI with no extension. Defaults RACK_ENV to development. |
| `prog/vm/host_nexus.rb` | M | `assemble` gains `provider_config:` and `ssh_private_key:` kwargs plus a generic branch; `setup_ssh_keys` gets a Hetzner guard. |
| `model/host_provider.rb` | M | Adds `GENERIC_PROVIDER_NAME = "generic"`. The schema annotation was **not** updated for `config`. |
| `migrate/20260412000000_add_generic_provider.rb` | A | Inserts `provider('generic')` and adds `host_provider.config jsonb NULL`. Note the 14-digit name. |
| `config.rb` | M | `generic_connection_string`, `generic_user`, `generic_password` set to `""`. They exist only to satisfy `HostProvider::PROVIDER_METHODS`. |
| `cache/schema.cache` | M | Regenerated binary. |
| `package-lock.json` | M | Accidental churn from `npm install`; package.json is unchanged. Drop it on rebase. |
| `.gitignore` | M | `/backups/` |
| `spec/lib/hosting/{generic_apis,redfish_client}_spec.rb`, `spec/lib/byoh_registration_spec.rb`, `spec/integration/byoh_end_to_end_spec.rb` | A | 71 `it` blocks: generic_apis 28, registration 25, redfish 11, e2e 7. |
| `spec/prog/vm/host_nexus_spec.rb` | M | Adds a "generic (BYOH) provider" block (+10 `it` blocks, 81 in total). |
| `scripts/byoh/bootstrap-ctrl-plane.sh`, `bootstrap-data-plane.sh`, `providers/aws-routed-network-setup.sh`, `README.md` | A | Ops tooling. |
| `scripts/byoh-ops/reconfigure-routed-networks.rb` | A | Swaps a host's IP pool. It destroys the host's VMs. |
| `terraform/aws-byoh/*` | A | VPC 10.98.0.0/16; t3.medium control plane; m5d.metal data plane with `source_dest_check=false`; 3 secondary IPs + EIPs. |
| `docs/byoh/{QUICKSTART,SETUP,SETUP_PROXMOX}.md`, `docs/providers/generic.md` | A | Docs. Many errors; see §10. |

**GenericApis methods** (`lib/hosting/generic_apis.rb`):

- `pull_ips` returns the declared IPv4 `routed_networks`. It prepends a management `/32` unless the management IP is already inside a declared block (`mgmt_covered?`).
- `pull_dc` returns `location_label`; nothing calls it for generic hosts.
- `reimage` always raises `CapabilityMissing`.
- `reset` uses Redfish if a BMC is configured, otherwise raises `CapabilityMissing`.
- `set_server_name`, `add_key`, and `delete_key` are no-ops.
- `bmc_password`:
  - If `password_env` is set, it returns `ENV[that]`, even when that is nil. It does **not** fall back.
  - It uses `bmc.password` only when `password_env` is absent.
  - The env var is checked only at registration, so the respirate process must also have it in its environment.

### Dispatch

`VmHost#{create_addresses,set_data_center,set_server_name,reimage,hardware_reset}` → `Hosting::Apis.*` → whitelist check → `HostProvider#api` → `Object.const_get("Hosting::#{name.capitalize}Apis")`.
The file and class names are load-bearing: `"generic"` must resolve to `Hosting::GenericApis`.

### `host_provider.config` (jsonb)

`{main_ip4, location_label, routed_networks:[{cidr, source_host_ip?, is_failover?}], bmc?:{protocol:"redfish", endpoint, username, password_env|password, system_id?, reset_type?, verify_ssl?}}`

### Registration (one DB transaction in `HostNexus.assemble`)

1. Create the `Sshable` with host = main IP and `raw_private_key_1` = the operator key, preloaded to avoid a race with `setup_ssh_keys`.
2. Create the `VmHost`:
   - `location_id` = **`Location::HETZNER_FSN1_ID`**. The CLI never passes `location_id`, even though `register!(location_id:)` supports it.
   - `family` = "standard"; `ndp_needed` = false.
   - `net6` = the first IPv6 routed network. If none is given, `ByohRegistration` appends a **random ULA /64**.
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

`start → setup_ssh_keys → bootstrap_rhizome → prep → wait_prep → setup_hugepages → setup_storage_backend → download_boot_images → wait_download_boot_images → prep_reboot → reboot → [verify_spdk if SPDK installs exist] → verify_hugepages → start_slices → start_vms → configure_metrics → wait`

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

- The VM must be created in location **`eu-central-h1` / "Germany"** (the hetzner-fsn1 row).
- Host requirements:
  - `allocation_state = 'accepting'`
  - family `standard`
  - architecture matches
  - a `boot_image` with that name and `activated_at` set
  - free hugepages and cores
  - **enabled `storage_devices` rows with enough `available_storage_gib`** (INNER JOIN)
  - `accepts_slices` matches
- **The allocator INNER JOINs `available_ipv4`.** A host with no free `ipv4_address` row is never a candidate, **even for IPv6-only VMs**.
  - So declare at least one real IPv4 block or `/32` besides the management IP.
- `Config.default_boot_image_name` = **ubuntu-jammy**. Either download jammy too, or always pick ubuntu-noble explicitly.
- `enable_ip4` defaults to false.
- Failure message: `"no space left on any eligible host"`. The VM sets `waiting_for_capacity` and pages after 10 minutes.

### Routing model: the operator owns L3

- The driver **never** configures upstream routing.
- On the host, rhizome adds:
  - `ip route replace <vm-ip>/32 dev vetho<vm>` plus proxy_arp
  - netns DNAT public→private, and SNAT only toward non-RFC1918 destinations (`rhizome/host/lib/vm_setup.rb`)
  - the nftables allowed set
- `wait_sshable` TCP-connects **from the control plane to `<vm ip4>:22`**, but only when the VM has IPv4. If it cannot connect, the VM stays at `wait_sshable` indefinitely and pages after 10 minutes.

| Environment | Operator pre-work |
|---|---|
| Real bare-metal providers (Hetzner, OVH, Leaseweb…) | Order a routed block; the provider routes it |
| AWS (shipped tooling) | ENI secondary private IPs, each registered as a `/32`; src/dst check off; 1:1 EIPs (`terraform/aws-byoh` **or** `aws-routed-network-setup.sh`, never both). `--main-ip` = the data plane's **private** IP |
| AWS (alt, `docs/providers/generic.md`) | VPC `create-route <cidr> → ENI` plus src/dst check off. This works **only for a CIDR outside the VPC CIDR**. Commit d1f9ee2d8: 10.99.100.0/29 inside the VPC wasn't routable, so the setup switched to secondary IPs + EIPs |
| Homelab router | Static route for the block → data-plane IP |
| Proxmox as router | `ip route add <cidr> via <data-plane-VM-IP>` + ip_forward on the Proxmox host |
| Same-L2 pool (fork deploy scripts) | Pool `/32`s on the bridge subnet; relies on host proxy_arp (UNVERIFIED) |
| Single IP only | **Does not work today:** zero pool rows means the host is never a candidate |

## 5. Deployment flow (real commands)

### Control plane

Ubuntu 24.04, run as a non-root sudo user.

1. `git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud`
   - **The bootstrap does not clone.** Step 5 exits 1 if the repo is missing.
2. `bash ~/ubicloud/scripts/byoh/bootstrap-ctrl-plane.sh`
   - Env overrides: `UBI_REPO_DIR`, `UBI_RUBY_VERSION` (4.0.2), `UBI_NODE_VERSION` (24.12.0), `UBI_DB_NAME` (**clover_test**), `UBI_RACK_ENV` (development), `UBI_START_SERVICES`.
   - It installs PG16 and creates roles `clover` (superuser) and `clover_password`.
   - It sets **pg_hba to trust** for local and loopback connections.
   - It writes `.env.rb` (chmod 600; never overwritten if it exists) and runs `bin/rake-task-runner migrate "" 0`.
   - It starts tmux sessions **`puma`** and **`respirate`**. Logs go to `/tmp/{puma,respirate}.{log,err}`.
   - Markers live in `~/.ubi-bootstrap/`. The `migrations` and `caches-refreshed` markers are permanent, so **delete them after pulling new migrations**.
   - **`bin/monitor` and `bin/restarter` are not started**, and nothing survives a reboot.
3. Ruby is not on the interactive PATH. `export PATH=~/.local/share/mise/installs/ruby/4.0.2/bin:$PATH`
4. Open the UI at `http://<ctrl>:3000/create-account`. **No admin account is seeded.**
   - The verification email goes to the logger, so look in `/tmp/puma.log`, not the tmux pane.

### Data plane

Ubuntu 24.04 with KVM, outbound internet, and root SSH from the control plane.

- Run `scripts/byoh/bootstrap-data-plane.sh`, or use terraform's `user-data-data.sh`.
  - It does openssh, `PermitRootLogin prohibit-password`, and a ruby-bundler pre-install.
- Put the control plane's **public** key into `/root/.ssh/authorized_keys` **before** registering.
- Do the L3 pre-work from §4.

### Register (on the control plane, from the repo root)

```
RACK_ENV=development bundle exec bin/register-byoh-host \
  --main-ip <v4> --routed-network <v4cidr-or-/32> [--routed-network ...] \
  [--routed-network <v6>/64] --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble [--default-boot-image ubuntu-jammy] \
  [--location <label>] [--server-identifier ID] \
  [--bmc-endpoint URL --bmc-user U --bmc-pass-env VAR [--bmc-system-id ID] [--bmc-reset-type ForceRestart] [--bmc-verify-ssl]] \
  --yes
```

- `--ssh-key` must be an unencrypted OpenSSH Ed25519 key.
- Run the CLI from the repo root with a working `.env.rb`; it loads `db.rb` and `loader.rb`.
- `--location` defaults to `byoh`.
- Terraform: SSH ingress comes from `var.operator_ssh_cidr` (default 0.0.0.0/0), and ports 3000 and 443 are hard-coded open to the world.
- Boot images live only in the strand stack. To add one later, run `vm_host.download_boot_image("name")` in `bin/pry`.

- There is **no `--provider` flag**; passing one aborts with InvalidOption. Several docs still pass it.
- `--location` is only a label in the config. The host still lands in eu-central-h1.
- Without `--ssh-key`, the CLI generates a key and prints the public key to install.
- If any BMC flag is given, `verify_ssl` is forced to false unless `--bmc-verify-ssl` is passed.
- Prefer `--bmc-pass-env`. `--bmc-password` is stored in plaintext in jsonb.
- IPv4 rules:
  - Each block must be ≤ /24 and network-aligned.
  - Keep the management IP **outside** declared blocks.
  - IPv6 must be /64.
- Bring-up to `accepting` takes about 15–25 minutes, including one host reboot.

### Change the IP pool later

`bundle exec ruby scripts/byoh-ops/reconfigure-routed-networks.rb --vm-host-ubid vh… --cidrs a/32,b/32 [--v6 X/64] [--dry-run] [--yes]`

- It **destroys the host's VMs**.
- It does **not** update `vm_host.net6`.
- Omitting `--v6` drops the v6 entry from the config. The `--help` text wrongly says the existing value is kept.

### Re-registering the same IP

- The unique indexes `sshable.host`, `address.cidr`, and `vm_host.net6` will collide.
- Destroy the old VmHost first with `incr_destroy`:
  - `HostNexus#destroy` drains the host and waits until it has **no VMs**, so delete the VMs first.
  - Dependents are destroyed when the strand pops.
  - The generic driver is not called on destroy, so there is no BMC or provider cleanup.
- **Never delete `location` rows.** The row is the shared hetzner-fsn1.

## 6. Debugging playbook

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
| LearnMemory "unexpected dmidecode unit" | Non-GB DIMM sizes (common in nested VMs) |
| `verify_hugepages` fails | Not enough RAM for 1G hugepages |
| VM "no space left on any eligible host" | Wrong location (use eu-central-h1); no activated boot image of that name; no free `ipv4_address`; cores/hugepages; slices mismatch on low-core hosts (scope the fix: `DB[:vm_host].where(id: …).update(accepts_slices: false)`) |
| VM stuck at `wait_sshable` | The control plane can't reach `<vm ip4>:22`. This is a missing operator L3 route, not a driver bug |
| Strand stuck at `hardware_reset` | Admin "Hardware Reset" on a host with no BMC raises `CapabilityMissing` forever (or on a host with VMs that isn't draining); VMs show as "rebooting". **Don't click it** without a BMC |
| Redfish reset fails with an auth error after a control-plane restart | The `--bmc-pass-env` variable is missing from respirate's environment, so the call goes out with a nil password |
| `pgrep -a cloud-hypervisor` shows nothing | The name is longer than 15 chars. Use `pgrep -af cloud-hypervisor` |
| Health / `unavailable` never triggers | `bin/monitor` isn't running |

- **Nested or virtual hosts:** if monitor is started, upstream health checks may mark the host down. They require the `tsc` clocksource and smartctl, and handle `sd*` without wwn badly. UNVERIFIED.

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
docker run --rm --network ubi-test-net -v "$PWD:/app" -w /app -e RACK_ENV=test ubi-bundler sh -c 'apk add --quiet bash openssh-client && bundle exec rspec spec/lib/hosting spec/lib/byoh_registration_spec.rb spec/integration spec/prog/vm/host_nexus_spec.rb'
```

- The containers run as root, so `var/` ends up root-owned.
- The earlier session's results: BYOH specs, 80 examples, 0 failures; a 1911-example subset, 0 failures.
- **The full `rake` (coverage + frozen_spec) has never been run.**
- Upstream's gate is **100% line and 100% branch coverage per file** (`spec/coverage_helper.rb`). Likely failures (UNVERIFIED):
  - the overridden bodies in `lib/hosting/base.rb`
  - several branches in `generic_apis.rb`
  - `scripts/byoh-ops/reconfigure-routed-networks.rb`, which has no spec
  - Use `# :nocov:` or add specs.
- **Spec conventions:**
  - Mock `Sshable#_cmd`, never `#cmd`. `RACK_ENV=test` raises `NetSsh::MissingMock` on real SSH.
  - Use the `hop`/`nap`/`exit` matchers.
  - Run `rake test_up` or refresh caches after a migration.
- **Lint:** rubocop + standard. Multiline literals need trailing commas (`diff_comma`). Our `DELEGATING_PROVIDERS` and `creates_host_provider` arrays likely violate this.
- **Never run `RACK_ENV=test` on a real control plane.** It disables SSH.
- **Never run `rake setup_database[test]` on a control plane.** It drops `clover_test`, which is the deployment DB.

## 8. Upstream drift and rebase plan

Dry merge: `git merge-tree --write-tree --name-only origin/main byoh-driver` reports 7 conflicts:
- `.gitignore`
- `cache/schema.cache` (regenerate it)
- `config.rb` (drop our `generic_*`)
- **`lib/hosting/apis.rb` (modify/delete)**: upstream replaced it with `Hosting::ProviderApis.for(provider)` in ad6bba614
- `package-lock.json` (take theirs)
- `prog/vm/host_nexus.rb`
- `spec/prog/vm/host_nexus_spec.rb`

What has to change:
- **GenericApis must move to the new contract.**
  - Upstream `IpInfo` is `Data.define(:ip_address, :source_host_ip)`, so our `is_failover:` kwarg breaks.
  - `ProviderApis.for` splits `provider_name` on `-`, so the name must not contain `-`.
  - Methods take no server_id: `pull_ips`, `pull_data_center`, `pull_inventory`, `set_server_name(name)`, `reimage`, `hardware_reset`, `power_on`, `power_status`.
  - `IpInfo` needs `host_only?` (`ip == "#{source}/32"`) and `host_connectivity?`. Without them, `create_addresses` raises NoMethodError.
  - `ProviderApis.for` still resolves `"generic"` to `Hosting::GenericApis`.
- **host_nexus conflict trap.** `effective_server_identifier` and `hp.config` sit outside the markers but are defined inside our hunk.
  - Keep our kwargs and our default.
  - Keep upstream's `install_os`.
  - Use `[HETZNER, *LEASEWEB_PROVIDER_NAMES, GENERIC]`.
  - Our setup_ssh_keys guard would skip the bootstrap for leaseweb-eu as well.
- **Migration name.** Upstream rejects numbers outside `20230117..today+5` unless `validate_migration_dates=false` (`bin/rake-task-runner`, bae0347fd, for forks). `20260412000000` is out of range. Either rename it to an 8-digit name (and fix `schema_migrations` on existing DBs) or opt out.
- **Upstream `prep` changes.** It now buds `SetupNdpProxy` (when `ndp_needed`) and `LearnStorage` with `format_storage: install_os`. `install_os` defaults to false; keep it false for generic hosts.
- **New `check_ip_reachability` label.** It runs after `bootstrap_rhizome` and pings 1.1.1.1/8.8.8.8/9.9.9.9 from every host IP and pool IP. On failure it naps 60s and retries forever, paging after 5 failures. This is likely to block private or partial-EIP BYOH pools. Decide on a skip policy.
- **`verify_hugepages` now needs MemAvailable ≥ 2 GiB.** This hurts the low-tier Proxmox setup.
- **SSH host keys are now TOFU-pinned.** Reinstalling a host requires re-registering it.
- **Ruby 4.0.7.** Upstream uses `mise.toml` and has dropped `.tool-versions`. Bump the bootstrap default and the hard-coded mise path.
- **Address semantics changed** (07a15651e): `after_create` no longer fills the pool. The reconfigure script's comments are obsolete.

## 9. Secrets and sensitive local files (gitignored — never print or commit)

- `.env.rb` (mode 664 here)
- `backups/**`: DB dumps and control-plane tarballs that contain the AWS `.env.rb`. The README there wrongly says "Nothing sensitive".
- `terraform/aws-byoh/terraform.tfstate*` (the backups hold the TLS private key) and `terraform.tfvars`
- `.claude/settings.local.json`
- Terraform state suggests a messy destroy, and the ad-hoc 10.99 environment (instances + 3 EIPs) has no teardown record. **AWS resources may be orphaned. UNVERIFIED**; check the console.

## 10. Known bugs / discrepancies (fix list)

Code:
1. A management IP inside a declared v4 block enters the VM pool (`generic_apis.rb` `mgmt_covered?`, `model/address.rb:35`). The spec only checks `assigned_subnets`.
2. Network and broadcast addresses of declared blocks are allocatable.
3. Every BYOH host lands in hetzner-fsn1 and `data_center` is NULL. The `'generic'` provider row is unused. Fix: add a CLI `--location-id` plus a BYOH Location row with billing rates.
4. The BMC password can be stored in plaintext despite the comment in `byoh_registration.rb`.
5. Hardware Reset without a BMC wedges the strand.
6. The leaseweb `setup_ssh_keys` behaviour changed.
7. Default ULA net6 plus the in-netns `2000::/3` route: private IPsec between VMs is likely broken. Inferred, UNVERIFIED.
8. Validation gaps:
   - No IPv4 size/overlap check (more than /24 fails late in `Address#validate`).
   - Host-bit CIDRs are probably silently normalized by NetAddr (UNVERIFIED).
   - Only the first v6 is used.
9. Dead code: `declared_net6`, `capabilities`, `get_main_ip4`, `set_next_boot_pxe`, the `generic_*` Config entries.
10. The `host_provider` annotation is missing `config`; the migration name is 14 digits; RedfishClient has no timeouts.

Scripts:
- The bootstrap DB is named `clover_test` while running in development.
- pg_hba is set to trust.
- No monitor or restarter.
- Migration markers are permanent.
- `aws-routed-network-setup.sh`:
  - reads the region before installing aws-cli
  - doesn't install `unzip`
  - assumes a /24 subnet
  - can leak EIPs
- reconfigure:
  - isn't atomic
  - doesn't update net6
  - prints the global pool

Docs (SETUP.md and SETUP_PROXMOX.md are the least trustworthy; QUICKSTART is the most accurate):
- They pass `--provider generic`.
- They `curl|bash` without cloning first.
- tmux names are `ctrl-plane-*`; the real ones are `puma`/`respirate`.
- `rake db:migrate` (doesn't exist).
- A manual `.env.rb` with a quoted heredoc and missing vars.
- A "Created location" output that never happens.
- The VM location given as the label; it is really eu-central-h1.
- Invented labels, `ubi-spdk.service`, `/var/log/ubi-rhizome`, `/opt/rhizome-host`.
- A broken strand-watch Ruby loop.
- 10.99 vs 10.98 IPs.
- A claim that terraform attaches SSM; it doesn't.
- A dangerous "delete the location row" step.
- A broken `TESTING.md` link.
- Contradictory claims that SPDK/NVMe is required.

Fork deploy-scripts (06f359de4):
- `04` does ctrl→data `ssh ubuntu@` with no key and no `-A`, which blocks `99-deploy-all`.
- `|tee` without pipefail.
- AMD nested check broken.
- Preflight requires 20 GB / 250 GB, contradicting the 16 GB target.
- Env vars aren't forwarded.
- Unscoped `DB[:vm_host].update(accepts_slices:false)`.
- `admin@admin.com` login that nothing creates.
- `reset.sh` destroys VMIDs 400/401/**9000** by number only.
- `--cipassword ubuntu` and `PermitRootLogin yes`.

## 10a. Validated deployment: AWS with nested virtualization (2026-10-11)

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
  Prog::Vm::Nexus.assemble(pubkey, project.id, name:, size: "standard-2", location_id: Location::HETZNER_FSN1_ID, boot_image: "ubuntu-noble", enable_ip4: true)
  ```
  The VM user is `ubi`.
- **`terraform/aws-byoh` changes:**
  - Provider `~> 6.0`.
  - `web_ui_cidr` variable, so ports 3000/443 are no longer hard-coded to 0.0.0.0/0.
  - Per-workspace key name and `.generated/<workspace>/`.
  - `lifecycle { ignore_changes = [user_data] }`, so editing first-boot scripts never stops a registered host.
  - Use one Terraform workspace plus one `<name>.tfvars` (gitignored) per environment.

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
