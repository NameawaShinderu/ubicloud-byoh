# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "byoh_fake_root_login"

# Phase 6 end-to-end integration. Each example registers a BYOH host via
# the real CLI entry point (ByohRegistration), then exercises a full
# production code path that was previously only tested in isolation:
#
#   • strand label walk — assemble → start → setup_ssh_keys → bootstrap_rhizome.
#     Verifies the Phase 1-5 composition works end-to-end via the real Prog
#     dispatcher pattern (no mocks of setup_ssh_keys itself).
#
#   • vm_host.hardware_reset integration — exercises the full chain from
#     model/vm_host.rb → HostProvider#api (Hosting::ProviderApis.for)
#     → Hosting::GenericApis#hardware_reset → Hosting::RedfishClient#power_reset → wire.
#     Excon stubs stand in for a real BMC but the code path is 100% production.
RSpec.describe ByohRegistration, "end_to_end" do
  include ByohFakeRootLogin

  let(:location) {
    Location.create(name: "byoh-e2e", display_name: "byoh-e2e", ui_name: "BYOH e2e", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:1:2::/48"})
  }
  let(:base_reg) {
    described_class.new(
      location:,
      main_ip: "203.0.113.42",
      routed_networks: ["10.99.0.0/29", "fd00:feed::/64"],
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
      described_class.new(
        location:,
        main_ip: "203.0.113.99",
        routed_networks: ["10.100.0.0/29", "fd00:beef::/64"],
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test",
          "username" => "admin",
          "password" => "s3cret",
          "verify_ssl" => false,
          "system_id" => "1",
        },
      ).register!
    }
    let(:vm_host) { VmHost[strand.id] }

    it "drives the full model → ProviderApis → GenericApis → RedfishClient chain on a live DB record" do
      # Stub the Redfish wire as if a real BMC were answering.
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get},
        {status: 200, body: {
          "Actions" => {
            "#ComputerSystem.Reset" => {
              "target" => "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
            },
          },
        }.to_json})

      captured_body = nil
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          captured_body = JSON.parse(req[:body])
          {status: 204, body: ""}
        },
      )

      # This is the exact call production makes from prog/vm/host_nexus.rb
      # hardware_reset label → vm_host.hardware_reset → provider.api.hardware_reset.
      expect { vm_host.hardware_reset }.not_to raise_error
      expect(captured_body).to eq("ResetType" => "ForceRestart")
    end

    it "honors bmc.reset_type override through the full chain" do
      # Re-register with a different reset_type and verify it propagates all
      # the way to the HTTP body.
      st = described_class.new(
        location:,
        main_ip: "203.0.113.88",
        routed_networks: ["10.101.0.0/29", "fd00:cafe::/64"],
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test-2",
          "username" => "admin",
          "password" => "s3cret",
          "verify_ssl" => false,
          "system_id" => "Self",
          "reset_type" => "PowerCycle",
        },
      ).register!
      vmh = VmHost[st.id]

      Excon.stub({path: "/redfish/v1/Systems/Self", method: :get},
        {status: 200, body: {
          "Actions" => {"#ComputerSystem.Reset" => {"target" => "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}},
        }.to_json})

      captured_body = nil
      Excon.stub(
        {path: "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          captured_body = JSON.parse(req[:body])
          {status: 202, body: ""}
        },
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
      strand = described_class.new(
        location:,
        main_ip: "203.0.113.77",
        routed_networks: ["10.102.0.0/29", "fd00:dead::/64"],
        bmc_config: {
          "protocol" => "redfish",
          "endpoint" => "https://bmc-under-test-3",
          "username" => "admin",
          "password" => "s3cret",
        },
      ).register!

      expect { VmHost[strand.id].reimage }
        .to raise_error(Hosting::CapabilityMissing, /does not support automated reimage/)
    end
  end

  describe "a bare IPv4 routed network" do
    it "registers it as a /32 pool, with net6 from the location" do
      strand = described_class.new(main_ip: "203.0.113.88", location:, routed_networks: ["198.51.100.5"]).register!
      vm_host = VmHost[strand.id]
      expect(vm_host.assigned_subnets.map { it.cidr.to_s }.sort).to eq(["198.51.100.5/32", "203.0.113.88/32"])
      # Without an IPv6 pool, net6 is a /64 of the location's ula48.
      expect(vm_host.net6.netmask.prefix_len).to eq 64
      expect(ByohNetworkProfile.covers?(NetAddr::IPv6Net.parse("fd00:1:2::/48"), vm_host.net6)).to be true
      expect(vm_host.ipv6_mode).to eq "ula"
    end
  end

  describe "preflight, then registration" do
    it "downloads ubuntu-noble, and pins the host keys the preflight login met for the first root login" do
      key_path = File.join(Dir.mktmpdir, "byoh_key")
      File.write(key_path, SshKey.generate.private_key)
      reg = described_class.new(location:, main_ip: "203.0.113.10", routed_networks: ["fd00:feed::/64"], ssh_key_source: key_path)
      report = reg.preflight(starter: fake_root_starter(channels: preflight_channels(preflight_fixture("base"))), nonce: "f1x7ure", services: nil)
      expect(report).not_to be_blocking

      strand = reg.register!
      vm_host = VmHost[strand.id]
      expect(strand.stack.first).to include("default_boot_images" => ["ubuntu-noble"], "pin_host_keys" => true)
      expect(vm_host.sshable.host_keys).to eq [ByohFakeRootLogin::FIXTURE_HOST_KEY]
      expect(vm_host.provider.config["uplink_ip"]).to eq "203.0.113.10"
    ensure
      FileUtils.rm_rf(File.dirname(key_path))
    end
  end
end
