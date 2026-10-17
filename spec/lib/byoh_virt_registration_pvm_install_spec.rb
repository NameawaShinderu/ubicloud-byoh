# frozen_string_literal: true

require_relative "../model/spec_helper"
require "tmpdir"
require_relative "../../rhizome/host/lib/virt_probe"
require_relative "../../rhizome/host/spec/virt_probe_fixtures"

# Registration of a pvm host whose PVM kernel the control plane installs
# (--install-pvm-kernel, docs/byoh/NO_KVM.md section 6.7).
RSpec.describe ByohVirtRegistration, "pvm install" do
  def facts(**over)
    {
      "arch" => "x86_64", "kernel" => "7.0.0-1014-aws", "cpu_vendor" => "GenuineIntel", "cpu_model" => "Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz",
      "cpu_flags" => %w[hypervisor pdpe1gb], "tdp" => nil, "dev_kvm" => false, "kvm_api" => nil, "kvm_errno" => nil,
      "kvm_create_vm" => nil, "kvm_caps_missing" => nil, "modules" => [], "nested_param" => nil,
      "pvm_module_available" => false, "bios_log" => nil, "virt_vm" => "amazon", "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Amazon EC2", "product_name" => "m6i.2xlarge"}, "cgroup2" => true, "apparmor" => true,
      "commands" => VirtProbe::CONTAINER_COMMANDS.to_h { [it, true] }, "ovmf" => false, "secure_boot" => false, "lockdown" => "none",
      "vulnerabilities" => {"meltdown" => "Not affected"},
    }.merge(over.transform_keys(&:to_s))
  end

  def verdict(**) = ByohVirtLadder.from_facts(facts(**))

  # The probes of a stock kernel, and of the hosts an install is wrong for.
  probes = {
    "none" => {},
    "pvm_blocked" => {pvm_module_available: true},
    "kvm_blocked (generic CPU)" => {cpu_model: "QEMU Virtual CPU version 2.5+", virt_vm: "kvm", dmi: {"sys_vendor" => "QEMU"}},
    "kvm_blocked (generic CPU, ships kvm_pvm)" => {cpu_model: "QEMU Virtual CPU version 2.5+", virt_vm: "kvm", dmi: {"sys_vendor" => "QEMU"}, pvm_module_available: true},
    "kvm_blocked (vmx, no module)" => {cpu_flags: %w[vmx pdpe1gb], virt_vm: "none", dmi: {"sys_vendor" => "Dell Inc."}},
    "kvm" => {cpu_flags: %w[vmx pdpe1gb hypervisor], dev_kvm: true, kvm_api: 12, kvm_create_vm: true, kvm_caps_missing: [], modules: %w[kvm kvm_intel]},
    "pvm" => {dev_kvm: true, kvm_api: 12, kvm_create_vm: true, kvm_caps_missing: [], modules: %w[kvm kvm_pvm]},
    "container" => {virt_container: "docker"},
    "unknown" => {dev_kvm: nil, cpu_flags: nil},
  }.freeze

  # Probe => [what --virt-tier pvm --install-pvm-kernel gives, what
  # --virt-tier auto --install-pvm-kernel gives]: a tier, or the start of
  # the refusal.
  golden = {
    "none" => ["pvm (install)", "pvm (install)"],
    "pvm_blocked" => [/refused \(--install-pvm-kernel\): The running kernel ships kvm_pvm, so it is a PVM kernel already; modprobe kvm_pvm and register the host as pvm without --install-pvm-kernel\.\z/, "container"],
    "kvm_blocked (generic CPU, ships kvm_pvm)" => [/refused \(--install-pvm-kernel\): The running kernel ships kvm_pvm/, /refused: Give this VM the host's CPU model/],
    "kvm_blocked (generic CPU)" => ["pvm (install)", /refused: Give this VM the host's CPU model/],
    "kvm_blocked (vmx, no module)" => [/refused \(--install-pvm-kernel\): The CPU has vmx: this host has hardware virtualization/, /refused: Load the KVM module/],
    "kvm" => [/refused \(--install-pvm-kernel\): This host runs KVM \(L1\)/, "kvm"],
    "pvm" => [/refused \(--install-pvm-kernel\): This host already runs a PVM kernel/, "pvm"],
    "container" => [/refused \(--install-pvm-kernel\): The control plane cannot install a PVM kernel on this host: container/, /refused: Run the data plane/],
    "unknown" => [/refused \(--install-pvm-kernel\): The control plane cannot install a PVM kernel on this host: unknown/, /refused: Gather what is missing/],
  }.freeze

  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }

  def offer(tiers: %w[kvm container pvm emulated], acks: {"container" => [], "pvm" => [], "emulated" => []}, pins: pvm_test_pins)
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => tiers, "acks" => acks, "pvm_kernel" => pins}.compact))
  end

  def registration(declared, **) = described_class.new(declared:, accept_fallback: true, install_pvm_kernel: true, **)

  def outcome(declared, v)
    decision = registration(declared).decide!(v, location:, main_ip: "203.0.113.42")
    decision.install_pvm_kernel ? "#{decision.tier} (install)" : decision.tier
  rescue described_class::Refused => ex
    ex.message
  end

  before do
    ship_virt_tiers("container", "pvm", "emulated")
    offer
  end

  probes.each do |probe, over|
    it "answers a #{probe} probe as the golden table says" do
      results = [outcome("pvm", verdict(**over)), outcome("auto", verdict(**over))]
      golden.fetch(probe).zip(results).each { |expected, got| expected.is_a?(String) ? expect(got).to(eq(expected)) : expect(got).to(match(expected)) }
    end
  end

  it "records the acknowledgement, the pin and the host's lockdown and Meltdown state" do
    decision = registration("pvm").decide!(verdict(lockdown: "integrity"), location:, main_ip: "x")
    expect(decision.record).to eq("declared" => "pvm", "tier" => "pvm", "probe" => "none", "accepted_fallback" => true,
      "install_pvm_kernel" => true, "host_deb_sha256" => "a" * 64, "lockdown" => "integrity", "meltdown" => "Not affected")
    expect([decision.pvm_install, decision.pvm_facts]).to eq ["install_pending", {"lockdown" => "integrity", "meltdown" => "Not affected"}]
    recorded = described_class::Recorded.new(tier: "pvm", record: JSON.parse(JSON.generate(decision.record)))
    expect([recorded.pvm_install, recorded.pvm_facts]).to eq [decision.pvm_install, decision.pvm_facts]
    expect(described_class::Recorded.new(tier: "container", record: {"tier" => "container"}).pvm_install).to be_nil
  end

  it "notes the install, a fixable KVM and a kernel lockdown" do
    notes = registration("pvm").decide!(verdict, location:, main_ip: "x").notes
    expect(notes).to eq ["pvm: the control plane installs the PVM host kernel pinned by location byoh-test (sha256 #{"a" * 64}), a third-party build, " \
      "then reboots the host into it once; the stock kernel 7.0.0-1014-aws stays the GRUB default (docs/byoh/NO_KVM.md section 6.7)"]
    blocked = verdict(**probes["kvm_blocked (generic CPU)"], lockdown: "integrity")
    notes = registration("pvm").decide!(blocked, location:, main_ip: "x").notes
    expect(notes[1]).to start_with "pvm: the probe says KVM could be switched on instead, which is faster and isolates better: Give this VM the host's CPU model"
    expect(notes[2]).to start_with "pvm: kernel lockdown is integrity on the stock kernel."
    expect(registration("pvm").decide!(verdict(lockdown: nil), location:, main_ip: "x").notes.size).to eq 1
  end

  it "refuses what PVM refuses on every host, before any change" do
    {
      {arch: "aarch64"} => "PVM is x86_64 only; this host is aarch64.",
      {arch: nil, cpu_flags: [], dev_kvm: false} => "The control plane cannot install a PVM kernel on this host: unknown",
      {vulnerabilities: {"meltdown" => "Mitigation: PTI"}} => "This CPU's Meltdown status is \"Mitigation: PTI\"",
      {vulnerabilities: nil} => "This CPU's Meltdown status was not gathered",
      {secure_boot: true} => "Secure Boot is on",
      {dev_kvm: true, kvm_api: "Inappropriate ioctl for device"} => "/dev/kvm exists on the stock kernel",
    }.each do |over, message|
      expect { registration("pvm").decide!(verdict(**over), location:, main_ip: "x") }
        .to raise_error(described_class::Refused, /refused \(--install-pvm-kernel\): #{Regexp.escape(message)}/)
    end
  end

  it "refuses a location that does not offer, acknowledge or pin pvm, with the commands that do" do
    fix = "location byoh-test does not offer pvm with pinned PVM kernels. To allow it:\n  " \
      "bin/byoh-location rates --location byoh-test --family pvm --from standard --multiplier <X>\n  " \
      "bin/byoh-location set --location byoh-test --virt-tiers kvm,container,pvm --accept pvm " \
      "--pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX"
    offer(tiers: %w[kvm container], acks: {"container" => []}, pins: nil)
    expect { registration("pvm").decide!(verdict, location:, main_ip: "x") }.to raise_error(described_class::Refused, /#{Regexp.escape(fix)}\z/)
    # The location's CHECK ties pvm to its acknowledgement and its pins,
    # so only an unsaved policy lacks them; the registration checks both
    # anyway.
    [{"tiers" => %w[kvm pvm], "acks" => {}}, {"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}}].each do |policy|
      location.byoh_virt = Sequel.pg_jsonb(policy)
      expect { registration("pvm").decide!(verdict, location:, main_ip: "x") }.to raise_error(described_class::Refused, /does not offer pvm with pinned PVM kernels/)
    end
  end

  it "lets auto fall back as it does without the flag, with a note, where no install fits" do
    offer(tiers: %w[kvm container], acks: {"container" => []}, pins: nil)
    decision = registration("auto").decide!(verdict, location:, main_ip: "x")
    expect([decision.tier, decision.install_pvm_kernel]).to eq ["container", false]
    expect(decision.notes.first).to start_with "--install-pvm-kernel was not used: location byoh-test does not offer pvm with pinned PVM kernels."
    offer
    note = registration("auto").decide!(verdict(vulnerabilities: {"meltdown" => "Vulnerable"}), location:, main_ip: "x").notes.first
    expect(note).to start_with "--install-pvm-kernel was not used: This CPU's Meltdown status is \"Vulnerable\""
    expect(registration("auto").decide!(verdict(**probes["kvm"]), location:, main_ip: "x").notes.first)
      .to eq "--install-pvm-kernel was not used: auto installs a PVM kernel only where the probe says none, and it says kvm; auto picked as it does without it"
    expect(registration("auto").decide!(verdict(**probes["pvm_blocked"]), location:, main_ip: "x").notes.first)
      .to eq "--install-pvm-kernel was not used: The running kernel ships kvm_pvm, so it is a PVM kernel already; modprobe kvm_pvm and register the host as pvm without --install-pvm-kernel.; auto picked as it does without it"
    ship_virt_tiers("container", "emulated")
    decision = registration("auto").decide!(verdict, location:, main_ip: "x")
    expect([decision.tier, decision.notes.first]).to eq ["container", "--install-pvm-kernel was not used: pvm hosts are not available yet; auto picked as it does without it"]
  end

  it "refuses pvm by an install while pvm is not shipped" do
    ship_virt_tiers("container", "emulated")
    expect { registration("pvm").decide!(verdict, location:, main_ip: "x") }.to raise_error(described_class::Refused, /pvm hosts are not available yet/)
  end

  it "takes the flag only with pvm or auto and the probe" do
    %w[kvm container emulated].each do |declared|
      expect { registration(declared) }.to raise_error(described_class::Refused, "--install-pvm-kernel goes with --virt-tier pvm or auto, not #{declared}")
    end
    expect { registration("pvm", probe: false) }.to raise_error(described_class::Refused, /needs the probe, which checks the host first/)
    expect { registration("pvm").decide!(nil, location:, main_ip: "x", unprobed_reason: "preflight was skipped") }
      .to raise_error(described_class::Refused, "--install-pvm-kernel needs the probe, which did not run: preflight was skipped")
    expect(described_class.new(declared: "pvm").install_pvm_kernel).to be false
  end

  it "has preflight judge the tier auto picks by an install" do
    auto = registration("auto")
    expect(auto.preflight_tier(facts, location:)).to eq "pvm"
    expect(auto.preflight_tier(facts)).to eq "container"
    expect(described_class.new(declared: "auto").preflight_tier(facts, location:)).to eq "container"
    expect(auto.pvm_install_preflight?("pvm")).to be true
    expect(auto.pvm_install_preflight?("container")).to be false
    expect(described_class.new(declared: "pvm").pvm_install_preflight?("pvm")).to be false
  end

  it "adds the flag to a parser" do
    options = {}
    OptionParser.new { described_class.add_options(it, options) }.parse(%w[--install-pvm-kernel])
    expect(options).to eq(install_pvm_kernel: true)
  end

  # Without the flag, auto picks on every fixture machine what it picked
  # before the flag existed; with it, in a location without pvm, the
  # same, with only the note added.
  describe "on every probe fixture" do
    vt = /refused: Enable Intel VT-x or AMD-V/
    kvm_module = /refused: Load the KVM module/
    lxc = /refused: Prepare container first/
    kvm_vms = /refused: KVM here cannot run cloud-hypervisor's VMs/
    cpu_model = /refused: Give this VM the host's CPU model/
    auto_golden = {
      "amd_svm_disabled_by_bios" => vt, "amd_svm_disabled_log_unread" => kvm_module, "aws_m7i" => "container",
      "aws_m8i_nested" => "kvm", "aws_m8i_nested_off" => lxc, "aws_metal_module" => kvm_module, "aws_xen_t2" => lxc,
      "bare_metal_kvm" => "kvm", "bare_metal_no_flags" => vt, "bare_metal_vmx_firmware_off" => vt,
      "dev_kvm_eacces" => /refused: Probe as root/, "docker_container" => /refused: Run the data plane on a VM or bare metal/,
      "gcp_e2" => lxc, "hetzner_cloud" => "container", "hidden_hypervisor_bit" => lxc, "intel_module_not_loaded" => kvm_module,
      "kvm_create_vm_refused" => kvm_vms, "kvm_missing_capability" => kvm_vms, "old_kernel_cgroup1" => /refused: Prepare emulated first/,
      "proxmox_host_cpu_no_pdpe1gb" => /refused: The CPU does not show pdpe1gb/, "proxmox_kvm64" => cpu_model,
      "proxmox_kvm64_vmx_nested" => cpu_model, "pvm_host" => /refused: This CPU's Meltdown status was not gathered/,
      "pvm_kernel_not_loaded" => "container", "shell_facts_without_dev_kvm" => /refused: Gather what is missing \(dev_kvm\)/,
    }

    let(:fixture_verdicts) do
      VirtProbeFixtures.all.to_h do |name, fixture|
        Dir.mktmpdir do |root|
          [name, ByohVirtLadder.parse(JSON.generate(VirtProbe.report(VirtProbe.facts(root: VirtProbeFixtures.materialize(fixture, root)))))]
        end
      end
    end

    def auto_outcome(v, **)
      described_class.new(declared: "auto", accept_fallback: true, **).decide!(v, location:, main_ip: "x").tier
    rescue described_class::Refused => ex
      ex.message
    end

    it "keeps auto's answer without the flag" do
      results = fixture_verdicts.transform_values { auto_outcome(it) }
      expect(results.keys).to eq auto_golden.keys
      auto_golden.each { |name, expected| expected.is_a?(String) ? expect(results[name]).to(eq(expected), name) : expect(results[name]).to(match(expected), name) }
    end

    it "keeps it with the flag where the location has no pvm" do
      offer(tiers: %w[kvm container emulated], acks: {"container" => [], "emulated" => []}, pins: nil)
      fixture_verdicts.each do |name, v|
        expect(auto_outcome(v, install_pvm_kernel: true)).to eq(auto_outcome(v)), name
      end
    end

    it "installs only where the ladder's own stock-host check agrees" do
      fixture_verdicts.each do |name, v|
        installable = ByohVirtLadder.pvm_install_problem(v).nil?
        expect(installable).to eq(ByohVirtTiers.pvm_stock_host?(v) && ByohVirtLadder.pvm_refusal(v.report["facts"]).nil?), name
      end
    end
  end

  describe "Prog::Vm::HostNexus.assemble" do
    # Each host its own /64.
    def assemble(ip = "203.0.113.42", **)
      provider_config = {"main_ip4" => ip, "location_label" => "x", "routed_networks" => [{"cidr" => "fd00:feed:0:#{ip.split(".").last}::/64"}]}
      Prog::Vm::HostNexus.assemble(ip, location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME, provider_config:, **)
    end

    it "keeps the PVM kernel's state for a pvm host" do
      st = assemble(virt_tier: "pvm", pvm_install: "install_pending", pvm_facts: {"lockdown" => "none", "meltdown" => "Not affected"})
      expect(ByohPvmHost[st.id].values.slice(:state, :install, :lockdown, :meltdown, :host_kver, :stock_entry))
        .to eq(state: "install_pending", install: true, lockdown: "none", meltdown: "Not affected", host_kver: nil, stock_entry: nil)
      expect(VmHost[st.id].values.slice(:virt_tier, :family)).to eq(virt_tier: "pvm", family: "pvm")
      st = assemble("203.0.113.43", virt_tier: "pvm", pvm_install: "committed")
      expect(ByohPvmHost[st.id].values.slice(:state, :install, :lockdown)).to eq(state: "committed", install: false, lockdown: nil)
    end

    it "refuses a pvm host without a known install state, and the state on other tiers" do
      expect { assemble(virt_tier: "pvm") }.to raise_error(RuntimeError, "A pvm host is registered with pvm_install install_pending or committed, not nil")
      expect { assemble(virt_tier: "pvm", pvm_install: "armed") }.to raise_error(RuntimeError, /not "armed"/)
      expect { assemble(virt_tier: "container", pvm_install: "committed") }.to raise_error(RuntimeError, "Only a pvm host takes pvm_install")
      expect { assemble(pvm_install: "committed") }.to raise_error(RuntimeError, "Only a pvm host takes pvm_install")
      expect(assemble(virt_tier: "pvm", pvm_install: "committed").stack.first["default_boot_images"]).to eq %w[ubuntu-noble]
      expect([VmHost.count, ByohPvmHost.count]).to eq [1, 1]
    end

    it "gives kvm, container and emulated hosts no PVM state, as before" do
      images = {"kvm" => [], "container" => %w[ubuntu-noble-container], "emulated" => %w[ubuntu-noble]}
      images.each_with_index do |(tier, default_boot_images), i|
        st = assemble("203.0.113.#{50 + i}", virt_tier: tier)
        expect(VmHost[st.id].virt_tier).to eq tier
        expect(st.stack).to eq [{"vhost_block_backend_version" => Config.vhost_block_backend_version, "default_boot_images" => default_boot_images, "install_os" => false}]
      end
      expect(ByohPvmHost.count).to eq 0
    end
  end

  describe "ByohRegistration#register!" do
    let(:reg) { ByohRegistration.new(main_ip: "203.0.113.42", location:, pools: ["fd00:feed::/64"]) }

    it "registers the decision's PVM state and records the acknowledgement" do
      decision = registration("pvm").decide!(verdict, location:, main_ip: "203.0.113.42")
      host = VmHost[reg.register!(virt: decision).id]
      expect(ByohPvmHost[host.id].values.slice(:state, :install, :lockdown, :meltdown)).to eq(state: "install_pending", install: true, lockdown: "none", meltdown: "Not affected")
      expect(DB[:byoh_operator_action].first[:args]["virt"]).to eq decision.record
    end

    it "registers a host that runs a PVM kernel as committed, from a recorded decision" do
      record = {"declared" => "pvm", "tier" => "pvm", "probe" => "pvm", "accepted_fallback" => true, "install_pvm_kernel" => false, "lockdown" => nil, "meltdown" => "Not affected"}
      host = VmHost[reg.register!(virt: described_class::Recorded.new(tier: "pvm", record:)).id]
      expect(ByohPvmHost[host.id].values.slice(:state, :install, :meltdown)).to eq(state: "committed", install: false, meltdown: "Not affected")
    end
  end
end
