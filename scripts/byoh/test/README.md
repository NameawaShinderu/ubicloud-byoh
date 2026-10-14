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
scripts/byoh/test/run.sh all                    # or: envfmt verify fresh rerun flags smoke kill restart reboot tls-provided tunnel
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

`fixture.sh` holds test helpers only: `units` (the working tree's units),
`account EMAIL` and `as-service`/`as-migrate CMD` (a command in the
release with exactly the units' environment, parsed by systemd).

## Scenarios

| Scenario | Checks |
|---|---|
| `envfmt` | systemd's `EnvironmentFile=` and bash's `set -a; . F` read the `KEY='value'` lines of `/etc/ubicloud/env` the same way. The run fails if the set of differing cases changes. |
| `fresh` | One `install.sh` run on `ubi-m3-tools` (no release yet): units active and `ubicloud.target` enabled, monitor disabled, puma only on 127.0.0.1:3000, postgres `listen_addresses` localhost. Roles `ubicloud` and `ubicloud_password` are not superuser, createdb or createrole; the managed hba block is the first rule and has no trust or password method; OS user `ubicloud` gets role `ubicloud` but not `ubicloud_password`, `ubicloud-migrate` gets both, and TCP logins to database `ubicloud` are refused. `/etc/ubicloud/env` and `backup.conf` are root 0600, the env file has the full key set and no `PRY_ALLOW_UNAUDITED`, `GIT_REV` or (with `--tls none`) `IP_FROM_HEADER`. Nothing under `/opt/ubicloud` is writable by `ubicloud` or `ubicloud-migrate` or owned by anyone but root. `.bundle/config` carries deployment and the without-list. `byoh-config-check` has no fail and reports the role check ok. The shipped `cache/*.cache` equal a `refresh_sequel_caches` run (as `ubicloud-migrate`, in a scratch copy) against the installed schema. An account logs in. No `*ubi-bootstrap*` file exists. |
| `rerun` | `install.sh` again with identical arguments: exit 0, no `changed` line, the env, backup, hba, ident and unit files byte for byte, the MainPIDs kept. `--version t2` exits 2 and names the release switch. A different `--mail-from` exits 2 naming only the key, and with `--update-env MAIL_FROM` updates it and restarts the services. A deleted key is appended by name. `PRY_ALLOW_UNAUDITED` in the env file, a malformed line, and another rev for `t1` exit non-zero without printing a value or changing a file. |
| `flags` | Usage errors (`--mgmt-endpoint`, `--smtp` on argv, `--tls acme`, an https URL with `--tls none`, a bad version, an `s3://` target, `--cert`, `--import-env-rb`, an unknown stage, no source) exit 2 and create nothing. `--source-git` on a repository owned by another user, with `--ref HEAD`: the release rev is that commit. `--smtp-file` refuses mode 0644, and at 0600 writes `MAIL_DRIVER=smtp` and the `SMTP_*` keys without printing the password. `--billing-rates-dir` copies the files, owned by `ubicloud`. A postgres listening on `*` is set back to localhost with a restart notice. `--no-start` neither enables nor starts the target. A rerun and a `--stage tools` rerun change nothing, and `--rack-env development` serves. |
| `verify` | `systemd-analyze verify` is clean (apart from the missing `ubicloud-admin`, until WP6). web and respirate are ordered after `postgresql@16-main` and `network-online.target` without `Requires=`. Monitor is installed but disabled. Without `ubicloud-admin`, `ubicloud-backup.service` is skipped on its condition, not failed. Writes the `systemd-analyze security` report. |
| `smoke` | Every unit is active. An account is created and logs in over the two-step login. puma listens only on 127.0.0.1:3000, also with `BIND` and `PORT` removed from the env file. The release is read-only to `ubicloud`. web, respirate and monitor each run with no capabilities (effective and bounding) and NoNewPrivs. A rerun of `install.sh` while the services run leaves `pg_hba.conf` and `pg_ident.conf` byte for byte, and its migrate as `ubicloud-migrate` rewrites the `var/ca_bundles` files web wrote; web then rewrites them again. A rerun with another rev exits 2. The journal has no Ruby errors. |
| `kill` | A: SIGKILL to the respirate child; restarter keeps its PID and respawns within 4 s. B: `systemctl kill -s KILL`; a new MainPID within 5 s. Both: a strand runs within 150 s. |
| `restart` | `systemctl restart ubicloud.target`. A stop while an idle child runs ends with `Result=success`. A stop while restarter sleeps between children ends quickly, with no ESRCH and no leftover process. A running backup (a stand-in drop-in) survives a restart and a stop of the target, and the stop pauses the timer. Then, with strands held in a query by a lock on `vm_host`: a stop with one running strand, a stop past a shortened `TimeoutStopSec`, and a stop with every dispatcher thread busy (below). |
| `reboot` | `docker restart`: the target starts at boot, web answers, and strands run. A real VM reboot is UNVERIFIED. |
| `tls-provided` | The E0 HTTPS gate: one `install.sh --tls provided` run on `ubi-m3-tools` with a self-signed certificate for `cp.test` and `--url https://cp.test`. Refused first, with exit 2 and nothing created: a certificate for another host, the key of another certificate, a missing key, `--cert` with `--tls none`, an http URL, a URL with a port. Then: caddy (Ubuntu universe) active and enabled; `https://cp.test` answers through caddy with the given certificate (verified with `--cacert`, not `-k`); http redirects to https (308); the caddy admin API on 127.0.0.1:2019 refuses connections; puma listens on 127.0.0.1 only; `/etc/ubicloud/tls` is `root:caddy` 0750 with the key 0640; `IP_FROM_HEADER='X-Real-IP'`; `byoh-config-check` reports the client-IP check ok. An account logs in over HTTPS, and the audit log records the container's address as caddy sees it, not 127.0.0.1 and not the `X-Real-IP` the client sent. A rerun changes no file and restarts nothing (web, respirate, caddy). A reissued certificate with 10 days left warns, is installed and served (serial checked with `openssl s_client`), and restarts caddy only. install.sh's own `render_caddyfile` with `--tls acme` adapts with `caddy adapt`: admin off, the `--admin-email` ACME account, `X-Real-IP` set and `CF-Connecting-IP` dropped (a real ACME run is UNVERIFIED). Switching back to `--tls none` exits 2 naming `BASE_URL`, `IP_FROM_HEADER` and `TLS_FRONT` and the exact `--update-env` flags, and with them stops and disables caddy and removes `IP_FROM_HEADER`. |
| `tunnel` | From `ubi-m3-release` with a stand-in `cloudflared.service` that has a token on its command line (the live case): `--tls tunnel --update-env BASE_URL --update-env TLS_FRONT` leaves that unit byte for byte with the same MainPID, warns that its token is on the command line without printing it, prints the `http://127.0.0.1:3000` ingress reminder, installs no unit of its own and sets `IP_FROM_HEADER='CF-Connecting-IP'`; a login carrying that header is recorded with its address; a rerun changes nothing. Next to that running unit, `--tls provided` exits 2 (puma would trust an `X-Real-IP` the tunnel passes through) and `--cloudflared-token-file` exits 2 (it would never be used), both changing nothing; stopped and disabled, the unit is warned about. With the stand-in removed: no token file exits 2, a 0644 token file exits 2, and a 0600 one installs the pinned cloudflared (sha256-checked) and `ubicloud-cloudflared.service` (`systemd-analyze verify` clean) with the token as a `LoadCredential=` credential, copied to `/etc/ubicloud/cloudflared.token` root 0600. The token is a dummy, so cloudflared answers "Provided Tunnel token is not valid.", which proves it read the credential; the token is on no command line and not in the unit. Reruns with and without the token file change no file (the dummy token makes each one start the unit again). With no caddy candidate (an apt pin), a switch to `--tls provided` exits 2 before any change and the tunnel stays enabled. `--no-start --tls none` with `--update-env` leaves `ubicloud-cloudflared` running and `front.conf` at `tunnel`; the run without `--no-start` then names only `--update-env TLS_FRONT`, and with it stops and disables `ubicloud-cloudflared`, keeps the token copy and records `none`. A real tunnel is UNVERIFIED. |

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
  (WP6) is not tested yet. `/var/lib/ubicloud` is 0750 and holds no
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
