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
class Prog::LearnVirt < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    Strand.create(prog: "LearnVirt", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    verdict = begin
      ByohVirtLadder.parse(sshable.cmd("sudo host/bin/virt-probe --json"))
    rescue => e
      error = ByohVirtLadder.sanitize("#{e.class}: #{e.message}")
      vm_host.update(virt_probe: Sequel.pg_jsonb({"error" => error}))
      page("the virtualization probe failed: #{error}", {error:, fix: "Check that rhizome is installed (vm_host.install_rhizome) and that ruby runs on the host, then bin/byoh-virt refresh --host #{vm_host.ubid}."})
      pop "virt probe failed"
    end

    vm_host.update(virt_probe: Sequel.pg_jsonb(verdict.record))
    tier = vm_host.virt_tier
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

  def page(summary, extra_data)
    Prog::PageNexus.assemble("#{vm_host.ubid} #{summary}", ["ByohVirtTier", vm_host.ubid], vm_host.ubid,
      resource_id: vm_host.id, extra_data:)
  end
end
