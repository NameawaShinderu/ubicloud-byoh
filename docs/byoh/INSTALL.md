# Installing a packaged control plane

`scripts/byoh/install.sh` installs the BYOH control plane as a packaged
service on one Ubuntu 24.04 machine: systemd units run by user
`ubicloud`, a root-owned release under `/opt/ubicloud`, database
`ubicloud` with peer authentication and non-superuser roles, settings in
`/etc/ubicloud/env`, a TLS front, nightly backups and `ubicloud-admin`.
It is the M3 replacement for the development bootstrap
(`scripts/byoh/bootstrap-dev-ctrl-plane.sh`, tmux, `clover_test`, `trust`).

- Day-2 operation (units, `ubicloud-admin`, backups, restore, the release
  switch, the audit-partition deadline): [OPERATIONS.md](OPERATIONS.md).
- Moving an existing development control plane (the live one):
  [MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md). Do not run `install.sh`
  by hand on such a machine; it refuses to start the units while
  `~/.ubi-bootstrap` exists.
- Hosts, locations and pools after the install: [SETUP.md](SETUP.md) §5-§10,
  with the commands in §5 of this page.

**Status.** Every step below ran in the container harness
(`scripts/byoh/test/`, systemd 255 in `ubuntu:24.04` containers; results
in `scripts/byoh/test/README.md`). It has **not** run on a real machine,
and the UNVERIFIED list (§9) names what the harness cannot show. There
is no release tarball yet (E4/M12): the installer builds a release from
a git checkout or a tarball you made. M3 lives on branch `m3-packaging`
until it is merged into `byoh-driver` and pushed; until then a
`byoh-driver` clone has no `install.sh`.

---

## 1. Requirements

| Need | Detail |
|---|---|
| OS | Ubuntu 24.04, x86_64 (the pinned mise and cloudflared binaries are amd64 only; step 1 refuses another architecture with exit 2) |
| Memory | About 4 GiB (`MemTotal` at least 3.5 GiB; `--skip-check mem` overrides). Sizing beyond that is UNVERIFIED; the live control plane is a t3.large |
| Clock | NTP-synchronized (`timedatectl`; `--skip-check clock` overrides). TLS, tokens and backup timestamps depend on it |
| Access | root (`sudo`) |
| Outbound internet | apt (Ubuntu archive, universe for Caddy), github.com (mise, cloudflared), the Ruby source and Node binaries that mise fetches, rubygems.org, registry.npmjs.org |
| Ports | `acme` and `provided`: 80 and 443 free (Caddy). `acme` also needs public DNS for the host name. Port 3000 is bound to 127.0.0.1 only |
| PostgreSQL | Installed by the script (16, Ubuntu's package). A postgres that already listens on more than `localhost` is switched to `localhost` with a restart (`--skip-check listen` keeps it) |
| A source | A git checkout of this repository owned by a normal user, or a tarball made with `git archive` |
| Backup key | An [age](https://age-encryption.org) recipient (`age1...`) whose identity lives **off** the machine. Without one the secrets are not backed up and `ubicloud-admin status` fails |

The first run builds Ruby from source and installs the gems and Node
packages. In the harness that took about 3.5 minutes for the tools and
under a minute for the release.

---

## 2. The command

```bash
# as a normal user
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
git -C ~/ubicloud rev-parse HEAD            # the rev you install

# as root
sudo bash ~/ubicloud/scripts/byoh/install.sh \
  --version v0.1.0 \
  --source-git ~/ubicloud --ref HEAD \
  --url https://cloud.example.com --tls acme \
  --admin-email ops@example.com \
  --backup-recipient age1...
sudo ubicloud-admin account create --email ops@example.com
sudo ubicloud-admin backup now
sudo ubicloud-admin status
```

`git archive` runs as the owner of the checkout, so git's "dubious
ownership" check never trips, and only committed files reach the
release: uncommitted changes and `.env.rb` are left behind (a source with
`.env.rb` is refused).

The run prints one line per step: `ok` (nothing to do), `changed`,
`skip`, `warn` or `notice`. It ends with step 12, `ubicloud-admin
smoke` (§6), then the URL and the next commands.

### Steps

| # | Step | Changes |
|---|---|---|
| 1 | Checks | Ubuntu 24.04, amd64, memory, NTP; nothing changes |
| — | Source | Extracts the rev into a temp dir; reads Ruby and Node versions from its `mise.toml` |
| — | Release and tools checks | Exit 2 before any change when the version exists with another rev, when `--version` is not the current release (use the release switch, OPERATIONS.md §7), or when the source wants other Ruby/Node versions than the current release |
| 2 | Packages | `postgresql-16`, `age`, build dependencies, `git curl jq iproute2 openssl` (apt, only the missing ones) |
| 3 | Tools | Pinned mise (sha256-checked) builds Ruby and Node into `/opt/ubicloud/tools`; plain symlinks in `/opt/ubicloud/tools/bin`. No mise at runtime |
| — | Settings checks | Exit 2 before any change when a flag would change an existing setting without `--update-env` (§4), when the env file sets `PRY_ALLOW_UNAUDITED` or `PORT=8081`, when the database has a schema but the env file is missing, when the front cannot be set up, or when something else holds the web port or a development control plane lives here |
| 4 | Users and release | OS users `ubicloud`, `ubicloud-migrate` and `ubicloud-build` (builds releases only); `/var/lib/ubicloud/{var,billing_rates.d}`; builds `releases/<version>` (bundle in deployment mode, `npm ci`, `npm run prod`), then makes it root-owned and read-only and points `current` at it |
| 5 | Database | Roles `ubicloud`, `ubicloud_password`, `ubicloud_restorer` (LOGIN, no superuser, createdb or createrole); database `ubicloud`, `citext`, `btree_gist`; the managed `# BEGIN ubicloud` blocks at the top of `pg_hba.conf` and in `pg_ident.conf`; `listen_addresses = 'localhost'`. Warns about `trust` lines and login superusers elsewhere |
| 6 | Env file | `/etc/ubicloud/env` (root 0600): missing keys added, secrets generated once (§4) |
| 7 | Migrations | `bin/rake-task-runner migrate` as `ubicloud-migrate` |
| 9 | Units and `ubicloud-admin` | `/usr/local/bin/ubicloud-admin`; units into `/etc/systemd/system`; enables and starts `ubicloud.target` (restarts it when the release, units or env changed) |
| 10 | TLS front | Caddy or cloudflared per `--tls` (§3); `/etc/ubicloud/front.conf` |
| 11 | Backups | `/etc/ubicloud/backup.conf`, `backup-recipients`, the target directory and its `KEYS-README.txt` |
| 12 | Smoke | `ubicloud-admin smoke` (skipped with `--no-start`) |

Step 8 (the WireGuard management hub) comes with M8. The committed Sequel
caches (`cache/*.cache`) are used as they are; the installer never runs
`refresh_sequel_caches`.

### Flags

| Flag | Meaning |
|---|---|
| `--version V` | Release name: letters, digits, `.`, `_`, `+`, `-`. Required except with `--stage tools`. A rerun with the same version and rev is a no-op; another version exits 2 (release switch) |
| `--source-git DIR --ref REF` | Build from commit REF of the checkout DIR |
| `--source-tarball F --source-rev REV` | Build from a `git archive` tarball; REV is the commit it came from (recorded as `GIT_REV`) |
| `--url URL` | `BASE_URL`. `acme`, `provided`, `tunnel`: `https://HOST`, no port, no path. `none`: `http://localhost:PORT` with puma's port |
| `--tls acme\|provided\|tunnel\|none` | The front (§3). Required |
| `--cert F --key F` | `--tls provided` only: PEM certificate (chain) and unencrypted key. Checked for host name, key match and expiry; warns under 30 days |
| `--cloudflared-token-file F` | `--tls tunnel` on a machine without a `cloudflared.service`: the tunnel token, mode 0600 |
| `--admin-email ADDR` | The operator's address. With `acme` it is the ACME account. Also the default `MAIL_FROM` |
| `--mail-from ADDR` | `MAIL_FROM` (default: `--admin-email`) |
| `--smtp-file F` or `--smtp-file -` | An SMTP URL (§4.4) from a 0600 file, or from stdin. Without it mail goes to the logger (journald) |
| `--rack-env production\|development` | Default `production`. See §7 before you choose |
| `--billing-rates-dir DIR` | Copies `DIR/*.yml` into `/var/lib/ubicloud/billing_rates.d` (owned by `ubicloud`) |
| `--backup-target DIR` | Absolute directory, default `/var/backups/ubicloud`. `s3://` comes with E5 |
| `--backup-recipient age1...` or `--backup-recipient-file F` | Who can decrypt the secrets backups (OPERATIONS.md §6.2) |
| `--update-env KEY` | Lets a run change KEY (repeatable; §4.1) |
| `--skip-check clock\|mem\|listen` | Skips that check (repeatable) |
| `--stage tools\|release\|all` | `tools`: steps 1-3 only (needs only a source). `release`: build another release next to the current one, nothing else (OPERATIONS.md §7). Default `all` |
| `--no-start` | Installs everything but neither enables nor starts the units, leaves the front as it was and skips step 12 (used by `migrate-from-dev.sh install`) |
| `--help` | The header of the script |

Refused flags: `--mgmt-endpoint` ("available in M8"), `--smtp URL` (a
password on the command line; use `--smtp-file`), `--import-env-rb`
(that is `migrate-from-dev.sh install`).

**Exit status:** 0 success; 1 a failure (for example the smoke test);
2 a usage error or a refusal that changed nothing.

---

## 3. TLS fronts

By default puma listens on `127.0.0.1:3000` (`BIND`, `PORT`), so the
front is the only thing users reach. `BIND` and `PORT` are yours to
change (`ubicloud-admin env set`), but the front's `IP_FROM_HEADER` is
only trustworthy while nothing but the front reaches puma: a client that
reaches puma directly sets that header itself and with it its own
audit-log IP. So with `IP_FROM_HEADER` set and `BIND` not a loopback
address, `bin/byoh-config-check` fails `ubicloud-admin status` in
production and warns in development.

| `--tls` | Front | Certificate | `IP_FROM_HEADER` | Ports | Status |
|---|---|---|---|---|---|
| `acme` | Caddy (Ubuntu universe), `admin off` | Let's Encrypt for the `--url` host, in the background | `X-Real-IP` (set by Caddy from the connection) | 80, 443 | Caddyfile rendered and parsed; a real ACME issuance is **UNVERIFIED** |
| `provided` | Caddy, `auto_https disable_certs` | `--cert`/`--key`, copied to `/etc/ubicloud/tls` (`root:caddy`, key 0640) | `X-Real-IP` | 80, 443 | Harness gate (`tls-provided`): HTTPS login with a self-signed certificate |
| `tunnel` | cloudflared | Cloudflare's edge | `CF-Connecting-IP` | none inbound | Existing-unit case and own-unit case in the harness; a real tunnel is **UNVERIFIED** |
| `none` | none | none | unset | none | Lab only: `--url http://localhost:3000`, reached with `ssh -L 3000:127.0.0.1:3000`; browser use is UNVERIFIED |

- **Caddy and port 80.** Caddy serves port 80 only to redirect to HTTPS
  (308) and, for `acme`, to answer the HTTP-01 challenge. A firewall must
  allow both 80 and 443. The Caddyfile is `/etc/caddy/Caddyfile`, written
  from `packaging/caddy/Caddyfile.tmpl`; install.sh refuses to replace a
  Caddyfile it did not write (other than the package's own). With `admin
  off`, `systemctl reload caddy` fails; install.sh restarts Caddy when the
  file or certificate changes. To renew a provided certificate, run
  install.sh again with the new `--cert`/`--key`.
- **cloudflared, existing unit.** A `cloudflared.service` that is already
  there (the live control plane's) is never modified. install.sh only
  reports whether it runs, whether it is enabled, and whether its token is
  on the command line or in the unit's environment (warn: every local user
  can read it there).
- **cloudflared, own unit.** On a machine without one,
  `--cloudflared-token-file F` installs cloudflared 2026.9.3 (pinned and
  sha256-checked, amd64) and `ubicloud-cloudflared.service`, which reads
  the token as a systemd credential from `/etc/ubicloud/cloudflared.token`
  (root 0600). The token is never on a command line or in a unit.
- **Cloudflare dashboard step (tunnel).** In the Zero Trust dashboard (or
  the tunnel's ingress rules), the public hostname of `--url` must route to
  **`http://127.0.0.1:3000`**, not `localhost`: where `localhost` resolves
  to `::1`, the route fails, because puma listens on 127.0.0.1 only.
  install.sh prints this as a notice and cannot check it.
  `ubicloud-admin smoke` fails on an HTTP 404 through the tunnel and warns
  on 530 (no connector yet) or no answer.
- **HSTS.** With `RACK_ENV=production` every page carries
  `Strict-Transport-Security: max-age=63072000; includeSubDomains`
  (`helpers/general.rb:92-94`). After one visit, browsers refuse plain
  HTTP for that host **and all its subdomains** for two years. Use a host
  name whose subdomains are all served over HTTPS, and do not switch a
  production host back to `--tls none`.
- **Secure cookies.** Outside development the session cookie is `Secure`
  (`clover.rb:177`), so a production control plane needs HTTPS. Browsers
  treat `http://localhost` as secure, which is why `--tls none` insists on
  `localhost`.
- **Switching fronts** on an installed control plane needs `--update-env
  TLS_FRONT`, plus `IP_FROM_HEADER` (unless it was unset) and `BASE_URL`
  (unless the URL stays). The exit-2 message names the exact flags. The
  new front comes up first, then the old one stops. An existing
  `cloudflared.service` next to `--tls acme|provided` is refused: puma
  would then trust an `X-Real-IP` that tunnel clients choose.

---

## 4. Settings: `/etc/ubicloud/env`

One file for systemd and bash, root 0600. Each line is `KEY='value'`
with nothing after the closing quote. Read it with `sudo ubicloud-admin
env keys` (names only) and change it with `ubicloud-admin env set|unset`
(OPERATIONS.md §4), never with an editor while the services run.

### 4.1 Rerun semantics

Every run compares the file with the flags. Each key has a kind:

| Kind | On a rerun |
|---|---|
| secret | Generated once and never compared or replaced |
| default | Added when missing. An existing value is the operator's and is kept |
| flag | Derived from a flag. A different existing value exits 2 naming the key, unless `--update-env KEY` is given; then it is replaced (or removed, when the flag now wants it empty) and the services restart |

The same rule covers `BACKUP_TARGET` (`/etc/ubicloud/backup.conf`),
`BACKUP_RECIPIENTS` (`/etc/ubicloud/backup-recipients`) and `TLS_FRONT`
(`/etc/ubicloud/front.conf`). Messages name keys, never values. A rerun
with identical flags changes no file and restarts nothing (harness
`rerun`: same MainPIDs, files byte for byte). A missing
`CLOVER_COLUMN_ENCRYPTION_KEY`, or a missing env file next to a database
that has a schema, stops the run: a new key would make every encrypted
column unreadable. Restore the env file from the secrets backup first
(OPERATIONS.md §6).

### 4.2 Keys

| Key | Value install.sh writes | Kind | Upstream default | Why |
|---|---|---|---|---|
| `RACK_ENV` | `--rack-env`, default `production` | flag (default without `--rack-env`) | none (required) | §7 |
| `CLOVER_DATABASE_URL` | `postgres:///ubicloud?user=ubicloud` | default | none (required) | Unix socket, peer auth, no password |
| `CLOVER_SESSION_SECRET` | 64 random bytes, base64 | secret | none (required) | Rodauth password hashing and token signing. Changing it locks every account out |
| `CLOVER_COLUMN_ENCRYPTION_KEY` | 32 random bytes, base64 | secret | none (required) | Encrypts columns such as every host's SSH private key. Lose it and the hosts are unreachable |
| `CLOVER_RUNTIME_TOKEN_SECRET` | 64 random bytes, base64 | secret | optional | VM runtime tokens |
| `BASE_URL` | `--url` | flag | `http://localhost:9292` | Links in mail; the front's host |
| `ADMIN_URL` | `http://admin.localhost:3000` | default | `http://admin.localhost:9292` | The admin UI over HTTPS is deferred (M3-l) |
| `BIND` | `127.0.0.1` | default | `0.0.0.0` (`puma_config.rb`) | Only the front reaches puma |
| `PORT` | `3000` | default | `3000` | Must not be 8081, which `bin/production_check` uses |
| `DB_POOL_WEB` | `16` | default | `DB_POOL` (5) | puma runs 15 threads |
| `MAIL_FROM` | `--mail-from`, default `--admin-email` | flag | `nil` in production, `dev@example.com` otherwise | Production refuses to send without it |
| `MAIL_DRIVER` | `smtp` with `--smtp-file`, else `logger` | flag / default | `smtp` in production, `logger` otherwise | §4.4 |
| `SMTP_HOSTNAME`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_USER`, `SMTP_PASSWORD` | From the SMTP URL | flag | port 587, TLS on | §4.4 |
| `BOOT_IMAGE_SOURCE` | `public` | default | `auto` | `auto` takes every boot image from Ubicloud's R2 in production, which BYOH lacks. `public` uses the public mirrors (SHA256-checked in production) |
| `DELETED_RECORD_DROP_UNARCHIVED` | `true` | default | `false` | Without an archive bucket, expired `deleted_record` partitions are dropped instead of piling up (development always does this). The rows are gone for good |
| `ALLOW_UNSPREAD_SERVERS` | `true` | default | `!production` | A single-host site can run HA Postgres servers on one host |
| `IP_FROM_HEADER` | Per `--tls` (§3); absent for `none` | flag | unset | Audit rows record the client, not the proxy |
| `BILLING_RATES_EXTRA_DIR` | `/var/lib/ubicloud/billing_rates.d` | default | unset | BYOH location rates (VERIFY.md §1.1). Must not be under `/home`, `/root` or `/run/user`: the units run with `ProtectHome=yes` |

Set by the units, not the file: `PATH=/opt/ubicloud/tools/bin:/usr/bin:/bin`,
`HOME=/var/lib/ubicloud`, `RESTART_MAX_SLEEP=2` (respirate; upstream 10),
and `GIT_REV` from the release's `.release-env`.

Keys you may add with `env set`:
- A BMC password variable named by `--bmc-pass-env` (OPERATIONS.md §4.2).
- `CONTROL_PLANE_OUTBOUND_CIDRS` (`status` warns while it is the open
  default; the M8 overlay sets it properly).
- `PRY_AUDIT_BUCKET` or `OTEL_EXPORTER_OTLP_ENDPOINT` to audit the console.

Never set: `PRY_ALLOW_UNAUDITED` (install.sh exits 2, `status` fails;
`ubicloud-admin console` sets it for its own session only).

### 4.3 Validation

- Key names match `^[A-Z][A-Z0-9_]{0,63}$`. `PATH`, `IFS`, `BASH_ENV`,
  `ENV`, `HOME`, `SHELL` and `LD_*` are refused everywhere; `env set`
  also refuses keys that load code (`RUBYOPT`, `RUBYLIB`, `GEM_*`,
  `BUNDLE_*`, `NODE_OPTIONS`, ...), the secrets, `GIT_REV` and the flag
  keys (change those with install.sh and `--update-env`).
- Values must not contain `'`, `\`, a newline, a CR or a NUL. Inside the
  quotes `$`, `#` and spaces are literal for both systemd and bash (the
  harness `envfmt` scenario checks this); text after the closing quote is
  read differently by the two, so no line may have any.
- A key may appear once.

### 4.4 The SMTP file

One line, an SMTP URL, in a file of mode 0600 (or on stdin with
`--smtp-file -`):

```
smtp://USER:PASSWORD@smtp.example.com:587?tls=on
```

- Percent-encode special characters in the user and password (`@` is
  `%40`). Both or neither.
- Port default 587. `tls=on` (STARTTLS, the default) or `tls=off`.
  `smtps://`, paths and other query parameters are refused.
- `bin/byoh-smtp-url` parses it as user `nobody`; the URL never reaches
  argv or the output. A URL without credentials removes old ones only with
  `--update-env SMTP_USER --update-env SMTP_PASSWORD`.

Without `--smtp-file`, mail goes to the logger, which writes the whole
message, links included, to the journal of `ubicloud-web` (OPERATIONS.md
§5, security note).

---

## 5. After the install

```bash
sudo ubicloud-admin account create --email ops@example.com     # prints a generated password once
sudo ubicloud-admin run byoh-location create --name <site> ...  # SETUP.md §6
sudo systemctl restart ubicloud.target                         # load the new rates
sudo ubicloud-admin run register-byoh-host --location <site> --main-ip <ip> \
  --pool-file pools.yaml --ssh-key ~/.ssh/byoh_data --default-boot-image ubuntu-noble --yes
sudo ubicloud-admin logs respirate -f
```

- `ubicloud-admin run TOOL` runs `byoh-location`, `byoh-pool`,
  `byoh-host`, `register-byoh-host`, `byoh-config-check`,
  `production_check`, `create_prod_admin_account` or `m2-checks` (the
  gates' database checks, VERIFY.md) in the release as user `ubicloud`.
  Files named by `--pool-file`, `--ssh-key`, `--registration-key`,
  `--external-map`, `--password-file` and `--snapshot` are copied for it,
  relative to your directory; `--out F` is written back to you.
- Use `--bmc-pass-env`, never `--bmc-password` (refused): OPERATIONS.md §4.2.
- A database query: `sudo -u postgres psql -d ubicloud -c "SELECT allocation_state FROM vm_host"`.
- A REPL: `sudo ubicloud-admin console`, which is **not audited** unless
  the env file names an audit sink (OPERATIONS.md §3).
- Admin accounts: `sudo ubicloud-admin run create_prod_admin_account LOGIN`.
  The admin UI itself is not reachable over HTTPS yet (M3-l).
- Never run `bin/pry`, `bundle exec` or `rake` from a checkout on this
  machine against the packaged database, and never `RACK_ENV=test`.

---

## 6. The install smoke (step 12)

`ubicloud-admin smoke` changes no setting and no unit. It checks:

1. puma answers `/login` on `BIND:PORT` (waits up to 120 s);
2. the front in `front.conf` runs and answers: Caddy under the `BASE_URL`
   host on 127.0.0.1:443, or `BASE_URL` itself through the tunnel;
3. `ubicloud-web` and `ubicloud-respirate` are active;
4. `bin/byoh-config-check` has no `fail`;
5. with `RACK_ENV=production`, `bin/production_check` passes (a second
   puma on port 8081 answers a login with 401).

Only things that come up in the background warn: an `acme` certificate
not issued yet (TLS handshake failure) and a tunnel still connecting
(no answer or 530). A fail exits 1 with everything installed; fix the
cause and run install.sh again (only what changed is redone) or
`ubicloud-admin smoke`.

---

## 7. Production mode

`--rack-env production` is the default. What it changes, and what
install.sh sets to keep a BYOH control plane working:

| Area | Development | Production | install.sh |
|---|---|---|---|
| Sign-up | `/create-account` makes a usable account at once, no mail | Email verification required (`verify_account`), common passwords refused | Onboard with `ubicloud-admin account create` (verified, with a project) |
| Mail | logger | SMTP, `MAIL_FROM` required | `MAIL_DRIVER=logger` unless `--smtp-file`; `MAIL_FROM` from the flags |
| Cookies, HSTS | Plain cookies, no HSTS | `Secure` cookies; HSTS two years with subdomains | Needs `acme`, `provided` or `tunnel` (or `none` on `localhost`) |
| Boot images | Public mirrors | Every image from Ubicloud's R2 | `BOOT_IMAGE_SOURCE=public` |
| Strand retry backoff | `least(5, try)` s | Exponential up to 600 s, randomized | Expect slower retries after a failure |
| Loading | Files load on first use | Everything loads at boot and is frozen (`clover_freeze`) | Boot takes a few seconds longer |
| `deleted_record` partitions | Dropped when expired | Kept unless archived | `DELETED_RECORD_DROP_UNARCHIVED=true` |
| HA Postgres on one host | Allowed | Refused (`allow_unspread_servers=false`) | `ALLOW_UNSPREAD_SERVERS=true` |
| `bin/pry` | Runs | Refuses without an audit sink | `ubicloud-admin console` opts in for one session (§5) |
| Admin UI | A development setting can skip WebAuthn | WebAuthn required, which needs a secure context | Deferred (M3-l) |
| Load balancer certificates | Self-signed | Need a `DnsZone` (`prog/vnet/cert_nexus.rb`) | Not set up; `--dns-zone` is E5 |

**The E1 canary has not run.** No VM has booted on a control plane in
production mode yet (a disposable canary host, approved by the user, is
the gate). Until it has, a deployment that must boot VMs today can use
`--rack-env development` and switch later with `--rack-env production
--update-env RACK_ENV` (smoke then runs `bin/production_check`). In
development the sign-up page is open: anyone who reaches the URL can make
a working account.

---

## 8. Files

| Path | Owner, mode | Holds |
|---|---|---|
| `/opt/ubicloud/tools` | root, read-only to others | Ruby, Node, mise |
| `/opt/ubicloud/releases/<version>` | root, `go-w` | The code, `vendor/bundle`, built assets, `.ubicloud-release`, `.release-env`; `var` links to `/var/lib/ubicloud/var` |
| `/opt/ubicloud/current`, `previous` | root | Symlinks to releases |
| `/etc/ubicloud/env` | root 0600 | Settings and secrets (§4) |
| `/etc/ubicloud/{backup.conf,backup-recipients,front.conf}` | root | Backup target, age recipients, the front |
| `/etc/ubicloud/tls/`, `cloudflared.token` | root:caddy 0750 / root 0600 | Provided certificate and key; tunnel token |
| `/var/lib/ubicloud` | root:ubicloud 0750 | `var/` (ubicloud 2770: CA bundles, shared with `ubicloud-migrate`), `billing_rates.d/` (ubicloud 0750), `release-hold` (root, during `release use --for-restore`) |
| `/var/backups/ubicloud` | root 0700 | Backups (OPERATIONS.md §6) |
| `/usr/local/bin/ubicloud-admin` | root 0755 | From the current release |
| `/etc/systemd/system/ubicloud*` | root 0644 | From `packaging/systemd` |

All the services can write is `/var/lib/ubicloud/var` and
`billing_rates.d`; a compromised web process cannot change code that
root later runs. `/var/lib/ubicloud` itself is root's, so the services
cannot swap those two directories for symlinks: `install.sh` and
`ubicloud-admin` refuse one that is a symlink and make an older
`ubicloud`-owned `/var/lib/ubicloud` root's. Releases are built as the
system user `ubicloud-build`, which no service runs as, and made root's
before root writes or runs anything in them.

---

## 9. UNVERIFIED

Not run, or only approximated in containers:

- Any install on a real machine or VM; a real reboot (the harness uses
  `docker restart`).
- A Let's Encrypt issuance (`--tls acme`) and a real Cloudflare tunnel.
  `ubicloud-cloudflared.service` on a real machine (its credential needs
  `/` to be a shared mount, which systemd sets up at boot outside
  containers).
- A VM boot in production mode (the E1 canary, §7).
- `--tls none` from a browser over `ssh -L`; the admin UI.
- Sending to a real SMTP server, a real `PRY_AUDIT_BUCKET`.
- An arm64 machine. Step 1 refuses it with exit 2 (the pinned mise and
  cloudflared binaries are amd64); the harness fakes the architecture.
- Memory and disk sizing beyond the 3.5 GiB check.
- A restore onto a second machine (OPERATIONS.md §6.3).
- Everything on the live control plane ([MIGRATE_FROM_DEV.md](MIGRATE_FROM_DEV.md)).

**The console is not audited.** `ubicloud-admin console` writes one
system-log line (who, when) and nothing about what was typed, unless
`PRY_AUDIT_BUCKET` or `OTEL_EXPORTER_OTLP_ENDPOINT` is set in the env
file.
