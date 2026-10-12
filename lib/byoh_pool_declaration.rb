# frozen_string_literal: true

require "netaddr"
require "yaml"

# The address pools an operator declares for a BYOH host
# (docs/byoh/NETWORKING.md sections 3 and 5.4), in any of three forms:
#
# - a stored host_provider.config entry, a bare CIDR string or a hash;
# - the inline CLI form "CIDR[,key=value...]", where reserve= and
#   external=P:E may repeat and a bare "ndp" means ndp=true;
# - a pools.yaml v2 document with a routed_networks list.
#
# .parse checks each entry on its own; .validate_set! checks a set of new
# entries against each other, the stored entries, the host, the location
# and the database.
class ByohPoolDeclaration
  class ValidationError < StandardError; end

  DELIVERIES = %w[routed onlink fabric].freeze
  EXPOSURES = %w[public nat internal].freeze
  USABLE = %w[auto all].freeze
  IPV6_MODES = %w[gua ula].freeze

  V4_KEYS = %w[cidr delivery exposure external external_cidr usable reserve segment gateway].freeze
  V6_KEYS = %w[cidr ndp].freeze
  # Keys older registrations stored; nothing reads them.
  LEGACY_KEYS = %w[source_host_ip is_failover].freeze
  DOCUMENT_KEYS = %w[version uplink ipv6_mode routed_networks].freeze
  INLINE_BOOLEANS = {"true" => true, "false" => false}.freeze

  # Address.validate refuses blocks of more than 256 addresses.
  MAX_IPV4_PREFIX = 24

  # IPv4 special-purpose ranges that are not globally reachable (RFC 6890
  # and its updates). A "public" pool may not overlap them.
  SPECIAL_USE_V4 = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
  ].map { NetAddr::IPv4Net.parse(it) }.freeze

  Document = Data.define(:entries, :uplink, :ipv6_mode)

  Entry = Data.define(:cidr, :delivery, :exposure, :exposure_defaulted, :external, :reserve, :usable, :segment, :gateway, :ndp) do
    def ipv4? = cidr.is_a?(NetAddr::IPv4Net)

    def ipv6? = !ipv4?

    def onlink? = delivery == "onlink"

    def ndp_needed? = ndp

    # Addresses that are imported but never allocated: the operator's
    # holdback plus, for an onlink pool, the segment's network, broadcast
    # and gateway addresses that fall inside the block.
    def reserved_ips
      ips = reserve.dup
      if onlink? && usable == "auto"
        ips.concat([segment.network, segment.nth(segment.len - 1), gateway].map(&:to_s))
      end
      ips.select { ByohPoolDeclaration.contains?(cidr, it) }.uniq
    end

    def usable_ips
      Array.new(cidr.len) { cidr.nth(it).to_s } - reserved_ips
    end

    # The normalised entry stored in host_provider.config.
    def to_config
      return {"cidr" => cidr.to_s, "ndp" => ndp} if ipv6?

      config = {"cidr" => cidr.to_s, "delivery" => delivery, "exposure" => exposure}
      config["external"] = external unless external.empty?
      config["reserve"] = reserve unless reserve.empty?
      config["usable"] = usable unless usable == "auto"
      if segment
        config["segment"] = segment.to_s
        config["gateway"] = gateway.to_s
      end
      config
    end
  end

  def self.contains?(net, ip)
    net.contains(NetAddr::IPv4.parse(ip))
  end

  def self.global_ipv4?(net)
    SPECIAL_USE_V4.none? { ByohNetworkProfile.overlap?(it, net) }
  end

  # Parses one entry. A stored (legacy) entry without an exposure keeps its
  # original meaning, public; a newly declared one defaults to public only
  # when it is globally routable, and internal otherwise.
  def self.parse(input, legacy: false)
    hash = case input
    when String then parse_inline(input)
    when Hash then input.transform_keys(&:to_s)
    else raise ValidationError, "pool entry must be a CIDR string or a mapping, got #{input.inspect}"
    end
    build_entry(hash, legacy:)
  end

  def self.parse_yaml(text)
    doc = begin
      YAML.safe_load(text)
    rescue Psych::Exception => ex
      raise ValidationError, "pools file is not valid YAML: #{ex.message}"
    end
    raise ValidationError, "pools file must be a mapping with a routed_networks list" unless doc.is_a?(Hash)

    unknown = doc.keys - DOCUMENT_KEYS
    raise ValidationError, "pools file has unknown key(s) #{unknown.join(", ")}" unless unknown.empty?
    raise ValidationError, "pools file version must be 2" if doc.key?("version") && doc["version"] != 2
    raise ValidationError, "pools file routed_networks must be a list" unless doc["routed_networks"].is_a?(Array)
    raise ValidationError, "pools file uplink must be a string" unless doc["uplink"].nil? || doc["uplink"].is_a?(String)
    if doc.key?("ipv6_mode") && !IPV6_MODES.include?(doc["ipv6_mode"])
      raise ValidationError, "pools file ipv6_mode must be one of #{IPV6_MODES.join(", ")}"
    end

    Document.new(entries: doc["routed_networks"].map { parse(it) }, uplink: doc["uplink"], ipv6_mode: doc["ipv6_mode"])
  end

  # The host's IPv6 mode: gua for a globally routable /64, ula for a ULA
  # or when no IPv6 is declared (registration then derives a ULA).
  def self.ipv6_mode(entries, explicit = nil)
    mode, error = derive_ipv6_mode(entries, explicit)
    raise ValidationError, error if error
    mode
  end

  # Checks new entries as a set and returns notes for the operator. Stored
  # entries, those already in host_provider.config, are only checked for
  # overlap with the new ones: they were accepted under the rules of their
  # time. host excludes the host's own database rows from the overlap and
  # external IP checks, so re-declaring an existing pool is not a conflict.
  def self.validate_set!(entries, main_ip:, location:, host: nil, stored: [], ipv6_mode: nil)
    errors = []
    notes = []
    all = stored + entries
    main = NetAddr::IPv4.parse(main_ip)

    errors << "at most one IPv6 /64 may be declared" if all.count(&:ipv6?) > 1

    entries.each_with_index do |entry, i|
      (stored + entries.drop(i + 1)).each do |other|
        if ByohNetworkProfile.overlap?(entry.cidr, other.cidr)
          errors << "#{entry.cidr} overlaps #{other.cidr}"
        else
          [[entry, other], [other, entry]].each do |pool, neighbour|
            if pool.onlink? && neighbour.ipv4? && !neighbour.onlink? && neighbour.cidr.to_s != "#{main_ip}/32" &&
                ByohNetworkProfile.overlap?(neighbour.cidr, pool.segment)
              errors << "#{neighbour.cidr} overlaps the onlink segment #{pool.segment} of #{pool.cidr}"
            end
          end
        end
      end
    end

    entries.each do |entry|
      errors.concat(database_overlap_errors(entry, host))
      next if entry.ipv6?

      if entry.cidr.netmask.prefix_len != 32 && entry.cidr.contains(main)
        errors << "#{entry.cidr} contains main_ip #{main_ip}; declare pools that exclude the management IP, or #{main_ip}/32 alone"
      end

      if entry.exposure == "public" && !global_ipv4?(entry.cidr)
        errors << "#{entry.cidr} is not globally routable, so it cannot be public; use exposure=internal or exposure=nat"
      end

      if entry.exposure == "nat"
        missing = entry.usable_ips - entry.external.keys
        errors << "#{entry.cidr} is nat but has no external IP for #{missing.join(", ")}" unless missing.empty?
      end

      errors.concat(location_overlap_errors(entry, location))

      if entry.exposure_defaulted
        reason = (entry.exposure == "public") ? "it is globally routable" : "it is not globally routable"
        notes << "#{entry.cidr}: no exposure given, using #{entry.exposure} because #{reason}"
      end

      if entry.delivery == "fabric" && entry.exposure == "public"
        notes << "#{entry.cidr}: warning: fabric delivery with public exposure needs a cloud that routes these public addresses to the NIC"
      end
    end

    errors.concat(external_ip_errors(entries, all, host))

    _, error = derive_ipv6_mode(all, ipv6_mode)
    errors << error if error

    raise ValidationError, errors.join("\n") unless errors.empty?
    notes
  end

  def self.parse_inline(text)
    cidr, *options = text.split(",").map(&:strip)
    options.each_with_object({"cidr" => cidr}) do |option, hash|
      key, value = option.split("=", 2)
      if key == "ndp" && value.nil?
        hash["ndp"] = true
      elsif value.nil?
        raise ValidationError, "#{text}: #{option} must be key=value"
      elsif key == "reserve"
        (hash["reserve"] ||= []) << value
      elsif key == "external"
        ip, external_ip = value.split(":", 2)
        (hash["external"] ||= {})[ip] = external_ip
      elsif key == "ndp"
        hash["ndp"] = INLINE_BOOLEANS.fetch(value, value)
      else
        hash[key] = value
      end
    end
  end

  def self.build_entry(hash, legacy:)
    cidr = parse_cidr(legacy ? legacy_cidr(hash["cidr"]) : hash["cidr"]) or
      raise ValidationError, "#{hash["cidr"].inspect} is not a CIDR (address/prefix, no host bits)"
    v4 = cidr.is_a?(NetAddr::IPv4Net)

    unknown = hash.keys - (v4 ? V4_KEYS : V6_KEYS) - LEGACY_KEYS
    raise ValidationError, "#{cidr}: unknown key(s) #{unknown.join(", ")} for an IPv#{v4 ? 4 : 6} pool" unless unknown.empty?

    errors = []
    entry = v4 ? build_v4_entry(cidr, hash, legacy, errors) : build_v6_entry(cidr, hash, errors)
    raise ValidationError, errors.map { "#{cidr}: #{it}" }.join("\n") unless errors.empty?
    entry
  end

  def self.build_v6_entry(cidr, hash, errors)
    errors << "an IPv6 pool must be a /64" unless cidr.netmask.prefix_len == 64
    ndp = hash.fetch("ndp", false)
    errors << "ndp must be true or false" unless [true, false].include?(ndp)
    Entry.new(cidr:, delivery: nil, exposure: nil, exposure_defaulted: false, external: {}, reserve: [], usable: nil, segment: nil, gateway: nil, ndp:)
  end

  def self.build_v4_entry(cidr, hash, legacy, errors)
    errors << "an IPv4 pool may be at most a /#{MAX_IPV4_PREFIX}" if cidr.netmask.prefix_len < MAX_IPV4_PREFIX

    delivery = choice(hash, "delivery", DELIVERIES, errors)
    usable = choice(hash, "usable", USABLE, errors)
    exposure_defaulted = !hash.key?("exposure") && !legacy
    exposure = if hash.key?("exposure")
      choice(hash, "exposure", EXPOSURES, errors)
    else
      (legacy || global_ipv4?(cidr)) ? "public" : "internal"
    end

    segment = gateway = nil
    if delivery == "onlink"
      segment = parse_cidr(hash["segment"])
      gateway = parse_ipv4(hash["gateway"])
      if !segment.is_a?(NetAddr::IPv4Net) || !gateway
        errors << "an onlink pool needs segment=<LAN CIDR> and gateway=<LAN gateway>"
        segment = gateway = nil
      elsif !ByohNetworkProfile.covers?(segment, cidr)
        errors << "segment #{segment} does not contain the pool"
      elsif !segment.contains(gateway)
        errors << "gateway #{gateway} is outside segment #{segment}"
      end
    elsif hash.key?("segment") || hash.key?("gateway")
      errors << "segment and gateway apply only to onlink pools"
    end

    reserve = list_of_ips(hash.fetch("reserve", []), "reserve", errors).each do |ip|
      errors << "reserve #{ip} is outside the pool" unless contains?(cidr, ip)
    end

    entry = Entry.new(cidr:, delivery:, exposure:, exposure_defaulted:, external: {}, reserve:, usable:, segment:, gateway:, ndp: false)
    # The external map depends on the reserved addresses, which need a
    # valid onlink segment.
    return entry unless errors.empty?

    entry.with(external: externals(entry, hash, errors))
  end

  def self.externals(entry, hash, errors)
    return {} unless hash.key?("external") || hash.key?("external_cidr")

    error = if entry.exposure != "nat"
      "external and external_cidr apply only to nat pools"
    elsif hash.key?("external") && hash.key?("external_cidr")
      "use either external or external_cidr, not both"
    elsif hash.key?("external_cidr")
      return external_by_offset(entry, hash["external_cidr"], errors)
    elsif !hash["external"].is_a?(Hash)
      "external must map pool IPs to external IPs"
    end
    if error
      errors << error
      return {}
    end

    reserved = entry.reserved_ips
    hash["external"].each_with_object({}) do |(ip, external_ip), result|
      pool_ip = parse_ipv4(ip)
      mapped = parse_ipv4(external_ip)
      if !pool_ip || !mapped
        errors << "external #{ip.inspect}: #{external_ip.inspect} is not an IPv4 pair"
      elsif !entry.cidr.contains(pool_ip) || reserved.include?(pool_ip.to_s)
        errors << "external #{pool_ip} is not a usable address of the pool"
      else
        result[pool_ip.to_s] = mapped.to_s
      end
    end
  end

  # Block-to-block 1:1 NAT maps each usable address to the one at the same
  # offset in the external block.
  def self.external_by_offset(entry, value, errors)
    external_cidr = parse_cidr(value)
    unless external_cidr.is_a?(NetAddr::IPv4Net) && external_cidr.netmask.prefix_len == entry.cidr.netmask.prefix_len
      errors << "external_cidr must be an IPv4 CIDR of the same size as the pool"
      return {}
    end

    usable = entry.usable_ips
    Array.new(entry.cidr.len) { [entry.cidr.nth(it).to_s, external_cidr.nth(it).to_s] }
      .select { usable.include?(it.first) }
      .to_h
  end

  def self.choice(hash, key, values, errors)
    value = hash.fetch(key, values.first)
    errors << "#{key} must be one of #{values.join(", ")}" unless values.include?(value)
    value
  end

  def self.list_of_ips(values, key, errors)
    unless values.is_a?(Array)
      errors << "#{key} must be a list of IPv4 addresses"
      return []
    end

    values.filter_map do |value|
      ip = parse_ipv4(value)
      errors << "#{key} #{value.inspect} is not an IPv4 address" unless ip
      ip&.to_s
    end
  end

  # A CIDR must carry its prefix; a bare address is refused rather than
  # read as a /32 so that a missing prefix is not silently a single IP.
  def self.parse_cidr(value)
    ByohNetworkProfile.parse_cidr(value) if value.is_a?(String) && value.include?("/")
  end

  # Registration has always stored a bare IPv4 address as given, and
  # Postgres reads it as a /32, so a stored entry keeps that meaning.
  def self.legacy_cidr(value)
    parse_ipv4(value) ? "#{value}/32" : value
  end

  def self.parse_ipv4(value)
    ip = ByohNetworkProfile.parse_ip(value) if value.is_a?(String)
    ip if ip.is_a?(NetAddr::IPv4)
  end

  def self.derive_ipv6_mode(entries, explicit)
    v6 = entries.find(&:ipv6?)
    derived = (v6.nil? || ByohNetworkProfile.covers?(ByohNetworkProfile::ULA, v6.cidr)) ? "ula" : "gua"
    if explicit && !IPV6_MODES.include?(explicit)
      [nil, "ipv6_mode must be one of #{IPV6_MODES.join(", ")}"]
    elsif explicit == "gua" && derived == "ula"
      [nil, "ipv6_mode gua needs a globally routable IPv6 /64, but #{v6 ? "#{v6.cidr} is a ULA" : "none is declared"}"]
    else
      [explicit || derived]
    end
  end

  def self.database_overlap_errors(entry, host)
    cidr = entry.cidr.to_s
    errors = []

    addresses = DB[:address].where(Sequel.lit("cidr && ?::cidr", cidr))
    addresses = addresses.exclude(routed_to_host_id: host.id, cidr:) if host
    addresses.select_order_map(:cidr).each { errors << "#{cidr} overlaps #{it}, already registered" }

    if entry.ipv6?
      hosts = DB[:vm_host].where(Sequel.lit("net6 && ?::cidr", cidr))
      hosts = hosts.exclude(id: host.id) if host
      hosts.select_order_map(:net6).each { errors << "#{cidr} overlaps the IPv6 network #{it} of another host" }
    end

    errors
  end

  def self.location_overlap_errors(entry, location)
    overlays = location.byoh_profile&.overlay_ipv4_cidrs || []
    errors = overlays.select { ByohNetworkProfile.overlap?(it, entry.cidr) }
      .map { "#{entry.cidr} overlaps the location's overlay network #{it}" }

    DB[:private_subnet].where(location_id: location.id).where(Sequel.lit("net4 && ?::cidr", entry.cidr.to_s))
      .select_order_map(:net4).each { errors << "#{entry.cidr} overlaps the private subnet #{it} in this location" }

    errors
  end

  # Every external IP is globally routable, used once, and never one of
  # the pool addresses it fronts.
  def self.external_ip_errors(entries, all, host)
    external_ips = entries.flat_map { it.external.values }
    return [] if external_ips.empty?

    errors = external_ips.tally.select { |_, count| count > 1 }.keys.map { "external IP #{it} is used more than once" }

    external_ips.uniq.each do |ip|
      net = NetAddr::IPv4Net.parse("#{ip}/32")
      errors << "external IP #{ip} is not globally routable" unless global_ipv4?(net)
      all.select(&:ipv4?).each do |entry|
        errors << "external IP #{ip} is inside the pool #{entry.cidr}" if entry.cidr.contains(net.network)
      end
    end

    pools = DB[:ipv4_address].where(external_ip: external_ips)
    vms = DB[:assigned_vm_address].where(external_ip: external_ips)
    if host
      pools = pools.exclude(cidr: host.assigned_subnets_dataset.select(:cidr))
      vms = vms.exclude(address_id: host.assigned_subnets_dataset.select(:id))
    end
    (pools.select_map(:external_ip) + vms.select_map(:external_ip)).map(&:to_s).uniq.sort.each do
      errors << "external IP #{it} is already mapped to another address"
    end

    DB[:address].where(Sequel.|(*external_ips.map { Sequel.lit("cidr >>= ?::inet", it) })).select_order_map(:cidr).each do
      errors << "external IPs overlap the registered pool #{it}"
    end

    errors
  end

  private_class_method :parse_inline, :build_entry, :legacy_cidr, :build_v4_entry, :build_v6_entry, :externals, :external_by_offset, :choice,
    :list_of_ips, :derive_ipv6_mode, :database_overlap_errors, :location_overlap_errors, :external_ip_errors
end
