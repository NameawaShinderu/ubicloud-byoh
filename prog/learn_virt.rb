# frozen_string_literal: true

# Records where a host stands on the virtualization ladder
# (docs/byoh/NO_KVM.md) in vm_host.virt_probe. A host that cannot run
# today's VMs gets a page carrying the fix for its platform, so the
# operator learns why PrepHost refuses it; the page resolves once a
# later probe finds KVM. HostNexus runs it at prep on BYOH hosts, and
# bin/byoh-virt refresh runs it again after the operator fixed the host.
class Prog::LearnVirt < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    Strand.create(prog: "LearnVirt", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    verdict = ByohVirtLadder.parse(sshable.cmd("sudo host/bin/virt-probe --json"))
    vm_host.update(virt_probe: Sequel.pg_jsonb(verdict.record))

    if verdict.standard_vms?
      Page.from_tag_parts("ByohVirtTier", vm_host.ubid)&.incr_resolve
    else
      Prog::PageNexus.assemble("#{vm_host.ubid} cannot run VMs: #{verdict.summary}", ["ByohVirtTier", vm_host.ubid], vm_host.ubid,
        resource_id: vm_host.id, extra_data: {tier: verdict.tier, rung: verdict.rung, fix: verdict.fix})
    end

    pop "virt tier #{verdict.tier}"
  end
end
