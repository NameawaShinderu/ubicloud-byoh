# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../golden_fixture"

# The control-plane side of emulated hosts, the last rung of the
# virtualization ladder (docs/byoh/NO_KVM.md section 8): what an emulated
# host and its VMs get that KVM ones never do. The KVM paths are pinned
# by the goldens of WP2 (prog/vm/metal/nexus_golden_spec.rb among them).
RSpec.describe ByohVirtTiers do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48", cp_reach: "public") }
  let(:project) { Project.create(name: "emulated-project") }

  def offer
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm emulated], "acks" => {"emulated" => []}}))
  end

  describe "the tier" do
    it "runs QEMU, not cloud-hypervisor, and waits longer than KVM hosts" do
      expect(described_class.fetch("emulated").hypervisor).to eq "qemu"
      expect(%w[kvm pvm].map { described_class.runs_cloud_hypervisor?(it) }).to eq [true, true]
      expect(%w[container emulated].map { described_class.runs_cloud_hypervisor?(it) }).to eq [false, false]
      expect(%i[start_deadline netns_probe soft_stop].map { described_class.slow_timing("emulated", it) }).to eq [1800, 1680, 180]
      %w[kvm container pvm].each { expect(described_class.slow_timing(it, :soft_stop)).to be_nil }
    end

    it "has small sizes of 1 GiB per vCPU, and the other tiers keep 4 GiB" do
      sizes = Option::TierVmSizes.to_h { [it.name, [it.family, it.vcpus, it.memory_gib, it.arch]] }
      expect(sizes.slice("emulated-2", "emulated-4")).to eq("emulated-2" => ["emulated", 2, 2, "x64"], "emulated-4" => ["emulated", 4, 4, "x64"])
      expect(sizes["container-2"]).to eq ["container", 2, 8, "x64"]
    end
  end

  describe "Prog::Vm::Nexus.assemble" do
    before do
      project.set_ff_visible_locations([location.name])
      allow(BillingRate).to receive(:from_resource_properties).and_call_original
      %w[VmVCpu VmStorage].each { allow(BillingRate).to receive(:from_resource_properties).with(it, "emulated", location.name).and_return({"id" => "rate"}) }
      offer
    end

    def assemble(**)
      Prog::Vm::Nexus.assemble("ssh-ed25519 key", project.id, size: "emulated-2", location_id: location.id, allowed_tiers: %w[kvm emulated], **)
    end

    it "creates an emulated VM without hugepages from a stock cloud image" do
      st = assemble(boot_image: "ubuntu-jammy", storage_volumes: [{size_gib: 40}, {size_gib: 10}])
      expect(st.subject.values.slice(:family, :vcpus, :memory_gib)).to eq(family: "emulated", vcpus: 2, memory_gib: 2)
      expect(st.stack.first["hugepages"]).to be false
      expect(st.subject.vm_storage_volumes.size).to eq 2
    end

    it "refuses GPUs and container images" do
      expect { assemble(gpu_count: 1) }
        .to raise_error(Validation::ValidationFailed) { expect(it.details[:size]).to eq "emulated VMs cannot have GPUs" }
      expect { assemble(boot_image: "ubuntu-noble-container") }
        .to raise_error(Validation::ValidationFailed) { expect(it.details[:size]).to eq "emulated VMs can only boot ubuntu-noble, ubuntu-jammy" }
    end
  end

  describe "an emulated host" do
    let(:vm_host) { create_byoh_vm_host(location, virt_tier: "emulated", family: "emulated", total_cpus: 4, total_cores: 4, total_dies: 1, total_sockets: 1) }
    let(:vm) {
      ps = PrivateSubnet.create(name: "golden-ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", project_id: project.id)
      vm = Vm.create_with_id("2464de61-7501-8374-9ab0-416caebe31da",
        name: "golden-vm", unix_user: "ubi", public_key: "ssh-ed25519 AAAAgolden", boot_image: "ubuntu-noble",
        family: "emulated", cores: 1, vcpus: 2, memory_gib: 2, cpu_percent_limit: 200, cpu_burst_percent_limit: 0,
        arch: "x64", location_id: location.id, project_id: project.id, vm_host_id: vm_host.id, created_at: Time.now,
        ephemeral_net6: "2a01:4f8:10a:128b:3bfa::/79", local_vetho_ip: "169.254.0.5/32")
      Nic.create_with_id("7f3b5a5e-2a8c-8a72-a4a3-2b0b6c6b6f11", private_subnet_id: ps.id, vm_id: vm.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::/79", private_ipv4: "10.0.0.5/32", mac: "52:54:00:12:34:56",
        name: "golden-nic", state: "active")
      sd = StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 60)
      bi = BootImage.create(name: "ubuntu-noble", version: "20250502.1", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 3)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 40, disk_index: 0, storage_device_id: sd.id,
        boot_image_id: bi.id, key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "golden").id)
      Strand.create_with_id(vm.id, prog: "Vm::Metal::Nexus", label: "start")
      vm
    }
    let(:sshable) { vm_host.sshable }

    before { offer }

    it "sends prep.json for QEMU under tcg without hugepages, whatever the frame says" do
      params = vm.reload.params_json(hugepages: true)
      expect(JSON.parse(params).slice("hypervisor", "accel", "hugepages", "ch_version", "firmware_version")).to eq({
        "hypervisor" => "qemu", "accel" => "tcg", "hugepages" => false, "ch_version" => nil, "firmware_version" => nil,
      })
      expect(params).to eq GoldenFixture.read("params_json_emulated.json", params)
    end

    it "reads the serial log where KVM VMs keep theirs" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo tail -c :max_bytes /vm/:vm_name/serial.log", max_bytes: RunCommand::MAX_OUTPUT_BYTES, vm_name: vm.inhost_name).and_return("boot")
      expect(vm.send(:metal_fetch_serial_log)).to eq "boot"
    end

    it "learns QEMU as the hypervisor" do
      lh = Prog::LearnHypervisor.new(Strand.create(prog: "LearnHypervisor", label: "start", stack: [{"subject_id" => vm.id}]))
      expect(lh.vm.vm_host.sshable).to receive(:_cmd).with("sudo cat /etc/systemd/system/#{vm.inhost_name}.service")
        .and_return(File.read("rhizome/host/spec/fixtures/qemu_tcg/tcg_unit.service"))
      expect { lh.start }.to exit({"msg" => "learned qemu for #{vm}"})
      expect(vm.reload.hypervisor).to eq Hypervisor.first(name: "qemu")
    end

    describe "Prog::Vm::Metal::Nexus" do
      subject(:nx) {
        Prog::Vm::Metal::Nexus.new(vm.strand).tap {
          it.instance_variable_set(:@vm, vm)
          it.instance_variable_set(:@host, vm_host)
        }
      }

      let(:st) { vm.strand }

      it "creates the unix user with a root-owned home and without the kvm group" do
        expect(nx).to receive(:rand).and_return(1111)
        command = nil
        expect(sshable).to receive(:_cmd) { |cmd, **kw|
          expect(kw).to eq(log: :on_error)
          command = cmd
        }
        expect { nx.create_unix_user }.to hop("create_billing_record")
        expect(command).to eq GoldenFixture.read("create_unix_user_emulated.sh", command)
        expect(command).to include("sudo install -d -o root -g #{vm.inhost_name} -m 0750 /vm/#{vm.inhost_name}\n")
        expect(command).not_to include("kvm")
        expect(command).not_to include("userdel -r")
      end

      it "writes prep.json as root, into the root-owned home" do
        expect(sshable).to receive(:cmd).with("sudo tee :params_path > /dev/null", vm_name: vm.inhost_name, params_path: "/vm/#{vm.inhost_name}/prep.json", stdin: vm.params_json, log: :on_error)
        nx.write_params_json
      end

      it "gives a newly allocated VM 30 minutes to reach wait" do
        st.stack = [{"storage_volumes" => [{"use_bdev_ubi" => false, "size_gib" => 11, "boot" => true}]}]
        allow(Config).to receive(:machine_images_service_project_id).and_return(Project.create(name: "machine-images").id)
        expect(Scheduling::Allocator).to receive(:allocate)
        expect(nx).to receive(:register_deadline).with("wait", 1800, page: true)
        expect { nx.start }.to hop("create_unix_user")
      end

      describe "the network-namespace probe" do
        let(:probe_command) { "sudo timeout 3 ip netns exec #{vm.inhost_name} bash -c #{Shellwords.escape(":>/dev/tcp/10.0.0.5/22")}" }

        before { vm.incr_update_firewall_rules }

        it "still probes just before 28 minutes" do
          vm.update(allocated_at: Time.now - 1670)
          expect(sshable).to receive(:_cmd).with(probe_command, log: false).and_raise(Sshable::SshError.new(probe_command, "", "", 1, nil))
          expect { nx.wait_sshable }.to nap(5)
        end

        it "gives up after 28 minutes" do
          vm.update(allocated_at: Time.now - 1681)
          expect(sshable).not_to receive(:_cmd)
          expect { nx.wait_sshable }.to hop("wait")
        end
      end

      describe "a soft stop" do
        def stopping_since(seconds)
          now = Time.at(Time.now.to_i)
          Semaphore.create(name: "stopping", strand_id: st.id) do |sem|
            sem.id = UBID.generate_from_time(UBID::TYPE_SEMAPHORE, now - seconds).to_uuid
          end
          allow(Time).to receive(:now).and_return(now)
          expect(sshable).to receive(:_cmd).with("systemctl is-active #{vm.inhost_name} #{vm.inhost_name}-dnsmasq").and_return("active\nactive\n")
        end

        it "keeps powering a running VM down over QMP for exactly 180 seconds" do
          stopping_since(180)
          expect(sshable).to receive(:_cmd).with("sudo host/bin/stop-vm #{vm.inhost_name}").and_return("")
          expect { nx.stopped }.to nap(10)
        end

        it "stops a running VM hard 1 ms after 180 seconds" do
          stopping_since(180.001)
          expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{vm.inhost_name}").and_return("")
          expect { nx.stopped }.to nap(0)
        end
      end
    end

    describe "cloud-hypervisor downloads" do
      it "are refused, as on container hosts, and allowed on KVM hosts" do
        [vm_host, create_byoh_vm_host(location, virt_tier: "container", family: "container", net6: "fd00:9:9:9::/64")].each do |host|
          message = "#{host} is a #{host.virt_tier} host, which runs no cloud-hypervisor"
          expect { host.download_cloud_hypervisor(version_x64: "46.0") }.to raise_error(ArgumentError, message)
          expect { host.download_firmware(version_x64: "202311", sha256_x64: "x") }.to raise_error(ArgumentError, message)
          ch = Prog::DownloadCloudHypervisor.new(Strand.create(prog: "DownloadCloudHypervisor", label: "start", stack: [{"subject_id" => host.id, "version" => "46.0"}]))
          expect { ch.start }.to exit({"msg" => message})
          fw = Prog::DownloadFirmware.new(Strand.create(prog: "DownloadFirmware", label: "start", stack: [{"subject_id" => host.id, "version" => "202311", "sha256" => "x"}]))
          expect { fw.start }.to exit({"msg" => "#{message} firmware"})
        end
        kvm_host = create_vm_host
        expect(kvm_host.download_firmware(version_x64: "202311", sha256_x64: "x").prog).to eq "DownloadFirmware"
        expect(kvm_host.download_cloud_hypervisor(version_x64: "46.0", sha256_ch_bin_x64: "a", sha256_ch_remote_x64: "b").prog).to eq "DownloadCloudHypervisor"
      end
    end
  end

  describe "Prog::Vm::HostNexus.assemble" do
    let(:provider_config) { {"main_ip4" => "203.0.113.42", "location_label" => "x", "routed_networks" => [{"cidr" => "fd00:feed::/64"}]} }

    def assemble(**)
      Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME, provider_config:, virt_tier: "emulated", **)
    end

    it "downloads ubuntu-noble unless registration names other images of the tier" do
      offer
      expect { assemble(default_boot_images: %w[ubuntu-noble-container]) }
        .to raise_error(RuntimeError, "A emulated host cannot boot ubuntu-noble-container; its images are ubuntu-noble, ubuntu-jammy")
      expect(assemble.stack.first["default_boot_images"]).to eq %w[ubuntu-noble]
    end

    it "takes ubuntu-jammy when registration names it" do
      offer
      expect(assemble(default_boot_images: %w[ubuntu-noble ubuntu-jammy]).stack.first["default_boot_images"]).to eq %w[ubuntu-noble ubuntu-jammy]
    end
  end
end
