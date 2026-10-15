# frozen_string_literal: true

require_relative "../../rhizome/host/lib/virt_probe"

RSpec.describe ByohVirtLadder do
  def facts(**over)
    {
      "arch" => "x86_64",
      "kernel" => "6.8.0-1-generic",
      "cpu_vendor" => "GenuineIntel",
      "cpu_model" => "Intel Xeon",
      "cpu_flags" => %w[vmx pdpe1gb],
      "dev_kvm" => true,
      "kvm_api" => 12,
      "modules" => %w[kvm kvm_intel],
      "nested_param" => true,
      "pvm_module_available" => false,
      "virt_vm" => "none",
      "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Dell Inc.", "product_name" => "PowerEdge R650"},
    }.merge(over.transform_keys(&:to_s))
  end

  def verdict(**over)
    described_class.parse(JSON.generate(VirtProbe.report(facts(**over))))
  end

  it "knows every tier the probe reports" do
    expect(described_class::RUNGS.keys).to match_array(VirtProbe::TIERS)
  end

  it "takes a bare-metal KVM host as L1 without fix or caveats" do
    v = verdict
    expect([v.tier, v.rung, v.nested, v.fix, v.caveats, v.standard_vms?, v.platform]).to eq ["kvm", "L1", false, nil, [], true, nil]
    expect(v.text).to eq "tier: kvm (L1)\nplatform: unknown platform\nwhy: /dev/kvm answers KVM_GET_API_VERSION 12"
  end

  it "takes a nested KVM host as L1 with the nested caveats" do
    v = verdict(cpu_flags: %w[vmx hypervisor pdpe1gb], virt_vm: "amazon", dmi: {"sys_vendor" => "Amazon EC2"})
    expect([v.tier, v.nested, v.platform.key, v.standard_vms?]).to eq ["kvm", true, "aws", true]
    expect(v.caveats).to eq described_class::NESTED_CAVEATS
    expect(v.text).to start_with("tier: kvm (L1) nested\nplatform: AWS EC2\n").and include("caveat: nested virtualization")
  end

  it "warns about a KVM host without 1G pages" do
    expect(verdict(cpu_flags: %w[vmx]).caveats).to eq [described_class::NO_1G_HUGEPAGES]
    expect(verdict(arch: "aarch64", cpu_flags: []).caveats).to eq []
  end

  it "tells how to enable VT-x on bare metal" do
    v = verdict(cpu_flags: [], dev_kvm: false, kvm_api: nil, modules: [])
    expect([v.tier, v.rung, v.standard_vms?]).to eq ["kvm_blocked", "L2", false]
    expect(v.fix).to start_with "Enable Intel VT-x or AMD-V"
    expect(v.summary).to eq "kvm_blocked (L2) on unknown platform: bare metal without the vmx or svm flag: the firmware has VT-x/AMD-V disabled"
  end

  it "tells how to load the KVM module, with the platform fix inside a VM" do
    expect(verdict(dev_kvm: false, kvm_api: nil, modules: []).fix).to eq "Load the KVM module (modprobe kvm_intel, or kvm_amd) and persist it under /etc/modules-load.d; if it refuses to load, check dmesg for \"disabled by bios\"."
    v = verdict(cpu_flags: %w[vmx hypervisor], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "vmware", dmi: {"sys_vendor" => "VMware, Inc."})
    expect(v.fix).to end_with "(vhv.enable = \"TRUE\")."
  end

  it "tells how to make a silent /dev/kvm usable" do
    expect(verdict(kvm_api: "Permission denied").fix).to eq "Make /dev/kvm usable: check that the KVM module loaded cleanly (dmesg) and that this is not a container. #{ByohVirtPlatforms::GENERIC_FIX}"
  end

  it "tells how to load kvm_pvm" do
    v = verdict(cpu_flags: %w[hypervisor], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "kvm", pvm_module_available: true)
    expect([v.tier, v.rung]).to eq ["pvm_blocked", "L2"]
    expect(v.fix).to start_with "modprobe kvm_pvm"
  end

  it "refuses VMs on a PVM host and names the way to L1" do
    v = verdict(cpu_flags: %w[hypervisor], modules: %w[kvm kvm_pvm], virt_vm: "kvm", dmi: {"sys_vendor" => "Hetzner"})
    expect([v.tier, v.rung, v.standard_vms?, v.caveats]).to eq ["pvm", "L3", false, []]
    expect(v.fix).to include("This is a PVM host").and include("Hetzner dedicated server")
  end

  it "lists the platform fix and the fallbacks when there is no virtualization" do
    v = verdict(cpu_flags: %w[hypervisor], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "kvm", dmi: {"sys_vendor" => "Google", "product_name" => "Google Compute Engine"})
    expect([v.tier, v.rung, v.platform_name]).to eq ["none", "L3-L5", "Google Compute Engine"]
    expect(v.fix).to start_with("Recreate the VM with --enable-nested-virtualization").and end_with(described_class::FALLBACKS)
  end

  it "refuses a container" do
    v = verdict(virt_container: "docker")
    expect([v.tier, v.rung]).to eq ["container", "refused"]
    expect(v.fix).to eq "Run the data plane on a VM or bare metal, not in a container."
  end

  it "records the verdict with the report" do
    record = verdict(dmi: {"sys_vendor" => "QEMU"}, virt_vm: "kvm", cpu_flags: %w[vmx hypervisor pdpe1gb]).record
    expect(record).to include("version" => 1, "tier" => "kvm", "rung" => "L1", "platform" => "qemu_kvm", "fix" => nil, "nested" => true)
    expect(described_class.verdict(record).tier).to eq "kvm"
    expect(verdict.record).to include("platform" => nil, "caveats" => [])
  end

  it "takes the last JSON line of noisy output" do
    output = "Welcome!\n#{JSON.generate(VirtProbe.report(facts))}\n"
    expect(described_class.parse(output).tier).to eq "kvm"
  end

  it "refuses output that is not a report" do
    expect { described_class.parse("no json here") }.to raise_error(described_class::ParseError, "virt-probe output is not JSON")
    expect { described_class.parse(nil) }.to raise_error(described_class::ParseError, "virt-probe output is not JSON")
    expect { described_class.parse("{nope") }.to raise_error(described_class::ParseError, "virt-probe output is not JSON")
    expect { described_class.verdict([]) }.to raise_error(described_class::ParseError, "virt-probe report is not an object")
    expect { described_class.parse('{"version":2}') }.to raise_error(described_class::ParseError, "virt-probe report version 2 is not 1")
    expect { described_class.parse('{"version":1,"tier":"magic"}') }.to raise_error(described_class::ParseError, "unknown tier \"magic\"")
    expect { described_class.parse('{"version":1,"tier":"kvm"}') }.to raise_error(described_class::ParseError, "virt-probe report has no facts")
  end

  it "builds a remote script that runs the probe" do
    expect(described_class.remote_script).to start_with("# frozen_string_literal: true\n").and end_with("\nexit VirtProbe.main(ARGV)\n")
  end
end
