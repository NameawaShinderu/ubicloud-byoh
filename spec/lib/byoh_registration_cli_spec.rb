# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohRegistrationCli do
  let(:dir) { Dir.mktmpdir }
  let(:required) { ["--main-ip", "203.0.113.42", "--location", "byoh-test"] }

  before do
    Location.create(name: "byoh-test", display_name: "byoh-test", ui_name: "BYOH test", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:1:2::/48"})
  end

  after { FileUtils.rm_rf(dir) }

  # Runs the command; returns its exit status, stdout and stderr.
  def cli(*argv, input: "")
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, input: StringIO.new(input)).run(argv)
    [status, out.string, err.string]
  end

  it "prints the help" do
    status, out, err = cli("--help")
    expect(status).to eq 0
    expect(out).to start_with "Usage: bin/register-byoh-host --main-ip IP --location NAME [options]"
    expect(out).to include "--pool-file PATH", "default: byoh-<vm_host uuid>"
    expect(err).to eq ""
  end

  it "requires --main-ip and --location" do
    status, _, err = cli("--location", "byoh-test")
    expect(status).to eq 1
    expect(err).to start_with "! --main-ip is required\nUsage:"

    status, _, err = cli("--main-ip", "203.0.113.42")
    expect(status).to eq 1
    expect(err).to start_with "! --location is required\nUsage:"
  end

  it "refuses unknown options and extra arguments" do
    expect(cli(*required, "--provider", "generic")).to eq [1, "", "! invalid option: --provider\n"]
    expect(cli(*required, "extra")).to eq [1, "", "! unexpected argument extra\n"]
  end

  it "reports a validation failure" do
    status, out, err = cli("--main-ip", "203.0.113.42", "--location", "hetzner-fsn1", "--yes")
    expect(status).to eq 1
    expect(out).to eq ""
    expect(err).to eq "! validation failed: location hetzner-fsn1 is not a BYOH location; create one with bin/byoh-location\n"
  end

  it "reports a /64 it cannot derive as a validation failure" do
    Location.first(name: "byoh-test").update(byoh_network: Sequel.pg_jsonb({}))
    status, _, err = cli(*required, "--yes")
    expect(status).to eq 1
    expect(err).to start_with "! validation failed: location byoh-test has no ula48"
  end

  it "registers the host" do
    pools = File.join(dir, "pools.yaml")
    File.write(pools, "version: 2\nuplink: enp1s0\nrouted_networks:\n  - cidr: 2001:db8:1::/64\n    ndp: true\n")
    status, out, err = cli(*required, "--routed-network", "10.99.0.0/29", "--routed-network", "185.0.2.8/29,exposure=public,reserve=185.0.2.9",
      "--pool-file", pools, "--ipv6-mode", "gua", "--server-identifier", "rack-1", "--default-boot-image", "ubuntu-noble", "--yes")
    expect(status).to eq 0
    expect(err).to eq "note: 10.99.0.0/29: no exposure given, using internal because it is not globally routable\n"

    vm_host = VmHost.first
    expect(vm_host.provider.server_identifier).to eq "rack-1"
    expect(vm_host.ipv6_mode).to eq "gua"
    expect(vm_host.ndp_needed).to be true
    expect(Strand[vm_host.id].stack.first["default_boot_images"]).to eq ["ubuntu-noble"]
    location = Location.first(name: "byoh-test")
    expect(out).to include(
      "Location         byoh-test (#{location.ubid}), BYOH test\n",
      "IPv6 mode        gua\n",
      "Pools            2001:db8:1::/64 ndp=true\n" \
      "                 10.99.0.0/29 delivery=routed exposure=internal\n" \
      "                 185.0.2.8/29 delivery=routed exposure=public reserve=[\"185.0.2.9\"]\n",
      "Uplink           enp1s0\n",
      "VmHost UBID:  #{vm_host.ubid}",
      "SELECT label, stack FROM strand WHERE id = '#{vm_host.id}';",
    )
    expect(out).not_to include "Press ENTER"
    expect(out).not_to include "BMC "
  end

  it "waits for confirmation without --yes" do
    status, out, _ = cli(*required, "--routed-network", "fd00:feed::/64", input: "\n")
    expect(status).to eq 0
    expect(out).to include "Press ENTER once the public key is installed", "Host registered."
  end

  it "aborts when standard input has no confirmation" do
    status, out, err = cli(*required, "--routed-network", "fd00:feed::/64")
    expect(status).to eq 1
    expect(out).not_to include "Host registered."
    expect(err).to eq "! aborted: no confirmation on standard input (pass --yes to skip it)\n"
    expect(VmHost.count).to eq 0
  end

  it "stores the BMC options, with TLS verification off unless asked for" do
    bmc = ["--bmc-endpoint", "https://192.0.2.11", "--bmc-user", "admin", "--bmc-pass-env", "TEST_BMC_PASS_SILENCED",
      "--bmc-system-id", "1", "--bmc-reset-type", "PowerCycle"]
    status, out, _ = cli(*required, "--routed-network", "fd00:feed::/64", *bmc, "--yes")
    expect(status).to eq 0
    expect(out).to include "BMC              https://192.0.2.11 (protocol=redfish, system_id=1)"
    expect(VmHost.first.provider.config["bmc"]).to eq(
      "protocol" => "redfish", "endpoint" => "https://192.0.2.11", "username" => "admin",
      "password_env" => "TEST_BMC_PASS_SILENCED", "system_id" => "1", "reset_type" => "PowerCycle", "verify_ssl" => false,
    )
  end

  it "keeps TLS verification on with --bmc-verify-ssl" do
    bmc = ["--bmc-endpoint", "https://192.0.2.11", "--bmc-user", "admin", "--bmc-password", "pw", "--bmc-verify-ssl"]
    status, out, _ = cli(*required, "--main-ip", "203.0.113.43", "--routed-network", "fd00:feed::/64", *bmc, "--yes")
    expect(status).to eq 0
    expect(out).to include "system_id=auto"
    expect(VmHost.first.provider.config["bmc"]).to include("password" => "pw", "verify_ssl" => true)
  end
end
