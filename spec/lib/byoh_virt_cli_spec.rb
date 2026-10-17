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

    it "judges a lower-tier host by its tier" do
      tier_host = create_byoh_vm_host(host.location, virt_tier: "emulated", family: "emulated", net6: "fd00:9:9:9::/64")
      tier_host.update(virt_probe: Sequel.pg_jsonb(ByohVirtLadder.parse(no_virt).record))
      status, out, = cli("show", "--host", tier_host.ubid)
      expect(status).to eq 3
      expect(out).to start_with("host #{tier_host.ubid}, registered as emulated (L5, experimental)\ntier: none (L3-L5)")
        .and end_with("registered tier: emulated, the probe disagrees; see the ByohVirtTier page\n")
      ready = JSON.parse(no_virt).tap { it["facts"].merge!("commands" => {"qemu-system-x86_64" => true}, "ovmf" => true) }
      tier_host.update(virt_probe: Sequel.pg_jsonb(ByohVirtLadder.verdict(ready).record))
      status, out, = cli("show", "--host", tier_host.ubid)
      expect([status, out.lines.last]).to eq [0, "registered tier: emulated, the probe agrees\n"]
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

  describe "pvm" do
    let(:pvm_host) { create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm", net6: "fd00:9:9:8::/64") }
    let(:row) { ByohPvmHost.create(vm_host_id: pvm_host.id, state: "failed", install: true, host_deb_sha256: "a" * 64, lockdown: "none", meltdown: "Not affected", last_error: "apt-get failed") }
    let(:strand) { Strand.create_with_id(pvm_host, prog: "Vm::HostNexus", label: "pvm_install_failed", stack: [{}]) }

    before do
      location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins}))
      row
      strand
    end

    def semaphores = Semaphore.where(strand_id: pvm_host.id).select_order_map(:name)

    def actions = DB[:byoh_operator_action].order(:id).select_map([:command, :args, :result]).map { |c, a, r| [c, a.to_h, r] }

    it "refuses an unknown subcommand, a missing host and a host of another tier" do
      expect(cli("pvm")).to eq [1, "", "! usage: bin/byoh-virt pvm retry|uninstall --host UBID
"]
      expect(cli("pvm", "frob")[2]).to eq "! usage: bin/byoh-virt pvm retry|uninstall --host UBID
"
      expect(cli("pvm", "retry")).to eq [1, "", "! --host is required
"]
      expect(cli("pvm", "uninstall", "--host", host.ubid)).to eq [1, "", "! host #{host.ubid} is a kvm host, not pvm
"]
      row.destroy
      expect(cli("pvm", "retry", "--host", pvm_host.ubid)).to eq [1, "", "! host #{pvm_host.ubid} has no PVM kernel record
"]
    end

    describe "retry" do
      it "asks the host to install again and records it" do
        status, out, = cli("pvm", "retry", "--host", pvm_host.ubid)
        expect(status).to eq 0
        expect(out).to eq "Asked host #{pvm_host.ubid} to install the PVM host kernel again; follow it with bin/byoh-host watch #{pvm_host.ubid}.\n"
        expect(semaphores).to eq ["pvm_retry"]
        expect(actions).to eq [["virt-pvm-retry", {"from" => "pvm_install_failed"}, "requested"]]
      end

      it "asks a host whose PVM boot failed to boot it once more" do
        strand.update(label: "pvm_boot_failed")
        row.update(state: "armed")
        create_vm(vm_host_id: pvm_host.id, family: "pvm", location_id: location.id)
        status, out, = cli("pvm", "retry", "--host", pvm_host.ubid)
        expect([status, out]).to eq [0, "Asked host #{pvm_host.ubid} to arm one more PVM kernel boot and reboot it; follow it with bin/byoh-host watch #{pvm_host.ubid}.\n"]
        expect(cli("pvm", "retry", "--host", pvm_host.ubid, "--accept-host-deb", "a" * 64)[2]).to eq "! --accept-host-deb is for a failed install; this host's PVM kernel is installed\n"
      end

      it "reboots a host whose PVM boot could not be armed under its running VMs only when told to" do
        strand.update(label: "pvm_boot_failed", stack: [{"pvm_not_rebooted" => true}])
        row.update(state: "committed")
        expect(cli("pvm", "retry", "--host", pvm_host.ubid)[0]).to eq 0
        Semaphore.where(strand_id: pvm_host.id).destroy
        create_vm(vm_host_id: pvm_host.id, family: "pvm", location_id: location.id)
        expect(cli("pvm", "retry", "--host", pvm_host.ubid)).to eq [1, "", "! host #{pvm_host.ubid} was not rebooted (its PVM boot could not be armed), so its 1 VMs still run, and a retry reboots it under them; " \
          "delete them first, or pass --reboot-vms to reboot them with the host\n"]
        expect(semaphores).to eq []
        expect(cli("pvm", "retry", "--host", pvm_host.ubid, "--reboot-vms")[0]).to eq 0
        expect(semaphores).to eq ["pvm_retry"]
        expect(actions).to contain_exactly(["virt-pvm-retry", {"from" => "pvm_boot_failed"}, "requested"], ["virt-pvm-retry", {"from" => "pvm_boot_failed", "reboot_vms" => 1}, "requested"])
      end

      it "refuses a host where nothing failed" do
        strand.update(label: "wait")
        expect(cli("pvm", "retry", "--host", pvm_host.ubid)).to eq [1, "", "! host #{pvm_host.ubid} is at wait; pvm retry acts only where a PVM kernel install or boot failed (pvm_install_failed, pvm_boot_failed)\n"]
        expect(semaphores).to eq []
      end

      it "takes the location's new host-deb pin only when the operator accepts it" do
        location.update(byoh_virt: Sequel.pg_jsonb(location.byoh_virt.to_h.merge("pvm_kernel" => pvm_test_pins.merge("host_deb" => {"url" => "https://example.com/new.deb", "sha256" => "c" * 64}))))
        expect(cli("pvm", "retry", "--host", pvm_host.ubid)[2]).to eq "! location byoh-v pins host-deb sha256 #{"c" * 64}, but this host acknowledged #{"a" * 64}; check the new build, then pvm retry --host #{pvm_host.ubid} --accept-host-deb #{"c" * 64}\n"
        expect(cli("pvm", "retry", "--host", pvm_host.ubid, "--accept-host-deb", "a" * 64)[2]).to eq "! location byoh-v pins host-deb sha256 #{"c" * 64}, not #{"a" * 64}\n"
        expect(semaphores).to eq []
        expect(cli("pvm", "retry", "--host", pvm_host.ubid, "--accept-host-deb", "c" * 64)[0]).to eq 0
        expect(row.reload.host_deb_sha256).to eq "c" * 64
        expect(actions).to eq [["virt-pvm-retry", {"from" => "pvm_install_failed", "accept_host_deb" => "c" * 64}, "requested"]]
      end

      it "names a location that pins no host kernel" do
        location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm], "acks" => {}}))
        expect(cli("pvm", "retry", "--host", pvm_host.ubid)[2]).to end_with "then pvm retry --host #{pvm_host.ubid} --accept-host-deb SHA256\n"
        expect(cli("pvm", "retry", "--host", pvm_host.ubid, "--accept-host-deb", "c" * 64)[2]).to eq "! location byoh-v pins host-deb sha256 none, not #{"c" * 64}\n"
      end
    end

    describe "uninstall" do
      it "asks the host to uninstall its PVM kernel and records it" do
        status, out, = cli("pvm", "uninstall", "--host", pvm_host.ubid)
        expect(status).to eq 0
        expect(out).to start_with "Asked host #{pvm_host.ubid} to uninstall its PVM host kernel"
        expect(semaphores).to eq ["pvm_uninstall"]
        expect(actions).to eq [["virt-pvm-uninstall", {"from" => "pvm_install_failed"}, "requested"]]
      end

      it "refuses while the host has VMs, at a label it cannot start from, or when there is nothing to uninstall" do
        vm = create_vm(vm_host_id: pvm_host.id, family: "pvm", location_id: location.id)
        expect(cli("pvm", "uninstall", "--host", pvm_host.ubid)[2]).to eq "! host #{pvm_host.ubid} has 1 VMs; delete them first (an uninstall leaves the host unable to run them)\n"
        vm.destroy
        strand.update(label: "reboot")
        expect(cli("pvm", "uninstall", "--host", pvm_host.ubid)[2]).to eq "! host #{pvm_host.ubid} is at reboot; pvm uninstall starts only at verify_virt_tier, pvm_install_failed, pvm_boot_failed, wait\n"
        row.update(state: "uninstalled")
        expect(cli("pvm", "uninstall", "--host", pvm_host.ubid)[2]).to eq "! host #{pvm_host.ubid} has its PVM kernel uninstalled already\n"
        row.update(state: "committed", install: false)
        expect(cli("pvm", "uninstall", "--host", pvm_host.ubid)[2]).to start_with "! the control plane did not install the PVM kernel of host #{pvm_host.ubid}"
        expect(semaphores).to eq []
        expect(actions).to eq []
      end
    end

    describe "show" do
      it "shows the PVM host kernel, the host's last word on its boot and the guest kernels" do
        row.update(state: "committed", host_kver: "6.12.33-pvm", stock_kver: "7.0.0-1014-aws", stock_entry: "Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-1014-aws", last_error: nil)
        strand.update(label: "wait", stack: [{
          "pvm_status" => {"at" => "2026-10-17T00:00:00Z", "kernel" => "6.12.33-pvm", "grubenv" => {"saved_entry" => "S", "next_entry" => "ubicloud-pvm"},
                           "boot_unit" => {"ActiveState" => "active", "Result" => "success"}},
          "pvm_patch_kernels" => {"before" => ["linux-image-7.0.0-1014-aws"]},
        }])
        ByohPvmGuestKernel.create(vm_host_id: pvm_host.id, sha256: "b" * 64, state: "ready", release: "6.12.33-pvm", console: "hvc0", config_checked: true)
        ByohPvmGuestKernel.create(vm_host_id: pvm_host.id, sha256: "c" * 64, state: "refused")
        ByohPvmGuestKernel.create(vm_host_id: pvm_host.id, sha256: "d" * 64, state: "ready", release: "6.12.40-pvm", console: "ttyS0", config_checked: false)
        status, out, err = cli("show", "--host", pvm_host.ubid)
        expect([status, err]).to eq [0, ""]
        expect(out.lines).to eq <<~OUT.lines
          host #{pvm_host.ubid} was never probed; run bin/byoh-virt refresh --host #{pvm_host.ubid}
          PVM host kernel: committed, installed by the control plane
            PVM kernel 6.12.33-pvm, stock kernel 7.0.0-1014-aws (GRUB default 'Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-1014-aws')
            host-deb sha256 #{"a" * 64} (the location's pin)
            lockdown none, Meltdown Not affected
            at 2026-10-17T00:00:00Z: kernel 6.12.33-pvm, grubenv next_entry=ubicloud-pvm saved_entry=S
            boot unit Result=success ActiveState=active
            kernel packages before patch: linux-image-7.0.0-1014-aws; after: (patch running)
          PVM guest kernels:
            #{"b" * 64} ready 6.12.33-pvm, console hvc0, config checked, the location's pin
            #{"c" * 64} refused
            #{"d" * 64} ready 6.12.40-pvm, console ttyS0, config unchecked
        OUT
      end

      it "shows a failed install, a stale pin, and what is not recorded" do
        location.update(byoh_virt: Sequel.pg_jsonb(location.byoh_virt.to_h.merge("pvm_kernel" => pvm_test_pins.merge("host_deb" => {"url" => "https://example.com/new.deb", "sha256" => "c" * 64}))))
        strand.update(stack: [{"pvm_status" => {"at" => "t"}, "pvm_patch_kernels" => {"before" => ["a"], "after" => ["a", "b"]}}])
        pvm_host.update(virt_probe: Sequel.pg_jsonb(ByohVirtLadder.parse(no_virt).record))
        status, out, = cli("show", "--host", pvm_host.ubid)
        expect(status).to eq 3
        expect(out).to include(
          "registered tier: pvm, the probe disagrees; see the ByohVirtTier page\nPVM host kernel: failed, installed by the control plane\n",
          "  PVM kernel -, stock kernel - (GRUB default -)\n",
          "  host-deb sha256 #{"a" * 64} (the location pins #{"c" * 64})\n",
          "  last error: apt-get failed\n",
          "  at t: kernel -, grubenv \n",
          "  kernel packages before patch: a; after: a b\n",
          "  waiting for bin/byoh-virt pvm retry or pvm uninstall (pvm_install_failed)\n",
          "PVM guest kernels: none\n",
        )

        row.update(host_deb_sha256: nil, lockdown: nil, meltdown: nil)
        strand.update(stack: [{"pvm_patch_kernels" => {}}])
        out = cli("show", "--host", pvm_host.ubid)[1]
        expect(out).to include("  lockdown -, Meltdown -\n", "  kernel packages before patch: ; after: (patch running)\n")
        expect(out).not_to include("host-deb sha256", "  at ")

        row.update(state: "committed", install: false)
        expect(cli("show", "--host", pvm_host.ubid)[1]).to include "PVM host kernel: committed, installed before registration\n"

        strand.destroy
        expect(cli("pvm", "retry", "--host", pvm_host.ubid)[2]).to start_with "! host #{pvm_host.ubid} is at no strand; pvm retry acts only"
        row.update(install: true)
        expect(cli("pvm", "uninstall", "--host", pvm_host.ubid)[2]).to start_with "! host #{pvm_host.ubid} is at no strand; pvm uninstall starts only"
        row.destroy
        expect(cli("show", "--host", pvm_host.ubid)[1]).to end_with "PVM host kernel: not recorded\nPVM guest kernels: none\n"
      end
    end
  end
end
