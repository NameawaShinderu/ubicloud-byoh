# shellcheck shell=bash
# Helpers for the BYOH container harness. Sourced by run.sh (M3) and
# m4-lib.sh (M4) on the docker host. Every container is named
# $PREFIX-* (UBI_TEST_PREFIX, default ubi-m3), joins only the
# ubi-test-net network, publishes no ports, and is removed on exit only
# if this run created it.
#
# Never `set -x` here: the env file and its secrets are in scope.

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)
PREFIX=${UBI_TEST_PREFIX:-ubi-m3}
IMAGE=${UBI_TEST_SYSTEMD_IMAGE:-ubi-m3-systemd}
NET=${UBI_M3_NET:-ubi-test-net}
STATE=${UBI_M3_STATE:-$(mktemp -d "${TMPDIR:-/tmp}/$PREFIX.XXXXXX")}
ART=$STATE/art
LOGS=${UBI_M3_LOGS:-$STATE/logs}
mkdir -p "$ART" "$LOGS"
: >>"$STATE/created"

say() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOGS/harness.log"; }
fail() {
  say "FAIL: $*"
  exit 1
}

# start_sys NAME [IMAGE]: boots systemd as PID 1 in $PREFIX-NAME.
# systemd 255 does not boot without --privileged under a private cgroup
# namespace (it exits 255 with a read-only cgroup tree), so the harness
# needs it; it never bind mounts /sys/fs/cgroup.
start_sys() {
  local name=$PREFIX-$1 image=${2:-$IMAGE}
  docker run -d --name "$name" --network "$NET" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock -v "$ART:/art:ro" "$image" /sbin/init >/dev/null
  echo "$name" >>"$STATE/created"
  wait_booted "$1"
  # On a real machine systemd makes / shared at boot; in a container it
  # leaves docker's private mounts alone, and systemd's credentials
  # (LoadCredential=, used by ubicloud-cloudflared) are then mounted
  # where the service never sees them. This undoes that difference
  # inside the container's own mount namespace only.
  docker exec "$name" mount --make-rshared /
  # The login check relies on curl sending Secure cookies to localhost
  # over http, which depends on the curl version.
  say "$1: $(docker exec "$name" systemctl --version | head -1); $(docker exec "$name" curl --version | head -1)"
}

wait_booted() {
  local s
  for _ in $(seq 120); do
    s=$(docker exec "$PREFIX-$1" systemctl is-system-running 2>/dev/null) || true
    case $s in
      running) return 0 ;;
      degraded)
        docker exec "$PREFIX-$1" systemctl --failed --no-legend | tee -a "$LOGS/harness.log"
        return 0
        ;;
    esac
    sleep 1
  done
  fail "$PREFIX-$1 did not boot (state: ${s:-none})"
}

# dx NAME CMD...: runs CMD as root in $PREFIX-NAME.
dx() {
  local name=$PREFIX-$1
  shift
  docker exec -i "$name" "$@"
}

# Removes only the containers this run created, and only those that
# carry this run's prefix; other prefixes' records stay in the file.
cleanup() {
  local name
  if [[ ${UBI_M3_KEEP:-0} == 1 ]]; then
    say "keeping containers: $(tr '\n' ' ' <"$STATE/created")"
    return
  fi
  while read -r name; do
    [[ $name == "$PREFIX"-* ]] && docker rm -f "$name" >/dev/null 2>&1
  done <"$STATE/created"
  # Keeps the records of another prefix sharing this state dir, so that
  # run's own cleanup still removes them.
  grep -v "^$PREFIX-" "$STATE/created" >"$STATE/created.tmp" || true
  mv "$STATE/created.tmp" "$STATE/created"
}

# Archives the working tree, untracked but not ignored files included,
# without touching the real index. The tree id is the rev.
src_tarball() {
  local tmp tree
  tmp=$(mktemp)
  cp "$(git -C "$WT" rev-parse --absolute-git-dir)/index" "$tmp"
  GIT_INDEX_FILE=$tmp git -C "$WT" add -A
  tree=$(GIT_INDEX_FILE=$tmp git -C "$WT" write-tree)
  rm -f "$tmp"
  git -C "$WT" archive -o "$ART/src.tgz" "$tree"
  echo "$tree" >"$ART/src.rev"
}

# Copies what the containers read from /art besides the source tarball.
stage_art() {
  rm -rf "$ART/packaging"
  mkdir -p "$ART/packaging"
  cp -R "$WT/packaging/systemd" "$WT/packaging/bin" "$ART/packaging/"
  cp "$HARNESS_DIR/fixture.sh" "$ART/fixture.sh"
  cp "$WT/scripts/byoh/install.sh" "$ART/install.sh"
  cp "$WT/scripts/byoh/verify/m2-gate.sh" "$ART/m2-gate.sh"
  cp "$WT/mise.toml" "$ART/mise.toml"
  chmod -R a+rX "$ART"
}

# wait_for TIMEOUT CMD...: polls CMD once a second; prints the seconds
# it took, or returns 1 after TIMEOUT seconds.
wait_for() {
  local timeout=$1 start now
  shift
  start=$(date +%s.%N)
  while :; do
    if "$@" >/dev/null 2>&1; then
      now=$(date +%s.%N)
      awk -v a="$start" -v b="$now" 'BEGIN { printf "%.1f\n", b - a }'
      return 0
    fi
    now=$(date +%s.%N)
    if awk -v a="$start" -v b="$now" -v t="$timeout" 'BEGIN { exit !(b - a > t) }'; then
      return 1
    fi
    sleep 0.2
  done
}

# timed CMD...: runs CMD once and prints the seconds it took; returns
# CMD's status.
timed() {
  local start rc=0
  start=$(date +%s.%N)
  "$@" >/dev/null 2>&1 || rc=$?
  awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f\n", b - a }'
  return "$rc"
}
