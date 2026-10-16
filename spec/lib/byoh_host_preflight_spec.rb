# frozen_string_literal: true

require "tempfile"

RSpec.describe ByohHostPreflight do
  # Raw output of scripts/byoh/host/ubicloud-host on the fixture hosts,
  # written by scripts/byoh/test/preflight-fixtures.sh --update-spec.
  def fixture(name) = File.read(File.join(__dir__, "../fixtures/byoh/preflight/#{name}.txt"))

  def from_fixture(name) = described_class.parse(fixture(name), "f1x7ure")

  def line(record, nonce: "n0nce") = "UBIPF:#{nonce} #{JSON.generate(record)}\n"

  def addr = [
    {"ifname" => "lo", "addr_info" => [{"family" => "inet", "local" => "127.0.0.1"}]},
    {"ifname" => "eth0", "addr_info" => [{"family" => "inet", "local" => "10.0.0.5"}, {"family" => "inet6", "local" => "fe80::1"}]},
    {"ifname" => "eth1", "addr_info" => ["junk"]},
    "not a link",
  ]

  def default_facts
    {
      "arch" => "x86_64", "os_version" => "ubuntu 24.04", "mem_gib" => 64, "cpus_online" => 8, "storage_fstype" => "ext4",
      "ip_addr" => addr,
      "ip_route" => [{"dst" => "default", "gateway" => "10.0.0.1", "dev" => "eth0", "prefsrc" => "10.0.0.5"}],
      "netplan" => "", "host_keys" => ["ssh-ed25519 AAAA root@h"], "sshd" => {"permitrootlogin" => "without-password"},
    }
  end

  # A complete, readable output: every host check passes unless statuses
  # says otherwise.
  def output(statuses = {}, facts = {}, nonce: "n0nce")
    checks = described_class::HOST_CHECKS.map { line({kind: "check", id: it, status: statuses.fetch(it, "pass"), detail: "#{it} detail", fix: ""}, nonce:) }
    checks.join + default_facts.merge(facts).map { |id, value| line({kind: "fact", id:, value:}, nonce:) }.join
  end

  def parse(statuses = {}, facts = {}) = described_class.parse(output(statuses, facts), "n0nce")

  def check(preflight, id) = preflight.checks.find { it.id == id }

  def status(preflight, id) = check(preflight, id)&.status

  let(:location) {
    Location.create(name: "byoh-pf", display_name: "byoh-pf", ui_name: "byoh-pf", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"overlay_ipv4_cidrs" => ["172.20.0.0/14"]})
  }

  def pools(*inputs) = inputs.map { ByohPoolDeclaration.parse(it) }

  def evaluate(preflight = parse, main_ip: "10.0.0.5", boot_images: ["ubuntu-noble"], **)
    preflight.evaluate(main_ip:, location:, location_name: "byoh-pf", boot_images:, **)
  end

  it "makes a random hex nonce" do
    expect(described_class.nonce).to match(/\A\h{16}\z/)
    expect(described_class.nonce).not_to eq described_class.nonce
  end

  describe ".parse" do
    it "reads every fixture host's real output" do
      %w[base amd-uniform arm-biglittle btrfs ebs-nvme gpu-nouveau intel-hybrid kvm64-model kvm64-vmx lvm no-kvm noisy-bashrc
        offline-cpus one-cpu pve-node blank-disk rhizome-user smt-offline sshd-broken two-default-routes ufw-off ufw-on virtio-vda zfs
        no-kvm-container old-script].each do |name|
        preflight = from_fixture(name)
        expect(preflight).to be_readable, name
        expect(preflight.checks.map(&:id)).to include(*described_class::HOST_CHECKS, *described_class::STANDALONE_CHECKS)
      end
    end

    it "keeps the verdicts the script gave" do
      expect(check(from_fixture("no-kvm"), "PF3")).to have_attributes(status: "fail", detail: "no /dev/kvm", accepted: false)
      expect(check(from_fixture("kvm64-model"), "PF3").detail).to eq "kvm64-class CPU model (Common KVM processor)"
      expect(check(from_fixture("kvm64-model"), "PF3").fix).to include("TROUBLESHOOTING.md#pf3")
      expect(status(from_fixture("intel-hybrid"), "PF8-hybrid")).to eq "fail"
      expect(status(from_fixture("arm-biglittle"), "PF8-hybrid")).to eq "fail"
      expect(status(from_fixture("amd-uniform"), "PF8-hybrid")).to eq "pass"
      # An offline SMT sibling is a PF8 warning, not a hybrid CPU.
      expect(%w[PF8 PF8-hybrid].map { status(from_fixture("smt-offline"), it) }).to eq %w[warn pass]
      expect(status(from_fixture("base"), "PF3")).to eq "pass"
      # ufw.service is active even with ENABLED=no; only ufw.conf counts.
      expect(check(from_fixture("ufw-off"), "PF16-ufw")).to have_attributes(status: "pass", detail: "ufw not enabled")
      expect(status(from_fixture("ufw-on"), "PF16-ufw")).to eq "fail"
      expect(from_fixture("base").facts).to include("arch" => "x86_64", "cpus_online" => 8, "mem_gib" => 64)
      expect(from_fixture("base").host_keys.map { it.split.first }).to eq %w[ecdsa-sha2-nistp256 ssh-ed25519]
    end

    it "ignores noise and lines with another nonce" do
      preflight = from_fixture("noisy-bashrc")
      expect(status(preflight, "PF3")).to eq "pass"
      expect(status(preflight, "PF16-docker")).to eq "fail"
      expect(preflight.checks.count { it.id == "PF3" }).to eq 1
    end

    it "scrubs bytes that are not UTF-8" do
      expect(described_class.parse("\xff\xfe noise\n".b + output, "n0nce")).to be_readable
    end

    {
      "a line that is not JSON" => ["UBIPF:n0nce {not json\n", "a line is not JSON"],
      "a JSON line that is not an object" => ["UBIPF:n0nce [1]\n", "a line is not a JSON object"],
      "an unknown kind" => [%(UBIPF:n0nce {"kind":"verdict"}\n), %(unknown kind "verdict")],
      "an unknown check" => [%(UBIPF:n0nce {"kind":"check","id":"PF99","status":"pass","detail":"","fix":""}\n), %(unknown check "PF99")],
      "a bad status" => [%(UBIPF:n0nce {"kind":"check","id":"default-route","status":"ok","detail":"","fix":""}\n), %(check default-route has status "ok")],
      "a check without detail" => [%(UBIPF:n0nce {"kind":"check","id":"main-ip-local","status":"pass","fix":""}\n), "check main-ip-local has no detail or fix text"],
      "a check without fix" => [%(UBIPF:n0nce {"kind":"check","id":"main-ip-local","status":"pass","detail":""}\n), "check main-ip-local has no detail or fix text"],
      "an unknown fact" => [%(UBIPF:n0nce {"kind":"fact","id":"colour","value":"blue"}\n), %(unknown fact "colour")],
      "a fact of the wrong type" => [%(UBIPF:n0nce {"kind":"fact","id":"cpus_online","value":"8"}\n), "fact cpus_online is not a Integer"],
      "a check printed twice" => [%(UBIPF:n0nce {"kind":"check","id":"PF1","status":"pass","detail":"","fix":""}\n), "check PF1 printed more than once"],
    }.each do |what, (extra, error)|
      it "fails on #{what}" do
        preflight = described_class.parse(output + extra, "n0nce")
        expect(preflight).not_to be_readable
        expect(preflight.checks.map(&:to_h)).to eq [{id: "preflight", status: "fail", detail: "preflight output unreadable: #{error}", fix: "check that scripts/byoh/host/ubicloud-host runs on the host", accepted: false}]
        expect(preflight).to be_blocking
      end
    end

    it "fails on missing checks and facts, naming at most five" do
      preflight = described_class.parse(output.lines.reject { it.include?(%("id":"PF19")) || it.include?(%("id":"sshd")) }.join, "n0nce")
      expect(check(preflight, "preflight").detail).to eq "preflight output unreadable: no check PF19; no fact sshd"
      expect(check(described_class.parse("", "n0nce"), "preflight").detail.split("; ").size).to eq 5
      expect(described_class.parse(output, "other")).not_to be_readable
    end

    it "accepts a null ip_addr or ip_route" do
      expect(parse({}, "ip_addr" => nil, "ip_route" => nil)).to be_readable
    end

    it "names blank disks as ByohDeviceIdentity does, for --storage-disk" do
      links = ByohDeviceIdentity.byid_links(File.read(File.join(__dir__, "../../scripts/byoh/test/fixtures/host/blank-disk/cmd/byid")))
      pf11 = check(from_fixture("blank-disk"), "PF11")
      expect(pf11.detail).to eq "blank disk(s) not used for VM storage: " + %w[nvme2n1 sdb].map { "#{it} (#{ByohDeviceIdentity.pick(it, links[it])})" }.join(", ")
      expect(pf11.fix).to eq "to use one, pass its by-id name to host add, e.g. --storage-disk nvme-eui.002538b921b0c3d4"
      expect(check(from_fixture("virtio-vda"), "PF11")).to have_attributes(detail: "blank disk(s) not used for VM storage: vdb (no by-id link)",
        fix: "host add --storage-disk takes a disk by its /dev/disk/by-id name; these disks have none (give the virtual disk a serial)")
    end

    it "reads the sshd settings, and null when sshd -T failed" do
      expect(from_fixture("base").facts["sshd"]).to eq("permitrootlogin" => "without-password", "pubkeyauthentication" => "yes", "authenticationmethods" => "any")
      preflight = from_fixture("sshd-broken")
      expect(preflight).to be_readable
      expect(preflight.facts).to include("sshd" => nil)
    end
  end

  describe ".script" do
    it "puts the virtualization probe ahead of the script, in a heredoc the probe never ends" do
      script = described_class.script("main \"$@\"\n")
      expect(script).to start_with("UBICLOUD_VIRT_PROBE=$(cat <<'UBICLOUD_VIRT_PROBE_END'\n# frozen_string_literal: true\n")
      expect(script).to end_with("exit VirtProbe.main(ARGV)\nUBICLOUD_VIRT_PROBE_END\n)\nmain \"$@\"\n")
      expect(ByohVirtLadder.remote_script).not_to include described_class::PROBE_END
    end
  end

  describe "#virt_facts" do
    it "reads the probe's report, the shell's facts with the BIOS lines, and nothing else" do
      expect(from_fixture("base").virt_facts).to include("dev_kvm" => true, "kvm_caps_missing" => [], "bios_log" => nil)
      expect(from_fixture("no-kvm").virt_facts).to include("dev_kvm" => false, "cpu_flags" => %w[vmx pdpe1gb])
      expect(from_fixture("no-kvm").virt_facts).not_to have_key "bios_log"
      shell = ->(facts) { parse({}, "virt" => {"source" => "shell", "facts" => facts}).virt_facts }
      expect(shell.call({"bios_lines" => ["kvm: disabled by bios", "x"]})).to eq("bios_log" => "kvm: disabled by bios")
      expect(shell.call({"bios_lines" => ["SGX disabled by BIOS"]})).to eq("bios_log" => nil)
      expect(shell.call({"bios_lines" => "junk"})).to eq({})
      expect(shell.call([])).to be_nil
      expect(parse({}, "virt" => {"source" => "probe", "report" => {"facts" => []}}).virt_facts).to be_nil
      expect(parse({}, "virt" => {"source" => "probe", "report" => []}).virt_facts).to be_nil
      expect(parse({}, "virt" => {"source" => "other"}).virt_facts).to be_nil
      expect(from_fixture("old-script").virt_facts).to be_nil
    end

    it "refuses a virt fact that is not an object" do
      expect(check(parse({}, "virt" => "kvm"), "preflight").detail).to eq "preflight output unreadable: fact virt is not a Hash"
    end
  end

  describe "PF3 from the virtualization ladder" do
    def offer(tier)
      ship_virt_tiers(tier)
      location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["kvm", tier], "acks" => {tier => []}}))
    end

    it "passes a KVM host on the probe's verdict, keeping the script's words" do
      preflight = evaluate(from_fixture("base"), main_ip: "203.0.113.10")
      expect(check(preflight, "PF3").to_h).to include(status: "pass", fix: "",
        detail: "/dev/kvm present (Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz); ladder: kvm (L1) on unknown platform: /dev/kvm answers KVM_GET_API_VERSION 12")
      expect(preflight.virt_tier).to eq "kvm"
      expect(preflight.virt_verdict.tier).to eq "kvm"
      expect(check(preflight, "PF3-tier")).to be_nil
    end

    it "fails a host without usable KVM with its rung and the fix" do
      preflight = evaluate(from_fixture("kvm64-model"), main_ip: "203.0.113.10")
      expect(check(preflight, "PF3")).to have_attributes(status: "fail",
        detail: start_with("kvm64-class CPU model (Common KVM processor); ladder: kvm_blocked (L2) on unknown platform: the CPU model is the hypervisor's generic"),
        fix: start_with("Give this VM the host's CPU model"))
      expect(preflight).to be_blocking
    end

    it "keeps the script's verdict, with the caveat, when the ladder lacks KVM facts" do
      facts = {"virt" => {"source" => "shell", "facts" => {"arch" => "x86_64", "cpu_model" => "Xeon", "cpu_flags" => %w[vmx pdpe1gb], "dev_kvm" => true}}}
      preflight = evaluate(parse({}, facts))
      expect(check(preflight, "PF3")).to have_attributes(status: "pass",
        detail: "PF3 detail; ladder: kvm (L1) on unknown platform: /dev/kvm exists (not opened); some KVM facts were not gathered (kvm_open, kvm_create_vm, kvm_capabilities, firmware); Prog::LearnVirt checks them at prep")
    end

    it "keeps the script's PF3 without facts, or when told to leave them unused" do
      expect(check(evaluate(from_fixture("old-script"), main_ip: "203.0.113.10"), "PF3").detail).to eq "/dev/kvm present (Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz)"
      preflight = evaluate(from_fixture("no-kvm"), main_ip: "203.0.113.10", ladder: false)
      expect(check(preflight, "PF3").detail).to eq "no /dev/kvm"
      expect(preflight.virt_verdict).to be_nil
    end

    it "passes a host without KVM on a lower tier it is ready for, in a location that offers it" do
      offer("container")
      preflight = evaluate(from_fixture("no-kvm-container"), main_ip: "203.0.113.10", virt_tier: "container")
      expect(check(preflight, "PF3")).to have_attributes(status: "pass", fix: "", detail: start_with("container: none (L3-L5) on unknown platform: this VM (kvm) gets no hardware virtualization"))
      expect(check(preflight, "PF3-tier").to_h).to include(status: "pass", detail: "location byoh-pf offers container (L3, experimental)")
      expect(%w[PF4 PF5 PF7].map { check(preflight, it).to_h.values_at(:status, :detail) }).to eq [
        ["info", "not needed by a container host: pdpe1gb flag present"],
        ["info", "not needed by a container host: /etc/default/grub and update-grub present"],
        ["info", "not needed by a container host: 64 GiB of memory gives 57 1G hugepages"],
      ]
      expect(preflight).not_to be_blocking
    end

    it "fails a lower tier the host cannot run, or a location does not offer" do
      preflight = evaluate(from_fixture("no-kvm"), main_ip: "203.0.113.10", virt_tier: "container")
      expect(check(preflight, "PF3")).to have_attributes(status: "fail", detail: start_with("container: kvm_blocked (L2)"), fix: start_with("This host cannot run container"))
      expect(check(preflight, "PF3-tier")).to have_attributes(status: "fail", detail: "location byoh-pf does not offer container hosts",
        fix: "bin/byoh-location rates --location byoh-pf --family container --from standard --multiplier <X>; bin/byoh-location set --location byoh-pf --virt-tiers kvm,container --accept container")
      expect(check(evaluate(from_fixture("base"), main_ip: "203.0.113.10", virt_tier: "container"), "PF3").fix).to eq "This host runs KVM (L1); register it as kvm."
    end

    it "says a lower tier with an unchecked need is checked at prep, and notes a script without facts" do
      offer("emulated")
      facts = {"virt" => {"source" => "shell", "facts" => {"arch" => "x86_64", "cpu_flags" => [], "dev_kvm" => false, "virt_vm" => "kvm", "commands" => {}}}}
      preflight = evaluate(parse({}, facts), virt_tier: "container")
      expect(check(preflight, "PF3")).to have_attributes(status: "info", detail: include("; Could not check that this host has an x86_64 CPU, cgroup v2"))
      preflight = evaluate(from_fixture("old-script"), main_ip: "203.0.113.10", virt_tier: "emulated")
      expect(check(preflight, "PF3").to_h).to include(status: "info",
        detail: "not needed by a emulated host: /dev/kvm present (Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz); the host reported no virtualization facts, so Prog::LearnVirt checks the tier at prep")
      expect(status(preflight, "PF3-tier")).to eq "pass"
    end

    it "fails a tier this control plane cannot register, and skips the location check without a location" do
      preflight = evaluate(from_fixture("no-kvm"), main_ip: "203.0.113.10", virt_tier: "pvm")
      expect(check(preflight, "PF3-tier").to_h).to include(status: "fail", detail: "pvm hosts are not available yet (docs/byoh/NO_KVM.md section 11)")
      preflight = from_fixture("no-kvm").evaluate(main_ip: "203.0.113.10", virt_tier: "container")
      expect(check(preflight, "PF3-tier")).to be_nil
    end
  end

  describe "#evaluate" do
    it "leaves an unreadable output alone" do
      preflight = described_class.parse("", "n0nce")
      expect(evaluate(preflight).checks.map(&:id)).to eq ["preflight"]
    end

    it "passes a sound host with sound arguments" do
      preflight = evaluate(services: {"ubicloud-web" => true, "ubicloud-respirate" => true})
      expect(preflight.checks.drop(described_class::HOST_CHECKS.size).map { [it.id, it.status, it.detail] }).to eq [
        ["PF17-route", "pass", "default route via 10.0.0.1 on eth0, uplink IP 10.0.0.5"],
        ["PF17-main-ip", "pass", "main IP 10.0.0.5 is on the host"],
        ["PF17", "info", "no pools declared; only IPv6-only VMs will be placed on this host"],
        ["PF20", "pass", "location byoh-pf, boot image(s) ubuntu-noble for x64"],
        ["PF21", "pass", "ubicloud-web and ubicloud-respirate are active"],
      ]
      expect(preflight.uplink_ip).to eq "10.0.0.5"
      expect(preflight.gateway).to eq "10.0.0.1"
      expect(preflight).not_to be_blocking
    end

    it "evaluates the base fixture host" do
      preflight = evaluate(from_fixture("base"), main_ip: "203.0.113.10", pools: pools("8.8.8.0/29,exposure=public"))
      expect(preflight.uplink_ip).to eq "203.0.113.10"
      expect(status(preflight, "PF17")).to eq "pass"
      expect(check(preflight, "PF17-netplan").detail).to eq "the cloud-init netplan gives eno1 at most one IPv4 address"
      expect(preflight).not_to be_blocking
    end

    describe "PF17 and contract C5" do
      it "refuses a routed pool holding the uplink IP and a local address" do
        facts = {"ip_addr" => [{"ifname" => "eth0", "addr_info" => [{"family" => "inet", "local" => "10.0.0.5"}, {"family" => "inet", "local" => "10.0.0.6"}]}]}
        preflight = evaluate(parse({}, facts), main_ip: "203.0.113.10", pools: pools("10.0.0.4/30"))
        expect(check(preflight, "PF17")).to have_attributes(status: "fail", detail: "10.0.0.4/30 hands the uplink IP 10.0.0.5 to VMs; declare pools without it, or reserve it; " \
          "10.0.0.4/30: 10.0.0.6 is configured on the host; remove it from the interface, since the host must not answer for a VM address (contract C5)")
        expect(status(preflight, "PF17-main-ip")).to eq "warn"
        expect(preflight).to be_blocking
      end

      it "refuses an onlink pool that hands out the gateway" do
        facts = {"ip_route" => [{"dst" => "default", "gateway" => "10.0.0.1", "dev" => "eth0"}]}
        onlink = "10.0.0.0/28,delivery=onlink,segment=10.0.0.0/24,gateway=10.0.0.1,reserve=10.0.0.5"
        expect(status(evaluate(parse({}, facts), main_ip: "203.0.113.10", pools: pools(onlink)), "PF17")).to eq "pass"
        preflight = evaluate(parse({}, facts), main_ip: "203.0.113.10", pools: pools("#{onlink},usable=all"))
        expect(check(preflight, "PF17").detail).to eq "10.0.0.0/28 hands the default gateway 10.0.0.1 to VMs; declare pools without it, or reserve it"
      end

      it "refuses a nat pool holding the uplink IP" do
        preflight = evaluate(main_ip: "203.0.113.10", pools: pools("10.0.0.5/32,delivery=fabric,exposure=nat,external=10.0.0.5:8.8.4.20"))
        expect(check(preflight, "PF17").detail).to eq "10.0.0.5/32 hands the uplink IP 10.0.0.5 to VMs; declare pools without it, or reserve it"
      end

      it "includes the registration rules when the location resolves" do
        preflight = evaluate(main_ip: "10.0.0.5", pools: pools("10.0.0.4/30"))
        expect(check(preflight, "PF17").detail).to start_with "10.0.0.4/30 contains main_ip 10.0.0.5"
      end

      it "checks against the host alone without a location" do
        preflight = parse.evaluate(main_ip: "10.0.0.5", location: nil, location_name: "nowhere", boot_images: ["ubuntu-noble"], pools: pools("10.1.0.0/30"))
        expect(check(preflight, "PF17").detail).to eq "1 pool(s) hand VMs no address of the host (against the host only; the location did not resolve)"
        expect(check(preflight, "PF20").detail).to eq "location nowhere does not exist"
        preflight = parse.evaluate(main_ip: "203.0.113.10", boot_images: ["ubuntu-noble"], pools: pools("10.0.0.4/30"))
        expect(check(preflight, "PF17").detail).to start_with "10.0.0.4/30 hands the uplink IP 10.0.0.5"
        expect(check(preflight, "PF20").detail).to eq "no location given"
      end

      it "fails without a default route" do
        preflight = evaluate(parse({}, "ip_route" => nil, "netplan" => "network: {}"))
        expect(check(preflight, "PF17-route")).to have_attributes(status: "fail", detail: "no IPv4 default route; the host needs one for egress and as its uplink")
        expect(preflight.uplink_ip).to be_nil
        expect(check(preflight, "PF17-netplan")).to be_nil
      end

      it "takes the uplink IP from the route's interface when the route has no source" do
        preflight = evaluate(parse({}, "ip_route" => [{"dst" => "default", "dev" => "eth0"}, {"dst" => "10.0.0.0/24", "dev" => "eth0"}]))
        expect(check(preflight, "PF17-route").detail).to eq "default route via a device route on eth0, uplink IP 10.0.0.5"
      end

      it "fails when the route's interface has no IPv4 address" do
        preflight = evaluate(parse({}, "ip_route" => [{"dst" => "default", "dev" => "eth1", "gateway" => "10.9.0.1"}]))
        expect(check(preflight, "PF17-route").detail).to eq "the default route on eth1 has no IPv4 source address"
      end

      it "needs --uplink-ip to choose between two default routes" do
        routes = [
          {"dst" => "default", "gateway" => "192.168.1.1", "dev" => "eth1", "metric" => 200},
          {"dst" => "default", "gateway" => "10.0.0.1", "dev" => "eth0", "metric" => 100},
        ]
        addr = self.addr + [{"ifname" => "eth2", "addr_info" => [{"family" => "inet", "local" => "192.168.1.20"}]}]
        preflight = evaluate(parse({}, "ip_route" => routes, "ip_addr" => addr))
        expect(check(preflight, "PF17-route")).to have_attributes(status: "fail", detail: "2 IPv4 default routes (eth0, eth1); the uplink is ambiguous")
        expect(preflight.uplink_ip).to eq "10.0.0.5"

        preflight = evaluate(parse({}, "ip_route" => routes), uplink_ip: "10.0.0.5")
        expect(check(preflight, "PF17-route")).to have_attributes(status: "warn", detail: "2 IPv4 default routes (eth0, eth1); uplink 10.0.0.5 given with --uplink-ip")

        routes[0] = routes[0].merge("prefsrc" => "192.168.1.20")
        preflight = evaluate(parse({}, "ip_route" => routes, "ip_addr" => addr), uplink_ip: "192.168.1.20")
        expect(preflight.uplink_ip).to eq "192.168.1.20"
        expect(status(preflight, "PF17-route")).to eq "warn"
      end

      it "refuses an --uplink-ip on an interface without a default route" do
        # 192.168.1.20 is on eth2; the default routes leave by eth0 and
        # eth1, so neither gateway belongs to the named uplink.
        routes = [
          {"dst" => "default", "gateway" => "192.168.1.1", "dev" => "eth1", "metric" => 200},
          {"dst" => "default", "gateway" => "10.0.0.1", "dev" => "eth0", "metric" => 100},
        ]
        addr = self.addr + [{"ifname" => "eth2", "addr_info" => [{"family" => "inet", "local" => "192.168.1.20"}]}]
        # The pool holds eth0's gateway 10.0.0.1, which is not the named
        # uplink's gateway, so PF17 must not judge the pool against it.
        preflight = evaluate(parse({}, "ip_route" => routes, "ip_addr" => addr), uplink_ip: "192.168.1.20", uplink: "eth0", pools: pools("10.0.0.0/30"))
        expect(check(preflight, "PF17-route")).to have_attributes(status: "fail",
          detail: "--uplink-ip 192.168.1.20 is not on an interface with a default route (eth0, eth1)")
        expect(check(preflight, "PF17")).to have_attributes(status: "pass", detail: "1 pool(s) hand VMs no address of the host")
        expect(preflight.uplink_ip).to eq "192.168.1.20"
        expect(check(preflight, "PF17-uplink")).to be_nil
        expect(check(preflight, "PF17-netplan")).to be_nil
        expect(preflight).to be_blocking
      end

      it "reads two default routes from the fixture host" do
        expect(status(evaluate(from_fixture("two-default-routes"), main_ip: "203.0.113.10"), "PF17-route")).to eq "fail"
      end

      it "refuses an --uplink-ip that is not on the host" do
        preflight = evaluate(uplink_ip: "10.0.0.99")
        expect(check(preflight, "PF17-route").detail).to eq "--uplink-ip 10.0.0.99 is not an address of the host"
      end

      it "checks the pools file's uplink interface" do
        expect(check(evaluate(uplink: "eth0"), "PF17-uplink")).to have_attributes(status: "pass", detail: "uplink eth0 carries the default route")
        expect(check(evaluate(uplink: "eth1"), "PF17-uplink")).to have_attributes(status: "warn", detail: "the pools file names uplink eth1, but the default route leaves by eth0")
        expect(check(evaluate(uplink: "ens5"), "PF17-uplink").detail).to eq "the pools file names uplink ens5, which is not an interface of the host"
        expect(check(evaluate(parse({}, "ip_route" => nil), uplink: "eth0"), "PF17-uplink")).to be_nil
      end

      it "warns when cloud-init's netplan puts more than one IPv4 address on the uplink" do
        netplan = <<~YAML
          network:
            version: 2
            ethernets:
              nic0:
                set-name: eth0
                dhcp4: true
                addresses: [10.0.0.6/24, "2001:db8::6/64"]
              eth9: {addresses: [10.9.0.1/24, 10.9.0.2/24]}
              broken: 1
        YAML
        preflight = evaluate(parse({}, "netplan" => netplan))
        expect(check(preflight, "PF17-netplan")).to have_attributes(status: "warn", detail: "the cloud-init netplan gives eth0 2 IPv4 addresses; pool addresses there are configured on the host at boot (contract C5)")
        expect(status(evaluate(parse({}, "netplan" => "network:\n  ethernets:\n    eth0: {dhcp4: true}\n")), "PF17-netplan")).to eq "pass"
        expect(status(evaluate(parse({}, "netplan" => "network: 1\n")), "PF17-netplan")).to eq "pass"
        expect(status(evaluate(parse({}, "netplan" => "- 1\n")), "PF17-netplan")).to eq "pass"
        expect(status(evaluate(parse({}, "netplan" => "network:\n  ethernets: [1]\n")), "PF17-netplan")).to eq "pass"
        expect(check(evaluate(parse({}, "netplan" => "network: [")), "PF17-netplan")).to have_attributes(status: "info", detail: "the cloud-init netplan is not valid YAML")
      end
    end

    describe "PF20" do
      it "fails without boot images" do
        expect(check(evaluate(boot_images: []), "PF20").detail).to eq "no boot image given (--default-boot-image)"
      end

      it "fails on unknown and blob-storage images" do
        preflight = evaluate(boot_images: ["ubuntu-noble", "ubuntu-hardy", "github-ubuntu-2404"])
        expect(check(preflight, "PF20")).to have_attributes(status: "fail",
          detail: "ubuntu-hardy is not a known boot image for x64; github-ubuntu-2404 is served only from Ubicloud's blob storage")
      end

      it "fails on an architecture without images" do
        preflight = evaluate(parse({}, "arch" => "riscv64"))
        expect(check(preflight, "PF20").detail).to eq "host architecture riscv64 has no boot images"
      end

      it "fails when production fetches images from storage the control plane lacks" do
        allow(Config).to receive_messages(production?: true, boot_image_source: "auto")
        expect(check(evaluate, "PF20").detail).to start_with "BOOT_IMAGE_SOURCE=auto fetches every boot image from Ubicloud's R2 storage"
      end

      it "takes blob-storage images when production fetches every image from R2" do
        allow(Config).to receive_messages(production?: true, boot_image_source: "auto", ubicloud_images_r2_bucket_name: "b",
          ubicloud_images_r2_endpoint: "https://r2.example", ubicloud_images_r2_access_key: "a", ubicloud_images_r2_secret_key: "s")
        preflight = evaluate(boot_images: ["ubuntu-noble", "github-ubuntu-2404", "ubuntu-hardy"])
        expect(check(preflight, "PF20").detail).to eq "ubuntu-hardy is not a known boot image for x64"
        expect(status(evaluate(boot_images: ["github-ubuntu-2404"]), "PF20")).to eq "pass"
      end

      it "keeps refusing blob-storage images in production with public sources" do
        allow(Config).to receive_messages(production?: true, boot_image_source: "public")
        expect(check(evaluate(boot_images: ["github-ubuntu-2404"]), "PF20").detail).to eq "github-ubuntu-2404 is served only from Ubicloud's blob storage"
      end

      it "checks arm64 images" do
        expect(check(evaluate(from_fixture("arm-biglittle"), main_ip: "203.0.113.10"), "PF20").detail).to eq "location byoh-pf, boot image(s) ubuntu-noble for arm64"
      end
    end

    describe "PF21" do
      it "reports a development layout" do
        expect(check(evaluate, "PF21").status).to eq "info"
      end

      it "fails when a service is not active" do
        preflight = evaluate(services: {"ubicloud-web" => true, "ubicloud-respirate" => false})
        expect(check(preflight, "PF21")).to have_attributes(status: "fail", detail: "ubicloud-respirate not active, so a registered host would never be set up", fix: "systemctl start ubicloud.target")
      end
    end

    describe "minimum CPUs" do
      it "fails a host with one CPU even if the script passed it" do
        preflight = evaluate(parse({}, "cpus_online" => 1))
        expect(check(preflight, "PF-min-cpu")).to have_attributes(status: "fail", detail: "1 online CPU(s); at least 2 are needed")
        expect(preflight.checks.count { it.id == "PF-min-cpu" }).to eq 1
      end

      it "keeps the script's own fail" do
        preflight = evaluate(from_fixture("one-cpu"), main_ip: "203.0.113.10")
        expect(check(preflight, "PF-min-cpu").detail).to eq "1 online CPU(s); at least 2 are needed"
      end
    end
  end

  describe "#boot_image_urls" do
    it "gives the public mirror of each usable image" do
      urls = parse.boot_image_urls(["ubuntu-noble", "github-ubuntu-2404", "ubuntu-hardy"])
      version = Prog::DownloadBootImage::BOOT_IMAGE_SHA256["ubuntu-noble"]["x64"].keys.max
      expect(urls).to eq ["https://cloud-images.ubuntu.com/releases/noble/release-#{version}/ubuntu-24.04-server-cloudimg-amd64.img"]
      expect(from_fixture("arm-biglittle").boot_image_urls(["ubuntu-noble"]).first).to end_with "-arm64.img"
    end

    it "gives none when production fetches every image from blob storage" do
      allow(Config).to receive_messages(production?: true, boot_image_source: "auto")
      expect(parse.boot_image_urls(["ubuntu-noble"])).to eq []
      allow(Config).to receive(:boot_image_source).and_return("public")
      expect(parse.boot_image_urls(["ubuntu-noble"]).size).to eq 1
    end

    it "gives none for an unknown architecture" do
      expect(parse({}, "arch" => "riscv64").boot_image_urls(["ubuntu-noble"])).to eq []
    end
  end

  describe "#accept" do
    it "downgrades an accepted fail to a warning" do
      preflight = from_fixture("intel-hybrid").accept(["PF8"])
      expect(check(preflight, "PF8-hybrid")).to have_attributes(status: "warn", accepted: true,
        detail: "accepted: Intel hybrid CPU (cpu_core and cpu_atom PMUs); VMs get a mix of performance and efficiency cores, and placement does not tell them apart")
      expect(preflight).not_to be_blocking
      expect(from_fixture("intel-hybrid").accept(["PF8-hybrid"])).not_to be_blocking
    end

    it "leaves a hybrid host blocked without it" do
      expect(from_fixture("intel-hybrid")).to be_blocking
      expect(status(from_fixture("intel-hybrid"), "PF8-hybrid")).to eq "fail"
    end

    it "accepts btrfs with the UNVERIFIED note" do
      expect(check(from_fixture("btrfs").accept(["PF10-btrfs"]), "PF10-btrfs").detail).to end_with "VM storage there is UNVERIFIED"
    end

    it "accepts only the overridable PF16 checks" do
      preflight = from_fixture("pve-node").accept(["PF16"])
      expect(status(preflight, "PF16-libvirtd")).to eq "warn"
      expect(status(preflight, "PF16-pve")).to eq "fail"
      expect(status(preflight, "PF16-docker")).to eq "pass"
      expect(preflight).to be_blocking
    end

    it "refuses checks that cannot be accepted, and unknown ones" do
      %w[PF3 PF10-zfs PF16-pve PF16-rhizome-user PF17 PF-min-cpu PF2 PF20].each do |id|
        expect { parse.accept([id]) }.to raise_error(described_class::UsageError, /\A--accept-check #{id}: this check cannot be accepted; only PF8-hybrid, /)
      end
      expect { parse.accept(["PF99"]) }.to raise_error(described_class::UsageError, /\A--accept-check PF99: no such check/)
    end

    it "validates ids before there is any output to accept them on" do
      expect(described_class.validate_accept!(%w[PF8-hybrid PF16])).to eq %w[PF8-hybrid PF16]
      expect { described_class.validate_accept!(%w[PF8-hybrid PF3]) }.to raise_error(described_class::UsageError, /\A--accept-check PF3: this check cannot be accepted/)
    end
  end

  describe "output" do
    let(:preflight) {
      described_class.new([
        described_class::Check.new(id: "PF1", status: "pass", detail: "Ubuntu 24.04 on x86_64", fix: "", accepted: false),
        described_class::Check.new(id: "PF3", status: "fail", detail: "no /dev/kvm", fix: "enable it", accepted: false),
      ], {})
    }

    it "prints a table" do
      expect(preflight.to_table).to eq <<~TABLE
        pass  PF1                Ubuntu 24.04 on x86_64
        fail  PF3                no /dev/kvm
                                 fix: enable it
      TABLE
    end

    it "prints JSON lines" do
      expect(preflight.to_json_lines.lines.map { JSON.parse(it) }).to eq [
        {"id" => "PF1", "status" => "pass", "detail" => "Ubuntu 24.04 on x86_64", "fix" => "", "accepted" => false},
        {"id" => "PF3", "status" => "fail", "detail" => "no /dev/kvm", "fix" => "enable it", "accepted" => false},
      ]
    end
  end

  describe ".service_states" do
    it "is nil on a development layout" do
      expect(described_class.service_states(env_file: "/nonexistent/env")).to be_nil
    end

    it "asks systemctl on the packaged layout" do
      Tempfile.create("env") do |env|
        expect(described_class.service_states(env_file: env.path, runner: ->(unit) { unit == "ubicloud-web" }))
          .to eq("ubicloud-web" => true, "ubicloud-respirate" => false)
        # The test image has no systemd, so nothing is active.
        expect(described_class.service_states(env_file: env.path).values).to eq [false, false]
      end
    end
  end
end
