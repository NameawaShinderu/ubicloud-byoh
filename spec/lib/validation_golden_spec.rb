# frozen_string_literal: true

require_relative "../spec_helper"

# Freezes what the size-validation error of every non-VM caller offers.
# The size list itself is upstream's to change, so it is computed rather
# than pinned: callers must keep offering exactly Option::VmSizes (or its
# visible subset) without the emulated family, in the same order and text.
RSpec.describe Validation do
  def size_error
    yield
    fail "expected a validation error"
  rescue described_class::ValidationFailed => e
    e.details[:size]
  end

  def expected_error(size, only_visible: false)
    names = Option::VmSizes.select { (!only_visible || it.visible) && it.family != "emulated" }.map(&:name)
    "\"#{size}\" is not a valid virtual machine size. Available sizes: #{names}"
  end

  def offered(error)
    error.split("Available sizes: ", 2).fetch(1)
  end

  it "offers every non-emulated size, and only those, in each argument shape" do
    {
      ["x64", false] => size_error { described_class.validate_vm_size("emulated-2", "x64") },
      ["arm64", false] => size_error { described_class.validate_vm_size("emulated-2", "arm64") },
      ["x64", true] => size_error { described_class.validate_vm_size("emulated-2", "x64", only_visible: true) },
    }.each do |(_arch, only_visible), error|
      expect(error).to eq expected_error("emulated-2", only_visible:)
      expect(offered(error)).to include("\"standard-2\"")
      expect(offered(error)).not_to include("\"emulated-")
    end
  end

  it "keeps the error Vm::Nexus.assemble gives every VM" do
    error = size_error { Prog::Vm::Nexus.assemble("a a", Project.create(name: "golden").id, size: "emulated-2") }
    expect(error).to eq expected_error("emulated-2")
    expect(offered(error)).not_to include("\"emulated-")
  end

  it "keeps the error a VM pool with an unknown size gets" do
    pool = VmPool.create(size: 1, vm_size: "emulated-2", boot_image: "img", location_id: Location::HETZNER_FSN1_ID, storage_size_gib: 86, arch: "arm64")
    nx = Prog::Vm::VmPool.new(Strand.create_with_id(pool, prog: "Vm::VmPool", label: "wait"))
    error = size_error { nx.wait }
    expect(error).to eq expected_error("emulated-2")
    expect(offered(error)).not_to include("\"emulated-")
  end
end
