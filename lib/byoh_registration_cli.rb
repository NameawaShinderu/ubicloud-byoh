# frozen_string_literal: true

require "optparse"

# bin/register-byoh-host: registers a bring-your-own host in a BYOH
# location. Parses the options, shows the SSH key the operator installs
# on the host, and hands the rest to ByohRegistration.
class ByohRegistrationCli
  class Error < StandardError; end

  def initialize(out: $stdout, err: $stderr, input: $stdin)
    @out = out
    @err = err
    @input = input
  end

  # Returns the process exit status.
  def run(argv)
    options = parse(argv)
    return 0 unless options

    registration = ByohRegistration.new(
      main_ip: options[:main_ip],
      location: options[:location],
      pools: options[:pools],
      pool_file: options[:pool_file],
      ipv6_mode: options[:ipv6_mode],
      ssh_key_source: options[:ssh_key_source],
      server_identifier: options[:server_identifier],
      bmc_config: options[:bmc],
      default_boot_images: options[:default_boot_images],
    )
    registration.validate!
    virt = ByohVirtRegistration.new(declared: options[:virt_tier], accept_fallback: options[:accept_fallback], probe: options[:virt_probe] != false)
    cfg = registration.provider_config
    registration.notes.each { @err.puts "note: #{it}" }

    @out.puts "ubicloud byoh host registration"
    @out.puts "────────────────────────────────"
    @out.puts
    @out.puts "Step 1/2 — Install the control-plane SSH public key on the host"
    @out.puts "────────────────────────────────"
    @out.puts registration.install_instructions
    unless options[:assume_yes]
      @out.print "Press ENTER once the public key is installed, or Ctrl-C to abort: "
      @input.readline
    end

    # The host can be probed only once the key is installed.
    verdict, unprobed = virt.probe(options[:main_ip], SshKey.from_binary(registration.keypair).private_key)
    decision = virt.decide!(verdict, location: registration.location, main_ip: options[:main_ip], unprobed_reason: unprobed)
    decision.notes.each { @err.puts "note: #{it}" }

    @out.puts
    @out.puts "Step 2/2 — Registering host with control plane"
    @out.puts "────────────────────────────────"
    print_summary(registration, cfg, decision)

    strand = registration.register!(virt: decision)
    vm_host = VmHost[strand.id]

    @out.puts "Host registered."
    @out.puts "  VmHost UBID:  #{vm_host.ubid}"
    @out.puts "  Strand UBID:  #{strand.ubid}"
    @out.puts
    @out.puts "The dispatcher will pick up the strand and drive bootstrap automatically."
    @out.puts "Monitor progress via the admin console, or query the DB directly:"
    @out.puts "  SELECT label, stack FROM strand WHERE id = '#{strand.id}';"
    0
  rescue ByohRegistration::ValidationError => ex
    @err.puts "! validation failed: #{ex.message}"
    1
  rescue ByohVirtRegistration::Refused => ex
    @err.puts "! refused: #{ex.message}"
    1
  rescue Error, OptionParser::ParseError => ex
    @err.puts "! #{ex.message}"
    1
  rescue EOFError
    @err.puts "! aborted: no confirmation on standard input (pass --yes to skip it)"
    1
  end

  private

  # Returns the options, or nil after printing the help.
  def parse(argv)
    options = {pools: [], ssh_key_source: :generate, assume_yes: false, bmc: nil, default_boot_images: []}
    help = false
    parser = OptionParser.new do |o|
      o.banner = "Usage: bin/register-byoh-host --main-ip IP --location NAME [options]"
      o.separator ""
      o.separator "Required:"
      o.on("--main-ip IP", "Management IPv4 address (control plane will SSH here)") { options[:main_ip] = it }
      o.on("--location NAME", "BYOH location (name, display name or ubid), created with bin/byoh-location") { options[:location] = it }
      o.separator ""
      o.separator "Pools (repeatable; see docs/byoh/NETWORKING.md):"
      o.on("--routed-network CIDR[,KEY=VALUE...]",
        "Address pool routed to this host, e.g. 198.51.100.0/29,exposure=public or 10.0.0.8/32,exposure=nat,external=10.0.0.8:203.0.113.5.",
        "IPv4 pools hold VM addresses; one IPv6 /64 (add ,ndp if the uplink needs NDP proxying) becomes the host's net6.",
        "Without an IPv6 pool a /64 of the location's ula48 is used.") { options[:pools] << it }
      o.on("--pool-file PATH", "pools.yaml (version 2) with routed_networks, uplink and ipv6_mode") { options[:pool_file] = it }
      o.on("--ipv6-mode MODE", "gua or ula (default: derived from the IPv6 pool)") { options[:ipv6_mode] = it }
      o.separator ""
      o.separator "SSH key:"
      o.on("--ssh-key PATH", "Use an existing Ed25519 private key file (default: generate a new one)") { options[:ssh_key_source] = it }
      o.separator ""
      o.separator "Optional:"
      o.on("--server-identifier ID", "Operator-assigned identifier (default: byoh-<vm_host uuid>)") { options[:server_identifier] = it }
      o.on("--yes", "Skip interactive confirmation") { options[:assume_yes] = true }
      o.on("--default-boot-image NAME", "Boot image name to download on this host at registration time (repeatable; e.g. 'ubuntu-noble', 'ubuntu-jammy'). Without this the boot_image table stays empty and the VM allocator will fail with 'no space left on any eligible host' when a user tries to create a VM.") do
        options[:default_boot_images] << it
      end
      o.separator ""
      o.separator "BMC (optional — enables Ubicloud to power-cycle this host via Redfish):"
      o.on("--bmc-endpoint URL", "Redfish base URL (e.g. https://192.168.1.11)") { bmc(options)["endpoint"] = it }
      o.on("--bmc-user USERNAME", "BMC username") { bmc(options)["username"] = it }
      o.on("--bmc-pass-env VAR", "Env var holding the BMC password (preferred over --bmc-password)") { bmc(options)["password_env"] = it }
      o.on("--bmc-password PASSWORD", "BMC password (inline; prefer --bmc-pass-env)") { bmc(options)["password"] = it }
      o.on("--bmc-system-id ID", "Explicit Redfish SystemId (needed for chassis BMCs)") { bmc(options)["system_id"] = it }
      o.on("--bmc-verify-ssl", "Enable TLS verification (default: disabled — BMC certs are usually self-signed)") { bmc(options)["verify_ssl"] = true }
      o.on("--bmc-reset-type TYPE", "Redfish ResetType (default: ForceRestart)") { bmc(options)["reset_type"] = it }
      ByohVirtRegistration.add_options(o, options)
      o.separator ""
      o.on("-h", "--help", "Show this help") { help = true }
    end
    rest = parser.parse(argv)
    if help
      @out.puts parser
      return
    end
    raise Error, "unexpected argument #{rest.first}" unless rest.empty?
    raise Error, "--main-ip is required\n#{parser}" unless options[:main_ip]
    raise Error, "--location is required\n#{parser}" unless options[:location]

    options[:bmc]["verify_ssl"] = false if options[:bmc] && !options[:bmc]["verify_ssl"]
    options
  end

  def bmc(options)
    options[:bmc] ||= {"protocol" => "redfish"}
  end

  def print_summary(registration, cfg, decision)
    location = registration.location
    @out.puts "Provider         generic"
    @out.puts "Management IP    #{cfg["main_ip4"]}"
    @out.puts "Location         #{location.name} (#{location.ubid}), #{location.ui_name}"
    @out.puts "IPv6 mode        #{registration.ipv6_mode}"
    @out.puts "Pools            " + cfg["routed_networks"].map { pool_line(it) }.join("\n                 ")
    @out.puts "Uplink           #{cfg["uplink"]}" if cfg["uplink"]
    if (bmc = cfg["bmc"])
      @out.puts "BMC              #{bmc["endpoint"]} (protocol=#{bmc["protocol"]}, system_id=#{bmc["system_id"] || "auto"})"
    end
    @out.puts "Virt tier        #{decision.tier}#{" (#{ByohVirtTiers.fetch(decision.tier).label}, accepted with --accept-fallback)" if ByohVirtTiers.lower?(decision.tier)}"
    @out.puts
  end

  def pool_line(network)
    details = network.except("cidr").map { |key, value| "#{key}=#{value.is_a?(String) ? value : value.to_json}" }
    [network["cidr"], *details].join(" ")
  end
end
