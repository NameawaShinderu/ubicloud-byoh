# frozen_string_literal: true

require "ipaddr"
require "securerandom"
require "uri"

# BYOH host registration helper. Extracted from the `bin/register-byoh-host`
# CLI wrapper for testability — parses + validates operator input, builds
# the `host_provider.config` payload, generates or accepts an SSH keypair,
# and drives `Prog::Vm::HostNexus.assemble` with the right shape. The CLI
# wrapper is a thin OptionParser front-end around this class.
class ByohRegistration
  class ValidationError < StandardError; end

  attr_reader :main_ip, :routed_networks, :location_label, :server_identifier,
    :bmc_config, :ssh_key_source

  # @param main_ip [String] management IPv4 address of the host (what the
  #   control plane will SSH to; becomes the sshable.host).
  # @param routed_networks [Array<String>] zero or more CIDRs to declare
  #   routable to this host. Mix of v4 and v6 allowed. The first v6 /64
  #   becomes vm_host.net6; all v4 entries become Address rows populated
  #   for VM IP allocation. If no v6 is given, a random ULA /64 is
  #   auto-generated so that VM allocation (which hardcodes ephemeral_net6)
  #   doesn't crash.
  # @param ssh_key_source [String, Symbol] `:generate` to mint a fresh
  #   Ed25519 keypair, or an absolute path to an existing Ed25519 private
  #   key file on disk.
  # @param location_label [String] operator-chosen label stored in
  #   provider_config.location_label (shown in admin UI; no routing impact).
  # @param server_identifier [String, nil] operator-chosen HostProvider
  #   identifier. Defaults to a generated `byoh-<random>` if nil.
  # @param bmc_config [Hash, nil] optional BMC section (see #validate_bmc!).
  def initialize(main_ip:, routed_networks: [], ssh_key_source: :generate,
    location_label: "byoh", server_identifier: nil, bmc_config: nil)
    @main_ip = main_ip
    @routed_networks = Array(routed_networks)
    @ssh_key_source = ssh_key_source
    @location_label = location_label
    @server_identifier = server_identifier
    @bmc_config = bmc_config
  end

  def validate!
    validate_main_ip!
    validate_routed_networks!
    validate_ssh_key_source!
    validate_bmc! if @bmc_config
    self
  end

  # Returns the parsed Ed25519 keypair (binary blob suitable for storage in
  # sshable.raw_private_key_1) and its openssh-formatted public key. If
  # ssh_key_source is :generate, mints a fresh one. If it's a file path,
  # reads and parses.
  def prepare_keypair
    return @keypair_and_public if @keypair_and_public

    keypair, public_key = if @ssh_key_source == :generate
      key = SshKey.generate
      [key.keypair, key.public_key]
    else
      contents = File.read(@ssh_key_source)
      priv = Net::SSH::Authentication::ED25519::PrivKey.read(contents, nil)
      wrapped = SshKey.from_binary(priv.sign_key.keypair)
      [wrapped.keypair, wrapped.public_key]
    end

    @keypair_and_public = [keypair, public_key]
  end

  def keypair
    prepare_keypair.first
  end

  def public_key
    prepare_keypair.last
  end

  # The `host_provider.config` payload. Includes main_ip, location_label,
  # routed_networks (with an auto-generated ULA /64 appended if the operator
  # didn't supply one), and the bmc section if configured. Never contains a
  # plaintext BMC password — callers must pass `bmc.password_env` instead.
  def provider_config
    cfg = {
      "main_ip4" => @main_ip,
      "location_label" => @location_label,
      "routed_networks" => effective_routed_networks
    }
    cfg["bmc"] = @bmc_config if @bmc_config
    cfg
  end

  # Call Prog::Vm::HostNexus.assemble with validated input + pre-generated
  # SSH key. Returns the resulting Strand. Caller is responsible for
  # printing the UBID to the operator.
  def register!(location_id: nil)
    validate!
    prepare_keypair

    kwargs = {
      provider_name: HostProvider::GENERIC_PROVIDER_NAME,
      provider_config: provider_config,
      server_identifier: @server_identifier,
      ssh_private_key: keypair
    }
    kwargs[:location_id] = location_id if location_id

    Prog::Vm::HostNexus.assemble(@main_ip, **kwargs)
  end

  # Human-facing instructions the CLI shows before running register!. The
  # operator must have installed this public key in /root/.ssh/authorized_keys
  # on the BYOH host (otherwise the control plane can't SSH in and the
  # strand will be stuck at bootstrap_rhizome).
  def install_instructions
    <<~INSTRUCTIONS
      The control plane will SSH into #{@main_ip} as root using the key below.
      Install it on the BYOH host first:

        #{public_key}

      Run on the BYOH host (as root or via sudo):

        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        echo '#{public_key}' >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    INSTRUCTIONS
  end

  private

  def effective_routed_networks
    entries = @routed_networks.map { |c| {"cidr" => c} }
    unless entries.any? { |e| e["cidr"].include?(":") }
      entries << {"cidr" => self.class.generate_ula_64}
    end
    entries
  end

  def validate_main_ip!
    IPAddr.new(@main_ip).ipv4? or raise ValidationError, "main_ip must be IPv4"
  rescue IPAddr::Error
    raise ValidationError, "main_ip is not a valid IP address: #{@main_ip}"
  end

  def validate_routed_networks!
    @routed_networks.each do |cidr|
      parsed = IPAddr.new(cidr)
      if parsed.ipv6? && parsed.prefix != 64
        raise ValidationError, "IPv6 routed_networks must be /64 (got #{cidr}); Ubicloud slices a /64 per host"
      end
    rescue IPAddr::InvalidAddressError
      raise ValidationError, "routed_network is not a valid CIDR: #{cidr}"
    end
  end

  def validate_ssh_key_source!
    return if @ssh_key_source == :generate
    raise ValidationError, "ssh_key_source must be :generate or a file path" unless @ssh_key_source.is_a?(String)
    raise ValidationError, "SSH key file does not exist: #{@ssh_key_source}" unless File.file?(@ssh_key_source)
    raise ValidationError, "SSH key file is not readable: #{@ssh_key_source}" unless File.readable?(@ssh_key_source)
  end

  def validate_bmc!
    unless @bmc_config.is_a?(Hash)
      raise ValidationError, "bmc_config must be a Hash"
    end

    endpoint = @bmc_config["endpoint"] or
      raise ValidationError, "bmc.endpoint is required when bmc is configured"

    begin
      parsed = URI.parse(endpoint)
    rescue URI::InvalidURIError
      raise ValidationError, "bmc.endpoint is not a valid URL: #{endpoint}"
    end
    unless %w[http https].include?(parsed.scheme)
      raise ValidationError, "bmc.endpoint must be http(s): #{endpoint}"
    end

    unless @bmc_config["username"]
      raise ValidationError, "bmc.username is required when bmc is configured"
    end

    has_pw = @bmc_config["password"] || @bmc_config["password_env"]
    raise ValidationError, "bmc.password or bmc.password_env is required" unless has_pw

    if (env_key = @bmc_config["password_env"]) && ENV[env_key].nil?
      warn "WARNING: env var #{env_key} is not set; BMC reset will fail at runtime"
    end

    protocol = @bmc_config["protocol"] || "redfish"
    unless protocol == "redfish"
      raise ValidationError, "bmc.protocol '#{protocol}' is not supported in v1 (use 'redfish')"
    end
  end

  def self.generate_ula_64
    ula_bytes = [0xfd] + Array.new(5) { rand(256) }
    hex = ula_bytes.map { |b| format("%02x", b) }.join
    "#{hex[0..3]}:#{hex[4..7]}:#{hex[8..11]}:0::/64"
  end
end
