# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "zlib"
require "digest"

RSpec.describe ByohLocationCli do
  let(:random) { class_double(SecureRandom) }
  let(:dir) { Dir.mktmpdir }
  let(:fetcher) { instance_double(ByohArtifactFetch) }

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, random:, fetcher:).run(argv)
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
      expect(output).to eq "Created location byoh-aws-aps1 (#{location.ubid}), hidden.\n#{described_class::RESTART_NOTE}\n" \
        "Next: ubicloud-admin host add --site byoh-aws-aps1 --ssh USER@HOST --ssh-key KEY --pool-file pools.yaml (bin/byoh-host add takes the same options)\n"
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

  describe "add (ubicloud-admin site add)" do
    let(:project) { Project.create(name: "p") }

    it "creates the location named by its argument, with the site add spellings" do
      expect(random).to receive(:random_bytes).and_return("\x01\x02\x03\x04\x05".b)
      status, output, error = cli("add", "byoh-aws-aps1", "--display", "AWS Mumbai (BYOH)", "--display-name", "aws-aps1",
        "--dns", "10.80.0.1", "--postgres", "no", "--mgmt", "direct", "--cp-reach", "onhost")
      expect(status).to eq 0
      expect(error).to start_with "warning: BILLING_RATES_EXTRA_DIR is unset"
      location = Location.first(name: "byoh-aws-aps1")
      expect(location.values.slice(:display_name, :ui_name)).to eq(display_name: "aws-aps1", ui_name: "AWS Mumbai (BYOH)")
      # --dns is OptionParser's unique prefix of --dns-servers.
      expect(location.byoh_network.to_h).to include("dns_servers" => ["10.80.0.1"], "cp_reach" => "onhost")
      expect(output).to end_with "Next: ubicloud-admin host add --site byoh-aws-aps1 --ssh USER@HOST --ssh-key KEY --pool-file pools.yaml (bin/byoh-host add takes the same options)\n"
    end

    it "grants projects after copying the rates" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      expect(random).to receive(:random_bytes).and_return("\x01\x02\x03\x04\x05".b)
      status, output, error = cli("add", "byoh-1", "--rates-from", "hetzner-fsn1", "--grant", project.ubid, "--grant", project.ubid)
      expect([status, error]).to eq [0, ""]
      expect(output).to include "Project #{project.ubid} can now use location byoh-1."
      expect(project.reload.get_ff_visible_locations).to eq ["byoh-1"]
      expect(audit_rows.map { it[:command] }).to eq ["byoh-location create", "byoh-location rates", "byoh-location grant"]
    end

    it "refuses a grant before creating anything" do
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      expect(cli("add", "byoh-1", "--grant", "nope")).to eq [1, "", "! no project nope\n"]
      expect(cli("add", "byoh-1", "--grant", project.ubid)[2]).to start_with "! location byoh-1 cannot be granted: no billing rate for VmVCpu/standard"
      expect(Location.where(name: "byoh-1").count).to eq 0
      expect(audit_rows).to be_empty
    end

    it "refuses the choices that come later with exit status 2" do
      {
        [] => "add needs a location name: add NAME [options]",
        ["--name", "byoh-1"] => "add needs a location name: add NAME [options]",
        ["byoh-1", "--postgres", "yes"] => "--postgres yes is UNVERIFIED: Location.postgres_locations excludes BYOH locations (ROADMAP §8.2); pass --postgres no",
        ["byoh-1", "--postgres", "maybe"] => "--postgres takes no or yes, not maybe",
        ["byoh-1", "--mgmt", "wireguard"] => "--mgmt wireguard is available in M8 (the management overlay); M4 supports only --mgmt direct, the operator's own route or VPN",
        ["byoh-1", "--cp-reach", "mgmt"] => "--cp-reach mgmt is available in M8 (the management overlay); use onhost or public",
        ["byoh-1", "--name", "byoh-2"] => "add takes the location name as its argument (add byoh-1), not --name byoh-2",
        ["byoh-1", "--na=byoh-2"] => "add takes the location name as its argument (add byoh-1), not --name byoh-2",
      }.each do |args, message|
        expect(cli("add", *args)).to eq [2, "", "! #{message}\n"]
      end
      expect(Location.where(name: %w[byoh-1 byoh-2]).count).to eq 0
    end

    it "prints the options of create for add --help" do
      expect { cli("add", "--help") }.to output(/\AUsage: bin\/byoh-location add NAME \[options\].*--display TEXT.*--grant PROJECT.*--postgres CHOICE.*--mgmt MODE/m).to_stdout
        .and raise_error(SystemExit) { expect(it.status).to eq 0 }
      expect(Location.where(provider: HostProvider::GENERIC_PROVIDER_NAME).count).to eq 0
    end

    it "says that ubicloud-admin restarts the services when it runs the tool" do
      ENV["UBICLOUD_ADMIN_RESTARTS"] = "1"
      expect(described_class.new.instance_variable_get(:@restart_note)).to eq described_class::ADMIN_RESTART_NOTE
    ensure
      ENV.delete("UBICLOUD_ADMIN_RESTARTS")
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
          Virt tiers    kvm
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

    it "reapplies changed egress NAT settings to the hosts past prep" do
      host = create_vm_host(location_id: location.id)
      early = create_vm_host(location_id: location.id, allocation_state: "unprepared")
      Strand.create_with_id(early, prog: "Vm::HostNexus", label: "bootstrap_rhizome")
      expect(cli("set", "--location", location.name, "--guest-mtu", "1500")[1]).to eq "Updated location byoh-1.\n"
      expect(Strand.where(prog: "SetupByohEgressNat").count).to eq 0
      output = cli("set", "--location", location.name, "--egress-smtp")[1]
      strand = Strand.first(prog: "SetupByohEgressNat")
      expect(output).to eq "Updated location byoh-1.\nStarted #{strand.ubid} to install the new egress NAT settings on host #{host.ubid}.\n"
      expect([Strand.where(prog: "SetupByohEgressNat").count, strand.stack]).to eq [1, [{"subject_id" => host.id}]]
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

    it "takes the location name alone and refuses --cp-reach mgmt" do
      location = byoh_location("byoh-1")
      expect(cli("set", "byoh-1", "--cp-reach", "mgmt")).to eq [2, "", "! --cp-reach mgmt is available in M8 (the management overlay); use onhost or public\n"]
      # Not the prefix of --mgmt-allow.
      expect(cli("set", "byoh-1", "--mgmt", "wireguard")).to eq [2, "", "! --mgmt wireguard is available in M8 (the management overlay); M4 supports only --mgmt direct, the operator's own route or VPN\n"]
      expect(cli("set", "byoh-1", "--mgmt", "direct")[0]).to eq 0
      expect(cli("set", "byoh-1", "--cp-reach", "public")[0]).to eq 0
      expect(location.reload.byoh_network["cp_reach"]).to eq "public"
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

  describe "virtualization tiers" do
    let(:location) { byoh_location("byoh-1") }
    let(:path) { File.join(dir, "byoh-1.yml") }

    before { allow(Config).to receive(:billing_rates_extra_dir).and_return(dir) }

    def tier_rates(family = "container")
      %w[VmVCpu VmStorage].map { rate("byoh-1", it, family) }
    end

    def project_granted(name)
      Project.create(name:).tap { it.set_ff_visible_locations(["byoh-1"]) }
    end

    it "refuses a tier this control plane cannot run yet" do
      ship_virt_tiers("container", "emulated")
      expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,pvm", "--accept", "pvm")[2])
        .to eq "! pvm is not available yet: this control plane's rhizome cannot run pvm hosts (docs/byoh/NO_KVM.md section 11)\n"
      expect(location.reload.byoh_virt).to be_nil
    end

    context "with shipped tiers" do
      before { ship_virt_tiers("container", "emulated") }

      it "offers a tier only with its acknowledgement and rates" do
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,container")[2]).to start_with "! container must be acknowledged: add --accept container (System container"
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,container", "--accept", "container")[2])
          .to start_with "! container has no VmVCpu and VmStorage rate in byoh-1; run: bin/byoh-location rates --location byoh-1 --family container --from standard --multiplier X"

        write_rates(dir, "byoh-1", full_rates("byoh-1") + tier_rates)
        status, output, = cli("set", "--location", location.name, "--virt-tiers", "kvm,container", "--accept", "container")
        expect(status).to eq 0
        expect(output).to start_with "Updated location byoh-1.\n"
        expect(location.reload.byoh_virt.to_h).to eq("tiers" => %w[kvm container], "acks" => {"container" => []})
        expect(audit_rows.last[:args]["byoh_virt"]).to eq("tiers" => %w[kvm container], "acks" => {"container" => []})
        expect(cli("show", "--location", location.name)[1]).to include "Virt tiers    kvm, container (L3, experimental)\n"
        expect(cli("set", "--location", location.name, "--unaccept", "pvm:multitenant")[0]).to eq 0
        expect(location.reload.byoh_virt["acks"]).to eq("container" => [])

        expect(cli("set", "--location", location.name, "--accept", "container:multitenant")[2])
          .to eq "! container:multitenant is not available yet: nothing checks container hosts for what sharing them between projects needs (docs/byoh/NO_KVM.md section 6.5), so container stays single-project\n"
        expect(location.reload.byoh_virt["acks"]).to eq("container" => [])
        check_virt_multitenant("container")
        expect(cli("set", "--location", location.name, "--accept", "container:multitenant", "--accept", "container:guest-firewall")[0]).to eq 0
        expect(cli("show", "--location", location.name)[1]).to include "Virt tiers    kvm, container (L3, experimental) [multitenant, guest-firewall]\n"
        expect(cli("set", "--location", location.name, "--unaccept", "container:guest-firewall")[0]).to eq 0
        expect(location.reload.byoh_virt["acks"]).to eq("container" => ["multitenant"])
        expect(cli("set", "--location", location.name, "--unaccept", "container")[2]).to start_with "! container must be acknowledged"
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm", "--unaccept", "container")[0]).to eq 0
        expect(location.reload.byoh_virt.to_h).to eq("tiers" => ["kvm"], "acks" => {})
      end

      it "refuses unknown tiers and options" do
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,tcg")[2]).to eq "! unknown tier tcg; expected kvm, container, pvm, emulated\n"
        expect(cli("set", "--location", location.name, "--virt-tiers", "")[2]).to eq "! --virt-tiers needs at least one tier\n"
        expect(cli("set", "--location", location.name, "--accept", "kvm")[2]).to eq "! cannot acknowledge kvm: expected one of container, pvm, emulated\n"
        expect(cli("set", "--location", location.name, "--accept", "emulated:guest-firewall")[2]).to eq "! emulated has no options\n"
        expect(cli("set", "--location", location.name, "--accept", "emulated:multitenant")[2]).to eq "! emulated has no options\n"
        expect(cli("set", "--location", location.name, "--accept", "pvm:guest-firewall")[2]).to eq "! pvm has no option guest-firewall; expected one of multitenant\n"
      end

      it "keeps a tier while hosts are registered on it" do
        write_rates(dir, "byoh-1", full_rates("byoh-1") + tier_rates("emulated"))
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,emulated", "--accept", "emulated")[0]).to eq 0
        create_byoh_vm_host(location, virt_tier: "emulated", family: "emulated")
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm")[2]).to eq "! emulated has 1 hosts in byoh-1; destroy them before dropping the tier\n"
      end

      it "keeps single-project tiers to one project" do
        write_rates(dir, "byoh-1", full_rates("byoh-1") + tier_rates)
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,container", "--accept", "container")[0]).to eq 0
        expect(cli("set", "--location", location.name, "--visible")[2])
          .to start_with "! location byoh-1 offers container to one project only, so it cannot be visible"
        first = Project.create(name: "first")
        second = Project.create(name: "second")
        expect(cli("grant", "--location", location.name, "--project", first.ubid)[0]).to eq 0
        expect(cli("grant", "--location", location.name, "--project", first.ubid)[0]).to eq 0
        expect(cli("grant", "--location", location.name, "--project", second.ubid)[2])
          .to start_with "! location byoh-1 offers container to one project only, and is granted to #{first.ubid}; revoke first"

        # A multitenant ack stored without its host checks lifts nothing.
        location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container], "acks" => {"container" => ["multitenant"]}}))
        expect(cli("grant", "--location", location.name, "--project", second.ubid)[2])
          .to start_with "! location byoh-1 offers container to one project only, and is granted to #{first.ubid}; revoke first"

        check_virt_multitenant("container")
        expect(cli("set", "--location", location.name, "--accept", "container:multitenant")[0]).to eq 0
        expect(cli("grant", "--location", location.name, "--project", second.ubid)[0]).to eq 0
        expect(cli("set", "--location", location.name, "--unaccept", "container:multitenant")[2])
          .to eq "! location byoh-1 offers container to one project only, but is granted to #{[first, second].sort_by(&:id).map(&:ubid).join(", ")}\n"
        expect(cli("set", "--location", location.name, "--visible")[0]).to eq 0
        expect(cli("set", "--location", location.name, "--no-visible")[0]).to eq 0
      end

      it "refuses a grant on a visible location with a single-project tier" do
        write_rates(dir, "byoh-1", full_rates("byoh-1") + tier_rates)
        location.update(visible: true, byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container], "acks" => {"container" => []}}))
        expect(cli("grant", "--location", location.name, "--project", Project.create(name: "p").ubid)[2])
          .to start_with "! location byoh-1 offers container to one project only, and is visible to every project"
      end
    end

    describe "PVM kernel pins" do
      # What cocoonstack/pvm v0.1.0's guest config has: the virtio
      # console, no 8250 serial driver.
      let(:config) { ByohPvmPolicy::REQUIRED_GUEST_CONFIG.map { "CONFIG_#{it}=y\n" }.join + "CONFIG_VIRTIO_CONSOLE=y\n" }
      let(:vmlinux) { "\x7FELF".b + "IKCFG_ST".b + Zlib.gzip(config) + "IKCFG_ED".b }
      let(:files) { {"https://example.com/h.deb" => "host kernel package", "https://example.com/vmlinux" => vmlinux, "https://example.com/config" => config} }
      let(:fetched) { [] }
      let(:curl) { {} }
      let(:fetcher) do
        ByohArtifactFetch.new(max_bytes: 1 << 20, runner: lambda { |*argv|
          fetched << argv.last
          code, out = curl[argv.last]
          File.binwrite(argv[argv.index("-o") + 1], files.fetch(argv.last)) unless code
          [out.to_s, instance_double(Process::Status, success?: code.nil?, exitstatus: code || 0)]
        })
      end

      def sha(url) = Digest::SHA256.hexdigest(files.fetch(url))

      def pin_args(deb: "https://example.com/h.deb", kernel: "https://example.com/vmlinux", deb_sha: sha(deb), kernel_sha: sha(kernel))
        ["--pvm-host-deb", deb, "--pvm-host-deb-sha256", deb_sha, "--pvm-guest-kernel", kernel, "--pvm-guest-kernel-sha256", kernel_sha]
      end

      def pins
        location.reload.byoh_virt&.[]("pvm_kernel")
      end

      it "verifies the pins by downloading them before storing anything" do
        status, output, = cli("set", "--location", location.name, *pin_args)
        expect(status).to eq 0
        expect(fetched).to eq ["https://example.com/h.deb", "https://example.com/vmlinux"]
        expect(output).to eq "Downloaded the changed PVM pins; each matches its sha256.\n" \
          "The guest kernel config has what PVM VMs need; their console is hvc0.\n" \
          "Updated location byoh-1.\n#{ByohPvmPolicy::ACK}\n"
        expected = {
          "host_deb" => {"url" => "https://example.com/h.deb", "sha256" => sha("https://example.com/h.deb")},
          "guest_kernel" => {"url" => "https://example.com/vmlinux", "sha256" => sha("https://example.com/vmlinux")},
          "guest_unchecked" => false, "config_checked" => true, "guest_console" => "hvc0",
        }
        expect(location.reload.byoh_virt.to_h).to eq("tiers" => ["kvm"], "acks" => {}, "pvm_kernel" => expected)
        expect(JSON.parse(audit_rows.last[:args].to_json).slice("byoh_virt", "pvm_pins")).to eq("byoh_virt" => {"tiers" => ["kvm"], "acks" => {}, "pvm_kernel" => expected}, "pvm_pins" => {"verify_download" => true, "ack" => ByohPvmPolicy::ACK})
        expect(cli("show", "--location", location.name)[1]).to include "Virt tiers    kvm\nPVM pins\n  host kernel package: https://example.com/h.deb sha256 #{expected["host_deb"]["sha256"]}\n" \
          "  guest kernel: https://example.com/vmlinux sha256 #{expected["guest_kernel"]["sha256"]}\n  guest kernel config: none pinned\n  config checked: yes, console hvc0\nProfile\n"

        # The same pins again change nothing and download nothing; other
        # policy changes keep them.
        fetched.clear
        expect(cli("set", "--location", location.name, *pin_args)[1]).to eq "Updated location byoh-1.\n"
        expect(fetched).to eq []
        ship_virt_tiers("emulated")
        write_rates(dir, "byoh-1", full_rates("byoh-1") + tier_rates("emulated"))
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,emulated", "--accept", "emulated")[0]).to eq 0
        expect(pins).to eq expected
        expect(audit_rows.last[:args]).not_to have_key("pvm_pins")
      end

      it "refuses a wrong sha256, an http redirect or an oversized file, changing nothing" do
        refusals = {
          ["--pvm-guest-kernel-sha256", "b" * 64] => "! https://example.com/vmlinux has sha256 #{sha("https://example.com/vmlinux")}, not the pinned #{"b" * 64}\n",
        }
        refusals.each do |(flag, value), message|
          args = pin_args
          args[args.index(flag) + 1] = value
          expect(cli("set", "--location", location.name, *args)).to eq [1, "", message]
        end
        curl["https://example.com/h.deb"] = [1, "curl: (1) Protocol \"http\" not supported"]
        expect(cli("set", "--location", location.name, *pin_args)[2]).to include "(curl exit 1; an http:// URL or redirect is refused, only https is fetched)"
        curl.clear
        files["https://example.com/h.deb"] = "x" * ((1 << 20) + 1)
        expect(cli("set", "--location", location.name, *pin_args)[2]).to eq "! https://example.com/h.deb is larger than the 1048576-byte cap\n"
        expect(location.reload.byoh_virt).to be_nil
        expect(audit_rows).to eq []
        expect(Dir.glob(File.join(Dir.tmpdir, "byoh-pvm-pins-*"))).to eq []
      end

      it "refuses incomplete or unsafe pins before downloading" do
        expect(cli("set", "--location", location.name, "--pvm-host-deb", "https://example.com/h.deb")[2]).to eq "! --pvm-host-deb and --pvm-host-deb-sha256 go together\n"
        expect(cli("set", "--location", location.name, "--pvm-guest-config-sha256", "c" * 64)[2]).to eq "! --pvm-guest-config and --pvm-guest-config-sha256 go together\n"
        expect(cli("set", "--location", location.name, *pin_args.first(4))[2]).to eq "! pin the PVM guest kernel: --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX\n"
        expect(cli("set", "--location", location.name, *pin_args(deb: "http://example.com/h.deb", deb_sha: "a" * 64))[2]).to eq "! the PVM host kernel package URL http://example.com/h.deb is not https\n"
        expect(cli("set", "--location", location.name, *pin_args(deb: "HTTPS://example.com/h.deb", deb_sha: "a" * 64), "--no-verify-download")).to eq [1, "", "! the PVM host kernel package URL HTTPS://example.com/h.deb is not https\n"]
        expect(cli("set", "--location", location.name, *pin_args, "--pvm-guest-config", "https://example.com/config", "--pvm-guest-config-sha256", sha("https://example.com/config"), "--pvm-guest-unchecked")[2])
          .to eq "! pass either --pvm-guest-config or --pvm-guest-unchecked, not both\n"
        expect(fetched).to eq []
        expect(location.reload.byoh_virt).to be_nil
      end

      it "stores the drivers the operator vouches for without downloading anything, and clears them" do
        expect(cli("set", "--location", location.name, *pin_args)[0]).to eq 0
        fetched.clear
        status, output, = cli("set", "--location", location.name, "--pvm-unchecked-drivers", "hv_storvsc,hv_netvsc")
        expect([status, output]).to eq [0, "Updated location byoh-1.\n#{ByohPvmPolicy::ACK}\n"]
        expect(fetched).to eq []
        expect(pins["unchecked_drivers"]).to eq %w[hv_storvsc hv_netvsc]
        expect(JSON.parse(audit_rows.last[:args].to_json).dig("byoh_virt", "pvm_kernel", "unchecked_drivers")).to eq %w[hv_storvsc hv_netvsc]
        expect(cli("show", "--location", location.name)[1]).to include "  unchecked host drivers (operator vouched): hv_storvsc hv_netvsc\n"
        expect(cli("set", "--location", location.name, "--pvm-unchecked-drivers", "bad name")).to eq [1, "", "! --pvm-unchecked-drivers takes sysfs driver names, such as hv_storvsc,hv_netvsc\n"]
        expect(cli("set", "--location", location.name, "--pvm-unchecked-drivers", "")[0]).to eq 0
        expect(pins).not_to have_key("unchecked_drivers")
        expect(fetched).to eq []
      end

      it "refuses a guest kernel that is not an ELF vmlinux, even with a pinned config" do
        files["https://example.com/vmlinux"] = "MZ bzImage".b
        args = [*pin_args, "--pvm-guest-config", "https://example.com/config", "--pvm-guest-config-sha256", sha("https://example.com/config")]
        expect(cli("set", "--location", location.name, *args)[2]).to eq "! the guest kernel https://example.com/vmlinux is not an ELF vmlinux (cloud-hypervisor boots it directly; a bzImage will not do)\n"
        expect(location.reload.byoh_virt).to be_nil
      end

      it "takes a guest kernel without a readable config only when accepted unchecked" do
        files["https://example.com/vmlinux"] = "\x7FELF no config".b
        expect(cli("set", "--location", location.name, *pin_args)[2]).to start_with "! the guest kernel has no embedded config (CONFIG_IKCONFIG)"
        expect(location.reload.byoh_virt).to be_nil
        status, output, = cli("set", "--location", location.name, *pin_args, "--pvm-guest-unchecked")
        expect([status, output]).to eq [0, "Downloaded the changed PVM pins; each matches its sha256.\nThe guest kernel config was not checked (--pvm-guest-unchecked).\nUpdated location byoh-1.\n#{ByohPvmPolicy::ACK}\n"]
        expect(pins).to include("guest_unchecked" => true, "config_checked" => false)

        # A pinned config replaces the acknowledgement.
        fetched.clear
        expect(cli("set", "--location", location.name, "--pvm-guest-config", "https://example.com/config", "--pvm-guest-config-sha256", sha("https://example.com/config"))[0]).to eq 0
        expect(fetched).to eq ["https://example.com/config"]
        expect(pins).to include("guest_config" => {"url" => "https://example.com/config", "sha256" => sha("https://example.com/config")}, "config_checked" => true, "guest_console" => "hvc0")
        expect(pins).not_to have_key("guest_unchecked")
      end

      it "stores the pins unverified with --no-verify-download, and records that" do
        status, output, = cli("set", "--location", location.name, *pin_args(deb_sha: "a" * 64, kernel_sha: "b" * 64), "--no-verify-download")
        expect(status).to eq 0
        expect(output).to start_with "Not downloading the PVM pins (--no-verify-download): each host checks them when it downloads them.\nUpdated location byoh-1.\n"
        expect(fetched).to eq []
        expect(pins).to include("host_deb" => {"url" => "https://example.com/h.deb", "sha256" => "a" * 64}, "guest_unchecked" => false, "config_checked" => false)
        expect(audit_rows.last[:args]["pvm_pins"]).to eq("verify_download" => false, "ack" => ByohPvmPolicy::ACK)
        # A host package alone leaves the guest side as it was.
        expect(cli("set", "--location", location.name, "--pvm-host-deb", "https://example.com/h2.deb", "--pvm-host-deb-sha256", "d" * 64, "--no-verify-download")[0]).to eq 0
        expect(pins).to include("host_deb" => {"url" => "https://example.com/h2.deb", "sha256" => "d" * 64}, "config_checked" => false)
      end

      it "offers pvm only with its pins" do
        ship_virt_tiers("pvm")
        write_rates(dir, "byoh-1", full_rates("byoh-1") + tier_rates("pvm"))
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,pvm", "--accept", "pvm")[2])
          .to eq "! pvm needs its kernel pins: add --pvm-host-deb URL --pvm-host-deb-sha256 HEX --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX (docs/byoh/NO_KVM.md section 6.7)\n"
        expect(location.reload.byoh_virt).to be_nil
        expect(cli("set", "--location", location.name, "--virt-tiers", "kvm,pvm", "--accept", "pvm", *pin_args)[0]).to eq 0
        expect(location.reload.byoh_virt.to_h).to include("tiers" => %w[kvm pvm], "acks" => {"pvm" => []})
        expect(cli("show", "--location", location.name)[1]).to include "Virt tiers    kvm, pvm (L4, experimental)\nPVM pins\n"
      end

      it "starts the new guest kernel's download on the pvm hosts past prep only" do
        expect(cli("set", "--location", location.name, *pin_args)[0]).to eq 0
        pvm = create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm")
        early = create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm", allocation_state: "unprepared")
        Strand.create_with_id(early, prog: "Vm::HostNexus", label: "bootstrap_rhizome")
        create_byoh_vm_host(location, virt_tier: "emulated", family: "emulated")
        create_byoh_vm_host(location)

        # A new host kernel package starts nothing.
        files["https://example.com/h2.deb"] = "newer package"
        expect(cli("set", "--location", location.name, "--pvm-host-deb", "https://example.com/h2.deb", "--pvm-host-deb-sha256", sha("https://example.com/h2.deb"))[1])
          .to eq "Downloaded the changed PVM pins; each matches its sha256.\nUpdated location byoh-1.\n#{ByohPvmPolicy::ACK}\n"
        expect(Strand.where(prog: "DownloadPvmGuestKernel").count).to eq 0

        files["https://example.com/vmlinux2"] = vmlinux + "newer".b
        output = cli("set", "--location", location.name, "--pvm-guest-kernel", "https://example.com/vmlinux2", "--pvm-guest-kernel-sha256", sha("https://example.com/vmlinux2"))[1]
        strand = Strand.first(prog: "DownloadPvmGuestKernel")
        expect(Strand.where(prog: "DownloadPvmGuestKernel").count).to eq 1
        expect(strand.stack).to eq [{"subject_id" => pvm.id, "pin" => {"guest_kernel" => {"url" => "https://example.com/vmlinux2", "sha256" => sha("https://example.com/vmlinux2")}, "guest_unchecked" => false}}]
        expect(output).to include "Started #{strand.ubid} to download the new PVM guest kernel on host #{pvm.ubid}; its VMs boot it from their next stop and start.\n"
      end

      describe "a new PVM host kernel pin" do
        it "names the hosts on another build and how each moves to the new pin" do
          expect(cli("set", "--location", location.name, *pin_args)[0]).to eq 0
          old_sha = sha("https://example.com/h.deb")
          files["https://example.com/h2.deb"] = "newer package"
          new_sha = sha("https://example.com/h2.deb")
          hosts = %w[committed install_pending uninstalled committed committed].map { create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm") }
          hosts.zip(%w[committed install_pending uninstalled committed committed], [old_sha, old_sha, old_sha, new_sha, old_sha], [true, true, true, true, false]).each do |host, state, deb, install|
            ByohPvmHost.create(vm_host_id: host.id, state:, install:, host_deb_sha256: deb)
          end
          ByohPvmHost.create(vm_host_id: create_byoh_vm_host(create_byoh_location(name: "byoh-other", ui_name: "Other"), virt_tier: "pvm", family: "pvm").id, state: "committed", install: true, host_deb_sha256: old_sha)
          lines = cli("set", "--location", location.name, "--pvm-host-deb", "https://example.com/h2.deb", "--pvm-host-deb-sha256", new_sha)[1].lines.grep(/\AHost /)
          expect(lines).to eq [
            [hosts[0], "Host #{hosts[0].ubid} (PVM kernel committed) has host-deb sha256 #{old_sha}, not the new pin: move it with bin/byoh-virt pvm upgrade --host #{hosts[0].ubid} --accept-host-deb #{new_sha} once it has no VMs (UNVERIFIED on a real host).\n"],
            [hosts[1], "Host #{hosts[1].ubid} (PVM kernel install_pending) has host-deb sha256 #{old_sha}, not the new pin: its install stays on the build it acknowledged; see bin/byoh-virt show --host #{hosts[1].ubid}.\n"],
          ].sort_by { it[0].id }.map(&:last)

          # A guest kernel change alone names no host.
          files["https://example.com/vmlinux2"] = vmlinux + "newer".b
          output = cli("set", "--location", location.name, "--pvm-guest-kernel", "https://example.com/vmlinux2", "--pvm-guest-kernel-sha256", sha("https://example.com/vmlinux2"))[1]
          expect(output).not_to include "Host "
        end
      end
    end

    describe "rates --family" do
      it "prices a tier from the location's own rates" do
        write_rates(dir, "byoh-1", full_rates("byoh-1"))
        status, output, = cli("rates", "--location", location.name, "--family", "container", "--from", "standard", "--multiplier", "0.5")
        expect(status).to eq 0
        expect(output).to start_with "Wrote 2 rates copied from byoh-1/standard (x0.5) to #{path}."
        rows = YAML.load_file(path, permitted_classes: [Time]).select { it["resource_family"] == "container" }
        expect(rows.map { it.values_at("resource_type", "unit_price", "location") }).to contain_exactly(["VmVCpu", 0.0005, "byoh-1"], ["VmStorage", 0.0005, "byoh-1"])
        expect(cli("rates", "--location", location.name, "--family", "container", "--from", "standard", "--multiplier", "0.5")[1]).to start_with "#{path} already has every rate of byoh-1/standard."
      end

      it "refuses what it cannot price" do
        expect(cli("rates", "--location", location.name, "--family", "container")[2]).to eq "! --family and --from go together, without --rates-from\n"
        expect(cli("rates", "--location", location.name, "--from", "standard", "--family", "container", "--rates-from", "hetzner-fsn1")[2]).to eq "! --family and --from go together, without --rates-from\n"
        expect(cli("rates", "--location", location.name, "--family", "gpu", "--from", "standard", "--multiplier", "1")[2]).to eq "! --family must be one of container, pvm, emulated\n"
        expect(cli("rates", "--location", location.name, "--family", "container", "--from", "standard")[2]).to eq "! --multiplier is required with --family: price the tier deliberately\n"
        write_rates(dir, "byoh-1", [rate("byoh-1", "IPAddress", "IPv4")])
        expect(cli("rates", "--location", location.name, "--family", "container", "--from", "standard", "--multiplier", "1")[2])
          .to eq "! location byoh-1 has no standard rates to copy; copy them first with --rates-from\n"
      end
    end
  end
end
