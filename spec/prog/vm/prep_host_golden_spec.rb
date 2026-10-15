# frozen_string_literal: true

require_relative "../../spec_helper"

# Freezes the command PrepHost runs on a KVM host, on a non-BYOH host and
# on a BYOH generic host alike.
RSpec.describe Prog::Vm::PrepHost do
  {"non-BYOH" => false, "BYOH generic" => true}.each do |kind, byoh|
    it "runs the same command on a #{kind} host" do
      vm_host = byoh ? create_byoh_vm_host(create_byoh_location) : create_vm_host
      ph = described_class.new(Strand.create(prog: "Vm::PrepHost", label: "start", stack: [{"subject_id" => vm_host.id}]))
      expect(ph.sshable).to receive(:_cmd).with("sudo host/bin/prep_host.rb #{vm_host.ubid} test")
      expect { ph.start }.to exit({"msg" => "host prepared"})
    end
  end

  it "names the tier of a lower-tier host" do
    vm_host = create_byoh_vm_host(create_byoh_location, virt_tier: "emulated", family: "emulated")
    ph = described_class.new(Strand.create(prog: "Vm::PrepHost", label: "start", stack: [{"subject_id" => vm_host.id}]))
    expect(ph.sshable).to receive(:_cmd).with("sudo host/bin/prep_host.rb #{vm_host.ubid} test emulated")
    expect { ph.start }.to exit({"msg" => "host prepared"})
  end
end
