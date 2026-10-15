# frozen_string_literal: true

require "json"
require "optparse"
require "time"

# The database side of the M2 canary gate (scripts/byoh/verify/m2-gate.sh,
# docs/byoh/VERIFY.md). Every check prints PASS, FAIL, WARN or INFO lines;
# a command exits 1 when any check fails. Nothing here changes the
# database.
class ByohGateChecks
  class Error < StandardError; end

  USAGE = <<~USAGE
    Usage: scripts/byoh/verify/m2-checks COMMAND [options]

    Commands:
      location  --location NAME [--rates-from LOCATION]
      host      --host UBID [--ipv6-mode gua|ula]
      vm        --vm UBID --expect public|nat|none|internal|waiting [--external IP]
      info      --vm UBID
      snapshot  --host UBID
      compare   --host UBID --snapshot FILE
      health    --host UBID [--since TIME] [--probe]
  USAGE

  COMMANDS = %w[location host vm info snapshot compare health].freeze
  EXPECTATIONS = %w[public nat none internal waiting].freeze

  # The rate types a VM is billed under; a snapshot counts the open
  # records of these whose VM no longer exists.
  VM_RATE_TYPES = %w[VmVCpu VmStorage IPAddress Gpu].freeze

  def initialize(out: $stdout, err: $stderr)
    @out = out
    @err = err
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when *COMMANDS
      send(:"cmd_#{command}", argv)
    when nil, "help", "-h", "--help"
      @out.puts USAGE
      0
    else
      raise Error, "unknown command #{command}\n#{USAGE}"
    end
  rescue Error, OptionParser::ParseError => e
    @err.puts "! #{e.message}"
    1
  end

  private

  # G2: the location is a BYOH location with the minimum rates, and every
  # rate type of the source location was copied into it.
  def cmd_location(argv)
    opts = {}
    parse(argv, "location --location NAME [--rates-from LOCATION]") do |o|
      o.on("--location NAME", "BYOH location") { opts[:location] = it }
      o.on("--rates-from LOCATION", "Location whose rate types must all be copied") { opts[:rates_from] = it }
    end
    location = ByohRegistration.find_location(opts[:location] || raise(Error, "--location is required")) ||
      raise(Error, "no location #{opts[:location]}")

    report do |r|
      r.check(location.byoh?, "location #{location.name} is a BYOH location")
      rates = BillingRate.load_rates(BillingRate.rate_globs)
      missing = ByohPreflightWarnings.missing_rates(location.name, rates)
      r.check(missing.empty?, "location #{location.name} has the minimum rates#{" (missing #{missing.map { it.join("/") }.join(", ")})" unless missing.empty?}")
      if (source = opts[:rates_from])
        wanted = rate_pairs(rates, source)
        uncopied = wanted - rate_pairs(rates, location.name)
        r.check(!wanted.empty? && uncopied.empty?,
          "every rate type of #{source} (#{wanted.size}) is copied to #{location.name}#{" (missing #{uncopied.map { it.join("/") }.join(", ")})" unless uncopied.empty?}")
      end
      ByohPreflightWarnings.warnings.each { r.warn(it) }
    end
  end

  # G4, G5 and G10: the host is a BYOH host taking VMs, registered with an
  # audit row (or moved into its location with one), its pools pass byoh-pool verify, no VM has a link-local
  # veth address cloud services use, and no internet VM holds an internal
  # address.
  def cmd_host(argv)
    opts = {}
    parse(argv, "host --host UBID [--ipv6-mode gua|ula]") do |o|
      host_option(o, opts)
      o.on("--ipv6-mode MODE", %w[gua ula], "Expected IPv6 mode") { opts[:ipv6_mode] = it }
    end
    host = find_host(opts)

    report do |r|
      r.check(host.byoh?, "host #{host.ubid} is a BYOH host (location #{host.location.name})")
      r.check(host.allocation_state == "accepting", "host #{host.ubid} is accepting (#{host.allocation_state})")
      if (mode = opts[:ipv6_mode])
        r.check(host.ipv6_mode == mode, "ipv6_mode is #{mode} (#{host.ipv6_mode})")
      end
      if host.ipv6_mode == "ula"
        ula48 = host.location.byoh_profile&.ula48
        r.check(!!ula48 && ByohNetworkProfile.covers?(ula48, host.net6), "net6 #{host.net6} is inside the location's ula48 #{ula48 || "(none)"}")
      end
      if audit_row?("register-byoh-host", host) || !audit_row?("move-location", host)
        r.check(audit_row?("register-byoh-host", host), "a register-byoh-host audit row exists for #{host.ubid}")
      else
        # A host registered before the audit log existed has no
        # registration row; the move into its BYOH location wrote one.
        r.info("#{host.ubid} has no register-byoh-host audit row, but a move-location row: it was registered before M2 and moved")
      end

      host.vms_dataset.order(:name).all.each do |vm|
        apipa = VmHost::APIPA_EXCLUDED.find { ByohNetworkProfile.covers?(it, vm.local_vetho_ip) }
        r.fail("#{vm.ubid}: veth address #{vm.local_vetho_ip} is inside #{apipa}") if apipa
      end
      misplaced = DB[:assigned_vm_address]
        .join(:address, id: :address_id)
        .join(:vm, id: Sequel[:assigned_vm_address][:dst_vm_id])
        .where(Sequel[:address][:routed_to_host_id] => host.id, Sequel[:address][:exposure] => "internal", Sequel[:vm][:ip4_exposure] => "internet")
        .select_map(Sequel[:assigned_vm_address][:ip])
        .map { it.network.to_s }
      r.check(misplaced.empty?, "no internet VM holds an internal address#{" (#{misplaced.join(", ")})" unless misplaced.empty?}")

      ByohPool.new(host).verify.each do |level, message|
        case level
        when :fail then r.fail("verify: #{message}")
        when :warn then r.warn("verify: #{message}")
        else r.info("verify: #{message}")
        end
      end
    end
  end

  # G6, G7, G8, G10 and G11: what customers see, what the control plane
  # dials and what is billed for one VM.
  def cmd_vm(argv)
    opts = {}
    parse(argv, "vm --vm UBID --expect public|nat|none|internal|waiting [--external IP]") do |o|
      vm_option(o, opts)
      o.on("--expect KIND", EXPECTATIONS, "public, nat, none (no IPv4), internal, or waiting (not placed)") { opts[:expect] = it }
      o.on("--external IP", "The external IP a nat VM must have") { opts[:external] = it }
    end
    expect = opts[:expect] || raise(Error, "--expect is required")
    vm = find_vm(opts)

    report do |r|
      if expect == "waiting"
        r.check(vm.vm_host_id.nil?, "#{vm.ubid} is waiting for capacity#{" (placed on #{vm.vm_host.ubid})" if vm.vm_host_id}")
        next
      end
      next r.fail("#{vm.ubid} is not on a BYOH host") unless vm.byoh_host?

      api = Serializers::Vm.serialize(vm)
      ipv4_records = ipv4_billing_records(vm)
      send(:"check_#{expect}", r, vm, api, ipv4_records, opts)
      expected_ssh = vm.cp_reach_ip4&.to_s || vm.ip6_string
      # Only VMs assembled with an Sshable have one; for the rest,
      # wait_sshable dials cp_reach_ip4 directly, or nothing without IPv4.
      if (ssh_host = vm.sshable&.host)
        r.check(ssh_host == expected_ssh, "the control plane reaches #{vm.ubid} at #{expected_ssh} (#{ssh_host})")
      else
        r.info("#{vm.ubid} has no sshable; wait_sshable #{(cp = vm.cp_reach_ip4) ? "dials #{cp}:22" : "does not dial it (no IPv4)"}")
      end
    end
  end

  # A VM on a public pool address, which the internet reaches directly
  # (routed or onlink blocks on bare metal, colo, or a routed site).
  def check_public(r, vm, api, ipv4_records, _opts)
    address = vm.assigned_vm_address
    return r.fail("#{vm.ubid} has no IPv4 address") unless address

    ip4 = vm.ip4_string
    exposure = address.address.exposure
    r.check(exposure == "public" && !address.external_ip, "#{vm.ubid}'s address #{ip4} is in a public pool (exposure #{exposure}#{", external #{address.external_ip}" if address.external_ip})")
    check_shown_and_billed(r, vm, api, ipv4_records, ip4)
  end

  def check_nat(r, vm, api, ipv4_records, opts)
    external = vm.assigned_vm_address&.external_ip&.to_s
    return r.fail("#{vm.ubid} has no external IP") unless external

    r.check(external == opts[:external], "#{vm.ubid}'s external IP is #{opts[:external]} (#{external})") if opts[:external]
    check_shown_and_billed(r, vm, api, ipv4_records, external)
  end

  def check_shown_and_billed(r, vm, api, ipv4_records, public_ip)
    r.check(api[:ip4].to_s == public_ip && api[:ip4_scope] == "public", "the API shows #{public_ip} with scope public (#{api[:ip4]}, #{api[:ip4_scope]})")
    if vm.project.billable
      names = ipv4_records.map(&:resource_name)
      r.check(names == ["#{public_ip}/32"], "the IPv4 billing record is named #{public_ip}/32 (#{names.join(", ").then { it.empty? ? "none" : it }})")
    else
      r.info("project #{vm.project.ubid} is not billable, so no billing record is written")
    end
  end

  def check_none(r, vm, api, ipv4_records, _opts)
    r.check(vm.assigned_vm_address.nil? && api[:ip4].nil?, "#{vm.ubid} has no IPv4 address")
    r.check(vm.byoh_egress_nat4?, "#{vm.ubid}'s outbound IPv4 goes through the host NAT")
    r.check(ipv4_records.empty?, "#{vm.ubid} has no IPv4 billing record")
  end

  def check_internal(r, vm, api, ipv4_records, _opts)
    r.check(vm.ip4_exposure == "internal", "#{vm.ubid} was created with ip4_exposure internal (#{vm.ip4_exposure})")
    r.check(api[:ip4_scope] == "internal", "the API shows ip4_scope internal (#{api[:ip4_scope] || "none"})")
    r.check(vm.byoh_egress_nat4?, "#{vm.ubid}'s outbound IPv4 goes through the host NAT (internal_egress #{vm.vm_host.location.byoh_profile.internal_egress})")
    r.check(ipv4_records.empty?, "#{vm.ubid} has no IPv4 billing record")
  end

  # The addresses the gate script connects to, as key=value lines. The
  # script reaches a VM at private_ip4 from inside its namespace on the
  # host (ip netns exec <inhost>), which works whatever the host's IPv6.
  def cmd_info(argv)
    opts = {}
    parse(argv, "info --vm UBID") { vm_option(it, opts) }
    vm = find_vm(opts)
    {
      name: vm.name,
      host: vm.vm_host&.ubid,
      host_ip: vm.vm_host&.sshable&.host,
      ip4: vm.ip4_string,
      public_ip4: vm.public_ip4_string,
      ip6: vm.ip6_string,
      private_ip4: vm.private_ipv4_string,
      inhost: vm.inhost_name,
    }.each { |key, value| @out.puts "#{key}=#{value}" }
    0
  end

  # G15: counts that must come back exactly after VMs are created and
  # destroyed on the host.
  def cmd_snapshot(argv)
    opts = {}
    parse(argv, "snapshot --host UBID") { host_option(it, opts) }
    @out.puts JSON.pretty_generate(snapshot(find_host(opts)))
    0
  end

  def cmd_compare(argv)
    opts = {}
    parse(argv, "compare --host UBID --snapshot FILE") do |o|
      host_option(o, opts)
      o.on("--snapshot FILE", "Output of an earlier snapshot") { opts[:snapshot] = it }
    end
    host = find_host(opts)
    path = opts[:snapshot] || raise(Error, "--snapshot is required")
    before = begin
      JSON.parse(File.read(path))
    rescue SystemCallError, JSON::ParserError => ex
      raise Error, "cannot read snapshot #{path}: #{ex.message}"
    end
    now = snapshot(host)

    report do |r|
      now.each do |key, value|
        was = before[key.to_s]
        if key == :audit_rows
          r.check(was.is_a?(Integer) && value >= was, "audit rows are kept (#{was} then #{value})")
        else
          r.check(value == was, "#{key} is back to #{was} (#{value})")
        end
      end
    end
  end

  # One sample of the M4 F5 soak (scripts/byoh/verify/m4-f5-soak.sh):
  # what bin/monitor and HostNexus have decided about the host. With
  # --since TIME (the soak's start) a non-info page for the host raised
  # after TIME fails too when it is resolved already, so a mark-down that
  # recovered between two samples is not lost. With --probe it also runs
  # the health checks the monitor runs, over a fresh SSH session, as
  # HostNexus#available? does; the only write is the read/write check's
  # 1 MiB test file in each storage path, which it deletes again. The
  # probe refuses a host whose SSH host keys are not pinned yet, as the
  # session would pin the keys it meets in the database.
  def cmd_health(argv)
    opts = {}
    parse(argv, "health --host UBID [--since TIME] [--probe]") do |o|
      host_option(o, opts)
      o.on("--since TIME", "Also fail on pages for the host raised after TIME (ISO 8601), resolved or not") { opts[:since] = it }
      o.on("--probe", "Also run the host's health checks over SSH") { opts[:probe] = true }
    end
    host = find_host(opts)
    since = opts[:since] && begin
      Time.iso8601(opts[:since])
    rescue ArgumentError
      raise Error, "--since takes an ISO 8601 time such as 2026-10-15T08:00:00Z, not #{opts[:since]}"
    end
    label = host.strand&.label

    report do |r|
      r.check(host.byoh?, "host #{host.ubid} is a BYOH host, so the M4 health checks apply (location #{host.location.name})")
      r.check(label != "unavailable", "host strand is at #{label || "(none)"}, not unavailable")
      r.check(host.allocation_state == "accepting", "host #{host.ubid} is accepting (#{host.allocation_state})")
      r.check(!host.checkup_set?(cached: false), "checkup is not set (the monitor has not read the host as down)")
      pages = Page.active.for_resource(host.id).order(:created_at).all
      pages.select { it.severity == "info" }.each { r.info("open info page: #{it.summary}") }
      raised = pages.reject { it.severity == "info" }
      r.check(raised.empty?, "no open page for #{host.ubid}") if raised.empty?
      raised.each { r.fail("open #{it.severity} page: #{it.summary}") }
      if since
        past = Page.for_resource(host.id).non_info.exclude(resolved_at: nil).where { created_at > since }.order(:created_at).all
        r.check(true, "no page for #{host.ubid} was raised and resolved since #{since.utc.iso8601}") if past.empty?
        past.each { r.fail("#{it.severity} page raised at #{it.created_at.utc.iso8601}, resolved since: #{it.summary}") }
      end
      if opts[:probe] && Array(host.sshable.host_keys).empty?
        r.fail("health checks not run: the SSH host keys of #{host.ubid} are not pinned yet, and the probe would pin the keys it meets; " \
          "respirate pins them on its next SSH session to the host")
      elsif opts[:probe]
        healthy = begin
          host.sshable.start_fresh_session { host.perform_health_checks(it, test_file_suffix: "soak") }
        rescue => ex
          r.fail("health checks raised #{ex.class}: #{ex.message}")
          nil
        end
        r.check(healthy, "health checks pass (SMART, read/write, kernel log, clock source)") unless healthy.nil?
      end
    end
  end

  def snapshot(host)
    host.reload
    rate_ids = BillingRate.load_rates(BillingRate.rate_globs).select { VM_RATE_TYPES.include?(it["resource_type"]) }.map { it["id"] }
    rows = ByohPool.new(host).rows
    {
      vms: host.vms_dataset.count,
      free_ipv4: rows.count { !it[:vm_id] && !it[:reserved] },
      assigned_ipv4: rows.count { it[:vm_id] },
      used_cores: host.used_cores,
      used_hugepages_1g: host.used_hugepages_1g,
      available_storage_gib: host.available_storage_gib,
      orphaned_vm_billing_records: BillingRecord.active.where(billing_rate_id: rate_ids).exclude(resource_id: DB[:vm].select(:id)).count,
      audit_rows: DB[:byoh_operator_action].count,
    }
  end

  def audit_row?(command, host)
    !DB[:byoh_operator_action].where(command:, target_id: host.id, result: "ok").empty?
  end

  def ipv4_billing_records(vm)
    ids = BillingRate.load_rates(BillingRate.rate_globs).select { it["resource_type"] == "IPAddress" }.map { it["id"] }
    BillingRecord.active.where(resource_id: vm.id, billing_rate_id: ids).all
  end

  def rate_pairs(rates, location_name)
    rates.select { it["location"] == location_name }.map { [it["resource_type"], it["resource_family"]] }.uniq.sort
  end

  # Collects check results from the block, prints them and returns the
  # exit status.
  def report
    results = Report.new
    yield results
    results.lines.each { @out.puts it }
    failures = results.lines.count { it.start_with?("FAIL") }
    @out.puts failures.zero? ? "ok" : "#{failures} failed"
    failures.zero? ? 0 : 1
  end

  class Report
    attr_reader :lines

    def initialize
      @lines = []
    end

    def check(ok, message)
      @lines << "#{ok ? "PASS" : "FAIL"} #{message}"
    end

    def fail(message) = check(false, message)

    def warn(message)
      @lines << "WARN #{message}"
    end

    def info(message)
      @lines << "INFO #{message}"
    end
  end

  def parse(argv, banner)
    parser = OptionParser.new do |o|
      o.banner = "Usage: scripts/byoh/verify/m2-checks #{banner}"
      yield o
    end
    rest = parser.parse(argv)
    raise Error, "unexpected argument #{rest.first}" unless rest.empty?
  end

  def host_option(o, opts)
    o.on("--host UBID", "VmHost ubid") { opts[:host] = it }
  end

  def vm_option(o, opts)
    o.on("--vm UBID", "Vm ubid") { opts[:vm] = it }
  end

  def find_host(opts)
    key = opts[:host] || raise(Error, "--host is required")
    host = (VmHost[key] if key.match?(/\Avh[0-9a-z]{24}\z/)) || raise(Error, "no host #{key}")
    raise Error, "host #{host.ubid} is not a generic (BYOH) host" unless host.provider_name == HostProvider::GENERIC_PROVIDER_NAME
    host
  end

  def find_vm(opts)
    key = opts[:vm] || raise(Error, "--vm is required")
    (Vm[key] if key.match?(/\Avm[0-9a-z]{24}\z/)) || raise(Error, "no VM #{key}")
  end
end
