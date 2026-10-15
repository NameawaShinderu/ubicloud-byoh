# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohGateChecks do
  let(:dir) { Dir.mktmpdir }
  let(:profile) { {"ula48" => "fd00:1:2::/48"} }
  let(:location) {
    Location.create(name: "byoh-gate", display_name: "byoh-gate", ui_name: "BYOH gate", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: profile)
  }
  let(:host) {
    VmHost[ByohRegistration.new(main_ip: "10.98.1.10", location:, pools: [
      "5.9.10.0/30",
      "10.98.1.128/32,delivery=fabric,exposure=nat,external=10.98.1.128:8.8.8.10",
      "10.98.1.129/32,delivery=fabric,exposure=internal",
    ]).register!.id]
  }

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:).run(argv)
    [status, out.string, err.string]
  end

  def rate(location, type, family)
    {"id" => "#{location}-#{type}-#{family}", "resource_type" => type, "resource_family" => family, "location" => location,
     "unit_price" => 0.001, "billed_by" => "duration", "active_from" => Time.utc(2020, 1, 1), "byoc" => false}
  end

  def write_rates(name, rows)
    File.write(File.join(dir, "#{name}.yml"), "---\n" + rows.map { [it].to_yaml.delete_prefix("---\n") }.join)
  end

  def place_vm(ip, name: "vm-#{ip.tr(".", "-")}", **)
    vm = create_vm(vm_host_id: host.id, location_id: location.id, name:, ip4_enabled: true, **)
    row = DB[:ipv4_address].first(ip:)
    AssignedVmAddress.create(ip:, address_id: Address.first(cidr: row[:cidr]).id, dst_vm_id: vm.id, external_ip: row[:external_ip]&.to_s)
    vm.reload
  end

  def ipv4_record(vm, name)
    BillingRecord.create(project_id: vm.project_id, resource_id: vm.id, resource_name: name, amount: 1,
      billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", "hetzner-fsn1")["id"])
  end

  before do
    # Load the memoised rates before any example points the overlay
    # directory at its temporary files.
    BillingRate.rates
    allow(Config).to receive_messages(base_url: "https://cloud.example.com", control_plane_outbound_cidrs: ["198.51.100.7/32"],
      billing_rates_extra_dir: dir)
  end

  after { FileUtils.rm_rf(dir) }

  describe "#run" do
    it "prints the usage without a command" do
      expect(cli).to eq [0, described_class::USAGE, ""]
      expect(cli("--help")[0]).to eq 0
    end

    it "refuses an unknown command, unknown options and extra arguments" do
      status, _, err = cli("frobnicate")
      expect(status).to eq 1
      expect(err).to start_with "! unknown command frobnicate\nUsage:"
      expect(cli("host", "--frob")).to eq [1, "", "! invalid option: --frob\n"]
      expect(cli("host", "extra")).to eq [1, "", "! unexpected argument extra\n"]
    end

    it "needs a generic host and an existing VM" do
      expect(cli("host")).to eq [1, "", "! --host is required\n"]
      expect(cli("host", "--host", "nope")).to eq [1, "", "! no host nope\n"]
      other = create_vm_host
      expect(cli("host", "--host", other.ubid)).to eq [1, "", "! host #{other.ubid} is not a generic (BYOH) host\n"]
      expect(cli("info")).to eq [1, "", "! --vm is required\n"]
      expect(cli("info", "--vm", "nope")).to eq [1, "", "! no VM nope\n"]
      ubid = Vm.generate_ubid.to_s
      expect(cli("info", "--vm", ubid)).to eq [1, "", "! no VM #{ubid}\n"]
    end
  end

  describe "location" do
    let(:minimum) { ByohPreflightWarnings::MINIMUM_RATES.map { |type, family| rate("byoh-gate", type, family) } }

    it "needs an existing location" do
      expect(cli("location")).to eq [1, "", "! --location is required\n"]
      expect(cli("location", "--location", "nowhere")).to eq [1, "", "! no location nowhere\n"]
    end

    it "passes a BYOH location with the minimum rates and every source rate type" do
      write_rates("src", [rate("src", "VmVCpu", "standard"), rate("src", "Gpu", "h100")])
      write_rates("byoh-gate", minimum + [rate("byoh-gate", "Gpu", "h100")])
      location
      status, out, _ = cli("location", "--location", "byoh-gate", "--rates-from", "src")
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        PASS location byoh-gate is a BYOH location
        PASS location byoh-gate has the minimum rates
        PASS every rate type of src (2) is copied to byoh-gate
        ok
      OUT
    end

    it "fails missing rates, uncopied types and a non-BYOH location, and prints the warnings" do
      allow(Config).to receive(:base_url).and_return("http://localhost:9292")
      write_rates("src", [rate("src", "Gpu", "h100")])
      write_rates("byoh-gate", minimum.drop(1))
      location
      status, out, _ = cli("location", "--location", "byoh-gate", "--rates-from", "src")
      expect(status).to eq 1
      expect(out).to include "FAIL location byoh-gate has the minimum rates (missing VmVCpu/standard)\n",
        "FAIL every rate type of src (1) is copied to byoh-gate (missing Gpu/h100)\n",
        "WARN BASE_URL is http://localhost:9292",
        "2 failed\n"

      status, out, _ = cli("location", "--location", "hetzner-fsn1", "--rates-from", "nowhere")
      expect(status).to eq 1
      expect(out).to include "FAIL location hetzner-fsn1 is a BYOH location\n", "FAIL every rate type of nowhere (0) is copied to hetzner-fsn1\n"
    end

    it "checks the rates only when --rates-from is given" do
      write_rates("byoh-gate", minimum)
      location
      expect(cli("location", "--location", "byoh-gate")[1]).not_to include "every rate type"
    end
  end

  describe "host" do
    it "passes an accepting BYOH host with its registration row" do
      host.update(allocation_state: "accepting")
      place_vm("5.9.10.1", local_vetho_ip: "169.254.3.1/32")
      status, out, _ = cli("host", "--host", host.ubid, "--ipv6-mode", "ula")
      expect(status).to eq 0
      expect(out).to include "PASS host #{host.ubid} is a BYOH host (location byoh-gate)\n",
        "PASS host #{host.ubid} is accepting (accepting)\n",
        "PASS ipv6_mode is ula (ula)\n",
        "PASS net6 #{host.net6} is inside the location's ula48 fd00:1:2::/48\n",
        "PASS a register-byoh-host audit row exists for #{host.ubid}\n",
        "PASS no internet VM holds an internal address\n",
        "INFO verify: /etc/nftables.d/1-byoh-egress.conf is not checked from the database",
        "\nok\n"
    end

    it "fails what the gate needs and reports byoh-pool verify" do
      vm = place_vm("10.98.1.129", local_vetho_ip: "169.254.169.2/32")
      DB[:byoh_operator_action].delete
      status, out, _ = cli("host", "--host", host.ubid, "--ipv6-mode", "gua")
      expect(status).to eq 1
      expect(out).to include "FAIL host #{host.ubid} is accepting (unprepared)\n",
        "FAIL ipv6_mode is gua (ula)\n",
        "FAIL a register-byoh-host audit row exists for #{host.ubid}\n",
        "FAIL #{vm.ubid}: veth address 169.254.169.2/32 is inside 169.254.169.0/24\n",
        "FAIL no internet VM holds an internal address (10.98.1.129)\n",
        "WARN verify: #{vm.ubid}: its veth address"
    end

    it "reports a host moved into BYOH without a registration row as INFO" do
      host.update(allocation_state: "accepting")
      DB[:byoh_operator_action].delete
      ByohOperatorLog.record(command: "move-location", target_id: host.id, args: {from: "hetzner-fsn1", to: "byoh-gate"}, result: "ok")
      status, out, _ = cli("host", "--host", host.ubid)
      expect(status).to eq 0
      expect(out).to include "INFO #{host.ubid} has no register-byoh-host audit row, but a move-location row: it was registered before M2 and moved\n"
      expect(out).not_to include "FAIL"
    end

    it "fails a ULA outside the location's ula48 and passes on verify failures" do
      host
      DB[:location].where(id: location.id).update(byoh_network: Sequel.pg_jsonb({}))
      expect(cli("host", "--host", host.ubid)[1]).to include "FAIL net6 #{host.net6} is inside the location's ula48 (none)\n"

      host.update(ipv6_mode: "gua")
      _, out, _ = cli("host", "--host", host.ubid)
      expect(out).not_to include "ula48"
      expect(out).to include "FAIL verify: ipv6_mode is gua, but net6 #{host.net6} is a ULA\n"
    end

    it "fails a generic host outside a BYOH location" do
      host.update(location_id: Location::HETZNER_FSN1_ID)
      expect(cli("host", "--host", host.ubid)[1]).to include "FAIL host #{host.ubid} is a BYOH host (location hetzner-fsn1)\n",
        "WARN verify: location hetzner-fsn1 is not a BYOH location"
    end
  end

  describe "vm" do
    it "needs --expect" do
      expect(cli("vm", "--vm", "x")).to eq [1, "", "! --expect is required\n"]
      expect(cli("vm", "--vm", "x", "--expect", "odd")[2]).to start_with "! invalid argument: --expect odd"
    end

    it "checks a VM waiting for capacity" do
      vm = place_vm("5.9.10.1")
      expect(cli("vm", "--vm", vm.ubid, "--expect", "waiting")).to eq [1, "FAIL #{vm.ubid} is waiting for capacity (placed on #{host.ubid})\n1 failed\n", ""]
      vm.update(vm_host_id: nil)
      expect(cli("vm", "--vm", vm.ubid, "--expect", "waiting")).to eq [0, "PASS #{vm.ubid} is waiting for capacity\nok\n", ""]
    end

    it "fails a VM that is not on a BYOH host" do
      vm = create_vm
      expect(cli("vm", "--vm", vm.ubid, "--expect", "nat")).to eq [1, "FAIL #{vm.ubid} is not on a BYOH host\n1 failed\n", ""]
    end

    it "passes a nat VM shown, reached and billed at its external IP" do
      vm = place_vm("10.98.1.128")
      Sshable.create_with_id(vm.id, host: "10.98.1.128")
      ipv4_record(vm, "8.8.8.10/32")
      status, out, _ = cli("vm", "--vm", vm.ubid, "--expect", "nat", "--external", "8.8.8.10")
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        PASS #{vm.ubid}'s external IP is 8.8.8.10 (8.8.8.10)
        PASS the API shows 8.8.8.10 with scope public (8.8.8.10, public)
        PASS the IPv4 billing record is named 8.8.8.10/32 (8.8.8.10/32)
        PASS the control plane reaches #{vm.ubid} at 10.98.1.128 (10.98.1.128)
        ok
      OUT
    end

    it "fails a nat VM with the wrong external IP, billing and sshable" do
      vm = place_vm("10.98.1.128")
      _, out, _ = cli("vm", "--vm", vm.ubid, "--expect", "nat", "--external", "8.8.4.4")
      expect(out).to include "FAIL #{vm.ubid}'s external IP is 8.8.4.4 (8.8.8.10)\n",
        "FAIL the IPv4 billing record is named 8.8.8.10/32 (none)\n",
        "INFO #{vm.ubid} has no sshable; wait_sshable dials 10.98.1.128:22\n"

      vm.project.update(billable: false)
      expect(cli("vm", "--vm", vm.ubid, "--expect", "nat")[1]).to include "INFO project #{vm.project.ubid} is not billable"
    end

    it "fails a VM whose sshable points at the wrong address" do
      vm = place_vm("10.98.1.128")
      Sshable.create_with_id(vm.id, host: "10.98.1.200")
      ipv4_record(vm, "8.8.8.10/32")
      status, out, _ = cli("vm", "--vm", vm.ubid, "--expect", "nat")
      expect(status).to eq 1
      expect(out).to end_with "FAIL the control plane reaches #{vm.ubid} at 10.98.1.128 (10.98.1.200)\n1 failed\n"
    end

    it "fails a nat VM without an external IP" do
      vm = place_vm("5.9.10.1")
      expect(cli("vm", "--vm", vm.ubid, "--expect", "nat")[1]).to start_with "FAIL #{vm.ubid} has no external IP\n"
      vm.assigned_vm_address.destroy
      expect(cli("vm", "--vm", vm.reload.ubid, "--expect", "nat")[1]).to start_with "FAIL #{vm.ubid} has no external IP\n"
    end

    it "passes a VM without IPv4 that leaves through the host NAT" do
      vm = create_vm(vm_host_id: host.id, location_id: location.id)
      status, out, _ = cli("vm", "--vm", vm.ubid, "--expect", "none")
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        PASS #{vm.ubid} has no IPv4 address
        PASS #{vm.ubid}'s outbound IPv4 goes through the host NAT
        PASS #{vm.ubid} has no IPv4 billing record
        INFO #{vm.ubid} has no sshable; wait_sshable does not dial it (no IPv4)
        ok
      OUT
    end

    it "passes a public VM shown and billed at its own address" do
      vm = place_vm("5.9.10.1")
      Sshable.create_with_id(vm.id, host: "5.9.10.1")
      ipv4_record(vm, "5.9.10.1/32")
      status, out, _ = cli("vm", "--vm", vm.ubid, "--expect", "public")
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        PASS #{vm.ubid}'s address 5.9.10.1 is in a public pool (exposure public)
        PASS the API shows 5.9.10.1 with scope public (5.9.10.1, public)
        PASS the IPv4 billing record is named 5.9.10.1/32 (5.9.10.1/32)
        PASS the control plane reaches #{vm.ubid} at 5.9.10.1 (5.9.10.1)
        ok
      OUT
    end

    it "fails a public expectation for a nat VM or a VM without IPv4" do
      vm = place_vm("10.98.1.128")
      expect(cli("vm", "--vm", vm.ubid, "--expect", "public")[1]).to include "FAIL #{vm.ubid}'s address 10.98.1.128 is in a public pool (exposure nat, external 8.8.8.10)\n",
        "FAIL the API shows 10.98.1.128 with scope public (8.8.8.10, public)\n"
      other = create_vm(vm_host_id: host.id, location_id: location.id, name: "no-ip4")
      expect(cli("vm", "--vm", other.ubid, "--expect", "public")[1]).to start_with "FAIL #{other.ubid} has no IPv4 address\n"
    end

    it "checks an internal VM" do
      vm = place_vm("10.98.1.129", ip4_exposure: "internal")
      Sshable.create_with_id(vm.id, host: "10.98.1.129")
      status, out, _ = cli("vm", "--vm", vm.ubid, "--expect", "internal")
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        PASS #{vm.ubid} was created with ip4_exposure internal (internal)
        PASS the API shows ip4_scope internal (internal)
        PASS #{vm.ubid}'s outbound IPv4 goes through the host NAT (internal_egress host_nat)
        PASS #{vm.ubid} has no IPv4 billing record
        PASS the control plane reaches #{vm.ubid} at 10.98.1.129 (10.98.1.129)
        ok
      OUT

      other = create_vm(vm_host_id: host.id, location_id: location.id, name: "no-ip4")
      expect(cli("vm", "--vm", other.ubid, "--expect", "internal")[1]).to include "FAIL #{other.ubid} was created with ip4_exposure internal (internet)\n",
        "FAIL the API shows ip4_scope internal (none)\n"
    end
  end

  describe "info" do
    it "prints the VM's addresses" do
      vm = place_vm("10.98.1.128")
      expect(cli("info", "--vm", vm.ubid)).to eq [0, <<~OUT, ""]
        name=vm-10-98-1-128
        host=#{host.ubid}
        host_ip=10.98.1.10
        ip4=10.98.1.128
        public_ip4=8.8.8.10
        ip6=
        private_ip4=
        inhost=#{vm.inhost_name}
      OUT
    end

    it "prints empty values for a VM without a host" do
      vm = create_vm
      expect(cli("info", "--vm", vm.ubid)[1]).to include "host_ip=\n"
      vm.update(vm_host_id: nil)
      expect(cli("info", "--vm", vm.ubid)[1]).to include "host=\nhost_ip=\n"
    end
  end

  describe "snapshot and compare" do
    def snapshot
      status, out, _ = cli("snapshot", "--host", host.ubid)
      expect(status).to eq 0
      File.join(dir, "snap.json").tap { File.write(it, out) }
    end

    it "passes when the counts come back after a VM" do
      path = snapshot
      expect(JSON.parse(File.read(path))).to include("vms" => 0, "free_ipv4" => 6, "assigned_ipv4" => 0, "audit_rows" => 1, "orphaned_vm_billing_records" => 0)
      vm = place_vm("5.9.10.1")
      ByohOperatorLog.record(command: "test", target_id: nil, args: {}, result: "ok")
      expect(cli("compare", "--host", host.ubid, "--snapshot", path)[1]).to include "FAIL vms is back to 0 (1)\n", "FAIL free_ipv4 is back to 6 (5)\n"
      ipv4_record(vm, "5.9.10.1/32")
      vm.assigned_vm_address.destroy
      DB[:vm].where(id: vm.id).delete
      status, out, _ = cli("compare", "--host", host.ubid, "--snapshot", path)
      expect(status).to eq 1
      expect(out).to include "PASS vms is back to 0 (0)\n", "PASS audit rows are kept (1 then 2)\n", "FAIL orphaned_vm_billing_records is back to 0 (1)\n"
      BillingRecord.dataset.destroy
      expect(cli("compare", "--host", host.ubid, "--snapshot", path)[0]).to eq 0
    end

    it "fails a snapshot without audit rows" do
      path = File.join(dir, "old.json")
      File.write(path, "{}")
      expect(cli("compare", "--host", host.ubid, "--snapshot", path)[1]).to include "FAIL audit rows are kept ( then 1)\n"
    end

    it "needs a readable snapshot" do
      expect(cli("compare", "--host", host.ubid)).to eq [1, "", "! --snapshot is required\n"]
      missing = File.join(dir, "missing.json")
      expect(cli("compare", "--host", host.ubid, "--snapshot", missing)[2]).to start_with "! cannot read snapshot #{missing}: No such file"
      File.write(missing, "not json")
      expect(cli("compare", "--host", host.ubid, "--snapshot", missing)[2]).to start_with "! cannot read snapshot #{missing}:"
    end
  end

  describe "health" do
    def page(summary, severity: "error", resource_id: host.id)
      Page.create(summary:, tag: "Test-#{summary}", severity:, resource_id:, details: {})
    end

    it "passes an accepting host with no pages, checkup or unavailable label" do
      host.update(allocation_state: "accepting")
      host.strand.update(label: "wait")
      page("other host", resource_id: create_vm_host.id)
      page("boot id", severity: "info")
      page("resolved").update(resolved_at: Time.now)
      status, out, _ = cli("health", "--host", host.ubid)
      expect(status).to eq 0
      expect(out).to eq <<~OUT
        PASS host #{host.ubid} is a BYOH host, so the M4 health checks apply (location byoh-gate)
        PASS host strand is at wait, not unavailable
        PASS host #{host.ubid} is accepting (accepting)
        PASS checkup is not set (the monitor has not read the host as down)
        INFO open info page: boot id
        PASS no open page for #{host.ubid}
        ok
      OUT
    end

    it "fails an unavailable host the monitor read as down, with its pages" do
      host.update(allocation_state: "unprepared")
      host.strand.update(label: "unavailable")
      host.incr_checkup
      page("#{host.ubid} has an expired deadline!")
      page("#{host.ubid} sshable unreachable", severity: "warning")
      status, out, _ = cli("health", "--host", host.ubid)
      expect(status).to eq 1
      expect(out).to include "FAIL host strand is at unavailable, not unavailable\n",
        "FAIL host #{host.ubid} is accepting (unprepared)\n",
        "FAIL checkup is not set (the monitor has not read the host as down)\n",
        "FAIL open error page: #{host.ubid} has an expired deadline!\n",
        "FAIL open warning page: #{host.ubid} sshable unreachable\n", "5 failed\n"
      expect(out).not_to include "no open page"
    end

    it "fails a generic host outside a BYOH location and one without a strand" do
      host.update(location_id: Location::HETZNER_FSN1_ID, allocation_state: "accepting")
      host.strand.destroy
      out = cli("health", "--host", host.ubid)[1]
      expect(out).to include "FAIL host #{host.ubid} is a BYOH host, so the M4 health checks apply (location hetzner-fsn1)\n",
        "PASS host strand is at (none), not unavailable\n"
    end

    # The host find_host loads, with its sshable loaded, so the stubs on
    # both reach the command (frozen specs cannot stub any instance).
    def probed_host
      h = VmHost[host.id]
      h.update(allocation_state: "accepting")
      expect(VmHost).to receive(:[]).with(host.ubid).and_return(h)
      h.sshable
      h
    end

    [[true, 0, "PASS"], [false, 1, "FAIL"]].each do |healthy, code, word|
      it "runs the health checks over a fresh session with --probe (#{healthy})" do
        h = probed_host
        session = instance_double(Net::SSH::Connection::Session)
        expect(h.sshable).to receive(:start_fresh_session).and_yield(session)
        expect(h).to receive(:perform_health_checks).with(session, test_file_suffix: "soak").and_return(healthy)
        status, out, _ = cli("health", "--host", host.ubid, "--probe")
        expect(status).to eq code
        expect(out).to include "#{word} health checks pass (SMART, read/write, kernel log, clock source)\n"
      end
    end

    it "fails when the probe cannot connect" do
      h = probed_host
      expect(h.sshable).to receive(:start_fresh_session).and_raise(Errno::ECONNREFUSED)
      status, out, _ = cli("health", "--host", host.ubid, "--probe")
      expect(status).to eq 1
      expect(out).to include "FAIL health checks raised Errno::ECONNREFUSED: Connection refused\n", "1 failed\n"
      expect(out).not_to include "health checks pass"
    end
  end
end
