# frozen_string_literal: true

require "optparse"

# bin/register-byoh-host: registers a bring-your-own host in a BYOH
# location. Parses the options, shows the SSH key the operator installs
# on the host, runs host preflight once that key is installed (given
# with --ssh-key, or confirmed by the operator), decides the
# virtualization tier from what preflight found (ByohVirtRegistration),
# and hands the rest to ByohRegistration.
class ByohRegistrationCli
  class Error < StandardError; end

  # preflight holds keywords for ByohRegistration#preflight: specs pass
  # starter, which stands in for Net::SSH.start, and nonce.
  def initialize(out: $stdout, err: $stderr, input: $stdin, **preflight)
    @out = out
    @err = err
    @input = input
    @preflight = preflight
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
      uplink_ip: options[:uplink_ip],
    )
    registration.validate!
    ByohHostPreflight.validate_accept!(options[:accept_checks])
    virt = ByohVirtRegistration.new(declared: options[:virt_tier], accept_fallback: options[:accept_fallback], probe: options[:virt_probe] != false,
      install_pvm_kernel: options[:install_pvm_kernel])
    registration.boot_images_for!(virt.declared) unless virt.declared == "auto"
    registration.provider_config
    registration.notes.each { @err.puts "note: #{it}" }

    @out.puts "ubicloud byoh host registration"
    @out.puts "────────────────────────────────"
    @out.puts
    @out.puts "Step 1/3 — Install the control-plane SSH public key on the host"
    @out.puts "────────────────────────────────"
    @out.puts registration.install_instructions
    unless options[:assume_yes]
      @out.print "Press ENTER once the public key is installed, or Ctrl-C to abort: "
      @input.readline
    end

    @out.puts
    @out.puts "Step 2/3 — Host preflight"
    @out.puts "────────────────────────────────"
    passed, report = preflight(registration, options, virt)
    return 1 unless passed

    # The tier, from the virt facts preflight gathered (PF3).
    decision = virt.decide!(report&.virt_verdict, location: registration.location, main_ip: options[:main_ip],
      unprobed_reason: virt.unprobed_reason(report), boot_images: registration.default_boot_images)
    decision.notes.each { @err.puts "note: #{it}" }

    @out.puts
    @out.puts "Step 3/3 — Registering host with control plane"
    @out.puts "────────────────────────────────"
    print_summary(registration, registration.provider_config, decision)

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
  rescue ByohHostPreflight::UsageError => ex
    @err.puts "! #{ex.message}"
    2
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
    options = {pools: [], ssh_key_source: :generate, assume_yes: false, bmc: nil, default_boot_images: [], accept_checks: [], skip_preflight: false}
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
      o.on("--ssh-key PATH", "Use an existing Ed25519 private key file, already in root's authorized_keys on the host (default: generate a new one)") { options[:ssh_key_source] = it }
      o.separator ""
      o.separator "Preflight (docs/byoh/PLATFORMS.md PF1-PF21; runs as root over the control plane's own login, except with a generated key and --yes):"
      o.on("--skip-preflight", "Register without checking the host first") { options[:skip_preflight] = true }
      o.on("--accept-check ID", "Accept an overridable failed check, such as PF8-hybrid or PF16-docker (repeatable)") { options[:accept_checks] << it }
      o.on("--uplink-ip IP", "The address the host's default route leaves from (default: what preflight detects); no pool may hand it to VMs") { options[:uplink_ip] = it }
      o.separator ""
      o.separator "Optional:"
      o.on("--server-identifier ID", "Operator-assigned identifier (default: byoh-<vm_host uuid>)") { options[:server_identifier] = it }
      o.on("--yes", "Skip interactive confirmation") { options[:assume_yes] = true }
      o.on("--default-boot-image NAME", "Boot image to download on this host at registration time (repeatable; default: #{ByohRegistration::DEFAULT_BOOT_IMAGES.join(", ")}, or the first image of a lower --virt-tier)") do
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
    # nil: ByohRegistration picks the default, which depends on the tier.
    options[:default_boot_images] = nil if options[:default_boot_images].empty?
    options
  end

  # Runs preflight when it can work; returns whether to register, and
  # the report (nil when preflight was skipped).
  def preflight(registration, options, virt)
    if options[:skip_preflight]
      @err.puts "warning: preflight skipped (--skip-preflight); the host was not checked"
      return [true, nil]
    end
    generated = options[:ssh_key_source] == :generate
    if generated && options[:assume_yes]
      @err.puts "warning: preflight skipped: this run generated the registration key and --yes skipped the step that installs it, " \
        "so the login cannot work yet; check the host by running scripts/byoh/host/ubicloud-host preflight on it, " \
        "or install a key first and pass --ssh-key"
      return [true, nil]
    end

    report = registration.preflight(accept_checks: options[:accept_checks], virt:, **@preflight)
    @out.print report.to_table
    return [true, report] unless report.blocking?

    @err.puts "! preflight failed: fix the checks marked fail, or accept an overridable one with --accept-check; nothing was registered"
    if generated
      @err.puts "  The generated key was not kept: remove its line from root's authorized_keys on the host. " \
        "The next run prints a new key, or pass --ssh-key with one you keep."
    end
    [false, report]
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
    @out.puts "Uplink IP        #{cfg["uplink_ip"]}" if cfg["uplink_ip"]
    @out.puts "Pinned host keys #{registration.pinned_host_keys.map { ByohOperatorSsh::HostKey.parse(it).fingerprint }.join(", ")}" if registration.pinned_host_keys
    if (bmc = cfg["bmc"])
      @out.puts "BMC              #{bmc["endpoint"]} (protocol=#{bmc["protocol"]}, system_id=#{bmc["system_id"] || "auto"})"
    end
    @out.puts "Virt tier        #{decision.tier}#{" (#{ByohVirtTiers.fetch(decision.tier).label}, accepted with --accept-fallback)" if ByohVirtTiers.lower?(decision.tier)}"
    @out.puts "PVM kernel       installed by the control plane (--install-pvm-kernel), sha256 #{decision.host_deb_sha256}" if decision.install_pvm_kernel
    @out.puts
  end

  def pool_line(network)
    details = network.except("cidr").map { |key, value| "#{key}=#{value.is_a?(String) ? value : value.to_json}" }
    [network["cidr"], *details].join(" ")
  end
end
