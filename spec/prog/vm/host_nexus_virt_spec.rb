# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "prep", stack: [{}]) }
  let(:vm_host) { create_vm_host(net6: "2a01:4f9:2b:35a::/64") }

  it "probes the virtualization ladder at prep on BYOH hosts only" do
    HostProvider.create { |hp|
      hp.id = vm_host.id
      hp.provider_name = HostProvider::GENERIC_PROVIDER_NAME
      hp.server_identifier = "byoh-virt"
    }

    expect { nx.prep }.to hop("wait_prep")
    expect(Strand.where(parent_id: st.id).select_map(:prog)).not_to include("LearnVirt")

    Strand.where(parent_id: st.id).destroy
    location = Location.create(name: "byoh-virt", display_name: "byoh-virt", ui_name: "byoh-virt", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {})
    vm_host.update(location_id: location.id)
    expect { described_class.new(st.reload).prep }.to hop("wait_prep")
    expect(Strand.where(parent_id: st.id).select_map(:prog)).to include("LearnVirt")
  end

  it "ignores the probe when reaping prep" do
    vm_host.update(virt_probe: Sequel.pg_jsonb({"tier" => "kvm"}))
    Strand.create(parent_id: st.id, prog: "LearnVirt", label: "start", stack: [{}], exitval: {"msg" => "virt tier kvm"})
    expect { nx.wait_prep }.to hop("setup_hugepages")
  end
end
