#!/bin/bash
# Runs scripts/byoh/host/ubicloud-host preflight against the canned hosts
# in fixtures/host/ (WP5), each in a throwaway ubi-m4-pf-<case> container
# (ubuntu:24.04, ubi-test-net, --rm, no ports), and checks the verdicts.
#
#   preflight-fixtures.sh [--update-spec] [CASE...]
#
# Each case is fixtures/host/base with fixtures/host/<case> laid over it;
# <case>/.remove lists base paths the case deletes. The script reads the
# tree through --fixture-root and UBICLOUD_HOST_TEST_ROOT, and is fed on
# stdin (`bash -s`) as the control plane feeds it over ssh. Assertions:
#   <case>/expect   "ID STATUS" lines that must match
#   <case>/detail   "ID DETAIL" lines that must match exactly
#   <case>/noise    sourced first (BASH_ENV), as a noisy .bashrc would be
# and in every case: exit 0, each check id exactly once, nothing printed
# with the nonce that is not a check or a fact.
#
# Then one live run in the ubi-m4-fakehost image (no fixtures, no
# /dev/kvm) must fail PF3 with "no /dev/kvm", and its sshd fact must
# honour a `Match Host` block for --cp-ip.
#
# --update-spec writes each case's raw output to
# spec/fixtures/byoh/preflight/<case>.txt for spec/lib/byoh_host_preflight_spec.rb.
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

HOST_DIR=$WT/scripts/byoh/host
SPEC_OUT=$WT/spec/fixtures/byoh/preflight
NONCE=f1x7ure
CHECK_IDS=(PF1 PF3 PF4 PF5 PF6 PF7 PF-min-cpu PF8 PF8-hybrid PF9 PF10 PF10-btrfs PF10-zfs PF11 PF12 PF13 PF14
  PF15-apt PF15-egress PF16-docker PF16-ufw PF16-tailscaled PF16-k3s PF16-libvirtd PF16-pve PF16-rhizome-user PF19
  default-route main-ip-local)

update=0
if [[ ${1:-} == --update-spec ]]; then
  update=1
  shift
fi
cases=("$@")
if ((${#cases[@]} == 0)); then
  for d in "$FIXTURES"/*/; do
    d=${d%/}
    [[ ${d##*/} == base ]] || cases+=("${d##*/}")
  done
fi

# run_case CASE: prints the script's stdout; fails on a non-zero exit.
run_case() {
  local dir name=$PREFIX-pf-$1 env=() rc=0
  dir=$(pf_fixture "$1")
  [[ -f $dir/noise ]] && env=(-e BASH_ENV=/fx/noise)
  echo "$name" >>"$STATE/created"
  docker run --rm --name "$name" --network "$NET" -i \
    -v "$HOST_DIR:/h:ro" -v "$dir:/fx:ro" -e UBICLOUD_HOST_TEST_ROOT=/fx "${env[@]}" \
    docker.io/library/ubuntu:24.04 \
    bash -s preflight --json --nonce "$NONCE" --standalone --main-ip 203.0.113.10 --fixture-root /fx \
    <"$HOST_DIR/ubicloud-host" 2>"$LOGS/$1.err" || rc=$?
  ((rc == 0)) || fail "$1: exit $rc ($(tail -2 "$LOGS/$1.err" | tr '\n' ' '))"
}

# The check lines of an output as "ID STATUS" pairs. The nonce may follow
# noise on the same line.
pairs() {
  grep -o "UBIPF:$NONCE {\"kind\":\"check\".*" | sed -E 's/.*"id":"([^"]*)","status":"([^"]*)".*/\1 \2/'
}

detail_of() {
  grep -o "UBIPF:$NONCE {\"kind\":\"check\",\"id\":\"$1\".*" | sed -E 's/.*"detail":"([^"]*)",.*/\1/'
}

check_output() {
  local case=$1 out=$2 got id status want n line
  got=$(pairs <<<"$out")
  for id in "${CHECK_IDS[@]}"; do
    n=$(grep -c "^$id " <<<"$got" || true)
    ((n == 1)) || fail "$case: check $id printed $n times"
  done
  n=$(wc -l <<<"$got")
  ((n == ${#CHECK_IDS[@]})) || fail "$case: $n checks, expected ${#CHECK_IDS[@]}"
  n=$(grep -o "UBIPF:$NONCE .*" <<<"$out" | grep -cvE "^UBIPF:$NONCE \{\"kind\":\"(check|fact)\"," || true)
  ((n == 0)) || fail "$case: $n nonce lines are neither checks nor facts"
  for id in arch os_version mem_gib cpus_online storage_fstype ip_addr ip_route netplan host_keys sshd; do
    grep -q "UBIPF:$NONCE {\"kind\":\"fact\",\"id\":\"$id\"" <<<"$out" || fail "$case: no fact $id"
  done
  while read -r id want; do
    status=$(grep "^$id " <<<"$got" | cut -d' ' -f2)
    [[ $status == "$want" ]] || fail "$case: $id is $status, expected $want (detail: $(detail_of "$id" <<<"$out"))"
  done <"$FIXTURES/$case/expect"
  if [[ -f $FIXTURES/$case/detail ]]; then
    while read -r id want; do
      line=$(detail_of "$id" <<<"$out")
      [[ $line == "$want" ]] || fail "$case: $id detail is '$line', expected '$want'"
    done <"$FIXTURES/$case/detail"
  fi
}

[[ $update == 1 ]] && mkdir -p "$SPEC_OUT"
for case in base "${cases[@]}"; do
  [[ -f $FIXTURES/$case/expect ]] || fail "$case: no such fixture"
  out=$(run_case "$case")
  check_output "$case" "$out"
  [[ $update == 1 ]] && printf '%s\n' "$out" >"$SPEC_OUT/$case.txt"
  say "pass $case"
done

# Test mode needs both the flag and the variable, set alike.
rc=0
docker run --rm --name "$PREFIX-pf-guard" --network "$NET" -v "$HOST_DIR:/h:ro" docker.io/library/ubuntu:24.04 \
  bash /h/ubicloud-host preflight --fixture-root /h >/dev/null 2>&1 || rc=$?
((rc == 2)) || fail "--fixture-root without UBICLOUD_HOST_TEST_ROOT exited $rc, expected 2"
say "pass fixture guard"

# A live run on the fakehost image: real commands, no /dev/kvm.
prepare_fakehost_image
echo "$PREFIX-pf-live" >>"$STATE/created"
# A `Match Host` block for the control plane's address must reach the
# sshd fact, which needs host= in sshd -T -C.
out=$(docker run --rm --name "$PREFIX-pf-live" --network "$NET" -i --entrypoint bash "$FAKEHOST_IMAGE" \
  -c 'ssh-keygen -A >/dev/null && mkdir -p /run/sshd &&
    printf "Match Host 192.0.2.7\n  PermitRootLogin no\n" >/etc/ssh/sshd_config.d/99-pf-live.conf &&
    bash -s preflight --json --nonce '"$NONCE"' --standalone --cp-ip 192.0.2.7' <"$HOST_DIR/ubicloud-host")
grep -q "UBIPF:$NONCE {\"kind\":\"fact\",\"id\":\"sshd\",\"value\":{\"permitrootlogin\":\"no\"" <<<"$out" ||
  fail "live: the sshd fact misses the Match Host block ($(grep -o "UBIPF:$NONCE {\"kind\":\"fact\",\"id\":\"sshd\".*" <<<"$out"))"
[[ $(pairs <<<"$out" | grep '^PF3 ') == "PF3 fail" ]] || fail "live: PF3 is not fail"
[[ $(detail_of PF3 <<<"$out") == "no /dev/kvm" ]] || fail "live: PF3 detail is '$(detail_of PF3 <<<"$out")'"
n=$(pairs <<<"$out" | wc -l)
((n == ${#CHECK_IDS[@]})) || fail "live: $n checks, expected ${#CHECK_IDS[@]}"
say "pass live fakehost (PF3: no /dev/kvm; sshd Match Host)"
say "PASS preflight fixtures: ${#cases[@]} cases + base, guard, live"
