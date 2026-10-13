# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupByohEgressNat do
  subject(:sn) {
    described_class.new(Strand.new(stack: [{"subject_id" => host.id}], prog: "SetupByohEgressNat"))
  }

  let(:location) {
    Location.create(name: "byoh-egress", display_name: "byoh-egress", ui_name: "byoh-egress", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME,
      byoh_network: {"underlay_cidrs" => ["10.97.0.0/16", "fd00:97::/48"], "cp_source_cidrs" => ["198.51.100.7/32"], "egress_smtp" => true})
  }
  let(:host) {
    Prog::Vm::HostNexus.assemble("10.97.1.10", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
      provider_config: {"main_ip4" => "10.97.1.10", "routed_networks" => [{"cidr" => "fd00:feed::/64"}]}).subject
  }

  describe "#start" do
    it "installs the table from the location's profile" do
      expect(sn.sshable).to receive(:_cmd).with("sudo host/bin/setup-byoh-egress-nat", stdin: {deny4: ["10.97.0.0/16", "198.51.100.7/32"], smtp: true}.to_json)
      expect { sn.start }.to exit({"msg" => "byoh egress nat was setup"})
    end

    it "does nothing on a host that is not a BYOH host" do
      host.update(location_id: Location::HETZNER_FSN1_ID)
      expect(sn.sshable).not_to receive(:_cmd)
      expect { sn.start }.to exit({"msg" => "not a BYOH host"})
    end
  end
end
