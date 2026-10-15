# frozen_string_literal: true

require "tmpdir"
require_relative "../../rhizome/host/lib/virt_probe"
require_relative "../../rhizome/host/spec/virt_probe_fixtures"

RSpec.describe ByohVirtLadder do
  def facts(**over)
    {
      "arch" => "x86_64",
      "kernel" => "6.8.0-1-generic",
      "cpu_vendor" => "GenuineIntel",
      "cpu_model" => "Intel Xeon",
      "cpu_flags" => %w[vmx pdpe1gb],
      "tdp" => true,
      "dev_kvm" => true,
      "kvm_api" => 12,
      "kvm_errno" => nil,
      "kvm_create_vm" => true,
      "kvm_caps_missing" => [],
      "modules" => %w[kvm kvm_intel],
      "nested_param" => true,
      "pvm_module_available" => false,
      "bios_log" => nil,
      "virt_vm" => "none",
      "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Dell Inc.", "product_name" => "PowerEdge R650"},
      "cgroup2" => true,
      "commands" => {"lxc-start" => false, "lxcfs" => false, "qemu-system-x86_64" => false},
      "ovmf" => false,
    }.merge(over.transform_keys(&:to_s))
  end

  def verdict(**over)
    described_class.parse(JSON.generate(VirtProbe.report(facts(**over))))
  end

  no_virt = {cpu_flags: %w[hypervisor pdpe1gb], dev_kvm: false, kvm_api: nil, kvm_create_vm: nil, kvm_caps_missing: nil, modules: [], virt_vm: "kvm"}

  describe "fixture machines" do
    VirtProbeFixtures.all.each do |name, fixture|
      it "explains #{name} and agrees with the probe" do
        Dir.mktmpdir do |root|
          f = VirtProbe.facts(root: VirtProbeFixtures.materialize(fixture, root))
          expect = fixture["expect"]
          expect(described_class.classify(f)).to eq VirtProbe.classify(f)
          v = described_class.parse(JSON.generate(VirtProbe.report(f)))
          expect([v.tier, v.cause, v.platform&.key, v.standard_vms?, v.nested, v.ready, v.recommended]).to eq expect.values_at("tier", "cause", "platform", "standard", "nested", "ready", "recommended")
          if expect["fix"]
            expect(v.fix).to include(expect["fix"])
          else
            expect(v.fix).to be_nil
          end
          # Every machine that cannot take VMs gets a fix (bin/byoh-virt explain).
          expect(v.fix).not_to be_nil unless v.standard_vms?
          expect(v.text).to include("tier: #{v.tier} (#{v.rung}").and include("recommended: ")
        end
      end
    end
  end

  it "knows every tier the probe reports" do
    expect(described_class::RUNGS.keys).to match_array(VirtProbe::TIERS)
  end

  it "takes a bare-metal KVM host as L1 without fix or caveats" do
    v = verdict
    expect([v.tier, v.rung, v.nested, v.fix, v.caveats, v.standard_vms?, v.platform, v.recommended]).to eq ["kvm", "L1", false, nil, [], true, nil, nil]
    expect(v.text).to eq "tier: kvm (L1)\nplatform: unknown platform\nwhy: /dev/kvm answers KVM_GET_API_VERSION 12\nrecommended: register it as it is (L1)"
  end

  it "takes a nested KVM host as L1 with the nested caveats" do
    v = verdict(cpu_flags: %w[vmx hypervisor pdpe1gb], virt_vm: "amazon", dmi: {"sys_vendor" => "Amazon EC2", "product_name" => "m8i.large"})
    expect([v.tier, v.nested, v.platform.key, v.standard_vms?]).to eq ["kvm", true, "aws", true]
    expect(v.caveats).to eq described_class::NESTED_CAVEATS
    expect(v.text).to start_with("tier: kvm (L1) nested\nplatform: AWS EC2\n").and include("caveat: nested virtualization")
    expect(v.text).not_to include("cost:")
  end

  it "warns about KVM without EPT/NPT" do
    expect(verdict(tdp: false).caveats).to eq [described_class::NO_TDP]
  end

  it "refuses today's VMs on a KVM host without 1G pages, and not on arm64" do
    v = verdict(cpu_flags: %w[vmx])
    expect([v.tier, v.standard_vms?, v.fix, v.checks["pdpe1gb"]]).to eq ["kvm", false, described_class::NO_1G_FIX, "fail"]
    expect(v.text).to end_with "recommended: apply the fix above and probe again"
    v = verdict(arch: "aarch64", cpu_flags: [])
    expect([v.standard_vms?, v.checks["pdpe1gb"], v.caveats]).to eq [true, "skip", []]
  end

  it "reads a v1 report, and leaves the facts it lacks unknown" do
    v1 = facts.except("tdp", "kvm_errno", "kvm_create_vm", "kvm_caps_missing", "bios_log", "cgroup2", "commands", "ovmf")
    v = described_class.parse(JSON.generate("version" => 1, "tier" => "kvm", "reasons" => [], "nested" => false, "facts" => v1))
    expect([v.tier, v.standard_vms?]).to eq ["kvm", true]
    expect(v.checks.values_at("kvm_create_vm", "kvm_capabilities", "firmware")).to eq %w[unknown unknown unknown]
    expect(v.caveats).to eq [format(described_class::UNKNOWN_CAVEAT, "kvm_create_vm, kvm_capabilities, firmware")]
  end

  it "decides the tier from the facts, never from the host's own verdict" do
    v = described_class.parse(JSON.generate(VirtProbe.report(facts).merge("tier" => "none", "reasons" => ["trust me"], "nested" => true)))
    expect([v.tier, v.reasons, v.nested]).to eq ["kvm", ["/dev/kvm answers KVM_GET_API_VERSION 12"], false]
  end

  it "sanitises what a host reports before it prints or stores it" do
    v = verdict(cpu_model: "Evil\e]0;owned\aCPU #{"x" * 300}", cpu_flags: %w[hypervisor], dev_kvm: false, virt_vm: "kvm\nfix: rm -rf /", dmi: {"sys_vendor" => "Hetzner\r"})
    expect(v.text).not_to match(/[\e\a\r]/)
    expect(v.text.lines.grep(/\Afix: rm/)).to eq []
    expect(v.platform.key).to eq "hetzner_cloud"
    expect(v.record["facts"]["cpu_model"].size).to eq VirtProbe::MAX_STRING
    expect(described_class.sanitize("a\eb")).to eq "ab"
  end

  describe "fixes" do
    it "tells how to enable VT-x on bare metal" do
      v = verdict(cpu_flags: [], dev_kvm: false, kvm_api: nil, modules: [])
      expect([v.tier, v.rung, v.standard_vms?, v.cause]).to eq ["kvm_blocked", "L2", false, "firmware"]
      expect(v.fix).to start_with "Enable Intel VT-x or AMD-V"
      expect(v.text).to start_with "tier: kvm_blocked (L2 probably fixable)\n"
      expect(v.summary).to eq "kvm_blocked (L2) on unknown platform: bare metal without the vmx or svm flag: the firmware has VT-x/AMD-V disabled"
    end

    it "tells how to set the CPU type" do
      v = verdict(cpu_model: "Common KVM processor", virt_vm: "kvm", dmi: {"sys_vendor" => "QEMU"})
      expect(v.fix).to start_with("Give this VM the host's CPU model").and include("qm set <vmid> --cpu host")
    end

    it "tells how to load the KVM module, with the platform fix inside a VM" do
      expect(verdict(dev_kvm: false, kvm_api: nil, modules: []).fix).to eq "Load the KVM module (modprobe kvm_intel, or kvm_amd) and persist it under /etc/modules-load.d; if it refuses to load, check the kernel log for \"disabled by bios\"."
      v = verdict(cpu_flags: %w[vmx hypervisor], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "vmware", dmi: {"sys_vendor" => "VMware, Inc."})
      expect(v.fix).to end_with "(vhv.enable = \"TRUE\")."
    end

    it "tells what to do about a KVM without what cloud-hypervisor needs" do
      expect(verdict(kvm_caps_missing: ["Xcrs"]).fix).to eq "KVM here cannot run cloud-hypervisor's VMs. Update the host kernel; inside a VM, also use a hypervisor or instance type with full nested virtualization."
      expect(verdict(kvm_create_vm: "Out of memory", virt_vm: "kvm").fix).to end_with ByohVirtPlatforms::GENERIC_FIX
    end

    it "tells how to make a silent /dev/kvm usable" do
      expect(verdict(kvm_api: "Inappropriate ioctl for device", kvm_errno: "ENOTTY").fix).to eq "Make /dev/kvm usable: check that the KVM module loaded cleanly (kernel log) and that udev created /dev/kvm. #{ByohVirtPlatforms::GENERIC_FIX}"
    end

    it "asks for root when /dev/kvm refused to open" do
      v = verdict(kvm_api: "Permission denied", kvm_errno: "EACCES")
      expect([v.tier, v.rung, v.recommended]).to eq ["unknown_permission", "unknown", nil]
      expect(v.fix).to start_with "Probe as root"
    end

    it "tells how to load kvm_pvm" do
      v = verdict(**no_virt, pvm_module_available: true)
      expect([v.tier, v.rung, v.possible, v.recommended]).to eq ["pvm_blocked", "L3-L5", %w[container pvm emulated], "container"]
      expect(v.fix).to start_with "modprobe kvm_pvm"
    end

    it "refuses VMs on a PVM host and names the way to L1" do
      v = verdict(cpu_flags: %w[hypervisor], modules: %w[kvm kvm_pvm], virt_vm: "kvm", dmi: {"sys_vendor" => "Hetzner"})
      expect([v.tier, v.rung, v.standard_vms?, v.caveats, v.recommended]).to eq ["pvm", "L4", false, [], "pvm"]
      expect(v.fix).to include("This is a PVM host").and include("Hetzner dedicated server")
    end

    it "words the platform fix by whether the platform offers nested virtualization" do
      gcp = verdict(**no_virt, dmi: {"sys_vendor" => "Google", "product_name" => "Google Compute Engine"})
      expect([gcp.tier, gcp.rung, gcp.platform_name]).to eq ["none", "L3-L5", "Google Compute Engine"]
      expect(gcp.fix).to start_with("Fixable by changing the instance type or a VM option: Recreate the VM").and end_with(described_class::FALLBACKS)
      expect(verdict(**no_virt, dmi: {"sys_vendor" => "Scaleway"}).fix).to start_with "Ask your provider whether nested virtualization can be enabled. Check whether"
      expect(verdict(**no_virt, dmi: {"sys_vendor" => "Vultr"}).fix).to start_with "Vultr cloud instances"
      expect(verdict(**no_virt, dmi: {}).fix).to start_with ByohVirtPlatforms::GENERIC_FIX
    end

    it "refuses a container" do
      v = verdict(virt_container: "docker")
      expect([v.tier, v.rung]).to eq ["container", "refused"]
      expect(v.fix).to eq "Run the data plane on a VM or bare metal, not in a container."
      expect(v.text).to end_with "recommended: use a VM or bare metal as the data plane"
    end
  end

  describe "the plan in the text" do
    it "prints the cost of the fix, the fallbacks and the recommendation" do
      v = verdict(**no_virt, dmi: {"sys_vendor" => "Amazon EC2", "product_name" => "m7i.large"}, commands: {"qemu-system-x86_64" => true}, ovmf: true)
      expect(v.text).to include("\ncost: #{ByohVirtPlatforms::AWS_COST}\n")
        .and include("\nfallbacks ready: emulated\nfallbacks possible after installing their packages: container\n")
        .and end_with("recommended: #{described_class::FALLBACK_LABELS["container"]} after apt-get install lxc lxcfs uidmap; fallbacks cannot be registered yet (docs/byoh/NO_KVM.md section 11)")
    end

    it "says when no fallback is installed, and when the recommended one is" do
      v = verdict(**no_virt, commands: {"lxc-start" => true, "lxcfs" => true})
      expect(v.text).to include("fallbacks ready: container\nfallbacks possible after installing their packages: emulated\n")
        .and include("recommended: #{described_class::FALLBACK_LABELS["container"]}; fallbacks")
      expect(verdict(**no_virt).text).to include("fallbacks ready: none\n")
      expect(verdict(**no_virt, kernel: "5.4.0", commands: {"qemu-system-x86_64" => true}, ovmf: true).text).not_to include("possible after")
    end
  end

  describe ".checks" do
    it "says which facts were not gathered" do
      expect(described_class.checks({})).to eq(
        "kvm_device" => "unknown", "kvm_open" => "skip", "kvm_create_vm" => "skip", "kvm_capabilities" => "skip",
        "cpu_model" => "unknown", "pdpe1gb" => "skip", "firmware" => "unknown",
      )
      expect(described_class.checks("dev_kvm" => true, "arch" => "x86_64")).to include("kvm_device" => "pass", "kvm_open" => "unknown", "pdpe1gb" => "unknown")
    end

    it "fails what failed" do
      f = facts(dev_kvm: true, kvm_api: 11, kvm_create_vm: "Out of memory", kvm_caps_missing: ["Xcrs"], cpu_model: "QEMU Virtual CPU", cpu_flags: [], bios_log: "kvm: disabled by bios")
      expect(described_class.checks(f).values.uniq).to eq ["pass", "fail"]
      expect(described_class.checks(facts(dev_kvm: false))["kvm_device"]).to eq "fail"
    end
  end

  describe ".preflight_check" do
    it "passes an L1 host, and says when facts were missing" do
      expect(described_class.preflight_check(facts)).to include(status: "pass", tier: "kvm", rung: "L1", fix: nil, caveats: [], platform: nil)
      shell = facts.slice("arch", "cpu_model", "cpu_flags", "dev_kvm", "modules", "virt_vm", "virt_container", "dmi")
      result = described_class.preflight_check(shell, declared_tier: "kvm")
      expect(result).to include(status: "info", tier: "kvm")
      expect(result[:checks].values_at("kvm_open", "firmware")).to eq %w[unknown unknown]
      expect(result[:caveats].last).to include("Prog::LearnVirt checks them at prep")
    end

    it "fails a host off L1 with the fix" do
      result = described_class.preflight_check(facts(cpu_model: "Common KVM processor", dmi: {"sys_vendor" => "QEMU"}, virt_vm: "kvm"))
      expect(result).to include(status: "fail", tier: "kvm_blocked", platform: "qemu_kvm")
      expect(result[:fix]).to include("qm set <vmid> --cpu host")
    end

    it "refuses an unknown tier" do
      expect { described_class.preflight_check(facts, declared_tier: "magic") }.to raise_error(ArgumentError, "unknown tier \"magic\"; expected one of kvm, container, pvm, emulated")
    end

    it "gates a declared fallback on its own readiness" do
      ready = facts(**no_virt, commands: {"lxc-start" => true, "lxcfs" => true})
      result = described_class.preflight_check(ready, declared_tier: "container")
      expect(result).to include(status: "pass", fix: nil)
      expect(result[:caveats].first).to start_with "KVM: none (L3-L5)"
      expect(described_class.preflight_check(facts(**no_virt), declared_tier: "emulated")).to include(status: "fail", fix: "Prepare emulated first: apt-get install qemu-system-x86 ovmf.")
      expect(described_class.preflight_check(facts(**no_virt), declared_tier: "pvm")).to include(status: "fail", fix: "This host cannot run pvm: #{described_class::FALLBACK_LABELS["pvm"]} needs a kernel that ships kvm_pvm.")
    end

    it "refuses a fallback where KVM works, in a container, without root, and beside PVM" do
      expect(described_class.preflight_check(facts, declared_tier: "container")).to include(status: "fail", fix: "This host runs KVM (L1); register it as kvm.")
      expect(described_class.preflight_check(facts(virt_container: "docker"), declared_tier: "emulated")[:fix]).to start_with "Run the data plane on a VM"
      expect(described_class.preflight_check(facts(kvm_errno: "EPERM", kvm_api: "Operation not permitted"), declared_tier: "container")[:fix]).to start_with "Probe as root"
      pvm = facts(cpu_flags: %w[hypervisor], modules: %w[kvm kvm_pvm], virt_vm: "kvm")
      expect(described_class.preflight_check(pvm, declared_tier: "container")).to include(status: "fail", fix: "This is a PVM host; register it as pvm.")
      expect(described_class.preflight_check(pvm, declared_tier: "pvm")).to include(status: "pass")
    end
  end

  it "records the verdict with the report" do
    record = verdict(dmi: {"sys_vendor" => "QEMU"}, virt_vm: "kvm", cpu_flags: %w[vmx hypervisor pdpe1gb]).record
    expect(record).to include("version" => 2, "tier" => "kvm", "rung" => "L1", "platform" => "qemu_kvm", "fix" => nil, "nested" => true, "cause" => nil, "recommended" => nil)
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
    expect { described_class.parse('{"version":3}') }.to raise_error(described_class::ParseError, "virt-probe report version 3 is not one of 1, 2")
    expect { described_class.parse('{"version":2,"tier":"magic"}') }.to raise_error(described_class::ParseError, "unknown tier \"magic\"")
    expect { described_class.parse('{"version":2,"tier":"kvm"}') }.to raise_error(described_class::ParseError, "virt-probe report has no facts")
  end

  it "builds a remote script that runs the probe" do
    expect(described_class.remote_script).to start_with("# frozen_string_literal: true\n").and end_with("\nexit VirtProbe.main(ARGV)\n")
  end
end
