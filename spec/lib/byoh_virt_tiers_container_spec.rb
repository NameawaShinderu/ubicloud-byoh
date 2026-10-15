# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../golden_fixture"

# The control-plane side of system containers, the container tier of the
# virtualization ladder (docs/byoh/NO_KVM.md section 4.2): what a
# container host and its VMs get that KVM ones never do. The KVM paths
# are pinned by the goldens of WP2.
RSpec.describe ByohVirtTiers do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:project) { Project.create(name: "container-project") }

  def offer(acks)
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container], "acks" => {"container" => acks}}))
  end

  describe "location options" do
    it "encrypts container disks unless the location acknowledged unencrypted ones" do
      offer([])
      expect(described_class.container_disk_encrypted?(location)).to be true
      expect(described_class.container_options(location)).to eq({"nested_userns" => false, "guest_firewall" => false})
      offer(%w[unencrypted-disk nested-userns guest-firewall])
      expect(described_class.container_disk_encrypted?(location.reload)).to be false
      expect(described_class.container_options(location)).to eq({"nested_userns" => true, "guest_firewall" => true})
    end
  end

  describe "Prog::Vm::Nexus.assemble" do
    before do
      project.set_ff_visible_locations([location.name])
      allow(BillingRate).to receive(:from_resource_properties).and_call_original
      %w[VmVCpu VmStorage].each { allow(BillingRate).to receive(:from_resource_properties).with(it, "container", location.name).and_return({"id" => "rate"}) }
    end

    def assemble(**)
      Prog::Vm::Nexus.assemble("ssh-ed25519 key", project.id, size: "container-2", location_id: location.id, allowed_tiers: %w[kvm container],
        boot_image: "ubuntu-noble-container", **)
    end

    it "gives a container an encrypted disk, or a plain one where the location acknowledged that" do
      offer([])
      expect(assemble.subject.vm_storage_volumes.first.key_encryption_key_1).not_to be_nil
      offer(%w[unencrypted-disk])
      expect(assemble(name: "plain").subject.vm_storage_volumes.first.key_encryption_key_1).to be_nil
    end

    it "refuses a container with more than one disk" do
      offer([])
      expect { assemble(storage_volumes: [{size_gib: 40}, {size_gib: 40}]) }
        .to raise_error(Validation::ValidationFailed) { expect(it.details[:size]).to eq "container VMs have exactly one disk" }
    end
  end

  describe "a container host" do
    let(:vm_host) { create_byoh_vm_host(location, virt_tier: "container", family: "container", total_cpus: 4, total_cores: 4, total_dies: 1, total_sockets: 1) }
    let(:vm) {
      ps = PrivateSubnet.create(name: "golden-ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", project_id: project.id)
      vm = Vm.create_with_id("2464de61-7501-8374-9ab0-416caebe31da",
        name: "golden-vm", unix_user: "ubi", public_key: "ssh-ed25519 AAAAgolden", boot_image: "ubuntu-noble-container",
        family: "container", cores: 1, vcpus: 2, memory_gib: 8, cpu_percent_limit: 200, cpu_burst_percent_limit: 0,
        arch: "x64", location_id: location.id, project_id: project.id, vm_host_id: vm_host.id,
        ephemeral_net6: "2a01:4f8:10a:128b:3bfa::/79", local_vetho_ip: "169.254.0.5/32")
      Nic.create_with_id("7f3b5a5e-2a8c-8a72-a4a3-2b0b6c6b6f11", private_subnet_id: ps.id, vm_id: vm.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::/79", private_ipv4: "10.0.0.5/32", mac: "52:54:00:12:34:56",
        name: "golden-nic", state: "active")
      sd = StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 60)
      bi = BootImage.create(name: "ubuntu-noble-container", version: "20260926", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 1)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 40, disk_index: 0, storage_device_id: sd.id,
        boot_image_id: bi.id, key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "golden").id)
      vm
    }

    before { offer(%w[guest-firewall]) }

    it "sends prep.json with hypervisor lxc and the location's container options" do
      params = vm.reload.params_json(hugepages: false)
      expect(JSON.parse(params).slice("hypervisor", "container", "hugepages")).to eq({
        "hypervisor" => "lxc", "container" => {"nested_userns" => false, "guest_firewall" => true}, "hugepages" => false,
      })
      expect(params).to eq GoldenFixture.read("params_json_container.json", params)
    end

    it "reads the serial log from the container's console log" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo tail -c :max_bytes /var/lib/ubicloud/lxc/:vm_name/console.log", max_bytes: RunCommand::MAX_OUTPUT_BYTES, vm_name: vm.inhost_name).and_return("boot")
      expect(vm.send(:metal_fetch_serial_log)).to eq "boot"
    end

    it "learns no hypervisor" do
      lh = Prog::LearnHypervisor.new(Strand.create(prog: "LearnHypervisor", label: "start", stack: [{"subject_id" => vm.id}]))
      expect(vm.vm_host.sshable).not_to receive(:cmd)
      expect { lh.start }.to exit({"msg" => "#{vm} is a system container"})
    end
  end

  describe "Prog::Vm::HostNexus.assemble" do
    let(:provider_config) { {"main_ip4" => "203.0.113.42", "location_label" => "x", "routed_networks" => [{"cidr" => "fd00:feed::/64"}]} }

    def assemble(**)
      Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME, provider_config:, virt_tier: "container", **)
    end

    it "downloads the tier's boot images unless registration names some of them, and refuses others" do
      offer([])
      expect { assemble(default_boot_images: %w[ubuntu-noble-container ubuntu-noble]) }
        .to raise_error(RuntimeError, "A host of virt tier container cannot boot ubuntu-noble; its images are ubuntu-noble-container")
      expect(assemble.stack.first["default_boot_images"]).to eq %w[ubuntu-noble-container]
    end
  end

  describe "the container root tarball" do
    let(:st) { Strand.create(prog: "DownloadBootImage", label: "start", stack: [{"subject_id" => create_vm_host.id, "image_name" => "ubuntu-noble-container"}]) }
    let(:dbi) { Prog::DownloadBootImage.new(st) }

    it "comes from cloud-images.ubuntu.com with its checksum, even with production sources" do
      allow(Config).to receive(:production?).and_return(true)
      expect(dbi.download_from_blob_storage?).to be false
      expect(dbi.version).to eq "20260926"
      expect(dbi.url).to eq "https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-amd64-root.tar.xz"
      expect(dbi.sha256sum).to eq "820311e238ea34d76a8ca2643d6c01065212e9417109e7397d70472a236df261"
      expect(Prog::DownloadBootImage.upstream_url("ubuntu-noble-container", "20260926", "arm64")).to end_with "/ubuntu-24.04-server-cloudimg-arm64-root.tar.xz"
    end

    it "is kept as a tarball" do
      expect(BootImage.new(name: "ubuntu-noble-container", version: "20260926").path).to eq "/var/storage/images/ubuntu-noble-container-20260926.tar.xz"
      expect(BootImage.new(name: "ubuntu-noble", version: "20250502.1").path).to eq "/var/storage/images/ubuntu-noble-20250502.1.raw"
    end
  end
end
