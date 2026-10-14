# Moving a development control plane to the packaged layout

This runbook moves a control plane that `scripts/byoh/bootstrap-ctrl-plane.sh`
(now `bootstrap-dev-ctrl-plane.sh`) set up to the packaged layout of
`scripts/byoh/install.sh`. The development setup has puma and respirate
in tmux, database `clover_test`, a superuser role `clover` and `trust`
in `pg_hba.conf`. The packaged layout has systemd units, database
`ubicloud`, peer authentication with non-superuser roles, and
`/etc/ubicloud/env`.

The tool is `scripts/byoh/migrate-from-dev.sh`, run one phase at a time.
The development database is **copied, never changed**. `copy-db` only
switches off its connections, so a rollback restarts tmux against it
exactly as it was at the copy.

**Status:** every phase passed in the container harness
(`scripts/byoh/test/run.sh migrate` and `migrate-preM1`; results in
`scripts/byoh/test/README.md`). Every step on the live control plane is
**UNVERIFIED** until the window.

## What each phase does

| Phase | Changes | Notes |
|---|---|---|
| `preflight` | Nothing; it writes `/var/lib/ubicloud-migration/state` (root 0600) | Checks are listed below. Every `fatal` line must be resolved first. |
| `install` | `/etc/ubicloud/env` from `.env.rb`, then `install.sh --no-start` | Nothing stops. The development control plane keeps serving. |
| `copy-db` | `<backup target>/pre-migration-<UTC>.dump`, database `ubicloud`, `clover_test` connections off | Refuses while tmux or the units run. |
| `start` | Enables and starts `ubicloud.target` | Refuses a rolled-back copy, or one whose `clover_test` accepts connections. Runs `install_rhizome` only if preflight found rhizome changes. |
| `flip-production` | `RACK_ENV=production` through `install.sh` | Window B; blocked on the E1 canary. |
| `rollback` | Disables the units; marks `ubicloud` rolled back; `clover_test` connections on | Prints the tmux commands to run. |
| `retire` | `pg_hba.conf` trust lines, role `clover`, `clover_test` renamed | At least 14 days later. |

**`preflight`** (read-only). It checks:
- `clover_test`'s `schema_migrations` and `schema_migrations_password`
  against the release's `migrate/` and `migrate/ph/` at `--ref`. A row
  the release lacks is a downgrade and fatal. The pre-M1 file
  `20260412000000_add_generic_provider.rb` is renamed by `copy-db`, in
  `ubicloud` only.
- The names of every key `.env.rb` sets. It loads `.env.rb` as the
  development user with an empty environment. If it fails to load, only
  the exception class and line are shown, never Ruby's message, which can
  quote a value.
  - `CLOVER_DATABASE_URL` and `GIT_REV` are dropped.
  - `RACK_ENV` becomes `--rack-env`.
  - `BILLING_RATES_EXTRA_DIR` becomes `/var/lib/ubicloud/billing_rates.d`.
  - `BASE_URL` becomes `--url` (default: `.env.rb`'s, without a trailing slash).
  - `MAIL_FROM` becomes `--mail-from` (default: `.env.rb`'s, then `--admin-email`).
  - Every other key is kept as it is and takes precedence over
    install.sh's defaults.
  - Fatal: names the env file cannot hold (M3-b), `PATH`/`LD_*`/`RUBYOPT`/`BUNDLE_*`
    and the like, `PRY_ALLOW_UNAUDITED`, a value with `'`, `\`, a newline
    or CR, an `IP_FROM_HEADER` other than the front's, a non-loopback
    `BIND`, `PORT` 8081.
- Every `password_env` in `host_provider.config`. Its value must come
  from `.env.rb` or from the environment of the running development
  respirate, and it is imported. One found only in respirate's
  environment is a `warn`: the rollback's tmux commands start respirate
  without it, so add it to `.env.rb` (a rollback names it again).
- The role that owns `clover_test`'s tables (`clover`). It is recorded
  for `retire`; `postgres`, `pg_*` and `ubicloud*` are fatal.
- The billing-rates directory exists.
- `cloudflared.service`: whether its `ExecStart` carries a token (yes/no),
  and which address its connections to port 3000 reach while it curls
  `BASE_URL`. Anything but `127.0.0.1:3000` is fatal, because the
  packaged puma listens on 127.0.0.1 only.
- Free disk: three times the database for postgres, and the dump size
  for the backup target.
- R0 (the development repo's `HEAD`, plus whether it has uncommitted
  changes), and whether `rhizome/` changed between R0 and `--ref`.

**`copy-db`** runs these steps:
1. It refuses (exit 2, nothing changed) when:
   - `ubicloud.target` or a unit is active
   - a development puma or respirate runs
   - a client is connected to `clover_test`
   - `ubicloud` already holds a finished copy (rolled back or not), unless `--i-understand-this-drops-live-data` is passed; the old copy is then kept as `ubicloud_prev_<time>`
2. It waits up to 150 s for `strand.lease` to end, and never forces it.
3. It runs `pg_dump -Fc`, counts the rows of every table, and switches
   `clover_test`'s connections off.
4. It builds the reference `ubicloud_ref`: a fresh migrate at this
   release. The database install.sh migrated serves when nothing ran on it.
5. It restores the dump into `ubicloud_restore` as role
   `ubicloud_restorer` with `--no-owner --no-acl`, never as a
   superuser, and the row counts must equal the source.
6. It applies the renamed migration, if any.
7. `migrate-role-map.sql` gives every object to `ubicloud`. What
   `clover_password` owned goes to `ubicloud_password`, and the
   password-hash grants are replayed.
8. The copy becomes `ubicloud`, and the pending migrations run as
   `ubicloud-migrate`.
9. It checks the result. `migrate-compare.sql` on the copy and the
   reference must agree on owners, ACLs, column ACLs, SECURITY DEFINER
   and `has_function_privilege('public', …)`, in both directions: an
   object only the reference has fails, and so does one only the copy
   has, except tables of `ubicloud` without grants (the
   `deleted_record_*` partitions respirate makes). `schema_migrations*` must
   equal the release's files. `bin/byoh-config-check` must report the
   password-hash isolation of role `ubicloud` as ok.
10. It drops `ubicloud_ref` and sets the comment
    `migrated-from clover_test <UTC>`.

A failure before step 10 leaves `ubicloud` marked `migrating-from`, and the
next `copy-db` drops it. `clover_test` stays switched off until `rollback`.

**Residual risk until `retire`:** the superuser `clover` and the trust
lines remain. Any local user can reach a superuser, and a superuser can
reach `ubicloud` indirectly, for example with `COPY … TO PROGRAM` as the
postgres OS user. The managed `pg_hba.conf` block keeps direct logins to
`ubicloud` peer-only. `ubicloud-admin status` reports this as a `fail`
until `retire`.

## T-1 day (no change to the running control plane)

1. Merge M3 into `byoh-driver`, after asking. Push only once the user approves.
2. Make a separate clone. `~/ubicloud` stays untouched at R0:
   ```
   git clone ~/ubicloud ~/ubicloud-m3
   git -C ~/ubicloud-m3 fetch byoh-fork && git -C ~/ubicloud-m3 checkout <M3 rev>
   git -C ~/ubicloud rev-parse HEAD     # record R0
   ```
3. Run the preflight:
   ```
   sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh preflight \
     --dev-user ubuntu --version v0.1.0-m3 --source-git ~/ubicloud-m3 --ref <M3 rev> \
     --admin-email <operator> --backup-recipient age1...
   ```
   - Resolve every `fatal` line.
   - If the pending list holds M1/M2 migrations, the window is also the
     schema upgrade, so add the CLAUDE.md §8 verification list to the checklist.
4. If preflight says cloudflared's origin is not `127.0.0.1:3000`, change
   the ingress in the Cloudflare dashboard now. The tmux puma on 0.0.0.0
   still serves it.
5. Build the tools ahead of time:
   `sudo bash ~/ubicloud-m3/scripts/byoh/install.sh --stage tools --source-git ~/ubicloud-m3 --ref <M3 rev>`.
6. Make off-box copies of `.env.rb` and of `pg_dump -Fc clover_test`,
   **age-encrypted to the backup recipient** before they leave the
   machine. Never put them under the repo's `backups/`. Delete any
   plaintext intermediate.
7. **Start the data-plane instance.** `start` runs `Sshable#cmd` on every
   host and fails on a host that does not answer.

## Window A: packaging and the database move (behaviour stays development; 30-45 min)

1. `sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh install`
   - It reuses the flags preflight recorded. If you give a flag again,
     it must be the same.
   - It reruns the preflight checks and refuses on a fatal finding.
2. Stop respirate and wait for it to exit. **Never kill it.**
   ```
   tmux send-keys -t respirate C-c
   while pgrep -u ubuntu -f 'ruby.*bin/respirate|bundle.*bin/respirate' >/dev/null; do sleep 2; done
   ```
   Graceful shutdown is bounded by apoptosis, about 91 s. Past 150 s,
   stop and investigate.
3. `tmux kill-session -t puma`, then `tmux kill-session -t respirate`
   (the second session may already be gone).
4. `sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh copy-db`
   must report the reference comparison, the row counts, the
   isolation and `schema_migrations` as ok.
5. `sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh start`
   runs `ubicloud-admin smoke`, then `status`. The trust `fail` is
   expected until `retire`; every other line must be ok or warn.
6. Verify:
   - login at `https://ubicust.dinanshubiswas.org`
   - the host strand advances (`ubicloud-admin logs respirate`)
   - VM create and destroy
   - `systemctl restart ubicloud.target`
   - `sudo ubicloud-admin backup now`
   - `ss -tln 'sport = :3000'` shows only 127.0.0.1 (the security group allows 3000 from one /32)
   - the audit rows show real client IPs (`CF-Connecting-IP`)
7. From now on, operators use `sudo ubicloud-admin …`. Do not run
   `bin/pry` or the tmux commands in `~/ubicloud`.

## Window B: the production flip (later; blocked on the E1 canary)

Window B needs a production-mode VM boot with ubuntu-noble on a
disposable canary that the user approves first.

1. `sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh flip-production`
   - It takes a backup, then runs `bin/byoh-config-check --simulate-production`.
   - Any fail exits 2 and changes nothing.
   - It then runs install.sh with `--rack-env production --update-env RACK_ENV`.
     Its step 12 runs `bin/production_check`.
2. What changes:
   - Sign-up mail goes to the logger (journald), so onboard users with
     `ubicloud-admin account create`.
   - Cookies are Secure, and HSTS is on.
   - The retry backoff grows up to 600 s.
   - The runtime is frozen.
   - There is no admin UI (M3-l).
3. Verify: `ubicloud-admin smoke`, and a VM with ubuntu-noble.
4. Roll back window B with
   `sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh flip-production --back`,
   which sets development again through install.sh.

## Rollback of window A

1. `sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh rollback` does the following:
   - It disables and stops `ubicloud.target`, and checks that it stays
     disabled and that port 3000 is free.
   - It marks `ubicloud` `rolled-back-from clover_test <UTC>`. From then
     on `start` and `retire` refuse it, because the development control
     plane may change `clover_test` after the copy.
   - It switches `clover_test`'s connections on again.
   - It warns, by name, about a BMC password variable that preflight took
     from respirate's environment rather than `.env.rb`.
   - It prints what the packaged control plane did after the copy: the VMs
     created, the pages opened, the strands that differ from `clover_test`,
     and whether `start` ran `install_rhizome`.
2. Destroy or record the VMs it lists, and review host-side changes
   (reboots, rhizome installs), **before** the development control plane
   runs on `clover_test` again.
3. As `ubuntu`, run the **R0 tmux commands** the rollback printed. For
   the live control plane (R0 at Ruby 4.0.7) they are:
   ```
   tmux new-session -d -s puma "cd /home/ubuntu/ubicloud && export PATH=/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/4.0.7/bin:\$PATH && RACK_ENV=development bundle exec puma -C puma_config.rb > /tmp/puma.log 2> /tmp/puma.err"
   tmux new-session -d -s respirate "cd /home/ubuntu/ubicloud && export PATH=/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/4.0.7/bin:\$PATH && RACK_ENV=development bundle exec bin/respirate > /tmp/respirate.log 2> /tmp/respirate.err"
   ```
   - These are the development bootstrap's own commands.
   - The R0 bootstrap has no M3 guard, and `UBI_FORCE_DEV` means nothing to it.
   - Do not rerun the bootstrap.
4. cloudflared needs no change.
5. The database `ubicloud` is kept. The next move needs
   `copy-db --i-understand-this-drops-live-data`, which keeps the old copy
   as `ubicloud_prev_<time>`.

## Retire (at least 14 days and 14 nightly backups after the copy, plus one passed restore drill)

```
sudo bash ~/ubicloud-m3/scripts/byoh/migrate-from-dev.sh retire --restore-drill-done
```

`retire` counts the backups made since the copy and refuses below 14. It then:
- puts the bootstrap's four trust lines in `pg_hba.conf` back to Ubuntu's
  `peer` and `scram-sha-256`, keeping the old file as
  `pg_hba.conf.before-retire-<UTC>`
- renames `clover_test` to `clover_test_retired_<date>` (never dropped)
  and runs `ALTER ROLE clover NOLOGIN NOSUPERUSER` (and `clover_password
  NOLOGIN`), in one transaction. The role is the one preflight and
  copy-db found owning the tables, never the database's owner; retire
  refuses `postgres`, `pg_*` and `ubicloud*` before it changes anything
- moves `~/.ubi-bootstrap` aside, so that install.sh no longer sees a
  development control plane
- runs `ubicloud-admin status`, which must then show no trust fail

After `retire` there is no rollback to tmux. `~/ubicloud/.env.rb` still
holds the secrets of `/etc/ubicloud/env`: keep the encrypted off-box
copy, then delete it.

Never run `rake setup_database[test]` or the test suite on the control plane.

## Rehearsal

`scripts/byoh/test/run.sh migrate` runs the whole runbook on a throwaway
container. It uses R0 = fc693b1e0, or `UBI_M3_R0`:
- the R0 bootstrap
- a seeded host, account and BMC variable
- preflight (first refused on a tunnel origin that is not loopback), install, the tmux stop, copy-db and start
- copy-db failing on an object only the reference has, then a rerun that cleans up and passes
- rollback across a `docker restart` (start then refuses the copy), then the printed tmux commands
- preflight on a `.env.rb` that fails to load (class and line only) and on a BMC variable only in respirate's environment
- preflight and copy-db refusing a downgrade, copy-db refusing a held lease after 150 s
- the re-cutover, a second rollback (naming the BMC variable), copy-db and start again
- flip-production, refused without `MAIL_FROM` and then passing, and `--back`
- retire, refused with the role `postgres`, then passing

`migrate-preM1` runs the cutover from aca70df27 (pre-M1: Ruby 4.0.2,
the 14-digit migration, about 140 pending migrations, rhizome changed).
