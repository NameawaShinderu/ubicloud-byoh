#!/bin/bash
# Tests the M4 real-infrastructure gate scripts (WP13) against stubs, as
# far as they can run here: scripts/byoh/verify/m4-e2.sh with a stub
# ubicloud-admin and a stub m2-gate.sh, and m4-f5-soak.sh with a stub
# m2-checks, a stub sleep and a fake monitor process. Both run as root in
# one ubi-m4-gates fakehost container (on ubi-test-net, no ports) with
# the worktree mounted read-only; nothing reaches a real host. What the
# stubs stand in for (site add, host add, the gate, the health probe)
# has its own tests; the real runs stay UNVERIFIED (VERIFY.md section 6).
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

prepare_fakehost_image
start_fakehost gates -v "$WT:/w:ro"

docker exec -i "$PREFIX-gates" bash -s <<'INNER' || fail "gate script cases failed"
set -euo pipefail
T=/tmp/t
mkdir -p $T/bin
cd /w
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
expect_rc() { # expect_rc WANT DESC CMD...
  local want=$1 desc=$2 rc
  shift 2
  "$@" >$T/out 2>&1 && rc=0 || rc=$?
  if ((rc == want)); then ok "$desc (exit $rc)"; else bad "$desc: exit $rc, wanted $want"; sed 's/^/     | /' $T/out; fi
}
has() { # has FILE DESC PATTERN (fixed string)
  if grep -qF -- "$3" "$1"; then ok "$2"; else bad "$2: no '$3' in $1"; sed 's/^/     | /' "$1"; fi
}
hasnt() {
  if grep -qF -- "$3" "$1"; then bad "$2: '$3' in $1"; else ok "$2"; fi
}

# --- m4-e2.sh ---------------------------------------------------------
cat >$T/bin/admin <<'EOF'
#!/bin/bash
# Stub ubicloud-admin: logs each call, one argument per line.
{ echo "CALL $1 $2"; printf 'ARG %s\n' "$@"; } >>/tmp/t/admin.log
case "$1 $2" in
  "site show") exit "${STUB_SITE_EXISTS_RC:-1}" ;;
  "site add") echo "created site $3"; exit "${STUB_SITE_RC:-0}" ;;
  "host add")
    echo "Checking ubuntu@10.0.0.5 (preflight, read-only)"
    [[ ${STUB_RESUME:-0} == 0 ]] || echo "Resuming: 10.0.0.5 is already registered as host vh0000000000000000000000ab (at Vm::HostNexus.wait)."
    if [[ ${STUB_HOST_RC:-0} == 0 ]]; then
      echo "Registered host vh0000000000000000000000ab in site s1."
      echo "Host vh0000000000000000000000ab accepts VMs."
    fi
    exit "${STUB_HOST_RC:-0}"
    ;;
esac
exit 99
EOF
cat >$T/bin/gate <<'EOF'
#!/bin/bash
{ echo "steps=$*"; echo "host=$GATE_HOST location=$GATE_LOCATION main=$GATE_MAIN_IP key=$GATE_HOST_KEY"; echo "checks=$GATE_CHECKS"; } >>/tmp/t/gate.log
[[ -f $GATE_HOST_KEY ]] && echo "keyfile=present" >>/tmp/t/gate.log
echo "PASS g4"
exit "${STUB_GATE_RC:-0}"
EOF
cat >$T/bin/checks <<'EOF'
#!/bin/bash
# Stub m2-checks: help exits STUB_HELP_RC; health lines for host $3;
# /tmp/t/sick-<host> holds how many more samples fail, /tmp/t/gone-<host>
# makes the command fail.
echo "$*" >>/tmp/t/checks.log
if [[ $1 == help ]]; then
  echo "Usage: scripts/byoh/verify/m2-checks COMMAND [options]"
  exit "${STUB_HELP_RC:-0}"
fi
[[ $1 == health ]] || exit 0
[[ -e /tmp/t/gone-$3 ]] && { echo "! no host $3"; exit 1; }
n=$(cat "/tmp/t/sick-$3" 2>/dev/null || echo 0)
echo "PASS host strand is at wait, not unavailable"
if ((n > 0)); then
  echo $((n - 1)) >"/tmp/t/sick-$3"
  echo "FAIL checkup is not set (the monitor has not read the host as down)"
  exit 1
fi
echo "ok"
EOF
chmod +x $T/bin/*
ssh-keygen -q -t ed25519 -N '' -f $T/opkey
echo "version: 2" >$T/pools.yaml

e2() { # runs m4-e2.sh with the stubs, a fresh log directory and, unless
  # E2_RESUME=1 (a re-run), no generated key from an earlier run
  rm -rf "${T:?}/var" $T/admin.log $T/gate.log $T/checks.log
  [[ ${E2_RESUME:-0} == 1 ]] || rm -rf "${T:?}/keys"
  env ADMIN=$T/bin/admin E2_GATE=$T/bin/gate GATE_CHECKS=$T/bin/checks E2_LOG_DIR=$T/var E2_KEY_DIR=$T/keys \
    SITE=s1 PLATFORM=proxmox HOST_SSH=ubuntu@10.0.0.5 HOST_KEY=$T/opkey POOL_FILE=$T/pools.yaml "$@"
}
key=$T/keys/m4-e2-proxmox-s1-10.0.0.5.key
fp1=SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fp2=SHA256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

expect_rc 0 "e2: site add, host add and the gate pass" \
  e2 EXPECT_HOST_KEY="$fp1 $fp2" HOST_ADD_ARGS="--storage-disk virtio-d1 --accept-check PF8-hybrid" \
  scripts/byoh/verify/m4-e2.sh -- --display "Office Proxmox (BYOH)" --underlay 10.77.0.0/24
log=$(ls $T/var/m4-e2-proxmox-*.log)
has $T/admin.log "e2: site add keeps a quoted option whole" "ARG Office Proxmox (BYOH)"
has $T/admin.log "e2: site add is called" "CALL site add"
has $T/admin.log "e2: host add gets the first fingerprint" "ARG $fp1"
has $T/admin.log "e2: host add gets the second fingerprint" "ARG $fp2"
has $T/admin.log "e2: host add gets the generated registration key" "ARG $key"
has $T/admin.log "e2: host add gets HOST_ADD_ARGS" "ARG virtio-d1"
hasnt $T/admin.log "e2: no --yes with fingerprints" "ARG --yes"
has $T/gate.log "e2: the gate runs the no-VM steps" "steps=g1 g2 g4 g5"
has $T/gate.log "e2: the gate gets the host, site and main IP" "host=vh0000000000000000000000ab location=s1 main=10.0.0.5"
has $T/gate.log "e2: the gate's root key is the registration key" "keyfile=present"
has "$log" "e2: output lines carry seconds" "[    0s] Registered host vh0000000000000000000000ab"
has "$log" "e2: phase times" "   host add "
has "$log" "e2: verdict" "PASS: host add exited 0, vh0000000000000000000000ab accepts VMs"
has $T/gate.log "e2: the gate gets GATE_CHECKS" "checks=$T/bin/checks"
has $T/checks.log "e2: m2-checks is tried before anything changes" "help"
[[ ! -e $key && ! -e $key.pub ]] && ok "e2: the generated root key is shredded after a pass" || bad "e2: $key is left after a pass"
has "$log" "e2: the shred is logged" "shredded the generated key $key"
[[ $(stat -c %a $T/keys) == 700 ]] && ok "e2: the key directory is 0700" || bad "e2: key directory mode $(stat -c %a $T/keys)"

expect_rc 0 "e2: pasted --expect-host-key flags" \
  e2 EXPECT_HOST_KEY="--expect-host-key $fp1 --expect-host-key=$fp2" scripts/byoh/verify/m4-e2.sh
[[ $(grep -cx -- "ARG --expect-host-key" $T/admin.log) == 2 ]] && ok "e2: each pasted fingerprint gets one flag" ||
  { bad "e2: pasted flags"; sed 's/^/     | /' $T/admin.log; }
has $T/admin.log "e2: the flag=value form gives the bare fingerprint" "ARG $fp2"
hasnt $T/admin.log "e2: no doubled flag" "ARG --expect-host-key="

expect_rc 0 "e2: E2_KEEP_KEY=1 keeps the key" e2 HOST_ADD_YES=1 E2_KEEP_KEY=1 scripts/byoh/verify/m4-e2.sh
[[ -f $key ]] && ok "e2: the kept key is there" || bad "e2: E2_KEEP_KEY=1 lost $key"
has "$(ls $T/var/*.log)" "e2: the kept key is named with its shred line" "Once you are done: shred -u $key"

expect_rc 0 "e2: --main-ip in HOST_ADD_ARGS is the gate's main IP" \
  e2 HOST_ADD_YES=1 HOST_ADD_ARGS="--storage-disk d1 --main-ip 10.77.0.20" scripts/byoh/verify/m4-e2.sh
has $T/gate.log "e2: the gate checks the registered address" "main=10.77.0.20"
has $T/admin.log "e2: the key is named by that address" "ARG $T/keys/m4-e2-proxmox-s1-10.77.0.20.key"
expect_rc 0 "e2: --main-ip=IP too" e2 HOST_ADD_YES=1 HOST_ADD_ARGS="--main-ip=10.77.0.21" scripts/byoh/verify/m4-e2.sh
has $T/gate.log "e2: --main-ip=IP reaches the gate" "main=10.77.0.21"
expect_rc 0 "e2: a MAIN_IP equal to --main-ip" e2 HOST_ADD_YES=1 MAIN_IP=10.77.0.20 HOST_ADD_ARGS="--main-ip 10.77.0.20" scripts/byoh/verify/m4-e2.sh
expect_rc 2 "e2: a MAIN_IP other than --main-ip" e2 HOST_ADD_YES=1 MAIN_IP=10.0.0.5 HOST_ADD_ARGS="--main-ip 10.77.0.20" scripts/byoh/verify/m4-e2.sh
has $T/out "e2: says the addresses differ" "differs from --main-ip 10.77.0.20"

expect_rc 2 "e2: an m2-checks that cannot run stops before any change" e2 HOST_ADD_YES=1 STUB_HELP_RC=1 scripts/byoh/verify/m4-e2.sh
has $T/out "e2: names the m2-checks command" "$T/bin/checks does not run here"
[[ ! -e $T/admin.log ]] && ok "e2: no ubicloud-admin call when m2-checks cannot run" || bad "e2: ubicloud-admin ran"

expect_rc 2 "e2: no fingerprint and no HOST_ADD_YES" e2 scripts/byoh/verify/m4-e2.sh
expect_rc 0 "e2: HOST_ADD_YES=1 confirms with --yes" e2 HOST_ADD_YES=1 GATE_HOST_KEY=$T/opkey scripts/byoh/verify/m4-e2.sh
has $T/admin.log "e2: --yes passed" "ARG --yes"
hasnt $T/admin.log "e2: a given GATE_HOST_KEY means no generated key" "ARG --registration-key"
has $T/gate.log "e2: the gate uses the given key" "key=$T/opkey"

expect_rc 0 "e2: an existing site is not added again" e2 HOST_ADD_YES=1 STUB_SITE_EXISTS_RC=0 scripts/byoh/verify/m4-e2.sh
hasnt $T/admin.log "e2: no site add call" "CALL site add"
has "$(ls $T/var/*.log)" "e2: the skip is logged" "site add: skipped, site s1 exists"

expect_rc 1 "e2: a failed site add stops the run" e2 HOST_ADD_YES=1 STUB_SITE_RC=1 scripts/byoh/verify/m4-e2.sh
expect_rc 1 "e2: a failed host add stops before the gate" e2 HOST_ADD_YES=1 STUB_HOST_RC=3 scripts/byoh/verify/m4-e2.sh
[[ ! -e $T/gate.log ]] && ok "e2: no gate after a failed host add" || bad "e2: the gate ran after a failed host add"
has "$(ls $T/var/*.log)" "e2: host add's exit status is logged" "== host add: exit 3"
[[ -f $key ]] && ok "e2: the key stays for the resume" || bad "e2: $key is gone after a failed host add"
has "$(ls $T/var/*.log)" "e2: the failure names the kept key" "$key is a root login to 10.0.0.5; it stays for a re-run"
first=$(sha256sum <$key)
E2_RESUME=1 expect_rc 0 "e2: the resume the failure recommends passes" e2 HOST_ADD_YES=1 STUB_RESUME=1 E2_KEEP_KEY=1 scripts/byoh/verify/m4-e2.sh
has "$(ls $T/var/*.log)" "e2: the resume reuses the key" "reusing the registration key $key"
has $T/admin.log "e2: the resume passes the same key" "ARG $key"
has $T/gate.log "e2: the gate logs in with the first run's key" "key=$key"
[[ $(sha256sum <$key) == "$first" ]] && ok "e2: the key was not regenerated" || bad "e2: the key was regenerated"
expect_rc 1 "e2: a resume whose key is gone fails clearly" e2 HOST_ADD_YES=1 STUB_RESUME=1 scripts/byoh/verify/m4-e2.sh
has "$(ls $T/var/*.log)" "e2: says why" "FAIL the host was registered by an earlier run whose key is gone"
[[ ! -e $T/gate.log ]] && ok "e2: no gate with a key the host does not know" || bad "e2: the gate ran with a new key"
[[ ! -e $key ]] && ok "e2: the useless new key is removed" || bad "e2: the new key stayed"
expect_rc 1 "e2: a failed gate fails the run" e2 HOST_ADD_YES=1 STUB_GATE_RC=1 scripts/byoh/verify/m4-e2.sh
has "$(ls $T/var/*.log)" "e2: the gate failure is the verdict" "== FAIL m2 gate"
expect_rc 2 "e2: an unknown platform" e2 HOST_ADD_YES=1 PLATFORM=gcp scripts/byoh/verify/m4-e2.sh
expect_rc 2 "e2: HOST_SSH without a user" e2 HOST_ADD_YES=1 HOST_SSH=10.0.0.5 scripts/byoh/verify/m4-e2.sh
expect_rc 2 "e2: site options without --" e2 HOST_ADD_YES=1 scripts/byoh/verify/m4-e2.sh --display x
expect_rc 2 "e2: SITE unset" e2 HOST_ADD_YES=1 SITE= scripts/byoh/verify/m4-e2.sh

# --- m4-f5-soak.sh ----------------------------------------------------
cat >$T/bin/sleep <<'EOF'
#!/bin/bash
# Stub sleep: with /tmp/t/down-on-sleep naming a host, the monitor
# "logs" one down pulse of it (and lines that must not count) meanwhile.
echo "sleep $*" >>/tmp/t/sleep.log
if [[ -e /tmp/t/down-on-sleep ]]; then
  h=$(cat /tmp/t/down-on-sleep)
  rm /tmp/t/down-on-sleep
  {
    echo '{"got_pulse":{"ubid":"'"$h"'","pulse":{"reading":"down","reading_rpt":1}},"message":"Got new pulse."}'
    echo '{"got_pulse":{"ubid":"'"$h"'","pulse":{"reading":"up","reading_rpt":2,"dns_egress4":"down"}},"message":"Got new pulse."}'
    echo '{"got_pulse":{"ubid":"vm00000000000000000000000a","pulse":{"reading":"down"}},"message":"Got new pulse."}'
  } >>/tmp/t/monitor.log
fi
EOF
mkdir -p $T/sudobin
cat >$T/sudobin/sudo <<'EOF'
#!/bin/bash
echo "sudo $*" >>/tmp/t/sudo.log
exit 1
EOF
chmod +x $T/bin/sleep $T/sudobin/sudo
h1=vh00000000000000000000000a
h2=vh00000000000000000000000b
soak() {
  rm -rf "${T:?}/var" $T/checks.log $T/sleep.log $T/sick-* $T/gone-* $T/down-on-sleep $T/sudo.log
  # PRELOG: what the monitor logged before the soak started.
  if [[ -n ${PRELOG:-} ]]; then printf '%s\n' "$PRELOG" >$T/monitor.log; else : >$T/monitor.log; fi
  env SOAK_CHECKS=$T/bin/checks SOAK_SLEEP=$T/bin/sleep SOAK_LOG_DIR=$T/var SOAK_SERVICES=tmux SOAK_MONITOR_LOG=$T/monitor.log "$@"
}

expect_rc 1 "soak: fails while the monitor does not run" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 2
has "$(ls $T/var/*.log)" "soak: says to start the monitor" "FAIL the monitor does not run"
has "$(ls $T/var/*.log)" "soak: counts monitor-down samples" "2 failing, monitor down in 2"

bash -c 'exec -a "ruby bin/monitor" sleep 600' &
monitor=$!
expect_rc 0 "soak: passes healthy hosts" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --host $h2 --samples 3 --interval 5
[[ $(grep -cE "^health --host $h1 --since 20[0-9-]{8}T[0-9:]{8}Z --probe$" $T/checks.log) == 3 ]] &&
  ok "soak: probes each host every sample, since the soak's start" || bad "soak: probe count"
[[ $(grep -c "^health --host $h2 --since " $T/checks.log) == 3 ]] && ok "soak: probes the second host too" || bad "soak: second host probes"
[[ $(sed -n 1p $T/checks.log) == help ]] && ok "soak: m2-checks is tried first" || bad "soak: no m2-checks help first"
has "$(ls $T/var/*.log)" "soak: reads the monitor log" "$h1 PASS the monitor logged no down reading of the host since the last sample"
[[ $(grep -c "^sleep 5$" $T/sleep.log) == 2 ]] && ok "soak: sleeps the interval between samples only" || bad "soak: sleep calls"
has "$(ls $T/var/*.log)" "soak: lines are prefixed with the host" "$h2 PASS host strand is at wait"
has "$(ls $T/var/*.log)" "soak: verdict" "== PASS"

expect_rc 1 "soak: one failing sample fails the soak" bash -c "$(declare -f soak); T=$T; soak bash -c 'echo 1 >$T/sick-$h2; scripts/byoh/verify/m4-f5-soak.sh --host $h1 --host $h2 --samples 3'"
has "$(ls $T/var/*.log)" "soak: names the failing host" "$h2: 1 failing sample(s)"
has "$(ls $T/var/*.log)" "soak: the other host passed" "$h1: 0 failing sample(s)"
expect_rc 1 "soak: a failing command fails the sample" bash -c "$(declare -f soak); T=$T; soak bash -c 'touch $T/gone-$h1; scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 1'"
has "$(ls $T/var/*.log)" "soak: logs the command's error" "$h1 ! no host $h1"
expect_rc 0 "soak: hours and interval decide the sample count" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --hours 1 --interval 600
[[ $(grep -c ^health $T/checks.log) == 7 ]] && ok "soak: 1 h every 600 s is 7 samples" || bad "soak: sample count $(grep -c ^health $T/checks.log)"

old_down='{"got_pulse":{"ubid":"'$h1'","pulse":{"reading":"down"}},"message":"Got new pulse."}'
PRELOG=$old_down expect_rc 0 "soak: a down pulse logged before the soak does not count" \
  soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 2
has $T/monitor.log "soak: the old down pulse was in the log" '"reading":"down"'
expect_rc 1 "soak: a down pulse between samples fails the soak, though every sample looks healthy" \
  bash -c "$(declare -f soak); T=$T; soak bash -c 'echo $h1 >$T/down-on-sleep; scripts/byoh/verify/m4-f5-soak.sh --host $h1 --host $h2 --samples 3'"
log=$(ls $T/var/*.log)
has "$log" "soak: counts the host's down readings only" "$h1 FAIL the monitor logged 1 down reading(s) of the host since the last sample"
has "$log" "soak: the other host has none" "$h2 PASS the monitor logged no down reading"
has "$log" "soak: one failing sample" "3 sample(s), 1 failing"
[[ $(grep -c "$h1 FAIL the monitor logged" "$log") == 1 ]] && ok "soak: a down reading is counted in one sample only" || bad "soak: down reading counted again"
expect_rc 0 "soak: an unreadable monitor log is a warning" soak SOAK_MONITOR_LOG=$T/no-such.log scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 1
has "$(ls $T/var/*.log)" "soak: says down readings go unseen" "WARN cannot read the monitor log $T/no-such.log"
hasnt "$(ls $T/var/*.log)" "soak: no PASS for a log it did not read" "PASS the monitor logged"
expect_rc 0 "soak: SOAK_MONITOR_LOG=none" soak SOAK_MONITOR_LOG=none scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 1
hasnt "$(ls $T/var/*.log)" "soak: none reads no log" "monitor logged"
kill $monitor

expect_rc 2 "soak: an m2-checks that cannot run is a setup error, not a failing sample" soak STUB_HELP_RC=1 scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 1
has $T/out "soak: names the command" "$T/bin/checks does not run here"
[[ $(grep -c ^health $T/checks.log) == 0 ]] && ok "soak: no sample after the setup error" || bad "soak: sampled anyway"
rm -f $T/sudo.log
expect_rc 2 "soak: under systemd, m2-checks runs through ubicloud-admin" \
  env PATH=$T/sudobin:$PATH SOAK_SERVICES=systemd SOAK_LOG_DIR=$T/var scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 1
has $T/sudo.log "soak: the packaged m2-checks" "sudo ubicloud-admin run m2-checks help"

# --- m2-gate.sh GATE_CHECKS -------------------------------------------
rm -f $T/checks.log $T/sudo.log
expect_rc 0 "gate: GATE_CHECKS runs the database checks" \
  env GATE_SERVICES=tmux GATE_CHECKS=$T/bin/checks GATE_LOCATION=s1 scripts/byoh/verify/m2-gate.sh g2
has $T/checks.log "gate: g2 went through GATE_CHECKS" "location --location s1 --rates-from hetzner-fsn1"
expect_rc 1 "gate: under systemd the default is ubicloud-admin run" \
  env PATH=$T/sudobin:$PATH GATE_SERVICES=systemd GATE_LOCATION=s1 scripts/byoh/verify/m2-gate.sh g2
has $T/sudo.log "gate: the packaged m2-checks" "sudo ubicloud-admin run m2-checks location --location s1"

expect_rc 2 "soak: --host is required" soak scripts/byoh/verify/m4-f5-soak.sh --samples 1
expect_rc 2 "soak: --host takes a ubid" soak scripts/byoh/verify/m4-f5-soak.sh --host 10.0.0.5
expect_rc 2 "soak: --hours takes a number" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --hours x
expect_rc 2 "soak: --interval above 0" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --interval 0
expect_rc 2 "soak: an unknown argument" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --frob
expect_rc 2 "soak: an unknown SOAK_SERVICES" soak SOAK_SERVICES=runit scripts/byoh/verify/m4-f5-soak.sh --host $h1

echo "$fails failure(s)"
((fails == 0))
INNER
say "m4 gate scripts: all cases passed"
