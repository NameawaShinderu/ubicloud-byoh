# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../rhizome/host/lib/virt_probe"

RSpec.describe ByohVirtCli do
  let(:location) { Location.create(name: "byoh-v", display_name: "byoh-v", ui_name: "byoh-v", visible: false, provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {}) }
  let(:host) {
    Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
      provider_config: {"main_ip4" => "203.0.113.42", "location_label" => location.name, "routed_networks" => [{"cidr" => "fd00:feed::/64"}]}).subject
  }
  let(:no_virt) { report(cpu_flags: %w[hypervisor], dev_kvm: false, kvm_api: nil, modules: [], virt_vm: "kvm", dmi: {"sys_vendor" => "Vultr"}) }

  def report(**over)
    facts = {
      "arch" => "x86_64", "kernel" => "6.8.0", "cpu_vendor" => "GenuineIntel", "cpu_model" => "Xeon",
      "cpu_flags" => %w[vmx pdpe1gb], "dev_kvm" => true, "kvm_api" => 12, "modules" => %w[kvm kvm_intel],
      "nested_param" => nil, "pvm_module_available" => false, "virt_vm" => "none", "virt_container" => "none",
      "dmi" => {"sys_vendor" => "Dell Inc."},
    }.merge(over.transform_keys(&:to_s))
    JSON.generate(VirtProbe.report(facts))
  end

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv, stdin: "")
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, stdin: StringIO.new(stdin)).run(argv)
    [status, out.string, err.string]
  end

  def ok_status = instance_double(Process::Status, success?: true)

  it "prints the usage without a command" do
    expect(cli).to eq [0, described_class::USAGE, ""]
    expect(cli("--help")[0]).to eq 0
  end

  it "refuses an unknown command, option or argument" do
    expect(cli("frob")[2]).to start_with "! unknown command frob\n"
    expect(cli("script", "--frob")).to eq [1, "", "! invalid option: --frob\n"]
    expect(cli("script", "extra")).to eq [1, "", "! unexpected argument extra\n"]
  end

  it "prints the remote script" do
    expect(cli("script")).to eq [0, ByohVirtLadder.remote_script, ""]
  end

  describe "probe" do
    it "requires --main-ip" do
      expect(cli("probe")).to eq [1, "", "! --main-ip is required\n"]
    end

    it "probes a host over ssh as root under sudo -n and explains it" do
      expect(Open3).to receive(:capture3).with("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-i", "/k", "ubuntu@198.51.100.7", "sudo -n ruby - --json", stdin_data: ByohVirtLadder.remote_script).and_return([report, "", ok_status])
      status, out, = cli("probe", "--main-ip", "198.51.100.7", "--ssh-key", "/k", "--user", "ubuntu")
      expect(status).to eq 0
      expect(out).to start_with "tier: kvm (L1)\n"
    end

    it "exits 3 for a host that cannot run VMs, also with --json" do
      expect(Open3).to receive(:capture3).with("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "root@198.51.100.7", "ruby - --json", stdin_data: anything).twice.and_return([no_virt, "", ok_status])
      status, out, = cli("probe", "--main-ip", "198.51.100.7")
      expect(status).to eq 3
      expect(out).to include("fix: Vultr cloud instances")
      status, out, = cli("probe", "--main-ip", "198.51.100.7", "--json")
      expect([status, out]).to eq [3, "#{no_virt}\n"]
    end

    it "prints the raw report of an L1 host with --json" do
      expect(Open3).to receive(:capture3).and_return([report, "", ok_status])
      expect(cli("probe", "--main-ip", "198.51.100.7", "--json")).to eq [0, "#{report}\n", ""]
    end

    it "reports an ssh failure" do
      expect(Open3).to receive(:capture3).and_return(["", "bash: ruby: command not found\e[0m\n", instance_double(Process::Status, success?: false, exitstatus: 127)])
      expect(cli("probe", "--main-ip", "198.51.100.7")).to eq [1, "", "! probing 198.51.100.7 failed (127): bash: ruby: command not found[0m; the host needs ruby (apt-get install ruby) and SSH from here\n"]
    end

    it "says when sudo needs a password instead of misclassifying the host" do
      failed = instance_double(Process::Status, success?: false, exitstatus: 1)
      expect(Open3).to receive(:capture3).and_return(["", "sudo: a password is required\n", failed])
      expect(cli("probe", "--main-ip", "198.51.100.7", "--user", "ubuntu")).to eq [1, "", "! sudo -n failed for ubuntu on 198.51.100.7: sudo: a password is required; the probe must run as root to open /dev/kvm, so give ubuntu passwordless sudo or use --user root\n"]
      expect(Open3).to receive(:capture3).and_return(["", "sudo-ish: no\n", failed])
      expect(cli("probe", "--main-ip", "198.51.100.7", "--user", "ubuntu")[2]).to start_with "! probing 198.51.100.7 failed (1): sudo-ish: no"
    end
  end

  describe "explain" do
    it "explains a saved report from a file or stdin" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "p.json"), no_virt)
        expect(cli("explain", File.join(dir, "p.json"))[0]).to eq 3
      end
      expect(cli("explain", stdin: report)[0]).to eq 0
    end

    it "refuses a missing file, a bad report and two files" do
      expect(cli("explain", "/nonexistent/p.json")).to eq [1, "", "! No such file or directory @ rb_sysopen - /nonexistent/p.json\n"]
      expect(cli("explain", stdin: "junk")).to eq [1, "", "! virt-probe output is not JSON\n"]
      expect(cli("explain", "a", "b")).to eq [1, "", "! unexpected argument b\n"]
    end
  end

  describe "show" do
    it "says a host was never probed" do
      expect(cli("show", "--host", host.ubid)).to eq [0, "host #{host.ubid} was never probed; run bin/byoh-virt refresh --host #{host.ubid}\n", ""]
    end

    it "shows the recorded verdict and exits by it" do
      host.update(virt_probe: Sequel.pg_jsonb(ByohVirtLadder.parse(no_virt).record))
      status, out, = cli("show", "--host", host.ubid)
      expect(status).to eq 3
      expect(out).to start_with "host #{host.ubid}\ntier: none (L3-L5)\nplatform: Vultr\n"
      host.update(virt_probe: Sequel.pg_jsonb(ByohVirtLadder.parse(report).record))
      expect(cli("show", "--host", host.ubid)[0]).to eq 0
    end

    it "shows a failed probe" do
      host.update(virt_probe: Sequel.pg_jsonb({"error" => "RuntimeError: boom"}))
      expect(cli("show", "--host", host.ubid)).to eq [3, "host #{host.ubid}\nthe last probe failed: RuntimeError: boom\n", ""]
    end

    it "refuses a missing, unknown or non-generic host" do
      expect(cli("show")).to eq [1, "", "! --host is required\n"]
      expect(cli("show", "--host", "nope")).to eq [1, "", "! no host nope\n"]
      other = create_vm_host
      expect(cli("show", "--host", other.ubid)).to eq [1, "", "! host #{other.ubid} is not a generic (BYOH) host\n"]
    end

    it "refuses a generic host still in a non-BYOH location, which keeps its M1 behaviour" do
      host.update(location_id: Location::HETZNER_FSN1_ID)
      expect(cli("show", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is #{described_class::NOT_BYOH}\n"]
    end
  end

  describe "refresh" do
    it "starts a probe and records it" do
      host.strand.update(label: "wait")
      status, out, = cli("refresh", "--host", host.ubid)
      expect(status).to eq 0
      st = Strand.first(prog: "LearnVirt")
      expect(st.stack.first["subject_id"]).to eq host.id
      expect(out).to eq "Started #{st.ubid} to probe host #{host.ubid}; see the result with bin/byoh-virt show --host #{host.ubid}.\n"
      expect(DB[:byoh_operator_action].select_map([:command, :result])).to eq [["virt-refresh", "started #{st.ubid}"]]
    end

    it "refuses a host before rhizome is installed" do
      expect(cli("refresh", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} has no rhizome yet; its prep probes it\n"]
    end

    it "needs exactly one of --host and --all" do
      expect(cli("refresh")).to eq [1, "", "! give either --host or --all\n"]
      expect(cli("refresh", "--all", "--host", host.ubid)).to eq [1, "", "! give either --host or --all\n"]
    end

    it "probes every generic host whose rhizome is installed with --all" do
      host.strand.update(label: "wait")
      fresh = Prog::Vm::HostNexus.assemble("203.0.113.43", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
        provider_config: {"main_ip4" => "203.0.113.43", "location_label" => location.name, "routed_networks" => [{"cidr" => "fd00:feed:1::/64"}]}).subject
      create_vm_host
      status, out, = cli("refresh", "--all")
      expect(status).to eq 0
      expect(Strand.where(prog: "LearnVirt").all.map { it.stack.first["subject_id"] }).to eq [host.id]
      expect(out).to include("Started ").and include("Skipped host #{fresh.ubid}: no rhizome yet")
    end

    it "never probes a generic host still in a non-BYOH location" do
      host.strand.update(label: "wait")
      host.update(location_id: Location::HETZNER_FSN1_ID)
      expect(cli("refresh", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is #{described_class::NOT_BYOH}\n"]
      expect(cli("refresh", "--all")).to eq [0, "Skipped host #{host.ubid}: #{described_class::NOT_BYOH}.\n", ""]
      expect(Strand.where(prog: "LearnVirt").count).to eq 0
      expect(DB[:byoh_operator_action].count).to eq 0
    end

    it "starts a probe for a host without a strand" do
      host.strand.destroy
      expect(cli("refresh", "--host", host.reload.ubid)[0]).to eq 0
    end
  end
end
