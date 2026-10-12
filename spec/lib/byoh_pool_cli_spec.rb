# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohPoolCli do
  let(:dir) { Dir.mktmpdir }
  let(:location) {
    Location.create(name: "byoh-cli", display_name: "byoh-cli", ui_name: "byoh-cli", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:1:2::/48"})
  }
  let(:host) {
    VmHost[ByohRegistration.new(main_ip: "10.98.1.10", location:, pools: [
      "5.9.10.0/30",
      "10.98.1.128/32,delivery=fabric,exposure=nat,external=10.98.1.128:8.8.8.10",
    ]).register!.id]
  }
  let(:sleeps) { [] }

  after { FileUtils.rm_rf(dir) }

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, sleeper: ->(seconds) { sleeps << seconds }).run(argv)
    [status, out.string, err.string]
  end

  def write(name, text)
    path = File.join(dir, name)
    File.write(path, text)
    path
  end

  def place_vm(ip)
    vm = create_vm(vm_host_id: host.id, location_id: location.id, name: "vm-1")
    AssignedVmAddress.create(ip:, address_id: Address.first(cidr: DB[:ipv4_address].first(ip:)[:cidr]).id, dst_vm_id: vm.id)
    vm
  end

  describe "#run" do
    it "prints the usage without a command" do
      expect(cli).to eq [0, described_class::USAGE, ""]
      expect(cli("--help")[0]).to eq 0
    end

    it "refuses an unknown command, unknown options and extra arguments" do
      status, _, err = cli("frobnicate")
      expect(status).to eq 1
      expect(err).to start_with "! unknown command frobnicate\nUsage:"
      expect(cli("list", "--frob")).to eq [1, "", "! invalid option: --frob\n"]
      expect(cli("list", "extra")).to eq [1, "", "! unexpected argument extra\n"]
    end

    it "needs a generic host" do
      expect(cli("list")).to eq [1, "", "! --host is required\n"]
      expect(cli("list", "--host", "nope")).to eq [1, "", "! no host nope\n"]
      other = create_vm_host
      expect(cli("list", "--host", other.ubid)).to eq [1, "", "! host #{other.ubid} is not a generic (BYOH) host\n"]
    end

    it "changes pools only in a BYOH location" do
      host.update(location_id: Location::HETZNER_FSN1_ID)
      expect(cli("remap", "--host", host.ubid, "--ip", "10.98.1.128", "--external", "8.8.4.4")).to eq [1, "",
        "! host #{host.ubid} is in location hetzner-fsn1, which is not a BYOH location; move it with bin/byoh-host move-location first\n"]
    end
  end

  it "lists the pools and their addresses" do
    vm = place_vm("5.9.10.1")
    DB[:ipv4_address].where(ip: "5.9.10.2").update(reserved: true)
    status, out, _ = cli("list", "--host", host.ubid)
    expect(status).to eq 0
    expect(out).to eq <<~OUT
      Host #{host.ubid}, location byoh-cli, IPv6 #{host.net6} (ula)
      Pool 5.9.10.0/30: delivery routed, exposure public
      Pool 10.98.1.128/32: delivery fabric, exposure nat
      IP               EXTERNAL         EXPOSURE  STATE
      5.9.10.0         -                public    free
      5.9.10.1         -                public    #{vm.ubid} vm-1
      5.9.10.2         -                public    reserved
      5.9.10.3         -                public    free
      10.98.1.128      8.8.8.10         nat       free
    OUT
  end

  describe "export" do
    it "prints pools.yaml with overrides and an AWS external map" do
      map = write("addresses.json", {"Addresses" => [{"PublicIp" => "8.8.8.20", "PrivateIpAddress" => "5.9.10.0"}]}.to_json)
      status, out, err = cli("export", "--host", host.ubid, "--set", "exposure=nat,delivery=fabric", "--external-map", map)
      expect(status).to eq 0
      expect(err).to eq "note: 5.9.10.1: no external IP, exported as reserved\nnote: 5.9.10.2: no external IP, exported as reserved\nnote: 5.9.10.3: no external IP, exported as reserved\n"
      expect(YAML.safe_load(out)["routed_networks"].first).to eq(
        "cidr" => "5.9.10.0/30", "delivery" => "fabric", "exposure" => "nat", "external" => {"5.9.10.0" => "8.8.8.20"}, "reserve" => ["5.9.10.1", "5.9.10.2", "5.9.10.3"],
      )
    end

    it "prints the pools as registered without options" do
      status, out, err = cli("export", "--host", host.ubid)
      expect([status, err]).to eq [0, ""]
      expect(ByohPoolDeclaration.parse_yaml(out).entries.size).to eq 3
    end

    it "refuses a malformed --set and an unreadable map" do
      expect(cli("export", "--host", host.ubid, "--set", "exposure")).to eq [1, "", "! --set takes key=value pairs, not exposure\n"]
      status, _, err = cli("export", "--host", host.ubid, "--external-map", File.join(dir, "missing"))
      expect(status).to eq 1
      expect(err).to start_with "! cannot read #{File.join(dir, "missing")}: No such file"
    end
  end

  describe "add and annotate" do
    it "adds pools inline and from a file" do
      file = write("pools.yaml", {"version" => 2, "routed_networks" => [{"cidr" => "10.98.4.0/30", "exposure" => "internal"}]}.to_yaml)
      status, out, err = cli("add", "--host", host.ubid, "--pool-file", file, "--pool", "10.98.5.0/30")
      expect(status).to eq 0
      expect(out).to eq "Updated the pools of host #{host.ubid}; check them with bin/byoh-pool verify --host #{host.ubid}.\n"
      expect(err).to eq "note: 10.98.5.0/30: no exposure given, using internal because it is not globally routable\n"
      expect(DB[:address].where(cidr: ["10.98.4.0/30", "10.98.5.0/30"]).count).to eq 2
    end

    it "annotates from an exported file" do
      _, yaml, _ = cli("export", "--host", host.ubid, "--set", "delivery=fabric")
      expect(cli("annotate", "--host", host.ubid, "--pool-file", write("pools.yaml", yaml))[0]).to eq 0
      expect(DB[:address].first(cidr: "5.9.10.0/30")[:delivery]).to eq "fabric"
      expect(cli("annotate", "--host", host.ubid, "--pool", "5.9.10.0/30,exposure=public")[0]).to eq 0
      expect(DB[:address].first(cidr: "5.9.10.0/30")[:delivery]).to eq "routed"
    end

    it "reports invalid pools" do
      expect(cli("add", "--host", host.ubid, "--pool", "10.98.5.1/30")).to eq [1, "", "! \"10.98.5.1/30\" is not a CIDR (address/prefix, no host bits)\n"]
      expect(cli("add", "--host", host.ubid)).to eq [1, "", "! no pools given\n"]
    end
  end

  describe "remove" do
    it "removes a pool, draining its VMs" do
      vm = place_vm("5.9.10.1")
      expect(cli("remove", "--host", host.ubid, "--pool", "5.9.10.0/30")[0]).to eq 1
      vm.assigned_vm_address.destroy
      expect(cli("remove", "--host", host.ubid, "--pool", "5.9.10.0/30", "--drain", "--drain-timeout", "60"))
        .to eq [0, "Removed pool 5.9.10.0/30 from host #{host.ubid}.\n", ""]
    end

    it "waits as long as asked for drained VMs" do
      place_vm("5.9.10.1")
      status, _, err = cli("remove", "--host", host.ubid, "--pool", "5.9.10.0/30", "--drain", "--drain-timeout", "15")
      expect([status, sleeps]).to eq [1, [5, 5, 5]]
      expect(err).to include "its VMs are still being destroyed"
    end

    it "needs --pool" do
      expect(cli("remove", "--host", host.ubid)).to eq [1, "", "! --pool is required\n"]
    end
  end

  describe "remap" do
    it "maps a nat address to another external IP" do
      expect(cli("remap", "--host", host.ubid, "--ip", "10.98.1.128", "--external", "8.8.4.4"))
        .to eq [0, "Mapped 10.98.1.128 to 8.8.4.4 on host #{host.ubid}.\n", ""]
    end

    it "needs --ip and --external" do
      expect(cli("remap", "--host", host.ubid, "--ip", "10.98.1.128")).to eq [1, "", "! --ip and --external are required\n"]
    end
  end

  describe "ipv6 set" do
    it "sets the IPv6 network" do
      expect(cli("ipv6", "set", "--host", host.ubid, "--cidr", "2a01:4f8:1:2::/64", "--mode", "gua"))
        .to eq [0, "Set the IPv6 network of host #{host.ubid} to 2a01:4f8:1:2::/64 (gua).\n", ""]
    end

    it "needs the set subcommand and --cidr" do
      expect(cli("ipv6", "get")).to eq [1, "", "! ipv6 takes the subcommand set\n"]
      expect(cli("ipv6", "set", "--host", host.ubid)).to eq [1, "", "! --cidr is required\n"]
    end
  end

  describe "verify" do
    it "exits 0 when nothing fails" do
      status, out, _ = cli("verify", "--host", host.ubid)
      expect(status).to eq 0
      expect(out).to end_with "Host #{host.ubid}: 0 failed, 0 warnings.\n"
      expect(out).to start_with "unverified: /etc/nftables.d/1-byoh-egress.conf"
    end

    it "exits 1 on a failure" do
      host
      DB[:ipv4_address].where(ip: "10.98.1.128").update(external_ip: nil)
      status, out, _ = cli("verify", "--host", host.ubid)
      expect(status).to eq 1
      expect(out).to include "fail: 10.98.1.128/32 is nat, but 10.98.1.128 have no external IP\n"
      expect(out).to end_with "Host #{host.ubid}: 2 failed, 0 warnings.\n"
    end
  end

  describe "trace" do
    it "traces an address" do
      host
      status, out, _ = cli("trace", "8.8.8.10")
      expect(status).to eq 0
      expect(out).to start_with "pool address  10.98.1.128\n"
    end

    it "takes exactly one address" do
      expect(cli("trace")).to eq [1, "", "! trace takes one IP address\n"]
      expect(cli("trace", "1.1.1.1", "2.2.2.2")).to eq [1, "", "! trace takes one IP address\n"]
    end
  end
end
