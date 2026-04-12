# frozen_string_literal: true

require_relative "../model/spec_helper"

# Phase 6 end-to-end integration. Each example registers a BYOH host via
# the real CLI entry point (ByohRegistration), then exercises a full
# production code path that was previously only tested in isolation:
#
#   • strand label walk — assemble → start → setup_ssh_keys → bootstrap_rhizome.
#     Verifies the Phase 1-5 composition works end-to-end via the real Prog
#     dispatcher pattern (no mocks of setup_ssh_keys itself).
#
#   • vm_host.hardware_reset integration — exercises the full chain from
#     model/vm_host.rb → Hosting::Apis.hardware_reset_server → HostProvider#api
#     → Hosting::GenericApis#reset → Hosting::RedfishClient#power_reset → wire.
#     Excon stubs stand in for a real BMC but the code path is 100% production.
RSpec.describe "BYOH end-to-end integration" do
  let(:base_reg) {
    ByohRegistration.new(
      main_ip: "203.0.113.42",
      routed_networks: ["10.99.0.0/29", "fd00:feed::/64"],
      location_label: "byoh-e2e-test"
    )
  }

  describe "strand label walk after ByohRegistration#register!" do
    let(:strand) { base_reg.register! }
    let(:vm_host) { VmHost[strand.id] }
    let(:sshable) { vm_host.sshable }
    let(:nx) { Prog::Vm::HostNexus.new(strand) }

    before do
      # Phase 1-5 preconditions — verify assemble produced the expected DB state.
      expect(vm_host.provider_name).to eq("generic")
      expect(vm_host.net6.to_s).to eq("fd00:feed::/64")
      expect(sshable.raw_private_key_1).not_to be_nil
      expect(vm_host.assigned_subnets.map { it.cidr.to_s }.sort).to eq(["10.99.0.0/29", "203.0.113.42/32"].sort)
    end

    it "runs start → setup_ssh_keys → bootstrap_rhizome without any SSH side effects" do
      # start: no-op hop
      expect { nx.start }.to hop("setup_ssh_keys")

      # setup_ssh_keys: the Phase 3 guard MUST skip the Hetzner bootstrap because
      # provider_name == "generic". Net::SSH must never be called even with
      # hetzner_ssh_private_key set globally.
      allow(Config).to receive(:hetzner_ssh_private_key).and_return(SshKey.generate.private_key)
      expect(Net::SSH).not_to receive(:start)
      expect(Util).not_to receive(:rootish_ssh)

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")

      # sshable.raw_private_key_1 is still the operator-provided key, not a fresh
      # auto-generated one (Phase 5: assemble pre-loaded it, setup_ssh_keys's
      # "generate if nil" branch must not have fired).
      expect(sshable.reload.raw_private_key_1).to eq(base_reg.keypair)
    end
  end

  describe "vm_host.hardware_reset → Redfish wire" do
    let(:strand) {
      ByohRegistration.new(
        main_ip: "203.0.113.99",
        routed_networks: ["10.100.0.0/29", "fd00:beef::/64"],
        location_label: "byoh-reset-test",
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test",
          "username" => "admin",
          "password" => "s3cret",
          "verify_ssl" => false,
          "system_id" => "1"
        }
      ).register!
    }
    let(:vm_host) { VmHost[strand.id] }

    it "drives the full model → Hosting::Apis → GenericApis → RedfishClient chain on a live DB record" do
      # Stub the Redfish wire as if a real BMC were answering.
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get},
        {status: 200, body: {
          "Actions" => {
            "#ComputerSystem.Reset" => {
              "target" => "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"
            }
          }
        }.to_json})

      captured_body = nil
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          captured_body = JSON.parse(req[:body])
          {status: 204, body: ""}
        }
      )

      # This is the exact call production makes from prog/vm/host_nexus.rb
      # hardware_reset label → vm_host.hardware_reset → Hosting::Apis.hardware_reset_server.
      expect { vm_host.hardware_reset }.not_to raise_error
      expect(captured_body).to eq("ResetType" => "ForceRestart")
    end

    it "honors bmc.reset_type override through the full chain" do
      # Re-register with a different reset_type and verify it propagates all
      # the way to the HTTP body.
      st = ByohRegistration.new(
        main_ip: "203.0.113.88",
        routed_networks: ["10.101.0.0/29", "fd00:cafe::/64"],
        location_label: "byoh-reset-test-2",
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test-2",
          "username" => "admin",
          "password" => "s3cret",
          "verify_ssl" => false,
          "system_id" => "Self",
          "reset_type" => "PowerCycle"
        }
      ).register!
      vmh = VmHost[st.id]

      Excon.stub({path: "/redfish/v1/Systems/Self", method: :get},
        {status: 200, body: {
          "Actions" => {"#ComputerSystem.Reset" => {"target" => "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}}
        }.to_json})

      captured_body = nil
      Excon.stub(
        {path: "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset", method: :post},
        ->(req) { captured_body = JSON.parse(req[:body]); {status: 202, body: ""} }
      )

      vmh.hardware_reset
      expect(captured_body).to eq("ResetType" => "PowerCycle")
    end

    it "propagates Excon errors when the BMC is unreachable — strand machinery retries" do
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get},
        {status: 500, body: "Internal Server Error"})

      # The prog label would catch this and nap; at this layer we just verify
      # the chain surfaces the error rather than silently swallowing it.
      expect { vm_host.hardware_reset }.to raise_error(Excon::Error::InternalServerError)
    end
  end

  describe "vm_host.reimage — stays CapabilityMissing for BYOH (PXE infra absent)" do
    it "raises CapabilityMissing when reimage is attempted on a generic host" do
      allow(Config).to receive(:development?).and_return(true)
      strand = ByohRegistration.new(
        main_ip: "203.0.113.77",
        routed_networks: ["10.102.0.0/29", "fd00:dead::/64"],
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test-3",
          "username" => "admin",
          "password" => "s3cret"
        }
      ).register!

      expect { VmHost[strand.id].reimage }
        .to raise_error(Hosting::CapabilityMissing, /does not support automated reimage/)
    end
  end

  describe "capabilities exposure after registration" do
    it "advertises :ip_pull always and :hw_reset when BMC is configured" do
      strand = ByohRegistration.new(
        main_ip: "203.0.113.66",
        routed_networks: ["10.103.0.0/29", "fd00:babe::/64"],
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test-4",
          "username" => "admin",
          "password" => "s3cret"
        }
      ).register!

      caps = VmHost[strand.id].provider.api.capabilities
      expect(caps).to include(:ip_pull)
      expect(caps).to include(:hw_reset)
      expect(caps).not_to include(:reimage)
    end

    it "advertises only :ip_pull when no BMC is configured" do
      strand = ByohRegistration.new(
        main_ip: "203.0.113.55",
        routed_networks: ["10.104.0.0/29", "fd00:feed:1::/64"]
      ).register!

      caps = VmHost[strand.id].provider.api.capabilities
      expect(caps).to eq(Set.new([:ip_pull]))
    end
  end
end
