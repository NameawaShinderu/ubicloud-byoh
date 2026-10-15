# BYOH bootstrap scripts

Reproducible scripts for standing up the Ubicloud control plane and BYOH
data plane on any Ubuntu 24.04 LTS host. Nothing in them is specific to
a platform. The development bootstrap and the data-plane script were run
on AWS; `install.sh`, `ubicloud-admin` and `migrate-from-dev.sh` have run
only in the container harness (`test/`). Everything else is UNVERIFIED.
The runbooks are `docs/byoh/INSTALL.md` and `docs/byoh/OPERATIONS.md`
(packaged control plane), `docs/byoh/MIGRATE_FROM_DEV.md` (moving a
development control plane), `docs/byoh/SETUP.md` (any platform) and
`docs/byoh/SETUP_PROXMOX.md` (a Proxmox VM as the data plane).

## The two roles

A Ubicloud BYOH deployment needs two kinds of Linux hosts:

| Role | What runs on it | Who runs this script | Script |
|---|---|---|---|
| **Control plane** | Postgres, clover (Roda/Puma), respirate dispatcher, `bin/register-byoh-host` CLI, web UI | You, once per deployment | `install.sh` (packaged), or `bootstrap-dev-ctrl-plane.sh` (development and labs only) |
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

## Packaged control plane (`install.sh`, M3)

`install.sh` installs the control plane as root-owned releases under
`/opt/ubicloud`, run by systemd as user `ubicloud`, with database
`ubicloud` on peer authentication and settings in `/etc/ubicloud/env`.
It is safe to re-run and keeps no marker files. `--tls` takes `acme`,
`provided`, `tunnel` or `none`. A development control plane moves to it
with `migrate-from-dev.sh` (below); the live control plane keeps the
development bootstrap until its window. It has run only in the container
harness (`scripts/byoh/test/`); on a real machine it is UNVERIFIED. Every
flag and setting is in `docs/byoh/INSTALL.md`.

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
| `ubicloud-admin release list\|check\|migrate\|use\|prune` | the manual release switch (`docs/byoh/OPERATIONS.md` §7); `install.sh --stage release` builds the release |
| `ubicloud-admin console [-e CODE\|-e -]` | `bin/pry`; audited when the env file sets `PRY_AUDIT_BUCKET` or `OTEL_EXPORTER_OTLP_ENDPOINT`, otherwise unaudited (one system log line). `-e -` reads the code from stdin, so it stays out of sudo's log |

`ubicloud-admin --help` has the details; `docs/byoh/OPERATIONS.md` is the operator's guide.

### Moving a development control plane (`migrate-from-dev.sh`)

`migrate-from-dev.sh` moves a control plane that the development
bootstrap set up (tmux, database `clover_test`) to the packaged layout,
phase by phase: `preflight` (read-only), `install` (`/etc/ubicloud/env`
from `.env.rb`, then `install.sh --no-start`), `copy-db`, `start`,
`flip-production`, `rollback` and `retire`. The development database is
copied, never changed, so a rollback restarts tmux against it as it was.
Its SQL lives beside it: `migrate-role-map.sql`, `migrate-compare.sql`,
`migrate-row-counts.sql`, `migrate-rollback-report.sql` and
`migrate-retire.sql`. The runbook is `docs/byoh/MIGRATE_FROM_DEV.md`;
`bash scripts/byoh/migrate-from-dev.sh --help` lists every flag.

## Usage — control plane (development bootstrap, labs only)

```bash
# On the target host (as a sudo-capable user, NOT as root):
./scripts/byoh/bootstrap-dev-ctrl-plane.sh
```

**Development and labs only.** It makes role `clover` a superuser, sets
`pg_hba.conf` to trust for local and loopback connections, runs puma on
`0.0.0.0:3000` in tmux, and nothing survives a reboot. Use `install.sh`
for anything else.

`bootstrap-ctrl-plane.sh`, the old name, is a shim: it prints a warning
and runs `bootstrap-dev-ctrl-plane.sh` with the same arguments and
environment, so existing docs, terraform user data and
`curl ... | bash` one-liners keep working. Run from disk it uses the
script next to it; read from a pipe it uses
`${UBI_REPO_DIR:-$HOME/ubicloud}/scripts/byoh/bootstrap-dev-ctrl-plane.sh`,
and exits 1 with the clone command when that is missing.

The script refuses, before it changes anything, `UBI_RACK_ENV=production`,
`UBI_DB_NAME=ubicloud`, and a machine with a packaged control plane
(`/etc/ubicloud/env` exists, or `ubicloud.target` is active or enabled):
its trust rules would open the packaged database and its tmux puma
would take port 3000. `UBI_FORCE_DEV=1` overrides the last check, for
labs only. Since M3 it also fails instead of continuing when creating
the roles or database, or refreshing the Sequel caches, fails, and it
installs JavaScript packages with `npm ci`.

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
- `UBI_FORCE_DEV` — `1` to run next to a packaged control plane (labs only; default: `0`)

The script does not clone the repository: clone it first
(`git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud`).

## Usage — data plane

```bash
# On the BYOH target host (as a sudo-capable user):
./scripts/byoh/bootstrap-data-plane.sh [--main-ip IP] [--preflight-script PATH | --no-preflight]
```

Idempotent. Prepares the host for the control plane's rhizome bootstrap
by ensuring root SSH works, pre-seeding `ruby-bundler` so Ubicloud's
`BootstrapRhizome` doesn't race on `apt-get update`, then runs host
preflight and prints the operator's next step.

Preflight is `scripts/byoh/host/ubicloud-host preflight --standalone`
(read-only, PLATFORMS.md §6), found next to the script or at
`host/ubicloud-host` below its directory, or given with
`--preflight-script`. Standalone it checks what needs no pools: PF1-PF19
plus one IPv4 default route and, with `--main-ip`, that the main IP is
on the host. The script exits 1 when a check fails (the finished steps
stay marked, so a re-run only repeats the checks), and prints how to run
preflight from the control plane when the script is not found.
`ubicloud-admin host add` runs the full preflight again with the pools
and installs its own root key; with `bin/register-byoh-host`, install
the control plane's public key in `/root/.ssh/authorized_keys` yourself
first. Tested by `scripts/byoh/test/bootstrap-preflight.sh`.

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

A packaged control plane restarts by itself (systemd); recover it with
`ubicloud-admin restore` from its nightly backups
(`docs/byoh/OPERATIONS.md` §6). On a development control plane, re-run
the development bootstrap after a crash or reboot: it detects the
existing state and only does the missing steps (reload tmux sessions,
verify the DB is up, etc.). Its only recovery is a `pg_dump` of
`clover_test` plus `.env.rb`, taken by hand.

## Container harness (`test/`)

`test/run.sh` tests `install.sh`, the units, `ubicloud-admin`, the TLS
fronts, the development shim and `migrate-from-dev.sh` in throwaway
`ubi-m3-*` containers that run systemd. Scenarios and results:
`test/README.md`.

## Verification (`verify/`)

- `verify/m2-gate.sh STEP...` runs the M2 canary gate checks (G1-G15)
  on the control plane, from the repo root. Its settings are listed in
  its header and in `docs/byoh/VERIFY.md` §1.4. It never runs terraform
  or aws; G0, G16 and G17 are manual.
- `verify/m2-checks` is the read-only database half of the gate
  (`lib/byoh_gate_checks.rb`), usable on its own:
  `bundle exec scripts/byoh/verify/m2-checks host --host vh...`.
- `verify/m4-e2.sh` runs the M4 E2 gate (G-M4-1 AWS, G-M4-2 Proxmox):
  `ubicloud-admin site add` and `host add --ssh` exactly as an operator
  types them, with a timed transcript in `var/`, then the no-VM steps
  of `m2-gate.sh`. `verify/m4-f5-soak.sh --host vh... --hours 24`
  samples hosts while `bin/monitor` runs (G-M4-3 to 5) through
  `m2-checks health --probe`. Both are UNVERIFIED on real
  infrastructure; `docs/byoh/VERIFY.md` §6 has the settings and pass
  rules, and `test/m4-gate-scripts.sh` tests them against stubs.
