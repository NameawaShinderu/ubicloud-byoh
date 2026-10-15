# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "byoh_fake_root_login"

RSpec.describe ByohRegistrationCli do
  include ByohFakeRootLogin

  let(:dir) { Dir.mktmpdir }
  let(:required) { ["--main-ip", "203.0.113.42", "--location", "byoh-test"] }
  let(:starts) { [] }
  let(:key_path) {
    path = File.join(dir, "byoh_key")
    File.write(path, SshKey.generate.private_key)
    path
  }
  # A host whose key is installed: --ssh-key, and the fixture host's
  # address.
  let(:installed) { ["--main-ip", "203.0.113.10", "--location", "byoh-test", "--ssh-key", key_path, "--routed-network", "fd00:feed::/64", "--yes"] }

  before do
    Location.create(name: "byoh-test", display_name: "byoh-test", ui_name: "BYOH test", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:1:2::/48"})
  end

  after { FileUtils.rm_rf(dir) }

  # Runs the command; returns its exit status, stdout and stderr. A
  # preflight logs in to a fake host that prints the named fixture, with
  # the nonce the fixtures carry.
  def cli(*argv, input: "", fixture: "base")
    out = StringIO.new
    err = StringIO.new
    starter = fake_root_starter(channels: preflight_channels(preflight_fixture(fixture)), starts:)
    status = described_class.new(out:, err:, input: StringIO.new(input), starter:, nonce: "f1x7ure").run(argv)
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
    expect(err).to eq "note: 10.99.0.0/29: no exposure given, using internal because it is not globally routable\n" \
      "warning: preflight skipped: it logs in with the registration key, which this run generated; " \
      "once the key is installed, check the host with `ubicloud-admin host preflight`, or pass --ssh-key next time\n"
    expect(starts).to be_empty

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

  it "downloads ubuntu-noble when no boot image is named" do
    expect(cli(*required, "--routed-network", "fd00:feed::/64", "--yes").first).to eq 0
    expect(Strand[VmHost.first.id].stack.first["default_boot_images"]).to eq ["ubuntu-noble"]
  end

  describe "preflight" do
    it "checks the host with an installed key, then registers it with its host keys pinned" do
      status, out, err = cli(*installed)
      expect([status, err]).to eq [0, ""]
      expect(out).to include "Step 2/3 — Host preflight", "Step 3/3 — Registering host with control plane"
      expect(out).to match(/^pass +PF2 +root@203\.0\.113\.10 logs in with the registration key and runs commands$/)
      expect(out).to match(/^pass +PF3 /)
      expect(out).to include "Uplink IP        203.0.113.10\n",
        "Pinned host keys #{ByohOperatorSsh::HostKey.parse(ByohFakeRootLogin::FIXTURE_HOST_KEY).fingerprint}\n",
        "Host registered."
      expect(starts.map(&:first)).to eq ["203.0.113.10"]

      vm_host = VmHost.first
      expect(vm_host.sshable.host_keys).to eq [ByohFakeRootLogin::FIXTURE_HOST_KEY]
      expect(vm_host.provider.config["uplink_ip"]).to eq "203.0.113.10"
    end

    it "refuses a host without /dev/kvm" do
      status, out, err = cli(*installed, fixture: "no-kvm")
      expect(status).to eq 1
      expect(out).to match(/^fail +PF3 +no \/dev\/kvm$/)
      expect(out).not_to include "Step 3/3"
      expect(err).to eq "! preflight failed: fix the checks marked fail, or accept an overridable one with --accept-check; nothing was registered\n"
      expect(VmHost.count).to eq 0
    end

    it "refuses a hybrid CPU unless the operator accepts it" do
      expect(cli(*installed, fixture: "intel-hybrid").first).to eq 1
      status, out, _ = cli(*installed, "--accept-check", "PF8-hybrid", fixture: "intel-hybrid")
      expect(status).to eq 0
      expect(out).to match(/^warn +PF8-hybrid +accepted: Intel hybrid CPU/)
    end

    it "refuses a pool that holds the host's uplink IP" do
      status, out, _ = cli(*installed, "--main-ip", "198.51.100.7", "--routed-network", "203.0.113.8/29,exposure=internal", fixture: "base")
      expect(status).to eq 1
      expect(out).to include "203.0.113.8/29 hands the uplink IP 203.0.113.10 to VMs"
      expect(VmHost.count).to eq 0
    end

    it "takes --uplink-ip and refuses a pool that holds it before logging in" do
      status, _, err = cli(*installed, "--main-ip", "198.51.100.7", "--uplink-ip", "203.0.113.10", "--routed-network", "203.0.113.8/29,exposure=internal")
      expect(status).to eq 1
      expect(err).to eq "! validation failed: 203.0.113.8/29 hands the uplink IP 203.0.113.10 to VMs; declare pools without it, or reserve it\n"
      expect(starts).to be_empty
    end

    it "refuses an --accept-check it cannot honour before logging in" do
      expect(cli(*installed, "--accept-check", "PF3")).to eq [2, "", "! --accept-check PF3: this check cannot be accepted; only #{ByohHostPreflight::OVERRIDABLE.keys.join(", ")} can\n"]
      expect(cli(*installed, "--accept-check", "PF99").last).to start_with "! --accept-check PF99: no such check"
      expect(starts).to be_empty
    end

    it "skips preflight with --skip-preflight" do
      status, _, err = cli(*installed, "--skip-preflight")
      expect(status).to eq 0
      expect(err).to eq "warning: preflight skipped (--skip-preflight); the host was not checked\n"
      expect(starts).to be_empty
      expect(VmHost.first.sshable.host_keys).to be_nil
    end

    # scripts/byoh/verify/m2-gate.sh G3 passes --ssh-key --yes and expects
    # the refusal before anything reaches the host.
    it "refuses a pool that contains the main IP before logging in, as the M2 gate expects" do
      status, _, err = cli("--location", "byoh-test", "--main-ip", "203.0.113.10", "--routed-network", "203.0.113.8/29", "--ssh-key", key_path, "--yes")
      expect(status).to eq 1
      expect(err).to include "contains main_ip"
      expect(starts).to be_empty
    end
  end
end
