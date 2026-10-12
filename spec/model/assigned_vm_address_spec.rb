# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AssignedVmAddress do
  let(:vm) { create_vm }

  it "has no external IP by default" do
    expect(described_class.create(dst_vm_id: vm.id, ip: "10.0.0.1/32").reload.external_ip).to be_nil
  end

  it "stores an IPv4 external IP" do
    expect(described_class.create(dst_vm_id: vm.id, ip: "10.0.0.1/32", external_ip: "203.0.113.1").reload.external_ip.to_s).to eq "203.0.113.1"
  end

  it "refuses an IPv6 external IP" do
    expect { described_class.create(dst_vm_id: vm.id, ip: "10.0.0.1/32", external_ip: "2001:db8::1") }.to raise_error(Sequel::ValidationFailed, "external_ip is invalid")
  end

  it "refuses an external IP that another VM already has" do
    described_class.create(dst_vm_id: vm.id, ip: "10.0.0.1/32", external_ip: "203.0.113.1")
    other = create_vm(name: "other-vm", project_id: vm.project_id)
    expect { described_class.create(dst_vm_id: other.id, ip: "10.0.0.2/32", external_ip: "203.0.113.1") }.to raise_error(Sequel::ValidationFailed, "external_ip is already taken")
  end
end
