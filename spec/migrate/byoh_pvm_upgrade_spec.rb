# frozen_string_literal: true

Sequel.extension :migration

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "migrate/20261017_byoh_pvm_upgrade.rb" do
  # rubocop:enable RSpec/DescribeClass
  let(:migration) {
    # Sequel.migration registers each migration it defines; take ours back out.
    load File.expand_path("../../migrate/20261017_byoh_pvm_upgrade.rb", __dir__)
    Sequel::Migration.descendants.pop
  }

  let(:row) { ByohPvmHost.create(vm_host_id: create_vm_host(virt_tier: "pvm", family: "pvm").id, state: "committed", install: true, host_deb_sha256: "a" * 64) }

  def columns = DB.schema(:byoh_pvm_host, reload: true).map(&:first)

  it "migrates down and up again while no upgrade is pending" do
    row
    migration.apply(DB, :down)
    expect(columns).not_to include :upgrade_host_deb_sha256
    migration.apply(DB, :up)
    expect(columns).to include :upgrade_host_deb_sha256
  end

  it "takes only a sha256 for the accepted build" do
    expect { DB.transaction(savepoint: true) { DB[:byoh_pvm_host].where(vm_host_id: row.vm_host_id).update(upgrade_host_deb_sha256: "C" * 64) } }.to raise_error(Sequel::CheckConstraintViolation)
  end

  it "refuses to migrate down while an upgrade is pending" do
    row.update(state: "upgrade_pending", upgrade_host_deb_sha256: "c" * 64)
    expect { migration.apply(DB, :down) }.to raise_error(RuntimeError, /\Arefusing to migrate down: there are PVM hosts with an upgrade pending;/)
  end
end
