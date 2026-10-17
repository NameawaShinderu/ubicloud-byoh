# frozen_string_literal: true

require_relative "../../spec_helper"

# PVM VMs through the API (docs/byoh/NO_KVM.md section 6.7): a pvm size in
# a BYOH location that offers pvm with its kernel pins, for a project the
# hidden location is granted to, booting an image the tier boots directly.
RSpec.describe Clover, "vm pvm sizes" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }

  before do
    login_api
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins}))
    project.set_ff_visible_locations([location.name])
    allow(BillingRate).to receive(:from_resource_properties).and_call_original
    %w[VmVCpu VmStorage].each do |type|
      allow(BillingRate).to receive(:from_resource_properties).with(type, "pvm", location.name).and_return({"id" => "rate"})
    end
  end

  def create(project, name: "pvm", **params)
    post "/project/#{project.ubid}/location/#{location.display_name}/vm/#{name}", {public_key: "ssh key", unix_user: "ubi", size: "pvm-2", boot_image: "ubuntu-noble"}.merge(params).compact.to_json
  end

  def error_details
    JSON.parse(last_response.body).dig("error", "details")
  end

  it "creates a pvm VM in a pinned, acknowledged and granted location" do
    create(project)
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    expect(body["size"]).to eq "pvm-2"
    expect(body["virt_tier"]).to eq("tier" => "pvm", "description" => ByohVirtTiers.fetch("pvm").description, "experimental" => true)
    expect(Vm.first(name: "pvm")).to have_attributes(family: "pvm", boot_image: "ubuntu-noble", vcpus: 2)
  end

  it "refuses images a PVM VM cannot boot directly" do
    %w[ubuntu-jammy almalinux-9 debian-12].each do |image|
      create(project, boot_image: image)
      expect(last_response.status).to eq 400
      expect(error_details["size"]).to eq "pvm VMs boot ubuntu-noble only (direct kernel boot), not #{image}"
    end
    expect(Vm.count).to eq 0
  end

  it "refuses pvm sizes in a location that does not offer pvm" do
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm], "acks" => {}, "pvm_kernel" => pvm_test_pins}))
    create(project)
    expect(last_response.status).to eq 400
    expect(error_details["size"]).to start_with "\"pvm-2\" is not a valid virtual machine size."
    expect(Vm.count).to eq 0
  end

  it "boots ubuntu-noble when the create names no image" do
    create(project, boot_image: nil)
    expect(last_response.status).to eq 200
    expect(Vm.first(name: "pvm")).to have_attributes(family: "pvm", boot_image: "ubuntu-noble")
  end

  # No API case for a location that lists pvm without its acknowledgement
  # or its kernel pins: location_byoh_virt_check refuses such a policy
  # however it is written (spec/migrate/byoh_pvm_spec.rb).

  # The route answers 404 for a hidden location the project is not
  # granted, as it does for every size, before any size check; that
  # replaces the plan's 400 here. check_vm!'s "not available to this
  # project" refusal covers Ruby callers (spec/lib/byoh_virt_tiers_spec.rb).
  it "refuses a project the hidden location is not granted to" do
    project.set_ff_visible_locations([])
    create(project)
    expect(last_response.status).to eq 404
    expect(Vm.count).to eq 0
  end

  it "keeps a pvm location to one project" do
    create(project)
    expect(last_response.status).to eq 200
    other = project_with_default_policy(user, name: "other")
    other.set_ff_visible_locations([location.name])
    create(other, name: "pvm2")
    expect(last_response.status).to eq 400
    expect(error_details["size"]).to eq "location #{location.display_name} already runs lower-tier VMs of another project, and its pvm tier is single-project"
    expect(Vm.select_map(:name)).to eq ["pvm"]
  end
end
