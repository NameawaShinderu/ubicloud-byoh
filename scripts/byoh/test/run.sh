#!/bin/bash
# Container harness for the packaged BYOH control plane (M3). Runs on a
# docker host; everything happens in throwaway ubi-m3-* containers on
# the ubi-test-net network, with no published ports.
#
#   run.sh --prepare-image     build ubi-m3-systemd (Dockerfile.systemd)
#   run.sh --prepare-tools     ubi-m3-tools: install.sh --stage tools
#                              (packages, mise, ruby, node)
#   run.sh --prepare-release   ubi-m3-release: install.sh of the working
#                              tree (release t1, database, env, units),
#                              stopped
#   run.sh SCENARIO...         run scenarios, each in a fresh container
#
# Scenarios: envfmt verify fresh rerun flags smoke kill restart reboot
# (or "all").
# Logs go to $UBI_M3_LOGS (default: a fresh temp dir, printed at the
# end). UBI_M3_KEEP=1 keeps the containers for inspection.
set -euo pipefail
# shellcheck source=scripts/byoh/test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

EMAIL=harness@example.test
PASSWORD=Harness-Pass-2026x

prepare_image() {
  docker build -q -t ubi-m3-systemd -f "$HARNESS_DIR/Dockerfile.systemd" "$HARNESS_DIR" >/dev/null
  say "built ubi-m3-systemd"
}

prepare_tools() {
  stage_art
  src_tarball
  start_sys tools-build ubi-m3-systemd
  dx tools-build bash /art/install.sh --stage tools --source-tarball /art/src.tgz \
    --source-rev "$(cat "$ART/src.rev")" --skip-check clock >"$LOGS/prepare-tools.log" 2>&1 ||
    fail "tools stage failed, see $LOGS/prepare-tools.log"
  dx tools-build systemctl stop postgresql
  docker commit -c 'CMD ["/sbin/init"]' ubi-m3-tools-build ubi-m3-tools >/dev/null
  say "committed ubi-m3-tools: $(tail -3 "$LOGS/prepare-tools.log" | tr '\n' ' ')"
}

# The arguments of every install.sh run in the harness. The backup
# recipient is generated in the container by backup_key.
INSTALL_ARGS=(--version t1 --url http://localhost:3000 --tls none --admin-email ops@example.test
  --backup-recipient-file /root/backup-recipient --skip-check clock)

# install_cp NAME [ARGS...]: runs install.sh in ubi-m3-NAME with the
# harness arguments, the source tarball of $ART and ARGS; the output
# goes to stdout.
install_cp() {
  local name=$1
  shift
  dx "$name" bash /art/install.sh "${INSTALL_ARGS[@]}" --source-tarball /art/src.tgz \
    --source-rev "$(cat "$ART/src.rev")" "$@"
}

backup_key() {
  dx "$1" bash -c 'test -e /root/backup-key || { age-keygen -o /root/backup-key 2>/dev/null &&
    age-keygen -y /root/backup-key >/root/backup-recipient; }'
}

prepare_release() {
  stage_art
  src_tarball
  start_sys release-build ubi-m3-tools
  backup_key release-build
  install_cp release-build >"$LOGS/prepare-release.log" 2>&1 ||
    fail "install.sh failed, see $LOGS/prepare-release.log"
  dx release-build systemctl stop ubicloud.target postgresql
  docker commit -c 'CMD ["/sbin/init"]' ubi-m3-release-build ubi-m3-release >/dev/null
  say "committed ubi-m3-release (rev $(cat "$ART/src.rev"))"
}

# --- helpers on a running control-plane container ---------------------

psql_q() { dx "$1" runuser -u postgres -- psql -XtAq -d ubicloud -c "$2"; }

web_up() { [[ $(dx "$1" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/login) == 200 ]]; }

main_pid() { dx "$1" systemctl show -p MainPID --value "$2"; }

child_pid() { dx "$1" pgrep -P "$(main_pid "$1" ubicloud-respirate)" || true; }

has_child() { [[ -n $(child_pid "$1") ]]; }

# child_changed NAME OLD: a respirate child other than OLD runs.
child_changed() {
  local c
  c=$(child_pid "$1")
  [[ -n $c && $c != "$2" ]]
}

# main_changed NAME OLD: ubicloud-respirate has a MainPID other than OLD.
main_changed() {
  local n
  n=$(main_pid "$1" ubicloud-respirate)
  [[ $n != 0 && $n != "$2" ]]
}

# Makes the LogVmHostUtilizations strand (respirate creates it, it naps
# 60 s) due now. strand_ran then sees it ran once its schedule is pushed
# out again. A strand still leased by a dead respirate waits for the
# 120 s lease first.
poke_strand() {
  psql_q "$1" "UPDATE strand SET schedule = now() WHERE prog = 'LogVmHostUtilizations'" >/dev/null
}
strand_ran() {
  [[ $(psql_q "$1" "SELECT count(*) FROM strand WHERE prog = 'LogVmHostUtilizations' AND schedule > now() + interval '20 seconds'") == 1 ]]
}

# hold_vm_host_lock NAME SECS: a postgres session holds an ACCESS
# EXCLUSIVE lock on vm_host for SECS, so a LogVmHostUtilizations run
# blocks in its query while it holds the strand's lease: a strand that is
# running, for as long as the harness wants.
hold_vm_host_lock() {
  docker exec -d "ubi-m3-$1" runuser -u postgres -- psql -Xq -d ubicloud \
    -c "BEGIN; LOCK TABLE vm_host IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep($2); COMMIT"
}
release_vm_host_lock() {
  psql_q "$1" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE 'BEGIN; LOCK TABLE vm_host%'" >/dev/null
}
# blocked_at_least NAME N: N respirate queries wait on that lock.
blocked_at_least() {
  (($(psql_q "$1" "SELECT count(*) FROM pg_stat_activity WHERE usename = 'ubicloud' AND wait_event_type = 'Lock'") >= $2))
}

# stop_respirate NAME LABEL: stops ubicloud-respirate and prints
# "SECONDS RESULT STATUS".
stop_respirate() {
  local t
  t=$(timed dx "$1" systemctl stop ubicloud-respirate) || fail "$2: systemctl stop failed"
  echo "$t $(dx "$1" systemctl show -p Result --value ubicloud-respirate) $(dx "$1" systemctl show -p ExecMainStatus --value ubicloud-respirate)"
}

# release_rev_to_art NAME: makes the release's own rev the --source-rev
# of the next install_cp, so that a rerun matches the installed release
# even when the working tree has moved on. install.sh then reads only
# mise.toml and bin/byoh-smtp-url from the tarball.
release_rev_to_art() {
  dx "$1" sed -n 's/^rev=//p' /opt/ubicloud/current/.ubicloud-release >"$ART/src.rev"
}

# boot_cp NAME: a fresh control plane from ubi-m3-release, with the
# units of the working tree, started and healthy.
boot_cp() {
  local t
  stage_art
  start_sys "$1" ubi-m3-release
  dx "$1" bash /art/fixture.sh units
  dx "$1" systemctl start ubicloud.target
  t=$(wait_for 180 web_up "$1") || {
    dx "$1" journalctl -u ubicloud-web --no-pager | tail -40 >>"$LOGS/harness.log"
    fail "$1: web did not answer within 180 s"
  }
  say "$1: web answers after ${t}s"
  poke_strand "$1"
  t=$(wait_for 60 strand_ran "$1") || fail "$1: respirate ran no strand within 60 s"
  say "$1: respirate ran the probe strand after ${t}s"
}

assert_active() {
  local u
  for u in ubicloud-web ubicloud-respirate ubicloud-backup.timer ubicloud.target; do
    [[ $(dx "$1" systemctl is-active "$u") == active ]] || fail "$1: $u not active"
  done
}

# journal_clean NAME SINCE: no Ruby error in either service since SINCE.
journal_clean() {
  local out
  out=$(dx "$1" journalctl -u ubicloud-respirate -u ubicloud-web -u ubicloud-monitor --since "$2" --no-pager -o cat |
    grep -E 'Errno::|ESRCH|exception terminates|\(NoMethodError\)|\(RuntimeError\)|Traceback|from /opt/ubicloud' || true)
  [[ -z $out ]] || {
    printf '%s\n' "$out" | head -20 >>"$LOGS/harness.log"
    fail "$1: errors in the journal since $2"
  }
}

# Two-step Rodauth login over http://localhost:3000; prints the final
# location. Production cookies are Secure, and curl sends them to
# localhost over plain http.
login() {
  dx "$1" bash -s "$EMAIL" "$PASSWORD" <<'EOF'
set -euo pipefail
jar=$(mktemp)
csrf() { grep -o '<input name="_csrf"[^>]*>' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/'; }
tok=$(curl -sf -c "$jar" -b "$jar" http://localhost:3000/login | csrf)
tok=$(curl -sf -c "$jar" -b "$jar" --data-urlencode "_csrf=$tok" --data-urlencode "login=$1" http://localhost:3000/login | csrf)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -c "$jar" -b "$jar" \
  --data-urlencode "_csrf=$tok" --data-urlencode "login=$1" --data-urlencode "password=$2" \
  http://localhost:3000/login
rm -f "$jar"
EOF
}

# --- scenarios -----------------------------------------------------------

# Compares how systemd's EnvironmentFile= and bash's `set -a; . F` read
# the KEY='value' format of /etc/ubicloud/env (M3-b). The keys in
# ENVFMT_DIFFER are the cases that parse differently, and a change in
# that set fails the run. Result on systemd 255: inside single quotes
# both read $, #, \, tabs, CR and leading or trailing spaces literally;
# only text after the closing quote differs (systemd keeps "# c", bash
# drops it as a comment), so a writer must end each line at the quote.
# The validator still rejects ', \, newline and NUL in values.
ENVFMT_DIFFER="T_AFTERCMT"
sc_envfmt() {
  local f="$ART/envfmt.env" sd bs differ="" k
  cat >"$f" <<'EOF'
T_PLAIN='abc'
T_SPACE='a b'
T_DOLLAR='a$b'
T_BRACE='${HOME}x'
T_CMD='$(id -u)'
T_BT='a`id`b'
T_HASH='a#b'
T_HASHSP='a #b'
T_TRAIL='ab  '
T_LEAD='  ab'
T_BSL='a\b'
T_BSLN='a\nb'
T_BSLQ='a\\b'
T_DQ='a"b'
T_EQ='a=b=c'
T_SEMI='a;b'
T_PCT='a%nb%%'
T_EMPTY=''
T_UTF='ü€'
T_TAB='a	b'
T_ENDBSL='ab\'
T_AFTERSP='ab'
T_AFTERCMT='ab' # c
EOF
  printf "T_CR='a\rb'\n" >>"$f"
  chmod 0644 "$f"
  start_sys envfmt ubi-m3-systemd
  sd=$(dx envfmt systemd-run --quiet --wait --pipe --collect -p EnvironmentFile=/art/envfmt.env env | grep '^T_' | sort)
  bs=$(dx envfmt env -i bash -c 'set -a; . /art/envfmt.env; env' | grep '^T_' | sort)
  {
    echo "# systemd $(dx envfmt systemctl --version | head -1)"
    echo "# key: systemd | bash"
    while read -r k; do
      local a b
      a=$(grep "^$k=" <<<"$sd" || echo "<unset>")
      b=$(grep "^$k=" <<<"$bs" || echo "<unset>")
      if [[ $a == "$b" ]]; then
        echo "same   $a"
      else
        echo "DIFFER systemd[$a] bash[$b]"
        differ+="${differ:+ }$k"
      fi
    done < <(grep -o '^T_[A-Z]*' "$f")
  } >"$LOGS/envfmt.txt"
  cat "$LOGS/envfmt.txt"
  [[ $differ == "$ENVFMT_DIFFER" ]] ||
    fail "envfmt: expected [$ENVFMT_DIFFER] to differ, got [$differ]; update install.sh's validator"
  say "envfmt: ok, differing keys: $differ"
}

sc_verify() {
  local out after req
  boot_cp verify
  out=$(dx verify bash -c 'cd /etc/systemd/system && systemd-analyze verify ubicloud.target ubicloud-*.service ubicloud-*.timer 2>&1' || true)
  # The backup service names ubicloud-admin, which WP6 installs.
  out=$(grep -v 'ubicloud-admin' <<<"$out" || true)
  [[ -z $out ]] || {
    printf '%s\n' "$out" >>"$LOGS/harness.log"
    fail "systemd-analyze verify: $out"
  }
  for u in ubicloud-web ubicloud-respirate; do
    after=$(dx verify systemctl list-dependencies --after --plain --no-pager "$u")
    grep -q 'postgresql@16-main.service' <<<"$after" || fail "$u not ordered after postgresql@16-main"
    grep -q 'network-online.target' <<<"$after" || fail "$u not ordered after network-online.target"
    req=$(dx verify systemctl show -p Requires --value "$u")
    [[ $req != *postgresql* ]] || fail "$u Requires= postgres"
    dx verify systemd-analyze security --no-pager "$u" >"$LOGS/security-$u.txt" 2>&1 || true
    say "verify: $u $(tail -1 "$LOGS/security-$u.txt")"
  done
  [[ $(dx verify systemctl is-enabled ubicloud-monitor || true) == disabled ]] ||
    fail "ubicloud-monitor is not disabled"
  [[ $(dx verify systemctl is-active ubicloud-monitor || true) == inactive ]] ||
    fail "ubicloud-monitor is running"
  # Until WP6 installs ubicloud-admin, a backup run is skipped, not failed.
  dx verify test ! -e /usr/local/bin/ubicloud-admin || fail "verify: ubicloud-admin exists, update this check"
  dx verify systemctl start ubicloud-backup.service || fail "verify: starting ubicloud-backup failed"
  [[ $(dx verify systemctl show -p ConditionResult --value ubicloud-backup.service) == no ]] ||
    fail "verify: ubicloud-backup did not skip on its condition"
  [[ $(dx verify systemctl is-failed ubicloud-backup.service || true) != failed ]] ||
    fail "verify: ubicloud-backup failed"
  say "verify: ubicloud-backup without ubicloud-admin is skipped, not failed"
  say "verify: ok"
}

# Lists the managed files whose bytes a rerun must not change.
SETTINGS_FILES="/etc/ubicloud/env /etc/ubicloud/backup.conf /etc/ubicloud/backup-recipients
  /etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/pg_ident.conf
  /etc/systemd/system/ubicloud*"
settings_sums() { dx "$1" bash -c "sha256sum ${SETTINGS_FILES//$'\n'/ }"; }
service_pids() { echo "$(main_pid "$1" ubicloud-web) $(main_pid "$1" ubicloud-respirate)"; }

# psql_as NAME OSUSER ARGS...: psql -c 'SELECT 1' as OSUSER; succeeds
# only when postgres lets that login in.
psql_as() {
  local name=$1 user=$2
  shift 2
  dx "$name" runuser -u "$user" -- psql -X -tA "$@" -c 'SELECT 1' >/dev/null 2>&1
}

# One-command install from the tools image (packages, ruby and node
# already there): a release of the working tree, the database, the env
# file, migrations and the units, started.
sc_fresh() {
  local out since t
  stage_art
  src_tarball
  start_sys fresh ubi-m3-tools
  since=$(dx fresh date '+%F %T')
  backup_key fresh
  # M3-n: a build that died left releases/t1.tmp; the next build starts over.
  dx fresh bash -c 'install -d /opt/ubicloud/releases/t1.tmp && touch /opt/ubicloud/releases/t1.tmp/stale'
  install_cp fresh >"$LOGS/fresh-install.log" 2>&1 || fail "fresh: install.sh failed, see $LOGS/fresh-install.log"
  dx fresh test ! -e /opt/ubicloud/releases/t1.tmp || fail "fresh: the leftover releases/t1.tmp is still there"
  grep -E '^(ok|changed|skip|warn|notice) ' "$LOGS/fresh-install.log" | tee -a "$LOGS/harness.log" >/dev/null
  t=$(wait_for 180 web_up fresh) || fail "fresh: web did not answer within 180 s"
  say "fresh: install done, web answers after ${t}s more"
  assert_active fresh
  [[ $(dx fresh systemctl is-enabled ubicloud.target) == enabled ]] || fail "fresh: ubicloud.target is not enabled"
  [[ $(dx fresh systemctl is-enabled ubicloud-monitor || true) == disabled ]] || fail "fresh: ubicloud-monitor is not disabled"
  out=$(dx fresh ss -Htln | grep -E ':3000\b' || true)
  [[ $out == *"127.0.0.1:3000"* && $out != *"0.0.0.0:3000"* && $out != *"[::]:3000"* ]] ||
    fail "fresh: puma listens on: $out"
  [[ $(dx fresh runuser -u postgres -- psql -XtAc 'SHOW listen_addresses') == localhost ]] ||
    fail "fresh: postgres listen_addresses is not localhost"

  # Roles and authentication (M3-e).
  out=$(dx fresh runuser -u postgres -- psql -XtAc "SELECT string_agg(rolname || ':' || rolsuper || rolcreatedb || rolcreaterole, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname LIKE 'ubicloud%'")
  [[ $out == "ubicloud:falsefalsefalse ubicloud_password:falsefalsefalse" ]] || fail "fresh: roles are $out"
  out=$(dx fresh sed -n '/^# BEGIN ubicloud$/,/^# END ubicloud$/p' /etc/postgresql/16/main/pg_hba.conf)
  [[ -n $out && $out != *trust* && $out != *md5* && $out != *scram* ]] || fail "fresh: the managed hba block: $out"
  [[ $(dx fresh grep -v -e '^#' -e '^[[:space:]]*$' /etc/postgresql/16/main/pg_hba.conf | head -1) == "local ubicloud postgres peer" ]] ||
    fail "fresh: the managed hba block is not the first rule"
  psql_as fresh ubicloud -d ubicloud || fail "fresh: ubicloud cannot log in as role ubicloud"
  psql_as fresh ubicloud-migrate -d ubicloud -U ubicloud_password || fail "fresh: ubicloud-migrate cannot log in as ubicloud_password"
  psql_as fresh ubicloud -d ubicloud -U ubicloud_password && fail "fresh: ubicloud logged in as ubicloud_password"
  psql_as fresh ubicloud -d ubicloud -h 127.0.0.1 && fail "fresh: a TCP login to ubicloud was accepted"
  psql_as fresh postgres -d ubicloud -h 127.0.0.1 && fail "fresh: a TCP login as postgres to ubicloud was accepted"
  say "fresh: roles not superuser, peer map only, password role refused to ubicloud, TCP refused"

  # Files and ownership (M3-b, M3-n).
  out=$(dx fresh stat -c '%U:%G %a %n' /etc/ubicloud/env /etc/ubicloud/backup.conf)
  [[ $out == "root:root 600 /etc/ubicloud/env"$'\n'"root:root 600 /etc/ubicloud/backup.conf" ]] ||
    fail "fresh: settings files are $out"
  dx fresh grep -q '^PRY_ALLOW_UNAUDITED=' /etc/ubicloud/env && fail "fresh: the env file sets PRY_ALLOW_UNAUDITED"
  dx fresh grep -q '^GIT_REV=' /etc/ubicloud/env && fail "fresh: the env file sets GIT_REV"
  for k in RACK_ENV CLOVER_DATABASE_URL CLOVER_SESSION_SECRET CLOVER_COLUMN_ENCRYPTION_KEY CLOVER_RUNTIME_TOKEN_SECRET \
    BASE_URL ADMIN_URL BIND PORT DB_POOL_WEB MAIL_DRIVER MAIL_FROM BOOT_IMAGE_SOURCE DELETED_RECORD_DROP_UNARCHIVED \
    ALLOW_UNSPREAD_SERVERS BILLING_RATES_EXTRA_DIR; do
    dx fresh grep -q "^$k='" /etc/ubicloud/env || fail "fresh: the env file has no $k"
  done
  dx fresh grep -q '^IP_FROM_HEADER=' /etc/ubicloud/env && fail "fresh: --tls none set IP_FROM_HEADER"
  dx fresh runuser -u ubicloud -- touch /opt/ubicloud/current/x 2>/dev/null && fail "fresh: ubicloud could write the release"
  out=$(dx fresh runuser -u ubicloud -- find /opt/ubicloud -xdev ! -type l -writable -print -quit)
  [[ -z $out ]] || fail "fresh: ubicloud can write $out"
  out=$(dx fresh runuser -u ubicloud-migrate -- find /opt/ubicloud -xdev ! -type l -writable -print -quit)
  [[ -z $out ]] || fail "fresh: ubicloud-migrate can write $out"
  out=$(dx fresh find /opt/ubicloud -xdev ! -user root -print -quit)
  [[ -z $out ]] || fail "fresh: $out is not owned by root"
  dx fresh test -s /var/backups/ubicloud/KEYS-README.txt || fail "fresh: no KEYS-README.txt"
  dx fresh cmp -s /root/backup-recipient /etc/ubicloud/backup-recipients || fail "fresh: backup recipients not installed"
  out=$(dx fresh find / -xdev -name '*ubi-bootstrap*' -print -quit)
  [[ -z $out ]] || fail "fresh: found $out"
  say "fresh: env and backup.conf root 0600 with the full key set, release and tools read-only and root-owned"

  # bundler's settings hold without bundle exec, and both groups load.
  out=$(dx fresh bash -c 'cd /opt/ubicloud/current && cat .bundle/config')
  [[ $out == *'BUNDLE_DEPLOYMENT: "true"'* && $out == *'BUNDLE_WITHOUT: "test:rubocop'* ]] ||
    fail "fresh: .bundle/config is $out"

  # The BYOH config check, as the services run it.
  dx fresh bash /art/fixture.sh as-service bin/byoh-config-check >"$LOGS/fresh-config-check.txt" 2>&1 || true
  grep -q '^ok   database role ubicloud: not a superuser' "$LOGS/fresh-config-check.txt" ||
    fail "fresh: byoh-config-check role check: $(cat "$LOGS/fresh-config-check.txt")"
  if grep -q '^fail' "$LOGS/fresh-config-check.txt"; then
    fail "fresh: byoh-config-check fails: $(grep '^fail' "$LOGS/fresh-config-check.txt")"
  fi
  say "fresh: byoh-config-check has no fail ($(grep -c '^ok' "$LOGS/fresh-config-check.txt") ok, $(grep -c '^warn' "$LOGS/fresh-config-check.txt") warn)"

  # M3-p: the committed Sequel caches match the migrated schema. The
  # refresh runs in a scratch copy, never in the release.
  dx fresh bash -c 'rm -rf /var/tmp/cc && cp -a /opt/ubicloud/releases/t1 /var/tmp/cc && chown -R -h ubicloud-migrate /var/tmp/cc'
  dx fresh env FIXTURE_CWD=/var/tmp/cc FIXTURE_SETENV=FORCE_AUTOLOAD=1 \
    bash /art/fixture.sh as-migrate bin/rake-task-runner refresh_sequel_caches >"$LOGS/fresh-caches.log" 2>&1 ||
    fail "fresh: refresh_sequel_caches failed, see $LOGS/fresh-caches.log"
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx fresh bash -c 'for f in /opt/ubicloud/current/cache/*.cache; do cmp -s "$f" "/var/tmp/cc/cache/${f##*/}" || echo "${f##*/}"; done')
  [[ -z $out ]] || fail "fresh: the shipped Sequel caches differ from the migrated schema: $out"
  dx fresh rm -rf /var/tmp/cc
  say "fresh: the shipped cache/*.cache match a refresh against the installed schema"

  printf '%s\n' "$PASSWORD" | dx fresh bash /art/fixture.sh account "$EMAIL" >"$LOGS/fresh-account.txt" 2>&1 ||
    fail "fresh: account create: $(cat "$LOGS/fresh-account.txt")"
  out=$(login fresh) || fail "fresh: login request failed"
  [[ $out == "302 http://localhost:3000/after-login" ]] || fail "fresh: login: $out"
  say "fresh: account created, login ok ($out)"
  poke_strand fresh
  wait_for 60 strand_ran fresh >/dev/null || fail "fresh: respirate ran no strand"
  journal_clean fresh "$since"
  say "fresh: ok"
}

# install.sh again on an installed control plane: identical arguments
# change nothing; a setting that differs from the flags exits 2 until
# --update-env; another version exits 2.
sc_rerun() {
  local sums pids out rc since
  boot_cp rerun
  since=$(dx rerun date '+%F %T')
  src_tarball
  release_rev_to_art rerun
  sums=$(settings_sums rerun)
  pids=$(service_pids rerun)
  # No secret value on a command line while install.sh runs: a watcher
  # scans ps for the column key through the whole run, migrate included.
  docker exec -d ubi-m3-rerun bash /art/fixture.sh argv-watch
  wait_for 10 dx rerun test -e /root/argv-watch.run >/dev/null || fail "rerun: the argv watcher did not start"
  install_cp rerun >"$LOGS/rerun-same.log" 2>&1 || fail "rerun: install.sh failed, see $LOGS/rerun-same.log"
  dx rerun rm -f /root/argv-watch.run
  dx rerun test -e /root/argv-watch.saw || fail "rerun: the argv watcher never saw the migrate run"
  dx rerun test ! -e /root/argv-watch.leak || fail "rerun: the column key was on a command line during install.sh"
  say "rerun: no secret on any command line during the run (migrate seen by the watcher)"
  grep -q '^changed ' "$LOGS/rerun-same.log" && fail "rerun: identical arguments changed: $(grep '^changed ' "$LOGS/rerun-same.log")"
  [[ $(settings_sums rerun) == "$sums" ]] || fail "rerun: identical arguments changed a managed file"
  [[ $(service_pids rerun) == "$pids" ]] || fail "rerun: identical arguments restarted a service"
  say "rerun: identical arguments: exit 0, nothing changed, MainPIDs $pids kept"

  rc=0
  install_cp rerun --version t2 >"$LOGS/rerun-t2.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "rerun: --version t2 exited $rc, not 2"
  grep -q 'release switch' "$LOGS/rerun-t2.log" || fail "rerun: --version t2: $(cat "$LOGS/rerun-t2.log")"
  dx rerun test ! -e /opt/ubicloud/releases/t2 || fail "rerun: --version t2 built a release"
  say "rerun: --version t2 exits 2 and points at the release switch"

  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-mailfrom.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "rerun: a different --mail-from exited $rc, not 2"
  grep -q "key MAIL_FROM differs; edit with 'ubicloud-admin env set MAIL_FROM' or pass --update-env MAIL_FROM" "$LOGS/rerun-mailfrom.log" ||
    fail "rerun: a different --mail-from: $(cat "$LOGS/rerun-mailfrom.log")"
  grep -q 'ops@example.test' "$LOGS/rerun-mailfrom.log" && fail "rerun: install.sh printed a value"
  [[ $(settings_sums rerun) == "$sums" ]] || fail "rerun: a refused run changed a managed file"
  say "rerun: a different --mail-from exits 2 naming the key only"

  install_cp rerun --mail-from other@example.test --update-env MAIL_FROM >"$LOGS/rerun-update.log" 2>&1 ||
    fail "rerun: --update-env MAIL_FROM failed, see $LOGS/rerun-update.log"
  grep -q '^changed settings: /etc/ubicloud/env: updated MAIL_FROM$' "$LOGS/rerun-update.log" ||
    fail "rerun: --update-env: $(cat "$LOGS/rerun-update.log")"
  grep -q 'other@example.test' "$LOGS/rerun-update.log" && fail "rerun: install.sh printed a value"
  [[ $(dx rerun grep '^MAIL_FROM=' /etc/ubicloud/env) == "MAIL_FROM='other@example.test'" ]] || fail "rerun: MAIL_FROM not updated"
  [[ $(dx rerun stat -c '%U:%G %a' /etc/ubicloud/env) == "root:root 600" ]] || fail "rerun: the env file mode changed"
  wait_for 120 web_up rerun >/dev/null || fail "rerun: web down after --update-env"
  [[ $(service_pids rerun) != "$pids" ]] || fail "rerun: --update-env did not restart the services"
  say "rerun: --update-env MAIL_FROM updated the key and restarted the services"

  # A key the env file lacks is appended by name; a value is never shown.
  dx rerun sed -i '/^DB_POOL_WEB=/d' /etc/ubicloud/env
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-add.log" 2>&1 || fail "rerun: re-adding a key failed"
  grep -q '^changed settings: /etc/ubicloud/env: added DB_POOL_WEB$' "$LOGS/rerun-add.log" ||
    fail "rerun: re-adding a key: $(cat "$LOGS/rerun-add.log")"

  # M3-q: the services never run with the console's opt-in.
  sums=$(settings_sums rerun)
  dx rerun bash -c "echo \"PRY_ALLOW_UNAUDITED='true'\" >>/etc/ubicloud/env"
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-pry.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'PRY_ALLOW_UNAUDITED' "$LOGS/rerun-pry.log"; then
    fail "rerun: PRY_ALLOW_UNAUDITED in the env file: exit $rc"
  fi
  dx rerun sed -i '/^PRY_ALLOW_UNAUDITED=/d' /etc/ubicloud/env
  # A malformed line is refused without echoing it.
  dx rerun bash -c "echo 'SMTP_PASSWORD=\"s3cret-value\"' >>/etc/ubicloud/env"
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-bad.log" 2>&1 || rc=$?
  if [[ $rc != 1 ]] || ! grep -q "is not KEY='value'" "$LOGS/rerun-bad.log"; then
    fail "rerun: a malformed env line: exit $rc"
  fi
  grep -q 's3cret-value' "$LOGS/rerun-bad.log" && fail "rerun: install.sh printed a malformed line's value"
  dx rerun sed -i '/^SMTP_PASSWORD=/d' /etc/ubicloud/env
  # An env file without the column key: exit 1, and no new key.
  dx rerun cp -p /etc/ubicloud/env /root/env.full
  dx rerun sed -i '/^CLOVER_COLUMN_ENCRYPTION_KEY=/d' /etc/ubicloud/env
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-nokey.log" 2>&1 || rc=$?
  if [[ $rc != 1 ]] || ! grep -q 'has no CLOVER_COLUMN_ENCRYPTION_KEY' "$LOGS/rerun-nokey.log"; then
    fail "rerun: an env file without the column key: exit $rc"
  fi
  dx rerun grep -q '^CLOVER_COLUMN_ENCRYPTION_KEY=' /etc/ubicloud/env && fail "rerun: a refused run wrote a new column key"
  dx rerun cp -p /root/env.full /etc/ubicloud/env
  [[ $(settings_sums rerun) == "$sums" ]] || fail "rerun: the refused runs changed a managed file"
  say "rerun: PRY_ALLOW_UNAUDITED, a malformed line and a missing column key are refused without showing values"

  # GIT_REV in the env file is only a warning: .release-env overrides it.
  dx rerun bash -c "echo \"GIT_REV='0123abc'\" >>/etc/ubicloud/env"
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-gitrev.log" 2>&1 ||
    fail "rerun: GIT_REV in the env file failed the run, see $LOGS/rerun-gitrev.log"
  grep -qE '^warn +env: /etc/ubicloud/env sets GIT_REV' "$LOGS/rerun-gitrev.log" || fail "rerun: no GIT_REV warning"
  grep -q '^changed ' "$LOGS/rerun-gitrev.log" && fail "rerun: GIT_REV changed: $(grep '^changed ' "$LOGS/rerun-gitrev.log")"
  dx rerun sed -i '/^GIT_REV=/d' /etc/ubicloud/env
  [[ $(settings_sums rerun) == "$sums" ]] || fail "rerun: the GIT_REV run changed a managed file"
  say "rerun: GIT_REV in the env file warns and changes nothing"

  # A lost env file with a migrated database: no new column key.
  dx rerun mv /etc/ubicloud/env /root/env.saved
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-noenv.log" 2>&1 || rc=$?
  if [[ $rc != 1 ]] || ! grep -q 'restore the env file' "$LOGS/rerun-noenv.log"; then
    fail "rerun: a missing env file with a migrated database: exit $rc"
  fi
  dx rerun test ! -e /etc/ubicloud/env || fail "rerun: a refused run wrote a new env file"
  dx rerun mv /root/env.saved /etc/ubicloud/env
  say "rerun: a missing env file with a migrated database is refused"

  # The same version from another rev is refused before anything changes.
  local rev
  rev=$(cat "$ART/src.rev")
  echo 0000000000000000000000000000000000000000 >"$ART/src.rev"
  pids=$(service_pids rerun)
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-rev.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "rerun: another rev exited $rc, not 2"
  grep -q "release t1 exists with rev $rev, not 0000000000000000000000000000000000000000" "$LOGS/rerun-rev.log" ||
    fail "rerun: another rev: $(cat "$LOGS/rerun-rev.log")"
  grep -q '^changed ' "$LOGS/rerun-rev.log" && fail "rerun: another rev changed: $(grep '^changed ' "$LOGS/rerun-rev.log")"
  [[ $(settings_sums rerun) == "$sums" ]] || fail "rerun: another rev changed a managed file"
  [[ $(service_pids rerun) == "$pids" ]] || fail "rerun: another rev restarted a service"
  echo "$rev" >"$ART/src.rev"
  say "rerun: another rev exits 2 naming both revs, and changes nothing"

  sc_rerun_tools
  sc_rerun_backup
  assert_active rerun
  journal_clean rerun "$since"
  sc_rerun_pg_stopped
  say "rerun: ok"
}

tool_links() {
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx "$1" bash -c 'for t in /opt/ubicloud/tools/bin/*; do echo "$t -> $(readlink "$t")"; done'
}

# A source whose mise.toml wants another Ruby than the current release
# runs on: --stage tools and a new --version both exit 2 before the
# shared tools change under the running services.
sc_rerun_tools() {
  local links rc
  dx rerun bash -s <<'EOF'
set -euo pipefail
rm -rf /root/s && mkdir /root/s && tar -xzf /art/src.tgz -C /root/s
sed -i 's/^ruby = ".*"$/ruby = "9.9.9"/' /root/s/mise.toml
grep -q '^ruby = "9.9.9"$' /root/s/mise.toml
tar -czf /root/src-ruby.tgz -C /root/s . && rm -rf /root/s
EOF
  links=$(tool_links rerun)
  rc=0
  dx rerun bash /art/install.sh --stage tools --source-tarball /root/src-ruby.tgz --source-rev "$(cat "$ART/src.rev")" \
    --skip-check clock >"$LOGS/rerun-tools.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'changing them is a release switch' "$LOGS/rerun-tools.log"; then
    fail "rerun: --stage tools with another ruby: exit $rc, see $LOGS/rerun-tools.log"
  fi
  rc=0
  dx rerun bash /art/install.sh "${INSTALL_ARGS[@]}" --mail-from other@example.test --version t2 \
    --source-tarball /root/src-ruby.tgz --source-rev "$(cat "$ART/src.rev")" >"$LOGS/rerun-tools-t2.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "rerun: --version t2 with another ruby exited $rc, not 2"
  [[ $(tool_links rerun) == "$links" ]] || fail "rerun: a refused run changed the tools links"
  dx rerun test ! -e /opt/ubicloud/tools/mise/installs/ruby/9.9.9 || fail "rerun: a refused run built ruby 9.9.9"
  say "rerun: another ruby in mise.toml exits 2 with the tools untouched"
}

# backup.conf and the recipients: a different flag exits 2 until
# --update-env names the key.
sc_rerun_backup() {
  local rc sums
  sums=$(settings_sums rerun)
  rc=0
  install_cp rerun --mail-from other@example.test --backup-target /var/backups/other >"$LOGS/rerun-btarget.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q "key BACKUP_TARGET differs" "$LOGS/rerun-btarget.log"; then
    fail "rerun: another --backup-target: exit $rc"
  fi
  [[ $(settings_sums rerun) == "$sums" ]] || fail "rerun: a refused --backup-target changed a managed file"
  dx rerun test ! -e /var/backups/other || fail "rerun: a refused --backup-target created the directory"
  install_cp rerun --mail-from other@example.test --backup-target /var/backups/other --update-env BACKUP_TARGET \
    >"$LOGS/rerun-btarget-update.log" 2>&1 || fail "rerun: --update-env BACKUP_TARGET failed"
  grep -q '^changed settings: /etc/ubicloud/backup.conf: updated BACKUP_TARGET$' "$LOGS/rerun-btarget-update.log" ||
    fail "rerun: --update-env BACKUP_TARGET: $(cat "$LOGS/rerun-btarget-update.log")"
  dx rerun test -s /var/backups/other/KEYS-README.txt || fail "rerun: no KEYS-README.txt in the new target"
  say "rerun: another --backup-target exits 2, --update-env BACKUP_TARGET moves it"

  dx rerun bash -c 'age-keygen -o /root/backup-key2 2>/dev/null && age-keygen -y /root/backup-key2 >/root/backup-recipient2'
  rc=0
  install_cp rerun --mail-from other@example.test --backup-recipient-file /root/backup-recipient2 >"$LOGS/rerun-brecip.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q "key BACKUP_RECIPIENTS differs" "$LOGS/rerun-brecip.log"; then
    fail "rerun: another --backup-recipient-file: exit $rc"
  fi
  dx rerun cmp -s /root/backup-recipient /etc/ubicloud/backup-recipients || fail "rerun: a refused run changed the recipients"
  install_cp rerun --mail-from other@example.test --backup-recipient-file /root/backup-recipient2 --update-env BACKUP_RECIPIENTS \
    >"$LOGS/rerun-brecip-update.log" 2>&1 || fail "rerun: --update-env BACKUP_RECIPIENTS failed"
  grep -q '^changed backups: recipients in /etc/ubicloud/backup-recipients$' "$LOGS/rerun-brecip-update.log" ||
    fail "rerun: --update-env BACKUP_RECIPIENTS: $(cat "$LOGS/rerun-brecip-update.log")"
  dx rerun cmp -s /root/backup-recipient2 /etc/ubicloud/backup-recipients || fail "rerun: the recipients were not replaced"
  say "rerun: another backup recipient exits 2, --update-env BACKUP_RECIPIENTS replaces it"
}

# A lost env file while postgres is stopped: install.sh starts postgres
# to look, finds the schema and refuses; it never takes a stopped server
# for an empty one.
sc_rerun_pg_stopped() {
  local rc
  dx rerun systemctl stop ubicloud.target postgresql@16-main
  dx rerun mv /etc/ubicloud/env /root/env.saved
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-noenv-pgdown.log" 2>&1 || rc=$?
  if [[ $rc != 1 ]] || ! grep -q 'restore the env file' "$LOGS/rerun-noenv-pgdown.log"; then
    fail "rerun: a missing env file with postgres stopped: exit $rc, see $LOGS/rerun-noenv-pgdown.log"
  fi
  dx rerun test ! -e /etc/ubicloud/env || fail "rerun: a refused run wrote a new env file"
  dx rerun mv /root/env.saved /etc/ubicloud/env
  dx rerun systemctl start ubicloud.target
  wait_for 180 web_up rerun >/dev/null || fail "rerun: web down after the postgres-stopped check"
  assert_active rerun
  say "rerun: a missing env file with postgres stopped is refused"
}

# The install.sh paths that fresh does not take: usage errors, a git
# source owned by another user, relative paths, an SMTP URL file, a
# billing-rates directory, development mode, --no-start, a postgres that
# listens on every address and has trust lines and a superuser, a port
# that is taken, a development control plane, and SMTP credentials that
# a later URL drops.
sc_flags() {
  local rc out rev
  stage_art
  src_tarball
  start_sys flags ubi-m3-tools
  backup_key flags
  # Usage errors exit 2 before anything changes.
  local spec bad=()
  for spec in "--mgmt-endpoint cp.example.test:51820" "--smtp smtp://u:p@h" "--tls acme" \
    "--url https://cp.example.test" "--version bad/version" "--backup-target s3://bucket" \
    "--cert /etc/hostname" "--import-env-rb /etc/hostname" "--stage release" \
    "--url http://localhost" "--url http://localhost:8080"; do
    read -ra bad <<<"$spec"
    rc=0
    install_cp flags "${bad[@]}" >"$LOGS/flags-usage.log" 2>&1 || rc=$?
    [[ $rc == 2 ]] || fail "flags: ${bad[*]} exited $rc, not 2: $(cat "$LOGS/flags-usage.log")"
  done
  rc=0
  dx flags bash /art/install.sh "${INSTALL_ARGS[@]}" >"$LOGS/flags-usage.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "flags: no source exited $rc, not 2"
  dx flags test ! -e /etc/ubicloud || fail "flags: a refused run created /etc/ubicloud"
  say "flags: usage errors exit 2 and change nothing"

  # A git checkout owned by another user, as on the live control plane.
  dx flags bash -c 'useradd -m dev && install -d -o dev -g dev /home/dev/repo &&
    runuser -u dev -- tar -xzf /art/src.tgz -C /home/dev/repo &&
    cd /home/dev/repo && runuser -u dev -- git init -q &&
    runuser -u dev -- git add -A && runuser -u dev -- git -c user.email=dev@example.test -c user.name=dev commit -qm src'
  rev=$(dx flags bash -c 'cd /home/dev/repo && runuser -u dev -- git rev-parse HEAD')
  # The SMTP URL file must be 0600; the password must never be printed.
  dx flags bash -c "printf 'smtp://mailer:p%%40ss-w0rd@mail.example.test:2525?tls=off\n' >/root/smtp && chmod 0644 /root/smtp &&
    mkdir -p /root/rates && printf -- '- id: harness\n' >/root/rates/byoh-harness.yml"
  # The first runs give every path relative to /root: install.sh runs git
  # from /, so it must resolve them first. Later runs use absolute paths.
  local -a common=(--version t1 --url http://localhost:3000 --tls none --admin-email ops@example.test
    --skip-check clock --ref HEAD --rack-env development)
  local -a rel=("${common[@]}" --source-git ../home/dev/repo --smtp-file smtp --billing-rates-dir rates
    --backup-recipient-file backup-recipient --no-start)
  local -a args=("${common[@]}" --source-git /home/dev/repo --smtp-file /root/smtp --billing-rates-dir /root/rates
    --backup-recipient-file /root/backup-recipient)
  rc=0
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx flags bash -c 'cd /root && exec bash /art/install.sh "$@"' install.sh "${rel[@]}" >"$LOGS/flags-smtp-mode.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'chmod 600' "$LOGS/flags-smtp-mode.log"; then
    fail "flags: a 0644 --smtp-file exited $rc"
  fi
  dx flags chmod 0600 /root/smtp
  # As an operator would: the stock commented line, above include_dir.
  dx flags sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
  # As the development bootstrap leaves it: trust lines and a superuser.
  dx flags sed -i -E 's/^(local[[:space:]]+all[[:space:]]+all[[:space:]]+)peer/\1trust/' /etc/postgresql/16/main/pg_hba.conf
  dx flags grep -qE '^local[[:space:]]+all[[:space:]]+all[[:space:]]+trust' /etc/postgresql/16/main/pg_hba.conf ||
    fail "flags: could not add a trust line"
  dx flags systemctl restart postgresql@16-main
  [[ $(dx flags runuser -u postgres -- psql -XtAc 'SHOW listen_addresses') == '*' ]] ||
    fail "flags: could not make postgres listen on '*'"
  dx flags runuser -u postgres -- psql -Xqc 'CREATE ROLE clover LOGIN SUPERUSER'
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx flags bash -c 'cd /root && exec bash /art/install.sh "$@"' install.sh "${rel[@]}" >"$LOGS/flags-install.log" 2>&1 ||
    fail "flags: install.sh failed, see $LOGS/flags-install.log"
  grep -q 'p@ss-w0rd\|p%40ss-w0rd' "$LOGS/flags-install.log" && fail "flags: install.sh printed the SMTP password"
  [[ $(dx flags sed -n 's/^rev=//p' /opt/ubicloud/current/.ubicloud-release) == "$rev" ]] ||
    fail "flags: the release rev is not the commit of --ref HEAD"
  out=$(dx flags grep -E '^(RACK_ENV|MAIL_DRIVER|SMTP_[A-Z]*)=' /etc/ubicloud/env | sort | tr '\n' ' ')
  [[ $out == "MAIL_DRIVER='smtp' RACK_ENV='development' SMTP_HOSTNAME='mail.example.test' SMTP_PASSWORD='p@ss-w0rd' SMTP_PORT='2525' SMTP_TLS='false' SMTP_USER='mailer' " ]] ||
    fail "flags: env has ${out//p@ss-w0rd/<password>}"
  [[ $(dx flags stat -c '%U:%G' /var/lib/ubicloud/billing_rates.d/byoh-harness.yml) == ubicloud:ubicloud ]] ||
    fail "flags: the billing rates were not copied"
  [[ $(dx flags runuser -u postgres -- psql -XtAc 'SHOW listen_addresses') == localhost ]] ||
    fail "flags: listen_addresses is not localhost"
  grep -q '^notice  database: restarting postgresql@16-main' "$LOGS/flags-install.log" || fail "flags: no restart notice"
  dx flags cmp -s /root/backup-recipient /etc/ubicloud/backup-recipients || fail "flags: the relative recipient file was not installed"
  grep -qE '^warn +database: /etc/postgresql/16/main/pg_hba.conf line\(s\) [0-9,]+ use trust' "$LOGS/flags-install.log" ||
    fail "flags: no warning about the trust lines"
  grep -qE '^warn +database: role\(s\) clover are superusers' "$LOGS/flags-install.log" ||
    fail "flags: no warning about the superuser"
  [[ $(dx flags systemctl is-enabled ubicloud.target || true) != enabled ]] || fail "flags: --no-start enabled the target"
  [[ $(dx flags systemctl is-active ubicloud-web || true) != active ]] || fail "flags: --no-start started web"
  say "flags: git source as its owner, relative paths, SMTP from a 0600 file (no password in the output), rates copied, listen fixed, trust and superuser warned, --no-start"

  # The same arguments again, absolute (the SMTP file is read again): nothing changes.
  dx flags bash /art/install.sh "${args[@]}" --no-start >"$LOGS/flags-rerun.log" 2>&1 ||
    fail "flags: rerun failed, see $LOGS/flags-rerun.log"
  grep -q '^changed ' "$LOGS/flags-rerun.log" && fail "flags: rerun changed: $(grep '^changed ' "$LOGS/flags-rerun.log")"

  # Starting is refused while another process holds the port, or while a
  # development control plane lives on the machine.
  docker exec -d ubi-m3-flags /opt/ubicloud/tools/bin/ruby -rsocket -e 'TCPServer.new("0.0.0.0", 3000); sleep'
  # shellcheck disable=SC2016 # expanded by the container's bash
  wait_for 20 dx flags bash -c '[[ -n $(ss -Htln "sport = :3000") ]]' >/dev/null || fail "flags: the stand-in listener did not start"
  rc=0
  dx flags bash /art/install.sh "${args[@]}" >"$LOGS/flags-port.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'already listens on port 3000' "$LOGS/flags-port.log"; then
    fail "flags: a taken port: exit $rc, see $LOGS/flags-port.log"
  fi
  dx flags pkill -f TCPServer
  dx flags install -d -o dev -g dev /home/dev/.ubi-bootstrap
  rc=0
  dx flags bash /art/install.sh "${args[@]}" >"$LOGS/flags-devcp.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q '/home/dev/.ubi-bootstrap exists' "$LOGS/flags-devcp.log"; then
    fail "flags: a development control plane: exit $rc, see $LOGS/flags-devcp.log"
  fi
  dx flags rmdir /home/dev/.ubi-bootstrap
  [[ $(dx flags systemctl is-enabled ubicloud.target || true) != enabled ]] || fail "flags: a refused start enabled the target"
  say "flags: a taken port and a development control plane refuse the start"

  # Development mode runs too: install.sh starts it.
  dx flags bash /art/install.sh "${args[@]}" >"$LOGS/flags-start.log" 2>&1 ||
    fail "flags: install.sh start failed, see $LOGS/flags-start.log"
  grep -q '^changed units: started ubicloud.target$' "$LOGS/flags-start.log" || fail "flags: install.sh did not start the target"
  wait_for 180 web_up flags >/dev/null || fail "flags: web did not answer in development mode"
  dx flags bash /art/install.sh --stage tools --source-git /home/dev/repo --ref HEAD --skip-check clock >"$LOGS/flags-tools.log" 2>&1 ||
    fail "flags: --stage tools rerun failed"
  grep -q '^changed ' "$LOGS/flags-tools.log" && fail "flags: --stage tools rerun changed something"
  say "flags: reruns change nothing; development mode serves"

  # A URL without credentials: the old SMTP_USER and SMTP_PASSWORD
  # conflict, and go with --update-env.
  dx flags bash -c "printf 'smtp://mail.example.test:2525?tls=off\n' >/root/smtp-anon && chmod 0600 /root/smtp-anon"
  rc=0
  dx flags bash /art/install.sh "${args[@]}" --smtp-file /root/smtp-anon >"$LOGS/flags-smtp-anon.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'key SMTP_USER differs' "$LOGS/flags-smtp-anon.log" ||
    ! grep -q 'key SMTP_PASSWORD differs' "$LOGS/flags-smtp-anon.log"; then
    fail "flags: a URL without credentials: exit $rc, see $LOGS/flags-smtp-anon.log"
  fi
  dx flags bash /art/install.sh "${args[@]}" --smtp-file /root/smtp-anon --update-env SMTP_USER --update-env SMTP_PASSWORD \
    >"$LOGS/flags-smtp-anon-update.log" 2>&1 || fail "flags: --update-env SMTP_USER SMTP_PASSWORD failed"
  grep -q '^changed settings: /etc/ubicloud/env: removed SMTP_USER SMTP_PASSWORD$' "$LOGS/flags-smtp-anon-update.log" ||
    fail "flags: removing the SMTP credentials: $(cat "$LOGS/flags-smtp-anon-update.log")"
  grep -q 'p@ss-w0rd\|mailer' "$LOGS/flags-smtp-anon.log" "$LOGS/flags-smtp-anon-update.log" && fail "flags: install.sh printed an SMTP credential"
  out=$(dx flags grep -E '^SMTP_[A-Z]*=' /etc/ubicloud/env | sort | tr '\n' ' ')
  [[ $out == "SMTP_HOSTNAME='mail.example.test' SMTP_PORT='2525' SMTP_TLS='false' " ]] || fail "flags: env has ${out//p@ss-w0rd/<password>}"
  wait_for 180 web_up flags >/dev/null || fail "flags: web down after the SMTP change"
  say "flags: SMTP credentials a new URL drops conflict, and --update-env removes them"
  say "flags: ok"
}

sc_smoke() {
  local since out
  boot_cp smoke
  since=$(dx smoke date '+%F %T')
  assert_active smoke
  printf '%s\n' "$PASSWORD" | dx smoke bash /art/fixture.sh account "$EMAIL" >"$LOGS/smoke-account.txt" 2>&1 ||
    fail "account create: $(cat "$LOGS/smoke-account.txt")"
  out=$(login smoke) || fail "login: request failed"
  [[ $out == "302 http://localhost:3000/after-login" ]] || fail "login: $out"
  say "smoke: login ok ($out)"
  # Listener only on loopback.
  out=$(dx smoke ss -Htlnp | grep -E ':3000\b' || true)
  [[ $out == *"127.0.0.1:3000"* && $out != *"0.0.0.0:3000"* && $out != *"[::]:3000"* ]] ||
    fail "puma listens on: $out"
  # The services cannot write the release, and run without capabilities.
  dx smoke runuser -u ubicloud -- touch /opt/ubicloud/current/x 2>/dev/null &&
    fail "ubicloud could write the release"
  # Monitor is shipped disabled (M9) but must run under the same
  # hardening when an operator starts it.
  dx smoke systemctl start ubicloud-monitor
  sleep 10
  [[ $(dx smoke systemctl is-active ubicloud-monitor) == active ]] || fail "monitor did not stay up"
  [[ $(dx smoke systemctl show -p NRestarts --value ubicloud-monitor) == 0 ]] || fail "monitor restarted"
  local u st pid
  for u in ubicloud-web ubicloud-respirate ubicloud-monitor; do
    pid=$(main_pid smoke "$u")
    st=$(dx smoke cat "/proc/$pid/status")
    [[ $(grep '^CapEff:' <<<"$st") == *0000000000000000 ]] || fail "$u has capabilities"
    [[ $(grep '^CapBnd:' <<<"$st") == *0000000000000000 ]] || fail "$u has a capability bounding set"
    [[ $(grep '^NoNewPrivs:' <<<"$st") == *1 ]] || fail "$u runs without NoNewPrivs"
  done
  say "smoke: web, respirate and monitor run with no capabilities and NoNewPrivs"
  dx smoke systemctl stop ubicloud-monitor

  # Without BIND and PORT in the env file, the unit's defaults keep puma
  # on loopback (puma_config.rb alone would bind 0.0.0.0).
  dx smoke cp -p /etc/ubicloud/env /root/env.orig
  dx smoke sed -i '/^BIND=/d; /^PORT=/d' /etc/ubicloud/env
  dx smoke systemctl restart ubicloud-web
  wait_for 120 web_up smoke >/dev/null || fail "smoke: web down without BIND"
  out=$(dx smoke ss -Htln | grep -E ':3000\b' || true)
  [[ $out == *"127.0.0.1:3000"* && $out != *"0.0.0.0:3000"* && $out != *"[::]:3000"* ]] ||
    fail "without BIND, puma listens on: $out"
  dx smoke cp -p /root/env.orig /etc/ubicloud/env
  dx smoke systemctl restart ubicloud-web
  wait_for 120 web_up smoke >/dev/null || fail "smoke: web down after restoring the env"
  say "smoke: without BIND in the env file, puma listens on 127.0.0.1:3000 only"

  # A rerun of the release step while the services run: the managed
  # pg_hba/pg_ident blocks stay as they are, and ubicloud-migrate
  # rewrites the var/ca_bundles files that web and respirate wrote at
  # boot. Then web and respirate rewrite them in turn.
  local sums sums2 cab=/var/lib/ubicloud/var/ca_bundles/db_ca_bundle.crt
  sums=$(dx smoke sha256sum /etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/pg_ident.conf)
  [[ $(dx smoke stat -c %U "$cab") == ubicloud ]] || fail "smoke: $cab not written by the services"
  src_tarball
  release_rev_to_art smoke
  install_cp smoke >"$LOGS/smoke-rerun.log" 2>&1 ||
    fail "smoke: install.sh rerun failed, see $LOGS/smoke-rerun.log"
  sums2=$(dx smoke sha256sum /etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/pg_ident.conf)
  [[ $sums == "$sums2" ]] || fail "smoke: the rerun changed pg_hba.conf or pg_ident.conf"
  [[ $(dx smoke grep -c '^# BEGIN ubicloud$' /etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/pg_ident.conf | cut -d: -f2 | sort -u) == 1 ]] ||
    fail "smoke: more than one managed block"
  [[ $(dx smoke stat -c %U "$cab") == ubicloud-migrate ]] || fail "smoke: the rerun's migrate did not rewrite $cab"
  dx smoke systemctl restart ubicloud-web ubicloud-respirate
  wait_for 120 web_up smoke >/dev/null || fail "smoke: web down after the migrate rerun"
  [[ $(dx smoke stat -c %U "$cab") == ubicloud ]] || fail "smoke: web did not rewrite $cab"
  poke_strand smoke
  wait_for 60 strand_ran smoke >/dev/null || fail "smoke: no strand after the migrate rerun"
  say "smoke: release rerun kept hba/ident, migrate and the services rewrote each other's ca_bundles"
  echo 0000000000000000000000000000000000000000 >"$ART/src.rev"
  local rc=0
  install_cp smoke >>"$LOGS/smoke-rerun.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "smoke: a release rerun with another rev exited $rc, not 2"
  say "smoke: a release rerun with another rev exits 2"
  assert_active smoke
  journal_clean smoke "$since"
  say "smoke: ok"
}

sc_kill() {
  local main child t since
  boot_cp kill
  since=$(dx kill date '+%F %T')
  # Run A: only the child dies; restarter respawns it.
  main=$(main_pid kill ubicloud-respirate)
  child=$(child_pid kill)
  [[ -n $child ]] || fail "kill A: no respirate child under $main"
  dx kill kill -9 "$child"
  t=$(wait_for 4 child_changed kill "$child") || fail "kill A: no new child within 4 s"
  [[ $(main_pid kill ubicloud-respirate) == "$main" ]] || fail "kill A: restarter pid changed"
  say "kill A: new child after ${t}s, restarter $main unchanged"
  echo "kill A (child SIGKILL): new respirate child after ${t}s" >>"$LOGS/kill-times.txt"
  poke_strand kill
  t=$(wait_for 150 strand_ran kill) || fail "kill A: no strand ran within 150 s"
  say "kill A: strand ran after ${t}s"
  echo "kill A: probe strand ran after ${t}s" >>"$LOGS/kill-times.txt"

  # Run B: the whole unit dies; systemd restarts it.
  local restarts
  restarts=$(dx kill systemctl show -p NRestarts --value ubicloud-respirate)
  # systemd 255 in this container kills the unit but still exits 1 with
  # "Failed to send signal SIGKILL to auxiliary processes: Invalid
  # argument", so success is judged by NRestarts and the new MainPID.
  dx kill systemctl kill -s KILL ubicloud-respirate 2>>"$LOGS/harness.log" || true
  t=$(wait_for 5 main_changed kill "$main") || fail "kill B: no new MainPID within 5 s"
  [[ $(dx kill systemctl show -p NRestarts --value ubicloud-respirate) == $((restarts + 1)) ]] ||
    fail "kill B: systemd did not count one restart"
  say "kill B: new MainPID after ${t}s"
  echo "kill B (unit SIGKILL): new MainPID after ${t}s" >>"$LOGS/kill-times.txt"
  poke_strand kill
  t=$(wait_for 150 strand_ran kill) || fail "kill B: no strand ran within 150 s"
  say "kill B: strand ran after ${t}s"
  echo "kill B: probe strand ran after ${t}s" >>"$LOGS/kill-times.txt"
  assert_active kill
  journal_clean kill "$since"
  say "kill: ok"
}

sc_restart() {
  local before after t since child result
  boot_cp restart
  since=$(dx restart date '+%F %T')

  # The whole target, with a respirate child running.
  before="$(main_pid restart ubicloud-web) $(main_pid restart ubicloud-respirate)"
  t=$(timed dx restart systemctl restart ubicloud.target) || fail "restart: target restart failed"
  after="$(main_pid restart ubicloud-web) $(main_pid restart ubicloud-respirate)"
  [[ $before != "$after" ]] || fail "restart: MainPIDs unchanged"
  say "restart: ubicloud.target restarted in ${t}s"
  echo "restart ubicloud.target: ${t}s" >>"$LOGS/kill-times.txt"
  wait_for 180 web_up restart >/dev/null || fail "restart: web down after restart"
  poke_strand restart
  wait_for 60 strand_ran restart >/dev/null || fail "restart: no strand after restart"

  # TERM while a child runs: respirate shuts down gracefully, no SIGKILL.
  t=$(timed dx restart systemctl stop ubicloud-respirate) || fail "restart: stop with a child failed"
  result=$(dx restart systemctl show -p Result --value ubicloud-respirate)
  [[ $result == success ]] || fail "restart: stop with a child ended with Result=$result"
  say "restart: stop with a running child took ${t}s (Result=$result)"
  dx restart systemctl start ubicloud-respirate

  # TERM while restarter sleeps between children.
  wait_for 30 has_child restart >/dev/null || fail "restart: no respirate child"
  child=$(child_pid restart)
  dx restart kill -9 "$child"
  sleep 0.3
  [[ -z $(child_pid restart) ]] || fail "restart: restarter respawned before the stop"
  t=$(timed dx restart systemctl stop ubicloud-respirate) || fail "restart: stop during the pause failed"
  awk -v t="$t" 'BEGIN { exit !(t < 15) }' || fail "restart: stop during the pause took ${t}s"
  result=$(dx restart systemctl show -p Result --value ubicloud-respirate)
  [[ $result == success ]] || fail "restart: stop during the pause ended with Result=$result"
  [[ -z $(dx restart pgrep -f 'bin/respirate' || true) ]] || fail "restart: respirate left behind"
  say "restart: stop during the restarter pause took ${t}s (Result=$result)"
  dx restart systemctl start ubicloud-respirate
  poke_strand restart
  wait_for 60 strand_ran restart >/dev/null || fail "restart: no strand after the pause stop"

  journal_clean restart "$since"

  sc_restart_backup
  sc_restart_running_strand
  sc_restart_stop_timeout
  sc_restart_saturated
  assert_active restart
  say "restart: ok"
}

# A backup that runs survives a restart and a stop of the target. A
# drop-in stands in for ubicloud-admin (WP6) with a sleep.
sc_restart_backup() {
  local inv
  dx restart bash -c 'mkdir -p /run/systemd/system/ubicloud-backup.service.d &&
    printf "[Unit]\nConditionFileIsExecutable=\n[Service]\nExecStart=\nExecStart=/bin/sleep 300\n" \
      >/run/systemd/system/ubicloud-backup.service.d/harness.conf && systemctl daemon-reload'
  dx restart systemctl start --no-block ubicloud-backup.service
  wait_for 10 backup_active restart >/dev/null || fail "restart: the stand-in backup did not start"
  inv=$(dx restart systemctl show -p InvocationID --value ubicloud-backup.service)
  dx restart systemctl restart ubicloud.target
  backup_active restart || fail "restart: a target restart stopped the running backup"
  [[ $(dx restart systemctl show -p InvocationID --value ubicloud-backup.service) == "$inv" ]] ||
    fail "restart: a target restart started the backup over"
  dx restart systemctl stop ubicloud.target
  backup_active restart || fail "restart: a target stop stopped the running backup"
  [[ $(dx restart systemctl is-active ubicloud-backup.timer || true) == inactive ]] ||
    fail "restart: a target stop left the backup timer running"
  dx restart systemctl start ubicloud.target
  # systemctl warns that the timer can trigger the service again.
  dx restart systemctl stop ubicloud-backup.service 2>/dev/null
  dx restart bash -c 'rm -r /run/systemd/system/ubicloud-backup.service.d && systemctl daemon-reload'
  wait_for 120 web_up restart >/dev/null || fail "restart: web down after the backup checks"
  say "restart: a running backup survived a target restart and stop; the stop paused the timer"
}
# A oneshot service is "activating" while its ExecStart runs.
backup_active() { [[ $(dx "$1" systemctl is-active ubicloud-backup.service) == activating ]]; }

# field N "SECONDS RESULT STATUS": one field of stop_respirate's output.
field() { cut -d' ' -f"$1" <<<"$2"; }

# TERM while one strand is running, here blocked in a query on the
# vm_host lock. respirate stops scanning, gives running strands 2 s and
# then exits, but Ruby cannot end a thread that waits in a database
# query, so the exit waits for that query. The lock is released 8 s into
# the stop: the stop must end soon after, without a SIGKILL.
sc_restart_running_strand() {
  local r t out
  hold_vm_host_lock restart 600
  poke_strand restart
  wait_for 30 blocked_at_least restart 1 >/dev/null || fail "restart: no strand blocked on the lock"
  out=$(mktemp)
  stop_respirate restart "running strand" >"$out" &
  sleep 8
  [[ $(dx restart systemctl is-active ubicloud-respirate || true) == deactivating ]] ||
    fail "restart: respirate stopped while its strand was still in a query"
  release_vm_host_lock restart
  wait $! || fail "restart: stop with a running strand failed"
  r=$(cat "$out")
  rm -f "$out"
  say "restart: stop with a running strand, lock released after 8 s: ${r%% *}s, Result=$(field 2 "$r"), status $(field 3 "$r")"
  echo "stop with one running strand, lock released after 8 s: $r (seconds Result status)" >>"$LOGS/kill-times.txt"
  [[ $(field 2 "$r") != timeout ]] || fail "restart: stop with a running strand hit TimeoutStopSec"
  awk -v t="${r%% *}" 'BEGIN { exit !(t < 20) }' || fail "restart: stop with a running strand took ${r%% *}s"
  dx restart systemctl reset-failed ubicloud-respirate
  dx restart systemctl start ubicloud-respirate
  t=$(wait_for 150 strand_ran restart) || fail "restart: the interrupted strand did not run again within 150 s"
  say "restart: the interrupted strand ran again ${t}s after the restart"
  echo "interrupted strand (lock released) ran again ${t}s after respirate restarted" >>"$LOGS/kill-times.txt"
}

# A strand whose query outlasts TimeoutStopSec: systemd SIGKILLs
# respirate, and the strand runs again only once its 120 s lease has
# expired. A drop-in shortens TimeoutStopSec to 10 s for this case.
sc_restart_stop_timeout() {
  local r t
  dx restart bash -c 'mkdir -p /run/systemd/system/ubicloud-respirate.service.d &&
    printf "[Service]\nTimeoutStopSec=10\n" >/run/systemd/system/ubicloud-respirate.service.d/harness.conf &&
    systemctl daemon-reload'
  hold_vm_host_lock restart 600
  poke_strand restart
  wait_for 30 blocked_at_least restart 1 >/dev/null || fail "restart: no strand blocked on the lock"
  r=$(stop_respirate restart "stop timeout")
  release_vm_host_lock restart
  dx restart bash -c 'rm -r /run/systemd/system/ubicloud-respirate.service.d && systemctl daemon-reload'
  say "restart: stop with a strand in a query past TimeoutStopSec=10: ${r%% *}s, Result=$(field 2 "$r")"
  echo "stop with a strand in a query past TimeoutStopSec=10: $r (seconds Result status)" >>"$LOGS/kill-times.txt"
  [[ $(field 2 "$r") == timeout ]] || fail "restart: expected a stop timeout, got $r"
  dx restart systemctl reset-failed ubicloud-respirate
  dx restart systemctl start ubicloud-respirate
  t=$(wait_for 150 strand_ran restart) || fail "restart: the killed strand did not run again within 150 s"
  say "restart: the strand of the killed respirate ran again ${t}s after the restart (lease)"
  echo "strand of a SIGKILLed respirate ran again ${t}s after respirate restarted" >>"$LOGS/kill-times.txt"
}
# TERM while every dispatcher thread runs a strand and the strand queue is
# full: the scan thread blocks pushing to the queue, so respirate cannot
# begin its shutdown, and apoptosis (91 s after the first of those
# strands started) ends it with exit status 2. TimeoutStopSec=100 covers
# that, so the stop ends without a SIGKILL.
sc_restart_saturated() {
  local r t
  hold_vm_host_lock restart 600
  psql_q restart "INSERT INTO strand (id, prog, label, stack, schedule)
    SELECT gen_random_uuid(), 'LogVmHostUtilizations', 'wait', '[{\"harness\": 1}]', now() FROM generate_series(1, 60)" >/dev/null
  wait_for 30 blocked_at_least restart 1 >/dev/null || fail "restart: the strands did not block on the lock"
  sleep 5
  r=$(stop_respirate restart "saturated")
  release_vm_host_lock restart
  say "restart: stop with every thread busy: ${r%% *}s, Result=$(field 2 "$r"), status $(field 3 "$r")"
  echo "stop with every dispatcher thread busy: $r (seconds Result status)" >>"$LOGS/kill-times.txt"
  [[ $(field 2 "$r") != timeout ]] || fail "restart: the saturated stop hit TimeoutStopSec"
  [[ $(field 3 "$r") == 2 ]] || fail "restart: the saturated stop did not end by apoptosis: $r"
  awk -v t="${r%% *}" 'BEGIN { exit !(t < 100) }' || fail "restart: the saturated stop took ${r%% *}s"
  psql_q restart "DELETE FROM strand WHERE stack @> '[{\"harness\": 1}]'" >/dev/null
  dx restart systemctl reset-failed ubicloud-respirate
  dx restart systemctl start ubicloud-respirate
  poke_strand restart
  t=$(wait_for 150 strand_ran restart) || fail "restart: no strand ran within 150 s after the saturated stop"
  say "restart: strands ran again ${t}s after the restart"
}

sc_reboot() {
  local t since
  boot_cp reboot
  docker restart -t 120 ubi-m3-reboot >/dev/null
  wait_booted reboot
  since=$(dx reboot date '+%F %T')
  t=$(wait_for 180 web_up reboot) || fail "reboot: web did not come back"
  say "reboot: web answers ${t}s after boot"
  poke_strand reboot
  t=$(wait_for 150 strand_ran reboot) || fail "reboot: no strand ran after boot"
  say "reboot: strand ran ${t}s after poke"
  assert_active reboot
  [[ $(dx reboot systemctl is-active postgresql@16-main) == active ]] || fail "reboot: postgres down"
  journal_clean reboot "$since"
  say "reboot: ok (docker restart; a real VM reboot is UNVERIFIED)"
}

[[ $# -gt 0 ]] || {
  sed -n '2,15p' "$0"
  exit 2
}
for arg in "$@"; do
  case $arg in
    --prepare-image) prepare_image ;;
    --prepare-tools) prepare_tools ;;
    --prepare-release) prepare_release ;;
    all) for s in envfmt verify fresh rerun flags smoke kill restart reboot; do "sc_$s"; cleanup; done ;;
    envfmt | verify | fresh | rerun | flags | smoke | kill | restart | reboot)
      "sc_$arg"
      cleanup
      ;;
    *) fail "unknown argument $arg" ;;
  esac
done
say "logs: $LOGS"
