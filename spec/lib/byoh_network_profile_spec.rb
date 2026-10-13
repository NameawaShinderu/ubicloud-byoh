# frozen_string_literal: true

RSpec.describe ByohNetworkProfile do
  def profile(hash)
    described_class.new(hash)
  end

  let(:full) {
    {
      "underlay_cidrs" => ["10.98.0.0/16"],
      "overlay_ipv4_cidrs" => ["172.20.0.0/14"],
      "vm_egress_deny" => ["10.98.0.0/16", "fd00:1::/64"],
      "vm_egress_allow" => ["10.98.1.0/24"],
      "cp_reach" => "public",
      "cp_source_cidrs" => ["10.98.1.10/32"],
      "host_mgmt_allow" => ["10.98.1.0/24", "203.0.113.7/32"],
      "ula48" => "fd12:3456:789a::/48",
      "ula_underlay" => "mesh",
      "guest_mtu" => 1400,
      "dns_servers" => ["10.98.0.2", "2001:db8::53"],
      "vm_egress_nat4" => false,
      "internal_egress" => "site",
      "egress_smtp" => true,
    }
  }

  describe "readers" do
    it "parse every key" do
      p = profile(full)
      expect(p.errors).to eq []
      expect(p.underlay_cidrs.map(&:to_s)).to eq ["10.98.0.0/16"]
      expect(p.overlay_ipv4_cidrs.map(&:to_s)).to eq ["172.20.0.0/14"]
      expect(p.vm_egress_deny.map(&:to_s)).to eq ["10.98.0.0/16", "fd00:1::/64"]
      expect(p.vm_egress_allow.map(&:to_s)).to eq ["10.98.1.0/24"]
      expect(p.cp_source_cidrs.map(&:to_s)).to eq ["10.98.1.10/32"]
      expect(p.host_mgmt_allow.map(&:to_s)).to eq ["10.98.1.0/24", "203.0.113.7/32"]
      expect(p.cp_reach).to eq "public"
      expect(p.ula48.to_s).to eq "fd12:3456:789a::/48"
      expect(p.ula_underlay).to eq "mesh"
      expect(p.guest_mtu).to eq 1400
      expect(p.dns_servers.map(&:to_s)).to eq ["10.98.0.2", "2001:db8::53"]
      expect(p.vm_egress_nat4).to be false
      expect(p.internal_egress).to eq "site"
      expect(p.egress_smtp).to be true
      expect(p.to_h).to eq full
    end

    it "fill in defaults for an empty profile" do
      p = profile({})
      expect(p.errors).to eq []
      described_class::CIDR_LIST_KEYS.each { expect(p.public_send(it)).to eq [] }
      expect(p.cp_reach).to eq "onhost"
      expect(p.ula48).to be_nil
      expect(p.ula_underlay).to eq "none"
      expect(p.guest_mtu).to be_nil
      expect(p.dns_servers).to eq []
      expect(p.vm_egress_nat4).to be true
      expect(p.internal_egress).to eq "host_nat"
      expect(p.egress_smtp).to be false
    end

    it "accept symbol keys and JSONB hashes" do
      expect(profile({cp_reach: "public"}).cp_reach).to eq "public"
      expect(profile(Sequel.pg_jsonb_wrap({"cp_reach" => "public"})).cp_reach).to eq "public"
    end
  end

  describe "#egress_nat4_params" do
    it "denies the IPv4 networks of the deny list, underlay, control plane and management, once each" do
      expect(profile(full).egress_nat4_params).to eq(deny4: ["10.98.0.0/16", "10.98.1.10/32", "10.98.1.0/24", "203.0.113.7/32"], smtp: true)
    end

    it "denies nothing and blocks SMTP by default" do
      expect(profile({}).egress_nat4_params).to eq(deny4: [], smtp: false)
    end
  end

  describe "#errors" do
    it "refuses a value that is not an object" do
      expect(profile(["10.0.0.0/8"]).errors).to eq ["must be a JSON object"]
    end

    it "refuses unknown keys" do
      expect(profile({"tier" => "x"}).errors).to eq ["unknown key tier"]
    end

    it "refuses CIDR lists that are not lists of strings" do
      expect(profile({"underlay_cidrs" => "10.0.0.0/8"}).errors).to eq ["underlay_cidrs must be a list of strings"]
      expect(profile({"vm_egress_deny" => [1]}).errors).to eq ["vm_egress_deny must be a list of strings"]
    end

    it "refuses invalid CIDRs and CIDRs with host bits" do
      expect(profile({"host_mgmt_allow" => ["10.0.0.0/33", "10.0.0.1/24", "10.0.0.0/24"]}).errors)
        .to eq ["host_mgmt_allow: 10.0.0.0/33 is not valid", "host_mgmt_allow: 10.0.0.1/24 is not valid"]
    end

    it "refuses overlay networks outside RFC 1918" do
      expect(profile({"overlay_ipv4_cidrs" => ["100.64.0.0/16", "fd00::/64", "172.0.0.0/11"]}).errors).to eq [
        "overlay_ipv4_cidrs: 100.64.0.0/16 is not an RFC 1918 IPv4 network",
        "overlay_ipv4_cidrs: fd00::/64 is not an RFC 1918 IPv4 network",
        "overlay_ipv4_cidrs: 172.0.0.0/11 is not an RFC 1918 IPv4 network",
      ]
    end

    it "refuses overlay networks that overlap the underlay" do
      errors = profile({
        "underlay_cidrs" => ["10.98.0.0/16", "fd00::/48", "192.168.0.0/24"],
        "overlay_ipv4_cidrs" => ["10.98.4.0/24", "10.0.0.0/8", "172.20.0.0/14"],
      }).errors
      expect(errors).to eq [
        "overlay_ipv4_cidrs: 10.98.4.0/24 overlaps underlay 10.98.0.0/16",
        "overlay_ipv4_cidrs: 10.0.0.0/8 overlaps underlay 10.98.0.0/16",
      ]
    end

    it "refuses invalid DNS servers" do
      expect(profile({"dns_servers" => ["8.8.8.8", "dns.example"]}).errors).to eq ["dns_servers: dns.example is not valid"]
    end

    it "refuses unknown choices" do
      expect(profile({"cp_reach" => "tunnel", "ula_underlay" => nil, "internal_egress" => "host_nat"}).errors)
        .to eq ["cp_reach must be one of onhost, public", "ula_underlay must be one of none, operator, mesh"]
    end

    it "refuses booleans that are not booleans" do
      expect(profile({"vm_egress_nat4" => "yes", "egress_smtp" => false}).errors).to eq ["vm_egress_nat4 must be true or false"]
    end

    it "refuses guest MTUs outside 1280..9000 or not integers" do
      ["1400", 1279, 9001].each do
        expect(profile({"guest_mtu" => it}).errors).to eq ["guest_mtu must be an integer between 1280 and 9000"]
      end
      expect(profile({"guest_mtu" => 9000}).errors).to eq []
    end

    it "refuses a ula48 that is not a ULA /48" do
      [1, "bogus", "10.0.0.0/8", "fd00::/64", "2001:db8::/48"].each do
        expect(profile({"ula48" => it}).errors).to eq ["ula48 must be a /48 inside fc00::/7"]
      end
    end
  end
end
