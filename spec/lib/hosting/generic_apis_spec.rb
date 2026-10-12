# frozen_string_literal: true

RSpec.describe Hosting::GenericApis do
  let(:vm_host) {
    vmh = create_vm_host
    vmh.sshable.update(host: "203.0.113.42")
    vmh
  }

  let(:config) {
    {
      "main_ip4" => "203.0.113.42",
      "location_label" => "homelab-rack-A",
      "routed_networks" => [{"cidr" => "10.99.0.0/29"}, {"cidr" => "2001:db8:dead::/64"}],
    }
  }

  let(:host_provider) {
    HostProvider.create do |hp|
      hp.id = vm_host.id
      hp.server_identifier = "byoh-test-1"
      hp.provider_name = HostProvider::GENERIC_PROVIDER_NAME
      hp.config = config
    end
  }

  let(:api) { host_provider.api }

  let(:bmc) {
    {"protocol" => "redfish", "endpoint" => "https://bmc.example", "username" => "admin", "password" => "s3cret", "verify_ssl" => false}
  }

  def with_config(**changes)
    host_provider.update(config: config.merge(changes.transform_keys(&:to_s)))
    described_class.new(host_provider.reload)
  end

  def stub_redfish_system(power_state: "On")
    Excon.stub({path: "/redfish/v1/Systems", method: :get},
      {status: 200, body: {"Members" => [{"@odata.id" => "/redfish/v1/Systems/1"}]}.to_json})
    Excon.stub({path: "/redfish/v1/Systems/1", method: :get},
      {status: 200, body: {"PowerState" => power_state, "Actions" => {"#ComputerSystem.Reset" => {"target" => "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}}}.to_json})
  end

  def expect_reset_type(reset_type)
    Excon.stub({path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post}, lambda { |req|
      expect(JSON.parse(req[:body])).to eq("ResetType" => reset_type)
      {status: 204, body: ""}
    })
  end

  it "is what HostProvider#api returns for a generic provider" do
    expect(api).to be_a(described_class)
  end

  describe "#pull_ips" do
    it "returns the declared IPv4 networks after the management /32" do
      expect(api.pull_ips.map { [it.ip_address, it.source_host_ip] }).to eq([
        ["203.0.113.42/32", "203.0.113.42"],
        ["10.99.0.0/29", "203.0.113.42"],
      ])
    end

    it "lets the host claim only the management address" do
      expect(api.pull_ips.map { [it.host_only?, it.host_connectivity?] }).to eq([[true, false], [false, false]])
    end

    it "omits the management /32 when a declared block covers it" do
      ips = with_config(routed_networks: [{"cidr" => "203.0.113.40/29"}]).pull_ips
      expect(ips.map(&:ip_address)).to eq(["203.0.113.40/29"])
    end

    it "uses the sshable host even when main_ip4 differs" do
      ips = with_config(main_ip4: "1.2.3.4", routed_networks: []).pull_ips
      expect(ips.map(&:ip_address)).to eq(["203.0.113.42/32"])
    end

    it "defaults the network contract of the management /32" do
      expect(api.pull_ips.first.to_h).to include(delivery: "routed", exposure: "public", reserved_ips: [], external_ips: {})
    end

    it "keeps the meaning of legacy entries" do
      expect(api.pull_ips.last.to_h.slice(:delivery, :exposure)).to eq(delivery: "routed", exposure: "public")
    end

    it "carries each pool's delivery, exposure, reserved and external IPs" do
      ips = with_config(routed_networks: [
        {"cidr" => "10.98.1.0/30", "delivery" => "onlink", "exposure" => "nat", "segment" => "10.98.1.0/24", "gateway" => "10.98.1.1",
         "external" => {"10.98.1.2" => "8.8.8.2", "10.98.1.3" => "8.8.8.3"}},
      ]).pull_ips
      expect(ips.last).to have_attributes(ip_address: "10.98.1.0/30", delivery: "onlink", exposure: "nat",
        reserved_ips: %w[10.98.1.0 10.98.1.1], external_ips: {"10.98.1.2" => "8.8.8.2", "10.98.1.3" => "8.8.8.3"})
    end

    it "reads a stored bare IPv4 address as a /32, as registration accepted it" do
      ips = with_config(routed_networks: [{"cidr" => "198.51.100.7"}, "198.51.100.9"]).pull_ips
      expect(ips.map(&:ip_address)).to eq(["203.0.113.42/32", "198.51.100.7/32", "198.51.100.9/32"])
    end

    it "returns only the management /32 without a config" do
      host_provider.update(config: nil)
      expect(described_class.new(host_provider.reload).pull_ips.map(&:ip_address)).to eq(["203.0.113.42/32"])
    end
  end

  describe "#reimage" do
    it "raises CapabilityMissing because BYOH hosts have no PXE server" do
      expect { with_config(bmc:).reimage }.to raise_error(Hosting::CapabilityMissing, /does not support automated reimage/)
    end
  end

  describe "without a Redfish BMC" do
    it "raises CapabilityMissing for hardware_reset and power_on" do
      expect { api.hardware_reset }.to raise_error(Hosting::CapabilityMissing, /hardware reset must be performed manually/)
      expect { api.power_on }.to raise_error(Hosting::CapabilityMissing, /power on must be performed manually/)
    end

    it "reports that power status is unavailable" do
      expect(api.power_status).to eq("no Redfish BMC configured")
    end

    it "treats a bmc section without an endpoint as no BMC" do
      expect { with_config(bmc: {"username" => "admin"}).hardware_reset }.to raise_error(Hosting::CapabilityMissing)
    end

    it "treats a non-redfish protocol as no BMC" do
      expect { with_config(bmc: bmc.merge("protocol" => "ipmi")).hardware_reset }.to raise_error(Hosting::CapabilityMissing)
    end
  end

  describe "with a Redfish BMC" do
    it "power-cycles with ForceRestart by default" do
      stub_redfish_system
      expect_reset_type("ForceRestart")
      expect(with_config(bmc:).hardware_reset).to be_nil
    end

    it "honors a configured reset_type" do
      stub_redfish_system
      expect_reset_type("PowerCycle")
      expect(with_config(bmc: bmc.merge("reset_type" => "PowerCycle")).hardware_reset).to be_nil
    end

    it "powers on with the On reset type" do
      stub_redfish_system(power_state: "Off")
      expect_reset_type("On")
      expect(with_config(bmc:).power_on).to be_nil
    end

    it "does not power on a system that is already on" do
      stub_redfish_system(power_state: "On")
      expect(with_config(bmc:).power_on).to be_nil
    end

    it "reports the Redfish power state" do
      stub_redfish_system(power_state: "Off")
      expect(with_config(bmc:).power_status).to eq("redfish: Off")
    end

    it "reads the password from password_env when set" do
      stub_redfish_system
      Excon.stub({path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post}, lambda { |req|
        expect(req[:password]).to eq("from-env")
        {status: 204, body: ""}
      })
      ENV["BYOH_TEST_BMC_PASS"] = "from-env"
      with_config(bmc: bmc.except("password").merge("password_env" => "BYOH_TEST_BMC_PASS")).hardware_reset
    ensure
      ENV.delete("BYOH_TEST_BMC_PASS")
    end
  end
end
