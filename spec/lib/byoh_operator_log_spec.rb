# frozen_string_literal: true

RSpec.describe ByohOperatorLog do
  it "inserts an audit row and logs it" do
    target_id = Location::HETZNER_FSN1_ID
    expect(Clog).to receive(:emit).with("byoh operator action", hash_including(byoh_operator_action: hash_including(command: "byoh-location grant", target_id:, result: "ok")))
    id = described_class.record(command: "byoh-location grant", target_id:, args: {project: "pj1"}, result: "ok")

    row = DB[:byoh_operator_action].first(id:)
    expect(row.slice(:command, :target_id, :result)).to eq(command: "byoh-location grant", target_id:, result: "ok")
    expect(row[:args].to_h).to eq("project" => "pj1")
    expect(row[:created_at]).to be_a(Time)
  end
end
