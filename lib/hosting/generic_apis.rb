# frozen_string_literal: true

require "set"
require "ipaddr"
require_relative "base"
require_relative "redfish_client"

class Hosting::GenericApis < Hosting::Base
  def config_hash
    @config_hash ||= (@host.config || {})
  end

  # For BYOH hosts the operator declares which networks are routed to this
  # host at registration time. We just replay that declaration — no provider
  # API is called.
  #
  # Expected shape in host_provider.config:
  #   { "routed_networks" => [
  #       { "cidr" => "10.99.0.0/24" },
  #       { "cidr" => "fd00:feed::/64" }    # parsed out via declared_net6
  #     ],
  #     "main_ip4" => "192.168.1.10",
  #     "location_label" => "homelab-rack-A",
  #     "bmc" => { ... optional ... } }
  #
  # Returns only IPv4 entries — the IPv6 /64 is consumed via #declared_net6
  # and stored directly on vm_host.net6. The management IPv4 is auto-prepended
  # as a /32 if it isn't already covered by a declared block, so the operator
  # only needs to declare their VM-allocatable networks.
  def pull_ips
    source_ip = @host.vm_host&.sshable&.host || config_hash["main_ip4"]
    declared = Array(config_hash["routed_networks"]).filter_map do |net|
      cidr = net["cidr"] or next
      next if cidr.include?(":")
      [cidr, net]
    end

    records = declared.map do |cidr, net|
      Hosting::Base::IpInfo.new(
        ip_address: cidr,
        source_host_ip: net["source_host_ip"] || source_ip,
        is_failover: net.fetch("is_failover", false)
      )
    end

    if source_ip && !mgmt_covered?(source_ip, declared.map(&:first))
      records.unshift(Hosting::Base::IpInfo.new(
        ip_address: "#{source_ip}/32",
        source_host_ip: source_ip,
        is_failover: false
      ))
    end

    records
  end

  # The IPv6 /64 the operator has delegated to this host, as a string (e.g.
  # "fd00:feed::/64"). nil if none was declared.
  #
  # This is pulled out of routed_networks at registration time and stored on
  # vm_host.net6, bypassing Prog::LearnNetwork (which SSHes into the host and
  # parses `ip -6 addr` — works on Hetzner but not on BYOH hosts without a
  # globally-routed v6 block).
  def declared_net6
    Array(config_hash["routed_networks"]).each do |net|
      cidr = net["cidr"] or next
      return cidr if cidr.include?(":")
    end
    nil
  end

  def pull_dc(_server_id = nil)
    config_hash["location_label"] || "byoh-unknown"
  end

  def get_main_ip4(_server_id = nil)
    config_hash["main_ip4"] || @host.vm_host&.sshable&.host
  end

  def reimage(server_id, **_opts)
    unless bmc_configured?
      raise Hosting::CapabilityMissing,
        "generic provider host #{server_id} has no BMC endpoint configured; " \
        "reimage must be performed manually"
    end
    # Even with a working Redfish BMC, automated reimage requires a PXE/iPXE
    # server on the operator's network that Ubicloud does not provision for
    # BYOH hosts. The operator must trigger reimage out-of-band (e.g. via
    # their own PXE infrastructure + BMC boot override).
    raise Hosting::CapabilityMissing,
      "generic provider does not support automated reimage; Ubicloud does " \
      "not run a PXE/iPXE server for BYOH hosts. Reinstall the OS out-of-band " \
      "and re-run host registration."
  end

  def reset(server_id)
    client = redfish_client
    unless client
      raise Hosting::CapabilityMissing,
        "generic provider host #{server_id} has no BMC endpoint configured; " \
        "hardware reset must be performed manually"
    end
    bmc = config_hash["bmc"]
    reset_type = bmc["reset_type"] || Hosting::RedfishClient::DEFAULT_RESET_TYPE
    client.power_reset(reset_type: reset_type)
    nil
  end

  def set_server_name(_server_id, _name)
    nil
  end

  def add_key(_name, _key)
    nil
  end

  def delete_key(_key)
    nil
  end

  def capabilities
    caps = Set.new([:ip_pull])
    # Reimage is intentionally NOT advertised even with a BMC — see #reimage
    # for why. Only hw_reset is a real BYOH capability gated on BMC config.
    caps << :hw_reset if bmc_configured?
    caps
  end

  private

  def bmc_configured?
    bmc = config_hash["bmc"]
    return false if bmc.nil? || bmc.empty?
    return false unless bmc["endpoint"]
    return false if bmc["protocol"] && bmc["protocol"] != "redfish"
    true
  end

  # Returns a configured Hosting::RedfishClient instance, or nil if the host
  # has no BMC config (or its protocol is non-redfish — v1 is redfish-only).
  def redfish_client
    return nil unless bmc_configured?
    bmc = config_hash["bmc"]
    Hosting::RedfishClient.new(
      bmc["endpoint"],
      username: bmc["username"],
      password: bmc_password(bmc),
      verify_ssl: bmc.fetch("verify_ssl", true),
      system_id: bmc["system_id"]
    )
  end

  # Prefer password_env (reference an env var on the control plane) over
  # storing the password in the host_provider.config JSONB column. The DB
  # should never hold a BMC secret in a production deployment.
  def bmc_password(bmc)
    if (env_key = bmc["password_env"])
      return ENV[env_key]
    end
    bmc["password"]
  end

  def mgmt_covered?(ip, cidrs)
    ip_obj = IPAddr.new(ip)
    cidrs.any? { |c| IPAddr.new(c).include?(ip_obj) }
  rescue IPAddr::Error
    false
  end
end
