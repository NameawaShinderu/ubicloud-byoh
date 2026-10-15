# frozen_string_literal: true

require_relative "../../../model/spec_helper"
require_relative "../../../golden_fixture"

# Freezes the host commands and timings a VM on a KVM host gets today, on a
# non-BYOH host and on a BYOH generic host alike.
RSpec.describe Prog::Vm::Metal::Nexus do
  subject(:nx) {
    described_class.new(vm.strand).tap {
      it.instance_variable_set(:@vm, vm)
      it.instance_variable_set(:@host, vm_host)
    }
  }

  let(:st) { vm.strand }
  let(:sshable) { vm_host.sshable }
  let(:project) { Project.create(name: "golden") }
  let(:byoh_location) { create_byoh_location(name: "byoh-golden", cp_reach: "public") }
  let(:vm_host) { create_vm_host }
  let(:vm) {
    vm = Vm.create_with_id("2464de61-7501-8374-9ab0-416caebe31da",
      name: "golden-vm", unix_user: "ubi", public_key: "ssh key", boot_image: "ubuntu-noble",
      family: "standard", cores: 1, vcpus: 2, cpu_percent_limit: 200, cpu_burst_percent_limit: 0, memory_gib: 8,
      arch: "x64", location_id: vm_host.location_id, created_at: Time.now, project_id: project.id, vm_host_id: vm_host.id)
    Strand.create_with_id(vm.id, prog: "Vm::Metal::Nexus", label: "start")
    vm
  }

  {"non-BYOH" => false, "BYOH generic" => true}.each do |kind, byoh|
    describe "on a #{kind} host" do
      let(:vm_host) { byoh ? create_byoh_vm_host(byoh_location) : create_vm_host }

      it "creates the VM's unix user with the same command" do
        expect(nx).to receive(:rand).and_return(1111)
        command = nil
        expect(sshable).to receive(:_cmd) { |cmd, **kw|
          expect(kw).to eq(log: :on_error)
          command = cmd
        }
        expect { nx.create_unix_user }.to hop("create_billing_record")
        expect(command).to eq GoldenFixture.read("create_unix_user.sh", command)
      end

      it "gives a newly allocated VM 10 minutes to reach wait" do
        st.stack = [{"storage_volumes" => [{"use_bdev_ubi" => false, "size_gib" => 11, "boot" => true}]}]
        allow(Config).to receive(:machine_images_service_project_id).and_return(Project.create(name: "machine-images").id)
        expect(Scheduling::Allocator).to receive(:allocate)
        expect(nx).to receive(:register_deadline).with("wait", 600, page: true)
        expect { nx.start }.to hop("create_unix_user")
      end

      # Time.now is frozen on a whole second, so the semaphore's
      # millisecond timestamp is exact and the boundary is pinned to the
      # millisecond on both sides.
      def stopping_since(seconds)
        now = Time.at(Time.now.to_i)
        Semaphore.create(name: "stopping", strand_id: st.id) do |sem|
          sem.id = UBID.generate_from_time(UBID::TYPE_SEMAPHORE, now - seconds).to_uuid
        end
        allow(Time).to receive(:now).and_return(now)
        expect(sshable).to receive(:_cmd).with("systemctl is-active #{vm.inhost_name} #{vm.inhost_name}-dnsmasq").and_return("active\nactive\n")
      end

      it "keeps soft-stopping a running VM for exactly 60 seconds" do
        stopping_since(60)
        expect(sshable).to receive(:_cmd).with("sudo host/bin/stop-vm #{vm.inhost_name}").and_return("")
        expect { nx.stopped }.to nap(10)
      end

      it "stops a running VM hard 1 ms after 60 seconds" do
        stopping_since(60.001)
        expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{vm.inhost_name}").and_return("")
        expect { nx.stopped }.to nap(0)
      end
    end
  end

  describe "the BYOH network-namespace probe" do
    let(:vm_host) { create_byoh_vm_host(byoh_location) }
    let(:nic) {
      ps = PrivateSubnet.create(name: "golden-ps", location_id: byoh_location.id, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", project_id: project.id)
      Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::", private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00", name: "golden-nic", state: "active", vm_id: vm.id)
    }
    let(:probe_command) { "sudo timeout 3 ip netns exec #{vm.inhost_name} bash -c #{Shellwords.escape(":>/dev/tcp/10.0.0.1/22")}" }

    before do
      nic
      vm.incr_update_firewall_rules
    end

    it "is 8 minutes long" do
      expect(described_class::NETNS_PROBE_SECONDS).to eq 480
    end

    it "still probes just before 8 minutes" do
      vm.update(allocated_at: Time.now - 470)
      expect(sshable).to receive(:_cmd).with(probe_command, log: false).and_raise(Sshable::SshError.new(probe_command, "", "", 1, nil))
      expect { nx.wait_sshable }.to nap(5)
    end

    it "gives up after 8 minutes" do
      vm.update(allocated_at: Time.now - 481)
      expect(sshable).not_to receive(:_cmd)
      expect { nx.wait_sshable }.to hop("wait")
    end
  end
end
