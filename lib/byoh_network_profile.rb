# frozen_string_literal: true

require "netaddr"

# The site network profile of a BYOH location, stored in
# location.byoh_network (docs/byoh/NETWORKING.md section 5.3).
#
# #errors lists every problem with the stored hash. The readers parse the
# values and fill in defaults; they assume #errors is empty.
class ByohNetworkProfile
  CIDR_LIST_KEYS = %w[underlay_cidrs overlay_ipv4_cidrs cp_source_cidrs host_mgmt_allow vm_egress_deny vm_egress_allow].freeze

  # The first choice is the default.
  CHOICES = {
    "cp_reach" => %w[onhost public],
    "ula_underlay" => %w[none operator mesh],
    "internal_egress" => %w[host_nat site],
  }.freeze

  BOOLEANS = {"vm_egress_nat4" => true, "egress_smtp" => false}.freeze

  KEYS = [*CIDR_LIST_KEYS, *CHOICES.keys, *BOOLEANS.keys, "ula48", "guest_mtu", "dns_servers"].freeze

  GUEST_MTU = 1280..9000
  RFC1918 = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16].map { NetAddr::IPv4Net.parse(it) }.freeze
  ULA = NetAddr::IPv6Net.parse("fc00::/7")

  # Parses a CIDR, refusing host bits so that a typo is not silently
  # widened into a different network. Returns nil when it is invalid.
  def self.parse_cidr(value)
    net = NetAddr.parse_net(value)
    net if NetAddr.parse_ip(value.split("/", 2).first).addr == net.network.addr
  rescue NetAddr::ValidationError
    nil
  end

  def self.parse_ip(value)
    NetAddr.parse_ip(value)
  rescue NetAddr::ValidationError
    nil
  end

  def self.covers?(outer, inner)
    outer.instance_of?(inner.class) &&
      outer.netmask.prefix_len <= inner.netmask.prefix_len &&
      outer.contains(inner.network)
  end

  def self.overlap?(a, b)
    covers?(a, b) || covers?(b, a)
  end

  def initialize(hash)
    @raw = hash.respond_to?(:to_hash) ? hash.to_hash.transform_keys(&:to_s) : hash
  end

  def to_h
    @raw
  end

  CIDR_LIST_KEYS.each do |key|
    define_method(key) { @raw.fetch(key, []).map { NetAddr.parse_net(it) } }
  end

  CHOICES.each do |key, values|
    define_method(key) { @raw.fetch(key, values.first) }
  end

  BOOLEANS.each do |key, default|
    define_method(key) { @raw.fetch(key, default) }
  end

  def ula48
    @raw["ula48"]&.then { NetAddr::IPv6Net.parse(it) }
  end

  def guest_mtu
    @raw["guest_mtu"]
  end

  def dns_servers
    @raw.fetch("dns_servers", []).map { NetAddr.parse_ip(it) }
  end

  def errors
    return ["must be a JSON object"] unless @raw.is_a?(Hash)

    errors = (@raw.keys - KEYS).map { "unknown key #{it}" }

    nets = CIDR_LIST_KEYS.to_h do |key|
      [key, parse_list(key, errors) { self.class.parse_cidr(it) }]
    end

    nets["overlay_ipv4_cidrs"].each do |overlay|
      unless RFC1918.any? { self.class.covers?(it, overlay) }
        errors << "overlay_ipv4_cidrs: #{overlay} is not an RFC 1918 IPv4 network"
      end
      nets["underlay_cidrs"].each do |underlay|
        errors << "overlay_ipv4_cidrs: #{overlay} overlaps underlay #{underlay}" if self.class.overlap?(overlay, underlay)
      end
    end

    parse_list("dns_servers", errors) { self.class.parse_ip(it) }

    CHOICES.each do |key, values|
      if @raw.key?(key) && !values.include?(@raw[key])
        errors << "#{key} must be one of #{values.join(", ")}"
      end
    end

    BOOLEANS.each_key do |key|
      errors << "#{key} must be true or false" if @raw.key?(key) && ![true, false].include?(@raw[key])
    end

    if @raw.key?("guest_mtu") && !(@raw["guest_mtu"].is_a?(Integer) && GUEST_MTU.cover?(@raw["guest_mtu"]))
      errors << "guest_mtu must be an integer between #{GUEST_MTU.begin} and #{GUEST_MTU.end}"
    end

    if @raw.key?("ula48")
      ula48 = @raw["ula48"].is_a?(String) && self.class.parse_cidr(@raw["ula48"])
      unless ula48.is_a?(NetAddr::IPv6Net) && ula48.netmask.prefix_len == 48 && self.class.covers?(ULA, ula48)
        errors << "ula48 must be a /48 inside fc00::/7"
      end
    end

    errors
  end

  private

  def parse_list(key, errors)
    values = @raw.fetch(key, [])
    unless values.is_a?(Array) && values.all?(String)
      errors << "#{key} must be a list of strings"
      return []
    end

    values.filter_map do |value|
      parsed = yield(value)
      errors << "#{key}: #{value} is not valid" unless parsed
      parsed
    end
  end
end
