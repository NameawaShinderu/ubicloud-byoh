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
# Scenarios: parity envfmt verify fresh rerun flags smoke kill restart
# reboot tls-provided tunnel backup admin (or "all").
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

# login NAME [BASE [CURL_OPTION...] [-- PASSWORD]]: the two-step Rodauth
# login at BASE (default http://localhost:3000); prints the status and
# the redirect of the last step. Production cookies are Secure, and curl
# sends them to localhost over plain http. The curl options go to every
# request (such as --resolve or extra headers).
login() {
  local name=$1 base=${2:-http://localhost:3000} pass=$PASSWORD
  shift $(($# < 2 ? $# : 2))
  local -a opts=()
  while [[ $# -gt 0 ]]; do
    if [[ $1 == -- ]]; then
      pass=$2
      break
    fi
    opts+=("$1")
    shift
  done
  dx "$name" bash -s "$EMAIL" "$pass" "$base" "${opts[@]}" <<'EOF'
set -euo pipefail
email=$1 pass=$2 base=$3
shift 3
jar=$(mktemp)
csrf() { grep -o '<input name="_csrf"[^>]*>' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/'; }
tok=$(curl -sf "$@" -c "$jar" -b "$jar" "$base/login" | csrf)
tok=$(curl -sf "$@" -c "$jar" -b "$jar" --data-urlencode "_csrf=$tok" --data-urlencode "login=$email" "$base/login" | csrf)
curl -s "$@" -o /dev/null -w '%{http_code} %{redirect_url}\n' -c "$jar" -b "$jar" \
  --data-urlencode "_csrf=$tok" --data-urlencode "login=$email" --data-urlencode "password=$pass" \
  "$base/login"
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
  # The timer's service runs ubicloud-admin backup now.
  dx verify systemctl start ubicloud-backup.service || fail "verify: ubicloud-backup failed"
  [[ $(dx verify systemctl show -p Result --value ubicloud-backup.service) == success ]] ||
    fail "verify: ubicloud-backup did not succeed"
  [[ -n $(dx verify find /var/backups/ubicloud -mindepth 2 -maxdepth 2 -name manifest.json) ]] ||
    fail "verify: ubicloud-backup wrote no backup"
  say "verify: ubicloud-backup.service ran ubicloud-admin backup now"
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

  [[ $(dx fresh stat -c '%U:%G %a' /usr/local/bin/ubicloud-admin) == "root:root 755" ]] ||
    fail "fresh: /usr/local/bin/ubicloud-admin is not root 0755"
  dx fresh cmp -s /usr/local/bin/ubicloud-admin /opt/ubicloud/current/packaging/bin/ubicloud-admin ||
    fail "fresh: /usr/local/bin/ubicloud-admin is not the release's"
  printf '%s\n' "$PASSWORD" | adm fresh account create --email "$EMAIL" --password-stdin >"$LOGS/fresh-account.txt" 2>&1 ||
    fail "fresh: ubicloud-admin account create: $(cat "$LOGS/fresh-account.txt")"
  grep -q "$EMAIL" <<<"$(adm fresh account list)" || fail "fresh: ubicloud-admin account list from /"
  out=$(login fresh) || fail "fresh: login request failed"
  [[ $out == "302 http://localhost:3000/after-login" ]] || fail "fresh: login: $out"
  say "fresh: account created with ubicloud-admin from /, login ok ($out)"
  adm fresh status >"$LOGS/fresh-status.txt" 2>&1 || fail "fresh: ubicloud-admin status: $(grep '^fail' "$LOGS/fresh-status.txt")"
  say "fresh: ubicloud-admin status passes ($(tail -1 "$LOGS/fresh-status.txt"))"
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
# drop-in stands in for ubicloud-admin backup now with a sleep.
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

# --tls provided, the E0 HTTPS gate: one install.sh run on ubi-m3-tools
# with a self-signed certificate for cp.test, then HTTPS through Caddy,
# the client address through X-Real-IP, the admin API closed, a rerun
# that changes nothing, and a switch back to --tls none.
FRONT_FILES="/etc/caddy/Caddyfile /etc/ubicloud/front.conf /etc/ubicloud/tls/cert.pem /etc/ubicloud/tls/key.pem"

sc_tls_provided() {
  local out rc ip since sums pids cpid
  stage_art
  src_tarball
  start_sys tlsp ubi-m3-tools
  since=$(dx tlsp date '+%F %T')
  backup_key tlsp
  dx tlsp bash -c 'install -d -m 0700 /root/tls && cd /root/tls &&
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 -subj /CN=cp.test \
      -addext subjectAltName=DNS:cp.test -keyout key.pem -out cert.pem 2>/dev/null &&
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 -subj /CN=cp.test \
      -addext subjectAltName=DNS:cp.test -keyout other-key.pem -out other.pem 2>/dev/null &&
    chmod 600 key.pem other-key.pem'
  local -a tls=(--url https://cp.test --tls provided --cert /root/tls/cert.pem --key /root/tls/key.pem)

  # A certificate for another host, a key of another certificate, a
  # missing key, --cert with --tls none, an http URL and a URL with a
  # port: exit 2 before anything changes, without printing key material.
  local spec bad=()
  for spec in "--url https://other.test|is not valid for other.test" \
    "--key /root/tls/other-key.pem|is not the key of --cert" "--key /root/tls/missing.pem|is not a file" \
    "--tls none --url http://localhost:3000|go with --tls provided" "--url http://cp.test|needs --url https://HOST" \
    "--url https://cp.test:8443|needs --url https://HOST"; do
    read -ra bad <<<"${spec%%|*}"
    rc=0
    install_cp tlsp "${tls[@]}" "${bad[@]}" >"$LOGS/tlsp-usage.log" 2>&1 || rc=$?
    if [[ $rc != 2 ]] || ! grep -qF -- "${spec#*|}" "$LOGS/tlsp-usage.log"; then
      fail "tls-provided: ${bad[*]} exited $rc: $(cat "$LOGS/tlsp-usage.log")"
    fi
    grep -q 'PRIVATE KEY' "$LOGS/tlsp-usage.log" && fail "tls-provided: ${bad[*]} printed key material"
  done
  dx tlsp test ! -e /etc/ubicloud || fail "tls-provided: a refused run created /etc/ubicloud"
  dx tlsp test ! -e /etc/caddy || fail "tls-provided: a refused run installed caddy"
  say "tls-provided: a wrong host, a foreign key, a missing key, --cert with none, http and a port exit 2 and change nothing"

  install_cp tlsp "${tls[@]}" >"$LOGS/tlsp-install.log" 2>&1 || fail "tls-provided: install.sh failed, see $LOGS/tlsp-install.log"
  grep -E '^(ok|changed|skip|warn|notice) ' "$LOGS/tlsp-install.log" | tee -a "$LOGS/harness.log" >/dev/null
  grep -q '^changed front: installed caddy' "$LOGS/tlsp-install.log" || fail "tls-provided: caddy was not installed"
  wait_for 180 web_up tlsp >/dev/null || fail "tls-provided: web did not answer"
  assert_active tlsp
  [[ $(dx tlsp systemctl is-active caddy) == active && $(dx tlsp systemctl is-enabled caddy) == enabled ]] ||
    fail "tls-provided: caddy is not active and enabled"
  ip=$(dx tlsp hostname -I | awk '{ print $1 }')
  local -a via=(--cacert /root/tls/cert.pem --resolve "cp.test:443:$ip" --resolve "cp.test:80:$ip")

  # HTTPS with the given certificate (verified, not -k), http redirects.
  out=$(dx tlsp curl -s -o /dev/null -w '%{http_code}' "${via[@]}" https://cp.test/login) || true
  [[ $out == 200 ]] || fail "tls-provided: GET https://cp.test/login through caddy: $out"
  out=$(dx tlsp curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${via[@]}" http://cp.test/login) || true
  [[ $out == "308 https://cp.test/login" ]] || fail "tls-provided: http is not redirected: $out"
  rc=0
  dx tlsp curl -s --max-time 5 -o /dev/null http://127.0.0.1:2019/config/ || rc=$?
  [[ $rc == 7 ]] || fail "tls-provided: the caddy admin API answered or hung (curl exit $rc)"
  out=$(dx tlsp ss -Htln | awk '{ print $4 }' | sort | tr '\n' ' ')
  [[ $out != *"0.0.0.0:3000"* && $out != *"*:3000"* ]] || fail "tls-provided: puma listens on every address: $out"
  say "tls-provided: HTTPS with the given certificate, http redirects to https, admin API refused, puma local only"

  # Files and settings.
  out=$(dx tlsp stat -c '%U:%G %a %n' /etc/ubicloud/tls /etc/ubicloud/tls/cert.pem /etc/ubicloud/tls/key.pem /etc/ubicloud/front.conf | tr '\n' ' ')
  [[ $out == "root:caddy 750 /etc/ubicloud/tls root:caddy 644 /etc/ubicloud/tls/cert.pem root:caddy 640 /etc/ubicloud/tls/key.pem root:root 600 /etc/ubicloud/front.conf " ]] ||
    fail "tls-provided: tls files are $out"
  dx tlsp grep -qx "IP_FROM_HEADER='X-Real-IP'" /etc/ubicloud/env || fail "tls-provided: IP_FROM_HEADER is not X-Real-IP"
  dx tlsp grep -qx "BASE_URL='https://cp.test'" /etc/ubicloud/env || fail "tls-provided: BASE_URL is not https://cp.test"
  dx tlsp grep -qx "TLS_FRONT='provided'" /etc/ubicloud/front.conf || fail "tls-provided: front.conf"
  [[ $(dx tlsp head -1 /etc/caddy/Caddyfile) == "# Written by scripts/byoh/install.sh for --tls provided"* ]] ||
    fail "tls-provided: the Caddyfile is not install.sh's"
  dx tlsp grep -q 'admin off' /etc/caddy/Caddyfile || fail "tls-provided: the Caddyfile has no admin off"
  dx tlsp bash /art/fixture.sh as-service bin/byoh-config-check >"$LOGS/tlsp-config-check.txt" 2>&1 || true
  grep -q '^ok   client IP: from the X-Real-IP header; puma binds 127.0.0.1' "$LOGS/tlsp-config-check.txt" ||
    fail "tls-provided: byoh-config-check client IP: $(grep -i 'client IP\|IP_FROM' "$LOGS/tlsp-config-check.txt")"
  grep -q '^ok   BASE_URL https://cp.test' "$LOGS/tlsp-config-check.txt" || fail "tls-provided: byoh-config-check BASE_URL"
  grep -q '^fail' "$LOGS/tlsp-config-check.txt" && fail "tls-provided: byoh-config-check fails: $(grep '^fail' "$LOGS/tlsp-config-check.txt")"

  # Login over HTTPS, and the audit log records the client's address
  # (this container's, as caddy sees it), not caddy's 127.0.0.1 and not
  # an X-Real-IP the client sends.
  printf '%s\n' "$PASSWORD" | dx tlsp bash /art/fixture.sh account "$EMAIL" >"$LOGS/tlsp-account.txt" 2>&1 ||
    fail "tls-provided: account create: $(cat "$LOGS/tlsp-account.txt")"
  out=$(login tlsp https://cp.test "${via[@]}" -H 'X-Real-IP: 203.0.113.9') || fail "tls-provided: login request failed"
  [[ $out == "302 https://cp.test/after-login" ]] || fail "tls-provided: login over HTTPS: $out"
  out=$(login tlsp https://cp.test "${via[@]}" -- wrong-password) || true
  out=$(psql_q tlsp "SELECT string_agg(DISTINCT metadata->>'ip', ' ') FROM account_authentication_audit_log")
  [[ $out == "$ip" ]] || fail "tls-provided: the audit log has the addresses '$out', not only $ip"
  say "tls-provided: login over HTTPS ok; audit rows record $ip (not 127.0.0.1, not a client X-Real-IP)"

  # A rerun with the same arguments changes nothing.
  sums=$(settings_sums tlsp; dx tlsp bash -c "sha256sum $FRONT_FILES")
  pids=$(service_pids tlsp)
  cpid=$(main_pid tlsp caddy)
  install_cp tlsp "${tls[@]}" >"$LOGS/tlsp-rerun.log" 2>&1 || fail "tls-provided: rerun failed, see $LOGS/tlsp-rerun.log"
  grep -q '^changed ' "$LOGS/tlsp-rerun.log" && fail "tls-provided: rerun changed: $(grep '^changed ' "$LOGS/tlsp-rerun.log")"
  [[ $(settings_sums tlsp; dx tlsp bash -c "sha256sum $FRONT_FILES") == "$sums" ]] || fail "tls-provided: rerun changed a file"
  [[ $(service_pids tlsp) == "$pids" && $(main_pid tlsp caddy) == "$cpid" ]] || fail "tls-provided: rerun restarted a service"
  say "tls-provided: a rerun changes nothing and restarts nothing"

  # A reissued certificate (same key, 10 days left): the rerun warns,
  # installs it and restarts caddy for it alone, and caddy serves it.
  local serial
  serial=$(dx tlsp bash -c 'cd /root/tls && openssl req -x509 -key key.pem -days 10 -subj /CN=cp.test \
    -addext subjectAltName=DNS:cp.test -out cert.pem 2>/dev/null && openssl x509 -in cert.pem -noout -serial')
  install_cp tlsp "${tls[@]}" >"$LOGS/tlsp-rotate.log" 2>&1 || fail "tls-provided: rotation rerun failed, see $LOGS/tlsp-rotate.log"
  grep -q '^warn    front: --cert /root/tls/cert.pem expires within 30 days' "$LOGS/tlsp-rotate.log" ||
    fail "tls-provided: no warning for a certificate with 10 days left"
  out=$(grep '^changed ' "$LOGS/tlsp-rotate.log" | sed 's/ (until .*//' | tr '\n' '|')
  [[ $out == "changed front: certificate for cp.test in /etc/ubicloud/tls|changed front: restarted caddy|" ]] ||
    fail "tls-provided: the rotation changed: $out"
  [[ $(main_pid tlsp caddy) != "$cpid" ]] || fail "tls-provided: caddy was not restarted for the new certificate"
  [[ $(service_pids tlsp) == "$pids" ]] || fail "tls-provided: the rotation restarted web or respirate"
  out=$(dx tlsp bash -c "openssl s_client -connect $ip:443 -servername cp.test </dev/null 2>/dev/null | openssl x509 -noout -serial")
  [[ $out == "$serial" ]] || fail "tls-provided: caddy serves $out, not the reissued $serial"
  say "tls-provided: a reissued certificate warns at 10 days left, is installed and served, and restarts caddy only"

  # The acme Caddyfile: install.sh's own render_caddyfile with --tls
  # acme, parsed by the installed caddy. A real acme run is UNVERIFIED
  # (it needs public DNS and Let's Encrypt).
  dx tlsp bash -c "set -euo pipefail; CURRENT=/opt/ubicloud/current TLS_DIR=/etc/ubicloud/tls
    TLS=acme URL_HOST=cp.test EFFECTIVE_PORT=3000 ADMIN_EMAIL=ops@example.test
    source <(sed -n '/^render_caddyfile() {/,/^}/p' /art/install.sh)
    render_caddyfile >/root/acme.Caddyfile
    caddy adapt --adapter caddyfile --config /root/acme.Caddyfile 2>/dev/null" >"$LOGS/tlsp-acme.json" ||
    fail "tls-provided: the acme Caddyfile does not adapt: $(dx tlsp cat /root/acme.Caddyfile)"
  out=$(jq -c '[.admin.disabled, ([.. | objects | .email? // empty] | unique),
    ([.. | objects | .headers?.request? // empty | ((.set // {}) | to_entries[] | "set \(.key)=\(.value[0])"), ((.delete // [])[] | "delete \(.)")] | map(ascii_downcase))]' "$LOGS/tlsp-acme.json" 2>&1)
  [[ $out == '[true,["ops@example.test"],["set x-real-ip={http.request.remote.host}","delete cf-connecting-ip"]]' ]] ||
    fail "tls-provided: the acme config is $out"
  dx tlsp grep -q 'auto_https' /root/acme.Caddyfile && fail "tls-provided: the acme Caddyfile turns off automatic certificates"
  say "tls-provided: the acme Caddyfile adapts with admin off, the --admin-email ACME account, X-Real-IP set and CF-Connecting-IP dropped"

  # Back to --tls none: the changed keys exit 2 by name, and with
  # --update-env caddy stops and IP_FROM_HEADER goes.
  rc=0
  install_cp tlsp >"$LOGS/tlsp-none.log" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "tls-provided: switching to none without --update-env exited $rc"
  out=$(grep -o 'key [A-Z_]* differs' "$LOGS/tlsp-none.log" | sort | tr '\n' ' ')
  [[ $out == "key BASE_URL differs key IP_FROM_HEADER differs key TLS_FRONT differs " ]] ||
    fail "tls-provided: switching to none named: $out"
  grep -qx 'install.sh: key TLS_FRONT differs; the front is --tls provided; to switch it to --tls none (the old one stops once the new one runs), pass --update-env BASE_URL --update-env IP_FROM_HEADER --update-env TLS_FRONT' "$LOGS/tlsp-none.log" ||
    fail "tls-provided: the switch message: $(grep TLS_FRONT "$LOGS/tlsp-none.log")"
  grep -q "^install.sh: key IP_FROM_HEADER differs; it follows --tls" "$LOGS/tlsp-none.log" ||
    fail "tls-provided: IP_FROM_HEADER is not tied to --tls: $(grep IP_FROM_HEADER "$LOGS/tlsp-none.log")"
  install_cp tlsp --update-env BASE_URL --update-env IP_FROM_HEADER --update-env TLS_FRONT >"$LOGS/tlsp-none.log" 2>&1 ||
    fail "tls-provided: switching to none failed, see $LOGS/tlsp-none.log"
  grep -q '^changed front: stopped and disabled caddy (was --tls provided)$' "$LOGS/tlsp-none.log" ||
    fail "tls-provided: caddy was not stopped: $(grep front "$LOGS/tlsp-none.log")"
  [[ $(dx tlsp systemctl is-active caddy || true) != active ]] || fail "tls-provided: caddy still runs"
  dx tlsp grep -q '^IP_FROM_HEADER=' /etc/ubicloud/env && fail "tls-provided: IP_FROM_HEADER is still set"
  wait_for 180 web_up tlsp >/dev/null || fail "tls-provided: web down after the switch to none"
  out=$(login tlsp) || fail "tls-provided: login after the switch failed"
  [[ $out == "302 http://localhost:3000/after-login" ]] || fail "tls-provided: login after the switch: $out"
  journal_clean tlsp "$since"
  say "tls-provided: the switch to --tls none needs --update-env, stops caddy and drops IP_FROM_HEADER"
  say "tls-provided: ok"
}

# --tls tunnel. First with a cloudflared.service the machine already has
# (the live case): install.sh leaves it byte for byte and running, warns
# about a token on its command line without printing it, and sets
# IP_FROM_HEADER. Then, with that unit gone, a fresh tunnel: the pinned
# cloudflared and ubicloud-cloudflared.service with the token as a
# credential. A real tunnel is UNVERIFIED: the token is a dummy, so
# cloudflared only proves that it read it.
sc_tunnel() {
  local out rc sums pid since
  boot_cp tunnel
  since=$(dx tunnel date '+%F %T')
  src_tarball
  release_rev_to_art tunnel
  dx tunnel bash -c "cat >/etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=cloudflared (harness stand-in)
After=network-online.target

[Service]
ExecStart=/bin/bash -c 'exec sleep infinity' cloudflared --no-autoupdate tunnel run --token dummy-live-token-0123456789
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable -q --now cloudflared"
  sums=$(dx tunnel sha256sum /etc/systemd/system/cloudflared.service)
  pid=$(main_pid tunnel cloudflared)
  local -a tun=(--url https://cp.example.test --tls tunnel)
  dx tunnel bash -c 'install -d -m 0700 /root/tls && cd /root/tls &&
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 -subj /CN=cp.example.test \
      -addext subjectAltName=DNS:cp.example.test -keyout key.pem -out cert.pem 2>/dev/null && chmod 600 key.pem &&
    printf "%s\n" "eyJhIjoiaGFybmVzcy1kdW1teS10b2tlbiJ9-not-a-real-tunnel" >/root/cf.token && chmod 0600 /root/cf.token'
  local -a prov=(--url https://cp.example.test --tls provided --cert /root/tls/cert.pem --key /root/tls/key.pem)

  rc=0
  install_cp tunnel "${tun[@]}" >"$LOGS/tunnel-existing.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'key BASE_URL differs' "$LOGS/tunnel-existing.log"; then
    fail "tunnel: a new URL without --update-env exited $rc"
  fi
  grep -qx 'install.sh: key TLS_FRONT differs; the front is --tls none; to switch it to --tls tunnel (the old one stops once the new one runs), pass --update-env BASE_URL --update-env TLS_FRONT' "$LOGS/tunnel-existing.log" ||
    fail "tunnel: the front switch is not named: $(cat "$LOGS/tunnel-existing.log")"
  install_cp tunnel "${tun[@]}" --update-env BASE_URL --update-env TLS_FRONT >"$LOGS/tunnel-existing.log" 2>&1 ||
    fail "tunnel: install.sh failed, see $LOGS/tunnel-existing.log"
  grep -E '^(ok|changed|skip|warn|notice) ' "$LOGS/tunnel-existing.log" | tee -a "$LOGS/harness.log" >/dev/null
  grep -q 'dummy-live-token' "$LOGS/tunnel-existing.log" && fail "tunnel: install.sh printed the token"
  grep -q '^ok      front: cloudflared.service exists; install.sh leaves it as it is$' "$LOGS/tunnel-existing.log" ||
    fail "tunnel: no report on the existing unit"
  grep -q '^warn    front: cloudflared.service passes the tunnel token on its command line' "$LOGS/tunnel-existing.log" ||
    fail "tunnel: no warning about the token on the command line"
  grep -q '^notice  front: the tunnel.s public hostname cp.example.test must route to http://127.0.0.1:3000' "$LOGS/tunnel-existing.log" ||
    fail "tunnel: no ingress reminder"
  [[ $(dx tunnel sha256sum /etc/systemd/system/cloudflared.service) == "$sums" ]] || fail "tunnel: cloudflared.service changed"
  [[ $(main_pid tunnel cloudflared) == "$pid" ]] || fail "tunnel: cloudflared.service was restarted"
  dx tunnel test ! -e /etc/systemd/system/ubicloud-cloudflared.service || fail "tunnel: installed its own unit next to the existing one"
  dx tunnel grep -qx "IP_FROM_HEADER='CF-Connecting-IP'" /etc/ubicloud/env || fail "tunnel: IP_FROM_HEADER is not CF-Connecting-IP"
  dx tunnel grep -qx "TLS_FRONT='tunnel'" /etc/ubicloud/front.conf || fail "tunnel: front.conf"
  wait_for 180 web_up tunnel >/dev/null || fail "tunnel: web down"
  # cloudflared's header reaches the audit log: a request that carries it
  # is what the edge would send through the tunnel.
  printf '%s\n' "$PASSWORD" | dx tunnel bash /art/fixture.sh account "$EMAIL" >"$LOGS/tunnel-account.txt" 2>&1 ||
    fail "tunnel: account create: $(cat "$LOGS/tunnel-account.txt")"
  out=$(login tunnel http://localhost:3000 -H 'CF-Connecting-IP: 198.51.100.7') || fail "tunnel: login failed"
  [[ $out == "302 "*/after-login ]] || fail "tunnel: login: $out"
  out=$(psql_q tunnel "SELECT string_agg(DISTINCT metadata->>'ip', ' ') FROM account_authentication_audit_log")
  [[ $out == 198.51.100.7 ]] || fail "tunnel: the audit log has '$out', not the CF-Connecting-IP address"
  install_cp tunnel "${tun[@]}" >"$LOGS/tunnel-rerun.log" 2>&1 || fail "tunnel: rerun failed"
  grep -q '^changed ' "$LOGS/tunnel-rerun.log" && fail "tunnel: rerun changed: $(grep '^changed ' "$LOGS/tunnel-rerun.log")"
  [[ $(dx tunnel sha256sum /etc/systemd/system/cloudflared.service) == "$sums" && $(main_pid tunnel cloudflared) == "$pid" ]] ||
    fail "tunnel: the rerun touched cloudflared.service"
  say "tunnel: an existing cloudflared.service is left byte for byte and running, its argv token is warned about unprinted, IP_FROM_HEADER is CF-Connecting-IP"

  # Next to that unit, Caddy would make puma trust an X-Real-IP the
  # tunnel passes through, and a token file would never be used: both
  # exit 2 and change nothing.
  local before
  before=$(settings_sums tunnel; dx tunnel cat /etc/ubicloud/front.conf)
  rc=0
  install_cp tunnel "${prov[@]}" --update-env IP_FROM_HEADER --update-env TLS_FRONT >"$LOGS/tunnel-caddy.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'cloudflared.service is running or enabled and forwards its tunnel to puma' "$LOGS/tunnel-caddy.log"; then
    fail "tunnel: --tls provided next to a running cloudflared.service exited $rc: $(cat "$LOGS/tunnel-caddy.log")"
  fi
  rc=0
  install_cp tunnel "${tun[@]}" --cloudflared-token-file /root/cf.token >"$LOGS/tunnel-unused-token.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'so it would never use --cloudflared-token-file' "$LOGS/tunnel-unused-token.log"; then
    fail "tunnel: a token file next to cloudflared.service exited $rc: $(cat "$LOGS/tunnel-unused-token.log")"
  fi
  [[ $(settings_sums tunnel; dx tunnel cat /etc/ubicloud/front.conf) == "$before" && $(main_pid tunnel cloudflared) == "$pid" ]] ||
    fail "tunnel: a refused run changed something"
  dx tunnel test ! -e /etc/caddy || fail "tunnel: a refused run installed caddy"
  say "tunnel: Caddy next to a running cloudflared.service, and a token file it would not use, exit 2 and change nothing"

  # A stopped, disabled unit serves nothing: the run warns.
  dx tunnel systemctl disable -q --now cloudflared
  install_cp tunnel "${tun[@]}" >"$LOGS/tunnel-stopped.log" 2>&1 || fail "tunnel: rerun with a stopped unit failed"
  if ! grep -q '^warn    front: cloudflared.service is not running, so nothing serves https://cp.example.test' "$LOGS/tunnel-stopped.log" ||
    ! grep -q '^warn    front: cloudflared.service is not enabled' "$LOGS/tunnel-stopped.log"; then
    fail "tunnel: no warning for a stopped, disabled cloudflared.service: $(grep front "$LOGS/tunnel-stopped.log")"
  fi
  say "tunnel: a stopped, disabled cloudflared.service is warned about"

  # A fresh tunnel.
  dx tunnel bash -c 'systemctl disable -q --now cloudflared && rm /etc/systemd/system/cloudflared.service && systemctl daemon-reload'
  rc=0
  install_cp tunnel "${tun[@]}" >"$LOGS/tunnel-notoken.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'needs --cloudflared-token-file' "$LOGS/tunnel-notoken.log"; then
    fail "tunnel: no token and no unit exited $rc"
  fi
  dx tunnel chmod 0644 /root/cf.token
  rc=0
  install_cp tunnel "${tun[@]}" --cloudflared-token-file /root/cf.token >"$LOGS/tunnel-fresh.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'chmod 600' "$LOGS/tunnel-fresh.log"; then
    fail "tunnel: a 0644 token file exited $rc"
  fi
  dx tunnel chmod 0600 /root/cf.token
  install_cp tunnel "${tun[@]}" --cloudflared-token-file /root/cf.token >"$LOGS/tunnel-fresh.log" 2>&1 ||
    fail "tunnel: fresh tunnel install failed, see $LOGS/tunnel-fresh.log"
  grep -E '^(ok|changed|skip|warn|notice) ' "$LOGS/tunnel-fresh.log" | tee -a "$LOGS/harness.log" >/dev/null
  grep -q 'harness-dummy' "$LOGS/tunnel-fresh.log" && fail "tunnel: install.sh printed the token"
  grep -q '^changed front: installed cloudflared 2026.9.3$' "$LOGS/tunnel-fresh.log" || fail "tunnel: cloudflared was not installed"
  out=$(dx tunnel stat -c '%U:%G %a' /etc/ubicloud/cloudflared.token)
  [[ $out == "root:root 600" ]] || fail "tunnel: the token copy is $out"
  [[ $(dx tunnel systemctl is-enabled ubicloud-cloudflared) == enabled ]] || fail "tunnel: ubicloud-cloudflared is not enabled"
  dx tunnel systemd-analyze verify /etc/systemd/system/ubicloud-cloudflared.service >"$LOGS/tunnel-verify.log" 2>&1 ||
    fail "tunnel: systemd-analyze verify: $(cat "$LOGS/tunnel-verify.log")"
  # The dummy token reached cloudflared through the credential, never argv.
  wait_for 30 dx tunnel bash -c 'journalctl -u ubicloud-cloudflared --no-pager -o cat | grep -qi "token"' >/dev/null ||
    fail "tunnel: cloudflared logged nothing about the token"
  dx tunnel journalctl -u ubicloud-cloudflared --no-pager -o cat >"$LOGS/tunnel-cloudflared.log" 2>&1 || true
  grep -qiE 'no such file|permission denied|failed to read' "$LOGS/tunnel-cloudflared.log" &&
    fail "tunnel: cloudflared could not read the token file: $(grep -iE 'no such file|permission denied|failed to read' "$LOGS/tunnel-cloudflared.log" | head -3)"
  [[ $(dx tunnel ps -eo args) != *harness-dummy* ]] || fail "tunnel: the token is on a command line"
  [[ $(dx tunnel systemctl show -p ExecStart --value ubicloud-cloudflared) != *harness-dummy* ]] || fail "tunnel: the token is in the unit"
  say "tunnel: fresh: cloudflared $(dx tunnel cloudflared --version | awk '{ print $3 }') and ubicloud-cloudflared with the token as a credential; cloudflared says: $(grep -i token "$LOGS/tunnel-cloudflared.log" | tail -1 | cut -c1-160)"

  # Reruns over ubicloud-cloudflared, with and without the token file,
  # change no file. The dummy token keeps the unit from staying active,
  # so each rerun starts it again; that start is the only change.
  sums=$(settings_sums tunnel; dx tunnel cat /etc/ubicloud/cloudflared.token /etc/ubicloud/front.conf)
  local args
  for args in "--cloudflared-token-file /root/cf.token" ""; do
    local -a extra=()
    read -ra extra <<<"$args"
    install_cp tunnel "${tun[@]}" "${extra[@]}" >"$LOGS/tunnel-fresh-rerun.log" 2>&1 ||
      fail "tunnel: rerun '$args' failed, see $LOGS/tunnel-fresh-rerun.log"
    out=$(grep '^changed ' "$LOGS/tunnel-fresh-rerun.log" | grep -vx 'changed front: started ubicloud-cloudflared.service' || true)
    [[ -z $out ]] || fail "tunnel: rerun '$args' changed: $out"
    [[ $(settings_sums tunnel; dx tunnel cat /etc/ubicloud/cloudflared.token /etc/ubicloud/front.conf) == "$sums" ]] ||
      fail "tunnel: rerun '$args' changed a file"
  done
  say "tunnel: reruns over ubicloud-cloudflared, with and without the token file, change no file (the dummy token makes each start it again)"

  # A switch to Caddy where no caddy package is available exits 2
  # before anything changes, and the tunnel keeps running.
  dx tunnel bash -c 'printf "Package: caddy\nPin: release *\nPin-Priority: -1\n" >/etc/apt/preferences.d/ubi-m3-no-caddy'
  before=$(settings_sums tunnel; dx tunnel cat /etc/ubicloud/front.conf)
  rc=0
  install_cp tunnel "${prov[@]}" --update-env IP_FROM_HEADER --update-env TLS_FRONT >"$LOGS/tunnel-nocaddy.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'no caddy package is available for --tls provided' "$LOGS/tunnel-nocaddy.log"; then
    fail "tunnel: a switch to caddy without a caddy package exited $rc: $(tail -5 "$LOGS/tunnel-nocaddy.log")"
  fi
  [[ $(settings_sums tunnel; dx tunnel cat /etc/ubicloud/front.conf) == "$before" ]] || fail "tunnel: the refused caddy switch changed a file"
  [[ $(dx tunnel systemctl is-enabled ubicloud-cloudflared) == enabled && $(dx tunnel systemctl is-active ubicloud-cloudflared || true) != inactive ]] ||
    fail "tunnel: the refused caddy switch stopped ubicloud-cloudflared"
  dx tunnel rm /etc/apt/preferences.d/ubi-m3-no-caddy
  say "tunnel: a switch to Caddy with no caddy package exits 2 and leaves the tunnel running"

  # --no-start leaves the tunnel running and front.conf as it is; the
  # real switch then needs only --update-env TLS_FRONT, and stops it.
  install_cp tunnel --no-start --update-env BASE_URL --update-env IP_FROM_HEADER --update-env TLS_FRONT >"$LOGS/tunnel-nostart.log" 2>&1 ||
    fail "tunnel: --no-start switch failed, see $LOGS/tunnel-nostart.log"
  grep -q '^skip    front: --tls none not set up and --tls tunnel left as it is (--no-start)' "$LOGS/tunnel-nostart.log" ||
    fail "tunnel: --no-start: $(grep front "$LOGS/tunnel-nostart.log")"
  [[ $(dx tunnel systemctl is-enabled ubicloud-cloudflared) == enabled && $(dx tunnel systemctl is-active ubicloud-cloudflared || true) != inactive ]] ||
    fail "tunnel: --no-start stopped ubicloud-cloudflared"
  dx tunnel grep -qx "TLS_FRONT='tunnel'" /etc/ubicloud/front.conf || fail "tunnel: --no-start recorded the new front"
  rc=0
  install_cp tunnel >"$LOGS/tunnel-none.log" 2>&1 || rc=$?
  out=$(grep '^install.sh: key' "$LOGS/tunnel-none.log" || true)
  [[ $rc == 2 && $out == "install.sh: key TLS_FRONT differs; the front is --tls tunnel; to switch it to --tls none (the old one stops once the new one runs), pass --update-env TLS_FRONT" ]] ||
    fail "tunnel: the switch to none after --no-start exited $rc: $out"
  install_cp tunnel --update-env TLS_FRONT >"$LOGS/tunnel-none.log" 2>&1 || fail "tunnel: the switch to none failed, see $LOGS/tunnel-none.log"
  grep -q '^changed front: stopped and disabled ubicloud-cloudflared.service (was --tls tunnel); /etc/ubicloud/cloudflared.token is kept$' "$LOGS/tunnel-none.log" ||
    fail "tunnel: ubicloud-cloudflared was not stopped: $(grep front "$LOGS/tunnel-none.log")"
  [[ $(dx tunnel systemctl is-enabled ubicloud-cloudflared || true) == disabled && $(dx tunnel systemctl is-active ubicloud-cloudflared || true) != active ]] ||
    fail "tunnel: ubicloud-cloudflared still enabled or active"
  dx tunnel test -s /etc/ubicloud/cloudflared.token || fail "tunnel: the token copy is gone"
  dx tunnel grep -qx "TLS_FRONT='none'" /etc/ubicloud/front.conf || fail "tunnel: front.conf after the switch"
  dx tunnel grep -q '^IP_FROM_HEADER=' /etc/ubicloud/env && fail "tunnel: IP_FROM_HEADER is still set"
  wait_for 180 web_up tunnel >/dev/null || fail "tunnel: web down after the switch to none"
  say "tunnel: --no-start leaves the tunnel up; the switch to none then needs --update-env TLS_FRONT only, stops ubicloud-cloudflared and keeps the token"
  journal_clean tunnel "$since"
  say "tunnel: ok (a real tunnel is UNVERIFIED)"
}

# --- ubicloud-admin (WP6) -----------------------------------------------------------

# adm NAME ARGS...: ubicloud-admin ARGS as root in ubi-m3-NAME, from /.
adm() {
  local name=ubi-m3-$1
  shift
  docker exec -i -w / "$name" ubicloud-admin "$@"
}

# adm_rc NAME ARGS...: prints ubicloud-admin's exit status; its output
# goes to $LOGS/adm.log.
adm_rc() {
  local rc=0
  {
    echo "### ubicloud-admin ${*:2}"
    adm "$@" 2>&1 || rc=$?
  } </dev/null >>"$LOGS/adm.log"
  echo "$rc"
}

# The database names of the container's postgres, one line.
db_names() { dx "$1" runuser -u postgres -- psql -XtAc "SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database WHERE datname LIKE 'ubicloud%'"; }

# A plain sshd on ubi-test-net, so a Sshable proves that the column key
# of a restored env file decrypts the restored private key.
start_sshd() {
  docker run -d --name ubi-m3-sshd --network "$NET" ubuntu:24.04 sleep infinity >/dev/null
  echo ubi-m3-sshd >>"$STATE/created"
  docker exec ubi-m3-sshd bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server >/dev/null &&
    mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh' || fail "sshd: openssh-server did not install"
  docker exec -d ubi-m3-sshd /usr/sbin/sshd -D
  SSHD_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" ubi-m3-sshd)
}

# The first connect also prints a "host keys added" log line.
sshable_ok() { grep -qx ok <<<"$(adm "$1" console -e 'puts Sshable.first.cmd("echo ok")' 2>/dev/null)"; }

# install.sh's and ubicloud-admin's copies of the env file format must
# not drift apart.
sc_parity() {
  local f a b
  a=$(sed -n '/^kv_read() {/,/^}/p' "$WT/scripts/byoh/install.sh")
  b=$(sed -n '/^kv_read() {/,/^}/p' "$WT/packaging/bin/ubicloud-admin")
  [[ -n $a && $a == "$b" ]] || fail "parity: kv_read differs between install.sh and ubicloud-admin"
  for f in "valid_value() " "readonly KEY_RE=" "readonly DENIED_KEY_RE=" "readonly LOCK="; do
    a=$(grep "^$f" "$WT/scripts/byoh/install.sh")
    b=$(grep "^$f" "$WT/packaging/bin/ubicloud-admin")
    [[ -n $a && $a == "$b" ]] || fail "parity: $f differs between install.sh and ubicloud-admin"
  done
  say "parity: kv_read, valid_value, KEY_RE, DENIED_KEY_RE and LOCK match"
}

sc_backup() {
  local out ts ts2 smp env_sum since dir f
  boot_cp backup
  since=$(dx backup date '+%F %T')
  start_sshd
  out=$(adm backup console -e "k = SshKey.generate; Sshable.create(host: '$SSHD_IP', unix_user: 'root', raw_private_key_1: k.keypair); puts k.public_key" 2>/dev/null) ||
    fail "backup: console -e could not create a Sshable"
  printf '%s\n' "$out" | docker exec -i ubi-m3-sshd tee -a /root/.ssh/authorized_keys >/dev/null
  wait_for 30 sshable_ok backup >/dev/null || fail "backup: Sshable#cmd fails before the backup"
  printf '%s\n' "$PASSWORD" | adm backup account create --email "$EMAIL" --password-stdin >"$LOGS/backup-account.txt" 2>&1 ||
    fail "backup: account create: $(cat "$LOGS/backup-account.txt")"
  [[ $(login backup) == "302 http://localhost:3000/after-login" ]] || fail "backup: login before the backup"
  say "backup: Sshable#cmd ok, account created, login ok"

  # backup now
  out=$(adm backup backup now 2>&1) || fail "backup: backup now: $out"
  ts=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  dir=/var/backups/ubicloud/$ts
  [[ $(dx backup stat -c '%U %a' "$dir") == "root 700" ]] || fail "backup: $dir is not root 0700"
  out=$(dx backup find "$dir" /var/backups/ubicloud/secrets -type f ! -perm 0600)
  [[ -z $out ]] || fail "backup: not 0600: $out"
  for f in db.dump globals.sql billing-rates.tar manifest.json; do dx backup test -s "$dir/$f" || fail "backup: no $f"; done
  dx backup test -s "/var/backups/ubicloud/secrets/$ts.age" || fail "backup: no secrets/$ts.age"
  dx backup grep -q CLOVER_COLUMN_ENCRYPTION_KEY "/var/backups/ubicloud/secrets/$ts.age" && fail "backup: the secrets file is not encrypted"
  grep -qx 'etc/ubicloud/env' <<<"$(dx backup age -d -i /root/backup-key "/var/backups/ubicloud/secrets/$ts.age" | tar -tf -)" ||
    fail "backup: the secrets do not hold etc/ubicloud/env"
  [[ $(dx backup jq -r '.files["db.dump"]' "$dir/manifest.json") == "$(dx backup sha256sum "$dir/db.dump" | cut -d' ' -f1)" ]] ||
    fail "backup: the manifest's sha256 of db.dump is wrong"
  grep -qE "^$ts +[^ ]+ +yes +t1 " <<<"$(adm backup backup list)" || fail "backup: backup list: $(adm backup backup list)"
  smp=$(psql_q backup "SELECT string_agg(filename, ',' ORDER BY filename) FROM schema_migrations_password")
  env_sum=$(dx backup sha256sum /etc/ubicloud/env)
  say "backup: $ts: files 0600 in a 0700 directory, manifest sha256 ok, secrets encrypted"

  # A changed dump is refused before anything changes.
  dx backup cp -p "$dir/db.dump" /root/db.dump.good
  printf 'x' | dx backup tee -a "$dir/db.dump" >/dev/null
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key) == 2 ]] || fail "backup: a changed db.dump was not refused with exit 2"
  dx backup cp -p /root/db.dump.good "$dir/db.dump"
  # A dump that matches a rewritten manifest but is no dump.
  dx backup cp -a "$dir" /var/backups/ubicloud/20200101T000000Z
  dx backup cp -p "/var/backups/ubicloud/secrets/$ts.age" /var/backups/ubicloud/secrets/20200101T000000Z.age
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx backup bash -c 'd=/var/backups/ubicloud/20200101T000000Z; head -c 4096 /dev/urandom >$d/db.dump &&
    jq --arg s "$(sha256sum $d/db.dump | cut -d" " -f1)" ".files[\"db.dump\"] = \$s" $d/manifest.json >$d/m && mv $d/m $d/manifest.json'
  [[ $(adm_rc backup restore 20200101T000000Z --key-file /root/backup-key) == 2 ]] || fail "backup: a dump pg_restore cannot list was not refused with exit 2"
  grep -q 'pg_restore --list cannot read' "$LOGS/adm.log" || fail "backup: no pg_restore --list message"
  # A key that is no recipient's.
  dx backup age-keygen -o /root/other-key 2>/dev/null
  [[ $(adm_rc backup restore "$ts" --key-file /root/other-key) == 2 ]] || fail "backup: a wrong --key-file was not refused with exit 2"
  [[ $(db_names backup) == ubicloud ]] || fail "backup: a refused restore left databases: $(db_names backup)"
  [[ $(login backup) == "302 http://localhost:3000/after-login" ]] || fail "backup: login after the refused restores"
  say "backup: a changed dump, an unreadable dump and a wrong key are refused (exit 2); the live database serves logins"

  # Another column key in the env file needs --force.
  dx backup cp -p /etc/ubicloud/env /root/env.good
  dx backup sed -i "s|^CLOVER_COLUMN_ENCRYPTION_KEY=.*|CLOVER_COLUMN_ENCRYPTION_KEY='$(head -c 32 /dev/urandom | base64 -w0)'|" /etc/ubicloud/env
  out=$(dx backup sha256sum /etc/ubicloud/env)
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key) == 2 ]] || fail "backup: another column key was not refused"
  [[ $(adm_rc backup restore "$ts" --db-only) == 2 ]] || fail "backup: --db-only with another column key was not refused"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$out" ]] || fail "backup: a refused restore changed the env file"
  dx backup cp -p /root/env.good /etc/ubicloud/env
  [[ $(db_names backup) == ubicloud ]] || fail "backup: a refused restore left databases: $(db_names backup)"
  say "backup: another column key is refused without --force, also with --db-only"

  # A restore whose migrations fail puts the old database back.
  printf '%s\n' "$PASSWORD" | adm backup account create --email after@example.test --password-stdin >/dev/null 2>&1 ||
    fail "backup: account create after@"
  dx backup bash -c 'printf "# frozen_string_literal: true\n\nSequel.migration { up { raise \"harness: failing migration\" } }\n" >/opt/ubicloud/current/migrate/20991231_harness_fail.rb'
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key) == 1 ]] || fail "backup: a restore with a failing migration did not exit 1"
  dx backup rm -f /opt/ubicloud/current/migrate/20991231_harness_fail.rb
  grep -q 'database ubicloud and /etc/ubicloud/env are as before' "$LOGS/adm.log" || fail "backup: no rollback message"
  grep -q after@example.test <<<"$(adm backup account list)" || fail "backup: the rollback did not bring the old database back"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: the rollback changed the env file"
  wait_for 120 web_up backup >/dev/null || fail "backup: web down after the rollback"
  assert_active backup
  [[ $(db_names backup) =~ ^ubicloud\ ubicloud_failed_[0-9]{14}$ ]] || fail "backup: databases after the rollback: $(db_names backup)"
  dx backup runuser -u postgres -- dropdb "$(db_names backup | cut -d' ' -f2)"
  say "backup: a failing migration rolls the restore back: old database and env file, services running"

  # A restore over the live database keeps it as ubicloud_prev_*.
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key) == 0 ]] || fail "backup: restore over the live database failed"
  grep -q after@example.test <<<"$(adm backup account list)" && fail "backup: the restore kept an account made after the backup"
  [[ $(db_names backup) =~ ^ubicloud\ ubicloud_prev_[0-9]{14}$ ]] || fail "backup: databases after the restore: $(db_names backup)"
  [[ $(adm_rc backup status) == 0 ]] || fail "backup: status after the restore"
  [[ $(login backup) == "302 http://localhost:3000/after-login" ]] || fail "backup: login after the restore"
  say "backup: a restore over the live database ran; the old one is $(db_names backup | cut -d' ' -f2); status ok"

  # The disaster: no database, no env file.
  dx backup systemctl stop ubicloud.target
  dx backup runuser -u postgres -- dropdb ubicloud
  dx backup rm /etc/ubicloud/env
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key) == 0 ]] || fail "backup: the restore without database and env file failed"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: the restored env file differs"
  [[ $(dx backup stat -c '%U:%G %a' /etc/ubicloud/env) == "root:root 600" ]] || fail "backup: the restored env file is not root 0600"
  wait_for 30 sshable_ok backup >/dev/null || fail "backup: Sshable#cmd fails after the restore"
  [[ $(login backup) == "302 http://localhost:3000/after-login" ]] || fail "backup: login after the disaster restore"
  [[ $(psql_q backup "SELECT string_agg(filename, ',' ORDER BY filename) FROM schema_migrations_password") == "$smp" ]] ||
    fail "backup: schema_migrations_password changed"
  [[ $(psql_q backup "SELECT nspowner::regrole FROM pg_namespace WHERE nspname = 'public'") == ubicloud ]] || fail "backup: public is not owned by ubicloud"
  [[ $(adm_rc backup status) == 0 ]] || fail "backup: status after the disaster restore: $(tail -30 "$LOGS/adm.log")"
  say "backup: restore without database and env file: env identical, Sshable#cmd ok, login ok, password migrations unchanged, public owned by ubicloud, status ok"

  # prune keeps the newest and never touches other directories.
  out=$(adm backup backup now 2>&1) || fail "backup: second backup now: $out"
  ts2=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  dx backup mkdir /var/backups/ubicloud/pre-migration-harness
  [[ $(adm_rc backup backup prune --keep 1) == 0 ]] || fail "backup: prune failed"
  out=$(dx backup ls /var/backups/ubicloud /var/backups/ubicloud/secrets | tr '\n' ' ')
  [[ $out == *"$ts2 "* && $out == *"$ts2.age"* && $out == *pre-migration-harness* && $out != *"$ts "* && $out != *"$ts.age"* && $out != *20200101T000000Z* ]] ||
    fail "backup: after prune --keep 1: $out"
  [[ $(adm_rc backup backup prune --keep 0) == 2 ]] || fail "backup: prune --keep 0 was not refused"
  say "backup: prune --keep 1 kept $ts2 and its secrets, and pre-migration-harness"

  # A backup started while a restore runs waits for the restore's lock.
  docker exec -d ubi-m3-backup bash -c "ubicloud-admin restore $ts2 --key-file /root/backup-key >/root/restore.log 2>&1; echo \$? >/root/restore.rc; date +%s.%N >/root/restore.done"
  wait_for 30 dx backup bash -c '! flock -n /run/ubicloud-admin.lock true' >/dev/null || fail "backup: the restore never took the lock"
  out=$(adm backup backup now 2>&1) || fail "backup: backup now during a restore: $out"
  [[ $out == *"waiting for /run/ubicloud-admin.lock"* ]] || fail "backup: backup now did not wait for the lock: $out"
  dx backup test -e /root/restore.done || fail "backup: backup now finished before the restore"
  [[ $(dx backup cat /root/restore.rc) == 0 ]] || fail "backup: the concurrent restore failed: $(dx backup cat /root/restore.log)"
  say "backup: backup now during a restore waited for its lock and ran after it"

  # The timer's service runs the same command.
  dx backup systemctl start ubicloud-backup.service || fail "backup: ubicloud-backup.service failed"
  [[ $(dx backup systemctl show -p Result --value ubicloud-backup.service) == success ]] || fail "backup: ubicloud-backup.service result"
  grep -q '^ok      backup: /var/backups/ubicloud/' <<<"$(dx backup journalctl -u ubicloud-backup --no-pager -o cat)" ||
    fail "backup: the service wrote no backup"
  wait_for 120 web_up backup >/dev/null || fail "backup: web down at the end"
  journal_clean backup "$since"
  say "backup: ok"
}

sc_admin() {
  local out pid since pw
  boot_cp admin
  since=$(dx admin date '+%F %T')
  [[ $(adm_rc admin --help) == 0 ]] || fail "admin: --help"
  [[ $(adm_rc admin restore --help) == 0 ]] || fail "admin: restore --help"
  [[ $(adm_rc admin bogus) == 2 ]] || fail "admin: an unknown command did not exit 2"
  [[ $(dx admin runuser -u ubicloud -- /usr/local/bin/ubicloud-admin status 2>&1 || true) == *"run ubicloud-admin as root"* ]] ||
    fail "admin: ubicloud-admin ran as a non-root user"

  # account: a password file relative to the caller's directory, which
  # ubicloud cannot read, and a generated password that is printed once.
  printf '%s\n' "$PASSWORD" | dx admin bash -c 'umask 077 && cat >/root/pw.txt'
  docker exec -i -w /root ubi-m3-admin ubicloud-admin account create --email "$EMAIL" --password-file pw.txt >/dev/null 2>&1 ||
    fail "admin: account create --password-file (relative, root 0600)"
  [[ $(login admin) == "302 http://localhost:3000/after-login" ]] || fail "admin: login"
  out=$(adm admin account create --email gen@example.test 2>&1) || fail "admin: account create with a generated password: $out"
  pw=$(sed -n 's/^Password: //p' <<<"$out")
  [[ ${#pw} -ge 16 ]] || fail "admin: account create printed no generated password"
  grep -qF -- "$pw" <<<"$(dx admin journalctl --no-pager)" && fail "admin: the generated password is in the journal"
  grep -q gen@example.test <<<"$(adm admin account list)" || fail "admin: account list from /"
  say "admin: account create (relative --password-file, generated password) and list from /"

  # env
  pid=$(main_pid admin ubicloud-web)
  out=$(printf 'ops@example.test\n' | adm admin env set MAIL_FROM 2>&1) || fail "admin: env set MAIL_FROM: $out"
  [[ $out != *ops@example.test* ]] || fail "admin: env set printed the value"
  [[ $(adm admin env get MAIL_FROM --reveal) == ops@example.test ]] || fail "admin: env get --reveal"
  [[ $(main_pid admin ubicloud-web) != "$pid" ]] || fail "admin: env set did not restart web"
  [[ $(dx admin stat -c '%U:%G %a' /etc/ubicloud/env) == "root:root 600" ]] || fail "admin: env set changed the env file's mode"
  out=$(dx admin sha256sum /etc/ubicloud/env)
  [[ $(adm_rc admin env get MAIL_FROM) == 2 ]] || fail "admin: env get without --reveal"
  for k in PATH LD_PRELOAD PRY_ALLOW_UNAUDITED CLOVER_COLUMN_ENCRYPTION_KEY GIT_REV IP_FROM_HEADER lower; do
    [[ $(printf 'v' | adm admin env set "$k" >/dev/null 2>&1; echo $?) == 2 ]] || fail "admin: env set $k was not refused"
  done
  for v in "a'b" 'a\b' $'a\nb' ''; do
    [[ $(printf '%s' "$v" | adm admin env set MAIL_FROM >/dev/null 2>&1; echo $?) == 2 ]] || fail "admin: env set took a bad value"
  done
  [[ $(printf 'a\0b' | adm admin env set MAIL_FROM >/dev/null 2>&1; echo $?) == 2 ]] || fail "admin: env set took a NUL"
  [[ $(dx admin sha256sum /etc/ubicloud/env) == "$out" ]] || fail "admin: a refused env set changed the env file"
  pid=$(main_pid admin ubicloud-web)
  printf 'x' | adm admin env set HARNESS_KEY --no-restart >/dev/null || fail "admin: env set --no-restart"
  [[ $(main_pid admin ubicloud-web) == "$pid" ]] || fail "admin: env set --no-restart restarted web"
  grep -qx HARNESS_KEY <<<"$(adm admin env keys)" || fail "admin: env keys"
  grep -q "=" <<<"$(adm admin env keys)" && fail "admin: env keys printed a value"
  adm admin env unset HARNESS_KEY >/dev/null || fail "admin: env unset"
  grep -qx HARNESS_KEY <<<"$(adm admin env keys)" && fail "admin: env unset left the key"
  wait_for 120 web_up admin >/dev/null || fail "admin: web down after env set"
  say "admin: env set/get/unset/keys, refusals change nothing, values never printed"

  # status fails on unaudited pry, a missing recipient and a trust rule.
  [[ $(adm_rc admin status) == 0 ]] || fail "admin: status on a healthy control plane"
  dx admin bash -c "echo \"PRY_ALLOW_UNAUDITED='true'\" >>/etc/ubicloud/env"
  [[ $(adm_rc admin status) == 1 ]] || fail "admin: status passed with PRY_ALLOW_UNAUDITED in the env file"
  adm admin env unset PRY_ALLOW_UNAUDITED --no-restart >/dev/null || fail "admin: env unset PRY_ALLOW_UNAUDITED"
  dx admin mv /etc/ubicloud/backup-recipients /root/recipients.saved
  [[ $(adm_rc admin status) == 1 ]] || fail "admin: status passed without a backup recipient"
  dx admin mv /root/recipients.saved /etc/ubicloud/backup-recipients
  dx admin bash -c 'echo "local all all trust" >>/etc/postgresql/16/main/pg_hba.conf && systemctl reload postgresql@16-main'
  [[ $(adm_rc admin status) == 1 ]] || fail "admin: status passed with a trust rule"
  grep -q 'use trust for database ubicloud or all' "$LOGS/adm.log" || fail "admin: no trust message"
  # shellcheck disable=SC2016 # sed's $, the last line
  dx admin bash -c 'sed -i "\$d" /etc/postgresql/16/main/pg_hba.conf && systemctl reload postgresql@16-main'
  [[ $(adm_rc admin status) == 0 ]] || fail "admin: status after the fixes"
  # The backup age: a newest backup 40 h old warns, 100 h old fails.
  out=/var/backups/ubicloud/$(dx admin date -u -d '40 hours ago' +%Y%m%dT%H%M%SZ)
  dx admin mkdir "$out"
  dx admin touch "$out/manifest.json"
  [[ $(adm_rc admin status) == 0 ]] || fail "admin: status failed on a backup 40 h old"
  grep -qE '^warn +backup: the last backup \([0-9TZ]+\) is 40 h old$' "$LOGS/adm.log" || fail "admin: no warning for a backup 40 h old"
  dx admin mv "$out" "/var/backups/ubicloud/$(dx admin date -u -d '100 hours ago' +%Y%m%dT%H%M%SZ)"
  [[ $(adm_rc admin status) == 1 ]] || fail "admin: status passed with a backup 100 h old"
  grep -qE '^fail +backup: the last backup \([0-9TZ]+\) is 100 h old' "$LOGS/adm.log" || fail "admin: no failure for a backup 100 h old"
  say "admin: status fails on PRY_ALLOW_UNAUDITED, a missing recipient, a trust rule and a backup 100 h old, passes once each is fixed, and warns at 40 h"

  # run
  [[ $(adm_rc admin run bogus) == 2 ]] || fail "admin: run bogus"
  [[ $(adm_rc admin run register-byoh-host --bmc-password x) == 2 ]] || fail "admin: --bmc-password"
  [[ $(adm_rc admin run register-byoh-host --bmc-passw=x) == 2 ]] || fail "admin: --bmc-passw="
  adm admin run byoh-location list >/dev/null || fail "admin: run byoh-location list"
  adm admin run byoh-config-check >/dev/null || fail "admin: run byoh-config-check"
  docker exec -i -w /root ubi-m3-admin ubicloud-admin run byoh-host export-audit --out audit.jsonl >/dev/null || fail "admin: export-audit --out"
  [[ $(dx admin stat -c '%U %a' /root/audit.jsonl) == "root 600" ]] || fail "admin: --out file"
  dx admin grep -q 'byoh-account create' /root/audit.jsonl || fail "admin: the audit export lacks the account rows"
  grep -q '^Password for account is: ' <<<"$(adm admin run create_prod_admin_account harness-admin 2>&1)" || fail "admin: create_prod_admin_account"
  adm admin run production_check >"$LOGS/admin-production-check.log" 2>&1 || fail "admin: production_check, see $LOGS/admin-production-check.log"
  say "admin: run refuses unknown tools and --bmc-password; tools run from /, --out is written back, production_check passes"

  # console
  out=$(adm admin console -e 'puts "harness-console-#{6 * 7}"' 2>&1) || fail "admin: console -e: $out"
  [[ $out == *harness-console-42* && $out == *"NOT audited"* ]] || fail "admin: console -e: $out"
  out=$(printf 'puts "harness-pry-#{6 * 7}"\nexit\n' | adm admin console 2>&1) || fail "admin: console: $out"
  [[ $out == *harness-pry-42* && $out == *"NOT audited"* ]] || fail "admin: console (pry): $out"
  out=$(dx admin journalctl --no-pager -t ubicloud-admin -t ubicloud-pry -o cat)
  [[ $out == *"console -e by root"* && $out == *"unaudited pry session opened"* ]] || fail "admin: console log lines: $out"
  grep -q 'harness-console' <<<"$(dx admin journalctl --no-pager)" && fail "admin: console code reached the journal"
  dx admin grep -q PRY_ALLOW_UNAUDITED /etc/ubicloud/env && fail "admin: console left PRY_ALLOW_UNAUDITED in the env file"
  say "admin: console -e and pry run unaudited with one log line each; the code stays out of the journal"

  # logs
  [[ -n $(adm admin logs web -n 5) ]] || fail "admin: logs web"
  [[ $(adm_rc admin logs bogus) == 2 ]] || fail "admin: logs bogus"
  journal_clean admin "$since"
  say "admin: ok"
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
    all) for s in parity envfmt verify fresh rerun flags smoke kill restart reboot tls_provided tunnel backup admin; do "sc_$s"; cleanup; done ;;
    parity | envfmt | verify | fresh | rerun | flags | smoke | kill | restart | reboot | tls-provided | tunnel | backup | admin)
      "sc_${arg//-/_}"
      cleanup
      ;;
    *) fail "unknown argument $arg" ;;
  esac
done
say "logs: $LOGS"
