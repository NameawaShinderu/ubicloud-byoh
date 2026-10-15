# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../../rhizome/host/lib/virt_probe"

RSpec.describe Prog::LearnVirt do
  subject(:lv) { described_class.new(described_class.assemble(vm_host.id)) }

  let(:vm_host) { create_vm_host }

  def probe_output(**over)
    facts = {
      "arch" => "x86_64", "kernel" => "6.8.0", "cpu_vendor" => "GenuineIntel", "cpu_model" => "Xeon",
      "cpu_flags" => %w[vmx pdpe1gb], "dev_kvm" => true, "kvm_api" => 12, "modules" => %w[kvm kvm_intel],
      "nested_param" => nil, "pvm_module_available" => false, "virt_vm" => "none", "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Hetzner"},
    }.merge(over.transform_keys(&:to_s))
    JSON.generate(VirtProbe.report(facts))
  end

  it "records an L1 host and resolves an earlier page" do
    Prog::PageNexus.assemble("old", ["ByohVirtTier", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id)
    page = Page.from_tag_parts("ByohVirtTier", vm_host.ubid)
    expect(lv.sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(probe_output)
    expect { lv.start }.to exit({"msg" => "virt tier kvm"})
    expect(vm_host.reload.virt_probe.to_h).to include("tier" => "kvm", "rung" => "L1", "platform" => "hetzner_cloud")
    expect(page.reload.resolve_set?).to be true
  end

  it "records an L1 host without a page" do
    expect(lv.sshable).to receive(:_cmd).and_return(probe_output)
    expect { lv.start }.to exit({"msg" => "virt tier kvm"})
    expect(Page.count).to eq 0
  end

  it "pages with the fix when the host cannot run VMs" do
    expect(lv.sshable).to receive(:_cmd).and_return(probe_output(cpu_flags: %w[hypervisor], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "kvm"))
    expect { lv.start }.to exit({"msg" => "virt tier none"})
    expect(vm_host.reload.virt_probe["tier"]).to eq "none"
    page = Page.from_tag_parts("ByohVirtTier", vm_host.ubid)
    expect(page.summary).to start_with "#{vm_host.ubid} cannot run VMs: none (L3-L5) on Hetzner Cloud"
    expect(page.details.to_h).to include("tier" => "none", "rung" => "L3-L5", "fix" => start_with("Hetzner Cloud servers do not expose"))
  end

  it "fails on output it cannot read, so the strand retries" do
    expect(lv.sshable).to receive(:_cmd).and_return("ruby: not found")
    expect { lv.start }.to raise_error(ByohVirtLadder::ParseError)
  end
end
