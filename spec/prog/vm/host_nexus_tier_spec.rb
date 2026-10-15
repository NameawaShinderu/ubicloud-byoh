# frozen_string_literal: true

require_relative "../../model/spec_helper"
require_relative "../../../rhizome/host/lib/virt_probe"

# HostNexus on hosts registered on a lower virtualization tier
# (docs/byoh/NO_KVM.md). KVM hosts keep every label as before; the
# goldens and host_nexus_spec.rb pin that.
RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(st) }

  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:tier) { "emulated" }
  let(:vm_host) { create_byoh_vm_host(location, virt_tier: tier, family: tier, net6: "fd00:1:2:3::/64", total_cores: 4, total_cpus: 8, used_cores: 1) }
  let(:st) { Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "wait_prep", stack: [{}]) }
  let(:provider_config) { {"main_ip4" => "203.0.113.42", "location_label" => "x", "routed_networks" => [{"cidr" => "fd00:feed::/64"}]} }

  def offer(tiers, acks = tiers.to_h { [it, []] })
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["kvm", *tiers], "acks" => acks}))
  end

  def probe(**over)
    facts = {
      "arch" => "x86_64", "kernel" => "6.8.0-1-generic", "cpu_vendor" => "GenuineIntel", "cpu_model" => "Intel Xeon",
      "cpu_flags" => %w[hypervisor pdpe1gb], "dev_kvm" => false, "modules" => [], "virt_vm" => "kvm", "virt_container" => "none",
      "bios_log" => nil, "dmi" => {"sys_vendor" => "QEMU"}, "cgroup2" => true,
      "commands" => {"lxc-start" => true, "lxcfs" => true, "qemu-system-x86_64" => true}, "ovmf" => true,
    }.merge(over.transform_keys(&:to_s))
    ByohVirtLadder.from_facts(facts).record
  end

  describe ".assemble" do
    def assemble(**)
      described_class.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME, provider_config:, **)
    end

    it "registers a lower-tier host with its tier's family" do
      ship_virt_tiers("emulated")
      offer(%w[emulated])
      host = assemble(virt_tier: "emulated").subject
      expect(host.values.slice(:virt_tier, :family)).to eq(virt_tier: "emulated", family: "emulated")
    end

    it "registers a kvm host as before" do
      host = assemble.subject
      expect(host.values.slice(:virt_tier, :family)).to eq(virt_tier: "kvm", family: "standard")
    end

    it "refuses a lower tier that is unknown, not shipped, not offered, outside BYOH or with another family" do
      expect { assemble(virt_tier: "tcg") }.to raise_error(ByohVirtTiers::Refused, /unknown tier "tcg"/)
      expect { assemble(virt_tier: "emulated") }.to raise_error(RuntimeError, "emulated hosts are not available yet")
      ship_virt_tiers("emulated")
      expect { assemble(virt_tier: "emulated") }.to raise_error(RuntimeError, "Location byoh-test does not offer emulated hosts")
      offer(%w[emulated])
      expect { assemble(virt_tier: "emulated", family: "premium") }.to raise_error(RuntimeError, "A emulated host has family emulated, not premium")
      expect { described_class.assemble("203.0.113.43", virt_tier: "emulated") }.to raise_error(RuntimeError, "A emulated host must be a generic provider host in a BYOH location")
      expect(VmHost.count).to eq 0
    end

    it "refuses a kvm host into a location that does not offer kvm" do
      ship_virt_tiers("emulated")
      location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["emulated"], "acks" => {"emulated" => []}}))
      expect { assemble }.to raise_error(RuntimeError, "Location byoh-test does not offer kvm hosts")
    end
  end

  describe "#wait_prep" do
    ByohVirtTiers::TIERS.each_key do |each_tier|
      context "with a #{each_tier} host" do
        let(:tier) { each_tier }

        it "takes no slices, keeps a core for the host and checks the tier next" do
          Strand.create(parent_id: st.id, prog: "LearnOs", label: "start", exitval: {"os_version" => "ubuntu-24.04"})
          Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", exitval: {"arch" => "x64", "total_sockets" => 1, "total_dies" => 1, "total_cores" => 4, "total_cpus" => 8, "cpu_numa_nodes" => [0] * 8})
          expect { nx.wait_prep }.to hop("verify_virt_tier")
          vm_host.reload
          expect(vm_host.accepts_slices).to be false
          expect(vm_host.used_cores).to eq 1
        end
      end
    end

    it "keeps a kvm BYOH host's walk when its probe crashed" do
      kvm_host = create_byoh_vm_host(location, net6: "fd00:1:2:4::/64", virt_probe: Sequel.pg_jsonb({"error" => "RuntimeError: boom"}))
      kvm_st = Strand.create_with_id(kvm_host, prog: "Vm::HostNexus", label: "wait_prep", stack: [{}])
      Strand.create(parent_id: kvm_st.id, prog: "LearnOs", label: "start", exitval: {"os_version" => "ubuntu-24.04"})
      Strand.create(parent_id: kvm_st.id, prog: "LearnVirt", label: "start", exitval: {"msg" => "virt probe failed"})
      expect { described_class.new(kvm_st).wait_prep }.to hop("setup_hugepages")
      expect(kvm_host.reload.accepts_slices).to be true
    end
  end

  describe "#verify_virt_tier" do
    it "waits for a probe" do
      expect { nx.verify_virt_tier }.to raise_error(RuntimeError, /\Aemulated host has no virtualization probe yet; run bin\/byoh-virt refresh --host #{vm_host.ubid}/)
      vm_host.update(virt_probe: Sequel.pg_jsonb({"error" => "boom"}))
      expect { nx.verify_virt_tier }.to raise_error(RuntimeError, /no virtualization probe yet/)
    end

    it "refuses a probe that disagrees with the tier" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(probe(ovmf: false)))
      expect { nx.verify_virt_tier }.to raise_error(RuntimeError, /\Aemulated host does not have the tier's prerequisites \(probe: none \(L3-L5\)/)
    end

    it "sets up the vhost backend for a tier that uses it" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(probe))
      expect { nx.verify_virt_tier }.to hop("setup_storage_backend")
    end

    context "with a tier that keeps its own disks" do
      let(:tier) { "container" }

      it "goes straight to the boot images" do
        vm_host.update(virt_probe: Sequel.pg_jsonb(probe))
        expect { nx.verify_virt_tier }.to hop("download_boot_images")
      end
    end
  end

  describe "#reboot" do
    it "checks the tier's capacity instead of hugepages" do
      vm_host.update(last_boot_id: "old")
      expect(nx.sshable).to receive(:available?).and_return(true)
      expect(nx.sshable).to receive(:_cmd).with("sudo host/bin/reboot-host old").and_return("new\n")
      expect { nx.reboot }.to hop("verify_tier_capacity")
    end
  end

  describe "#verify_tier_capacity" do
    def meminfo(total: 33554432, available: 30000000, hugepages: 0)
      "MemTotal:       #{total} kB\nMemAvailable:   #{available} kB\nHugePages_Total:    #{hugepages}\nHugePages_Free:     #{hugepages}\nHugepagesize:    1048576 kB\n"
    end

    # 32 GiB and 8 CPUs: (32768 * 42 / 43) - 2048 MiB, less the tier's
    # per-VM overhead for 4 VMs of 2 vCPUs.
    {"container" => 28, "pvm" => 27, "emulated" => 27}.each do |each_tier, budget|
      context "with a #{each_tier} host" do
        let(:tier) { each_tier }

        it "writes the memory budget into the hugepage columns" do
          create_vm(vm_host_id: vm_host.id, family: tier, memory_gib: 4, location_id: location.id)
          expect(nx.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return(meminfo)
          expect { nx.verify_tier_capacity }.to hop("start_slices")
          expect(vm_host.reload.values.slice(:total_hugepages_1g, :used_hugepages_1g)).to eq(total_hugepages_1g: budget, used_hugepages_1g: 4)
        end

        it "fails without the cores or the memory budget for its VMs" do
          expect(nx.sshable).to receive(:_cmd).and_return(meminfo, meminfo(total: 4194304))
          nx.vm_host.update(total_cores: 1, used_cores: 0)
          expect { nx.verify_tier_capacity }.to raise_error(RuntimeError, "#{tier} hosts need at least 2 physical cores")
          nx.vm_host.update(total_cores: 4)
          create_vm(vm_host_id: vm_host.id, family: tier, memory_gib: 4, location_id: location.id)
          expect { nx.verify_tier_capacity }.to raise_error(RuntimeError, /\ANot enough memory budget for VMs \([01] GiB for 4 GiB of VMs\)\z/)
        end
      end
    end

    it "logs hugepages the host still keeps" do
      expect(nx.sshable).to receive(:_cmd).and_return(meminfo(hugepages: 4))
      expect(Clog).to receive(:emit).with("lower-tier host keeps hugepages", {tier_capacity: {vm_host_id: vm_host.id, hugepages_mib: 4096}})
      expect { nx.verify_tier_capacity }.to hop("start_slices")
      expect(vm_host.reload.total_hugepages_1g).to eq 23
    end

    it "fails on what it cannot use" do
      expect(nx.sshable).to receive(:_cmd).and_return("MemTotal: 1 kB\n", meminfo(available: 1024), meminfo, meminfo(total: 4194304))
      expect { nx.verify_tier_capacity }.to raise_error(RuntimeError, "Couldn't parse /proc/meminfo")
      expect { nx.verify_tier_capacity }.to raise_error(RuntimeError, "Insufficient memory left for the host OS")
      nx.vm_host.update(total_cores: 1, used_cores: 0)
      expect { nx.verify_tier_capacity }.to raise_error(RuntimeError, "emulated hosts need at least 2 physical cores")
      nx.vm_host.update(total_cores: 4)
      create_vm(vm_host_id: vm_host.id, family: "emulated", memory_gib: 4, location_id: location.id)
      expect { nx.verify_tier_capacity }.to raise_error(RuntimeError, "Not enough memory budget for VMs (0 GiB for 4 GiB of VMs)")
    end
  end
end
