# frozen_string_literal: true

# Which virtualization tier (docs/byoh/NO_KVM.md) bin/register-byoh-host
# and byoh-host add register a host on: the registration matrix of
# section 3.2, from the probe verdict, the declared --virt-tier and the
# operator's --accept-fallback. It decides and explains; ByohRegistration
# passes the tier to Prog::Vm::HostNexus.assemble and records the
# decision.
#
# Nothing falls back silently: a tier below kvm needs --accept-fallback
# even when "auto" picked it, the location must offer the tier
# (bin/byoh-location set --virt-tiers), and every refusal prints the fix
# and the commands that would register the host on its fastest option.
#
# The verdict comes from host preflight (ByohHostPreflight): its virt
# fact, gathered in the preflight's own session, is what PF3 judges and
# what #decide! takes, so the host is probed once.
#
# PVM (docs/byoh/NO_KVM.md section 6.7): a stock host has no kvm_pvm, so
# its probe says none (or kvm_blocked without hardware virtualization;
# pvm_blocked is a PVM kernel whose kvm_pvm is not loaded, which is
# never installed on). --install-pvm-kernel is the operator's per-host
# acknowledgement that the control plane installs the location's pinned
# PVM host kernel there and reboots the host into it; only with it is
# such a host registered as pvm, and the operator log records it with
# the host's lockdown and Meltdown state. Without the flag every answer
# is what it was.
class ByohVirtRegistration
  class Refused < StandardError; end

  DECLARED = %w[kvm auto container pvm emulated].freeze

  # The byoh_pvm_host state a pvm host is registered in: install_pending
  # when the control plane installs its PVM kernel, committed when it
  # already runs one. nil for every other tier.
  def self.pvm_install_state(tier, record)
    return unless tier == "pvm"

    record["install_pvm_kernel"] ? "install_pending" : "committed"
  end

  # What byoh_pvm_host keeps of a pvm host's registration: the kernel's
  # lockdown mode and the CPU's Meltdown status the probe found, and the
  # host-deb sha256 the operator acknowledged installing.
  def self.pvm_facts(record) = record.slice("lockdown", "meltdown", "host_deb_sha256")

  Decision = Data.define(:tier, :declared, :verdict, :notes, :install_pvm_kernel, :host_deb_sha256) do
    # What the operator log records.
    def record
      r = {"declared" => declared, "tier" => tier, "probe" => verdict&.tier, "accepted_fallback" => ByohVirtTiers.lower?(tier)}
      return r unless tier == "pvm"

      facts = verdict ? verdict.report["facts"] : {}
      meltdown = facts["vulnerabilities"]["meltdown"] if facts["vulnerabilities"].is_a?(Hash)
      r["install_pvm_kernel"] = install_pvm_kernel
      # The host kernel pin the operator acknowledged installing.
      r["host_deb_sha256"] = host_deb_sha256 if install_pvm_kernel
      r.merge("lockdown" => facts["lockdown"], "meltdown" => meltdown)
    end

    def pvm_install = ByohVirtRegistration.pvm_install_state(tier, record)

    def pvm_facts = ByohVirtRegistration.pvm_facts(record)
  end

  # A decision kept between byoh-host add's prepare and register phases,
  # which may run in different processes: its tier and its record.
  Recorded = Data.define(:tier, :record) do
    def pvm_install = ByohVirtRegistration.pvm_install_state(tier, record)

    def pvm_facts = ByohVirtRegistration.pvm_facts(record)
  end

  attr_reader :declared, :accept_fallback, :probe_enabled, :install_pvm_kernel

  def self.add_options(parser, options)
    parser.separator ""
    parser.separator "Virtualization tier (docs/byoh/NO_KVM.md):"
    parser.on("--virt-tier TIER", "#{DECLARED.join(", ")} (default kvm). auto picks kvm when the host has usable KVM, else the fastest fallback the probe recommends") { options[:virt_tier] = it }
    parser.on("--accept-fallback", "Accept a tier below kvm: slower or weaker isolation; required for every lower tier, auto included") { options[:accept_fallback] = true }
    parser.on("--no-virt-probe", "Leave the virtualization facts of preflight unused (PF3 then checks only /dev/kvm); Prog::LearnVirt checks the host at prep") { options[:virt_probe] = false }
    parser.on("--install-pvm-kernel", "pvm (or auto) on a stock kernel without KVM: install the location's pinned PVM host kernel, a third-party build, and reboot the host into it; your acknowledgement for this host (docs/byoh/NO_KVM.md section 6.7)") { options[:install_pvm_kernel] = true }
  end

  def initialize(declared: "kvm", accept_fallback: false, probe: true, install_pvm_kernel: false)
    @declared = declared || "kvm"
    @accept_fallback = accept_fallback
    @probe_enabled = probe
    @install_pvm_kernel = !!install_pvm_kernel
    raise Refused, "--virt-tier #{@declared} is not one of #{DECLARED.join(", ")}" unless DECLARED.include?(@declared)
    raise Refused, "--virt-tier auto needs the probe; drop --no-virt-probe or declare a tier" if @declared == "auto" && !probe
    return unless @install_pvm_kernel

    raise Refused, "--install-pvm-kernel goes with --virt-tier pvm or auto, not #{@declared}" unless %w[pvm auto].include?(@declared)
    raise Refused, "--install-pvm-kernel needs the probe, which checks the host first; drop --no-virt-probe" unless probe
  end

  # The tier host preflight judges the host for (PF3): the declared one,
  # or for auto what #decide! will pick from the same facts (kvm when
  # they are missing or name no fallback; #decide! then refuses).
  # location: the host's Location, where auto may pick pvm by an install.
  def preflight_tier(facts, location: nil)
    return @declared unless @declared == "auto"
    return ByohVirtTiers::KVM unless facts

    verdict = ByohVirtLadder.from_facts(facts)
    return ByohVirtTiers::KVM if verdict.standard_vms?
    return "pvm" if location && auto_install?(verdict, location)

    verdict.recommended || ByohVirtTiers::KVM
  end

  # Whether PF3 judges the host's stock kernel for a PVM install.
  def pvm_install_preflight?(tier) = @install_pvm_kernel && tier == "pvm"

  # The reason #decide! gets when preflight gave no verdict.
  def unprobed_reason(report)
    if !@probe_enabled
      "the probe was skipped (--no-virt-probe)"
    elsif report.nil?
      "preflight was skipped"
    else
      "preflight reported no virtualization facts"
    end
  end

  # The tier to register on, or Refused with the fix. verdict is nil when
  # the host was not probed (unprobed_reason says why).
  # boot_images are the --default-boot-image names: a lower tier boots
  # only its own images, so a wrong one is refused here, with the names
  # to use, rather than by Prog::Vm::HostNexus.assemble.
  def decide!(verdict, location:, main_ip:, unprobed_reason: nil, boot_images: [])
    # A declared tier that is not shipped gets the same refusal on every
    # host, before the probe's preflight could ask the operator to
    # prepare the host for it.
    check_shipped!(@declared, verdict) unless @declared == "auto"
    notes = []
    install = false
    tier = if verdict.nil?
      raise Refused, "--virt-tier auto needs the probe, which failed: #{unprobed_reason}" if @declared == "auto"
      raise Refused, "--install-pvm-kernel needs the probe, which did not run: #{unprobed_reason}" if @install_pvm_kernel

      # LearnVirt fails open: only a lower tier is held at verify_virt_tier.
      after = if ByohVirtTiers.lower?(@declared)
        "Prog::LearnVirt checks it at prep, and the #{@declared} host waits there until the probe agrees"
      else
        "prep goes on, and Prog::LearnVirt pages there if the host cannot run VMs"
      end
      notes << "the host was not probed (#{unprobed_reason}); #{after}"
      @declared
    elsif install_pvm?(verdict, location)
      install = true
      install_notes(verdict, location, notes)
      "pvm"
    else
      if @install_pvm_kernel
        notes << "--install-pvm-kernel was not used: #{auto_install_skipped(verdict, location)}; auto picked as it does without it"
      end
      decide_from_verdict(verdict, location:, main_ip:, notes:)
    end

    check_location!(tier, location, verdict, main_ip:)
    check_boot_images!(tier, boot_images, verdict)
    if ByohVirtTiers.lower?(tier) && !@accept_fallback
      raise Refused, "#{explain(verdict)}#{tier} is #{ByohVirtTiers.fetch(tier).description} Pass --accept-fallback to register the host on it."
    end

    host_deb_sha256 = ByohPvmPolicy.pins(ByohVirtTiers.policy(location)).dig("host_deb", "sha256") if install
    Decision.new(tier:, declared: @declared, verdict:, notes:, install_pvm_kernel: install, host_deb_sha256:)
  end

  # The commands that register the host on its fastest option: the
  # location policy and rates for a fallback, then the registration.
  # None for a fallback that is not shipped: no command could register
  # it, and the verdict's text already says so.
  def self.recommended_commands(verdict, location:, main_ip:)
    tier = verdict.standard_vms? ? ByohVirtTiers::KVM : verdict.recommended
    return [] unless tier && ByohVirtTiers.shipped?(tier)

    commands = []
    if ByohVirtTiers.lower?(tier) && !ByohVirtTiers.allows?(location, tier)
      family = ByohVirtTiers.fetch(tier).family
      commands << "bin/byoh-location rates --location #{location.name} --family #{family} --from standard --multiplier <X>"
      # A location offers pvm only with both PVM kernel pins (ByohPvmPolicy).
      pins = (tier == "pvm") ? " --pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX" : ""
      commands << "bin/byoh-location set --location #{location.name} --virt-tiers #{(ByohVirtTiers.tiers(location) | [tier]).join(",")} --accept #{tier}#{pins}"
    end
    fallback = ByohVirtTiers.lower?(tier) ? " --virt-tier auto --accept-fallback" : ""
    commands << "bin/register-byoh-host --location #{location.name} --main-ip #{main_ip} ...#{fallback}"
    commands
  end

  private

  # Whether to register the host as pvm by installing the PVM host kernel
  # (--install-pvm-kernel). Declared pvm: always with the flag, refused
  # with the reason when the host or the location cannot take it. auto:
  # only on a stock probe (none) where the install would pass; otherwise
  # auto picks as it did without the flag, with a note.
  def install_pvm?(verdict, location)
    return false unless @install_pvm_kernel

    if @declared == "pvm"
      problem = ByohVirtLadder.pvm_install_problem(verdict) || location_problem(location)
      raise Refused, "#{explain(verdict)}refused (--install-pvm-kernel): #{problem}" if problem

      true
    else
      auto_install?(verdict, location)
    end
  end

  # auto with --install-pvm-kernel: pvm on a stock probe without
  # hardware virtualization (none) whose install would pass, in a
  # location that pins and acknowledges pvm. Never on kvm_blocked, whose
  # fix (switching KVM on) is the better answer, nor on pvm_blocked, a
  # PVM kernel whose fix is loading kvm_pvm.
  def auto_install?(verdict, location)
    @install_pvm_kernel && verdict.tier == "none" && ByohVirtTiers.shipped?("pvm") &&
      ByohVirtLadder.pvm_install_problem(verdict).nil? && location_problem(location).nil?
  end

  # Why auto with --install-pvm-kernel did not pick pvm by an install.
  def auto_install_skipped(verdict, location)
    if verdict.tier == "pvm_blocked"
      ByohVirtLadder.pvm_install_problem(verdict)
    elsif verdict.tier != "none"
      "auto installs a PVM kernel only where the probe says none, and it says #{verdict.tier}"
    elsif !ByohVirtTiers.shipped?("pvm")
      "pvm hosts are not available yet"
    else
      ByohVirtLadder.pvm_install_problem(verdict) || location_problem(location)
    end
  end

  # Why the location cannot take a PVM install, or nil.
  def location_problem(location)
    return if ByohVirtTiers.allows?(location, "pvm") && ByohVirtTiers.acked?(location, "pvm") && ByohVirtTiers.pvm_pinned?(location)

    "location #{location.name} does not offer pvm with pinned PVM kernels. To allow it:\n  " \
      "bin/byoh-location rates --location #{location.name} --family pvm --from standard --multiplier <X>\n  " \
      "bin/byoh-location set --location #{location.name} --virt-tiers #{(ByohVirtTiers.tiers(location) | ["pvm"]).join(",")} --accept pvm " \
      "--pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX"
  end

  def install_notes(verdict, location, notes)
    facts = verdict.report["facts"]
    pins = ByohPvmPolicy.pins(ByohVirtTiers.policy(location))
    notes << "pvm: the control plane installs the PVM host kernel pinned by location #{location.name} (sha256 #{pins["host_deb"]["sha256"]}), " \
      "a third-party build, then reboots the host into it once; the stock kernel #{facts["kernel"]} stays the GRUB default (docs/byoh/NO_KVM.md section 6.7)"
    notes << "pvm: the probe says KVM could be switched on instead, which is faster and isolates better: #{verdict.fix}" if verdict.tier == "kvm_blocked"
    if facts["lockdown"] && facts["lockdown"] != "none"
      notes << "pvm: kernel lockdown is #{facts["lockdown"]} on the stock kernel. The PVM boot keeps the stock command line, and the unsigned " \
        "kvm_pvm module does not load under lockdown, so that boot would fail and the host return to its stock kernel; remove lockdown= from the kernel command line first"
    end
  end

  def decide_from_verdict(verdict, location:, main_ip:, notes:)
    tier = if @declared == "auto"
      auto_tier(verdict, location:, main_ip:)
    else
      @declared
    end

    check = ByohVirtLadder.preflight_check(verdict.report["facts"], declared_tier: tier)
    case check[:status]
    when "fail"
      raise Refused, refusal(verdict, check[:fix], location:, main_ip:)
    when "info"
      notes << "#{tier}: #{check[:fix] || check[:caveats].join("; ")}"
    end
    notes.concat(check[:caveats]) if tier == ByohVirtTiers::KVM && check[:status] == "pass"
    tier
  end

  # auto: kvm on a host that runs today's VMs, pvm on a PVM host, else the
  # fastest fallback the probe recommends; never pvm by a kernel change.
  def auto_tier(verdict, location:, main_ip:)
    return ByohVirtTiers::KVM if verdict.standard_vms?
    return verdict.recommended if verdict.recommended

    fix = "fix KVM on the host, or declare a tier explicitly with --virt-tier"
    raise Refused, refusal(verdict, [verdict.fix, fix].compact.join(" Then: "), location:, main_ip:)
  end

  def check_boot_images!(tier, boot_images, verdict)
    return unless ByohVirtTiers.lower?(tier)

    images = ByohVirtTiers.fetch(tier).boot_images
    return if (other = boot_images - images).empty?

    raise Refused, "#{explain(verdict)}a #{tier} host cannot boot #{other.join(", ")}; its images are #{images.join(", ")}. " \
      "Drop --default-boot-image (the host then downloads #{images.first}) or pass --default-boot-image #{images.first}."
  end

  def check_shipped!(tier, verdict)
    return if ByohVirtTiers.shipped?(tier)

    raise Refused, "#{explain(verdict)}#{tier} hosts are not available yet: this control plane's rhizome cannot run them (docs/byoh/NO_KVM.md section 11)."
  end

  # auto may pick a tier that is not shipped (a ready PVM host).
  def check_location!(tier, location, verdict, main_ip:)
    check_shipped!(tier, verdict)
    return if ByohVirtTiers.allows?(location, tier)

    commands = if ByohVirtTiers.lower?(tier)
      ["bin/byoh-location rates --location #{location.name} --family #{tier} --from standard --multiplier <X>",
        "bin/byoh-location set --location #{location.name} --virt-tiers #{(ByohVirtTiers.tiers(location) | [tier]).join(",")} --accept #{tier}"]
    else
      ["bin/byoh-location set --location #{location.name} --virt-tiers #{(ByohVirtTiers.tiers(location) | [tier]).join(",")}"]
    end
    raise Refused, "#{explain(verdict)}location #{location.name} does not offer #{tier} hosts. To allow them:\n  #{commands.join("\n  ")}"
  end

  def explain(verdict)
    verdict ? "the probe found #{verdict.summary}. " : ""
  end

  def refusal(verdict, fix, location:, main_ip:)
    lines = [verdict.text]
    lines << "refused: #{fix}"
    commands = self.class.recommended_commands(verdict, location:, main_ip:)
    lines << "to register it on its fastest option:\n  #{commands.join("\n  ")}" unless commands.empty?
    lines.join("\n")
  end
end
