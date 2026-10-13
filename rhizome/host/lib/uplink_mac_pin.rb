# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"
require "json"
require "yaml"

class UplinkMacPin
  # Netplan definitions that name other interfaces by their netplan id.
  REFERENCING_TYPES = %w[bonds bridges vrfs].freeze

  def run
    ifname = uplink_interface
    return "the default route is multipath, nothing to pin" if ifname == :multipath

    path, id = name_keyed_entry(ifname)
    return "netplan does not select #{ifname} by name, nothing to pin" unless path
    # Re-keying the entry would leave a VLAN, bond, bridge or VRF that names
    # it pointing at an id that no longer exists, which netplan refuses.
    return "netplan definitions refer to #{ifname} by name, nothing to pin" if referenced?(id)

    fail "netplan already has an ethernet named uplink" if ethernet_ids.include?("uplink")

    mac = permanent_mac(ifname)
    document = pin(load_netplan(path), id, mac)
    verify(path, document)
    archive(path)
    safe_write_to_file(path, YAML.dump(document), perm: 0o600)
    "pinned #{ifname} to #{mac} in #{path}"
  end

  private

  # A multipath default route, as on a host with two BGP uplinks, names
  # its devices under nexthops and has no single uplink.
  def uplink_interface
    routes = JSON.parse(r("ip", "-j", "route", "show", "default"))
    fail "no default route to identify the uplink interface" if routes.empty?
    routes.filter_map { |route| route["dev"] }.first || :multipath
  end

  def referenced?(id)
    netplan_paths.any? do |path|
      network = load_netplan(path).to_h["network"].to_h
      network["vlans"].to_h.each_value.any? { |conf| conf.is_a?(Hash) && conf["link"] == id } ||
        REFERENCING_TYPES.any? { |type|
          network[type].to_h.each_value.any? { |conf| conf.is_a?(Hash) && Array(conf["interfaces"]).include?(id) }
        }
    end
  end

  def permanent_mac(ifname)
    mac = r("ethtool", "-P", ifname)[/(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/]
    mac = File.read(File.join("/sys/class/net", ifname, "address"))[/(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/] if mac.nil? || mac == "00:00:00:00:00:00"
    fail "no permanent mac for #{ifname}" unless mac
    mac
  end

  def netplan_paths
    Dir.glob("/etc/netplan/*.yaml").sort
  end

  def load_netplan(path)
    YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true)
  end

  def name_keyed_entry(ifname)
    netplan_paths.each do |path|
      conf = load_netplan(path).to_h.dig("network", "ethernets").to_h[ifname]
      return [path, ifname] if conf.is_a?(Hash) && !conf.key?("match")
    end
    nil
  end

  def ethernet_ids
    netplan_paths.flat_map { |path| load_netplan(path).to_h.dig("network", "ethernets").to_h.keys }
  end

  def pin(document, id, mac)
    ethernets = document.dig("network", "ethernets")
    ethernets["uplink"] = {"match" => {"macaddress" => mac}}.merge(ethernets.delete(id))
    document
  end

  def verify(path, document)
    before = stage("before")
    after = stage("after")
    File.write(File.join(after, "etc/netplan", File.basename(path)), YAML.dump(document), perm: 0o600)
    r "netplan", "generate", "--root-dir", before
    r "netplan", "generate", "--root-dir", after

    fail "pinning #{path} would change the generated network configuration" unless generated(before) == generated(after)
  ensure
    FileUtils.rm_rf("/var/tmp/uplink-mac-pin")
  end

  def stage(name)
    root = File.join("/var/tmp/uplink-mac-pin", name)
    netplan = File.join(root, "etc/netplan")
    FileUtils.mkdir_p(netplan, mode: 0o700)
    netplan_paths.each { |path| FileUtils.cp(path, netplan, preserve: true) }
    root
  end

  def generated(root)
    Dir.glob(File.join(root, "run/systemd/network/*.network")).map { |unit| without_match(File.read(unit)) }.sort
  end

  def without_match(unit)
    unit.split(/^(?=\[)/).reject { |section| section.start_with?("[Match]") }.join
  end

  def archive(path)
    target = path + ".ubicloud-orig"
    return if File.exist?(target)

    tmp = "#{target}.tmp"
    FileUtils.cp(path, tmp, preserve: true)
    File.rename(tmp, target)
  end
end
