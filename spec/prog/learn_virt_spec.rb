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

  describe "on a lower-tier host" do
    let(:vm_host) { create_byoh_vm_host(create_byoh_location, virt_tier: "emulated", family: "emulated") }
    let(:no_virt) { {cpu_flags: %w[hypervisor pdpe1gb], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "kvm"} }

    it "agrees when the tier's prerequisites are in place" do
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**no_virt, commands: {"qemu-system-x86_64" => true}, ovmf: true))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(Page.count).to eq 0
    end

    it "pages with what to install when they are missing" do
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**no_virt))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      page = Page.from_tag_parts("ByohVirtTier", vm_host.ubid)
      expect(page.summary).to start_with "#{vm_host.ubid} is registered as emulated but the probe disagrees: none (L3-L5)"
      expect(page.details.to_h).to include("virt_tier" => "emulated", "fix" => "Prepare the host for emulated (apt-get install qemu-system-x86 ovmf), then bin/byoh-virt refresh --host #{vm_host.ubid}.")
    end

    it "pages to register again as kvm when the host runs KVM" do
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output)
      expect { lv.start }.to exit({"msg" => "virt tier kvm"})
      expect(Page.from_tag_parts("ByohVirtTier", vm_host.ubid).details["fix"]).to start_with "The host runs KVM (L1) now; destroy it and register it again as kvm"
    end
  end

  describe "on a container host" do
    let(:vm_host) { create_byoh_vm_host(create_byoh_location, virt_tier: "container", family: "container") }
    let(:no_virt) { {cpu_flags: %w[hypervisor pdpe1gb], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "kvm"} }

    def kernel_page = Page.from_tag_parts("ByohKernelReboot", vm_host.ubid)

    it "records when a pending reboot was first seen, and when it was probed" do
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**no_virt, reboot_required: true))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      record = vm_host.reload.virt_probe.to_h
      expect(Time.now - Time.parse(record["reboot_required_since"])).to be < 60
      expect(Time.now - Time.parse(record["probed_at"])).to be < 60
      expect(kernel_page).to be_nil
      expect(described_class.stale?(vm_host)).to be false
    end

    it "pages when the host has waited a week for a reboot, keeping the first sighting" do
      since = (Time.now - 8 * 24 * 60 * 60).utc.iso8601
      vm_host.update(virt_probe: Sequel.pg_jsonb({"reboot_required_since" => since}))
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**no_virt, reboot_required: true, kernel: "6.8.0-40-generic"))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(vm_host.reload.virt_probe["reboot_required_since"]).to eq since
      expect(kernel_page.summary).to eq "#{vm_host.ubid} has waited for a reboot since #{since}; its container guests share kernel 6.8.0-40-generic"
      expect(kernel_page.details.to_h).to include("kernel" => "6.8.0-40-generic", "fix" => start_with("Drain the host"))
    end

    it "resolves the page once the reboot happened" do
      Prog::PageNexus.assemble("old", ["ByohKernelReboot", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id)
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**no_virt))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(vm_host.reload.virt_probe.to_h).to include("reboot_required_since" => nil)
      expect(kernel_page.resolve_set?).to be true
    end

    it "pages nothing without a pending reboot" do
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**no_virt))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(kernel_page).to be_nil
    end

    it "records when a failed probe ran" do
      expect(lv.sshable).to receive(:_cmd).and_return("ruby: not found")
      expect { lv.start }.to exit({"msg" => "virt probe failed"})
      expect(vm_host.reload.virt_probe.to_h.keys).to eq %w[error probed_at]
    end
  end

  describe "on a pvm host" do
    let(:location) { create_byoh_location }
    let(:vm_host) { create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm") }
    let(:stock) { {cpu_flags: %w[hypervisor pdpe1gb], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "amazon", kernel: "7.0.0-1014-aws", vulnerabilities: {"meltdown" => "Not affected"}} }
    let(:pvm) { {cpu_flags: %w[hypervisor pdpe1gb], dev_kvm: true, kvm_api: 12, kvm_create_vm: true, kvm_caps_missing: [], modules: %w[kvm kvm_pvm], pvm_module_available: true, virt_vm: "amazon", kernel: "6.12.33-pvm", vulnerabilities: {"meltdown" => "Not affected"}} }

    before { location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins})) }

    def kernel_page = Page.from_tag_parts("ByohPvmHostKernel", vm_host.ubid)

    def committed(**) = ByohPvmHost.create(vm_host_id: vm_host.id, state: "committed", install: true, host_kver: "6.12.33-pvm", host_deb_sha256: "a" * 64, **)

    it "agrees with the stock kernel of a host whose PVM kernel it installs, until that kernel boots" do
      ByohPvmHost.create(vm_host_id: vm_host.id, state: "install_pending", install: true)
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**stock))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(Page.count).to eq 0
      ByohPvmHost[vm_host.id].update(state: "committed")
      again = described_class.new(described_class.assemble(vm_host.id))
      expect(again.sshable).to receive(:_cmd).and_return(probe_output(**stock))
      expect { again.start }.to exit({"msg" => "virt tier none"})
      expect(Page.from_tag_parts("ByohVirtTier", vm_host.ubid).summary).to start_with "#{vm_host.ubid} is registered as pvm but the probe disagrees"
    end

    it "pages a committed host that runs another kernel than its PVM kernel" do
      committed
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**stock))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(kernel_page.summary).to eq "#{vm_host.ubid} runs kernel 7.0.0-1014-aws, not its PVM kernel 6.12.33-pvm"
      expect(kernel_page.severity).to eq "warning"
    end

    it "pages a host whose PVM kernel is not the location's host-deb pin, and resolves it once it is" do
      committed(host_deb_sha256: "c" * 64)
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**pvm))
      expect { lv.start }.to exit({"msg" => "virt tier pvm"})
      expect(kernel_page.summary).to eq "#{vm_host.ubid} runs the PVM host kernel 6.12.33-pvm (host-deb sha256 #{"c" * 64}), but location byoh-test pins sha256 #{"a" * 64}"
      expect(kernel_page.details.to_h).to include("pinned_sha256" => "a" * 64, "fix" => start_with("A PVM host kernel is never replaced in place"))
      expect(Page.from_tag_parts("ByohVirtTier", vm_host.ubid)).to be_nil

      ByohPvmHost[vm_host.id].update(host_deb_sha256: "a" * 64)
      again = described_class.new(described_class.assemble(vm_host.id))
      expect(again.sshable).to receive(:_cmd).and_return(probe_output(**pvm))
      expect { again.start }.to exit({"msg" => "virt tier pvm"})
      expect(kernel_page.resolve_set?).to be true
    end

    it "names a location that pins no host kernel" do
      committed
      location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm], "acks" => {}}))
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**pvm))
      expect { lv.start }.to exit({"msg" => "virt tier pvm"})
      expect(kernel_page.summary).to end_with "but location byoh-test pins no host kernel"
    end

    it "judges a pvm host without a PVM kernel record by its probe alone" do
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**stock))
      expect { lv.start }.to exit({"msg" => "virt tier none"})
      expect(Page.from_tag_parts("ByohVirtTier", vm_host.ubid)).not_to be_nil
      expect(kernel_page).to be_nil
    end

    it "pages nothing for a PVM kernel installed before registration, nor for a pending reboot" do
      ByohPvmHost.create(vm_host_id: vm_host.id, state: "committed", install: false)
      since = (Time.now - 8 * 24 * 60 * 60).utc.iso8601
      vm_host.update(virt_probe: Sequel.pg_jsonb({"reboot_required_since" => since}))
      expect(lv.sshable).to receive(:_cmd).and_return(probe_output(**pvm, reboot_required: true))
      expect { lv.start }.to exit({"msg" => "virt tier pvm"})
      expect(vm_host.reload.virt_probe["reboot_required_since"]).to eq since
      expect(Page.count).to eq 0
    end
  end

  it "is stale without a probe time or after a day" do
    expect(described_class.stale?(vm_host)).to be true
    vm_host.update(virt_probe: Sequel.pg_jsonb({"probed_at" => (Time.now - 25 * 60 * 60).utc.iso8601}))
    expect(described_class.stale?(vm_host)).to be true
    vm_host.update(virt_probe: Sequel.pg_jsonb({"probed_at" => Time.now.utc.iso8601}))
    expect(described_class.stale?(vm_host)).to be false
  end

  it "keeps a kvm host's record without probe times" do
    expect(lv.sshable).to receive(:_cmd).and_return(probe_output(reboot_required: true))
    expect { lv.start }.to exit({"msg" => "virt tier kvm"})
    expect(vm_host.reload.virt_probe.to_h.keys).not_to include("probed_at", "reboot_required_since")
  end

  it "fails open on output it cannot read: records it, pages once and pops" do
    expect(lv.sshable).to receive(:_cmd).and_return("ruby: not found")
    expect { lv.start }.to exit({"msg" => "virt probe failed"})
    expect(vm_host.reload.virt_probe.to_h).to eq("error" => "ByohVirtLadder::ParseError: virt-probe output is not JSON")
    page = Page.from_tag_parts("ByohVirtTier", vm_host.ubid)
    expect(page.summary).to eq "#{vm_host.ubid} the virtualization probe failed: ByohVirtLadder::ParseError: virt-probe output is not JSON"
    expect(page.details.to_h["fix"]).to include("bin/byoh-virt refresh --host #{vm_host.ubid}")
    again = described_class.new(described_class.assemble(vm_host.id))
    expect(again.sshable).to receive(:_cmd).and_return("{}")
    expect { again.start }.to exit({"msg" => "virt probe failed"})
    expect(Page.count).to eq 1
  end

  it "fails open on an SSH failure, with the message sanitised" do
    expect(lv.sshable).to receive(:_cmd).and_raise(Sshable::SshError.new("sudo host/bin/virt-probe\e[31m --json", "", "", 127, nil))
    expect { lv.start }.to exit({"msg" => "virt probe failed"})
    error = vm_host.reload.virt_probe["error"]
    expect(error).to start_with("Sshable::SshError: ").and end_with("sudo host/bin/virt-probe[31m --json")
  end
end
