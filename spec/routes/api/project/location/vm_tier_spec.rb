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
    ship_virt_tiers("container", "emulated")
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container emulated], "acks" => {"container" => [], "emulated" => []}}))
    project.set_ff_visible_locations([location.name])
    allow(BillingRate).to receive(:from_resource_properties).and_call_original
    %w[container emulated].product(%w[VmVCpu VmStorage]).each do |family, type|
      allow(BillingRate).to receive(:from_resource_properties).with(type, family, location.name).and_return({"id" => "rate"})
    end
  end

  def create(location_name, **params)
    post "/project/#{project.ubid}/location/#{location_name}/vm/tiered", {public_key: "ssh key", unix_user: "ubi", boot_image: "ubuntu-noble"}.merge(params).compact.to_json
  end

  def error_details
    JSON.parse(last_response.body).dig("error", "details")
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

  it "creates a container VM with the tier's boot image, given or by default" do
    create(location.display_name, size: "container-2", boot_image: "ubuntu-noble-container")
    expect(last_response.status).to eq 200
    expect(Vm.first(name: "tiered")).to have_attributes(family: "container", boot_image: "ubuntu-noble-container")
    post "/project/#{project.ubid}/location/#{location.display_name}/vm/tiered2", {public_key: "ssh key", size: "container-2"}.to_json
    expect(last_response.status).to eq 200
    expect(Vm.first(name: "tiered2")).to have_attributes(family: "container", boot_image: "ubuntu-noble-container")
  end

  it "accepts a tier's boot images only with one of its sizes" do
    create(location.display_name, size: "standard-2", boot_image: "ubuntu-noble-container")
    expect(last_response.status).to eq 400
    expect(error_details["boot_image"]).to start_with "\"ubuntu-noble-container\" is not a valid boot image name."
    create(location.display_name, size: "emulated-2", boot_image: "ubuntu-noble-container")
    expect(last_response.status).to eq 400
    expect(error_details["boot_image"]).to start_with "\"ubuntu-noble-container\" is not a valid boot image name."
    create(location.display_name, size: "container-2", boot_image: "ubuntu-noble")
    expect(last_response.status).to eq 400
    expect(error_details["size"]).to eq "container VMs can only boot ubuntu-noble-container"
    create(TEST_LOCATION, size: "container-2", boot_image: "ubuntu-noble-container")
    expect(last_response.status).to eq 400
    expect(error_details["boot_image"]).to start_with "\"ubuntu-noble-container\" is not a valid boot image name."
    expect(Vm.count).to eq 0
  end

  it "refuses tier sizes where they are not offered" do
    create(TEST_LOCATION, size: "emulated-2")
    expect(last_response.status).to eq 400
    expect(JSON.parse(last_response.body).dig("error", "details", "size")).to start_with "\"emulated-2\" is not a valid virtual machine size."
    expect(Vm.count).to eq 0
  end
end
