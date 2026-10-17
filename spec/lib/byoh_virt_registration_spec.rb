# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../../rhizome/host/lib/virt_probe"

RSpec.describe ByohVirtRegistration do
  def facts(**over)
    {
      "arch" => "x86_64", "kernel" => "6.8.0-1-generic", "cpu_vendor" => "GenuineIntel", "cpu_model" => "Intel Xeon",
      "cpu_flags" => %w[vmx pdpe1gb], "tdp" => true, "dev_kvm" => true, "kvm_api" => 12, "kvm_errno" => nil,
      "kvm_create_vm" => true, "kvm_caps_missing" => [], "modules" => %w[kvm kvm_intel], "nested_param" => true,
      "pvm_module_available" => false, "bios_log" => nil, "virt_vm" => "none", "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Dell Inc.", "product_name" => "PowerEdge R650"}, "cgroup2" => true, "apparmor" => true,
      "commands" => {**VirtProbe::CONTAINER_COMMANDS.to_h { [it, true] }, "qemu-system-x86_64" => true}, "ovmf" => true,
    }.merge(over.transform_keys(&:to_s))
  end

  no_virt = {cpu_flags: %w[hypervisor pdpe1gb], dev_kvm: false, kvm_api: nil, kvm_create_vm: nil, kvm_caps_missing: nil, modules: [], virt_vm: "kvm",
             dmi: {"sys_vendor" => "Hetzner", "product_name" => "vServer"}}

  probe_table = {
    "kvm" => {},
    "kvm without 1G pages" => {cpu_flags: %w[vmx]},
    "kvm_blocked" => {dev_kvm: false, kvm_api: nil, kvm_create_vm: nil, kvm_caps_missing: nil, modules: []},
    "unknown_permission" => {kvm_api: "Permission denied", kvm_errno: "EACCES", kvm_create_vm: nil, kvm_caps_missing: nil},
    "none" => no_virt,
    "pvm_blocked" => no_virt.merge(pvm_module_available: true, vulnerabilities: {"meltdown" => "Not affected"}),
    "pvm" => no_virt.merge(dev_kvm: true, kvm_api: 12, kvm_create_vm: true, kvm_caps_missing: [], modules: %w[kvm kvm_pvm], vulnerabilities: {"meltdown" => "Not affected"}),
    "container" => {virt_container: "docker"},
    "unknown" => {dev_kvm: nil, kvm_api: nil, kvm_create_vm: nil, kvm_caps_missing: nil},
    "not probed" => nil,
  }.freeze

  # Probe => the tier each declared value registers, or the start of its
  # refusal (docs/byoh/NO_KVM.md section 3.2).
  matrix = {
    "kvm" => {"kvm" => "kvm", "auto" => "kvm", "container" => /This host runs KVM \(L1\); register it as kvm/, "pvm" => /This host runs KVM/, "emulated" => /This host runs KVM/},
    "kvm without 1G pages" => {"kvm" => /refused: The CPU does not show pdpe1gb/, "auto" => /refused: The CPU does not show pdpe1gb.* Then: fix KVM on the host, or declare a tier/m, "container" => "container", "pvm" => /cannot run pvm/, "emulated" => "emulated"},
    "kvm_blocked" => {"kvm" => /refused: Load the KVM module/, "auto" => /fix KVM on the host, or declare a tier explicitly/, "container" => "container", "pvm" => /cannot run pvm/, "emulated" => "emulated"},
    "unknown_permission" => {"kvm" => /refused: Probe as root/, "auto" => /refused: Probe as root/, "container" => /refused: Probe as root/, "pvm" => /refused: Probe as root/, "emulated" => /refused: Probe as root/},
    "none" => {"kvm" => /refused: Hetzner Cloud/, "auto" => "container", "container" => "container", "pvm" => /cannot run pvm/, "emulated" => "emulated"},
    "pvm_blocked" => {"kvm" => /refused: modprobe kvm_pvm/, "auto" => "container", "container" => "container", "pvm" => /Prepare pvm first: modprobe kvm_pvm/, "emulated" => "emulated"},
    "pvm" => {"kvm" => /refused: This is a PVM host/, "auto" => "pvm", "container" => /register it as pvm/, "pvm" => "pvm", "emulated" => /register it as pvm/},
    "container" => {"kvm" => /refused: Run the data plane on a VM or bare metal/, "auto" => /refused: Run the data plane/, "container" => /Run the data plane/, "pvm" => /Run the data plane/, "emulated" => /Run the data plane/},
    "unknown" => {"kvm" => "kvm", "auto" => /refused: Gather what is missing/, "container" => "container", "pvm" => "pvm", "emulated" => "emulated"},
    "not probed" => {"kvm" => "kvm", "auto" => /auto needs the probe, which failed: SSH refused/, "container" => "container", "pvm" => "pvm", "emulated" => "emulated"},
  }.freeze

  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:probes) { probe_table }

  before do
    ship_virt_tiers("container", "pvm", "emulated")
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container pvm emulated], "acks" => {"container" => [], "pvm" => [], "emulated" => []}, "pvm_kernel" => pvm_test_pins}))
  end

  def verdict_for(probe)
    probes.fetch(probe)&.then { ByohVirtLadder.from_facts(facts(**it)) }
  end

  matrix.each do |probe, row|
    row.each do |declared, expected|
      it "#{expected.is_a?(String) ? "registers #{expected}" : "refuses"} for a #{probe} probe declared #{declared}" do
        virt = described_class.new(declared:, accept_fallback: true)
        decide = -> { virt.decide!(verdict_for(probe), location:, main_ip: "203.0.113.42", unprobed_reason: "SSH refused") }
        if expected.is_a?(String)
          decision = decide.call
          expect(decision.tier).to eq expected
          record = {"declared" => declared, "tier" => expected, "probe" => verdict_for(probe)&.tier, "accepted_fallback" => expected != "kvm"}
          # pvm adds what its kernel install needs (none here).
          meltdown = verdict_for(probe)&.report&.dig("facts", "vulnerabilities", "meltdown")
          record.merge!("install_pvm_kernel" => false, "lockdown" => nil, "meltdown" => meltdown) if expected == "pvm"
          expect(decision.record).to eq record
          expect(decision.pvm_install).to eq((expected == "pvm") ? "committed" : nil)
        else
          expect { decide.call }.to raise_error(described_class::Refused, expected)
        end
      end
    end
  end

  it "refuses a PVM host whose CPU needs Meltdown mitigation, even with auto" do
    affected = ByohVirtLadder.from_facts(facts(**probe_table["pvm"], vulnerabilities: {"meltdown" => "Mitigation: PTI"}))
    %w[pvm auto].each do |declared|
      expect { described_class.new(declared:, accept_fallback: true).decide!(affected, location:, main_ip: "x") }
        .to raise_error(described_class::Refused, /refused: This CPU's Meltdown status is "Mitigation: PTI"/)
    end
  end

  it "notes what the probe could not check" do
    expect(described_class.new.decide!(nil, location:, main_ip: "203.0.113.42", unprobed_reason: "SSH refused").notes)
      .to eq ["the host was not probed (SSH refused); prep goes on, and Prog::LearnVirt pages there if the host cannot run VMs"]
    expect(described_class.new(declared: "emulated", accept_fallback: true).decide!(nil, location:, main_ip: "x", unprobed_reason: "SSH refused").notes)
      .to eq ["the host was not probed (SSH refused); Prog::LearnVirt checks it at prep, and the emulated host waits there until the probe agrees"]
    expect(described_class.new(declared: "emulated", accept_fallback: true).decide!(verdict_for("unknown"), location:, main_ip: "x").notes.first)
      .to start_with "emulated: Whether KVM works here is unknown"
    nested = ByohVirtLadder.from_facts(facts(cpu_flags: %w[vmx pdpe1gb hypervisor], virt_vm: "kvm"))
    expect(described_class.new.decide!(nested, location:, main_ip: "x").notes).to eq nested.caveats
  end

  it "needs --accept-fallback for every tier below kvm, auto included" do
    expect { described_class.new(declared: "auto").decide!(verdict_for("none"), location:, main_ip: "x") }
      .to raise_error(described_class::Refused, /\Athe probe found none \(L3-L5\) on Hetzner Cloud.*container is System container: shared host kernel, near-native speed\. Not a VM\. Pass --accept-fallback/m)
    expect { described_class.new(declared: "emulated").decide!(nil, location:, main_ip: "x", unprobed_reason: "skipped") }
      .to raise_error(described_class::Refused, /\Aemulated is Emulated: slow, compatibility only/)
  end

  it "refuses boot images the tier cannot boot, with the ones it can" do
    auto = described_class.new(declared: "auto", accept_fallback: true)
    expect { auto.decide!(verdict_for("none"), location:, main_ip: "x", boot_images: %w[ubuntu-noble]) }
      .to raise_error(described_class::Refused, /\Athe probe found none .*a container host cannot boot ubuntu-noble; its images are ubuntu-noble-container\. Drop --default-boot-image \(the host then downloads ubuntu-noble-container\) or pass --default-boot-image ubuntu-noble-container\.\z/m)
    expect(auto.decide!(verdict_for("none"), location:, main_ip: "x", boot_images: %w[ubuntu-noble-container]).tier).to eq "container"
    expect(described_class.new(declared: "emulated", accept_fallback: true).decide!(verdict_for("none"), location:, main_ip: "x", boot_images: %w[ubuntu-noble ubuntu-jammy]).tier).to eq "emulated"
    expect(described_class.new.decide!(verdict_for("kvm"), location:, main_ip: "x", boot_images: %w[ubuntu-noble]).tier).to eq "kvm"
  end

  it "refuses a tier the location does not offer, with the commands that offer it" do
    location.update(byoh_virt: nil)
    expect { described_class.new(declared: "container", accept_fallback: true).decide!(verdict_for("none"), location:, main_ip: "x") }
      .to raise_error(described_class::Refused, /location byoh-test does not offer container hosts\. To allow them:\n  bin\/byoh-location rates --location byoh-test --family container --from standard --multiplier <X>\n  bin\/byoh-location set --location byoh-test --virt-tiers kvm,container --accept container\z/)
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["container"], "acks" => {"container" => []}}))
    expect { described_class.new.decide!(verdict_for("kvm"), location:, main_ip: "x") }
      .to raise_error(described_class::Refused, /location byoh-test does not offer kvm hosts\. To allow them:\n  bin\/byoh-location set --location byoh-test --virt-tiers container,kvm\z/)
  end

  it "refuses a tier that is not shipped" do
    ship_virt_tiers
    expect { described_class.new(declared: "emulated", accept_fallback: true).decide!(verdict_for("none"), location:, main_ip: "x") }
      .to raise_error(described_class::Refused, /emulated hosts are not available yet/)
    expect { described_class.new(declared: "auto", accept_fallback: true).decide!(verdict_for("pvm"), location:, main_ip: "x") }
      .to raise_error(described_class::Refused, /\Athe probe found .*pvm hosts are not available yet/m)
  end

  it "refuses a declared tier that is not shipped before the probe's preflight, on every host" do
    ship_virt_tiers("container", "emulated")
    probe_table.each_key do |probe|
      expect { described_class.new(declared: "pvm", accept_fallback: true).decide!(verdict_for(probe), location:, main_ip: "x", unprobed_reason: "skipped") }
        .to raise_error(described_class::Refused, /pvm hosts are not available yet: this control plane's rhizome cannot run them/)
    end
  end

  it "refuses unknown declarations and auto without a probe" do
    expect { described_class.new(declared: "tcg") }.to raise_error(described_class::Refused, "--virt-tier tcg is not one of kvm, auto, container, pvm, emulated")
    expect { described_class.new(declared: "auto", probe: false) }.to raise_error(described_class::Refused, /auto needs the probe/)
    expect(described_class.new(declared: nil).declared).to eq "kvm"
  end

  it "prints the commands that register a host on its fastest option" do
    location.update(byoh_virt: nil)
    refusal = begin
      described_class.new.decide!(verdict_for("none"), location:, main_ip: "203.0.113.42")
    rescue described_class::Refused => e
      e.message
    end
    expect(refusal).to end_with <<~TEXT.chomp
      to register it on its fastest option:
        bin/byoh-location rates --location byoh-test --family container --from standard --multiplier <X>
        bin/byoh-location set --location byoh-test --virt-tiers kvm,container --accept container
        bin/register-byoh-host --location byoh-test --main-ip 203.0.113.42 ... --virt-tier auto --accept-fallback
    TEXT
    expect(described_class.recommended_commands(verdict_for("kvm"), location:, main_ip: "203.0.113.42"))
      .to eq ["bin/register-byoh-host --location byoh-test --main-ip 203.0.113.42 ..."]
    expect(described_class.recommended_commands(verdict_for("kvm_blocked"), location:, main_ip: "x")).to eq []
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container], "acks" => {"container" => []}}))
    expect(described_class.recommended_commands(verdict_for("none"), location:, main_ip: "x"))
      .to eq ["bin/register-byoh-host --location byoh-test --main-ip x ... --virt-tier auto --accept-fallback"]
  end

  it "names the PVM kernel pins in the commands for a PVM host" do
    location.update(byoh_virt: nil)
    expect(described_class.recommended_commands(verdict_for("pvm"), location:, main_ip: "x")).to eq [
      "bin/byoh-location rates --location byoh-test --family pvm --from standard --multiplier <X>",
      "bin/byoh-location set --location byoh-test --virt-tiers kvm,pvm --accept pvm --pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX",
      "bin/register-byoh-host --location byoh-test --main-ip x ... --virt-tier auto --accept-fallback",
    ]
  end

  it "prints no commands for a fallback that is not shipped" do
    ship_virt_tiers
    location.update(byoh_virt: nil)
    %w[none pvm_blocked].each do |probe|
      refusal = begin
        described_class.new.decide!(verdict_for(probe), location:, main_ip: "203.0.113.42")
      rescue described_class::Refused => e
        e.message
      end
      expect(refusal).to include("fallbacks cannot be registered yet").and include("refused: ")
      expect(refusal).not_to include "fastest option"
      expect(refusal).not_to include "bin/byoh-location set"
      expect(refusal).not_to include "--virt-tier auto"
    end
    expect(described_class.recommended_commands(verdict_for("pvm"), location:, main_ip: "x")).to eq []
    expect(described_class.recommended_commands(verdict_for("kvm"), location:, main_ip: "x"))
      .to eq ["bin/register-byoh-host --location byoh-test --main-ip x ..."]
  end

  describe "#preflight_tier" do
    it "is the declared tier, or for auto what the facts say" do
      expect(described_class.new(declared: "container").preflight_tier(nil)).to eq "container"
      auto = described_class.new(declared: "auto")
      expect(auto.preflight_tier(nil)).to eq "kvm"
      expect(auto.preflight_tier(facts)).to eq "kvm"
      expect(auto.preflight_tier(facts(**no_virt))).to eq "container"
      expect(auto.preflight_tier(facts(virt_container: "docker"))).to eq "kvm"
    end
  end

  describe "#unprobed_reason" do
    it "says why preflight gave no verdict" do
      expect(described_class.new(probe: false).unprobed_reason(nil)).to eq "the probe was skipped (--no-virt-probe)"
      expect(described_class.new.unprobed_reason(nil)).to eq "preflight was skipped"
      expect(described_class.new.unprobed_reason(Object.new)).to eq "preflight reported no virtualization facts"
    end
  end

  it "adds its options to a parser" do
    options = {}
    parser = OptionParser.new { described_class.add_options(it, options) }
    parser.parse(%w[--virt-tier auto --accept-fallback --no-virt-probe])
    expect(options).to eq(virt_tier: "auto", accept_fallback: true, virt_probe: false)
  end
end
