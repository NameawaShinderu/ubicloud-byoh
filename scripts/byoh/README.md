# BYOH bootstrap scripts

Reproducible scripts for standing up the Ubicloud control plane and BYOH
data plane on any Ubuntu 24.04 LTS host. Nothing in them is specific to
a platform. They were run on AWS only; on other platforms they are
UNVERIFIED. The full runbooks are `docs/byoh/SETUP.md` (any platform)
and `docs/byoh/SETUP_PROXMOX.md` (a Proxmox VM as the data plane).

## The two roles

A Ubicloud BYOH deployment needs two kinds of Linux hosts:

| Role | What runs on it | Who runs this script | Script |
|---|---|---|---|
| **Control plane** | Postgres, clover (Roda/Puma), respirate dispatcher, `bin/register-byoh-host` CLI, web UI | You, once per deployment | `bootstrap-ctrl-plane.sh` |
| **Data plane** | rhizome agent + vhost-block-backend + cloud-hypervisor + the VMs themselves | You, once per BYOH host you want to add | `bootstrap-data-plane.sh` |

The control plane and data plane can be:
- **Same host** (single-machine lab) — run both scripts on the same box
- **Different hosts, same provider** (e.g. both in AWS Mumbai VPC) — what we have now
- **Different providers** (e.g. control plane in Hetzner Falkenstein, data plane on your Proxmox in your homelab) — the real BYOH use case

The control plane reaches the data plane over SSH; that's the only
coupling. No shared network is required as long as the control plane
can `ssh root@<data-plane-host>`.

## Prerequisites

- Target OS: **Ubuntu 24.04 LTS (Noble)**. Other Debian-derivatives may
  work but are unverified. Rocky/Alma/Fedora will not without porting.
- A copy of this ubicloud repo accessible to the target host (either
  cloned via git, or scp'd as a tarball).
- Sudo-capable user account on the target host.
- Outbound internet for apt + rubygems + npm + ubuntu image downloads.

## Packaged control plane (`install.sh`, M3, in progress)

`install.sh` installs the control plane as root-owned releases under
`/opt/ubicloud`, run by systemd as user `ubicloud`, with database
`ubicloud` on peer authentication and settings in `/etc/ubicloud/env`.
It is safe to re-run and keeps no marker files. `--tls` takes `acme`,
`provided`, `tunnel` or `none`. The migration from the development
bootstrap comes later in M3, so the live control plane keeps using
`bootstrap-ctrl-plane.sh` for now. It has run only in the container
harness (`scripts/byoh/test/`); on a real machine it is UNVERIFIED.

```bash
sudo bash scripts/byoh/install.sh --version v0.1.0 --url http://localhost:3000 \
  --tls none --admin-email ops@example.com --source-git ~/ubicloud --ref HEAD \
  --backup-recipient age1...
```

`bash scripts/byoh/install.sh --help` lists every flag.

The last step runs `ubicloud-admin smoke` (skipped with `--no-start`).
It checks that puma answers, that the front's unit (caddy, or the
cloudflared unit) runs and the front answers, that web and respirate
run, and that `bin/byoh-config-check` reports no fail. With
`RACK_ENV=production` it also runs `bin/production_check`, whose own
puma needs port 8081: `PORT` must not be 8081 (install.sh and
`ubicloud-admin env set PORT` refuse it). If any check fails, install.sh
exits 1 and points at `ubicloud-admin logs`. Two cases only warn,
because both come up in the background: an `acme` certificate that
caddy has not got yet (the TLS handshake fails), and a tunnel that has
not connected yet (cloudflared still starting, no answer, or
Cloudflare's HTTP 530). A stopped front fails. Smoke changes no setting
and no unit, but its two checks boot the app as `ubicloud`, which
rewrites `/var/lib/ubicloud/var/ca_bundles`.

install.sh also installs `ubicloud-admin` (`packaging/bin/ubicloud-admin`)
to `/usr/local/bin`. Run it as root:

| Command | Does |
|---|---|
| `ubicloud-admin status` | units, web, env file, pg_hba trust rules, backup recipient and age, `bin/byoh-config-check`; exits 1 on any fail |
| `ubicloud-admin smoke` | install.sh's step 12: puma and the front (`front.conf`) answer, the front's unit, web and respirate active, `bin/byoh-config-check` has no fail, `bin/production_check` in production; exits 1 on any fail |
| `ubicloud-admin backup now\|list\|prune --keep N` | `pg_dump` plus the age-encrypted `/etc/ubicloud` under `BACKUP_TARGET`; the daily `ubicloud-backup.timer` runs `backup now` |
| `ubicloud-admin restore TS --key-file F [--env-only\|--db-only] [--force]` | checks the backup, restores into `ubicloud_restore` as the non-superuser role `ubicloud_restorer`, then swaps it in (the old database stays as `ubicloud_prev_*`), migrates and starts; any failure after the swap puts back the database, `/etc/ubicloud` and the billing rates. A replaced env file is kept as `env.before-restore-*`. Backups are trusted: keep them where only root can write |
| `ubicloud-admin env set\|unset\|get --reveal\|keys` | edits `/etc/ubicloud/env` (values on stdin, never printed) and restarts the services, putting the old file back if web does not answer; refuses the secrets, install.sh's flag keys and code-loading keys |
| `ubicloud-admin logs [web\|respirate\|monitor\|backup\|caddy\|cloudflared] [-f]` | journalctl |
| `ubicloud-admin account create\|list` | `bin/byoh-account` |
| `ubicloud-admin run TOOL ...` | `byoh-location`, `byoh-pool`, `byoh-host`, `register-byoh-host`, `byoh-config-check`, `production_check`, `create_prod_admin_account` |
| `ubicloud-admin console [-e CODE\|-e -]` | `bin/pry`; audited when the env file sets `PRY_AUDIT_BUCKET` or `OTEL_EXPORTER_OTLP_ENDPOINT`, otherwise unaudited (one system log line). `-e -` reads the code from stdin, so it stays out of sudo's log |

`ubicloud-admin --help` has the details.

## Usage — control plane (development bootstrap)

```bash
# On the target host (as a sudo-capable user, NOT as root):
./scripts/byoh/bootstrap-ctrl-plane.sh
```

The script is **idempotent** — you can re-run it and it'll skip steps
that are already done. Every step has a marker file under
`~/.ubi-bootstrap/` so reruns are fast.

Environment variables you can override:
- `UBI_REPO_DIR` — path to the ubicloud repo (default: `$HOME/ubicloud`)
- `UBI_RUBY_VERSION` — Ruby version (default: `4.0.7`)
- `UBI_NODE_VERSION` — Node version (default: `24.12.0`)
- `UBI_DB_NAME` — Postgres DB name (default: `clover_test`)
- `UBI_RACK_ENV` — Rack env (default: `development`; use `test` only when running specs)
- `UBI_START_SERVICES` — `1` to start puma + respirate in tmux after setup, `0` to skip (default: `1`)
- `UBI_START_MONITOR` — `1` to also start `bin/monitor` in tmux (default: `0`; read `docs/byoh/PLATFORMS.md` first, as its health checks misjudge hosts without by-id disk links)
- `UBI_BILLING_RATES_DIR` — where `bin/byoh-location` writes BYOH billing rates, written to `.env.rb` as `BILLING_RATES_EXTRA_DIR` (default: `$HOME/ubicloud-billing-rates.d`)
- `UBI_BASE_URL` — the URL users open, written to a new `.env.rb` as `BASE_URL`; account email links use it (default: `http://<first address of hostname -I>:3000`)

The script does not clone the repository: clone it first
(`git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud`).

## Usage — data plane

```bash
# On the BYOH target host (as a sudo-capable user):
./scripts/byoh/bootstrap-data-plane.sh
```

Idempotent. Prepares the host for the control plane's rhizome bootstrap
by ensuring root SSH works, pre-seeding `ruby-bundler` so Ubicloud's
`BootstrapRhizome` doesn't race on `apt-get update`, and printing the
operator's next step.

You'll also need to install the control plane's SSH public key into
`/root/.ssh/authorized_keys` on this host before running
`bin/register-byoh-host` on the control plane — the script prints
instructions for this step.

## Provider-specific pre-work

The bootstrap scripts handle the UNIVERSAL parts. These environment-
specific steps happen BEFORE you run `bin/register-byoh-host`:

Each pool is declared with a `delivery` (how packets reach the host) and
an `exposure` (what the internet sees); see `docs/byoh/NETWORKING.md`
sections 3 and 9. The driver code is the same everywhere.

| Site | Pool shape | Operator pre-work |
|---|---|---|
| **Hetzner / OVH / Leaseweb** (rented bare metal) | `routed` + `public` | Order a block routed to the server's main IP |
| **Colocation** | `routed` + `public` | Static route or BGP of the block to the host |
| **Proxmox or another LAN, no public block** | `onlink` + `internal` | Keep the pool IPs out of the DHCP range; one NIC on the bridge; PVE firewall/ipfilter off on it (`docs/byoh/SETUP_PROXMOX.md`) |
| **Proxmox behind pfSense with extra public IPs** | `onlink` + `nat` | pfSense 1:1 NAT external IP → pool IP, reflection off (`docs/byoh/SETUP_PROXMOX.md`) |
| **Proxmox, block routed by the router** | `routed` + `public` | Router static route `<block> → <data-plane VM IP>` (the data-plane VM, not the Proxmox node) |
| **AWS** | `fabric` + `nat` | `terraform/aws-byoh` (ENI secondary IPs + EIPs, cloud-init fix) |

`scripts/byoh/providers/aws-routed-network-setup.sh` is **retired and
broken** (cloud-init puts the pool IPs back on the NIC at the bootstrap
reboot, and it can leak EIPs). Use `terraform/aws-byoh`.

## Restart playbook

If the ctrl plane or data plane crashes, re-run the bootstrap script.
It'll detect the existing state and only do the missing steps (reload
tmux sessions, verify DB is up, etc.).

Full disaster recovery (fresh machine): start from
`backups/aws-mumbai-pre-eip/clover_test.dump` per the restore
instructions in `backups/README.md`.

## Verification (`verify/`)

- `verify/m2-gate.sh STEP...` runs the M2 canary gate checks (G1-G15)
  on the control plane, from the repo root. Its settings are listed in
  its header and in `docs/byoh/VERIFY.md` §1.4. It never runs terraform
  or aws; G0, G16 and G17 are manual.
- `verify/m2-checks` is the read-only database half of the gate
  (`lib/byoh_gate_checks.rb`), usable on its own:
  `bundle exec scripts/byoh/verify/m2-checks host --host vh...`.
