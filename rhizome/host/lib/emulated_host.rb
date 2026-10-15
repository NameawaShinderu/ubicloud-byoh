# frozen_string_literal: true

require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"
require_relative "kvm_check"
require_relative "qemu_tcg"

# Host preparation for emulated hosts (accel=tcg): hosts without KVM,
# whose VMs run under QEMU's software translator. See
# docs/byoh/EMULATED_HOSTS.md section 6.3.
#
# bin/prep_host.rb runs the steps prep_steps lists for the host's accel.
# The kvm list is the order prep_host.rb ran its steps in before emulated
# hosts existed, so KVM hosts are prepared exactly as before.
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
module EmulatedHost
  class Unsupported < RuntimeError
  end

  # The Ubuntu packages that provide QEMU's x86_64 system emulator and the
  # OVMF UEFI firmware (QemuTcg::FIRMWARE).
  PACKAGES = %w[qemu-system-x86 ovmf].freeze

  QEMU_BIN = "qemu-system-x86_64"

  INSTALL_HINT = "run scripts/byoh/bootstrap-data-plane.sh --emulated (or apt-get install qemu-system-x86 ovmf)"

  KVM_AVAILABLE_HINT = "KVM is available; register without --accel tcg to use cloud-hypervisor"

  # Resident memory of one VM's vhost-user block backend (ubiblk) plus its
  # dnsmasq, in MiB. The control plane's per-VM overhead on emulated hosts
  # (EMULATED_VM_OVERHEAD_MIB) must cover QemuTcg::TB_SIZE_MIB, about
  # 128 MiB of QEMU heap and device state, and this. Provisional and
  # UNVERIFIED: the container harness measures both processes for
  # emulated-2 and emulated-4 VMs and sets the final value.
  BACKEND_RSS_MIB = 64

  # Steps shared by both accels, in prep_host.rb's original order.
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
  TCG_STEPS = [
    :check_arch,
    :check_emulator,
    :kvm_hint,
    *COMMON_STEPS,
    *LATE_STEPS,
  ].freeze

  def self.prep_steps(accel)
    case accel
    when "kvm" then KVM_STEPS
    when "tcg" then TCG_STEPS
    else raise Unsupported, "unknown accel #{accel.inspect}, expected kvm or tcg"
    end
  end

  # Emulated hosts run x86_64 guests only, and the TCG unit
  # (VmSetup#build_qemu_service) refuses arm64.
  def self.check_arch!(arch: Arch)
    return if arch.x64?

    raise Unsupported, "emulated hosts must be x86_64; this host is #{arch.sym}"
  end

  # The PACKAGES that dpkg does not list as installed. dpkg-query exits 1
  # when it does not know one of the names, and prints nothing for it; a
  # package that was removed but left its configuration behind is listed
  # with a status other than "ii".
  def self.missing_packages
    out = r("dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", *PACKAGES, expect: [0, 1])
    PACKAGES - out.scan(/^(\S+) ii/).flatten
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
  # or nil. It never changes the host's accel: switching needs
  # re-registration.
  def self.kvm_hint(kvm_problem: KvmCheck.problem)
    KVM_AVAILABLE_HINT unless kvm_problem
  end
end
