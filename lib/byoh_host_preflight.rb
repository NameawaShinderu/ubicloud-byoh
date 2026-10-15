# frozen_string_literal: true

require "json"
require "securerandom"
require "yaml"

# Host preflight for a BYOH host (docs/byoh/PLATFORMS.md PF1-PF21).
# scripts/byoh/host/ubicloud-host runs on the host, gathers facts and
# judges the host-local checks; .parse reads its --json output, and
# #evaluate adds the checks that need the control plane: PF17 and
# contract C5 against the declared pools, PF20 boot images and the
# location, PF21 the control-plane services, and a cross-check of the
# CPU count. #accept lets the operator downgrade the few fails that are
# a choice rather than a defect.
class ByohHostPreflight
  class UsageError < StandardError; end

  Check = Data.define(:id, :status, :detail, :fix, :accepted)

  STATUSES = %w[pass info warn fail].freeze

  # Every check the script prints, always, once.
  HOST_CHECKS = %w[
    PF1 PF3 PF4 PF5 PF6 PF7 PF-min-cpu PF8 PF8-hybrid PF9 PF10 PF10-btrfs PF10-zfs PF11 PF12 PF13 PF14
    PF15-apt PF15-egress PF16-docker PF16-ufw PF16-tailscaled PF16-k3s PF16-libvirtd PF16-pve
    PF16-rhizome-user PF19
  ].freeze
  # Printed only with --standalone; the control plane does better (PF17).
  STANDALONE_CHECKS = %w[default-route main-ip-local].freeze

  # The facts the script prints, and the JSON type each must have. nil
  # is allowed where a command can print nothing.
  FACTS = {
    "arch" => [String],
    "os_version" => [String],
    "mem_gib" => [Integer],
    "cpus_online" => [Integer],
    "storage_fstype" => [String],
    "ip_addr" => [Array, NilClass],
    "ip_route" => [Array, NilClass],
    "netplan" => [String],
    "host_keys" => [Array],
    "sshd" => [Hash],
  }.freeze

  # The fails an operator may accept, and what accepting one means.
  OVERRIDABLE = {
    "PF8-hybrid" => "VMs get a mix of performance and efficiency cores, and placement does not tell them apart",
    "PF10-btrfs" => "write-through detection is off on btrfs, and VM storage there is UNVERIFIED",
    "PF16-docker" => "docker's firewall rules may still drop VM traffic",
    "PF16-ufw" => "ufw's firewall rules may still drop VM traffic",
    "PF16-tailscaled" => "tailscaled's firewall rules may still drop VM traffic",
    "PF16-k3s" => "k3s's firewall rules may still drop VM traffic",
    "PF16-libvirtd" => "libvirtd's firewall rules and bridges may still disturb VM traffic",
  }.freeze

  ARCHES = {"x86_64" => "x64", "aarch64" => "arm64"}.freeze

  # The services that must run for a registered host to be set up.
  SERVICES = %w[ubicloud-web ubicloud-respirate].freeze

  attr_reader :checks, :facts, :uplink_ip

  def self.nonce = SecureRandom.hex(8)

  # Reads the script's --json output. Lines without "UBIPF:<nonce> " are
  # noise (a .bashrc, sudo warnings) and skipped; the marker may follow
  # noise that lacks a newline. Anything else that is wrong gives a single
  # failing check.
  def self.parse(output, nonce)
    prefix = "UBIPF:#{nonce} "
    checks = []
    facts = {}
    errors = []
    output.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_line do |line|
      next unless (start = line.index(prefix))

      record = begin
        JSON.parse(line[(start + prefix.size)..])
      rescue JSON::ParserError
        errors << "a line is not JSON"
        next
      end
      error = record_error(record)
      if error
        errors << error
      elsif record["kind"] == "check"
        checks << Check.new(id: record["id"], status: record["status"], detail: record["detail"], fix: record["fix"], accepted: false)
      else
        facts[record["id"]] = record["value"]
      end
    end

    ids = checks.map(&:id)
    errors.concat((HOST_CHECKS - ids).map { "no check #{it}" })
    errors.concat(ids.tally.select { |_, n| n > 1 }.keys.map { "check #{it} printed more than once" })
    errors.concat((FACTS.keys - facts.keys).map { "no fact #{it}" })
    return new(checks, facts) if errors.empty?

    new([Check.new(id: "preflight", status: "fail", detail: "preflight output unreadable: #{errors.uniq.first(5).join("; ")}", fix: "check that scripts/byoh/host/ubicloud-host runs on the host", accepted: false)], {})
  end

  def self.record_error(record)
    return "a line is not a JSON object" unless record.is_a?(Hash)

    case record["kind"]
    when "check"
      if !(HOST_CHECKS + STANDALONE_CHECKS).include?(record["id"])
        "unknown check #{record["id"].inspect}"
      elsif !STATUSES.include?(record["status"])
        "check #{record["id"]} has status #{record["status"].inspect}"
      elsif !record["detail"].is_a?(String) || !record["fix"].is_a?(String)
        "check #{record["id"]} has no detail or fix text"
      end
    when "fact"
      types = FACTS[record["id"]]
      if types.nil?
        "unknown fact #{record["id"].inspect}"
      elsif types.none? { record["value"].is_a?(it) }
        "fact #{record["id"]} is not a #{types.first.name}"
      end
    else
      "unknown kind #{record["kind"].inspect}"
    end
  end

  # Whether the control plane's services run: nil on a dev layout (no
  # env_file), else {unit => active?}.
  def self.service_states(env_file: "/etc/ubicloud/env", runner: ->(unit) { system("systemctl", "is-active", "--quiet", unit, out: File::NULL, err: File::NULL) == true })
    SERVICES.to_h { [it, runner.call(it)] } if File.exist?(env_file)
  end

  def initialize(checks, facts)
    @checks = checks
    @facts = facts
  end

  def readable? = !@facts.empty?

  def host_keys = @facts.fetch("host_keys", [])

  # Adds the control-plane checks. pools are ByohPoolDeclaration entries,
  # uplink the pools file's uplink interface, uplink_ip an explicit
  # --uplink-ip; location is the resolved Location or nil, location_name
  # what the operator asked for; services as from .service_states.
  def evaluate(main_ip:, pools: [], uplink: nil, uplink_ip: nil, location: nil, location_name: nil, boot_images: [], services: nil)
    return self unless readable?

    route = default_route(uplink_ip)
    addressing(route, main_ip:, pools:, uplink:, explicit_uplink_ip: uplink_ip, location:)
    boot_images_check(boot_images, location:, location_name:)
    services_check(services)
    min_cpu_cross_check
    self
  end

  # Downgrades the accepted fails to warnings. "PF16" accepts every
  # overridable PF16 check. An id that names no overridable check is a
  # usage error.
  def accept(ids)
    ids.each do |id|
      targets = OVERRIDABLE.keys.select { it == id || it.start_with?("#{id}-") }
      if targets.empty?
        known = (HOST_CHECKS + %w[PF2 PF17 PF20 PF21]).any? { it == id || it.start_with?("#{id}-") }
        raise UsageError, "--accept-check #{id}: #{known ? "this check cannot be accepted" : "no such check"}; only #{OVERRIDABLE.keys.join(", ")} can"
      end

      @checks.map! do |check|
        next check unless targets.include?(check.id) && check.status == "fail"

        check.with(status: "warn", detail: "accepted: #{check.detail}; #{OVERRIDABLE[check.id]}", accepted: true)
      end
    end
    self
  end

  def blocking? = @checks.any? { it.status == "fail" }

  # The URL a host downloads each image from, for the PF15 egress check
  # (--boot-image-url); images without one are left out, PF20 reports
  # them. Every image outside blob storage has a public mirror.
  def boot_image_urls(boot_images)
    return [] unless (arch = ARCHES[@facts["arch"]])

    boot_images.reject { boot_image_problem(it, arch) }.map do |name|
      Prog::DownloadBootImage.upstream_url(name, Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig(name, arch).keys.max, arch)
    end
  end

  def to_table
    @checks.flat_map do |check|
      rows = [format("%-5s %-18s %s", check.status, check.id, check.detail)]
      rows << format("%24s fix: %s", "", check.fix) unless check.fix.empty?
      rows
    end.join("\n") + "\n"
  end

  def to_json_lines
    @checks.map { JSON.generate(it.to_h) }.join("\n") + "\n"
  end

  private

  def add(id, status, detail, fix = "")
    @checks << Check.new(id:, status:, detail:, fix:, accepted: false)
  end

  def replace(id, status, detail, fix = "")
    @checks.reject! { it.id == id }
    add(id, status, detail, fix)
  end

  # [[interface, address]] of the host's IPv4 addresses.
  def ipv4_addresses
    Array(@facts["ip_addr"]).flat_map do |link|
      next [] unless link.is_a?(Hash)

      Array(link["addr_info"]).filter_map { [link["ifname"], it["local"]] if it.is_a?(Hash) && it["family"] == "inet" }
    end
  end

  def default_routes
    Array(@facts["ip_route"]).select { it.is_a?(Hash) && it["dst"] == "default" }.sort_by { it["metric"].to_i }
  end

  # The default route VMs leave by: the first by metric, or the one that
  # carries an explicit uplink IP, and nil when no default route does.
  def default_route(explicit)
    routes = default_routes
    return routes.first unless explicit

    explicit_dev = ipv4_addresses.find { |_, ip| ip == explicit }&.first
    routes.find { it["prefsrc"] == explicit || it["dev"] == explicit_dev }
  end

  def addressing(route, main_ip:, pools:, uplink:, explicit_uplink_ip:, location:)
    routes = default_routes
    local = ipv4_addresses
    local_ips = local.map(&:last)
    @uplink_ip = explicit_uplink_ip || (route && (route["prefsrc"] || local.find { |dev, _| dev == route["dev"] }&.last))
    devs = routes.map { it["dev"] }.join(", ")

    if routes.empty?
      add("PF17-route", "fail", "no IPv4 default route; the host needs one for egress and as its uplink", "give the host a default route")
    elsif explicit_uplink_ip && !local_ips.include?(explicit_uplink_ip)
      add("PF17-route", "fail", "--uplink-ip #{explicit_uplink_ip} is not an address of the host", "pass an address the host's default route leaves from")
    elsif !route
      add("PF17-route", "fail", "--uplink-ip #{explicit_uplink_ip} is not on an interface with a default route (#{devs})", "pass an address the host's default route leaves from")
    elsif !@uplink_ip
      add("PF17-route", "fail", "the default route on #{route["dev"]} has no IPv4 source address", "pass --uplink-ip")
    elsif routes.size > 1 && !explicit_uplink_ip
      add("PF17-route", "fail", "#{routes.size} IPv4 default routes (#{devs}); the uplink is ambiguous", "remove the extra default routes, or pass --uplink-ip to name the uplink")
    elsif routes.size > 1
      add("PF17-route", "warn", "#{routes.size} IPv4 default routes (#{devs}); uplink #{@uplink_ip} given with --uplink-ip")
    else
      add("PF17-route", "pass", "default route via #{route["gateway"] || "a device route"} on #{route["dev"]}, uplink IP #{@uplink_ip}")
    end

    # Without a default route PF17-route has failed already.
    if uplink && route
      if Array(@facts["ip_addr"]).none? { it.is_a?(Hash) && it["ifname"] == uplink }
        add("PF17-uplink", "warn", "the pools file names uplink #{uplink}, which is not an interface of the host")
      elsif route["dev"] != uplink
        add("PF17-uplink", "warn", "the pools file names uplink #{uplink}, but the default route leaves by #{route["dev"]}")
      else
        add("PF17-uplink", "pass", "uplink #{uplink} carries the default route")
      end
    end

    if local_ips.include?(main_ip)
      add("PF17-main-ip", "pass", "main IP #{main_ip} is on the host")
    else
      add("PF17-main-ip", "warn", "main IP #{main_ip} is not on the host; that is right only for a NAT address in front of it")
    end

    pool_check(pools, main_ip:, gateway: route && route["gateway"], local_ips:, location:)
    netplan_check(route)
  end

  def pool_check(pools, main_ip:, gateway:, local_ips:, location:)
    if pools.empty?
      add("PF17", "info", "no pools declared; only IPv6-only VMs will be placed on this host")
      return
    end

    args = {main_ip:, uplink_ip: @uplink_ip, gateway:, local_ips:}
    errors = if location
      begin
        ByohPoolDeclaration.validate_set!(pools, location:, **args)
        []
      rescue ByohPoolDeclaration::ValidationError => ex
        ex.message.split("\n")
      end
    else
      ByohPoolDeclaration.host_address_errors(pools, **args)
    end

    if errors.empty?
      scope = location ? "" : " (against the host only; the location did not resolve)"
      add("PF17", "pass", "#{pools.size} pool(s) hand VMs no address of the host#{scope}")
    else
      add("PF17", "fail", errors.join("; "), "see docs/byoh/NETWORKING.md contract C5 and docs/byoh/POOL_OPERATIONS.md")
    end
  end

  # cloud-init on some clouds writes every address the cloud assigns to
  # the NIC into its netplan, which puts pool addresses on the host
  # (contract C5) at the next boot even when they are not there now.
  def netplan_check(route)
    text = @facts["netplan"]
    return if text.empty? || route.nil?

    doc = begin
      YAML.safe_load(text)
    rescue Psych::Exception
      add("PF17-netplan", "info", "the cloud-init netplan is not valid YAML")
      return
    end
    ethernets = doc.is_a?(Hash) && doc["network"].is_a?(Hash) && doc["network"]["ethernets"]
    count = (ethernets.is_a?(Hash) ? ethernets : {}).sum do |name, config|
      next 0 unless config.is_a?(Hash) && [name, config["set-name"]].include?(route["dev"])

      Array(config["addresses"]).reject { it.to_s.include?(":") }.size + ((config["dhcp4"] == true) ? 1 : 0)
    end
    if count > 1
      add("PF17-netplan", "warn", "the cloud-init netplan gives #{route["dev"]} #{count} IPv4 addresses; pool addresses there are configured on the host at boot (contract C5)", "stop cloud-init or the cloud agent from configuring pool addresses on the uplink; see docs/byoh/TROUBLESHOOTING.md section 4")
    else
      add("PF17-netplan", "pass", "the cloud-init netplan gives #{route["dev"]} at most one IPv4 address")
    end
  end

  def boot_images_check(boot_images, location:, location_name:)
    arch = ARCHES[@facts["arch"]]
    problems = []
    problems << (location_name ? "location #{location_name} does not exist" : "no location given") unless location
    problems << "no boot image given (--default-boot-image)" if boot_images.empty?
    if arch
      problems.concat(boot_images.filter_map { boot_image_problem(it, arch) })
    else
      problems << "host architecture #{@facts["arch"]} has no boot images"
    end
    level, message = ByohConfigCheck.boot_image_source(production: Config.production?)
    problems << message if level == "fail"

    if problems.empty?
      add("PF20", "pass", "location #{location.name}, boot image(s) #{boot_images.join(", ")} for #{arch}")
    else
      add("PF20", "fail", problems.join("; "), "create the location with ubicloud-admin site add, and name a boot image with a public mirror, such as ubuntu-noble")
    end
  end

  def boot_image_problem(name, arch)
    if Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig(name, arch).to_h.empty?
      "#{name} is not a known boot image for #{arch}"
    elsif Prog::DownloadBootImage.blob_storage_only?(name)
      "#{name} is served only from Ubicloud's blob storage"
    end
  end

  def services_check(services)
    if services.nil?
      add("PF21", "info", "development layout: make sure web and respirate run (bin/respirate), or the host is never set up")
    elsif (stopped = SERVICES.reject { services[it] }).empty?
      add("PF21", "pass", "#{SERVICES.join(" and ")} are active")
    else
      add("PF21", "fail", "#{stopped.join(" and ")} not active, so a registered host would never be set up", "systemctl start ubicloud.target")
    end
  end

  # The script judges the CPU count too; this holds even if it did not.
  def min_cpu_cross_check
    cpus = @facts["cpus_online"]
    return if cpus >= 2 || @checks.any? { it.id == "PF-min-cpu" && it.status == "fail" }

    replace("PF-min-cpu", "fail", "#{cpus} online CPU(s); at least 2 are needed", "give the machine at least 2 CPUs")
  end
end
