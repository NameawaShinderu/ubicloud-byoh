#!/usr/bin/env bash
# L4-T2: the PVM tier end to end on a real cloud VM without hardware
# virtualization (docs/byoh/NO_KVM.md sections 6.7 and 6.8, the PVM plan's
# WP10). Where pvm-go-no-go.sh (next to this file) proved that a PVM guest
# boots by hand, this run drives the product: a location that pins the
# kernels, `host add --virt-tier pvm --install-pvm-kernel`, VMs through the
# API, their lifecycle, host reboots of every kind, a guest kernel
# rollout, the recovery path and teardown.
#
# Run it on the control plane, from the repository root, against ONE
# throwaway Ubuntu 24.04 x86_64 instance without nested virtualization
# that you can stop and start from the provider console. Recommended: AWS
# m6i.2xlarge (an m6i.large fails verify_tier_capacity with one core, an
# m6i.xlarge fits one pvm-2), Secure Boot off. scripts/byoh/test/aws-e2e
# launches it as role pvme. The host gets an out-of-tree kernel and boots
# it with pti=off; never point this at anything you care about. It
# refuses to do anything unless BYOH_REAL_E2E=1.
#
#   BYOH_REAL_E2E=1 scripts/byoh/test/real/pvm-e2e.sh all
#   BYOH_REAL_E2E=1 scripts/byoh/test/real/pvm-e2e.sh vm lifecycle   # resume
#
# Phases, in this order (each needs the ones before it; `all` runs them
# all and stops at the first that fails; a phase can be rerun on its own):
#   location           site add (unless it exists), pvm rates, set with the pins
#   neg-sha            a wrong guest sha256 refused by set; a wrong host-deb
#                      sha256 refused on the host before any change; a wrong
#                      guest sha256 refused by the host in bring-up
#   host-add           host add --virt-tier pvm --install-pvm-kernel to accepting
#   patch-kernel       the stock kernel the install pinned is the one that ran
#   host-check         PVM kernel, pti=off, GRUB, /dev/kvm, kvm_pvm, unit, probe, holds
#   vm                 a pvm-2 VM: SSH, DNS, egress, apt, serial log, API fields
#   prod-path          fio through ubiblk, download speed, host memory, vs the host
#   bench              the go/no-go benchmarks in the VM and on the host
#   lifecycle          stop, start, restart, SSH after each
#   host-reboot        HostNexus reboot; VMs and the PVM boot come back
#   oob-reboot         reboot on the host behind the control plane's back
#   power-cycle        MANUAL: stop and start the instance from the console
#   tenancy            the location stays single-project
#   guest-pin-rollout  a second guest kernel pin reaches the VM at stop/start
#   refusals           a pvm-2 VM of an image the tier cannot boot is refused
#   stock-return       a PVM boot that does not happen: page, stock, pvm retry
#   delete             the VM and everything of it on the host go away
#   billing            the VM's family-pvm billing records span its life
#   teardown           pvm uninstall, destroy, reboot: the stock host is back
#
# Steps that need the provider console print MANUAL: and wait for Enter
# (or, without a terminal, for the file $PVM_E2E_WORK/manual-done).
#
# Settings (environment; defaults in brackets):
#   PVM_E2E_SITE         BYOH location (site) for the run [byoh-pvm-e2e]
#   PVM_E2E_SITE_ARGS    site add options, split on spaces, used when the
#                        site does not exist yet; must copy standard rates,
#                        e.g. "--underlay 10.98.0.0/16 --cp-reach onhost
#                        --rates-from hetzner-fsn1" (the scratch site of
#                        neg-sha is created with the same options, less
#                        the ones each location must have its own value
#                        of: --ula48, --display-name and --ui-name)
#   PVM_E2E_SCRATCH_SITE location of the neg-sha registration [$PVM_E2E_SITE-neg]
#   PVM_E2E_HOST_SSH     the operator's login to the host, USER@HOST
#   PVM_E2E_HOST_KEY     the operator's private key for that login
#   PVM_E2E_MAIN_IP      the host's main IP [the host part of PVM_E2E_HOST_SSH]
#   PVM_E2E_EXPECT_HOST_KEY  SHA256:... host key fingerprint(s); or
#   PVM_E2E_YES=1        trust the key ssh meets (host add --yes)
#   PVM_E2E_POOL_FILE    pools.yaml of the host; without it the VMs are
#                        IPv6-only and reach the internet through the host NAT
#   PVM_E2E_PROJECT      ubid of the project of UBI_TOKEN; the site is
#                        granted to it
#   PVM_E2E_PROJECT2     ubid of another project, which tenancy must not
#                        be able to grant (that check is skipped without it)
#   UBI_TOKEN, UBI_URL   personal access token of PVM_E2E_PROJECT and the
#                        control plane's CLI endpoint (https://<host>/cli)
#   PVM_E2E_UBI          the ubi command, split on spaces [bin/ubi]
#   PVM_E2E_UBI_LOCATION the site's name in the API [$PVM_E2E_SITE]
#   PVM_E2E_WORK         state, keys, logs and the report [var/pvm-e2e]
#   PVM_E2E_INSTANCE     the instance id, only printed in MANUAL steps
#   PVM_E2E_PAGE_WAIT    seconds a destroyed host's pages may take to resolve [300]
#   PVM_E2E_BOOT_WAIT    seconds HostNexus may take to notice a boot it did
#                        not ask for [1200; its wait checks every 300]
#   PVM_E2E_SET_CHECKUP=1  set checkup after an out-of-band boot as
#                        bin/monitor would, instead of testing that the pvm
#                        host notices it by itself (reported as simulated)
#   ADMIN                the ubicloud-admin command [sudo ubicloud-admin on a
#                        packaged control plane, else packaging/bin/ubicloud-admin --dev]
#   PVM_HOST_DEB_URL, PVM_HOST_DEB_SHA256, PVM_GUEST_KERNEL_URL,
#   PVM_GUEST_KERNEL_SHA256, PVM_GUEST_CONFIG_URL, PVM_GUEST_CONFIG_SHA256
#                        the location's pins [the cocoonstack/pvm v0.1.0
#                        example below]
#   PVM_E2E_GUEST2_URL, PVM_E2E_GUEST2_SHA256 (and optionally
#   PVM_E2E_GUEST2_CONFIG_URL, PVM_E2E_GUEST2_CONFIG_SHA256)
#                        a second guest kernel build for guest-pin-rollout,
#                        which is reported NOT RUN without them
#
# The default pins are the cocoonstack/pvm v0.1.0 release that the
# go/no-go booted. THIRD PARTY; Januscape fix inclusion UNVERIFIED; for
# testing only, not a recommended production pin (docs/byoh/NO_KVM.md
# section 6.7). The product has no default pin: an operator chooses one.
#
# Report: $PVM_E2E_WORK/pvm-e2e-report.txt, one block per phase run.
# Exit codes: 0 every phase given passed, 1 a phase failed, 2 refused or a
# usage error.
#
# Not covered on hardware by this run, only by mocked specs and the fake
# world (UNVERIFIED on a real host): an install that fails after it
# changed the host (exit 3, un-armed) and `pvm retry` or `pvm uninstall`
# from that partial state; an `arm` that fails (pvm_not_rebooted,
# `pvm retry --reboot-vms`); a PVM host-kernel upgrade; a Meltdown-affected
# CPU.
#
# The report ends with a summary of every check a phase skipped (NOT
# RUN) or simulated (PVM_E2E_SET_CHECKUP=1); without it every phase ran.
#
# UNVERIFIED: this script has never run against a real host. Only its
# refusal without BYOH_REAL_E2E=1, its usage errors and its static checks
# (spec/lib/byoh_pvm_e2e_script_spec.rb, bash -n, shellcheck) were run.

set -euo pipefail

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  sed -n '2,/^# (spec/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ ${BYOH_REAL_E2E:-0} != 1 ]]; then
  echo "pvm-e2e: refusing: this installs a custom kernel on a real host and reboots it many times." >&2
  echo "Run it only against a throwaway instance, with BYOH_REAL_E2E=1 (see the header of $0)." >&2
  exit 2
fi

PHASES=(location neg-sha host-add patch-kernel host-check vm prod-path bench lifecycle host-reboot oob-reboot
  power-cycle tenancy guest-pin-rollout refusals stock-return delete billing teardown)

usage_die() {
  echo "pvm-e2e: $*" >&2
  echo "usage: BYOH_REAL_E2E=1 $0 all | PHASE... (phases: ${PHASES[*]})" >&2
  exit 2
}

(($#)) || usage_die "name the phases to run, or all"
RUN=()
for arg in "$@"; do
  if [[ $arg == all ]]; then
    RUN+=("${PHASES[@]}")
  elif [[ " ${PHASES[*]} " == *" $arg "* ]]; then
    RUN+=("$arg")
  else
    usage_die "unknown phase $arg"
  fi
done

[[ -f loader.rb && -d scripts/byoh ]] || usage_die "run it from the repository root on the control plane"

need() {
  local v
  for v in "$@"; do
    [[ -n ${!v:-} ]] || usage_die "$v is not set; see the header of $0"
  done
}

need PVM_E2E_HOST_SSH PVM_E2E_HOST_KEY
[[ $PVM_E2E_HOST_SSH == *@* ]] || usage_die "PVM_E2E_HOST_SSH must be USER@HOST"
[[ -r $PVM_E2E_HOST_KEY ]] || usage_die "PVM_E2E_HOST_KEY $PVM_E2E_HOST_KEY is not readable"
[[ -n ${PVM_E2E_EXPECT_HOST_KEY:-} || ${PVM_E2E_YES:-0} == 1 ]] || usage_die "set PVM_E2E_EXPECT_HOST_KEY, or PVM_E2E_YES=1 to trust the key ssh meets"
MAIN_IP=${PVM_E2E_MAIN_IP:-${PVM_E2E_HOST_SSH#*@}}

# The example pins (D5 of the PVM plan): see the header.
EXAMPLE_LABEL="third party; Januscape fix inclusion UNVERIFIED; for testing only, not a recommended production pin"
EXAMPLE_RELEASE=https://github.com/cocoonstack/pvm/releases/download/v0.1.0
PVM_HOST_DEB_URL=${PVM_HOST_DEB_URL:-$EXAMPLE_RELEASE/linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb}
PVM_HOST_DEB_SHA256=${PVM_HOST_DEB_SHA256:-a02e2555c0ae65c2007dc9db2a92b14b63a61c86b3eb796d5a25868f3701ffd1}
PVM_GUEST_KERNEL_URL=${PVM_GUEST_KERNEL_URL:-$EXAMPLE_RELEASE/vmlinux-pvm-amd64}
PVM_GUEST_KERNEL_SHA256=${PVM_GUEST_KERNEL_SHA256:-84dcf08143ce7e945a770ff1b6d25e0505c1da69d674831b470cabc139598acb}
PVM_GUEST_CONFIG_URL=${PVM_GUEST_CONFIG_URL:-$EXAMPLE_RELEASE/guest-pvm-amd64.config}
PVM_GUEST_CONFIG_SHA256=${PVM_GUEST_CONFIG_SHA256:-51ce5c264373e18817bf94816cfb08c365eaee36cfa624045ccbb7c17aad90f5}
EXAMPLE_PINS=0
[[ $PVM_HOST_DEB_URL != "$EXAMPLE_RELEASE"/* ]] || EXAMPLE_PINS=1

SITE=${PVM_E2E_SITE:-byoh-pvm-e2e}
SCRATCH=${PVM_E2E_SCRATCH_SITE:-$SITE-neg}
read -ra SITE_ARGS <<<"${PVM_E2E_SITE_ARGS:-}"
WORK=${PVM_E2E_WORK:-var/pvm-e2e}
UBI_LOCATION=${PVM_E2E_UBI_LOCATION:-$SITE}
read -ra UBI_CMD <<<"${PVM_E2E_UBI:-bin/ubi}"
VM_SIZE=pvm-2
VM_A=pvm-e2e-a
VM_JAMMY=pvm-e2e-jammy
PVM_ENTRY_ID=ubicloud-pvm
BOOT_UNIT=ubicloud-pvm-boot.service
RHIZOME=/home/rhizome

PACKAGED=0
[[ ! -e /etc/ubicloud && ! -e /opt/ubicloud ]] || PACKAGED=1
if [[ -z ${ADMIN:-} ]]; then
  if ((PACKAGED)); then ADMIN="sudo ubicloud-admin"; else ADMIN="packaging/bin/ubicloud-admin --dev"; fi
fi
read -ra ADMIN_CMD <<<"$ADMIN"

mkdir -p "$WORK"
chmod 0700 "$WORK"
REPORT=$WORK/pvm-e2e-report.txt
STATE=$WORK/state
ROOT_KEY=$WORK/root_key
VM_KEY=$WORK/vm_key
HOST_KH=$WORK/host_known_hosts

# --- output -------------------------------------------------------------

FAILS=0
PASSES=0
NOTES=()
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
pass() {
  log "  PASS  $*"
  PASSES=$((PASSES + 1))
}
fail() {
  log "  FAIL  $*"
  FAILS=$((FAILS + 1))
}
info() { log "  info  $*"; }
# A check the phase could not run here: it never counts as a PASS. A
# phase whose checks were all skipped is NOT RUN, and the run's summary
# lists every skip and note.
skip() {
  log "  SKIP  $* (NOT RUN, UNVERIFIED)"
  NOTES+=("NOT RUN: $*")
}
# Something a phase's PASS does not prove as the default deployment runs it.
note() { NOTES+=("$*"); }
check() { # what command...: PASS when the command succeeds, else FAIL
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

state_get() {
  if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -1; fi
}
state_set() {
  touch "$STATE"
  sed -i "/^$1=/d" "$STATE"
  printf '%s=%s\n' "$1" "$2" >>"$STATE"
}


# MANUAL steps: the lead does them at the provider console.
manual() {
  log "  MANUAL $*"
  if [[ -t 0 ]]; then
    read -r -p "  press Enter once done " _
  else
    echo "  touch $WORK/manual-done once done" >&2
    until [[ -e $WORK/manual-done ]]; do sleep 10; done
    rm -f "$WORK/manual-done"
  fi
}

# wait_until SECONDS WHAT COMMAND...: retries the command every 10 s.
wait_until() {
  local limit=$1 what=$2 t0=$SECONDS
  shift 2
  until "$@"; do
    if ((SECONDS - t0 >= limit)); then
      fail "$what (not within ${limit}s)"
      return 1
    fi
    sleep 10
  done
  pass "$what (after $((SECONDS - t0))s)"
}

# --- the control plane ----------------------------------------------------

cpadmin() { "${ADMIN_CMD[@]}" "$@"; }

# A BYOH tool of bin/, as m2-gate.sh runs it.
tool() {
  if ((PACKAGED)); then
    sudo ubicloud-admin run "$@"
  else
    local name=$1
    shift
    bundle exec "bin/$name" "$@"
  fi
}

checks() {
  if ((PACKAGED)); then
    sudo ubicloud-admin run m2-checks "$@"
  else
    bundle exec scripts/byoh/verify/m2-checks "$@"
  fi
}

# Ruby on the control plane (the code on stdin), for the few writes no
# CLI makes: a HostNexus reboot, a host destroy, a checkup.
cp_ruby() {
  if ((PACKAGED)); then
    sudo ubicloud-admin console -e -
  else
    UBICLOUD_CONSOLE_CODE=$(cat) bundle exec ruby --enable-frozen-string-literal bin/pry
  fi
}

ubicli() { "${UBI_CMD[@]}" "$@"; }

# The rates of a location changed: a packaged control plane restarted its
# services already; a development one is restarted by hand.
rates_note() {
  if ((PACKAGED == 0)) && grep -q '^Wrote [1-9]' <<<"$1"; then
    manual "restart puma and respirate (tmux; and monitor if it runs) so that they load the new rates"
  fi
}

host_kv() { # host-ubid -> $WORK/host.kv
  checks pvm-host --host "$1" >"$WORK/host.kv"
}
kv() { sed -n "s/^$1=//p" "${2:-$WORK/host.kv}" | head -1; }

host_at() { # host-ubid label allocation_state
  host_kv "$1" && [[ $(kv label) == "$2" && $(kv allocation_state) == "$3" ]]
}
host_gone() { host_kv "$1" && [[ $(kv exists) == 0 ]]; }
host_page() { # host-ubid type [text]
  host_kv "$1" && grep -q "^page=$2 .*${3:-}" "$WORK/host.kv"
}
host_no_page() { host_kv "$1" && ! grep -q "^page=$2 " "$WORK/host.kv"; }

vm_kv() { checks pvm-vm --vm "$1" >"$WORK/vm.kv"; }

# --- the host ---------------------------------------------------------------

HOST_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o UserKnownHostsFile="$HOST_KH" -o StrictHostKeyChecking=accept-new)

# Root on the host with the key host add gave the control plane too
# (host_ssh_in passes standard input on); op_ssh is the operator's own
# login, which works before any registration.
host_ssh() { ssh -n "${HOST_OPTS[@]}" -i "$ROOT_KEY" "root@$MAIN_IP" "$@"; }
host_ssh_in() { ssh "${HOST_OPTS[@]}" -i "$ROOT_KEY" "root@$MAIN_IP" "$@"; }
op_ssh() { ssh -n "${HOST_OPTS[@]}" -i "$PVM_E2E_HOST_KEY" "$PVM_E2E_HOST_SSH" "$@"; }
host_boot_id() { host_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }
host_up() { [[ -n $(host_boot_id) ]]; }
host_rebooted() { # old-boot-id
  local now
  now=$(host_boot_id)
  [[ -n $now && $now != "$1" ]]
}
grubenv() { host_ssh grub-editenv list 2>/dev/null | sed -n "s/^$1=//p"; }

# A value from rhizome's `install-pvm-host-kernel status` (keys as for Hash#dig).
pvm_status() {
  host_ssh "cd $RHIZOME && echo '{}' | host/bin/install-pvm-host-kernel status | ruby -rjson -e 'v = JSON.parse(STDIN.read).dig(*ARGV); puts(v.is_a?(String) ? v : JSON.generate(v))' $*"
}

# --- VMs --------------------------------------------------------------------

VM_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

vm_ref() { echo "$UBI_LOCATION/$1"; }
vm_field() { ubicli vm "$(vm_ref "$1")" show -f "$2" 2>/dev/null | sed -n "s/^$2: //p" | head -1; }
vm_state_is() { [[ $(vm_field "$1" state) == "$2" ]]; }

# ssh to a VM's private IPv4 from inside its namespace on the host, as
# m2-gate.sh does: works on every platform and either IPv6 mode.
vm_ssh() { vm_ssh_in "$@" </dev/null; }
vm_ssh_in() { # vm-ubid command...
  local vm=$1
  shift
  checks info --vm "$vm" >"$WORK/vm-info.kv" </dev/null
  local inhost priv
  inhost=$(kv inhost "$WORK/vm-info.kv")
  priv=$(kv private_ip4 "$WORK/vm-info.kv")
  ssh "${VM_OPTS[@]}" -i "$VM_KEY" \
    -o ProxyCommand="ssh ${HOST_OPTS[*]} -i $ROOT_KEY root@$MAIN_IP ip netns exec $inhost nc %h %p" "ubi@$priv" "$@"
}
vm_up() { vm_ssh "$1" true 2>/dev/null; }
vm_boot_id() { vm_ssh "$1" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

vm_id() { # name -> ubid, also kept in the state file
  local id
  id=$(state_get "vm_$1")
  if [[ -z $id ]]; then
    id=$(vm_field "$1" id)
    [[ -z $id ]] || state_set "vm_$1" "$id"
  fi
  echo "$id"
}

# --- shared checks ----------------------------------------------------------

host_ubid() {
  local h
  h=$(state_get host)
  [[ -n $h ]] || usage_die "no host recorded in $STATE; run host-add first"
  echo "$h"
}
vm_a() {
  local v
  v=$(vm_id "$VM_A")
  [[ -n $v ]] || usage_die "no VM $VM_A; run the vm phase first"
  echo "$v"
}

# The host is back at work on its PVM kernel, armed for the next boot.
check_host_on_pvm() {
  local host=$1 kver
  wait_until 1800 "host $host is at wait and accepting" host_at "$host" wait accepting || return 0
  check "byoh_pvm_host is committed ($(kv pvm_state))" [ "$(kv pvm_state)" = committed ]
  kver=$(kv host_kver)
  check "the host runs its PVM kernel $kver" [ "$(host_ssh uname -r)" = "$kver" ]
  check "pti=off is on the running command line" host_ssh grep -qw pti=off /proc/cmdline
  check "the next boot is armed (next_entry=$PVM_ENTRY_ID)" [ "$(grubenv next_entry)" = "$PVM_ENTRY_ID" ]
  check "saved_entry is still the stock kernel" [ "$(grubenv saved_entry)" = "$(kv stock_entry)" ]
}

# The VM came back by itself and answers on SSH.
check_vm_back() {
  local vm
  vm=$(vm_a)
  wait_until 1200 "VM $VM_A is running" vm_state_is "$VM_A" running || return 0
  wait_until 600 "VM $VM_A answers on SSH" vm_up "$vm"
}

# How HostNexus notices a boot it did not ask for. bin/monitor's checkup
# does it where a monitor runs; a BYOH control plane runs none by default
# (until M9), and there a pvm host's wait compares its boot id itself
# every 5 minutes (HostNexus#check_pvm_boot_id), which is what this run
# tests. PVM_E2E_SET_CHECKUP=1 sets checkup as the monitor would instead,
# and the phase then says that its detection was simulated.
expect_boot_noticed() {
  local host=$1 boot
  if pgrep -f 'bin/monitor' >/dev/null 2>&1; then
    info "bin/monitor runs; its pulse check may set checkup on the host too"
  elif [[ ${PVM_E2E_SET_CHECKUP:-0} == 1 ]]; then
    info "PVM_E2E_SET_CHECKUP=1: setting checkup on $host as bin/monitor's pulse check would"
    note "detection simulated: checkup set by the script, not by the host's own boot id check"
    echo "VmHost[\"$host\"].incr_checkup" | cp_ruby >/dev/null
  else
    info "no bin/monitor (the BYOH default): HostNexus#wait on the pvm host compares its boot id itself every 5 minutes"
  fi
  boot=$(host_boot_id)
  wait_until "${PVM_E2E_BOOT_WAIT:-1200}" "HostNexus recorded the new boot id $boot" boot_noticed "$host" "$boot"
}
boot_noticed() { [[ -n $2 ]] && host_kv "$1" && [[ $(kv last_boot_id) == "$2" ]]; }

# The guest kernel the VM really boots, not only the byoh_vm_guest_kernel
# row the control plane writes before it rewrites the unit: the --kernel
# of its unit and of its running cloud-hypervisor, and the guest's
# uname -r against the release the host read from that kernel.
vm_inhost() { checks info --vm "$1" >"$WORK/vm-info.kv" </dev/null && kv inhost "$WORK/vm-info.kv"; }
vm_unit_kernel() { host_ssh "systemctl cat $1.service | sed -n 's/.*--kernel \([^ ]*\).*/\1/p' | head -1"; }
vm_proc_kernel() {
  host_ssh "pid=\$(systemctl show -p MainPID --value $1.service); [ \"\${pid:-0}\" -gt 0 ] && tr '\\0' '\\n' </proc/\$pid/cmdline | sed -n '/^--kernel\$/{n;p;q;}'"
}
guest_release_is() { [[ -n $2 && $(vm_ssh "$1" uname -r) == "$2" ]]; }
check_vm_kernel() { # vm sha256 what
  local vm=$1 sha=$2 what=$3 inhost want release
  want=/opt/pvm-guest/$sha/vmlinux
  inhost=$(vm_inhost "$vm")
  check "$what: its unit boots $want" [ "$(vm_unit_kernel "$inhost")" = "$want" ]
  check "$what: its running cloud-hypervisor has --kernel $want" [ "$(vm_proc_kernel "$inhost")" = "$want" ]
  host_kv "$(host_ubid)"
  release=$(kv "guest_release_$sha")
  check "$what: the guest runs ${release:-?}, the release the host recorded for that kernel" guest_release_is "$vm" "$release"
}

# --- phases -----------------------------------------------------------------

ensure_site() { # name [site add options...]
  local name=$1
  shift
  if cpadmin site show "$name" >/dev/null 2>&1; then
    info "site $name exists"
    return 0
  fi
  (($#)) || {
    fail "site $name does not exist and PVM_E2E_SITE_ARGS is empty"
    return 1
  }
  check "site add $name" cpadmin site add "$name" "$@"
}

# SITE_ARGS without the options whose value must differ per location
# (site add refuses a ula48, display name or UI name another one has).
scratch_site_args() {
  SCRATCH_ARGS=()
  local i
  for ((i = 0; i < ${#SITE_ARGS[@]}; i++)); do
    case ${SITE_ARGS[i]} in
      --ula48 | --display-name | --ui-name | --display) i=$((i + 1)) ;;
      --ula48=* | --display-name=* | --ui-name=* | --display=*) ;;
      *) SCRATCH_ARGS+=("${SITE_ARGS[i]}") ;;
    esac
  done
}

pin_args() {
  PIN_ARGS=(--pvm-host-deb "$PVM_HOST_DEB_URL" --pvm-host-deb-sha256 "$1"
    --pvm-guest-kernel "$PVM_GUEST_KERNEL_URL" --pvm-guest-kernel-sha256 "$PVM_GUEST_KERNEL_SHA256"
    --pvm-guest-config "$PVM_GUEST_CONFIG_URL" --pvm-guest-config-sha256 "$PVM_GUEST_CONFIG_SHA256")
}

# A sha256 that differs from $1 in its last digit.
wrong_sha() {
  local s=$1
  if [[ ${s: -1} == 0 ]]; then echo "${s%?}1"; else echo "${s%?}0"; fi
}

# location: the site offers pvm with the pins (verified by download).
phase_location() {
  ensure_site "$SITE" "${SITE_ARGS[@]}" || return 0
  local out
  if out=$(cpadmin site rates "$SITE" --family pvm --from standard --multiplier 1.0 2>&1); then pass "pvm rates from standard"; else fail "pvm rates: $out"; fi
  printf '%s\n' "$out" >>"$REPORT"
  rates_note "$out"
  pin_args "$PVM_HOST_DEB_SHA256"
  ((EXAMPLE_PINS == 0)) || info "pins: the cocoonstack/pvm v0.1.0 example ($EXAMPLE_LABEL)"
  check "set --virt-tiers kvm,pvm --accept pvm with the pins (downloaded and checked)" \
    cpadmin site set "$SITE" --virt-tiers kvm,pvm --accept pvm "${PIN_ARGS[@]}"
  if [[ -n ${PVM_E2E_PROJECT:-} ]]; then
    if out=$(cpadmin site grant "$SITE" --project "$PVM_E2E_PROJECT" 2>&1); then pass "granted to $PVM_E2E_PROJECT"; else fail "grant: $out"; fi
  else
    info "PVM_E2E_PROJECT is unset: the site is not granted to the API project"
  fi
  cpadmin site show "$SITE" | tee -a "$REPORT" >"$WORK/site-show.txt"
  check "show lists pvm" grep -q '^Virt tiers .*pvm' "$WORK/site-show.txt"
  check "show lists the PVM pins" grep -q '^PVM pins' "$WORK/site-show.txt"
}

# The host's GRUB state and PVM packages, through the operator's login
# (the run's root key is not on the host before the first host add). The
# bring-up's patch may add a stock kernel package, so the kernel package
# list is only shown, not compared.
host_snapshot() {
  {
    op_ssh "sudo -n grub-editenv list" | grep -E '^(saved_entry|next_entry)=' || true
    op_ssh "ls /etc/grub.d /etc/default/grub.d 2>/dev/null"
    op_ssh "dpkg-query -W -f '\${Package} \${Status}\n' 'linux-image-*' 2>/dev/null | grep -i pvm | grep ' installed$'" || true
  } >"$1"
  info "kernel packages: $(op_ssh "dpkg-query -W -f '\${Package} ' 'linux-image-[0-9]*' 2>/dev/null" || true)"
}

registration_key() {
  if [[ ! -f $ROOT_KEY ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "pvm-e2e $SITE" -f "$ROOT_KEY" </dev/null
    info "generated the registration key $ROOT_KEY (a root login to the host; shred it after teardown)"
  fi
}

host_add_args() {
  ADD_ARGS=(--ssh "$PVM_E2E_HOST_SSH" --ssh-key "$PVM_E2E_HOST_KEY" --main-ip "$MAIN_IP"
    --virt-tier pvm --accept-fallback --install-pvm-kernel --registration-key "$ROOT_KEY")
  [[ -z ${PVM_E2E_POOL_FILE:-} ]] || ADD_ARGS+=(--pool-file "$PVM_E2E_POOL_FILE")
  local fp n=0
  for fp in ${PVM_E2E_EXPECT_HOST_KEY:-}; do
    [[ $fp != --expect-host-key ]] || continue
    ADD_ARGS+=(--expect-host-key "${fp#--expect-host-key=}")
    n=$((n + 1))
  done
  ((n)) || ADD_ARGS+=(--yes)
}

# The rhizome user a destroyed registration leaves on the instance.
# Preflight refuses any rhizome user (PF16-rhizome-user, never
# accepted), so an operator registering the same machine again deletes
# it first; this run registers the instance up to three times.
forget_rhizome_user() {
  op_ssh 'getent passwd rhizome >/dev/null' || return 0
  op_ssh 'sudo -n pkill -u rhizome; sleep 1; sudo -n userdel -r rhizome' >/dev/null 2>&1 || true
  if op_ssh 'getent passwd rhizome >/dev/null'; then
    fail "the rhizome user of an earlier registration is still on the instance"
    return 1
  fi
  info "deleted the rhizome user of an earlier registration"
}

destroy_host() { # ubid
  echo "VmHost[\"$1\"].incr_destroy" | cp_ruby >/dev/null
  wait_until 900 "host $1 is destroyed" host_gone "$1" || return 1
  # The destroy resolves the host's own pages; LastBootIDDiscrepancy is
  # upstream's, which nothing resolves, and is only shown.
  grep '^page=LastBootIDDiscrepancy ' "$WORK/host.kv" | sed 's/^/  info  left open (upstream): /' | tee -a "$REPORT" || true
  wait_until "${PVM_E2E_PAGE_WAIT:-300}" "no page of host $1 is left open" host_no_own_pages "$1" || true
}
host_no_own_pages() { host_kv "$1" && awk '/^page=/ && !/^page=LastBootIDDiscrepancy / {n++} END {exit n > 0}' "$WORK/host.kv"; }

# neg-sha: wrong pins are refused, and a wrong host-deb sha256 changes
# nothing on the host.
phase_neg_sha() {
  local before after out
  before=$(cpadmin site show "$SITE")
  pin_args "$PVM_HOST_DEB_SHA256"
  PIN_ARGS=("${PIN_ARGS[@]/#$PVM_GUEST_KERNEL_SHA256/$(wrong_sha "$PVM_GUEST_KERNEL_SHA256")}")
  if out=$(cpadmin site set "$SITE" "${PIN_ARGS[@]}" 2>&1); then
    fail "set with a wrong guest kernel sha256 was accepted"
  else
    pass "set with a wrong guest kernel sha256 is refused: $(tail -1 <<<"$out")"
  fi
  after=$(cpadmin site show "$SITE")
  check "show is unchanged after the refusal" [ "$before" = "$after" ]

  scratch_site_args
  ensure_site "$SCRATCH" "${SCRATCH_ARGS[@]}" || return 0
  out=$(cpadmin site rates "$SCRATCH" --family pvm --from standard --multiplier 1.0 2>&1) || fail "scratch pvm rates: $out"
  rates_note "$out"
  pin_args "$(wrong_sha "$PVM_HOST_DEB_SHA256")"
  check "scratch site takes a wrong host-deb sha256 with --no-verify-download" \
    cpadmin site set "$SCRATCH" --virt-tiers kvm,pvm --accept pvm "${PIN_ARGS[@]}" --no-verify-download

  registration_key
  host_snapshot "$WORK/neg-before.txt" || true
  host_add_args
  forget_rhizome_user || return 0
  out=$(cpadmin host add --site "$SCRATCH" "${ADD_ARGS[@]}" --no-wait 2>&1) || true
  printf '%s\n' "$out" >>"$REPORT"
  local host
  host=$(grep -oE 'host vh[0-9a-z]{24}' <<<"$out" | tail -1 | cut -d' ' -f2 || true)
  [[ -n $host ]] || {
    fail "host add into $SCRATCH printed no host ubid"
    return 0
  }
  state_set neg_host "$host"
  wait_until 7200 "ByohPvmInstall pages the refusal" host_page "$host" ByohPvmInstall "refused to install" || return 0
  grep '^page=\|^label=\|^last_error=' "$WORK/host.kv" | sed 's/^/  /' | tee -a "$REPORT"
  check "the host waits at pvm_install_failed" [ "$(kv label)" = pvm_install_failed ]
  host_snapshot "$WORK/neg-after.txt"
  check "GRUB (saved_entry, next_entry), the kernel packages and /etc/grub.d are unchanged" \
    cmp -s "$WORK/neg-before.txt" "$WORK/neg-after.txt"
  check "no PVM kernel package" sh -c "! grep -q 'pvm' '$WORK/neg-after.txt'"
  check "no 42_ubicloud_pvm" op_ssh "[ ! -e /etc/grub.d/42_ubicloud_pvm ]"
  destroy_host "$host" || return 0

  # A guest kernel the host itself refuses in bring-up: the right host
  # .deb and a wrong guest sha256 that set stores unchecked. The host
  # must stop at pvm_guest_kernel_refused, short of accepting, before
  # patch or the install changes anything.
  pin_args "$PVM_HOST_DEB_SHA256"
  PIN_ARGS=("${PIN_ARGS[@]/#$PVM_GUEST_KERNEL_SHA256/$(wrong_sha "$PVM_GUEST_KERNEL_SHA256")}")
  check "scratch site takes a wrong guest kernel sha256 with --no-verify-download" \
    cpadmin site set "$SCRATCH" "${PIN_ARGS[@]}" --no-verify-download
  host_snapshot "$WORK/neg-guest-before.txt" || true
  forget_rhizome_user || return 0
  out=$(cpadmin host add --site "$SCRATCH" "${ADD_ARGS[@]}" --no-wait 2>&1) || true
  printf '%s\n' "$out" >>"$REPORT"
  host=$(grep -oE 'host vh[0-9a-z]{24}' <<<"$out" | tail -1 | cut -d' ' -f2 || true)
  [[ -n $host ]] || {
    fail "the second host add into $SCRATCH printed no host ubid"
    return 0
  }
  state_set neg_host "$host"
  wait_until 7200 "ByohPvmGuestKernel pages the host's refusal of the guest kernel" host_page "$host" ByohPvmGuestKernel "refused the PVM guest kernel" || return 0
  grep '^page=\|^label=\|^allocation_state=' "$WORK/host.kv" | sed 's/^/  /' | tee -a "$REPORT"
  check "the host waits at pvm_guest_kernel_refused" [ "$(kv label)" = pvm_guest_kernel_refused ]
  check "the host does not accept VMs ($(kv allocation_state))" [ "$(kv allocation_state)" != accepting ]
  host_snapshot "$WORK/neg-guest-after.txt"
  check "GRUB, the kernel packages and /etc/grub.d are unchanged by the guest refusal" \
    cmp -s "$WORK/neg-guest-before.txt" "$WORK/neg-guest-after.txt"
  destroy_host "$host" || return 0
  if out=$(cpadmin site delete "$SCRATCH" 2>&1); then pass "scratch site deleted"; else fail "site delete $SCRATCH: $out"; fi
}

phase_host_add() {
  registration_key
  if [[ -n $(state_get host) ]]; then
    info "host $(state_get host) was added already; host add resumes its watch"
  else
    state_set stock_kver "$(op_ssh uname -r)"
    forget_rhizome_user || return 0
  fi
  info "stock kernel before host add: $(state_get stock_kver)"
  local boots_before t0=$SECONDS out rc=0
  boots_before=$(op_ssh 'sudo -n journalctl --list-boots --no-pager 2>/dev/null | wc -l' || echo 0)
  host_add_args
  out=$(cpadmin host add --site "$SITE" "${ADD_ARGS[@]}" --timeout 7200 2>&1 | tee -a "$REPORT") || rc=$?
  local host
  host=$(grep -oE 'host vh[0-9a-z]{24}' <<<"$out" | tail -1 | cut -d' ' -f2 || true)
  [[ -z $host ]] || state_set host "$host"
  check "host add exited 0 (the host accepts VMs)" [ "$rc" = 0 ]
  [[ -n $host ]] || {
    fail "host add printed no host ubid"
    return 0
  }
  local boots_after
  boots_after=$(op_ssh 'sudo -n journalctl --list-boots --no-pager 2>/dev/null | wc -l' || echo 0)
  info "bring-up took $(((SECONDS - t0) / 60)) minutes and $((boots_after - boots_before)) reboots (journal boots $boots_before -> $boots_after)"
  host_kv "$host"
  check "virt tier pvm" [ "$(kv virt_tier)" = pvm ]
  check "byoh_pvm_host is committed" [ "$(kv pvm_state)" = committed ]
}

phase_patch_kernel() {
  local host
  host=$(host_ubid)
  tool byoh-virt show --host "$host" | tee -a "$REPORT" >"$WORK/virt-show.txt" || true
  check "show records the kernel packages before and after patch" grep -q 'kernel packages before patch' "$WORK/virt-show.txt"
  host_kv "$host"
  local stock
  stock=$(state_get stock_kver)
  check "the install pinned the stock kernel that ran before patch ($stock)" [ "$(kv stock_kver)" = "$stock" ]
  check "saved_entry is the recorded stock entry" [ "$(grubenv saved_entry)" = "$(kv stock_entry)" ]
  check "the stock entry still resolves (grub.cfg and its vmlinuz)" [ "$(pvm_status stock_entry_resolves)" = true ]
  info "kernels in /boot: $(host_ssh 'ls /boot | grep ^vmlinuz- | tr "\n" " "')"
}

is_pvm_kernel() { [[ $1 == "$2" && $1 == *-pvm ]]; }

phase_host_check() {
  local host kver
  host=$(host_ubid)
  host_kv "$host"
  kver=$(kv host_kver)
  check "the running kernel is the PVM kernel $kver (*-pvm)" is_pvm_kernel "$(host_ssh uname -r)" "$kver"
  check "pti=off on the command line" host_ssh grep -qw pti=off /proc/cmdline
  check "saved_entry is the stock entry" [ "$(grubenv saved_entry)" = "$(kv stock_entry)" ]
  check "next_entry=$PVM_ENTRY_ID (the boot unit re-armed the next boot)" [ "$(grubenv next_entry)" = "$PVM_ENTRY_ID" ]
  check "/dev/kvm is crw-rw---- root kvm" [ "$(host_ssh "stat -c '%A %U %G' /dev/kvm")" = "crw-rw---- root kvm" ]
  check "kvm_pvm is loaded" host_ssh "grep -q '^kvm_pvm ' /proc/modules"
  check "$BOOT_UNIT is active" [ "$(host_ssh systemctl show -p ActiveState --value $BOOT_UNIT)" = active ]
  check "$BOOT_UNIT succeeded" [ "$(host_ssh systemctl show -p Result --value $BOOT_UNIT)" = success ]
  # byoh-virt probe would ssh with the operator's own known_hosts, which
  # has never seen this host: the run sends the same probe script over
  # its own connection and has byoh-virt explain the report.
  local probe
  tool byoh-virt script >"$WORK/probe.rb"
  host_ssh_in ruby - --json <"$WORK/probe.rb" >"$WORK/probe.json" || true
  probe=$(tool byoh-virt explain <"$WORK/probe.json" 2>&1 || true)
  printf '%s\n' "$probe" >>"$REPORT"
  check "the probe says pvm" grep -q '^tier: pvm' <<<"$probe"
  local holds
  holds=$(host_ssh apt-mark showhold)
  check "the PVM kernel package is held" grep -qx "linux-image-$kver" <<<"$holds"
  check "the stock kernel package is held" grep -qx "linux-image-$(kv stock_kver)" <<<"$holds"
  local sys
  sys=$(host_ssh systemctl is-system-running || true)
  check "systemctl is-system-running is not degraded ($sys)" [ "$sys" = running ]
}

phase_vm() {
  local host
  host=$(host_ubid)
  need UBI_TOKEN UBI_URL
  [[ -f $VM_KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "pvm-e2e vm" -f "$VM_KEY" </dev/null
  local ip=(-6)
  [[ -z ${PVM_E2E_POOL_FILE:-} ]] || ip=()
  if [[ -z $(vm_id "$VM_A") ]]; then
    # Only before the create: a resumed run keeps the reading without the VM.
    state_set mem_before_kib "$(host_ssh awk "'/^MemAvailable:/ {print \$2}'" /proc/meminfo)"
    state_set vm_a_created "$(date -u +%FT%TZ)"
    check "create $VM_SIZE ubuntu-noble" ubicli vm "$(vm_ref "$VM_A")" create -s "$VM_SIZE" -b ubuntu-noble "${ip[@]}" "$(cat "$VM_KEY.pub")"
  fi
  wait_until 1800 "VM $VM_A is running" vm_state_is "$VM_A" running || return 0
  local vm
  vm=$(vm_id "$VM_A")
  info "VM $vm"
  wait_until 900 "VM $VM_A answers on SSH (netns proxy)" vm_up "$vm" || return 0
  info "guest kernel: $(vm_ssh "$vm" uname -r)"
  check "DNS resolves in the guest" vm_ssh "$vm" getent hosts cloud-images.ubuntu.com
  check "egress over https from the guest" vm_ssh "$vm" curl -fsS -o /dev/null --max-time 30 https://cloud-images.ubuntu.com/
  check "apt-get update in the guest" vm_ssh "$vm" sudo apt-get update -qq
  local show
  show=$(ubicli vm "$(vm_ref "$VM_A")" show 2>&1)
  printf '%s\n' "$show" >>"$REPORT"
  check "the API shows virt-tier pvm" grep -q '^virt-tier: pvm' <<<"$show"
  check "the API shows the guest kernel" grep -q '^  guest-kernel: .*sha256 '"$PVM_GUEST_KERNEL_SHA256" <<<"$show"
  vm_kv "$vm"
  check "family pvm" [ "$(kv family "$WORK/vm.kv")" = pvm ]
  check "the VM's guest kernel row is the pinned one" [ "$(kv guest_sha256 "$WORK/vm.kv")" = "$PVM_GUEST_KERNEL_SHA256" ]
  info "guest console: $(kv guest_console "$WORK/vm.kv")"
  check_vm_kernel "$vm" "$PVM_GUEST_KERNEL_SHA256" "the VM boots the pinned guest kernel"
  local serial t0=$SECONDS
  while :; do
    serial=$(ubicli vm "$(vm_ref "$VM_A")" serial-log -r 2>&1 || true)
    grep -q 'Linux version' <<<"$serial" && grep -q 'login:' <<<"$serial" && break
    ((SECONDS - t0 < 300)) || break
    sleep 15
  done
  printf '%s\n' "$serial" >"$WORK/serial-log.txt"
  check "the serial log shows the kernel banner" grep -q 'Linux version' "$WORK/serial-log.txt"
  check "the serial log shows a login prompt" grep -q 'login:' "$WORK/serial-log.txt"
}

# fio on a file: "read_iops write_iops" from its JSON output.
FIO_PARSE="python3 -c 'import json,sys; j=json.load(sys.stdin)[\"jobs\"][0]; print(int(j[\"read\"][\"iops\"]), int(j[\"write\"][\"iops\"]))'"
fio_cmd() { # dir
  echo "fio --name=e2e --filename=$1/pvm-e2e-fio --size=1G --rw=randrw --bs=4k --direct=1 --ioengine=libaio --iodepth=32 --runtime=60 --time_based --output-format=json | $FIO_PARSE; rm -f $1/pvm-e2e-fio"
}
# Download speed in bytes/s of the first 200 MiB of the noble image.
DL_CMD="curl -fsS -o /dev/null -r 0-209715199 --max-time 120 -w '%{speed_download}' https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

ratio() { awk -v g="$1" -v h="$2" 'BEGIN {printf "%.0f%%", (h > 0 ? 100 * g / h : 0)}'; }

phase_prod_path() {
  local vm host_dir=/var/storage
  vm=$(vm_a)
  host_ssh "[ -d $host_dir ]" || host_dir=/var/tmp
  check "fio in the guest" vm_ssh "$vm" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fio >/dev/null"
  check "fio on the host" host_ssh "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fio >/dev/null"
  local g h
  read -r -a g <<<"$(vm_ssh "$vm" "$(fio_cmd /var/tmp)")"
  read -r -a h <<<"$(host_ssh "$(fio_cmd $host_dir)")"
  info "fio 4k randrw qd32 (ubiblk vhost-user in the guest, $host_dir on the host): guest ${g[0]:-?}/${g[1]:-?} IOPS r/w, host ${h[0]:-?}/${h[1]:-?}, read at $(ratio "${g[0]:-0}" "${h[0]:-0}") of the host"
  check "fio ran in the guest" [ -n "${g[0]:-}" ]
  local gd hd
  gd=$(vm_ssh "$vm" "$DL_CMD" || echo 0)
  hd=$(host_ssh "$DL_CMD" || echo 0)
  info "download (200 MiB over https): guest ${gd%.*} B/s, host ${hd%.*} B/s, guest at $(ratio "$gd" "$hd")"
  check "the guest downloads" awk -v s="$gd" 'BEGIN {exit !(s > 0)}'
  # The host's memory with the guest's memory touched: the VM may take
  # its RAM plus vm_overhead_mib (384), the budget verify_tier_capacity
  # gives it (lib/byoh_virt_tiers.rb), UNVERIFIED before this run.
  local before after mem_gib budget
  before=$(state_get mem_before_kib)
  mem_gib=$(vm_ssh "$vm" "awk '/^MemTotal:/ {printf \"%d\", \$2 / 1048576 + 0.5}' /proc/meminfo")
  vm_ssh "$vm" "nohup python3 -c 'import time; b = bytearray(int(0.85 * $mem_gib * 2**30)); time.sleep(90)' >/dev/null 2>&1 &" || true
  sleep 60
  after=$(host_ssh awk "'/^MemAvailable:/ {print \$2}'" /proc/meminfo)
  budget=$(((mem_gib * 1024 + 384) * 1024))
  info "host MemAvailable: $((before / 1024)) MiB before the VM, $((after / 1024)) MiB with ~85% of its ${mem_gib} GiB touched; the VM takes $(((before - after) / 1024)) MiB of a $((budget / 1024)) MiB budget"
  check "the VM stays within RAM + vm_overhead_mib" [ $((before - after)) -le "$budget" ]
}

# The same measurements as pvm-go-no-go.sh (spec/lib/byoh_pvm_e2e_script_spec.rb keeps the bodies equal).
write_bench() {
  cat >"$1" <<'EOF'
#!/bin/sh
ms() { echo $(($(date +%s%N) / 1000000)); }
run() {
  n=$1
  shift
  t0=$(ms)
  "$@" >/dev/null 2>&1
  echo "BYOH_PVM_BENCH $n $(($(ms) - t0))"
}
forks() { i=0; while [ $i -lt 2000 ]; do /bin/true; i=$((i + 1)); done; }
run cpu_sha256_1g sh -c 'dd if=/dev/zero bs=1M count=1024 | sha256sum'
run mem_dd_8g dd if=/dev/zero of=/dev/null bs=1M count=8192
run syscalls_400k dd if=/dev/zero of=/dev/null bs=1 count=200000
run fork_exec_2000 forks
d=${BENCH_DIR:-/var/tmp}
run disk_write_512m dd if=/dev/zero of="$d/byoh-pvm-bench" bs=1M count=512 oflag=direct
rm -f "$d/byoh-pvm-bench"
EOF
  chmod 755 "$1"
}

phase_bench() {
  local vm host_dir=/var/storage
  vm=$(vm_a)
  host_ssh "[ -d $host_dir ]" || host_dir=/var/tmp
  write_bench "$WORK/bench.sh"
  host_ssh_in "BENCH_DIR=$host_dir sh -s" <"$WORK/bench.sh" >"$WORK/bench-host.txt" 2>&1 || true
  vm_ssh_in "$vm" "sh -s" <"$WORK/bench.sh" >"$WORK/bench-guest.txt" 2>&1 || true
  check "the bench ran on the host" grep -q BYOH_PVM_BENCH "$WORK/bench-host.txt"
  check "the bench ran in the guest" grep -q BYOH_PVM_BENCH "$WORK/bench-guest.txt"
  awk 'FNR == NR {h[$2] = $3; next} $1 == "BYOH_PVM_BENCH" && h[$2] > 0 {printf "  ratio %s: guest %d ms, host %d ms, guest at %.0f%% of host speed\n", $2, $3, h[$2], 100 * h[$2] / ($3 > 0 ? $3 : 1)}' \
    <(grep BYOH_PVM_BENCH "$WORK/bench-host.txt") <(grep BYOH_PVM_BENCH "$WORK/bench-guest.txt") | tee -a "$REPORT"
}

phase_lifecycle() {
  local vm before
  vm=$(vm_a)
  check "stop" ubicli vm "$(vm_ref "$VM_A")" stop
  wait_until 600 "VM $VM_A is stopped" vm_state_is "$VM_A" stopped || return 0
  check "start" ubicli vm "$(vm_ref "$VM_A")" start
  check_vm_back
  before=$(vm_boot_id "$vm")
  check "restart" ubicli vm "$(vm_ref "$VM_A")" restart
  wait_until 900 "the guest booted again after restart" vm_rebooted "$vm" "$before" || return 0
  check_vm_back
}
vm_rebooted() { # vm old-boot-id
  local now
  now=$(vm_boot_id "$1")
  [[ -n $now && $now != "$2" ]]
}

phase_host_reboot() {
  local host boot
  host=$(host_ubid)
  boot=$(host_boot_id)
  echo "VmHost[\"$host\"].incr_reboot" | cp_ruby >/dev/null
  wait_until 1800 "the host rebooted" host_rebooted "$boot" || return 0
  check_host_on_pvm "$host"
  check_vm_back
}

phase_oob_reboot() {
  local host boot
  host=$(host_ubid)
  boot=$(host_boot_id)
  host_ssh systemctl reboot || true
  wait_until 1200 "the host rebooted behind the control plane's back" host_rebooted "$boot" || return 0
  expect_boot_noticed "$host" || return 0
  check "HostNexus paged the out-of-band boot (LastBootIDDiscrepancy)" host_page "$host" LastBootIDDiscrepancy
  check_host_on_pvm "$host"
  check_vm_back
}

phase_power_cycle() {
  local host boot
  host=$(host_ubid)
  boot=$(host_boot_id)
  manual "stop the instance ${PVM_E2E_INSTANCE:-of $MAIN_IP} from the console (AWS: aws ec2 stop-instances --instance-ids ${PVM_E2E_INSTANCE:-<id>}; wait for stopped), then start it again"
  wait_until 1800 "the host is back after the power cycle" host_rebooted "$boot" || return 0
  expect_boot_noticed "$host" || return 0
  # D2: the boot that succeeded before the stop armed this one.
  check_host_on_pvm "$host"
  check_vm_back
}

phase_tenancy() {
  local out
  if out=$(cpadmin site set "$SITE" --visible 2>&1); then fail "set --visible was accepted"; else pass "set --visible is refused: $(tail -1 <<<"$out")"; fi
  if out=$(cpadmin site set "$SITE" --accept pvm:multitenant 2>&1); then fail "--accept pvm:multitenant was accepted"; else pass "--accept pvm:multitenant is refused: $(tail -1 <<<"$out")"; fi
  if [[ -z ${PVM_E2E_PROJECT2:-} ]]; then
    skip "a grant to a second project is refused (PVM_E2E_PROJECT2 is unset)"
  elif out=$(cpadmin site grant "$SITE" --project "$PVM_E2E_PROJECT2" 2>&1); then
    fail "a grant to a second project was accepted"
  else
    pass "a grant to a second project is refused: $(tail -1 <<<"$out")"
  fi
}

guest_kernel_ready() { host_kv "$1" && [[ ,$(kv guest_kernels), == *",$2:ready,"* ]]; }
vm_on_kernel() {
  vm_kv "$1" && [[ $(kv guest_sha256 "$WORK/vm.kv") == "$2" ]]
}

phase_guest_pin_rollout() {
  if [[ -z ${PVM_E2E_GUEST2_URL:-} || -z ${PVM_E2E_GUEST2_SHA256:-} ]]; then
    skip "guest-pin-rollout (PVM_E2E_GUEST2_URL and PVM_E2E_GUEST2_SHA256 are unset)"
    return 0
  fi
  local host vm sha=$PVM_E2E_GUEST2_SHA256 args
  host=$(host_ubid)
  vm=$(vm_a)
  args=(--pvm-guest-kernel "$PVM_E2E_GUEST2_URL" --pvm-guest-kernel-sha256 "$sha")
  if [[ -n ${PVM_E2E_GUEST2_CONFIG_URL:-} ]]; then
    args+=(--pvm-guest-config "$PVM_E2E_GUEST2_CONFIG_URL" --pvm-guest-config-sha256 "$PVM_E2E_GUEST2_CONFIG_SHA256")
  else
    args+=(--pvm-guest-unchecked)
  fi
  check "set the second guest kernel pin" cpadmin site set "$SITE" "${args[@]}"
  wait_until 1800 "the host downloaded and checked it" guest_kernel_ready "$host" "$sha" || return 0
  wait_until 600 "ByohPvmGuestKernelStale lists the VM" host_page "$host" ByohPvmGuestKernelStale || true
  local before
  before=$(vm_boot_id "$vm")
  check "restart" ubicli vm "$(vm_ref "$VM_A")" restart
  wait_until 900 "the guest booted again" vm_rebooted "$vm" "$before" || return 0
  check "a restart keeps the VM's guest kernel" vm_on_kernel "$vm" "$PVM_GUEST_KERNEL_SHA256"
  check_vm_kernel "$vm" "$PVM_GUEST_KERNEL_SHA256" "after a restart"
  check "stop" ubicli vm "$(vm_ref "$VM_A")" stop
  wait_until 600 "VM $VM_A is stopped" vm_state_is "$VM_A" stopped || return 0
  check "start" ubicli vm "$(vm_ref "$VM_A")" start
  check_vm_back
  check "after stop and start the VM boots the new guest kernel" vm_on_kernel "$vm" "$sha"
  check_vm_kernel "$vm" "$sha" "after stop and start"
  wait_until 600 "the stale guest kernel page resolves" host_no_page "$host" ByohPvmGuestKernelStale
}

phase_refusals() {
  local out ip=(-6)
  [[ -z ${PVM_E2E_POOL_FILE:-} ]] || ip=()
  if out=$(ubicli vm "$(vm_ref "$VM_JAMMY")" create -s "$VM_SIZE" -b ubuntu-jammy "${ip[@]}" "$(cat "$VM_KEY.pub")" 2>&1); then
    fail "a $VM_SIZE ubuntu-jammy VM was accepted"
    ubicli vm "$(vm_ref "$VM_JAMMY")" destroy -f >/dev/null 2>&1 || true
  else
    printf '%s\n' "$out" >>"$REPORT"
    check "a $VM_SIZE ubuntu-jammy VM is refused with the tier's reason" grep -q 'boot ubuntu-noble only' <<<"$out"
  fi
}

# stock-return: a PVM boot that does not happen. The next boot is armed
# already (D2), so a HostNexus reboot would arm it again in prep_reboot;
# instead the run unsets next_entry and reboots the host itself, which a
# hung PVM boot followed by a power cycle looks like to the control plane.
phase_stock_return() {
  local host boot stock
  host=$(host_ubid)
  host_kv "$host"
  stock=$(kv stock_kver)
  boot=$(host_boot_id)
  check "unset next_entry" host_ssh grub-editenv - unset next_entry
  host_ssh systemctl reboot || true
  wait_until 1200 "the host rebooted" host_rebooted "$boot" || return 0
  check "the host booted its stock kernel $stock" [ "$(host_ssh uname -r)" = "$stock" ]
  check "no pti=off on the stock kernel" host_ssh "! grep -qw pti=off /proc/cmdline"
  expect_boot_noticed "$host" || return 0
  wait_until 900 "ByohPvmBoot pages the stock boot" host_page "$host" ByohPvmBoot "booted its stock kernel" || return 0
  check "the host waits at pvm_boot_failed" [ "$(kv label)" = pvm_boot_failed ]
  check "the host does not take VMs ($(kv allocation_state))" [ "$(kv allocation_state)" = draining ]
  # [c]: the remote shell that runs the negation stays pgrep's parent,
  # and its command line would match the plain pattern.
  check "no VM was started (no cloud-hypervisor)" host_ssh "! pgrep -f '[c]loud-hypervisor' >/dev/null"
  check "pvm retry" tool byoh-virt pvm retry --host "$host"
  check_host_on_pvm "$host"
  check_vm_back
}

phase_delete() {
  local vm inhost
  vm=$(vm_a)
  checks info --vm "$vm" >"$WORK/vm-info.kv"
  inhost=$(kv inhost "$WORK/vm-info.kv")
  state_set vm_a_deleted "$(date -u +%FT%TZ)"
  check "destroy" ubicli vm "$(vm_ref "$VM_A")" destroy -f
  wait_until 900 "the VM is gone" vm_gone "$vm" || return 0
  check "no guest kernel row" [ "$(kv guest_kernel_row "$WORK/vm.kv")" = 0 ]
  check "its unit is gone" host_ssh "! systemctl cat $inhost.service >/dev/null 2>&1"
  check "its network namespace is gone" host_ssh "! ip netns list | grep -qw $inhost"
  check "its home is gone" host_ssh "[ ! -e /vm/$inhost ]"
}
vm_gone() { vm_kv "$1" && [[ $(kv exists "$WORK/vm.kv") == 0 ]]; }

# ISO 8601 UTC times compare as strings.
not_before() { [[ -n $1 && -n $2 && ! $1 < $2 ]]; }

phase_billing() {
  local vm
  vm=$(vm_a)
  vm_kv "$vm"
  grep '^billing=' "$WORK/vm.kv" | sed 's/^/  /' | tee -a "$REPORT" || true
  check "a family-pvm VmVCpu record exists" grep -q '^billing=VmVCpu pvm ' "$WORK/vm.kv"
  check "every record is closed" sh -c "! grep -q '^billing=.* open ' '$WORK/vm.kv'"
  local first last created deleted
  first=$(grep '^billing=VmVCpu pvm' "$WORK/vm.kv" | awk '{print $4}' | sort | head -1)
  last=$(grep '^billing=VmVCpu pvm' "$WORK/vm.kv" | awk '{print $5}' | sort | tail -1)
  created=$(state_get vm_a_created)
  deleted=$(state_get vm_a_deleted)
  info "VmVCpu billed from $first to $last; created $created, deleted $deleted"
  check "billing began after the create request" not_before "$first" "$created"
  check "billing ran until the delete request" not_before "$last" "$deleted"
}

# The newest stock kernel version in patch's "after" list of byoh-virt
# show (the linux-image-<version> packages after the apt full-upgrade).
newest_after_patch() {
  sed -n 's/.*kernel packages before patch: .*; after: //p' "$1" | tr ' ' '\n' | sed -n 's/^linux-image-\([0-9].*\)$/\1/p' | grep -v -- '-pvm$' | sort -V | tail -1
}
not_pvm_kernel() { [[ -n $1 && $1 != *-pvm ]]; }
one_of() { # value candidates...
  local v=$1 c
  shift
  for c in "$@"; do [[ -z $v || $v != "$c" ]] || return 0; done
  return 1
}
running_stock_installed() { [[ $(host_ssh "dpkg-query -W -f '\${db:Status-Status}' linux-image-$1" 2>/dev/null) == installed ]]; }

phase_teardown() {
  local host stock boot newest
  host=$(host_ubid)
  host_kv "$host"
  stock=$(kv stock_kver)
  # The install pinned the stock kernel that ran when it ran, but patch's
  # apt full-upgrade may have added a newer one; uninstall unsets
  # saved_entry (or restores the one it found), and GRUB_DEFAULT=0 boots
  # the newest stock kernel.
  tool byoh-virt show --host "$host" >"$WORK/virt-show-teardown.txt" 2>&1 || true
  newest=$(newest_after_patch "$WORK/virt-show-teardown.txt")
  info "stock kernel the install pinned: $stock; newest stock kernel after patch: ${newest:-unknown}"
  check "pvm uninstall" tool byoh-virt pvm uninstall --host "$host"
  wait_until 3600 "the host uninstalled its PVM kernel (ByohPvmUninstalled)" host_page "$host" ByohPvmUninstalled || {
    info "by hand, on the stock kernel: cd $RHIZOME && echo '{}' | sudo host/bin/install-pvm-host-kernel uninstall"
    return 0
  }
  check "byoh_pvm_host is uninstalled" [ "$(kv pvm_state)" = uninstalled ]
  destroy_host "$host" || return 0
  state_set host ""
  boot=$(host_boot_id)
  host_ssh systemctl reboot || true
  wait_until 1200 "the host rebooted" host_rebooted "$boot" || return 0
  # pvm-go-no-go.sh's recovery-check, and what uninstall restores.
  local running
  running=$(host_ssh uname -r)
  check "a stock kernel runs, not a PVM one ($running)" not_pvm_kernel "$running"
  check "the running kernel is an installed stock package (linux-image-$running)" running_stock_installed "$running"
  check "it is the newest stock kernel after patch (${newest:-unknown}) or the pinned one ($stock)" one_of "$running" "$newest" "$stock"
  check "no pti=off" host_ssh "! grep -qw pti=off /proc/cmdline"
  check "no next_entry" [ -z "$(grubenv next_entry)" ]
  check "no PVM kernel package" host_ssh "! dpkg-query -W -f '\${Package} \${Status}\n' 'linux-image-*' | grep 'pvm.* installed'"
  check "the stock kernel package is not held" host_ssh "! apt-mark showhold | grep -qx linux-image-$stock"
  check "no boot unit, GRUB entry or drop-in" host_ssh "[ ! -e /etc/systemd/system/$BOOT_UNIT ] && [ ! -e /etc/grub.d/42_ubicloud_pvm ] && [ ! -e /etc/default/grub.d/98-ubicloud-pvm.cfg ]"
  info "shred the registration key once you are done: shred -u $ROOT_KEY"
}

# --- main -------------------------------------------------------------------


log "== pvm-e2e $(date -u +%FT%TZ): site $SITE, host $PVM_E2E_HOST_SSH ($MAIN_IP), phases: ${RUN[*]}"
SUMMARY=()
for phase in "${RUN[@]}"; do
  FAILS=0
  PASSES=0
  NOTES=()
  log "== $phase $(date -u +%FT%TZ)"
  t0=$SECONDS
  "phase_${phase//-/_}"
  if ((FAILS)); then
    log "== $phase: FAIL ($FAILS failed) after $((SECONDS - t0))s"
    log "report: $REPORT"
    exit 1
  fi
  if ((PASSES == 0 && ${#NOTES[@]})); then
    log "== $phase: NOT RUN (UNVERIFIED) after $((SECONDS - t0))s"
    SUMMARY+=("$phase: NOT RUN (UNVERIFIED)")
  elif ((${#NOTES[@]})); then
    log "== $phase: PASS with ${#NOTES[@]} note(s) after $((SECONDS - t0))s"
    for n in "${NOTES[@]}"; do SUMMARY+=("$phase: $n"); done
  else
    log "== $phase: PASS after $((SECONDS - t0))s"
  fi
done
if ((${#SUMMARY[@]})); then
  log "== summary: no phase failed, but not every check ran as the default deployment runs it:"
  for n in "${SUMMARY[@]}"; do log "  $n"; done
else
  log "== summary: every phase given passed"
fi
log "report: $REPORT"
