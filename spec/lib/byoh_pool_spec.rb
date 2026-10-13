# frozen_string_literal: true

RSpec.describe ByohPool do
  subject(:pool) { described_class.new(host) }

  let(:profile) { {"ula48" => "fd00:1:2::/48"} }
  let(:location) {
    Location.create(name: "byoh-pool", display_name: "byoh-pool", ui_name: "BYOH pool", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: profile)
  }
  let(:pools) {
    [
      "5.9.10.0/29",
      "10.98.1.128/32,delivery=fabric,exposure=nat,external=10.98.1.128:8.8.8.10",
      "10.98.1.129/32,delivery=fabric,exposure=nat,external=10.98.1.129:8.8.8.11",
      "10.98.2.0/30,exposure=internal",
    ]
  }
  let(:host) { register(pools) }

  def register(pools, main_ip: "10.98.1.10")
    VmHost[ByohRegistration.new(main_ip:, location:, pools:).register!.id]
  end

  def config_networks(vm_host = host)
    vm_host.provider.reload.config["routed_networks"]
  end

  def ipv4_row(ip)
    DB[:ipv4_address].first(ip:)
  end

  def place_vm(ip, name: "vm-#{ip.tr(".", "-")}", vm_host: host)
    vm = create_vm(vm_host_id: vm_host.id, location_id: location.id, name:)
    row = ipv4_row(ip)
    AssignedVmAddress.create(ip:, address_id: Address.first(cidr: row[:cidr]).id, dst_vm_id: vm.id, external_ip: row[:external_ip]&.to_s)
    vm
  end

  def pool_actions
    DB[:byoh_operator_action].where(Sequel.like(:command, "byoh-pool%")).order(:created_at).all
  end

  describe ".load_external_map" do
    it "reads a YAML map" do
      expect(described_class.load_external_map("10.0.0.1: 8.8.8.8\n")).to eq("10.0.0.1" => "8.8.8.8")
    end

    it "reads aws ec2 describe-addresses output, skipping unassociated addresses" do
      json = {"Addresses" => [
        {"PublicIp" => "8.8.8.8", "PrivateIpAddress" => "10.0.0.1"},
        {"PublicIp" => "8.8.8.9"},
        "junk",
      ]}.to_json
      expect(described_class.load_external_map(json)).to eq("10.0.0.1" => "8.8.8.8")
    end

    it "refuses invalid input" do
      expect { described_class.load_external_map("a: [") }.to raise_error(described_class::Error, /not valid YAML or JSON/)
      ["- 10.0.0.1\n", "10.0.0.1: [8.8.8.8]\n"].each do |text|
        expect { described_class.load_external_map(text) }.to raise_error(described_class::Error, /must map pool IPs to external IPs/)
      end
    end
  end

  describe ".trace" do
    it "follows a pool address held by a VM, by either address" do
      vm = place_vm("10.98.1.128")
      lines = described_class.trace("8.8.8.10")
      expect(lines).to eq [
        "pool address  10.98.1.128",
        "external IP   8.8.8.10",
        "pool          10.98.1.128/32 (delivery fabric, exposure nat)",
        "host          #{host.ubid} (10.98.1.10, location byoh-pool)",
        "vm            #{vm.ubid} #{vm.name} (running), external IP 8.8.8.10",
        "The NAT rules and connections are not read from the host. On the host, run:",
        "  sudo ip netns exec #{vm.inhost_name} nft list table ip nat",
        "  sudo ip netns exec #{vm.inhost_name} conntrack -L",
      ]
      expect(described_class.trace("10.98.1.128/32")).to eq lines
    end

    it "shows a free or reserved address and a VM without an external IP" do
      host
      expect(described_class.trace("5.9.10.1").last(2)).to eq ["host          #{host.ubid} (10.98.1.10, location byoh-pool)", "state         free"]
      expect(described_class.trace("5.9.10.1")[1]).to eq "external IP   none"
      DB[:ipv4_address].where(ip: "5.9.10.2").update(reserved: true)
      expect(described_class.trace("5.9.10.2").last).to eq "state         reserved"
      vm = place_vm("5.9.10.3")
      expect(described_class.trace("5.9.10.3")[4]).to eq "vm            #{vm.ubid} #{vm.name} (running), external IP none"
    end

    it "names a host's own address" do
      host
      expect(described_class.trace("10.98.1.10")).to eq ["10.98.1.10 is inside 10.98.1.10/32, but no VM can take it: it is a host's own address"]
    end

    it "refuses an address it does not know" do
      expect { described_class.trace("nope") }.to raise_error(described_class::Error, "nope is not an IPv4 address")
      expect { described_class.trace("9.9.9.9") }.to raise_error(described_class::Error, "9.9.9.9 is neither a pool address nor an external IP of any host")
    end
  end

  describe "#export" do
    it "prints the registered pools as pools.yaml v2" do
      yaml, notes = pool.export
      expect(notes).to eq []
      expect(YAML.safe_load(yaml)).to eq(
        "version" => 2,
        "ipv6_mode" => "ula",
        "routed_networks" => [
          {"cidr" => "5.9.10.0/29", "delivery" => "routed", "exposure" => "public"},
          {"cidr" => "10.98.1.128/32", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.1.128" => "8.8.8.10"}},
          {"cidr" => "10.98.1.129/32", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.1.129" => "8.8.8.11"}},
          {"cidr" => "10.98.2.0/30", "delivery" => "routed", "exposure" => "internal"},
          {"cidr" => host.net6.to_s, "ndp" => false},
        ],
      )
    end

    it "exports the database shape with overrides and an external map, reserving or internalising addresses without one" do
      host = register(["10.98.1.128/32", "10.98.1.129/32", "10.98.3.0/30,reserve=10.98.3.3"])
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("uplink" => "ens5")))
      map = {"10.98.1.128" => "8.8.8.10", "10.98.3.0" => "8.8.8.20", "10.98.3.1" => "8.8.8.21"}
      yaml, notes = described_class.new(host).export(set: {"delivery" => "fabric", "exposure" => "nat"}, external_map: map)
      expect(notes).to eq ["10.98.1.129/32: no external IP, exported as exposure internal", "10.98.3.2: no external IP, exported as reserved"]
      document = YAML.safe_load(yaml)
      expect(document["uplink"]).to eq "ens5"
      expect(document["routed_networks"].first(3)).to eq [
        {"cidr" => "10.98.1.128/32", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.1.128" => "8.8.8.10"}},
        {"cidr" => "10.98.1.129/32", "delivery" => "fabric", "exposure" => "internal"},
        {"cidr" => "10.98.3.0/30", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.3.0" => "8.8.8.20", "10.98.3.1" => "8.8.8.21"}, "reserve" => ["10.98.3.3", "10.98.3.2"]},
      ]
      entries = ByohPoolDeclaration.parse_yaml(yaml).entries
      expect(entries.map(&:exposure)).to eq ["nat", "internal", "nat", nil]
    end

    it "exports a nat block with no external IP at all as fully reserved" do
      host = register(["10.98.3.0/31"])
      yaml, notes = described_class.new(host).export(set: {"exposure" => "nat"})
      expect(notes).to eq ["10.98.3.0: no external IP, exported as reserved", "10.98.3.1: no external IP, exported as reserved"]
      expect(YAML.safe_load(yaml)["routed_networks"].first).to eq("cidr" => "10.98.3.0/31", "delivery" => "routed", "exposure" => "nat", "reserve" => ["10.98.3.0", "10.98.3.1"])
    end

    it "keeps an onlink pool's segment without listing its derived reservations" do
      host = register(["192.168.5.8/29,delivery=onlink,segment=192.168.5.0/24,gateway=192.168.5.9,reserve=192.168.5.10"], main_ip: "192.168.5.2")
      yaml, _ = described_class.new(host).export
      expect(YAML.safe_load(yaml)["routed_networks"].first).to eq(
        "cidr" => "192.168.5.8/29", "delivery" => "onlink", "exposure" => "internal", "reserve" => ["192.168.5.10"],
        "segment" => "192.168.5.0/24", "gateway" => "192.168.5.9",
      )
    end

    it "keeps an onlink pool's derived reservations when it leaves onlink delivery" do
      host = register([
        "192.168.5.8/29,delivery=onlink,segment=192.168.5.0/24,gateway=192.168.5.9,reserve=192.168.5.10",
        "192.168.5.16/30,delivery=onlink,segment=192.168.5.0/24,gateway=192.168.5.1,usable=all",
      ], main_ip: "192.168.5.2")
      yaml, notes = described_class.new(host).export(set: {"delivery" => "fabric"})
      expect(notes).to eq ["192.168.5.8/29: leaves onlink delivery but keeps 192.168.5.9 reserved"]
      expect(YAML.safe_load(yaml)["routed_networks"].first(2)).to eq [
        {"cidr" => "192.168.5.8/29", "delivery" => "fabric", "exposure" => "internal", "reserve" => ["192.168.5.9", "192.168.5.10"]},
        {"cidr" => "192.168.5.16/30", "delivery" => "fabric", "exposure" => "internal"},
      ]
      described_class.new(host).annotate(ByohPoolDeclaration.parse_yaml(yaml).entries.select(&:ipv4?))
      expect(ipv4_row("192.168.5.9")[:reserved]).to be true
    end

    it "exports a registered pool that is not declared" do
      address = Address.create(cidr: "5.9.20.0/30", routed_to_host_id: host.id)
      address.populate_ipv4_addresses
      yaml, _ = pool.export
      expect(YAML.safe_load(yaml)["routed_networks"]).to include("cidr" => "5.9.20.0/30", "delivery" => "routed", "exposure" => "public")
    end

    it "refuses unknown overrides and exports that would not parse" do
      expect { pool.export(set: {"usable" => "all"}) }.to raise_error(described_class::Error, "--set takes delivery and exposure, not usable")
      expect { pool.export(set: {"delivery" => "onlink"}) }.to raise_error(described_class::Error, /cannot export 5.9.10.0\/29: .*an onlink pool needs segment/)
      Address.create(cidr: "5.9.0.0/30", routed_to_host_id: host.id)
      expect { pool.export(set: {"delivery" => "onlink"}) }.to raise_error(described_class::Error, /cannot export 5.9.0.0\/30/)
    end
  end

  describe "#add" do
    it "declares and registers new pools without touching VMs, rebuilding the firewall" do
      host.update(allocation_state: "accepting")
      vm = place_vm("5.9.10.1")
      entries = [ByohPoolDeclaration.parse("10.98.4.0/30"), ByohPoolDeclaration.parse("5.9.30.0/31,exposure=public")]
      expect(pool.add(entries)).to eq ["10.98.4.0/30: no exposure given, using internal because it is not globally routable"]
      expect(config_networks.last(2)).to eq [
        {"cidr" => "10.98.4.0/30", "delivery" => "routed", "exposure" => "internal"},
        {"cidr" => "5.9.30.0/31", "delivery" => "routed", "exposure" => "public"},
      ]
      expect(DB[:address].where(cidr: ["10.98.4.0/30", "5.9.30.0/31"]).select_order_map([:cidr, :exposure]).map { [it[0].to_s, it[1]] })
        .to eq [["5.9.30.0/31", "public"], ["10.98.4.0/30", "internal"]]
      expect(DB[:ipv4_address].where(cidr: "10.98.4.0/30").count).to eq 4
      expect(Strand.where(prog: "SetupNftables").count).to eq 1
      expect(vm.reload.assigned_vm_address.ip.to_s).to eq "5.9.10.1/32"
      expect(pool_actions.map { it.values_at(:command, :target_id, :result) }).to eq [["byoh-pool add", host.id, "ok"]]
    end

    it "keeps legacy stored pools working when adding to a registered host" do
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => ["10.98.9.1", *config_networks])))
      Address.create(cidr: "10.98.9.1/32", routed_to_host_id: host.id).populate_ipv4_addresses
      expect(pool.add([ByohPoolDeclaration.parse("10.98.4.0/30,exposure=internal")])).to eq []
      expect(Strand.where(prog: "SetupNftables").count).to eq 0
    end

    it "refuses empty, IPv6, already declared and invalid pools" do
      expect { pool.add([]) }.to raise_error(described_class::Error, "no pools given")
      expect { pool.add([ByohPoolDeclaration.parse("fd00:1:2:3::/64")]) }.to raise_error(described_class::Error, /change the IPv6 network with ipv6 set/)
      expect { pool.add([ByohPoolDeclaration.parse("5.9.10.0/29")]) }.to raise_error(described_class::Error, "5.9.10.0/29 is already registered; change it with annotate")
      expect { pool.add([ByohPoolDeclaration.parse("10.98.1.10/32,exposure=internal")]) }.to raise_error(described_class::Error, "10.98.1.10/32 is already registered; change it with annotate")
      expect { pool.add([ByohPoolDeclaration.parse("10.98.2.0/31,exposure=internal")]) }.to raise_error(described_class::Error, /10.98.2.0\/31 overlaps 10.98.2.0\/30/)
      expect(pool_actions).to eq []
    end
  end

  describe "#add of a declared pool without address rows" do
    before do
      networks = config_networks + ["10.98.9.0/30", {"cidr" => "10.98.8.0/30", "exposure" => "internal"}]
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => networks)))
    end

    it "refuses to register such pools unchecked as a side effect" do
      expect { pool.add([ByohPoolDeclaration.parse("10.98.4.0/30")]) }
        .to raise_error(described_class::Error, "10.98.9.0/30, 10.98.8.0/30 declared but not registered; add them in this command too, or remove them first")
      expect(DB[:address].where(cidr: ["10.98.4.0/30", "10.98.9.0/30", "10.98.8.0/30"]).count).to eq 0
    end

    it "follows verify's advice: add validates and registers them, replacing their declarations" do
      expect(pool.verify.first(2)).to eq [
        [:fail, "10.98.9.0/30 is declared but not registered; register it with add, or drop it with remove"],
        [:fail, "10.98.8.0/30 is declared but not registered; register it with add, or drop it with remove"],
      ]
      expect { pool.add([ByohPoolDeclaration.parse("10.98.9.0/29,exposure=internal"), ByohPoolDeclaration.parse("10.98.8.0/30,exposure=internal")]) }
        .to raise_error(described_class::Error, /10.98.9.0\/30 declared but not registered/)
      pool.add([ByohPoolDeclaration.parse("10.98.9.0/30,exposure=internal,reserve=10.98.9.3"), ByohPoolDeclaration.parse("10.98.8.0/30,exposure=internal")])
      expect(config_networks.last(2)).to eq [
        {"cidr" => "10.98.9.0/30", "delivery" => "routed", "exposure" => "internal", "reserve" => ["10.98.9.3"]},
        {"cidr" => "10.98.8.0/30", "delivery" => "routed", "exposure" => "internal"},
      ]
      expect(config_networks.count { (it.is_a?(Hash) ? it["cidr"] : it).start_with?("10.98.9.0") }).to eq 1
      expect(ipv4_row("10.98.9.3")[:reserved]).to be true
      expect(pool.verify).to eq [[:unverified, "/etc/nftables.d/1-byoh-egress.conf is not checked from the database; on the host, run: sudo nft list table inet byoh_egress"]]
    end

    it "follows verify's other advice: remove drops them" do
      pool.remove("10.98.9.0/30")
      pool.remove("10.98.8.0/30")
      expect(pool.verify.map(&:first)).to eq [:unverified]
    end
  end

  describe "#remove" do
    it "removes a pool without VMs" do
      host.update(allocation_state: "accepting")
      expect(pool.remove("10.98.2.0/30")).to eq []
      expect(DB[:address].where(cidr: "10.98.2.0/30").count).to eq 0
      expect(DB[:ipv4_address].where(cidr: "10.98.2.0/30").count).to eq 0
      expect(config_networks.map { it["cidr"] }).not_to include "10.98.2.0/30"
      expect(Strand.where(prog: "SetupNftables").count).to eq 1
      expect(pool_actions.map { [it[:command], it[:args].to_h] }).to eq [["byoh-pool remove", {"cidr" => "10.98.2.0/30"}]]
    end

    it "removes a pool that is only declared, or only registered" do
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => [*config_networks, "10.98.9.0/30"])))
      pool.remove("10.98.9.0/30")
      expect(config_networks.map { it.is_a?(Hash) ? it["cidr"] : it }).not_to include "10.98.9.0/30"
      Address.create(cidr: "5.9.20.0/30", routed_to_host_id: host.id).populate_ipv4_addresses
      pool.remove("5.9.20.0/30")
      expect(DB[:address].where(cidr: "5.9.20.0/30").count).to eq 0
    end

    it "refuses a pool with VMs unless draining, then destroys them and waits" do
      vm = place_vm("5.9.10.1")
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "wait")
      expect { pool.remove("5.9.10.0/29") }.to raise_error(described_class::Error, "5.9.10.0/29 has VMs #{vm.ubid}; destroy them first, or pass --drain to destroy them")

      sleeper = ->(seconds) {
        expect(seconds).to eq 5
        expect(DB[:ipv4_address].where(cidr: "5.9.10.0/29", reserved: false).count).to eq 0
        expect(Semaphore.where(strand_id: vm.id, name: "destroy").count).to eq 1
        vm.assigned_vm_address.destroy
      }
      pool = described_class.new(host, sleeper:, drain_polls: 2)
      expect(pool.remove("5.9.10.0/29", drain: true)).to eq []
      expect(DB[:address].where(cidr: "5.9.10.0/29").count).to eq 0
      expect(pool_actions.map { [it[:command], it[:args].to_h] }).to eq [
        ["byoh-pool remove-drain", {"cidr" => "5.9.10.0/29", "vms" => [vm.ubid]}],
        ["byoh-pool remove", {"cidr" => "5.9.10.0/29", "drained_vms" => [vm.ubid]}],
      ]
    end

    it "checks once more after its last wait" do
      vm = place_vm("5.9.10.1")
      pool = described_class.new(host, sleeper: ->(_) { vm.assigned_vm_address.destroy }, drain_polls: 1)
      expect(pool.remove("5.9.10.0/29", drain: true)).to eq []
    end

    it "refuses to drain VMs that their owners destroy, or that prevent_destroy protects" do
      owned = place_vm("5.9.10.1")
      pg = create_postgres_resource(project: owned.project, location_id: Location::HETZNER_FSN1_ID)
      PostgresServer.create(timeline: create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID), resource: pg, vm_id: owned.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")
      protected_vm = place_vm("5.9.10.3")
      Strand.create_with_id(protected_vm, prog: "Vm::Nexus", label: "wait")
      protected_vm.incr_prevent_destroy
      reserved = DB[:ipv4_address].where(cidr: "5.9.10.0/29", reserved: true).select_order_map(:ip)
      blocked = {owned => "belongs to a PostgresServer", protected_vm => "prevent_destroy is set"}.sort_by { it.first.id }.map { "#{it.first.ubid} (#{it.last})" }
      expect { pool.remove("5.9.10.0/29", drain: true) }.to raise_error(described_class::Error,
        "5.9.10.0/29 cannot be drained: #{blocked.join(", ")}; destroy those through their owner or clear prevent_destroy, then remove the pool")
      expect(DB[:ipv4_address].where(cidr: "5.9.10.0/29", reserved: true).select_order_map(:ip)).to eq reserved
      expect(Semaphore.where(name: "destroy").count).to eq 0
      expect(pool_actions).to eq []
    end

    it "gives up waiting for drained VMs" do
      vm = place_vm("5.9.10.1")
      pool = described_class.new(host, sleeper: ->(_) {}, drain_polls: 1)
      expect { pool.remove("5.9.10.0/29", drain: true) }.to raise_error(described_class::Error, /its VMs are still being destroyed/)
      expect(vm.reload.assigned_vm_address).not_to be_nil
      expect(DB[:address].where(cidr: "5.9.10.0/29").count).to eq 1
    end

    it "drains nothing for a pool without VMs" do
      expect(pool.remove("10.98.2.0/30", drain: true)).to eq []
      expect(pool_actions.map { it[:command] }).to eq ["byoh-pool remove"]
    end

    it "refuses what is not a removable pool" do
      host
      expect { pool.remove("10.98.2.1/30") }.to raise_error(described_class::Error, "10.98.2.1/30 is not a CIDR (address/prefix, no host bits)")
      expect { pool.remove("fd00:1:2:3::/64") }.to raise_error(described_class::Error, /is IPv6; change the IPv6 network with ipv6 set/)
      expect { pool.remove("10.98.7.0/30") }.to raise_error(described_class::Error, "10.98.7.0/30 is not a pool of host #{host.ubid}")
      expect { pool.remove("10.98.1.10/32") }.to raise_error(described_class::Error, "10.98.1.10/32 is the host's management address")
    end
  end

  describe "#remap" do
    let(:profile) { {"ula48" => "fd00:1:2::/48", "cp_reach" => "public"} }

    it "maps a nat address to another external IP and refreshes its VM" do
      vm = place_vm("10.98.1.128")
      Sshable.create_with_id(vm.id, host: "8.8.8.10")
      ip_rate = BillingRate.from_resource_properties("IPAddress", "IPv4", "hetzner-fsn1")["id"]
      cpu_rate = BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")["id"]
      ip_record = BillingRecord.create(project_id: vm.project_id, resource_id: vm.id, resource_name: "8.8.8.10", billing_rate_id: ip_rate, amount: 1)
      cpu_record = BillingRecord.create(project_id: vm.project_id, resource_id: vm.id, resource_name: vm.name, billing_rate_id: cpu_rate, amount: 2)
      subnet = PrivateSubnet.create(name: "ps", project_id: vm.project_id, location_id: location.id, net4: "172.16.0.0/26", net6: "fd10:9b0b:6b4b:8fbb::/64")
      lb = LoadBalancer.create(name: "lb", private_subnet_id: subnet.id, project_id: vm.project_id, health_check_endpoint: "/up")
      Strand.create_with_id(lb, prog: "Vnet::LoadBalancerNexus", label: "wait")
      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm.id)
      pg = create_postgres_resource(project: vm.project, location_id: Location::HETZNER_FSN1_ID)
      PostgresServer.create(timeline: create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID), resource: pg, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")

      expect(pool.remap("10.98.1.128", "8.8.4.4")).to eq []
      expect(ipv4_row("10.98.1.128")[:external_ip].to_s).to eq "8.8.4.4"
      expect(vm.reload.assigned_vm_address.external_ip.to_s).to eq "8.8.4.4"
      expect(Sshable[vm.id].host).to eq "8.8.4.4"
      expect(ip_record.reload.resource_name).to eq "8.8.4.4/32"
      expect(cpu_record.reload.resource_name).to eq vm.name
      expect(Semaphore.where(strand_id: lb.id, name: "rewrite_dns_records").count).to eq 1
      expect(Semaphore.where(strand_id: pg.id, name: "refresh_dns_record").count).to eq 1
      expect(config_networks[1]).to eq("cidr" => "10.98.1.128/32", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.1.128" => "8.8.4.4"})
      expect(pool_actions.map { it[:args].to_h }).to eq [{"ip" => "10.98.1.128", "external" => "8.8.4.4", "from" => "8.8.8.10"}]
    end

    it "names BILLING_RATES_EXTRA_DIR when a VM's billing rate is not loaded, changing nothing" do
      vm = place_vm("10.98.1.128")
      BillingRecord.create(project_id: vm.project_id, resource_id: vm.id, resource_name: "8.8.8.10", billing_rate_id: "5ba4e8fd-4c1c-8c34-8c10-7e8a2a0bd9a8", amount: 1)
      expect { pool.remap("10.98.1.128", "8.8.4.4") }.to raise_error(described_class::Error,
        "billing rate 5ba4e8fd-4c1c-8c34-8c10-7e8a2a0bd9a8 of #{vm.ubid} is not loaded; run with BILLING_RATES_EXTRA_DIR set, as web and respirate are")
      expect(ipv4_row("10.98.1.128")[:external_ip].to_s).to eq "8.8.8.10"
      expect(pool_actions).to eq []
    end

    it "maps an address that lost its external IP, for a VM the control plane does not reach" do
      host
      DB[:ipv4_address].where(ip: "10.98.1.129").update(external_ip: nil)
      vm = place_vm("10.98.1.129")
      pool.remap("10.98.1.129", "8.8.4.4")
      expect(ipv4_row("10.98.1.129")[:external_ip].to_s).to eq "8.8.4.4"
      expect(vm.reload.assigned_vm_address.external_ip.to_s).to eq "8.8.4.4"
      expect(pool_actions.first[:args].to_h).to include("from" => nil)
    end

    it "points the control plane at the IPv6 address of an internal VM" do
      vm = place_vm("10.98.2.1")
      vm.update(ephemeral_net6: "2a01:4f8:1:2::/79")
      Sshable.create_with_id(vm.id, host: "10.98.2.1")
      pool.annotate([ByohPoolDeclaration.parse("10.98.2.0/30,delivery=fabric,exposure=internal")])
      expect(Sshable[vm.id].host).to eq vm.ip6_string
    end

    it "refuses what it cannot remap" do
      host
      expect { pool.remap("x", "8.8.4.4") }.to raise_error(described_class::Error, "x is not an IPv4 address")
      expect { pool.remap("10.98.7.1", "8.8.4.4") }.to raise_error(described_class::Error, "10.98.7.1 is not a pool address of host #{host.ubid}")
      expect { pool.remap("5.9.10.1", "8.8.4.4") }.to raise_error(described_class::Error, /in the public pool 5.9.10.0\/29; only nat pools/)
      expect { pool.remap("10.98.1.128", "10.1.1.1") }.to raise_error(described_class::Error, "external IP 10.1.1.1 is not globally routable")
      expect { pool.remap("10.98.1.128", "8.8.8.11") }.to raise_error(described_class::Error, /8.8.8.11 is already mapped/)
      expect { pool.remap("10.98.1.128", "nope") }.to raise_error(described_class::Error, /is not an IPv4 pair/)
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => config_networks.reject { it["cidr"] == "10.98.1.128/32" })))
      expect { pool.remap("10.98.1.128", "8.8.4.4") }.to raise_error(described_class::Error, "10.98.1.128/32 is not declared in the host's config; declare it with annotate first")
      expect(pool_actions).to eq []
    end
  end

  describe "#annotate" do
    let(:pools) { ["10.98.1.128/32,exposure=internal", "10.98.1.129/32,exposure=internal", "10.98.3.0/30,exposure=internal"] }

    def entries(*specs) = specs.map { ByohPoolDeclaration.parse(it) }

    it "sets delivery, exposure, reservations and external IPs on legacy pools and their VMs" do
      # Pools registered before the network contract: bare CIDRs, public.
      v6 = config_networks.last
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => ["10.98.1.128/32", "10.98.1.129/32", "10.98.3.0/30", v6])))
      DB[:address].where(routed_to_host_id: host.id).update(exposure: "public")
      vm = place_vm("10.98.1.128")
      Sshable.create_with_id(vm.id, host: "10.98.1.128")
      notes = pool.annotate(entries(
        "10.98.1.128/32,delivery=fabric,exposure=nat,external=10.98.1.128:8.8.8.10",
        "10.98.3.0/30,delivery=fabric,exposure=nat,external_cidr=8.8.4.0/30,reserve=10.98.3.3",
        v6["cidr"],
      ), uplink: "ens5", ipv6_mode: "ula")
      expect(notes).to eq []
      expect(DB[:address].where(cidr: ["10.98.1.128/32", "10.98.3.0/30"]).select_map([:delivery, :exposure]).uniq).to eq [["fabric", "nat"]]
      expect(ipv4_row("10.98.1.128")[:external_ip].to_s).to eq "8.8.8.10"
      expect(DB[:ipv4_address].where(cidr: "10.98.3.0/30").order(:ip).select_map([:reserved, :external_ip]).map { [it[0], it[1]&.to_s] })
        .to eq [[false, "8.8.4.0"], [false, "8.8.4.1"], [false, "8.8.4.2"], [true, nil]]
      expect(vm.reload.assigned_vm_address.external_ip.to_s).to eq "8.8.8.10"
      expect(Sshable[vm.id].host).to eq "10.98.1.128"
      cfg = host.provider.reload.config
      expect(cfg["uplink"]).to eq "ens5"
      expect(cfg["routed_networks"]).to eq [
        {"cidr" => "10.98.1.128/32", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.1.128" => "8.8.8.10"}},
        "10.98.1.129/32",
        {"cidr" => "10.98.3.0/30", "delivery" => "fabric", "exposure" => "nat", "external" => {"10.98.3.0" => "8.8.4.0", "10.98.3.1" => "8.8.4.1", "10.98.3.2" => "8.8.4.2"}, "reserve" => ["10.98.3.3"]},
        v6,
      ]
      expect(pool_actions.map { it[:command] }).to eq ["byoh-pool annotate"]
    end

    it "declares a registered pool the config lacks, and keeps the uplink when none is given" do
      Address.create(cidr: "5.9.20.0/30", routed_to_host_id: host.id).populate_ipv4_addresses
      expect(pool.annotate(entries("5.9.20.0/30,exposure=public"))).to eq []
      expect(config_networks.last).to eq("cidr" => "5.9.20.0/30", "delivery" => "routed", "exposure" => "public")
      expect(host.provider.config.key?("uplink")).to be false
    end

    it "moves an external IP from one address to another" do
      pool.annotate(entries("10.98.1.128/32,exposure=nat,external=10.98.1.128:8.8.8.10", "10.98.1.129/32,exposure=nat,external=10.98.1.129:8.8.8.11"))
      pool.annotate(entries("10.98.1.128/32,exposure=nat,external=10.98.1.128:8.8.8.11", "10.98.1.129/32,exposure=nat,external=10.98.1.129:8.8.8.10"))
      expect(ipv4_row("10.98.1.128")[:external_ip].to_s).to eq "8.8.8.11"
    end

    it "refuses changes it cannot make" do
      place_vm("10.98.3.1")
      expect { pool.annotate([]) }.to raise_error(described_class::Error, "no pools given")
      expect { pool.annotate(entries("10.98.3.0/30"), ipv6_mode: "gua") }.to raise_error(described_class::Error, "the host's IPv6 mode is ula; change it with ipv6 set")
      expect { pool.annotate(entries("fd00:9::/64")) }.to raise_error(described_class::Error, "fd00:9::/64: annotate does not change the IPv6 network; use ipv6 set")
      expect { pool.annotate(entries("10.98.1.128/31,exposure=internal")) }.to raise_error(described_class::Error, /10.98.1.128\/31 is not a registered pool/)
      expect { pool.annotate(entries("10.98.3.0/30,exposure=internal,reserve=10.98.3.1")) }.to raise_error(described_class::Error, "10.98.3.1 is held by a VM, so it cannot be reserved")
      expect { pool.annotate(entries("10.98.3.0/30,exposure=nat,external_cidr=8.8.4.0/30")) }.to raise_error(described_class::Error, "10.98.3.0/30 has VMs, so its exposure cannot change from internal to nat")
      expect { pool.annotate(entries("10.98.1.128/32,exposure=public")) }.to raise_error(described_class::Error, /is not globally routable, so it cannot be public/)
      expect(pool_actions).to eq []
    end
  end

  describe "#reset_to_legacy" do
    it "returns every pool to routed and public with nothing reserved and no external IPs" do
      DB[:ipv4_address].where(ip: "10.98.2.1").update(reserved: true)
      expect(pool.reset_to_legacy(host)).to eq 4
      expect(Address.where(routed_to_host_id: host.id).exclude(delivery: "routed", exposure: "public").count).to eq 0
      expect(DB[:ipv4_address].where(reserved: true).count).to eq 0
      expect(DB[:ipv4_address].exclude(external_ip: nil).count).to eq 0
      expect(config_networks.map { it["cidr"] }).to eq ["5.9.10.0/29", "10.98.1.128/32", "10.98.1.129/32", "10.98.2.0/30", host.net6.to_s]
      expect(config_networks.map(&:keys).uniq).to eq [["cidr"]]
    end
  end

  describe "#ipv6_set" do
    it "changes the IPv6 network of an empty host" do
      host.update(allocation_state: "accepting")
      expect(pool.ipv6_set("2a01:4f8:1:2::/64,ndp")).to eq []
      expect(host.net6.to_s).to eq "2a01:4f8:1:2::/64"
      expect([host.ipv6_mode, host.ndp_needed]).to eq ["gua", true]
      expect(config_networks.last).to eq("cidr" => "2a01:4f8:1:2::/64", "ndp" => true)
      expect(config_networks.count { !it["cidr"].include?(".") }).to eq 1
      expect(Strand.where(prog: "SetupNdpProxy").count).to eq 1
      expect(pool_actions.first[:args].to_h).to include("cidr" => "2a01:4f8:1:2::/64", "ipv6_mode" => "gua", "ndp" => true)
    end

    it "takes an explicit mode and starts no NDP proxy without ndp or before prep" do
      pool.ipv6_set("2a01:4f8:1:2::/64", mode: "ula")
      expect([host.ipv6_mode, host.ndp_needed]).to eq ["ula", false]
      pool.ipv6_set("2a01:4f8:1:2::/64,ndp")
      expect(Strand.where(prog: "SetupNdpProxy").count).to eq 0
    end

    it "refuses a host with VMs, IPv4 and invalid networks" do
      expect { pool.ipv6_set("10.98.5.0/30") }.to raise_error(described_class::Error, "10.98.5.0/30 is not IPv6; ipv6 set takes the host's IPv6 /64")
      expect { pool.ipv6_set("2a01:4f8:1:2::/63") }.to raise_error(described_class::Error, /must be a \/64/)
      expect { pool.ipv6_set("fd00:5::/64", mode: "gua") }.to raise_error(described_class::Error, /ipv6_mode gua needs a globally routable/)
      place_vm("5.9.10.1")
      expect { pool.ipv6_set("2a01:4f8:1:2::/64") }.to raise_error(described_class::Error, "host #{host.ubid} has 1 VMs; ipv6 set changes the IPv6 network of an empty host only")
    end
  end

  describe "#verify" do
    it "reports nothing but the unverified egress file for a consistent host" do
      create_vm(vm_host_id: host.id, location_id: location.id)
      expect(pool.verify).to eq [[:unverified, "/etc/nftables.d/1-byoh-egress.conf is not checked from the database; on the host, run: sudo nft list table inet byoh_egress"]]
    end

    it "reports drift between the declaration and the database" do
      cfg = host.provider.config.to_h
      networks = cfg["routed_networks"].map(&:dup)
      networks[0]["reserve"] = ["5.9.10.7"]
      networks[3]["delivery"] = "fabric"
      networks << {"cidr" => "10.98.1.10/32", "exposure" => "internal"} << {"cidr" => "10.98.9.0/30", "exposure" => "internal"}
      networks[4] = {"cidr" => "fd00:1:2:3::/64", "ndp" => false}
      host.provider.update(config: Sequel.pg_jsonb(cfg.merge("routed_networks" => networks)))
      Address.create(cidr: "10.98.20.0/30", routed_to_host_id: host.id, exposure: "public").populate_ipv4_addresses
      DB[:ipv4_address].where(ip: "10.98.1.129").update(external_ip: nil)
      vm = place_vm("10.98.1.128")
      DB[:assigned_vm_address].where(dst_vm_id: vm.id).update(external_ip: "8.8.4.4")
      other = place_vm("10.98.2.1")
      Sshable.create_with_id(other.id, host: "10.98.2.9")
      vm.update(local_vetho_ip: "169.254.169.2/32")
      host.update(ipv6_mode: "gua")

      expect(pool.verify).to eq [
        [:fail, "10.98.9.0/30 is declared but not registered; register it with add, or drop it with remove"],
        [:fail, "5.9.10.0/29 has reserved addresses  but declares 5.9.10.7"],
        [:fail, "10.98.1.128: the VM's external IP 8.8.4.4 differs from the pool's 8.8.8.10"],
        [:fail, "10.98.1.129/32 maps external IPs {} but declares {\"10.98.1.129\" => \"8.8.8.11\"}"],
        [:fail, "10.98.1.129/32 is nat, but 10.98.1.129 have no external IP"],
        [:fail, "10.98.2.0/30 is registered as routed/internal but declared as fabric/internal"],
        [:warn, "10.98.20.0/30 is registered but not declared in the host's config; declare it with annotate"],
        [:warn, "10.98.20.0/30 is public but not globally routable; set its exposure to internal or nat with annotate"],
        [:fail, "net6 #{host.net6} differs from the declared IPv6 network fd00:1:2:3::/64"],
        [:fail, "ipv6_mode is gua, but net6 #{host.net6} is a ULA"],
        [:warn, "#{vm.ubid}: its veth address 169.254.169.2/32 is in a link-local range cloud services use; recreate the VM"],
        [:warn, "#{other.ubid}: the control plane reaches it at 10.98.2.9, expected 10.98.2.1; remap or annotate refreshes it"],
        [:unverified, "/etc/nftables.d/1-byoh-egress.conf is not checked from the database; on the host, run: sudo nft list table inet byoh_egress"],
      ]
    end

    it "warns about a host without free internet addresses or outside a BYOH location" do
      host = register(["10.98.2.0/31,exposure=internal"])
      host.update(location_id: Location::HETZNER_FSN1_ID)
      vm = place_vm("10.98.2.0", vm_host: host)
      Sshable.create_with_id(vm.id, host: "10.98.2.0")
      expect(described_class.new(host).verify).to eq [
        [:warn, "no free public or nat IPv4 address: no internet VM with IPv4 can be placed on this host; internal VMs and VMs without IPv4 can"],
        [:warn, "location hetzner-fsn1 is not a BYOH location, so the network contract does not apply to this host yet"],
      ]
    end
  end
end
