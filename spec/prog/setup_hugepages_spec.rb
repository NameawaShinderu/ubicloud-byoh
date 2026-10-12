# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupHugepages do
  subject(:sh) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}], prog: "SetupHugepages")) }

  let(:vm_host) {
    vm_host = Prog::Vm::HostNexus.assemble("::1").subject
    vm_host.update(arch: "x64", total_mem_gib: 64)
    vm_host
  }

  def expect_prerequisites(pdpe1gb: "16\n", grub: "ok\n")
    expect(sh.sshable).to receive(:_cmd).with("grep -cw pdpe1gb /proc/cpuinfo || true").and_return(pdpe1gb)
    expect(sh.sshable).to receive(:_cmd).with(described_class::GRUB_CHECK).and_return(grub)
  end

  def expect_grub_update(hugepages)
    expect(sh.sshable).to receive(:_cmd).with(described_class::STRIP_GRUB_TOKENS).ordered
    expect(sh.sshable).to receive(:_cmd).with("sudo mkdir -p /etc/default/grub.d").ordered
    expect(sh.sshable).to receive(:_cmd).with("sudo tee /etc/default/grub.d/99-ubicloud-hugepages.cfg > /dev/null",
      stdin: "GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX hugetlb_free_vmemmap=on default_hugepagesz=1G hugepagesz=1G hugepages=#{hugepages}\"\n").ordered
    expect(sh.sshable).to receive(:_cmd).with("sudo update-grub").ordered
  end

  describe "#start" do
    it "pops after installing hugepages" do
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 65011712 kB\n")
      expect_grub_update(57)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "allocates 120 hugepages for a 128G system" do
      # To fit premium-30 VMs on AX-102 hosts, we need to be able to allocate
      # 120 hugepages on a 128G system.
      vm_host.update(total_mem_gib: 128)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 129000000 kB\n")
      expect_grub_update(120)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "clamps the hugepage count when available memory falls short" do
      vm_host.update(total_mem_gib: 128)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 124780544 kB\n")
      expect(Clog).to receive(:emit).with("hugepage count clamped to available memory", {hugepage_clamp: {formula_count: 120, clamped_count: 116}}).and_call_original
      expect_grub_update(116)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "counts the hugepages already reserved when setup runs again" do
      # 57 1G pages reserved at boot, with their struct page memory returned.
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return(<<~MEMINFO)
        MemAvailable: #{65011712 - 57 * 1048576 + 57 * 16380} kB
        HugePages_Total:      57
        Hugepagesize:    1048576 kB
      MEMINFO
      expect(Clog).not_to receive(:emit)
      expect_grub_update(57)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "counts reserved 2M hugepages without a struct page credit" do
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return(<<~MEMINFO)
        MemAvailable: #{65011712 - 1024 * 2048} kB
        HugePages_Total:    1024
        Hugepagesize:       2048 kB
      MEMINFO
      expect(Clog).not_to receive(:emit)
      expect_grub_update(57)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "never asks for a negative hugepage count" do
      vm_host.update(total_mem_gib: 4)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 2097152 kB\n")
      expect_grub_update(0)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "clamps to zero when available memory is below the host margin" do
      vm_host.update(total_mem_gib: 16)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 2097152 kB\n")
      expect(Clog).to receive(:emit).with("hugepage count clamped to available memory", {hugepage_clamp: {formula_count: 10, clamped_count: 0}}).and_call_original
      expect_grub_update(0)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "does not check for pdpe1gb on arm64" do
      vm_host.update(arch: "arm64")
      expect(sh.sshable).not_to receive(:_cmd).with("grep -cw pdpe1gb /proc/cpuinfo || true")
      expect(sh.sshable).to receive(:_cmd).with(described_class::GRUB_CHECK).and_return("ok\n")
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 65011712 kB\n")
      expect_grub_update(57)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "fails if the CPU lacks pdpe1gb" do
      expect(sh.sshable).to receive(:_cmd).with("grep -cw pdpe1gb /proc/cpuinfo || true").and_return("0\n")
      expect { sh.start }.to raise_error RuntimeError, "CPU lacks the pdpe1gb flag, so it cannot use 1G hugepages"
    end

    it "fails if the host does not boot with GRUB" do
      expect_prerequisites(grub: "")
      expect { sh.start }.to raise_error RuntimeError, "/etc/default/grub or update-grub is missing; the host must boot with GRUB"
    end

    it "fails before changing GRUB when a slice host would get too few hugepages" do
      vm_host.update(total_mem_gib: 16, accepts_slices: true)
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100, hugepages: 4)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 16252928 kB\n")
      expect(sh.sshable).not_to receive(:_cmd).with(described_class::STRIP_GRUB_TOKENS)
      expect { sh.start }.to raise_error RuntimeError, "Only 6 usable 1G hugepages; a host that runs dedicated slices needs at least 8"
    end

    it "accepts a slice host with enough hugepages for the smallest slice" do
      vm_host.update(total_mem_gib: 14, accepts_slices: true)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemAvailable: 14155776 kB\n")
      expect_grub_update(8)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end

    it "fails if available memory couldn't be extracted" do
      vm_host.update(total_mem_gib: 128)
      expect_prerequisites
      expect(sh.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemTotal: 131379640 kB\n")
      expect { sh.start }.to raise_error RuntimeError, "Couldn't extract available memory"
    end
  end
end
