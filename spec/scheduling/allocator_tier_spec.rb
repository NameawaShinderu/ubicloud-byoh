# frozen_string_literal: true

require_relative "../model/spec_helper"

# Lower virtualization tiers in the allocator (docs/byoh/NO_KVM.md
# section 5.4). allocator_golden_spec.rb pins KVM placement.
RSpec.describe Scheduling::Allocator do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:project) { Project.create(name: "tier") }
  let(:vol) { [{"size_gib" => 10, "use_bdev_ubi" => false, "encrypted" => false, "boot" => true, "vring_workers" => 1, "track_written" => false}] }

  def host(tier, family = (tier == "kvm") ? "standard" : tier, suffix:)
    vmh = create_byoh_vm_host(location, virt_tier: tier, family:, net6: "fd00:1:2:#{suffix}::/64", total_mem_gib: 64, total_sockets: 1,
      total_dies: 1, total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2, accepts_slices: false)
    BootImage.create(name: "ubuntu-noble", version: "20250502.1", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
    StorageDevice.create(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 120)
    create_vhost_block_backend(vm_host_id: vmh.id, version: "v0.4.2")
    (0..15).each { VmHostCpu.create(vm_host_id: vmh.id, cpu_number: it, io: false) }
    vmh
  end

  def vm(family)
    Vm.create(name: "vm-#{family}", unix_user: "ubi", public_key: "ssh key", boot_image: "ubuntu-noble", location_id: location.id,
      project_id: project.id, arch: "x64", family:, cores: 0, vcpus: 2, cpu_percent_limit: 200, cpu_burst_percent_limit: 0, memory_gib: 8).tap {
      it.create_storage_volumes(vol.map { |v| v.transform_keys(&:to_sym) })
    }
  end

  it "places a lower-tier VM only on a host of its tier" do
    host("kvm", suffix: 1)
    emulated = host("emulated", suffix: 2)
    v = vm("emulated")
    described_class.allocate(v, vol, family_filter: ["emulated"])
    expect(v.reload.vm_host_id).to eq emulated.id
    expect(v.vm_storage_volumes.first.vhost_block_backend).not_to be_nil
  end

  it "refuses a VM forced onto a host of another tier" do
    kvm = host("kvm", suffix: 1)
    emulated = host("emulated", suffix: 2)
    expect { described_class.allocate(vm("emulated"), vol, host_filter: [kvm.id]) }
      .to raise_error(Scheduling::Allocator::NoSpaceLeft, "emulated VM cannot run on kvm host #{kvm.ubid}")
    expect { described_class.allocate(vm("standard"), vol, host_filter: [emulated.id]) }
      .to raise_error(Scheduling::Allocator::NoSpaceLeft, "kvm VM cannot run on emulated host #{emulated.ubid}")
    expect(Vm.exclude(vm_host_id: nil).count).to eq 0
  end

  it "gives volumes on a tier with its own disks no vhost backend" do
    container = host("container", suffix: 3)
    v = vm("container")
    described_class.allocate(v, vol, family_filter: ["container"])
    volume = v.reload.vm_storage_volumes.first
    expect(v.vm_host_id).to eq container.id
    expect(volume.values.slice(:vhost_block_backend_id, :spdk_installation_id, :use_bdev_ubi, :vring_workers))
      .to eq(vhost_block_backend_id: nil, spdk_installation_id: nil, use_bdev_ubi: false, vring_workers: nil)
    expect(volume.storage_device.name).to eq "stor1"
    expect(volume.boot_image.name).to eq "ubuntu-noble"
  end
end
