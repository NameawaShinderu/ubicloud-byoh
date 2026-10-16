# frozen_string_literal: true

require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"
require_relative "kvm_check"
require_relative "qemu_tcg"
require_relative "container_idmap"
require_relative "container_setup"
require "etc"

# Host preparation per virtualization tier (docs/byoh/NO_KVM.md; the
# control plane's ByohVirtTiers). bin/prep_host.rb runs the steps
# prep_steps lists for the tier the host was registered on. The kvm list
# is the order prep_host.rb ran its steps in before tiers existed, so KVM
# hosts are prepared exactly as before.
#
# The emulated tier runs VMs under QEMU's software translator on hosts
# without KVM (docs/byoh/EMULATED_HOSTS.md section 6.3). The container
# tier runs system containers (ContainerSetup). The pvm tier has no host
# support in this rhizome yet, so prep refuses it before changing
# anything.
#
# An emulated host differs in three ways:
# - It is not refused for lacking KVM.
# - It downloads neither cloud-hypervisor nor its firmware; QEMU and OVMF
#   come from Ubuntu packages instead.
# - Those packages are checked, never installed. PrepHost runs inside a
#   respirate strand, which the dispatcher kills after about 90 seconds,
#   so prep_host.rb must not depend on how long apt takes to fetch QEMU.
#   The operator installs them beforehand with
#   scripts/byoh/bootstrap-data-plane.sh --tier emulated.
module HostTier
  class Unsupported < RuntimeError
  end

  # The Ubuntu packages that provide QEMU's x86_64 system emulator and the
  # OVMF UEFI firmware (QemuTcg::FIRMWARE).
  PACKAGES = %w[qemu-system-x86 ovmf].freeze

  QEMU_BIN = "qemu-system-x86_64"

  INSTALL_HINT = "run scripts/byoh/bootstrap-data-plane.sh --tier emulated (or apt-get install qemu-system-x86 ovmf)"

  KVM_AVAILABLE_HINT = "KVM is available; register the host again as kvm (bin/register-byoh-host --virt-tier kvm) to use cloud-hypervisor"

  TIERS = %w[kvm container pvm emulated].freeze

  # Resident memory of one VM's vhost-user block backend (ubiblk) plus its
  # dnsmasq, in MiB. The control plane's per-VM overhead on emulated hosts
  # (EMULATED_VM_OVERHEAD_MIB) must cover QemuTcg::TB_SIZE_MIB, about
  # 128 MiB of QEMU heap and device state, and this. Provisional and
  # UNVERIFIED: the container harness measures both processes for
  # emulated-2 and emulated-4 VMs and sets the final value.
  BACKEND_RSS_MIB = 64

  # Steps shared by kvm and emulated hosts, in prep_host.rb's original
  # order.
  COMMON_STEPS = %i[
    hostname
    prompt
    motd
    timezone
  ].freeze

  LATE_STEPS = %i[
    needrestart
    forwarding_sysctls
    blacklist_irdma
    unload_irdma
    image_packages
    prod_packages
    disk_probe_packages
    uplink_mac_pin
    htcat
    spdk
    crypt_swap
    serial_log_cron
  ].freeze

  KVM_STEPS = [
    :kvm_check,
    *COMMON_STEPS,
    :download_ch,
    :download_firmware,
    *LATE_STEPS,
  ].freeze

  # The checks come first, so a host that cannot run emulated VMs is
  # refused before prep changes anything, as kvm_check does for KVM hosts.
  EMULATED_STEPS = [
    :check_arch,
    :check_emulator,
    :kvm_hint,
    *COMMON_STEPS,
    *LATE_STEPS,
  ].freeze

  # A container host is checked first as well: x86_64, the container
  # userspace, the kernel settings a shared kernel needs and the id range.
  # Then it gets what containers need beyond the kvm steps.
  CONTAINER_STEPS = [
    :check_container_arch,
    :check_container_runtime,
    :check_container_sysctls,
    :check_idmap_range,
    :kvm_hint,
    *COMMON_STEPS,
    :container_host_setup,
    *LATE_STEPS,
  ].freeze

  # The packages a container host needs (scripts/byoh/bootstrap-data-plane.sh
  # --tier container installs them): LXC, lxcfs, newuidmap, xz for the root
  # tarballs, setquota for unencrypted disks, cryptsetup and mkfs.ext4 for
  # encrypted ones.
  # "a|b" takes either package: Ubuntu 24.04 ships the LXC tools in lxc,
  # later releases in lxc-utils.
  CONTAINER_PACKAGES = %w[lxc|lxc-utils lxcfs uidmap xz-utils quota cryptsetup-bin e2fsprogs].freeze

  CONTAINER_INSTALL_HINT = "run scripts/byoh/bootstrap-data-plane.sh --tier container (or apt-get install lxc lxcfs uidmap xz-utils quota cryptsetup-bin e2fsprogs)"

  # Kernel settings a shared kernel needs before untrusted guests run on
  # it, with the least value each needs (docs/byoh/NO_KVM.md section 4.2).
  # Ubuntu 24.04 ships all of them; prep checks and never sets them.
  CONTAINER_SYSCTLS = {
    "kernel.dmesg_restrict" => 1,
    "kernel.kptr_restrict" => 1,
    "kernel.unprivileged_bpf_disabled" => 1,
    "kernel.perf_event_paranoid" => 2,
  }.freeze

  # DelegateSubgroup= in the container unit (ContainerSetup#unit).
  MIN_SYSTEMD = 254

  def self.prep_steps(tier)
    case tier
    when "kvm" then KVM_STEPS
    when "emulated" then EMULATED_STEPS
    when "container" then CONTAINER_STEPS
    when *TIERS then raise Unsupported, "#{tier} hosts are not supported by this rhizome yet (docs/byoh/NO_KVM.md section 11)"
    else raise Unsupported, "unknown tier #{tier.inspect}, expected one of #{TIERS.join(", ")}"
    end
  end

  # Emulated hosts run x86_64 guests only, and the TCG unit
  # (VmSetup#build_qemu_service) refuses arm64.
  def self.check_arch!(arch: Arch, tier: "emulated")
    return if arch.x64?

    raise Unsupported, "#{tier} hosts must be x86_64; this host is #{arch.sym}"
  end

  # The PACKAGES that dpkg does not list as installed. dpkg-query exits 1
  # when it does not know one of the names, and prints nothing for it.
  #
  # ${db:Status-Abbrev} is three characters: the desired action, the
  # current state and the error flag. A package counts when its state is
  # "i" (installed) and its error flag is blank, and its desired action
  # is unknown, install or hold. Hold matters: operators may pin QEMU
  # with apt-mark hold so upgrades never change the emulator under
  # running guests, and installing again would not help. A package marked
  # for removal or purge is refused, since the next apt run removes it;
  # so is one that was removed with its configuration kept ("rc").
  #
  # Any other dpkg-query failure, such as a locked or broken dpkg
  # database, is reported as Unsupported so prep_host.rb aborts with the
  # error instead of a backtrace.
  def self.missing_packages(packages = PACKAGES, hint = INSTALL_HINT)
    out = begin
      r("dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", *packages.flat_map { |spec| spec.split("|") }, expect: [0, 1])
    rescue CommandFail, SystemCallError => e
      raise Unsupported, "dpkg-query failed: #{e.message.strip}; #{hint}"
    end
    installed = out.scan(/^(\S+) [uih]i $/).flatten
    packages.reject { |spec| spec.split("|").any? { |name| installed.include?(name) } }
  end

  # Whether QEMU runs and was built with the TCG accelerator.
  def self.accel_help_ok?
    r(QEMU_BIN, "-accel", "help").lines.map(&:strip).include?("tcg")
  rescue CommandFail, SystemCallError
    false
  end

  # Raises Unsupported, with what to do, unless the emulator and its
  # firmware are installed and usable.
  def self.check_emulator!(firmware: QemuTcg::FIRMWARE)
    unless (missing = missing_packages).empty?
      raise Unsupported, "missing packages: #{missing.join(" ")}; #{INSTALL_HINT}"
    end

    unless accel_help_ok?
      raise Unsupported, "#{QEMU_BIN} -accel help does not list tcg; #{INSTALL_HINT}"
    end

    unless File.file?(firmware)
      raise Unsupported, "#{firmware} is missing; #{INSTALL_HINT}"
    end

    nil
  end

  # A hint for an emulated host that could run cloud-hypervisor after all,
  # or nil. It never changes the host's tier: switching needs
  # re-registration.
  def self.kvm_hint(kvm_problem: KvmCheck.problem)
    KVM_AVAILABLE_HINT unless kvm_problem
  end

  # Raises Unsupported, with what to do, unless the host can run system
  # containers: cgroup v2, Linux 5.12 or newer, systemd with
  # DelegateSubgroup=, the CONTAINER_PACKAGES, and AppArmor with LXC's
  # container profile loaded.
  def self.check_container_runtime!(root: "/", release: Etc.uname[:release])
    unless File.exist?(File.join(root, "sys/fs/cgroup/cgroup.controllers"))
      raise Unsupported, "containers need the unified cgroup hierarchy (cgroup v2)"
    end

    if Gem::Version.new(release[/\A\d+\.\d+/] || "0") < Gem::Version.new("5.12")
      raise Unsupported, "containers need Linux 5.12 or newer; this host runs #{release}"
    end

    systemd = r("systemctl", "--version")[/\Asystemd (\d+)/, 1].to_i
    raise Unsupported, "containers need systemd #{MIN_SYSTEMD} or newer (DelegateSubgroup=); this host has #{systemd}" if systemd < MIN_SYSTEMD

    unless (missing = missing_packages(CONTAINER_PACKAGES, CONTAINER_INSTALL_HINT)).empty?
      raise Unsupported, "missing packages: #{missing.join(" ")}; #{CONTAINER_INSTALL_HINT}"
    end

    unless File.read(File.join(root, "sys/module/apparmor/parameters/enabled")).strip == "Y"
      raise Unsupported, "containers need AppArmor enabled"
    end

    profile = ContainerSetup::APPARMOR_PROFILE
    unless File.foreach(File.join(root, "sys/kernel/security/apparmor/profiles")).any? { _1.start_with?("#{profile} ") }
      raise Unsupported, "AppArmor profile #{profile} is not loaded; install lxc and run systemctl reload apparmor"
    end

    nil
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Unsupported, "cannot check AppArmor: #{e.message}"
  end

  # Raises Unsupported, with the settings to add, unless every
  # CONTAINER_SYSCTLS value is at least its minimum.
  def self.check_container_sysctls!(root: "/")
    low = CONTAINER_SYSCTLS.filter_map do |key, min|
      path = File.join(root, "proc/sys", key.tr(".", "/"))
      value = begin
        Integer(File.read(path).strip, 10)
      rescue Errno::ENOENT, ArgumentError
        nil
      end
      "#{key} = #{min}" if value.nil? || value < min
    end
    return if low.empty?

    raise Unsupported, "a container host needs these kernel settings; add them to /etc/sysctl.d/60-ubicloud-containers.conf and run sysctl --system: #{low.join(", ")}"
  end

  # Raises Unsupported unless no subordinate id range of another user
  # reaches the container id slots (ContainerIdmap).
  def self.check_idmap_range!(files: ContainerIdmap::SUBID_FILES)
    overlaps = ContainerIdmap.overlaps(files: files)
    return if overlaps.empty?

    raise Unsupported, "subordinate id ranges overlap the container id range #{ContainerIdmap::BASE}+: #{overlaps.join("; ")}"
  end

  # What a container host needs: newuidmap may map root's container
  # slots; useradd gives no new user subordinate ids (none can then reach
  # the slots); the kvm group exists for create_unix_user's usermod;
  # Ubuntu's lxc-net bridge, which would add its own dnsmasq and NAT next
  # to rhizome's, is off; LXC's directories exist.
  def self.container_host_setup(login_defs: "/etc/login.defs")
    ContainerIdmap.ensure_root_entries
    content = File.read(login_defs)
    %w[SUB_UID_COUNT SUB_GID_COUNT].each do |key|
      line = "#{key}\t\t0"
      content = if content.match?(/^#{key}\s/)
        content.gsub(/^#{key}\s.*$/, line)
      else
        "#{content.chomp}\n#{line}\n"
      end
    end
    safe_write_to_file(login_defs, content, perm: 0o644)
    r "groupadd", "-f", "-r", "kvm"
    safe_write_to_file("/etc/default/lxc-net", "# Written by rhizome: rhizome sets up container networking.\nUSE_LXC_BRIDGE=\"false\"\n", perm: 0o644)
    r "systemctl", "disable", "--now", "lxc-net.service" if File.exist?("/usr/lib/systemd/system/lxc-net.service")
    r "install", "-d", "-m", "0711", ContainerSetup::LXC_PATH
    r "install", "-d", "-m", "0700", ContainerIdmap::DIR
  end
end
