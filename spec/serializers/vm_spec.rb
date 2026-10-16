# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Vm do
  let(:vm) {
    project = Project.create(name: "test-project")
    vm_host = create_vm_host(location_id: Location::HETZNER_FSN1_ID)
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "test-vm", location_id: Location::HETZNER_FSN1_ID, enable_ip4: true, boot_image: "ubuntu-noble").subject
    vm.update(display_state: "running", vm_host_id: vm_host.id)
    vm.vm_storage_volumes.first.update(size_gib: 100)
    add_ipv4_to_vm(vm, "192.168.1.0")
    vm
  }

  def prepare_for_comparison(serialized)
    [:ip4, :ip6, :private_ipv4, :private_ipv6].each do |ip_field|
      serialized[ip_field] = serialized[ip_field].to_s if serialized[ip_field]
    end
    serialized
  end

  describe ".serialize_internal" do
    it "serializes a VM with no loadbalancer_vm_port correctly" do
      expected_result = {
        id: vm.ubid,
        name: "test-vm",
        boot_image: "ubuntu-noble",
        state: "running",
        location: "eu-central-h1",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: 100,
        ip6: nil,
        ip4_enabled: true,
        ip4: "192.168.1.0",
        maintenance_window_start_at: nil,
      }

      expect(prepare_for_comparison(described_class.serialize_internal(vm))).to eq(expected_result)
    end

    it "serializes a VM with GPU correctly" do
      PciDevice.create(vm_host_id: vm.vm_host_id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "20b5", numa_node: 0, iommu_group: 0)

      expected_result = {
        id: vm.ubid,
        name: "test-vm",
        boot_image: "ubuntu-noble",
        state: "running",
        location: "eu-central-h1",
        size: "standard-2",
        unix_user: "ubi",
        storage_size_gib: 100,
        ip6: nil,
        ip4_enabled: true,
        ip4: "192.168.1.0",
        maintenance_window_start_at: nil,
        firewalls: Serializers::Firewall.serialize(vm.firewalls, {include_path: true}),
        private_ipv4: vm.private_ipv4.to_s,
        private_ipv6: vm.private_ipv6.to_s,
        subnet: "default-eu-central-h1",
        gpu: "1x NVIDIA A100 80GB PCIe",
      }

      expect(prepare_for_comparison(described_class.serialize_internal(vm, {detailed: true}))).to eq(expected_result)
    end

    describe "on a BYOH host" do
      let(:location) { create_byoh_location }
      let(:byoh_vm) {
        vm = create_vm(name: "byoh-vm", location_id: location.id, ephemeral_net6: "fd10:1:2:3::/79")
        add_byoh_ipv4_to_vm(vm, create_byoh_vm_host(location, ipv6_mode: "ula"), "10.98.1.129", exposure: "nat", external_ip: "203.0.113.9")
      }

      it "shows the addresses customers reach the VM at" do
        serialized = described_class.serialize_internal(byoh_vm, {detailed: true})
        expect(serialized.slice(:ip6, :ip4, :ip4_scope, :ip4_internal).transform_values(&:to_s)).to eq(
          ip6: "", ip4: "203.0.113.9", ip4_scope: "public", ip4_internal: "10.98.1.129",
        )
        expect(serialized.keys.last).to eq :ip4_internal
      end

      it "shows an internal address with its scope and no internal address in the summary" do
        byoh_vm.assigned_vm_address.update(external_ip: nil)
        byoh_vm.assigned_vm_address.address.update(exposure: "internal")
        byoh_vm.vm_host.update(ipv6_mode: "gua")
        serialized = described_class.serialize_internal(byoh_vm.reload)
        expect(serialized.slice(:ip4, :ip4_scope).transform_values(&:to_s)).to eq(ip4: "10.98.1.129", ip4_scope: "internal")
        expect(serialized[:ip6].to_s).to eq byoh_vm.ip6_string
        expect(serialized).not_to have_key(:ip4_internal)
      end

      it "keeps the VM's own addresses on a generic host outside a BYOH location" do
        byoh_vm.vm_host.update(location_id: Location::HETZNER_FSN1_ID)
        byoh_vm.update(location_id: Location::HETZNER_FSN1_ID)
        serialized = described_class.serialize_internal(byoh_vm.reload, {detailed: true})
        expect([serialized[:ip4].to_s, serialized[:ip6].to_s]).to eq ["10.98.1.129", byoh_vm.ip6_string]
        expect(serialized.keys).not_to include(:ip4_scope, :ip4_internal)
      end
    end

    it "says what a lower-tier VM is, with the host kernel a container shares in the detailed view" do
      location = create_byoh_location(ula48: "fd00:1:2::/48")
      host = create_byoh_vm_host(location, virt_tier: "container", family: "container", net6: "fd00:1:2:3::/64", virt_probe: Sequel.pg_jsonb({"facts" => {"kernel" => "6.8.0-90-generic"}}))
      container = create_vm(family: "container", location_id: location.id, vm_host_id: host.id)
      described = {tier: "container", description: "System container: shared host kernel, near-native speed. Not a VM.", experimental: true}
      expect(described_class.serialize_internal(container)[:virt_tier]).to eq(described)
      expect(described_class.serialize_internal(container, {detailed: true})[:virt_tier]).to eq(described.merge(host_kernel: "6.8.0-90-generic"))
      emulated = create_vm(name: "emu", family: "emulated", location_id: location.id)
      expect(described_class.serialize_internal(emulated, {detailed: true})[:virt_tier]).to eq(tier: "emulated", description: "Emulated: slow, compatibility only. Not a security boundary.", experimental: true)
      expect(described_class.serialize_internal(vm, {detailed: true}).keys).not_to include(:virt_tier)
      # Without a host, or a host without a probe, there is no kernel to show.
      expect(create_vm(name: "unplaced", family: "container", location_id: location.id).shared_host_kernel).to be_nil
      host.update(virt_probe: nil)
      expect(described_class.serialize_internal(container.reload, {detailed: true})[:virt_tier]).to eq(described)
    end

    it "serializes a VM whose user_nic is gone (mid-destroy) without raising" do
      vm.user_nic.update(vm_id: nil)
      vm.reload

      serialized = described_class.serialize_internal(vm, {detailed: true})
      expect(serialized[:subnet]).to be_nil
    end
  end
end
