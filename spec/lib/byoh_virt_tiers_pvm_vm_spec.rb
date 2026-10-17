# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../golden_fixture"

# PVM VMs on the control plane (docs/byoh/NO_KVM.md section 6.7): which
# guest kernel each boots, the prep.json that tells rhizome to boot it
# directly, and a new pin applied at the VM's next start (section 6.8).
# The KVM, container and emulated paths stay pinned by their goldens.
RSpec.describe ByohVirtTiers do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48", cp_reach: "public") }
  let(:project) { Project.create(name: "pvm-project") }
  let(:pin_sha) { pvm_test_pins.dig("guest_kernel", "sha256") }
  let(:old_sha) { "c" * 64 }
  let(:vm_host) { create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm", total_cpus: 4, total_cores: 4, total_dies: 1, total_sockets: 1) }

  before do
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins}))
  end

  def guest_kernel(sha, state: "ready", updated_at: Time.now, console: "hvc0")
    ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: sha, state:, release: "6.12.33-pvm", console:, config_checked: true, updated_at:)
  end

  describe ".pvm_guest_kernel" do
    it "gives the location's pin once the host holds it ready" do
      guest_kernel(old_sha, updated_at: Time.now + 60)
      guest_kernel(pin_sha)
      expect(described_class.pvm_guest_kernel(vm_host).sha256).to eq pin_sha
    end

    it "gives the host's newest ready kernel while the pin is not ready" do
      guest_kernel("d" * 64, updated_at: Time.now - 60)
      guest_kernel(old_sha)
      guest_kernel(pin_sha, state: "downloading", console: nil)
      expect(described_class.pvm_guest_kernel(vm_host).sha256).to eq old_sha
    end

    it "gives the newest ready kernel in a location without pins, and nil when none is ready" do
      guest_kernel(pin_sha, state: "refused", console: nil)
      expect(described_class.pvm_guest_kernel(vm_host)).to be_nil
      location.update(byoh_virt: nil)
      guest_kernel(old_sha)
      expect(described_class.pvm_guest_kernel(vm_host.reload).sha256).to eq old_sha
    end
  end

  it "keeps rhizome's oldest cloud-hypervisor for PVM VMs" do
    expect(File.read("rhizome/host/lib/vm_setup.rb")[/^  PVM_MIN_CH = "([^"]+)"$/, 1]).to eq described_class::PVM_MIN_CH
    # pvm_os_ok? stands for the host's cloud-hypervisor: rhizome adds
    # 46.0 (PVM_MIN_CH) only from this Ubuntu major on.
    ch = File.read("rhizome/host/lib/cloud_hypervisor.rb")
    gate = Regexp.new("^    if ubuntu_version >= (\\d+)$\\n      SUPPORTED\\[\"#{Regexp.escape(described_class::PVM_MIN_CH)}\"\\]")
    expect(ch[gate, 1]).to eq described_class::PVM_MIN_UBUNTU.split(".").first
  end

  describe "a PVM VM" do
    let(:vm) {
      ps = PrivateSubnet.create(name: "golden-ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", project_id: project.id)
      vm = Vm.create_with_id("2464de61-7501-8374-9ab0-416caebe31da",
        name: "golden-vm", unix_user: "ubi", public_key: "ssh-ed25519 AAAAgolden", boot_image: "ubuntu-noble",
        family: "pvm", cores: 1, vcpus: 2, memory_gib: 8, cpu_percent_limit: 200, cpu_burst_percent_limit: 0,
        arch: "x64", location_id: location.id, project_id: project.id, vm_host_id: vm_host.id, created_at: Time.now,
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
      Strand.create_with_id(vm.id, prog: "Vm::Metal::Nexus", label: "start")
      vm
    }
    let(:sshable) { vm_host.sshable }

    def vm_kernel = ByohVmGuestKernel[vm.id]

    it "sends prep.json for a direct kernel boot without hugepages or firmware, whatever the frame says" do
      ByohVmGuestKernel.create(vm_id: vm.id, sha256: pin_sha, release: "6.12.33-pvm", console: "hvc0")
      params = vm.reload.params_json(hugepages: true, firmware_version: "202311")
      expect(JSON.parse(params).slice("hypervisor", "hugepages", "ch_version", "firmware_version", "pvm")).to eq({
        "hypervisor" => "ch", "hugepages" => false, "ch_version" => nil, "firmware_version" => nil,
        "pvm" => {"kernel_sha256" => pin_sha, "root" => "/dev/vda1"},
      })
      expect(params).to eq GoldenFixture.read("params_json_pvm.json", params)
    end

    it "refuses prep.json for a VM without a recorded guest kernel" do
      expect { vm.params_json }.to raise_error(RuntimeError, "BUG: #{vm.ubid} has no PVM guest kernel recorded")
    end

    it "refuses prep.json for an image the guest kernel cannot boot" do
      ByohVmGuestKernel.create(vm_id: vm.id, sha256: pin_sha, console: "hvc0")
      vm.update(boot_image: "ubuntu-jammy")
      expect { vm.params_json }.to raise_error(described_class::Refused, "pvm VMs boot ubuntu-noble only (direct kernel boot), not ubuntu-jammy")
    end

    it "reads the serial log where KVM VMs keep theirs, whichever console the guest has" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo tail -c :max_bytes /vm/:vm_name/serial.log", max_bytes: RunCommand::MAX_OUTPUT_BYTES, vm_name: vm.inhost_name).and_return("login:")
      expect(vm.send(:metal_fetch_serial_log)).to eq "login:"
    end

    describe "Prog::Vm::Metal::Nexus" do
      subject(:nx) {
        Prog::Vm::Metal::Nexus.new(vm.strand).tap {
          it.instance_variable_set(:@vm, vm)
          it.instance_variable_set(:@host, vm_host)
        }
      }

      def expect_params_written
        expect(sshable).to receive(:_cmd).with("sudo -u #{vm.inhost_name} tee /vm/#{vm.inhost_name}/prep.json > /dev/null", hash_including(log: :on_error)) { |_, stdin:, **|
          expect(JSON.parse(stdin).dig("pvm", "kernel_sha256")).to eq vm_kernel.sha256
        }
      end

      it "creates the unix user in the kvm group, as on KVM hosts" do
        expect(nx).to receive(:rand).and_return(1111)
        expect(sshable).to receive(:_cmd) { |cmd, **| expect(cmd).to eq GoldenFixture.read("create_unix_user.sh", cmd) }
        expect { nx.create_unix_user }.to hop("create_billing_record")
      end

      it "records the host's guest kernel for the VM before writing its prep.json" do
        guest_kernel(pin_sha, console: "ttyS0")
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_#{vm.inhost_name}").and_return("NotStarted")
        expect_params_written
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ host/bin/setup-vm\\ prep\\ #{vm.inhost_name} prep_#{vm.inhost_name}", hash_including(log: :on_error))
        expect { nx.prep }.to nap(1)
        expect(vm_kernel.values).to eq(vm_id: vm.id, sha256: pin_sha, release: "6.12.33-pvm", console: "ttyS0")
      end

      it "moves the VM to the host's kernel again when prep runs again" do
        ByohVmGuestKernel.create(vm_id: vm.id, sha256: old_sha, console: "hvc0")
        guest_kernel(pin_sha)
        expect_params_written
        nx.write_params_json(pvm_kernel: true)
        expect(vm_kernel.sha256).to eq pin_sha
      end

      it "keeps the VM's kernel when other steps write its prep.json" do
        ByohVmGuestKernel.create(vm_id: vm.id, sha256: old_sha, console: "hvc0")
        guest_kernel(pin_sha)
        expect_params_written
        nx.write_params_json
        expect(vm_kernel.sha256).to eq old_sha
      end

      it "records a kernel for a VM without one whatever step writes its prep.json" do
        guest_kernel(pin_sha)
        expect_params_written
        nx.write_params_json
        expect(vm_kernel.sha256).to eq pin_sha
      end

      it "refuses a host that holds no ready guest kernel" do
        guest_kernel(pin_sha, state: "downloading", console: nil)
        expect { nx.write_params_json }.to raise_error(RuntimeError, "host #{vm_host.ubid} holds no ready PVM guest kernel")
        expect(vm_kernel).to be_nil
      end

      describe "#start_after_stop" do
        before { vm.incr_start }

        it "starts a VM on its kernel through rhizome, which checks the host first" do
          ByohVmGuestKernel.create(vm_id: vm.id, sha256: pin_sha, console: "hvc0")
          guest_kernel(pin_sha)
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm start #{vm.inhost_name}")
          expect { nx.start_after_stop }.to nap(5)
            .and change { vm.start_set?(cached: false) }.from(true).to(false)
        end

        it "applies a new guest kernel pin before starting the VM" do
          ByohVmGuestKernel.create(vm_id: vm.id, sha256: old_sha, console: "hvc0")
          guest_kernel(old_sha, updated_at: Time.now - 60)
          guest_kernel(pin_sha, console: "ttyS0")
          expect_params_written
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm reinstall-systemd-units #{vm.inhost_name}").ordered
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm start #{vm.inhost_name}").ordered
          expect { nx.start_after_stop }.to nap(5)
          expect(vm_kernel.values.slice(:sha256, :console)).to eq(sha256: pin_sha, console: "ttyS0")
        end

        it "wakes the host's wait, which resolves the stale guest kernel page" do
          host_strand = Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "wait", stack: [{}], schedule: Time.now + 6 * 60 * 60)
          ByohVmGuestKernel.create(vm_id: vm.id, sha256: old_sha, console: "hvc0")
          guest_kernel(old_sha, updated_at: Time.now - 60)
          guest_kernel(pin_sha, console: "ttyS0")
          expect_params_written
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm reinstall-systemd-units #{vm.inhost_name}")
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm start #{vm.inhost_name}")
          expect { nx.start_after_stop }.to nap(5)
          expect(host_strand.reload.schedule).to be <= Time.now
        end

        it "records a kernel for a VM that has none before starting it" do
          guest_kernel(pin_sha)
          expect_params_written
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm reinstall-systemd-units #{vm.inhost_name}").ordered
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm start #{vm.inhost_name}").ordered
          expect { nx.start_after_stop }.to nap(5)
          expect(vm_kernel.sha256).to eq pin_sha
        end

        it "keeps the VM's kernel while the host holds none ready" do
          ByohVmGuestKernel.create(vm_id: vm.id, sha256: old_sha, console: "hvc0")
          expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm start #{vm.inhost_name}")
          expect { nx.start_after_stop }.to nap(5)
          expect(vm_kernel.sha256).to eq old_sha
        end
      end
    end

    describe "allocation" do
      let(:vol) { [{"size_gib" => 10, "use_bdev_ubi" => false, "encrypted" => false, "boot" => true, "vring_workers" => 1, "track_written" => false}] }
      let(:new_vm) {
        Vm.create(name: "vm-pvm", unix_user: "ubi", public_key: "ssh key", boot_image: "ubuntu-noble", location_id: location.id,
          project_id: project.id, arch: "x64", family: "pvm", cores: 0, vcpus: 2, cpu_percent_limit: 200, cpu_burst_percent_limit: 0, memory_gib: 4).tap {
          it.create_storage_volumes(vol.map { |v| v.transform_keys(&:to_sym) })
        }
      }

      before do
        vm_host.update(total_mem_gib: 64, total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2, accepts_slices: false)
        BootImage.create(name: "ubuntu-noble", version: "20250502.1", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 3)
        StorageDevice.create(vm_host_id: vm_host.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 120)
        create_vhost_block_backend(vm_host_id: vm_host.id, version: "v0.4.2")
        (0..15).each { VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: it, io: false) }
      end

      it "refuses a PVM host that holds no ready guest kernel" do
        guest_kernel(pin_sha, state: "downloading", console: nil)
        expect { Scheduling::Allocator.allocate(new_vm, vol, family_filter: ["pvm"]) }.to raise_error(Scheduling::Allocator::NoSpaceLeft)
        expect { Scheduling::Allocator.allocate(new_vm, vol, host_filter: [vm_host.id]) }.to raise_error(Scheduling::Allocator::NoSpaceLeft)
      end

      it "places a PVM VM on a PVM host with a ready guest kernel" do
        guest_kernel(old_sha)
        Scheduling::Allocator.allocate(new_vm, vol, family_filter: ["pvm"])
        expect(new_vm.reload.vm_host_id).to eq vm_host.id
      end
    end
  end
end
