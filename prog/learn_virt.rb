# frozen_string_literal: true

# Records where a host stands on the virtualization ladder
# (docs/byoh/NO_KVM.md) in vm_host.virt_probe. A host that cannot run
# today's VMs gets a page carrying the fix for its platform, so the
# operator learns why PrepHost refuses it; the page resolves once a
# later probe finds KVM. HostNexus runs it at prep on BYOH hosts, and
# bin/byoh-virt refresh runs it again after the operator fixed the host.
#
# It fails open: whatever goes wrong (no ruby, an SSH error, output it
# cannot read, a probe crash) is recorded as {"error" => ...} with one
# page, and the strand pops, so a broken probe never holds up prep. The
# probe only explains; PrepHost and KvmCheck still decide.
#
# The verdict is compared with the tier the host was registered on
# (vm_host.virt_tier, ByohVirtTiers.accepts_probe?): a KVM host must run
# today's VMs, a lower-tier host must have its tier's prerequisites. The
# page is raised on disagreement and resolved on agreement. HostNexus
# holds a lower-tier host at verify_virt_tier until a probe agrees.
#
# On a lower-tier host the probe also runs once a day from HostNexus#wait
# (stale?), and on a tier whose guests rely on the host kernel
# (KERNEL_TIERS: containers share it, PVM guests run on its kvm_pvm) a
# pending reboot (/var/run/reboot-required) that lasts REBOOT_GRACE pages
# ByohKernelReboot, since every tenant shares that unpatched kernel. The
# page resolves once the flag clears.
class Prog::LearnVirt < Prog::Base
  subject_is :sshable, :vm_host

  KERNEL_TIERS = %w[container pvm].freeze

  REBOOT_GRACE = 7 * 24 * 60 * 60

  PROBE_INTERVAL = 24 * 60 * 60

  # Whether a lower-tier host's last probe is older than PROBE_INTERVAL.
  def self.stale?(vm_host)
    probed_at = vm_host.virt_probe&.[]("probed_at")
    probed_at.nil? || Time.now - Time.parse(probed_at) >= PROBE_INTERVAL
  end

  def self.assemble(vm_host_id)
    Strand.create(prog: "LearnVirt", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    verdict = begin
      ByohVirtLadder.parse(sshable.cmd("sudo host/bin/virt-probe --json"))
    rescue => e
      error = ByohVirtLadder.sanitize("#{e.class}: #{e.message}")
      vm_host.update(virt_probe: Sequel.pg_jsonb({"error" => error, **probed_at}))
      page("the virtualization probe failed: #{error}", {error:, fix: "Check that rhizome is installed (vm_host.install_rhizome) and that ruby runs on the host, then bin/byoh-virt refresh --host #{vm_host.ubid}."})
      pop "virt probe failed"
    end

    tier = vm_host.virt_tier
    record = verdict.record.merge(probed_at)
    if KERNEL_TIERS.include?(tier)
      since = record["reboot_required_since"] = reboot_required_since(verdict)
      check_kernel_reboot(since, verdict)
    end
    vm_host.update(virt_probe: Sequel.pg_jsonb(record))
    if ByohVirtTiers.accepts_probe?(tier, verdict)
      Page.from_tag_parts("ByohVirtTier", vm_host.ubid)&.incr_resolve
    elsif ByohVirtTiers.lower?(tier)
      fix = if verdict.standard_vms?
        "The host runs KVM (L1) now; destroy it and register it again as kvm, which is far faster than #{tier}."
      else
        "Prepare the host for #{tier} (#{ByohVirtLadder::FALLBACK_PACKAGES.fetch(tier)}), then bin/byoh-virt refresh --host #{vm_host.ubid}."
      end
      page("is registered as #{tier} but the probe disagrees: #{verdict.summary}", {tier: verdict.tier, rung: verdict.rung, virt_tier: tier, fix:})
    else
      page("cannot run VMs: #{verdict.summary}", {tier: verdict.tier, rung: verdict.rung, fix: verdict.fix})
    end

    pop "virt tier #{verdict.tier}"
  end

  # What a lower-tier host records of when it was probed (stale?); a KVM
  # host's record stays as it was.
  def probed_at
    ByohVirtTiers.lower?(vm_host.virt_tier) ? {"probed_at" => Time.now.utc.iso8601} : {}
  end

  # When the host was first seen waiting for a reboot, kept across probes.
  def reboot_required_since(verdict)
    return unless verdict.report.dig("facts", "reboot_required")

    vm_host.virt_probe&.[]("reboot_required_since") || Time.now.utc.iso8601
  end

  def check_kernel_reboot(since, verdict)
    if since && Time.now - Time.parse(since) >= REBOOT_GRACE
      kernel = verdict.report.dig("facts", "kernel")
      Prog::PageNexus.assemble("#{vm_host.ubid} has waited for a reboot since #{since}; its #{vm_host.virt_tier} guests share kernel #{kernel}",
        ["ByohKernelReboot", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id,
        extra_data: {kernel:, since:, fix: "Drain the host (its guests stop), reboot it into the updated kernel, then bin/byoh-virt refresh --host #{vm_host.ubid}."})
    else
      Page.from_tag_parts("ByohKernelReboot", vm_host.ubid)&.incr_resolve unless since
    end
  end

  def page(summary, extra_data)
    Prog::PageNexus.assemble("#{vm_host.ubid} #{summary}", ["ByohVirtTier", vm_host.ubid], vm_host.ubid,
      resource_id: vm_host.id, extra_data:)
  end
end
