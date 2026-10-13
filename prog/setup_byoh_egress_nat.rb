# frozen_string_literal: true

# Installs the host egress NAT table of a BYOH host from its location's
# network profile (rhizome/host/lib/byoh_egress_nat.rb). VM setup installs
# the same table, so this only needs to run at host prep and after the
# profile changes (bin/byoh-host setup-egress-nat).
class Prog::SetupByohEgressNat < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    pop "not a BYOH host" unless vm_host.byoh?

    params = vm_host.location.byoh_profile.egress_nat4_params
    sshable.cmd("sudo host/bin/setup-byoh-egress-nat", stdin: params.to_json)

    pop "byoh egress nat was setup"
  end
end
