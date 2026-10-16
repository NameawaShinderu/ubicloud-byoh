# frozen_string_literal: true

# Which virtualization tier (docs/byoh/NO_KVM.md) bin/register-byoh-host
# registers a host on: the registration matrix of section 3.2, from the
# probe verdict, the declared --virt-tier and the operator's
# --accept-fallback. It decides and explains; ByohRegistration passes
# the tier to Prog::Vm::HostNexus.assemble and records the decision.
#
# Nothing falls back silently: a tier below kvm needs --accept-fallback
# even when "auto" picked it, the location must offer the tier
# (bin/byoh-location set --virt-tiers), and every refusal prints the fix
# and the commands that would register the host on its fastest option.
#
# Hook for M4: once host preflight owns the pinned SSH session, it passes
# its facts here (ByohVirtLadder.from_facts) instead of #probe opening a
# second session.
class ByohVirtRegistration
  class Refused < StandardError; end

  DECLARED = %w[kvm auto container pvm emulated].freeze

  Decision = Data.define(:tier, :declared, :verdict, :notes) do
    # What the operator log records.
    def record
      {"declared" => declared, "tier" => tier, "probe" => verdict&.tier, "accepted_fallback" => ByohVirtTiers.lower?(tier)}
    end
  end

  attr_reader :declared, :accept_fallback, :probe_enabled

  def self.add_options(parser, options)
    parser.separator ""
    parser.separator "Virtualization tier (docs/byoh/NO_KVM.md):"
    parser.on("--virt-tier TIER", "#{DECLARED.join(", ")} (default kvm). auto picks kvm when the host has usable KVM, else the fastest fallback the probe recommends") { options[:virt_tier] = it }
    parser.on("--accept-fallback", "Accept a tier below kvm: slower or weaker isolation; required for every lower tier, auto included") { options[:accept_fallback] = true }
    parser.on("--no-virt-probe", "Skip the probe at registration; Prog::LearnVirt checks the host at prep") { options[:virt_probe] = false }
  end

  def initialize(declared: "kvm", accept_fallback: false, probe: true)
    @declared = declared || "kvm"
    @accept_fallback = accept_fallback
    @probe_enabled = probe
    raise Refused, "--virt-tier #{@declared} is not one of #{DECLARED.join(", ")}" unless DECLARED.include?(@declared)
    raise Refused, "--virt-tier auto needs the probe; drop --no-virt-probe or declare a tier" if @declared == "auto" && !probe
  end

  # Probes the host over SSH as root with the registration key: the probe
  # script piped to "ruby - --json" (ruby is on every host that
  # scripts/byoh/bootstrap-data-plane.sh prepared). Returns the verdict,
  # or [nil, why] when the host could not be probed.
  def probe(main_ip, private_key)
    return [nil, "the probe was skipped (--no-virt-probe)"] unless @probe_enabled

    output = Util.rootish_ssh(main_ip, "root", [private_key], "ruby - --json", stdin: ByohVirtLadder.remote_script)
    [ByohVirtLadder.parse(output.to_s), nil]
  rescue => e
    [nil, ByohVirtLadder.sanitize("#{e.class}: #{e.message}")]
  end

  # The tier to register on, or Refused with the fix. verdict is nil when
  # the host was not probed (unprobed_reason says why).
  def decide!(verdict, location:, main_ip:, unprobed_reason: nil)
    # A declared tier that is not shipped gets the same refusal on every
    # host, before the probe's preflight could ask the operator to
    # prepare the host for it.
    check_shipped!(@declared, verdict) unless @declared == "auto"
    notes = []
    tier = if verdict.nil?
      raise Refused, "--virt-tier auto needs the probe, which failed: #{unprobed_reason}" if @declared == "auto"

      # LearnVirt fails open: only a lower tier is held at verify_virt_tier.
      after = if ByohVirtTiers.lower?(@declared)
        "Prog::LearnVirt checks it at prep, and the #{@declared} host waits there until the probe agrees"
      else
        "prep goes on, and Prog::LearnVirt pages there if the host cannot run VMs"
      end
      notes << "the host was not probed (#{unprobed_reason}); #{after}"
      @declared
    else
      decide_from_verdict(verdict, location:, main_ip:, notes:)
    end

    check_location!(tier, location, verdict, main_ip:)
    if ByohVirtTiers.lower?(tier) && !@accept_fallback
      raise Refused, "#{explain(verdict)}#{tier} is #{ByohVirtTiers.fetch(tier).description} Pass --accept-fallback to register the host on it."
    end

    Decision.new(tier:, declared: @declared, verdict:, notes:)
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
      commands << "bin/byoh-location set --location #{location.name} --virt-tiers #{(ByohVirtTiers.tiers(location) | [tier]).join(",")} --accept #{tier}"
    end
    fallback = ByohVirtTiers.lower?(tier) ? " --virt-tier auto --accept-fallback" : ""
    commands << "bin/register-byoh-host --location #{location.name} --main-ip #{main_ip} ...#{fallback}"
    commands
  end

  private

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
