# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnPci do
  describe "#make_model_instances" do
    let(:nvidia_gpu_with_audio) do
    end

    it "exits, saving model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(lp.sshable).to receive(:_cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Vendor:	10de
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
NUMANode:	1
IOMMUGroup:	13

Slot:	01:00.1
Class:	0403
Vendor:	10de
Device:	22bc
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13
EOS
      expect { lp.start }.to exit({"msg" => "created PciDevice records"}).and change {
        PciDevice.map { {vm_host_id: it.vm_host_id, slot: it.slot, device_class: it.device_class, vendor: it.vendor, device: it.device, numa_node: it.numa_node, iommu_group: it.iommu_group, vm_id: it.vm_id} }.sort_by { it[:slot] }
      }.from(
        [],
      ).to(
        [
          {vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "10de", device: "27b0", numa_node: 1, iommu_group: 13, vm_id: nil},
          {vm_host_id: vmh.id, slot: "01:00.1", device_class: "0403", vendor: "10de", device: "22bc", numa_node: nil, iommu_group: 13, vm_id: nil},
        ],
      )
    end

    it "exits, updating existing model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      PciDevice.create(vm_host_id: vmh.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 3)
      expect(lp.sshable).to receive(:_cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Vendor:	10de
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13

Slot:	01:00.1
Class:	0403
Vendor:	10de
Device:	22bc
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13
EOS
      expect { lp.start }.to exit({"msg" => "created PciDevice records"}).and change {
        PciDevice.map { {vm_host_id: it.vm_host_id, slot: it.slot, device_class: it.device_class, vendor: it.vendor, device: it.device, numa_node: it.numa_node, iommu_group: it.iommu_group, vm_id: it.vm_id} }.sort_by { it[:slot] }
      }.from(
        [{vm_host_id: vmh.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 3, vm_id: nil}],
      ).to(
        [
          {vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "10de", device: "27b0", numa_node: nil, iommu_group: 13, vm_id: nil},
          {vm_host_id: vmh.id, slot: "01:00.1", device_class: "0403", vendor: "10de", device: "22bc", numa_node: nil, iommu_group: 13, vm_id: nil},
        ],
      )
    end

    it "ignores devices without iommu group" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(lp.sshable).to receive(:_cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Vendor:	10de
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
EOS
      expect(lp.make_model_instances).to eq([])
    end

    it "can raise a data parse error" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(lp.sshable).to receive(:_cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13
EOS

      expect { lp.make_model_instances }.to raise_error RuntimeError, "BUG: lspci parse failed"
    end
  end

  describe "on a BYOH host" do
    let(:vm_host) { create_byoh_vm_host(create_byoh_location) }
    let(:lp) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}])) }
    let(:lspci) { "/usr/bin/lspci -vnmmk -D" }

    def lspci_fixture(name)
      File.read(File.expand_path("../fixtures/byoh/lspci/#{name}.txt", __dir__)).lines.reject { it.start_with?("# fixture:") }.join
    end

    def learned(name)
      expect(lp.sshable).to receive(:_cmd).with(lspci).and_return(lspci_fixture(name))
      lp.make_model_instances.map { [it.slot, it.device_class, it.device, it.numa_node, it.iommu_group] }
    end

    def rows
      PciDevice.where(vm_host_id: vm_host.id).order(:slot).select_map([:slot, :vm_id])
    end

    it "keeps NVIDIA functions whose whole IOMMU group is on vfio-pci, a root port included" do
      expect(learned("gpu-vfio")).to eq([
        ["01:00.0", "0300", "27b0", 0, 13],
        ["01:00.1", "0403", "22bc", nil, 13],
        ["41:00.0", "0300", "27b0", 1, 14],
        ["41:00.1", "0403", "22bc", 1, 14],
      ])
    end

    it "skips a GPU on nouveau or nvidia" do
      expect(Clog).to receive(:emit).with("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", hash_including(slot: "0000:01:00.0", blockers: ["0000:01:00.0=nouveau", "0000:01:00.1=snd_hda_intel"])).and_call_original
      expect(Clog).to receive(:emit).with("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", hash_including(slot: "0000:01:00.1")).and_call_original
      expect(learned("gpu-nouveau")).to eq([])

      allow(Clog).to receive(:emit).and_call_original
      expect(learned("gpu-nvidia")).to eq([])
    end

    it "skips a vfio-pci GPU whose audio function is still on snd_hda_intel" do
      expect(Clog).to receive(:emit).with("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", hash_including(slot: "0000:01:00.0", blockers: ["0000:01:00.1=snd_hda_intel"])).and_call_original
      expect(Clog).to receive(:emit).with("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", hash_including(slot: "0000:01:00.1")).and_call_original
      expect(learned("gpu-vfio-audio-snd")).to eq([])
    end

    it "skips a GPU sharing its group with a bound endpoint, an unbound GPU and a GPU outside domain 0000" do
      expect(Clog).to receive(:emit).with("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", hash_including(slot: "0000:21:00.0", blockers: ["0000:21:00.3=xhci_hcd"])).and_call_original
      expect(Clog).to receive(:emit).with("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", hash_including(slot: "0000:22:00.0", blockers: ["0000:22:00.0=none"])).and_call_original
      expect(Clog).to receive(:emit).with("PCI device outside PCI domain 0000 skipped on VmHost #{vm_host.ubid}", {slot: "0001:01:00.0"}).and_call_original
      expect(learned("gpu-vfio-shared-group")).to eq([])
    end

    it "accepts an NVIDIA bridge in a GPU's group and does not record it" do
      expect(learned("gpu-vfio-nvidia-bridge")).to eq([["01:00.0", "0302", "20b5", 0, 7]])
    end

    it "learns nothing on a host without a GPU" do
      expect(learned("no-gpu")).to eq([])
    end

    it "accepts unbound and pci-stub members of a GPU's group" do
      expect(lp.sshable).to receive(:_cmd).with(lspci).and_return(<<EOS)
Slot:	0000:00:00.0
Class:	0600
Vendor:	8086
Device:	1234
IOMMUGroup:	5

Slot:	0000:00:00.1
Class:	0880
Vendor:	8086
Device:	1235
Driver:	pci-stub
IOMMUGroup:	5

Slot:	0000:00:02.0
Class:	0302
Vendor:	10de
Device:	20b5
Driver:	vfio-pci
IOMMUGroup:	5
EOS
      expect(lp.make_model_instances.map(&:slot)).to eq(["00:02.0"])
    end

    it "skips a slot lspci printed without its domain" do
      expect(lp.sshable).to receive(:_cmd).with(lspci).and_return("Slot:\t01:00.0\nClass:\t0300\nVendor:\t10de\nDevice:\t27b0\nDriver:\tvfio-pci\nIOMMUGroup:\t1\n")
      expect(Clog).to receive(:emit).with("PCI device outside PCI domain 0000 skipped on VmHost #{vm_host.ubid}", {slot: "01:00.0"})
      expect(lp.make_model_instances).to eq([])
    end

    it "drops rows of GPUs no longer on vfio-pci that no VM holds, and keeps the rest" do
      vm = create_vm
      PciDevice.create(vm_host_id: vm_host.id, slot: "01:00.0", device_class: "0300", vendor: "10de", device: "27b0", iommu_group: 13)
      PciDevice.create(vm_host_id: vm_host.id, slot: "05:00.0", device_class: "0300", vendor: "10de", device: "27b0", iommu_group: 15)
      PciDevice.create(vm_host_id: vm_host.id, slot: "06:00.0", device_class: "0300", vendor: "10de", device: "27b0", iommu_group: 16, vm_id: vm.id)
      other = create_vm_host
      PciDevice.create(vm_host_id: other.id, slot: "05:00.0", device_class: "0300", vendor: "10de", device: "27b0", iommu_group: 15)
      expect(lp.sshable).to receive(:_cmd).with(lspci).and_return(lspci_fixture("gpu-vfio"))

      expect { lp.start }.to exit({"msg" => "created PciDevice records"})
      expect(rows).to eq([["01:00.0", nil], ["01:00.1", nil], ["06:00.0", vm.id], ["41:00.0", nil], ["41:00.1", nil]])
      expect(PciDevice.where(vm_host_id: other.id).count).to eq(1)
    end

    it "drops every idle GPU row when none is on vfio-pci" do
      PciDevice.create(vm_host_id: vm_host.id, slot: "01:00.0", device_class: "0300", vendor: "10de", device: "27b0", iommu_group: 13)
      allow(Clog).to receive(:emit).and_call_original
      expect(lp.sshable).to receive(:_cmd).with(lspci).and_return(lspci_fixture("gpu-nouveau"))

      expect { lp.start }.to exit({"msg" => "created PciDevice records"})
      expect(rows).to eq([])
    end

    it "keeps the upstream command and rows for a generic host outside a BYOH location" do
      vm_host.update(location_id: Location::HETZNER_FSN1_ID)
      PciDevice.create(vm_host_id: vm_host.id, slot: "05:00.0", device_class: "0300", vendor: "10de", device: "27b0", iommu_group: 15)
      expect(lp.sshable).to receive(:_cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return("Slot:\t01:00.0\nClass:\t0300\nVendor:\t10de\nDevice:\t27b0\nIOMMUGroup:\t13\n")

      expect { lp.start }.to exit({"msg" => "created PciDevice records"})
      expect(rows).to eq([["01:00.0", nil], ["05:00.0", nil]])
    end
  end
end
