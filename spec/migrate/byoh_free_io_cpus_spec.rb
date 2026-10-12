# frozen_string_literal: true

Sequel.extension :migration

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "migrate/20261012_byoh_free_io_cpus.rb" do
  # rubocop:enable RSpec/DescribeClass
  let(:migration) {
    # Sequel.migration registers each migration it defines; take ours back out.
    load File.expand_path("../../migrate/20261012_byoh_free_io_cpus.rb", __dir__)
    Sequel::Migration.descendants.pop
  }

  def host_with_cpus(provider_name)
    vm_host = create_vm_host(total_cpus: 4, total_cores: 4, used_cores: 1)
    if provider_name
      HostProvider.create do |hp|
        hp.id = vm_host.id
        hp.provider_name = provider_name
        hp.server_identifier = "#{provider_name}-#{vm_host.id}"
      end
    end
    (0..3).each { VmHostCpu.create(vm_host_id: vm_host.id, cpu_number: it, spdk: it < 2) }
    vm_host
  end

  def cpu_map(vm_host)
    VmHostCpu.where(vm_host_id: vm_host.id).select_order_map([:cpu_number, :spdk, :vm_host_slice_id])
  end

  it "frees the unassigned IO cpus of generic hosts without SPDK, idempotently" do
    byoh = host_with_cpus(HostProvider::GENERIC_PROVIDER_NAME)
    slice = create_vm_host_slice(vm_host_id: byoh.id)
    VmHostCpu.where(vm_host_id: byoh.id, cpu_number: 1).update(vm_host_slice_id: slice.id)
    byoh_spdk = host_with_cpus(HostProvider::GENERIC_PROVIDER_NAME)
    SpdkInstallation.create(vm_host_id: byoh_spdk.id, version: "v1", allocation_weight: 100)
    hetzner = host_with_cpus(HostProvider::HETZNER_PROVIDER_NAME)
    no_provider = host_with_cpus(nil)

    2.times { migration.apply(DB, :up) }

    expect(cpu_map(byoh)).to eq [[0, false, nil], [1, true, slice.id], [2, false, nil], [3, false, nil]]
    untouched = [[0, true, nil], [1, true, nil], [2, false, nil], [3, false, nil]]
    expect(cpu_map(byoh_spdk)).to eq untouched
    expect(cpu_map(hetzner)).to eq untouched
    expect(cpu_map(no_provider)).to eq untouched
    expect(VmHost.where(id: [byoh.id, byoh_spdk.id, hetzner.id, no_provider.id]).select_map(:used_cores)).to eq [1, 1, 1, 1]
  end

  it "frees the io column once upstream has renamed spdk to io" do
    byoh = host_with_cpus(HostProvider::GENERIC_PROVIDER_NAME)
    hetzner = host_with_cpus(HostProvider::HETZNER_PROVIDER_NAME)
    DB.alter_table(:vm_host_cpu) { add_column :io, :boolean }
    DB[:vm_host_cpu].update(io: :spdk)
    DB.alter_table(:vm_host_cpu) { drop_column :spdk }

    migration.apply(DB, :up)

    io_map = ->(vm_host) { DB[:vm_host_cpu].where(vm_host_id: vm_host.id).select_order_map([:cpu_number, :io]) }
    expect(io_map.call(byoh)).to eq [[0, false], [1, false], [2, false], [3, false]]
    expect(io_map.call(hetzner)).to eq [[0, true], [1, true], [2, false], [3, false]]
  end

  it "does nothing when vm_host_cpu has neither flag column" do
    host_with_cpus(HostProvider::GENERIC_PROVIDER_NAME)
    DB.alter_table(:vm_host_cpu) { drop_column :spdk }

    expect { migration.apply(DB, :up) }.not_to raise_error
  end

  it "changes nothing when migrating down" do
    byoh = host_with_cpus(HostProvider::GENERIC_PROVIDER_NAME)
    migration.apply(DB, :up)
    expect { migration.apply(DB, :down) }.not_to change { cpu_map(byoh) }
  end
end
