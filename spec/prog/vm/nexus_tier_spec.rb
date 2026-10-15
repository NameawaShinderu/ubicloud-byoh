# frozen_string_literal: true

require_relative "../../model/spec_helper"

# The policy gate of Prog::Vm::Nexus.assemble for lower virtualization
# tiers (docs/byoh/NO_KVM.md section 5.3). nexus_assemble_golden_spec.rb
# pins that every existing family is created as before.
RSpec.describe Prog::Vm::Nexus do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:project) { Project.create(name: "tier-project") }
  let(:other) { Project.create(name: "other-project") }

  before do
    ship_virt_tiers("container", "emulated")
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container emulated], "acks" => {"container" => [], "emulated" => []}}))
    [project, other].each { it.set_ff_visible_locations([location.name]) }
    allow(BillingRate).to receive(:from_resource_properties).and_call_original
    %w[container emulated].product(%w[VmVCpu VmStorage]).each do |family, type|
      allow(BillingRate).to receive(:from_resource_properties).with(type, family, location.name).and_return({"id" => "rate"})
    end
  end

  def assemble(size, project: self.project, **)
    described_class.assemble("ssh-ed25519 key", project.id, size:, location_id: location.id, allowed_tiers: %w[kvm container emulated], **)
  end

  it "creates a lower-tier VM without hugepages" do
    st = assemble("emulated-2", boot_image: "ubuntu-noble")
    expect(st.subject.values.slice(:family, :vcpus, :memory_gib)).to eq(family: "emulated", vcpus: 2, memory_gib: 8)
    expect(st.stack.first["hugepages"]).to be false
    expect(st.stack.first["storage_volumes"].first["track_written"]).to be true
  end

  it "does not track written blocks for a tier that keeps its own disks" do
    st = assemble("container-2", boot_image: "ubuntu-noble-container")
    expect(st.stack.first["storage_volumes"].first["track_written"]).to be false
  end

  it "refuses tier sizes to callers that did not allow them" do
    expect {
      described_class.assemble("ssh-ed25519 key", project.id, size: "emulated-2", location_id: location.id)
    }.to raise_error(Validation::ValidationFailed) { expect(it.details[:size]).to start_with "\"emulated-2\" is not a valid virtual machine size." }
    expect {
      described_class.assemble("ssh-ed25519 key", project.id, size: "container-2", location_id: location.id, allowed_tiers: %w[kvm emulated])
    }.to raise_error(Validation::ValidationFailed)
  end

  it "runs the gate for a lower-tier size" do
    expect { assemble("emulated-2", boot_image: "ubuntu-noble", gpu_count: 1) }
      .to raise_error(Validation::ValidationFailed) { expect(it.details[:size]).to eq "emulated VMs cannot have GPUs" }
  end

  it "lets only one project create lower-tier VMs in a location" do
    assemble("emulated-2", boot_image: "ubuntu-noble")
    assemble("container-2", boot_image: "ubuntu-noble-container")
    expect { assemble("emulated-2", boot_image: "ubuntu-noble", project: other) }
      .to raise_error(Validation::ValidationFailed) { expect(it.details[:size]).to include "already runs lower-tier VMs of another project" }
    expect(Vm.where(project_id: other.id).count).to eq 0
    # KVM VMs of other projects are unaffected.
    allow(BillingRate).to receive(:from_resource_properties).with("VmVCpu", "standard", location.name).and_return({"id" => "rate"})
    expect(described_class.assemble("ssh-ed25519 key", other.id, location_id: location.id).subject.family).to eq "standard"
  end

  it "creates a standard VM unchanged when lower tiers are allowed" do
    allow(BillingRate).to receive(:from_resource_properties).with("VmVCpu", "standard", location.name).and_return({"id" => "rate"})
    st = assemble("standard-2")
    expect(st.subject.family).to eq "standard"
    expect(st.stack.first["hugepages"]).to be true
  end
end
