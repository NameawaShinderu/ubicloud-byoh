# frozen_string_literal: true

require_relative "../lib/host_tier"

RSpec.describe HostTier do
  let(:x64) { ArchClass.new(:x64) }
  let(:arm64) { ArchClass.new(:arm64) }
  let(:dpkg_query) { ["dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", "qemu-system-x86", "ovmf"] }
  let(:accel_help) { ["qemu-system-x86_64", "-accel", "help"] }

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

    it "checks first, then runs the kvm steps without the KVM check and the cloud-hypervisor downloads for emulated" do
      expect(described_class.prep_steps("emulated")).to eq(%i[check_arch check_emulator kvm_hint] +
        described_class.prep_steps("kvm") - %i[kvm_check download_ch download_firmware])
    end

    it "refuses the tiers it cannot prepare yet" do
      %w[container pvm].each do |tier|
        expect { described_class.prep_steps(tier) }.to raise_error(HostTier::Unsupported, "#{tier} hosts are not supported by this rhizome yet (docs/byoh/NO_KVM.md section 11)")
      end
    end

    it "refuses an unknown tier" do
      expect { described_class.prep_steps("tcg") }.to raise_error(HostTier::Unsupported, 'unknown tier "tcg", expected one of kvm, container, pvm, emulated')
      expect { described_class.prep_steps(nil) }.to raise_error(HostTier::Unsupported, "unknown tier nil, expected one of kvm, container, pvm, emulated")
    end
  end

  describe ".check_arch!" do
    it "accepts x86_64" do
      expect(described_class.check_arch!(arch: x64)).to be_nil
    end

    it "refuses arm64" do
      expect { described_class.check_arch!(arch: arm64) }.to raise_error(HostTier::Unsupported, "emulated hosts must be x86_64; this host is arm64")
    end
  end

  describe ".missing_packages" do
    it "is empty when dpkg lists every package as installed" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 ii \novmf ii \n")
      expect(described_class.missing_packages).to eq([])
    end

    it "lists a package dpkg does not know" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 ii \n")
      expect(described_class.missing_packages).to eq(["ovmf"])
    end

    it "lists a package that was removed with its configuration kept" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 rc \novmf ii \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86"])
    end

    it "takes a package the operator holds" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 hi \novmf ui \n")
      expect(described_class.missing_packages).to eq([])
    end

    it "lists a package marked for removal or purge" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 ri \novmf pi \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end

    it "lists a package that is not fully installed or needs reinstalling" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 iU \novmf iiR\n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end

    it "reports a dpkg-query failure as unsupported" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_raise(CommandFail.new("command failed: dpkg-query", "", "dpkg: error: database is locked"))
      expect { described_class.missing_packages }.to raise_error(HostTier::Unsupported, /\Adpkg-query failed: command failed: dpkg-query\n.*database is locked; run scripts\/byoh\/bootstrap-data-plane.sh --tier emulated/m)
    end

    it "reports a missing dpkg-query as unsupported" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_raise(Errno::ENOENT, "dpkg-query")
      expect { described_class.missing_packages }.to raise_error(HostTier::Unsupported, "dpkg-query failed: No such file or directory - dpkg-query; #{HostTier::INSTALL_HINT}")
    end

    it "does not take a package whose name only starts with a wanted one" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("ovmf-ia32 ii \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end
  end

  describe ".accel_help_ok?" do
    it "is true when QEMU lists tcg" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_return("Accelerators supported in QEMU binary:\ntcg\nkvm\n")
      expect(described_class.accel_help_ok?).to be(true)
    end

    it "is false when QEMU does not list tcg" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_return("Accelerators supported in QEMU binary:\nkvm\n")
      expect(described_class.accel_help_ok?).to be(false)
    end

    it "is false when QEMU fails" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_raise(CommandFail.new("command failed", "", "boom"))
      expect(described_class.accel_help_ok?).to be(false)
    end

    it "is false when QEMU is not installed" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_raise(Errno::ENOENT)
      expect(described_class.accel_help_ok?).to be(false)
    end
  end

  describe ".check_emulator!" do
    let(:hint) { "run scripts/byoh/bootstrap-data-plane.sh --tier emulated (or apt-get install qemu-system-x86 ovmf)" }

    it "passes when the packages, TCG and the firmware are all there" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(true)
      expect(File).to receive(:file?).with("/usr/share/ovmf/OVMF.fd").and_return(true)
      expect(described_class.check_emulator!).to be_nil
    end

    it "refuses missing packages without installing them" do
      expect(described_class).to receive(:missing_packages).and_return(["qemu-system-x86", "ovmf"])
      expect(described_class).not_to receive(:accel_help_ok?)
      expect { described_class.check_emulator! }.to raise_error(HostTier::Unsupported, "missing packages: qemu-system-x86 ovmf; #{hint}")
    end

    it "refuses a QEMU without TCG" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(false)
      expect { described_class.check_emulator! }.to raise_error(HostTier::Unsupported, "qemu-system-x86_64 -accel help does not list tcg; #{hint}")
    end

    it "refuses a missing firmware file" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(true)
      expect(File).to receive(:file?).with("/fw/OVMF.fd").and_return(false)
      expect { described_class.check_emulator!(firmware: "/fw/OVMF.fd") }.to raise_error(HostTier::Unsupported, "/fw/OVMF.fd is missing; #{hint}")
    end
  end

  describe ".kvm_hint" do
    it "suggests cloud-hypervisor when KVM works" do
      expect(described_class.kvm_hint(kvm_problem: nil)).to eq("KVM is available; register the host again as kvm (bin/register-byoh-host --virt-tier kvm) to use cloud-hypervisor")
    end

    it "says nothing when KVM is unavailable" do
      expect(described_class.kvm_hint(kvm_problem: "/dev/kvm is not a character device")).to be_nil
    end

    it "asks KvmCheck by default" do
      expect(KvmCheck).to receive(:problem).and_return(nil)
      expect(described_class.kvm_hint).to eq(HostTier::KVM_AVAILABLE_HINT)
    end
  end
end
