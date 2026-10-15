# frozen_string_literal: true

require "json"
require_relative "../rhizome/host/lib/virt_probe"

# The virtualization ladder of docs/byoh/NO_KVM.md, as the control plane
# sees it: takes the facts rhizome/host/lib/virt_probe.rb gathers on a
# host, says which rung the host is on, whether it can take today's VMs,
# what to fall back to, and how to fix it, naming the platform from
# ByohVirtPlatforms.
#
#   L1 kvm          cloud-hypervisor on KVM, as on every host today
#   L2 kvm_blocked  hardware can virtualize; KVM must be switched on
#   L3 container    system containers: shared kernel, near-native speed
#   L4 pvm          KVM without hardware support (out-of-tree kvm_pvm)
#   L5 emulated     the QEMU emulator: slow, compatibility only
#
# L3-L5 are fallbacks, opt-in and separately labelled; a host is
# registered on one only as ByohVirtRegistration allows, and only tiers
# in ByohVirtTiers::SHIPPED can be registered at all. The probe never refuses
# anything itself; PrepHost refuses a host without KVM as before, and
# Prog::LearnVirt records the verdict and pages with the fix.
#
# The tier is always decided here, from the facts (classify), never taken
# from the host's own report: an old probe on a host cannot overrule a
# newer control plane, and a host can only report facts, which are
# sanitised before anything prints or stores them.
#
# Hook for host preflight (M4's PF3): gather the facts over the
# preflight's own SSH session, either with the probe
# (ByohVirtLadder.remote_script piped to "ruby - --json", then
# ByohVirtLadder.parse) or in shell with the keys of VirtProbe.facts, and
# call ByohVirtLadder.preflight_check(facts, declared_tier:). A fact that
# was not gathered is "unknown" and never fails the check; LearnVirt
# checks again at prep.
module ByohVirtLadder
  class ParseError < StandardError; end

  PROBE_PATH = File.expand_path("../rhizome/host/lib/virt_probe.rb", __dir__)

  VERSIONS = [1, 2].freeze

  RUNGS = {
    "kvm" => "L1",
    "kvm_blocked" => "L2",
    "unknown_permission" => "unknown",
    "unknown" => "unknown",
    "pvm" => "L4",
    "pvm_blocked" => "L3-L5",
    "none" => "L3-L5",
    "container" => "refused",
  }.freeze

  FALLBACK_LABELS = {
    "container" => "L3 system containers (shared host kernel, near-native speed)",
    "pvm" => "L4 PVM (KVM in software; a kvm_pvm host kernel and PVM guest kernels)",
    "emulated" => "L5 the QEMU emulator (about 26-29% of native CPU speed; compatibility only)",
  }.freeze

  # What a fallback tier needs installed, for the operator's message.
  FALLBACK_PACKAGES = {
    "container" => "apt-get install lxc lxcfs uidmap",
    "pvm" => "modprobe kvm_pvm",
    "emulated" => "apt-get install qemu-system-x86 ovmf",
  }.freeze

  # What the kernel and CPU must offer for a fallback tier.
  FALLBACK_NEEDS = {
    "container" => "cgroup v2 and Linux 5.12 or newer",
    "pvm" => "a kernel that ships kvm_pvm",
    "emulated" => "an x86_64 host",
  }.freeze

  FALLBACKS = <<~TEXT.chomp
    Without hardware virtualization the fallbacks, fastest first, are: #{FALLBACK_LABELS.values.join(", ")}. None of them can be registered yet. See docs/byoh/NO_KVM.md.
  TEXT

  NESTED_CAVEATS = [
    "nested virtualization: CPU-bound work typically loses 10% or more, and memory- and page-fault-heavy work much more, since every guest page-table change traps to two hypervisors",
    "the provider may stop or restart this VM for maintenance, taking every VM on it down; plan for host restarts",
    "the clocksource is often not tsc and disks are virtual, so bin/monitor health checks may misfire (docs/byoh/PLATFORMS.md F5)",
  ].freeze

  NO_TDP = "KVM runs without EPT/NPT here, so guests use shadow page tables and memory-heavy work is very slow; expose EPT/NPT to this VM (CPU type host)"

  NO_1G_FIX = "The CPU does not show pdpe1gb, so there are no 1G hugepages for VMs (Prog::SetupHugepages). Give this VM the host's CPU model (Proxmox: qm set <vmid> --cpu host; libvirt: <cpu mode='host-passthrough'/>) or use an instance type whose CPU shows pdpe1gb."

  UNKNOWN_CAVEAT = "some KVM facts were not gathered (%s); Prog::LearnVirt checks them at prep"

  DECLARED_TIERS = %w[kvm container pvm emulated].freeze

  Verdict = Data.define(:tier, :cause, :rung, :nested, :reasons, :platform, :fix, :cost_hint, :caveats, :possible, :ready, :unchecked, :recommended, :checks, :report) do
    # Whether the host can take today's VMs: KVM that cloud-hypervisor
    # can use, and 1G pages for their hugepages.
    def standard_vms? = tier == "kvm" && checks["pdpe1gb"] != "fail"

    def platform_name = platform&.name || "unknown platform"

    def summary
      "#{tier} (#{rung}) on #{platform_name}: #{reasons.join("; ")}"
    end

    # What Prog::LearnVirt stores in vm_host.virt_probe.
    def record
      report.merge("tier" => tier, "cause" => cause, "reasons" => reasons, "nested" => nested, "rung" => rung,
        "platform" => platform&.key, "fix" => fix, "caveats" => caveats, "possible" => possible, "ready" => ready,
        "unchecked" => unchecked, "recommended" => recommended)
    end

    def text
      label = (tier == "kvm_blocked") ? " probably fixable" : ""
      lines = ["tier: #{tier} (#{rung}#{label})#{" nested" if nested}", "platform: #{platform_name}", "why: #{reasons.join("; ")}"]
      lines << "fix: #{fix}" if fix
      lines << "cost: #{cost_hint}" if cost_hint && !standard_vms?
      caveats.each { lines << "caveat: #{it}" }
      unless (possible + unchecked).empty?
        lines << "fallbacks ready: #{ready.empty? ? "none" : ready.join(", ")}"
        lines << "fallbacks possible after installing their packages: #{(possible - ready).join(", ")}" unless (possible - ready).empty?
        lines << "fallbacks not checked (the kernel facts were not gathered): #{unchecked.join(", ")}" unless unchecked.empty?
      end
      lines << "recommended: #{recommendation}"
      lines.join("\n")
    end

    def recommendation
      if standard_vms?
        "register it as it is (L1)"
      elsif recommended.nil?
        (tier == "container") ? "use a VM or bare metal as the data plane" : "apply the fix above and probe again"
      else
        label = FALLBACK_LABELS.fetch(recommended)
        install = ready.include?(recommended) ? "" : " after #{FALLBACK_PACKAGES.fetch(recommended)}"
        install += ", if the host has #{FALLBACK_NEEDS.fetch(recommended)} (not checked)" if unchecked.include?(recommended)
        register = if ByohVirtTiers.shipped?(recommended)
          "register it with bin/register-byoh-host --virt-tier auto --accept-fallback once the location offers it (bin/byoh-location set --virt-tiers)"
        else
          "fallbacks cannot be registered yet (docs/byoh/NO_KVM.md section 11)"
        end
        "#{label}#{install}; #{register}"
      end
    end
  end

  # The probe as a script for "ruby -" on a host without rhizome.
  def self.remote_script
    "#{File.read(PROBE_PATH)}\nexit VirtProbe.main(ARGV)\n"
  end

  # The verdict for virt-probe --json output. Raises ParseError when the
  # output is not a report this version understands.
  def self.parse(output)
    report = begin
      JSON.parse(output.to_s.lines.reverse.find { it.start_with?("{") } || "")
    rescue JSON::ParserError
      raise ParseError, "virt-probe output is not JSON"
    end
    verdict(report)
  end

  def self.verdict(report)
    raise ParseError, "virt-probe report is not an object" unless report.is_a?(Hash)
    raise ParseError, "virt-probe report version #{report["version"].inspect} is not one of #{VERSIONS.join(", ")}" unless VERSIONS.include?(report["version"])
    raise ParseError, "unknown tier #{report["tier"].inspect}" unless VirtProbe::TIERS.include?(report["tier"])
    raise ParseError, "virt-probe report has no facts" unless report["facts"].is_a?(Hash)

    from_facts(report["facts"], report: VirtProbe.sanitize(report.slice("version", "facts")))
  end

  # Host-supplied data made safe to print and store (VirtProbe.sanitize).
  def self.sanitize(value) = VirtProbe.sanitize(value)

  # The tier, reasons and cause for facts: VirtProbe.classify, run here on
  # sanitised facts.
  def self.classify(facts)
    VirtProbe.classify(VirtProbe.sanitize(facts))
  end

  def self.from_facts(facts, report: nil)
    facts = VirtProbe.sanitize(facts)
    report ||= {"version" => VirtProbe::VERSION, "facts" => facts}
    tier, reasons, cause = VirtProbe.classify(facts)
    nested = VirtProbe.nested?(facts, tier)
    fallbacks = VirtProbe.fallbacks(facts, tier)
    checks = checks(facts)
    platform = ByohVirtPlatforms.match(facts)
    platform_fix, cost_hint = platform ? ByohVirtPlatforms.advice(platform, facts) : [ByohVirtPlatforms::GENERIC_FIX, nil]
    Verdict.new(
      tier:,
      cause:,
      rung: RUNGS.fetch(tier),
      nested:,
      reasons:,
      platform:,
      fix: fix(tier, cause, facts, platform, platform_fix, checks),
      cost_hint:,
      caveats: caveats(tier, nested, facts, checks),
      possible: fallbacks["possible"],
      ready: fallbacks["ready"],
      unchecked: fallbacks["unchecked"],
      recommended: recommended(tier, fallbacks),
      checks:,
      report:,
    )
  end

  # The fallback "auto" would pick: pvm on a PVM host; otherwise the
  # fastest fallback the kernel and CPU allow, installed or not (speed
  # first; the text says what to install), or whose needs were not
  # checked, so a missing fact never puts the emulator ahead of
  # containers; never pvm unless kvm_pvm is loaded; nil when KVM should be
  # fixed instead.
  def self.recommended(tier, fallbacks)
    return "pvm" if tier == "pvm"
    return nil unless %w[none pvm_blocked].include?(tier)

    candidates = fallbacks["possible"] + fallbacks["unchecked"]
    (VirtProbe::FALLBACKS - ["pvm"]).find { candidates.include?(it) }
  end

  # Each KVM check: "pass", "fail", "unknown" (the fact was not gathered)
  # or "skip" (nothing to check).
  def self.checks(facts)
    dev = facts["dev_kvm"]
    {
      "kvm_device" => check(facts.key?("dev_kvm") && !dev.nil?, dev),
      "kvm_open" => kvm_check(dev, facts["kvm_api"]) { it == VirtProbe::KVM_API_VERSION },
      "kvm_create_vm" => kvm_check(dev, facts["kvm_create_vm"]) { it == true },
      "kvm_capabilities" => kvm_check(dev, facts["kvm_caps_missing"]) { it == [] },
      "cpu_model" => check(facts["cpu_model"].is_a?(String), !VirtProbe::GENERIC_CPU_MODEL.match?(facts["cpu_model"].to_s)),
      "pdpe1gb" => (facts["arch"] == "x86_64") ? check(facts["cpu_flags"].is_a?(Array), Array(facts["cpu_flags"]).include?("pdpe1gb")) : "skip",
      "firmware" => check(facts.key?("bios_log"), facts["bios_log"].nil?),
    }
  end

  def self.check(known, ok)
    return "unknown" unless known

    ok ? "pass" : "fail"
  end

  # A check that asks /dev/kvm: skipped without one.
  def self.kvm_check(dev, value)
    dev ? check(!value.nil?, value.nil? || yield(value)) : "skip"
  end

  def self.fix(tier, cause, facts, platform, platform_fix, checks)
    inside_vm = Array(facts["cpu_flags"]).include?("hypervisor") || ![nil, "none"].include?(facts["virt_vm"])
    case tier
    when "kvm"
      (checks["pdpe1gb"] == "fail") ? NO_1G_FIX : nil
    when "kvm_blocked"
      case cause
      when "firmware"
        "Enable Intel VT-x or AMD-V (SVM) in the BIOS/UEFI setup, then power the machine off and on."
      when "cpu_model"
        "Give this VM the host's CPU model instead of the hypervisor's generic one, with VT-x/AMD-V exposed. #{platform_fix}"
      when "module"
        "Load the KVM module (modprobe kvm_intel, or kvm_amd) and persist it under /etc/modules-load.d; if it refuses to load, check the kernel log for \"disabled by bios\". #{platform_fix if inside_vm}".strip
      when "create_vm", "missing_caps"
        "KVM here cannot run cloud-hypervisor's VMs. Update the host kernel; inside a VM, also use a hypervisor or instance type with full nested virtualization. #{platform_fix if inside_vm}".strip
      else
        "Make /dev/kvm usable: check that the KVM module loaded cleanly (kernel log) and that udev created /dev/kvm. #{platform_fix}"
      end
    when "unknown"
      "Gather what is missing (#{%w[dev_kvm cpu_flags arch].select { facts[it].nil? }.join(", ")}), for example with bin/byoh-virt probe --main-ip <host>; Prog::LearnVirt probes again at prep."
    when "unknown_permission"
      "Probe as root: bin/byoh-virt probe --user root, or a --user with passwordless sudo (the probe runs sudo -n)."
    when "pvm_blocked"
      "modprobe kvm_pvm, and persist it with: echo kvm_pvm > /etc/modules-load.d/kvm-pvm.conf. Ubicloud cannot run VMs on PVM hosts yet (L4, docs/byoh/NO_KVM.md). To get L1 instead: #{platform_fix}"
    when "pvm"
      "This is a PVM host. cloud-hypervisor runs, but guests need a PVM-enabled kernel booted directly, and Ubicloud's boot images boot through firmware, so Ubicloud cannot run VMs here yet (L4, docs/byoh/NO_KVM.md). To get L1 instead: #{platform_fix}"
    when "none"
      advice = case platform&.nested
      when :yes, :some then "Fixable by changing the instance type or a VM option: #{platform_fix}"
      when :ask then "Ask your provider whether nested virtualization can be enabled. #{platform_fix}"
      else platform_fix
      end
      "#{advice} #{FALLBACKS}"
    else
      "Run the data plane on a VM or bare metal, not in a container."
    end
  end

  def self.caveats(tier, nested, facts, checks)
    return [] unless tier == "kvm"

    list = nested ? NESTED_CAVEATS.dup : []
    list << NO_TDP if facts["tdp"] == false
    unknown = checks.select { |_, status| status == "unknown" }.keys
    list << format(UNKNOWN_CAVEAT, unknown.join(", ")) unless unknown.empty?
    list
  end

  # The virtualization check of host preflight (M4's PF3), from facts
  # gathered any way. Returns
  #   status         "pass", "fail", or "info" (passes, but some facts
  #                  were not gathered; LearnVirt checks them at prep)
  #   tier, rung     the probe's classification
  #   checks         each KVM check (see .checks)
  #   fix, caveats   the operator's fix text and INFO lines
  # For a declared fallback tier the KVM checks are INFO and the tier's
  # own readiness decides.
  def self.preflight_check(facts, declared_tier: "kvm")
    raise ArgumentError, "unknown tier #{declared_tier.inspect}; expected one of #{DECLARED_TIERS.join(", ")}" unless DECLARED_TIERS.include?(declared_tier)

    v = from_facts(facts)
    result = {tier: v.tier, rung: v.rung, checks: v.checks, platform: v.platform&.key}
    if declared_tier == "kvm"
      status = if v.tier == "unknown" then "info"
      elsif !v.standard_vms? then "fail"
      elsif v.checks.value?("unknown") then "info"
      else "pass"
      end
      return result.merge(status:, fix: v.fix, caveats: v.caveats)
    end

    status, fix = fallback_readiness(v, declared_tier)
    advice = v.fix && "KVM fix, if you would rather run today's VMs: #{v.fix}"
    result.merge(status:, fix:, caveats: ["KVM: #{v.summary}", *advice] + v.caveats)
  end

  def self.fallback_readiness(v, declared)
    if v.standard_vms?
      ["fail", "This host runs KVM (L1); register it as kvm."]
    elsif %w[container unknown_permission].include?(v.tier)
      ["fail", v.fix]
    elsif v.tier == "unknown"
      ["info", "Whether KVM works here is unknown, so #{declared} cannot be checked yet. #{v.fix}"]
    elsif v.tier == "pvm" && declared != "pvm"
      ["fail", "This is a PVM host; register it as pvm."]
    elsif v.ready.include?(declared)
      ["pass", nil]
    elsif v.possible.include?(declared)
      ["fail", "Prepare #{declared} first: #{FALLBACK_PACKAGES.fetch(declared)}."]
    elsif v.unchecked.include?(declared)
      ["info", "Could not check that this host has #{FALLBACK_NEEDS.fetch(declared)} (the facts were not gathered); check it before registering it as #{declared}."]
    else
      ["fail", "This host cannot run #{declared}: #{FALLBACK_LABELS.fetch(declared)} needs #{FALLBACK_NEEDS.fetch(declared)}."]
    end
  end
end
