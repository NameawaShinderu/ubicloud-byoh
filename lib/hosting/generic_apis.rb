# frozen_string_literal: true

require "ipaddr"

# Provider API for BYOH ("bring your own host") machines. Nothing here calls a
# hosting provider: the operator declares the host's routed networks and an
# optional Redfish BMC at registration, and this class replays that
# declaration from host_provider.config:
#
#   { "main_ip4" => "192.168.1.10",
#     "location_label" => "homelab-rack-A",
#     "routed_networks" => [{"cidr" => "10.99.0.0/29"}, {"cidr" => "fd00:feed::/64"}],
#     "bmc" => {"endpoint" => "https://...", "username" => "...", "password_env" => "..."} }
class Hosting::GenericApis < Hosting::ProviderApis
  IpInfo = Data.define(:ip_address, :source_host_ip) do
    # The management address is claimed by the host; every declared block is
    # routed to it and stays VM-allocatable.
    def host_only? = ip_address == "#{source_host_ip}/32"

    def host_connectivity? = false
  end

  # The declared IPv4 networks, preceded by the management address as a /32
  # unless a declared block already covers it. The IPv6 /64 is stored on
  # vm_host.net6 at registration instead.
  def pull_ips
    mgmt_ip = @provider.vm_host.sshable.host
    cidrs = Array(config["routed_networks"]).map { it["cidr"] }.reject { it.include?(":") }
    ip_infos = cidrs.map { IpInfo.new(ip_address: it, source_host_ip: mgmt_ip) }

    mgmt_addr = IPAddr.new(mgmt_ip)
    unless cidrs.any? { IPAddr.new(it).include?(mgmt_addr) }
      ip_infos.unshift(IpInfo.new(ip_address: "#{mgmt_ip}/32", source_host_ip: mgmt_ip))
    end

    ip_infos
  end

  # Automated reimage would need a PXE/iPXE server on the operator's network,
  # which Ubicloud does not run for BYOH hosts.
  def reimage
    raise Hosting::CapabilityMissing,
      "generic provider host #{@provider.server_identifier} does not support automated reimage; " \
      "Ubicloud does not run a PXE/iPXE server for BYOH hosts. Reinstall the " \
      "OS out-of-band and re-run host registration."
  end

  def hardware_reset
    redfish_client("hardware reset").power_reset(reset_type: bmc["reset_type"] || Hosting::RedfishClient::DEFAULT_RESET_TYPE)
    nil
  end

  # Many BMCs reject an "On" reset for a system that is already on.
  def power_on
    client = redfish_client("power on")
    client.power_reset(reset_type: "On") unless client.power_state == "On"
    nil
  end

  def power_status
    return "no Redfish BMC configured" unless redfish?

    "redfish: #{redfish_client("power status").power_state}"
  end

  private

  def config
    @provider.config || {}
  end

  def bmc
    config["bmc"] || {}
  end

  def redfish?
    !bmc["endpoint"].nil? && bmc.fetch("protocol", "redfish") == "redfish"
  end

  def redfish_client(operation)
    unless redfish?
      raise Hosting::CapabilityMissing,
        "generic provider host #{@provider.server_identifier} has no Redfish BMC endpoint configured; " \
        "#{operation} must be performed manually"
    end

    Hosting::RedfishClient.new(
      bmc["endpoint"],
      username: bmc["username"],
      password: bmc_password,
      verify_ssl: bmc.fetch("verify_ssl", true),
      system_id: bmc["system_id"],
    )
  end

  # Prefer password_env (an env var on the control plane) over a password
  # stored in the host_provider.config JSONB column.
  def bmc_password
    if (env_key = bmc["password_env"])
      ENV[env_key]
    else
      bmc["password"]
    end
  end
end
