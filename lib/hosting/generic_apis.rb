# frozen_string_literal: true

require "ipaddr"
require_relative "redfish_client"

class Hosting::GenericApis
  IpInfo = Struct.new(:ip_address, :source_host_ip, :is_failover, keyword_init: true)

  def initialize(host_provider)
    @host = host_provider
  end

  def config_hash
    @config_hash ||= @host.config || {}
  end

  # For BYOH hosts the operator declares which networks are routed to this
  # host at registration time. We just replay that declaration — no provider
  # API is called.
  #
  # Expected shape in host_provider.config:
  #   { "routed_networks" => [
  #       { "cidr" => "10.99.0.0/24" },
  #       { "cidr" => "fd00:feed::/64" }    # stored on vm_host.net6 instead
  #     ],
  #     "main_ip4" => "192.168.1.10",
  #     "location_label" => "homelab-rack-A",
  #     "bmc" => { ... optional ... } }
  #
  # Returns only IPv4 entries — the IPv6 /64 is stored directly on
  # vm_host.net6 at registration. The management IPv4 is auto-prepended
  # as a /32 if it isn't already covered by a declared block, so the operator
  # only needs to declare their VM-allocatable networks.
  def pull_ips
    source_ip = @host.vm_host.sshable.host
    declared = Array(config_hash["routed_networks"]).filter_map do |net|
      cidr = net["cidr"]
      [cidr, net] unless cidr.include?(":")
    end

    records = declared.map do |cidr, net|
      IpInfo.new(
        ip_address: cidr,
        source_host_ip: net["source_host_ip"] || source_ip,
        is_failover: net.fetch("is_failover", false),
      )
    end

    mgmt_ip = IPAddr.new(source_ip)
    unless declared.any? { |cidr, _| IPAddr.new(cidr).include?(mgmt_ip) }
      records.unshift(IpInfo.new(ip_address: "#{source_ip}/32", source_host_ip: source_ip, is_failover: false))
    end

    records
  end

  def pull_dc(_server_id)
    config_hash["location_label"] || "byoh-unknown"
  end

  # Even with a working Redfish BMC, automated reimage requires a PXE/iPXE
  # server on the operator's network that Ubicloud does not provision for
  # BYOH hosts. The operator must reinstall out-of-band.
  def reimage(server_id, **)
    raise Hosting::CapabilityMissing,
      "generic provider host #{server_id} does not support automated reimage; " \
      "Ubicloud does not run a PXE/iPXE server for BYOH hosts. Reinstall the " \
      "OS out-of-band and re-run host registration."
  end

  def reset(server_id)
    bmc = config_hash["bmc"]
    unless bmc && bmc["endpoint"] && bmc.fetch("protocol", "redfish") == "redfish"
      raise Hosting::CapabilityMissing,
        "generic provider host #{server_id} has no Redfish BMC endpoint configured; " \
        "hardware reset must be performed manually"
    end

    Hosting::RedfishClient.new(
      bmc["endpoint"],
      username: bmc["username"],
      password: bmc_password(bmc),
      verify_ssl: bmc.fetch("verify_ssl", true),
      system_id: bmc["system_id"],
    ).power_reset(reset_type: bmc["reset_type"] || Hosting::RedfishClient::DEFAULT_RESET_TYPE)
    nil
  end

  def set_server_name(_server_id, _name)
    nil
  end

  private

  # Prefer password_env (reference an env var on the control plane) over
  # storing the password in the host_provider.config JSONB column. The DB
  # should never hold a BMC secret in a production deployment.
  def bmc_password(bmc)
    if (env_key = bmc["password_env"])
      ENV[env_key]
    else
      bmc["password"]
    end
  end
end
