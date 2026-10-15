# frozen_string_literal: true

require_relative "../lib/emulated_host"

RSpec.describe EmulatedHost do
  let(:x64) { ArchClass.new(:x64) }
  let(:arm64) { ArchClass.new(:arm64) }
  let(:dpkg_query) { ["dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", "qemu-system-x86", "ovmf", {expect: [0, 1]}] }

  describe ".prep_steps" do
    # The order bin/prep_host.rb ran its steps in before emulated hosts
    # existed (9e22d71ec). KVM hosts must keep it: a change here changes
    # how every cloud-hypervisor host is prepared.
    it "keeps the original step order for kvm" do
      expect(described_class.prep_steps("kvm")).to eq(%i[
        kvm_check
        hostname
        prompt
        motd
        timezone
        download_ch
        download_firmware
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
      ])
    end

    it "checks first, then runs the kvm steps without the KVM check and the cloud-hypervisor downloads for tcg" do
      expect(described_class.prep_steps("tcg")).to eq(%i[check_arch check_emulator kvm_hint] +
        described_class.prep_steps("kvm") - %i[kvm_check download_ch download_firmware])
    end

    it "refuses an unknown accel" do
      expect { described_class.prep_steps("hvf") }.to raise_error(EmulatedHost::Unsupported, 'unknown accel "hvf", expected kvm or tcg')
      expect { described_class.prep_steps(nil) }.to raise_error(EmulatedHost::Unsupported, "unknown accel nil, expected kvm or tcg")
    end
  end

  describe ".check_arch!" do
    it "accepts x86_64" do
      expect(described_class.check_arch!(arch: x64)).to be_nil
    end

    it "refuses arm64" do
      expect { described_class.check_arch!(arch: arm64) }.to raise_error(EmulatedHost::Unsupported, "emulated hosts must be x86_64; this host is arm64")
    end
  end

  describe ".missing_packages" do
    it "is empty when dpkg lists every package as installed" do
      expect(described_class).to receive(:r).with(*dpkg_query).and_return("qemu-system-x86 ii \novmf ii \n")
      expect(described_class.missing_packages).to eq([])
    end

    it "lists a package dpkg does not know" do
      expect(described_class).to receive(:r).with(*dpkg_query).and_return("qemu-system-x86 ii \n")
      expect(described_class.missing_packages).to eq(["ovmf"])
    end

    it "lists a package that was removed with its configuration kept" do
      expect(described_class).to receive(:r).with(*dpkg_query).and_return("qemu-system-x86 rc \novmf ii \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86"])
    end

    it "does not take a package whose name only starts with a wanted one" do
      expect(described_class).to receive(:r).with(*dpkg_query).and_return("ovmf-ia32 ii \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end
  end

  describe ".accel_help_ok?" do
    it "is true when QEMU lists tcg" do
      expect(described_class).to receive(:r).with("qemu-system-x86_64", "-accel", "help").and_return("Accelerators supported in QEMU binary:\ntcg\nkvm\n")
      expect(described_class.accel_help_ok?).to be(true)
    end

    it "is false when QEMU does not list tcg" do
      expect(described_class).to receive(:r).with("qemu-system-x86_64", "-accel", "help").and_return("Accelerators supported in QEMU binary:\nkvm\n")
      expect(described_class.accel_help_ok?).to be(false)
    end

    it "is false when QEMU fails" do
      expect(described_class).to receive(:r).and_raise(CommandFail.new("command failed", "", "boom"))
      expect(described_class.accel_help_ok?).to be(false)
    end

    it "is false when QEMU is not installed" do
      expect(described_class).to receive(:r).and_raise(Errno::ENOENT)
      expect(described_class.accel_help_ok?).to be(false)
    end
  end

  describe ".check_emulator!" do
    let(:hint) { "run scripts/byoh/bootstrap-data-plane.sh --emulated (or apt-get install qemu-system-x86 ovmf)" }

    it "passes when the packages, TCG and the firmware are all there" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(true)
      expect(File).to receive(:file?).with("/usr/share/ovmf/OVMF.fd").and_return(true)
      expect(described_class.check_emulator!).to be_nil
    end

    it "refuses missing packages without installing them" do
      expect(described_class).to receive(:missing_packages).and_return(["qemu-system-x86", "ovmf"])
      expect(described_class).not_to receive(:accel_help_ok?)
      expect { described_class.check_emulator! }.to raise_error(EmulatedHost::Unsupported, "missing packages: qemu-system-x86 ovmf; #{hint}")
    end

    it "refuses a QEMU without TCG" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(false)
      expect { described_class.check_emulator! }.to raise_error(EmulatedHost::Unsupported, "qemu-system-x86_64 -accel help does not list tcg; #{hint}")
    end

    it "refuses a missing firmware file" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(true)
      expect(File).to receive(:file?).with("/fw/OVMF.fd").and_return(false)
      expect { described_class.check_emulator!(firmware: "/fw/OVMF.fd") }.to raise_error(EmulatedHost::Unsupported, "/fw/OVMF.fd is missing; #{hint}")
    end
  end

  describe ".kvm_hint" do
    it "suggests cloud-hypervisor when KVM works" do
      expect(described_class.kvm_hint(kvm_problem: nil)).to eq("KVM is available; register without --accel tcg to use cloud-hypervisor")
    end

    it "says nothing when KVM is unavailable" do
      expect(described_class.kvm_hint(kvm_problem: "/dev/kvm is not a character device")).to be_nil
    end

    it "asks KvmCheck by default" do
      expect(KvmCheck).to receive(:problem).and_return(nil)
      expect(described_class.kvm_hint).to eq(EmulatedHost::KVM_AVAILABLE_HINT)
    end
  end
end
