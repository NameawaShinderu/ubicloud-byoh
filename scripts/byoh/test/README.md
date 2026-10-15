# BYOH container harness

Tests the packaged control plane (M3) in throwaway containers that run
systemd as PID 1. It runs on any docker host and never touches a real
server.

- Containers are named `ubi-m3-*`, join only the `ubi-test-net` network
  and publish no ports. A run removes only the containers it created
  (`UBI_M3_KEEP=1` keeps them).
- systemd 255 needs `--privileged` with a private cgroup namespace. It
  exits 255 without it. The harness never bind-mounts `/sys/fs/cgroup`.
- Logs go to `$UBI_M3_LOGS` (default: a new temp dir, printed at the end).
  Each container's systemd and curl versions go to `harness.log`: the
  login check depends on curl sending Secure cookies to `localhost` over
  plain http.

```
docker network create ubi-test-net              # once, if missing
scripts/byoh/test/run.sh --prepare-image        # ubi-m3-systemd
scripts/byoh/test/run.sh --prepare-tools        # ubi-m3-tools: install.sh --stage tools (~4-10 min)
scripts/byoh/test/run.sh --prepare-release      # ubi-m3-release: install.sh of the working tree
scripts/byoh/test/run.sh all                    # or: parity envfmt verify fresh rerun flags smoke kill restart reboot tls-provided tunnel backup admin devshim gate-journal migrate migrate-preM1 upgrade-manual
```

`--prepare-tools` runs `scripts/byoh/install.sh --stage tools` (packages,
pinned mise, Ruby and Node) on a bare `ubi-m3-systemd` container.
`--prepare-release` archives the working tree (untracked, non-ignored
files included) and runs the full `install.sh` from that tarball, as
release `t1`, with `--tls none` and a backup recipient generated in the
container. Each scenario then boots a fresh container from one of those
images. `boot_cp` installs the units of the working tree's
`packaging/systemd` over the release's, so a change to the units needs no
re-prepare, but a change to the code or to `install.sh`'s release steps
does.

`fixture.sh` holds test helpers only: `units` (the working tree's units
and `ubicloud-admin`, so a change to either needs no re-prepare),
`account EMAIL` and `as-service`/`as-migrate CMD` (a command in the
release with exactly the units' environment, parsed by systemd).

## M4 harness (`ubi-m4-*`)

`lib.sh` takes its container prefix from `UBI_TEST_PREFIX` (default
`ubi-m3`) and the systemd image from `UBI_TEST_SYSTEMD_IMAGE` (default
`ubi-m3-systemd`). These are set by the wrapper that sources it, not a
user override: `run.sh` pins both to the M3 values, because its
scenarios name `ubi-m3-*` containers directly. `cleanup` removes only the
recorded containers that carry the run's prefix and keeps the other
records in `created`. `m4-lib.sh` sources it with prefix `ubi-m4` and
its own state dir; only `UBI_M4_STATE`, `UBI_M4_LOGS` and `UBI_M4_KEEP`
change that (an inherited `UBI_M3_*` is ignored). It adds a fake
data-plane host:

- `Dockerfile.fakehost` (context `fakehost/`) is ubuntu:24.04 with
  openssh-server, sudo, iproute2, util-linux, pciutils and curl, and no
  systemd and no `/dev/kvm`. `/usr/sbin/sshd -D -e` runs as PID 1, so
  every auth event is in `docker logs`. Host keys are generated when each
  container starts, never in the image.
- User `ubuntu` has passwordless sudo. Its RSA login key is generated per
  run in `$STATE` (`fakehost_key`) and never committed.
- `/usr/local/bin/systemctl` is a shim: `reload`/`restart` of
  `ssh`/`sshd` behaves like ssh.service's `ExecReload`: it fails for a
  non-root caller (as polkit does over ssh), fails without signalling
  when `sshd -t` rejects the config (the old sshd keeps serving), and
  otherwise sends SIGHUP to the listener (sshd re-execs and rereads its
  config); `is-active` answers from `/etc/fakehost-active`, which the
  entrypoint writes from `docker run -e FAKEHOST_ACTIVE="docker ufw"`
  (an ssh session does not see the container's env); every other verb
  exits 0. Calls are logged to `/var/log/fakehost-systemctl.log`.
- `start_fakehost NAME [docker run args]` runs `ubi-m4-NAME` on
  `ubi-test-net` with no published ports, records it, installs the key
  and waits for port 22; `fakehost_ip NAME` gives its address.

```
scripts/byoh/test/m4-fakehost-check.sh   # builds ubi-m4-fakehost, checks it, cleans up
```

The check logs in from a second fakehost as `ubuntu`, and checks sudo,
the auth line in `docker logs`, no `/dev/kvm`, per-container host keys,
`is-active`, that `systemctl reload ssh.service` makes sshd reread a
drop-in (`Received SIGHUP` in `docker logs`, then `sshd -T`) and keep
serving, that a reload without sudo or with an invalid drop-in exits
non-zero without signalling sshd while logins still work, and that
cleanup keeps another prefix's records in a shared state file. It fails
if any `ubi-m4-*` container is left (not checked with `UBI_M4_KEEP=1`).
Result (2026-10-15, OpenSSH 9.6p1 Ubuntu-3ubuntu13.20): pass in about
6 s after the image build, nothing left behind; with `UBI_M4_KEEP=1` it
passes and keeps both containers.

### Root key install cases (WP9)

```
scripts/byoh/test/m4-install-key-cases.sh
```

Runs `ByohHostAdd::INSTALL_SCRIPT`, the script `byoh-host add` runs as
root to install the registration key, on a fakehost. The remote command
and stdin come from `ByohOperatorSsh#run_script` itself, rendered in a
`ubi-m4-render` container from `ubi-bundler-m1` (`UBI_M4_RUBY_IMAGE`),
and each case sends them over ssh from a second fakehost as `ubuntu`.
The cases: sshd already allows root key login (only `authorized_keys`
changes; cloud-init's forced-command line, another site's line and a
comment stay, a stale line with the same tag is replaced, and a re-run
leaves the file as it was); `PermitRootLogin no` after the `Include`
(the drop-in is written, sshd reloads and root logs in with the key);
and the failures 11 (an earlier drop-in wins, named on stderr), 12
(`sshd -T` fails), 13 (no `Include`), 10 (`sshd -t` fails) and 14 (no
reload). 10 and 14 use per-case shims in `/usr/local/sbin`, which sudo's
secure_path puts first. Each failure must leave no drop-in and sshd
serving. A socket-activated `ssh.socket` is not covered (no systemd in
the fakehost): UNVERIFIED.
Result (2026-10-15, OpenSSH 9.6p1 Ubuntu-3ubuntu13.20): all 7 cases pass
in about 10 s after the image build, nothing left behind.

### ubicloud-admin site, host and pool (WP10)

```
scripts/byoh/test/m4-admin.sh
```

Boots `ubi-m4-admin` from `ubi-m3-release` (`UBI_M4_RELEASE_IMAGE`; build
it with `run.sh --prepare-image --prepare-tools --prepare-release`). It
extracts the working tree over that release, which works because M4 adds
no migration and no gem, and installs the working tree's `ubicloud-admin`
and units. It checks:

- `site add --rates-from` writes `billing_rates.d/<name>.yml` and
  restarts `ubicloud.target` (web gets a new PID). A `site rates` that
  changes no file, and `site set`, restart nothing.
- `site show NAME` and `site --help` work.
- These exit 2: `--postgres yes`, `--mgmt wireguard`, an unknown verb and
  `--bmc-password`.
- The `UBICLOUD_ADMIN_DRYRUN=1` mappings of `site add` and of the
  two-phase `host add`.
- `--dev` and `UBICLOUD_ADMIN_DEV=1` are refused on the packaged layout.
- With the real `byoh-host` and an unknown site, the failed prepare phase
  stops the run before register.
- With a Ruby probe in place of `bin/byoh-host`:
  - the register phase gets neither key option;
  - the staged key copies are gone (a listing of the staging directory
    holds only the two pool file copies);
  - `byoh-keys/` was made `ubicloud` 0700, although the release's
    `install.sh` predates it.

The script does not cover the dev layout. Its runs were checked by hand
in a throwaway `ubi-m4-devadm` ubuntu:24.04 container with a stub
`bundle`: running as `SUDO_USER` through `runuser`, relative files made
absolute, and the exit-2 refusal for root without `SUDO_USER`.

Result (2026-10-15): passes in about 50 s, and nothing is left behind.

### Host preflight fixtures (WP5)

```
scripts/byoh/test/preflight-fixtures.sh [--update-spec] [CASE...]
```

Runs `scripts/byoh/host/ubicloud-host preflight --json` once per case in
`fixtures/host/` (a throwaway `ubi-m4-pf-<case>` container from
ubuntu:24.04, `--rm`, no ports). It feeds the script on stdin, as
`bash -s`, the way the control plane runs it over ssh. A case is
`fixtures/host/base` (a sound x86 host) with the case's own files laid
over it; `.remove` lists base files the case deletes. The script reads
every file under the fixture root and every command's output from
`cmd/<key>` (exit status in `cmd/<key>.rc`); `bin/<tool>` marks a tool
as installed and `dev/kvm.chardev` stands for the `/dev/kvm` character
device. Test mode needs both `--fixture-root` and
`UBICLOUD_HOST_TEST_ROOT`, set to the same directory; the run checks that
the flag alone exits 2.

Each case asserts its `expect` (`ID STATUS`) and `detail` (`ID DETAIL`)
lines. Every case must also exit 0, print each check exactly once, print
every fact, and print nothing else under its nonce. `noisy-bashrc` runs
with a `BASH_ENV` that prints banners, a `UBIPF:` line under another
nonce and output with no trailing newline. The last run uses the
`ubi-m4-fakehost` image with real commands and no fixtures, and must
fail PF3 with `no /dev/kvm`.

The fixture outputs are synthesised. In particular, `arm-biglittle`,
`intel-hybrid`, `amd-uniform`, `ebs-nvme`, `lvm` and `gpu-nouveau` were
not captured on such hardware, so they are UNVERIFIED as real outputs.
The PF15 network calls are shimmed (`cmd/curl`, `cmd/apt-get`).

`--update-spec` writes each raw output to
`spec/fixtures/byoh/preflight/<case>.txt`. Two specs read those files:
`spec/lib/byoh_host_preflight_spec.rb` parses them, and
`rhizome/host/spec/kvm_check_parity_spec.rb` checks that `KvmCheck`, which
PrepHost runs, gives each fixture host the same PF3 verdict as the
script, except on kvm64-class CPU models, which only the script refuses
(`kvm64-vmx` has /dev/kvm and vmx, so KvmCheck passes it). Rerun the script with `--update-spec` after changing it or the
fixtures. Result (2026-10-15): 23 cases plus base, the guard and the
live run pass in about 25 s, with nothing left behind.

## Scenarios

| Scenario | Checks |
|---|---|
| `envfmt` | systemd's `EnvironmentFile=` and bash's `set -a; . F` read the `KEY='value'` lines of `/etc/ubicloud/env` the same way. The run fails if the set of differing cases changes. |
| `fresh` | One `install.sh` run on `ubi-m3-tools` (no release yet): units active and `ubicloud.target` enabled, monitor disabled, puma only on 127.0.0.1:3000, postgres `listen_addresses` localhost. Roles `ubicloud`, `ubicloud_password` and `ubicloud_restorer` are not superuser, createdb or createrole, and `ubicloud_restorer` is an inheriting member of the other two; the managed hba block is the first rule and has no trust or password method; OS user `ubicloud` gets role `ubicloud` but not `ubicloud_password`, `ubicloud-migrate` gets both, TCP logins to database `ubicloud` are refused, and `ubicloud_restorer` logs in only from `ubicloud-migrate` and only to `ubicloud_restore`. `/etc/ubicloud/env` and `backup.conf` are root 0600, the env file has the full key set and no `PRY_ALLOW_UNAUDITED`, `GIT_REV` or (with `--tls none`) `IP_FROM_HEADER`. Nothing under `/opt/ubicloud` is writable by `ubicloud` or `ubicloud-migrate` or owned by anyone but root. `.bundle/config` carries deployment and the without-list. `byoh-config-check` has no fail and reports the role check ok. The shipped `cache/*.cache` equal a `refresh_sequel_caches` run (as `ubicloud-migrate`, in a scratch copy) against the installed schema. An account logs in. No `*ubi-bootstrap*` file exists. Step 12 (`ubicloud-admin smoke`) printed ok for puma, web, respirate, `byoh-config-check` and `production_check`. With `MAIL_FROM` removed from the env file by hand, `smoke` exits 1 on the `byoh-config-check` fail. With port 8081 taken, a rerun of install.sh exits 1 at step 12 with the `ubicloud-admin logs` hint and changes nothing, and `smoke` passes once the port is free. With `PORT='8081'` in the env file, install.sh exits 2 and changes no file, `ubicloud-admin env set PORT` refuses 8081, and `smoke` (web restarted on 8081) fails naming `PORT`. A `bin/production_check` that fails (a bind-mounted stand-in) makes `smoke` print its output and fail. A release whose `ubicloud-admin` has no `cmd_smoke` (bind-mounted) makes step 12 warn and install.sh exit 0; the next run installs the current one and passes. |
| `rerun` | `install.sh` again with identical arguments: exit 0, no `changed` line, the env, backup, hba, ident and unit files byte for byte, the MainPIDs kept. `--version t2` exits 2 and names the release switch. A different `--mail-from` exits 2 naming only the key, and with `--update-env MAIL_FROM` updates it and restarts the services. A deleted key is appended by name. `PRY_ALLOW_UNAUDITED` in the env file, a malformed line, and another rev for `t1` exit non-zero without printing a value or changing a file. |
| `flags` | Usage errors (`--mgmt-endpoint`, `--smtp` on argv, `--tls acme`, an https URL with `--tls none`, a bad version, an `s3://` target, `--cert`, `--import-env-rb`, an unknown stage, no source) exit 2 and create nothing. `--source-git` on a repository owned by another user, with `--ref HEAD`: the release rev is that commit. `--smtp-file` refuses mode 0644, and at 0600 writes `MAIL_DRIVER=smtp` and the `SMTP_*` keys without printing the password. `--billing-rates-dir` copies the files, owned by `ubicloud`. A postgres listening on `*` is set back to localhost with a restart notice. `--no-start` neither enables nor starts the target, and skips step 12. A rerun and a `--stage tools` rerun change nothing, and `--rack-env development` serves; its step 12 skips `production_check`. |
| `parity` | No container: `kv_read`, `valid_value`, `KEY_RE`, `DENIED_KEY_RE` and the lock path are the same in `install.sh`, `ubicloud-admin` and `migrate-from-dev.sh`, which each carry a copy, and `INTERP_KEY_RE` in the last two. |
| `verify` | `systemd-analyze verify` is clean. web and respirate are ordered after `postgresql@16-main` and `network-online.target` without `Requires=`. Monitor is installed but disabled. `ubicloud-backup.service` runs `ubicloud-admin backup now` and writes a backup. Writes the `systemd-analyze security` report. |
| `smoke` | Every unit is active. An account is created and logs in over the two-step login. puma listens only on 127.0.0.1:3000, also with `BIND` and `PORT` removed from the env file. The release is read-only to `ubicloud`. web, respirate and monitor each run with no capabilities (effective and bounding) and NoNewPrivs. A rerun of `install.sh --no-start` while the services run (so that step 12, which runs as `ubicloud`, does not rewrite the files first) leaves `pg_hba.conf` and `pg_ident.conf` byte for byte, and its migrate as `ubicloud-migrate` rewrites the `var/ca_bundles` files web wrote; web then rewrites them again. A rerun with another rev exits 2. The journal has no Ruby errors. |
| `kill` | A: SIGKILL to the respirate child; restarter keeps its PID and respawns within 4 s. B: `systemctl kill -s KILL`; a new MainPID within 5 s. Both: a strand runs within 150 s. |
| `restart` | `systemctl restart ubicloud.target`. A stop while an idle child runs ends with `Result=success`. A stop while restarter sleeps between children ends quickly, with no ESRCH and no leftover process. A running backup (a stand-in drop-in) survives a restart and a stop of the target, and the stop pauses the timer. Then, with strands held in a query by a lock on `vm_host`: a stop with one running strand, a stop past a shortened `TimeoutStopSec`, and a stop with every dispatcher thread busy (below). |
| `backup` | `ubicloud-admin` backup and restore, with a Sshable on a plain sshd container (`ubi-m3-sshd`, ubuntu:24.04) whose private key is an encrypted column, so a working `Sshable#cmd` proves the restored column key. `backup now` writes `db.dump`, `globals.sql`, `billing-rates.tar` and `manifest.json` (0600 in a 0700 directory) and `secrets/TS.age`, which holds `etc/ubicloud/env` and is encrypted. Refused with exit 2 and no change: a dump whose sha256 differs, a dump that matches a rewritten manifest but that `pg_restore --list` cannot read, a `--key-file` of no recipient, an env file with another column key (also with `--db-only`), and a backup whose env file sets `RUBYOPT`. `--env-only --force` over another column key installs the backup's env file, keeps the old one as `env.before-restore-*` (root 0600) and restarts web. `--db-only` with the matching key restores the database and keeps the env file. A dump with a table owned by `postgres` fails in `pg_restore` (`must be able to SET ROLE "postgres"`), because it runs as `ubicloud_restorer`, and changes nothing. A `--force` restore whose migrations fail (a failing migration added to the release) exits 1 and puts back the old database, env file, `backup-recipients` and billing rates, with the services running; without the failing migration the same restore installs the backup's files and keeps the replaced env file. A restore over the live database keeps it as `ubicloud_prev_*`; an account made after the backup is gone and `status` passes. With the services stopped, database `ubicloud` dropped and the env file deleted, a restore brings back the same env file (root 0600), and `Sshable#cmd`, login, the password-hash migrations, the owner of `public` and `status` are all as before. `prune --keep 1` keeps the newest backup and its secrets and leaves `pre-migration-*` alone. A `backup now` started while a restore runs waits for the lock and finishes after it. `ubicloud-backup.service` succeeds. |
| `admin` | `ubicloud-admin` refuses non-root and unknown commands. `account create` reads a relative `--password-file` that only root can read, and a generated password is printed but never reaches the journal. `env set` takes the value on stdin, never prints it, restarts web (new MainPID) and waits until it answers, keeps the file root 0600; `env get` needs `--reveal`; denied keys (`PATH`, `LD_*`, `PRY_ALLOW_UNAUDITED`, the column key, `GIT_REV`, `IP_FROM_HEADER`, lower case) and values with a quote, backslash, newline, NUL or nothing exit 2 and change nothing; `--no-restart`, `keys` and `unset` work. `status` passes, and fails on `PRY_ALLOW_UNAUDITED` in the env file, a missing backup recipient and a `trust` rule. `run` refuses unknown tools and every spelling OptionParser reads as `--bmc-password` (`--bmc-passw=`, `--bmc_password=`, `--BMC-PASSWORD=`, `--b-password`, `--b-passw=`, `--Bmc_Passw`, the ambiguous `--bmc-pass`) but not `--bmc-pass-env` or `--b-pass-env`, runs `byoh-location`, `byoh-config-check`, `create_prod_admin_account` and `production_check` from `/`, and writes `--out` back to the caller's relative path (root 0600). Staged input files are `root:ubicloud` 0440 in a `root:ubicloud` 0750 directory that `ubicloud` cannot write, and an `--out` that the tool made a symlink to `/etc/shadow` is refused. `env set` refuses the secrets, install.sh's flag keys and code-loading keys (`RUBYOPT`, `BUNDLE_*`, ...), `env unset` refuses the keys config.rb requires, and an `env set` of a `CLOVER_DATABASE_URL` web cannot start with exits 1 and puts the old file back. `console -e`, `console -e -` (code on stdin) and `console` (pry on stdin) run unaudited and say so, with one system log line each, and the code stays out of the journal; a raise exits 1. With `OTEL_EXPORTER_OTLP_ENDPOINT` set to a small receiver in the container, `console -e -` says nothing about being unaudited and its code and session line reach the receiver. `logs web` prints. |
| `devshim` | The development bootstrap and its shim on `ubi-m3-tools`, as user `ubuntu` (passwordless sudo, as on cloud images) with the source extracted at `~/ubicloud` and `UBI_START_SERVICES=0`. Refused with exit 1, no marker and `pg_hba.conf` unchanged: `UBI_RACK_ENV=production`, `UBI_DB_NAME=ubicloud`, an existing `/etc/ubicloud/env`, an enabled and an active `ubicloud.target` (a stand-in), and the shim read from a pipe with no checkout at `UBI_REPO_DIR` (it names `git clone` into that path), with a checkout from before the rename (it names `git -C … pull`, not a clone) and with a directory that is no checkout. Then `bash ~/ubicloud/scripts/byoh/bootstrap-ctrl-plane.sh` warns, names its target and creates `clover_test` (migrated, roles `clover` superuser and `clover_password` as before, `.env.rb` 0600 with `RACK_ENV` development, assets built with `npm ci`). A second run by path and `cat` of the shim piped to `bash` from `/tmp` skip every step. Run from disk, the shim takes the development script beside it: a second copy of `scripts/byoh` names its own script and succeeds, and `UBI_REPO_DIR` pointing nowhere still names `~/ubicloud`'s. Without the `bundle-install` marker, step 6 runs `bundle install` although `bundle check` passes. Step 3 rerun over the existing roles and database succeeds without errors; a `refresh_sequel_caches` that fails (read-only `cache/`) exits 1 and sets no marker. `UBI_FORCE_DEV=1` with `/etc/ubicloud/env` warns and runs. `m2-gate.sh g1` picks tmux mode, fails on the missing puma and passes the `.env.rb` key. |
| `gate-journal` | `scripts/byoh/verify/m2-gate.sh` on a packaged control plane (`ubi-m3-release`): `g1` as root detects systemd, passes the web and respirate units, reports monitor as INFO (FAIL with `GATE_EXPECT_MONITOR=1`) and reads `BILLING_RATES_EXTRA_DIR` through `ubicloud-admin env get --reveal`; as `ubuntu` without sudo, with the key unset, and with `BILLING_RATES_EXTRA_DIR` under `/home` (directly or through a symlink, which `ProtectHome=yes` hides from the services) or in a directory user `ubicloud` cannot write, it fails naming the cause. With the units installed but `ubicloud.target` disabled and stopped, and stand-in `puma` and `bin/respirate` processes, `g1` is in tmux mode and passes on them and `.env.rb`, and the log is `/tmp/respirate.log`; enabled again, it is systemd. `probe_verdict` (G7) finds ok, gave-up (which wins) and missing in a 30000-line file, reads the journal, and returns 1 on a missing log. The gate's `respirate_log` reads the journal of `ubicloud-respirate.service` as root and as a member of `adm`, fails for a user with neither access nor sudo, and is `/tmp/respirate.log` with `GATE_SERVICES=tmux`. |
| `migrate` | `migrate-from-dev.sh` end to end (docs/byoh/MIGRATE_FROM_DEV.md) on `ubi-m3-tools`. Setup: `~ubuntu/ubicloud` is a one-commit git checkout of R0 (fc693b1e0, or `UBI_M3_R0`) set up by R0's own bootstrap, and `~ubuntu/ubicloud-m3` a clone with the working tree committed on top. `.env.rb` gets `BASE_URL`, `BILLING_RATES_EXTRA_DIR`, a BMC password variable, `DB_POOL_WEB=20` and `IP_FROM_HEADER`. A location with rates, a host registered by `bin/register-byoh-host` (Sshable on `ubi-m3-sshd`, BMC `--bmc-pass-env`, its strand parked at `wait`) and an account are seeded, then the bootstrap's tmux commands start puma and respirate, and login and `Sshable#cmd` work. A stand-in `cloudflared.service` with a token on its command line holds connections to the origin. `preflight` exits 1 naming a tunnel origin on the container address, then passes with origin 127.0.0.1 (argv token reported, BMC variable found, no pending migrations, rhizome unchanged, no secret printed). `install`: every `.env.rb` key is in `/etc/ubicloud/env` with its value, except the rewritten `RACK_ENV`, `BILLING_RATES_EXTRA_DIR` and database URL; `DB_POOL_WEB` stays 20; rates copied; nothing started; the tmux puma still serves. `copy-db` refuses (2) while tmux runs. After the C-c stop, with a column grant (`SELECT (id) ON strand TO ubicloud_password`) added only to the pristine database that becomes the reference, it exits 1 naming `only in the reference: col|strand.id`, leaves `ubicloud` marked `migrating-from` and `ubicloud_ref`, and keeps `clover_test` off; the rerun drops both and passes (row counts, reference comparison, isolation, `schema_migrations`), `clover_test` no longer accepts connections, and a second run refuses (2). `start`: Sshable ok, the trust fail in status, port 3000 on loopback only, login with the development account, `Sshable#cmd`, and the host strand in the respirate journal after `incr_configure_metrics`. `rollback` lists the host strand's move, gives no BMC warning (the variable is in `.env.rb`) and marks `ubicloud` `rolled-back-from`, and `start` then refuses (2); across `docker restart` the target stays disabled; the printed R0 commands serve `clover_test` with login and `Sshable#cmd`. A `.env.rb` with an unquoted token makes `preflight` exit 1 with `NameError at line N` and without the token. With the BMC variable removed from `.env.rb` and given only to a restarted tmux respirate, `preflight` passes with a warn and records it. Re-cutover: with a fake applied migration in `clover_test`, `preflight` exits 1 (downgrade) and `copy-db` 2; with a strand lease held an hour, `copy-db` waits 150 s and exits 2 with `clover_test` and the databases unchanged. `copy-db` refuses the rolled-back copy without `--i-understand-this-drops-live-data` and keeps it as `ubicloud_prev_*` with it. A second `rollback` warns naming the BMC variable (no value); `start` refuses (2) until another `copy-db`, then passes. `flip-production` with `MAIL_FROM` removed exits 2 with `RACK_ENV` unchanged; restored, it flips, step 12 runs `production_check`, login and smoke pass; `flip-production --back` returns to development and login works. `retire` refuses under 14 backups, and (2, `pg_hba.conf` and `clover_test` unchanged) with `DEV_ROLE='postgres'` put in the state file; then with `--skip-backup-count` restores peer/scram, makes `clover` NOLOGIN NOSUPERUSER, renames `clover_test` to `clover_test_retired_*`, moves `~/.ubi-bootstrap` aside, and `status` passes. |
| `migrate-preM1` | The cutover of `migrate` from aca70df27 (aws-mumbai-working-v1: Ruby 4.0.2, the 14-digit generic-provider migration): preflight notes the rename, the pending migrations and the rhizome changes; copy-db renames the row in `ubicloud` only and runs the pending migrations; start runs `install_rhizome`; login, `Sshable#cmd` and the host strand work; `clover_test` is unchanged. |
| `upgrade-manual` | The WP10 release switch (docs/byoh/OPERATIONS.md, release switch) on `ubi-m3-release`. t2 is the working tree plus a dummy file; t3 is t2 plus a migration dated today (rake-task-runner allows dates up to five days ahead); t4 and t5 are `cp -a` copies of t3, t4 with `cmd_release` renamed in its `ubicloud-admin` and the newest `built=`, t5 with a second migration, dated tomorrow, that raises. `install.sh --stage release --version t2` builds t2 root-owned and changes neither `current`, the managed files nor the MainPIDs; a rerun changes nothing; another rev for t2 and a settings flag exit 2. While the services run, `release use` and `release migrate` exit 2. Then t1 -> t2 (stop, `backup now`, `release migrate` with nothing to apply, `release use`, start): web runs in `releases/t2`, login and `status` pass, and `status` has the release line. t2 -> t1 is allowed (no new migrations); t1's `ubicloud-admin` has `release` too. For t3, `release use` before `release migrate` exits 2. `release migrate t3` exits 2 with a backup taken after the stop of respirate but before the stop of web (naming web), with that backup after a `docker restart` with `ubicloud.target` disabled (naming the boot), and with a backup whose manifest lacks one migration. t5's migrate exits 1 with its first migration applied and names the backup to restore; a rerun passes the backup check on that backup (naming the migration that ran) and fails again, also after a `backup now` of the half-migrated database, and `restore --db-only` of that backup on t1 drops the first migration. Then t3: migrate (naming the backup), use, start and `status` pass. On t3's schema, `release use t1`/`t2`, `release migrate t2`, `release check t2` and `--for-restore` with a backup that has t3's migration all exit 2 with `current` unchanged. Going back: `release use t2 --for-restore <pre-t3 backup>` writes the hold; `systemctl start ubicloud-web` fails, `systemctl start ubicloud.target` starts neither web nor respirate, and neither starts after a `docker restart` with the target enabled; `status` fails naming the downgrade and the hold; `restore --db-only` lifts the hold (no hold file or drop-in left) and drops t3's table, then login and `status` pass and `release list` shows t2 `current`/`matches` and t3 `previous`/`1 to apply`. `release migrate t3 --skip-backup-check` over a stale backup warns and migrates. t4 with a group-writable `Gemfile` makes `use` exit 2; with `ruby = "0.0.1"` in its `mise.toml`, `check`, `migrate` and `use` exit 2 naming it; `use t4 --for-restore 20000101T000000Z` exits 2; then `use t4` warns that its `ubicloud-admin` has no release command and leaves `/usr/local/bin/ubicloud-admin` byte for byte. `release prune --keep 1` with current t4 and previous t3 removes t1, t2 and a leftover `t9.tmp`; after `use t3` (current t3, previous t4, the newest) it removes nothing. |
| `reboot` | `docker restart`: the target starts at boot, web answers, and strands run. A real VM reboot is UNVERIFIED. |
| `tls-provided` | The E0 HTTPS gate: one `install.sh --tls provided` run on `ubi-m3-tools` with a self-signed certificate for `cp.test` and `--url https://cp.test`. Refused first, with exit 2 and nothing created: a certificate for another host, the key of another certificate, a missing key, `--cert` with `--tls none`, an http URL, a URL with a port. Then: caddy (Ubuntu universe) active and enabled; `https://cp.test` answers through caddy with the given certificate (verified with `--cacert`, not `-k`); http redirects to https (308); the caddy admin API on 127.0.0.1:2019 refuses connections; puma listens on 127.0.0.1 only; `/etc/ubicloud/tls` is `root:caddy` 0750 with the key 0640; `IP_FROM_HEADER='X-Real-IP'`; `byoh-config-check` reports the client-IP check ok. An account logs in over HTTPS, and the audit log records the container's address as caddy sees it, not 127.0.0.1 and not the `X-Real-IP` the client sent. Step 12 GETs `https://cp.test` through caddy (`--resolve`) and runs `production_check`. `ubicloud-admin smoke` with `front.conf` at `acme` and `BASE_URL` `https://nocert.test`, a name caddy has no certificate for, warns (curl exit 35, a certificate not issued yet) and passes; with caddy stopped it fails on `caddy.service is inactive`; an `http://` `BASE_URL` and an unknown `TLS_FRONT` fail. A rerun changes no file and restarts nothing (web, respirate, caddy). A reissued certificate with 10 days left warns, is installed and served (serial checked with `openssl s_client`), and restarts caddy only. install.sh's own `render_caddyfile` with `--tls acme` adapts with `caddy adapt`: admin off, the `--admin-email` ACME account, `X-Real-IP` set and `CF-Connecting-IP` dropped (a real ACME run is UNVERIFIED). Switching back to `--tls none` exits 2 naming `BASE_URL`, `IP_FROM_HEADER` and `TLS_FRONT` and the exact `--update-env` flags, and with them stops and disables caddy and removes `IP_FROM_HEADER`. |
| `tunnel` | From `ubi-m3-release` with a stand-in `cloudflared.service` that has a token on its command line (the live case): `--tls tunnel --update-env BASE_URL --update-env TLS_FRONT` leaves that unit byte for byte with the same MainPID, warns that its token is on the command line without printing it, prints the `http://127.0.0.1:3000` ingress reminder, installs no unit of its own and sets `IP_FROM_HEADER='CF-Connecting-IP'`; step 12 only warns that `https://cp.example.test` does not resolve (curl exit 6), and passes; with the name pointed at a local TLS stand-in for Cloudflare's edge (its certificate in the CA store), `smoke` passes on 200, warns on 530 (a tunnel without a connector) and fails on 404, and fails when `cloudflared.service` is stopped; a login carrying that header is recorded with its address; a rerun changes nothing. Next to that running unit, `--tls provided` exits 2 (puma would trust an `X-Real-IP` the tunnel passes through) and `--cloudflared-token-file` exits 2 (it would never be used), both changing nothing; stopped and disabled, the unit is warned about and step 12 fails on it (exit 1). With the stand-in removed: no token file exits 2, a 0644 token file exits 2, and a 0600 one installs the pinned cloudflared (sha256-checked) and `ubicloud-cloudflared.service` (`systemd-analyze verify` clean) with the token as a `LoadCredential=` credential, copied to `/etc/ubicloud/cloudflared.token` root 0600. The token is a dummy, so cloudflared answers "Provided Tunnel token is not valid.", which proves it read the credential, and since the unit is `Type=notify` it stays `activating`, which step 12 warns about as a tunnel still connecting; the token is on no command line and not in the unit. Reruns with and without the token file change no file (the dummy token makes each one start the unit again). With no caddy candidate (an apt pin), a switch to `--tls provided` exits 2 before any change and the tunnel stays enabled. `--no-start --tls none` with `--update-env` leaves `ubicloud-cloudflared` running and `front.conf` at `tunnel`; the run without `--no-start` then names only `--update-env TLS_FRONT`, and with it stops and disables `ubicloud-cloudflared`, keeps the token copy and records `none`. A real tunnel is UNVERIFIED. |

## Results (2026-10-14, systemd 255.4-1ubuntu8.17, curl 8.5.0)

Ranges cover three runs: two full runs, then every scenario again after
the review fixes.

- **envfmt:** inside single quotes, both parsers read `$`, `#`, `\`,
  tabs, CR and leading or trailing spaces literally. Only text after
  the closing quote differs (`KEY='ab' # c`: systemd keeps `ab# c`, bash
  drops the comment). So a writer must end each line at the closing
  quote. The M3-b validator still rejects `'`, `\`, newline and NUL in
  values.

- **kill A** (SIGKILL to the respirate child): restarter kept its PID
  and spawned a new child after 1.1-2.3 s (`RESTART_MAX_SLEEP=2`). The
  probe strand ran 3.3-4.1 s after the poke.
- **kill B** (`systemctl kill -s KILL`): a new MainPID after 1.1 s
  (`RestartSec=1`), and the probe strand ran after 3.7-4.3 s. In this
  container `systemctl kill` exits 1 with "Failed to send signal SIGKILL
  to auxiliary processes: Invalid argument" even though it kills the
  unit, so the harness judges by `NRestarts` and the MainPID.
- In kill A and B the probe strand was napping, not leased, when the
  process died. The lease case is measured in `restart` below.
- **restart:** `systemctl restart ubicloud.target` took 0.4-0.5 s on an
  idle control plane. Stopping respirate while an idle child ran took
  0.6-0.7 s, and stopping it during restarter's pause took 0.6-1.6 s.
  Both ended with `Result=success` and left no process or ESRCH behind.
- **Stops with strands running** (one run). respirate gives running
  strands 2 s after TERM and then exits 1, but a strand thread waiting in
  a database query holds that exit until the query returns:
  - One strand in a query, the lock released 8 s into the stop: the stop
    took 8.2 s and ended `Result=exit-code`, status 1. The strand ran
    again 3.9 s after respirate restarted.
  - The same with `TimeoutStopSec=10` (a drop-in): SIGKILL after 10.2 s,
    `Result=timeout`. The strand ran again 110 s after respirate
    restarted, when its 120 s lease expired.
  - Every dispatcher thread busy and the queue full: the scan thread
    cannot start the shutdown, and apoptosis ended respirate 85.9 s into
    the stop (91 s after the first strand started), status 2, with no
    SIGKILL. This is why `TimeoutStopSec=100`.
  - A stop that leaves a strand behind ends `Result=exit-code`, so the
    unit shows as failed until the next start. So does a TERM that
    reaches respirate before it installs its trap (status 143, seen when
    the target is stopped right after a restart).
- **reboot** (`docker restart`): web answered 3.2-4.6 s after boot, and a
  strand ran. A real VM reboot is UNVERIFIED.
- **Hardening:** every directive in the units was kept. `systemd-analyze
  security` rates web and respirate 3.5 ("OK").
- **Backup:** a running backup is not stopped or restarted with the
  target, because `ubicloud-backup.service` is not `PartOf` it. Its timer
  is, so stopping the target pauses scheduled backups until the target
  starts again. Until WP6 installs `ubicloud-admin`, the service is
  skipped on `ConditionFileIsExecutable=`, so the 03:15 run does not
  leave the system degraded.

## TLS front results (2026-10-14, caddy 2.6.2-6ubuntu0.24.04.3, cloudflared 2026.9.3)

- `tls-provided` and `tunnel` passed; the one-command `--tls provided`
  install (release build included) took about a minute on `ubi-m3-tools`.
- systemd mounts a unit's credentials in a child mount namespace and
  moves them into `/run/credentials`, which reaches the service only
  when `/` is a shared mount. systemd makes it shared at boot on a real
  machine, but not in a container, where `LoadCredential=` therefore
  failed ("Failed to read token file: open
  /run/credentials/ubicloud-cloudflared.service/token: no such file or
  directory"). `start_sys` runs `mount --make-rshared /` inside the
  container after boot. `ubicloud-cloudflared` on a real machine, where
  systemd does this itself, is UNVERIFIED: no VM was booted.
- Caddy's `admin off` also disables `caddy reload`, so `systemctl reload
  caddy` fails; install.sh restarts caddy when its Caddyfile or
  certificate changes.
- With a token that cloudflared rejects, `ubicloud-cloudflared` restarts
  every 5 s, and install.sh warns after 15 s instead of failing, because
  the tunnel connects in the background.

## ubicloud-admin results (2026-10-14, systemd 255.4-1ubuntu8.17)

`parity`, `backup` and `admin` passed, then every scenario in one
`run.sh all` on a release that install.sh built from this tree.

- A restore of the harness database (499 migrations, about 1 MB dump)
  takes about 6 s from check to `status`, most of it the service start.
- `pg_dumpall --globals-only` runs with `--no-role-passwords`: on a
  control plane moved from the development bootstrap, role `clover` has
  a password hash, which a backup has no use for.
- Commands run with `LANG=C.UTF-8`. Without it Ruby reads puma's UTF-8
  output as US-ASCII and `production_check` dies with "invalid byte
  sequence in US-ASCII".
- `console` and `console -e` run `ruby --enable-frozen-string-literal
  bin/pry`: ruby ignores the switch in bin/pry's shebang when it is
  given the script, and without it `Sshable#cmd("...")` raises
  `Command::PotentialInsecurity` for an unfrozen literal.
- Two `env set` restarts in a row can stop puma while it loads the app,
  and puma_config.rb's `after_stopped` then raises NameError for
  `CONNECTION_CHECKOUT_TELEMETRY` (harmless: the process is stopping).
  `env set` waits until web answers again before it returns.
- A real machine, a real reboot between backup and restore, and a
  restore onto a second machine are UNVERIFIED.

## Findings the installer handles

The WP3 fixture hit these first; `scripts/byoh/install.sh` handles each:

- mise adds `site_ruby/rubygems_plugin.rb`, which runs `mise reshim`
  after every gem install. With no mise on the PATH, `bundle install`
  fails with "No such file or directory - mise" (the live error of
  2026-10-13). Remove the plugin from the tools ruby.
- mise replaces `node/<v>/bin/npm` with a reshim wrapper that finds npm
  relative to the path it is run as. Link `tools/bin/npm` and `npx` to
  `lib/node_modules/npm/bin/npm-cli.js` and `npx-cli.js` instead.
- Build the tools under `umask 022`. The installer's `umask 077` makes
  them unreadable to the service users.
- Under `umask 077` the release also needs `chmod -R a+rX,go-w` after the
  build, not only `go-w`, so that `ubicloud` can read it.
- Migrations as `ubicloud-migrate` create `var/ca_bundles` and their lock
  files, which web and respirate open read-write at boot. Run
  migrations with `UMask=0007`, and give the services `UMask=0007` too,
  not `0077`, so either side can rewrite the other's files through the
  shared `ubicloud` group. `smoke` tests both directions. A restore
  (WP6) is not tested yet. `/var/lib/ubicloud` is root:ubicloud 0750
  (only `var/` and `billing_rates.d/` belong to `ubicloud`) and holds no
  secrets.
- Replace the managed `# BEGIN ubicloud` .. `# END ubicloud` blocks in
  `pg_hba.conf` (first) and `pg_ident.conf`, and reload only when a file
  changed. Never append: a rerun would add a second copy.
- A release that exists with the same rev is skipped, and with another
  rev the run exits 2 (M3-d), rather than failing in `mv`.

`install.sh` itself added these (2026-10-14):

- On noble `postgresql-contrib-16` is a virtual package that
  `postgresql-16` provides, so `dpkg-query` never reports it installed
  and every run would call apt. The package list names only
  `postgresql-16`, which ships `citext` and `btree_gist`.
- `loader.rb` connects to the database, so the "development group is
  installed" check runs `Bundler.setup(:default, :development)` and
  `require "pry"` instead of loading the app.
- A subshell on the left of `||` runs without `set -e`: a failed `npm ci`
  went unnoticed and the release had no `assets/css/app.css` (every page
  500s). The build commands are chained with `&&`, and the build checks
  that `app.css` exists. The build HOME is a temp dir `ubicloud` can
  enter, not one under root's 0700 work dir.

## install.sh results (2026-10-14, systemd 255.4-1ubuntu8.17, curl 8.5.0)

One `run.sh all` after the last change, plus `flags` separately before it
joined `all`:

- `--prepare-tools` (bare ubuntu:24.04 with systemd): packages, mise
  v2026.9.18 and Ruby 4.0.7 / Node 24.12.0 in about 3.5 min.
- `fresh`: the one-command install (release build included) took under a
  minute on `ubi-m3-tools`; web answered 4.1 s after it returned.
- `byoh-config-check` on a fresh production install: 8 ok, 6 warn, no
  fail. The warnings are expected: `BASE_URL` is localhost,
  `CONTROL_PLANE_OUTBOUND_CIDRS` is open (M8), mail goes to the logger,
  and the three audit-log tables end on 2027-01-01 (78 days).
- The committed Sequel caches matched the installed schema byte for byte.
- Every other scenario kept its WP3 results on a release that
  `install.sh` built.

## migrate-from-dev.sh results (2026-10-14, systemd 255.4-1ubuntu8.17)

One run of `migrate migrate-preM1` after the last change:

- **migrate** (R0 fc693b1e0, 499 migrations, no pending): the R0
  bootstrap took about 90 s. From `preflight` to a started packaged
  control plane took about 80 s. `copy-db` took 9 s: dump 1.2 MB, 223
  tables with equal row counts, 473 objects equal to the reference and
  15 only in the copy, all owned by `ubicloud` with no grants. The
  development respirate exited 0.6-0.9 s after C-c. `rollback`, a
  `docker restart` and the printed R0 commands had development web
  answering 1.8 s later. `flip-production` and `retire` passed, and
  `status` was ok with 6 warnings.
- **migrate-preM1** (aca70df27, 360 migrations, Ruby 4.0.2): `copy-db`
  renamed `20260412000000_add_generic_provider.rb` in `ubicloud` only.
  It ran 139 pending migrations as `ubicloud-migrate` in 8 s, and the
  copy matched the reference on all 473 objects. `start` ran
  `install_rhizome`, because rhizome changed since R0.
- After the WP9 review fixes (one run of `parity migrate migrate-preM1`,
  all ok): the copy-db that a reference-only column grant failed took
  8 s, and its rerun 10 s. The held-lease refusal took the full 150 s.
  The added refusals, the second rollback, the extra copy-db and
  `flip-production --back` made `migrate` about 6 minutes in all. This
  run also found that the lease refusal could not switch the development
  database's connections back (`ALLOW_CONNECTIONS t` is no boolean to
  `ALTER DATABASE`). That path had never run before.
- The R0 bootstrap's npm step changes `package-lock.json`, so preflight
  warns that the R0 checkout has uncommitted changes. The live checkout
  probably shows the same warning.
- Rehearsal stand-ins:
  - The host's strand is parked at `wait`.
  - Its Sshable uses root, because the stand-in sshd has no `rhizome` user before `bootstrap_rhizome`.
  - `configure_metrics` fails on the stand-in host and only puts the
    strand in the journal.
  - The cloudflared stand-in only holds TCP connections to the origin.
- UNVERIFIED: every step on the live control plane, a real Cloudflare
  tunnel, and a `retire` after 14 real nightly backups and a restore
  drill.

## Release switch results (2026-10-14, systemd 255.4-1ubuntu8.17)

`--prepare-release`, followed by one run of `parity rerun flags fresh admin
backup upgrade-manual`, passed in full.
- **`upgrade-manual`:** took about 3 minutes in all. Each
  `--stage release` build of t2 and t3 took about 55 s (`bundle install`
  and `npm ci`). Each `release use` and `release migrate` took 1-2 s,
  and web answered within a few seconds of each start.
- **Found on the way:** a probe migration dated 20261231 failed in
  `release migrate`. That date was outside `validate_migration_dates`,
  which allows today plus five days. `current` stayed at t1, the
  services stayed stopped, and the message named the backup to restore.
  This is the only run of a failing `release migrate`.
- **Image refresh:** the earlier `ubi-m3-release` image carried an
  `ubicloud-admin` from before WP10, so `rerun` failed with "changed
  admin". That is expected after a change to `ubicloud-admin`, and
  rebuilding the image fixed it.
- **UNVERIFIED:** a switch on the live control plane, a release that
  changes `rhizome/` followed by `install_rhizome` on real hosts, and a
  release with another Ruby (refused until M12).


## Release switch review fixes (2026-10-14, systemd 255.4-1ubuntu8.17)

`--prepare-release`, followed by one run of `upgrade-manual parity rerun
admin backup`, passed in full; `upgrade-manual` took about 3.5 minutes.
- **Found on the way:**
  - `latest_backup` piped into `head -1`. Under `pipefail`, a SIGPIPE
    could end `release migrate` with no message once a few backups
    existed. It now reads the whole list.
  - `systemctl stop ubicloud.target` returned while respirate was still
    stopping, and a `backup now` right after it was a second older than
    the stop of respirate. The guard refused it as it should. The
    procedure now names the services in the stop, which waits for them,
    and `release migrate` and `use` count a unit that is still stopping
    as running.
  - `InactiveEnterTimestamp` is empty for a unit that systemd unloaded
    after its stop (seen on a unit nothing refers to). The stop time
    therefore also comes from the unit's last journal entry of the boot.
- **UNVERIFIED:** a real reboot (the hold is rehearsed with `docker
  restart`), and the journal fallback on a host whose journal is not
  persistent or has been rotated.

## Final M3 run (2026-10-14, systemd 255.4-1ubuntu8.17)

From scratch: `--prepare-image`, `--prepare-tools` (about 4 minutes),
`--prepare-release`, then `all`, which passed every scenario in about 45
minutes (rc 0, no `ubi-m3-*` container left). This run uses the
`grep -q ... <<<"$(adm_last)"` form in `upgrade-manual`: the newest
shellcheck (SC2337) flags `cmd | grep -q` under `pipefail`, because
grep's early exit can fail the pipe with SIGPIPE.

### Storage disk fixtures (WP6)

```
scripts/byoh/test/storage-disk-fixtures.sh
```

Runs `storage-disk-cases.sh` in one throwaway `ubi-m4-sd` container
(ubuntu:24.04, `--rm`, no ports) against
`scripts/byoh/host/ubicloud-host storage-disk`. Each case builds a
fixture root inside the container with a root disk `sda` (`sda1` holds
`/`) and blank disks `sdb` and `sdc`. Every block device command
(`lsblk`, `findmnt`, `blkid`, `wipefs`, `swapon`, `blockdev`, `dd`,
`mkfs.ext4`, `chattr`, `mount`, `multipath`, `udevadm`, `systemctl`) is
`storage-disk-shim`, linked into `<root>/shim` and acting on fake disks
under `<root>/fake`. In test mode the script refuses to run unless every
one of them resolves to that shim directory, so no real device is
touched.

The cases cover these refusals:
- the disk of `/`, `/boot` or `/boot/efi`, a btrfs `/` (`/dev/sda1[/@]`, major 0), and a ZFS `/` no disk names (a warning, then refused by the partition check)
- a partition or device-mapper link
- a by-id prefix that matches two links, also when one of them is an exact name (an exact name alone wins)
- a missing link, or a link to something other than a disk
- partitions, a mount, holders or swap
- a `wipefs` signature, a `blkid` partition table, or a backup GPT in the last 4096-byte block
- iSCSI (and then allowed with `--allow-shared-transport`), FCoE, NVMe whose controller transport is `tcp`, `rdma` on one path of a multipath head, or missing, and multipath (NVMe over `pcie` passes)
- a `blkid` error, a failed or short read of the last block, and a failed `lsblk -o TRAN` (fail closed with exit 3)
- a failed copy of `/etc/fstab` (exit 3, fstab unchanged, no temporary file)
- an `ubi-diskN` label without its fstab line
- a signature that appears between the checks and mkfs

They also cover:
- a blank disk: the fstab line and `disk1`, `chattr +i` before mkfs, and no temporary file left behind
- a re-run that changes nothing
- a re-run that mounts a disk left unmounted
- `disk2` for the second disk, and skipping used `diskN` names
- the guards: no shims, non-root, and usage errors

One check runs the real `mkfs.ext4` on an image file. It confirms that
mke2fs 1.47 without a tty overwrites an existing filesystem whether or not
`-F` is given. That is why the script's own probes, repeated under the
fstab lock, are the only guard. Result (2026-10-15): 29 checks pass in
about 10 s, with nothing left behind. A run against a real disk or loop
device is UNVERIFIED.
