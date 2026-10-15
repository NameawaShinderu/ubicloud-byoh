#!/bin/bash
# The l3 lab: real rhizome (bin/setup-vm, the network hook, stop-vm,
# vm-stats) runs two system containers (docs/byoh/NO_KVM.md section 4.2)
# inside an ubi-q-nokvm-l3 container that run.sh created and checked.
# inside.sh runs it in a private mount namespace with a fresh /proc
# (docker's /proc/sys is read-only, and rhizome sets net.* sysctls of the
# VMs' network namespaces); it touches only this container's own network
# namespaces, its delegated cgroup subtree and tmpfs.
#
# What it cannot do, and fakes (each says so in the log): systemd
# (fake-systemctl), project quotas and AppArmor (lab-setup-vm.rb),
# lxcfs (needs /dev/fuse). crypt-loop disks need loop and device-mapper
# devices, so only the dir driver runs.
set -euo pipefail

W=/w/nokvm
SCRATCH=/scratch
IMAGE_VERSION=20260926
IMAGE_SHA=820311e238ea34d76a8ca2643d6c01065212e9417109e7397d70472a236df261
IMAGE_URL=https://cloud-images.ubuntu.com/releases/noble/release-$IMAGE_VERSION/ubuntu-24.04-server-cloudimg-amd64-root.tar.xz
POOL=192.168.77
SSH_LIMIT_S=30
fails=0

say() { printf '[l3 %s] %s\n' "$(date +%T)" "$*"; }
ok() { echo "ok   $*"; }
bad() {
  echo "FAIL $*"
  fails=$((fails + 1))
}
check() { # check DESC CMD...
  local desc=$1
  shift
  if "$@" >/tmp/l3.out 2>&1; then ok "$desc"; else
    bad "$desc"
    sed 's/^/     | /' /tmp/l3.out | tail -20
  fi
}
check_not() { # check_not DESC CMD...: CMD must fail
  local desc=$1
  shift
  if "$@" >/tmp/l3.out 2>&1; then
    bad "$desc (it succeeded)"
    sed 's/^/     | /' /tmp/l3.out | tail -5
  else ok "$desc"; fi
}

setup_vm() { (cd /home/rhizome && ruby "$W/lab-setup-vm.rb" "$@"); }
ssh_vm() { # ssh_vm IP CMD...
  local ip=$1
  shift
  ssh -i /root/.ssh/id_l3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR "ubi@$ip" "$@"
}

# --- the lab "host" ----------------------------------------------------
host_setup() {
  say "host: cgroup delegation, rhizome paths, fake systemd, egress, guard toward the test network"
  # This container's own cgroup namespace: make it writable and move its
  # processes into a leaf, so controllers can be delegated below it.
  mount -o remount,rw /sys/fs/cgroup
  mkdir -p /sys/fs/cgroup/init.scope /sys/fs/cgroup/system.slice
  local p
  local procs
  mapfile -t procs </sys/fs/cgroup/cgroup.procs
  for p in "${procs[@]}"; do echo "$p" >/sys/fs/cgroup/init.scope/cgroup.procs 2>/dev/null || true; done
  echo "+cpu +io +memory +pids" >/sys/fs/cgroup/cgroup.subtree_control
  echo "+cpu +io +memory +pids" >/sys/fs/cgroup/system.slice/cgroup.subtree_control

  ln -sfn /w/rhizome /home/rhizome
  install -m 0755 "$W/fake-systemctl" /usr/local/bin/systemctl
  ln -sf /usr/sbin/dnsmasq /usr/local/sbin/dnsmasq
  mkdir -p /etc/nftables.d "$SCRATCH/storage" /var/storage
  mount --bind "$SCRATCH/storage" /var/storage
  groupadd -f -r kvm
  # What HostTier.container_host_setup does on a host.
  (cd /home/rhizome && ruby -r/w/rhizome/host/lib/container_idmap -e 'ContainerIdmap.ensure_root_entries')

  # The VMs' public addresses leave through this container's NAT, as
  # through an upstream router.
  nft -f - <<NFT
table ip l3lab {
  chain post { type nat hook postrouting priority 100; ip saddr $POOL.0/24 oifname "eth0" masquerade; }
}
NFT
  guard_test_network
}

# No guest may reach another host of the test network (ubi-pg-test and
# the like); only the gateway, for egress. Installed before any guest.
guard_test_network() {
  local subnet gw
  subnet=$(ip -4 -o addr show dev eth0 | awk '{ print $4 }')
  gw=$(ip -4 route show default | awk '{ print $3 }')
  subnet=$(ruby -ripaddr -e 'puts "#{IPAddr.new(ARGV[0])}/#{ARGV[0].split("/")[1]}"' "$subnet")
  nft -f - <<NFT
table inet l3guard {
  chain guard { type filter hook forward priority -10; ip daddr $gw accept; ip daddr $subnet drop; }
}
NFT
  grep -q "ip daddr $subnet drop" <<<"$(nft list table inet l3guard)" || {
    echo "FAIL the guard toward $subnet is missing" >&2
    exit 1
  }
  ok "forward drop toward the test network $subnet (gateway $gw allowed)"
  echo "$subnet $gw" >/tmp/l3.testnet
}

image() {
  say "image: $IMAGE_URL"
  local params
  params=$(printf '{"image_name":"ubuntu-noble-container","version":"%s","url":"%s","sha256sum":"%s"}' "$IMAGE_VERSION" "$IMAGE_URL" "$IMAGE_SHA")
  (cd /home/rhizome && echo "$params" | ruby /w/rhizome/host/bin/download-boot-image)
  check "the root tarball is kept as downloaded" test -s "/var/storage/images/ubuntu-noble-container-$IMAGE_VERSION.tar.xz"
}

# --- a VM --------------------------------------------------------------
# vm_create NAME N: the unix user and prep.json the control plane makes,
# then setup-vm prep. N numbers the VM's addresses.
vm_create() {
  local vm=$1 n=$2 t0 t1
  adduser --disabled-password --gecos '' --home "/vm/$vm" --uid $((5000 + n)) "$vm" >/dev/null
  usermod -a -G kvm "$vm"
  ruby -rjson -e '
    vm, n, pub = ARGV
    n = Integer(n)
    params = {
      vm_name: vm, public_ipv6: "fd5a:1ab:0:#{n}::/79", public_ipv4: "192.168.77.#{10 + n}/32",
      local_ipv4: "169.254.0.#{n * 2}/32", dns_ipv4: "10.0.#{n}.2", unix_user: "ubi", ssh_public_keys: [pub],
      nics: [["fd10:9b0b:6b4b:#{n}::/79", "10.0.#{n}.5/32", "nclab#{n}", "52:54:00:12:34:5#{n}", "10.0.#{n}.1/26"]],
      boot_image: "ubuntu-noble-container", max_vcpus: 2, cpu_topology: "1:2:1:1", mem_gib: 1, ndp_needed: false,
      storage_volumes: [{boot: true, image: "ubuntu-noble-container", image_version: ENV.fetch("IMAGE_VERSION"), size_gib: 10,
        device_id: "#{vm}_0", disk_index: 0, encrypted: false, storage_device: "DEFAULT", read_only: false, slice_name: "system.slice"}],
      swap_size_bytes: nil, pci_devices: [], gpu_partition_id: nil, slice_name: "system.slice", cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0, hypervisor: "lxc", ch_version: nil, firmware_version: nil, hugepages: false, init_script: "",
      ipv6_disabled: false, append_serial_console: false, byoh_host: true,
      container: {nested_userns: false, guest_firewall: false},
    }
    File.write("/vm/#{vm}/prep.json", JSON.pretty_generate(params))
  ' "$vm" "$n" "$(cat /root/.ssh/id_l3.pub)"
  chown "$vm:$vm" "/vm/$vm/prep.json"
  t0=$(date +%s%N)
  say "$vm: setup-vm prep"
  echo '{"storage":{}}' | setup_vm prep "$vm"
  local ip=$POOL.$((10 + n)) up=0
  while [ $((($(date +%s%N) - t0) / 1000000000)) -lt "$SSH_LIMIT_S" ]; do
    if ssh_vm "$ip" true 2>/dev/null; then
      up=1
      break
    fi
    sleep 0.2
  done
  t1=$(date +%s%N)
  if [ "$up" = 1 ]; then
    ok "$vm: SSH as ubi after $(((t1 - t0) / 1000000)) ms from setup-vm prep (limit ${SSH_LIMIT_S}s; includes extracting the image)"
  else
    bad "$vm: no SSH within ${SSH_LIMIT_S}s of prep"
    tail -30 "/var/lib/ubicloud/lxc/$vm/console.log" 2>/dev/null | sed 's/^/     | /'
    tail -30 "/var/lib/ubicloud/lxc/$vm/lxc.log" 2>/dev/null | sed 's/^/     | /'
    tail -30 "/run/fake-systemd/$vm.log" 2>/dev/null | sed 's/^/     | /'
  fi
}

PROBE='
import ctypes, errno, os, socket
libc = ctypes.CDLL(None, use_errno=True)
def sc(name, nr, *args):
    r = libc.syscall(nr, *args)
    print(f"{name}={errno.errorcode.get(ctypes.get_errno(), 0) if r < 0 else 0}")
sc("clone3", 435, 0, 0)
sc("unshare_newuser", 272, 0x10000000)
sc("keyctl", 250, 0, 0)
sc("bpf", 321, 0, 0, 0)
sc("io_uring_setup", 425, 1, 0)
sc("userfaultfd", 323, 0)
sc("perf_event_open", 298, 0, 0, 0, 0, 0)
try:
    socket.socket(16, socket.SOCK_RAW, 12); print("netlink_netfilter=0")
except OSError as e: print("netlink_netfilter=" + errno.errorcode[e.errno])
'

dump_vm() {
  local vm=$1
  echo "     | --- $vm: unit log, LXC log, console"
  tail -15 "/run/fake-systemd/$vm.log" 2>/dev/null | sed 's/^/     | /'
  tail -15 "/var/lib/ubicloud/lxc/$vm/lxc.log" 2>/dev/null | sed 's/^/     | /'
  tail -25 "/var/lib/ubicloud/lxc/$vm/console.log" 2>/dev/null | tr -d '\r' | grep -v 'Job .* running' | tail -12 | sed 's/^/     | /'
  ip -n "$vm" -br addr 2>&1 | sed 's/^/     | /'
}

vm_checks() {
  local vm=$1 n=$2 ip base out
  ip=$POOL.$((10 + n))
  base=$((1000000000 + $(cat "/var/lib/ubicloud/idmap/$vm") * 65536))
  say "$vm: guest checks"
  check "$vm: DHCP gave the private address" ssh_vm "$ip" "ip -4 -o addr | grep -q ' 10.0.$n.5/'"
  check "$vm: cloud-init finished" ssh_vm "$ip" "cloud-init status --wait | grep -q 'status: done'"
  check "$vm: DNS through the VM's dnsmasq" ssh_vm "$ip" "getent hosts cloud-images.ubuntu.com"
  check "$vm: apt-get update" ssh_vm "$ip" "sudo apt-get -qq update"
  check "$vm: no kernel package can be installed" ssh_vm "$ip" "apt-cache policy linux-image-generic | grep -q 'Candidate: (none)'"
  check "$vm: the guest's root is host uid $base" ssh_vm "$ip" "awk '\$1 == 0 && \$2 == $base && \$3 == 65536 { f = 1 } END { exit !f }' /proc/self/uid_map"
  check "$vm: systemd says lxc" ssh_vm "$ip" "test \"\$(systemd-detect-virt)\" = lxc"
  check "$vm: no failed units" ssh_vm "$ip" "test -z \"\$(systemctl --failed --no-legend)\""
  check "$vm: no /dev/kvm, no /dev/fuse" ssh_vm "$ip" "test ! -e /dev/kvm && test ! -e /dev/fuse"
  check "$vm: /proc/sys is read-only" ssh_vm "$ip" "! sudo sh -c 'echo 1 > /proc/sys/kernel/panic' 2>/dev/null"
  check "$vm: the seed is a read-only mount" ssh_vm "$ip" "! sudo touch /var/lib/cloud/seed/nocloud/x 2>/dev/null"
  check "$vm: dmesg is refused" ssh_vm "$ip" "! sudo dmesg >/dev/null 2>&1"
  check "$vm: memory limit 1G, 2 CPUs" ssh_vm "$ip" "test \"\$(cat /sys/fs/cgroup/memory.max)\" = 1073741824 && test \"\$(cat /sys/fs/cgroup/cpu.max)\" = '200000 100000'"
  out=$(ssh_vm "$ip" "sudo python3 -c '$PROBE'" 2>&1 || true)
  local want
  for want in clone3=ENOSYS unshare_newuser=EPERM keyctl=ENOSYS bpf=EPERM io_uring_setup=EPERM userfaultfd=EPERM perf_event_open=EPERM netlink_netfilter=EAFNOSUPPORT; do
    if grep -qx "$want" <<<"$out"; then ok "$vm: seccomp $want"; else bad "$vm: seccomp $want (got: $(tr '\n' ' ' <<<"$out"))"; fi
  done
  read -r subnet gw </tmp/l3.testnet
  check_not "$vm: cannot reach another host of the test network ($subnet)" \
    ssh_vm "$ip" "timeout 4 bash -c 'echo > /dev/tcp/${subnet%.*/*}.2/5432'"
  check "$vm: the guest's processes are in the unit's lxc.payload cgroup" \
    grep -q . "/sys/fs/cgroup/system.slice/$vm.service/lxc.payload/init.scope/cgroup.procs"
  check "$vm: vm-stats reads the payload cgroup" bash -c "cd /home/rhizome && ruby /w/rhizome/host/bin/vm-stats $vm | ruby -rjson -e 'v = JSON.parse(\$stdin.read)[\"vm\"]; exit(v[\"cpu_stats\"][\"total_time_ms\"] > 0 && v[\"memory_current_bytes\"] > 0 ? 0 : 1)'"
  check "$vm: the serial log is the console" test -s "/var/lib/ubicloud/lxc/$vm/console.log"
}

# Plants symlinks where root might write, restarts the VM and the host
# path (recreate-unpersisted), and checks that no host file changed.
symlink_probe() {
  local vm=$1 n=$2 ip before after
  ip=$POOL.$((10 + n))
  say "$vm: symlink probes"
  before=$(sha256sum /etc/passwd /etc/shadow /etc/subuid /root/.ssh/authorized_keys 2>/dev/null; ls -la /etc /root)
  # Host paths a careless root would follow: none of them may change.
  ssh_vm "$ip" 'sudo ln -sfn /etc/shadow /x && sudo ln -sfn /etc/passwd /var/log/x && sudo rm -f /etc/hostname && sudo ln -s /root/.ssh/authorized_keys /etc/hostname' ||
    bad "$vm: could not plant the symlinks"
  check "$vm: stop-vm shuts the container down cleanly" bash -c "cd /home/rhizome && ruby /w/rhizome/host/bin/stop-vm $vm && for i in \$(seq 100); do systemctl is-active $vm >/dev/null || exit 0; sleep 0.2; done; exit 1"
  systemctl stop "$vm"
  local base
  base=$((1000000000 + $(cat "/var/lib/ubicloud/idmap/$vm") * 65536))
  check "$vm: nothing of the container is left after the stop" bash -c "! ps -eo uid= | awk '\$1 >= $base && \$1 < $base + 65536' | grep -q . && test -z \"\$(cat /sys/fs/cgroup/system.slice/$vm.service/*/cgroup.procs 2>/dev/null)\""
  # A host reboot: nothing of the VM runs when recreate-unpersisted does.
  systemctl stop "$vm-dnsmasq"
  check "$vm: recreate-unpersisted brings it back" bash -c "echo '{\"storage\":{}}' | (cd /home/rhizome && ruby $W/lab-setup-vm.rb recreate-unpersisted $vm)"
  local i
  for ((i = 0; i < 120; i++)); do ssh_vm "$ip" true 2>/dev/null && break; sleep 0.25; done
  check "$vm: SSH again after the restart" ssh_vm "$ip" true || true
  ssh_vm "$ip" true 2>/dev/null || dump_vm "$vm"
  check "$vm: restart through setup-vm" bash -c "cd /home/rhizome && ruby $W/lab-setup-vm.rb restart $vm"
  for ((i = 0; i < 120; i++)); do ssh_vm "$ip" true 2>/dev/null && break; sleep 0.25; done
  check "$vm: SSH again after setup-vm restart" ssh_vm "$ip" true
  after=$(sha256sum /etc/passwd /etc/shadow /etc/subuid /root/.ssh/authorized_keys 2>/dev/null; ls -la /etc /root)
  if [ "$before" = "$after" ]; then ok "$vm: no host file changed through the planted symlinks"; else
    bad "$vm: host files changed"
    diff <(echo "$before") <(echo "$after") | sed 's/^/     | /'
  fi
}

isolation() {
  say "isolation between the two VMs"
  check_not "vm A cannot reach vm B's private address" ssh_vm "$POOL.11" "timeout 4 bash -c 'echo > /dev/tcp/10.0.2.5/22'"
  check "vm A sees only its own processes" ssh_vm "$POOL.11" "! ps -eo comm | grep -qx -e lxc-start -e dnsmasq"
  check "the two VMs have disjoint id ranges" test "$(cat /var/lib/ubicloud/idmap/vml3aaa1)" != "$(cat /var/lib/ubicloud/idmap/vml3aaa2)"
}

vm_delete() {
  local vm=$1 round
  say "$vm: delete (twice)"
  systemctl stop "$vm"
  systemctl stop "$vm-dnsmasq"
  for round in 1 2; do
    check "$vm: setup-vm delete, round $round" setup_vm delete "$vm"
  done
  check "$vm: nothing left (netns, unit, LXC files, disk, slot, home, user)" bash -c "
    ! ip netns list | grep -qw $vm && test ! -e /etc/systemd/system/$vm.service && test ! -e /var/lib/ubicloud/lxc/$vm &&
    test ! -e /var/storage/$vm && test ! -e /var/lib/ubicloud/idmap/$vm && test ! -e /vm/$vm && ! id $vm 2>/dev/null"
}

host_setup
mkdir -p /root/.ssh
[ -f /root/.ssh/id_l3 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_l3
export IMAGE_VERSION
image
vm_create vml3aaa1 1
if [ "${L3_DEBUG:-0}" = 1 ]; then
  say "L3_DEBUG=1: holding the lab for inspection (nsenter -t $$ -m)"
  exec sleep infinity
fi
vm_create vml3aaa2 2
vm_checks vml3aaa1 1
vm_checks vml3aaa2 2
isolation
symlink_probe vml3aaa1 1
vm_delete vml3aaa1
vm_delete vml3aaa2
check "no process of any container id is left" bash -c "! ps -eo uid= | awk '\$1 >= 1000000000' | grep -q ."
check "no LXC monitor is left" bash -c "! pgrep -x lxc-start"
say "scratch used: $(du -sh $SCRATCH | cut -f1)"
if [ "$fails" -eq 0 ]; then say "l3 ok"; else
  say "l3: $fails failures"
  exit 1
fi
