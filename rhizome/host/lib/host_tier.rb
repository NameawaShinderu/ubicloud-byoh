# frozen_string_literal: true

require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"
require_relative "kvm_check"
require_relative "qemu_tcg"

# Host preparation per virtualization tier (docs/byoh/NO_KVM.md; the
# control plane's ByohVirtTiers). bin/prep_host.rb runs the steps
# prep_steps lists for the tier the host was registered on. The kvm list
# is the order prep_host.rb ran its steps in before tiers existed, so KVM
# hosts are prepared exactly as before.
#
# The emulated tier runs VMs under QEMU's software translator on hosts
# without KVM (docs/byoh/EMULATED_HOSTS.md section 6.3). The container and
# pvm tiers have no host support in this rhizome yet, so prep refuses
# them before changing anything.
#
# An emulated host differs in three ways:
# - It is not refused for lacking KVM.
# - It downloads neither cloud-hypervisor nor its firmware; QEMU and OVMF
#   come from Ubuntu packages instead.
# - Those packages are checked, never installed. PrepHost runs inside a
#   respirate strand, which the dispatcher kills after about 90 seconds,
#   so prep_host.rb must not depend on how long apt takes to fetch QEMU.
#   The operator installs them beforehand with
#   scripts/byoh/bootstrap-data-plane.sh --emulated.
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

  def self.prep_steps(tier)
    case tier
    when "kvm" then KVM_STEPS
    when "emulated" then EMULATED_STEPS
    when *TIERS then raise Unsupported, "#{tier} hosts are not supported by this rhizome yet (docs/byoh/NO_KVM.md section 11)"
    else raise Unsupported, "unknown tier #{tier.inspect}, expected one of #{TIERS.join(", ")}"
    end
  end

  # Emulated hosts run x86_64 guests only, and the TCG unit
  # (VmSetup#build_qemu_service) refuses arm64.
  def self.check_arch!(arch: Arch)
    return if arch.x64?

    raise Unsupported, "emulated hosts must be x86_64; this host is #{arch.sym}"
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
  def self.missing_packages
    out = begin
      r("dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", *PACKAGES, expect: [0, 1])
    rescue CommandFail, SystemCallError => e
      raise Unsupported, "dpkg-query failed: #{e.message.strip}; #{INSTALL_HINT}"
    end
    PACKAGES - out.scan(/^(\S+) [uih]i $/).flatten
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
end
