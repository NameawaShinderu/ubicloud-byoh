# frozen_string_literal: true

# BYOH (generic) hosts run vhost-block-backend and never SPDK, but they were
# prepared with 2 or 4 CPUs marked as spdk. Those CPUs can never be allocated
# to a slice and were never counted in used_cores, so the host lost them for
# nothing. Release the ones that are not assigned to a slice. used_cores is
# left alone: it never included these CPUs.
Sequel.migration do
  up do
    byoh_hosts_without_spdk = from(:host_provider)
      .where(provider_name: "generic")
      .exclude(from(:spdk_installation).where(vm_host_id: Sequel[:host_provider][:id]).exists)
      .select(:id)

    from(:vm_host_cpu)
      .where(vm_host_id: byoh_hosts_without_spdk, spdk: true, vm_host_slice_id: nil)
      .update(spdk: false)
  end

  down do
    # Which CPUs used to be reserved is not recorded, and the reservation had
    # no use on these hosts, so there is nothing to restore.
  end
end
