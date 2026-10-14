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

```
docker network create ubi-test-net              # once, if missing
scripts/byoh/test/run.sh --prepare-image        # ubi-m3-systemd
scripts/byoh/test/run.sh --prepare-tools        # ubi-m3-tools (ruby build, ~10 min)
scripts/byoh/test/run.sh --prepare-release      # ubi-m3-release from the working tree
scripts/byoh/test/run.sh all                    # or: envfmt verify smoke kill restart reboot
```

`--prepare-release` archives the working tree (untracked, non-ignored
files included) and builds release `t1` from it. Each scenario then boots
a fresh container from that image and installs the units from the
working tree's `packaging/systemd`. A change to the units needs no
re-prepare, but a change to the code does.

`fixture.sh` is a test fixture that lays out tools, the release, the
database, `/etc/ubicloud/env` and the units. `scripts/byoh/install.sh`
(WP4) replaces it in the scenarios.

## Scenarios

| Scenario | Checks |
|---|---|
| `envfmt` | systemd's `EnvironmentFile=` and bash's `set -a; . F` read the `KEY='value'` lines of `/etc/ubicloud/env` the same way. The run fails if the set of differing cases changes. |
| `verify` | `systemd-analyze verify` is clean (apart from the missing `ubicloud-admin`, until WP6). web and respirate are ordered after `postgresql@16-main` and `network-online.target` without `Requires=`. Monitor is installed but disabled. Without `ubicloud-admin`, `ubicloud-backup.service` is skipped on its condition, not failed. Writes the `systemd-analyze security` report. |
| `smoke` | Every unit is active. An account is created and logs in over the two-step login. puma listens only on 127.0.0.1:3000. The release is read-only to `ubicloud`. web has no capabilities and respirate runs with NoNewPrivs. The journal has no Ruby errors. |
| `kill` | A: SIGKILL to the respirate child; restarter keeps its PID and respawns within 4 s. B: `systemctl kill -s KILL`; a new MainPID within 5 s. Both: a strand runs within 150 s. |
| `restart` | `systemctl restart ubicloud.target`. A stop while a child runs ends with `Result=success`. A stop while restarter sleeps between children ends quickly, with no ESRCH and no leftover process. A running backup (a stand-in drop-in) survives a restart and a stop of the target, and the stop pauses the timer. |
| `reboot` | `docker restart`: the target starts at boot, web answers, and strands run. A real VM reboot is UNVERIFIED. |

## Results (2026-10-14, systemd 255.4-1ubuntu8.17)

- **envfmt:** inside single quotes, both parsers read `$`, `#`, `\`,
  tabs, CR and leading or trailing spaces literally. Only text after
  the closing quote differs (`KEY='ab' # c`: systemd keeps `ab# c`, bash
  drops the comment). So a writer must end each line at the closing
  quote. The M3-b validator still rejects `'`, `\`, newline and NUL in
  values.
Ranges cover two full runs.

- **kill A** (SIGKILL to the respirate child): restarter kept its PID
  and spawned a new child after 2.1-2.3 s (`RESTART_MAX_SLEEP=2`). The
  probe strand ran 3.3-4.1 s after the poke.
- **kill B** (`systemctl kill -s KILL`): a new MainPID after 1.1 s
  (`RestartSec=1`), and the probe strand ran after 3.7-4.3 s. In this
  container `systemctl kill` exits 1 with "Failed to send signal SIGKILL
  to auxiliary processes: Invalid argument" even though it kills the
  unit, so the harness judges by `NRestarts` and the MainPID.
- The probe strand naps between runs, so it was never leased when the
  process died. A strand that a killed respirate was running waits for
  its 120 s lease before it resumes. The harness allows 150 s for that,
  but it did not measure that case.
- **restart:** `systemctl restart ubicloud.target` took 0.4 s on an idle
  control plane. Stopping respirate while a child ran took 0.6 s, and
  stopping it during restarter's pause took 0.6-1.6 s. Both ended with
  `Result=success` and left no process or ESRCH behind. Strands that are
  running can hold a stop for up to about 91 s (apoptosis), which is why
  `TimeoutStopSec=100`.
- **reboot** (`docker restart`): web answered 3.3-4.6 s after boot, and a
  strand ran. A real VM reboot is UNVERIFIED.
- **Hardening:** every directive in the units was kept. `systemd-analyze
  security` rates web and respirate 3.5 ("OK").
- **Backup:** a running backup is not stopped or restarted with the
  target, because `ubicloud-backup.service` is not `PartOf` it. Its timer
  is, so stopping the target pauses scheduled backups until the target
  starts again. Until WP6 installs `ubicloud-admin`, the service is
  skipped on `ConditionFileIsExecutable=`, so the 03:15 run does not
  leave the system degraded.

## Findings for `install.sh` (WP4)

The fixture hit these, and the installer must handle them the same way:

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
  shared `ubicloud` group. `/var/lib/ubicloud` is 0750 and holds no
  secrets.
