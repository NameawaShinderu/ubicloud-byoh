# frozen_string_literal: true

class Prog::LearnPci < Prog::Base
  subject_is :sshable, :vm_host

  REQUIRED_KEYS = ["Slot", "Class", "Vendor", "Device"]
  PciDeviceRecord = Struct.new(:slot, :device_class, :vendor, :device, :numa_node, :iommu_group, :driver) do
    def self.parse_all(lspci_str)
      out = []
      lspci_str.strip.split(/^\n+/).each do |dev_str|
        dev_h = dev_str.split("\n").to_h { |e| e.split(":\t") }
        fail "BUG: lspci parse failed" unless REQUIRED_KEYS.all? { |s| dev_h.key? s }
        next unless dev_h.key? "IOMMUGroup"

        out << PciDeviceRecord.new(dev_h["Slot"], dev_h["Class"], dev_h["Vendor"], dev_h["Device"], dev_h["NUMANode"], dev_h["IOMMUGroup"], dev_h["Driver"])
      end
      out.freeze
    end
  end

  NVIDIA_VENDOR = "10de"
  PCI_BRIDGE_CLASS = "0604"
  # rhizome addresses passed-through devices as 0000:<slot>.
  BYOH_SLOT = /\A0000:(\h\h:\h\h\.[0-7])\z/
  BYOH_LSPCI = "/usr/bin/lspci -vnmmk -D"

  def make_model_instances
    records = vm_host.byoh? ? byoh_records : PciDeviceRecord.parse_all(sshable.cmd("/usr/bin/lspci -vnmm -d 10de::"))
    records.map do |rec|
      PciDevice.new(
        vm_host_id: vm_host.id,
        slot: rec.slot,
        device_class: rec.device_class,
        vendor: rec.vendor,
        device: rec.device,
        numa_node: rec.numa_node,
        iommu_group: rec.iommu_group,
      )
    end
  end

  # Upstream hosts bind their GPUs to vfio-pci before they are learned.
  # A BYOH host may leave a GPU on nouveau or nvidia, where cloud-hypervisor
  # cannot open it, so keep an NVIDIA device only when its whole IOMMU group
  # can be handed to a VM: every NVIDIA function is on vfio-pci, and every
  # other member is one the kernel's vfio viability rule accepts (vfio-pci,
  # pci-stub, no driver, or a PCI bridge of any vendor). Bridges are never
  # passed through, so an NVIDIA bridge is not recorded.
  def byoh_records
    all = PciDeviceRecord.parse_all(sshable.cmd(BYOH_LSPCI))
    groups = all.group_by(&:iommu_group)
    all.filter_map do |rec|
      next unless rec.vendor == NVIDIA_VENDOR && rec.device_class != PCI_BRIDGE_CLASS

      unless (short_slot = rec.slot[BYOH_SLOT, 1])
        Clog.emit("PCI device outside PCI domain 0000 skipped on VmHost #{vm_host.ubid}", {slot: rec.slot})
        next
      end

      blockers = groups[rec.iommu_group].reject { vfio_viable?(it) }
      unless blockers.empty?
        Clog.emit("NVIDIA device not bound to vfio-pci skipped on VmHost #{vm_host.ubid}", {slot: rec.slot, iommu_group: rec.iommu_group, blockers: blockers.map { "#{it.slot}=#{it.driver || "none"}" }})
        next
      end

      rec.dup.tap { it.slot = short_slot }
    end
  end

  def vfio_viable?(rec)
    return true if rec.driver == "vfio-pci" || rec.device_class == PCI_BRIDGE_CLASS
    return false if rec.vendor == NVIDIA_VENDOR

    rec.driver.nil? || rec.driver == "pci-stub"
  end

  label def start
    instances = make_model_instances
    instances.each do |pci|
      pci.skip_auto_validations(:unique) do
        pci.insert_conflict(target: [:vm_host_id, :slot],
          update: {
            device_class: Sequel[:excluded][:device_class],
            vendor: Sequel[:excluded][:vendor],
            device: Sequel[:excluded][:device],
            numa_node: Sequel[:excluded][:numa_node],
            iommu_group: Sequel[:excluded][:iommu_group],
          }).save_changes
      end
    end

    # insert_conflict never removes a row, so a BYOH host learned before
    # the vfio-pci filter keeps the GPUs it can't pass through. Drop
    # those that no VM holds. The strand run's transaction covers both.
    if vm_host.byoh?
      PciDevice.where(vm_host_id: vm_host.id, vm_id: nil).exclude(slot: instances.map(&:slot)).destroy
    end

    pop("created PciDevice records")
  end
end
