# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

RSpec.describe Address do
  let(:routed_to_host_id) { "46683a25-acb1-4371-afe9-d39f303e44b4" }

  it "does not allow IPv4 subnets larger than /24" do
    address = described_class.new(cidr: "0.0.0.0/23", routed_to_host_id:)
    expect(address.valid?).to be false
    expect(address.errors[:cidr]).to eq ["too large (contains more than 256 addresses)"]
  end

  it "allows IPv4 subnets up to /24" do
    address = described_class.new(cidr: "0.0.0.0/24", routed_to_host_id:)
    expect(address.valid?).to be true
  end

  describe "network contract columns" do
    let(:vm_host) { create_vm_host }

    it "default to a routed public block whose addresses are neither reserved nor mapped" do
      address = described_class.create(cidr: "10.0.0.0/30", vm_host:)
      address.populate_ipv4_addresses
      expect(address.reload.values.slice(:delivery, :exposure)).to eq(delivery: "routed", exposure: "public")
      expect(DB[:ipv4_address].select_map([:reserved, :external_ip]).uniq).to eq [[false, nil]]
    end

    it "accept every delivery and exposure" do
      %w[routed onlink fabric].product(%w[public nat internal]).each_with_index do |(delivery, exposure), i|
        expect(described_class.create(cidr: "10.0.#{i}.0/30", vm_host:, delivery:, exposure:).delivery).to eq delivery
      end
    end

    it "refuse an unknown delivery or exposure" do
      expect { described_class.create(cidr: "10.0.0.0/30", vm_host:, delivery: "tunnel") }.to raise_error(Sequel::ValidationFailed, "delivery is invalid")
      expect { described_class.create(cidr: "10.0.0.0/30", vm_host:, exposure: "private") }.to raise_error(Sequel::ValidationFailed, "exposure is invalid")
    end

    it "refuse an IPv6 or duplicate external IP for a pool address" do
      described_class.create(cidr: "10.0.0.0/30", vm_host:)
      DB[:ipv4_address].insert(ip: "10.0.0.1", cidr: "10.0.0.0/30", external_ip: "203.0.113.1")
      expect { DB.transaction { DB[:ipv4_address].insert(ip: "10.0.0.2", cidr: "10.0.0.0/30", external_ip: "203.0.113.1") } }.to raise_error(Sequel::UniqueConstraintViolation)
      expect { DB.transaction { DB[:ipv4_address].insert(ip: "10.0.0.2", cidr: "10.0.0.0/30", external_ip: "2001:db8::1") } }.to raise_error(Sequel::CheckConstraintViolation, /ipv4_address_external_ip_v4_check/)
    end
  end

  it "marks reserved addresses and records external IPs" do
    vm_host = create_vm_host
    address = described_class.create(cidr: "10.0.0.0/30", vm_host:, exposure: "nat")
    address.populate_ipv4_addresses(reserved_ips: ["10.0.0.0", "10.0.0.3"], external_ips: {"10.0.0.1" => "8.8.8.1", "10.0.0.2" => "8.8.8.2"})
    expect(DB[:ipv4_address].order(:ip).select_map([:ip, :reserved, :external_ip]).map { it.map(&:to_s) }).to eq [
      ["10.0.0.0", "true", ""],
      ["10.0.0.1", "false", "8.8.8.1"],
      ["10.0.0.2", "false", "8.8.8.2"],
      ["10.0.0.3", "true", ""],
    ]
  end

  it "populates ipv4_address table with addresses in cidr" do
    vm_host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    address = described_class.create(cidr: "0.0.0.0/30", vm_host:)
    address.populate_ipv4_addresses
    expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.0 0.0.0.1 0.0.0.2 0.0.0.3].freeze
    address.destroy
    expect(DB[:ipv4_address]).to be_empty
  end

  it "does not populate host sshable address" do
    Prog::Vm::HostNexus.assemble("1.1.1.1").subject
    expect(described_class.count).to eq 1
    expect(Sshable.count).to eq 1
    expect(described_class.get(:cidr).network.to_s).to eq Sshable.get(:host)
    expect(DB[:ipv4_address]).to be_empty
  end

  describe "leaseweb" do
    # Leaseweb routes whole blocks to the host, so assemble pulls them from the
    # API rather than deriving one address from the sshable host.
    def assemble_leaseweb_host(provider_name: HostProvider::LEASEWEB_PROVIDER_NAME)
      allow(Config).to receive_messages(
        leaseweb_connection_string: "https://api.leaseweb.com",
        leaseweb_api_key: "key123",
        leaseweb_eu_api_key: "eu-key",
      )
      stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/1/ips").with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.generate(
          ips: [{ip: "1.2.3.4/24", prefixLength: 24, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: true, gateway: "1.2.3.254"}],
          _metadata: {totalCount: 1},
        ))
      stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/1")
        .to_return(status: 200, body: JSON.generate(
          location: {site: "AMS-01", suite: "8", rack: "9200"},
          rack: {capacity: "10G"},
          specs: {
            chassis: "HPE RL300",
            cpu: {type: "Ampere Altra Max M128-30", quantity: 2},
            ram: {size: 512, unit: "GB"},
            hdd: [{size: 3.84, unit: "TB", amount: 2, type: "NVME"}],
          },
          contract: {billingCycle: 1, billingFrequency: "MONTH", pricePerFrequency: "483.62", currency: "EUR"},
        ))
      stub_request(:put, "https://api.leaseweb.com/bareMetals/v2/servers/1").to_return(status: 204)
      Prog::Vm::HostNexus.assemble("1.2.3.4", provider_name:, server_identifier: "1").subject
    end

    it "drops network and broadcast for the eu org too" do
      vm_host = assemble_leaseweb_host(provider_name: HostProvider::LEASEWEB_EU_PROVIDER_NAME)
      described_class.create(cidr: "0.0.0.0/30", vm_host:).populate_ipv4_addresses
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.1 0.0.0.2]
    end

    it "populates ipv4_address table with addresses in cidr without first and last" do
      vm_host = assemble_leaseweb_host
      described_class.create(cidr: "0.0.0.0/30", vm_host:).populate_ipv4_addresses
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.1 0.0.0.2]
    end

    # A /32 Leaseweb routes here is not a block: dropping a network and a
    # broadcast address would leave nothing behind.
    it "keeps the only address of a standalone ip" do
      vm_host = assemble_leaseweb_host
      described_class.create(cidr: "5.6.7.8/32", vm_host:).populate_ipv4_addresses
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[5.6.7.8]
    end

    it "keeps both addresses of a two address block" do
      vm_host = assemble_leaseweb_host
      described_class.create(cidr: "5.6.7.8/31", vm_host:).populate_ipv4_addresses
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[5.6.7.8 5.6.7.9]
    end
  end
end
