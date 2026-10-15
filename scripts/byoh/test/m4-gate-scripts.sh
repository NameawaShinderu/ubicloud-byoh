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
{ echo "steps=$*"; echo "host=$GATE_HOST location=$GATE_LOCATION main=$GATE_MAIN_IP key=$GATE_HOST_KEY"; } >>/tmp/t/gate.log
[[ -f $GATE_HOST_KEY ]] && echo "keyfile=present" >>/tmp/t/gate.log
echo "PASS g4"
exit "${STUB_GATE_RC:-0}"
EOF
chmod +x $T/bin/*
ssh-keygen -q -t ed25519 -N '' -f $T/opkey
echo "version: 2" >$T/pools.yaml

e2() { # runs m4-e2.sh with the stubs and a fresh log directory
  rm -rf "${T:?}/var" $T/admin.log $T/gate.log
  env ADMIN=$T/bin/admin E2_GATE=$T/bin/gate E2_LOG_DIR=$T/var SITE=s1 PLATFORM=proxmox \
    HOST_SSH=ubuntu@10.0.0.5 HOST_KEY=$T/opkey POOL_FILE=$T/pools.yaml "$@"
}
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
has $T/admin.log "e2: host add gets the generated registration key" "ARG $T/var/m4-e2-proxmox-"
has $T/admin.log "e2: host add gets HOST_ADD_ARGS" "ARG virtio-d1"
hasnt $T/admin.log "e2: no --yes with fingerprints" "ARG --yes"
has $T/gate.log "e2: the gate runs the no-VM steps" "steps=g1 g2 g4 g5"
has $T/gate.log "e2: the gate gets the host, site and main IP" "host=vh0000000000000000000000ab location=s1 main=10.0.0.5"
has $T/gate.log "e2: the gate's root key is the registration key" "keyfile=present"
has "$log" "e2: output lines carry seconds" "[    0s] Registered host vh0000000000000000000000ab"
has "$log" "e2: phase times" "   host add "
has "$log" "e2: verdict" "PASS: host add exited 0, vh0000000000000000000000ab accepts VMs"

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
expect_rc 1 "e2: a failed gate fails the run" e2 HOST_ADD_YES=1 STUB_GATE_RC=1 scripts/byoh/verify/m4-e2.sh
has "$(ls $T/var/*.log)" "e2: the gate failure is the verdict" "== FAIL m2 gate"
expect_rc 2 "e2: an unknown platform" e2 HOST_ADD_YES=1 PLATFORM=gcp scripts/byoh/verify/m4-e2.sh
expect_rc 2 "e2: HOST_SSH without a user" e2 HOST_ADD_YES=1 HOST_SSH=10.0.0.5 scripts/byoh/verify/m4-e2.sh
expect_rc 2 "e2: site options without --" e2 HOST_ADD_YES=1 scripts/byoh/verify/m4-e2.sh --display x
expect_rc 2 "e2: SITE unset" e2 HOST_ADD_YES=1 SITE= scripts/byoh/verify/m4-e2.sh

# --- m4-f5-soak.sh ----------------------------------------------------
cat >$T/bin/checks <<'EOF'
#!/bin/bash
# Stub m2-checks: health lines for host $3; /tmp/t/sick-<host> holds how
# many more samples fail, /tmp/t/gone-<host> makes the command fail.
echo "$*" >>/tmp/t/checks.log
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
cat >$T/bin/sleep <<'EOF'
#!/bin/bash
echo "sleep $*" >>/tmp/t/sleep.log
EOF
chmod +x $T/bin/checks $T/bin/sleep
h1=vh00000000000000000000000a
h2=vh00000000000000000000000b
soak() {
  rm -rf "${T:?}/var" $T/checks.log $T/sleep.log $T/sick-* $T/gone-*
  env SOAK_CHECKS=$T/bin/checks SOAK_SLEEP=$T/bin/sleep SOAK_LOG_DIR=$T/var SOAK_SERVICES=tmux "$@"
}

expect_rc 1 "soak: fails while the monitor does not run" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 2
has "$(ls $T/var/*.log)" "soak: says to start the monitor" "FAIL the monitor does not run"
has "$(ls $T/var/*.log)" "soak: counts monitor-down samples" "2 failing, monitor down in 2"

bash -c 'exec -a "ruby bin/monitor" sleep 600' &
monitor=$!
expect_rc 0 "soak: passes healthy hosts" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --host $h2 --samples 3 --interval 5
[[ $(grep -c "health --host $h1 --probe" $T/checks.log) == 3 ]] && ok "soak: probes each host every sample" || bad "soak: probe count"
[[ $(grep -c "health --host $h2 --probe" $T/checks.log) == 3 ]] && ok "soak: probes the second host too" || bad "soak: second host probes"
[[ $(grep -c "^sleep 5$" $T/sleep.log) == 2 ]] && ok "soak: sleeps the interval between samples only" || bad "soak: sleep calls"
has "$(ls $T/var/*.log)" "soak: lines are prefixed with the host" "$h2 PASS host strand is at wait"
has "$(ls $T/var/*.log)" "soak: verdict" "== PASS"

expect_rc 1 "soak: one failing sample fails the soak" bash -c "$(declare -f soak); T=$T; soak bash -c 'echo 1 >$T/sick-$h2; scripts/byoh/verify/m4-f5-soak.sh --host $h1 --host $h2 --samples 3'"
has "$(ls $T/var/*.log)" "soak: names the failing host" "$h2: 1 failing sample(s)"
has "$(ls $T/var/*.log)" "soak: the other host passed" "$h1: 0 failing sample(s)"
expect_rc 1 "soak: a failing command fails the sample" bash -c "$(declare -f soak); T=$T; soak bash -c 'touch $T/gone-$h1; scripts/byoh/verify/m4-f5-soak.sh --host $h1 --samples 1'"
has "$(ls $T/var/*.log)" "soak: logs the command's error" "$h1 ! no host $h1"
expect_rc 0 "soak: hours and interval decide the sample count" soak scripts/byoh/verify/m4-f5-soak.sh --host $h1 --hours 1 --interval 600
[[ $(grep -c . $T/checks.log) == 7 ]] && ok "soak: 1 h every 600 s is 7 samples" || bad "soak: sample count $(grep -c . $T/checks.log)"
kill $monitor

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
