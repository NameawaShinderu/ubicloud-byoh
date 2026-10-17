# frozen_string_literal: true

# The PVM tier (docs/byoh/NO_KVM.md section 6.7): the state of each PVM
# host's kernel install, the guest kernels each host holds, the guest
# kernel each PVM VM boots, and the kernel pins of a location that offers
# pvm.
#
# byoh_pvm_host.state walks install_pending -> installing -> armed ->
# committed for a host whose PVM kernel the control plane installs, and
# starts at committed for one that already ran it at registration.
#
# location.byoh_virt["pvm_kernel"] holds the pins: host_deb and
# guest_kernel {url, sha256} always, and either guest_config {url,
# sha256} or an explicit guest_unchecked boolean (whether the operator
# accepted a guest kernel whose config could not be read). A location
# offers pvm only with them.
Sequel.migration do
  up do
    sha256 = ->(column) { Sequel.like(column, /^[0-9a-f]{64}$/) }

    create_table(:byoh_pvm_host) do
      foreign_key :vm_host_id, :vm_host, type: :uuid, primary_key: true, on_delete: :cascade
      column :state, :text, null: false
      column :install, :boolean, null: false
      column :host_kver, :text
      column :stock_entry, :text
      column :stock_kver, :text
      column :host_deb_sha256, :text
      column :lockdown, :text
      column :meltdown, :text
      column :last_error, :text
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      constraint(:byoh_pvm_host_state_check, state: %w[install_pending installing armed committed failed upgrade_pending uninstalled])
      constraint(:byoh_pvm_host_deb_sha256_check, sha256.call(:host_deb_sha256))
    end

    create_table(:byoh_pvm_guest_kernel) do
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false, on_delete: :cascade
      column :sha256, :text, null: false
      column :state, :text, null: false
      column :release, :text
      column :console, :text
      column :config_checked, :boolean, null: false, default: false
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      primary_key [:vm_host_id, :sha256]
      constraint(:byoh_pvm_guest_kernel_state_check, state: %w[downloading ready refused])
      constraint(:byoh_pvm_guest_kernel_sha256_check, sha256.call(:sha256))
      constraint(:byoh_pvm_guest_kernel_console_check, console: %w[ttyS0 hvc0])
    end

    create_table(:byoh_vm_guest_kernel) do
      foreign_key :vm_id, :vm, type: :uuid, primary_key: true, on_delete: :cascade
      column :sha256, :text, null: false
      column :release, :text
      column :console, :text, null: false
      constraint(:byoh_vm_guest_kernel_sha256_check, sha256.call(:sha256))
      constraint(:byoh_vm_guest_kernel_console_check, console: %w[ttyS0 hvc0])
    end

    alter_table(:location) do
      drop_constraint :location_byoh_virt_check
      add_constraint(:location_byoh_virt_check, Sequel.lit(<<~SQL))
        byoh_virt IS NULL OR (
          coalesce(jsonb_typeof(byoh_virt -> 'tiers') = 'array', false)
          AND byoh_virt -> 'tiers' <@ '["kvm", "container", "pvm", "emulated"]'::jsonb
          AND coalesce(jsonb_typeof(byoh_virt -> 'acks') = 'object', false)
          AND (NOT byoh_virt -> 'tiers' ? 'container' OR byoh_virt -> 'acks' ? 'container')
          AND (NOT byoh_virt -> 'tiers' ? 'pvm' OR byoh_virt -> 'acks' ? 'pvm')
          AND (NOT byoh_virt -> 'tiers' ? 'emulated' OR byoh_virt -> 'acks' ? 'emulated')
          AND (NOT byoh_virt -> 'tiers' ? 'pvm' OR byoh_virt ? 'pvm_kernel')
          AND (NOT byoh_virt ? 'pvm_kernel' OR (
            coalesce(byoh_virt #>> '{pvm_kernel,host_deb,url}' LIKE 'https://_%', false)
            AND coalesce(byoh_virt #>> '{pvm_kernel,host_deb,sha256}' ~ '^[0-9a-f]{64}$', false)
            AND coalesce(byoh_virt #>> '{pvm_kernel,guest_kernel,url}' LIKE 'https://_%', false)
            AND coalesce(byoh_virt #>> '{pvm_kernel,guest_kernel,sha256}' ~ '^[0-9a-f]{64}$', false)
            AND CASE WHEN byoh_virt -> 'pvm_kernel' ? 'guest_config' THEN
              coalesce(byoh_virt #>> '{pvm_kernel,guest_config,url}' LIKE 'https://_%', false)
              AND coalesce(byoh_virt #>> '{pvm_kernel,guest_config,sha256}' ~ '^[0-9a-f]{64}$', false)
            ELSE
              coalesce(jsonb_typeof(byoh_virt #> '{pvm_kernel,guest_unchecked}') = 'boolean', false)
            END
          ))
        )
      SQL
    end
  end

  down do
    # Code without these tables would run a PVM host as if its kernel
    # were stock, and lose which guest kernel each VM boots.
    {
      "PVM hosts" => from(:byoh_pvm_host),
      "PVM guest kernels on hosts" => from(:byoh_pvm_guest_kernel),
      "PVM VMs" => from(:byoh_vm_guest_kernel),
      "locations with PVM kernel pins" => from(:location).where(Sequel.lit("byoh_virt ? 'pvm_kernel'")),
    }.each do |what, dataset|
      raise "refusing to migrate down: there are #{what}; run bin/byoh-host export-audit first and remove them" unless dataset.empty?
    end

    alter_table(:location) do
      drop_constraint :location_byoh_virt_check
      add_constraint(:location_byoh_virt_check, Sequel.lit(<<~SQL))
        byoh_virt IS NULL OR (
          coalesce(jsonb_typeof(byoh_virt -> 'tiers') = 'array', false)
          AND byoh_virt -> 'tiers' <@ '["kvm", "container", "pvm", "emulated"]'::jsonb
          AND coalesce(jsonb_typeof(byoh_virt -> 'acks') = 'object', false)
          AND (NOT byoh_virt -> 'tiers' ? 'container' OR byoh_virt -> 'acks' ? 'container')
          AND (NOT byoh_virt -> 'tiers' ? 'pvm' OR byoh_virt -> 'acks' ? 'pvm')
          AND (NOT byoh_virt -> 'tiers' ? 'emulated' OR byoh_virt -> 'acks' ? 'emulated')
        )
      SQL
    end

    drop_table(:byoh_vm_guest_kernel)
    drop_table(:byoh_pvm_guest_kernel)
    drop_table(:byoh_pvm_host)
  end
end
