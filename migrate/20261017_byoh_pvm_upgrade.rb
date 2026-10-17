# frozen_string_literal: true

# The host-deb build an operator accepted for a PVM host's upgrade
# (bin/byoh-virt pvm upgrade), kept apart from host_deb_sha256, the build
# the host runs, until the upgrade installed it.
Sequel.migration do
  up do
    alter_table(:byoh_pvm_host) do
      add_column :upgrade_host_deb_sha256, :text
      add_constraint(:byoh_pvm_host_upgrade_host_deb_sha256_check, Sequel.like(:upgrade_host_deb_sha256, /^[0-9a-f]{64}$/))
    end
  end

  down do
    # Code without the column would read the pending upgrade's build as
    # the one the host runs.
    unless from(:byoh_pvm_host).exclude(upgrade_host_deb_sha256: nil).empty?
      raise "refusing to migrate down: there are PVM hosts with an upgrade pending; let it finish or fail first"
    end

    alter_table(:byoh_pvm_host) do
      drop_column :upgrade_host_deb_sha256
    end
  end
end
