#!/bin/sh
# Runs inside an ubi-q-nokvm-* container that run.sh created and
# checked. POSIX sh: the Alpine image has only busybox.
#
#   inside.sh probe       run the probe on this container and on every
#                         fixture tree
#   inside.sh probe-apt   the same after apt-get install ruby (Ubuntu
#                         images without Ruby)
set -eu

RHIZOME=/w/rhizome
PROBE=$RHIZOME/host/bin/virt-probe
FIXTURES=$RHIZOME/host/spec/virt_probe_fixtures.rb

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The container cannot reach host kernel state: /sys and every proc
# mount but /proc are read-only, /dev/kvm is absent, and the bounding
# capabilities lack SYS_MODULE (16) and SYS_RAWIO (17).
guard() {
  awk '($3 == "sysfs" && $4 !~ /(^|,)ro(,|$)/) || ($3 == "proc" && $2 != "/proc" && $4 !~ /(^|,)ro(,|$)/) { print; bad = 1 } END { exit bad }' /proc/mounts ||
    fail "a sysfs or proc mount is writable"
  awk '$2 == "/proc/sys" && $4 ~ /(^|,)ro(,|$)/ { found = 1 } END { exit !found }' /proc/mounts ||
    fail "/proc/sys is not a read-only mount"
  [ ! -e /dev/kvm ] || fail "this container can see the host's KVM device"
  cap=$(awk '/^CapBnd/ { print $2 }' /proc/self/status)
  [ $((0x$cap >> 16 & 3)) -eq 0 ] || fail "the container holds CAP_SYS_MODULE or CAP_SYS_RAWIO ($cap)"
}

# check_report LABEL REPORT EXPECT: the probe's report must have the
# expected tier, cause, nested and ready.
check_report() {
  ruby -rjson -e '
    label, report, want = ARGV
    got = JSON.parse(report)
    want = JSON.parse(want)
    keys = %w[tier cause nested ready]
    if got.values_at(*keys) == want.values_at(*keys)
      puts "ok   #{label}: #{got["tier"]}"
    else
      warn "FAIL #{label}: got #{got.slice(*keys)}, want #{want.slice(*keys)}"
      exit 1
    end
  ' "$1" "$2" "$3"
}

probe() {
  ruby -v
  # This container itself: a data plane must not be a container.
  check_report "this container" "$(ruby "$PROBE" --json)" '{"tier":"container","cause":null,"nested":false,"ready":[]}'
  ruby "$PROBE" | sed 's/^/  /'
  failed=0
  for name in $(ruby "$FIXTURES" --list); do
    root=/scratch/fixtures/$name
    mkdir -p "$root"
    want=$(ruby "$FIXTURES" "$name" "$root")
    check_report "$name" "$(ruby "$PROBE" --root "$root" --json)" "$want" || failed=1
  done
  [ "$failed" -eq 0 ] || fail "fixture trees disagree with their expectations"
}

guard
case "${1:-}" in
  probe) probe ;;
  probe-apt)
    if ! command -v ruby >/dev/null; then
      apt-get -qq update >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends ruby >/dev/null
    fi
    probe
    ;;
  *) fail "unknown mode ${1:-}" ;;
esac
guard
echo "inside ok"
