# frozen_string_literal: true

require_relative "../../model/spec_helper"
require_relative "../../golden_fixture"

# Freezes what Prog::Vm::Nexus.assemble records for every VM size family
# that exists today, in a location that bills it: the VM row, its storage
# volumes and the strand it starts. Random ids and times are replaced by
# placeholders.
RSpec.describe Prog::Vm::Nexus do
  let(:project) { Project.create(name: "golden") }
  let(:locations) {
    [
      Location[Location::HETZNER_FSN1_ID],
      Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true).tap {
        LocationAz.create(location_id: it.id, zone_id: "usw2-az1", az: "a")
      },
      Location.create(name: "gcp-us-central1", provider: "gcp", display_name: "gcp-us-central1", ui_name: "GCP US Central 1", visible: true),
    ]
  }

  def record(size)
    location = locations.find { BillingRate.from_resource_properties("VmVCpu", size.family, it.name) }
    return {"size" => size.name, "arch" => size.arch, "location" => nil} unless location

    vm = described_class.assemble("ssh-ed25519 AAAAgolden", project.id, name: "golden-#{size.family}-#{size.arch}".tr("._", "--"),
      size: size.name, arch: size.arch, location_id: location.id).subject
    vm.reload
    {
      "size" => size.name,
      "arch" => size.arch,
      "location" => location.name,
      "vm" => vm.values.except(:id, :created_at, :project_id, :location_id).transform_keys(&:to_s),
      "nics" => vm.nics.map { it.values.slice(:name, :state, :vm_id).transform_values(&:to_s) },
      "storage_volumes" => vm.vm_storage_volumes.map { |v|
        v.values.except(:id, :vm_id, :key_encryption_key_1_id, :key_encryption_key_2_id)
          .transform_keys(&:to_s).merge("encrypted" => !v.key_encryption_key_1_id.nil?)
      },
      "strand" => vm.strand.values.slice(:prog, :label, :stack).transform_keys(&:to_s),
    }
  end

  it "records the same VM, volumes and strand for every size family" do
    allow(Config).to receive(:machine_images_service_project_id).and_return(nil)
    sizes = Option::VmSizes.uniq { [it.family, it.arch] }
    expect(sizes.map(&:family).uniq).to include("standard", "premium", "burstable")
    result = JSON.pretty_generate(sizes.map { record(it) }).gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "<uuid>") + "\n"
    expect(result).to eq GoldenFixture.read("nexus_assemble_families.json", result)
  end
end
