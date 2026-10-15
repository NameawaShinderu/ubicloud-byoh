# Ubicloud BYOH setup (any platform)

This is the full runbook for a BYOH deployment with the current (M4) code: a control plane, one or more data-plane hosts, a BYOH location, address pools and VMs. The steps are the same on every platform. Only the site network work and the way you create the machines differ, and those are in the platform sections at the end.

| Platform | Status | Where |
|---|---|---|
| AWS EC2 (nested virtualization or `.metal`) | Validated (ap-south-1, 2026-10-11 and 2026-10-13) | This page, §12 "AWS-specific (optional)" |
| Proxmox VE (a VM as the data plane) | UNVERIFIED | [recipes/proxmox.md](recipes/proxmox.md), [SETUP_PROXMOX.md](SETUP_PROXMOX.md) |
| Rented bare metal, colo, homelab, GCP, Azure, other clouds | UNVERIFIED | §13 "Other platforms", [platforms/](platforms/README.md) and NETWORKING §9 |

**The same three commands on every platform (M4):** `install.sh` once, `ubicloud-admin site add` once per site, `ubicloud-admin host add --ssh` once per host. [recipes/README.md](recipes/README.md) lists them; §6 and §8.1 below explain them. The shortest path is [QUICKSTART.md](QUICKSTART.md). Per-platform guides: [platforms/README.md](platforms/README.md). Problems: [TROUBLESHOOTING.md](TROUBLESHOOTING.md). The design is in [NETWORKING.md](NETWORKING.md); the platform matrix and host requirements are in [PLATFORMS.md](PLATFORMS.md).

**Two control-plane layouts (M3).** A production control plane is installed with `scripts/byoh/install.sh` ([INSTALL.md](INSTALL.md)) and operated with `sudo ubicloud-admin` ([OPERATIONS.md](OPERATIONS.md)): systemd, database `ubicloud`, settings in `/etc/ubicloud/env`. The development bootstrap (`scripts/byoh/bootstrap-dev-ctrl-plane.sh`: tmux, `clover_test`, `trust`) is for development and labs; the live AWS control plane still runs it until its M3 window ([MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md)). The commands below are written for the development layout (`bundle exec bin/...` in `~/ubicloud`); §4.3 gives the packaged equivalent of each. The packaged layout has run only in the container harness (UNVERIFIED on a real machine).

The previous version of this page was an AWS-console walkthrough written before M2. It passed `--provider generic` (which aborts) and created no location. It is in git history if you need it.

---

## 1. What you build

| Role | Runs | Needs |
|---|---|---|
| Control plane | Postgres, web (`puma`), `respirate`, optionally `bin/monitor`, the operator CLIs | Ubuntu 24.04; SSH to every data-plane host's management IP (contract C0); users reach its HTTPS front (packaged) or port 3000 (development) |
| Data plane (VmHost) | rhizome, cloud-hypervisor, vhost-block-backend, the VMs | Ubuntu 24.04 with KVM; root SSH from the control plane; outbound internet; a dedicated machine or VM |
| BYOH location | One per site: network profile, billing rates, who can use it | `bin/byoh-location` |
| Pools | Addresses VMs get, each with a `delivery` and an `exposure` | `pools.yaml`, `bin/byoh-pool` |

The control plane and the data plane can be on different platforms. The only coupling is SSH from the control plane to each host, and, for `cp_reach: onhost`, from the control plane to the VMs' pool addresses.

---

## 2. Data-plane requirements (every platform)

| Requirement | Check on the host | If missing |
|---|---|---|
| Ubuntu 24.04 LTS, x86_64 | `lsb_release -rs` | Only 24.04 accepts VM slices |
| KVM | `ls /dev/kvm` | Bare metal: enable VT-x/AMD-V. Guest: nested virtualization plus a CPU model that passes `vmx`/`svm` |
| 1G hugepages | `grep -c pdpe1gb /proc/cpuinfo` > 0 | Guest: pass the host CPU model |
| Memory in whole GiB | `sudo dmidecode -t memory \| grep Size:` shows `GB` | On the published `byoh-driver` (17d383a9c), LearnMemory fails "unexpected dmidecode unit". `m2-network` (a0259a997) accepts kB/MB/GB/TB ([platforms/README.md](platforms/README.md) §3) |
| Not a hybrid (P+E core) CPU, SMT on | `lscpu` | Preflight fails `PF8-hybrid`. Since M4 a BYOH host with mixed thread counts counts every CPU as a core, so VMs boot; `--accept-check PF8-hybrid` accepts the uneven core speeds ([recipes/homelab.md](recipes/homelab.md) §2). Offline CPUs are left out (PF8 warns) |
| Outbound internet | `curl -sI https://cloud-images.ubuntu.com` and `curl -sfIL https://cloud-images.ubuntu.com/releases/noble/release-20250502.1/ubuntu-24.04-server-cloudimg-amd64.img` (it redirects to `http://cloud-images-archive.ubuntu.com`, so port 80 too) | PrepHost and boot image downloads fail |
| One uplink address only | `ip -br -4 addr` shows only the main IP | Pool addresses on the NIC steal VM traffic (C5) |
| Nothing else managing nftables | no Docker, ufw, Tailscale, k3s, libvirt | Their rules are flushed on every VM create and destroy (NH-6) |
| Disks | VM disks live under `/var/storage` on ext4 or xfs (ZFS refused, btrfs UNVERIFIED) | Give blank extra disks to `host add --storage-disk <by-id>`, which mounts each at `/var/storage/devices/diskN` before prep; never mount over `/var/storage` afterwards |

Registration reboots the host once and takes it over: it recreates the `rhizome` user, rewrites the sshd config and allocates hugepages. Never register a machine that does anything else, such as a hypervisor node.

Every row above is a host preflight check (PF1-PF21, [PLATFORMS.md](PLATFORMS.md) §6). `host add` runs preflight before it changes anything; `ubicloud-admin host preflight` runs it alone.

Upstream's `bin/monitor` health checks need `wwn-`/`nvme-eui` disk links and SMART, which cloud block storage (AWS EBS) and virtio disks (Proxmox) lack. Since M4 a BYOH host gets checks that allow for that (PLATFORMS.md F5), but the 24-hour soak on EBS, virtio and LVM hosts has not run (UNVERIFIED), so leave the monitor off unless you run it.

---

## 3. Choose the site network shape

Each pool has two attributes (NETWORKING §3):

| `delivery` | How packets for a pool address reach the host |
|---|---|
| `routed` | The upstream router routes the block to the host's main IP. No ARP. |
| `onlink` | The addresses sit on the host's LAN segment; the host answers ARP for them (proxy_arp). Needs `segment` and `gateway`. |
| `fabric` | A cloud SDN delivers addresses assigned to the host's NIC in the cloud API (AWS secondary IPs). |

| `exposure` | What customers see | IPv4 billing |
|---|---|---|
| `public` | The pool address itself, reachable from the internet | yes |
| `nat` | An external IP E that the site 1:1 NATs to the pool address P | yes, named E |
| `internal` | The pool address, reachable only from the site network | no |

A VM without IPv4 needs no pool at all; its outbound IPv4 goes through the host NAT. A VM with **internet** exposure places only on a host with a free `public` or `nat` address. An **internal** VM needs a free `internal` address.

| Site | Typical shape |
|---|---|
| Rented bare metal (Hetzner, OVH, Leaseweb), colo | `routed` + `public` |
| LAN without public addresses (Proxmox, homelab, office) | `onlink` + `internal` |
| LAN behind a router doing 1:1 NAT (pfSense) | `onlink` + `nat` |
| AWS (secondary IPs + EIPs) | `fabric` + `nat` |

The driver never changes upstream routing. Making pool addresses reach the host is the operator's job, and it is the only platform-specific network step.

---

## 4. Control plane

Choose one layout. Both need a fresh Ubuntu 24.04 machine.

### 4.1 Packaged (`install.sh`)

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
sudo bash ~/ubicloud/scripts/byoh/install.sh --version v0.1.0 \
  --source-git ~/ubicloud --ref HEAD \
  --url https://cloud.example.com --tls acme \
  --admin-email ops@example.com --backup-recipient age1...
sudo ubicloud-admin account create --email ops@example.com
sudo ubicloud-admin status
```

`--tls acme` is one of four fronts: use `provided` with your own certificate, `tunnel` with a Cloudflare tunnel, or `none` for `ssh -L` only ([INSTALL.md](INSTALL.md) §3). `install.sh` reaches `byoh-driver` when M3 is merged; until then it is on the unpushed branch `m3-packaging`. Flags, TLS fronts, settings and the production-mode differences are in [INSTALL.md](INSTALL.md). `--rack-env production` is the default and sets `BOOT_IMAGE_SOURCE=public`; no VM has booted in production mode yet (the E1 canary, [INSTALL.md](INSTALL.md) §7), so `--rack-env development` is the cautious choice for a first site. Onboard users with `ubicloud-admin account create`: with the default logger mail driver, verification mail lands in the journal.

### 4.2 Development (`bootstrap-dev-ctrl-plane.sh`, labs only)

As a sudo user (not root):

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
export PATH=$HOME/.local/bin:$HOME/.local/share/mise/installs/ruby/4.0.7/bin:$PATH
cd ~/ubicloud
```

- The script does not clone; clone first. Its old name, `bootstrap-ctrl-plane.sh`, is a shim that runs it.
- It installs Postgres 16, Ruby 4.0.7 and Node 24 via mise, runs `bundle install`, builds assets, writes `.env.rb` with random secrets, `BILLING_RATES_EXTRA_DIR=~/ubicloud-billing-rates.d` and `BASE_URL=http://<first address of hostname -I>:3000` (override with `UBI_BASE_URL`), migrates, and starts `puma` and `respirate` in tmux. Logs go to `/tmp/{puma,respirate}.{log,err}`.
- `~/.local/bin` (mise) must be on PATH for any later `bundle install`. Without it bundler fails with "No such file or directory - mise" (live AWS window, 2026-10-13).
- Set `UBI_START_MONITOR=1` only when PLATFORMS.md says the monitor suits your hosts' disks.
- Keep `RACK_ENV=development`. In `production`, this layout takes boot images from R2/MinIO, which BYOH does not have (the packaged layout sets `BOOT_IMAGE_SOURCE=public` instead). **Never run `RACK_ENV=test` on a control plane**: it disables SSH.
- Known shortcuts in the script: Postgres `pg_hba` is set to `trust` locally, role `clover` is a superuser, the database is named `clover_test`, puma listens on `0.0.0.0:3000` without TLS, and nothing restarts after a reboot. It refuses to run next to a packaged control plane.

The UI is at `http://<control plane>:3000/create-account`. In development the account works at once; no mail is sent for it. Other mail goes to `/tmp/puma.log`; its links start with `BASE_URL` (with an older `.env.rb` that lacks it, `http://localhost:9292`: replace that part with the control plane's URL).

### 4.3 The same commands on both layouts

| Development (in `~/ubicloud`, mise on PATH) | Packaged |
|---|---|
| `packaging/bin/ubicloud-admin --dev site\|host\|pool ...` (or `bundle exec bin/byoh-location`, `bin/byoh-host`, `bin/byoh-pool`) | `sudo ubicloud-admin site\|host\|pool ...` (M4; [OPERATIONS.md](OPERATIONS.md) §4.2a) |
| `bundle exec bin/byoh-location ...`, `bin/byoh-pool ...`, `bin/byoh-host ...`, `bin/register-byoh-host ...` | `sudo ubicloud-admin run byoh-location ...` (and `byoh-pool`, `byoh-host`, `register-byoh-host`). Files such as `--pool-file` and `--ssh-key` are copied for the tool |
| `RACK_ENV=development bundle exec bin/pry` | `sudo ubicloud-admin console` (not audited, [OPERATIONS.md](OPERATIONS.md) §3) |
| Restart: kill the tmux sessions, rerun the bootstrap | `sudo systemctl restart ubicloud.target` |
| `tail -f /tmp/respirate.log` | `sudo ubicloud-admin logs respirate -f` |
| `psql -U clover -d clover_test` | `sudo -u postgres psql -d ubicloud` |
| `ENV["X"] \|\|= "..."` in `.env.rb`, restart | `sudo ubicloud-admin env set X` (restarts) |
| `--bmc-pass-env VAR` with `VAR` in `.env.rb` | `sudo ubicloud-admin env set VAR`, then `--bmc-pass-env VAR` ([OPERATIONS.md](OPERATIONS.md) §4.2) |
| Billing rates in `~/ubicloud-billing-rates.d` | `/var/lib/ubicloud/billing_rates.d` |
| Create an account in the UI | `sudo ubicloud-admin account create --email ...` |
| `scripts/byoh/verify/m2-gate.sh` | Same script; it detects systemd ([VERIFY.md](VERIFY.md) §1.2). Its database steps on a packaged control plane are UNVERIFIED |

---

## 5. Data plane

**With `host add` (§8.1), nothing has to run on the host first.** You need a login with passwordless sudo and your key on it (cloud images: `ubuntu`), and the site network work (§3 and the platform section). `bootstrap-data-plane.sh` is still useful as a check: it ends with the standalone host preflight.

For the low-level `register-byoh-host` path (§8.2), on each host:

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

This enables root public-key login and installs `ruby-bundler` and `netcat-openbsd`. It does not touch the network.

On the control plane, create the host key and install its public half as root on the host:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
ssh <admin user>@<host main IP> "sudo tee -a /root/.ssh/authorized_keys" < ~/.ssh/byoh_data.pub
ssh -i ~/.ssh/byoh_data root@<host main IP> true && echo ok
```

`--ssh-key` must be an unencrypted OpenSSH Ed25519 key. Without `--ssh-key`, `register-byoh-host` generates one and prints its public key.

Then do the site's network work (§3, and the platform section).

---

## 6. Create the BYOH location (once per site)

```bash
sudo ubicloud-admin site add <site> --display "<Name shown to customers>" \
  --underlay <site LAN and management CIDRs> --overlay 172.20.0.0/14 \
  --cp-reach onhost|public --cp-source <control plane IP as the site sees it>/32 \
  --mgmt-allow <who may manage the hosts> --rates-from hetzner-fsn1
```

`site add NAME` is `byoh-location create --name NAME` (`--display` is `--ui-name`), and it restarts `ubicloud.target` when it wrote a rate file. Until M8 `--mgmt` takes only `direct` and `--cp-reach mgmt` is refused; `--postgres` takes only `no`. On the development layout, the same through `packaging/bin/ubicloud-admin --dev site add ...`, or:

```bash
bundle exec bin/byoh-location create --name <site> --ui-name "<Name shown to customers>" \
  --underlay <site LAN and management CIDRs> \
  --overlay 172.20.0.0/14 \
  --cp-reach onhost|public \
  --cp-source <control plane IP as the site sees it>/32 \
  --mgmt-allow <who may manage the hosts> \
  --rates-from hetzner-fsn1
```

| Option | Meaning |
|---|---|
| `--underlay` | The site's own networks. VMs may not open connections into them through the host NAT. |
| `--overlay` | RFC 1918 range customer private subnets are drawn from; must not overlap the underlay |
| `--cp-reach` | `onhost`: the control plane is on the site network and dials VMs at their pool address. `public`: it dials internet VMs at their public address, and probes the others from inside their namespace on the host. |
| `--ula48` | Generated at random. Pass one only to fit an existing host's `net6`. |
| `--rates-from` | Copies every billing rate of an upstream location into `$BILLING_RATES_EXTRA_DIR`; `--multiplier` scales them |

On the development layout, restart `puma` and `respirate` (and `bin/monitor`, if it runs) so they load the rates, then check with `bundle exec bin/byoh-location show --location <site>`. The location stays hidden until `set --visible`. Give your project access after you create your account (§9):

```bash
bundle exec bin/byoh-location grant --location <site> --project <project ubid>
```

---

## 7. Write pools.yaml

A hand-written file is the normal case on every platform. Format and rules: [POOL_OPERATIONS.md](POOL_OPERATIONS.md) §1.

```yaml
version: 2
uplink: eth0                  # informational
routed_networks:
  - cidr: 5.9.10.0/29         # a routed block on rented bare metal
    delivery: routed
    exposure: public
  # - cidr: 10.80.0.200/29    # a LAN pool: see SETUP_PROXMOX.md
  #   delivery: onlink
  #   exposure: internal
  #   segment: 10.80.0.0/24
  #   gateway: 10.80.0.1
  # - cidr: 2a01:db8:1:2::/64 # optional routed IPv6 /64; without one the host gets a ULA /64
```

- The main IP is never inside a pool.
- IPv4 pools are /24 or smaller, with no host bits.
- A `nat` pool needs a globally routable external IP for every usable address: `external: {P: E}` or `external_cidr`.
- External IPs can come from any source. Write them by hand, or pass a YAML map `{P: E}` to `bin/byoh-pool export --external-map` (POOL_OPERATIONS §2.1).

---

## 8. Add the host

### 8.1 `host add` (M4)

```bash
sudo ubicloud-admin host add --site <site> --ssh <user>@<host main IP> \
  --ssh-key <your login key> --pool-file pools.yaml \
  [--registration-key ~/.ssh/byoh_data] [--storage-disk <by-id>] [--accept-check PF8-hybrid]
```

(development: `packaging/bin/ubicloud-admin --dev host add ...` from `~/ubicloud`, without `sudo`.)

1. It checks the site, the pools and the control plane's services (PF20, PF21), then logs in as `<user>` and runs host preflight as root with the script sent on stdin: read-only, nothing is copied to the host. Any `fail` stops it before a change. [recipes/README.md](recipes/README.md) lists which fails `--accept-check` can accept.
2. It reads the host's SSH host keys over that login, shows them as SHA256 fingerprints with the list of changes, and asks for a typed `yes`. `--yes` skips the question; `--expect-host-key SHA256:...` (repeatable) checks the key ssh met instead, for scripts.
3. It installs its registration key for root on a tagged line, and writes `/etc/ssh/sshd_config.d/05-ubicloud-root.conf` only if sshd does not already let root log in with a key. Then it logs in as root with that key, pinned to the host keys (PF2).
4. It formats each `--storage-disk`, registers the host pinned to the host keys, and follows the bring-up (one reboot) until the host accepts VMs, then runs `pool verify`.

`--main-ip` defaults to the `--ssh` host when that is an IPv4 address; `--uplink-ip` names the uplink when there are several default routes; `--default-boot-image` (repeatable) replaces `ubuntu-noble`. Without `--registration-key` the key is generated and kept only in the database. Exit codes, resume and Ctrl-C: [TROUBLESHOOTING.md](TROUBLESHOOTING.md) §2.3. `sudo ubicloud-admin host preflight` (same `--site`, `--ssh`, `--ssh-key` and pools) runs step 1 alone.

### 8.2 `register-byoh-host` (low level)

For a host whose root login you set up yourself (§5):

```bash
bundle exec bin/register-byoh-host \
  --location <site> \
  --main-ip <host management IPv4> \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --yes
```

Other options: `--routed-network CIDR[,key=value...]` (inline pools, repeatable), `--ipv6-mode gua|ula`, `--server-identifier`, `--default-boot-image` (repeatable; `ubuntu-noble` when none is given, which is also the image of a VM that names none; add `ubuntu-jammy` only if customers will pick it), and the Redfish BMC flags (`--bmc-endpoint`, `--bmc-user`, `--bmc-pass-env`, …). There is no `--provider` flag.

**Preflight.** Once the registration key is in root's `authorized_keys` (given with `--ssh-key`, or generated and confirmed with ENTER), the command logs in as root with it and runs host preflight (`scripts/byoh/host/ubicloud-host`, checks PF1-PF21 in `docs/byoh/PLATFORMS.md`):

- PF2 (root login runs commands) comes first. The script then runs over the same connection, sent on stdin, so nothing is copied to the host and nothing on it changes.
- Any `fail` stops the command before anything is registered, for example no `/dev/kvm`, a kvm64-class CPU model, or a pool that holds the host's uplink IP or default gateway.
- `--accept-check ID` (repeatable) accepts one of the few fails that are a choice rather than a defect: `PF8-hybrid`, `PF10-btrfs` and the `PF16-*` firewall services other than `PF16-pve` and `PF16-rhizome-user`. Any other ID is a usage error (exit 2).
- `--skip-preflight` registers without checking.
- The host keys this login met are pinned, so the control plane's first root login during bring-up must meet the same key.
- The uplink IP (the source address of the default route) is stored as `uplink_ip` in the host's provider config. `--uplink-ip IP` sets it instead, for a host with more than one default route. No pool may hand it to VMs.

Without `--ssh-key` the command generates the key and waits for ENTER while you install it, then runs preflight as above. If preflight fails, the generated key is not kept: remove its line from `authorized_keys` before you run the command again, which prints a new key. With a generated key and `--yes` nothing confirms the install, so the command warns and registers without preflight; to check such a host, run `scripts/byoh/host/ubicloud-host preflight` on it.

Bring-up takes 15-25 minutes on bare metal and about 4 minutes on a nested-virtualization cloud VM. It **reboots the host once**. Watch it:

```bash
tail -f /tmp/respirate.log
psql -U clover -d clover_test -c "SELECT allocation_state, os_version, total_cores, total_hugepages_1g FROM vm_host"
# packaged:
sudo ubicloud-admin logs respirate -f
sudo -u postgres psql -d ubicloud -c "SELECT allocation_state, os_version, total_cores, total_hugepages_1g FROM vm_host"
```

The host is ready at `allocation_state = accepting`. Then check its pools and its NAT table:

```bash
bundle exec bin/byoh-pool verify --host vh...                                  # no FAIL lines
ssh -i ~/.ssh/byoh_data root@<main IP> nft list table inet byoh_egress        # loaded
ssh -i ~/.ssh/byoh_data root@<main IP> ip -br -4 addr                         # only the main IP
```

---

## 9. Create VMs

1. Create an account in the UI (packaged: `sudo ubicloud-admin account create`), then `bin/byoh-location grant` its project (§6).
2. Add an SSH public key.
3. Create a VM in the BYOH location (its UI name). With IPv4 enabled, pick **IPv4 Exposure**: `internet` (a `public` or `nat` address) or `internal`.

CLI equivalents, where the path uses the location's display name. By default `ubi` talks to Ubicloud's hosted service, and the API answers only on a host name that starts with `api.`. So first (UNVERIFIED against a BYOH control plane):

1. Create a token on the project's **Personal Access Tokens** page (`/project/pj…/token`).
2. Map an `api.` name to the control plane where you run `ubi`, for example `echo "<control plane IP> api.byoh.internal" | sudo tee -a /etc/hosts`.
3. `export UBI_TOKEN=pat-... UBI_URL=http://api.byoh.internal:3000/cli`

```bash
ubi vm <site>/vm1 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"                # internet IPv4
ubi vm <site>/vm2 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"    # internal IPv4
ubi vm <site>/vm3 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"             # no IPv4
```

The VM user is `ubi`.

---

## 10. Gate

`scripts/byoh/verify/m2-gate.sh` checks the result. [VERIFY.md](VERIFY.md) §1.4 lists its settings; the defaults fit any platform:

- VMs are reached through their namespace on the host (`ip netns exec <inhost> nc <private ipv4> 22`), which works with ULA hosts.
- The IPv6 mode is checked only when `GATE_IPV6_MODE` is set.
- `bin/monitor` is required only with `GATE_EXPECT_MONITOR=1`.
- VM-A may be `nat` or `public` (`GATE_VM_A_EXPOSURE`). Behind a router doing 1:1 NAT without NAT reflection, set `GATE_EXTERNAL_SSH_VIA` to a host outside the site, or G6's SSH to the external IP fails by design.
- A site without internet pools runs `g1 g2 g3 g4 g5 g7 g8 g9 g9b`.

---

## 11. Operating

| Task | How |
|---|---|
| Change pools | `bin/byoh-pool` `add`, `remove`, `remap` or `annotate` (POOL_OPERATIONS.md); no re-registration |
| Add a boot image | `VmHost["vh..."].download_boot_image("ubuntu-jammy")` in `bin/pry` (packaged: `ubicloud-admin console`) |
| Push new rhizome code | `VmHost.all.each(&:install_rhizome)` in `bin/pry` (packaged: `ubicloud-admin console`) |
| Back up the control plane | Packaged: nightly timer, `ubicloud-admin backup now`, restore drill ([OPERATIONS.md](OPERATIONS.md) §6). Development: `pg_dump` as postgres plus `.env.rb`, by hand |
| Remove a host | Destroy its VMs, then `VmHost["vh..."].incr_destroy`. Never delete `location` rows by hand. |
| Re-register the same machine | Destroy the old VmHost first (`sshable.host`, `address.cidr` and `vm_host.net6` are unique). A reinstalled OS also needs this, as host keys are pinned on first connect. |
| Upgrade the control plane | Packaged: the release switch, [OPERATIONS.md](OPERATIONS.md) §7. Development: CLAUDE.md §8 and VERIFY.md §3.2 L1. A host registered before M1 needs the vhost-block-backend upgrade, or every new VM fails with "No capacity left". |
| Hardware reset | Only with a BMC. Without one, admin "Hardware Reset" wedges the host strand. |

Troubleshooting for all platforms is in [TROUBLESHOOTING.md](TROUBLESHOOTING.md); the most common causes:

| Symptom | Cause |
|---|---|
| Stuck at `bootstrap_rhizome` | Root SSH from the control plane fails |
| PrepHost fails | No outbound internet |
| VM waits for capacity | No free address of the requested exposure; boot image missing; wrong location; too few cores or hugepages; host registered before M1 without the vhost-block-backend upgrade |
| VM stuck at `wait_sshable` | `cp_reach: onhost` but the control plane cannot reach the pool address |

---

## 12. AWS-specific (optional)

Everything in this section applies only to AWS. Nothing in the driver reads it.

| AWS-only piece | What it does | Notes |
|---|---|---|
| `terraform/aws-byoh` | VPC, control plane, data plane, ENI secondary IPs with EIPs, `.generated/<workspace>/pools.yaml` (`fabric` + `nat`) and the `byoh_location_create_command` output | One workspace and one `<name>.tfvars` (gitignored) per environment. Stale defaults: `data_plane_instance_type = m5d.metal` and `data_plane_nested_virtualization = false`. Set an m8i/c8i/r8i type with nested virtualization instead. `web_ui_cidr` limits ports 3000/443. |
| Cloud-init secondary-IP fix (C5) | `user-data-data.sh` sets `apply_full_imds_network_config: false`, strips `addresses:` from the netplan and removes the secondary IPs with `promote_secondaries` | Without it, the EC2 datasource puts every pool IP on the NIC. The host then answers for the VMs, and `wait_sshable` passes against the host's own sshd. After deploy, `ip -br -4 addr` must show only the primary IP. Other platforms' cloud-init (Proxmox `ipconfig0`) sets only the main IP. |
| EIPs as `--external-map` | `aws ec2 describe-addresses --output json > eips.json`, then `bin/byoh-pool export --set delivery=fabric,exposure=nat --external-map eips.json` | Use `describe-addresses` for a live host, not terraform output. The YAML map form works everywhere. |
| Nested-virtualization instance types | m8i/c8i/r8i with `cpu_options.nested_virtualization = "enabled"` (AWS provider ≥ 6) | m8i.2xlarge: 4 usable cores, 26 × 1G hugepages, 2-3 `standard-2` VMs, about $0.45/h in ap-south-1. `.metal` types also work. |
| IMDS | The host NAT table drops VM traffic to `169.254.0.0/16` on every platform (gate G9). On AWS also set IMDSv2 with hop limit 1 (`http_tokens = "required"`, `http_put_response_hop_limit = 1`) | The terraform setting is PLANNED (NETWORKING §9.1) |
| `--main-ip` | The data plane's **private** IP | Pool IPs are other ENI secondary IPs; never the primary |
| `bin/monitor` | Do not run for EBS-backed hosts | EBS has no SMART and only `nvme-Amazon_Elastic_Block_Store_*` links |
| Retired | `scripts/byoh/providers/aws-routed-network-setup.sh` (broken: cloud-init puts pool IPs back, EIP leak); VPC route-table routes for CIDRs inside the VPC | Use terraform |

The terraform flow, step by step, is in [QUICKSTART.md](QUICKSTART.md).

---

## 13. Other platforms

Each platform has a guide in [platforms/](platforms/README.md), which also has a chooser table and the common six-step flow. Problems on every platform: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

| Platform | delivery + exposure | Guide | Status |
|---|---|---|---|
| Proxmox VE guest, no public block | `onlink` + `internal` | [platforms/proxmox.md](platforms/proxmox.md), [SETUP_PROXMOX.md](SETUP_PROXMOX.md) §6.2 | UNVERIFIED |
| Proxmox behind pfSense with extra public IPs | `onlink` + `nat` | [SETUP_PROXMOX.md](SETUP_PROXMOX.md) §6.3 | UNVERIFIED |
| Proxmox, ISP block routed by the router | `routed` + `public` | [SETUP_PROXMOX.md](SETUP_PROXMOX.md) §6.4, NETWORKING §9.2 variant C | UNVERIFIED |
| Other hypervisors (libvirt, ESXi, Hyper-V, XCP-ng) | as Proxmox | [platforms/proxmox.md](platforms/proxmox.md) "Other hypervisors" | UNVERIFIED |
| Homelab or office behind a router | `onlink` + `internal`, `routed` via a static route, `onlink` + `nat` (1:1 NAT) | [platforms/own-hardware.md](platforms/own-hardware.md), NETWORKING §9.3 | UNVERIFIED |
| Single IP or CGNAT, internet ingress needed | `routed` (WireGuard) + `public` | [platforms/own-hardware.md](platforms/own-hardware.md) §3.5 T1, NETWORKING §9.4 | PLANNED |
| Hetzner, OVH, Leaseweb | `routed` + `public` (vSwitch: `onlink`) | [platforms/bare-metal-dedicated.md](platforms/bare-metal-dedicated.md), NETWORKING §9.5 | UNVERIFIED with BYOH |
| Colo with BGP or static routes | `routed` + `public` | [platforms/own-hardware.md](platforms/own-hardware.md) §3.5 C1-C3, NETWORKING §9.6 | UNVERIFIED |
| GCP | `routed` (protocol forwarding) + `public`, or `fabric` + `internal` | [platforms/gcp-azure.md](platforms/gcp-azure.md), NETWORKING §9.7 | UNVERIFIED |
| Azure | `fabric` + `nat` | [platforms/gcp-azure.md](platforms/gcp-azure.md), NETWORKING §9.8 | UNVERIFIED |
| OCI, Scaleway, Vultr, OVHcloud Public Cloud, DigitalOcean; VPS without KVM | `fabric` + `nat`, `routed` + `public`, or none | [platforms/other-clouds-vps.md](platforms/other-clouds-vps.md) | UNVERIFIED |
| AWS | `fabric` + `nat` | [platforms/aws.md](platforms/aws.md), §12, NETWORKING §9.1 | Validated |
