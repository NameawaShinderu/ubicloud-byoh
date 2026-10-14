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
# reboot tls-provided tunnel backup admin devshim gate-journal migrate
# migrate-preM1 upgrade-manual (or "all").
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
  local out since t rc
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
  [[ $out == "ubicloud:falsefalsefalse ubicloud_password:falsefalsefalse ubicloud_restorer:falsefalsefalse" ]] || fail "fresh: roles are $out"
  out=$(dx fresh runuser -u postgres -- psql -XtAc "SELECT string_agg(g.rolname || ':' || a.inherit_option, ' ' ORDER BY g.rolname) FROM pg_auth_members a JOIN pg_roles g ON g.oid = a.roleid JOIN pg_roles m ON m.oid = a.member WHERE m.rolname = 'ubicloud_restorer'")
  [[ $out == "ubicloud:true ubicloud_password:true" ]] || fail "fresh: ubicloud_restorer is a member of: $out"
  out=$(dx fresh sed -n '/^# BEGIN ubicloud$/,/^# END ubicloud$/p' /etc/postgresql/16/main/pg_hba.conf)
  [[ -n $out && $out != *trust* && $out != *md5* && $out != *scram* ]] || fail "fresh: the managed hba block: $out"
  [[ $(dx fresh grep -v -e '^#' -e '^[[:space:]]*$' /etc/postgresql/16/main/pg_hba.conf | head -1) == "local ubicloud,ubicloud_restore postgres peer" ]] ||
    fail "fresh: the managed hba block is not the first rule"
  psql_as fresh ubicloud -d ubicloud || fail "fresh: ubicloud cannot log in as role ubicloud"
  psql_as fresh ubicloud-migrate -d ubicloud -U ubicloud_password || fail "fresh: ubicloud-migrate cannot log in as ubicloud_password"
  psql_as fresh ubicloud -d ubicloud -U ubicloud_password && fail "fresh: ubicloud logged in as ubicloud_password"
  psql_as fresh ubicloud -d ubicloud -h 127.0.0.1 && fail "fresh: a TCP login to ubicloud was accepted"
  psql_as fresh postgres -d ubicloud -h 127.0.0.1 && fail "fresh: a TCP login as postgres to ubicloud was accepted"
  psql_as fresh ubicloud-migrate -d ubicloud -U ubicloud_restorer && fail "fresh: ubicloud_restorer logged in to ubicloud"
  psql_as fresh ubicloud -d postgres -U ubicloud_restorer && fail "fresh: ubicloud logged in as ubicloud_restorer"
  dx fresh runuser -u postgres -- createdb -O ubicloud ubicloud_restore
  psql_as fresh ubicloud-migrate -d ubicloud_restore -U ubicloud_restorer || fail "fresh: ubicloud-migrate cannot log in to ubicloud_restore as ubicloud_restorer"
  psql_as fresh ubicloud -d ubicloud_restore -U ubicloud_restorer && fail "fresh: ubicloud logged in to ubicloud_restore as ubicloud_restorer"
  psql_as fresh ubicloud-migrate -d ubicloud_restore -U ubicloud_restorer -h 127.0.0.1 && fail "fresh: a TCP login to ubicloud_restore was accepted"
  dx fresh runuser -u postgres -- dropdb ubicloud_restore
  say "fresh: roles not superuser, peer map only, password role refused to ubicloud, the restore role only from ubicloud-migrate to ubicloud_restore, TCP refused"

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

  # Step 12 (WP7): the install ended with ubicloud-admin smoke, and in
  # production that ran bin/production_check.
  local re
  for re in '^ok      smoke: puma answers on 127\.0\.0\.1:3000 \(HTTP 200\)$' '^ok      smoke: ubicloud-web active$' \
    '^ok      smoke: ubicloud-respirate active$' '^ok      smoke: bin/byoh-config-check has no fail$' \
    '^ok      smoke: bin/production_check ' '^smoke: ok '; do
    grep -qE "$re" "$LOGS/fresh-install.log" || fail "fresh: step 12 printed no line matching $re"
  done
  say "fresh: step 12 passed: puma, web, respirate, byoh-config-check and production_check"
  # A MAIL_FROM removed by hand: byoh-config-check fails in production,
  # so smoke exits 1. (install.sh itself appends a missing key before
  # step 12, so only ubicloud-admin smoke can see the file this way.)
  dx fresh cp -p /etc/ubicloud/env /root/env.orig
  dx fresh sed -i '/^MAIL_FROM=/d' /etc/ubicloud/env
  rc=0
  adm fresh smoke >"$LOGS/fresh-smoke-mailfrom.log" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "fresh: smoke without MAIL_FROM exited $rc, not 1"
  if ! { grep -qE '^ +fail +MAIL_FROM is unset' "$LOGS/fresh-smoke-mailfrom.log" &&
    grep -q '^fail    smoke: bin/byoh-config-check reports failures' "$LOGS/fresh-smoke-mailfrom.log" &&
    grep -q '^smoke: 1 fail, .*see ubicloud-admin logs web respirate$' "$LOGS/fresh-smoke-mailfrom.log"; }; then
    fail "fresh: smoke without MAIL_FROM: $(cat "$LOGS/fresh-smoke-mailfrom.log")"
  fi
  dx fresh cp -p /root/env.orig /etc/ubicloud/env
  say "fresh: smoke fails (exit 1) on a MAIL_FROM removed from the env file in production"
  # A failing step 12 fails install.sh with the logs hint: port 8081,
  # which production_check needs, is taken.
  docker exec -d ubi-m3-fresh /opt/ubicloud/tools/bin/ruby -rsocket -e 'TCPServer.new("127.0.0.1", 8081); sleep'
  # shellcheck disable=SC2016 # expanded by the container's bash
  wait_for 20 dx fresh bash -c '[[ -n $(ss -Htln "sport = :8081") ]]' >/dev/null || fail "fresh: the stand-in listener did not start"
  rc=0
  install_cp fresh >"$LOGS/fresh-smoke-port.log" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "fresh: install.sh with port 8081 taken exited $rc, not 1"
  if ! { grep -q "^fail    smoke: port 8081 is taken" "$LOGS/fresh-smoke-port.log" &&
    grep -q '^install.sh: the install smoke test failed (above); see ubicloud-admin logs web respirate' "$LOGS/fresh-smoke-port.log"; }; then
    fail "fresh: install.sh with port 8081 taken: $(cat "$LOGS/fresh-smoke-port.log")"
  fi
  grep -q '^changed ' "$LOGS/fresh-smoke-port.log" && fail "fresh: the rerun changed: $(grep '^changed ' "$LOGS/fresh-smoke-port.log")"
  dx fresh pkill -f TCPServer
  adm fresh smoke >"$LOGS/fresh-smoke-again.log" 2>&1 || fail "fresh: smoke after the fixes: $(grep '^fail' "$LOGS/fresh-smoke-again.log")"
  say "fresh: install.sh exits 1 with the logs hint when step 12 fails (port 8081 taken), and passes again once it is free"

  # PORT 8081 is production_check's: install.sh exits 2 before changing
  # anything, env set refuses it, and smoke names it when the env file
  # was edited by hand.
  local before
  dx fresh cp -p /etc/ubicloud/env /root/env.orig
  dx fresh sed -i "s/^PORT=.*/PORT='8081'/" /etc/ubicloud/env
  before=$(settings_sums fresh)
  rc=0
  install_cp fresh >"$LOGS/fresh-port-8081.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q '^install.sh: /etc/ubicloud/env sets PORT 8081, which is reserved for the puma of bin/production_check' "$LOGS/fresh-port-8081.log"; then
    fail "fresh: install.sh with PORT 8081 exited $rc: $(tail -3 "$LOGS/fresh-port-8081.log")"
  fi
  [[ $(settings_sums fresh) == "$before" ]] || fail "fresh: the refused PORT 8081 run changed a file"
  dx fresh systemctl restart ubicloud-web
  # shellcheck disable=SC2016 # expanded by the container's bash
  wait_for 120 dx fresh bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/login) == 200 ]]' >/dev/null ||
    fail "fresh: web did not answer on 8081"
  rc=0
  adm fresh smoke >"$LOGS/fresh-smoke-8081.log" 2>&1 || rc=$?
  if [[ $rc != 1 ]] || ! grep -q '^fail    smoke: PORT is 8081, which bin/production_check needs for its own puma' "$LOGS/fresh-smoke-8081.log"; then
    fail "fresh: smoke with PORT 8081 exited $rc: $(grep smoke "$LOGS/fresh-smoke-8081.log")"
  fi
  dx fresh cp -p /root/env.orig /etc/ubicloud/env
  dx fresh systemctl restart ubicloud-web
  wait_for 120 web_up fresh >/dev/null || fail "fresh: web down after PORT 8081"
  rc=0
  printf '8081' | adm fresh env set PORT --no-restart >"$LOGS/fresh-env-8081.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -q 'PORT 8081 is reserved for the puma of bin/production_check' "$LOGS/fresh-env-8081.log"; then
    fail "fresh: env set PORT 8081 exited $rc: $(cat "$LOGS/fresh-env-8081.log")"
  fi
  dx fresh cmp -s /root/env.orig /etc/ubicloud/env || fail "fresh: env set PORT 8081 changed the env file"
  say "fresh: PORT 8081 makes install.sh exit 2 unchanged and env set refuse it, and smoke names it"

  # A production_check that fails for another reason than the port:
  # smoke prints the tail of its output and fails.
  local rel
  rel=$(dx fresh readlink -f /opt/ubicloud/current)
  dx fresh bash -c "printf '%s\n' 'puts \"harness: production_check stand-in fails\"' 'exit 1' >/root/pc-fail.rb &&
    mount --bind /root/pc-fail.rb $rel/bin/production_check"
  rc=0
  adm fresh smoke >"$LOGS/fresh-smoke-pc.log" 2>&1 || rc=$?
  dx fresh umount "$rel/bin/production_check"
  if [[ $rc != 1 ]] || ! { grep -q '^  harness: production_check stand-in fails$' "$LOGS/fresh-smoke-pc.log" &&
    grep -q '^fail    smoke: bin/production_check failed (above)$' "$LOGS/fresh-smoke-pc.log"; }; then
    fail "fresh: smoke with a failing production_check exited $rc: $(cat "$LOGS/fresh-smoke-pc.log")"
  fi
  say "fresh: a production_check that fails shows its output and fails smoke"

  # A release whose ubicloud-admin predates smoke (an upgrade from an
  # older release): step 12 warns and install.sh exits 0.
  dx fresh bash -c "sed 's/^cmd_smoke()/cmd_smoke_absent()/' $rel/packaging/bin/ubicloud-admin >/root/old-admin &&
    chmod 0755 /root/old-admin && mount --bind /root/old-admin $rel/packaging/bin/ubicloud-admin"
  rc=0
  install_cp fresh >"$LOGS/fresh-old-admin.log" 2>&1 || rc=$?
  dx fresh umount "$rel/packaging/bin/ubicloud-admin"
  if [[ $rc != 0 ]] || ! grep -q "^warn    smoke: not run; the current release's ubicloud-admin has no smoke command$" "$LOGS/fresh-old-admin.log"; then
    fail "fresh: install.sh with an ubicloud-admin without smoke exited $rc: $(grep -E 'smoke|admin' "$LOGS/fresh-old-admin.log")"
  fi
  install_cp fresh >"$LOGS/fresh-new-admin.log" 2>&1 || fail "fresh: install.sh after the old ubicloud-admin: $(tail -3 "$LOGS/fresh-new-admin.log")"
  { grep -q '^changed admin: installed /usr/local/bin/ubicloud-admin' "$LOGS/fresh-new-admin.log" && grep -q '^smoke: ok ' "$LOGS/fresh-new-admin.log"; } ||
    fail "fresh: the rerun did not put back ubicloud-admin and pass smoke: $(grep -E 'smoke|admin' "$LOGS/fresh-new-admin.log")"
  say "fresh: an ubicloud-admin without smoke makes step 12 warn and exit 0; the next run installs the new one and passes"
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
  grep -qx "install.sh: key MAIL_FROM differs; pass the same flags as before, or add --update-env MAIL_FROM to change it" "$LOGS/rerun-mailfrom.log" ||
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

  # M3-n: the state dir is root's, so a service cannot swap var/ for a
  # symlink; one that is there anyway (planted under an older layout)
  # is refused before root follows it, and an older ubicloud-owned
  # state dir is made root's.
  [[ $(dx rerun stat -c '%U:%G %a' /var/lib/ubicloud) == "root:ubicloud 750" ]] ||
    fail "rerun: /var/lib/ubicloud is $(dx rerun stat -c '%U:%G %a' /var/lib/ubicloud)"
  dx rerun runuser -u ubicloud -- ln -s /etc /var/lib/ubicloud/x 2>/dev/null && fail "rerun: ubicloud can add entries to /var/lib/ubicloud"
  dx rerun bash -c 'install -d -m 0755 /victim && mv /var/lib/ubicloud/var /var/lib/ubicloud/var.x && ln -s /victim /var/lib/ubicloud/var'
  rc=0
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-symlink.log" 2>&1 || rc=$?
  dx rerun bash -c 'rm /var/lib/ubicloud/var && mv /var/lib/ubicloud/var.x /var/lib/ubicloud/var'
  { [[ $rc == 1 ]] && grep -q 'var is a symlink or not a directory' "$LOGS/rerun-symlink.log"; } ||
    fail "rerun: a symlinked var/: exit $rc, $(tail -3 "$LOGS/rerun-symlink.log")"
  [[ $(dx rerun stat -c '%U:%G %a' /victim) == "root:root 755" ]] || fail "rerun: install.sh changed the target of a symlinked var/"
  dx rerun rmdir /victim
  dx rerun chown ubicloud:ubicloud /var/lib/ubicloud
  install_cp rerun --mail-from other@example.test >"$LOGS/rerun-state.log" 2>&1 || fail "rerun: an ubicloud-owned state dir failed the run"
  [[ $(dx rerun stat -c '%U:%G %a' /var/lib/ubicloud) == "root:ubicloud 750" ]] || fail "rerun: the ubicloud-owned state dir stayed"
  say "rerun: /var/lib/ubicloud is root:ubicloud 750; a symlinked var/ exits 1 untouched, an ubicloud-owned state dir is made root's"

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

  # A bad recipient file exits 2 before anything changes: a key with a
  # broken checksum (found by age) and a file of comments only.
  local sums pids f
  sums=$(settings_sums rerun)
  pids=$(service_pids rerun)
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx rerun bash -c 'k=$(cat /root/backup-recipient); last=${k: -1}; [[ $last == q ]] && n=p || n=q; printf "%s\n" "${k%?}$n" >/root/recip-badsum; printf "# only a comment\n\n" >/root/recip-empty'
  for f in recip-badsum recip-empty; do
    rc=0
    install_cp rerun --mail-from other@example.test --backup-recipient-file "/root/$f" --update-env BACKUP_RECIPIENTS \
      >"$LOGS/rerun-$f.log" 2>&1 || rc=$?
    [[ $rc == 2 ]] || fail "rerun: --backup-recipient-file $f exited $rc, not 2"
    grep -qE 'not a valid age recipient|holds no age public key' "$LOGS/rerun-$f.log" || fail "rerun: $f: $(tail -2 "$LOGS/rerun-$f.log")"
    grep -q '^changed ' "$LOGS/rerun-$f.log" && fail "rerun: $f changed: $(grep '^changed ' "$LOGS/rerun-$f.log")"
  done
  [[ $(settings_sums rerun) == "$sums" && $(service_pids rerun) == "$pids" ]] || fail "rerun: a refused recipient file changed a file or a service"
  say "rerun: a recipient with a bad checksum and a file of comments only exit 2 and change nothing"
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

  # An arm64 machine, faked with a dpkg that reports arm64: step 1
  # refuses it before any package is installed.
  # shellcheck disable=SC2016 # the shim's $1 and $@ expand in the container
  dx flags bash -c 'mkdir -p /root/fakearch && printf "%s\n" "#!/bin/sh" \
    "[ \"\$1\" = --print-architecture ] && { echo arm64; exit 0; }" "exec /usr/bin/dpkg \"\$@\"" \
    >/root/fakearch/dpkg && chmod 0755 /root/fakearch/dpkg'
  rc=0
  dx flags env PATH=/root/fakearch:/usr/sbin:/usr/bin:/sbin:/bin bash /art/install.sh "${INSTALL_ARGS[@]}" \
    --source-tarball /art/src.tgz --source-rev "$(cat "$ART/src.rev")" >"$LOGS/flags-arm64.log" 2>&1 || rc=$?
  if [[ $rc != 2 ]] || ! grep -qx 'install.sh: the pinned mise and cloudflared binaries are amd64 only (this machine is arm64)' "$LOGS/flags-arm64.log"; then
    fail "flags: arm64 exited $rc: $(cat "$LOGS/flags-arm64.log")"
  fi
  dx flags test ! -e /etc/ubicloud || fail "flags: the arm64 refusal created /etc/ubicloud"
  dx flags rm -r /root/fakearch
  say "flags: an arm64 machine exits 2 in step 1 and changes nothing"

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
  grep -q '^skip    smoke: not run (--no-start)' "$LOGS/flags-install.log" || fail "flags: --no-start ran step 12"
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
  if ! { grep -q '^skip    smoke: bin/production_check (RACK_ENV is development, not production)$' "$LOGS/flags-start.log" &&
    grep -q '^smoke: ok ' "$LOGS/flags-start.log"; }; then
    fail "flags: step 12 in development: $(grep smoke "$LOGS/flags-start.log")"
  fi
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
  # --no-start skips step 12, whose byoh-config-check and
  # production_check run as ubicloud and would rewrite the files first.
  install_cp smoke --no-start >"$LOGS/smoke-rerun.log" 2>&1 ||
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
  if ! { grep -qE '^ok      smoke: caddy serves https://cp\.test \(HTTP 200\)$' "$LOGS/tlsp-install.log" &&
    grep -q '^ok      smoke: bin/production_check ' "$LOGS/tlsp-install.log" && grep -q '^smoke: ok ' "$LOGS/tlsp-install.log"; }; then
    fail "tls-provided: step 12: $(grep smoke "$LOGS/tlsp-install.log")"
  fi
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

  # Step 12's front checks (ubicloud-admin smoke). acme with a host caddy
  # has no certificate for: the handshake fails (curl exit 35), which is
  # a certificate not issued yet and only warns. A stopped caddy fails
  # for acme too. A BASE_URL that is not https://HOST, and an unknown
  # front, fail.
  dx tlsp cp -p /etc/ubicloud/env /root/env.orig
  dx tlsp cp -p /etc/ubicloud/front.conf /root/front.orig
  dx tlsp sed -i "s/^TLS_FRONT=.*/TLS_FRONT='acme'/" /etc/ubicloud/front.conf
  dx tlsp sed -i "s|^BASE_URL=.*|BASE_URL='https://nocert.test'|" /etc/ubicloud/env
  rc=0
  adm tlsp smoke >"$LOGS/tlsp-smoke-acme.log" 2>&1 || rc=$?
  if [[ $rc != 0 ]] || ! { grep -q '^ok      smoke: caddy.service active$' "$LOGS/tlsp-smoke-acme.log" &&
    grep -q '^warn    smoke: caddy has no certificate for nocert.test yet (curl exit 35' "$LOGS/tlsp-smoke-acme.log"; }; then
    fail "tls-provided: smoke, acme without a certificate, exited $rc: $(grep smoke "$LOGS/tlsp-smoke-acme.log")"
  fi
  dx tlsp systemctl stop caddy
  rc=0
  adm tlsp smoke >"$LOGS/tlsp-smoke-nocaddy.log" 2>&1 || rc=$?
  dx tlsp systemctl start caddy
  if [[ $rc != 1 ]] || ! grep -q '^fail    smoke: caddy.service is inactive, so nothing serves https://nocert.test (systemctl start caddy.service; ubicloud-admin logs caddy)$' "$LOGS/tlsp-smoke-nocaddy.log"; then
    fail "tls-provided: smoke, acme with caddy stopped, exited $rc: $(grep smoke "$LOGS/tlsp-smoke-nocaddy.log")"
  fi
  dx tlsp cp -p /root/front.orig /etc/ubicloud/front.conf
  dx tlsp sed -i "s|^BASE_URL=.*|BASE_URL='http://cp.test'|" /etc/ubicloud/env
  rc=0
  adm tlsp smoke >"$LOGS/tlsp-smoke-http.log" 2>&1 || rc=$?
  if [[ $rc != 1 ]] || ! grep -q '^fail    smoke: front --tls provided, but BASE_URL is not https://HOST$' "$LOGS/tlsp-smoke-http.log"; then
    fail "tls-provided: smoke with an http BASE_URL exited $rc: $(grep smoke "$LOGS/tlsp-smoke-http.log")"
  fi
  dx tlsp cp -p /root/env.orig /etc/ubicloud/env
  dx tlsp sed -i "s/^TLS_FRONT=.*/TLS_FRONT='bogus'/" /etc/ubicloud/front.conf
  rc=0
  adm tlsp smoke >"$LOGS/tlsp-smoke-bogus.log" 2>&1 || rc=$?
  dx tlsp cp -p /root/front.orig /etc/ubicloud/front.conf
  if [[ $rc != 1 ]] || ! grep -q '^fail    smoke: /etc/ubicloud/front.conf names an unknown front bogus$' "$LOGS/tlsp-smoke-bogus.log"; then
    fail "tls-provided: smoke with an unknown front exited $rc: $(grep smoke "$LOGS/tlsp-smoke-bogus.log")"
  fi
  say "tls-provided: smoke warns on an acme certificate not issued yet (curl exit 35) and fails on a stopped caddy, an http BASE_URL and an unknown front"

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
  # Step 12: the public name does not resolve here, which is a warning;
  # puma itself answers.
  if ! { grep -q '^warn    smoke: no answer from https://cp.example.test yet (HTTP 000, curl exit 6)' "$LOGS/tunnel-existing.log" &&
    grep -q '^ok      smoke: cloudflared.service active$' "$LOGS/tunnel-existing.log" &&
    grep -q '^smoke: ok ' "$LOGS/tunnel-existing.log"; }; then
    fail "tunnel: step 12: $(grep smoke "$LOGS/tunnel-existing.log")"
  fi
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

  # Step 12 through a stand-in for Cloudflare's edge under the public
  # name: 200 passes, 530 (a tunnel without a connector yet) warns,
  # another code fails, and a stopped cloudflared.service fails.
  dx tunnel bash -c 'cp /etc/hosts /root/hosts.orig && echo "127.0.0.1 cp.example.test" >>/etc/hosts &&
    cp /root/tls/cert.pem /usr/local/share/ca-certificates/ubi-m3-edge.crt && update-ca-certificates >/dev/null 2>&1'
  local code edge want
  # shellcheck disable=SC2016 # Ruby code
  edge='ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = OpenSSL::X509::Certificate.new(File.read("/root/tls/cert.pem"))
    ctx.key = OpenSSL::PKey.read(File.read("/root/tls/key.pem"))
    srv = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 443), ctx)
    loop do
      c = begin; srv.accept; rescue; next; end
      begin
        while (l = c.gets) && l != "\r\n"; end
        c.write("HTTP/1.1 #{ARGV[0]} Stand-in\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      rescue
      ensure
        c.close rescue nil
      end
    end'
  for code in 200 530 404; do
    docker exec -d ubi-m3-tunnel /opt/ubicloud/tools/bin/ruby -rsocket -ropenssl -e "$edge" "$code" ubi-m3-edge
    # shellcheck disable=SC2016 # expanded by the container's bash
    wait_for 20 dx tunnel bash -c '[[ -n $(ss -Htln "sport = :443") ]]' >/dev/null || fail "tunnel: the edge stand-in did not start"
    rc=0
    adm tunnel smoke >"$LOGS/tunnel-smoke-$code.log" 2>&1 || rc=$?
    dx tunnel pkill -f ubi-m3-edge
    # shellcheck disable=SC2016 # expanded by the container's bash
    wait_for 20 dx tunnel bash -c '[[ -z $(ss -Htln "sport = :443") ]]' >/dev/null || fail "tunnel: the edge stand-in did not stop"
    case $code in
      200) out='^ok      smoke: https://cp.example.test answers through the tunnel \(HTTP 200\)$' want=0 ;;
      530) out='^warn    smoke: no answer from https://cp.example.test yet \(HTTP 530, curl exit 0\)' want=0 ;;
      404) out='^fail    smoke: https://cp.example.test answers HTTP 404 through the tunnel' want=1 ;;
    esac
    if [[ $rc != "$want" ]] || ! grep -qE "$out" "$LOGS/tunnel-smoke-$code.log" ||
      ! grep -q '^ok      smoke: cloudflared.service active$' "$LOGS/tunnel-smoke-$code.log"; then
      fail "tunnel: smoke with the edge answering $code exited $rc: $(grep smoke "$LOGS/tunnel-smoke-$code.log")"
    fi
  done
  dx tunnel systemctl stop cloudflared
  rc=0
  adm tunnel smoke >"$LOGS/tunnel-smoke-stopped.log" 2>&1 || rc=$?
  dx tunnel systemctl start cloudflared
  pid=$(main_pid tunnel cloudflared)
  if [[ $rc != 1 ]] || ! grep -q '^fail    smoke: cloudflared.service is inactive, so nothing serves https://cp.example.test (systemctl start cloudflared.service; ubicloud-admin logs cloudflared)$' "$LOGS/tunnel-smoke-stopped.log"; then
    fail "tunnel: smoke with cloudflared.service stopped exited $rc: $(grep smoke "$LOGS/tunnel-smoke-stopped.log")"
  fi
  dx tunnel bash -c 'cp /root/hosts.orig /etc/hosts && rm /usr/local/share/ca-certificates/ubi-m3-edge.crt &&
    update-ca-certificates --fresh >/dev/null 2>&1'
  say "tunnel: smoke passes on 200, warns on Cloudflare's 530, fails on another code and on a stopped cloudflared.service"

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

  # A stopped, disabled unit serves nothing: the front step warns (the
  # unit is not install.sh's to start), and step 12 fails on it.
  dx tunnel systemctl disable -q --now cloudflared
  rc=0
  install_cp tunnel "${tun[@]}" >"$LOGS/tunnel-stopped.log" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "tunnel: rerun with a stopped unit exited $rc, not 1"
  if ! grep -q '^warn    front: cloudflared.service is not running, so nothing serves https://cp.example.test' "$LOGS/tunnel-stopped.log" ||
    ! grep -q '^warn    front: cloudflared.service is not enabled' "$LOGS/tunnel-stopped.log" ||
    ! grep -q '^fail    smoke: cloudflared.service is inactive, so nothing serves https://cp.example.test' "$LOGS/tunnel-stopped.log" ||
    ! grep -q '^install.sh: the install smoke test failed' "$LOGS/tunnel-stopped.log"; then
    fail "tunnel: a stopped, disabled cloudflared.service: $(grep -E 'front|smoke' "$LOGS/tunnel-stopped.log")"
  fi
  say "tunnel: a stopped, disabled cloudflared.service is warned about, and step 12 fails on it"

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
  # Type=notify: with the dummy token cloudflared never reports ready,
  # which step 12 takes for a tunnel still connecting.
  grep -q '^warn    smoke: ubicloud-cloudflared.service is activating; cloudflared connects in the background' "$LOGS/tunnel-fresh.log" ||
    fail "tunnel: step 12 on a connecting ubicloud-cloudflared: $(grep smoke "$LOGS/tunnel-fresh.log")"
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

# The output of the last adm_rc.
adm_last() { awk '/^### ubicloud-admin /{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$LOGS/adm.log"; }

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
  local f a b c m=$WT/scripts/byoh/migrate-from-dev.sh
  a=$(sed -n '/^kv_read() {/,/^}/p' "$WT/scripts/byoh/install.sh")
  b=$(sed -n '/^kv_read() {/,/^}/p' "$WT/packaging/bin/ubicloud-admin")
  c=$(sed -n '/^kv_read() {/,/^}/p' "$m")
  [[ -n $a && $a == "$b" && $a == "$c" ]] || fail "parity: kv_read differs between install.sh, ubicloud-admin and migrate-from-dev.sh"
  for f in "valid_value() " "readonly KEY_RE=" "readonly DENIED_KEY_RE=" "readonly LOCK="; do
    a=$(grep "^$f" "$WT/scripts/byoh/install.sh")
    b=$(grep "^$f" "$WT/packaging/bin/ubicloud-admin")
    c=$(grep "^$f" "$m")
    [[ -n $a && $a == "$b" && $a == "$c" ]] || fail "parity: $f differs between install.sh, ubicloud-admin and migrate-from-dev.sh"
  done
  a=$(grep '^readonly INTERP_KEY_RE=' "$WT/packaging/bin/ubicloud-admin")
  c=$(grep '^readonly INTERP_KEY_RE=' "$m")
  [[ -n $a && $a == "$c" ]] || fail "parity: INTERP_KEY_RE differs between ubicloud-admin and migrate-from-dev.sh"
  say "parity: kv_read, valid_value, KEY_RE, DENIED_KEY_RE and LOCK match in all three, INTERP_KEY_RE in ubicloud-admin and migrate-from-dev.sh"
}

sc_backup() {
  local out ts ts2 smp env_sum since dir f saved
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
  # A billing rate file, so a restore has one to bring back.
  dx backup bash -c 'printf "# harness v1\n[]\n" >/var/lib/ubicloud/billing_rates.d/harness.yml && chown ubicloud:ubicloud /var/lib/ubicloud/billing_rates.d/harness.yml && chmod 0640 /var/lib/ubicloud/billing_rates.d/harness.yml'
  say "backup: Sshable#cmd ok, account created, login ok"

  # backup now; a symlink in the billing rates goes into the archive,
  # and a restore must not copy what it points to.
  dx backup ln -s /etc/shadow /var/lib/ubicloud/billing_rates.d/evil.yml
  out=$(adm backup backup now 2>&1) || { dx backup rm -f /var/lib/ubicloud/billing_rates.d/evil.yml; fail "backup: backup now: $out"; }
  dx backup rm -f /var/lib/ubicloud/billing_rates.d/evil.yml
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

  # --env-only --force over another column key keeps the old env file.
  # The services keep the key they started with until the restore
  # restarts them.
  dx backup sed -i "s|^CLOVER_COLUMN_ENCRYPTION_KEY=.*|CLOVER_COLUMN_ENCRYPTION_KEY='$(head -c 32 /dev/urandom | base64 -w0)'|" /etc/ubicloud/env
  out=$(dx backup sha256sum /etc/ubicloud/env | cut -d' ' -f1)
  f=$(main_pid backup ubicloud-web)
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key --env-only --force) == 0 ]] || fail "backup: restore --env-only --force failed"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: --env-only --force did not install the backup's env file"
  saved=$(dx backup bash -c 'ls /etc/ubicloud/env.before-restore-*')
  [[ $(wc -l <<<"$saved") == 1 && $(dx backup sha256sum "$saved" | cut -d' ' -f1) == "$out" ]] ||
    fail "backup: --env-only --force kept no copy of the env file it replaced: $saved"
  [[ $(dx backup stat -c '%U:%G %a' "$saved") == "root:root 600" ]] || fail "backup: $saved is not root 0600"
  grep -q "the env file before the restore is $saved" "$LOGS/adm.log" || fail "backup: --env-only did not name $saved"
  [[ $(main_pid backup ubicloud-web) != "$f" ]] || fail "backup: --env-only --force did not restart web"
  dx backup rm -f "$saved"
  [[ $(db_names backup) == ubicloud ]] || fail "backup: --env-only touched the databases: $(db_names backup)"
  wait_for 120 web_up backup >/dev/null || fail "backup: web down after --env-only"
  say "backup: --env-only --force installed the backup's env file, kept the old one as ${saved##*/} (root 0600) and restarted the services"

  # --db-only with the matching key keeps the env file.
  [[ $(adm_rc backup restore "$ts" --db-only) == 0 ]] || fail "backup: restore --db-only failed"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: --db-only changed the env file"
  dx backup bash -c 'ls /etc/ubicloud/env.before-restore-* 2>/dev/null' && fail "backup: --db-only saved an env file"
  [[ $(db_names backup) =~ ^ubicloud\ ubicloud_prev_[0-9]{14}$ ]] || fail "backup: databases after --db-only: $(db_names backup)"
  dx backup runuser -u postgres -- dropdb "$(db_names backup | cut -d' ' -f2)"
  [[ $(login backup) == "302 http://localhost:3000/after-login" ]] || fail "backup: login after --db-only"
  say "backup: --db-only with the matching key restored the database and kept the env file"

  # A dump with SQL that needs a superuser: pg_restore runs as
  # ubicloud_restorer, so it fails and nothing changes.
  psql_q backup "CREATE TABLE harness_su (x int)"
  out=$(adm backup backup now 2>&1) || fail "backup: backup now with harness_su: $out"
  f=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  psql_q backup "DROP TABLE harness_su"
  [[ $(adm_rc backup restore "$f" --key-file /root/backup-key) == 1 ]] || fail "backup: a dump with a postgres-owned table did not fail"
  grep -q 'must be able to SET ROLE "postgres"' "$LOGS/adm.log" || fail "backup: no SET ROLE error from pg_restore"
  grep -q 'the live database was not touched' "$LOGS/adm.log" || fail "backup: no 'not touched' message"
  [[ $(db_names backup) == ubicloud ]] || fail "backup: the failed pg_restore left databases: $(db_names backup)"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: the failed pg_restore changed the env file"
  dx backup rm -rf "/var/backups/ubicloud/$f" "/var/backups/ubicloud/secrets/$f.age"
  say "backup: a dump whose SQL needs a superuser fails in pg_restore as ubicloud_restorer; the live control plane is untouched"

  # An env file in the backup that sets RUBYOPT is refused.
  dx backup bash -c "echo \"RUBYOPT='-W0'\" >>/etc/ubicloud/env"
  out=$(adm backup backup now 2>&1) || fail "backup: backup now with RUBYOPT: $out"
  f=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  dx backup sed -i '/^RUBYOPT=/d' /etc/ubicloud/env
  [[ $(adm_rc backup restore "$f" --key-file /root/backup-key --force) == 2 ]] || fail "backup: an env file with RUBYOPT was not refused"
  grep -q 'sets RUBYOPT, which loads code' "$LOGS/adm.log" || fail "backup: no RUBYOPT message"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: the RUBYOPT refusal changed the env file"
  dx backup rm -rf "/var/backups/ubicloud/$f" "/var/backups/ubicloud/secrets/$f.age"
  say "backup: a backup whose env file sets RUBYOPT is refused (exit 2)"

  # A restore --force whose migrations fail puts back the old database,
  # env file, other secrets and billing rates.
  printf '%s\n' "$PASSWORD" | adm backup account create --email after@example.test --password-stdin >/dev/null 2>&1 ||
    fail "backup: account create after@"
  dx backup bash -c "echo \"HARNESS_MARK='changed'\" >>/etc/ubicloud/env && echo '# harness: changed' >>/etc/ubicloud/backup-recipients &&
    echo '# harness v2' >>/var/lib/ubicloud/billing_rates.d/harness.yml && rm -f /etc/ubicloud/env.before-restore-*"
  local etc_sums
  etc_sums=$(dx backup bash -c 'cd /etc/ubicloud && sha256sum env backup-recipients backup.conf front.conf /var/lib/ubicloud/billing_rates.d/*')
  dx backup bash -c 'printf "# frozen_string_literal: true\n\nSequel.migration { up { raise \"harness: failing migration\" } }\n" >/opt/ubicloud/current/migrate/20991231_harness_fail.rb'
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key --force) == 1 ]] || fail "backup: a restore with a failing migration did not exit 1"
  dx backup rm -f /opt/ubicloud/current/migrate/20991231_harness_fail.rb
  grep -q 'database ubicloud, /etc/ubicloud and /var/lib/ubicloud/billing_rates.d are as before' "$LOGS/adm.log" || fail "backup: no rollback message"
  grep -q after@example.test <<<"$(adm backup account list)" || fail "backup: the rollback did not bring the old database back"
  [[ $(dx backup bash -c 'cd /etc/ubicloud && sha256sum env backup-recipients backup.conf front.conf /var/lib/ubicloud/billing_rates.d/*') == "$etc_sums" ]] ||
    fail "backup: the rollback did not put back the env file, the secrets or the billing rates"
  dx backup bash -c 'ls /etc/ubicloud/env.before-restore-* 2>/dev/null' && fail "backup: the rollback left an env.before-restore copy"
  wait_for 120 web_up backup >/dev/null || fail "backup: web down after the rollback"
  assert_active backup
  [[ $(db_names backup) =~ ^ubicloud\ ubicloud_failed_[0-9]{14}$ ]] || fail "backup: databases after the rollback: $(db_names backup)"
  dx backup runuser -u postgres -- dropdb "$(db_names backup | cut -d' ' -f2)"
  say "backup: a failing migration rolls a --force restore back: old database, env file, backup-recipients and billing rates, services running"

  # Then the same restore --force without the failing migration installs
  # the backup's files and keeps the replaced env file.
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key --force) == 0 ]] || fail "backup: restore --force failed"
  [[ $(dx backup sha256sum /etc/ubicloud/env) == "$env_sum" ]] || fail "backup: restore --force did not install the backup's env file"
  saved=$(dx backup bash -c 'ls /etc/ubicloud/env.before-restore-*')
  dx backup grep -qx "HARNESS_MARK='changed'" "$saved" || fail "backup: restore --force kept no copy of the replaced env file"
  dx backup grep -q '# harness: changed' /etc/ubicloud/backup-recipients && fail "backup: restore --force kept the changed backup-recipients"
  dx backup grep -q '# harness v2' /var/lib/ubicloud/billing_rates.d/harness.yml && fail "backup: restore --force kept the changed billing rates"
  [[ $(dx backup stat -c '%U:%G %a' /var/lib/ubicloud/billing_rates.d/harness.yml) == "ubicloud:ubicloud 640" ]] || fail "backup: the restored billing rates' mode"
  dx backup test ! -e /var/lib/ubicloud/billing_rates.d/evil.yml || fail "backup: restore --force copied a symlink's target into the billing rates"
  grep -q 'skipped evil.yml in the backup' "$LOGS/adm.log" || fail "backup: no warning for the symlink in the billing rates"
  dx backup rm -f "$saved"
  [[ $(db_names backup) =~ ^ubicloud\ ubicloud_prev_[0-9]{14}$ ]] || fail "backup: databases after restore --force: $(db_names backup)"
  dx backup runuser -u postgres -- dropdb "$(db_names backup | cut -d' ' -f2)"
  # The account made after the backup is gone again; the next case makes it anew.
  printf '%s\n' "$PASSWORD" | adm backup account create --email after@example.test --password-stdin >/dev/null 2>&1 ||
    fail "backup: account create after@ again"
  say "backup: restore --force installed the backup's env file (the old one kept), backup-recipients and billing rates"

  # A restore over the live database keeps it as ubicloud_prev_*.
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key) == 0 ]] || fail "backup: restore over the live database failed"
  grep -q after@example.test <<<"$(adm backup account list)" && fail "backup: the restore kept an account made after the backup"
  [[ $(db_names backup) =~ ^ubicloud\ ubicloud_prev_[0-9]{14}$ ]] || fail "backup: databases after the restore: $(db_names backup)"
  [[ $(adm_rc backup status) == 0 ]] || fail "backup: status after the restore"
  [[ $(login backup) == "302 http://localhost:3000/after-login" ]] || fail "backup: login after the restore"
  say "backup: a restore over the live database ran; the old one is $(db_names backup | cut -d' ' -f2); status ok"

  # The restore drill: --no-start leaves every service stopped, so the
  # restored respirate never runs the backup's strands.
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key --env-only --no-start) == 2 ]] ||
    fail "backup: --no-start with --env-only was not refused with exit 2"
  [[ $(adm_rc backup restore "$ts" --key-file /root/backup-key --no-start) == 0 ]] || fail "backup: restore --no-start failed: $(adm_last)"
  grep -q '^notice  restore: the services stay stopped (--no-start)' <<<"$(adm_last)" || fail "backup: restore --no-start: $(adm_last)"
  for u in ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor; do
    [[ $(dx backup systemctl is-active "$u" || true) == inactive ]] || fail "backup: $u runs after restore --no-start"
  done
  grep -q after@example.test <<<"$(adm backup account list)" && fail "backup: restore --no-start kept an account made after the backup"
  dx backup systemctl start ubicloud.target
  wait_for 120 web_up backup >/dev/null || fail "backup: web down after restore --no-start and a start"
  say "backup: restore --no-start restored the database and left every service stopped; --env-only refuses it"

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
  local out pid since pw since_otel
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
  out=$(printf 'ops@example.test\n' | adm admin env set HARNESS_SETTING 2>&1) || fail "admin: env set HARNESS_SETTING: $out"
  [[ $out != *ops@example.test* ]] || fail "admin: env set printed the value"
  [[ $(adm admin env get HARNESS_SETTING --reveal) == ops@example.test ]] || fail "admin: env get --reveal"
  [[ $(main_pid admin ubicloud-web) != "$pid" ]] || fail "admin: env set did not restart web"
  [[ $(dx admin stat -c '%U:%G %a' /etc/ubicloud/env) == "root:root 600" ]] || fail "admin: env set changed the env file's mode"
  out=$(dx admin sha256sum /etc/ubicloud/env)
  [[ $(adm_rc admin env get HARNESS_SETTING) == 2 ]] || fail "admin: env get without --reveal"
  for k in PATH LD_PRELOAD PRY_ALLOW_UNAUDITED CLOVER_COLUMN_ENCRYPTION_KEY CLOVER_SESSION_SECRET CLOVER_RUNTIME_TOKEN_SECRET \
    GIT_REV IP_FROM_HEADER BASE_URL RACK_ENV MAIL_FROM MAIL_DRIVER SMTP_HOST RUBYOPT RUBYLIB BUNDLE_GEMFILE GEM_PATH NODE_OPTIONS lower; do
    [[ $(printf 'v' | adm admin env set "$k" >/dev/null 2>&1; echo $?) == 2 ]] || fail "admin: env set $k was not refused"
  done
  for k in CLOVER_DATABASE_URL CLOVER_SESSION_SECRET CLOVER_COLUMN_ENCRYPTION_KEY RACK_ENV BASE_URL; do
    [[ $(adm_rc admin env unset "$k") == 2 ]] || fail "admin: env unset $k was not refused"
  done
  for v in "a'b" 'a\b' $'a\nb' ''; do
    [[ $(printf '%s' "$v" | adm admin env set HARNESS_SETTING >/dev/null 2>&1; echo $?) == 2 ]] || fail "admin: env set took a bad value"
  done
  [[ $(printf 'a\0b' | adm admin env set HARNESS_SETTING >/dev/null 2>&1; echo $?) == 2 ]] || fail "admin: env set took a NUL"
  [[ $(dx admin sha256sum /etc/ubicloud/env) == "$out" ]] || fail "admin: a refused env set changed the env file"
  # A value web cannot start with is put back.
  pid=0
  printf 'postgres:///harness_missing?user=ubicloud' | adm admin env set CLOVER_DATABASE_URL >>"$LOGS/adm.log" 2>&1 || pid=$?
  [[ $pid == 1 ]] || fail "admin: env set of a broken CLOVER_DATABASE_URL exited $pid, not 1"
  grep -q 'env set CLOVER_DATABASE_URL is undone: web did not answer with it' "$LOGS/adm.log" || fail "admin: no undo message"
  [[ $(dx admin sha256sum /etc/ubicloud/env) == "$out" ]] || fail "admin: the failed env set was not undone"
  wait_for 120 web_up admin >/dev/null || fail "admin: web down after the undone env set"
  # The broken URL's connection errors are expected; journal_clean checks
  # from the next second on.
  sleep 1
  since=$(dx admin date '+%F %T')
  adm admin env unset HARNESS_SETTING >/dev/null || fail "admin: env unset HARNESS_SETTING"
  out=$(dx admin sha256sum /etc/ubicloud/env)
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
  for out in --bmc-password --bmc-passw=x --bmc_password=x --BMC-PASSWORD=x --b-password --b-passw=x --Bmc_Passw --bmc-pass; do
    [[ $(adm_rc admin run register-byoh-host "$out" x) == 2 ]] || fail "admin: $out was not refused"
  done
  for out in --bmc-pass-env --b-pass-env; do
    [[ $(adm_rc admin run register-byoh-host "$out" BMC_PASS) != 2 ]] || fail "admin: $out was refused"
  done
  adm admin run byoh-location list >/dev/null || fail "admin: run byoh-location list"
  adm admin run byoh-config-check >/dev/null || fail "admin: run byoh-config-check"
  docker exec -i -w /root ubi-m3-admin ubicloud-admin run byoh-host export-audit --out audit.jsonl >/dev/null || fail "admin: export-audit --out"
  [[ $(dx admin stat -c '%U %a' /root/audit.jsonl) == "root 600" ]] || fail "admin: --out file"
  dx admin grep -q 'byoh-account create' /root/audit.jsonl || fail "admin: the audit export lacks the account rows"
  grep -q '^Password for account is: ' <<<"$(adm admin run create_prod_admin_account harness-admin 2>&1)" || fail "admin: create_prod_admin_account"
  adm admin run production_check >"$LOGS/admin-production-check.log" 2>&1 || fail "admin: production_check, see $LOGS/admin-production-check.log"
  say "admin: run refuses unknown tools and every OptionParser spelling of --bmc-password; tools run from /, --out is written back, production_check passes"

  # The staged files: a root directory ubicloud can read but not write,
  # and an --out that is a symlink is not followed as root.
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx admin bash -c 'source <(sed "\$d" /usr/local/bin/ubicloud-admin); CALLER_PWD=/root
    stage_dir; p=$(stage_in /root/pw.txt); d=${p%/*}
    stat -c "%U:%G %a" "$d" "$p"
    runuser -u ubicloud -- cat "$p" >/dev/null && echo read-ok
    runuser -u ubicloud -- ln -sf /etc/shadow "$d/x" 2>/dev/null || echo link-refused
    runuser -u ubicloud -- mv "$p" "$d/y" 2>/dev/null || echo move-refused
    stage_args --out /root/shadow.out; runuser -u ubicloud -- ln -s /etc/shadow "$OUT_STAGED"
    (deliver_out) 2>/dev/null || echo out-refused
    test -e /root/shadow.out || echo out-absent
    rm -f "$OUT_STAGED"; runuser -u ubicloud -- bash -c "echo harness-out >$OUT_STAGED"; deliver_out; cat /root/shadow.out; rm -f /root/shadow.out' 2>&1)
  [[ $out == $'root:ubicloud 750\nroot:ubicloud 440\nread-ok\nlink-refused\nmove-refused\nout-refused\nout-absent\nharness-out' ]] ||
    fail "admin: the staged files: $out"
  say "admin: staged files are root:ubicloud 0440 in a root:ubicloud 0750 directory; an --out symlink is refused"

  # console
  out=$(adm admin console -e 'puts "harness-console-#{6 * 7}"' 2>&1) || fail "admin: console -e: $out"
  [[ $out == *harness-console-42* && $out == *"NOT audited"* ]] || fail "admin: console -e: $out"
  out=$(printf 'x = 6 * 7\nputs "harness-stdin-#{x}"\n' | adm admin console -e - 2>&1) || fail "admin: console -e -: $out"
  [[ $out == *harness-stdin-42* ]] || fail "admin: console -e -: $out"
  [[ $(adm_rc admin console -e 'raise "harness-raise"') == 1 ]] || fail "admin: console -e of a raise did not exit 1"
  # With an audit sink, -e goes through it and nothing runs unaudited.
  # The sink is a tiny OTLP receiver on 127.0.0.1:4318.
  docker exec -d ubi-m3-admin /opt/ubicloud/tools/bin/ruby -rsocket -e '
    s = TCPServer.new("127.0.0.1", 4318)
    loop do
      c = s.accept
      while (l = c.gets)
        n = 0
        while (h = c.gets) && h != "\r\n"
          n = h.split(":", 2)[1].to_i if h.downcase.start_with?("content-length:")
        end
        File.write("/root/otlp.log", c.read(n) + "\n", mode: "a")
        c.write "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
      end
      c.close
    end'
  printf 'http://127.0.0.1:4318' | adm admin env set OTEL_EXPORTER_OTLP_ENDPOINT --no-restart >/dev/null || fail "admin: env set OTEL_EXPORTER_OTLP_ENDPOINT"
  # Counted, not --since: journalctl's --since has whole seconds, and the
  # unaudited runs above may end in the same second.
  since_otel=$(dx admin journalctl --no-pager -t ubicloud-pry -o cat | grep -c 'unaudited pry session opened' || true)
  out=$(printf 'puts "harness-audited-#{6 * 7}"' | adm admin console -e - 2>&1) || fail "admin: audited console -e -: $out"
  [[ $out == *harness-audited-42* && $out != *"NOT audited"* ]] || fail "admin: audited console -e -: $out"
  dx admin grep -q 'harness-audited-' /root/otlp.log || fail "admin: the code of console -e did not reach the audit sink"
  dx admin grep -q 'pry session opened' /root/otlp.log || fail "admin: no session line in the audit sink"
  [[ $(dx admin journalctl --no-pager -t ubicloud-pry -o cat | grep -c 'unaudited pry session opened' || true) == "$since_otel" ]] ||
    fail "admin: an audited console logged an unaudited session"
  adm admin env unset OTEL_EXPORTER_OTLP_ENDPOINT --no-restart >/dev/null || fail "admin: env unset OTEL_EXPORTER_OTLP_ENDPOINT"
  dx admin pkill -f 'TCPServer.new' || true
  out=$(printf 'puts "harness-pry-#{6 * 7}"\nexit\n' | adm admin console 2>&1) || fail "admin: console: $out"
  [[ $out == *harness-pry-42* && $out == *"NOT audited"* ]] || fail "admin: console (pry): $out"
  out=$(dx admin journalctl --no-pager -t ubicloud-admin -t ubicloud-pry -o cat)
  [[ $out == *"console -e by root"* && $out == *"unaudited pry session opened"* ]] || fail "admin: console log lines: $out"
  grep -q 'harness-console' <<<"$(dx admin journalctl --no-pager)" && fail "admin: console code reached the journal"
  dx admin grep -q PRY_ALLOW_UNAUDITED /etc/ubicloud/env && fail "admin: console left PRY_ALLOW_UNAUDITED in the env file"
  say "admin: console -e, -e - and pry run unaudited with one log line each and the code stays out of the journal; with an OTLP sink, -e goes through it"

  # logs
  [[ -n $(adm admin logs web -n 5) ]] || fail "admin: logs web"
  [[ $(adm_rc admin logs bogus) == 2 ]] || fail "admin: logs bogus"
  journal_clean admin "$since"
  say "admin: ok"
}

# --- development bootstrap and its shim (WP8) --------------------------------------------

# as_ubuntu NAME CMD: the bash command line CMD as user ubuntu, in a
# login-like environment (HOME, no inherited variables), with
# UBI_START_SERVICES=0; CMD may set more variables in front of it.
as_ubuntu() {
  dx "$1" runuser -u ubuntu -- env -i HOME=/home/ubuntu USER=ubuntu LOGNAME=ubuntu LANG=C.UTF-8 \
    PATH=/usr/local/bin:/usr/bin:/bin UBI_START_SERVICES=0 bash -c "cd ~ && $2"
}

# dev_run NAME LOG CMD: as_ubuntu, output to $LOGS/LOG; prints the exit
# status.
dev_run() {
  local rc=0
  as_ubuntu "$1" "$3" >"$LOGS/$2" 2>&1 </dev/null || rc=$?
  echo "$rc"
}

# The bootstrap's own markers, the one place it records progress.
dev_markers() { dx "$1" bash -c 'ls /home/ubuntu/.ubi-bootstrap 2>/dev/null | sort | tr "\n" " "'; }

# Every development step the bootstrap reports as skipped in LOG.
DEV_SKIPS=(apt-packages ruby-4.0.7 node-24.12.0 postgres-setup pg-hba-trust bundle-install npm-assets migrations caches-refreshed)
all_skipped() {
  local m
  for m in "${DEV_SKIPS[@]}"; do
    grep -qF "(marker: /home/ubuntu/.ubi-bootstrap/$m)" "$LOGS/$1" || return 1
  done
}

# The development bootstrap (scripts/byoh/bootstrap-dev-ctrl-plane.sh)
# and the old name's shim, as user ubuntu on ubi-m3-tools, with the
# repository extracted at ~/ubicloud and UBI_START_SERVICES=0.
sc_devshim() {
  # shellcheck disable=SC2088 # expanded by the container's bash
  local rc t n hba shim='~/ubicloud/scripts/byoh/bootstrap-ctrl-plane.sh'
  stage_art
  src_tarball
  start_sys devshim ubi-m3-tools
  # Ubuntu cloud images give ubuntu passwordless sudo, as the bootstrap
  # expects.
  dx devshim bash -c 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-ubuntu && chmod 0440 /etc/sudoers.d/90-ubuntu'
  as_ubuntu devshim 'mkdir ubicloud && tar -xzf /art/src.tgz -C ubicloud' || fail "devshim: cannot extract the source"
  hba=$(dx devshim sha256sum /etc/postgresql/16/main/pg_hba.conf)

  # Refusals change nothing: no marker directory, pg_hba.conf as it was.
  rc=$(dev_run devshim devshim-prod.log "UBI_RACK_ENV=production bash $shim")
  { [[ $rc == 1 ]] && grep -q 'UBI_RACK_ENV=production.*install.sh' "$LOGS/devshim-prod.log"; } ||
    fail "devshim: UBI_RACK_ENV=production gave $rc, see $LOGS/devshim-prod.log"
  rc=$(dev_run devshim devshim-dbname.log "UBI_DB_NAME=ubicloud bash $shim")
  { [[ $rc == 1 ]] && grep -q 'UBI_DB_NAME=ubicloud' "$LOGS/devshim-dbname.log"; } ||
    fail "devshim: UBI_DB_NAME=ubicloud gave $rc, see $LOGS/devshim-dbname.log"
  dx devshim bash -c 'install -d -m 0755 /etc/ubicloud && install -m 0600 /dev/null /etc/ubicloud/env'
  rc=$(dev_run devshim devshim-envfile.log "bash $shim")
  { [[ $rc == 1 ]] && grep -q '/etc/ubicloud/env exists.*UBI_FORCE_DEV=1' "$LOGS/devshim-envfile.log"; } ||
    fail "devshim: /etc/ubicloud/env present gave $rc, see $LOGS/devshim-envfile.log"
  dx devshim rm -rf /etc/ubicloud
  dx devshim bash -c 'printf "[Unit]\nDescription=stand-in\n[Install]\nWantedBy=multi-user.target\n" >/etc/systemd/system/ubicloud.target &&
    systemctl daemon-reload && systemctl enable ubicloud.target 2>/dev/null'
  rc=$(dev_run devshim devshim-target.log "bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh")
  { [[ $rc == 1 ]] && grep -q 'ubicloud.target is enabled' "$LOGS/devshim-target.log"; } ||
    fail "devshim: an enabled ubicloud.target gave $rc, see $LOGS/devshim-target.log"
  dx devshim bash -c 'systemctl disable ubicloud.target 2>/dev/null && systemctl start ubicloud.target'
  rc=$(dev_run devshim devshim-target-active.log "bash $shim")
  { [[ $rc == 1 ]] && grep -q 'ubicloud.target is active' "$LOGS/devshim-target-active.log"; } ||
    fail "devshim: an active ubicloud.target gave $rc, see $LOGS/devshim-target-active.log"
  dx devshim bash -c 'systemctl stop ubicloud.target && rm /etc/systemd/system/ubicloud.target && systemctl daemon-reload'
  rc=$(dev_run devshim devshim-norepo.log "cd /tmp && cat $shim | UBI_REPO_DIR=/home/ubuntu/none bash")
  { [[ $rc == 1 ]] && grep -q 'git clone .* /home/ubuntu/none$' "$LOGS/devshim-norepo.log"; } ||
    fail "devshim: the piped shim without a checkout gave $rc, see $LOGS/devshim-norepo.log"
  # A checkout from before the rename (the live control plane keeps one)
  # gets the pull step, not a clone into a directory that exists.
  as_ubuntu devshim 'mkdir -p old/scripts/byoh && touch old/Gemfile && printf "echo old bootstrap ran\n" >old/scripts/byoh/bootstrap-ctrl-plane.sh'
  rc=$(dev_run devshim devshim-oldrepo.log "cd /tmp && cat $shim | UBI_REPO_DIR=/home/ubuntu/old bash")
  { [[ $rc == 1 ]] && grep -q 'checkout at /home/ubuntu/old predates the rename' "$LOGS/devshim-oldrepo.log" &&
    grep -q 'git -C /home/ubuntu/old pull' "$LOGS/devshim-oldrepo.log" &&
    ! grep -q 'git clone\|old bootstrap ran' "$LOGS/devshim-oldrepo.log"; } ||
    fail "devshim: the piped shim with a pre-rename checkout gave $rc, see $LOGS/devshim-oldrepo.log"
  rc=$(dev_run devshim devshim-notrepo.log "cd /tmp && cat $shim | UBI_REPO_DIR=/home/ubuntu/old/scripts bash")
  { [[ $rc == 1 ]] && grep -q '/home/ubuntu/old/scripts is not an ubicloud checkout' "$LOGS/devshim-notrepo.log" &&
    ! grep -q 'git clone' "$LOGS/devshim-notrepo.log"; } ||
    fail "devshim: the piped shim with a directory that is no checkout gave $rc, see $LOGS/devshim-notrepo.log"
  as_ubuntu devshim 'rm -rf old'
  [[ -z $(dev_markers devshim) ]] || fail "devshim: a refusal created markers: $(dev_markers devshim)"
  [[ $(dx devshim sha256sum /etc/postgresql/16/main/pg_hba.conf) == "$hba" ]] || fail "devshim: a refusal changed pg_hba.conf"
  say "devshim: production, ubicloud, /etc/ubicloud/env, an enabled or an active ubicloud.target, and a missing, pre-rename or foreign checkout refuse (exit 1) and change nothing"

  # The old path: the shim warns and runs the development script.
  t=$(timed as_ubuntu devshim "bash $shim >/tmp/devshim-first.log 2>&1") || {
    dx devshim cat /tmp/devshim-first.log >"$LOGS/devshim-first.log"
    fail "devshim: the first run failed, see $LOGS/devshim-first.log"
  }
  dx devshim cat /tmp/devshim-first.log >"$LOGS/devshim-first.log"
  { grep -q 'is renamed to scripts/byoh/bootstrap-dev-ctrl-plane.sh' "$LOGS/devshim-first.log" &&
    grep -q 'running /home/ubuntu/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh' "$LOGS/devshim-first.log"; } ||
    fail "devshim: the shim did not warn or name its target"
  [[ $(dx devshim runuser -u postgres -- psql -XtAc "SELECT count(*) FROM pg_database WHERE datname = 'clover_test'") == 1 ]] ||
    fail "devshim: no clover_test database"
  [[ $(dx devshim runuser -u postgres -- psql -XtAc "SELECT string_agg(rolname || ':' || rolsuper, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname LIKE 'clover%'") == "clover:true clover_password:false" ]] ||
    fail "devshim: the roles are not as the bootstrap always made them"
  n=$(dx devshim runuser -u postgres -- psql -XtA -d clover_test -c "SELECT count(*) FROM schema_migrations")
  ((n > 400)) || fail "devshim: clover_test has $n migrations"
  [[ $(dx devshim stat -c '%a %U' /home/ubuntu/ubicloud/.env.rb) == "600 ubuntu" ]] || fail "devshim: .env.rb is not ubuntu 0600"
  dx devshim grep -q '^ENV\["RACK_ENV"\] ||= "development"' /home/ubuntu/ubicloud/.env.rb || fail "devshim: .env.rb RACK_ENV is not development"
  dx devshim test -s /home/ubuntu/ubicloud/assets/css/app.css || fail "devshim: no assets/css/app.css"
  say "devshim: the path run (through the shim) took ${t}s: clover_test with $n migrations, roles as before, .env.rb 0600, assets built; markers: $(dev_markers devshim)"

  rc=$(dev_run devshim devshim-second.log "bash $shim")
  { [[ $rc == 0 ]] && all_skipped devshim-second.log; } || fail "devshim: the second run gave $rc or ran a step, see $LOGS/devshim-second.log"
  rc=$(dev_run devshim devshim-pipe.log "cd /tmp && cat $shim | bash")
  { [[ $rc == 0 ]] && all_skipped devshim-pipe.log &&
    grep -q 'running /home/ubuntu/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh' "$LOGS/devshim-pipe.log"; } ||
    fail "devshim: cat shim | bash gave $rc, see $LOGS/devshim-pipe.log"
  say "devshim: a second run by path and a cat shim | bash run from /tmp skip every step"

  # Resolution order 1: run from disk, the shim takes the development
  # script beside it, even when UBI_REPO_DIR names another place. The
  # copy's target does its work in ~/ubicloud, so it succeeds; with
  # UBI_REPO_DIR missing, order 2 would have exited before naming it.
  as_ubuntu devshim 'mkdir -p copy/scripts && cp -R ubicloud/scripts/byoh copy/scripts/'
  rc=$(dev_run devshim devshim-copy.log "UBI_REPO_DIR=/home/ubuntu/ubicloud bash ~/copy/scripts/byoh/bootstrap-ctrl-plane.sh")
  { [[ $rc == 0 ]] && grep -q 'running /home/ubuntu/copy/scripts/byoh/bootstrap-dev-ctrl-plane.sh' "$LOGS/devshim-copy.log" &&
    all_skipped devshim-copy.log; } ||
    fail "devshim: the shim in a second copy gave $rc, see $LOGS/devshim-copy.log"
  rc=$(dev_run devshim devshim-order1.log "UBI_REPO_DIR=/home/ubuntu/none bash $shim")
  { [[ $rc == 1 ]] && grep -q 'running /home/ubuntu/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh' "$LOGS/devshim-order1.log" &&
    grep -q 'ERROR: /home/ubuntu/none does not contain a ubicloud checkout' "$LOGS/devshim-order1.log"; } ||
    fail "devshim: the shim from disk with UBI_REPO_DIR missing gave $rc, see $LOGS/devshim-order1.log"
  as_ubuntu devshim 'rm -rf copy'
  say "devshim: run from disk, the shim takes the script beside it whatever UBI_REPO_DIR says"

  # Step 6 needs its marker as well as a passing bundle check; the old
  # test skipped on bundle check alone.
  as_ubuntu devshim 'rm ~/.ubi-bootstrap/bundle-install'
  rc=$(dev_run devshim devshim-bundle.log "bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh")
  { [[ $rc == 0 ]] && ! grep -qF '(marker: /home/ubuntu/.ubi-bootstrap/bundle-install)' "$LOGS/devshim-bundle.log" &&
    grep -q 'Bundle complete' "$LOGS/devshim-bundle.log" && dx devshim test -e /home/ubuntu/.ubi-bootstrap/bundle-install; } ||
    fail "devshim: without its marker step 6 gave $rc or skipped, see $LOGS/devshim-bundle.log"
  say "devshim: without its marker, step 6 runs bundle install although bundle check passes, and sets the marker again"

  # Step 3 again: an existing role or database is skipped, not masked.
  as_ubuntu devshim 'rm ~/.ubi-bootstrap/postgres-setup'
  rc=$(dev_run devshim devshim-pg.log "bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh")
  { [[ $rc == 0 ]] && ! grep -qE 'ERROR|role ".*" already exists|database ".*" already exists' "$LOGS/devshim-pg.log"; } ||
    fail "devshim: step 3 over the existing roles gave $rc, see $LOGS/devshim-pg.log"
  # A failed cache refresh now stops the run.
  as_ubuntu devshim 'rm ~/.ubi-bootstrap/caches-refreshed && chmod a-w ~/ubicloud/cache'
  rc=$(dev_run devshim devshim-cache.log "bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh")
  as_ubuntu devshim 'chmod u+w ~/ubicloud/cache'
  { [[ $rc == 1 ]] && grep -q 'ERROR: refresh_sequel_caches failed' "$LOGS/devshim-cache.log" &&
    ! dx devshim test -e /home/ubuntu/.ubi-bootstrap/caches-refreshed; } ||
    fail "devshim: a failing refresh_sequel_caches gave $rc, see $LOGS/devshim-cache.log"
  say "devshim: step 3 over the existing roles and database succeeds quietly; a failing cache refresh exits 1 and sets no marker"

  # UBI_FORCE_DEV=1 runs next to a packaged control plane, with a warning.
  dx devshim bash -c 'install -d -m 0755 /etc/ubicloud && install -m 0600 /dev/null /etc/ubicloud/env'
  rc=$(dev_run devshim devshim-force.log "UBI_FORCE_DEV=1 bash $shim")
  { [[ $rc == 0 ]] && grep -q 'continuing because UBI_FORCE_DEV=1' "$LOGS/devshim-force.log"; } ||
    fail "devshim: UBI_FORCE_DEV=1 gave $rc, see $LOGS/devshim-force.log"
  dx devshim rm -rf /etc/ubicloud
  say "devshim: UBI_FORCE_DEV=1 warns and runs"

  # m2-gate g1 on a development control plane whose services are not
  # started: tmux mode, the process checks and the .env.rb key.
  rc=$(dev_run devshim devshim-gate.log "cd ~/ubicloud && bash /art/m2-gate.sh g1")
  { [[ $rc == 1 ]] && grep -q '^== G1 .*(tmux)' "$LOGS/devshim-gate.log" && grep -q '^FAIL puma is not running' "$LOGS/devshim-gate.log" &&
    grep -q '^PASS .env.rb sets BILLING_RATES_EXTRA_DIR' "$LOGS/devshim-gate.log"; } ||
    fail "devshim: m2-gate g1 (tmux) gave $rc, see $LOGS/devshim-gate.log"
  say "devshim: m2-gate g1 picks tmux mode and checks .env.rb"
  say "devshim: ok"
}

# m2-gate on a packaged control plane: systemd mode is detected, G1
# judges the units and reads BILLING_RATES_EXTRA_DIR through
# ubicloud-admin, and the respirate log comes from the journal.
sc_gate_journal() {
  local rc out first fns who
  boot_cp gatej
  rc=0
  out=$(dx gatej bash -c 'cd / && bash /art/m2-gate.sh g1' 2>&1) || rc=$?
  printf '%s\n' "$out" >"$LOGS/gatej-root.log"
  { [[ $rc == 0 ]] && grep -q '^== G1 .*(systemd)' <<<"$out" &&
    grep -q '^PASS ubicloud-web.service is running' <<<"$out" &&
    grep -q '^PASS ubicloud-respirate.service is running' <<<"$out" &&
    grep -q '^INFO ubicloud-monitor.service is not running' <<<"$out" &&
    grep -q '^PASS /etc/ubicloud/env sets BILLING_RATES_EXTRA_DIR to /var/lib/ubicloud/billing_rates.d, a directory' <<<"$out"; } ||
    fail "gate-journal: g1 as root gave $rc, see $LOGS/gatej-root.log"
  rc=0
  out=$(dx gatej bash -c 'cd / && GATE_EXPECT_MONITOR=1 bash /art/m2-gate.sh g1' 2>&1) || rc=$?
  { [[ $rc == 1 ]] && grep -q '^FAIL ubicloud-monitor.service is not running' <<<"$out"; } ||
    fail "gate-journal: GATE_EXPECT_MONITOR=1 without monitor gave $rc: $out"
  # ubuntu (group adm, no sudo here) cannot read the env file.
  rc=0
  out=$(dx gatej runuser -u ubuntu -- bash -c 'cd / && bash /art/m2-gate.sh g1' 2>&1) || rc=$?
  { [[ $rc == 1 ]] && grep -q '^FAIL .*run the gate as root or with sudo -n' <<<"$out"; } ||
    fail "gate-journal: g1 as ubuntu gave $rc: $out"
  # The services cannot use a directory that root can: under /home
  # (ProtectHome=yes), also through a symlink, or one user ubicloud
  # cannot write.
  dx gatej bash -c 'install -d -o ubicloud -g ubicloud /home/ubuntu/rates &&
    ln -sfn /home/ubuntu/rates /var/lib/ubicloud/rates-link && install -d -m 0700 /srv/rates-root'
  for who in /home/ubuntu/rates:'under /home, which ProtectHome=yes hides' \
    /var/lib/ubicloud/rates-link:'under /home, which ProtectHome=yes hides' \
    /srv/rates-root:'which is not a directory user ubicloud can read and write'; do
    printf '%s' "${who%%:*}" | dx gatej ubicloud-admin env set BILLING_RATES_EXTRA_DIR --no-restart >/dev/null ||
      fail "gate-journal: env set BILLING_RATES_EXTRA_DIR ${who%%:*}"
    rc=0
    out=$(dx gatej bash -c 'cd / && bash /art/m2-gate.sh g1' 2>&1) || rc=$?
    { [[ $rc == 1 ]] && grep -qF "FAIL /etc/ubicloud/env sets BILLING_RATES_EXTRA_DIR to ${who%%:*}, " <<<"$out" &&
      grep -qF "${who#*:}" <<<"$out"; } ||
      fail "gate-journal: g1 with BILLING_RATES_EXTRA_DIR=${who%%:*} gave $rc: $out"
  done
  printf '%s' /var/lib/ubicloud/billing_rates.d | dx gatej ubicloud-admin env set BILLING_RATES_EXTRA_DIR --no-restart >/dev/null
  dx gatej ubicloud-admin env unset BILLING_RATES_EXTRA_DIR --no-restart >/dev/null
  rc=0
  out=$(dx gatej bash -c 'cd / && bash /art/m2-gate.sh g1' 2>&1) || rc=$?
  { [[ $rc == 1 ]] && grep -q '^FAIL /etc/ubicloud/env does not set BILLING_RATES_EXTRA_DIR' <<<"$out"; } ||
    fail "gate-journal: g1 without the key gave $rc: $out"
  say "gate-journal: g1 detects systemd, judges the units, reads BILLING_RATES_EXTRA_DIR through ubicloud-admin, fails a directory under /home (also through a symlink) or one user ubicloud cannot write, and fails without the key or without root"

  # respirate_log, as m2-gate defines it, against the journal.
  fns=$(sed -n '/^GATE_SERVICES=/,/^esac/p; /^as_root()/,/^}/p; /^respirate_log()/,/^}/p; /^probe_verdict()/,/^}/p' "$WT/scripts/byoh/verify/m2-gate.sh")
  first=$(dx gatej bash -c 'journalctl -q -u ubicloud-respirate.service --no-pager -o cat | head -1')
  [[ -n $first ]] || fail "gate-journal: the respirate journal is empty"
  dx gatej useradd -M -s /bin/bash gatenoadm 2>/dev/null || true
  for who in root ubuntu gatenoadm; do
    rc=0
    # shellcheck disable=SC2016 # expanded by the container's bash
    out=$(dx gatej runuser -u "$who" -- bash -c "set -euo pipefail; cd /; $fns"$'\n''l=$(respirate_log); head -1 <<<"$l"' 2>/dev/null) || rc=$?
    case $who in
      root | ubuntu) [[ $rc == 0 && $out == "$first" ]] || fail "gate-journal: respirate_log as $who gave $rc: $out" ;;
      gatenoadm) [[ $rc != 0 && -z $out ]] || fail "gate-journal: respirate_log as a user without journal access gave $rc: $out" ;;
    esac
  done
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx gatej bash -c "cd /; GATE_SERVICES=tmux; $fns"$'\n''echo "$GATE_RESPIRATE_LOG"')
  [[ $out == /tmp/respirate.log ]] || fail "gate-journal: GATE_SERVICES=tmux reads $out"
  say "gate-journal: the respirate log is the journal under systemd (root and group adm read it; others fail) and /tmp/respirate.log under tmux"

  # probe_verdict, which g7 judges VM-B by: on the journal, which has no
  # probe line, and on a file whose matching line comes first and is
  # followed by far more output than a pipe buffer holds.
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx gatej bash -c "set -euo pipefail; cd /; $fns"$'\n''probe_verdict vmnotthere')
  [[ $out == missing ]] || fail "gate-journal: probe_verdict on the journal gave $out"
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx gatej bash -c 'f=/tmp/probe.log; {
      echo "x byoh netns probe ok {\"vm_ubid\":\"vmfirst\"}"
      for i in $(seq 1 30000); do echo "x byoh netns probe ok {\"vm_ubid\":\"vmother$i\"}"; done
      echo "x byoh netns probe gave up {\"vm_ubid\":\"vmbad\"}"
      echo "x byoh netns probe ok {\"vm_ubid\":\"vmbad\"}"
      echo "x some other line {\"vm_ubid\":\"vmquiet\"}"
    } >$f'
  for who in vmfirst:ok vmbad:gave-up vmquiet:missing; do
    rc=0
    # shellcheck disable=SC2016 # expanded by the container's bash
    out=$(dx gatej bash -c "set -euo pipefail; cd /; GATE_SERVICES=tmux GATE_RESPIRATE_LOG=/tmp/probe.log; $fns"$'\n'"probe_verdict ${who%%:*}") || rc=$?
    [[ $rc == 0 && $out == "${who#*:}" ]] || fail "gate-journal: probe_verdict ${who%%:*} gave $rc: $out"
  done
  rc=0
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx gatej bash -c "set -euo pipefail; cd /; GATE_SERVICES=tmux GATE_RESPIRATE_LOG=/tmp/no-such.log; $fns"$'\n''probe_verdict vmfirst') || rc=$?
  [[ $rc == 1 && -z $out ]] || fail "gate-journal: probe_verdict on a missing log gave $rc: $out"
  say "gate-journal: probe_verdict finds ok, gave-up (which wins) and missing in a 30000-line log, reads the journal, and returns 1 on a missing log"

  # Installed but neither active nor enabled (install.sh --no-start
  # before a migration's cutover, or after its rollback) is tmux mode:
  # the development processes and .env.rb are judged. Enabled is
  # systemd again, even while stopped.
  dx gatej systemctl disable --now -q ubicloud.target
  dx gatej bash -c 'install -d /root/devcp && echo "ENV[\"BILLING_RATES_EXTRA_DIR\"] ||= \"/root/rates\"" >/root/devcp/.env.rb'
  docker exec -d ubi-m3-gatej bash -c 'exec -a puma sleep 600'
  docker exec -d ubi-m3-gatej bash -c 'exec -a bin/respirate sleep 600'
  wait_for 10 dx gatej pgrep -f bin/respirate >/dev/null || fail "gate-journal: the stand-in processes did not start"
  rc=0
  out=$(dx gatej bash -c 'cd /root/devcp && bash /art/m2-gate.sh g1' 2>&1) || rc=$?
  printf '%s\n' "$out" >"$LOGS/gatej-disabled.log"
  { [[ $rc == 0 ]] && grep -q '^== G1 .*(tmux)' <<<"$out" && grep -q '^PASS puma is running' <<<"$out" &&
    grep -q '^PASS bin/respirate is running' <<<"$out" && grep -q '^PASS .env.rb sets BILLING_RATES_EXTRA_DIR' <<<"$out"; } ||
    fail "gate-journal: g1 with disabled units and the tmux services gave $rc, see $LOGS/gatej-disabled.log"
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx gatej bash -c "cd /; $fns"$'\n''echo "$GATE_SERVICES $GATE_RESPIRATE_LOG"')
  [[ $out == "tmux /tmp/respirate.log" ]] || fail "gate-journal: disabled units give $out"
  dx gatej systemctl enable -q ubicloud.target
  # shellcheck disable=SC2016 # expanded by the container's bash
  out=$(dx gatej bash -c "cd /; $fns"$'\n''echo "$GATE_SERVICES $GATE_RESPIRATE_LOG"')
  [[ $out == "systemd journal" ]] || fail "gate-journal: an enabled, stopped target gives $out"
  dx gatej pkill -f '^(puma|bin/respirate) 600$' || true
  say "gate-journal: with the units installed but disabled the gate judges the tmux processes and .env.rb, and reads /tmp/respirate.log; enabled, it is systemd again"
  say "gate-journal: ok"
}

# --- live migration from the development bootstrap (WP9) ------------------------------

# R0 is the development control plane's revision. The live one is
# fc693b1e0 unless the operator records another; aca70df27
# (aws-mumbai-working-v1) is the pre-M1 schema with the 14-digit
# generic-provider migration and Ruby 4.0.2.
MIG_R0=${UBI_M3_R0:-fc693b1e0}
MIG_PREM1=${UBI_M3_PREM1:-aca70df27}
MIG_URL=https://cp.example.test
MIG_SCRIPT=/home/ubuntu/ubicloud-m3/scripts/byoh/migrate-from-dev.sh
MIG_FLAGS=(--dev-user ubuntu --version t1 --source-git /home/ubuntu/ubicloud-m3 --ref HEAD
  --admin-email ops@example.test --backup-recipient-file /root/backup-recipient --skip-check clock)

# mig NAME LOG PHASE [ARGS...]: migrate-from-dev.sh PHASE as root, output
# to $LOGS/LOG; prints the exit status.
mig() {
  local name=$1 log=$2 rc=0
  shift 2
  dx "$name" bash -c 'cd / && bash "$@"' _ "$MIG_SCRIPT" "$@" >"$LOGS/$log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}

# dev_sh NAME RUBY CMD: CMD as ubuntu in ~/ubicloud with the development
# PATH (the bootstrap's mise Ruby) and RACK_ENV=development.
dev_sh() {
  as_ubuntu "$1" "export PATH=\$HOME/.local/bin:\$HOME/.local/share/mise/installs/ruby/$2/bin:\$PATH RACK_ENV=development && cd ~/ubicloud && $3"
}

# The tmux commands of the development bootstrap (the same ones rollback
# prints), run as ubuntu.
r0_tmux_start() {
  local p="/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/$2/bin"
  as_ubuntu "$1" "tmux new-session -d -s puma \"cd /home/ubuntu/ubicloud && export PATH=$p:\\\$PATH && RACK_ENV=development bundle exec puma -C puma_config.rb > /tmp/puma.log 2> /tmp/puma.err\" &&
    tmux new-session -d -s respirate \"cd /home/ubuntu/ubicloud && export PATH=$p:\\\$PATH && RACK_ENV=development bundle exec bin/respirate > /tmp/respirate.log 2> /tmp/respirate.err\""
}

dev_pids() { dx "$1" bash -c "ps -u ubuntu -o pid=,comm=,args= | awk '\$2 !~ /^tmux/ && (\$0 ~ /bin\\/respirate/ || \$0 ~ /puma/) { print \$1 }'"; }
respirate_up() { ! respirate_gone "$1"; }
respirate_gone() { [[ -z $(dx "$1" bash -c "ps -u ubuntu -o comm=,args= | awk '\$1 !~ /^tmux/ && /bin\\/respirate/'") ]]; }

# Stops the development control plane as the runbook says: respirate
# first with C-c, waiting for it to exit (never a kill), then puma.
r0_tmux_stop() {
  local t
  as_ubuntu "$1" 'tmux send-keys -t respirate C-c' || fail "$1: no tmux session respirate"
  t=$(wait_for 150 respirate_gone "$1") || fail "$1: respirate did not exit within 150 s of C-c"
  as_ubuntu "$1" 'tmux kill-session -t puma; tmux kill-session -t respirate 2>/dev/null; true'
  wait_for 30 bash -c "[[ -z \$(docker exec ubi-m3-$1 ss -Htln 'sport = :3000') ]]" >/dev/null || fail "$1: port 3000 still in use after the tmux stop"
  say "$1: development respirate exited ${t}s after C-c; puma stopped"
}

dev_web_up() { [[ $(dx "$1" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/login) == 200 ]]; }

# A stand-in for the live cloudflared.service: its token is on the
# command line, and, like a tunnel connector, it keeps a connection open
# to the origin in /etc/cf-origin, so preflight can see where it points.
mig_cloudflared() {
  dx "$1" bash -c "printf '%s\n' '$2' >/etc/cf-origin && cat >/usr/local/bin/cloudflared <<'EOF'
#!/bin/bash
# harness stand-in for cloudflared: holds connections to the origin
while :; do
  exec 3<>\"/dev/tcp/\$(cat /etc/cf-origin)/3000\" 2>/dev/null || true
  sleep 2
  exec 3>&- || true
done
EOF
chmod 0755 /usr/local/bin/cloudflared && cat >/etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=cloudflared (harness stand-in)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token dummy-live-token-0123456789
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable -q cloudflared && systemctl restart cloudflared"
}

# mig_setup NAME R0 RUBY: a development control plane at R0 on
# ubi-m3-tools, seeded and running in tmux:
# - ~ubuntu/ubicloud: a git checkout of R0 (one commit), set up by its
#   own bootstrap, with BASE_URL, BILLING_RATES_EXTRA_DIR, a BMC password
#   variable, DB_POOL_WEB and IP_FROM_HEADER in .env.rb
# - ~ubuntu/ubicloud-m3: a clone of it with this working tree committed
#   on top (the runbook's separate clone)
# - an account, a host registered by bin/register-byoh-host whose
#   Sshable reaches ubi-m3-sshd and whose BMC names the password
#   variable, its strand parked at wait for a day
# - cloudflared.service (stand-in) pointing at the container's own
#   address
mig_setup() {
  local name=$1 r0=$2 ruby=$3 t
  stage_art
  src_tarball
  git -C "$WT" archive -o "$ART/r0.tgz" "$r0"
  chmod a+r "$ART/r0.tgz"
  start_sys "$name" ubi-m3-tools
  backup_key "$name"
  dx "$name" bash -c 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-ubuntu && chmod 0440 /etc/sudoers.d/90-ubuntu'
  as_ubuntu "$name" "git config --global user.email harness@example.test && git config --global user.name harness &&
    git config --global init.defaultBranch main && mkdir ubicloud && tar -xzf /art/r0.tgz -C ubicloud &&
    cd ubicloud && git init -q && git add -A && git commit -qm 'R0 $r0' && cd ~ && git clone -q ubicloud ubicloud-m3 &&
    cd ubicloud-m3 && git rm -rq . && tar -xzf /art/src.tgz && git add -A && git commit -qm M3" ||
    fail "$name: cannot build the checkouts"
  t=$(timed as_ubuntu "$name" "UBI_BASE_URL=$MIG_URL bash ~/ubicloud/scripts/byoh/bootstrap-ctrl-plane.sh >/tmp/dev-boot.log 2>&1") || {
    dx "$name" cat /tmp/dev-boot.log >"$LOGS/$name-dev-boot.log"
    fail "$name: the R0 bootstrap failed, see $LOGS/$name-dev-boot.log"
  }
  dx "$name" cat /tmp/dev-boot.log >"$LOGS/$name-dev-boot.log"
  say "$name: R0 $r0 bootstrapped in ${t}s"
  as_ubuntu "$name" "mkdir -p ~/ubicloud-billing-rates.d && cat >>~/ubicloud/.env.rb <<'EOF'
ENV[\"BASE_URL\"] ||= \"$MIG_URL\"
ENV[\"BILLING_RATES_EXTRA_DIR\"] ||= \"/home/ubuntu/ubicloud-billing-rates.d\"
ENV[\"BYOH_BMC_PASS_TEST\"] ||= \"bmc-pass-harness-0123\"
ENV[\"DB_POOL_WEB\"] ||= \"20\"
ENV[\"IP_FROM_HEADER\"] ||= \"CF-Connecting-IP\"
EOF"
  start_sshd
  # ubi-m3-tools has no ssh client; the sshd container makes the key.
  docker exec ubi-m3-sshd bash -c 'ssh-keygen -q -t ed25519 -N "" -f /root/byoh_key && cat /root/byoh_key.pub >>/root/.ssh/authorized_keys' ||
    fail "$name: ssh-keygen"
  docker exec ubi-m3-sshd cat /root/byoh_key | dx "$name" bash -c 'install -m 0600 -o ubuntu -g ubuntu /dev/stdin /home/ubuntu/byoh_key' ||
    fail "$name: cannot copy the host key"
  local reg="bin/register-byoh-host --main-ip $SSHD_IP --ssh-key /home/ubuntu/byoh_key --bmc-endpoint https://192.0.2.10 --bmc-user admin --bmc-pass-env BYOH_BMC_PASS_TEST --default-boot-image ubuntu-noble --yes"
  if [[ $r0 == "$MIG_PREM1" ]]; then
    reg+=" --location byoh --routed-network 10.250.0.0/30"
  else
    dev_sh "$name" "$ruby" "bundle exec bin/byoh-location create --name mig-loc --rates-from hetzner-fsn1" >"$LOGS/$name-seed.log" 2>&1 ||
      fail "$name: byoh-location create failed, see $LOGS/$name-seed.log"
    reg+=" --location mig-loc"
  fi
  dev_sh "$name" "$ruby" "bundle exec $reg" >>"$LOGS/$name-seed.log" 2>&1 || fail "$name: register-byoh-host failed, see $LOGS/$name-seed.log"
  # The strand waits instead of bootstrapping the stand-in host, whose
  # sshd has only root (bootstrap_rhizome would create user rhizome).
  dx "$name" runuser -u postgres -- psql -XtAq -d clover_test \
    -c "UPDATE strand SET label = 'wait', schedule = now() + interval '1 day', try = 0 WHERE prog = 'Vm::HostNexus'" \
    -c "UPDATE sshable SET unix_user = 'root'" >/dev/null || fail "$name: cannot park the host strand"
  # shellcheck disable=SC2016 # Ruby code
  dev_sh "$name" "$ruby" "bundle exec ruby --enable-frozen-string-literal -e 'require_relative \"loader\"; require \"argon2\"
a = Account.create(email: ARGV[0], status_id: 2)
DB[:account_password_hashes].insert(id: a.id, password_hash: Argon2::Password.new(secret: Config.clover_session_secret).create(ARGV[1]))
a.create_project_with_default_policy(\"harness\")' $EMAIL $PASSWORD" >>"$LOGS/$name-seed.log" 2>&1 ||
    fail "$name: account create failed, see $LOGS/$name-seed.log"
  r0_tmux_start "$name" "$ruby" || fail "$name: the R0 tmux commands failed"
  t=$(wait_for 180 dev_web_up "$name") || fail "$name: the development puma did not answer within 180 s"
  local out
  out=$(login "$name") || fail "$name: development login failed"
  [[ $out == "302 "*/after-login ]] || fail "$name: development login: $out"
  # shellcheck disable=SC2016 # Ruby code
  out=$(dev_sh "$name" "$ruby" "bundle exec ruby --enable-frozen-string-literal -e 'require_relative \"loader\"; puts Sshable.first.cmd(\"echo ok\")'" 2>&1 | tail -1) || true
  [[ $out == ok ]] || fail "$name: the development Sshable#cmd printed '$out'"
  mig_cloudflared "$name" "$(dx "$name" hostname -I | awk '{ print $1 }')"
  say "$name: development control plane at R0 runs in tmux (web after ${t}s); login and Sshable#cmd work; host, account and BMC variable seeded"
}

# Every key .env.rb sets is in /etc/ubicloud/env with the same value,
# except the ones the move rewrites or drops. Compared in the container;
# only key names come out.
mig_env_matches() {
  dx "$1" bash -s <<'EOF'
set -euo pipefail
envrb=/home/ubuntu/ubicloud/.env.rb
bad=""
for k in $(sed -n 's/^ENV\["\([A-Z0-9_]*\)"\] ||= ".*"$/\1/p' "$envrb" | sort -u); do
  # The first ||= wins.
  v=$(sed -n "s/^ENV\[\"$k\"\] ||= \"\(.*\)\"\$/\1/p" "$envrb" | head -1)
  case $k in
    CLOVER_DATABASE_URL) grep -qx "CLOVER_DATABASE_URL='postgres:///ubicloud?user=ubicloud'" /etc/ubicloud/env || bad+=" $k" ;;
    RACK_ENV) grep -qx "RACK_ENV='development'" /etc/ubicloud/env || bad+=" $k" ;;
    BILLING_RATES_EXTRA_DIR) grep -qx "BILLING_RATES_EXTRA_DIR='/var/lib/ubicloud/billing_rates.d'" /etc/ubicloud/env || bad+=" $k" ;;
    *) grep -qxF "$k='$v'" /etc/ubicloud/env || bad+=" $k" ;;
  esac
done
[[ -z $bad ]] || { echo "differ:$bad"; exit 1; }
echo "keys: $(sed -n 's/^ENV\["\([A-Z0-9_]*\)"\] ||= ".*"$/\1/p' "$envrb" | sort -u | tr '\n' ' ')"
EOF
}

# mig_cutover NAME RUBY PREM1: preflight (a refusal first), install,
# copy-db (refused while tmux runs), the tmux stop, copy-db, a second
# copy-db (refused), start, and the checks of a moved control plane.
mig_cutover() {
  local name=$1 ruby=$2 prem1=$3 rc out ubid t
  rc=$(mig "$name" "$name-preflight-origin.log" preflight "${MIG_FLAGS[@]}")
  { [[ $rc == 1 ]] && grep -q '^fatal   cloudflared: the tunnel reaches puma at 172\.' "$LOGS/$name-preflight-origin.log"; } ||
    fail "$name: preflight with the tunnel origin on the container address gave $rc, see $LOGS/$name-preflight-origin.log"
  dx "$name" bash -c 'echo 127.0.0.1 >/etc/cf-origin && systemctl restart cloudflared'
  rc=$(mig "$name" "$name-preflight.log" preflight "${MIG_FLAGS[@]}")
  [[ $rc == 0 ]] || fail "$name: preflight gave $rc, see $LOGS/$name-preflight.log"
  grep -q '^ok      cloudflared: the tunnel.s origin is 127.0.0.1:3000' "$LOGS/$name-preflight.log" || fail "$name: preflight did not see the tunnel origin"
  grep -q '^notice  cloudflared: token on the command line: yes' "$LOGS/$name-preflight.log" || fail "$name: preflight did not report the argv token"
  grep -q '^ok      bmc: BYOH_BMC_PASS_TEST comes from .env.rb' "$LOGS/$name-preflight.log" || fail "$name: preflight did not find the BMC variable"
  grep -q 'dummy-live-token\|bmc-pass-harness' "$LOGS/$name-preflight.log" && fail "$name: preflight printed a secret"
  if ((prem1)); then
    grep -q '^notice  schema: clover_test applied 20260412000000_add_generic_provider.rb' "$LOGS/$name-preflight.log" || fail "$name: preflight did not note the renamed migration"
    grep -q '^notice  schema: copy-db runs [1-9][0-9]* pending migration' "$LOGS/$name-preflight.log" || fail "$name: preflight found no pending migrations"
    grep -q '^notice  rhizome: rhizome/ changed since R0' "$LOGS/$name-preflight.log" || fail "$name: preflight missed the rhizome changes"
  else
    grep -q '^ok      schema: no pending migrations' "$LOGS/$name-preflight.log" || fail "$name: preflight found pending migrations at R0"
    grep -q '^ok      rhizome: unchanged since R0' "$LOGS/$name-preflight.log" || fail "$name: preflight thinks rhizome changed"
  fi
  say "$name: preflight refuses a tunnel origin off loopback, then passes: $(grep -c '^warn' "$LOGS/$name-preflight.log") warn; $(grep '^ok      env: .env.rb sets' "$LOGS/$name-preflight.log")"

  rc=$(mig "$name" "$name-install.log" install)
  [[ $rc == 0 ]] || fail "$name: install gave $rc, see $LOGS/$name-install.log"
  grep -q 'dummy-live-token\|bmc-pass-harness' "$LOGS/$name-install.log" && fail "$name: install printed a secret"
  out=$(mig_env_matches "$name") || fail "$name: /etc/ubicloud/env does not hold .env.rb's keys: $out"
  say "$name: install: $out are all in /etc/ubicloud/env, with the same values but the rewritten RACK_ENV, BILLING_RATES_EXTRA_DIR and database URL"
  dx "$name" grep -qx "DB_POOL_WEB='20'" /etc/ubicloud/env || fail "$name: the imported DB_POOL_WEB did not take precedence"
  dx "$name" grep -qx "IP_FROM_HEADER='CF-Connecting-IP'" /etc/ubicloud/env || fail "$name: IP_FROM_HEADER"
  [[ $(dx "$name" stat -c '%U:%G %a' /etc/ubicloud/env) == "root:root 600" ]] || fail "$name: the env file is not root 0600"
  if ((prem1 == 0)); then
    [[ -n $(dx "$name" find /var/lib/ubicloud/billing_rates.d -name '*.yml') ]] || fail "$name: the billing rates were not copied"
  fi
  [[ $(dx "$name" systemctl is-enabled ubicloud.target || true) != enabled && $(dx "$name" systemctl is-active ubicloud-web || true) != active ]] ||
    fail "$name: install started the packaged control plane"
  dev_web_up "$name" || fail "$name: the development puma stopped answering during install"

  rc=$(mig "$name" "$name-copy-busy.log" copy-db)
  { [[ $rc == 2 ]] && grep -q 'the development control plane still runs' "$LOGS/$name-copy-busy.log"; } ||
    fail "$name: copy-db with tmux running gave $rc, see $LOGS/$name-copy-busy.log"
  r0_tmux_stop "$name"
  if ((prem1 == 0)); then
    # The pristine database install.sh migrated becomes copy-db's
    # reference. A column grant only it has is an object the copy lacks:
    # the comparison must fail, and a rerun must clean up after it
    # (the unfinished copy, the reference) and pass.
    psql_q "$name" "GRANT SELECT (id) ON strand TO ubicloud_password" >/dev/null
    rc=$(mig "$name" "$name-copy-refonly.log" copy-db)
    { [[ $rc == 1 ]] && grep -q '^  only in the reference: col|strand.id: acl=' "$LOGS/$name-copy-refonly.log" &&
      grep -q '^fail    copy-db: owners or privileges of the copy differ from the reference' "$LOGS/$name-copy-refonly.log" &&
      grep -q 'copy-db stopped (exit 1); clover_test accepts no connections' "$LOGS/$name-copy-refonly.log"; } ||
      fail "$name: copy-db with an object only in the reference gave $rc, see $LOGS/$name-copy-refonly.log"
    [[ $(db_names "$name") == "ubicloud ubicloud_ref" &&
      $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = 'ubicloud'") == "migrating-from clover_test "* ]] ||
      fail "$name: after the failed copy-db: $(db_names "$name")"
    say "$name: copy-db fails on an object only in the reference (exit 1, unfinished copy and reference left, clover_test off)"
  fi
  rc=$(mig "$name" "$name-copy.log" copy-db)
  [[ $rc == 0 ]] || fail "$name: copy-db gave $rc, see $LOGS/$name-copy.log"
  if ((prem1 == 0)); then
    { grep -q '^notice  copy-db: dropped ubicloud_ref, left by an earlier copy-db' "$LOGS/$name-copy.log" &&
      grep -q '^notice  copy-db: dropped ubicloud, the copy of an earlier copy-db that did not finish' "$LOGS/$name-copy.log"; } ||
      fail "$name: the rerun of copy-db did not clean up the failed run"
  fi
  for out in '^ok      copy-db: restored as ubicloud_restorer; row counts equal clover_test' \
    '^ok      copy-db: owners, privileges and SECURITY DEFINER settings equal the reference' \
    '^ok      copy-db: password hashes isolated' '^ok      copy-db: schema_migrations '; do
    grep -q "$out" "$LOGS/$name-copy.log" || fail "$name: copy-db did not report: $out"
  done
  [[ $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT datallowconn FROM pg_database WHERE datname = 'clover_test'") == f ]] ||
    fail "$name: clover_test still accepts connections"
  [[ $(db_names "$name") == ubicloud ]] || fail "$name: databases after copy-db: $(db_names "$name")"
  if ((prem1)); then
    grep -q '^changed copy-db: renamed 20260412000000_add_generic_provider.rb' "$LOGS/$name-copy.log" || fail "$name: copy-db did not rename the migration"
    [[ $(psql_q "$name" "SELECT count(*) FROM schema_migrations WHERE filename LIKE '20260412%generic%'") == 1 &&
      $(dx "$name" runuser -u postgres -- psql -XtAq -d postgres -c "SELECT 1") == 1 ]] || fail "$name: the renamed migration"
  fi
  say "$name: copy-db: $(grep -E '^ok      copy-db: (migrations|owners|schema_migrations)' "$LOGS/$name-copy.log" | cut -c9- | tr '\n' ';')"
  rc=$(mig "$name" "$name-copy-again.log" copy-db)
  { [[ $rc == 2 ]] && grep -q 'holds a finished copy' "$LOGS/$name-copy-again.log"; } ||
    fail "$name: a second copy-db gave $rc, see $LOGS/$name-copy-again.log"

  rc=$(mig "$name" "$name-start.log" start)
  [[ $rc == 0 ]] || fail "$name: start gave $rc, see $LOGS/$name-start.log"
  grep -q "^ok      start: Sshable .* ($SSHD_IP) runs a command" "$LOGS/$name-start.log" || fail "$name: start did not run the Sshable"
  if ((prem1)); then
    grep -q '^changed start: install_rhizome started for vh' "$LOGS/$name-start.log" || fail "$name: start did not run install_rhizome"
  else
    grep -q 'install_rhizome' "$LOGS/$name-start.log" && fail "$name: start ran install_rhizome with rhizome unchanged"
  fi
  grep -q '^fail    postgres: pg_hba.conf line(s) .* use trust' "$LOGS/$name-start.log" || fail "$name: status did not report the bootstrap's trust rules"
  # shellcheck disable=SC2016 # expanded by the container's bash
  [[ -z $(dx "$name" bash -c 'ss -Htln "sport = :3000" | awk "{ print \$4 }" | grep -v "^127.0.0.1:3000$"') ]] ||
    fail "$name: something listens on a non-loopback address of port 3000"
  out=$(login "$name") || fail "$name: login on the packaged web failed"
  [[ $out == "302 "*/after-login ]] || fail "$name: login on the packaged web: $out"
  sshable_ok "$name" || fail "$name: Sshable#cmd on the packaged control plane"
  ubid=$(adm "$name" console -e 'puts VmHost.first.ubid' 2>/dev/null | grep '^vh' | tail -1)
  adm "$name" console -e 'VmHost.first.incr_configure_metrics' >/dev/null 2>&1 || fail "$name: incr_configure_metrics"
  # shellcheck disable=SC2016 # expanded by the container's bash
  t=$(wait_for 60 dx "$name" bash -c "journalctl -u ubicloud-respirate --no-pager -o cat | grep -q '\"strand\":\"$ubid\"'") ||
    fail "$name: the respirate journal does not show the host strand $ubid"
  # configure_metrics fails on the stand-in host (no systemd there); its
  # retries stop for a day, and rollback lists the strand at that label.
  psql_q "$name" "UPDATE strand SET schedule = now() + interval '1 day', try = 0 WHERE prog = 'Vm::HostNexus'" >/dev/null
  say "$name: start: login with the development account, Sshable#cmd, and the host strand $ubid in the respirate journal after ${t}s"
}

sc_migrate() {
  local name=mig ruby=4.0.7 rc out t cmds
  mig_setup "$name" "$MIG_R0" "$ruby"
  mig_cutover "$name" "$ruby" 0

  # Rollback to R0, across a reboot.
  rc=$(mig "$name" "$name-rollback.log" rollback)
  [[ $rc == 0 ]] || fail "$name: rollback gave $rc, see $LOGS/$name-rollback.log"
  grep -q '^> .* Vm::HostNexus configure_metrics' "$LOGS/$name-rollback.log" || fail "$name: rollback did not list the host strand's move"
  grep -q '^warn    rollback: preflight took the BMC' "$LOGS/$name-rollback.log" && fail "$name: rollback warned about a BMC variable .env.rb sets"
  [[ $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = 'ubicloud'") == "rolled-back-from clover_test "* ]] ||
    fail "$name: rollback did not mark the copy rolled back"
  rc=$(mig "$name" "$name-start-rolledback.log" start)
  { [[ $rc == 2 ]] && grep -q 'was rolled back' "$LOGS/$name-start-rolledback.log"; } ||
    fail "$name: start after a rollback gave $rc, see $LOGS/$name-start-rolledback.log"
  [[ $(dx "$name" systemctl is-active ubicloud-web || true) != active ]] || fail "$name: the refused start started web"
  say "$name: rollback marks the copy rolled back; start refuses it (exit 2)"
  docker restart -t 60 "ubi-m3-$name" >/dev/null
  wait_booted "$name"
  [[ $(dx "$name" systemctl is-enabled ubicloud.target || true) == disabled && $(dx "$name" systemctl is-active ubicloud-web || true) == inactive ]] ||
    fail "$name: ubicloud.target came back after the reboot"
  cmds=$(sed -n '/^--- R0 commands/,/^--- end ---/p' "$LOGS/$name-rollback.log" | sed '1d;$d')
  [[ $(wc -l <<<"$cmds") == 2 ]] || fail "$name: rollback printed no R0 commands"
  printf '%s\n' "$cmds" | dx "$name" runuser -u ubuntu -- env -i HOME=/home/ubuntu USER=ubuntu LANG=C.UTF-8 PATH=/usr/bin:/bin bash -s ||
    fail "$name: the R0 commands failed"
  t=$(wait_for 180 dev_web_up "$name") || fail "$name: the development puma did not come back"
  out=$(login "$name") || fail "$name: development login after rollback failed"
  [[ $out == "302 "*/after-login ]] || fail "$name: development login after rollback: $out"
  # shellcheck disable=SC2016 # Ruby code
  out=$(dev_sh "$name" "$ruby" "bundle exec ruby --enable-frozen-string-literal -e 'require_relative \"loader\"; puts Sshable.first.cmd(\"echo ok\")'" 2>&1 | tail -1) || true
  [[ $out == ok ]] || fail "$name: the development Sshable#cmd after rollback printed '$out'"
  say "$name: rollback: target disabled across docker restart; the printed R0 commands serve clover_test again (web after ${t}s), login and Sshable#cmd work"

  # A .env.rb that fails to load: the class and line, never the value.
  as_ubuntu "$name" "echo 'ENV[\"HARNESS_BAD\"] = harnessleak0123' >>~/ubicloud/.env.rb"
  rc=$(mig "$name" "$name-preflight-badenv.log" preflight "${MIG_FLAGS[@]}")
  { [[ $rc == 1 ]] && grep -qE '^fatal   env: loading /home/ubuntu/ubicloud/.env.rb as ubuntu failed: NameError at line [0-9]+$' "$LOGS/$name-preflight-badenv.log"; } ||
    fail "$name: preflight with a broken .env.rb gave $rc, see $LOGS/$name-preflight-badenv.log"
  grep -q harnessleak0123 "$LOGS/$name-preflight-badenv.log" && fail "$name: preflight printed a token of the broken .env.rb"
  as_ubuntu "$name" "sed -i '/HARNESS_BAD/d' ~/ubicloud/.env.rb"
  say "$name: a .env.rb that does not load is reported as NameError at its line, without the token"

  # MAIL_FROM with a display name: install.sh would refuse it after the
  # env file is written, so preflight is fatal and names --mail-from.
  as_ubuntu "$name" "echo 'ENV[\"MAIL_FROM\"] = \"Ubicloud <ops@example.test>\"' >>~/ubicloud/.env.rb"
  rc=$(mig "$name" "$name-preflight-mailfrom.log" preflight "${MIG_FLAGS[@]}")
  { [[ $rc == 1 ]] && grep -qE '^fatal   env: MAIL_FROM \(from .env.rb\) is not a bare email address.*pass --mail-from' "$LOGS/$name-preflight-mailfrom.log"; } ||
    fail "$name: preflight with MAIL_FROM 'Name <addr>' gave $rc, see $LOGS/$name-preflight-mailfrom.log"
  as_ubuntu "$name" "sed -i '/MAIL_FROM/d' ~/ubicloud/.env.rb"
  say "$name: a .env.rb MAIL_FROM with a display name is fatal at preflight"

  # The BMC password only in the running respirate's environment: a
  # preflight warn, and a rollback warning naming it.
  as_ubuntu "$name" "sed -i '/BYOH_BMC_PASS_TEST/d' ~/ubicloud/.env.rb && tmux send-keys -t respirate C-c" || fail "$name: no tmux session respirate"
  wait_for 150 respirate_gone "$name" >/dev/null || fail "$name: respirate did not exit within 150 s of C-c"
  as_ubuntu "$name" 'tmux kill-session -t respirate 2>/dev/null; true'
  local p="/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/$ruby/bin"
  as_ubuntu "$name" "tmux new-session -d -s respirate \"cd /home/ubuntu/ubicloud && export PATH=$p:\\\$PATH BYOH_BMC_PASS_TEST=bmc-pass-harness-0123 && RACK_ENV=development bundle exec bin/respirate > /tmp/respirate.log 2> /tmp/respirate.err\"" ||
    fail "$name: cannot start respirate with the BMC variable"
  wait_for 60 respirate_up "$name" >/dev/null || fail "$name: respirate did not start"
  rc=$(mig "$name" "$name-preflight-bmcproc.log" preflight "${MIG_FLAGS[@]}")
  { [[ $rc == 0 ]] && grep -q '^warn    bmc: BYOH_BMC_PASS_TEST comes from the environment of the running development respirate' "$LOGS/$name-preflight-bmcproc.log"; } ||
    fail "$name: preflight with the BMC variable only in respirate's environment gave $rc, see $LOGS/$name-preflight-bmcproc.log"
  grep -q 'bmc-pass-harness' "$LOGS/$name-preflight-bmcproc.log" && fail "$name: preflight printed the BMC password"
  dx "$name" grep -qx "BMC_FROM_PROC='BYOH_BMC_PASS_TEST'" /var/lib/ubicloud-migration/state || fail "$name: preflight did not record the BMC variable's source"
  say "$name: preflight takes a BMC variable from the running respirate's environment, with a warn"

  # Re-cutover. A downgrade and a held lease are refused first.
  r0_tmux_stop "$name"
  dx "$name" runuser -u postgres -- psql -XtAq -d clover_test -c "INSERT INTO schema_migrations (filename) VALUES ('20991231_harness_downgrade.rb')"
  rc=$(mig "$name" "$name-preflight-downgrade.log" preflight "${MIG_FLAGS[@]}")
  { [[ $rc == 1 ]] && grep -q '^fatal   schema: clover_test has 1 migration(s) the release lacks (20991231_harness_downgrade.rb).*downgrade' "$LOGS/$name-preflight-downgrade.log"; } ||
    fail "$name: preflight of a newer clover_test gave $rc, see $LOGS/$name-preflight-downgrade.log"
  rc=$(mig "$name" "$name-copy-downgrade.log" copy-db --i-understand-this-drops-live-data)
  { [[ $rc == 2 ]] && grep -q 'that would be a downgrade' "$LOGS/$name-copy-downgrade.log"; } ||
    fail "$name: copy-db of a newer clover_test gave $rc, see $LOGS/$name-copy-downgrade.log"
  dx "$name" runuser -u postgres -- psql -XtAq -d clover_test -c "DELETE FROM schema_migrations WHERE filename = '20991231_harness_downgrade.rb'"
  dx "$name" runuser -u postgres -- psql -XtAq -d clover_test -c "UPDATE strand SET lease = now() + interval '1 hour' WHERE id = (SELECT id FROM strand ORDER BY id LIMIT 1)"
  rc=$(mig "$name" "$name-copy-lease.log" copy-db --i-understand-this-drops-live-data)
  { [[ $rc == 2 ]] && grep -q 'strand lease(s) in clover_test are still held after 150 s' "$LOGS/$name-copy-lease.log"; } ||
    fail "$name: copy-db with a held lease gave $rc, see $LOGS/$name-copy-lease.log"
  [[ $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT datallowconn FROM pg_database WHERE datname = 'clover_test'") == t &&
    $(db_names "$name") == ubicloud ]] || fail "$name: the lease refusal changed clover_test or the databases: $(db_names "$name")"
  dx "$name" runuser -u postgres -- psql -XtAq -d clover_test -c "UPDATE strand SET lease = now() - interval '1000 years' WHERE lease > now()"
  say "$name: preflight and copy-db refuse a clover_test with a migration the release lacks; copy-db waits 150 s for a held lease, then refuses with clover_test as it was"

  # copy-db over the rolled-back copy needs the flag.
  rc=$(mig "$name" "$name-recopy-refused.log" copy-db)
  { [[ $rc == 2 ]] && grep -q 'i-understand-this-drops-live-data' "$LOGS/$name-recopy-refused.log"; } ||
    fail "$name: copy-db over a finished copy gave $rc"
  rc=$(mig "$name" "$name-recopy.log" copy-db --i-understand-this-drops-live-data)
  [[ $rc == 0 ]] || fail "$name: the second copy-db gave $rc, see $LOGS/$name-recopy.log"
  [[ $(db_names "$name") == "ubicloud ubicloud_prev_"* ]] || fail "$name: the old copy was not kept: $(db_names "$name")"
  rc=$(mig "$name" "$name-restart.log" start)
  [[ $rc == 0 ]] || fail "$name: the second start gave $rc, see $LOGS/$name-restart.log"
  say "$name: re-cutover: copy-db refuses a finished copy without the flag, keeps it as ubicloud_prev_* with it, and start passes"

  # A second rollback warns that respirate's BMC variable is not in
  # .env.rb; start refuses the stale copy until a new copy-db.
  rc=$(mig "$name" "$name-rollback2.log" rollback)
  [[ $rc == 0 ]] || fail "$name: the second rollback gave $rc, see $LOGS/$name-rollback2.log"
  grep -q "^warn    rollback: preflight took the BMC password variable(s) BYOH_BMC_PASS_TEST from the running respirate's environment" "$LOGS/$name-rollback2.log" ||
    fail "$name: the second rollback did not warn about BYOH_BMC_PASS_TEST"
  grep -q 'bmc-pass-harness' "$LOGS/$name-rollback2.log" && fail "$name: rollback printed the BMC password"
  rc=$(mig "$name" "$name-start-rolledback2.log" start)
  [[ $rc == 2 ]] || fail "$name: start after the second rollback gave $rc"
  rc=$(mig "$name" "$name-recopy2.log" copy-db --i-understand-this-drops-live-data)
  [[ $rc == 0 ]] || fail "$name: copy-db after the second rollback gave $rc, see $LOGS/$name-recopy2.log"
  rc=$(mig "$name" "$name-restart2.log" start)
  [[ $rc == 0 ]] || fail "$name: start after the second copy gave $rc, see $LOGS/$name-restart2.log"
  dx "$name" grep -qx "ROLLED_BACK=''" /var/lib/ubicloud-migration/state || fail "$name: copy-db did not clear ROLLED_BACK"
  say "$name: a second rollback names the BMC variable to add to .env.rb; start refuses until copy-db makes a new copy, then passes"

  # Window B: flip-production refuses on a simulated-production fail.
  dx "$name" sed -i '/^MAIL_FROM=/d' /etc/ubicloud/env
  rc=$(mig "$name" "$name-flip-refused.log" flip-production)
  { [[ $rc == 2 ]] && grep -q 'MAIL_FROM is unset' "$LOGS/$name-flip-refused.log"; } ||
    fail "$name: flip-production without MAIL_FROM gave $rc, see $LOGS/$name-flip-refused.log"
  dx "$name" grep -qx "RACK_ENV='development'" /etc/ubicloud/env || fail "$name: the refused flip changed RACK_ENV"
  dx "$name" bash -c "echo \"MAIL_FROM='ops@example.test'\" >>/etc/ubicloud/env"
  rc=$(mig "$name" "$name-flip.log" flip-production)
  [[ $rc == 0 ]] || fail "$name: flip-production gave $rc, see $LOGS/$name-flip.log"
  dx "$name" grep -qx "RACK_ENV='production'" /etc/ubicloud/env || fail "$name: RACK_ENV is not production"
  grep -q '^ok      smoke: bin/production_check (a production puma boots' "$LOGS/$name-flip.log" ||
    fail "$name: the flip's step 12 did not run production_check: $(grep smoke "$LOGS/$name-flip.log" | tr '\n' ' ')"
  wait_for 120 web_up "$name" >/dev/null || fail "$name: web down after the flip"
  out=$(login "$name") || fail "$name: login in production failed"
  [[ $out == "302 "*/after-login ]] || fail "$name: login in production: $out"
  adm "$name" smoke >"$LOGS/$name-smoke-prod.log" 2>&1 || fail "$name: smoke after the flip, see $LOGS/$name-smoke-prod.log"
  say "$name: flip-production refuses without MAIL_FROM (exit 2, RACK_ENV unchanged), then flips; production_check, login and smoke pass"
  rc=$(mig "$name" "$name-flip-back.log" flip-production --back)
  [[ $rc == 0 ]] || fail "$name: flip-production --back gave $rc, see $LOGS/$name-flip-back.log"
  dx "$name" grep -qx "RACK_ENV='development'" /etc/ubicloud/env || fail "$name: RACK_ENV is not development after --back"
  wait_for 120 web_up "$name" >/dev/null || fail "$name: web down after flip-production --back"
  out=$(login "$name") || fail "$name: login after flip-production --back failed"
  [[ $out == "302 "*/after-login ]] || fail "$name: login after flip-production --back: $out"
  say "$name: flip-production --back returns to development; login works"

  # Retire.
  rc=$(mig "$name" "$name-retire-early.log" retire --restore-drill-done)
  { [[ $rc == 2 ]] && grep -q 'retire after 14' "$LOGS/$name-retire-early.log"; } || fail "$name: retire without 14 backups gave $rc"
  # retire never demotes postgres, whatever the state file says.
  dx "$name" sed -i "s/^DEV_ROLE='clover'\$/DEV_ROLE='postgres'/" /var/lib/ubicloud-migration/state
  rc=$(mig "$name" "$name-retire-postgres.log" retire --restore-drill-done --skip-backup-count)
  { [[ $rc == 2 ]] && grep -q 'retire would demote role postgres' "$LOGS/$name-retire-postgres.log"; } ||
    fail "$name: retire with DEV_ROLE postgres gave $rc, see $LOGS/$name-retire-postgres.log"
  [[ -n $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT 1 FROM pg_hba_file_rules WHERE auth_method = 'trust' LIMIT 1") &&
    $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT count(*) FROM pg_database WHERE datname = 'clover_test'") == 1 ]] ||
    fail "$name: the refused retire changed pg_hba.conf or clover_test"
  dx "$name" sed -i "s/^DEV_ROLE='postgres'\$/DEV_ROLE='clover'/" /var/lib/ubicloud-migration/state
  say "$name: retire refuses to demote postgres before it changes anything"
  rc=$(mig "$name" "$name-retire.log" retire --restore-drill-done --skip-backup-count)
  [[ $rc == 0 ]] || fail "$name: retire gave $rc, see $LOGS/$name-retire.log"
  grep -q 'use trust' "$LOGS/$name-retire.log" && fail "$name: status still reports trust after retire"
  [[ $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT rolsuper || ' ' || rolcanlogin FROM pg_roles WHERE rolname = 'clover'") == "false false" ]] ||
    fail "$name: role clover can still log in or is a superuser"
  [[ $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT count(*) FROM pg_database WHERE datname LIKE 'clover_test_retired_%'") == 1 &&
    $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT count(*) FROM pg_database WHERE datname = 'clover_test'") == 0 ]] ||
    fail "$name: clover_test was not renamed"
  [[ -z $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT 1 FROM pg_hba_file_rules WHERE auth_method = 'trust'") ]] || fail "$name: trust rules remain"
  dx "$name" test -d /home/ubuntu/.ubi-bootstrap && fail "$name: the bootstrap markers were not moved aside"
  adm "$name" status >"$LOGS/$name-status-retired.log" 2>&1 || fail "$name: status after retire, see $LOGS/$name-status-retired.log"
  say "$name: retire needs 14 backups (or --skip-backup-count), then restores peer/scram, makes clover NOLOGIN NOSUPERUSER, keeps clover_test as clover_test_retired_*; status passes"
  say "migrate: ok"
}

sc_migrate_preM1() {
  local name=migp ruby
  ruby=$(git -C "$WT" show "$MIG_PREM1:.tool-versions" | awk '$1 == "ruby" { print $2 }')
  mig_setup "$name" "$MIG_PREM1" "$ruby"
  mig_cutover "$name" "$ruby" 1
  [[ $(dx "$name" runuser -u postgres -- psql -XtAc "SELECT count(*) FROM pg_database WHERE datname = 'clover_test' AND NOT datallowconn") == 1 ]] ||
    fail "$name: clover_test changed"
  say "migrate-preM1: ok"
}

# --- release switch (WP10) -------------------------------------------------------------

# The migration t3 adds. rake-task-runner allows migration dates up to
# five days ahead (Config.validate_migration_dates), so it is today's.
PROBE_MIG=$(date -u +%Y%m%d)_harness_release_probe.rb
# The migration that fails in t5: tomorrow's, so it runs after PROBE_MIG.
FAIL_MIG=$(date -u -d tomorrow +%Y%m%d)_harness_release_fail.rb

# up_tree NAME OUT EXTRA: a source tarball OUT in ubi-m3-NAME, the working
# tree plus EXTRA (dummy: one file; migration: also PROBE_MIG).
up_tree() {
  dx "$1" bash -s "$2" "$3" "$PROBE_MIG" <<'EOS'
set -euo pipefail
out=$1 extra=$2 probe=$3
rm -rf /root/s && mkdir /root/s && tar -xzf /art/src.tgz -C /root/s
echo "$out" >/root/s/HARNESS_RELEASE
if [[ $extra == migration ]]; then
  cat >"/root/s/migrate/$probe" <<'EOR'
# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:harness_release_probe) do
      Integer :id
    end
  end
end
EOR
fi
tar -czf "$out" -C /root/s . && rm -rf /root/s
EOS
}

# stage_rel NAME VERSION TARBALL [ARGS...]: install.sh --stage release;
# the output goes to $LOGS/NAME-stage-VERSION.log, the status is printed.
stage_rel() {
  local name=$1 v=$2 tgz=$3 rc=0
  shift 3
  dx "$name" bash /art/install.sh --stage release --version "$v" --source-tarball "$tgz" \
    --source-rev "$(printf '%s' "$tgz" | sha1sum | cut -c1-40)" --skip-check clock "$@" \
    >"$LOGS/$name-stage-$v.log" 2>&1 || rc=$?
  echo "$rc"
}

current_of() { dx "$1" readlink /opt/ubicloud/current; }

# stop_cp NAME: stops the control plane and waits for web and respirate
# too; systemctl stop ubicloud.target alone can return while respirate
# still finishes its strands.
stop_cp() { dx "$1" systemctl stop ubicloud.target ubicloud-web ubicloud-respirate ubicloud-monitor; }
previous_of() { dx "$1" readlink /opt/ubicloud/previous 2>/dev/null || true; }

sc_upgrade_manual() {
  local n=upgrade sums pids rc ts_pre ts_post out
  src_tarball
  boot_cp "$n"
  printf '%s\n' "$PASSWORD" | adm "$n" account create --email "$EMAIL" --password-stdin >"$LOGS/$n-account.txt" 2>&1 ||
    fail "$n: account create: $(cat "$LOGS/$n-account.txt")"
  [[ $(login "$n") == "302 http://localhost:3000/after-login" ]] || fail "$n: login on t1"
  [[ $(current_of "$n") == releases/t1 ]] || fail "$n: current is $(current_of "$n"), not t1"

  # 1. --stage release builds t2 and touches nothing else.
  up_tree "$n" /root/src-t2.tgz dummy
  up_tree "$n" /root/src-t3.tgz migration
  sums=$(settings_sums "$n")
  pids=$(service_pids "$n")
  [[ $(stage_rel "$n" t2 /root/src-t2.tgz --url http://localhost:3000) == 2 ]] || fail "$n: --stage release took --url"
  dx "$n" test ! -e /opt/ubicloud/releases/t2 || fail "$n: a refused --stage release built t2"
  rc=$(stage_rel "$n" t2 /root/src-t2.tgz)
  [[ $rc == 0 ]] || fail "$n: --stage release t2 exited $rc, see $LOGS/$n-stage-t2.log"
  grep -q '^changed release: built t2' "$LOGS/$n-stage-t2.log" || fail "$n: --stage release did not build t2"
  grep -q 'current is still releases/t1' "$LOGS/$n-stage-t2.log" || fail "$n: --stage release output: $(cat "$LOGS/$n-stage-t2.log")"
  [[ $(current_of "$n") == releases/t1 ]] || fail "$n: --stage release moved current"
  [[ $(settings_sums "$n") == "$sums" ]] || fail "$n: --stage release changed a managed file"
  [[ $(service_pids "$n") == "$pids" ]] || fail "$n: --stage release restarted a service"
  [[ -z $(dx "$n" find /opt/ubicloud/releases/t2 -xdev ! -type l \( ! -user root -o -perm /022 \) -print -quit) ]] ||
    fail "$n: t2 is not root's alone"
  dx "$n" test -f /opt/ubicloud/releases/t2/HARNESS_RELEASE || fail "$n: t2 lacks its dummy file"
  rc=$(stage_rel "$n" t2 /root/src-t2.tgz)
  { [[ $rc == 0 ]] && ! grep -q '^changed' "$LOGS/$n-stage-t2.log"; } || fail "$n: a second --stage release t2 changed something"
  [[ $(stage_rel "$n" t2 /root/src-t3.tgz) == 2 ]] || fail "$n: --stage release t2 with another rev was not refused"
  say "$n: --stage release built t2 (root-owned) with current, settings, units and MainPIDs unchanged; a rerun is a no-op, another rev exits 2"

  # 2. use and migrate refuse while the services run.
  [[ $(adm_rc "$n" release check t2) == 0 ]] || fail "$n: release check t2 failed: $(tail -8 "$LOGS/adm.log")"
  [[ $(adm_rc "$n" release use t2) == 2 ]] || fail "$n: release use t2 with the services running was not refused"
  [[ $(adm_rc "$n" release migrate t2) == 2 ]] || fail "$n: release migrate t2 with the services running was not refused"
  [[ $(current_of "$n") == releases/t1 && $(service_pids "$n") == "$pids" ]] || fail "$n: a refused release command changed something"
  say "$n: release use and migrate exit 2 while the services run"

  # 3. The switch t1 -> t2, which has no migration to apply.
  stop_cp "$n"
  adm "$n" backup now >/dev/null 2>&1 || fail "$n: backup now after the stop"
  [[ $(adm_rc "$n" release migrate t2) == 0 ]] || fail "$n: release migrate t2: $(tail -5 "$LOGS/adm.log")"
  grep -q 'release: t2 has no migration to apply' "$LOGS/adm.log" || fail "$n: release migrate t2 found migrations"
  [[ $(adm_rc "$n" release use t2) == 0 ]] || fail "$n: release use t2: $(tail -5 "$LOGS/adm.log")"
  [[ $(current_of "$n") == releases/t2 && $(previous_of "$n") == releases/t1 ]] ||
    fail "$n: after use t2: current $(current_of "$n"), previous $(previous_of "$n")"
  dx "$n" systemctl start ubicloud.target
  wait_for 180 web_up "$n" >/dev/null || fail "$n: web down on t2"
  [[ $(dx "$n" systemctl show -p WorkingDirectory --value ubicloud-web) == /opt/ubicloud/current ]] || fail "$n: web runs elsewhere"
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx "$n" bash -c 'test "$(readlink /proc/$(systemctl show -p MainPID --value ubicloud-web)/cwd)" = /opt/ubicloud/releases/t2' ||
    fail "$n: web does not run in releases/t2"
  [[ $(login "$n") == "302 http://localhost:3000/after-login" ]] || fail "$n: login on t2"
  [[ $(adm_rc "$n" status) == 0 ]] || fail "$n: status on t2: $(grep '^fail' "$LOGS/adm.log" | tail -5)"
  grep -q '^ok      release: t2 matches the database' "$LOGS/adm.log" || fail "$n: status has no release line"
  say "$n: t1 -> t2: stop, backup now, release migrate, release use, start: web runs in t2, login and status ok"

  # 4. Back to t1: no new migrations, so it is allowed. t1 is the harness
  # image's release, which has the release command too, so its
  # ubicloud-admin is installed; step 8 covers one without it.
  stop_cp "$n"
  [[ $(adm_rc "$n" release use t1) == 0 ]] || fail "$n: release use t1 (no new migrations): $(tail -5 "$LOGS/adm.log")"
  [[ $(current_of "$n") == releases/t1 && $(previous_of "$n") == releases/t2 ]] || fail "$n: after use t1"
  dx "$n" grep -q '^cmd_release()' /usr/local/bin/ubicloud-admin || fail "$n: use t1 installed an ubicloud-admin without release"
  dx "$n" systemctl start ubicloud.target
  wait_for 180 web_up "$n" >/dev/null || fail "$n: web down on t1"
  [[ $(login "$n") == "302 http://localhost:3000/after-login" ]] || fail "$n: login back on t1"
  say "$n: t2 -> t1 allowed (no new migrations); login ok"

  # 5. t3 has one more migration.
  rc=$(stage_rel "$n" t3 /root/src-t3.tgz)
  [[ $rc == 0 ]] || fail "$n: --stage release t3 exited $rc"
  [[ $(adm_rc "$n" release check t3) == 0 ]] || fail "$n: release check t3"
  grep -q 'release migrate t3 applies 1 migration' "$LOGS/adm.log" || fail "$n: release check t3 did not name the pending migration"
  # 5a. A backup between the stop of respirate and the stop of web
  # misses what web wrote in between.
  dx "$n" systemctl stop ubicloud-respirate
  adm "$n" backup now >/dev/null 2>&1 || fail "$n: backup now with web running"
  # Backup times have whole seconds, and a backup from the second of
  # the stop passes.
  sleep 2
  stop_cp "$n"
  [[ $(adm_rc "$n" release use t3) == 2 ]] || fail "$n: release use t3 before its migration was not refused"
  grep -q 'run ubicloud-admin release migrate t3 first' "$LOGS/adm.log" || fail "$n: no migrate-first message"
  [[ $(adm_rc "$n" release migrate t3) == 2 ]] || fail "$n: release migrate took a backup older than the stop of web"
  grep -q 'is older than the stop of ubicloud-web' <<<"$(adm_last)" || fail "$n: no stale-backup message naming web: $(adm_last)"
  # 5b. A reboot with ubicloud.target disabled: no service ran since
  # boot, so systemd has no stop time, and the boot is the bound.
  dx "$n" systemctl disable -q ubicloud.target
  docker restart -t 120 "ubi-m3-$n" >/dev/null
  wait_booted "$n"
  [[ $(dx "$n" systemctl is-active ubicloud-respirate) != active ]] || fail "$n: respirate started with the target disabled"
  [[ $(adm_rc "$n" release migrate t3) == 2 ]] || fail "$n: release migrate took a backup from before the reboot"
  grep -q 'is older than the boot' <<<"$(adm_last)" || fail "$n: no stale-backup message naming the boot: $(adm_last)"
  dx "$n" systemctl enable -q ubicloud.target
  # 5c. A backup whose migrations are not the database's.
  out=$(adm "$n" backup now 2>&1) || fail "$n: backup now after the reboot"
  ts_pre=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  dx "$n" bash -c "m=/var/backups/ubicloud/$ts_pre/manifest.json && jq '.schema_migrations |= .[1:]' \$m >\$m.new && mv \$m.new \$m"
  [[ $(adm_rc "$n" release migrate t3) == 2 ]] || fail "$n: release migrate took a backup with other migrations"
  grep -q 'holds the database as it is (or as it was before migrations of t3 that ran already)' <<<"$(adm_last)" || fail "$n: no other-migrations message: $(adm_last)"
  dx "$n" rm -rf "/var/backups/ubicloud/$ts_pre" "/var/backups/ubicloud/secrets/$ts_pre.age"
  [[ $(psql_q "$n" "SELECT to_regclass('public.harness_release_probe') IS NULL") == t ]] || fail "$n: a refused migrate ran t3's migration"
  say "$n: release migrate exits 2 with a backup older than the stop of web, older than the boot (target disabled across a restart) or with other migrations"

  # 5d. t5 is t3 plus a migration that fails: the probe migration stays
  # applied, and a rerun goes on from the backup made before it.
  out=$(adm "$n" backup now 2>&1) || fail "$n: backup now before t5"
  ts_pre=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  dx "$n" bash -s "$FAIL_MIG" <<'EOS' || fail "$n: staging t5"
set -euo pipefail
cp -a /opt/ubicloud/releases/t3 /opt/ubicloud/releases/t5
sed -i 's/^version=.*/version=t5/' /opt/ubicloud/releases/t5/.ubicloud-release
cat >"/opt/ubicloud/releases/t5/migrate/$1" <<'EOR'
# frozen_string_literal: true

Sequel.migration do
  up do
    raise "harness: a migration that fails"
  end
end
EOR
EOS
  [[ $(adm_rc "$n" release migrate t5) == 1 ]] || fail "$n: release migrate t5 did not fail: $(adm_last)"
  grep -q "run release migrate t5 again.*restore $ts_pre --db-only" <<<"$(adm_last)" || fail "$n: failed migrate message: $(adm_last)"
  [[ $(psql_q "$n" "SELECT to_regclass('public.harness_release_probe') IS NOT NULL") == t ]] || fail "$n: the first migration of t5 did not stay applied"
  [[ $(adm_rc "$n" release migrate t5) == 1 ]] || fail "$n: the rerun of release migrate t5 was refused: $(adm_last)"
  grep -q "backup $ts_pre holds the database as it was before the 1 migration(s) of t5 that ran already ($PROBE_MIG)" <<<"$(adm_last)" ||
    fail "$n: the rerun did not go on from $ts_pre: $(adm_last)"
  adm "$n" backup now >/dev/null 2>&1 || fail "$n: backup now of the half-migrated database"
  [[ $(adm_rc "$n" release migrate t5) == 1 ]] || fail "$n: release migrate t5 after a backup of the half-migrated database: $(adm_last)"
  grep -q "restore $ts_pre --db-only" <<<"$(adm_last)" || fail "$n: a newer backup that t1 cannot restore replaced $ts_pre: $(adm_last)"
  [[ $(current_of "$n") == releases/t1 ]] || fail "$n: a failed migrate moved current"
  [[ $(adm_rc "$n" restore "$ts_pre" --db-only) == 0 ]] || fail "$n: restore $ts_pre on t1: $(tail -20 "$LOGS/adm.log")"
  [[ $(psql_q "$n" "SELECT to_regclass('public.harness_release_probe') IS NULL") == t ]] || fail "$n: the restore kept t5's first migration"
  wait_for 180 web_up "$n" >/dev/null || fail "$n: web down after the restore on t1"
  dx "$n" rm -rf /opt/ubicloud/releases/t5
  say "$n: a release migrate that fails halfway exits 1; reruns (also after a backup of the half-migrated database) go on from $ts_pre, and restore $ts_pre --db-only on t1 goes back"

  # 5e. The switch to t3.
  stop_cp "$n"
  out=$(adm "$n" backup now 2>&1) || fail "$n: backup now before t3"
  ts_pre=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  [[ $(adm_rc "$n" release migrate t3) == 0 ]] || fail "$n: release migrate t3: $(tail -20 "$LOGS/adm.log")"
  grep -q "backup $ts_pre holds the database as it is" <<<"$(adm_last)" || fail "$n: release migrate t3 did not name $ts_pre: $(adm_last)"
  [[ $(psql_q "$n" "SELECT to_regclass('public.harness_release_probe') IS NOT NULL") == t ]] || fail "$n: t3's migration did not run"
  [[ $(current_of "$n") == releases/t1 ]] || fail "$n: release migrate moved current"
  [[ $(adm_rc "$n" release use t3) == 0 ]] || fail "$n: release use t3"
  dx "$n" systemctl start ubicloud.target
  wait_for 180 web_up "$n" >/dev/null || fail "$n: web down on t3"
  [[ $(adm_rc "$n" status) == 0 ]] || fail "$n: status on t3: $(grep '^fail' "$LOGS/adm.log" | tail -5)"
  out=$(adm "$n" backup now 2>&1) || fail "$n: backup now on t3"
  ts_post=$(grep -oE '[0-9]{8}T[0-9]{6}Z' <<<"$out" | head -1)
  stop_cp "$n"
  for rc in t1 t2; do
    [[ $(adm_rc "$n" release use "$rc") == 2 ]] || fail "$n: the downgrade t3 -> $rc was not refused"
    grep -q "downgrade refused: the database has 1 migration(s) release $rc lacks ($PROBE_MIG)" "$LOGS/adm.log" ||
      fail "$n: no downgrade message for $rc"
  done
  [[ $(adm_rc "$n" release migrate t2) == 2 ]] || fail "$n: release migrate t2 on t3's schema was not refused"
  [[ $(adm_rc "$n" release check t2) == 2 ]] || fail "$n: release check t2 on t3's schema passed"
  [[ $(adm_rc "$n" release use t2 --for-restore "$ts_post") == 2 ]] || fail "$n: --for-restore with a backup t2 cannot read was not refused"
  [[ $(current_of "$n") == releases/t3 ]] || fail "$n: a refused downgrade moved current"
  say "$n: t1 -> t3 with backup $ts_pre; after t3's migration, use t1/t2, migrate t2, check t2 and --for-restore $ts_post exit 2; current stays t3"

  # 6. The way back: t2 with the backup made before t3's migration.
  # Until the restore, nothing starts t2 on t3's schema, not even a
  # reboot with ubicloud.target enabled.
  # A symlink planted under an older layout is not written through.
  dx "$n" ln -s /root/hold-victim /var/lib/ubicloud/release-hold.new
  [[ $(adm_rc "$n" release use t2 --for-restore "$ts_pre") == 0 ]] || fail "$n: release use t2 --for-restore $ts_pre"
  [[ $(current_of "$n") == releases/t2 && $(previous_of "$n") == releases/t3 ]] || fail "$n: after use t2 --for-restore"
  dx "$n" test -f /var/lib/ubicloud/release-hold || fail "$n: --for-restore set no hold"
  dx "$n" test ! -e /root/hold-victim || fail "$n: release use --for-restore wrote through a planted release-hold.new"
  ! dx "$n" systemctl start ubicloud-web 2>/dev/null || fail "$n: web started while held"
  dx "$n" systemctl start ubicloud.target || true
  [[ $(dx "$n" systemctl is-active ubicloud-web) != active && $(dx "$n" systemctl is-active ubicloud-respirate) != active ]] ||
    fail "$n: systemctl start ubicloud.target started a held service"
  docker restart -t 120 "ubi-m3-$n" >/dev/null
  wait_booted "$n"
  [[ $(dx "$n" systemctl is-enabled ubicloud.target) == enabled ]] || fail "$n: the hold disabled the target"
  [[ $(dx "$n" systemctl is-active ubicloud-web) != active && $(dx "$n" systemctl is-active ubicloud-respirate) != active ]] ||
    fail "$n: a held service started at boot"
  [[ $(adm_rc "$n" status) == 1 ]] || fail "$n: status passed between use --for-restore and the restore"
  grep -q 'release: the database has 1 migration(s) t2 lacks' "$LOGS/adm.log" || fail "$n: status did not name the downgrade"
  grep -q "held by release use --for-restore until ubicloud-admin restore $ts_pre --db-only" <<<"$(adm_last)" || fail "$n: status did not name the hold"
  [[ $(adm_rc "$n" restore "$ts_pre" --db-only) == 0 ]] || fail "$n: restore $ts_pre --db-only: $(tail -20 "$LOGS/adm.log")"
  grep -q 'the hold of release use --for-restore is lifted' <<<"$(adm_last)" || fail "$n: the restore did not lift the hold"
  dx "$n" test ! -e /var/lib/ubicloud/release-hold || fail "$n: the hold file outlived the restore"
  [[ -z $(dx "$n" find /etc/systemd/system -name 50-ubicloud-release-hold.conf) ]] || fail "$n: a hold drop-in outlived the restore"
  wait_for 180 web_up "$n" >/dev/null || fail "$n: web down after the restore"
  [[ $(psql_q "$n" "SELECT to_regclass('public.harness_release_probe') IS NULL") == t ]] || fail "$n: the restore kept t3's table"
  [[ $(login "$n") == "302 http://localhost:3000/after-login" ]] || fail "$n: login after going back to t2"
  [[ $(adm_rc "$n" status) == 0 ]] || fail "$n: status after going back: $(grep '^fail' "$LOGS/adm.log" | tail -5)"
  adm "$n" release list >"$LOGS/$n-list.txt" 2>&1 || fail "$n: release list"
  { grep -qE '^t2 .* current +matches' "$LOGS/$n-list.txt" && grep -qE '^t3 .* previous +1 to apply' "$LOGS/$n-list.txt"; } ||
    fail "$n: release list: $(cat "$LOGS/$n-list.txt")"
  say "$n: rollback rehearsed: release use t2 --for-restore $ts_pre held web and respirate (manual start, target start, reboot), restore --db-only lifted the hold; login and status ok on t2"

  # 7. --skip-backup-check: the newest backup ($ts_post) has t3's
  # migration and is older than the stop, and is not looked at.
  stop_cp "$n"
  [[ $(adm_rc "$n" release migrate t3 --skip-backup-check) == 0 ]] || fail "$n: release migrate t3 --skip-backup-check: $(adm_last)"
  grep -q 'no backup check (--skip-backup-check)' <<<"$(adm_last)" || fail "$n: --skip-backup-check did not warn"
  [[ $(psql_q "$n" "SELECT to_regclass('public.harness_release_probe') IS NOT NULL") == t ]] || fail "$n: t3's migration did not run"
  [[ $(adm_rc "$n" release use t3) == 0 ]] || fail "$n: release use t3 after --skip-backup-check"
  say "$n: release migrate t3 --skip-backup-check warns and migrates over a stale backup"

  # 8. t4 is t3 with the release command taken out of its
  # ubicloud-admin (an older admin), and the newest build.
  # shellcheck disable=SC2016 # expanded by the container's bash
  dx "$n" bash -c 'set -e; cp -a /opt/ubicloud/releases/t3 /opt/ubicloud/releases/t4; cd /opt/ubicloud/releases/t4
    sed -i "s/^version=.*/version=t4/; s/^built=.*/built=$(date -u +%FT%TZ)/" .ubicloud-release
    sed -i "s/^cmd_release()/cmd_release_removed()/" packaging/bin/ubicloud-admin
    cp -p mise.toml /root/mise.toml.t4' || fail "$n: staging t4"
  dx "$n" chmod g+w /opt/ubicloud/releases/t4/Gemfile
  [[ $(adm_rc "$n" release use t4) == 2 ]] || fail "$n: release use t4 with a group-writable file was not refused"
  grep -q "t4/Gemfile is not root's alone" <<<"$(adm_last)" || fail "$n: no ownership message: $(adm_last)"
  dx "$n" chmod g-w /opt/ubicloud/releases/t4/Gemfile
  dx "$n" sed -i 's/^ruby = .*/ruby = "0.0.1"/' /opt/ubicloud/releases/t4/mise.toml
  for rc in check migrate use; do
    [[ $(adm_rc "$n" release "$rc" t4) == 2 ]] || fail "$n: release $rc t4 with another ruby was not refused"
    grep -q 'release t4: wants ruby 0.0.1' <<<"$(adm_last)" || fail "$n: release $rc t4 did not name the ruby: $(adm_last)"
  done
  dx "$n" cp /root/mise.toml.t4 /opt/ubicloud/releases/t4/mise.toml
  [[ $(adm_rc "$n" release use t4 --for-restore 20000101T000000Z) == 2 ]] || fail "$n: --for-restore with no such backup was not refused"
  grep -q '20000101T000000Z/manifest.json does not exist' <<<"$(adm_last)" || fail "$n: no missing-backup message: $(adm_last)"
  [[ $(current_of "$n") == releases/t3 ]] || fail "$n: a refused use t4 moved current"
  sums=$(dx "$n" sha256sum /usr/local/bin/ubicloud-admin)
  [[ $(adm_rc "$n" release use t4) == 0 ]] || fail "$n: release use t4: $(adm_last)"
  grep -q "t4's ubicloud-admin has no release command, so /usr/local/bin/ubicloud-admin stays as it is" <<<"$(adm_last)" || fail "$n: no older-admin warning: $(adm_last)"
  [[ $(dx "$n" sha256sum /usr/local/bin/ubicloud-admin) == "$sums" ]] || fail "$n: use t4 replaced ubicloud-admin"
  [[ $(current_of "$n") == releases/t4 && $(previous_of "$n") == releases/t3 ]] || fail "$n: after use t4"
  say "$n: t4 refused with a group-writable file, another ruby (check, migrate, use) and --for-restore of no backup; use t4 warns and keeps the newer ubicloud-admin"

  # 9. prune keeps current and previous whatever --keep says: first
  # previous (t3) is not among the newest, then current (t3) is not.
  dx "$n" install -d -m 0755 /opt/ubicloud/releases/t9.tmp
  [[ $(adm_rc "$n" release prune --keep 1) == 0 ]] || fail "$n: release prune"
  [[ $(dx "$n" ls /opt/ubicloud/releases | tr '\n' ' ') == "t3 t4 " ]] ||
    fail "$n: after prune --keep 1 with current t4: $(dx "$n" ls /opt/ubicloud/releases | tr '\n' ' ')"
  [[ $(adm_rc "$n" release use t3) == 0 ]] || fail "$n: release use t3 back"
  [[ $(adm_rc "$n" release prune --keep 1) == 0 ]] || fail "$n: the second release prune"
  [[ $(dx "$n" ls /opt/ubicloud/releases | tr '\n' ' ') == "t3 t4 " ]] ||
    fail "$n: after prune --keep 1 with current t3: $(dx "$n" ls /opt/ubicloud/releases | tr '\n' ' ')"
  grep -q 'kept 2 (current t3, previous t4), removed 0' <<<"$(adm_last)" || fail "$n: second prune: $(adm_last)"
  dx "$n" systemctl start ubicloud.target
  wait_for 180 web_up "$n" >/dev/null || fail "$n: web down on t3 after prune"
  [[ $(adm_rc "$n" status) == 0 ]] || fail "$n: status after prune: $(grep '^fail' "$LOGS/adm.log" | tail -5)"
  say "$n: release prune --keep 1 removed t1, t2 and t9.tmp and kept t4 (newest) and t3 as previous, then as current; status ok on t3"
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
    all) for s in parity envfmt verify fresh rerun flags smoke kill restart reboot tls_provided tunnel backup admin devshim gate_journal migrate migrate_preM1 upgrade_manual; do "sc_$s"; cleanup; done ;;
    parity | envfmt | verify | fresh | rerun | flags | smoke | kill | restart | reboot | tls-provided | tunnel | backup | admin | devshim | gate-journal | migrate | migrate-preM1 | upgrade-manual)
      "sc_${arg//-/_}"
      cleanup
      ;;
    *) fail "unknown argument $arg" ;;
  esac
done
say "logs: $LOGS"
