# frozen_string_literal: true

# The rung of the virtualization ladder each host was registered on
# (docs/byoh/NO_KVM.md), and which rungs each BYOH location offers.
#
# vm_host.virt_tier is set once, at registration, and never changes: a
# host's VMs, its preparation and its capacity all depend on it, so moving
# a host to another rung means registering it again. A lower-rung host
# carries that rung's own family, which keeps its VMs apart from every
# KVM family.
#
# location.byoh_virt is the location's policy: {"tiers": [...], "acks":
# {"<tier>": [option, ...]}}. NULL means KVM only. A lower rung can only be
# listed together with the operator's acknowledgement of it.
Sequel.migration do
  up do
    alter_table(:vm_host) do
      add_column :virt_tier, :text, null: false, default: "kvm"
      add_constraint(:vm_host_virt_tier_check, virt_tier: %w[kvm container pvm emulated])
      add_constraint(:vm_host_virt_tier_family_check,
        Sequel.lit("(virt_tier = 'kvm') = (family NOT IN ('container', 'pvm', 'emulated'))"))
    end

    run <<~SQL
      CREATE FUNCTION vm_host_virt_tier_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.virt_tier IS DISTINCT FROM OLD.virt_tier THEN
          RAISE EXCEPTION 'vm_host.virt_tier cannot change (% to %); register the host again', OLD.virt_tier, NEW.virt_tier;
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER vm_host_virt_tier_immutable BEFORE UPDATE OF virt_tier ON vm_host
        FOR EACH ROW EXECUTE FUNCTION vm_host_virt_tier_immutable();
    SQL

    alter_table(:location) do
      add_column :byoh_virt, :jsonb
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
  end

  down do
    # Code without tiers would treat a lower-rung host as a KVM host.
    {
      "hosts registered on a rung other than kvm" => from(:vm_host).exclude(virt_tier: "kvm"),
      "locations with a byoh_virt policy" => from(:location).exclude(byoh_virt: nil),
    }.each do |what, dataset|
      raise "refusing to migrate down: there are #{what}; run bin/byoh-host export-audit first and remove them" unless dataset.empty?
    end

    alter_table(:location) do
      drop_constraint :location_byoh_virt_check
      drop_column :byoh_virt
    end

    run <<~SQL
      DROP TRIGGER vm_host_virt_tier_immutable ON vm_host;
      DROP FUNCTION vm_host_virt_tier_immutable();
    SQL

    alter_table(:vm_host) do
      drop_constraint :vm_host_virt_tier_family_check
      drop_constraint :vm_host_virt_tier_check
      drop_column :virt_tier
    end
  end
end
