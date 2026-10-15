#!/bin/bash
# Lab harness for the no-KVM virtualization ladder (docs/byoh/NO_KVM.md
# section 8). Runs on a shared docker host that HAS /dev/kvm, so every
# container must be proven unable to see it, or a test would fake the
# no-KVM case. It fails closed: a container whose docker inspect breaks a
# rule below is removed before it starts.
#
#   run.sh lint    static checks of the harness scripts only
#   run.sh probe   the real probe in ubuntu:24.04 (distribution Ruby) and
#                  in Alpine (expect tier container), and every fixture
#                  tree of rhizome/host/spec/fixtures/virt_probe in both
#
# Guest-running modes (l3, l5) come with WP5/WP6 and must also install
# the nft drop toward the test network before any guest starts.
#
# Rules for every container (checked with docker inspect before start):
#   - named ubi-q-nokvm-*, network ubi-test-net, no published ports
#   - not privileged; no device but /dev/net/tun; capabilities added only
#     from NET_ADMIN SYS_ADMIN NET_RAW; no unconfined seccomp, AppArmor
#     or systempaths; no host PID/IPC/UTS/user namespace
#   - CPUs 12-15, 4 CPUs, 6 GiB
#   - binds: only rhizome/ and this directory, read-only
# Inside, at start and at teardown: /sys and every proc mount but /proc
# read-only, no /dev/kvm, no CAP_SYS_MODULE or CAP_SYS_RAWIO.
# On the host, before and after: loaded modules, vm.nr_hugepages and
# some kernel.* settings must not change.
#
# Environment: NOKVM_UBUNTU_IMAGE (ubuntu:24.04), NOKVM_ALPINE_IMAGE
# (ruby:4.0.2-alpine3.23), NOKVM_KEEP=1 keeps containers.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(git -C "$HERE" rev-parse --show-toplevel)
NET=ubi-test-net
CPUSET=12-15
NANO_CPUS=4000000000
MEMORY_BYTES=6442450944
MIN_FREE_GB=7
UBUNTU_IMAGE=${NOKVM_UBUNTU_IMAGE:-ubuntu:24.04}
ALPINE_IMAGE=${NOKVM_ALPINE_IMAGE:-ruby:4.0.2-alpine3.23}
STATE=$(mktemp -d "${TMPDIR:-/tmp}/ubi-q-nokvm.XXXXXX")
CREATED=()

say() { printf '[nokvm %s] %s\n' "$(date +%T)" "$*"; }
fail() {
  say "FAIL: $*" >&2
  exit 1
}

cleanup() {
  local c
  if [ "${NOKVM_KEEP:-0}" != 1 ]; then
    for c in "${CREATED[@]+"${CREATED[@]}"}"; do
      docker rm -f "$c" >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$STATE"
}
trap cleanup EXIT

# Commands that must never appear in the harness, outside the lines
# that name them (marked "lint: allow").
lint() {
  local hits
  hits=$(grep -nE '(^|[^[:alnum:]_-])(modprobe|insmod|rmmod)([^[:alnum:]_-]|$)|sysctl +-w|--privileged|--device[= ]+/dev/kvm|/dev/kvm:' "$HERE"/*.sh | grep -v 'lint: allow' || true) # lint: allow
  [ -z "$hits" ] || fail "forbidden command in the harness: $hits"
  say "lint ok"
}

disk_check() {
  local free
  free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  [ "$free" -ge "$MIN_FREE_GB" ] || fail "only ${free} GB free on /, need ${MIN_FREE_GB}"
}

# What the containers must not change on the host. Read only.
host_state() {
  local k
  awk '{print $1}' /proc/modules | sort
  echo "vm.nr_hugepages=$(cat /proc/sys/vm/nr_hugepages)"
  for k in apparmor_restrict_unprivileged_userns unprivileged_userns_clone dmesg_restrict kptr_restrict yama/ptrace_scope; do
    echo "kernel.$k=$(cat "/proc/sys/kernel/$k" 2>/dev/null || echo -)"
  done
}

image_check() {
  docker image inspect "$1" >/dev/null 2>&1 && return
  disk_check
  say "pulling $1"
  docker pull -q "$1" >/dev/null
}

# field NAME TEMPLATE: what docker inspect says about the container.
field() { docker inspect --format "$2" "$1"; }

# assert_safe NAME: refuses (and removes) a created container that breaks
# a rule. Every value comes from docker inspect, not from what we asked.
assert_safe() {
  local name=$1 item bind src
  case "$name" in ubi-q-nokvm-*) ;; *) fail "$name: not an ubi-q-nokvm-* name" ;; esac
  [ "$(field "$name" '{{.HostConfig.Privileged}}')" = false ] || fail "$name: privileged"
  for item in $(field "$name" '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}'); do
    [ "$item" = /dev/net/tun ] || fail "$name: device $item"
  done
  for item in $(field "$name" '{{range .HostConfig.CapAdd}}{{.}} {{end}}'); do
    case "${item#CAP_}" in NET_ADMIN | SYS_ADMIN | NET_RAW) ;; *) fail "$name: capability $item" ;; esac
  done
  for item in $(field "$name" '{{range .HostConfig.SecurityOpt}}{{.}} {{end}}'); do
    case "$item" in *unconfined* | *systempaths*) fail "$name: security option $item" ;; esac
  done
  [ "$(field "$name" '{{len .HostConfig.PortBindings}}{{.HostConfig.PublishAllPorts}}')" = 0false ] || fail "$name: published ports"
  [ "$(field "$name" '{{.HostConfig.NetworkMode}}')" = "$NET" ] || fail "$name: network is not $NET"
  for item in PidMode IpcMode UTSMode UsernsMode; do
    [ "$(field "$name" "{{.HostConfig.$item}}")" != host ] || fail "$name: host $item"
  done
  [ "$(field "$name" '{{.HostConfig.CpusetCpus}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}')" = "$CPUSET $NANO_CPUS $MEMORY_BYTES" ] ||
    fail "$name: CPU or memory limits are not $CPUSET / $NANO_CPUS / $MEMORY_BYTES"
  [ "$(field "$name" '{{len .HostConfig.Mounts}}')" = 0 ] || fail "$name: --mount is not allowed, use the checked binds"
  for bind in $(field "$name" '{{range .HostConfig.Binds}}{{.}} {{end}}'); do
    src=${bind%%:*}
    case "$bind" in *:ro) ;; *) fail "$name: bind $bind is not read-only" ;; esac
    [ "$src" = "$WT/rhizome" ] || [ "$src" = "$HERE" ] || fail "$name: bind $src is not allowed"
  done
}

# run_in NAME IMAGE MODE: creates ubi-q-nokvm-NAME, checks it, and runs
# inside.sh MODE in it.
run_in() {
  local name=ubi-q-nokvm-$1 image=$2 mode=$3
  ! docker container inspect "$name" >/dev/null 2>&1 || fail "$name exists; remove it by hand if it is yours"
  docker create --name "$name" --network "$NET" --cpuset-cpus="$CPUSET" --cpus=4 --memory=6g \
    --security-opt no-new-privileges --tmpfs /scratch:rw,exec,nosuid,nodev,size=256m \
    -v "$WT/rhizome:/w/rhizome:ro" -v "$HERE:/w/nokvm:ro" -w /w \
    "$image" sh /w/nokvm/inside.sh "$mode" >/dev/null
  CREATED+=("$name")
  assert_safe "$name"
  say "$name ($image): $mode"
  docker start -a "$name" || fail "$name: $mode failed"
}

probe() {
  local before
  image_check "$UBUNTU_IMAGE"
  image_check "$ALPINE_IMAGE"
  before=$(host_state)
  run_in probe-ubuntu "$UBUNTU_IMAGE" probe-apt
  run_in probe-alpine "$ALPINE_IMAGE" probe
  [ "$before" = "$(host_state)" ] ||
    fail "host kernel state changed during the run (another workload on this machine may have done it): $(diff <(echo "$before") <(host_state) || true)"
  say "probe ok"
}

case "${1:-}" in
  lint) lint ;;
  probe)
    lint
    probe
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d'
    exit 2
    ;;
esac
