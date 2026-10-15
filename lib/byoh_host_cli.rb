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

  # Labels at which Prog::Vm::HostNexus has not yet budded its prep
  # children, so prep will install the egress NAT table itself.
  PRE_PREP_LABELS = %w[start install_host_os setup_ssh_keys bootstrap_rhizome check_ip_reachability prep].freeze

  # Whether the host's prep has started installing its egress NAT table,
  # so a later change must be installed by a SetupByohEgressNat strand.
  def self.past_prep?(host)
    !(host.allocation_state == "unprepared" && PRE_PREP_LABELS.include?(host.strand.label))
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
      # Only BYOH locations have lower virtualization tiers.
      raise Error, "host #{host.ubid} has virt tier #{host.virt_tier}, which only BYOH locations can hold; destroy and register it again instead" if ByohVirtTiers.lower?(host.virt_tier)
    else
      raise Error, "location #{target.name} is not a BYOH location" unless target.byoh?
      # The byoh_virt CHECK makes a listed lower tier an acknowledged one.
      raise Error, "location #{target.name} does not offer #{host.virt_tier} hosts; see bin/byoh-location set --virt-tiers" unless ByohVirtTiers.allows?(target, host.virt_tier)
    end
    raise Error, "host #{host.ubid} is already in location #{target.name}" if host.location_id == target.id

    from = host.location
    notes = []
    pools = 0
    strand = DB.transaction do
      # The row lock makes the move wait for an allocation that already
      # wrote a VM to the host, so that VM is counted here. It does not
      # stop an allocation that chose the host before the lock but writes
      # after the move commits: the allocator does not re-check the
      # location then. Requiring a host that is not accepting keeps it out
      # of every candidate search for the whole move.
      host = VmHost.dataset.for_update.with_pk(host.id)
      if host.allocation_state == "accepting"
        raise Error, "host #{host.ubid} is accepting VMs; move it to draining first (admin \"Move to Draining\") so no VM is placed on it during the move"
      end
      vms = host.vms_dataset.count
      raise Error, "host #{host.ubid} has #{vms} VMs; destroy them first" unless vms.zero?

      if rollback
        pools = ByohPool.new(host).reset_to_legacy(host)
      else
        notes = check_pools_for_location(host, target)
      end
      host.update(location_id: target.id)
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("location_label" => target.name)))
      ByohOperatorLog.record(command: rollback ? "move-location-rollback" : "move-location", target_id: host.id,
        args: {from: from.name, to: target.name}, result: "ok")
      # A host leaving BYOH must not keep the BYOH egress NAT table, which
      # outlives reboots. Prog::SetupByohEgressNat removes it from a host
      # that is no longer a BYOH host. A host entering BYOH needs the
      # table before it takes VMs, as it is all that keeps them off the
      # metadata service and the underlay; prep installs it only on hosts
      # that are BYOH hosts when prep runs, so a host past prep gets it
      # here.
      Strand.create(prog: "SetupByohEgressNat", label: "start", stack: [{subject_id: host.id}]) if rollback || self.class.past_prep?(host)
    end
    @out.puts "Moved host #{host.ubid} from location #{from.name} to #{target.name}."
    @out.puts "Reset #{pools} IPv4 pools to routed and public, with nothing reserved and no external IPs." if pools.positive?
    @out.puts "Started #{strand.ubid} to #{rollback ? "remove" : "install"} the egress NAT table #{rollback ? "from" : "on"} host #{host.ubid}." if strand
    notes.each { @out.puts "  #{it}" }
    @out.puts "The host is #{host.allocation_state}; set it to accepting in the admin UI when it should take VMs." if host.allocation_state == "draining"
  end

  # The host's pools must pass the same location checks registration
  # applies, so moving cannot place pools in a location that would refuse
  # them. Returns notes for the operator.
  def check_pools_for_location(host, target)
    pools = Array(host.provider.config["routed_networks"]).map { ByohPoolDeclaration.parse(it, legacy: true) }
    errors = pools.flat_map { ByohPoolDeclaration.location_overlap_errors(it, target) }
    raise Error, "host #{host.ubid} cannot move to #{target.name}:\n#{errors.join("\n")}" unless errors.empty?

    ula48 = target.byoh_profile.ula48
    declared_v6 = pools.select(&:ipv6?).map { it.cidr.to_s }
    if ula48 && !declared_v6.include?(host.net6.to_s) && !ByohNetworkProfile.overlap?(ula48, host.net6)
      ["note: the host's IPv6 network #{host.net6} is outside #{target.name}'s ula48 #{ula48}; it keeps working, but re-register the host to draw one from #{ula48}"]
    else
      []
    end
  end

  def cmd_setup_egress_nat(argv)
    opts = {}
    parse(argv, "setup-egress-nat --host UBID") { host_option(it, opts) }
    host = find_host(opts)
    raise Error, "host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)" unless host.byoh?
    raise Error, "host #{host.ubid} is still being prepared; its prep sets up the egress NAT" if host.allocation_state == "unprepared"

    strand = DB.transaction do
      st = Strand.create(prog: "SetupByohEgressNat", label: "start", stack: [{subject_id: host.id}])
      ByohOperatorLog.record(command: "setup-egress-nat", target_id: host.id, args: {location: host.location.name}, result: "started #{st.ubid}")
      st
    end
    @out.puts "Started #{strand.ubid} to install the egress NAT table on host #{host.ubid} from location #{host.location.name}'s profile."
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
