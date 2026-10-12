# frozen_string_literal: true

# The audit trail of BYOH operator commands (byoh-location, byoh-pool,
# byoh-host, register-byoh-host). Every mutation writes one
# byoh_operator_action row, normally in the transaction of the change it
# describes, and the same entry goes to the log. created_at is the wall
# clock, not the transaction start, so rows keep the order of the steps.
module ByohOperatorLog
  def self.record(command:, target_id:, args:, result:)
    id = DB[:byoh_operator_action].returning(:id).insert(created_at: Sequel.function(:clock_timestamp), command:, target_id:, args: Sequel.pg_jsonb(args), result:).first[:id]
    Clog.emit("byoh operator action", {byoh_operator_action: {id:, command:, target_id:, result:}})
    id
  end
end
