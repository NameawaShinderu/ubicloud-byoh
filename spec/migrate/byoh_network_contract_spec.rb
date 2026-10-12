# frozen_string_literal: true

Sequel.extension :migration

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "migrate/20261013_byoh_network_contract.rb" do
  # rubocop:enable RSpec/DescribeClass
  let(:migration) {
    # Sequel.migration registers each migration it defines; take ours back out.
    load File.expand_path("../../migrate/20261013_byoh_network_contract.rb", __dir__)
    Sequel::Migration.descendants.pop
  }

  def host(provider_name, net6)
    vm_host = create_vm_host(net6:)
    if provider_name
      HostProvider.create do |hp|
        hp.id = vm_host.id
        hp.provider_name = provider_name
        hp.server_identifier = "#{provider_name}-#{vm_host.id}"
      end
    end
    vm_host.id
  end

  def ipv6_modes(ids)
    DB[:vm_host].where(id: ids).as_hash(:id, :ipv6_mode).values_at(*ids)
  end

  def m2_columns
    {
      address: DB[:address].columns! & [:delivery, :exposure],
      ipv4_address: DB[:ipv4_address].columns! & [:reserved, :external_ip],
      assigned_vm_address: DB[:assigned_vm_address].columns! & [:external_ip],
      location: DB[:location].columns! & [:byoh_network],
      vm_host: DB[:vm_host].columns! & [:ipv6_mode, :network_check],
      vm: DB[:vm].columns! & [:ip4_exposure],
      byoh_operator_action: DB.table_exists?(:byoh_operator_action),
    }
  end

  it "backfills ula only for generic hosts with a ULA net6" do
    ids = [
      host(HostProvider::GENERIC_PROVIDER_NAME, "fd12:3456:789a:1::/64"),
      host(HostProvider::GENERIC_PROVIDER_NAME, "2a01:4f8:1:2::/64"),
      host(HostProvider::GENERIC_PROVIDER_NAME, nil),
      host(HostProvider::HETZNER_PROVIDER_NAME, "fd12:3456:789a:2::/64"),
      host(nil, "fd12:3456:789a:3::/64"),
    ]

    migration.apply(DB, :down)
    migration.apply(DB, :up)

    expect(ipv6_modes(ids)).to eq %w[ula gua gua gua gua]
  end

  it "migrates down and up again when only M1 data exists" do
    up_columns = m2_columns
    expect(up_columns.values).to all(be_truthy)

    migration.apply(DB, :down)
    expect(m2_columns).to eq(address: [], ipv4_address: [], assigned_vm_address: [], location: [], vm_host: [], vm: [], byoh_operator_action: false)

    migration.apply(DB, :up)
    expect(m2_columns).to eq up_columns
  end

  describe "down" do
    let(:vm_host) { create_vm_host }
    let(:address) { Address.create(cidr: "10.0.0.0/30", vm_host:) }

    def expect_refusal(what)
      expect { migration.apply(DB, :down) }.to raise_error(RuntimeError, "refusing to migrate down: there are #{what}")
      expect(DB.table_exists?(:byoh_operator_action)).to be true
    end

    it "refuses while ipv4_address rows are reserved" do
      DB[:ipv4_address].insert(ip: "10.0.0.1", cidr: address.cidr.to_s, reserved: true)
      expect_refusal("reserved ipv4_address rows")
    end

    it "refuses while ipv4_address rows have an external IP" do
      DB[:ipv4_address].insert(ip: "10.0.0.1", cidr: address.cidr.to_s, external_ip: "203.0.113.1")
      expect_refusal("ipv4_address rows with an external_ip")
    end

    it "refuses while assigned_vm_address rows have an external IP" do
      AssignedVmAddress.create(dst_vm_id: create_vm.id, ip: "10.0.0.1/32", external_ip: "203.0.113.1")
      expect_refusal("assigned_vm_address rows with an external_ip")
    end

    it "refuses while an address is not routed" do
      address.update(delivery: "onlink")
      expect_refusal("address rows that are not routed and public")
    end

    it "refuses while an address is not public" do
      address.update(exposure: "internal")
      expect_refusal("address rows that are not routed and public")
    end

    it "refuses while a location has a BYOH profile" do
      Location[Location::HETZNER_HEL1_ID].update(byoh_network: {})
      expect_refusal("locations with a byoh_network profile")
    end

    it "refuses while a VM asked for an internal IPv4" do
      create_vm(ip4_exposure: "internal")
      expect_refusal("VMs with an internal IPv4 exposure")
    end

    it "refuses while operator actions were never exported" do
      DB[:byoh_operator_action].insert(command: "register-byoh-host", result: "ok")
      expect_refusal("byoh_operator_action rows that were not exported")
    end

    it "refuses while operator actions are newer than the last export" do
      DB[:byoh_operator_action].insert(command: "register-byoh-host", result: "ok", created_at: Time.utc(2026, 10, 13, 12))
      DB.run "COMMENT ON TABLE byoh_operator_action IS 'exported_at=2026-10-13T11:00:00Z'"
      expect_refusal("byoh_operator_action rows that were not exported")
    end

    it "ignores a table comment that is not an export marker" do
      DB[:byoh_operator_action].insert(command: "register-byoh-host", result: "ok")
      DB.run "COMMENT ON TABLE byoh_operator_action IS 'audit log'"
      expect_refusal("byoh_operator_action rows that were not exported")
    end

    it "allows operator actions that were exported" do
      DB[:byoh_operator_action].insert(command: "register-byoh-host", result: "ok", created_at: Time.utc(2026, 10, 13, 10))
      DB.run "COMMENT ON TABLE byoh_operator_action IS 'exported_at=2026-10-13T11:00:00Z'"
      migration.apply(DB, :down)
      expect(DB.table_exists?(:byoh_operator_action)).to be false
    end
  end
end
