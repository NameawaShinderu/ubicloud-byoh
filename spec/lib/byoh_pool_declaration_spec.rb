# frozen_string_literal: true

RSpec.describe ByohPoolDeclaration do
  def parse(input, **) = described_class.parse(input, **)

  def parse_error(input)
    parse(input)
    raise "expected a ValidationError"
  rescue described_class::ValidationError => ex
    ex.message
  end

  let(:location) {
    Location.create(name: "byoh-pool", display_name: "byoh-pool", ui_name: "byoh-pool", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"overlay_ipv4_cidrs" => ["172.20.0.0/14"]})
  }

  def validate(inputs, main_ip: "198.51.100.10", **)
    described_class.validate_set!(inputs.map { parse(it) }, main_ip:, location:, **)
  end

  def validate_error(inputs, **)
    validate(inputs, **)
    raise "expected a ValidationError"
  rescue described_class::ValidationError => ex
    ex.message
  end

  describe ".parse" do
    it "reads a bare CIDR string" do
      entry = parse("8.8.8.0/29")
      expect(entry).to have_attributes(delivery: "routed", exposure: "public", exposure_defaulted: true, external: {}, reserve: [], usable: "auto", ndp: false)
      expect(entry.ipv4?).to be true
      expect(entry.onlink?).to be false
      expect(entry.reserved_ips).to eq []
      expect(entry.usable_ips.length).to eq 8
    end

    it "reads a hash with symbol or string keys" do
      expect(parse({cidr: "8.8.8.0/29", exposure: "internal"}).exposure).to eq "internal"
      expect(parse({"cidr" => "8.8.8.0/29", "delivery" => "fabric"}).delivery).to eq "fabric"
    end

    it "refuses other input types" do
      expect { parse(42) }.to raise_error(described_class::ValidationError, "pool entry must be a CIDR string or a mapping, got 42")
    end

    it "defaults a new non-routable entry to internal and keeps legacy entries public" do
      expect(parse("10.1.0.0/29")).to have_attributes(exposure: "internal", exposure_defaulted: true)
      expect(parse({"cidr" => "10.1.0.0/29"}, legacy: true)).to have_attributes(exposure: "public", exposure_defaulted: false)
      expect(parse("10.1.0.0/29,exposure=nat,external=10.1.0.1:8.8.4.4")).to have_attributes(exposure: "nat", exposure_defaulted: false)
    end

    it "reads a bare IPv4 address as a /32 only in a stored entry" do
      expect(parse({"cidr" => "203.0.113.5"}, legacy: true)).to have_attributes(exposure: "public")
      expect(parse("203.0.113.5", legacy: true).cidr.to_s).to eq "203.0.113.5/32"
      expect(parse_error("203.0.113.5")).to eq "\"203.0.113.5\" is not a CIDR (address/prefix, no host bits)"
      expect { parse("fd00::1", legacy: true) }.to raise_error(described_class::ValidationError, "\"fd00::1\" is not a CIDR (address/prefix, no host bits)")
    end

        it "accepts the legacy keys older registrations stored" do
      expect(parse({"cidr" => "8.8.8.0/29", "source_host_ip" => "1.1.1.1", "is_failover" => false}).cidr.to_s).to eq "8.8.8.0/29"
    end

    it "reads the inline form" do
      entry = parse("10.1.0.0/29, delivery=onlink, exposure=nat, segment=10.1.0.0/24, gateway=10.1.0.1, reserve=10.1.0.6, reserve=10.1.0.7, " \
        "external=10.1.0.2:8.8.4.2, external=10.1.0.3:8.8.4.3, external=10.1.0.4:8.8.4.4, external=10.1.0.5:8.8.4.5, usable=auto")
      expect(entry.onlink?).to be true
      expect(entry.reserved_ips).to eq %w[10.1.0.6 10.1.0.7 10.1.0.0 10.1.0.1]
      expect(entry.usable_ips).to eq %w[10.1.0.2 10.1.0.3 10.1.0.4 10.1.0.5]
      expect(entry.external.keys).to eq entry.usable_ips
    end

    it "reads ndp flags on an IPv6 entry" do
      expect(parse("2001:db8::/64,ndp").ndp_needed?).to be true
      expect(parse("2001:db8::/64,ndp=true").ndp_needed?).to be true
      expect(parse("2001:db8::/64,ndp=false").ndp_needed?).to be false
      expect(parse("2001:db8::/64")).to have_attributes(ndp: false, delivery: nil, exposure: nil)
      expect(parse("2001:db8::/64").ipv6?).to be true
      expect(parse_error("2001:db8::/64,ndp=maybe")).to eq "2001:db8::/64: ndp must be true or false"
    end

    it "refuses an inline option without a value" do
      expect(parse_error("8.8.8.0/29,exposure")).to eq "8.8.8.0/29,exposure: exposure must be key=value"
    end

    it "refuses bad CIDRs" do
      ["", "8.8.8.1", "8.8.8.1/29", "8.8.8.0/33", "bogus/24"].each do
        expect(parse_error(it)).to include("is not a CIDR (address/prefix, no host bits)")
      end
      expect(parse_error({"cidr" => 5})).to eq "5 is not a CIDR (address/prefix, no host bits)"
    end

    it "refuses unknown keys for the address family" do
      expect(parse_error("8.8.8.0/29,ndp")).to eq "8.8.8.0/29: unknown key(s) ndp for an IPv4 pool"
      expect(parse_error("2001:db8::/64,exposure=public")).to eq "2001:db8::/64: unknown key(s) exposure for an IPv6 pool"
    end

    it "refuses pools of the wrong size" do
      expect(parse_error("8.8.8.0/23")).to eq "8.8.8.0/23: an IPv4 pool may be at most a /24"
      expect(parse_error("2001:db8::/56")).to eq "2001:db8::/56: an IPv6 pool must be a /64"
    end

    it "refuses unknown choices and reports every problem" do
      expect(parse_error("8.8.8.0/29,delivery=tunnel,exposure=private,usable=some")).to eq [
        "8.8.8.0/29: delivery must be one of routed, onlink, fabric",
        "8.8.8.0/29: usable must be one of auto, all",
        "8.8.8.0/29: exposure must be one of public, nat, internal",
      ].join("\n")
    end

    describe "onlink" do
      it "needs a segment and a gateway" do
        message = "10.1.0.8/29: an onlink pool needs segment=<LAN CIDR> and gateway=<LAN gateway>"
        expect(parse_error("10.1.0.8/29,delivery=onlink")).to eq message
        expect(parse_error("10.1.0.8/29,delivery=onlink,segment=2001:db8::/64,gateway=10.1.0.1")).to eq message
        expect(parse_error("10.1.0.8/29,delivery=onlink,segment=10.1.0.0/24,gateway=2001:db8::1")).to eq message
      end

      it "needs the segment to contain the pool and the gateway" do
        expect(parse_error("10.1.0.8/29,delivery=onlink,segment=10.2.0.0/24,gateway=10.2.0.1")).to eq "10.1.0.8/29: segment 10.2.0.0/24 does not contain the pool"
        expect(parse_error("10.1.0.8/29,delivery=onlink,segment=10.1.0.0/24,gateway=10.3.0.1")).to eq "10.1.0.8/29: gateway 10.3.0.1 is outside segment 10.1.0.0/24"
      end

      it "strips only the segment's network, broadcast and gateway" do
        expect(parse("10.1.0.200/29,delivery=onlink,segment=10.1.0.0/24,gateway=10.1.0.1").reserved_ips).to eq []
        expect(parse("10.1.0.248/29,delivery=onlink,segment=10.1.0.0/24,gateway=10.1.0.254").reserved_ips).to eq %w[10.1.0.255 10.1.0.254]
        expect(parse("10.1.0.248/29,delivery=onlink,segment=10.1.0.0/24,gateway=10.1.0.254,usable=all").reserved_ips).to eq []
      end

      it "is the only delivery with a segment or gateway" do
        expect(parse_error("8.8.8.0/29,gateway=8.8.8.1")).to eq "8.8.8.0/29: segment and gateway apply only to onlink pools"
        expect(parse_error("8.8.8.0/29,segment=8.8.8.0/24")).to eq "8.8.8.0/29: segment and gateway apply only to onlink pools"
      end
    end

    it "checks reserved addresses" do
      expect(parse("8.8.8.0/29,reserve=8.8.8.1,reserve=8.8.8.1").reserved_ips).to eq %w[8.8.8.1]
      expect(parse_error({"cidr" => "8.8.8.0/29", "reserve" => "8.8.8.1"})).to eq "8.8.8.0/29: reserve must be a list of IPv4 addresses"
      expect(parse_error("8.8.8.0/29,reserve=nope,reserve=2001:db8::1,reserve=8.8.9.1")).to eq [
        "8.8.8.0/29: reserve \"nope\" is not an IPv4 address",
        "8.8.8.0/29: reserve \"2001:db8::1\" is not an IPv4 address",
        "8.8.8.0/29: reserve 8.8.9.1 is outside the pool",
      ].join("\n")
    end

    describe "external addresses" do
      it "apply only to nat pools" do
        expect(parse_error("8.8.8.0/30,external=8.8.8.1:1.1.1.1")).to eq "8.8.8.0/30: external and external_cidr apply only to nat pools"
      end

      it "come from either a map or a block" do
        expect(parse_error("10.1.0.0/30,exposure=nat,external=10.1.0.1:1.1.1.1,external_cidr=1.1.1.0/30")).to eq "10.1.0.0/30: use either external or external_cidr, not both"
      end

      it "map a block by offset, skipping reserved addresses" do
        entry = parse("10.1.0.0/30,exposure=nat,external_cidr=1.1.1.4/30,reserve=10.1.0.0")
        expect(entry.external).to eq("10.1.0.1" => "1.1.1.5", "10.1.0.2" => "1.1.1.6", "10.1.0.3" => "1.1.1.7")
      end

      it "need an external block of the pool's size" do
        message = "10.1.0.0/30: external_cidr must be an IPv4 CIDR of the same size as the pool"
        expect(parse_error("10.1.0.0/30,exposure=nat,external_cidr=1.1.1.0/29")).to eq message
        expect(parse_error("10.1.0.0/30,exposure=nat,external_cidr=2001:db8::/126")).to eq message
      end

      it "must be a map of IPv4 pairs for usable pool addresses" do
        expect(parse_error({"cidr" => "10.1.0.0/30", "exposure" => "nat", "external" => ["1.1.1.1"]})).to eq "10.1.0.0/30: external must map pool IPs to external IPs"
        expect(parse_error("10.1.0.0/30,exposure=nat,external=10.1.0.1,external=x:1.1.1.1,reserve=10.1.0.3,external=10.1.0.3:1.1.1.3,external=10.2.0.1:1.1.1.4")).to eq [
          "10.1.0.0/30: external \"10.1.0.1\": nil is not an IPv4 pair",
          "10.1.0.0/30: external \"x\": \"1.1.1.1\" is not an IPv4 pair",
          "10.1.0.0/30: external 10.1.0.3 is not a usable address of the pool",
          "10.1.0.0/30: external 10.2.0.1 is not a usable address of the pool",
        ].join("\n")
      end

      it "are not built while the onlink segment is invalid" do
        expect(parse_error("10.1.0.0/30,delivery=onlink,exposure=nat,external=10.1.0.1:1.1.1.1")).to eq "10.1.0.0/30: an onlink pool needs segment=<LAN CIDR> and gateway=<LAN gateway>"
      end
    end

    it "normalises entries for host_provider.config" do
      expect(parse("2001:db8::/64,ndp").to_config).to eq("cidr" => "2001:db8::/64", "ndp" => true)
      expect(parse("8.8.8.0/30").to_config).to eq("cidr" => "8.8.8.0/30", "delivery" => "routed", "exposure" => "public")
      expect(parse("10.1.0.248/30,delivery=onlink,segment=10.1.0.0/24,gateway=10.1.0.1,exposure=nat,usable=all,reserve=10.1.0.248,external_cidr=1.1.1.0/30").to_config).to eq(
        "cidr" => "10.1.0.248/30", "delivery" => "onlink", "exposure" => "nat",
        "external" => {"10.1.0.249" => "1.1.1.1", "10.1.0.250" => "1.1.1.2", "10.1.0.251" => "1.1.1.3"},
        "reserve" => ["10.1.0.248"], "usable" => "all", "segment" => "10.1.0.0/24", "gateway" => "10.1.0.1",
      )
    end
  end

  describe ".parse_yaml" do
    it "reads a pools.yaml v2 document" do
      doc = described_class.parse_yaml(<<~YAML)
        version: 2
        uplink: ens5
        ipv6_mode: ula
        routed_networks:
          - 8.8.8.0/30
          - cidr: 10.98.1.128/30
            delivery: fabric
            exposure: nat
            external:
              10.98.1.128: 43.204.120.20
              10.98.1.129: 43.204.120.21
              10.98.1.130: 43.204.120.22
              10.98.1.131: 43.204.120.23
          - cidr: fd00:1::/64
            ndp: false
      YAML
      expect(doc.uplink).to eq "ens5"
      expect(doc.ipv6_mode).to eq "ula"
      expect(doc.entries.map { it.cidr.to_s }).to eq %w[8.8.8.0/30 10.98.1.128/30 fd00:1::/64]
      expect(doc.entries[1].external["10.98.1.129"]).to eq "43.204.120.21"
    end

    it "needs only routed_networks" do
      doc = described_class.parse_yaml("routed_networks: []")
      expect([doc.entries, doc.uplink, doc.ipv6_mode]).to eq [[], nil, nil]
    end

    it "refuses malformed documents" do
      {
        "a: [" => /\Apools file is not valid YAML: /,
        "--- !ruby/object:Object {}" => /\Apools file is not valid YAML: /,
        "- 8.8.8.0/30" => "pools file must be a mapping with a routed_networks list",
        "routed_networks: []\nextra: 1" => "pools file has unknown key(s) extra",
        "version: 1\nrouted_networks: []" => "pools file version must be 2",
        "routed_networks: 8.8.8.0/30" => "pools file routed_networks must be a list",
        "uplink: [ens5]\nrouted_networks: []" => "pools file uplink must be a string",
        "ipv6_mode: public\nrouted_networks: []" => "pools file ipv6_mode must be one of gua, ula",
      }.each do |text, message|
        expect { described_class.parse_yaml(text) }.to raise_error(described_class::ValidationError, message)
      end
    end
  end

  describe ".ipv6_mode" do
    it "derives the mode from the declared /64" do
      expect(described_class.ipv6_mode([])).to eq "ula"
      expect(described_class.ipv6_mode([parse("fd00:1::/64")])).to eq "ula"
      expect(described_class.ipv6_mode([parse("8.8.8.0/30"), parse("2001:db8::/64")])).to eq "gua"
    end

    it "accepts an explicit ula on any prefix" do
      expect(described_class.ipv6_mode([parse("2001:db8::/64")], "ula")).to eq "ula"
      expect(described_class.ipv6_mode([parse("2001:db8::/64")], "gua")).to eq "gua"
    end

    it "refuses gua without a globally routable /64" do
      expect { described_class.ipv6_mode([parse("fd00:1::/64")], "gua") }.to raise_error(described_class::ValidationError, "ipv6_mode gua needs a globally routable IPv6 /64, but fd00:1::/64 is a ULA")
      expect { described_class.ipv6_mode([], "gua") }.to raise_error(described_class::ValidationError, "ipv6_mode gua needs a globally routable IPv6 /64, but none is declared")
      expect { described_class.ipv6_mode([], "both") }.to raise_error(described_class::ValidationError, "ipv6_mode must be one of gua, ula")
    end
  end

  describe ".validate_set!" do
    it "accepts a valid set and returns notes" do
      notes = validate(["8.8.8.0/30", "10.1.0.0/29", "8.8.4.0/30,delivery=fabric,exposure=public", "198.51.100.10/32", "2001:db8::/64,ndp"])
      expect(notes).to eq [
        "8.8.8.0/30: no exposure given, using public because it is globally routable",
        "10.1.0.0/29: no exposure given, using internal because it is not globally routable",
        "8.8.4.0/30: warning: fabric delivery with public exposure needs a cloud that routes these public addresses to the NIC",
        "198.51.100.10/32: no exposure given, using internal because it is not globally routable",
      ]
    end

    it "allows one IPv6 network" do
      expect(validate_error(["2001:db8::/64", "2001:db8:1::/64"])).to eq "at most one IPv6 /64 may be declared"
    end

    it "refuses overlapping entries, including stored ones" do
      expect(validate_error(["8.8.8.0/29", "8.8.8.4/30,exposure=public"])).to eq "8.8.8.0/29 overlaps 8.8.8.4/30"
      stored = [parse({"cidr" => "8.8.8.0/29"}, legacy: true)]
      expect { described_class.validate_set!([parse("8.8.8.0/30")], main_ip: "1.1.1.1", location:, stored:) }
        .to raise_error(described_class::ValidationError, "8.8.8.0/30 overlaps 8.8.8.0/29")
    end

    it "never re-validates stored entries on their own" do
      stored = [parse({"cidr" => "10.9.0.0/29", "exposure" => "public"}, legacy: true), parse("10.9.1.0/29,exposure=nat")]
      expect(described_class.validate_set!([parse("8.8.8.0/30")], main_ip: "1.1.1.1", location:, stored:).length).to eq 1
    end

    it "keeps other pools off an onlink segment, except the management /32 and other onlink pools" do
      onlink = "10.1.0.200/29,delivery=onlink,segment=10.1.0.0/24,gateway=10.1.0.1,exposure=internal"
      expect(validate([onlink, "10.1.0.208/29,delivery=onlink,segment=10.1.0.0/24,gateway=10.1.0.1,exposure=internal", "10.1.0.10/32,exposure=internal", "2001:db8::/64", "10.2.0.0/29,exposure=internal"], main_ip: "10.1.0.10")).to eq []
      expect(validate_error([onlink, "10.1.0.16/29,exposure=internal"], main_ip: "10.1.0.10")).to eq "10.1.0.16/29 overlaps the onlink segment 10.1.0.0/24 of 10.1.0.200/29"
      expect(validate_error(["10.1.0.16/29,exposure=internal", onlink], main_ip: "10.1.0.10")).to eq "10.1.0.16/29 overlaps the onlink segment 10.1.0.0/24 of 10.1.0.200/29"
    end

    it "refuses a pool around the management IP" do
      expect(validate_error(["8.8.8.0/29"], main_ip: "8.8.8.3")).to eq "8.8.8.0/29 contains main_ip 8.8.8.3; declare pools that exclude the management IP, or 8.8.8.3/32 alone"
      expect(validate(["8.8.8.3/32"], main_ip: "8.8.8.3").length).to eq 1
    end

    it "refuses public pools that are not globally routable" do
      expect(validate_error(["100.64.0.0/29,exposure=public"])).to eq "100.64.0.0/29 is not globally routable, so it cannot be public; use exposure=internal or exposure=nat"
    end

    it "needs an external IP for every usable nat address" do
      expect(validate_error(["10.1.0.0/30,exposure=nat,reserve=10.1.0.0,external=10.1.0.1:8.8.8.1"])).to eq "10.1.0.0/30 is nat but has no external IP for 10.1.0.2, 10.1.0.3"
    end

    describe "external IPs" do
      it "must be unique, routable and outside every pool" do
        expect(validate_error(["10.1.0.0/31,exposure=nat,external=10.1.0.0:8.8.8.1,external=10.1.0.1:8.8.8.1", "10.2.0.0/31,exposure=nat,external=10.2.0.0:10.9.9.9,external=10.2.0.1:10.1.0.0"])).to eq [
          "external IP 8.8.8.1 is used more than once",
          "external IP 10.9.9.9 is not globally routable",
          "external IP 10.1.0.0 is not globally routable",
          "external IP 10.1.0.0 is inside the pool 10.1.0.0/31",
        ].join("\n")
      end

      it "must not be mapped or registered already" do
        other = create_vm_host
        Address.create(cidr: "10.5.0.0/30", routed_to_host_id: other.id).populate_ipv4_addresses(external_ips: {"10.5.0.1" => "8.8.8.1"})
        address = Address.create(cidr: "10.5.1.0/30", routed_to_host_id: other.id)
        vm = create_vm
        AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.5.1.1", address_id: address.id, external_ip: "8.8.8.2")
        Address.create(cidr: "8.8.8.0/30", routed_to_host_id: other.id)
        expect(validate_error(["10.1.0.0/31,exposure=nat,external=10.1.0.0:8.8.8.1,external=10.1.0.1:8.8.8.2"])).to eq [
          "external IP 8.8.8.1 is already mapped to another address",
          "external IP 8.8.8.2 is already mapped to another address",
          "external IPs overlap the registered pool 8.8.8.0/30",
        ].join("\n")
      end

      it "may already be mapped by the host's own rows" do
        host = create_vm_host
        Address.create(cidr: "10.1.0.0/31", routed_to_host_id: host.id).populate_ipv4_addresses(external_ips: {"10.1.0.0" => "8.8.8.1"})
        address = Address.create(cidr: "10.1.1.0/31", routed_to_host_id: host.id)
        AssignedVmAddress.create(dst_vm_id: create_vm.id, ip: "10.1.1.1", address_id: address.id, external_ip: "8.8.8.2")
        entries = [parse("10.1.0.0/31,exposure=nat,external=10.1.0.0:8.8.8.1,external=10.1.0.1:8.8.8.2")]
        expect(described_class.validate_set!(entries, main_ip: "1.1.1.1", location:, host:)).to eq []
      end
    end

    it "refuses pools registered for another host but not the host's own identical rows" do
      host = create_vm_host
      Address.create(cidr: "8.8.8.0/30", routed_to_host_id: host.id)
      Address.create(cidr: "8.8.4.0/24", routed_to_host_id: host.id)
      entries = [parse("8.8.8.0/30,exposure=public"), parse("8.8.4.0/29,exposure=public")]
      expect { described_class.validate_set!(entries, main_ip: "1.1.1.1", location:, host:) }
        .to raise_error(described_class::ValidationError, "8.8.4.0/29 overlaps 8.8.4.0/24, already registered")
      expect { described_class.validate_set!(entries, main_ip: "1.1.1.1", location:) }
        .to raise_error(described_class::ValidationError, "8.8.8.0/30 overlaps 8.8.8.0/30, already registered\n8.8.4.0/29 overlaps 8.8.4.0/24, already registered")
    end

    it "refuses an IPv6 network another host uses" do
      host = create_vm_host(net6: "2001:db8::/64")
      expect(validate_error(["2001:db8::/64"])).to eq "2001:db8::/64 overlaps the IPv6 network 2001:db8::/64 of another host"
      expect(described_class.validate_set!([parse("2001:db8::/64")], main_ip: "1.1.1.1", location:, host:)).to eq []
    end

    it "keeps pools off the location's overlay and private subnets" do
      PrivateSubnet.create(name: "ps", location_id: location.id, net4: "10.7.0.0/26", net6: "fd10::/64", project_id: Project.create(name: "p").id)
      expect(validate_error(["172.21.0.0/29,exposure=internal", "10.7.0.0/29,exposure=internal"])).to eq [
        "172.21.0.0/29 overlaps the location's overlay network 172.20.0.0/14",
        "10.7.0.0/29 overlaps the private subnet 10.7.0.0/26 in this location",
      ].join("\n")
    end

    it "works in a location without a BYOH profile" do
      entries = [parse("172.21.0.0/29,exposure=internal")]
      expect(described_class.validate_set!(entries, main_ip: "1.1.1.1", location: Location[Location::HETZNER_FSN1_ID])).to eq []
    end

    it "checks the requested IPv6 mode" do
      expect(validate_error(["fd00:1::/64"], ipv6_mode: "gua")).to eq "ipv6_mode gua needs a globally routable IPv6 /64, but fd00:1::/64 is a ULA"
      expect(validate(["2001:db8::/64"], ipv6_mode: "gua")).to eq []
    end
  end
end
