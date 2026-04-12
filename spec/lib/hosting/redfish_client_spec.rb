# frozen_string_literal: true

RSpec.describe Hosting::RedfishClient do
  let(:endpoint) { "https://bmc.example" }
  let(:client) {
    described_class.new(endpoint, username: "admin", password: "secret", verify_ssl: false)
  }

  let(:single_system_body) {
    {
      "Members" => [{"@odata.id" => "/redfish/v1/Systems/1"}]
    }.to_json
  }

  let(:system_detail_body) {
    {
      "Id" => "1",
      "Actions" => {
        "#ComputerSystem.Reset" => {
          "target" => "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
          "ResetType@Redfish.AllowableValues" => ["On", "ForceOff", "ForceRestart", "PowerCycle"]
        }
      }
    }.to_json
  }

  describe "#power_reset" do
    it "discovers the system, reads the Reset action target, and POSTs the reset" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: single_system_body})
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get}, {status: 200, body: system_detail_body})
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          expect(JSON.parse(req[:body])).to eq("ResetType" => "ForceRestart")
          {status: 204, body: ""}
        }
      )

      expect(client.power_reset).to be_nil
    end

    it "honors a non-default reset_type" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: single_system_body})
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get}, {status: 200, body: system_detail_body})
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        ->(req) {
          expect(JSON.parse(req[:body])).to eq("ResetType" => "PowerCycle")
          {status: 202, body: ""}
        }
      )

      expect(client.power_reset(reset_type: "PowerCycle")).to be_nil
    end

    it "skips /Systems discovery when system_id is given at construction" do
      client_with_id = described_class.new(endpoint, username: "admin", password: "secret", verify_ssl: false, system_id: "1")
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get}, {status: 200, body: system_detail_body})
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        {status: 204, body: ""}
      )

      expect(client_with_id.power_reset).to be_nil
    end

    it "handles an absolute URL in the Reset action target" do
      absolute_body = {
        "Actions" => {
          "#ComputerSystem.Reset" => {
            "target" => "https://bmc.example/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"
          }
        }
      }.to_json
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: single_system_body})
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get}, {status: 200, body: absolute_body})
      Excon.stub(
        {path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", method: :post},
        {status: 204, body: ""}
      )

      expect(client.power_reset).to be_nil
    end
  end

  describe "#discover_system_id" do
    it "returns the SystemId from a single-member collection" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: single_system_body})
      expect(client.discover_system_id).to eq("1")
    end

    it "raises when /Systems is empty" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: {"Members" => []}.to_json})
      expect { client.discover_system_id }.to raise_error(described_class::Error, /no members/)
    end

    it "raises when /Systems has multiple members and system_id was not set (chassis BMC case)" do
      multi_body = {
        "Members" => [
          {"@odata.id" => "/redfish/v1/Systems/1"},
          {"@odata.id" => "/redfish/v1/Systems/2"}
        ]
      }.to_json
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: multi_body})
      expect { client.discover_system_id }.to raise_error(described_class::Error, /multiple systems/)
    end
  end

  describe "#reset_action_target" do
    it "raises if the system has no #ComputerSystem.Reset action" do
      bad_body = {"Actions" => {}}.to_json
      Excon.stub({path: "/redfish/v1/Systems/1", method: :get}, {status: 200, body: bad_body})
      expect { client.reset_action_target("1") }.to raise_error(described_class::Error, /no .+Reset action/)
    end
  end

  describe "#set_next_boot_pxe" do
    it "PATCHes /Systems/{id} with a one-shot PXE override" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 200, body: single_system_body})
      Excon.stub(
        {path: "/redfish/v1/Systems/1", method: :patch},
        ->(req) {
          parsed = JSON.parse(req[:body])
          expect(parsed["Boot"]).to eq(
            "BootSourceOverrideEnabled" => "Once",
            "BootSourceOverrideTarget" => "Pxe"
          )
          {status: 204, body: ""}
        }
      )

      expect(client.set_next_boot_pxe).to be_nil
    end
  end

  describe "error propagation" do
    it "raises on 401 Unauthorized from the BMC" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 401, body: ""})
      expect { client.discover_system_id }.to raise_error(Excon::Error::Unauthorized)
    end

    it "raises on 500 from the BMC" do
      Excon.stub({path: "/redfish/v1/Systems", method: :get}, {status: 500, body: ""})
      expect { client.discover_system_id }.to raise_error(Excon::Error::InternalServerError)
    end
  end
end
