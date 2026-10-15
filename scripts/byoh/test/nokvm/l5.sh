#!/bin/bash
# The l5 lab: real rhizome (bin/setup-vm, the ubiblk storage backend,
# stop-vm, vm-stats) boots one emulated VM under QEMU's software
# translator (docs/byoh/NO_KVM.md section 8, EMULATED_HOSTS.md section
# 6.5) inside an ubi-q-nokvm-l5 container that run.sh created and
# checked, without /dev/kvm. inside.sh runs it in a private mount
# namespace whose /proc/sys is read-only but for /proc/sys/net, as for
# l3; kernel_guard checks that at start and at the end. Guests reach only
# the internet: forwarding toward the test network, the gateway (the
# docker host) and every private or link-local address is dropped.
#
# It checks: SSH as ubi within 420 s of setup-vm prep; QEMU's query-kvm
# says KVM is off and QEMU holds no /dev/kvm; the guest sees a QEMU
# machine without vmx or svm; the VM user cannot replace anything in its
# root-owned home, and a socket swapped for a symlink in run/ only makes
# stop-vm fall back; a unit that lost its hardening is refused before it
# starts, as is a drop-in that overrides it; stop-vm powers the guest
# down over QMP; recreate-unpersisted, restart and start after a stop
# bring it back; delete twice leaves nothing.
#
# What it cannot do, and fakes (each says so in the log): systemd
# (fake-systemctl applies User=, Group= and the network namespace, none
# of the unit's other confinement), and the control plane, whose unix
# user and prep.json it recreates from Prog::Vm::Metal::Nexus.
set -euo pipefail

W=/w/nokvm
SCRATCH=/scratch
# The control plane's ubuntu-noble (Prog::DownloadBootImage) and
# vhost-block-backend (Config.vhost_block_backend_version) pins. An older
# release can leave cloud-images.ubuntu.com; override both together.
IMAGE_VERSION=${L5_IMAGE_VERSION:-20250502.1}
IMAGE_SHA=${L5_IMAGE_SHA:-8e7d1781c14d309f4ad6fa01d6cdb5fbf6adf95a509394135634f6a283d1f33f}
IMAGE_URL=https://cloud-images.ubuntu.com/releases/noble/release-$IMAGE_VERSION/ubuntu-24.04-server-cloudimg-amd64.img
UBIBLK=v0.4.2
POOL=192.168.78
VM=vml5aaaa1
N=1
IP=$POOL.$((10 + N))
# EMULATED_HOSTS.md section 7: SSH within 420 s; the control plane allows
# 30 minutes (ByohVirtTiers::SLOW_TIMINGS).
SSH_LIMIT_S=420
fails=0

say() { printf '[l5 %s] %s\n' "$(date +%T)" "$*"; }
ok() { echo "ok   $*"; }
bad() {
  echo "FAIL $*"
  fails=$((fails + 1))
}
check() { # check DESC CMD...
  local desc=$1
  shift
  if "$@" >/tmp/l5.out 2>&1; then ok "$desc"; else
    bad "$desc"
    sed 's/^/     | /' /tmp/l5.out | tail -20
  fi
}
check_not() { # check_not DESC CMD...: CMD must fail
  local desc=$1
  shift
  if "$@" >/tmp/l5.out 2>&1; then
    bad "$desc (it succeeded)"
    sed 's/^/     | /' /tmp/l5.out | tail -5
  else ok "$desc"; fi
}

setup_vm() { (cd /home/rhizome && ruby /w/rhizome/host/bin/setup-vm "$@"); }
ssh_vm() { # ssh_vm CMD...
  ssh -i /root/.ssh/id_l5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR "ubi@$IP" "$@"
}
as_vm() { setpriv --reuid="$VM" --regid="$VM" --init-groups "$@"; }
qemu_pid() { cat "/run/fake-systemd/$VM.pid"; }
wait_ssh() { # wait_ssh LIMIT_S: 0 once SSH answers
  local t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "$1" ]; do
    ssh_vm true 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
wait_down() { # wait_down LIMIT_S: 0 once the unit's QEMU is gone
  local t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "$1" ]; do
    systemctl is-active "$VM" >/dev/null || return 0
    sleep 1
  done
  return 1
}

# The same guard as l3.sh: host-global kernel settings read-only here,
# the per-netns net.* ones writable.
kernel_guard() {
  local f
  for f in /proc/sys/kernel/dmesg_restrict /proc/sys/kernel/core_pattern /proc/sys/vm/nr_hugepages /proc/sys/fs/file-max \
    /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages /sys/kernel/mm/transparent_hugepage/enabled; do
    if [ -e "$f" ] && [ -w "$f" ]; then
      echo "FAIL $f is writable; host kernel state is exposed" >&2
      exit 1
    fi
  done
  [ -w /proc/sys/net/ipv4/ip_forward ] || {
    echo "FAIL /proc/sys/net is not writable; inside.sh did not set up /proc" >&2
    exit 1
  }
  [ ! -e /dev/kvm ] || {
    echo "FAIL /dev/kvm is visible; this lab would not test emulation" >&2
    exit 1
  }
  ok "host kernel settings are read-only here, only /proc/sys/net is writable, and there is no /dev/kvm"
}

host_setup() {
  say "host: rhizome paths, fake systemd, ubiblk, egress, guard toward the test network"
  ln -sfn /w/rhizome /home/rhizome
  install -m 0755 "$W/fake-systemctl" /usr/local/bin/systemctl
  ln -sf /usr/sbin/dnsmasq /usr/local/sbin/dnsmasq
  mkdir -p /etc/nftables.d "$SCRATCH/storage" /var/storage
  mount --bind "$SCRATCH/storage" /var/storage
  # What prep_host.rb's emulated steps check (HostTier.check_emulator!).
  (cd /home/rhizome && ruby -r/w/rhizome/host/lib/host_tier -e 'HostTier.check_emulator!; puts "lab: HostTier.check_emulator! passed"')
  (cd /home/rhizome && ruby /w/rhizome/host/bin/setup-vhost-block-backend install "$UBIBLK")
  nft -f - <<NFT
table ip l5lab {
  chain post { type nat hook postrouting priority 100; ip saddr $POOL.0/24 oifname "eth0" masquerade; }
}
NFT
  guard_test_network
}

guard_test_network() {
  local subnet gw rules
  subnet=$(ip -4 -o addr show dev eth0 | awk '{ print $4 }')
  gw=$(ip -4 route show default | awk '{ print $3 }')
  subnet=$(ruby -ripaddr -e 'puts "#{IPAddr.new(ARGV[0])}/#{ARGV[0].split("/")[1]}"' "$subnet")
  nft -f - <<NFT
table inet l5guard {
  chain guard {
    type filter hook forward priority -10;
    ip daddr $subnet drop;
    ip daddr $gw drop;
    oifname "eth0" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } drop;
  }
}
NFT
  rules=$(nft list table inet l5guard)
  if ! grep -q "ip daddr $subnet drop" <<<"$rules" || ! grep -q "ip daddr $gw drop" <<<"$rules" || grep -q accept <<<"$rules"; then
    echo "FAIL the guard toward $subnet and $gw is missing" >&2
    exit 1
  fi
  ok "forward drop toward the test network $subnet, the gateway $gw and private addresses"
  echo "$subnet $gw" >/tmp/l5.testnet
}

image() {
  say "image: $IMAGE_URL"
  local params
  params=$(printf '{"image_name":"ubuntu-noble","version":"%s","url":"%s","sha256sum":"%s"}' "$IMAGE_VERSION" "$IMAGE_URL" "$IMAGE_SHA")
  (cd /home/rhizome && echo "$params" | ruby /w/rhizome/host/bin/download-boot-image)
  check "the image is converted to raw" test -s "/var/storage/images/ubuntu-noble-$IMAGE_VERSION.raw"
}

# The unix user and prep.json Prog::Vm::Metal::Nexus makes on an
# emulated host (EMULATED_UNIX_USER, write_params_json, and
# Vm#params_json with hypervisor qemu, accel tcg and no hugepages).
vm_create() {
  local t0
  say "lab: unix user and prep.json as the control plane makes them on an emulated host"
  adduser --disabled-password --gecos '' --no-create-home --home "/vm/$VM" --uid $((5000 + N)) "$VM" >/dev/null
  install -d -o root -g "$VM" -m 0750 "/vm/$VM"
  ruby -rjson -e '
    vm, n, pub, image_version, ubiblk = ARGV
    n = Integer(n)
    params = {
      vm_name: vm, public_ipv6: "fd5a:1ab:5:#{n}::/79", public_ipv4: "192.168.78.#{10 + n}/32",
      local_ipv4: "169.254.0.#{n * 2}/32", dns_ipv4: "10.5.#{n}.2", unix_user: "ubi", ssh_public_keys: [pub],
      nics: [["fd10:9b0b:6b4b:5#{n}::/79", "10.5.#{n}.5/32", "nql5#{n}", "52:54:00:12:35:5#{n}", "10.5.#{n}.1/26"]],
      boot_image: "ubuntu-noble", max_vcpus: 2, cpu_topology: "1:2:1:1", mem_gib: 2, ndp_needed: false,
      storage_volumes: [{boot: true, image: "ubuntu-noble", image_version:, size_gib: 10, device_id: "#{vm}_0",
        disk_index: 0, encrypted: false, spdk_version: nil, vhost_block_backend_version: ubiblk, use_bdev_ubi: false,
        storage_device: "DEFAULT", read_only: false, max_read_mbytes_per_sec: nil, max_write_mbytes_per_sec: nil,
        slice_name: "system.slice", num_queues: 1, queue_size: 256, copy_on_read: false, track_written: true}],
      swap_size_bytes: nil, pci_devices: [], gpu_partition_id: nil, slice_name: "system.slice", cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0, hypervisor: "qemu", ch_version: nil, firmware_version: nil, hugepages: false, init_script: "",
      ipv6_disabled: false, append_serial_console: false, byoh_host: true, accel: "tcg",
    }
    File.write("/vm/#{vm}/prep.json", JSON.pretty_generate(params))
  ' "$VM" "$N" "$(cat /root/.ssh/id_l5.pub)" "$IMAGE_VERSION" "$UBIBLK"
  t0=$SECONDS
  say "$VM: setup-vm prep"
  echo '{"storage":{}}' | setup_vm prep "$VM"
  if wait_ssh "$SSH_LIMIT_S"; then
    ok "$VM: SSH as ubi after $((SECONDS - t0)) s from setup-vm prep (limit ${SSH_LIMIT_S} s)"
  else
    bad "$VM: no SSH within ${SSH_LIMIT_S} s of prep"
    dump_vm
  fi
}

dump_vm() {
  echo "     | --- $VM: unit logs, serial log"
  tail -15 "/run/fake-systemd/$VM.log" 2>/dev/null | sed 's/^/     | /'
  tail -15 "/run/fake-systemd/$VM-0-storage.log" 2>/dev/null | sed 's/^/     | /'
  tail -25 "/vm/$VM/serial.log" 2>/dev/null | tr -d '\r' | tail -12 | sed 's/^/     | /'
  ip -n "$VM" -br addr 2>&1 | sed 's/^/     | /'
}

# QMP as the VM user, the only user that can enter run/.
qmp() { # qmp COMMAND: the reply lines
  printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" |
    as_vm timeout 5 socat - "UNIX-CONNECT:/vm/$VM/run/qmp.sock"
}

vm_checks() {
  local out subnet gw port
  say "$VM: emulation and guest checks"
  out=$(qmp query-kvm 2>&1 || true)
  if grep -q '"enabled": *false' <<<"$out" && grep -q '"present": *false' <<<"$out"; then ok "$VM: QMP query-kvm says KVM is neither present nor enabled"; else bad "$VM: query-kvm: $out"; fi
  check_not "$VM: QEMU holds no /dev/kvm" bash -c "ls -l /proc/$(qemu_pid)/fd | grep -q /dev/kvm"
  check "$VM: QEMU runs as the VM user" test "$(stat -c %U "/proc/$(qemu_pid)")" = "$VM"
  check "$VM: the guest sees a QEMU machine" ssh_vm "test \"\$(systemd-detect-virt)\" = qemu"
  check_not "$VM: the guest CPU has no vmx or svm" ssh_vm "grep -Eqw 'vmx|svm' /proc/cpuinfo"
  check "$VM: DHCP gave the private address" ssh_vm "ip -4 -o addr | grep -q ' 10.5.$N.5/'"
  check "$VM: cloud-init finished" ssh_vm "cloud-init status --wait | grep -q 'status: done'"
  check "$VM: DNS through the VM's dnsmasq" ssh_vm "getent hosts cloud-images.ubuntu.com"
  check "$VM: apt-get update" ssh_vm "sudo apt-get -qq update"
  read -r subnet gw </tmp/l5.testnet
  check_not "$VM: cannot reach another host of the test network ($subnet)" ssh_vm "timeout 4 bash -c 'echo > /dev/tcp/${subnet%.*/*}.2/5432'"
  for port in 5432 22; do
    check_not "$VM: cannot reach the docker host at $gw:$port" ssh_vm "timeout 4 bash -c 'echo > /dev/tcp/$gw/$port'"
  done
  check "$VM: vm-stats reports QEMU's resident memory" bash -c "cd /home/rhizome && ruby /w/rhizome/host/bin/vm-stats $VM | ruby -rjson -e 'exit(JSON.parse(\$stdin.read)[\"vm\"][\"rss_anon_bytes\"].to_i > 0 ? 0 : 1)'"
}

# The VM user, which an escaped guest would be, tries to replace what
# root later follows in its home; then a QMP socket swapped for a symlink
# meets stop-vm, which must refuse it and leave the stop to the hard stop.
symlink_probe() {
  local before after f
  say "$VM: symlink and chown-race probes"
  before=$(sha256sum /etc/passwd /etc/shadow /root/.ssh/authorized_keys 2>/dev/null; ls -la /etc /root "/vm/$VM")
  for f in serial.log prep.json dnsmasq.conf cloudinit.img run; do
    check_not "$VM: the VM user cannot replace $f in its root-owned home" as_vm bash -c "mv /vm/$VM/$f /vm/$VM/$f.x || ln -sfn /etc/shadow /vm/$VM/$f.x"
  done
  check_not "$VM: the VM user cannot create files in its home" as_vm touch "/vm/$VM/x"
  # run/ is the VM user's own: swap the socket for a symlink to another
  # root-owned socket path and let stop-vm meet it.
  as_vm bash -c "mv /vm/$VM/run/qmp.sock /vm/$VM/run/qmp.sock.real && ln -s /run/fake-systemd /vm/$VM/run/qmp.sock"
  out=$(cd /home/rhizome && ruby /w/rhizome/host/bin/stop-vm "$VM" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = 0 ] && grep -q 'leaving the stop to the hard-stop fallback' <<<"$out"; then ok "$VM: stop-vm refuses a swapped QMP socket and exits 0"; else bad "$VM: stop-vm with a swapped socket: rc $rc: $out"; fi
  check "$VM: the VM still runs after the refused soft stop" systemctl is-active "$VM"
  as_vm bash -c "rm /vm/$VM/run/qmp.sock && mv /vm/$VM/run/qmp.sock.real /vm/$VM/run/qmp.sock"
  after=$(sha256sum /etc/passwd /etc/shadow /root/.ssh/authorized_keys 2>/dev/null; ls -la /etc /root "/vm/$VM")
  if [ "$before" = "$after" ]; then ok "$VM: no host file and nothing in the home changed"; else
    bad "$VM: files changed"
    diff <(echo "$before") <(echo "$after") | sed 's/^/     | /'
  fi
}

# A unit that lost a hardening line is refused before systemctl runs, and
# reinstall-systemd-units writes it back.
hardening_probe() {
  say "$VM: refuse to start without the hardening"
  local unit=/etc/systemd/system/$VM.service
  cp "$unit" /tmp/l5.unit
  sed -i '/^ProtectSystem=strict$/d' "$unit"
  out=$(setup_vm restart "$VM" 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 0 ] && grep -q "lacks ProtectSystem=strict; refusing to start it" <<<"$out"; then ok "$VM: setup-vm restart refuses a unit without ProtectSystem=strict"; else bad "$VM: restart of a weakened unit: rc $rc: $out"; fi
  check "$VM: the refused restart left the VM running" systemctl is-active "$VM"
  check "$VM: reinstall-systemd-units writes the hardened unit back" bash -c "cd /home/rhizome && ruby /w/rhizome/host/bin/setup-vm reinstall-systemd-units $VM && cmp $unit /tmp/l5.unit"
  # A drop-in that overrides a key with spaces around '=', which systemd
  # strips, is refused by setup-vm start (the control plane's
  # start_after_stop on emulated hosts) as well.
  mkdir -p "$unit.d"
  printf '[Service]\nUser = root\n' >"$unit.d/l5-override.conf"
  out=$(setup_vm start "$VM" 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 0 ] && grep -q "overrides User=root; refusing to start it" <<<"$out"; then ok "$VM: setup-vm start refuses a drop-in that sets User = root"; else bad "$VM: start with a User = root drop-in: rc $rc: $out"; fi
  rm -r "$unit.d"
}

lifecycle() {
  local t0
  say "$VM: stop over QMP, recreate-unpersisted, restart"
  t0=$SECONDS
  check "$VM: stop-vm asks QEMU to power down" bash -c "cd /home/rhizome && ruby /w/rhizome/host/bin/stop-vm $VM"
  if wait_down 180; then ok "$VM: the guest powered off after $((SECONDS - t0)) s (control plane window 180 s)"; else
    bad "$VM: still running 180 s after the QMP power-down"
    systemctl stop "$VM"
  fi
  # A host reboot: nothing of the VM runs when recreate-unpersisted does.
  systemctl stop "$VM-dnsmasq"
  systemctl stop "$VM-0-storage"
  check "$VM: recreate-unpersisted brings it back" bash -c "echo '{\"storage\":{}}' | (cd /home/rhizome && ruby /w/rhizome/host/bin/setup-vm recreate-unpersisted $VM)"
  if wait_ssh "$SSH_LIMIT_S"; then ok "$VM: SSH again after recreate-unpersisted"; else
    bad "$VM: no SSH after recreate-unpersisted"
    dump_vm
  fi
  check "$VM: the disk kept the first boot's data" ssh_vm "test -f /var/lib/cloud/instance/boot-finished"
  check "$VM: restart through setup-vm" setup_vm restart "$VM"
  if wait_ssh "$SSH_LIMIT_S"; then ok "$VM: SSH again after setup-vm restart"; else bad "$VM: no SSH after setup-vm restart"; fi
  # A customer stop, then start: the control plane's start_after_stop runs
  # setup-vm start on emulated hosts.
  systemctl stop "$VM"
  check "$VM: start through setup-vm after a stop" setup_vm start "$VM"
  if wait_ssh "$SSH_LIMIT_S"; then ok "$VM: SSH again after setup-vm start"; else bad "$VM: no SSH after setup-vm start"; fi
}

vm_delete() {
  local round
  say "$VM: delete (twice)"
  systemctl stop "$VM"
  systemctl stop "$VM-dnsmasq"
  for round in 1 2; do
    check "$VM: setup-vm delete, round $round" setup_vm delete "$VM"
  done
  check "$VM: nothing left (netns, units, disk, home, user, processes)" bash -c "
    ! ip netns list | grep -qw $VM && test ! -e /etc/systemd/system/$VM.service && test ! -e /etc/systemd/system/$VM-0-storage.service &&
    test ! -e /var/storage/$VM && test ! -e /vm/$VM && ! id $VM 2>/dev/null && ! pgrep -x qemu-system-x86 && ! pgrep -x vhost-backend"
}

kernel_guard
host_setup
mkdir -p /root/.ssh
[ -f /root/.ssh/id_l5 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_l5
image
vm_create
if [ "${L5_DEBUG:-0}" = 1 ]; then
  say "L5_DEBUG=1: holding the lab for inspection (nsenter -t $$ -m)"
  exec sleep infinity
fi
vm_checks
symlink_probe
hardening_probe
lifecycle
vm_delete
used=$(du -sb "$SCRATCH" | cut -f1)
say "scratch used after the delete: $((used / 1048576)) MiB (the raw image remains)"
kernel_guard
if [ "$fails" -eq 0 ]; then say "l5 ok"; else
  say "l5: $fails failures"
  exit 1
fi
