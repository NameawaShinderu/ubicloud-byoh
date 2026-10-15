# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require_relative "../lib/virt_probe"

RSpec.describe VirtProbe do
  let(:uname) { {machine: "x86_64", release: "6.8.0-1-generic"} }

  # Facts for a machine, as .facts would gather them.
  def facts(**over)
    {
      "arch" => "x86_64",
      "kernel" => "6.8.0-1-generic",
      "cpu_vendor" => "GenuineIntel",
      "cpu_model" => "Intel Xeon",
      "cpu_flags" => %w[vmx pdpe1gb],
      "dev_kvm" => true,
      "kvm_api" => 12,
      "modules" => %w[kvm kvm_intel],
      "nested_param" => true,
      "pvm_module_available" => false,
      "virt_vm" => "none",
      "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Dell Inc.", "product_name" => "PowerEdge R650"},
    }.merge(over.transform_keys(&:to_s))
  end

  describe ".facts" do
    def write(root, path, content)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end

    it "reads a machine with KVM from its root" do
      Dir.mktmpdir do |root|
        write(root, "proc/cpuinfo", "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel Xeon\nflags\t\t: fpu vmx lm pdpe1gb hypervisor\n\nprocessor\t: 1\nflags\t\t: fpu\n")
        FileUtils.mkdir_p(File.join(root, "sys/module/kvm"))
        write(root, "sys/module/kvm_intel/parameters/nested", "Y\n")
        write(root, "lib/modules/6.8.0-1-generic/modules.dep", "kernel/arch/x86/kvm/kvm-pvm.ko: kernel/arch/x86/kvm/kvm.ko\n")
        write(root, "sys/class/dmi/id/sys_vendor", "QEMU\n")
        expect(File).to receive(:chardev?).with(File.join(root, "dev/kvm")).and_return(true)
        expect(described_class).to receive(:kvm_api_version).with(File.join(root, "dev/kvm")).and_return(12)
        expect(described_class).to receive(:detect_virt).with("--vm").and_return("kvm")
        expect(described_class).to receive(:detect_virt).with("--container").and_return("none")

        expect(described_class.facts(root: root, uname: uname)).to eq(
          "arch" => "x86_64",
          "kernel" => "6.8.0-1-generic",
          "cpu_vendor" => "GenuineIntel",
          "cpu_model" => "Intel Xeon",
          "cpu_flags" => %w[vmx hypervisor pdpe1gb],
          "dev_kvm" => true,
          "kvm_api" => 12,
          "modules" => %w[kvm kvm_intel],
          "nested_param" => true,
          "pvm_module_available" => true,
          "virt_vm" => "kvm",
          "virt_container" => "none",
          "dmi" => {
            "sys_vendor" => "QEMU",
            "product_name" => nil,
            "product_version" => nil,
            "bios_vendor" => nil,
            "board_vendor" => nil,
            "chassis_vendor" => nil,
            "chassis_asset_tag" => nil,
          },
        )
      end
    end

    it "reads an empty root as a machine without anything" do
      Dir.mktmpdir do |root|
        expect(described_class).to receive(:detect_virt).twice.and_return(nil)
        f = described_class.facts(root: root, uname: {machine: "aarch64", release: "6.8.0"})
        expect(f.slice("arch", "cpu_vendor", "cpu_flags", "dev_kvm", "kvm_api", "modules", "nested_param", "pvm_module_available")).to eq(
          "arch" => "aarch64",
          "cpu_vendor" => nil,
          "cpu_flags" => [],
          "dev_kvm" => false,
          "kvm_api" => nil,
          "modules" => [],
          "nested_param" => nil,
          "pvm_module_available" => false,
        )
      end
    end

    it "does not take a module whose name only ends in kvm-pvm" do
      Dir.mktmpdir do |root|
        write(root, "lib/modules/6.8.0-1-generic/modules.dep", "extra/not-kvm-pvm.ko:\n")
        expect(described_class).to receive(:detect_virt).twice.and_return(nil)
        expect(described_class.facts(root: root, uname: uname)["pvm_module_available"]).to be(false)
      end
    end
  end

  describe ".container_marker" do
    it "names docker" do
      Dir.mktmpdir do |root|
        FileUtils.touch(File.join(root, ".dockerenv"))
        expect(described_class.container_marker(root)).to eq("docker")
      end
    end

    it "names podman" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "run"))
        FileUtils.touch(File.join(root, "run/.containerenv"))
        expect(described_class.container_marker(root)).to eq("podman")
      end
    end

    it "reads the container variable of PID 1" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "proc/1"))
        File.write(File.join(root, "proc/1/environ"), "PATH=/bin\0container=lxc\0TERM=xterm\0")
        expect(described_class.container_marker(root)).to eq("lxc")
      end
    end

    it "is nil without a marker" do
      Dir.mktmpdir do |root|
        expect(described_class.container_marker(root)).to be_nil
      end
    end
  end

  describe ".nested_param" do
    it "reads kvm_amd's 1 as true" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "sys/module/kvm_amd/parameters"))
        File.write(File.join(root, "sys/module/kvm_amd/parameters/nested"), "1\n")
        expect(described_class.nested_param(root)).to be(true)
      end
    end

    it "reads N as false" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "sys/module/kvm_intel/parameters"))
        File.write(File.join(root, "sys/module/kvm_intel/parameters/nested"), "N\n")
        expect(described_class.nested_param(root)).to be(false)
      end
    end
  end

  describe ".kvm_api_version" do
    it "reports why a node that is not KVM does not answer" do
      Dir.mktmpdir do |root|
        path = File.join(root, "kvm")
        File.write(path, "")
        expect(described_class.kvm_api_version(path)).to start_with("Not a tty")
      end
    end

    it "reports a node it cannot open" do
      expect(described_class.kvm_api_version("/nonexistent/kvm")).to start_with("No such file or directory")
    end
  end

  describe ".detect_virt" do
    it "returns what systemd-detect-virt prints" do
      expect(Open3).to receive(:capture2).with("systemd-detect-virt", "--vm", stdin_data: "").and_return(["kvm\n", nil])
      expect(described_class.detect_virt("--vm")).to eq("kvm")
    end

    it "returns nil when it prints nothing" do
      expect(Open3).to receive(:capture2).and_return(["\n", nil])
      expect(described_class.detect_virt("--vm")).to be_nil
    end

    it "returns nil when it is not installed" do
      expect(Open3).to receive(:capture2).and_raise(Errno::ENOENT)
      expect(described_class.detect_virt("--container")).to be_nil
    end
  end

  describe ".classify" do
    it "takes a bare-metal host with KVM" do
      expect(described_class.classify(facts)).to eq(["kvm", ["/dev/kvm answers KVM_GET_API_VERSION 12"]])
    end

    it "refuses a container even with /dev/kvm" do
      expect(described_class.classify(facts(virt_container: "lxc"))).to eq(["container", ["this is a lxc container"]])
    end

    it "takes a container nil as unknown, not a container" do
      expect(described_class.classify(facts(virt_container: nil)).first).to eq("kvm")
    end

    it "blocks a /dev/kvm that does not answer" do
      expect(described_class.classify(facts(kvm_api: "Permission denied"))).to eq(["kvm_blocked", ["/dev/kvm exists but does not answer KVM_GET_API_VERSION (Permission denied)"]])
    end

    it "takes /dev/kvm from kvm_pvm alone as pvm" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], modules: %w[kvm kvm_pvm], virt_vm: "amazon")).first).to eq("pvm")
    end

    it "takes kvm_pvm beside a hardware module as kvm" do
      expect(described_class.classify(facts(modules: %w[kvm kvm_intel kvm_pvm])).first).to eq("kvm")
    end

    it "blocks vmx without kvm_intel" do
      expect(described_class.classify(facts(dev_kvm: false, kvm_api: nil, modules: []))).to eq(["kvm_blocked", ["the CPU has vmx but kvm_intel is not loaded"]])
    end

    it "blocks svm with kvm_amd loaded but no /dev/kvm" do
      expect(described_class.classify(facts(cpu_flags: %w[svm], dev_kvm: false, modules: %w[kvm kvm_amd]))).to eq(["kvm_blocked", ["kvm_amd is loaded but there is no /dev/kvm"]])
    end

    it "blocks x86 bare metal without vmx or svm as a firmware setting" do
      expect(described_class.classify(facts(cpu_flags: [], dev_kvm: false, modules: []))).to eq(["kvm_blocked", ["bare metal without the vmx or svm flag: the firmware has VT-x/AMD-V disabled"]])
    end

    it "blocks arm64 bare metal without /dev/kvm" do
      expect(described_class.classify(facts(arch: "aarch64", cpu_flags: [], dev_kvm: false, modules: [])).last.first).to start_with("bare metal without /dev/kvm")
    end

    it "takes a VM with the hypervisor flag as not bare metal" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], dev_kvm: false, modules: [], virt_vm: nil))).to eq(["none", ["no /dev/kvm and no hardware virtualization flags"]])
    end

    it "blocks a VM whose kernel ships kvm_pvm" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], dev_kvm: false, modules: [], virt_vm: "kvm", pvm_module_available: true)).first).to eq("pvm_blocked")
    end

    it "names the hypervisor of a VM without hardware virtualization" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], dev_kvm: false, modules: [], virt_vm: "xen"))).to eq(["none", ["this is a xen VM whose hypervisor does not expose hardware virtualization"]])
    end
  end

  describe ".report" do
    it "marks KVM inside a VM as nested" do
      expect(described_class.report(facts(cpu_flags: %w[vmx hypervisor], virt_vm: nil))).to include("version" => 1, "tier" => "kvm", "nested" => true)
    end

    it "marks KVM under a hypervisor systemd names as nested" do
      expect(described_class.report(facts(virt_vm: "kvm"))["nested"]).to be(true)
    end

    it "does not mark bare metal as nested" do
      expect(described_class.report(facts)["nested"]).to be(false)
    end

    it "does not mark a tier other than kvm as nested" do
      expect(described_class.report(facts(cpu_flags: %w[hypervisor], dev_kvm: false, virt_vm: "kvm"))["nested"]).to be(false)
    end
  end

  describe ".main" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    before do
      allow(described_class).to receive(:facts).with(root: "/").and_return(facts(cpu_flags: %w[vmx hypervisor]))
    end

    it "prints the report as JSON" do
      expect(described_class.main(["--json"], out: out, err: err)).to eq(0)
      expect(JSON.parse(out.string)).to include("tier" => "kvm", "nested" => true, "facts" => include("arch" => "x86_64"))
    end

    it "prints the report as text" do
      expect(described_class.main([], out: out, err: err)).to eq(0)
      expect(out.string).to eq(<<~TEXT)
        tier: kvm (nested: this machine is itself a VM)
        why: /dev/kvm answers KVM_GET_API_VERSION 12
        cpu: x86_64 Intel Xeon flags=vmx,hypervisor
        kvm: /dev/kvm=true modules=kvm,kvm_intel nested_param=true
        virt: vm="none" container="none" dmi=Dell Inc. / PowerEdge R650
        For the fix on this platform run bin/byoh-virt probe --main-ip <this host> on the control plane; see docs/byoh/NO_KVM.md.
      TEXT
    end

    it "prints unknown DMI and no nested note" do
      allow(described_class).to receive(:facts).with(root: "/x").and_return(facts(dmi: {}))
      expect(described_class.main(["--root", "/x"], out: out, err: err)).to eq(0)
      expect(out.string).to start_with("tier: kvm\n").and include("dmi=unknown")
    end

    it "refuses an unknown argument" do
      expect(described_class.main(["--yes"], out: out, err: err)).to eq(2)
      expect(err.string).to eq("usage: virt-probe [--json] [--root DIR]\n")
    end

    it "refuses --root without a directory" do
      expect(described_class.main(["--root"], out: out, err: err)).to eq(2)
    end
  end
end
