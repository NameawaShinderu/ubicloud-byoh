# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../golden_fixture"

# Freezes the size-validation errors every caller of validate_vm_size shows
# today: Kubernetes and VM pools validate without only_visible, the VM API
# with it, and Vm::Nexus.assemble on the way to every VM.
RSpec.describe Validation do
  def size_error
    yield
    fail "expected a validation error"
  rescue described_class::ValidationFailed => e
    e.details[:size]
  end

  it "keeps the size error text of every caller" do
    errors = {
      "kubernetes_node_size" => size_error { described_class.validate_vm_size("emulated-2", "x64") },
      "vm_pool_arm64" => size_error { described_class.validate_vm_size("emulated-2", "arm64") },
      "vm_api" => size_error { described_class.validate_vm_size("emulated-2", "x64", only_visible: true) },
      "vm_nexus_assemble" => size_error { Prog::Vm::Nexus.assemble("a a", Project.create(name: "golden").id, size: "emulated-2") },
    }
    json = JSON.pretty_generate(errors) + "\n"
    expect(json).to eq GoldenFixture.read("validate_vm_size_errors.json", json)
  end
end
