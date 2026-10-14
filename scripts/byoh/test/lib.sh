# shellcheck shell=bash
# Helpers for the BYOH container harness. Sourced by run.sh on the
# docker host. Every container is named ubi-m3-*, joins only the
# ubi-test-net network, publishes no ports, and is removed on exit only
# if this run created it.
#
# Never `set -x` here: the env file and its secrets are in scope.

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)
NET=${UBI_M3_NET:-ubi-test-net}
STATE=${UBI_M3_STATE:-$(mktemp -d "${TMPDIR:-/tmp}/ubi-m3.XXXXXX")}
ART=$STATE/art
LOGS=${UBI_M3_LOGS:-$STATE/logs}
mkdir -p "$ART" "$LOGS"
: >>"$STATE/created"

say() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOGS/harness.log"; }
fail() {
  say "FAIL: $*"
  exit 1
}

# start_sys NAME [IMAGE]: boots systemd as PID 1 in ubi-m3-NAME.
# systemd 255 does not boot without --privileged under a private cgroup
# namespace (it exits 255 with a read-only cgroup tree), so the harness
# needs it; it never bind mounts /sys/fs/cgroup.
start_sys() {
  local name=ubi-m3-$1 image=${2:-ubi-m3-systemd}
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
    s=$(docker exec "ubi-m3-$1" systemctl is-system-running 2>/dev/null) || true
    case $s in
      running) return 0 ;;
      degraded)
        docker exec "ubi-m3-$1" systemctl --failed --no-legend | tee -a "$LOGS/harness.log"
        return 0
        ;;
    esac
    sleep 1
  done
  fail "ubi-m3-$1 did not boot (state: ${s:-none})"
}

# dx NAME CMD...: runs CMD as root in ubi-m3-NAME.
dx() {
  local name=ubi-m3-$1
  shift
  docker exec -i "$name" "$@"
}

# Removes only the containers this run created.
cleanup() {
  local name
  if [[ ${UBI_M3_KEEP:-0} == 1 ]]; then
    say "keeping containers: $(tr '\n' ' ' <"$STATE/created")"
    return
  fi
  while read -r name; do
    [[ $name == ubi-m3-* ]] && docker rm -f "$name" >/dev/null 2>&1
  done <"$STATE/created"
  : >"$STATE/created"
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
  cp -R "$WT/packaging/systemd" "$ART/packaging/"
  cp "$HARNESS_DIR/fixture.sh" "$ART/fixture.sh"
  cp "$WT/scripts/byoh/install.sh" "$ART/install.sh"
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
