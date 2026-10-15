# frozen_string_literal: true

Sequel.extension :migration

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "migrate/20261016_byoh_virt_tier.rb" do
  # rubocop:enable RSpec/DescribeClass
  let(:migration) {
    # Sequel.migration registers each migration it defines; take ours back out.
    load File.expand_path("../../migrate/20261016_byoh_virt_tier.rb", __dir__)
    Sequel::Migration.descendants.pop
  }

  let(:location) { create_byoh_location }

  def columns
    {vm_host: DB[:vm_host].columns! & [:virt_tier], location: DB[:location].columns! & [:byoh_virt]}
  end

  def raw_host(**args)
    create_vm_host(**args).id
  end

  it "migrates down and up again while every host is kvm and no location has a policy" do
    id = raw_host
    migration.apply(DB, :down)
    expect(columns).to eq(vm_host: [], location: [])
    migration.apply(DB, :up)
    expect(columns).to eq(vm_host: [:virt_tier], location: [:byoh_virt])
    expect(DB[:vm_host].where(id:).get(:virt_tier)).to eq "kvm"
  end

  it "refuses to migrate down while a lower-tier host exists" do
    raw_host(virt_tier: "emulated", family: "emulated")
    expect { migration.apply(DB, :down) }.to raise_error(RuntimeError, /\Arefusing to migrate down: there are hosts registered on a rung other than kvm/)
  end

  it "refuses to migrate down while a location has a policy" do
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["kvm"], "acks" => {}}))
    expect { migration.apply(DB, :down) }.to raise_error(RuntimeError, /\Arefusing to migrate down: there are locations with a byoh_virt policy/)
  end

  it "ties a host's tier to its family" do
    expect { raw_host(virt_tier: "container", family: "container") }.not_to raise_error
    expect { DB.transaction(savepoint: true) { DB[:vm_host].where(id: raw_host).update(family: "container") } }.to raise_error(Sequel::CheckConstraintViolation, /vm_host_virt_tier_family_check/)
    row = {location_id: Location::HETZNER_FSN1_ID, allocation_state: "accepting", arch: "x64", family: "standard", total_cores: 4, used_cores: 0}
    expect { DB.transaction(savepoint: true) { DB[:vm_host].insert(row.merge(id: Sshable.create.id, virt_tier: "hvf")) } }.to raise_error(Sequel::CheckConstraintViolation, /vm_host_virt_tier_check/)
    expect { DB.transaction(savepoint: true) { DB[:vm_host].insert(row.merge(id: Sshable.create.id, virt_tier: "emulated")) } }.to raise_error(Sequel::CheckConstraintViolation, /vm_host_virt_tier_family_check/)
  end

  it "never lets a host's tier change" do
    id = raw_host(virt_tier: "emulated", family: "emulated")
    expect { DB.transaction(savepoint: true) { DB[:vm_host].where(id:).update(virt_tier: "container", family: "container") } }
      .to raise_error(Sequel::DatabaseError, /vm_host.virt_tier cannot change \(emulated to container\)/)
    expect(DB[:vm_host].where(id:).update(virt_tier: "emulated", used_cores: 1)).to eq 1
  end

  it "accepts only known tiers, each lower one with its acknowledgement" do
    ok = [{"tiers" => ["kvm"], "acks" => {}}, {"tiers" => %w[kvm container], "acks" => {"container" => ["multitenant"]}}, {"tiers" => ["emulated"], "acks" => {"emulated" => []}}]
    ok.each { expect(DB[:location].where(id: location.id).update(byoh_virt: Sequel.pg_jsonb(it))).to eq 1 }
    bad = [
      {"tiers" => %w[kvm container], "acks" => {}},
      {"tiers" => %w[kvm pvm], "acks" => {"container" => []}},
      {"tiers" => %w[kvm emulated], "acks" => {}},
      {"tiers" => %w[kvm tcg], "acks" => {}},
      {"tiers" => "kvm", "acks" => {}},
      {"tiers" => ["kvm"]},
      {"acks" => {}},
    ]
    bad.each do |policy|
      expect { DB.transaction(savepoint: true) { DB[:location].where(id: location.id).update(byoh_virt: Sequel.pg_jsonb(policy)) } }
        .to raise_error(Sequel::CheckConstraintViolation, /location_byoh_virt_check/)
    end
  end
end
