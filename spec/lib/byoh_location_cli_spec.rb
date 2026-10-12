# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohLocationCli do
  let(:random) { class_double(SecureRandom) }
  let(:dir) { Dir.mktmpdir }

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, random:).run(argv)
    [status, out.string, err.string]
  end

  def byoh_location(name, profile = {"ula48" => "fd00:1:2::/48"})
    Location.create(name:, display_name: name, ui_name: name, visible: false, provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: profile)
  end

  def write_rates(dir, name, rows)
    # Each row alone, so that rows sharing a Time write no YAML aliases.
    File.write(File.join(dir, "#{name}.yml"), "---\n" + rows.map { [it].to_yaml.delete_prefix("---\n") }.join)
  end

  def rate(location, type, family, unit_price: 0.001, active_from: Time.utc(2020, 1, 1))
    {"id" => "#{location}-#{type}-#{family}-#{active_from.to_i}", "resource_type" => type, "resource_family" => family, "location" => location, "unit_price" => unit_price, "billed_by" => "duration", "active_from" => active_from, "byoc" => false}
  end

  def full_rates(location)
    ByohPreflightWarnings::MINIMUM_RATES.map { |type, family| rate(location, type, family) }
  end

  def audit_rows
    DB[:byoh_operator_action].order(:created_at).all
  end

  before do
    # Load the memoised rates before any example points the overlay
    # directory at its temporary files.
    BillingRate.rates
    allow(Config).to receive_messages(base_url: "https://cloud.example.com", control_plane_outbound_cidrs: ["198.51.100.7/32"])
  end

  after { FileUtils.rm_rf(dir) }

  describe "#run" do
    it "prints the usage without a command" do
      expect(cli).to eq [0, described_class::USAGE, ""]
      expect(cli("--help")[0]).to eq 0
    end

    it "refuses an unknown command" do
      status, _, error = cli("frobnicate")
      expect(status).to eq 1
      expect(error).to start_with "! unknown command frobnicate\nUsage:"
    end

    it "refuses unknown options and extra arguments" do
      expect(cli("list", "--bogus")).to eq [1, "", "! invalid option: --bogus\n"]
      expect(cli("list", "extra")[2]).to eq "! unexpected argument extra\n"
    end
  end

  describe "create" do
    it "creates a hidden BYOH location with an audit row" do
      expect(random).to receive(:random_bytes).with(5).and_return("\x12\x34\x56\x78\x9a".b)
      status, output, error = cli("create", "--name", "byoh-aws-aps1", "--ui-name", "AWS Mumbai (BYOH)",
        "--underlay", "10.98.0.0/16", "--overlay", "172.20.0.0/14", "--cp-source", "10.98.1.10/32",
        "--mgmt-allow", "10.98.1.10/32,198.51.100.7/32", "--egress-deny", "10.98.0.0/16", "--egress-allow", "10.98.2.0/24",
        "--dns-servers", "10.98.0.2", "--cp-reach", "onhost", "--ula-underlay", "none", "--internal-egress", "site",
        "--guest-mtu", "1400", "--egress-smtp", "--no-vm-egress-nat4")
      expect(status).to eq 0

      location = Location.first(name: "byoh-aws-aps1")
      expect(location.values.slice(:display_name, :ui_name, :visible, :provider, :project_id)).to eq(
        display_name: "byoh-aws-aps1", ui_name: "AWS Mumbai (BYOH)", visible: false, provider: "generic", project_id: nil,
      )
      expect(location.byoh_network.to_h).to eq(
        "underlay_cidrs" => ["10.98.0.0/16"], "overlay_ipv4_cidrs" => ["172.20.0.0/14"], "cp_source_cidrs" => ["10.98.1.10/32"],
        "host_mgmt_allow" => ["10.98.1.10/32", "198.51.100.7/32"], "vm_egress_deny" => ["10.98.0.0/16"],
        "vm_egress_allow" => ["10.98.2.0/24"], "dns_servers" => ["10.98.0.2"], "cp_reach" => "onhost", "ula_underlay" => "none",
        "internal_egress" => "site", "guest_mtu" => 1400, "egress_smtp" => true, "vm_egress_nat4" => false,
        "ula48" => "fd12:3456:789a::/48",
      )
      expect(Strand[location.id].prog).to eq "LocationNexus"
      expect(output).to eq "Created location byoh-aws-aps1 (#{location.ubid}), hidden.\n#{described_class::RESTART_NOTE}\n"
      expect(error).to include "warning: location byoh-aws-aps1: cp_source_cidrs 10.98.1.10/32 is not in CONTROL_PLANE_OUTBOUND_CIDRS"

      row = audit_rows.last
      expect(row.slice(:command, :target_id, :result)).to eq(command: "byoh-location create", target_id: location.id, result: "ok")
      expect(row[:args]["byoh_network"]["ula48"]).to eq "fd12:3456:789a::/48"
    end

    it "copies rates and makes the location visible in the same run" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      status, output, error = cli("create", "--name", "byoh-1", "--display-name", "byoh-one", "--ula48", "fd00:aa::/48",
        "--rates-from", "hetzner-fsn1", "--multiplier", "2", "--visible")
      expect([status, error]).to eq [0, ""]
      expect(output).to include("Wrote ", "Location byoh-1 is now visible.")
      location = Location.first(name: "byoh-1")
      expect(location.visible).to be true
      expect(location.display_name).to eq "byoh-one"
      expect(audit_rows.map { it[:command] }).to eq ["byoh-location create", "byoh-location rates", "byoh-location set-visible"]
    end

    it "refuses --visible before creating anything when the rates would be incomplete" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      write_rates(dir, "partial", [rate("partial", "VmVCpu", "standard")])
      missing = "VmVCpu/burstable, VmStorage/standard, VmStorage/burstable, IPAddress/IPv4, MachineImageStorage/standard"
      expect(cli("create", "--name", "byoh-1", "--rates-from", "partial", "--visible"))
        .to eq [1, "", "! location byoh-1 cannot be created visible: no billing rate for #{missing}\n"]
      expect(cli("create", "--name", "byoh-1", "--visible"))
        .to eq [1, "", "! location byoh-1 cannot be created visible: no billing rate for VmVCpu/standard, #{missing}\n"]
      expect(Location.where(name: "byoh-1").count).to eq 0
      expect(File.exist?(File.join(dir, "byoh-1.yml"))).to be false
      expect(audit_rows).to be_empty
    end

    it "makes a location visible with the rates its overlay file already has" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      expect(random).to receive(:random_bytes).and_return("\x01\x02\x03\x04\x05".b)
      status, output, = cli("create", "--name", "byoh-1", "--visible")
      expect(status).to eq 0
      expect(output).to include "Location byoh-1 is now visible."
      expect(Location.first(name: "byoh-1").visible).to be true
    end

    it "retries a generated ula48 that another location uses" do
      byoh_location("byoh-old", {"ula48" => "fd01:203:405::/48"})
      expect(random).to receive(:random_bytes).and_return("\x01\x02\x03\x04\x05".b, "\x01\x02\x03\x04\x06".b)
      expect(cli("create", "--name", "byoh-1")[0]).to eq 0
      expect(Location.first(name: "byoh-1").byoh_network["ula48"]).to eq "fd01:203:406::/48"
    end

    it "gives up when every generated ula48 is taken" do
      byoh_location("byoh-old", {"ula48" => "fd01:203:405::/48"})
      expect(random).to receive(:random_bytes).exactly(32).times.and_return("\x01\x02\x03\x04\x05".b)
      expect(cli("create", "--name", "byoh-1")[2]).to eq "! could not pick an unused ula48; pass --ula48\n"
    end

    it "refuses bad input" do
      byoh_location("byoh-old")
      {
        [] => "--name is required",
        ["--name", "Byoh"] => "--name Byoh must be lowercase letters, digits and -",
        ["--name", "byoh-1", "--display-name", "a_b"] => "--display-name a_b must be lowercase letters, digits and -",
        ["--name", "global"] => "--name global is reserved for global billing rates",
        ["--name", "byoh-1", "--multiplier", "2"] => "--multiplier needs --rates-from",
        ["--name", "byoh-1", "--rates-from", "hetzner-fsn1"] => "BILLING_RATES_EXTRA_DIR is not set",
        ["--name", "hetzner-fsn1"] => "location hetzner-fsn1 already uses that name, display name or UI name",
        ["--name", "byoh-1", "--ui-name", "byoh-old"] => "location byoh-old already uses that name, display name or UI name",
        ["--name", "byoh-1", "--ula48", "fd00:1:2::/48"] => "ula48 fd00:1:2::/48 is already used by location byoh-old",
        ["--name", "byoh-1", "--ula48", "fd00::/47", "--cp-reach", "nowhere"] => "invalid profile: cp_reach must be one of onhost, public; ula48 must be a /48 inside fc00::/7",
      }.each do |args, message|
        expect(cli("create", *args)).to eq [1, "", "! #{message}\n"]
      end
      expect(Location.where(name: "byoh-1").count).to eq 0
    end
  end

  describe "list" do
    it "says when there are no BYOH locations" do
      expect(cli("list")).to eq [0, "No BYOH locations.\n", ""]
    end

    it "lists BYOH locations with hosts, grants and rate coverage" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      loc = byoh_location("byoh-1")
      byoh_location("byoh-2", {})
      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      create_vm_host(location_id: loc.id)
      Project.create(name: "p").set_ff_visible_locations(["byoh-1"])
      _, output, = cli("list")
      expect(output.lines.map(&:split)).to eq [
        %w[NAME DISPLAY NAME VISIBLE HOSTS GRANTS RATES],
        %w[byoh-1 byoh-1 false 1 1 complete],
        %w[byoh-2 byoh-2 false 0 0 missing],
      ]
    end
  end

  describe "show" do
    it "shows a location found by name or ubid" do
      loc = byoh_location("byoh-1", {"ula48" => "fd00:1:2::/48", "cp_reach" => "public"})
      project = Project.create(name: "p")
      project.set_ff_visible_locations(["byoh-1"])
      [loc.name, loc.ubid].each do |key|
        status, output, error = cli("show", "--location", key)
        expect(status).to eq 0
        expect(error).to include "warning: BILLING_RATES_EXTRA_DIR is unset"
        expect(output).to eq <<~OUT
          Location      byoh-1 (#{loc.ubid})
          Display name  byoh-1
          UI name       byoh-1
          Visible       false
          Hosts         0
          Granted to    #{project.ubid}
          Rate file     (BILLING_RATES_EXTRA_DIR is unset)
          Rates         missing VmVCpu/standard, VmVCpu/burstable, VmStorage/standard, VmStorage/burstable, IPAddress/IPv4, MachineImageStorage/standard
          Profile
          {
            "ula48": "fd00:1:2::/48",
            "cp_reach": "public"
          }
        OUT
      end
    end

    it "reports complete rates and the rate file" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      byoh_location("byoh-1")
      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      _, output, error = cli("show", "--location", "byoh-1")
      expect(output).to include("Rate file     #{dir}/byoh-1.yml\n", "Rates         complete\n")
      expect(error).to eq ""
    end

    it "refuses a missing, unknown or non-BYOH location" do
      expect(cli("show")[2]).to eq "! --location is required\n"
      expect(cli("show", "--location", "nope")[2]).to end_with "! no location nope\n"
      expect(cli("show", "--location", "10#{"a" * 24}")[2]).to end_with "! no location 10#{"a" * 24}\n"
      expect(cli("show", "--location", "hetzner-fsn1")[2]).to end_with "! location hetzner-fsn1 is not a BYOH location\n"
    end
  end

  describe "set" do
    let(:location) { byoh_location("byoh-1", {"ula48" => "fd00:1:2::/48", "cp_reach" => "public", "guest_mtu" => 1400}) }

    it "merges profile options, removes unset keys and renames" do
      status, output, = cli("set", "--location", location.name, "--underlay", "10.0.0.0/16", "--unset", "guest_mtu", "--ui-name", "Site 1")
      expect([status, output]).to eq [0, "Updated location byoh-1.\n"]
      location.reload
      expect(location.ui_name).to eq "Site 1"
      expect(location.byoh_network.to_h).to eq("ula48" => "fd00:1:2::/48", "cp_reach" => "public", "underlay_cidrs" => ["10.0.0.0/16"])
      expect(audit_rows.last[:args].to_h).to eq("ui_name" => "Site 1", "byoh_network" => location.byoh_network.to_h)
    end

    it "refuses a UI name another location shows, but keeps its own" do
      expect(cli("set", "--location", location.name, "--ui-name", "Germany")).to eq [1, "", "! location hetzner-fsn1 already uses UI name Germany\n"]
      expect(location.reload.ui_name).to eq "byoh-1"
      expect(cli("set", "--location", location.name, "--ui-name", "byoh-1")[0]).to eq 0
    end

    it "records a call that changes nothing" do
      expect(cli("set", "--location", location.name)[0]).to eq 0
      expect(audit_rows.map { it[:command] }).to eq ["byoh-location set"]
    end

    it "changes ula48 only while the location has no hosts" do
      expect(cli("set", "--location", location.name, "--ula48", "fd00:1:3::/48")[0]).to eq 0
      create_vm_host(location_id: location.id)
      expect(cli("set", "--location", location.name, "--ula48", "fd00:1:4::/48")[2]).to eq "! ula48 cannot change while the location has hosts\n"
      expect(location.reload.byoh_network["ula48"]).to eq "fd00:1:3::/48"
    end

    it "skips the ula48 check for a profile without ula48" do
      loc = byoh_location("byoh-2", {})
      byoh_location("byoh-3", {})
      expect(cli("set", "--location", loc.name, "--cp-reach", "public")[0]).to eq 0
    end

    it "refuses an invalid profile and unknown --unset keys" do
      expect(cli("set", "--location", location.name, "--guest-mtu", "10")[2]).to eq "! invalid profile: guest_mtu must be an integer between 1280 and 9000\n"
      expect(cli("set", "--location", location.name, "--unset", "ula48", "--unset", "tier")[2]).to end_with "! --unset cannot remove ula48, tier\n"
    end

    it "shows a location only with complete rates, and hides it" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      expect(cli("set", "--location", location.name, "--visible")[2]).to start_with "! location byoh-1 stays hidden: no billing rate for VmVCpu/standard"
      expect(location.reload.visible).to be false

      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      expect(cli("set", "--location", location.name, "--visible")[0]).to eq 0
      expect(location.reload.visible).to be true
      expect(cli("set", "--location", location.name, "--no-visible")[1]).to end_with "Location byoh-1 is now hidden.\n"
      expect(location.reload.visible).to be false
      expect(audit_rows.map { it[:command] }).to eq ["byoh-location set", "byoh-location set-visible", "byoh-location set", "byoh-location set-hidden"]
    end
  end

  describe "rates" do
    let(:location) { byoh_location("byoh-1") }
    let(:path) { File.join(dir, "byoh-1.yml") }

    def load_file
      YAML.load_file(path, permitted_classes: [Time])
    end

    before { allow(Config).to receive(:billing_rates_extra_dir).and_return(dir) }

    it "copies every rate of the source location, of every type and family" do
      status, output, = cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")
      expect(status).to eq 0
      source = BillingRate.rates.select { it["location"] == "hetzner-fsn1" }
      rows = load_file
      expect(output).to eq "Wrote #{source.size} rates copied from hetzner-fsn1 (x1.0) to #{path}.\n#{described_class::RESTART_NOTE}\n"
      expect(rows.size).to eq source.size
      expect(rows.map { it["resource_type"] }.uniq.sort).to eq source.map { it["resource_type"] }.uniq.sort
      expect(rows.map { it.values_at("resource_type", "resource_family", "byoc", "unit_price", "billed_by", "active_from") })
        .to match_array(source.map { it.values_at("resource_type", "resource_family", "byoc", "unit_price", "billed_by", "active_from") })
      expect(rows.map { it["location"] }.uniq).to eq ["byoh-1"]
      expect(rows.map { it["id"] }).to all(match(/\A\h{8}-\h{4}-5\h{3}-[89ab]\h{3}-\h{12}\z/))
      expect(rows.map { it["id"] } & BillingRate.rates.map { it["id"] }).to be_empty
      expect(ByohPreflightWarnings.missing_rates("byoh-1")).to eq []

      audit = audit_rows.last
      expect(audit[:command]).to eq "byoh-location rates"
      expect(audit[:args]["yaml"]).to eq File.read(path)
      expect(audit[:args].to_h.except("yaml")).to eq("rates_from" => "hetzner-fsn1", "multiplier" => 1.0, "file" => path, "added" => source.size, "replaced" => 0)
    end

    it "lets --visible succeed right after rates in the same process" do
      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")[0]).to eq 0
      expect(cli("set", "--location", location.name, "--visible")[0]).to eq 0
      expect(location.reload.visible).to be true
    end

    it "adds nothing when run again, and dated rows when the price changes" do
      cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")
      first = load_file
      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")[1]).to start_with "#{path} already has every rate of hetzner-fsn1.\n"
      expect(load_file).to eq first

      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1", "--multiplier", "1.5")[0]).to eq 0
      rows = load_file
      added = rows.drop(first.size)
      # Free rates stay free, so only the priced ones get a new row.
      priced = first.group_by { it.values_at("resource_type", "resource_family", "byoc") }.values.count { |group| group.max_by { it["active_from"] }["unit_price"] > 0 }
      expect(added.size).to eq priced
      expect(priced).to be < first.size
      expect(added.map { it["active_from"] }.uniq.size).to eq 1
      expect(added.first["active_from"]).to be > Time.now - 60
      expect(added.map { it["id"] } & first.map { it["id"] }).to be_empty
      ipv4 = added.find { it["resource_type"] == "IPAddress" }
      expect(ipv4["unit_price"]).to eq((BillingRate.unit_price_from_resource_properties("IPAddress", "IPv4", "hetzner-fsn1") * 1.5).round(10))

      all = BillingRate.load_rates(BillingRate.rate_globs)
      expect(all.group_by { it.values_at("resource_type", "resource_family", "location", "byoc", "active_from") }.values).to all(have_attributes(size: 1))
    end

    it "copies a price the source dates ahead on its date, not now" do
      now = Time.utc(2026, 10, 12, 12)
      allow(Time).to receive(:now).and_return(now)
      past = Time.utc(2020, 1, 1)
      future = now + 30 * 86400
      write_rates(dir, "src", [rate("src", "VmVCpu", "standard", active_from: past), rate("src", "IPAddress", "IPv4", unit_price: 0.003, active_from: future)])
      expect(cli("rates", "--location", location.name, "--rates-from", "src")[0]).to eq 0
      expect(load_file.map { it.values_at("resource_type", "unit_price", "active_from") }).to eq [["VmVCpu", 0.001, past], ["IPAddress", 0.003, future]]

      # The source gains a dated VmVCpu price and an IPv4 price in force now.
      write_rates(dir, "src", [
        rate("src", "VmVCpu", "standard", active_from: past), rate("src", "VmVCpu", "standard", unit_price: 0.002, active_from: future),
        rate("src", "IPAddress", "IPv4", unit_price: 0.001, active_from: past), rate("src", "IPAddress", "IPv4", unit_price: 0.003, active_from: future),
      ])
      expect(cli("rates", "--location", location.name, "--rates-from", "src")[1]).to start_with "Wrote 2 rates copied from src (x1.0) to #{path}.\n"
      expect(load_file.drop(2).map { it.values_at("resource_type", "unit_price", "active_from") }).to eq [["VmVCpu", 0.002, future], ["IPAddress", 0.001, now]]
      expect(cli("rates", "--location", location.name, "--rates-from", "src")[1]).to start_with "#{path} already has every rate of src.\n"

      # A new multiplier changes the price now, and replaces the dated
      # rows that are not in force yet instead of tying with them.
      later = now + 60
      allow(Time).to receive(:now).and_return(later)
      expect(cli("rates", "--location", location.name, "--rates-from", "src", "--multiplier", "2")[1])
        .to start_with "Wrote 4 rates copied from src (x2.0) to #{path}, replacing 2 not yet in force.\n"
      rows = load_file
      expect(rows.size).to eq 6
      expect(rows.select { it["active_from"] == future }.map { it.values_at("resource_type", "unit_price") }).to contain_exactly(["VmVCpu", 0.004], ["IPAddress", 0.006])
      expect(rows.select { it["active_from"] == later }.map { it.values_at("resource_type", "unit_price") }).to contain_exactly(["VmVCpu", 0.002], ["IPAddress", 0.002])
      expect(audit_rows.last[:args]["replaced"]).to eq 2

      # Run again within the same second: the rows dated now have billed
      # nothing yet, so they are replaced too.
      expect(cli("rates", "--location", location.name, "--rates-from", "src", "--multiplier", "3")[1])
        .to start_with "Wrote 4 rates copied from src (x3.0) to #{path}, replacing 4 not yet in force.\n"
      rows = load_file
      expect(rows.group_by { it.values_at("resource_type", "active_from") }.values).to all(have_attributes(size: 1))
      expect(rows.select { it["active_from"] == later }.map { it.values_at("resource_type", "unit_price") }).to contain_exactly(["VmVCpu", 0.003], ["IPAddress", 0.003])
      expect(BillingRate.load_rates(BillingRate.rate_globs).map { it["id"] }.tally.values.max).to eq 1
    end

    it "reads an empty rate file as no rates" do
      File.write(path, "")
      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")[0]).to eq 0
      expect(load_file.size).to eq BillingRate.rates.count { it["location"] == "hetzner-fsn1" }
    end

    it "refuses bad input" do
      expect(cli("rates", "--location", location.name)[2]).to eq "! --rates-from is required\n"
      expect(cli("rates", "--location", location.name, "--rates-from", "nowhere")[2]).to end_with "! no billing rates for location nowhere\n"
      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1", "--multiplier", "0")[2]).to end_with "! --multiplier must be positive\n"
      allow(Config).to receive(:billing_rates_extra_dir).and_return(nil)
      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")[2]).to end_with "! BILLING_RATES_EXTRA_DIR is not set\n"
      allow(Config).to receive(:billing_rates_extra_dir).and_return("")
      expect(cli("rates", "--location", location.name, "--rates-from", "hetzner-fsn1")[2]).to end_with "! BILLING_RATES_EXTRA_DIR is not set\n"
      expect(File.exist?(path)).to be false
    end
  end

  describe "grant and revoke" do
    let(:location) { byoh_location("byoh-1") }
    let(:project) { Project.create(name: "p") }

    it "grants a project the location once complete rates exist, and revokes it" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      project.set_ff_visible_locations(["latitude-fra"])
      expect(cli("grant", "--location", location.name, "--project", project.ubid)[2]).to start_with "! location byoh-1 cannot be granted (run the rates command): no billing rate for VmVCpu/standard"

      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      2.times do
        expect(cli("grant", "--location", location.name, "--project", project.ubid)).to eq [0, "Project #{project.ubid} can now use location byoh-1.\n", ""]
      end
      expect(project.reload.get_ff_visible_locations).to eq ["latitude-fra", "byoh-1"]

      expect(cli("revoke", "--location", location.name, "--project", project.ubid)[0]).to eq 0
      expect(project.reload.get_ff_visible_locations).to eq ["latitude-fra"]
      expect(cli("revoke", "--location", location.name, "--project", project.ubid)[1]).to end_with "Project #{project.ubid} has no grant for location byoh-1.\n"
      expect(audit_rows.map { [it[:command], it[:args]["project"]] }).to eq [["byoh-location grant", project.ubid]] * 2 + [["byoh-location revoke", project.ubid]]
    end

    it "revokes from a project without feature flags" do
      expect(cli("revoke", "--location", location.name, "--project", project.ubid)[0]).to eq 0
    end

    it "grants a project without feature flags" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      expect(cli("grant", "--location", location.name, "--project", project.ubid)[0]).to eq 0
      expect(project.reload.get_ff_visible_locations).to eq ["byoh-1"]
    end

    it "refuses a missing or unknown project" do
      expect(cli("grant", "--location", location.name)[2]).to eq "! --project is required\n"
      expect(cli("grant", "--location", location.name, "--project", "nope")[2]).to end_with "! no project nope\n"
      expect(cli("grant", "--location", location.name, "--project", "pj#{"a" * 24}")[2]).to end_with "! no project pj#{"a" * 24}\n"
    end
  end

  describe "delete" do
    let(:location) { byoh_location("byoh-1") }

    it "deletes an empty location through its strand and keeps the rate file" do
      Strand.create_with_id(location, prog: "LocationNexus", label: "wait")
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      write_rates(dir, "byoh-1", full_rates("byoh-1"))
      status, output, = cli("delete", "--location", location.name)
      expect(status).to eq 0
      expect(output).to eq "Location byoh-1 will be deleted by its strand.\nThe rate file #{dir}/byoh-1.yml is kept: old invoices may refer to its rates.\n"
      expect(Semaphore.where(strand_id: location.id, name: "destroy").count).to eq 1
      expect(audit_rows.last[:command]).to eq "byoh-location delete"
    end

    it "does not mention a rate file without an overlay directory" do
      Strand.create_with_id(location, prog: "LocationNexus", label: "wait")
      expect(cli("delete", "--location", location.name)[1]).to eq "Location byoh-1 will be deleted by its strand.\n"
    end

    it "does not mention a rate file that was never written" do
      Strand.create_with_id(location, prog: "LocationNexus", label: "wait")
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      expect(cli("delete", "--location", location.name)[1]).to eq "Location byoh-1 will be deleted by its strand.\n"
    end

    it "refuses while projects have grants or rows use the location" do
      project = Project.create(name: "p")
      project.set_ff_visible_locations(["byoh-1"])
      expect(cli("delete", "--location", location.name)[2]).to eq "! revoke the grants first: #{project.ubid}\n"

      project.set_ff_visible_locations([])
      create_vm_host(location_id: location.id)
      LocationAz.create(location_id: location.id, az: "a")
      expect(cli("delete", "--location", location.name)[2]).to end_with "! location byoh-1 is still used by 1 vm_host\n"
      expect(Semaphore.where(strand_id: location.id).count).to eq 0
    end
  end
end
