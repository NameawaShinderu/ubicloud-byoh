#!/bin/bash
# Runs scripts/byoh/test/real/pvm-e2e.sh (the PVM tier's real-run script,
# PVM plan WP10) against the fake world of pvm-e2e-fake.sh: admin, bundle,
# ubi, ssh, sleep and pgrep are that one fake, so every phase runs its
# real logic against answers like the real ones, and nothing reaches a
# host. It proves the phases' flow, their checks and their failure paths,
# not the product: the real run stays UNVERIFIED until the lead runs it.
#
# One ubi-q-pvm-e2e container (ruby:alpine-based ubi-bundler-m1 or IMG,
# on ubi-test-net, no ports) with the worktree mounted read-only.
#
#   scripts/byoh/test/pvm-e2e-stubs.sh
set -euo pipefail

WT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
NAME=ubi-q-pvm-e2e
docker rm -f "$NAME" >/dev/null 2>&1 || true
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

docker run -i --rm --name "$NAME" --network ubi-test-net -v "$WT:/w:ro" -w /w "${IMG:-ubi-bundler-m1}" sh -c '
apk add --quiet bash openssh-client coreutils >/dev/null 2>&1 || exit 9
exec bash -s' <<'INNER'
set -euo pipefail
T=/tmp/t
fails=0
ok() { echo "ok   $*"; }
bad() {
  echo "FAIL $*"
  fails=$((fails + 1))
}

GUEST2=1111111111111111111111111111111111111111111111111111111111111111
# run NAME [ENV=VALUE...] -- PHASE...: a fresh fake world and work dir.
run() {
  local name=$1
  shift
  local envs=()
  while [[ $1 != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  rm -rf "$T"
  mkdir -p "$T/bin" "$T/fake" "$T/work"
  for b in admin bundle ubi ssh sleep pgrep; do ln -s /w/scripts/byoh/test/pvm-e2e-fake.sh "$T/bin/$b"; done
  echo "operator key" >"$T/opkey"
  set +e
  env PATH="$T/bin:$PATH" FAKE="$T/fake" FAKE_WORK="$T/work" FAKE_SCRATCH=byoh-pvm-e2e-neg FAKE_GUEST2=$GUEST2 FAKE_PROJECT2=pj2 \
    BYOH_REAL_E2E=1 PVM_E2E_HOST_SSH=ubuntu@10.0.0.5 PVM_E2E_HOST_KEY="$T/opkey" PVM_E2E_YES=1 \
    PVM_E2E_SITE_ARGS="--rates-from hetzner-fsn1 --ula48 fd00:1:2::/48" PVM_E2E_PROJECT=pj1 PVM_E2E_PROJECT2=pj2 \
    UBI_TOKEN=t UBI_URL=http://127.0.0.1:3000/cli PVM_E2E_UBI=ubi ADMIN=admin PVM_E2E_WORK="$T/work" \
    PVM_E2E_GUEST2_URL=https://example.com/vmlinux2 PVM_E2E_GUEST2_SHA256=$GUEST2 \
    "${envs[@]}" timeout 300 scripts/byoh/test/real/pvm-e2e.sh "$@" >"$T/out" 2>&1
  RC=$?
  set -e
  cp "$T/out" "/tmp/out-$name"
}
report_has() {
  if grep -qF -- "$2" "$T/work/pvm-e2e-report.txt"; then ok "$1"; else
    bad "$1: no '$2' in the report"
    sed 's/^/     | /' "$T/out" | tail -40
  fi
}
rc_is() {
  if [[ $RC == "$2" ]]; then ok "$1 (exit $RC)"; else
    bad "$1: exit $RC, wanted $2"
    sed 's/^/     | /' "$T/out" | tail -60
  fi
}

# The happy path: every phase passes, in order.
run all -- all
rc_is "all phases pass against the fake" 0
for p in location neg-sha host-add patch-kernel host-check vm prod-path bench lifecycle host-reboot oob-reboot \
  power-cycle tenancy guest-pin-rollout refusals stock-return delete billing teardown; do
  report_has "phase $p passed" "== $p: PASS"
done
report_has "the example pins carry their label" "third party; Januscape fix inclusion UNVERIFIED"
report_has "the wrong guest sha256 is refused" "PASS  set with a wrong guest kernel sha256 is refused"
report_has "the neg-sha install is refused before any change" "PASS  GRUB (saved_entry, next_entry), the kernel packages and /etc/grub.d are unchanged"
report_has "the power cycle is a MANUAL step" "MANUAL stop the instance"
report_has "without a monitor the host notices the boot itself" "no bin/monitor (the BYOH default): HostNexus#wait on the pvm host compares its boot id itself"
report_has "the out-of-band boot is noticed by its boot id" "PASS  HostNexus recorded the new boot id boot-"
grep -q 'setting checkup' "$T/work/pvm-e2e-report.txt" && bad "the run set checkup without PVM_E2E_SET_CHECKUP=1" || ok "the run sets no checkup by default"
report_has "the guest kernel is checked in the running unit" "PASS  the VM boots the pinned guest kernel: its running cloud-hypervisor has --kernel /opt/pvm-guest/84dcf08143ce7e945a770ff1b6d25e0505c1da69d674831b470cabc139598acb/vmlinux"
report_has "the guest's uname -r is checked" "PASS  the VM boots the pinned guest kernel: the guest runs 6.12.33-pvm"
report_has "a restart keeps the unit's kernel" "PASS  after a restart: its unit boots /opt/pvm-guest/84dcf08143ce7e945a770ff1b6d25e0505c1da69d674831b470cabc139598acb/vmlinux"
report_has "stop and start boots the new kernel" "PASS  after stop and start: the guest runs 6.12.34-pvm"
report_has "the host refuses a wrong guest kernel in bring-up" "PASS  the host waits at pvm_guest_kernel_refused"
report_has "the guest refusal changes nothing" "PASS  GRUB, the kernel packages and /etc/grub.d are unchanged by the guest refusal"
report_has "every phase ran" "== summary: every phase given passed"
report_has "the bench prints ratios" "ratio cpu_sha256_1g: guest 1200 ms, host 1000 ms"
report_has "a restart keeps the guest kernel" "PASS  a restart keeps the VM's guest kernel"
report_has "stop and start moves to the new guest kernel" "PASS  after stop and start the VM boots the new guest kernel"
report_has "the stock return pages" "PASS  ByohPvmBoot pages the stock boot"
report_has "jammy is refused" "PASS  a pvm-2 ubuntu-jammy VM is refused"
report_has "billing is closed" "PASS  every record is closed"
report_has "teardown returns to a stock kernel" "PASS  a stock kernel runs, not a PVM one (7.0.0-1015-aws)"
report_has "teardown accepts the newer stock kernel patch added" "PASS  it is the newest stock kernel after patch (7.0.0-1015-aws) or the pinned one (7.0.0-1014-aws)"
report_has "teardown checks the running kernel's package" "PASS  the running kernel is an installed stock package (linux-image-7.0.0-1015-aws)"
report_has "the scratch site is added without the main site's ula48" "PASS  site add byoh-pvm-e2e-neg"
report_has "the host-check probe goes over the run's own connection" "PASS  the probe says pvm"
report_has "teardown leaves no page of the host open" "PASS  no page of host vh0000000000000000000000ab is left open"
report_has "upstream's LastBootIDDiscrepancy is only shown" "info  left open (upstream): page=LastBootIDDiscrepancy"
grep -q 'unhandled' "$T/out" && bad "the fake met a command it does not know: $(grep unhandled "$T/out" | head -3)" || ok "the fake knew every command"

# Failures stop the run with exit 1 at the phase that failed.
run accept FAKE_ACCEPT_WRONG_GUEST=1 -- location neg-sha host-add
rc_is "a wrong guest sha256 that set accepts fails neg-sha" 1
report_has "neg-sha reports it" "FAIL  set with a wrong guest kernel sha256 was accepted"
report_has "neg-sha fails" "== neg-sha: FAIL"
grep -q '== host-add' "$T/work/pvm-e2e-report.txt" && bad "host-add ran after a failed phase" || ok "no phase runs after a failure"

run grub FAKE_NEG_CHANGES_GRUB=1 -- location neg-sha
rc_is "a refused install that touched GRUB fails neg-sha" 1
report_has "neg-sha names the change" "FAIL  GRUB (saved_entry, next_entry), the kernel packages and /etc/grub.d are unchanged"

run vmstart FAKE_STOCK_RETURN_STARTS_VM=1 -- location neg-sha host-add vm stock-return
rc_is "a VM started on a stock boot fails stock-return" 1
report_has "stock-return names it" "FAIL  no VM was started (no cloud-hypervisor)"

run pages FAKE_DESTROY_LEAVES_PAGES=1 PVM_E2E_PAGE_WAIT=0 -- location neg-sha
rc_is "a destroy that leaves the scratch host's page open fails neg-sha" 1
report_has "neg-sha names the page" "FAIL  no page of host vh0000000000000000000000cd is left open"

# Without a second guest build the rollout is reported as not run.
run noguest PVM_E2E_GUEST2_URL= PVM_E2E_PROJECT2= -- location neg-sha host-add vm tenancy guest-pin-rollout
rc_is "guest-pin-rollout without a second build is NOT RUN, not a failure" 0
report_has "it skips the rollout" "SKIP  guest-pin-rollout (PVM_E2E_GUEST2_URL and PVM_E2E_GUEST2_SHA256 are unset) (NOT RUN, UNVERIFIED)"
report_has "the phase line says NOT RUN" "== guest-pin-rollout: NOT RUN (UNVERIFIED)"
report_has "tenancy without a second project passes with a note" "== tenancy: PASS with 1 note(s)"
report_has "the summary lists the skips" "== summary: no phase failed, but not every check ran"
report_has "the summary names the rollout" "  guest-pin-rollout: NOT RUN (UNVERIFIED)"
report_has "the summary names the grant" "  tenancy: NOT RUN: a grant to a second project is refused (PVM_E2E_PROJECT2 is unset)"

# An out-of-band boot the host strand does not notice by itself fails;
# PVM_E2E_SET_CHECKUP=1 passes it, marked as simulated.
run noself FAKE_NO_SELF_CHECK=1 PVM_E2E_BOOT_WAIT=0 -- location neg-sha host-add vm oob-reboot
rc_is "an out-of-band boot the host does not notice fails oob-reboot" 1
report_has "oob-reboot names it" "FAIL  HostNexus recorded the new boot id boot-"
run setcheckup FAKE_NO_SELF_CHECK=1 PVM_E2E_SET_CHECKUP=1 -- location neg-sha host-add vm oob-reboot
rc_is "PVM_E2E_SET_CHECKUP=1 passes oob-reboot" 0
report_has "the checkup is set by the run" "setting checkup on vh0000000000000000000000ab"
report_has "the summary says it was simulated" "  oob-reboot: detection simulated: checkup set by the script"

# A start that moves the guest kernel row but not the unit fails the rollout.
run unit FAKE_UNIT_NOT_REWRITTEN=1 -- location neg-sha host-add vm guest-pin-rollout
rc_is "a unit that keeps the old kernel fails guest-pin-rollout" 1
report_has "guest-pin-rollout names the unit" "FAIL  after stop and start: its unit boots /opt/pvm-guest/$GUEST2/vmlinux"

run guestgrub FAKE_NEG_GUEST_CHANGES_GRUB=1 -- location neg-sha
rc_is "a guest kernel refusal that touched GRUB fails neg-sha" 1
report_has "neg-sha names the change" "FAIL  GRUB, the kernel packages and /etc/grub.d are unchanged by the guest refusal"

# Usage and refusals.
run refuse BYOH_REAL_E2E=0 -- all
rc_is "refuses without BYOH_REAL_E2E=1" 2
grep -q "refusing: this installs a custom kernel" "$T/out" && ok "says why" || bad "no refusal text"
run nophase -- frob
rc_is "an unknown phase is a usage error" 2
run nohost PVM_E2E_HOST_SSH= -- location
rc_is "PVM_E2E_HOST_SSH is required" 2
run nokey PVM_E2E_YES=0 -- location
rc_is "a host key fingerprint or PVM_E2E_YES=1 is required" 2
run nostate -- vm
rc_is "a phase whose host is not recorded is a usage error" 2
grep -q "run host-add first" "$T/out" && ok "it names the phase to run" || bad "no hint: $(cat "$T/out")"

echo "$fails failed"
((fails == 0))
INNER
