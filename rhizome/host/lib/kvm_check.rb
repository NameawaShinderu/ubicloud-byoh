# frozen_string_literal: true

require_relative "../../common/lib/arch"

module KvmCheck
  # Returns why this host cannot run KVM guests, or nil when it can.
  def self.problem(arch: Arch, kvm_path: "/dev/kvm", cpuinfo_path: "/proc/cpuinfo")
    unless File.chardev?(kvm_path)
      return "#{kvm_path} is not a character device, so KVM is unavailable. Enable virtualization in the firmware, or nested virtualization if this host is itself a VM."
    end

    if arch.x64? && !File.read(cpuinfo_path).match?(/^flags\s*:.*\b(?:vmx|svm)\b/)
      return "The CPU has neither the vmx nor the svm flag, so hardware virtualization is unavailable. Enable VT-x or AMD-V in the firmware, or nested virtualization if this host is itself a VM."
    end

    nil
  end
end
