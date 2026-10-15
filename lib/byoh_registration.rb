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

  # Attempts at drawing an unused /64 from the location's ula48.
  ULA_ATTEMPTS = 32

  attr_reader :main_ip, :server_identifier, :bmc_config, :ssh_key_source, :default_boot_images

  # @param main_ip [String] management IPv4 address of the host (what the
  #   control plane will SSH to; becomes the sshable.host).
  # @param location [Location, String] the BYOH location of the host, or
  #   its name, display name or ubid.
  # @param pools [Array<String, Hash>] the host's address pools, each in the
  #   inline form "CIDR[,key=value...]" or as a hash (see
  #   ByohPoolDeclaration). At most one IPv6 /64, which becomes
  #   vm_host.net6; without one, a /64 is drawn from the location's ula48.
  # @param routed_networks [Array<String>] the older name of pools.
  # @param pool_file [String, nil] path of a pools.yaml v2 document whose
  #   pools are added to the others.
  # @param ipv6_mode [String, nil] gua or ula; derived from the IPv6 pool
  #   when not given.
  # @param ssh_key_source [String, Symbol] `:generate` to mint a fresh
  #   Ed25519 keypair, or an absolute path to an existing Ed25519 private
  #   key file on disk.
  # @param server_identifier [String, nil] operator-chosen HostProvider
  #   identifier. Defaults to `byoh-<vm_host uuid>` if nil.
  # @param bmc_config [Hash, nil] optional BMC section (see #validate_bmc!).
  # @param default_boot_images [Array<String>] optional list of Ubicloud boot
  #   image names to download on the host at registration time (e.g.
  #   ["ubuntu-noble"]). Without this the host comes up with an empty
  #   boot_image table and the VM allocator can't match anything,
  #   causing "no space left on any eligible host" at first VM create.
  def initialize(main_ip:, location:, pools: [], routed_networks: [], pool_file: nil, ipv6_mode: nil,
    ssh_key_source: :generate, server_identifier: nil, bmc_config: nil, default_boot_images: [], random: SecureRandom)
    @main_ip = main_ip
    @location_input = location
    @pool_inputs = Array(pools) + Array(routed_networks)
    @pool_file = pool_file
    @explicit_ipv6_mode = ipv6_mode
    @ssh_key_source = ssh_key_source
    @server_identifier = server_identifier
    @bmc_config = bmc_config
    @default_boot_images = Array(default_boot_images)
    @random = random
  end

  # Checks the input once; later calls return at once. Returns self.
  def validate!
    return self if @validated

    validate_main_ip!
    @location = resolve_location(@location_input)
    @entries, @uplink, @notes = parse_pools
    @notes += ByohPoolDeclaration.validate_set!(@entries, main_ip: @main_ip, location: @location, ipv6_mode: @explicit_ipv6_mode)
    validate_ssh_key_source!
    validate_bmc! if @bmc_config
    @validated = true
    self
  rescue ByohPoolDeclaration::ValidationError => ex
    raise ValidationError, ex.message
  end

  def location
    validate!
    @location
  end

  # The validated pool entries, without the derived ULA.
  def entries
    validate!
    @entries
  end

  # Remarks for the operator, such as the exposure chosen for a pool that
  # did not name one.
  def notes
    validate!
    @notes
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

  # The `host_provider.config` payload: main_ip, the location name, the
  # normalised pools (with a /64 of the location's ula48 appended if no
  # IPv6 pool is declared), the uplink of a pools file and the bmc
  # section. Computed once, so the derived /64 does not change between
  # showing it and registering.
  def provider_config
    @provider_config ||= begin
      networks = entries.map(&:to_config)
      networks << {"cidr" => derive_ula_64, "ndp" => false} unless entries.any?(&:ipv6?)
      cfg = {
        "main_ip4" => @main_ip,
        "location_label" => location.name,
        "routed_networks" => networks,
      }
      cfg["uplink"] = @uplink if @uplink
      cfg["bmc"] = @bmc_config if @bmc_config
      cfg
    end
  end

  def ipv6_mode
    ByohPoolDeclaration.ipv6_mode(entries, @explicit_ipv6_mode)
  end

  # Call Prog::Vm::HostNexus.assemble with validated input + pre-generated
  # SSH key. Returns the resulting Strand. Caller is responsible for
  # printing the UBID to the operator. The registration is written to the
  # operator log, a failure outside the failed transaction.
  # virt: the ByohVirtRegistration::Decision of the virtualization tier,
  # or nil for kvm without a probe.
  def register!(virt: nil)
    validate!
    prepare_keypair

    kwargs = {
      location_id: location.id,
      provider_name: HostProvider::GENERIC_PROVIDER_NAME,
      provider_config:,
      server_identifier: @server_identifier,
      ssh_private_key: keypair,
      ipv6_mode:,
      ndp_needed: entries.any?(&:ndp_needed?),
    }
    kwargs[:default_boot_images] = @default_boot_images unless @default_boot_images.empty?
    kwargs[:virt_tier] = virt.tier if virt && ByohVirtTiers.lower?(virt.tier)

    args = {main_ip: @main_ip, location: location.name, pools: provider_config["routed_networks"], server_identifier: @server_identifier}
    args[:virt] = virt.record if virt
    begin
      DB.transaction do
        strand = Prog::Vm::HostNexus.assemble(@main_ip, **kwargs)
        ByohOperatorLog.record(command: "register-byoh-host", target_id: strand.id, args:, result: "ok")
        strand
      end
    rescue => ex
      ByohOperatorLog.record(command: "register-byoh-host", target_id: nil, args:, result: "error: #{ex.message}")
      raise
    end
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

  # Finds a location by name, display name or ubid.
  def self.find_location(key)
    Location.first(project_id: nil, name: key) ||
      Location.first(project_id: nil, display_name: key) ||
      (Location[key] if key.match?(/\A10[0-9a-z]{24}\z/))
  end

  private

  def resolve_location(input)
    raise ValidationError, "a BYOH location is required; create one with bin/byoh-location" unless input
    location = input.is_a?(Location) ? input : self.class.find_location(input.to_s)
    raise ValidationError, "no location #{input}; create it with bin/byoh-location" unless location
    raise ValidationError, "location #{location.name} is not a BYOH location; create one with bin/byoh-location" unless location.byoh?
    location
  end

  # The pools of the file and of the inline inputs. A bare IPv4 address is
  # read as a /32, as registration always did, with a note.
  def parse_pools
    notes = []
    uplink = nil
    entries = []
    if @pool_file
      text = begin
        File.read(@pool_file)
      rescue SystemCallError => ex
        raise ValidationError, "cannot read pool file: #{ex.message}"
      end
      document = ByohPoolDeclaration.parse_yaml(text)
      if @explicit_ipv6_mode && document.ipv6_mode && @explicit_ipv6_mode != document.ipv6_mode
        raise ValidationError, "--ipv6-mode #{@explicit_ipv6_mode} contradicts ipv6_mode #{document.ipv6_mode} of the pool file"
      end
      @explicit_ipv6_mode ||= document.ipv6_mode
      uplink = document.uplink
      entries.concat(document.entries)
    end

    @pool_inputs.each do |input|
      if input.is_a?(String)
        cidr, rest = input.split(",", 2)
        cidr = cidr.to_s.strip
        if ByohPoolDeclaration.parse_ipv4(cidr)
          notes << "#{cidr}: no prefix given, read as #{cidr}/32"
          input = ["#{cidr}/32", rest].compact.join(",")
        end
      end
      entries << ByohPoolDeclaration.parse(input)
    end
    [entries, uplink, notes]
  end

  # A random /64 of the location's ula48 that no host uses.
  def derive_ula_64
    ula48 = location.byoh_profile.ula48 or
      raise ValidationError, "location #{location.name} has no ula48; declare an IPv6 /64 or set one with bin/byoh-location set --ula48"
    ULA_ATTEMPTS.times do
      candidate = ula48.nth_subnet(64, @random.random_number(1 << 16)).to_s
      return candidate if DB[:vm_host].where(Sequel.lit("net6 && ?::cidr", candidate)).empty?
    end
    raise ValidationError, "could not find an unused /64 in #{ula48} after #{ULA_ATTEMPTS} attempts; declare an IPv6 /64"
  end

  def validate_main_ip!
    IPAddr.new(@main_ip).ipv4? or raise ValidationError, "main_ip must be IPv4"
  rescue IPAddr::Error
    raise ValidationError, "main_ip is not a valid IP address: #{@main_ip}"
  end

  def validate_ssh_key_source!
    return if @ssh_key_source == :generate
    unless @ssh_key_source.is_a?(String) && File.file?(@ssh_key_source)
      raise ValidationError, "SSH key file does not exist: #{@ssh_key_source.inspect}"
    end
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
end
