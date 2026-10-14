#!/bin/bash
# Container harness for the packaged BYOH control plane (M3). Runs on a
# docker host; everything happens in throwaway ubi-m3-* containers on
# the ubi-test-net network, with no published ports.
#
#   run.sh --prepare-image     build ubi-m3-systemd (Dockerfile.systemd)
#   run.sh --prepare-tools     ubi-m3-tools: packages, mise, ruby, node
#   run.sh --prepare-release   ubi-m3-release: a release of the working
#                              tree, its database, env and units, stopped
#   run.sh SCENARIO...         run scenarios, each in a fresh container
#
# Scenarios: envfmt verify smoke kill restart reboot (or "all").
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
  start_sys tools-build ubi-m3-systemd
  dx tools-build bash /art/fixture.sh tools >"$LOGS/prepare-tools.log" 2>&1 ||
    fail "tools stage failed, see $LOGS/prepare-tools.log"
  dx tools-build systemctl stop postgresql
  docker commit -c 'CMD ["/sbin/init"]' ubi-m3-tools-build ubi-m3-tools >/dev/null
  say "committed ubi-m3-tools: $(tail -2 "$LOGS/prepare-tools.log" | tr '\n' ' ')"
}

prepare_release() {
  stage_art
  src_tarball
  start_sys release-build ubi-m3-tools
  dx release-build bash /art/fixture.sh release t1 >"$LOGS/prepare-release.log" 2>&1 ||
    fail "release stage failed, see $LOGS/prepare-release.log"
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
  dx smoke systemctl stop ubicloud-monitor
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(dx smoke bash -c 'grep CapEff /proc/$(systemctl show -p MainPID --value ubicloud-web)/status')
  [[ $out == *0000000000000000 ]] || fail "web has capabilities: $out"
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(dx smoke bash -c 'cat /proc/$(systemctl show -p MainPID --value ubicloud-respirate)/status | grep NoNewPrivs')
  [[ $out == *1 ]] || fail "respirate without NoNewPrivs: $out"
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
    all) for s in envfmt verify smoke kill restart reboot; do "sc_$s"; cleanup; done ;;
    envfmt | verify | smoke | kill | restart | reboot)
      "sc_$arg"
      cleanup
      ;;
    *) fail "unknown argument $arg" ;;
  esac
done
say "logs: $LOGS"
