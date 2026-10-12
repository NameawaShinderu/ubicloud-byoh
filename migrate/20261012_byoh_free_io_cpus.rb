# frozen_string_literal: true

# BYOH (generic) hosts run vhost-block-backend and never SPDK, but they were
# prepared with 2 or 4 CPUs marked as spdk. Those CPUs can never be allocated
# to a slice and were never counted in used_cores, so the host lost them for
# nothing. Release the ones that are not assigned to a slice. used_cores is left alone: it never included these
# CPUs.
#
# Upstream renames vm_host_cpu.spdk to io through migrations dated 20260831,
# which sort before this one. Depending on how far that rename has gone, the
# flag is in spdk, in io, or in both, so clear whichever of them exist.
Sequel.migration do
  up do
    byoh_hosts_without_spdk = from(:host_provider)
      .where(provider_name: "generic")
      .exclude(from(:spdk_installation).where(vm_host_id: Sequel[:host_provider][:id]).exists)
      .select(:id)

    (from(:vm_host_cpu).columns! & [:spdk, :io]).each do |column|
      from(:vm_host_cpu)
        .where(vm_host_id: byoh_hosts_without_spdk, column => true, vm_host_slice_id: nil)
        .update(column => false)
    end
  end

  down do
    # Which CPUs used to be reserved is not recorded, and the reservation had
    # no use on these hosts, so there is nothing to restore.
  end
end
