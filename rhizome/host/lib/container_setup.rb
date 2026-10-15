# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/util"
require_relative "container_idmap"

# System containers: the container tier of the virtualization ladder
# (docs/byoh/NO_KVM.md section 4.2), for hosts without hardware
# virtualization. A container VM is an unprivileged LXC container that
# boots the guest's own systemd on the host kernel, inside rhizome's
# per-VM network namespace; VmSetup drives it like a cloud-hypervisor VM
# (the same netns, nftables, dnsmasq and cloud-init data), with these
# parts swapped:
#
# - The unit runs lxc-start as root in the VM's network namespace, with
#   explicit id maps (ContainerIdmap), never as the VM's unix user. The
#   container's root is an unprivileged host uid of its own slot.
# - LXC's configuration, seccomp policy, network hook, cloud-init seed
#   and console log live in a root-only directory outside the VM's home
#   (#dir), so no file there can be swapped by the VM's unix user. The
#   seed reaches the guest as a read-only bind mount; rhizome never
#   writes into the guest's root file system after extracting it.
# - The guest's tap is the host end of a veth pair that LXC creates;
#   the network hook (setup-vm net-up) gives it the addresses and routes
#   a tap gets (VmSetup#container_net_up).
# - The disk is a directory or an encrypted loop file (ContainerDisk).
#
# The policy narrows LXC's unprivileged defaults: LXC's own seccomp
# denials plus keyctl, bpf, userfaultfd, perf_event_open, kexec and
# io_uring; no new user namespaces (clone3 fails with ENOSYS so libc
# falls back to clone, whose CLONE_NEWUSER flag seccomp can see) unless
# the location acknowledged "nested-userns"; no netfilter netlink socket
# (nftables or iptables-nft in the guest) unless it acknowledged
# "guest-firewall"; AppArmor's lxc-container-default-cgns profile; no
# device but LXC's standard ones (the guest cannot create device files in
# its user namespace, so LXC's device allowlist, which names /dev/fuse,
# reaches no other); and cgroup limits for CPU, memory, swap and tasks.
# (An explicit device deny entry made LXC 5.0.3 refuse /dev/null as well,
# verified in the l3 lab.)
class ContainerSetup
  LXC_PATH = "/var/lib/ubicloud/lxc"
  APPARMOR_PROFILE = "lxc-container-default-cgns"
  LXC_START = "/usr/bin/lxc-start"
  LXC_STOP = "/usr/bin/lxc-stop"
  NSENTER = "/usr/bin/nsenter"
  # Where rhizome lives on every host (as in prep_host.rb's cron entry).
  RHIZOME_HOME = "/home/rhizome"
  SETUP_VM = "#{RHIZOME_HOME}/host/bin/setup-vm"

  # Tasks per vCPU (pids.max).
  PIDS_PER_VCPU = 2048

  # How long a stop waits for the guest's systemd to power off before
  # LXC kills the container.
  STOP_TIMEOUT_SECONDS = 60

  # LXC's /usr/share/lxc/config/common.seccomp, which a profile of our own
  # replaces, followed by the denials of docs/byoh/NO_KVM.md section 4.2.
  # Argument comparisons are [index,value,op] or, for SCMP_CMP_MASKED_EQ,
  # [index,value,op,mask], in decimal (verified with LXC 5.0.3).
  CLONE_NEWUSER = 0x10000000
  SECCOMP_COMMON = [
    "kexec_load errno 1",
    "open_by_handle_at errno 1",
    "init_module errno 1",
    "finit_module errno 1",
    "delete_module errno 1",
  ].freeze
  SECCOMP_DENY = [
    "kexec_file_load errno 1",
    "keyctl errno 38",
    "bpf errno 1",
    "userfaultfd errno 1",
    "perf_event_open errno 1",
    "io_uring_setup errno 1",
    "io_uring_enter errno 1",
    "io_uring_register errno 1",
  ].freeze
  SECCOMP_NO_USERNS = [
    "clone3 errno 38",
    "clone errno 1 [0,#{CLONE_NEWUSER},SCMP_CMP_MASKED_EQ,#{CLONE_NEWUSER}]",
    "unshare errno 1 [0,#{CLONE_NEWUSER},SCMP_CMP_MASKED_EQ,#{CLONE_NEWUSER}]",
  ].freeze
  # socket(AF_NETLINK, *, NETLINK_NETFILTER) fails as if netlink were
  # missing (EAFNOSUPPORT).
  SECCOMP_NO_NETFILTER = ["socket errno 97 [0,16,SCMP_CMP_EQ][2,12,SCMP_CMP_EQ]"].freeze

  # Units a container cannot run; the guest image masks them
  # (ContainerDisk#tweak_image).
  MASKED_UNITS = %w[sys-kernel-config.mount sys-kernel-debug.mount systemd-remount-fs.service].freeze

  def initialize(vm_name, nested_userns: false, guest_firewall: false, lxc_path: LXC_PATH)
    ContainerIdmap.check_name!(vm_name)
    @vm_name = vm_name
    @nested_userns = nested_userns
    @guest_firewall = guest_firewall
    @lxc_path = lxc_path
  end

  def nested_userns? = @nested_userns

  def guest_firewall? = @guest_firewall

  # The container's directory: root-owned and only traversable by others,
  # because LXC's child, already running as the container's root,
  # resolves the seed path through it.
  def dir = File.join(@lxc_path, @vm_name)

  def config_path = File.join(dir, "config")

  def seccomp_path = File.join(dir, "seccomp")

  def net_up_path = File.join(dir, "net-up")

  def seed_dir = File.join(dir, "seed")

  def console_log = File.join(dir, "console.log")

  def lxc_log = File.join(dir, "lxc.log")

  # The cgroup that holds the guest's processes (lxc.cgroup.dir.container),
  # relative to the cgroup2 mount.
  def payload_cgroup(slice_name) = "#{slice_name}/#{@vm_name}.service/lxc.payload"

  def apparmor_profile = APPARMOR_PROFILE

  def lxc_config(rootfs:, slot:, nics:, mem_gib:, max_vcpus:, slice_name:)
    fail "container VMs run in system.slice, not #{slice_name}" unless slice_name == "system.slice"

    base = ContainerIdmap.base(slot)
    net = nics.each_with_index.flat_map do |nic, i|
      [
        "lxc.net.#{i}.type = veth",
        "lxc.net.#{i}.veth.pair = #{nic.tap}",
        "lxc.net.#{i}.name = eth#{i}",
        "lxc.net.#{i}.hwaddr = #{nic.mac}",
        "lxc.net.#{i}.flags = up",
        "lxc.net.#{i}.script.up = #{net_up_path}",
      ]
    end

    <<~CONFIG
      # Written by rhizome (ContainerSetup); docs/byoh/NO_KVM.md section 4.2.
      lxc.include = /usr/share/lxc/config/common.conf
      lxc.include = /usr/share/lxc/config/userns.conf
      lxc.arch = linux64
      lxc.uts.name = #{@vm_name}
      lxc.rootfs.path = dir:#{rootfs}
      lxc.idmap = u 0 #{base} #{ContainerIdmap::SIZE}
      lxc.idmap = g 0 #{base} #{ContainerIdmap::SIZE}
      lxc.apparmor.profile = #{apparmor_profile}
      lxc.apparmor.allow_nesting = 0
      lxc.seccomp.profile = #{seccomp_path}
      lxc.cap.drop =
      lxc.cap.drop = mac_admin mac_override sys_time sys_module sys_rawio
      lxc.mount.auto =
      lxc.mount.auto = proc:mixed sys:mixed cgroup:rw:force
      lxc.mount.entry = #{seed_dir} var/lib/cloud/seed/nocloud none ro,bind,create=dir 0 0
      lxc.cgroup.dir.monitor = #{slice_name}/#{@vm_name}.service/lxc.monitor
      lxc.cgroup.dir.container = #{payload_cgroup(slice_name)}
      lxc.cgroup2.cpu.max = #{max_vcpus * 100000} 100000
      lxc.cgroup2.memory.max = #{mem_gib}G
      lxc.cgroup2.memory.swap.max = 0
      lxc.cgroup2.pids.max = #{max_vcpus * PIDS_PER_VCPU}
      lxc.console.logfile = #{console_log}
      lxc.init.cmd = /sbin/init
      #{net.join("\n")}
    CONFIG
  end

  def seccomp_policy
    rules = SECCOMP_COMMON + SECCOMP_DENY
    rules += SECCOMP_NO_USERNS unless @nested_userns
    rules += SECCOMP_NO_NETFILTER unless @guest_firewall
    <<~POLICY
      2
      denylist
      reject_force_umount
      [all]
      #{rules.join("\n")}
    POLICY
  end

  # LXC runs it as root in the VM's network namespace once it created the
  # host end of a veth pair, the guest's tap. It starts in rhizome's home,
  # where bundler finds rhizome's Gemfile, as every rhizome command does.
  def net_up_script
    <<~SCRIPT
      #!/bin/sh
      # Written by rhizome (ContainerSetup): addresses and routes for the tap.
      cd #{RHIZOME_HOME}
      exec #{SETUP_VM} net-up #{@vm_name}
    SCRIPT
  end

  # The VM's unit. systemd puts lxc-start in a delegated subgroup, so LXC
  # can move its monitor and the guest into lxc.monitor and lxc.payload
  # under the unit's cgroup, and a stop of the unit stops everything in
  # it. LXC's command socket is an abstract socket, which belongs to the
  # VM's network namespace, so lxc-stop runs there too.
  def unit(slice_name:)
    <<~UNIT
      [Unit]
      Description=#{@vm_name}
      After=network.target
      After=#{@vm_name}-dnsmasq.service
      Wants=#{@vm_name}-dnsmasq.service

      [Service]
      Slice=#{slice_name}
      NetworkNamespacePath=/var/run/netns/#{@vm_name}
      Delegate=yes
      DelegateSubgroup=supervisor
      ExecStart=#{LXC_START} -F -n #{@vm_name} -P #{@lxc_path} -o #{lxc_log} -l WARN
      ExecStop=#{LXC_STOP} -n #{@vm_name} -P #{@lxc_path} -t #{STOP_TIMEOUT_SECONDS}
      TimeoutStopSec=#{STOP_TIMEOUT_SECONDS + 30}s
      Restart=no
      LimitNOFILE=500000
    UNIT
  end

  # The command bin/stop-vm runs: a clean shutdown of the guest, without
  # waiting for it (like cloud-hypervisor's power button).
  def stop_command
    [NSENTER, "--net=/var/run/netns/#{@vm_name}", LXC_STOP, "-n", @vm_name, "-P", @lxc_path, "--nowait"]
  end

  def write_config(rootfs:, slot:, nics:, mem_gib:, max_vcpus:, slice_name:)
    make_dir
    write(config_path, lxc_config(rootfs: rootfs, slot: slot, nics: nics, mem_gib: mem_gib, max_vcpus: max_vcpus, slice_name: slice_name), 0o600)
    write(seccomp_path, seccomp_policy, 0o600)
    write(net_up_path, net_up_script, 0o700)
  end

  # The NoCloud seed, from the cloud-init data VmSetup wrote for the VM.
  def write_seed(meta_data:, user_data:, network_config:)
    make_dir
    r "install", "-d", "-o", "root", "-g", "root", "-m", "0755", seed_dir
    write(File.join(seed_dir, "meta-data"), meta_data, 0o644)
    write(File.join(seed_dir, "user-data"), user_data, 0o644)
    write(File.join(seed_dir, "network-config"), network_config, 0o644)
  end

  def purge
    rm_if_exists(dir)
  end

  private

  def make_dir
    r "install", "-d", "-o", "root", "-g", "root", "-m", "0711", @lxc_path
    r "install", "-d", "-o", "root", "-g", "root", "-m", "0711", dir
  end

  def write(path, content, perm)
    File.write("#{path}.tmp", content, perm: perm)
    File.chmod(perm, "#{path}.tmp")
    File.rename("#{path}.tmp", path)
  end
end
