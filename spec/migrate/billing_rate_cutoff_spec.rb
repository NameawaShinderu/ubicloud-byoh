# frozen_string_literal: true

Sequel.extension :migration

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "billing rate cutoff migrations" do
  # rubocop:enable RSpec/DescribeClass
  let(:project) { Project.create(name: "billing-cutoff") }
  let(:june) { Time.utc(2026, 6, 1) }
  let(:september) { Time.utc(2026, 9, 1) }
  let(:after_cutoff) { Time.utc(2026, 10, 12) }

  before do
    # The migrations build SQL by interpolation; the migrate task runs them
    # without the test suite's frozen-literal check.
    allow(DB).to receive(:run).and_wrap_original { |m, sql, *args| m.call(sql.dup.freeze, *args) }
  end

  def migration(name)
    # Sequel.migration registers each migration it defines; take ours back out.
    load File.expand_path("../../migrate/#{name}.rb", __dir__)
    Sequel::Migration.descendants.pop
  end

  def rate_id(type, active_from)
    BillingRate.rates.find {
      it["resource_type"] == type && it["resource_family"] == "standard" && it["location"] == "hetzner-fsn1" && !it["byoc"] && it["active_from"] == active_from
    }.fetch("id")
  end

  def record(rate_id, from, amount: 2)
    id = BillingRecord.generate_uuid
    DB[:billing_record].insert(id:, project_id: project.id, resource_id: SecureRandom.uuid, resource_name: "vm",
      span: Sequel.lit("tstzrange(?, NULL)", from), amount:, billing_rate_id: rate_id)
    id
  end

  def open_records
    DB[:billing_record].where(project_id: project.id).where(Sequel.function(:upper, :span) => nil)
      .select_order_map([Sequel.function(:lower, :span).as(:from), :billing_rate_id, :amount])
      .map { |from, rate, amount| [from.utc, rate, amount.to_i] }
  end

  def closed_at(id)
    DB[:billing_record].where(id:).get(Sequel.function(:upper, :span))&.utc
  end

  it "splits VmCores records opened before June 1 and moves later ones to vCPUs in place" do
    cores = rate_id("VmCores", Time.utc(2023, 1, 1))
    vcpu = BillingRate.rates.select { it["resource_type"] == "VmVCpu" && it["resource_family"] == "standard" && it["location"] == "hetzner-fsn1" && !it["byoc"] }.max_by { it["active_from"] }["id"]
    early = record(cores, Time.utc(2026, 3, 1))
    record(cores, after_cutoff)

    migration("20260601_migrate_vmcores_to_vmvcpu").apply(DB, :up)

    expect(closed_at(early)).to eq june
    expect(open_records).to eq [[june, vcpu, 4], [after_cutoff, vcpu, 4]]
  end

  it "finalizes June records opened before the cutoff and rebinds later ones" do
    old = rate_id("VmVCpu", Time.utc(2025, 1, 1))
    new = rate_id("VmVCpu", Time.utc(2026, 5, 1))
    early = record(old, Time.utc(2026, 3, 1))
    record(old, after_cutoff)

    migration("20260601_finalize_billing_records_at_old_rates").apply(DB, :up)

    expect(closed_at(early)).to eq june
    expect(open_records).to eq [[june, new, 2], [after_cutoff, new, 2]]
  end

  it "finalizes September records opened before the cutoff and rebinds later ones" do
    old = rate_id("VmVCpu", Time.utc(2026, 5, 1))
    new = rate_id("VmVCpu", september)
    early = record(old, Time.utc(2026, 7, 1))
    record(old, after_cutoff)

    migration("20260901_finalize_billing_records_at_old_rates").apply(DB, :up)

    expect(closed_at(early)).to eq september
    expect(open_records).to eq [[september, new, 2], [after_cutoff, new, 2]]
  end
end
