# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../golden_fixture"

# Freezes the option tree the VM create form gives a project that sees no
# BYOH location: locations, families, sizes, storage sizes and images.
RSpec.describe Clover, "vm create options" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  before { login(user.email) }

  it "offers a non-BYOH project the same VM create options" do
    visit "#{project.path}/vm/create"
    expect(page.title).to eq("Ubicloud - Create Virtual Machine")

    script = page.body.lines.grep(/\A\s*let option_(tree|children) = /).map(&:strip)
    expect(script.size).to eq 2
    tree = JSON.parse(script[0].delete_prefix("let option_tree = "))
    children = JSON.parse(script[1].delete_prefix("let option_children = "))
    result = JSON.pretty_generate({"option_tree" => tree, "option_children" => children}) + "\n"
    expect(result).to eq GoldenFixture.read("vm_create_options.json", result)
  end
end
