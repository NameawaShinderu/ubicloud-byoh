# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "securerandom"
require "tmpdir"
require "yaml"

# bin/byoh-location: creates and manages the Location of a BYOH site, its
# network profile (location.byoh_network), its billing rates and who can
# use it. Every change is written to byoh_operator_action.
class ByohLocationCli
  class Error < StandardError; end

  # A refused option or value; exits 2, like a usage error.
  class UsageError < Error; end

  USAGE = <<~USAGE
    Usage: bin/byoh-location COMMAND [options]

    Commands:
      create   --name NAME [--display-name NAME] [--ui-name TEXT] [profile options]
               [--rates-from LOCATION [--multiplier X]] [--visible] [--grant PROJECT]...
      add      NAME [the options of create]
      list
      show     --location NAME
      set      --location NAME [--ui-name TEXT] [--[no-]visible] [--unset KEY] [profile options]
               [--virt-tiers LIST] [--accept TIER[:OPTION]] [--unaccept TIER[:OPTION]]
               [--pvm-host-deb URL --pvm-host-deb-sha256 HEX] [--pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX]
               [--pvm-guest-config URL --pvm-guest-config-sha256 HEX | --pvm-guest-unchecked] [--no-verify-download]
               [--pvm-unchecked-drivers LIST]
      rates    --location NAME --rates-from LOCATION [--multiplier X]
      rates    --location NAME --family FAMILY --from FAMILY --multiplier X
      grant    --location NAME --project UBID
      revoke   --location NAME --project UBID
      delete   --location NAME

    The commands that take --location NAME also take NAME alone.
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

  # ubicloud-admin restarts the services itself when a rate file changed;
  # it sets UBICLOUD_ADMIN_RESTARTS=1 for the tool.
  ADMIN_RESTART_NOTE = "ubicloud-admin restarts the services if a rate file changed, so that they load the new rates."

  # Commands that name one location, which they also take alone.
  LOCATION_COMMANDS = %w[show set rates grant revoke delete].freeze

  # The PVM kernel pin options: the pin each sets, and what it names.
  PVM_PIN_FLAGS = {"host-deb" => "host_deb", "guest-kernel" => "guest_kernel", "guest-config" => "guest_config"}.freeze

  def initialize(out: $stdout, err: $stderr, random: SecureRandom, restart_note: (ENV["UBICLOUD_ADMIN_RESTARTS"] == "1") ? ADMIN_RESTART_NOTE : RESTART_NOTE, fetcher: ByohArtifactFetch.new)
    @out = out
    @err = err
    @random = random
    @restart_note = restart_note
    @fetcher = fetcher
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when "create", "list", "show", "set", "rates", "grant", "revoke", "delete"
      argv = location_argument(argv) if LOCATION_COMMANDS.include?(command)
      send(:"cmd_#{command}", argv)
    when "add"
      # site add NAME: create with NAME in place of --name.
      if %w[-h --help].include?(argv.first)
        cmd_create(argv, banner: "add NAME [options]")
      else
        name = argv.shift
        raise UsageError, "add needs a location name: add NAME [options]" if name.nil? || name.start_with?("-")
        cmd_create(argv, name:, banner: "add NAME [options]")
      end
    when nil, "help", "-h", "--help"
      @out.puts USAGE
    else
      raise Error, "unknown command #{command}\n#{USAGE}"
    end
    0
  rescue Error, OptionParser::ParseError, ByohPvmPolicy::Refused, ByohArtifactFetch::Refused => e
    @err.puts "! #{e.message}"
    e.is_a?(UsageError) ? 2 : 1
  end

  private

  # NAME alone, first, stands for --location NAME.
  def location_argument(argv)
    (argv.first && !argv.first.start_with?("-")) ? ["--location", *argv] : argv
  end

  # NAME, from add, stands for --name; add refuses --name (in any
  # spelling OptionParser takes for it) beside it.
  def cmd_create(argv, name: nil, banner: "create --name NAME [options]")
    opts = {grants: [], name:}
    profile = {}
    parse(argv, banner) do |o|
      o.on("--name NAME", "Location name, also the billing rate key (lowercase letters, digits and -)") do
        raise UsageError, "add takes the location name as its argument (add #{name}), not --name #{it}" if name
        opts[:name] = it
      end
      o.on("--display-name NAME", "Name used in API paths (default: --name)") { opts[:display_name] = it }
      # An exact option name wins over a prefix of a longer one in
      # OptionParser, so --display stays apart from --display-name.
      o.on("--ui-name TEXT", "--display TEXT", "Name shown to customers (default: --name)") { opts[:ui_name] = it }
      o.on("--rates-from LOCATION", "Copy every billing rate of LOCATION (see the rates command)") { opts[:rates_from] = it }
      o.on("--multiplier X", Float, "Price multiplier for --rates-from (default 1.0)") { opts[:multiplier] = it }
      o.on("--visible", "Show the location to every project (needs complete billing rates)") { opts[:visible] = true }
      o.on("--grant PROJECT", "Let project PROJECT (a ubid) use the location (repeatable; needs complete billing rates)") { opts[:grants] << it }
      o.on("--postgres CHOICE", "Managed Postgres in the location: no (the only choice yet)") do
        raise UsageError, "--postgres takes no or yes, not #{it}" unless %w[no yes].include?(it)
        raise UsageError, "--postgres yes is UNVERIFIED: Location.postgres_locations excludes BYOH locations (ROADMAP §8.2); pass --postgres no" if it == "yes"
      end
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
    projects = opts[:grants].uniq.map { find_project(it) }

    taken = Location.where(project_id: nil)
      .where(Sequel.|({name:}, {display_name:}, {ui_name:}))
      .select_map(:name)
    raise Error, "location #{taken.first} already uses that name, display name or UI name" unless taken.empty?

    multiplier = opts[:multiplier] || 1.0
    copies = opts[:rates_from] ? source_rates(opts[:rates_from], multiplier).map { it.merge("location" => name) } : []
    # Checked before anything is created, so that a refused --visible
    # leaves no location behind.
    require_rates!(name, "cannot be created visible", copies) if opts[:visible]
    require_rates!(name, "cannot be granted", copies) unless projects.empty?
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
    projects.each { grant(location, it) }
    @out.puts @restart_note
    @out.puts "Next: ubicloud-admin host add --site #{name} --ssh USER@HOST --ssh-key KEY --pool-file pools.yaml (bin/byoh-host add takes the same options)"
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
    @out.puts "Virt tiers    #{virt_summary(location)}"
    if (pins = ByohPvmPolicy.pins(ByohVirtTiers.policy(location)))
      @out.puts "PVM pins"
      ByohPvmPolicy.summary(pins).each { @out.puts "  #{it}" }
    end
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
      virt_options(o, opts)
      profile_options(o, profile)
    end
    location = find_location(opts)
    old_pins = ByohPvmPolicy.pins(ByohVirtTiers.policy(location))
    new_virt = virt_policy(location, opts)

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
    check_tenancy!(location, new_virt || ByohVirtTiers.policy(location), visible: opts[:visible].nil? ? location.visible : opts[:visible])
    # Last, so that nothing is downloaded for a change refused anyway, and
    # before anything is stored.
    new_pins = new_virt ? ByohPvmPolicy.pins(new_virt) : old_pins
    pins_changed = new_pins != old_pins
    new_virt["pvm_kernel"] = verified_pins(old_pins, new_pins, opts) if pins_changed

    changes = {}
    changes[:ui_name] = opts[:ui_name] if opts[:ui_name]
    changes[:byoh_network] = Sequel.pg_jsonb(new_profile) if new_profile != old_profile
    changes[:byoh_virt] = Sequel.pg_jsonb(new_virt) if new_virt
    # The egress table holds the location's deny lists, so a change must
    # reach every host now: VM setup keeps a table that is already loaded.
    # A host before prep gets the new settings from prep.
    egress_changed = ByohNetworkProfile.new(old_profile).egress_nat4_params != ByohNetworkProfile.new(new_profile).egress_nat4_params
    pvm_args = {verify_download: opts[:verify_download] != false, ack: ByohPvmPolicy::ACK} if pins_changed
    strands, downloads = DB.transaction do
      location.update(changes) unless changes.empty?
      audit("set", location, {ui_name: opts[:ui_name], byoh_network: new_profile, byoh_virt: new_virt, pvm_pins: pvm_args}.compact)
      [egress_changed ? start_on_hosts(location, "SetupByohEgressNat") : [], pvm_downloads(location, old_pins, pins_changed && new_virt["pvm_kernel"])]
    end
    @out.puts "Updated location #{location.name}."
    strands.each { |host, strand| @out.puts "Started #{strand.ubid} to install the new egress NAT settings on host #{host.ubid}." }
    downloads.each { |host, strand| @out.puts "Started #{strand.ubid} to download the new PVM guest kernel on host #{host.ubid}; its VMs boot it from their next stop and start." }
    @out.puts ByohPvmPolicy::ACK if pins_changed
    print_pvm_host_kernels(location, old_pins, new_virt["pvm_kernel"]) if pins_changed
    update_visibility(location, opts[:visible]) unless opts[:visible].nil?
    print_warnings
  end

  def cmd_rates(argv)
    opts = {}
    parse(argv, "rates --location NAME (--rates-from LOCATION [--multiplier X] | --family FAMILY --from FAMILY --multiplier X)") do |o|
      location_option(o, opts)
      o.on("--rates-from LOCATION", "Location whose rates are copied, of every resource type and family") { opts[:rates_from] = it }
      o.on("--multiplier X", Float, "Price multiplier (default 1.0 with --rates-from; required with --family)") { opts[:multiplier] = it }
      o.on("--family FAMILY", "Lower-tier family to price (#{ByohVirtTiers::TIERS.keys.join(", ")}) from this location's own rates") { opts[:family] = it }
      o.on("--from FAMILY", "Family of this location whose rates --family copies, e.g. standard") { opts[:from] = it }
    end
    location = find_location(opts)

    if opts[:family] || opts[:from]
      raise Error, "--family and --from go together, without --rates-from" if opts[:rates_from] || !(opts[:family] && opts[:from])
      raise Error, "--family must be one of #{ByohVirtTiers::TIERS.keys.join(", ")}" unless ByohVirtTiers::TIERS.key?(opts[:family])
      raise Error, "--multiplier is required with --family: price the tier deliberately" unless opts[:multiplier]

      # Only what a VM of the family is charged by (ByohVirtTiers::RATE_TYPES).
      rows = source_rates(location.name, opts[:multiplier]).select { it["resource_family"] == opts[:from] && ByohVirtTiers::RATE_TYPES.include?(it["resource_type"]) }
      raise Error, "location #{location.name} has no #{opts[:from]} rates to copy; copy them first with --rates-from" if rows.empty?

      copy_rates(location, "#{location.name}/#{opts[:from]}", opts[:multiplier],
        rows: rows.map { it.merge("resource_family" => opts[:family]) }, id_extra: [opts[:family]])
    else
      raise Error, "--rates-from is required" unless opts[:rates_from]

      copy_rates(location, opts[:rates_from], opts[:multiplier] || 1.0)
    end
    @out.puts @restart_note
  end

  def cmd_grant(argv)
    location, project = location_and_project(argv, "grant")
    require_rates!(location.name, "cannot be granted (run the rates command)")
    grant(location, project)
  end

  # Every grant, from grant or from create --grant, keeps a single-project
  # tier to one project (docs/byoh/NO_KVM.md).
  def grant(location, project)
    others = granted_projects(location).reject { it.id == project.id }
    single = single_project_tiers(ByohVirtTiers.policy(location))
    if !single.empty? && (location.visible || !others.empty?)
      raise Error, "location #{location.name} offers #{single.join(", ")} to one project only, and #{location.visible ? "is visible to every project" : "is granted to #{others.map(&:ubid).join(", ")}"}; revoke first, or acknowledge sharing with set --accept <tier>:multitenant"
    end

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

  def virt_options(o, opts)
    o.separator ""
    o.separator "Virtualization tiers (location.byoh_virt; docs/byoh/NO_KVM.md):"
    o.on("--virt-tiers LIST", Array, "Tiers hosts and VMs of the location may use: #{ByohVirtTiers::IDS.join(", ")} (default kvm)") { opts[:virt_tiers] = it }
    o.on("--accept TIER[:OPTION]", "Acknowledge a lower tier, or one of its options such as container:multitenant (repeatable)") { (opts[:accept] ||= []) << it }
    o.on("--unaccept TIER[:OPTION]", "Withdraw an acknowledgement (repeatable)") { (opts[:unaccept] ||= []) << it }
    o.separator ""
    o.separator "PVM kernel pins (pvm needs them; https URLs with their sha256, third-party builds you choose):"
    # An exact option name wins over a prefix of a longer one, so
    # --pvm-host-deb stays apart from --pvm-host-deb-sha256.
    PVM_PIN_FLAGS.each do |flag, key|
      what = ByohPvmPolicy::FILES[key]
      o.on("--pvm-#{flag} URL", "https URL of the PVM #{what}") { ((opts[:pvm] ||= {})[key] ||= {})["url"] = it }
      o.on("--pvm-#{flag}-sha256 HEX", "sha256 of the PVM #{what}") { ((opts[:pvm] ||= {})[key] ||= {})["sha256"] = it }
    end
    o.on("--pvm-guest-unchecked", "Accept a guest kernel whose config cannot be read (no --pvm-guest-config, no embedded config)") { (opts[:pvm] ||= {})["guest_unchecked"] = true }
    o.on("--no-verify-download", "Store the PVM pins without downloading them first (each host still checks them)") { opts[:verify_download] = it }
    o.on("--pvm-unchecked-drivers LIST", Array, "Disk and NIC drivers you checked the PVM host kernel has, that its preflight cannot map (\"\" clears)") { (opts[:pvm] ||= {})["unchecked_drivers"] = it }
  end

  # The PVM pins after verifying them: every changed file is downloaded
  # and checked against its sha256, and the guest kernel config read,
  # unless --no-verify-download.
  def verified_pins(old_pins, pins, opts)
    return pins unless ByohPvmPolicy.files_changed?(old_pins, pins)

    if opts[:verify_download] == false
      @out.puts "Not downloading the PVM pins (--no-verify-download): each host checks them when it downloads them."
      return ByohPvmPolicy.guest_changed?(old_pins, pins) ? ByohPvmPolicy.unchecked(pins) : pins
    end

    verified = Dir.mktmpdir("byoh-pvm-pins-") { ByohPvmPolicy.verify(old_pins, pins, fetcher: @fetcher, dir: it) }
    @out.puts "Downloaded the changed PVM pins; each matches its sha256."
    if ByohPvmPolicy.guest_changed?(old_pins, pins)
      @out.puts(verified["config_checked"] ? "The guest kernel config has what PVM VMs need; their console is #{verified["guest_console"]}." : "The guest kernel config was not checked (--pvm-guest-unchecked).")
    end
    verified
  end

  # Starts prog on every host of the location past prep (a host before
  # prep gets the location's settings from prep).
  def start_on_hosts(location, prog, hosts = VmHost.where(location_id: location.id), &stack)
    stack ||= ->(host) { {subject_id: host.id} }
    hosts.order(:id).all.select { ByohHostCli.past_prep?(it) }.map do |host|
      [host, Strand.create(prog:, label: "start", stack: [stack.call(host)])]
    end
  end

  # A new guest kernel pin starts its download on every pvm host of the
  # location past prep (Prog::DownloadPvmGuestKernel). A new host kernel
  # package starts nothing: hosts keep the kernel they were installed
  # with.
  def pvm_downloads(location, old_pins, new_pins)
    return [] unless new_pins && ByohPvmPolicy.guest_changed?(old_pins, new_pins)

    start_on_hosts(location, "DownloadPvmGuestKernel", VmHost.where(location_id: location.id, virt_tier: "pvm")) do |host|
      {subject_id: host.id, pin: new_pins.slice(*ByohPvmPolicy::GUEST_KEYS)}
    end
  end

  # A new host-deb pin is not rolled out by itself (docs/byoh/NO_KVM.md
  # section 6.8): the hosts the control plane installed another build on,
  # with how each one moves to the new pin.
  def print_pvm_host_kernels(location, old_pins, new_pins)
    sha256 = new_pins.dig("host_deb", "sha256")
    return if sha256 == old_pins&.dig("host_deb", "sha256")

    ByohPvmHost.where(vm_host_id: VmHost.where(location_id: location.id).select(:id), install: true)
      .exclude(state: "uninstalled").exclude(host_deb_sha256: sha256).order(:vm_host_id).all.each do |row|
      ubid = row.vm_host.ubid
      how = if row.state == "committed"
        "move it with bin/byoh-virt pvm upgrade --host #{ubid} --accept-host-deb #{sha256} once it has no VMs (UNVERIFIED on a real host)"
      else
        "its install stays on the build it acknowledged; see bin/byoh-virt show --host #{ubid}"
      end
      @out.puts "Host #{ubid} (PVM kernel #{row.state}) has host-deb sha256 #{row.host_deb_sha256}, not the new pin: #{how}."
    end
  end

  # The location's new byoh_virt policy, or nil when the options do not
  # change it. Refuses a policy that offers a tier without its
  # acknowledgement, its rates, its rhizome support or (pvm) its kernel
  # pins, or that drops a tier hosts are registered on.
  def virt_policy(location, opts)
    return unless opts[:virt_tiers] || opts[:accept] || opts[:unaccept] || opts[:pvm]

    old = ByohVirtTiers.policy(location)
    tiers = opts[:virt_tiers]&.uniq || old["tiers"]
    unknown = tiers - ByohVirtTiers::IDS
    raise Error, "unknown tier #{unknown.join(", ")}; expected #{ByohVirtTiers::IDS.join(", ")}" unless unknown.empty?
    raise Error, "--virt-tiers needs at least one tier" if tiers.empty?

    acks = old["acks"].transform_values(&:dup)
    Array(opts[:accept]).each do |item|
      tier, option = parse_ack(item)
      if option == "multitenant" && !ByohVirtTiers.multitenant_checked?(tier)
        raise Error, "#{tier}:multitenant is not available yet: nothing checks #{tier} hosts for what sharing them between projects needs (docs/byoh/NO_KVM.md section 6.5), so #{tier} stays single-project"
      end
      acks[tier] ||= []
      acks[tier] |= [option] if option
    end
    Array(opts[:unaccept]).each do |item|
      tier, option = parse_ack(item)
      option ? acks[tier]&.delete(option) : acks.delete(tier)
    end

    pins = pvm_pins(ByohPvmPolicy.pins(old), opts[:pvm])
    tiers.each do |tier|
      next unless ByohVirtTiers.lower?(tier)

      raise Error, "#{tier} is not available yet: this control plane's rhizome cannot run #{tier} hosts (docs/byoh/NO_KVM.md section 11)" unless ByohVirtTiers.shipped?(tier)
      raise Error, "#{tier} must be acknowledged: add --accept #{tier} (#{ByohVirtTiers.fetch(tier).description})" unless acks.key?(tier)
      if tier == "pvm" && !pins
        raise Error, "pvm needs its kernel pins: add --pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX (docs/byoh/NO_KVM.md section 6.7)"
      end
      family = ByohVirtTiers.fetch(tier).family
      missing = ByohVirtTiers::RATE_TYPES.reject { |type| BillingRate.load_rates(BillingRate.rate_globs).any? { it["resource_type"] == type && it["resource_family"] == family && it["location"] == location.name } }
      raise Error, "#{tier} has no #{missing.join(" and ")} rate in #{location.name}; run: bin/byoh-location rates --location #{location.name} --family #{family} --from standard --multiplier X" unless missing.empty?
    end
    (old["tiers"] - tiers).each do |tier|
      hosts = VmHost.where(location_id: location.id, virt_tier: tier).count
      raise Error, "#{tier} has #{hosts} hosts in #{location.name}; destroy them before dropping the tier" unless hosts.zero?
    end

    {"tiers" => tiers, "acks" => acks, "pvm_kernel" => pins}.compact
  end

  # The PVM pins after the pin options (ByohPvmPolicy.merge), or the old
  # ones without any.
  def pvm_pins(old, changes)
    return old unless changes

    changes.each do |key, pin|
      next if key == "guest_unchecked" || key == "unchecked_drivers"
      flag = "--pvm-#{PVM_PIN_FLAGS.key(key)}"
      raise Error, "#{flag} and #{flag}-sha256 go together" unless pin["url"] && pin["sha256"]
    end
    ByohPvmPolicy.merge(old, changes)
  end

  def parse_ack(item)
    tier, option = item.split(":", 2)
    spec = ByohVirtTiers::TIERS[tier] || raise(Error, "cannot acknowledge #{tier}: expected one of #{ByohVirtTiers::TIERS.keys.join(", ")}")
    if option && !spec.options.include?(option)
      raise Error, spec.options.empty? ? "#{tier} has no options" : "#{tier} has no option #{option}; expected one of #{spec.options.join(", ")}"
    end
    [tier, option]
  end

  # The lower tiers of a policy that are single-project.
  def single_project_tiers(policy)
    policy["tiers"].select { ByohVirtTiers.lower?(it) && !ByohVirtTiers.shared?(policy, it) }
  end

  # Refuses a policy whose single-project tiers would be shared: a
  # visible location, or one granted to more than one project.
  def check_tenancy!(location, policy, visible:)
    single = single_project_tiers(policy)
    return if single.empty?

    raise Error, "location #{location.name} offers #{single.join(", ")} to one project only, so it cannot be visible; grant it to one project, or add --accept <tier>:multitenant" if visible

    grants = granted_projects(location)
    raise Error, "location #{location.name} offers #{single.join(", ")} to one project only, but is granted to #{grants.map(&:ubid).join(", ")}" if grants.size > 1
  end

  def virt_summary(location)
    policy = ByohVirtTiers.policy(location)
    policy["tiers"].map { |tier|
      next tier unless ByohVirtTiers.lower?(tier)

      options = Array(policy["acks"][tier])
      "#{ByohVirtTiers.fetch(tier).label}#{" [#{options.join(", ")}]" unless options.empty?}"
    }.join(", ")
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
      o.on("--#{flag} VALUE", "#{key}: #{ByohNetworkProfile::CHOICES.fetch(key).join(", ")}") do
        raise UsageError, "--cp-reach mgmt is available in M8 (the management overlay); use onhost or public" if key == "cp_reach" && it == "mgmt"
        profile[key] = it
      end
    end
    # Here, so that set takes it too: otherwise OptionParser would read
    # --mgmt as the prefix of --mgmt-allow there.
    o.on("--mgmt MODE", "How the control plane reaches the hosts: direct (the only choice until M8)") do
      raise UsageError, "--mgmt #{it} is available in M8 (the management overlay); M4 supports only --mgmt direct, the operator's own route or VPN" unless it == "direct"
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
    [location, find_project(opts[:project] || raise(Error, "--project is required"))]
  end

  def find_project(ubid)
    (Project[ubid] if ubid.match?(/\Apj[0-9a-z]{24}\z/)) || raise(Error, "no project #{ubid}")
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
    check_tenancy!(location, ByohVirtTiers.policy(location), visible:) if visible
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
  def copy_rates(location, source, multiplier, rows: nil, id_extra: [])
    source_rows = rows || source_rates(source, multiplier)
    path = rate_file(location)
    existing = File.exist?(path) ? (YAML.load_file(path, permitted_classes: [Time]) || []) : []
    now = Time.now.utc.floor
    added = []
    replaced = []
    source_rows.group_by { it.values_at(*RATE_KEY) }.each do |key, rows|
      mine = existing.select { it.values_at(*RATE_KEY) == key }
      if mine.empty?
        added.concat(rows.map { copied_rate(location, it, multiplier, it["active_from"], rate_id(location, it, multiplier, *id_extra)) })
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
        copy = copied_rate(location, row, multiplier, at, rate_id(location, row, multiplier, *id_extra, at.iso8601))
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
