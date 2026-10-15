# Operating a packaged control plane

This page is for a control plane that `scripts/byoh/install.sh` installed
([INSTALL.md](INSTALL.md)): systemd units, `/opt/ubicloud`,
`/etc/ubicloud/env`, database `ubicloud`. A development control plane
(`bootstrap-dev-ctrl-plane.sh`, tmux, `clover_test`) moves to this layout
with [MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md).

Every command runs as root (`sudo`). `ubicloud-admin --help` lists all of
them. Measurements on this page come from the container harness
(`scripts/byoh/test/README.md`, systemd 255 in `ubuntu:24.04`
containers); nothing here has run on a real machine yet (UNVERIFIED).

| Section | |
|---|---|
| 1 | Units, journald, kill and restart times |
| 2 | `ubicloud-admin` reference |
| 3 | The console (not audited) |
| 4 | Settings: `env set`, BMC passwords, billing rates |
| 5 | Mail, sign-up and onboarding |
| 6 | Backups and restore |
| 7 | Release switch |
| 8 | The 2027-01-01 audit-partition deadline |
| 9 | Monitor |
| 10 | Disk layout |

---

## 1. Units

| Unit | Runs (as `ubicloud`, in `/opt/ubicloud/current`) | Restart | Notes |
|---|---|---|---|
| `ubicloud.target` | Wants web, respirate and the backup timer | — | Enabled at boot. `systemctl start\|stop\|restart ubicloud.target` acts on everything `PartOf` it |
| `ubicloud-web` | `bundle exec puma -C puma_config.rb` on `BIND:PORT` (127.0.0.1:3000) | always, 2 s | 15 threads |
| `ubicloud-respirate` | `ruby bin/restarter bin/respirate` | always, 1 s | When respirate exits (an apoptosis or a crash), `bin/restarter` respawns it within `RESTART_MAX_SLEEP=2` s; at the first such exit after an hour it exits 0 instead, and systemd restarts it. A respirate that keeps running keeps the same restarter. `KillMode=mixed`, `TimeoutStopSec=100` |
| `ubicloud-monitor` | `ruby bin/monitor` | always, 2 s | **Installed, not enabled** until M9 (§9) |
| `ubicloud-backup.timer` | Daily at 03:15 (+ up to 15 min random), `Persistent=true` | — | `PartOf` the target: stopping the target pauses scheduled backups |
| `ubicloud-backup.service` | `ubicloud-admin backup now`, as root | oneshot | Not `PartOf` the target, so a stop or restart of the target never kills a running backup |
| `caddy` or `cloudflared` / `ubicloud-cloudflared` | The TLS front | stock / on-failure | Not part of the target ([INSTALL.md](INSTALL.md) §3) |
| `postgresql@16-main` | Postgres | stock | The units `Want` it but do not stop with it |

Web, respirate and monitor run with `ProtectSystem=strict`,
`ProtectHome=yes`, `ReadWritePaths=/var/lib/ubicloud`, no capabilities
and `UMask=0007`; `systemd-analyze security` rates web and respirate
3.5. `ubicloud-backup.service` is not confined this way: it runs as
root with only `UMask=0077` and `PrivateTmp`, because it reads
`/etc/ubicloud` and dumps as postgres. They read
`/etc/ubicloud/env` and the release's `.release-env` (`GIT_REV`).

**Logs** go to journald only: `sudo ubicloud-admin logs [web|respirate|monitor|backup|caddy|cloudflared]... [-f] [--since T] [-n N]`
(`journalctl -u ubicloud-respirate` works too). Without a unit name it
shows web, respirate, monitor and backup. Ubuntu keeps the journal in
`/var/log/journal` across reboots by default, capped by journald's
`SystemMaxUse` (EXTERNAL). There are no files in `/tmp` any more.

### 1.1 Kill and restart times (harness, 2026-10-14)

| Event | Result |
|---|---|
| SIGKILL to the respirate child | `bin/restarter` keeps its PID and spawns a new child in 1.1-2.3 s; a strand ran 3.3-4.1 s after the kill |
| SIGKILL to the whole unit (`systemctl kill -s KILL`) | New MainPID after 1.1 s; a strand ran after 3.7-4.3 s |
| `systemctl restart ubicloud.target`, idle | 0.4-0.5 s |
| Stop with one strand in a database query | Waits for the query (8.2 s in the test), exits status 1, the unit shows failed until the next start; the strand ran again 3.9 s after the restart |
| Stop with every dispatcher thread busy | respirate cannot start its shutdown; apoptosis ends it about 91 s after the oldest strand started (85.9 s into the stop), status 2, no SIGKILL. This is why `TimeoutStopSec=100` |
| Stop that hits the timeout (tested with 10 s) | SIGKILL; the interrupted strand ran again 110 s later, when its lease expired |
| Reboot (`docker restart`) | web answered 3.2-4.6 s after boot and strands ran. A real reboot is UNVERIFIED |

**Lease note.** A strand that is running holds a 120 s lease. If
respirate dies mid-strand (SIGKILL, OOM, a timeout), no other respirate
takes that strand until the lease expires, so it resumes up to two
minutes later. Never kill respirate to make a stop faster: wait. A stop
of up to about 100 s is normal under load.

---

## 2. `ubicloud-admin` reference

Exit status: 0 success, 1 failure, 2 usage error or a refusal that
changed nothing. Every command but `logs` and `env keys` writes one line
(the command and `$SUDO_USER`, never its arguments) to the system log
with tag `ubicloud-admin`. Commands that change state hold
`/run/ubicloud-admin.lock`, the lock install.sh takes, so the backup
timer never races a restore, an install or a release switch.

| Command | Does |
|---|---|
| `status` | Units, enabled target, monitor state, release and migrations, web answer, env file mode and keys, `pg_hba` trust rules and login superusers, leftover restore databases, backup recipient and age, then `bin/byoh-config-check` (settings, role isolation, partition runway). Exits 1 on any fail |
| `smoke` | install.sh step 12 ([INSTALL.md](INSTALL.md) §6) |
| `backup now\|list\|prune --keep N` | §6 |
| `restore TS --key-file F [--env-only\|--db-only] [--force] [--no-start]` | §6.3, §6.4 |
| `env set KEY [--no-restart]`, `env unset KEY`, `env get KEY --reveal`, `env keys` | §4 |
| `logs ...` | §1 |
| `account create --email E [--name N] [--project P] [--password-stdin\|--password-file F]`, `account list` | §5 |
| `run TOOL [ARGS...]` | `byoh-location`, `byoh-pool`, `byoh-host`, `register-byoh-host`, `byoh-config-check`, `production_check`, `create_prod_admin_account LOGIN` in the release as `ubicloud`. Input files (`--pool-file`, `--ssh-key`, `--external-map`, `--password-file`) are copied for it; `--out F` comes back to you (0600). `--bmc-password` in any spelling is refused |
| `console [-e CODE\|-e -]` | §3 |
| `release list\|check\|migrate\|use\|prune` | §7 |

`status` in practice:

| Line | Meaning |
|---|---|
| `fail postgres: pg_hba.conf line(s) N use trust ...` | Expected on a control plane moved from the development bootstrap until `migrate-from-dev.sh retire` |
| `fail backup: no recipient ...` | Secrets are not backed up; run install.sh with `--backup-recipient age1... --update-env BACKUP_RECIPIENTS` |
| `warn backup: the last backup ... is N h old` (36 h), `fail` (72 h) | The timer failed or was paused (`ubicloud-admin logs backup`) |
| `warn ... CONTROL_PLANE_OUTBOUND_CIDRS includes 0.0.0.0/0` | Open default; narrow it with `env set`, or wait for M8 |
| `warn audit_log partitions end 2027-01-01 (N days)` | §8. Becomes a fail 30 days before |
| `warn postgres: database(s) ubicloud_prev_... are left from restores` | Drop each once checked: `sudo -u postgres dropdb NAME` |

---

## 3. The console

```bash
sudo ubicloud-admin console                 # pry as user ubicloud
echo 'puts VmHost.count' | sudo ubicloud-admin console -e -
```

**The console is not audited.** In production `bin/pry` refuses to start
without an audit sink. `ubicloud-admin console` sets
`PRY_ALLOW_UNAUDITED=true` for its own session only, prints a warning,
and `bin/pry` writes one system-log line (tag `ubicloud-pry`: who and
when). Nothing records what was typed. With `PRY_AUDIT_BUCKET` or
`OTEL_EXPORTER_OTLP_ENDPOINT` in the env file, the session and the code
go to that sink instead (an OTLP receiver was tested; a real bucket is
UNVERIFIED).

- `-e CODE` appears in sudo's own log; `-e -` reads the code from stdin
  and keeps it out.
- pry's history goes to a throwaway HOME, never to `/var/lib/ubicloud`.
- `PRY_ALLOW_UNAUDITED` must never be in `/etc/ubicloud/env`: install.sh
  exits 2 on it, `status` fails and `env set` refuses it.

---

## 4. Settings

### 4.1 `env set`

```bash
sudo ubicloud-admin env keys                       # names only
sudo ubicloud-admin env set DB_POOL_WEB            # typed without echo, or from stdin
printf '%s' "$VALUE" | sudo ubicloud-admin env set SOME_KEY
sudo ubicloud-admin env unset SOME_KEY
sudo ubicloud-admin env get SOME_KEY --reveal      # prints the value; logged
```

`env set` writes the file (root 0600), restarts `ubicloud.target` and
waits up to 120 s for web to answer. If web does not answer, it puts the
old file back and restarts again. `--no-restart` leaves the services on
the old values until their next start. Refused (exit 2, nothing
changed), with the reason:
- the secrets (`CLOVER_COLUMN_ENCRYPTION_KEY`, `CLOVER_SESSION_SECRET`,
  `CLOVER_RUNTIME_TOKEN_SECRET`), whose change breaks data or logins;
- the keys install.sh owns through a flag (`BASE_URL`, `RACK_ENV`,
  `MAIL_*`, `SMTP_*`, `IP_FROM_HEADER`): change those with install.sh and
  `--update-env KEY` ([INSTALL.md](INSTALL.md) §4.1);
- keys that load code (`RUBYOPT`, `GEM_*`, `BUNDLE_*`, `NODE_OPTIONS`, ...),
  `PRY_ALLOW_UNAUDITED`, `GIT_REV`, `PORT=8081`, and the names and values
  [INSTALL.md](INSTALL.md) §4.3 forbids;
- `unset` of a key `config.rb` requires.

### 4.2 BMC password variables

`register-byoh-host --bmc-pass-env VAR` stores only the variable's name.
The value must be in the environment of respirate (Hardware Reset) and
web (Power On, Power Status), which on this layout means the env file:

```bash
sudo ubicloud-admin env set BMC_PASS            # type the password
sudo ubicloud-admin run register-byoh-host ... --bmc-endpoint https://bmc.example \
  --bmc-user admin --bmc-pass-env BMC_PASS
```

Use one variable per BMC password (`BMC_PASS_RACK1`, ...). `run` refuses
`--bmc-password`, which would put the password on a command line and in
the database. The variable is part of the secrets backup. A control plane
moved with `migrate-from-dev.sh` already has the variables `preflight`
found ([MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md)).

### 4.3 Billing rates

`BILLING_RATES_EXTRA_DIR` is `/var/lib/ubicloud/billing_rates.d`, owned by
`ubicloud` (never a path under `/home`: the services cannot see it). The
services read the rates once at start, so after `ubicloud-admin run
byoh-location create --rates-from ...` or `... rates ...`:

```bash
sudo systemctl restart ubicloud.target
```

The directory is in every backup (`billing-rates.tar`).

---

## 5. Mail, sign-up and onboarding

Without `--smtp-file`, `MAIL_DRIVER=logger`: every mail, with its links,
is written to the journal of `ubicloud-web`.

**Security note.** In production, verification, password-reset and
email-change mails carry one-time links that take over the account.
With the logger driver those links sit in the journal, which root and
members of the `adm` and `systemd-journal` groups can read. Keep those
groups to operators, or configure SMTP.

- **Onboarding is `account create`**, not the sign-up page:

  ```bash
  sudo ubicloud-admin account create --email user@example.com --name "Name" --project "Default"
  ```

  It creates a verified account with a project (as sign-up would) and an
  operator-action row. Without `--password-stdin` or `--password-file`
  it generates a password and prints it **once** on your terminal; it
  never reaches the journal. Do not pipe this command's output into a
  log.
- **The sign-up page stays public.** In production anyone who reaches the
  URL can fill in `/create-account`; the account cannot log in until its
  verification link is followed, which with the logger driver only a
  journal reader can do. In **development** (the live control plane
  today, and window A of the migration) `/create-account` makes a
  working account at once, with no mail at all. Closing sign-up is a
  product decision that M3 does not make; until then restrict who can
  reach the URL (Cloudflare Access on the tunnel, or a firewall) if that
  matters.
- Admin accounts: `sudo ubicloud-admin run create_prod_admin_account LOGIN`
  prints the password. The admin UI is not reachable over HTTPS yet (M3-l).

---

## 6. Backups and restore

### 6.1 Layout

`BACKUP_TARGET` in `/etc/ubicloud/backup.conf` (default
`/var/backups/ubicloud`, root 0700):

| Path | Holds |
|---|---|
| `<TS>/db.dump` | `pg_dump -Fc ubicloud`, made as `postgres`, so the password-hash tables are included |
| `<TS>/globals.sql` | `pg_dumpall --globals-only --no-role-passwords` |
| `<TS>/billing-rates.tar` | `/var/lib/ubicloud/billing_rates.d` |
| `<TS>/manifest.json` | Version, rev, applied migrations, sha256 of each file, a fingerprint of the column key |
| `secrets/<TS>.age` | A tar of `/etc/ubicloud` (env with every secret, TLS key, tunnel token, backup settings), encrypted with age to `/etc/ubicloud/backup-recipients` |
| `KEYS-README.txt` | Written at install: what each file is and where the key must live |
| `pre-migration-<UTC>.dump` | Left by `migrate-from-dev.sh copy-db`; never pruned |

`TS` is UTC, such as `20261014T031512Z`. A backup is written to
`.<TS>.partial` and renamed when complete, so a crash leaves no half
backup that looks whole. In the harness a backup of a fresh database is
about 1 MB.

```bash
sudo ubicloud-admin backup now
sudo ubicloud-admin backup list          # TIMESTAMP SIZE SECRETS VERSION MIGRATIONS
sudo ubicloud-admin backup prune --keep 14
```

**Nothing prunes automatically.** The timer only runs `backup now`. Run
`prune --keep 14` (or your retention) by hand or from root's crontab.
`prune` removes only `<TS>` directories and their secrets, never other
files. `migrate-from-dev.sh retire` counts the backups since the copy, so
keep at least 14 until it has run.

**Off the machine.** The target is on the control plane's own disk:
it survives a broken database, not a lost machine. Copy the target
elsewhere (rsync, object storage) on your own schedule. `s3://` targets,
WAL archiving and point-in-time recovery come with E5.

### 6.2 Key custody

- The age **identity** (private key) that decrypts `secrets/*.age` must
  not live on the control plane or next to the backups. Keep it offline
  or in a password manager; give each operator who may restore their own
  recipient (`--backup-recipient-file` with several `age1...` lines).
- Without the identity, and without another copy of
  `/etc/ubicloud/env`, a restore cannot read the encrypted columns, which
  hold every host's SSH key: the control plane loses its hosts.
- Without any recipient, `backup now` warns, the secrets are skipped, and
  `status` fails until one is set.
- `KEYS-README.txt` in the target says the same for whoever finds the
  backups.
- Rotating `CLOVER_COLUMN_ENCRYPTION_KEY` or the session secret has no
  procedure yet; `env set` refuses both.

### 6.3 Restore

`restore` first checks the backup: sha256 of every file,
`pg_restore --list`, no migration the current release lacks, only the
`citext` and `btree_gist` extensions, and (unless `--db-only`) that the
secrets decrypt and hold the column key the manifest names. It then
builds database `ubicloud_restore` as the non-superuser role
`ubicloud_restorer`. Only then does it stop the services, rename
`ubicloud` to `ubicloud_prev_<time>` and the restored copy to `ubicloud`,
run the release's migrations as `ubicloud-migrate`, install the backup's
files, start the services and print `status`. A failure after the swap
puts back the old database, `/etc/ubicloud` and the billing rates.

| Case | Command |
|---|---|
| The database is damaged; env file fine | `sudo ubicloud-admin restore TS --db-only` (the env file's column key must match the backup's) |
| Database and env file from the backup | `sudo ubicloud-admin restore TS --key-file ~/age-identity.txt` (the env file is replaced only when missing, or with `--force`; the old one stays as `env.before-restore-<time>`) |
| Only the env file and the other secrets | `restore TS --key-file F --env-only [--force]` |
| A new machine | Install with `install.sh` at the **same version and rev** (any `--tls`), copy `<TS>/` and `secrets/<TS>.age` into the target, `restore TS --key-file F --force`, then run install.sh again with the original machine's flags to set up its front |

- Everything written after the backup is lost: VMs created since then
  exist on the hosts but not in the database. Compare with the hosts
  before you let customers back.
- The old database stays as `ubicloud_prev_<time>` until you drop it.
- A backup is trusted: the sha256s catch damage, not tampering. Keep the
  target writable by root only.
- In the harness a restore took about 6 s from check to `status`, and a
  restored Sshable's `cmd` worked (the column key round trip). A restore
  onto a second machine and a real reboot between backup and restore are
  UNVERIFIED.

### 6.4 Monthly restore drill

A restore you never tried is a hope. Once a month (and once before
`migrate-from-dev.sh retire --restore-drill-done`), restore the newest
backup on a **disposable** machine. Never drill on the live control
plane: `restore` replaces the live database.

The restored database holds the live strands, and the restored env file
holds the BMC passwords (§4.2). A respirate that ran them on the drill
machine would act on the real fleet: SSH to the hosts, and Redfish resets
through their BMCs, which have other addresses than the hosts. So the
drill keeps respirate from ever running, and cuts the machine off as
well.

1. A fresh Ubuntu 24.04 VM. Install with the live machine's version and
   rev and `--tls none --url http://localhost:3000`.
2. Before the restore, make outbound traffic default-deny: allow only
   loopback and DNS, and drop everything else (an nftables `output`
   chain with `policy drop`, or the VM's security group). Do not build
   an allow-list of the data-plane hosts and SMTP: the BMC and Redfish
   endpoints, the pool addresses and every other address in the
   database must be unreachable too. Check with `curl -m 5` to one host
   and one BMC endpoint.
3. Stop the services and keep them from coming back at boot:

   ```bash
   sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor
   sudo systemctl disable ubicloud.target
   ```

4. Copy `<TS>/` and `secrets/<TS>.age` into `/var/backups/ubicloud`, then
   `sudo ubicloud-admin restore TS --key-file F --force --no-start` with
   an identity you keep off the live machine. `--no-start` leaves every
   service stopped after the restore; without it the restore starts
   respirate.
5. Check, without starting any service:

   ```bash
   echo 'Sshable.each { it.raw_private_key_1 }; puts "decrypted #{Sshable.count} host keys"' | sudo ubicloud-admin console -e -
   echo 'puts Account.count, VmHost.count, Vm.count' | sudo ubicloud-admin console -e -
   ```

   A wrong column key raises on the first Sshable.
6. Destroy the drill machine (it holds every secret). Never start
   `ubicloud.target` or `ubicloud-respirate` on it.

This drill is UNVERIFIED end to end: the harness restores on the same
container, and checks only that `restore --no-start` leaves web,
respirate, monitor and the target stopped.

---

## 7. Release switch

A release is one directory under `/opt/ubicloud/releases/<version>`.
`/opt/ubicloud/current` points at the release the services run, and
`/opt/ubicloud/previous` at the one before the last switch. A switch
changes the code, applies its migrations and moves `current`.

The switch is manual until M12, which brings `ubicloud-admin upgrade`
and release tarballs. Each step below is guarded, and the services are
stopped for the whole switch: there is no rolling upgrade.

### Limits

- Every release runs on the shared tools in `/opt/ubicloud/tools`. A
  release whose `mise.toml` asks for another Ruby or Node version is
  refused by `install.sh --stage release` (exit 2), and by `release
  check`, `migrate` and `use`. Changing the tools needs tools per release
  (M12).
- Switching the release does not change the data-plane hosts. If
  `rhizome/` changed between the two releases, push it to the hosts after
  the switch (step 8). Without that, existing hosts keep the old rhizome.
- The TLS front (the Caddyfile or the cloudflared unit) is written from
  the release by `install.sh`. If the new release changes
  `packaging/caddy` or `packaging/cloudflared`, run `install.sh` once
  more after the switch with its usual flags and `--version <new>`. That
  version is current by then, so the run is allowed.

### Procedure

`v1` is current, `v2` is the new release. Run each step only when the one
before it succeeded.

1. **Build v2 next to v1.** This changes nothing else: not `current`, not
   the settings, the database or the units, and the services keep
   running.

   ```
   sudo bash ~/ubicloud/scripts/byoh/install.sh --stage release --version v2 \
     --source-git ~/ubicloud --ref <commit>
   ```

   `--stage release` takes only `--version`, the source and
   `--skip-check`. Any settings flag exits 2. If `v2` already exists with
   another rev, the run exits 2; give the build another `--version`.
   Without `--stage release`, a new `--version` still exits 2.

2. **Check v2.** This step changes nothing.

   ```
   sudo ubicloud-admin release check v2
   ```

   It checks that v2 runs on the installed tools and that its files are
   root's alone. It also checks that v2 knows every migration the
   database has applied, and it says how many migrations `release
   migrate` would apply. It exits 2 if v2 cannot be used.

3. **Stop the services.**

   ```
   sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor
   ```

   This stops web, respirate, monitor (if you enabled it) and the backup
   timer. Respirate stops gracefully, which takes up to
   `TimeoutStopSec=100` while a strand finishes. Name the services as
   well as the target: `systemctl stop ubicloud.target` alone can return
   while respirate or monitor is still stopping, and a backup taken then
   is older than its stop. `release
   migrate` and `use` count a unit that is still stopping as running.

4. **Back up.**

   ```
   sudo ubicloud-admin backup now
   ```

   Back up after the stop, not before: a backup taken while respirate
   runs misses the strands that ran afterwards. `release migrate` refuses a backup that is
   older than the last time web, respirate or monitor ran: the latest
   stop of one of them, from systemd or the journal, or the boot when
   none ran since. It also refuses a backup that holds other migrations
   than the database, or one with migrations v1 lacks (a restore on v1
   could not take it). `--skip-backup-check` overrides this, but then
   there is nothing to go back to.

5. **Migrate with v2.**

   ```
   sudo ubicloud-admin release migrate v2
   ```

   It runs `bin/rake-task-runner migrate` from v2's directory as
   `ubicloud-migrate`, with the same environment as the units. If v2 has
   no new migrations, it says so and changes nothing. `current` still
   points at v1 after this step.

6. **Point current at v2.**

   ```
   sudo ubicloud-admin release use v2
   ```

   It installs v2's units (with `systemctl daemon-reload` when one
   changed) and v2's `ubicloud-admin`. Then it points `previous` at v1
   and `current` at v2, each through an atomic rename.

7. **Start and check.**

   ```
   sudo systemctl start ubicloud.target
   sudo ubicloud-admin status
   sudo ubicloud-admin smoke
   ```

   `status` fails while the database and `current` disagree: when the
   database has a migration the release lacks, or when the release has
   migrations that have not run.

8. **Rhizome, only if it changed.**

   ```
   sudo ubicloud-admin console -e 'VmHost.all.each(&:install_rhizome)'
   ```

   This is UNVERIFIED on a packaged control plane with real hosts.

9. **Disk ids, only when moving a host registered before M4 to M4 or
   later.** Before you enable `ubicloud-monitor`, refresh each such BYOH
   host's stored disk ids, which can be `""`, `root` or a partition name:

   ```
   sudo ubicloud-admin run byoh-host relearn-device-ids --host vh...         # shows old -> new
   sudo ubicloud-admin run byoh-host relearn-device-ids --host vh... --yes   # stores them
   ```

   The host must be reachable over SSH. See §9 for what the ids are for.

10. **GPUs, only when moving a BYOH host with an NVIDIA GPU registered
    before M4 to M4 or later.** Its GPU rows were learned under
    upstream's rule, which keeps a GPU whatever its driver. Rerun
    LearnPci so a GPU that is not on `vfio-pci` stops being offered to
    GPU VMs:

    ```
    sudo ubicloud-admin run byoh-host relearn-pci --host vh...
    ```

    It starts a `LearnPci` strand, writes a `byoh_operator_action` row,
    and drops only idle rows; a GPU a VM holds keeps its row. The
    respirate log names each GPU it skips. UNVERIFIED on real GPU
    hardware.

Do not flip `current` by hand with `ln -sfn`. That skips the downgrade
guard below.

### Guards

| Command | Refuses (exit 2, nothing changed) when |
|---|---|
| `install.sh --stage release` | No installed control plane; a settings flag; the version exists with another rev; other tools than the current release |
| `release migrate`, `release use` | web, respirate or monitor run; the release wants other tools; a file in it is not root's alone or is group/other writable |
| `release migrate` | The database has a migration the release lacks; no backup made since web, respirate or monitor last ran (or since the boot) holds the database's migrations, or holds them minus migrations of this release that an earlier run applied, with only migrations `current` knows (unless `--skip-backup-check`) |
| `release use` | **Downgrade guard:** the database has a migration (`schema_migrations`, or `schema_migrations_password` for `migrate/ph`) that the release's `migrate/` lacks. Also: the release has migrations that have not run (run `release migrate` first) |
| `release use --for-restore TS` | Backup `TS` does not exist, or holds a migration the release lacks. When it takes the downgrade, it holds the services until the restore (see Going back) |
| `release prune --keep N` | Never removes `current` or `previous`, whatever N says |

Migrations only run forward, so a release can never run on a schema
newer than its own. Going back past a migration means restoring a backup
that was made before it ran.

### Going back

- **The new release has no new migrations** (`release list` shows
  `matches` for the old one):

  ```
  sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor
  sudo ubicloud-admin release use v1
  sudo systemctl start ubicloud.target
  ```

  If v1's `ubicloud-admin` predates the `release` command, the newer one
  stays installed, so v1 can switch forward again. `release use` warns
  when this happens.

- **v2's migrations ran.** `release use v1` refuses. Go back to the
  backup from step 4 (`ubicloud-admin backup list`):

  ```
  sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor
  sudo ubicloud-admin release use v1 --for-restore <TS>
  sudo ubicloud-admin restore <TS> --db-only
  ```

  `--for-restore` takes the downgrade only if v1 knows every migration
  in that backup. It then holds the services: it writes
  `/var/lib/ubicloud/release-hold` and drop-ins
  (`/etc/systemd/system/<unit>.service.d/50-ubicloud-release-hold.conf`)
  that make web, respirate and monitor fail to start, by hand, through
  `ubicloud.target` or at boot, and make the backup timer's runs skip.
  `status` fails and names the hold until the restore ran. The restore
  builds the backup beside the live database, swaps the two, runs v1's
  migrations, lifts the hold and starts the services. The v2 database
  stays as `ubicloud_prev_<time>`; drop it yourself once it is not
  needed. Anything written between the backup and the rollback is lost.
  If the restore fails, it puts the v2 database back and the hold stays.
  Then `release use v2` returns to v2 and lifts the hold.

- **A migration failed in step 5.** `current` still points at v1, and the
  services stay stopped. Each migration runs in its own transaction, so
  the database keeps the ones that finished before the failure. Either
  fix the cause and run `release migrate v2` again, or run `restore <TS>
  --db-only` with the backup from step 4. That restore runs on v1 and
  starts the services.

  A rerun needs no new backup, as long as the services stay stopped: it
  takes the backup from step 4, which holds the database before the v2
  migrations that ran, and names it again if the rerun fails. A `backup
  now` in between does no harm. That backup has v2 migrations, which v1
  cannot restore, so `release migrate` passes it over. If a service ran
  after the failure, the step 4 backup is too old and the rerun is
  refused. Then either restore the step 4 backup, which loses what the
  services wrote since, or rerun with `--skip-backup-check`.

### Listing and pruning

```
sudo ubicloud-admin release list
sudo ubicloud-admin release prune --keep 3
```

`list` prints each release's version, rev, build time and role
(`current`, `previous`), and where it stands against the database's
migrations. The last column is `matches`, `N to apply`, or `lacks N
applied` (a downgrade the guard refuses).

`prune` keeps the N newest releases by build time, plus `current` and
`previous` whatever N is. It also removes unfinished builds
(`<version>.tmp`). It holds the same lock as `install.sh`, so it never
races a build.

### What was rehearsed

The `upgrade-manual` scenario of the container harness
(`scripts/byoh/test`) ran these steps. Release t1 comes from the harness
image; t2 is the working tree plus a dummy file; t3 is t2 plus one
migration. t4 and t5 are copies of t3: t4's `ubicloud-admin` lacks the
`release` command, and t5 has a second migration that fails. The
scenario covered:
- t1 → t2 → t1;
- the backup guard: a backup older than the stop of web, one older than
  a reboot with the target disabled, one with other migrations, and
  `--skip-backup-check`;
- a migration that fails halfway (t5): reruns, also after a `backup
  now`, go on from the backup made before it, and `restore --db-only` on
  t1 goes back;
- t1 → t3, after which use and migrate of t1 and t2 are refused;
- going back to t2 with `--for-restore` and `restore --db-only`, with
  the services held across a manual start, a target start and a reboot;
- t4 refused for a group-writable file, for another Ruby (`check`,
  `migrate`, `use`) and for `--for-restore` of a backup that does not
  exist, then used with a warning that keeps the newer `ubicloud-admin`;
- logins and `status` after every switch;
- prune with `current`, then `previous`, outside the N newest.

Results are in `scripts/byoh/test/README.md`. None of this has run on the
live control plane (UNVERIFIED).

---

## 8. The 2027-01-01 audit-partition deadline

`audit_log`, `account_authentication_audit_log` and
`admin_account_authentication_audit_log` are range-partitioned by month,
and upstream's migrations create partitions only up to **2027-01-01**
(`migrate/20260331_2026_partitions.rb`,
`migrate/20260325_authentication_audit_logs.rb`), with no DEFAULT
partition. From 2027-01-01 every insert into them fails: logins and
every audited action would fail.

`bin/byoh-config-check`, and so `ubicloud-admin status` and `smoke`,
report the runway of each table:

| Days left | Line |
|---|---|
| 90 or more | `ok ... partitions end 2027-01-01 (N days)` |
| 30-89 (from 2026-10-03) | `warn ... inserts fail after that, so add partitions (an upstream merge brings them) before then` |
| under 30 (from 2026-12-02) | `fail`, so `status` and the install smoke exit 1 |

The partitions come from upstream, whose comment in
`20260331_2026_partitions.rb` already plans them. The fork does not add
its own migration, because creating the same tables would make the next
upstream merge fail. The fix is the per-milestone upstream merge
(CLAUDE.md §8), deployed with the release switch (§7) **before
2026-12-02**. The development layout (the live control plane today) has
the same deadline and no check: check it with `bin/byoh-config-check`
from the repository there.

---

## 9. Monitor

`ubicloud-monitor` is installed but not enabled, and `ubicloud.target`
does not want it. It is enabled in M9. `status` warns when it is enabled.
Without it, an out-of-band host reboot is not noticed: use the admin
Reboot, as [TROUBLESHOOTING.md](TROUBLESHOOTING.md) §8 says.

Upstream's health checks misjudge hosts without `wwn-`/`nvme-eui` disk
links and SMART (AWS EBS, virtio, LVM roots; PLATFORMS F5) and can mark
them `unavailable`. Since M4, BYOH hosts (a generic host in a BYOH
location) get their own checks: disks are identified from the mount
point down (`findmnt`, `lsblk -s`, the best `/dev/disk/by-id` link or
the kernel name), virtual and SMART-less disks are not SMART-checked,
`kvm-clock` passes on a virtual host, and the read/write check always
writes into `/var/storage`. The 24-hour monitor soak on EBS, virtio and
LVM hosts has not been run (UNVERIFIED).

Hosts registered before M4 keep the disk ids learned then, which can be
`""`, `root` (from a `/dev/root` df source, as on Ubuntu cloud images)
or a partition name. Before enabling the monitor, refresh them on each
such host (§7 step 9 in a release switch):

```
bin/byoh-host relearn-device-ids --host vh...         # shows old -> new
bin/byoh-host relearn-device-ids --host vh... --yes   # stores them
```

(packaged: `sudo ubicloud-admin run byoh-host relearn-device-ids ...`).
It changes only `storage_device.unix_device_list`, writes a
`byoh_operator_action` row, and needs SSH to the host. Until then the
monitor reads such a host as down: a blank or `root` id fails with "has a
stale storage device id", and a partition with "is not a whole disk";
both messages name the command.

---

## 10. Disk layout

| Path | Owner | Grows with | Notes |
|---|---|---|---|
| `/opt/ubicloud/tools` | root | Ruby/Node versions | Shared by every release |
| `/opt/ubicloud/releases/<v>` | root | One per release (gems, assets) | `release prune --keep N` |
| `/opt/ubicloud/current`, `previous` | root | — | Symlinks |
| `/etc/ubicloud/` | root | — | `env` (0600), `backup.conf`, `backup-recipients`, `front.conf`, `tls/`, `cloudflared.token`, `env.before-restore-*` |
| `/var/lib/ubicloud/` | ubicloud | Little | `var/` (CA bundles), `billing_rates.d/`, `release-hold` during a held downgrade |
| `/var/lib/postgresql/16/main` | postgres | The database, plus `ubicloud_prev_*` copies | Drop old copies (`status` warns) |
| `/var/backups/ubicloud` | root | One database dump per day | §6.1; prune by hand |
| `/var/log/journal` | root | Service logs | journald's own cap |
| `/var/lib/ubicloud-migration/` | root | — | State of `migrate-from-dev.sh` (moved control planes only) |
| `/etc/postgresql/16/main/` | postgres | — | `pg_hba.conf` and `pg_ident.conf` carry a managed `# BEGIN ubicloud` block (install.sh rewrites it; edit outside it); `conf.d/90-ubicloud.conf` sets `listen_addresses` |
| `/usr/local/bin/ubicloud-admin`, `/etc/systemd/system/ubicloud*`, `/etc/caddy/Caddyfile` | root | — | Written from the current release |

Disk sizing for a busy control plane is UNVERIFIED.
