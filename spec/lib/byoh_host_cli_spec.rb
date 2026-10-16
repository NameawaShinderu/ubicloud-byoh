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
  def cli(*argv, **)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, **).run(argv)
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

    it "hands add, preflight and watch to ByohHostAdd with its stand-ins" do
      status, out, = cli("add", "--help", runner: :fake)
      expect(status).to eq 0
      expect(out).to start_with "Usage: bin/byoh-host add"
      expect(cli("watch")).to eq [2, "", "! invalid argument: watch takes one host\n"]
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

    it "keeps a host in locations that offer its virtualization tier" do
      ship_virt_tiers("emulated")
      [byoh_1, byoh_2].each { it.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["emulated"], "acks" => {"emulated" => []}})) }
      host = Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: byoh_1.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME, virt_tier: "emulated",
        provider_config: {"main_ip4" => "203.0.113.42", "location_label" => "byoh-1", "routed_networks" => [{"cidr" => "fd00:feed::/64"}]}).subject
      host.update(allocation_state: "draining")
      expect(cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")[2])
        .to eq "! host #{host.ubid} has virt tier emulated, which only BYOH locations can hold; destroy and register it again instead\n"
      byoh_2.update(byoh_virt: nil)
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-2", "--empty-only")[2])
        .to eq "! location byoh-2 does not offer emulated hosts; see bin/byoh-location set --virt-tiers\n"
      expect(host.reload.location_id).to eq byoh_1.id
    end

    it "moves a host between BYOH locations" do
      host = generic_host(byoh_1)
      expect(cli("move-location", "--host", host.ubid, "--location", byoh_2.ubid, "--empty-only")[0]).to eq 0
      expect(host.reload.location_id).to eq byoh_2.id
    end

    it "rolls a host back out of a BYOH location" do
      host = generic_host(byoh_1)
      status, out, _ = cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")
      strand = Strand.first(prog: "SetupByohEgressNat")
      expect(status).to eq 0
      expect(out).to eq "Moved host #{host.ubid} from location byoh-1 to hetzner-fsn1.\n" \
        "Started #{strand.ubid} to remove the egress NAT table from host #{host.ubid}.\n"
      expect([strand.label, strand.stack]).to eq ["start", [{"subject_id" => host.id}]]
      expect(host.reload.location_id).to eq Location::HETZNER_FSN1_ID
      expect(host.byoh?).to be false
      expect(host.provider.config["location_label"]).to eq "hetzner-fsn1"
      expect(audit_rows.map { it.values_at(:command, :result) }).to eq [["move-location-rollback", "ok"]]
    end

    it "resets the host's IPv4 pools when rolling it back" do
      host = Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: byoh_1.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
        provider_config: {"main_ip4" => "203.0.113.42", "location_label" => "byoh-1",
                          "routed_networks" => [{"cidr" => "10.98.2.0/30", "delivery" => "fabric", "exposure" => "internal"}]}).subject
      Address.where(cidr: "10.98.2.0/30").update(delivery: "fabric", exposure: "internal")
      status, out, _ = cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")
      expect([status, out.lines[1]]).to eq [0, "Reset 1 IPv4 pools to routed and public, with nothing reserved and no external IPs.\n"]
      expect(Address.first(cidr: "10.98.2.0/30").values.values_at(:delivery, :exposure)).to eq ["routed", "public"]
      expect(host.provider.reload.config.values_at("routed_networks", "location_label")).to eq [[{"cidr" => "10.98.2.0/30"}], "hetzner-fsn1"]
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

    it "refuses a host that is accepting VMs" do
      host = legacy_host
      host.update(allocation_state: "accepting")
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only"))
        .to eq [1, "", "! host #{host.ubid} is accepting VMs; move it to draining first (admin \"Move to Draining\") so no VM is placed on it during the move\n"]
      expect(host.reload.location_id).to eq Location::HETZNER_FSN1_ID
    end

    it "reminds the operator to accept VMs again after moving a draining host" do
      host = legacy_host
      host.update(allocation_state: "draining")
      byoh_1
      status, out, err = cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only")
      install = Strand.first(prog: "SetupByohEgressNat")
      relearn = Strand.first(prog: "LearnPci")
      expect([status, out, err]).to eq [0,
        "Moved host #{host.ubid} from location hetzner-fsn1 to byoh-1.\n" \
        "Started #{install.ubid} to install the egress NAT table on host #{host.ubid}.\n" \
        "Started #{relearn.ubid} to relearn the GPUs of host #{host.ubid} under the BYOH vfio-pci rule.\n" \
        "The host is draining; set it to accepting in the admin UI when it should take VMs.\n", ""]
      expect([install.label, install.stack]).to eq ["start", [{"subject_id" => host.id}]]
      expect([relearn.label, relearn.stack]).to eq ["start", [{"subject_id" => host.id}]]
      expect(host.reload.allocation_state).to eq "draining"
      expect(cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")[1])
        .to eq "Moved host #{host.ubid} from location byoh-1 to hetzner-fsn1.\n" \
          "Started #{Strand.exclude(id: install.id).first(prog: "SetupByohEgressNat").ubid} to remove the egress NAT table from host #{host.ubid}.\n" \
          "The host is draining; set it to accepting in the admin UI when it should take VMs.\n"
      expect(Strand.where(prog: "LearnPci").count).to eq 1
    end

    it "installs the egress NAT table on an unprepared host that is past prep" do
      host = legacy_host
      byoh_1
      host.strand.update(label: "wait_prep")
      status, out, _ = cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only")
      strand = Strand.first(prog: "SetupByohEgressNat")
      expect([status, out]).to eq [0,
        "Moved host #{host.ubid} from location hetzner-fsn1 to byoh-1.\n" \
        "Started #{strand.ubid} to install the egress NAT table on host #{host.ubid}.\n" \
        "Started #{Strand.first(prog: "LearnPci").ubid} to relearn the GPUs of host #{host.ubid} under the BYOH vfio-pci rule.\n"]
    end

    it "counts a host whose HostNexus pushed a prog after prep as past prep" do
      host = legacy_host
      byoh_1
      host.strand.update(prog: "SetupHugepages", label: "start",
        stack: [{"subject_id" => host.id, "link" => ["Vm::HostNexus", "setup_hugepages"]}, *host.strand.stack])
      expect(described_class.past_prep?(VmHost[host.id])).to be true
      host.strand.update(prog: "BootstrapRhizome", label: "start",
        stack: [{"subject_id" => host.id, "link" => ["Vm::HostNexus", "bootstrap_rhizome"]}, *host.strand.stack.drop(1)])
      expect(described_class.past_prep?(VmHost[host.id])).to be false
    end

    it "leaves the egress NAT table to prep on a host that has not reached it" do
      host = legacy_host
      byoh_1
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-1", "--empty-only")[1]).to eq "Moved host #{host.ubid} from location hetzner-fsn1 to byoh-1.\n"
      expect(Strand.where(prog: ["SetupByohEgressNat", "LearnPci"]).count).to eq 0
    end

    it "refuses pools that overlap the target's overlay network or private subnets" do
      target = Location.create(name: "byoh-3", display_name: "byoh-3", ui_name: "byoh-3", visible: false,
        provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"overlay_ipv4_cidrs" => ["172.20.0.0/14"]})
      PrivateSubnet.create(name: "ps", location_id: target.id, net4: "10.7.0.0/26", net6: "fd10::/64", project_id: Project.create(name: "p").id)
      host = Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: byoh_1.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
        provider_config: {"main_ip4" => "203.0.113.42", "location_label" => "byoh-1",
                          "routed_networks" => [{"cidr" => "172.20.1.0/30", "exposure" => "internal"}, {"cidr" => "10.7.0.0/30", "exposure" => "internal"}]}).subject
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-3", "--empty-only")).to eq [1, "",
        "! host #{host.ubid} cannot move to byoh-3:\n" \
        "172.20.1.0/30 overlaps the location's overlay network 172.20.0.0/14\n" \
        "10.7.0.0/30 overlaps the private subnet 10.7.0.0/26 in this location\n"]
      expect(host.reload.location_id).to eq byoh_1.id
      expect(audit_rows).to eq []
    end

    it "notes an IPv6 network drawn outside the target's ula48" do
      Location.create(name: "byoh-3", display_name: "byoh-3", ui_name: "byoh-3", visible: false,
        provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd12:3456:789a::/48"})
      host = generic_host(byoh_1)
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-3", "--empty-only")[1])
        .to eq "Moved host #{host.ubid} from location byoh-1 to byoh-3.\n"

      host.update(net6: "fd99:1:2:3::/64")
      expect(cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")[0]).to eq 0
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-3", "--empty-only")[1])
        .to eq "Moved host #{host.ubid} from location hetzner-fsn1 to byoh-3.\n" \
          "  note: the host's IPv6 network fd99:1:2:3::/64 is outside byoh-3's ula48 fd12:3456:789a::/48; it keeps working, but re-register the host to draw one from fd12:3456:789a::/48\n"

      host.update(net6: "fd12:3456:789a:1::/64")
      expect(cli("move-location", "--host", host.ubid, "--rollback-to", "hetzner-fsn1", "--empty-only")[0]).to eq 0
      expect(cli("move-location", "--host", host.ubid, "--location", "byoh-3", "--empty-only")[1])
        .to eq "Moved host #{host.ubid} from location hetzner-fsn1 to byoh-3.\n"
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

  describe "relearn-device-ids" do
    let(:host) { generic_host(byoh_1) }

    def add_device(name, ids)
      StorageDevice.create(vm_host_id: host.id, name:, total_storage_gib: 100, available_storage_gib: 90, unix_device_list: ids)
    end

    # A stand-in for ByohDeviceIdentity.device_ids (frozen in frozen
    # specs) that checks it is asked about the host's storage paths.
    def relearn(result)
      lambda do |sshable, mounts|
        expect(sshable.id).to eq host.id
        expect(mounts).to eq result.keys
        result
      end
    end

    it "shows the new ids without --yes and writes nothing" do
      add_device("DEFAULT", [""])
      status, out, err = cli("relearn-device-ids", "--host", host.ubid, device_ids: relearn("/var/storage" => ["nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f60718"]))
      expect([status, err]).to eq [0, ""]
      expect(out).to eq <<~OUT
        DEFAULT (/var/storage): [""] -> ["nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f60718"]
        Nothing written; re-run with --yes to store the new ids.
      OUT
      expect(host.storage_devices.first.unix_device_list.to_a).to eq [""]
      expect(audit_rows).to be_empty
    end

    it "stores the changed ids with --yes and records them" do
      add_device("DEFAULT", ["vda1"])
      add_device("extra", ["vdb"])
      status, out, = cli("relearn-device-ids", "--host", host.ubid, "--yes", device_ids: relearn("/var/storage" => ["vda"], "/var/storage/devices/extra" => ["vdb"]))
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        DEFAULT (/var/storage): ["vda1"] -> ["vda"]
        extra (/var/storage/devices/extra): ["vdb"] -> ["vdb"] (unchanged)
        Stored the new ids of 1 storage devices of host #{host.ubid}.
      OUT
      expect(host.storage_devices_dataset.order(:name).select_map(:unix_device_list).map(&:to_a)).to eq [["vda"], ["vdb"]]
      expect(host.storage_devices_dataset.select_map(:available_storage_gib)).to eq [90, 90]
      row = audit_rows.last
      expect(row[:command]).to eq "relearn-device-ids"
      expect(row[:target_id]).to eq host.id
      expect(row[:args].to_h).to eq("devices" => {"DEFAULT" => {"from" => ["vda1"], "to" => ["vda"]}})
    end

    it "says so when nothing changes" do
      add_device("DEFAULT", ["vda"])
      expect(cli("relearn-device-ids", "--host", host.ubid, "--yes", device_ids: relearn("/var/storage" => ["vda"]))).to eq [0, "DEFAULT (/var/storage): [\"vda\"] -> [\"vda\"] (unchanged)\nNothing to change.\n", ""]
      expect(audit_rows).to be_empty
    end

    it "refuses a generic host outside a BYOH location" do
      expect(cli("relearn-device-ids", "--host", legacy_host.ubid)).to eq [1, "", "! host #{legacy_host.ubid} is not a BYOH host (a generic host in a BYOH location)\n"]
    end

    it "refuses a host without storage devices" do
      expect(cli("relearn-device-ids", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} has no storage devices yet; LearnStorage records them during prep\n"]
    end

    it "reports a device identity error" do
      add_device("DEFAULT", [""])
      zfs = ->(_, _) { raise ByohDeviceIdentity::Error, "/var/storage is on rpool/ROOT (zfs), not a block device" }
      expect(cli("relearn-device-ids", "--host", host.ubid, device_ids: zfs)).to eq [1, "", "! /var/storage is on rpool/ROOT (zfs), not a block device\n"]
    end

    it "reports a command that failed on the host without a backtrace" do
      add_device("DEFAULT", [""])
      failed = ->(_, _) { raise Sshable::SshError.new("findmnt -nP -o SOURCE,MAJ:MIN,FSTYPE --target /var/storage", "", "findmnt: /var/storage: not found\n", 1, nil) }
      expect(cli("relearn-device-ids", "--host", host.ubid, device_ids: failed)).to eq [1, "", "! could not read disk ids from host #{host.ubid} over SSH: command exited with an error: findmnt -nP -o SOURCE,MAJ:MIN,FSTYPE --target /var/storage: findmnt: /var/storage: not found\n"]
      expect(host.storage_devices.first.unix_device_list.to_a).to eq [""]
    end

    it "reports an unreachable host without a backtrace" do
      add_device("DEFAULT", [""])
      down = ->(_, _) { raise Net::SSH::ConnectionTimeout, "timed out connecting to 10.0.0.5" }
      expect(cli("relearn-device-ids", "--host", host.ubid, device_ids: down)).to eq [1, "", "! could not read disk ids from host #{host.ubid} over SSH: Net::SSH::ConnectionTimeout: timed out connecting to 10.0.0.5\n"]
    end
  end

  describe "setup-egress-nat" do
    it "refuses a host that is not a BYOH host" do
      host = legacy_host
      expect(cli("setup-egress-nat", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)\n"]
    end

    it "refuses a host that is still being prepared" do
      host = generic_host(byoh_1)
      expect(cli("setup-egress-nat", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is still being prepared; its prep sets up the egress NAT\n"]
      expect(Strand.where(prog: "SetupByohEgressNat").count).to eq 0
    end

    it "starts a strand that installs the table and records it" do
      host = generic_host(byoh_1)
      host.update(allocation_state: "accepting")
      status, out, err = cli("setup-egress-nat", "--host", host.ubid)
      strand = Strand.first(prog: "SetupByohEgressNat")
      expect([status, out, err]).to eq [0, "Started #{strand.ubid} to install the egress NAT table on host #{host.ubid} from location byoh-1's profile.\n", ""]
      expect([strand.label, strand.stack]).to eq ["start", [{"subject_id" => host.id}]]
      row = audit_rows.last
      expect([row[:command], row[:target_id], row[:args].to_h, row[:result]]).to eq ["setup-egress-nat", host.id, {"location" => "byoh-1"}, "started #{strand.ubid}"]
    end
  end

  describe "relearn-pci" do
    it "refuses a host that is not a BYOH host" do
      host = legacy_host
      host.update(allocation_state: "accepting")
      expect(cli("relearn-pci", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is not a BYOH host (a generic host in a BYOH location)\n"]
    end

    it "refuses a host whose prep has not started" do
      host = generic_host(byoh_1)
      expect(cli("relearn-pci", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is still being prepared; its prep learns the GPUs\n"]
      expect(Strand.where(prog: "LearnPci").count).to eq 0
      expect(audit_rows).to be_empty
    end

    it "starts LearnPci on the host and records it" do
      host = generic_host(byoh_1)
      host.update(allocation_state: "accepting")
      status, out, err = cli("relearn-pci", "--host", host.ubid)
      strand = Strand.first(prog: "LearnPci")
      expect([status, out, err]).to eq [0, "Started #{strand.ubid} to relearn the GPUs of host #{host.ubid}. The respirate log names each GPU it skips and why.\n", ""]
      expect([strand.label, strand.stack]).to eq ["start", [{"subject_id" => host.id}]]
      row = audit_rows.last
      expect([row[:command], row[:target_id], row[:args].to_h, row[:result]]).to eq ["relearn-pci", host.id, {}, "started #{strand.ubid}"]
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
