# frozen_string_literal: true

require_relative "../lib/vm_setup"

# VMs on PVM hosts (docs/byoh/NO_KVM.md section 6.7): their parameters
# and the host checks that run before any of them starts. The units are
# frozen in vm_setup_golden_spec.rb.
RSpec.describe VmSetup do
  let(:sha) { "ab" * 32 }
  let(:pvm) { {"kernel_sha256" => sha, "root" => "/dev/vda1"} }
  let(:dir) { "/opt/pvm-guest/#{sha}" }
  let(:vs) { described_class.new("test", hugepages: false, ch_version: "46.0", pvm: pvm) }
  let(:kvm_stat) { instance_double(File::Stat, chardev?: true, mode: 0o20660, gid: 108) }

  before do
    stub_const("CloudHypervisor::Version::INSTALLED", {
      "35.1" => CloudHypervisor::Version.new("35.1", "a", "b"),
      "46.0" => CloudHypervisor::Version.new("46.0", "a", "b"),
    })
    stub_const("CloudHypervisor::Firmware::INSTALLED", {})
  end

  describe "the parameters" do
    it "reads pvm from prep.json" do
      vm_setup = described_class.from_params("test", {"hugepages" => false, "pvm" => pvm})
      expect(vm_setup.pvm?).to be true
      expect(vm_setup.pvm_vmlinux).to eq "#{dir}/vmlinux"
      expect(described_class.from_params("test", {}).pvm?).to be false
    end

    it "refuses what a PVM VM cannot have" do
      expect { described_class.new("test", hypervisor: "qemu", hugepages: false, pvm: pvm) }.to raise_error("pvm VMs need hypervisor ch, not qemu")
      expect { described_class.new("test", pvm: pvm) }.to raise_error("pvm VMs run without hugepages")
      expect { described_class.new("test", hugepages: false, pvm: pvm.merge("kernel_sha256" => "AB" * 32)) }
        .to raise_error("pvm needs kernel_sha256 as 64 lowercase hex digits")
      expect { described_class.new("test", hugepages: false, pvm: pvm.except("kernel_sha256")) }
        .to raise_error("pvm needs kernel_sha256 as 64 lowercase hex digits")
      expect { described_class.new("test", hugepages: false, pvm: pvm.merge("root" => "/dev/vda1 init=/bin/sh")) }
        .to raise_error('pvm needs root as a virtio-blk device such as /dev/vda1, not "/dev/vda1 init=/bin/sh"')
      expect { described_class.new("test", hugepages: false, pvm: pvm.except("root")) }
        .to raise_error("pvm needs root as a virtio-blk device such as /dev/vda1, not nil")
    end
  end

  describe "#pvm_console" do
    it "reads the console of the downloaded guest kernel, once" do
      expect(File).to receive(:read).with("#{dir}/meta.json").once.and_return(JSON.generate("sha256" => sha, "console" => "hvc0"))
      expect(vs.pvm_console).to eq "hvc0"
      expect(vs.pvm_console).to eq "hvc0"
    end

    it "refuses a kernel that is not downloaded" do
      expect(File).to receive(:read).with("#{dir}/meta.json").and_raise(Errno::ENOENT)
      expect { vs.pvm_console }.to raise_error("the PVM guest kernel #{sha} is not downloaded on this host (#{dir}/meta.json); run download-pvm-guest-kernel")
    end

    it "refuses a meta.json that is not JSON" do
      expect(File).to receive(:read).with("#{dir}/meta.json").and_return("{")
      expect { vs.pvm_console }.to raise_error(/is not downloaded on this host/)
    end

    it "refuses a meta.json of another kernel" do
      expect(File).to receive(:read).with("#{dir}/meta.json").and_return(JSON.generate("sha256" => "cd" * 32, "console" => "hvc0"))
      expect { vs.pvm_console }.to raise_error("#{dir}/meta.json is for another kernel")
    end

    it "refuses a meta.json that is not an object" do
      expect(File).to receive(:read).with("#{dir}/meta.json").and_return("[]")
      expect { vs.pvm_console }.to raise_error("#{dir}/meta.json is for another kernel")
    end

    it "refuses an unknown console" do
      expect(File).to receive(:read).with("#{dir}/meta.json").and_return(JSON.generate("sha256" => sha, "console" => "ttyAMA0"))
      expect { vs.pvm_console }.to raise_error("#{dir}/meta.json has an unknown console \"ttyAMA0\"")
    end
  end

  describe "#check_pvm_host" do
    before do
      allow(File).to receive(:file?).with("#{dir}/vmlinux").and_return(true)
      allow(vs).to receive(:pvm_console).and_return("hvc0")
      allow(File).to receive(:read).with(described_class::MELTDOWN).and_return("Not affected\n")
      allow(File).to receive(:read).with(described_class::CMDLINE).and_return("BOOT_IMAGE=/vmlinuz-6.12.33-pvm root=UUID=x ro pti=off\n")
      allow(File).to receive(:stat).with("/dev/kvm").and_return(kvm_stat)
      allow(Etc).to receive(:getgrgid).with(108).and_return(Struct.new(:name).new("kvm"))
    end

    it "passes on a PVM kernel with pti=off, a CPU Meltdown does not affect and the kvm group's /dev/kvm" do
      expect(vs.check_pvm_host).to be_nil
    end

    it "refuses cloud-hypervisor older than 46.0" do
      old = described_class.new("test", hugepages: false, ch_version: "35.1", pvm: pvm)
      expect { old.check_pvm_host }.to raise_error("pvm VMs need cloud-hypervisor 46.0 or later, not 35.1")
    end

    it "refuses a missing guest kernel" do
      expect(File).to receive(:file?).with("#{dir}/vmlinux").and_return(false)
      expect { vs.check_pvm_host }.to raise_error("the PVM guest kernel #{dir}/vmlinux is missing")
    end

    it "refuses a CPU Meltdown affects" do
      expect(File).to receive(:read).with(described_class::MELTDOWN).and_return("Vulnerable\n")
      expect { vs.check_pvm_host }.to raise_error(%(refusing to start a pvm VM: #{described_class::MELTDOWN} says "Vulnerable", not "Not affected"))
    end

    it "refuses a kernel without the Meltdown report" do
      expect(File).to receive(:read).with(described_class::MELTDOWN).and_raise(Errno::ENOENT)
      expect { vs.check_pvm_host }.to raise_error(%(refusing to start a pvm VM: #{described_class::MELTDOWN} says "unknown (no #{described_class::MELTDOWN})", not "Not affected"))
    end

    it "refuses a kernel booted without pti=off" do
      expect(File).to receive(:read).with(described_class::CMDLINE).and_return("BOOT_IMAGE=/vmlinuz-7.0.0-1014-aws root=UUID=x ro xpti=off\n")
      expect { vs.check_pvm_host }.to raise_error("refusing to start a pvm VM: the host kernel did not boot with pti=off (/proc/cmdline); it is not the PVM kernel")
    end

    it "refuses a host without /dev/kvm" do
      expect(File).to receive(:stat).with("/dev/kvm").and_raise(Errno::ENOENT)
      expect { vs.check_pvm_host }.to raise_error("refusing to start a pvm VM: /dev/kvm is missing; is kvm_pvm loaded?")
    end

    it "refuses a /dev/kvm others can open" do
      expect(kvm_stat).to receive(:mode).at_least(:once).and_return(0o20666)
      expect { vs.check_pvm_host }.to raise_error("refusing to start a pvm VM: /dev/kvm must be a character device of mode 0660 and group kvm, not 0666 group kvm")
    end

    it "refuses a /dev/kvm that is not a character device" do
      expect(kvm_stat).to receive(:chardev?).and_return(false)
      expect { vs.check_pvm_host }.to raise_error(/must be a character device of mode 0660 and group kvm, not 0660 group kvm/)
    end

    it "refuses a /dev/kvm of another group, named or not" do
      expect(Etc).to receive(:getgrgid).with(108).and_return(Struct.new(:name).new("root"))
      expect { vs.check_pvm_host }.to raise_error(/not 0660 group root\z/)
      expect(Etc).to receive(:getgrgid).with(108).and_raise(ArgumentError)
      expect { vs.check_pvm_host }.to raise_error(/not 0660 group 108\z/)
    end
  end

  describe "the actions" do
    it "checks the host instead of the firmware before any host change" do
      expect(vs).to receive(:check_pvm_host).and_raise("refusing")
      expect(vs).not_to receive(:cloudinit)
      expect {
        vs.prep("ubi", [], [], "fddf::/79", "", "10.0.0.0/31", 2, "1:1:1:2", 2, false, [], {}, nil, [], "ubuntu-noble", "10.0.0.2", "system.slice", 0, 0, nil, false, nil)
      }.to raise_error("refusing")
    end

    it "checks the host on restart" do
      expect(vs).to receive(:check_pvm_host).and_raise("refusing")
      expect(vs).not_to receive(:restart_systemd_unit)
      expect { vs.restart("system.slice", 0) }.to raise_error("refusing")
    end

    it "checks the host before starting the unit" do
      expect(vs).to receive(:check_pvm_host)
      expect(vs).to receive(:_run_command).with("systemctl", "start", "test")
      vs.start_systemd_unit
    end

    it "does not start the unit on a host that fails the checks" do
      expect(vs).to receive(:check_pvm_host).and_raise("refusing")
      expect(vs).not_to receive(:_run_command)
      expect { vs.start_systemd_unit }.to raise_error("refusing")
    end
  end
end
