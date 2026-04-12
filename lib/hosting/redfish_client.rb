# frozen_string_literal: true

require "excon"
require "json"
require "uri"

# Minimal Redfish client for out-of-band power operations against a
# BYOH host's BMC. Targets the subset of the DMTF Redfish spec that
# every modern server BMC (iDRAC, iLO, Supermicro, MegaRAC) implements:
#
#   GET  /redfish/v1/Systems                  → discover SystemId
#   GET  /redfish/v1/Systems/{SystemId}       → read Actions.#Reset.target
#   POST {Reset.target} {"ResetType": "..."}  → power-cycle
#
# Intentionally NOT implemented: session authentication (Basic is fine
# for one-shot commands), BIOS attribute manipulation, virtual media
# mounting, full boot-source override (see #set_next_boot_pxe for the
# narrow case we do support — only for future automated reimage, which
# Ubicloud does not currently drive for BYOH hosts).
class Hosting::RedfishClient
  class Error < StandardError; end

  DEFAULT_RESET_TYPE = "ForceRestart"

  def initialize(endpoint, username:, password:, verify_ssl: true, system_id: nil)
    @endpoint = endpoint
    @username = username
    @password = password
    @verify_ssl = verify_ssl
    @system_id = system_id
  end

  def power_reset(reset_type: DEFAULT_RESET_TYPE)
    sys_id = @system_id || discover_system_id
    target = reset_action_target(sys_id)
    http_post(target, {"ResetType" => reset_type})
    nil
  end

  # Not currently exercised by any caller — present so that when/if
  # Ubicloud stands up PXE infrastructure for BYOH hosts, the hook is
  # already there. Kept deliberately minimal.
  def set_next_boot_pxe
    sys_id = @system_id || discover_system_id
    http_patch("/redfish/v1/Systems/#{sys_id}", {
      "Boot" => {
        "BootSourceOverrideEnabled" => "Once",
        "BootSourceOverrideTarget" => "Pxe"
      }
    })
    nil
  end

  def discover_system_id
    body = http_get("/redfish/v1/Systems")
    members = body["Members"] || []
    raise Error, "Redfish /Systems contains no members" if members.empty?
    if members.length > 1 && @system_id.nil?
      raise Error, "Redfish /Systems returned multiple systems; set bmc.system_id explicitly"
    end
    odata_id = members.first["@odata.id"] or raise Error, "Redfish member has no @odata.id"
    odata_id.split("/").last
  end

  def reset_action_target(sys_id)
    body = http_get("/redfish/v1/Systems/#{sys_id}")
    target = body.dig("Actions", "#ComputerSystem.Reset", "target")
    raise Error, "Redfish System #{sys_id} has no #ComputerSystem.Reset action" unless target
    target
  end

  private

  def connection
    @connection ||= Excon.new(@endpoint,
      user: @username,
      password: @password,
      ssl_verify_peer: @verify_ssl,
      headers: {"Content-Type" => "application/json", "Accept" => "application/json"})
  end

  def http_get(path)
    resp = connection.get(path: path, expects: 200)
    JSON.parse(resp.body)
  end

  def http_post(url_or_path, body)
    connection.post(path: extract_path(url_or_path), body: JSON.generate(body), expects: [200, 202, 204])
  end

  def http_patch(path, body)
    connection.patch(path: path, body: JSON.generate(body), expects: [200, 202, 204])
  end

  # Redfish action targets are usually absolute-path but some BMCs return
  # full URLs. Accept both, assuming the host matches @endpoint.
  def extract_path(url_or_path)
    return url_or_path unless url_or_path.start_with?("http")
    URI.parse(url_or_path).request_uri
  end
end
