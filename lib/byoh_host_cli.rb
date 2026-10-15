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
      add                 --site NAME --ssh USER@HOST (--pool-file FILE | --routed-network CIDR ...) [--yes]
      preflight           --site NAME --ssh USER@HOST [--pool-file FILE | --routed-network CIDR ...]
      watch               HOST [--timeout SECONDS]
      move-location       --host UBID --location NAME --empty-only
      move-location       --host UBID --rollback-to LOCATION --empty-only
      setup-egress-nat    --host UBID
      relearn-device-ids  --host UBID [--yes]
      relearn-pci         --host UBID
      export-audit        [--out FILE]

    Run a command with --help for its options.
  USAGE

  # device_ids is ByohDeviceIdentity.device_ids; specs pass a stand-in.
  # host_add holds keywords for ByohHostAdd (add, preflight, watch).
  def initialize(out: $stdout, err: $stderr, device_ids: ByohDeviceIdentity.method(:device_ids), **host_add)
    @out = out
    @err = err
    @device_ids = device_ids
    @host_add = host_add
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when "add", "preflight", "watch"
      return ByohHostAdd.new(out: @out, err: @err, **@host_add).run(command, argv)
    when "move-location", "setup-egress-nat", "relearn-device-ids", "relearn-pci", "export-audit"
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
    else
      raise Error, "location #{target.name} is not a BYOH location" unless target.byoh?
    end
    raise Error, "host #{host.ubid} is already in location #{target.name}" if host.location_id == target.id

    from = host.location
    notes = []
    pools = 0
    strand, relearn = DB.transaction do
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
      # here. Such a host also learned its GPUs under upstream's rule,
      # which keeps GPUs that are not on vfio-pci; LearnPci applies the
      # BYOH rule and drops those rows (the host has no VMs to hold one).
      past_prep = self.class.past_prep?(host)
      [
        (Strand.create(prog: "SetupByohEgressNat", label: "start", stack: [{subject_id: host.id}]) if rollback || past_prep),
        (start_learn_pci(host) if !rollback && past_prep),
      ]
    end
    @out.puts "Moved host #{host.ubid} from location #{from.name} to #{target.name}."
    @out.puts "Reset #{pools} IPv4 pools to routed and public, with nothing reserved and no external IPs." if pools.positive?
    @out.puts "Started #{strand.ubid} to #{rollback ? "remove" : "install"} the egress NAT table #{rollback ? "from" : "on"} host #{host.ubid}." if strand
    @out.puts "Started #{relearn.ubid} to relearn the GPUs of host #{host.ubid} under the BYOH vfio-pci rule." if relearn
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

  # Recomputes the disk ids of a BYOH host's storage devices with
  # ByohDeviceIdentity and, with --yes, stores them. Hosts registered
  # before it hold "", "root" or partition names, which the health checks
  # cannot resolve, and LearnStorage refuses to relearn once VMs have
  # volumes.
  # Only unix_device_list changes; capacity is left alone.
  def cmd_relearn_device_ids(argv)
    opts = {}
    parse(argv, "relearn-device-ids --host UBID [--yes]") do |o|
      host_option(o, opts)
      o.on("--yes", "Store the new ids (without it, only show them)") { opts[:yes] = true }
    end
    host = find_host(opts)
    raise Error, "host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)" unless host.byoh?

    devices = host.storage_devices.sort_by(&:name)
    raise Error, "host #{host.ubid} has no storage devices yet; LearnStorage records them during prep" if devices.empty?

    ids = begin
      @device_ids.call(host.sshable, devices.map { it.path.chomp("/") })
    rescue ByohDeviceIdentity::Error => e
      raise Error, e.message
    rescue Sshable::SshError => e
      raise Error, "could not read disk ids from host #{host.ubid} over SSH: #{e.message}: #{e.stderr.to_s.strip}"
    rescue *Sshable::SSH_CONNECTION_ERRORS => e
      raise Error, "could not read disk ids from host #{host.ubid} over SSH: #{e.class}: #{e.message}"
    end
    changes = devices.filter_map do |sd|
      new_ids = ids.fetch(sd.path.chomp("/"))
      old_ids = sd.unix_device_list.to_a
      @out.puts "#{sd.name} (#{sd.path.chomp("/")}): #{old_ids.inspect} -> #{new_ids.inspect}#{" (unchanged)" if old_ids == new_ids}"
      [sd, old_ids, new_ids] unless old_ids == new_ids
    end

    if changes.empty?
      @out.puts "Nothing to change."
    elsif !opts[:yes]
      @out.puts "Nothing written; re-run with --yes to store the new ids."
    else
      DB.transaction do
        changes.each { |sd, _, new_ids| sd.update(unix_device_list: Sequel.pg_array(new_ids, :text)) }
        ByohOperatorLog.record(command: "relearn-device-ids", target_id: host.id,
          args: {devices: changes.to_h { |sd, old_ids, new_ids| [sd.name, {from: old_ids, to: new_ids}] }}, result: "ok")
      end
      @out.puts "Stored the new ids of #{changes.size} storage devices of host #{host.ubid}."
    end
  end

  # Reruns LearnPci on a BYOH host past prep. Prep learns a host's GPUs
  # once, so a host learned before the vfio-pci rule (PLATFORMS F9), or
  # whose GPU binding changed since, keeps rows of GPUs a VM cannot
  # open. LearnPci records the GPUs whose IOMMU group is all on vfio-pci
  # and drops the idle rows of the others; a row a VM holds stays.
  def cmd_relearn_pci(argv)
    opts = {}
    parse(argv, "relearn-pci --host UBID") { host_option(it, opts) }
    host = find_host(opts)
    raise Error, "host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)" unless host.byoh?
    raise Error, "host #{host.ubid} is still being prepared; its prep learns the GPUs" unless self.class.past_prep?(host)

    strand = DB.transaction do
      st = start_learn_pci(host)
      ByohOperatorLog.record(command: "relearn-pci", target_id: host.id, args: {}, result: "started #{st.ubid}")
      st
    end
    @out.puts "Started #{strand.ubid} to relearn the GPUs of host #{host.ubid}. The respirate log names each GPU it skips and why."
  end

  def start_learn_pci(host)
    Strand.create(prog: "LearnPci", label: "start", stack: [{subject_id: host.id}])
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
