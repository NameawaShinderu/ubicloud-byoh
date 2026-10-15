# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require_relative "../lib/virt_probe"
require_relative "virt_probe_fixtures"

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
      "kvm_errno" => nil,
      "kvm_create_vm" => true,
      "kvm_caps_missing" => [],
      "modules" => %w[kvm kvm_intel],
      "nested_param" => true,
      "pvm_module_available" => false,
      "bios_log" => nil,
      "virt_vm" => "none",
      "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Dell Inc.", "product_name" => "PowerEdge R650"},
      "cgroup2" => true,
      "commands" => {"lxc-start" => false, "lxcfs" => false, "qemu-system-x86_64" => false},
      "ovmf" => false,
    }.merge(over.transform_keys(&:to_s))
  end

  def write(root, path, content)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), content)
  end

  describe "fixture machines" do
    VirtProbeFixtures.all.each do |name, fixture|
      it "classifies #{name}" do
        Dir.mktmpdir do |root|
          report = described_class.report(described_class.facts(root: VirtProbeFixtures.materialize(fixture, root)))
          expect = fixture["expect"]
          expect(report.values_at("tier", "cause", "nested", "ready")).to eq expect.values_at("tier", "cause", "nested", "ready")
        end
      end
    end

    it "covers every tier" do
      expect(VirtProbeFixtures.all.values.map { |f| f["expect"]["tier"] }.uniq).to match_array(described_class::TIERS)
    end
  end

  describe ".facts" do
    it "reads this machine when the root is /" do
      expect(described_class).to receive(:read).at_least(:once).and_return(nil)
      expect(File).to receive(:chardev?).with("/dev/kvm").and_return(false)
      expect(described_class).to receive(:detect_virt).with("--vm").and_return("kvm")
      expect(described_class).to receive(:detect_virt).with("--container").and_return(nil)
      expect(described_class).to receive(:kernel_log).and_return(nil)
      expect(described_class).to receive(:container_marker).with("/").and_return(nil)
      f = described_class.facts(uname: uname)
      expect(f.slice("arch", "kernel", "virt_vm", "virt_container", "dev_kvm", "cpu_flags")).to eq(
        "arch" => "x86_64", "kernel" => "6.8.0-1-generic", "virt_vm" => "kvm", "virt_container" => nil,
        "dev_kvm" => false, "cpu_flags" => [],
      )
      # An unreadable kernel log leaves the BIOS evidence unknown, not clean.
      expect(f).not_to have_key("bios_log")
      expect(f["euid"]).to eq Process.euid
    end

    it "reads a fixture tree in full" do
      Dir.mktmpdir do |root|
        write(root, ".virt-probe/uname", "x86_64 6.8.0-1-generic\n")
        write(root, ".virt-probe/detect-virt-vm", "kvm\n")
        write(root, ".virt-probe/detect-virt-container", "none\n")
        write(root, ".virt-probe/kernel-log", "booting\n")
        write(root, ".virt-probe/kvm.json", JSON.generate("dev_kvm" => true, "kvm_api" => 12, "kvm_create_vm" => true, "kvm_caps_missing" => []))
        write(root, "proc/cpuinfo", "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel Xeon\nflags\t\t: fpu vmx lm pdpe1gb hypervisor\n\nprocessor\t: 1\nflags\t\t: fpu\n")
        write(root, "proc/mounts", "/dev/vda1 / ext4 rw 0 0\n/dev/vdb /var/storage xfs rw,prjquota 0 0\n")
        write(root, "proc/sys/kernel/apparmor_restrict_unprivileged_userns", "1\n")
        FileUtils.mkdir_p(File.join(root, "sys/module/kvm"))
        write(root, "sys/module/kvm_intel/parameters/nested", "Y\n")
        write(root, "sys/module/apparmor/parameters/enabled", "Y\n")
        write(root, "sys/fs/cgroup/cgroup.controllers", "cpu\n")
        write(root, "sys/kernel/security/lockdown", "[none] integrity confidentiality\n")
        write(root, "sys/devices/system/cpu/vulnerabilities/meltdown", "Not affected\n")
        write(root, "sys/devices/system/cpu/smt/control", "on\n")
        write(root, "sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c", "\x06\x00\x00\x00\x01")
        write(root, "var/run/reboot-required", "")
        write(root, "lib/modules/6.8.0-1-generic/modules.dep", "kernel/arch/x86/kvm/kvm-pvm.ko: kernel/arch/x86/kvm/kvm.ko\n")
        write(root, "sys/class/dmi/id/sys_vendor", "QEMU\n")
        write(root, "usr/share/OVMF/OVMF_CODE_4M.fd", "")
        write(root, "usr/bin/qemu-system-x86_64", "")
        File.chmod(0o755, File.join(root, "usr/bin/qemu-system-x86_64"))
        expect(described_class).not_to receive(:detect_virt)
        expect(described_class).not_to receive(:kernel_log)

        expect(described_class.facts(root: root)).to eq(
          "arch" => "x86_64",
          "kernel" => "6.8.0-1-generic",
          "euid" => Process.euid,
          "cpu_vendor" => "GenuineIntel",
          "cpu_model" => "Intel Xeon",
          "cpu_flags" => %w[vmx hypervisor pdpe1gb],
          "tdp" => nil,
          "dev_kvm" => true,
          "kvm_dev_mode" => nil,
          "kvm_dev_group" => nil,
          "kvm_api" => 12,
          "kvm_errno" => nil,
          "kvm_create_vm" => true,
          "kvm_caps_missing" => [],
          "modules" => %w[kvm kvm_intel],
          "nested_param" => true,
          "pvm_module_available" => true,
          "bios_log" => nil,
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
          "secure_boot" => true,
          "lockdown" => "none",
          "vulnerabilities" => {"meltdown" => "Not affected", "l1tf" => nil, "mds" => nil, "retbleed" => nil, "spec_rstack_overflow" => nil},
          "smt" => "on",
          "reboot_required" => true,
          "cgroup2" => true,
          "apparmor" => true,
          "userns_restricted" => true,
          "prjquota" => true,
          "commands" => {"lxc-start" => false, "lxcfs" => false, "qemu-system-x86_64" => true},
          "ovmf" => true,
        )
      end
    end

    it "reads an empty tree as a machine without anything" do
      Dir.mktmpdir do |root|
        f = described_class.facts(root: root, uname: {machine: "aarch64", release: "6.8.0"})
        expect(f.slice("arch", "cpu_vendor", "cpu_flags", "dev_kvm", "kvm_api", "modules", "nested_param", "pvm_module_available", "virt_vm", "virt_container", "secure_boot", "lockdown", "prjquota", "cgroup2", "apparmor")).to eq(
          "arch" => "aarch64",
          "cpu_vendor" => nil,
          "cpu_flags" => [],
          "dev_kvm" => false,
          "kvm_api" => nil,
          "modules" => [],
          "nested_param" => nil,
          "pvm_module_available" => false,
          "virt_vm" => nil,
          "virt_container" => nil,
          "secure_boot" => nil,
          "lockdown" => nil,
          "prjquota" => nil,
          "cgroup2" => false,
          "apparmor" => false,
        )
      end
    end

    it "does not take a module whose name only ends in kvm-pvm" do
      Dir.mktmpdir do |root|
        write(root, "lib/modules/6.8.0-1-generic/modules.dep", "extra/not-kvm-pvm.ko:\n")
        expect(described_class.facts(root: root, uname: uname)["pvm_module_available"]).to be(false)
      end
    end

    it "never reads serial numbers or the machine UUID" do
      expect(described_class::DMI_FIELDS.grep(/serial|uuid/)).to eq []
    end
  end

  describe ".root_uname" do
    it "is this machine's for / and for a tree without one" do
      expect(described_class.root_uname("/")).to eq Etc.uname
      Dir.mktmpdir { |dir| expect(described_class.root_uname(dir)).to eq Etc.uname }
    end
  end

  describe ".kvm_facts" do
    it "is empty without a character device" do
      expect(File).to receive(:chardev?).with("/dev/kvm").and_return(false)
      expect(described_class.kvm_facts("/")).to eq described_class.empty_kvm_facts
    end

    it "is empty for a tree without kvm.json" do
      Dir.mktmpdir { |dir| expect(described_class.kvm_facts(dir)).to eq described_class.empty_kvm_facts }
    end

    it "records the mode and group of /dev/kvm" do
      expect(File).to receive(:chardev?).with("/dev/kvm").and_return(true)
      expect(File).to receive(:stat).with("/dev/kvm").and_return(instance_double(File::Stat, mode: 0o20660, gid: 0))
      expect(Etc).to receive(:getgrgid).with(0).and_return(Etc::Group.new("kvm"))
      expect(described_class).to receive(:kvm_check).with("/dev/kvm").and_return("kvm_api" => 12)
      expect(described_class.kvm_facts("/")).to eq("dev_kvm" => true, "kvm_dev_mode" => "0660", "kvm_dev_group" => "kvm", "kvm_api" => 12)
    end

    it "records a group without a name by number" do
      expect(File).to receive(:chardev?).and_return(true)
      expect(File).to receive(:stat).and_return(instance_double(File::Stat, mode: 0o20600, gid: 4242))
      expect(Etc).to receive(:getgrgid).with(4242).and_raise(ArgumentError)
      expect(described_class).to receive(:kvm_check).and_return({})
      expect(described_class.kvm_facts("/")).to include("kvm_dev_mode" => "0600", "kvm_dev_group" => "4242")
    end
  end

  describe ".kvm_check" do
    let(:kvm) { instance_double(File) }

    def open_kvm
      expect(File).to receive(:open).with("/dev/kvm", "r+").and_yield(kvm)
    end

    it "asks for the API, a VM and every capability cloud-hypervisor needs" do
      open_kvm
      expect(kvm).to receive(:ioctl).with(described_class::KVM_GET_API_VERSION).and_return(12)
      expect(kvm).to receive(:ioctl).with(described_class::KVM_CREATE_VM, 0).and_return(9)
      vm = instance_double(IO)
      expect(IO).to receive(:for_fd).with(9, autoclose: true).and_return(vm)
      expect(vm).to receive(:close)
      described_class::REQUIRED_CAPS_X86.each do |name, cap|
        expect(kvm).to receive(:ioctl).with(described_class::KVM_CHECK_EXTENSION, cap).and_return((name == "SplitIrqchip") ? 0 : 1)
      end
      expect(described_class.kvm_check("/dev/kvm")).to eq("kvm_api" => 12, "kvm_errno" => nil, "kvm_create_vm" => true, "kvm_caps_missing" => ["SplitIrqchip"])
    end

    it "stops at an unexpected API version" do
      open_kvm
      expect(kvm).to receive(:ioctl).with(described_class::KVM_GET_API_VERSION).and_return(11)
      expect(described_class.kvm_check("/dev/kvm")).to eq("kvm_api" => 11, "kvm_errno" => nil, "kvm_create_vm" => nil, "kvm_caps_missing" => nil)
    end

    it "records a refused VM" do
      open_kvm
      expect(kvm).to receive(:ioctl).with(described_class::KVM_GET_API_VERSION).and_return(12)
      expect(kvm).to receive(:ioctl).with(described_class::KVM_CREATE_VM, 0).and_raise(Errno::ENOMEM)
      expect(described_class.kvm_check("/dev/kvm")).to eq("kvm_api" => 12, "kvm_errno" => "ENOMEM", "kvm_create_vm" => Errno::ENOMEM.new.message, "kvm_caps_missing" => nil)
    end

    it "leaves the capabilities unknown when asking fails" do
      open_kvm
      expect(kvm).to receive(:ioctl).with(described_class::KVM_GET_API_VERSION).and_return(12)
      expect(kvm).to receive(:ioctl).with(described_class::KVM_CREATE_VM, 0).and_return(9)
      expect(IO).to receive(:for_fd).and_return(instance_double(IO, close: nil))
      expect(kvm).to receive(:ioctl).with(described_class::KVM_CHECK_EXTENSION, 39).and_raise(Errno::EINVAL)
      expect(described_class.kvm_check("/dev/kvm")).to eq("kvm_api" => 12, "kvm_errno" => "EINVAL", "kvm_create_vm" => true, "kvm_caps_missing" => nil)
    end

    it "records why /dev/kvm did not open" do
      expect(described_class.kvm_check("/nonexistent/kvm")).to include("kvm_api" => start_with("No such file or directory"), "kvm_errno" => "ENOENT")
    end

    it "records a node that is not KVM" do
      Dir.mktmpdir do |root|
        path = File.join(root, "kvm")
        File.write(path, "")
        expect(described_class.kvm_check(path)).to include("kvm_api" => match(/tty|ioctl/i), "kvm_errno" => "ENOTTY")
      end
    end
  end

  describe ".tdp" do
    it "reads kvm_intel's ept and kvm_amd's npt" do
      Dir.mktmpdir do |root|
        write(root, "sys/module/kvm_amd/parameters/npt", "0\n")
        expect(described_class.tdp(root, "")).to be(false)
        write(root, "sys/module/kvm_intel/parameters/ept", "Y\n")
        expect(described_class.tdp(root, "")).to be(true)
      end
    end

    it "falls back to the vmx flags, and nil" do
      Dir.mktmpdir do |root|
        expect(described_class.tdp(root, "vmx flags\t: vnmi ept vpid\n")).to be(true)
        expect(described_class.tdp(root, "vmx flags\t: vnmi\n")).to be(false)
        expect(described_class.tdp(root, "flags\t: fpu\n")).to be_nil
      end
    end
  end

  describe ".bios_line" do
    it "finds the firmware line of every kernel that prints one" do
      expect(described_class.bios_line("x\nkvm: disabled by bios\ny\n")).to eq "kvm: disabled by bios"
      [
        "x86/cpu: VMX (outside TXT) disabled by BIOS",
        "x86/cpu: VMX (inside TXT) disabled by BIOS",
        "kvm_intel: VMX not enabled (disabled by BIOS) in MSR_IA32_FEAT_CTL on CPU 0",
        "kvm_amd: SVM disabled (by BIOS) in MSR_VM_CR on CPU 0",
        "kvm_intel: disabled by bios",
      ].each { |line| expect(described_class.bios_line("#{line}\n")).to eq line }
    end

    it "is nil without the line, and ignores other features the firmware disabled" do
      expect(described_class.bios_line("nothing\n")).to be_nil
      expect(described_class.bios_line("x86/cpu: SGX disabled by BIOS.\nsome_driver: feature disabled (by BIOS)\n")).to be_nil
    end
  end

  it "takes an SGX firmware line on an Intel host without kvm_intel as the module, not the firmware" do
    Dir.mktmpdir do |root|
      fixture = VirtProbeFixtures.all.fetch("intel_module_not_loaded")
      VirtProbeFixtures.materialize(fixture, root)
      write(root, ".virt-probe/kernel-log", "x86/cpu: SGX disabled by BIOS.\n")
      f = described_class.facts(root: root)
      expect(f["bios_log"]).to be_nil
      expect(described_class.classify(f).last).to eq "module"
    end
  end

  describe ".kernel_log" do
    let(:ok) { instance_double(Process::Status, success?: true) }
    let(:failed) { instance_double(Process::Status, success?: false) }

    it "reads journald" do
      expect(Open3).to receive(:capture2).with("journalctl", "-k", "-b", "-q", "--no-pager", "-o", "cat", stdin_data: "", err: File::NULL).and_return(["log\n", ok])
      expect(described_class.kernel_log).to eq "log\n"
    end

    it "falls back to dmesg" do
      expect(Open3).to receive(:capture2).with("journalctl", any_args).and_return(["", ok])
      expect(Open3).to receive(:capture2).with("dmesg", stdin_data: "", err: File::NULL).and_return(["dmesg\n", ok])
      expect(described_class.kernel_log).to eq "dmesg\n"
    end

    it "is nil when neither can be read" do
      expect(Open3).to receive(:capture2).with("journalctl", any_args).and_raise(Errno::ENOENT)
      expect(Open3).to receive(:capture2).with("dmesg", any_args).and_return(["", failed])
      expect(described_class.kernel_log).to be_nil
    end
  end

  describe ".secure_boot" do
    it "reads the last byte of the variable" do
      Dir.mktmpdir do |root|
        write(root, "sys/firmware/efi/efivars/SecureBoot-x", "\x06\x00\x00\x00\x00")
        expect(described_class.secure_boot(root)).to be(false)
      end
    end

    it "is nil when the variable cannot be read" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "sys/firmware/efi/efivars/SecureBoot-x"))
        expect(described_class.secure_boot(root)).to be_nil
      end
    end
  end

  describe ".prjquota" do
    it "takes the mount of / when nothing is mounted on /var/storage, and skips short lines" do
      Dir.mktmpdir do |root|
        write(root, "proc/mounts", "junk\n/dev/sda1 / ext4 rw,prjquota 0 0\n/dev/sdb /data xfs rw 0 0\n/dev/sdc /vm xfs rw 0 0\n")
        expect(described_class.prjquota(root)).to be(true)
      end
    end

    it "takes the longest mount holding /var/storage, where VM disks live, even before it exists" do
      Dir.mktmpdir do |root|
        write(root, "proc/mounts", "/dev/sda1 / ext4 rw,prjquota 0 0\n/dev/sdb /var ext4 rw 0 0\n/dev/sdc /var/storagex ext4 rw,prjquota 0 0\n")
        expect(described_class.prjquota(root)).to be(false)
        write(root, "proc/mounts", "/dev/sda1 / ext4 rw 0 0\n/dev/sdb /var ext4 rw 0 0\n/dev/nvme0n1 /var/storage xfs rw,prjquota 0 0\n")
        expect(described_class.prjquota(root)).to be(true)
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
        write(root, "proc/1/environ", "PATH=/bin\0container=lxc\0TERM=xterm\0")
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
        write(root, "sys/module/kvm_amd/parameters/nested", "1\n")
        expect(described_class.nested_param(root)).to be(true)
      end
    end

    it "reads N as false" do
      Dir.mktmpdir do |root|
        write(root, "sys/module/kvm_intel/parameters/nested", "N\n")
        expect(described_class.nested_param(root)).to be(false)
      end
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

  describe ".sanitize" do
    it "strips control characters, bad bytes and length from strings" do
      expect(described_class.sanitize("a\e[31mb\nc\u0000d")).to eq "a[31mbcd"
      expect(described_class.sanitize("x\xFFy".b.force_encoding("UTF-8"))).to eq "x?y"
      expect(described_class.sanitize("z" * 500).size).to eq described_class::MAX_STRING
    end

    it "caps arrays, hashes and nesting, and keeps scalars" do
      expect(described_class.sanitize(Array.new(100, 1)).size).to eq described_class::MAX_ENTRIES
      expect(described_class.sanitize((1..100).to_h { |i| [i, i] }).size).to eq described_class::MAX_ENTRIES
      expect(described_class.sanitize({"a" => [{"b" => [[1]]}], :c => {"d" => {"e" => {"f" => {}}}}})).to eq("a" => [{"b" => [[]]}], "c" => {"d" => {"e" => {"f" => {}}}})
      expect(described_class.sanitize([[[[[1]]]]])).to eq [[[[[]]]]]
      expect(described_class.sanitize({"a" => {"b" => {"c" => {"d" => {"e" => 1}}}}})).to eq("a" => {"b" => {"c" => {"d" => {}}}})
      expect(described_class.sanitize([1, 1.5, true, false, nil, :sym])).to eq [1, 1.5, true, false, nil, "sym"]
    end
  end

  describe ".classify" do
    it "takes a bare-metal host with KVM" do
      expect(described_class.classify(facts)).to eq(["kvm", ["/dev/kvm answers KVM_GET_API_VERSION 12"], nil])
    end

    it "takes a /dev/kvm nobody opened as kvm (facts from a shell preflight)" do
      expect(described_class.classify(facts(kvm_api: nil, kvm_create_vm: nil, kvm_caps_missing: nil))).to eq(["kvm", ["/dev/kvm exists (not opened)"], nil])
    end

    it "refuses a container even with /dev/kvm" do
      expect(described_class.classify(facts(virt_container: "lxc"))).to eq(["container", ["this is a lxc container"], nil])
    end

    it "takes a container nil as unknown, not a container" do
      expect(described_class.classify(facts(virt_container: nil)).first).to eq("kvm")
    end

    it "does not conclude anything from a refused open" do
      expect(described_class.classify(facts(kvm_api: "Permission denied @ rb_sysopen - /dev/kvm", kvm_errno: "EACCES"))).to eq(["unknown_permission", ["opening /dev/kvm was refused (EACCES); run the probe as root"], "permission"])
      expect(described_class.classify(facts(kvm_api: "Operation not permitted", kvm_errno: nil)).first).to eq("unknown_permission")
      expect(described_class.classify(facts(kvm_api: "Permission denied", kvm_errno: "ENXIO")).last).to eq("unresponsive")
    end

    it "takes /dev/kvm from kvm_pvm alone as pvm, even on a generic CPU model" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], modules: %w[kvm kvm_pvm], virt_vm: "amazon", cpu_model: "Common KVM processor")).first).to eq("pvm")
    end

    it "takes kvm_pvm beside a hardware module as kvm" do
      expect(described_class.classify(facts(modules: %w[kvm kvm_intel kvm_pvm])).first).to eq("kvm")
    end

    it "blocks a generic CPU model, with or without a working /dev/kvm" do
      expect(described_class.classify(facts(cpu_model: "QEMU Virtual CPU version 2.5+"))).to eq(["kvm_blocked", ["the CPU model is the hypervisor's generic \"QEMU Virtual CPU version 2.5+\", not the host's"], "cpu_model"])
      expect(described_class.classify(facts(cpu_model: "Common KVM processor", cpu_flags: %w[hypervisor], dev_kvm: false, virt_vm: "kvm")).last).to eq("cpu_model")
    end

    it "blocks a KVM that refuses a VM or lacks a capability" do
      expect(described_class.classify(facts(kvm_create_vm: "Cannot allocate memory"))).to eq(["kvm_blocked", ["/dev/kvm refuses KVM_CREATE_VM (Cannot allocate memory)"], "create_vm"])
      expect(described_class.classify(facts(kvm_caps_missing: %w[SplitIrqchip Xcrs]))).to eq(["kvm_blocked", ["KVM lacks capabilities cloud-hypervisor requires: SplitIrqchip, Xcrs"], "missing_caps"])
    end

    it "checks the capabilities only on x86_64" do
      expect(described_class.classify(facts(arch: "aarch64", kvm_caps_missing: %w[SplitIrqchip])).first).to eq("kvm")
    end

    it "trusts the kernel log's firmware line over the CPU flags" do
      expect(described_class.classify(facts(cpu_flags: %w[svm], dev_kvm: false, modules: [], bios_log: "kvm_amd: SVM disabled (by BIOS)"))).to eq(["kvm_blocked", ["the kernel log says the firmware disabled virtualization: kvm_amd: SVM disabled (by BIOS)"], "firmware"])
    end

    it "blocks a /dev/kvm that does not answer" do
      expect(described_class.classify(facts(kvm_api: "Inappropriate ioctl for device", kvm_errno: "ENOTTY"))).to eq(["kvm_blocked", ["/dev/kvm exists but does not answer KVM_GET_API_VERSION (Inappropriate ioctl for device)"], "unresponsive"])
    end

    it "blocks vmx without kvm_intel" do
      expect(described_class.classify(facts(dev_kvm: false, kvm_api: nil, modules: []))).to eq(["kvm_blocked", ["the CPU has vmx but kvm_intel is not loaded"], "module"])
    end

    it "blocks svm with kvm_amd loaded but no /dev/kvm" do
      expect(described_class.classify(facts(cpu_flags: %w[svm], dev_kvm: false, modules: %w[kvm kvm_amd]))).to eq(["kvm_blocked", ["kvm_amd is loaded but there is no /dev/kvm"], "no_device"])
    end

    it "blocks x86 bare metal without vmx or svm as a firmware setting" do
      expect(described_class.classify(facts(cpu_flags: [], dev_kvm: false, modules: []))).to eq(["kvm_blocked", ["bare metal without the vmx or svm flag: the firmware has VT-x/AMD-V disabled"], "firmware"])
    end

    it "blocks arm64 bare metal without /dev/kvm" do
      expect(described_class.classify(facts(arch: "aarch64", cpu_flags: [], dev_kvm: false, modules: []))[1].first).to start_with("bare metal without /dev/kvm")
    end

    it "does not take a VM that hides its CPUID bit for bare metal" do
      expect(described_class.classify(facts(cpu_flags: [], dev_kvm: false, modules: [], dmi: {"sys_vendor" => "QEMU"}))).to eq(["none", ["this is a VM (its DMI names a hypervisor) without hardware virtualization"], "no_virt"])
      expect(described_class.classify(facts(cpu_flags: [], dev_kvm: false, modules: [], dmi: "junk")).last).to eq("firmware")
    end

    it "takes a VM with the hypervisor flag as not bare metal" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], dev_kvm: false, modules: [], virt_vm: nil, dmi: {}))).to eq(["none", ["no /dev/kvm and no hardware virtualization flags"], "no_virt"])
    end

    it "blocks a VM whose kernel ships kvm_pvm" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], dev_kvm: false, modules: [], virt_vm: "kvm", pvm_module_available: true))).to eq(["pvm_blocked", ["the running kernel ships kvm_pvm but it is not loaded"], "pvm_module"])
    end

    it "names the hypervisor of a VM without hardware virtualization" do
      expect(described_class.classify(facts(cpu_flags: %w[hypervisor], dev_kvm: false, modules: [], virt_vm: "xen"))).to eq(["none", ["this VM (xen) gets no hardware virtualization from its hypervisor"], "no_virt"])
    end

    it "takes missing facts as unknown" do
      expect(described_class.classify({"dev_kvm" => true}).first).to eq("kvm")
      expect(described_class.classify({})).to eq(["unknown", ["dev_kvm, cpu_flags, arch not gathered, so whether KVM can work here is unknown"], "not_gathered"])
    end

    it "never makes a host L2 from a fact that was not gathered" do
      # A shell preflight that skipped /dev/kvm, on a working L1 host.
      expect(described_class.classify(facts.except("dev_kvm", "kvm_api", "kvm_create_vm", "kvm_caps_missing"))).to eq(["unknown", ["dev_kvm not gathered, so whether KVM can work here is unknown"], "not_gathered"])
      expect(described_class.classify(facts(dev_kvm: nil, modules: nil)).last).to eq("not_gathered")
      # Without the CPU flags, "no vmx" is not evidence of firmware.
      expect(described_class.classify(facts(dev_kvm: false, cpu_flags: nil)).first).to eq("unknown")
      expect(described_class.classify(facts(dev_kvm: false, arch: nil)).first).to eq("unknown")
    end

    it "says which facts behind an L2 cause were not gathered" do
      expect(described_class.classify(facts(dev_kvm: false, modules: nil).except("bios_log"))).to eq(["kvm_blocked", ["the CPU has vmx but kvm_intel was not seen loaded (the loaded modules were not gathered); the kernel log was not read, so the firmware may have disabled it"], "module"])
      expect(described_class.classify(facts(cpu_flags: %w[svm], dev_kvm: false, modules: %w[kvm_amd]).except("bios_log"))).to eq(["kvm_blocked", ["kvm_amd is loaded but there is no /dev/kvm; the kernel log was not read, so the firmware may have disabled it"], "no_device"])
    end
  end

  describe ".nested?" do
    it "marks KVM inside a VM as nested, by flag, systemd or DMI" do
      expect(described_class.nested?(facts(cpu_flags: %w[vmx hypervisor], virt_vm: nil), "kvm")).to be(true)
      expect(described_class.nested?(facts(virt_vm: "kvm"), "kvm")).to be(true)
      expect(described_class.nested?(facts(dmi: {"product_name" => "VMware7,1"}), "kvm")).to be(true)
    end

    it "does not mark bare metal or another tier as nested" do
      expect(described_class.nested?(facts, "kvm")).to be(false)
      expect(described_class.nested?(facts(virt_vm: "kvm"), "pvm")).to be(false)
    end
  end

  describe ".fallbacks" do
    none = {"possible" => [], "ready" => [], "unchecked" => []}

    it "offers none on L1, in a container, without permission or facts, and only pvm on a PVM host" do
      %w[kvm container unknown_permission unknown].each { |tier| expect(described_class.fallbacks(facts, tier)).to eq(none) }
      expect(described_class.fallbacks(facts, "pvm")).to eq("possible" => ["pvm"], "ready" => ["pvm"], "unchecked" => [])
    end

    it "offers container and emulated on a KVM host without 1G pages, which cannot take today's VMs" do
      installed = {"lxc-start" => true, "lxcfs" => true, "qemu-system-x86_64" => false}
      expect(described_class.fallbacks(facts(cpu_flags: %w[vmx], commands: installed), "kvm")).to eq("possible" => %w[container emulated], "ready" => %w[container], "unchecked" => [])
      expect(described_class.fallbacks(facts(arch: "aarch64", cpu_flags: []), "kvm")).to eq(none)
      expect(described_class.fallbacks(facts(cpu_flags: nil), "kvm")).to eq(none)
    end

    it "lists what the kernel allows and what is installed, fastest first" do
      installed = {"lxc-start" => true, "lxcfs" => true, "qemu-system-x86_64" => true}
      expect(described_class.fallbacks(facts(commands: installed, ovmf: true), "pvm_blocked")).to eq("possible" => %w[container pvm emulated], "ready" => %w[container emulated], "unchecked" => [])
      expect(described_class.fallbacks(facts(commands: installed.merge("lxcfs" => false)), "none")).to eq("possible" => %w[container emulated], "ready" => [], "unchecked" => [])
      expect(described_class.fallbacks(facts(kernel: "5.4.0-1", commands: nil), "none")).to eq("possible" => %w[emulated], "ready" => [], "unchecked" => [])
      expect(described_class.fallbacks(facts(kernel: "5.12.0", cgroup2: false), "none")).to eq("possible" => %w[emulated], "ready" => [], "unchecked" => [])
      expect(described_class.fallbacks(facts(arch: "aarch64", kernel: "6.8.0"), "kvm_blocked")).to eq("possible" => %w[container], "ready" => [], "unchecked" => [])
    end

    it "lists a fallback whose kernel needs were not gathered as unchecked, never as impossible" do
      expect(described_class.fallbacks(facts.except("cgroup2"), "none")).to eq("possible" => %w[emulated], "ready" => [], "unchecked" => %w[container])
      expect(described_class.fallbacks(facts(kernel: nil), "none")).to eq("possible" => %w[emulated], "ready" => [], "unchecked" => %w[container])
      expect(described_class.fallbacks(facts(arch: nil, kernel: nil), "kvm_blocked")).to eq("possible" => [], "ready" => [], "unchecked" => %w[container emulated])
    end
  end

  describe ".report" do
    it "carries the classification, the fallbacks and the facts" do
      expect(described_class.report(facts(cpu_flags: %w[vmx hypervisor pdpe1gb], virt_vm: nil))).to include("version" => 2, "tier" => "kvm", "cause" => nil, "nested" => true, "possible" => [], "ready" => [], "unchecked" => [])
    end
  end

  describe ".main" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    before do
      allow(described_class).to receive(:facts).with(root: "/").and_return(facts(cpu_flags: %w[vmx hypervisor pdpe1gb]))
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
        cpu: x86_64 Intel Xeon flags=vmx,hypervisor,pdpe1gb
        kvm: /dev/kvm=true api=12 create_vm=true caps_missing=[] modules=kvm,kvm_intel nested_param=true
        virt: vm="none" container="none" dmi=Dell Inc. / PowerEdge R650
        fallbacks: possible= ready=
        For the fix on this platform run bin/byoh-virt probe --main-ip <this host> on the control plane; see docs/byoh/NO_KVM.md.
      TEXT
    end

    it "prints a machine without KVM, unknown DMI and no nested note" do
      allow(described_class).to receive(:facts).with(root: "/x").and_return(facts(dmi: {"sys_vendor" => "x\ey"}, cpu_flags: [], dev_kvm: false, virt_vm: "kvm", commands: {"qemu-system-x86_64" => true}, ovmf: true))
      expect(described_class.main(["--root", "/x"], out: out, err: err)).to eq(0)
      expect(out.string).to start_with("tier: none\n").and include("kvm: /dev/kvm=false modules=").and include("dmi=xy\n").and include("fallbacks: possible=container,emulated ready=emulated\n")
      allow(described_class).to receive(:facts).with(root: "/z").and_return(facts(cpu_flags: [], dev_kvm: false, virt_vm: "kvm", cgroup2: nil))
      described_class.main(["--root", "/z"], out: out, err: err)
      expect(out.string).to include("fallbacks: possible=emulated ready= unchecked=container\n")
      allow(described_class).to receive(:facts).with(root: "/y").and_return(facts(dmi: {}))
      described_class.main(["--root", "/y"], out: out, err: err)
      expect(out.string).to include("dmi=unknown")
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
