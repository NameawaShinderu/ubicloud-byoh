# Operating a packaged control plane

This page is for a control plane that `scripts/byoh/install.sh` installed
(systemd units, `/opt/ubicloud`, `/etc/ubicloud/env`, database
`ubicloud`). A development control plane (`bootstrap-dev-ctrl-plane.sh`,
tmux) moves to this layout with `docs/byoh/MIGRATE_FROM_DEV.md`.

Every command runs as root. `ubicloud-admin --help` lists all of them.
The rest of this page (the unit map, backups and restore, `env set`,
logs, the audit-partition deadline) is still to be written (M3 WP11).

## Release switch

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
   sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate
   ```

   This stops web, respirate and the backup timer. Respirate stops
   gracefully, which takes up to `TimeoutStopSec=100` while a strand
   finishes. Name the two services as well as the target: `systemctl
   stop ubicloud.target` alone can return while respirate is still
   stopping, and a backup taken then is older than its stop. `release
   migrate` and `use` count a unit that is still stopping as running.

4. **Back up.**

   ```
   sudo ubicloud-admin backup now
   ```

   The backup comes after the stop, so it holds the database as v1 left
   it. The plan put the backup before the stop, which would miss every
   strand that ran in between. `release migrate` refuses a backup that is
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
  sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate
  sudo ubicloud-admin release use v1
  sudo systemctl start ubicloud.target
  ```

  If v1's `ubicloud-admin` predates the `release` command, the newer one
  stays installed, so v1 can switch forward again. `release use` warns
  when this happens.

- **v2's migrations ran.** `release use v1` refuses. Go back to the
  backup from step 4 (`ubicloud-admin backup list`):

  ```
  sudo systemctl stop ubicloud.target ubicloud-web ubicloud-respirate
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
