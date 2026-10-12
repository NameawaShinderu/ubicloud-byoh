# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohHostCli do
  let(:dir) { Dir.mktmpdir }
  let(:byoh_1) { byoh_location("byoh-1") }
  let(:byoh_2) { byoh_location("byoh-2") }
  let(:fsn1) { Location[Location::HETZNER_FSN1_ID] }
  # A generic host still in hetzner-fsn1, as registered before BYOH
  # locations existed.
  let(:legacy_host) { generic_host(byoh_1).tap { it.update(location_id: Location::HETZNER_FSN1_ID) } }

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:).run(argv)
    [status, out.string, err.string]
  end

  def byoh_location(name)
    Location.create(name:, display_name: name, ui_name: name, visible: false, provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {})
  end

  def generic_host(location)
    Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
      provider_config: {"main_ip4" => "203.0.113.42", "location_label" => location.name, "routed_networks" => [{"cidr" => "fd00:feed::/64"}]}).subject
  end

  def audit_rows
    DB[:byoh_operator_action].order(:created_at).all
  end

  after { FileUtils.rm_rf(dir) }

  describe "#run" do
    it "prints the usage without a command" do
      expect(cli).to eq [0, described_class::USAGE, ""]
      expect(cli("help")[0]).to eq 0
    end

    it "refuses an unknown command" do
      status, _, err = cli("frobnicate")
      expect(status).to eq 1
      expect(err).to start_with "! unknown command frobnicate\nUsage:"
    end

    it "refuses unknown options and extra arguments" do
      expect(cli("export-audit", "--frob")).to eq [1, "", "! invalid option: --frob\n"]
      expect(cli("export-audit", "extra")).to eq [1, "", "! unexpected argument extra\n"]
    end
  end

  describe "move-location" do
    it "moves an empty generic host into a BYOH location" do
      host = legacy_host
      byoh_2
      status, out, err = cli("move-location", "--host", host.ubid, "--location", "byoh-2", "--empty-only")
      expect([status, err]).to eq [0, ""]
      expect(out).to eq "Moved host #{host.ubid} from location hetzner-fsn1 to byoh-2.\n"
      host.reload
      expect(host.location_id).to eq byoh_2.id
      expect(host.byoh?).to be true
      expect(host.provider.config["location_label"]).to eq "byoh-2"
      expect(audit_rows.map { it.values_at(:command, :target_id, :result) }).to eq [["move-location", host.id, "ok"]]
      expect(audit_rows.first[:args].to_h).to eq("from" => "hetzner-fsn1", "to" => "byoh-2")
    end

    it "moves a host between BYOH locations" do
      host = generic_host(byoh_1)
      expect(cli("move-location", "--host", host.ubid, "--location", byoh_2.ubid, "--empty-only")[0]).to eq 0
      expect(host.reload.location_id).to eq byoh_2.id
    end

    it "rolls a host back out of a BYOH location" do
      host = generic_host(byoh_1)
      status, out, _ = cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")
      expect(status).to eq 0
      expect(out).to eq "Moved host #{host.ubid} from location byoh-1 to hetzner-fsn1.\n"
      expect(host.reload.location_id).to eq Location::HETZNER_FSN1_ID
      expect(host.byoh?).to be false
      expect(host.provider.config["location_label"]).to eq "hetzner-fsn1"
      expect(audit_rows.map { it.values_at(:command, :result) }).to eq [["move-location-rollback", "ok"]]
    end

    it "requires --empty-only and exactly one target" do
      host = legacy_host
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1")).to eq [1, "", "! --empty-only is required: only hosts without VMs can be moved\n"]
      expect(cli("move-location", "--host", host.ubid, "--empty-only")).to eq [1, "", "! pass either --location or --rollback-to\n"]
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--rollback-to", "hetzner-fsn1", "--empty-only")[2]).to eq "! pass either --location or --rollback-to\n"
    end

    it "refuses a missing, unknown or non-generic host" do
      expect(cli("move-location", "--location", "byoh-1", "--empty-only")[2]).to eq "! --host is required\n"
      expect(cli("move-location", "--host", "nonsense", "--location", "byoh-1", "--empty-only")[2]).to eq "! no host nonsense\n"
      ubid = VmHost.generate_ubid.to_s
      expect(cli("move-location", "--host", ubid, "--location", "byoh-1", "--empty-only")[2]).to eq "! no host #{ubid}\n"
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only")[2]).to eq "! host #{host.ubid} is not a generic (BYOH) host\n"
    end

    it "refuses an unknown or non-BYOH target" do
      host = legacy_host
      expect(cli("move-location", "--host", host.ubid, "--location", "nowhere", "--empty-only")[2]).to eq "! no location nowhere\n"
      expect(cli("move-location", "--host", host.ubid, "--location", "hetzner-hel1", "--empty-only")[2]).to eq "! location hetzner-hel1 is not a BYOH location\n"
    end

    it "refuses a move to the current location" do
      host = generic_host(byoh_1)
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only")[2]).to eq "! host #{host.ubid} is already in location byoh-1\n"
    end

    it "refuses a host with VMs" do
      host = legacy_host
      create_vm(vm_host_id: host.id)
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only")).to eq [1, "", "! host #{host.ubid} has 1 VMs; destroy them first\n"]
      expect(host.reload.location_id).to eq Location::HETZNER_FSN1_ID
      expect(audit_rows).to eq []
    end

    it "refuses a rollback into a BYOH location or of a host outside one" do
      host = generic_host(byoh_1)
      expect(cli("move-location", "--host", host.ubid, "--rollback-to", byoh_2.name, "--empty-only")[2])
        .to eq "! location byoh-2 is a BYOH location; --rollback-to moves a host out of BYOH (use --location)\n"
      host.update(location_id: fsn1.id)
      expect(cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-hel1", "--empty-only")[2])
        .to eq "! host #{host.ubid} is not in a BYOH location; nothing to roll back\n"
    end
  end

  describe "setup-egress-nat" do
    it "refuses a host that is not a BYOH host" do
      host = legacy_host
      expect(cli("setup-egress-nat", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)\n"]
    end

    it "is not available yet" do
      host = generic_host(byoh_1)
      expect(cli("setup-egress-nat", "--host", host.ubid)[2]).to eq "! setup-egress-nat is not available yet: the host egress NAT is not part of this release\n"
    end
  end

  describe "export-audit" do
    def comment
      DB.get(Sequel.function(:obj_description, Sequel.cast("byoh_operator_action", :regclass), "pg_class"))
    end

    it "prints every row and records the newest one in the table comment" do
      first = ByohOperatorLog.record(command: "byoh-location create", target_id: nil, args: {name: "byoh-1"}, result: "ok")
      second = ByohOperatorLog.record(command: "register-byoh-host", target_id: nil, args: {}, result: "error: boom")
      status, out, err = cli("export-audit")
      expect([status, err]).to eq [0, ""]

      lines = out.lines.map { JSON.parse(it) }
      expect(lines.map { it.values_at("id", "command", "args", "result") }).to eq [
        [first, "byoh-location create", {"name" => "byoh-1"}, "ok"],
        [second, "register-byoh-host", {}, "error: boom"],
      ]
      newest = DB[:byoh_operator_action].max(:created_at)
      expect(lines.last["created_at"]).to eq newest.utc.iso8601(6)
      expect(comment).to eq "exported_at=#{newest.utc.iso8601(6)}"
      # The migration's down guard reads the comment as the export time.
      expect(DB[:byoh_operator_action].where { created_at > Sequel.cast(newest.utc.iso8601(6), :timestamptz) }.count).to eq 0
    end

    it "writes to a file" do
      ByohOperatorLog.record(command: "byoh-location create", target_id: nil, args: {}, result: "ok")
      path = File.join(dir, "audit.jsonl")
      status, out, err = cli("export-audit", "--out", path)
      expect([status, out]).to eq [0, ""]
      expect(err).to eq "Exported 1 operator actions to #{path}.\n"
      expect(File.read(path).lines.map { JSON.parse(it)["command"] }).to eq ["byoh-location create"]
    end

    it "records the export time when there are no rows" do
      expect(cli("export-audit")).to eq [0, "", ""]
      expect(comment).to match(/\Aexported_at=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/)
    end
  end
end
