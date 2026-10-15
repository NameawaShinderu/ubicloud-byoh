# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../golden_fixture"

# The prep.json a host receives, frozen byte for byte: a cloud-hypervisor
# VM on a non-BYOH host and on a BYOH generic host, and a VM with a B200
# or B300 GPU, which runs under QEMU+KVM.
RSpec.describe Vm do
  let(:project) { Project.create(name: "golden") }

  def golden_vm(vm_host, location_id:, vm_host_slice_id: nil)
    ps = PrivateSubnet.create(name: "golden-ps", location_id:, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", project_id: project.id)
    vm = described_class.create_with_id("2464de61-7501-8374-9ab0-416caebe31da",
      name: "golden-vm", unix_user: "ubi", public_key: "ssh-ed25519 AAAAgolden", boot_image: "ubuntu-noble",
      family: "standard", cores: 1, vcpus: 2, memory_gib: 8, cpu_percent_limit: 200, cpu_burst_percent_limit: 0,
      arch: "x64", location_id:, project_id: project.id, vm_host_id: vm_host.id, vm_host_slice_id:,
      ephemeral_net6: "2a01:4f8:10a:128b:3bfa::/79", local_vetho_ip: "169.254.0.5/32")
    Nic.create_with_id("7f3b5a5e-2a8c-8a72-a4a3-2b0b6c6b6f11", private_subnet_id: ps.id, vm_id: vm.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::/79", private_ipv4: "10.0.0.5/32", mac: "52:54:00:12:34:56",
      name: "golden-nic", state: "active")
    sd = StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 60)
    vbb = create_vhost_block_backend(vm_host_id: vm_host.id, version: "v0.4.2")
    bi = BootImage.create(name: "ubuntu-noble", version: "20250502.1", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 3)
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 40, disk_index: 0, storage_device_id: sd.id,
      vhost_block_backend_id: vbb.id, vring_workers: 2, boot_image_id: bi.id,
      key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "golden").id)
    vm
  end

  it "writes the same params for a cloud-hypervisor VM on a non-BYOH host" do
    vm_host = create_vm_host(total_cpus: 8, total_cores: 4, total_dies: 1, total_sockets: 1, accepts_slices: true)
    slice = create_vm_host_slice(vm_host_id: vm_host.id, name: "standardgold")
    VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: 0, io: true)
    VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: 2, vm_host_slice_id: slice.id, io: false)
    VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: 3, vm_host_slice_id: slice.id, io: false)
    vm = golden_vm(vm_host, location_id: Location::HETZNER_FSN1_ID, vm_host_slice_id: slice.id)
    address = Address.create(cidr: "203.0.113.0/30", routed_to_host_id: vm_host.id)
    AssignedVmAddress.create(ip: "203.0.113.1/32", address_id: address.id, dst_vm_id: vm.id)

    params = vm.reload.params_json(swap_size_bytes: 1024, ch_version: "46.0", firmware_version: "202311")
    expect(params).to eq GoldenFixture.read("params_json_ch.json", params)
  end

  it "writes the same params for a cloud-hypervisor VM on a BYOH generic host" do
    location = create_byoh_location(cp_reach: "public", underlay_cidrs: ["10.98.0.0/16"])
    vm_host = create_byoh_vm_host(location, total_cpus: 4, total_cores: 4, total_dies: 1, total_sockets: 1)
    vm = golden_vm(vm_host, location_id: location.id)

    params = vm.reload.params_json(ch_version: "46.0", firmware_version: "202311")
    expect(params).to eq GoldenFixture.read("params_json_ch_byoh.json", params)
  end

  {"2901" => [true, "params_json_qemu_gpu.json"], "3182" => [false, "params_json_qemu_gpu_nohugepages.json"]}.each do |device, (hugepages, fixture)|
    it "writes the same params for a QEMU+KVM VM with GPU device #{device}, hugepages #{hugepages}" do
      vm_host = create_vm_host(total_cpus: 8, total_cores: 4, total_dies: 1, total_sockets: 1)
      vm = golden_vm(vm_host, location_id: Location::HETZNER_FSN1_ID)
      PciDevice.create(vm_host_id: vm_host.id, vm_id: vm.id, slot: "c1:00.0", device_class: "0302", vendor: "10de", device:, numa_node: 0, iommu_group: 17)

      params = vm.reload.params_json(swap_size_bytes: nil, ch_version: "46.0", firmware_version: "202311", hugepages:)
      expect(JSON.parse(params)["hypervisor"]).to eq "qemu"
      expect(params).to eq GoldenFixture.read(fixture, params)
    end
  end
end
