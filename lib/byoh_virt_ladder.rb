# frozen_string_literal: true

require "json"

# The virtualization ladder of docs/byoh/NO_KVM.md, as the control plane
# sees it: reads what rhizome/host/lib/virt_probe.rb reports about a host
# and says which rung the host is on, whether it can take today's VMs, and
# how to fix it, naming the platform from ByohVirtPlatforms.
#
#   L1 kvm          cloud-hypervisor on KVM, as on every host today
#   L2 kvm_blocked  hardware can virtualize; KVM must be switched on
#      pvm_blocked  the kernel ships kvm_pvm; load it
#   L3 pvm          KVM without hardware support (out-of-tree kvm_pvm)
#   L4/L5           no virtualization at all: system containers or the
#                   QEMU emulator, both opt-in and separately labelled
#
# Only L1 hosts take VMs today. The probe never refuses anything itself;
# PrepHost refuses a host without KVM as before, and Prog::LearnVirt
# records the verdict and pages with the fix.
#
# Hook for host preflight: run VirtProbe on the host over the same SSH
# session (ByohVirtLadder.remote_script piped to "ruby - --json") and
# pass the output to ByohVirtLadder.parse; Verdict#fix is the fix text
# for a failing KVM check.
module ByohVirtLadder
  class ParseError < StandardError; end

  PROBE_PATH = File.expand_path("../rhizome/host/lib/virt_probe.rb", __dir__)

  RUNGS = {
    "kvm" => "L1",
    "kvm_blocked" => "L2",
    "pvm_blocked" => "L2",
    "pvm" => "L3",
    "none" => "L3-L5",
    "container" => "refused",
  }.freeze

  FALLBACKS = <<~TEXT.chomp
    Without hardware virtualization the fallbacks, fastest first, are: L3 PVM (a kvm_pvm host kernel; needs PVM guest kernels, not supported for Ubicloud VMs yet), L4 system containers (shared kernel; design only) and L5 the QEMU emulator (typically 5-20% of native speed; compatibility only). See docs/byoh/NO_KVM.md.
  TEXT

  NESTED_CAVEATS = [
    "nested virtualization: CPU-bound work typically loses 10% or more, and memory- and page-fault-heavy work much more, since every guest page-table change traps to two hypervisors",
    "the provider may stop or restart this VM for maintenance, taking every VM on it down; plan for host restarts",
    "the clocksource is often not tsc and disks are virtual, so bin/monitor health checks may misfire (docs/byoh/PLATFORMS.md F5)",
  ].freeze

  NO_1G_HUGEPAGES = "the CPU lacks pdpe1gb, so 1G hugepages (Prog::SetupHugepages) are unavailable; pick a CPU model or instance type that exposes it"

  Verdict = Data.define(:tier, :rung, :nested, :reasons, :platform, :fix, :caveats, :report) do
    def standard_vms? = tier == "kvm"

    def platform_name = platform&.name || "unknown platform"

    def summary
      "#{tier} (#{rung}) on #{platform_name}: #{reasons.join("; ")}"
    end

    # What Prog::LearnVirt stores in vm_host.virt_probe.
    def record
      report.merge("rung" => rung, "platform" => platform&.key, "fix" => fix, "caveats" => caveats)
    end

    def text
      lines = ["tier: #{tier} (#{rung})#{" nested" if nested}", "platform: #{platform_name}", "why: #{reasons.join("; ")}"]
      lines << "fix: #{fix}" if fix
      caveats.each { lines << "caveat: #{it}" }
      lines.join("\n")
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
    raise ParseError, "virt-probe report version #{report["version"].inspect} is not 1" unless report["version"] == 1
    tier = report["tier"]
    raise ParseError, "unknown tier #{tier.inspect}" unless RUNGS.key?(tier)
    facts = report["facts"]
    raise ParseError, "virt-probe report has no facts" unless facts.is_a?(Hash)

    platform = ByohVirtPlatforms.match(facts)
    Verdict.new(
      tier:,
      rung: RUNGS.fetch(tier),
      nested: report["nested"] == true,
      reasons: Array(report["reasons"]).map(&:to_s),
      platform:,
      fix: fix(tier, report, platform),
      caveats: caveats(tier, report),
      report:,
    )
  end

  def self.fix(tier, report, platform)
    platform_fix = platform&.fix || ByohVirtPlatforms::GENERIC_FIX
    case tier
    when "kvm"
      nil
    when "kvm_blocked"
      reasons = Array(report["reasons"]).join(" ")
      if reasons.include?("firmware")
        "Enable Intel VT-x or AMD-V (SVM) in the BIOS/UEFI setup, then reboot."
      elsif reasons.include?("not loaded")
        "Load the KVM module (modprobe kvm_intel, or kvm_amd) and persist it under /etc/modules-load.d; if it refuses to load, check dmesg for \"disabled by bios\". #{platform_fix if Array(report.dig("facts", "cpu_flags")).include?("hypervisor")}".strip
      else
        "Make /dev/kvm usable: check that the KVM module loaded cleanly (dmesg) and that this is not a container. #{platform_fix}"
      end
    when "pvm_blocked"
      "modprobe kvm_pvm, and persist it with: echo kvm_pvm > /etc/modules-load.d/kvm-pvm.conf. Note: Ubicloud cannot run VMs on PVM hosts yet (L3, docs/byoh/NO_KVM.md)."
    when "pvm"
      "This is a PVM host. cloud-hypervisor runs, but guests need a PVM-enabled kernel booted directly, and Ubicloud's boot images boot through firmware, so Ubicloud cannot run VMs here yet (L3, docs/byoh/NO_KVM.md). To get L1 instead: #{platform_fix}"
    when "none"
      "#{platform_fix} #{FALLBACKS}"
    else
      "Run the data plane on a VM or bare metal, not in a container."
    end
  end

  def self.caveats(tier, report)
    return [] unless tier == "kvm"

    list = (report["nested"] == true) ? NESTED_CAVEATS.dup : []
    flags = Array(report.dig("facts", "cpu_flags"))
    list << NO_1G_HUGEPAGES if report.dig("facts", "arch") == "x86_64" && !flags.include?("pdpe1gb")
    list
  end
end
