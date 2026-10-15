# frozen_string_literal: true

require_relative "../../spec_helper"

# Customers opt into a lower virtualization tier (docs/byoh/NO_KVM.md) by
# picking one of its sizes through the API, in a BYOH location that
# offers it.
RSpec.describe Clover, "vm tier sizes" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }

  before do
    login_api
    ship_virt_tiers("emulated")
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm emulated], "acks" => {"emulated" => []}}))
    project.set_ff_visible_locations([location.name])
    allow(BillingRate).to receive(:from_resource_properties).and_call_original
    %w[VmVCpu VmStorage].each { allow(BillingRate).to receive(:from_resource_properties).with(it, "emulated", location.name).and_return({"id" => "rate"}) }
  end

  def create(location_name, **params)
    post "/project/#{project.ubid}/location/#{location_name}/vm/tiered", {public_key: "ssh key", unix_user: "ubi", boot_image: "ubuntu-noble"}.merge(params).to_json
  end

  it "creates a VM of an offered tier" do
    create(location.display_name, size: "emulated-2", storage_size: 80)
    expect(last_response.status).to eq 200
    expect(JSON.parse(last_response.body)["size"]).to eq "emulated-2"
    vm = Vm.first(name: "tiered")
    expect(vm.display_size).to eq "emulated-2"
    expect(vm.family).to eq "emulated"
    expect(vm.vm_storage_volumes.map(&:size_gib)).to eq [80]
  end

  it "refuses tier sizes where they are not offered" do
    create(TEST_LOCATION, size: "emulated-2")
    expect(last_response.status).to eq 400
    expect(JSON.parse(last_response.body).dig("error", "details", "size")).to start_with "\"emulated-2\" is not a valid virtual machine size."
    expect(Vm.count).to eq 0
  end
end
