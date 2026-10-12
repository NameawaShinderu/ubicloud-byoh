# frozen_string_literal: true

RSpec.describe Hosting::GenericApis do
  let(:vmh) {
    vmh = create_vm_host
    vmh.sshable.update(host: "203.0.113.42")
    vmh
  }

  let(:routed_networks) {
    [
      {"cidr" => "203.0.113.40/29", "is_failover" => false},
      {"cidr" => "2001:db8:dead::/64", "is_failover" => false},
    ]
  }

  let(:config_hash) {
    {
      "main_ip4" => "203.0.113.42",
      "location_label" => "homelab-rack-A",
      "routed_networks" => routed_networks,
    }
  }

  let(:generic_host) {
    HostProvider.create do |hp|
      hp.id = vmh.id
      hp.server_identifier = "byoh-test-1"
      hp.provider_name = HostProvider::GENERIC_PROVIDER_NAME
      hp.config = config_hash
    end
  }

  let(:generic_apis) { described_class.new(generic_host) }

  describe "pull_ips" do
    it "returns only IPv4 entries from operator-declared routed networks (v6 is stored on vm_host.net6)" do
      result = generic_apis.pull_ips
      expect(result.map(&:ip_address)).to contain_exactly("203.0.113.40/29")
      expect(result[0]).to have_attributes(
        source_host_ip: "203.0.113.42",
        is_failover: false,
      )
    end

    it "auto-prepends the management IP as /32 when not covered by any declared block" do
      generic_host.update(config: {
        "main_ip4" => "203.0.113.42",
        "routed_networks" => [{"cidr" => "10.99.0.0/24"}],
      })
      result = described_class.new(generic_host.reload).pull_ips
      expect(result.map(&:ip_address)).to eq(["203.0.113.42/32", "10.99.0.0/24"])
    end

    it "does NOT prepend the management /32 when it's already inside a declared block" do
      generic_host.update(config: {
        "main_ip4" => "203.0.113.42",
        "routed_networks" => [{"cidr" => "203.0.113.40/29"}],
      })
      result = described_class.new(generic_host.reload).pull_ips
      expect(result.map(&:ip_address)).to eq(["203.0.113.40/29"])
    end

    it "returns just the auto-prepended management /32 when no routed networks are configured" do
      generic_host.update(config: {})
      result = described_class.new(generic_host.reload).pull_ips
      expect(result.map(&:ip_address)).to eq(["203.0.113.42/32"])
    end

    it "honors is_failover flag from config" do
      generic_host.update(config: {
        "main_ip4" => "203.0.113.42",
        "routed_networks" => [
          {"cidr" => "203.0.113.99/32", "is_failover" => true},
        ],
      })
      result = described_class.new(generic_host.reload).pull_ips
      failover = result.find { |r| r.ip_address == "203.0.113.99/32" }
      expect(failover.is_failover).to be(true)
    end

    it "uses sshable.host as source_host_ip regardless of what main_ip4 says" do
      generic_host.update(config: {"main_ip4" => "1.2.3.4", "routed_networks" => [{"cidr" => "10.0.0.0/29"}]})
      result = described_class.new(generic_host.reload).pull_ips
      expect(result.first.source_host_ip).to eq("203.0.113.42")
    end

    it "uses a per-network source_host_ip when the operator declared one" do
      generic_host.update(config: {"routed_networks" => [{"cidr" => "10.0.0.0/29", "source_host_ip" => "10.0.0.1"}]})
      result = described_class.new(generic_host.reload).pull_ips
      expect(result.map { [it.ip_address, it.source_host_ip] }).to eq([["203.0.113.42/32", "203.0.113.42"], ["10.0.0.0/29", "10.0.0.1"]])
    end
  end

  describe "pull_dc" do
    it "returns the operator-supplied location label" do
      expect(generic_apis.pull_dc("any")).to eq("homelab-rack-A")
    end

    it "returns a sensible default when no label is set" do
      generic_host.update(config: {})
      expect(described_class.new(generic_host.reload).pull_dc(nil)).to eq("byoh-unknown")
    end
  end

  describe "reimage" do
    it "raises CapabilityMissing when no BMC is configured" do
      expect { generic_apis.reimage("byoh-test-1") }
        .to raise_error(Hosting::CapabilityMissing, /does not support automated reimage/)
    end

    it "still raises CapabilityMissing even when a Redfish BMC IS configured (Ubicloud doesn't run a PXE server for BYOH hosts)" do
      generic_host.update(config: config_hash.merge("bmc" => {
        "protocol" => "redfish",
        "endpoint" => "https://bmc.example",
        "username" => "admin",
        "password" => "s3cret",
      }))
      expect { described_class.new(generic_host.reload).reimage("byoh-test-1") }
        .to raise_error(Hosting::CapabilityMissing, /does not support automated reimage/)
    end
  end

  describe "reset" do
    it "raises CapabilityMissing when no BMC is configured" do
      expect { generic_apis.reset("byoh-test-1") }
        .to raise_error(Hosting::CapabilityMissing, /no Redfish BMC endpoint/)
    end

    it "power-cycles the host via Redfish when a BMC is configured" do
      generic_host.update(config: config_hash.merge("bmc" => {
        "protocol" => "redfish",
        "endpoint" => "https://bmc.example",
        "username" => "admin",
        "password" => "s3cret",
        "verify_ssl" => false,
      }))
      Excon.stub({path: "/redfish/v1/Systems", method: :get},
        {status: 200, body: {"Members" => [{"@odata.id" => "/redfish/v1/Systems/1"}]}.to_json})
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get},
        {status: 200, body: {"Actions" => {"#ComputerSystem.Reset" => {"target" => "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}}}.to_json})
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          expect(JSON.parse(req[:body])).to eq("ResetType" => "ForceRestart")
          {status: 204, body: ""}
        },
      )

      expect(described_class.new(generic_host.reload).reset("byoh-test-1")).to be_nil
    end

    it "honors bmc.reset_type override for BMCs that need PowerCycle" do
      generic_host.update(config: config_hash.merge("bmc" => {
        "protocol" => "redfish",
        "endpoint" => "https://bmc.example",
        "username" => "admin",
        "password" => "s3cret",
        "verify_ssl" => false,
        "system_id" => "Self",
        "reset_type" => "PowerCycle",
      }))
      Excon.stub({path: "/redfish/v1/Systems/Self", method: :get},
        {status: 200, body: {"Actions" => {"#ComputerSystem.Reset" => {"target" => "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}}}.to_json})
      Excon.stub(
        {path: "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          expect(JSON.parse(req[:body])).to eq("ResetType" => "PowerCycle")
          {status: 204, body: ""}
        },
      )

      expect(described_class.new(generic_host.reload).reset("byoh-test-1")).to be_nil
    end

    it "raises CapabilityMissing when the bmc section has no endpoint" do
      generic_host.update(config: config_hash.merge("bmc" => {"username" => "admin"}))
      expect { described_class.new(generic_host.reload).reset("byoh-test-1") }
        .to raise_error(Hosting::CapabilityMissing, /no Redfish BMC endpoint/)
    end

    it "raises CapabilityMissing when protocol is ipmi (v1 is redfish-only)" do
      generic_host.update(config: config_hash.merge("bmc" => {
        "protocol" => "ipmi",
        "endpoint" => "192.168.1.11",
        "username" => "admin",
        "password" => "s3cret",
      }))
      expect { described_class.new(generic_host.reload).reset("byoh-test-1") }
        .to raise_error(Hosting::CapabilityMissing, /no Redfish BMC endpoint/)
    end

    it "reads the BMC password from an env var when password_env is set" do
      ENV["TEST_BMC_PASSWORD"] = "from-env"
      begin
        generic_host.update(config: config_hash.merge("bmc" => {
          "protocol" => "redfish",
          "endpoint" => "https://bmc.example",
          "username" => "admin",
          "password_env" => "TEST_BMC_PASSWORD",
          "verify_ssl" => false,
          "system_id" => "1",
        }))
        Excon.stub({path: "/redfish/v1/Systems/1", method: :get},
          {status: 200, body: {"Actions" => {"#ComputerSystem.Reset" => {"target" => "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}}}.to_json})

        captured_auth = nil
        Excon.stub(
          {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
          ->(req) {
            captured_auth = req[:headers]["Authorization"]
            {status: 204, body: ""}
          },
        )
        described_class.new(generic_host.reload).reset("byoh-test-1")

        # Excon sets Authorization: Basic base64(user:password). Decode and verify.
        expect(captured_auth).to start_with("Basic ")
        decoded = Base64.decode64(captured_auth.sub("Basic ", ""))
        expect(decoded).to eq("admin:from-env")
      ensure
        ENV.delete("TEST_BMC_PASSWORD")
      end
    end
  end

  describe "set_server_name" do
    it "is a no-op for BYOH hosts" do
      expect(generic_apis.set_server_name("byoh-test-1", "new-name")).to be_nil
    end
  end

  describe "factory integration with HostProvider#api" do
    it "HostProvider#api returns a Hosting::GenericApis instance for generic provider" do
      expect(generic_host.api).to be_a(described_class)
    end
  end
end
