#!/usr/bin/env bash
# M2 canary gate: the checks of docs/byoh/VERIFY.md steps G1-G15, run on
# the control plane from the repository root. The terraform steps (G0,
# G17) and the full rake run (G16) happen elsewhere and are described in
# VERIFY.md; this script never runs terraform or aws.
#
# Usage: scripts/byoh/verify/m2-gate.sh STEP...
#   steps: g1 g2 g3 g4 g5 g6 g7 g8 g9 g9b g10 g11 g12 g13 g14
#          g15-before g15-after
#          all  (g1 g2 g4 g5 g6 g7 g8 g9 g9b g10: the state after setup)
#   A site without internet pools (onlink + internal) skips g6, g10 and
#   g11: g1 g2 g3 g4 g5 g7 g8 g9 g9b g12 g13 g14.
#
# Database checks go through scripts/byoh/verify/m2-checks and change
# nothing. Host checks SSH to the data plane as root. VM checks SSH to a
# VM's private IPv4 from inside its network namespace on the data plane
# (ip netns exec <vm> nc), so they work on every platform and with either
# IPv6 mode; a VM on a ULA host cannot route back to the host's IPv6, so
# jumping to the VM's IPv6 fails there. G3 runs a
# registration that must be refused, and G13 runs byoh-pool annotate with
# the host's own export, which writes one audit row and no other change.
#
# Settings (environment):
#   GATE_LOCATION        BYOH location name (G2, G3)
#   GATE_RATES_FROM      location the rates were copied from (default hetzner-fsn1)
#   GATE_HOST            VmHost ubid (G4 onwards)
#   GATE_IPV6_MODE       expected host IPv6 mode for G4, gua or ula (default: not checked)
#   GATE_EXPECT_MONITOR  1 to require bin/monitor in G1 (default 0: docs/byoh/PLATFORMS.md
#                        says not to run it on hosts without by-id disk links, such as
#                        AWS EBS and Proxmox virtio disks)
#   GATE_MAIN_IP         data plane primary IP, as registered (--main-ip)
#   GATE_HOST_KEY        root SSH key for the data plane (default ~/.ssh/byoh_data)
#   GATE_VM_KEY          SSH key of the gate VMs' "ubi" user
#   GATE_VM_A            VM with an internet address (G6, G9; G11 needs a nat one)
#   GATE_VM_A_EXPOSURE   exposure of VM-A's pool, nat or public (default nat)
#   GATE_VM_B            VM without IPv4 (G7, G9, G9b, G12)
#   GATE_VM_C            VM created with ip4_exposure internal (G8, G9)
#   GATE_VM_D            the fourth internet VM, which must wait (G10)
#   GATE_NEW_EXTERNAL    VM-A's external IP after the G11 remap
#   GATE_CTRL_PRIV       control plane private IP (G9b)
#   GATE_UNDERLAY_PROBE  another underlay address with SSH open (G9b)
#   GATE_SMTP_PROBE      an internet host that accepts TCP 25 (G9b)
#   GATE_RESPIRATE_LOG   respirate log (default /tmp/respirate.log)
#   GATE_STATE_DIR       where snapshots and exports go (default var/m2-gate)

set -euo pipefail

GATE_RATES_FROM=${GATE_RATES_FROM:-hetzner-fsn1}
GATE_HOST_KEY=${GATE_HOST_KEY:-$HOME/.ssh/byoh_data}
GATE_RESPIRATE_LOG=${GATE_RESPIRATE_LOG:-/tmp/respirate.log}
GATE_STATE_DIR=${GATE_STATE_DIR:-var/m2-gate}
GATE_EXPECT_MONITOR=${GATE_EXPECT_MONITOR:-0}
GATE_VM_A_EXPOSURE=${GATE_VM_A_EXPOSURE:-nat}

failures=0
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
info() { echo "INFO $*"; }

need() {
  local name
  for name in "$@"; do
    if [[ -z ${!name:-} ]]; then
      echo "! $name is not set; see the header of $0" >&2
      exit 2
    fi
  done
}

checks() {
  bundle exec scripts/byoh/verify/m2-checks "$@"
}

# Runs an m2-checks command and counts its result.
gate_checks() {
  if checks "$@"; then pass "m2-checks $1"; else fail "m2-checks $1"; fi
}

# -n keeps ssh from reading the script's own standard input, which a
# heredoc-driven run would otherwise lose to the first ssh.
host_ssh() {
  ssh -n "${SSH_OPTS[@]}" -i "$GATE_HOST_KEY" "root@$GATE_MAIN_IP" "$@"
}

vm_field() {
  checks info --vm "$1" | sed -n "s/^$2=//p"
}

# Runs a command in a VM. The proxy enters the VM's namespace on the
# host and connects to its private IPv4 there, which needs no route from
# the control plane or the host to the VM. The known_hosts entry is keyed
# by the VM, as private addresses are reused across VMs.
vm_ssh() {
  local vm=$1 info private inhost
  shift
  info=$(checks info --vm "$vm")
  private=$(sed -n 's/^private_ip4=//p' <<<"$info")
  inhost=$(sed -n 's/^inhost=//p' <<<"$info")
  if [[ -z $private || -z $inhost ]]; then
    echo "! $vm has no private IPv4 or namespace to reach it through the host" >&2
    return 255
  fi
  ssh -n "${SSH_OPTS[@]}" -o "HostKeyAlias=$vm" -i "$GATE_VM_KEY" \
    -o "ProxyCommand=ssh ${SSH_OPTS[*]} -i $GATE_HOST_KEY root@$GATE_MAIN_IP ip netns exec $inhost nc %h %p" \
    "ubi@$private" "$@"
}

# The summed packet counts of the byoh_egress rules that contain $1.
counter() {
  { host_ssh nft list table inet byoh_egress | grep -F -- "$1" |
    sed -n 's/.*counter packets \([0-9]*\).*/\1/p' | awk '{ n += $1 } END { if (NR) print n }'; } || true
}

IMDS_RULE="ip daddr 169.254.0.0/16 ct direction original"
# Three rules drop deny4 targets: in the forward chain one for RFC 1918
# addresses and one for the rest, and in the input chain one for the
# host's own addresses, so the deny probes count all of them.
DENY4_RULE="ip daddr @deny4"
SMTP_RULE="dport 25 "

g1() {
  echo "== G1 control plane services and BILLING_RATES_EXTRA_DIR"
  local process
  for process in puma bin/respirate; do
    if pgrep -f "$process" >/dev/null; then pass "$process is running"; else fail "$process is not running"; fi
  done
  if [[ $GATE_EXPECT_MONITOR == 1 ]]; then
    if pgrep -f bin/monitor >/dev/null; then pass "bin/monitor is running"; else fail "bin/monitor is not running"; fi
  elif pgrep -f bin/monitor >/dev/null; then
    info "bin/monitor is running; check docs/byoh/PLATFORMS.md that its health checks suit this host's disks"
  else
    info "bin/monitor is not running (GATE_EXPECT_MONITOR=1 requires it), so hosts are never marked unavailable"
  fi
  if grep -q BILLING_RATES_EXTRA_DIR .env.rb 2>/dev/null; then
    pass ".env.rb sets BILLING_RATES_EXTRA_DIR"
  else
    fail ".env.rb does not set BILLING_RATES_EXTRA_DIR (web, respirate and monitor all need it)"
  fi
}

g2() {
  echo "== G2 location, rates and warnings"
  need GATE_LOCATION
  gate_checks location --location "$GATE_LOCATION" --rates-from "$GATE_RATES_FROM"
}

g3() {
  echo "== G3 a /29 pool that contains the main IP is refused"
  need GATE_LOCATION GATE_MAIN_IP
  local a b c d out status
  IFS=. read -r a b c d <<<"$GATE_MAIN_IP"
  set +e
  out=$(bundle exec bin/register-byoh-host --location "$GATE_LOCATION" --main-ip "$GATE_MAIN_IP" \
    --routed-network "$a.$b.$c.$((d & ~7))/29" --ssh-key "$GATE_HOST_KEY" --yes </dev/null 2>&1)
  status=$?
  set -e
  if [[ $status -ne 0 && $out == *"contains main_ip"* ]]; then
    pass "registration refused (exit $status) with \"contains main_ip\""
  else
    fail "registration exited $status: $out"
  fi
}

g4() {
  echo "== G4 registered host"
  need GATE_HOST
  gate_checks host --host "$GATE_HOST" ${GATE_IPV6_MODE:+--ipv6-mode "$GATE_IPV6_MODE"}
}

g5() {
  echo "== G5 host addresses and egress table"
  need GATE_HOST GATE_MAIN_IP
  local addrs others
  if ! addrs=$(host_ssh ip -br -4 addr); then
    fail "cannot SSH to root@$GATE_MAIN_IP"
    return
  fi
  # VM veth interfaces carry link-local addresses; any other address on
  # the host would take traffic meant for a VM.
  others=$(awk '$1 != "lo" && $1 !~ /^vetho/ { for (i = 3; i <= NF; i++) if ($i ~ /\//) print $1, $i }' <<<"$addrs" |
    grep -v -F " $GATE_MAIN_IP/" || true)
  if [[ -z $others ]]; then pass "only $GATE_MAIN_IP is on the host"; else fail "other addresses on the host: $others"; fi
  if host_ssh nft list table inet byoh_egress >/dev/null; then
    pass "table inet byoh_egress is loaded"
  else
    fail "table inet byoh_egress is missing; run bin/byoh-host setup-egress-nat --host $GATE_HOST"
  fi
  gate_checks host --host "$GATE_HOST"
}

# apt, DNS and outbound IPv4 from a VM, which must leave from the host's
# own egress address.
egress() {
  local vm=$1 host_egress vm_egress
  host_egress=$(host_ssh curl -4 -s -m 10 ifconfig.me || true)
  if vm_ssh "$vm" "getent hosts archive.ubuntu.com >/dev/null && sudo apt-get update -qq"; then
    pass "$vm resolves names and runs apt-get update"
  else
    fail "$vm cannot resolve names or run apt-get update"
  fi
  vm_egress=$(vm_ssh "$vm" curl -4 -s -m 10 ifconfig.me || true)
  if [[ -n $vm_egress && $vm_egress == "$host_egress" ]]; then
    pass "$vm leaves through the host NAT as $vm_egress"
  else
    fail "$vm's IPv4 egress is \"$vm_egress\", the host's is \"$host_egress\""
  fi
}

g6() {
  echo "== G6 VM-A ($GATE_VM_A_EXPOSURE)"
  need GATE_VM_A GATE_VM_KEY
  gate_checks vm --vm "$GATE_VM_A" --expect "$GATE_VM_A_EXPOSURE"
  local public
  public=$(vm_field "$GATE_VM_A" public_ip4)
  if ssh -n "${SSH_OPTS[@]}" -i "$GATE_VM_KEY" "ubi@$public" true; then
    pass "SSH to $GATE_VM_A at its external IP $public"
  else
    fail "SSH to $GATE_VM_A at its external IP $public"
  fi
  info "check that the UI overview and 'ubi vm show' also show $public"
}

g7() {
  echo "== G7 VM-B (no IPv4)"
  need GATE_VM_B GATE_VM_KEY GATE_MAIN_IP
  gate_checks vm --vm "$GATE_VM_B" --expect none
  if grep -F "byoh netns probe gave up" "$GATE_RESPIRATE_LOG" 2>/dev/null | grep -qF "$GATE_VM_B"; then
    fail "the netns probe gave up on $GATE_VM_B ($GATE_RESPIRATE_LOG)"
  elif grep -F "byoh netns probe ok" "$GATE_RESPIRATE_LOG" 2>/dev/null | grep -qF "$GATE_VM_B"; then
    pass "$GATE_VM_B was provisioned through the netns probe"
  else
    fail "no 'byoh netns probe ok' line for $GATE_VM_B in $GATE_RESPIRATE_LOG"
  fi
  egress "$GATE_VM_B"
  info "check that the UI overview says outbound IPv4 goes through the shared NAT"
}

g8() {
  echo "== G8 VM-C (internal)"
  need GATE_VM_C GATE_VM_KEY GATE_MAIN_IP
  gate_checks vm --vm "$GATE_VM_C" --expect internal
  egress "$GATE_VM_C"
}

g9() {
  echo "== G9 link-local addresses (cloud instance metadata) are unreachable"
  need GATE_VM_KEY GATE_MAIN_IP
  # A site without internet pools (onlink + internal) has no VM-A, so
  # G9 probes from whichever gate VMs exist.
  local vm before after vms=()
  for vm in "${GATE_VM_A:-}" "${GATE_VM_B:-}" "${GATE_VM_C:-}"; do
    if [[ -n $vm ]]; then vms+=("$vm"); fi
  done
  if ((${#vms[@]} == 0)); then
    echo "! set at least one of GATE_VM_A, GATE_VM_B and GATE_VM_C" >&2
    exit 2
  fi
  for vm in "${vms[@]}"; do
    before=$(counter "$IMDS_RULE")
    if vm_ssh "$vm" curl -s -m 5 -o /dev/null http://169.254.169.254/; then
      fail "$vm reached 169.254.169.254"
    elif (($? == 255)); then
      fail "cannot SSH to $vm to probe 169.254.169.254"
    else
      pass "$vm cannot reach 169.254.169.254"
    fi
    after=$(counter "$IMDS_RULE")
    if ((${after:-0} > ${before:-0})); then pass "link-local drop counter $before -> $after"; else fail "link-local drop counter stayed at ${before:-none}"; fi
  done
}

# Fails when the VM opens a TCP connection (exit 255 is ssh's own
# failure, not a refused probe), and checks that the rule
# matching $3 counted it.
denied() {
  local vm=$1 target=$2 rule=$3 before after
  before=$(counter "$rule")
  if vm_ssh "$vm" nc -z -w 3 "$target"; then
    fail "$vm connected to $target"
  elif (($? == 255)); then
    fail "cannot SSH to $vm to probe $target"
  else
    pass "$vm cannot connect to $target"
  fi
  after=$(counter "$rule")
  if ((${after:-0} > ${before:-0})); then pass "\"$rule\" counter $before -> $after"; else fail "\"$rule\" counter stayed at ${before:-none}"; fi
}

g9b() {
  echo "== G9b the site, control plane and SMTP are denied"
  need GATE_VM_B GATE_VM_KEY GATE_MAIN_IP GATE_CTRL_PRIV GATE_UNDERLAY_PROBE GATE_SMTP_PROBE
  denied "$GATE_VM_B" "$GATE_CTRL_PRIV 22" "$DENY4_RULE"
  denied "$GATE_VM_B" "$GATE_UNDERLAY_PROBE 22" "$DENY4_RULE"
  denied "$GATE_VM_B" "$GATE_SMTP_PROBE 25" "$SMTP_RULE"
}

g10() {
  echo "== G10 allocation by exposure"
  need GATE_VM_D GATE_HOST
  gate_checks vm --vm "$GATE_VM_D" --expect waiting
  gate_checks host --host "$GATE_HOST"
}

g11() {
  echo "== G11 after bin/byoh-pool remap"
  need GATE_VM_A GATE_NEW_EXTERNAL GATE_HOST
  gate_checks vm --vm "$GATE_VM_A" --expect nat --external "$GATE_NEW_EXTERNAL"
  gate_checks host --host "$GATE_HOST"
  info "check that the load balancer's DNS name now resolves to $GATE_NEW_EXTERNAL"
}

g12() {
  echo "== G12 VM-B in an IPv6 load balancer keeps its egress"
  need GATE_VM_B GATE_VM_KEY GATE_MAIN_IP
  egress "$GATE_VM_B"
}

g13() {
  echo "== G13 export round trip"
  need GATE_HOST
  mkdir -p "$GATE_STATE_DIR"
  local first=$GATE_STATE_DIR/export-1.yaml second=$GATE_STATE_DIR/export-2.yaml
  bundle exec bin/byoh-pool export --host "$GATE_HOST" >"$first"
  if bundle exec bin/byoh-pool annotate --host "$GATE_HOST" --pool-file "$first"; then
    pass "annotate accepts the host's own export"
  else
    fail "annotate refused the host's own export"
  fi
  bundle exec bin/byoh-pool export --host "$GATE_HOST" >"$second"
  if cmp -s "$first" "$second"; then pass "annotate with the export changed nothing"; else fail "export changed: diff $first $second"; fi
  if bundle exec bin/byoh-pool verify --host "$GATE_HOST"; then pass "byoh-pool verify"; else fail "byoh-pool verify"; fi
  info "add and remove --drain need a spare address; run them by hand as VERIFY.md G13 describes"
}

g14() {
  echo "== G14 after a host reboot"
  g5
  g7
  g8
  g9
}

g15_before() {
  echo "== G15 snapshot"
  need GATE_HOST
  mkdir -p "$GATE_STATE_DIR"
  checks snapshot --host "$GATE_HOST" >"$GATE_STATE_DIR/g15.json"
  info "wrote $GATE_STATE_DIR/g15.json; create and destroy the VMs, then run g15-after"
}

g15_after() {
  echo "== G15 counts are back"
  need GATE_HOST
  gate_checks compare --host "$GATE_HOST" --snapshot "$GATE_STATE_DIR/g15.json"
}

if [[ $# -eq 0 ]]; then
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 2
fi

for step in "$@"; do
  case $step in
    g1 | g2 | g3 | g4 | g5 | g6 | g7 | g8 | g9 | g9b | g10 | g11 | g12 | g13 | g14) "$step" ;;
    g15-before) g15_before ;;
    g15-after) g15_after ;;
    all) for s in g1 g2 g4 g5 g6 g7 g8 g9 g9b g10; do "$s"; done ;;
    *)
      echo "! unknown step $step" >&2
      exit 2
      ;;
  esac
done

if ((failures == 0)); then
  echo "gate: ok"
else
  echo "gate: $failures failed"
  exit 1
fi
