# frozen_string_literal: true

require "json"
require "optparse"

# bin/byoh-host: operator commands for registered BYOH hosts. Every change
# is written to byoh_operator_action.
class ByohHostCli
  class Error < StandardError; end

  USAGE = <<~USAGE
    Usage: bin/byoh-host COMMAND [options]

    Commands:
      move-location     --host UBID --location NAME --empty-only
      move-location     --host UBID --rollback-to LOCATION --empty-only
      setup-egress-nat  --host UBID
      export-audit      [--out FILE]

    Run a command with --help for its options.
  USAGE

  def initialize(out: $stdout, err: $stderr)
    @out = out
    @err = err
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when "move-location", "setup-egress-nat", "export-audit"
      send(:"cmd_#{command.tr("-", "_")}", argv)
    when nil, "help", "-h", "--help"
      @out.puts USAGE
    else
      raise Error, "unknown command #{command}\n#{USAGE}"
    end
    0
  rescue Error, OptionParser::ParseError => e
    @err.puts "! #{e.message}"
    1
  end

  private

  # Moves an empty generic host into a BYOH location, or, with
  # --rollback-to, out of one into a non-BYOH location. Hosts with VMs are
  # refused: the VMs belong to the old location and their addresses were
  # chosen under its rules.
  def cmd_move_location(argv)
    opts = {}
    parse(argv, "move-location --host UBID (--location NAME | --rollback-to LOCATION) --empty-only") do |o|
      host_option(o, opts)
      o.on("--location NAME", "BYOH location to move the host into") { opts[:location] = it }
      o.on("--rollback-to LOCATION", "Non-BYOH location to move the host back to") { opts[:rollback_to] = it }
      o.on("--empty-only", "Move only a host without VMs (required)") { opts[:empty_only] = true }
    end
    raise Error, "pass either --location or --rollback-to" unless opts.key?(:location) ^ opts.key?(:rollback_to)
    raise Error, "--empty-only is required: only hosts without VMs can be moved" unless opts[:empty_only]

    host = find_host(opts)
    rollback = opts.key?(:rollback_to)
    target = find_location(opts[:location] || opts[:rollback_to])
    if rollback
      raise Error, "host #{host.ubid} is not in a BYOH location; nothing to roll back" unless host.location.byoh?
      raise Error, "location #{target.name} is a BYOH location; --rollback-to moves a host out of BYOH (use --location)" if target.byoh?
    else
      raise Error, "location #{target.name} is not a BYOH location" unless target.byoh?
    end
    raise Error, "host #{host.ubid} is already in location #{target.name}" if host.location_id == target.id

    from = host.location
    DB.transaction do
      # The row lock makes a concurrent allocation wait until the move
      # commits, so a VM placed before it is seen here.
      host = VmHost.dataset.for_update.with_pk(host.id)
      vms = host.vms_dataset.count
      raise Error, "host #{host.ubid} has #{vms} VMs; destroy them first" unless vms.zero?

      host.update(location_id: target.id)
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("location_label" => target.name)))
      ByohOperatorLog.record(command: rollback ? "move-location-rollback" : "move-location", target_id: host.id,
        args: {from: from.name, to: target.name}, result: "ok")
    end
    @out.puts "Moved host #{host.ubid} from location #{from.name} to #{target.name}."
  end

  def cmd_setup_egress_nat(argv)
    opts = {}
    parse(argv, "setup-egress-nat --host UBID") { host_option(it, opts) }
    host = find_host(opts)
    raise Error, "host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)" unless host.byoh?
    raise Error, "setup-egress-nat is not available yet: the host egress NAT is not part of this release"
  end

  # Writes every byoh_operator_action row as JSON lines and records the
  # newest exported row in the table comment, which the network contract
  # migration's down guard reads. The table is locked against writers
  # meanwhile, so no row can commit with an earlier created_at after the
  # export.
  def cmd_export_audit(argv)
    opts = {}
    parse(argv, "export-audit [--out FILE]") do |o|
      o.on("--out FILE", "Write to FILE instead of standard output") { opts[:out] = it }
    end

    lines = DB.transaction do
      DB.run("LOCK TABLE byoh_operator_action IN SHARE MODE")
      rows = DB[:byoh_operator_action].order(:created_at, :id).all
      exported_at = rows.last&.fetch(:created_at) || DB.get(Sequel.function(:clock_timestamp))
      DB.run(Sequel.lit("COMMENT ON TABLE byoh_operator_action IS ?", "exported_at=#{exported_at.utc.iso8601(6)}"))
      rows.map do |row|
        JSON.generate(row.merge(created_at: row[:created_at].utc.iso8601(6), args: row[:args].to_h))
      end
    end

    text = lines.map { "#{it}\n" }.join
    if opts[:out]
      File.write(opts[:out], text)
      @err.puts "Exported #{lines.size} operator actions to #{opts[:out]}."
    else
      @out.print text
    end
  end

  def parse(argv, banner)
    parser = OptionParser.new do |o|
      o.banner = "Usage: bin/byoh-host #{banner}"
      yield o
    end
    rest = parser.parse(argv)
    raise Error, "unexpected argument #{rest.first}" unless rest.empty?
  end

  def host_option(o, opts)
    o.on("--host UBID", "VmHost ubid") { opts[:host] = it }
  end

  def find_host(opts)
    key = opts[:host] || raise(Error, "--host is required")
    host = (VmHost[key] if key.match?(/\Avh[0-9a-z]{24}\z/)) || raise(Error, "no host #{key}")
    raise Error, "host #{host.ubid} is not a generic (BYOH) host" unless host.provider_name == HostProvider::GENERIC_PROVIDER_NAME
    host
  end

  def find_location(key)
    ByohRegistration.find_location(key) || raise(Error, "no location #{key}")
  end
end
