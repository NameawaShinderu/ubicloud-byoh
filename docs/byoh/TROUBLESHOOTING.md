# BYOH troubleshooting

One Symptom | Cause | Fix catalogue for every platform, in the order things happen: control-plane install, host bring-up, allocation, VM networking, DNS, billing, upgrades, and the monitor. Each row points to the platform guide that has more detail where a platform differs.

It consolidates [NETWORKING.md](NETWORKING.md) §11, the debugging playbook in the repository's `CLAUDE.md` §6, [PLATFORMS.md](PLATFORMS.md) §4 and §7, [VERIFY.md](VERIFY.md) §5 and the "Problems and solutions" tables of the [platform guides](platforms/README.md). Those pages stay the source for design detail.

**Status.** Rows marked "verified live" happened on the AWS deployment (ap-south-1). Everything else is derived from the code and is UNVERIFIED on a real host. Branch differences: the guides describe `m2-network`; the published `byoh-driver` is at 17d383a9c ([platforms/README.md](platforms/README.md) §3). Rows that depend on a later commit name it.

Platform guides: [AWS](platforms/aws.md) · [rented bare metal](platforms/bare-metal-dedicated.md) · [own hardware](platforms/own-hardware.md) · [Proxmox and other hypervisors](platforms/proxmox.md) · [GCP and Azure](platforms/gcp-azure.md) · [other clouds and VPS](platforms/other-clouds-vps.md).

---

## 0. First look

Two control-plane layouts exist ([SETUP.md](SETUP.md) §4). The table gives the development layout (`bootstrap-dev-ctrl-plane.sh`: run from the repository root with mise and Ruby on PATH) and the packaged layout (`install.sh`: run as root through `ubicloud-admin`).

| What | Development | Packaged |
|---|---|---|
| Host strand (the VmHost id is the strand id) | `psql -U clover -d clover_test -c "SELECT prog,label,try,schedule FROM strand WHERE id='<uuid>'"` | `sudo -u postgres psql -d ubicloud -c "..."` (same SQL) |
| Its children (PrepHost, LearnMemory, ...) | `... "SELECT prog,label,try FROM strand WHERE parent_id='<uuid>'"` | as left, through `sudo -u postgres psql -d ubicloud` |
| Host state | `... "SELECT allocation_state,os_version,total_cores,total_hugepages_1g,accepts_slices,net6 FROM vm_host"` | as left |
| Errors | `/tmp/respirate.log` and `/tmp/respirate.err`: look for "exception terminates strand run". Expired deadlines create `page` rows ("has an expired deadline!") | `sudo ubicloud-admin logs respirate --since -1h` (journald); same messages |
| Control plane health | `pgrep -af 'puma\|respirate'` | `sudo ubicloud-admin status` (exits 1 on any fail), `sudo ubicloud-admin smoke` |
| Pools and addresses | `bundle exec bin/byoh-pool list --host vh...`, `verify --host vh...`, `trace <ip>` | `sudo ubicloud-admin run byoh-pool list --host vh...` |
| One VM | `bundle exec scripts/byoh/verify/m2-checks info --vm vm...` (prints `private_ip4=` and `inhost=`) | UNVERIFIED on this layout; `ubicloud-admin console` with `Vm["vm..."]` |
| Reach a VM from the host | `ssh -o "ProxyCommand=ssh -i ~/.ssh/byoh_data root@<main IP> ip netns exec <inhost> nc %h %p" ubi@<private_ip4>` ([VERIFY.md](VERIFY.md) §1.4) | same |
| REPL | `RACK_ENV=development bundle exec bin/pry`, then `VmHost["vh..."]`, `Vm["vm..."]` | `sudo ubicloud-admin console` (not audited) |
| On the host | `ip -br -4 addr` (only the main IP, contract C5), `nft list table inet byoh_egress`, `pgrep -af cloud-hypervisor` (not `pgrep -a`: the name is longer than 15 characters) | same |
---

## 1. Control-plane install

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| `bootstrap-dev-ctrl-plane.sh`: "… does not contain a ubicloud checkout", or the `bootstrap-ctrl-plane.sh` shim: "no ubicloud checkout with scripts/byoh/bootstrap-dev-ctrl-plane.sh" | The script does not clone | `git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud` first (or set `UBI_REPO_DIR`) | |
| `bootstrap-ctrl-plane.sh` warns "is renamed to scripts/byoh/bootstrap-dev-ctrl-plane.sh" | The old name is a shim since M3 | Nothing to fix: it runs the development script. Use the new name, or `scripts/byoh/install.sh` for production | |
| The development bootstrap refuses: "/etc/ubicloud/env exists" or "ubicloud.target is active/enabled", "UBI_RACK_ENV=production", "UBI_DB_NAME=ubicloud" | A packaged control plane lives on this machine, or production settings were passed to a development-only script | Operate the packaged one with `ubicloud-admin`. `UBI_FORCE_DEV=1` overrides the packaged-machine check, for labs only | |
| `bundle install` fails: "No such file or directory - mise" | `~/.local/bin` (mise) not on PATH (verified live, 2026-10-13) | `export PATH=$HOME/.local/bin:$HOME/.local/share/mise/installs/ruby/4.0.7/bin:$PATH` | |
| `bundle` or `ruby -v` uses the system Ruby | mise's Ruby is not on PATH | As above. After a Ruby upgrade, change the version in the path too | |
| `register-byoh-host` aborts with `InvalidOption` on `--provider` | There is no such flag | Use `--location` | Older docs pass it |
| `register-byoh-host`: "--location is required", "no location X", "is not a BYOH location" | No BYOH location yet | `bin/byoh-location create` ([SETUP.md](SETUP.md) §6) | |
| Strands fail with `NetSsh::MissingMock` | `RACK_ENV=test` on a control plane, which disables SSH | Use `RACK_ENV=development`. Never `test` on a control plane, and never `rake setup_database[test]` there: it drops `clover_test`, the deployment database | |
| Boot images never download with `RACK_ENV=production` | In production every image comes from R2/MinIO, which BYOH does not have, unless `BOOT_IMAGE_SOURCE=public` | Development layout: keep `RACK_ENV=development`. Packaged: install.sh sets `BOOT_IMAGE_SOURCE=public` (a production VM boot is UNVERIFIED, [INSTALL.md](INSTALL.md) §7) | |
| No verification email (development) | Mail goes to the logger | Look in `/tmp/puma.log`, not the tmux pane | |
| Email link starts with `http://localhost:9292` or a private IP | `.env.rb` has no `BASE_URL`, or the bootstrap took the first address of `hostname -I` | Set `ENV["BASE_URL"] \|\|= "http://<address you browse to>:3000"` in `.env.rb` and restart `puma`. On a new control plane, `export UBI_BASE_URL=...` before the bootstrap, which writes `BASE_URL` only into a new `.env.rb` | AWS: the private IP ([aws.md](platforms/aws.md) §3.4). 17d383a9c does not write `BASE_URL` at all |
| `byoh-location show` warns "BASE_URL is …; set it to the URL customers use" | `BASE_URL` unset or a localhost address. A private address does not warn | As above | |
| `byoh-location show` warns "CONTROL_PLANE_OUTBOUND_CIDRS includes 0.0.0.0/0, ::/0, so Postgres and Kubernetes firewalls allow SSH from anywhere" | The `config.rb` default `0.0.0.0/0,::/0` | Security setting: `ENV["CONTROL_PLANE_OUTBOUND_CIDRS"] \|\|= "<the --cp-source CIDRs>"` in `.env.rb`, then restart the services (NETWORKING §6.6) | LAN sites: the control plane's LAN IP; off-site: its egress IP ([own-hardware.md](platforms/own-hardware.md) §3.3) |
| Warns "location X: cp_source_cidrs … is not in CONTROL_PLANE_OUTBOUND_CIDRS" | You narrowed the variable and left a `--cp-source` CIDR out | Add that CIDR | |
| UI on port 3000 unreachable | Firewall in front of the control plane | Open 3000 from your address only | AWS: `web_ui_cidr` ([aws.md](platforms/aws.md) §3.10) |
| Packaged: install.sh exits 2 "key X differs; pass the same flags as before, or add --update-env X to change it" | A flag would change a setting install.sh wrote earlier | Pass the same flags as before, or add `--update-env X` to change it on purpose ([INSTALL.md](INSTALL.md) §4.1). `ubicloud-admin env set` refuses the keys a flag owns (`BASE_URL`, `RACK_ENV`, `MAIL_*`, `SMTP_*`), and `BACKUP_*` are not in the env file. For `TLS_FRONT`, the message names every `--update-env` the switch needs | |
| Packaged: install.sh exits 2 "release A is current; switching to B is a release switch" or "release V exists with rev R, not S" | A new `--version` (or a reused one with another commit) | Keep `--version` for reruns; build a new version with `--stage release` and switch ([OPERATIONS.md](OPERATIONS.md) §7) | |
| Packaged: install.sh exits 2 "the current release runs ruby X ... this source wants ruby Y" | Every release shares `/opt/ubicloud/tools` | A Ruby or Node change needs tools per release (M12) | |
| Packaged: install.sh exits 2 "/home/U/.ubi-bootstrap exists, so a development control plane lives on this machine" | The development bootstrap ran here | Move it with `migrate-from-dev.sh` ([MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md)); its `install` phase passes `--no-start` | Live AWS control plane |
| Packaged: install.sh exits 2 "something already listens on port 3000" | Another process (often a tmux puma) holds the web port | Stop it, or install with `--no-start` | |
| Packaged: install.sh dies "database ubicloud has a schema but /etc/ubicloud/env is missing" | The env file, and with it the column key, is gone | Restore it from the secrets backup: `ubicloud-admin restore TS --key-file F --env-only` ([OPERATIONS.md](OPERATIONS.md) §6.3). A new key would make every encrypted column unreadable | |
| Packaged: install.sh dies "the clock is not NTP-synchronized" or "needs about 4 GiB of memory" | Step 1 checks | `timedatectl set-ntp true`; or `--skip-check clock` / `mem` | |
| Packaged: "no caddy package is available" or "something other than caddy listens on port 80 or 443" | `--tls acme\|provided` needs Ubuntu universe and ports 80 and 443 | `add-apt-repository universe`; stop the other web server | |
| Packaged: "cloudflared.service is running or enabled and forwards its tunnel to puma" | A tunnel next to Caddy would let tunnel clients choose `X-Real-IP` | Switch DNS to this machine, `systemctl disable --now cloudflared.service`, rerun | |
| Packaged: smoke warns "caddy has no certificate for HOST yet (curl exit 35 ...)" | Let's Encrypt has not issued yet (UNVERIFIED path) | Public DNS for the host and ports 80 and 443 open; `ubicloud-admin logs caddy` | |
| Packaged: smoke fails "answers HTTP 404 through the tunnel", or warns on 530 / no answer | The tunnel's public hostname does not route to the origin, or no connector is up | In the Cloudflare dashboard route the hostname to `http://127.0.0.1:3000` (not `localhost`, which may be `::1`); `ubicloud-admin logs cloudflared` | Live: the existing `cloudflared.service` is never changed by install.sh |
| Packaged: smoke fails "port 8081 is taken" or "PORT is 8081" | `bin/production_check` starts its own puma on 8081 | Free 8081; never set `PORT=8081` | |
| Packaged: smoke or status fails "bin/byoh-config-check reports failures" | A setting (`MAIL_FROM` unset, http `BASE_URL` in production, a superuser role, partitions ending in under 30 days, ...) | The failing line above it names the key; [OPERATIONS.md](OPERATIONS.md) §2 | |
| Packaged: `psql` or a Ruby tool says "Peer authentication failed for user ..." or "pg_hba.conf rejects connection ... database \"ubicloud\"" | By design: database `ubicloud` takes only peer logins from OS users `ubicloud` (role `ubicloud`), `ubicloud-migrate` (also `ubicloud_password`) and `postgres`; TCP and every other login are rejected | `sudo -u postgres psql -d ubicloud`, or `ubicloud-admin run`/`console`. Never add a trust or password rule for it | |
| Packaged: `status` fails "pg_hba.conf line(s) N use trust for database ubicloud or all" | The development bootstrap's trust lines are still there | Expected on a control plane moved from development until `migrate-from-dev.sh retire`. Elsewhere remove the trust lines | Live AWS control plane after window A |
| Packaged: `status` warns "role(s) clover are superusers that can log in" | The development bootstrap's superuser role | `migrate-from-dev.sh retire` makes it NOLOGIN NOSUPERUSER | |
| Packaged: `bundle exec bin/...` in `~/ubicloud` cannot reach the database | The packaged database takes no logins from your user, and the checkout has no `.env.rb` for it | `sudo ubicloud-admin run <tool> ...` | |
| Packaged: `env set` exits 2 "env set X is refused: ..." | The key is a secret, a flag key of install.sh, or loads code | The message says where to change it ([OPERATIONS.md](OPERATIONS.md) §4.1) | |
| Packaged: `env set` says "web does not answer after 120 s ...; putting the old one back" | The new value stops web from booting | Fix the value; `ubicloud-admin logs web` names the error. The old file is back | |
| Packaged: a service cannot read `BILLING_RATES_EXTRA_DIR` or another path under `/home` | The units run with `ProtectHome=yes` | Keep the rates in `/var/lib/ubicloud/billing_rates.d` | |
| Packaged: `ubicloud-respirate` shows `failed` (status 1 or 143) after a stop or restart | A strand was still running at the stop, or TERM came before respirate's trap | Harmless: the next start clears it, and the strand resumes when its 120 s lease expires ([OPERATIONS.md](OPERATIONS.md) §1.1) | |
| Packaged: a stop of `ubicloud.target` takes up to 100 s | respirate waits for running strands (apoptosis bounds a strand at about 91 s) | Wait; never kill it | |
| `puma` and `respirate` gone after the control plane rebooted | The development bootstrap runs them in tmux; nothing restarts them | `bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh` again: it restarts them and skips finished steps. A packaged control plane (`scripts/byoh/install.sh`) runs them under systemd | |
| Packaged: nothing runs after a reboot; `status` fails "ubicloud.target is not enabled" | The target was disabled (a `migrate-from-dev.sh rollback` does that) | `systemctl enable --now ubicloud.target`, unless you rolled back on purpose | |
| Packaged: web, respirate and monitor refuse to start; `status` names a release hold | `release use --for-restore` holds the services until the restore | `ubicloud-admin restore TS --db-only`, or `release use <newer>` to go back ([OPERATIONS.md](OPERATIONS.md) §7) | |
| No verification email (packaged, production) | `MAIL_DRIVER=logger`: mail goes to the journal | Onboard with `ubicloud-admin account create`; the link is in `ubicloud-admin logs web` ([OPERATIONS.md](OPERATIONS.md) §5, security note) | |

---

## 2. Host bring-up

`ubicloud-admin host add` (or the low-level `bin/register-byoh-host`) creates the host strand. The labels run in this order (generic hosts skip `check_ip_reachability`): `start → setup_ssh_keys → bootstrap_rhizome → prep → wait_prep → setup_hugepages → setup_storage_backend → download_boot_images → wait_download_boot_images → prep_reboot → reboot → [verify_spdk] → verify_hugepages → start_slices → start_vms → configure_metrics → wait`. The host is ready when `allocation_state` is `accepting` (set in `start_vms`). Watch the label in `strand` and the state in `vm_host` (§0); the log does not print `allocation_state`.

### 2.1 Before registration

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| `bootstrap-data-plane.sh`: "/dev/kvm is missing, so KVM is unavailable." or "the CPU has neither the vmx nor the svm flag." | Bare metal: VT-x/AMD-V off in the firmware. VM: no nested virtualization, or a CPU model that hides `vmx`/`svm` | Enable it; power off and on | AWS: m8i/c8i/r8i with `data_plane_nested_virtualization = true`, or `.metal`. Proxmox: `qm set <vmid> --cpu host`. GCP: `--enable-nested-virtualization` on N2/C3. Azure: security type Standard. VPS without KVM: not possible ([other-clouds-vps.md](platforms/other-clouds-vps.md) §1.3) |
| "the CPU lacks the pdpe1gb flag" | Old CPU, or a virtual CPU model that hides 1G pages | Another machine, `--cpu host`, libvirt `host-passthrough`, a newer EVC baseline. A `flexible` profile without hugepages is PLANNED ([COMPUTE.md](COMPUTE.md)) | [proxmox.md](platforms/proxmox.md) "Other hypervisors" |
| "This script requires Ubuntu 24.04 LTS (Noble)." | Another OS or release | Reinstall with 24.04. Only 24.04 accepts VM slices | |
| `register-byoh-host`: "contains main_ip …" | A declared IPv4 block contains `--main-ip` | Declare only the extra block(s); `<main-ip>/32` alone is allowed | Bare metal: never declare the main IP's own subnet |
| "is not globally routable, so it cannot be public" | An RFC 1918 or documentation range declared `public` | `exposure=internal`, or `exposure=nat` with a real external IP. Documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) are refused as public or external | |
| "is nat but has no external IP for …" | A `nat` pool address without an `external` entry | Map it, or `reserve` it | |
| "an IPv4 pool may be at most a /24", "is not a CIDR (address/prefix, no host bits)" | Block too large or with host bits | Split it; write the network address | |
| "an IPv6 pool must be a /64", "at most one IPv6 /64 may be declared" | Registration takes exactly one /64 | Declare one /64 of a /56 or /48. A provider /96 or /128 cannot be declared: register without IPv6 and the host gets a ULA /64 | GCP /96, Kimsufi /128 |
| "overlaps the location's overlay network …", "overlaps the private subnet …" | Pool inside `--overlay` or an existing private subnet | Another range. Overlap with `--underlay` is not checked, but avoid it | |
| "an onlink pool needs segment=<LAN CIDR> and gateway=<LAN gateway>" | `onlink` without `segment`/`gateway` | Add both | |
| Registration fails on a unique index (`sshable.host`, `address.cidr`, `vm_host.net6`) | The same machine or block is registered already | Destroy the old VmHost first (delete its VMs, then `VmHost["vh..."].incr_destroy`). Never delete `location` rows | A reinstalled OS needs this too: host keys are pinned on first connect |
| "WARNING: env var X is not set; BMC reset will fail at runtime" | `--bmc-pass-env` names a variable this shell lacks | Put it in `.env.rb` and restart `puma` and `respirate` **before** registering (§8) | |

### 2.1a Host preflight checks

Host preflight runs in `ubicloud-admin host add` and `host preflight` (with the pools and the control plane's view), in `bin/register-byoh-host --ssh-key`, and standalone at the end of `bootstrap-data-plane.sh`. Each line reads `<status> <check> <detail>` with a fix; statuses are `pass`, `info`, `warn` and `fail`. Any `fail` stops `host add` before it changes the host. The table of checks is [PLATFORMS.md](PLATFORMS.md) §6.2. Only `PF8-hybrid`, `PF10-btrfs` and `PF16-docker`, `-ufw`, `-tailscaled`, `-k3s`, `-libvirtd` can be accepted, with `--accept-check ID` (repeatable; `PF16` accepts all five); any other ID is a usage error (exit 2).

#### PF1

Not Ubuntu 24.04, or not x86_64/aarch64. Reinstall with Ubuntu 24.04 LTS.

#### PF2

The control plane cannot log in as root with the registration key, or root's login runs a forced command. `host add` installs the key itself; a fail after that names the ssh error. Check sshd's `PermitRootLogin` (`sshd -T | grep -i permitrootlogin`), an `AllowUsers`/`DenyUsers` line, and that TCP 22 reaches the main IP from the control plane. With `--expect-host-key`, a host key mismatch also stops here: compare the fingerprints with the console before retrying.

#### PF3

Host preflight (`ubicloud-host preflight`, PLATFORMS.md PF3) fails PF3 for any of three reasons. Each reason needs its own fix, and accepting the failure is not possible (`--accept-check PF3` is refused). PrepHost applies the same rules after registration (`rhizome/host/lib/kvm_check.rb`). A spec runs both on the same fixture hosts.

| PF3 detail | Meaning |
|---|---|
| `no /dev/kvm` | The KVM module is not loaded. Either the firmware has VT-x/AMD-V off, or the machine is a VM without nested virtualization |
| `kvm64-class CPU model (…)` | The VM has a generic CPU model (`kvm64`, `qemu64`, "Common KVM processor", "QEMU Virtual CPU"). That model hides `vmx`/`svm` and the CPU features that x86-64-v2 guests need. The script fails it even when the model adds `vmx` (PrepHost alone would pass it then) |
| `the CPU has neither the vmx nor the svm flag` | `/dev/kvm` exists, but the CPU does not expose hardware virtualization |

Fixes by platform, from the platform guides:

- **Bare metal:** turn on VT-x/AMD-V (and VT-d/AMD-Vi for GPUs) in the firmware, then power the machine off and on.
- **QEMU/KVM, Proxmox, libvirt:** use `qm set <vmid> --cpu host` or libvirt `host-passthrough`, and turn on nested virtualization on the hypervisor host (`kvm_intel nested=1` / `kvm_amd nested=1`). See [proxmox.md](platforms/proxmox.md).
- **Amazon EC2:** use a `.metal` instance, or m8i/c8i/r8i with nested virtualization (`data_plane_nested_virtualization = true` in `terraform/aws-byoh`).
- **Google Cloud:** `--enable-nested-virtualization` on N2/C3 (UNVERIFIED).
- **Microsoft Azure:** a size that supports nested virtualization, with security type Standard (UNVERIFIED).
- **VPS without KVM:** not possible ([other-clouds-vps.md](platforms/other-clouds-vps.md) §1.3).

#### PF4

No `pdpe1gb` CPU flag (x86): 1G hugepages are impossible. Another machine, or a host-passthrough CPU model (`qm set <vmid> --cpu host`, libvirt `host-passthrough`). A `flexible` profile without hugepages is PLANNED ([COMPUTE.md](COMPUTE.md)).

#### PF5

No `/etc/default/grub` or `update-grub`: hugepages are set on the kernel command line through GRUB. Install `grub-pc` or `grub-efi-amd64` and boot with it.

#### PF6

`dmidecode` reports a memory size in an unknown unit. kB/MB/GB/TB are accepted (a0259a997); `info` lines say MemTotal is used when dmidecode is missing or fails. Report the `dmidecode -t 17` output.

#### PF7

Too few 1G hugepages from the memory (fewer than 8 fails, under 16 warns). Give the machine at least 15 GiB of memory; on a hypervisor, turn ballooning and dynamic memory off.

#### PF8

Offline CPUs (`warn`): since M4 a BYOH host uses only online CPUs. `PF8-hybrid` (`fail`, acceptable): performance and efficiency cores, or cores of different speeds. Turn E-cores off in the firmware, or `--accept-check PF8-hybrid` ([recipes/homelab.md](recipes/homelab.md) §2).

#### PF-min-cpu

Fewer than 2 online CPUs. Cannot be accepted. Give the machine more CPUs.

#### PF9

`/sys/fs/cgroup` is not cgroup v2 with the `cpuset` controller. Boot with the unified hierarchy (Ubuntu 24.04's default); remove `systemd.unified_cgroup_hierarchy=0` from the kernel command line.

#### PF10

Too little free space at `/var/storage` (5 GiB + 4 per boot image + VM disks), or a warning that it shares the root filesystem. `PF10-zfs`: refused, cannot be accepted; mount ext4 or xfs at `/var/storage`, or give `host add` a blank disk with `--storage-disk`. `PF10-btrfs`: acceptable; write-through detection does not work on btrfs (rhizome keeps flushes on and logs "assuming a write-back cache"), and VM storage there is UNVERIFIED.

#### PF11

`info`: blank disks that VMs would not use. Pass one to `host add --storage-disk <by-id name>` (the line prints it). A disk with no by-id name needs a serial (a virtual disk) first.

#### PF12

`info`: a storage disk without a `/dev/disk/by-id` link; the kernel name is recorded and can change across reboots. Since M4 the monitor checks of a BYOH host work with it.

#### PF13

`fail`: SMART reports a failing disk. Replace it. `info` when SMART is not available (virtual disks) or smartctl is not installed yet.

#### PF14

`warn`: no stable clocksource (`tsc`, `kvm-clock` on a VM, `arch_sys_counter` on arm64). The monitor would read the host as down.

#### PF15

`PF15-apt`: the archive cannot serve the packages bring-up installs; fix the apt sources (`apt-get update` errors). A `warn` with empty package lists is harmless (PrepHost updates them). `PF15-egress`: GitHub release downloads (github.com and release-assets.githubusercontent.com) or the image mirrors (cloud-images.ubuntu.com over HTTPS, cloud-images-archive.ubuntu.com over HTTP) are unreachable. Open outbound 80 and 443.

#### PF16

`PF16-docker`, `-ufw`, `-tailscaled`, `-k3s`, `-libvirtd` (acceptable): that service manages firewall rules, which rhizome's nftables reload flushes on every VM create and destroy (NH-6). Stop and disable it, or accept. `PF16-pve` (never): the target is a Proxmox node; point `--ssh` at the data-plane VM. `PF16-rhizome-user` (never): a `rhizome` user exists, and bring-up deletes it with its home; use another machine or remove that user yourself.

#### PF17

`PF17` (never acceptable): a pool would hand VMs an address of the host itself: the uplink IP, the main IP or the default gateway (contract C5). Take those addresses out of the pool, or `reserve:` them. `PF17-route`: no default route, several (pass `--uplink-ip`), or an `--uplink-ip` the routes do not use. `PF17-main-ip` (`warn`): `--main-ip` is not on the host, right only when it is a NAT address in front of it. `PF17-uplink` (`warn`): the pools file's `uplink` names another interface than the default route's. `PF17-netplan` (`warn`): cloud-init's netplan gives the uplink several IPv4 addresses, which come back at boot (§4, the C5 row; on AWS the `user-data-data.sh` fix).

#### PF19

`info`: an NVIDIA device whose IOMMU group is not all on `vfio-pci`; the host takes only non-GPU VMs. To offer the GPU, bind the whole group (§3, the GPU row).

#### PF20

The site is not a BYOH location, or a boot image cannot be downloaded for the host's architecture from the source in effect. Create the site with `ubicloud-admin site add`; name a boot image with a public mirror, such as `ubuntu-noble`.

#### PF21

`web` or `respirate` is not active, so a registered host would never be set up. `sudo systemctl start ubicloud.target` (development: start the tmux sessions; the check says `info`).

### 2.2 During bring-up

| Label | Symptom | Cause | Fix | Platform notes |
|---|---|---|---|---|
| `setup_ssh_keys`, `bootstrap_rhizome` | Stuck; pages after the 10-minute deadline to `download_boot_images` | Root SSH from the control plane fails: the key is not in `/root/.ssh/authorized_keys`, `PermitRootLogin` forbids keys, a firewall blocks TCP 22, or there is no route to the main IP (C0) | `ssh -i ~/.ssh/byoh_data -o BatchMode=yes root@<main IP> true` from the control plane must print nothing and exit 0. Install the key, open 22 from `--cp-source` | Rented servers: append the key from the workstation that has root ([bare-metal-dedicated.md](platforms/bare-metal-dedicated.md) §3.4). Ubuntu Server: `sudo` needs a terminal ([own-hardware.md](platforms/own-hardware.md) §3.2). GCP: an admin login and the `byoh-host-ssh` rule ([gcp-azure.md](platforms/gcp-azure.md) §3.1). AWS: user-data installs the key |
| `prep` (PrepHost) | Fails downloading | No outbound internet. PrepHost runs `apt-get` (Ubuntu mirrors over HTTP 80 and HTTPS) and downloads cloud-hypervisor and firmware from github.com, which redirects to `*.githubusercontent.com` | Allow outbound HTTP and HTTPS; `curl -sfI https://github.com` on the host | Azure VNets after 2025-09-30, private OCI subnets and GCP without an external IP or Cloud NAT have no default egress ([gcp-azure.md](platforms/gcp-azure.md) Z3) |
| `prep` (PrepHost) | "/dev/kvm is not a character device, so KVM is unavailable." | No KVM (§2.1) | As §2.1. Registering does not help | |
| `prep` (PrepHost) | "no default route to identify the uplink interface" | No default route when PrepHost pins the uplink by MAC | Fix netplan: a single or multipath default route | |
| `prep` (PrepHost) | `netplan generate` fails after the uplink MAC pin | A VLAN `link:`, bond `interfaces:`, bridge or VRF names the uplink (builds without c73f96ddc, including 17d383a9c) | Tag VLANs on the hypervisor or switch, not on the host; `m2-network` skips the pin | Azure Accelerated Networking: [gcp-azure.md](platforms/gcp-azure.md) Z8 |
| `prep` (LearnMemory) | "BUG: unexpected dmidecode unit …" | 17d383a9c: a DIMM size not in whole GB (common in VMs). `m2-network` (a0259a997): only a unit other than kB/MB/GB/TB | Give the machine a multiple of 1024 MiB and power it off and on; respirate retries, do not re-register. Or run `m2-network` control-plane code and restart `respirate` (LearnMemory is a control-plane prog; no `install_rhizome` needed) | Proxmox: `qm set <vmid> --memory 32768`, then `qm shutdown` and `qm start` |
| `wait_prep` | Host never takes slice VMs | `accepts_slices` is set only on Ubuntu 24.04 | Reinstall with 24.04 | |
| `setup_hugepages`, `verify_hugepages` | "Insufficient memory left for the host OS", "Only N usable 1G hugepages …", "Not enough hugepages for VMs", "Couldn't set hugepage size to 1G" | Too little RAM (hugepages = `GiB*42/43 - 5`, and 2 GiB `MemAvailable` must remain); memory ballooning; no `pdpe1gb`; a GRUB without a `GRUB_CMDLINE_LINUX="..."` line | 16+ GiB, ballooning off, the standard GRUB line (PLATFORMS PF5, PF7) | Proxmox: `--balloon 0`. Hyper-V: no Dynamic Memory. ESXi: full memory reservation |
| `setup_storage_backend` | vhost-block-backend install fails | No egress to github.com | As PrepHost | |
| `download_boot_images`, `wait_download_boot_images` | Waits; pages after the 4-hour deadline to `prep_reboot` | Egress blocked: the pinned Ubuntu releases redirect from `https://cloud-images.ubuntu.com` to `http://cloud-images-archive.ubuntu.com` (plain HTTP, port 80), so HTTPS to the first host alone is not enough. Or `RACK_ENV=production` with `BOOT_IMAGE_SOURCE` unset or `auto` (R2; see the row in §1) | Allow HTTPS to cloud-images.ubuntu.com and HTTP to cloud-images-archive.ubuntu.com (the SHA256 pin keeps HTTP safe); test with `curl -sfIL -o /dev/null -w '%{url_effective}\n'` on the image URL in the strand's error. Packaged layout: `printf public \| sudo ubicloud-admin env set BOOT_IMAGE_SOURCE`, never a switch out of production. Development layout: `RACK_ENV=development` | Same cause for every platform |
| `prep_reboot`, `reboot` | Host does not come back; pages after the 15-minute deadline to `wait` | The host **really reboots**, and netplan, fstab, GRUB, policy routing or `wg0` did not survive it | Rescue or console, fix, power on. The strand resumes once SSH works | Rented servers: rescue system ([bare-metal-dedicated.md](platforms/bare-metal-dedicated.md) row 15). T1/vSwitch: persist `ip rule` ([own-hardware.md](platforms/own-hardware.md) §3.5) |
| after `reboot` | Pool IPs back on the NIC | A cloud agent or cloud-init re-adds them on boot (C5) | `ip -br -4 addr` must show only the main IP; fix the agent (§4) | AWS user-data fix; GCP `instance_configs.cfg`; Azure cloud-init drop-in ([gcp-azure.md](platforms/gcp-azure.md) §3.2) |
| `start_vms` | Host is `accepting` but every VM waits | No boot image, or the wrong one | §3 | |
| `wait` | Host goes `unavailable` and pages | `bin/monitor` health checks: a host registered before M4 with stale disk ids, or a generic host still in hetzner-fsn1 (upstream checks) | §8 | |

### 2.3 `host add`: exit codes, resume and Ctrl-C

| Exit | Meaning | What to do |
|---|---|---|
| 0 | The host accepts VMs and `pool verify` has no FAIL (or `--no-wait` / `--phase prepare` finished) | Nothing |
| 1 | Validation, preflight, host-key or SSH failure, or the host was destroyed while it was being watched ("no longer exists") | Read the `!` line or the `fail` checks (§2.1a). Nothing was registered if it stopped before "Registered host"; a destroyed host is added again with the same command |
| 2 | Usage error: an unknown option, `--accept-check` of a check that cannot be accepted, `--bmc-password`, `--storage-disk` on a host already registered | Fix the command |
| 3 | The watch gave up: a phase took longer than its deadline (bootstrap 10 min, boot image download 4 h, reboot 15 min), respirate is not running, `--timeout` passed, or the host sits outside its bring-up without accepting | The bring-up is not undone. Check §2.2 for the label it stopped at; start respirate if it is down; then resume |
| 4 | `pool verify` failed after the host started accepting | `ubicloud-admin pool verify --host vh...` names the FAIL lines ([POOL_OPERATIONS.md](POOL_OPERATIONS.md)) |
| 130 | Interrupted | See Ctrl-C below |

- **Resume.** Run the same `host add` again. A host already registered at the main IP is not registered twice: the site, pools, settings and host keys must match, and then it only watches. `--storage-disk` is refused then (prep may already be learning the storage). `ubicloud-admin host watch <vh... or main IP>` only watches.
- **Ctrl-C.** Before the root key is installed, nothing on the host changed. During and after the key install, until registration, `host add` prints "To undo the key install on the host: ..." with the `sed` line that removes its tagged key from root's `authorized_keys` and the `rm` of its sshd drop-in; a re-run reuses the same key and replaces the tagged line. **After registration, Ctrl-C stops only the watch: the host strand keeps running and still reboots the host.** To give up on a registered host, delete its VMs and destroy the VmHost (§2.1, the unique-index row).
- **Packaged layout.** `ubicloud-admin host add` runs `byoh-host add` twice, `--phase prepare` then `--phase register`, and deletes its staged copies of `--ssh-key` and `--registration-key` after prepare. Between the two, the registration key waits in `/var/lib/ubicloud/byoh-keys`.
- **"refusing to reach a host under RACK_ENV=test"**: a control plane must never run with `RACK_ENV=test` (it disables SSH); use `development` or `production`.

---

## 3. Allocation: "no space left" and "No capacity left"

The allocator fails with "no space left on any eligible host". The VM sets `waiting_for_capacity`, and after 10 minutes a page says "No capacity left at <location> for <family> family of <arch>". The message does not say which resource ran out; check in this order.

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| **Every** VM create fails with "No capacity left" on a host registered before M1 | The host has vhost-block-backend v0.2.2; new VMs need `version_code >= 401` (`VhostBlockBackend::MIN_ARCHIVE_SUPPORT_VERSION`) (verified live, 2026-10-13) | In `bin/pry`: `VmHost.all.each { Prog::Storage::SetupVhostBlockBackend.assemble(it.id, Config.vhost_block_backend_version, allocation_weight: 100) }`, wait for the strands, then resolve the stale page (§7) | Any host registered before the M1 merge |
| VM never places | Created in the wrong location: the host's BYOH location is the one to use (its UI name); a legacy host not yet moved is still in eu-central-h1 / hetzner-fsn1 | Recreate the VM in the host's location. A hidden location needs `bin/byoh-location grant --location <name> --project pj...` | |
| Internet VM waits | No free `public` or `nat` address | `bin/byoh-pool list --host vh...`; add one (`bin/byoh-pool add`), or create the VM with `-6` or `-e internal` | Single-IP hosts, GCP variant B, Proxmox variant A have none |
| Internal VM waits | No free `internal` address | Add an internal pool | AWS: `byoh_internal_private_ips` |
| VM without IPv4 waits | Not the address: the allocator left-joins free IPv4 and filters on it only for IPv4 VMs. Look at the other rows | | |
| Fresh host takes nothing | No activated boot image of the requested name. The default image is `ubuntu-noble` (`Config.default_boot_image_name`) | `VmHost["vh..."].download_boot_image("ubuntu-jammy")` in `bin/pry` for another image | |
| VM stuck in `creating`; respirate log "failed to allocate cpus" | IO-CPU over-count on small hosts (PLATFORMS #2) | Fewer or smaller VMs; see PLATFORMS §7 | |
| `Sequel::CheckConstraintViolation hugepages_allocation_limit` | Burstable hugepage accounting (PLATFORMS #3) | PLATFORMS §7 | |
| Host never a candidate | `allocation_state` not `accepting` (draining, unavailable) | Fix the cause, then set it back (§8) | |
| Host never a candidate for normal VMs | A legacy generic host (still in hetzner-fsn1) with an NVIDIA GPU in an IOMMU group (VR-4). From M4 a BYOH host takes non-GPU VMs created in its own location, and LearnPci records a GPU only when its whole IOMMU group is on `vfio-pci` | Move the host to a BYOH location (`bin/byoh-host move-location`), or remove the GPU or turn the IOMMU off and re-register. The host's GPU rows were learned under upstream's rule, which keeps a GPU whatever its driver, so a GPU on `nouveau` or `nvidia` would stay offered to GPU VMs, which then fail. On a host past prep `move-location` therefore also starts LearnPci, which drops those rows; check the respirate log for the GPUs it skipped. If the move happened before this, run `bin/byoh-host relearn-pci --host vh...` | [own-hardware.md](platforms/own-hardware.md) §2.2 |
| GPU VMs never place on a BYOH host with an NVIDIA GPU | The GPU, or another function of its IOMMU group (often the HDMI audio on `snd_hda_intel`), is not bound to `vfio-pci`, so LearnPci skipped it. The respirate log says "NVIDIA device not bound to vfio-pci skipped" and names the blocking functions. A GPU outside PCI domain 0000 is skipped too | Bind every endpoint of the group to `vfio-pci` at boot: add `vfio-pci.ids=10de:<gpu>,10de:<audio>` to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, and put `softdep nouveau pre: vfio-pci`, `softdep nvidia pre: vfio-pci` and `softdep snd_hda_intel pre: vfio-pci` in `/etc/modprobe.d/vfio.conf` (a softdep is a modprobe directive, not a kernel parameter). Run `update-initramfs -u` and `update-grub`, and reboot. Prep learns the GPUs once, so then run `bin/byoh-host relearn-pci --host vh...` (packaged: `sudo ubicloud-admin run byoh-host relearn-pci --host vh...`); it also drops idle rows of GPUs that are no longer on `vfio-pci`. UNVERIFIED on real GPU hardware | [own-hardware.md](platforms/own-hardware.md) §2.1 |
| Slice VMs never place on a small host | `accepts_slices` does not match | Scoped fix only: `DB[:vm_host].where(id: <uuid>).update(accepts_slices: false)`; never unscoped | |
| Storage | `available_storage_gib` too low on every enabled `storage_device` | PLATFORMS §7 queries; extra disks only count when mounted at `/var/storage/devices/<name>` before prep; `ubicloud-host storage-disk --by-id <id>` formats and mounts a blank one there | |
| Every VM fails with `RuntimeError "BUG"` in `write_params_json` | Hybrid P+E-core CPU, SMT off on some cores, or offline CPUs (PLATFORMS HW-6, HW-7), on a host whose CPUs were learned before M4 or that is not a BYOH host. Since M4 LearnCpu on a BYOH host keeps only online CPUs and counts every CPU as a core when thread counts differ | Re-register the host in a BYOH location on M4 code (prep learns the CPUs once; `move-location` does not relearn them); otherwise a non-hybrid CPU, SMT on, all CPUs online | Homelab desktops, some rental lines |
| VM prep fails with `Errno::ENOENT` | `/var/storage` on btrfs or ZFS (STOR-5) on a host whose rhizome predates M4 | ext4 or xfs. From M4, rhizome treats a device with no sysfs write-cache entry as write-back (flushes stay on) and logs "assuming a write-back cache"; push it to an older host with `vm_host.install_rhizome` in `bin/pry`. An `ENOENT` naming the VM's disk file itself is a different fault | |
| `ubicloud-host storage-disk` refuses a disk | The disk is not blank (partition, signature, backup GPT, holder, swap, mount), it holds `/`, `/boot` or `/boot/efi`, or it is iSCSI/FC/FCoE, NVMe over fabrics (any NVMe controller transport but `pcie`, or none found) or multipath | The message names the reason. The script never wipes: clear the disk yourself only when you are sure it is unused (`wipefs -a /dev/<disk>`, and `sgdisk --zap-all` for a GPT), or pass `--allow-shared-transport` when only this host writes to the SAN volume. "carries the label ubi-diskN but /etc/fstab does not mount" is either a run cut short before its fstab write (it formatted, then stopped) or a `ubi-diskN` disk that came from another host or lost its fstab line by hand, which may hold VM data. Mount it read-only first (`mount -o ro /dev/<disk> /mnt`); wipe and re-run only when it holds no VM data | |
| VM create fails resolving a billing rate | §6 | | |

---

## 4. VM networking

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| VM create fails: "<ip> is a local address of this host, so the host answers for the VM" (`m2-network`, a092f1b8b) | A pool IP is configured on the host (netplan, cloud-init, a cloud agent, by hand) (C5) | Remove it from netplan and the interface (`ip -br addr`, `ip route show table local`), stop the agent from re-adding it, recreate the VM | AWS: cloud-init fix ([aws.md](platforms/aws.md) §3.3). GCP: guest agent, `proto 66` local routes. Azure: cloud-init secondary ipconfigs. Proxmox: `ipconfig0` |
| SSH to a VM gives "Permission denied (publickey)", or `wait_sshable` passed but customers cannot log in | Same cause on 17d383a9c, or on a VM created before the check; or the wrong user | As above, then recreate the VM. The VM user is `ubi`, not `ubuntu` | Verified live on AWS (2026-10) |
| VM stuck at `wait_sshable`; page after 10 minutes | The control plane cannot reach the address `wait_sshable` dials (C0): with `cp_reach: onhost` the pool IP, with `public` the public or external IP; an internal VM is not dialled | `nc -vz <ip> 22` from the control plane. Use `bin/byoh-location set --location <name> --cp-reach public` when the control plane is off-site, or add the route | O1 with reflection off: use `onhost`. GCP variant A: the control plane needs egress to the forwarding-rule IP ([gcp-azure.md](platforms/gcp-azure.md) G3) |
| VM without IPv4 marked running only after a long wait; log "byoh netns probe gave up" | The netns probe from the host could not reach the VM's SSH within 8 minutes | Check the VM's serial log; reach it through its namespace (§0) | |
| Inbound to a VM's public or external IP times out; its egress works | A filter in front of the host (cloud security group, NSG, provider firewall, router WAN rule), a missing 1:1 mapping, or the address is not routed to the main IP (on-link, or tied to a virtual MAC) | Allow everything to the pool addresses at the edge; restrict only the host's main IP. `bin/byoh-pool trace <ip>` shows the VM and netns commands | AWS: `data_plane_open_ingress = false` by design until `host_guard` ([aws.md](platforms/aws.md) §3.10). Hetzner Robot firewall, OVH vMAC ([bare-metal-dedicated.md](platforms/bare-metal-dedicated.md) rows 5-6). Azure NSG matches the private IP |
| Customer allow-from-CIDR rules never match; VM egress shows the router's IP | Source not preserved (C2): the router masquerades the block, NAT reflection, a port forward | "Do not NAT" rule for the block on the router | [own-hardware.md](platforms/own-hardware.md) O2/C1 |
| VM cannot reach the external IP of another VM at the same site | NAT reflection off; the same-site hairpin is PLANNED (NETWORKING §4.6) | Test from outside the site; split DNS | Router 1:1 NAT sites; AWS EIP from inside the VPC (UNVERIFIED) |
| VM cannot reach the LAN, VPC, NAS or control plane | By design: `deny4` = `--egress-deny` + `--underlay` + `--cp-source` + `--mgmt-allow`. Every VM is dropped toward the host's own `deny4` addresses and the RFC 1918 parts of `deny4`; host-NAT VMs toward all of it (gate G9b) | Expected. `--egress-allow` (`vm_egress_allow`) is stored but nothing reads it yet (PLANNED). The only lever is to leave a range out of those options | |
| VM cannot reach 169.254.169.254, 168.63.129.16, `fd00:ec2::254` or `fd20:ce::254` | By design: platform metadata and services are dropped for every VM on a BYOH host (gate G9; the last three need 9d85a6e3c) | Expected | Azure: keep the DHCP resolver, not Azure DNS ([gcp-azure.md](platforms/gcp-azure.md) Z6) |
| Outbound TCP 25 fails | `egress_smtp` is off by default | `bin/byoh-location set --location <name> --egress-smtp` if you accept the abuse risk | |
| VM without IPv4 or internal VM has no IPv4 egress | Host NAT table missing | `nft list table inet byoh_egress` on the host; `bundle exec bin/byoh-host setup-egress-nat --host vh...` | |
| VM-to-VM private traffic fails | ULA `net6` without cross-host routing (NH-2, OPEN) | `ip -n <inhost> -6 route`; `ip xfrm state` (NETWORKING §7.3) | Every host without a routed global /64 |
| Large transfers hang | Path MTU. Guests always get MTU 1400 from DHCP; `--guest-mtu` is stored but not applied | Check that the guest image did not override it (`ip link` in the VM); keep tunnels (`wg0`) at 1420 or lower | GCP VPC 1460; Hetzner vSwitch VLAN 1400 |
| VM IPv6 dead on an on-link /64 | Declared without `ndp`, or a multipath default route (NDP proxying needs a single-device route) | `bin/byoh-pool ipv6 set --host vh... --cidr <v6>/64,ndp` (empty host only) | OVH ([bare-metal-dedicated.md](platforms/bare-metal-dedicated.md) row 11); BGP hosts: use a routed /64 |
| Internal VMs unreachable from the LAN | Pool inside the router's DHCP range or used by another device (`arping` shows two MACs); a route or VPN covers the pool; stale ARP; a hypervisor IP filter (Proxmox `ipfilter`, libvirt `clean-traffic`) | Shrink DHCP, remove the overlap, clear the router's ARP cache, `firewall=0` on the data plane's NIC | [proxmox.md](platforms/proxmox.md) §4, [own-hardware.md](platforms/own-hardware.md) H1/H2 |
| Docker, ufw, Tailscale or the hypervisor's firewall stop working on the host | `flush ruleset` on every VM create and destroy (NH-6) | Dedicate the host. Never register a Proxmox node or a libvirt host | |

---

## 5. DNS

Each VM's dnsmasq hands out its own address as the resolver and forwards to `8.8.8.8` and `2606:4700:4700::1111` (VMs without any IPv4 path: `2001:4860:4860::8888` and `2606:4700:4700::1111`) (`rhizome/host/lib/vm_setup.rb`).

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| Guest DNS fails on a host without IPv6 egress | VM created before the 971a3d608 backport | Recreate the VM; existing VMs converge only on recreate | AWS, homelab, Proxmox |
| Guest DNS broke after the VM was added to or removed from a load balancer | The load-balancer update rebuilds the netns NAT without the port-53 rules (NETWORKING §4.7, PLANNED fix) | `nft list ruleset` in the netns, look for the `dport 53` SNAT rules; recreate the VM | |
| VMs resolve no names on an office network | The firewall blocks UDP/TCP 53 except to its own resolver | Allow DNS from the host and the pool to the resolvers above. The location's `dns_servers` is stored but not applied | [own-hardware.md](platforms/own-hardware.md) O1/O2 |
| A guest set by hand to the platform resolver (Azure 168.63.129.16, a metadata resolver) gets no answers | Platform services are dropped for VMs (§4) | Keep the DHCP-provided resolver | Azure |
| `getent hosts` works but `apt-get update` fails | Egress, not DNS | §4 | |

---

## 6. Billing and rates

BYOH locations are billed from an overlay directory of rate files (`BILLING_RATES_EXTRA_DIR`, [VERIFY.md](VERIFY.md) §1.1).

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| `byoh-location show` warns "BILLING_RATES_EXTRA_DIR is unset, so web, respirate and monitor do not load the billing rates of BYOH locations" | `.env.rb` lacks the variable (17d383a9c's bootstrap never writes it) | `ENV["BILLING_RATES_EXTRA_DIR"] \|\|= "/home/<user>/ubicloud-billing-rates.d"` in `.env.rb` (an absolute path: Ruby does not expand `~`); restart web, respirate and monitor | |
| VM create fails resolving a billing rate, or invoices cannot be built | A process started without the variable, or before the last `create --rates-from`/`rates`: rates are read once at start | Restart web, respirate and monitor after every `create --rates-from` or `rates` | |
| `show` warns "location X: no billing rate for …"; or reports missing coverage | The rates were written to another directory than the services read | Use the `.env.rb` directory (`show` prints the `Rate file`), rerun `bin/byoh-location rates --location <name> --rates-from hetzner-fsn1`, restart | AWS: terraform before M4 printed `/etc/ubicloud/billing_rates.d`, which no control plane reads; since M4 it prints `ubicloud-admin site add`, which uses the control plane's own directory ([aws.md](platforms/aws.md) §3.5) |
| An `internal` VM has no IPv4 billing record | By design: internal addresses are not billed | Expected | |
| A `nat` VM's IPv4 record is named after the external IP | By design: a `nat` address is billed as `<external IP>/32`, also after `remap` | Expected | |
| Rate ids cannot be resolved after a code rollback | M1 code cannot resolve overlay rate ids | Stay on M2 code while any BYOH billing record exists in the current invoice month ([VERIFY.md](VERIFY.md) §4) | |
| Rates lost after a restore | The overlay directory was not backed up | Back it up with the database ([VERIFY.md](VERIFY.md) §1.3); each `rates` audit row also keeps a copy of the YAML | |

---

## 7. Upgrades and migrations

The full procedure is in `CLAUDE.md` §8 (M1) and [VERIFY.md](VERIFY.md) §3.2 L1 (M2) for the development layout, and the release switch ([OPERATIONS.md](OPERATIONS.md) §7) for the packaged one. These are the steps that failed or nearly failed.

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| `bundle install` fails "No such file or directory - mise" during the upgrade | mise's `~/.local/bin` not on PATH (verified live, 2026-10-13) | Put `~/.local/bin` and the new Ruby's `bin` on PATH **before** `bundle install` | |
| Sequel aborts: an applied migration file no longer exists | The generic-provider migration was renamed in M1 | Once, before migrating: `UPDATE schema_migrations SET filename='20260412_add_generic_provider.rb' WHERE filename='20260412000000_add_generic_provider.rb';`. Never rename an applied migration | Control planes registered before M1 |
| The 20260601 billing migrations abort while closing billing records | A database that kept running pre-merge code past upstream's rate cutoff has open records that start after it, and closing them at the cutoff builds an empty span. Caught in the rehearsal on a dump of the live database | Pull 17d383a9c or later **before** migrating: it rebinds records opened after the cutoff to the new rate. Rehearse every upgrade on a restored `pg_dump` first | Any long-running fork database |
| New migrations are not applied after a pull | `~/.ubi-bootstrap/{migrations,caches-refreshed}` markers are permanent | Delete them, run `bin/rake-task-runner migrate "" 0`, then `FORCE_AUTOLOAD=1 bin/rake-task-runner refresh_sequel_caches` | |
| Every VM create fails with "No capacity left" after the upgrade | vhost-block-backend too old (§3) | `SetupVhostBlockBackend.assemble` per host | Hosts registered before M1 |
| A "No capacity left" page stays open after the fix | Pages are not resolved by the fix | Admin page "Resolve", or `Page.active.where(Sequel.like(:summary, "No capacity left%")).each(&:incr_resolve)` in `bin/pry` | |
| New rhizome behaviour missing on existing hosts | Rhizome code is pushed only on demand | `VmHost.all.each(&:install_rhizome)` in `bin/pry`; recreate VMs that need new VM-setup behaviour | |
| Host egress table missing after `move-location` | The strand that installs it did not finish | `bundle exec bin/byoh-host setup-egress-nat --host vh...` | |
| Migration `down` refuses | M2 data exists (reserved rows, external IPs, non-default delivery or exposure, a profile, an internal VM, or audit rows newer than the export) | `bin/byoh-host export-audit --out backups/audit-<ts>.jsonl` first; follow [VERIFY.md](VERIFY.md) §4 | |
| Packaged: `release migrate` exits 2 naming the backup check | No backup made after web, respirate and monitor last stopped holds the database's migrations | Stop with `systemctl stop ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor` (the target alone can return early), then `backup now`, then `release migrate` | |
| Packaged: `release use` exits 2 "the database has a migration the release lacks" | The downgrade guard: the schema is newer than that release | Restore a backup made before the migration: `release use V --for-restore TS`, then `restore TS --db-only` ([OPERATIONS.md](OPERATIONS.md) §7, Going back) | |
| Packaged: `release migrate` or `use` exits 2 while the services run | Both need web, respirate and monitor stopped | Stop them first | |
| Any layout: `status` or `byoh-config-check` warns "audit_log partitions end 2027-01-01" (fails from 2026-12-02) | Upstream has created audit partitions only to 2027-01-01; inserts fail after that | Merge upstream (which brings 2027 partitions) and deploy it before 2026-12-02 ([OPERATIONS.md](OPERATIONS.md) §8) | |
| SSH to a reinstalled host fails with a host-key mismatch | Host keys are pinned on first connect | Destroy and re-register the VmHost | |

---

## 8. Monitor, reboots and BMC

| Symptom | Cause | Fix | Platform notes |
|---|---|---|---|
| Host flaps to `unavailable`; pages about SMART or the clocksource | Upstream health checks need `wwn-`/`nvme-eui` disk links, SMART and the `tsc` clocksource. Since M4 BYOH hosts have their own checks (PLATFORMS F5), but a host registered earlier keeps its old disk ids (`""`, `root` or a partition), and a generic host still in hetzner-fsn1 keeps upstream's checks. The log names the cause: "has a stale storage device id", "Device X failed its health check" with a reason (a partition id gives "is not a whole disk"), or "unexpected clock source" with the clocksource list and `systemd-detect-virt` | Stale ids: `bin/byoh-host relearn-device-ids --host vh... --yes` ([OPERATIONS.md](OPERATIONS.md) §9). Legacy location: `bin/byoh-host move-location`. Meanwhile stop the monitor (`tmux kill-session -t monitor`; packaged: `systemctl disable --now ubicloud-monitor`, its default state until M9); it is one global process with no per-host switch. Then `VmHost["vh..."].update(allocation_state: "accepting")` in `bin/pry` | The BYOH checks on EBS, GCP PD, Azure, virtio and LVM hosts are tested against fixtures only; the 24-hour soak is UNVERIFIED. A real failing SMART disk still fails, as it should |
| `unavailable` never triggers; VMs stay stopped after a power outage | `bin/monitor` is not running (the bootstrap starts it only with `UBI_START_MONITOR=1`), so the out-of-band reboot is not noticed | Admin **Reboot** of the host: it reboots once more and `start_vms` restarts every VM | Own hardware: "Restore on AC power loss" ([own-hardware.md](platforms/own-hardware.md) §3.10) |
| Host strand stuck at `hardware_reset`; VMs show "rebooting" | Admin "Hardware Reset" on a host without a Redfish BMC raises `CapabilityMissing` and retries forever; or the host had VMs and was not draining ("Host has VMs and is not in draining state") | Never click it without a BMC. A provider-panel or cloud-console reset does not unstick the strand, and no command adds a BMC to a registered host. Recovery (UNVERIFIED): in `bin/pry`, `Strand[VmHost["vh..."].id].update(label: "prep_reboot", try: 0)`. The semaphore was already cleared in `prep_hardware_reset`, so the host reboots over SSH and `start_vms` restarts the VMs. Otherwise destroy and re-register with `--bmc-*` | Cloud hosts never have a BMC |
| Admin "Power On" returns an error | No BMC configured (OPEN) | Power on through the provider panel or by hand | |
| Redfish reset or Power Status fails with an auth error after a control-plane restart | The `--bmc-pass-env` variable is not in the environment of respirate (Hardware Reset) or puma (Power On, Power Status), so the call goes out with a nil password | `ENV["VAR"] \|\|= "..."` in `.env.rb` (mode 600); restart both. Packaged: `sudo ubicloud-admin env set VAR`, which restarts them ([OPERATIONS.md](OPERATIONS.md) §4.2) | |
| BMC discovery: "returned multiple systems; set bmc.system_id explicitly" | The BMC lists several systems | Register with `--bmc-system-id` | |
| A BMC cannot be registered | IPMI only; only Redfish is implemented | Manage power by hand (`ipmitool`, provider panel) | Many rented servers give customers no BMC |
| A reimage is needed | Not supported for generic hosts | Reinstall by hand, then destroy and re-register the VmHost | |
