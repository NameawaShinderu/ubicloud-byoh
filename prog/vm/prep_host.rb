# frozen_string_literal: true

class Prog::Vm::PrepHost < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    # A lower-tier host (docs/byoh/NO_KVM.md) names its tier, so that
    # prep_host.rb runs that tier's steps; a KVM host runs the command as
    # it always did.
    if ByohVirtTiers.lower?(vm_host.virt_tier)
      sshable.cmd("sudo host/bin/prep_host.rb :ubid :rack_env :tier", ubid: vm_host.ubid, rack_env: Config.rack_env, tier: ByohVirtTiers.fetch(vm_host.virt_tier).prep_arg)
    else
      sshable.cmd("sudo host/bin/prep_host.rb :ubid :rack_env", ubid: vm_host.ubid, rack_env: Config.rack_env)
    end
    pop "host prepared"
  end
end
