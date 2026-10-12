# frozen_string_literal: true

# Schema for the BYOH host network contract (docs/byoh/NETWORKING.md
# section 5.2). Every default reproduces today's rows, so nothing changes
# for hosts that never use the new columns.
#
# Never rename this file once applied: Sequel refuses to run when an
# applied migration file disappears.
Sequel.migration do
  up do
    alter_table(:address) do
      add_column :delivery, :text, null: false, default: "routed", collate: '"C"'
      add_column :exposure, :text, null: false, default: "public", collate: '"C"'
      add_constraint(:address_delivery_check, delivery: %w[routed onlink fabric])
      add_constraint(:address_exposure_check, exposure: %w[public nat internal])
    end

    # The unique indexes below cover a column added in the same transaction,
    # whose ALTER TABLE already holds an exclusive lock on the table, and no
    # row is non-NULL yet, so building them concurrently would gain nothing.
    alter_table(:ipv4_address) do
      add_column :reserved, :boolean, null: false, default: false
      add_column :external_ip, :inet
      add_constraint(:ipv4_address_external_ip_v4_check, Sequel.lit("family(external_ip) = 4"))
      add_index :external_ip, unique: true, where: Sequel.~(external_ip: nil), name: :ipv4_address_external_ip_uidx # rubocop:disable Sequel/ConcurrentIndex
    end

    alter_table(:assigned_vm_address) do
      add_column :external_ip, :inet
      add_constraint(:assigned_vm_address_external_ip_v4_check, Sequel.lit("family(external_ip) = 4"))
      add_index :external_ip, unique: true, where: Sequel.~(external_ip: nil), name: :assigned_vm_address_external_ip_uidx # rubocop:disable Sequel/ConcurrentIndex
    end

    alter_table(:location) do
      add_column :byoh_network, :jsonb
    end

    alter_table(:vm_host) do
      add_column :ipv6_mode, :text, null: false, default: "gua", collate: '"C"'
      add_column :network_check, :jsonb
      add_constraint(:vm_host_ipv6_mode_check, ipv6_mode: %w[gua ula])
    end

    alter_table(:vm) do
      add_column :ip4_exposure, :text, null: false, default: "internet", collate: '"C"'
      add_constraint(:vm_ip4_exposure_check, ip4_exposure: %w[internet internal])
    end

    create_table(:byoh_operator_action) do
      uuid :id, primary_key: true, default: Sequel.function(:gen_random_uuid)
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :command, :text, null: false, collate: '"C"'
      column :target_id, :uuid
      column :args, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column :result, :text, null: false, collate: '"C"'

      index :created_at
      index :target_id
    end

    # Registration put a random ULA /64 into net6 of BYOH hosts that had no
    # IPv6 block. Such a prefix is not reachable from the internet, so it
    # must not be shown to customers as a public address.
    from(:vm_host)
      .where(id: from(:host_provider).where(provider_name: "generic").select(:id))
      .where(Sequel.lit("net6 <<= 'fc00::/7'::cidr"))
      .update(ipv6_mode: "ula")
  end

  down do
    # M1 code does not know about reserved, internal or NAT addresses and
    # would hand them to VMs. Refuse to drop the columns while they hold
    # anything M1 cannot represent; the rollback runbook clears them first.
    exported_at = get(Sequel.function(:obj_description, Sequel.cast("byoh_operator_action", :regclass), "pg_class"))
      &.then { it[/\Aexported_at=(.+)\z/, 1] }
    unexported_actions = from(:byoh_operator_action)
    unexported_actions = unexported_actions.where { created_at > Sequel.cast(exported_at, :timestamptz) } if exported_at

    {
      "reserved ipv4_address rows" => from(:ipv4_address).where(reserved: true),
      "ipv4_address rows with an external_ip" => from(:ipv4_address).exclude(external_ip: nil),
      "assigned_vm_address rows with an external_ip" => from(:assigned_vm_address).exclude(external_ip: nil),
      "address rows that are not routed and public" => from(:address).exclude(delivery: "routed", exposure: "public"),
      "locations with a byoh_network profile" => from(:location).exclude(byoh_network: nil),
      "VMs with an internal IPv4 exposure" => from(:vm).where(ip4_exposure: "internal"),
      "byoh_operator_action rows that were not exported" => unexported_actions,
    }.each do |what, dataset|
      raise "refusing to migrate down: there are #{what}" unless dataset.empty?
    end

    drop_table(:byoh_operator_action)

    alter_table(:vm) do
      drop_column :ip4_exposure
    end

    alter_table(:vm_host) do
      drop_column :network_check
      drop_column :ipv6_mode
    end

    alter_table(:location) do
      drop_column :byoh_network
    end

    alter_table(:assigned_vm_address) do
      drop_column :external_ip
    end

    alter_table(:ipv4_address) do
      drop_column :external_ip
      drop_column :reserved
    end

    alter_table(:address) do
      drop_column :exposure
      drop_column :delivery
    end
  end
end
