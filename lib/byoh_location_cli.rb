# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "securerandom"
require "yaml"

# bin/byoh-location: creates and manages the Location of a BYOH site, its
# network profile (location.byoh_network), its billing rates and who can
# use it. Every change is written to byoh_operator_action.
class ByohLocationCli
  class Error < StandardError; end

  USAGE = <<~USAGE
    Usage: bin/byoh-location COMMAND [options]

    Commands:
      create   --name NAME [--display-name NAME] [--ui-name TEXT] [profile options]
               [--rates-from LOCATION [--multiplier X]] [--visible]
      list
      show     --location NAME
      set      --location NAME [--ui-name TEXT] [--[no-]visible] [--unset KEY] [profile options]
      rates    --location NAME --rates-from LOCATION [--multiplier X]
      grant    --location NAME --project UBID
      revoke   --location NAME --project UBID
      delete   --location NAME

    Run a command with --help for its options.
  USAGE

  NAME_FORMAT = /\A[a-z][a-z0-9-]{0,61}[a-z0-9]\z/

  # Profile options that take a comma-separated list.
  LIST_FLAGS = {
    "underlay" => "underlay_cidrs",
    "overlay" => "overlay_ipv4_cidrs",
    "cp-source" => "cp_source_cidrs",
    "mgmt-allow" => "host_mgmt_allow",
    "egress-deny" => "vm_egress_deny",
    "egress-allow" => "vm_egress_allow",
    "dns-servers" => "dns_servers",
  }.freeze

  CHOICE_FLAGS = {
    "cp-reach" => "cp_reach",
    "ula-underlay" => "ula_underlay",
    "internal-egress" => "internal_egress",
  }.freeze

  # Namespace of the UUIDv5 ids of copied billing rates.
  RATE_ID_NAMESPACE = "4f0c7a3e-5b1d-4e8a-9c2f-6d3b8a1e0f57"

  # Tables whose rows are deleted with the location itself.
  DELETED_WITH_LOCATION = %w[location_az location_credential_aws location_credential_gcp provider_ip_range].freeze

  # The fields that, with the location, identify a billing rate.
  RATE_KEY = %w[resource_type resource_family byoc].freeze

  LIST_ROW = "%-24s %-24s %-8s %-6s %-7s %s"

  RESTART_NOTE = "Restart web, respirate and monitor with BILLING_RATES_EXTRA_DIR set, so that they load the new rates."

  def initialize(out: $stdout, err: $stderr, random: SecureRandom)
    @out = out
    @err = err
    @random = random
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when "create", "list", "show", "set", "rates", "grant", "revoke", "delete"
      send(:"cmd_#{command}", argv)
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

  def cmd_create(argv)
    opts = {}
    profile = {}
    parse(argv, "create --name NAME [options]") do |o|
      o.on("--name NAME", "Location name, also the billing rate key (lowercase letters, digits and -)") { opts[:name] = it }
      o.on("--display-name NAME", "Name used in API paths (default: --name)") { opts[:display_name] = it }
      o.on("--ui-name TEXT", "Name shown to customers (default: --name)") { opts[:ui_name] = it }
      o.on("--rates-from LOCATION", "Copy every billing rate of LOCATION (see the rates command)") { opts[:rates_from] = it }
      o.on("--multiplier X", Float, "Price multiplier for --rates-from (default 1.0)") { opts[:multiplier] = it }
      o.on("--visible", "Show the location to every project (needs complete billing rates)") { opts[:visible] = true }
      profile_options(o, profile)
    end

    name = opts[:name] || raise(Error, "--name is required")
    display_name = opts[:display_name] || name
    ui_name = opts[:ui_name] || name
    {"--name" => name, "--display-name" => display_name}.each do |flag, value|
      raise Error, "#{flag} #{value} must be lowercase letters, digits and -" unless NAME_FORMAT.match?(value)
    end
    raise Error, "--name global is reserved for global billing rates" if name == "global"
    raise Error, "--multiplier needs --rates-from" if opts[:multiplier] && !opts[:rates_from]

    taken = Location.where(project_id: nil)
      .where(Sequel.|({name:}, {display_name:}, {ui_name:}))
      .select_map(:name)
    raise Error, "location #{taken.first} already uses that name, display name or UI name" unless taken.empty?

    multiplier = opts[:multiplier] || 1.0
    copies = opts[:rates_from] ? source_rates(opts[:rates_from], multiplier).map { it.merge("location" => name) } : []
    # Checked before anything is created, so that a refused --visible
    # leaves no location behind.
    require_rates!(name, "cannot be created visible", copies) if opts[:visible]
    profile["ula48"] ||= generate_ula48
    check_profile!(profile, nil)

    location = DB.transaction do
      location = Prog::LocationNexus.assemble(
        name:, display_name:, ui_name:, visible: false,
        provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: Sequel.pg_jsonb(profile),
      ).subject
      audit("create", location, {name:, display_name:, ui_name:, byoh_network: profile})
      location
    end
    @out.puts "Created location #{location.name} (#{location.ubid}), hidden."

    copy_rates(location, opts[:rates_from], multiplier) if opts[:rates_from]
    update_visibility(location, true) if opts[:visible]
    @out.puts RESTART_NOTE
    print_warnings
  end

  def cmd_list(argv)
    parse(argv, "list")
    locations = byoh_locations
    if locations.empty?
      @out.puts "No BYOH locations."
      return
    end

    rates = BillingRate.load_rates(BillingRate.rate_globs)
    @out.puts format(LIST_ROW, "NAME", "DISPLAY NAME", "VISIBLE", "HOSTS", "GRANTS", "RATES")
    locations.each do |location|
      @out.puts format(LIST_ROW,
        location.name, location.display_name, location.visible, VmHost.where(location_id: location.id).count,
        granted_projects(location).count, ByohPreflightWarnings.missing_rates(location.name, rates).empty? ? "complete" : "missing")
    end
  end

  def cmd_show(argv)
    opts = {}
    parse(argv, "show --location NAME") { location_option(it, opts) }
    location = find_location(opts)

    missing = ByohPreflightWarnings.missing_rates(location.name)
    @out.puts "Location      #{location.name} (#{location.ubid})"
    @out.puts "Display name  #{location.display_name}"
    @out.puts "UI name       #{location.ui_name}"
    @out.puts "Visible       #{location.visible}"
    @out.puts "Hosts         #{VmHost.where(location_id: location.id).count}"
    @out.puts "Granted to    #{granted_projects(location).map(&:ubid).join(", ")}"
    @out.puts "Rate file     #{rate_file(location) || "(BILLING_RATES_EXTRA_DIR is unset)"}"
    @out.puts "Rates         #{missing.empty? ? "complete" : "missing #{missing.map { it.join("/") }.join(", ")}"}"
    @out.puts "Profile"
    @out.puts JSON.pretty_generate(location.byoh_network.to_h)
    print_warnings
  end

  def cmd_set(argv)
    opts = {unset: []}
    profile = {}
    parse(argv, "set --location NAME [options]") do |o|
      location_option(o, opts)
      o.on("--ui-name TEXT", "Name shown to customers") { opts[:ui_name] = it }
      o.on("--[no-]visible", "Show the location to every project (needs complete billing rates)") { opts[:visible] = it }
      o.on("--unset KEY", "Remove a profile key, restoring its default (repeatable)") { opts[:unset] << it }
      profile_options(o, profile)
    end
    location = find_location(opts)

    unknown = opts[:unset] - (ByohNetworkProfile::KEYS - ["ula48"])
    raise Error, "--unset cannot remove #{unknown.join(", ")}" unless unknown.empty?

    old_profile = location.byoh_network.to_h
    new_profile = old_profile.merge(profile).except(*opts[:unset])
    if new_profile["ula48"] != old_profile["ula48"] && !VmHost.where(location_id: location.id).empty?
      raise Error, "ula48 cannot change while the location has hosts"
    end
    if opts[:ui_name]
      taken = Location.where(project_id: nil, ui_name: opts[:ui_name]).exclude(id: location.id).select_map(:name)
      raise Error, "location #{taken.first} already uses UI name #{opts[:ui_name]}" unless taken.empty?
    end
    check_profile!(new_profile, location)
    require_rates!(location.name, "stays hidden") if opts[:visible]

    changes = {}
    changes[:ui_name] = opts[:ui_name] if opts[:ui_name]
    changes[:byoh_network] = Sequel.pg_jsonb(new_profile) if new_profile != old_profile
    # The egress table holds the location's deny lists, so a change must
    # reach every host now: VM setup keeps a table that is already loaded.
    # A host before prep gets the new settings from prep.
    egress_changed = ByohNetworkProfile.new(old_profile).egress_nat4_params != ByohNetworkProfile.new(new_profile).egress_nat4_params
    strands = DB.transaction do
      location.update(changes) unless changes.empty?
      audit("set", location, {ui_name: opts[:ui_name], byoh_network: new_profile}.compact)
      next [] unless egress_changed

      VmHost.where(location_id: location.id).order(:id).all.select { ByohHostCli.past_prep?(it) }.map do |host|
        [host, Strand.create(prog: "SetupByohEgressNat", label: "start", stack: [{subject_id: host.id}])]
      end
    end
    @out.puts "Updated location #{location.name}."
    strands.each { |host, strand| @out.puts "Started #{strand.ubid} to install the new egress NAT settings on host #{host.ubid}." }
    update_visibility(location, opts[:visible]) unless opts[:visible].nil?
    print_warnings
  end

  def cmd_rates(argv)
    opts = {}
    parse(argv, "rates --location NAME --rates-from LOCATION [--multiplier X]") do |o|
      location_option(o, opts)
      o.on("--rates-from LOCATION", "Location whose rates are copied, of every resource type and family") { opts[:rates_from] = it }
      o.on("--multiplier X", Float, "Price multiplier (default 1.0)") { opts[:multiplier] = it }
    end
    location = find_location(opts)
    raise Error, "--rates-from is required" unless opts[:rates_from]

    copy_rates(location, opts[:rates_from], opts[:multiplier] || 1.0)
    @out.puts RESTART_NOTE
  end

  def cmd_grant(argv)
    location, project = location_and_project(argv, "grant")
    require_rates!(location.name, "cannot be granted (run the rates command)")

    DB.transaction do
      project.set_ff_visible_locations(((project.get_ff_visible_locations || []) + [location.name]).uniq)
      audit("grant", location, {project: project.ubid})
    end
    @out.puts "Project #{project.ubid} can now use location #{location.name}."
  end

  def cmd_revoke(argv)
    location, project = location_and_project(argv, "revoke")
    granted = project.get_ff_visible_locations || []
    unless granted.include?(location.name)
      @out.puts "Project #{project.ubid} has no grant for location #{location.name}."
      return
    end

    DB.transaction do
      project.set_ff_visible_locations(granted - [location.name])
      audit("revoke", location, {project: project.ubid})
    end
    @out.puts "Revoked the grant of location #{location.name} from project #{project.ubid}."
  end

  def cmd_delete(argv)
    opts = {}
    parse(argv, "delete --location NAME") { location_option(it, opts) }
    location = find_location(opts)

    grants = granted_projects(location)
    raise Error, "revoke the grants first: #{grants.map(&:ubid).join(", ")}" unless grants.empty?

    in_use = location_references.filter_map do |table, column|
      count = DB[table.to_sym].where(column.to_sym => location.id).count
      "#{count} #{table}" if count > 0
    end
    raise Error, "location #{location.name} is still used by #{in_use.join(", ")}" unless in_use.empty?

    DB.transaction do
      location.incr_destroy
      audit("delete", location, {name: location.name})
    end
    @out.puts "Location #{location.name} will be deleted by its strand."
    path = rate_file(location)
    @out.puts "The rate file #{path} is kept: old invoices may refer to its rates." if path && File.exist?(path)
  end

  def parse(argv, banner)
    parser = OptionParser.new do |o|
      o.banner = "Usage: bin/byoh-location #{banner}"
      yield o if block_given?
    end
    rest = parser.parse(argv)
    raise Error, "unexpected argument #{rest.first}" unless rest.empty?
  end

  def location_option(o, opts)
    o.on("--location NAME", "BYOH location name or ubid") { opts[:location] = it }
  end

  def profile_options(o, profile)
    o.separator ""
    o.separator "Profile options (location.byoh_network):"
    LIST_FLAGS.each do |flag, key|
      o.on("--#{flag} LIST", Array, "#{key}, comma-separated") { profile[key] = it }
    end
    CHOICE_FLAGS.each do |flag, key|
      o.on("--#{flag} VALUE", "#{key}: #{ByohNetworkProfile::CHOICES.fetch(key).join(", ")}") { profile[key] = it }
    end
    o.on("--ula48 CIDR", "ULA /48 that host IPv6 prefixes are drawn from (default: random)") { profile["ula48"] = it }
    o.on("--guest-mtu N", Integer, "Guest MTU") { profile["guest_mtu"] = it }
    o.on("--[no-]egress-smtp", "Allow outbound SMTP (port 25) through the host NAT (default: no)") { profile["egress_smtp"] = it }
    o.on("--[no-]vm-egress-nat4", "Give VMs without public IPv4 outbound IPv4 through the host (default: yes)") { profile["vm_egress_nat4"] = it }
  end

  def find_location(opts)
    key = opts[:location] || raise(Error, "--location is required")
    location = Location.first(project_id: nil, name: key) || (Location[key] if key.match?(/\A10[0-9a-z]{24}\z/))
    raise Error, "no location #{key}" unless location
    raise Error, "location #{location.name} is not a BYOH location" unless location.byoh?
    location
  end

  def location_and_project(argv, command)
    opts = {}
    parse(argv, "#{command} --location NAME --project UBID") do |o|
      location_option(o, opts)
      o.on("--project UBID", "Project ubid") { opts[:project] = it }
    end
    location = find_location(opts)
    project_ubid = opts[:project] || raise(Error, "--project is required")
    project = (Project[project_ubid] if project_ubid.match?(/\Apj[0-9a-z]{24}\z/)) || raise(Error, "no project #{project_ubid}")
    [location, project]
  end

  def byoh_locations
    Location.exclude(byoh_network: nil).order(:name).all
  end

  def granted_projects(location)
    Project.where(Sequel.pg_jsonb_op(:feature_flags).contains(Sequel.pg_jsonb({"visible_locations" => [location.name]}))).order(:id).all
  end

  def location_references
    DB.fetch(<<~SQL).map { [it[:table_name], it[:column_name]] }.reject { DELETED_WITH_LOCATION.include?(it.first) }
      SELECT c.conrelid::regclass::text AS table_name, a.attname AS column_name
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
      WHERE c.contype = 'f' AND c.confrelid = 'location'::regclass
      ORDER BY 1, 2
    SQL
  end

  def check_profile!(profile, location)
    errors = ByohNetworkProfile.new(profile).errors
    raise Error, "invalid profile: #{errors.join("; ")}" unless errors.empty?
    return unless profile["ula48"]

    ula48 = ByohNetworkProfile.parse_cidr(profile["ula48"]).to_s
    other = byoh_locations.find { it.id != location&.id && ByohNetworkProfile.parse_cidr(it.byoh_network["ula48"].to_s).to_s == ula48 }
    raise Error, "ula48 #{ula48} is already used by location #{other.name}" if other
  end

  def generate_ula48
    used = byoh_locations.map { ByohNetworkProfile.parse_cidr(it.byoh_network["ula48"].to_s).to_s }
    32.times do
      candidate = ByohNetworkProfile.parse_cidr(format("fd%02x:%02x%02x:%02x%02x::/48", *@random.random_bytes(5).bytes)).to_s
      return candidate unless used.include?(candidate)
    end
    raise Error, "could not pick an unused ula48; pass --ula48"
  end

  # Refuses unless the rate files, plus the rates in extra, have every
  # minimum rate of the location.
  def require_rates!(name, consequence, extra = [])
    missing = ByohPreflightWarnings.missing_rates(name, BillingRate.load_rates(BillingRate.rate_globs) + extra)
    raise Error, "location #{name} #{consequence}: no billing rate for #{missing.map { it.join("/") }.join(", ")}" unless missing.empty?
  end

  def update_visibility(location, visible)
    require_rates!(location.name, "stays hidden") if visible
    DB.transaction do
      location.update(visible:)
      audit(visible ? "set-visible" : "set-hidden", location, {})
    end
    @out.puts "Location #{location.name} is now #{visible ? "visible" : "hidden"}."
  end

  def rate_file(location)
    File.join(BillingRate.extra_dir, "#{location.name}.yml") if BillingRate.extra_dir
  end

  # Appends rates for location, copied from every rate of source, to the
  # location's overlay file. A key (type, family, byoc) the file lacks gets
  # all source rows with their own active_from. For a key it has, the
  # source row in force now and every source row dated later are copied,
  # each active from now or its own later date, unless the file already
  # charges that price then. So a price upstream schedules ahead starts
  # on its date, and running the same command again adds nothing.
  def copy_rates(location, source, multiplier)
    source_rows = source_rates(source, multiplier)
    path = rate_file(location)
    existing = File.exist?(path) ? (YAML.load_file(path, permitted_classes: [Time]) || []) : []
    now = Time.now.utc.floor
    added = []
    replaced = []
    source_rows.group_by { it.values_at(*RATE_KEY) }.each do |key, rows|
      mine = existing.select { it.values_at(*RATE_KEY) == key }
      if mine.empty?
        added.concat(rows.map { copied_rate(location, it, multiplier, it["active_from"], rate_id(location, it, multiplier)) })
        next
      end

      in_force = rows.select { it["active_from"] <= now }.max_by { it["active_from"] }
      [in_force, *rows.select { it["active_from"] > now }.sort_by { it["active_from"] }].compact.each do |row|
        at = [now, row["active_from"]].max
        previous = mine.select { it["active_from"] <= at }.max_by { it["active_from"] }
        next if previous && previous["unit_price"].to_f.round(10) == (row["unit_price"] * multiplier).round(10) && previous["billed_by"] == row["billed_by"]

        # A row of the file dated at the same time, now or later, has
        # billed nothing yet (processes load the file when they start),
        # so it is replaced instead of left to tie with the copy.
        stale = mine.select { it["active_from"] == at }
        replaced.concat(stale)
        copy = copied_rate(location, row, multiplier, at, rate_id(location, row, multiplier, at.iso8601))
        mine = mine - stale + [copy]
        added << copy
      end
    end

    if added.empty?
      @out.puts "#{path} already has every rate of #{source}."
      return
    end

    # One document of rows, each dumped alone so that Psych writes no
    # aliases for values the rows share (YAML.load_file refuses them).
    yaml = "---\n" + (existing - replaced + added).map { [it].to_yaml.delete_prefix("---\n") }.join
    FileUtils.mkdir_p(File.dirname(path))
    File.write("#{path}.tmp", yaml)
    File.rename("#{path}.tmp", path)
    # The YAML goes into the audit row too, so a database backup can
    # restore a lost overlay directory.
    audit("rates", location, {rates_from: source, multiplier:, file: path, added: added.size, replaced: replaced.size, yaml:})
    @out.puts "Wrote #{added.size} rates copied from #{source} (x#{multiplier}) to #{path}#{", replacing #{replaced.size} not yet in force" unless replaced.empty?}."
  end

  # The rates copy_rates would copy; refuses when it cannot run.
  def source_rates(source, multiplier)
    raise Error, "BILLING_RATES_EXTRA_DIR is not set" unless BillingRate.extra_dir
    raise Error, "--multiplier must be positive" unless multiplier.positive?

    rows = BillingRate.load_rates(BillingRate.rate_globs).select { it["location"] == source }
    raise Error, "no billing rates for location #{source}" if rows.empty?
    rows
  end

  def copied_rate(location, row, multiplier, active_from, id)
    {
      "id" => id,
      "resource_type" => row["resource_type"],
      "resource_family" => row["resource_family"],
      "location" => location.name,
      "unit_price" => (row["unit_price"] * multiplier).round(10),
      "billed_by" => row["billed_by"],
      "active_from" => active_from,
      "byoc" => row["byoc"],
    }
  end

  # A UUIDv5 (RFC 9562) of the location, the source rate and the copy's
  # parameters, so the same copy always gets the same id.
  def rate_id(location, row, multiplier, *extra)
    namespace = [RATE_ID_NAMESPACE.delete("-")].pack("H*")
    hash = Digest::SHA1.digest(namespace + [location.name, row["id"], multiplier, *extra].join("|")).bytes.first(16)
    hash[6] = (hash[6] & 0x0f) | 0x50
    hash[8] = (hash[8] & 0x3f) | 0x80
    hash.pack("C*").unpack1("H*").unpack("a8a4a4a4a12").join("-")
  end

  def audit(action, location, args)
    ByohOperatorLog.record(command: "byoh-location #{action}", target_id: location.id, args:, result: "ok")
  end

  def print_warnings
    ByohPreflightWarnings.warnings.each { @err.puts "warning: #{it}" }
  end
end
