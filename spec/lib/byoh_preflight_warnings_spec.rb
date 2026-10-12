# frozen_string_literal: true

require "tmpdir"

RSpec.describe ByohPreflightWarnings do
  def byoh_location(name, profile = {})
    Location.create(name:, display_name: name, ui_name: name, visible: false, provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: profile)
  end

  def rate(location, type, family, active_from: Time.utc(2020, 1, 1), byoc: false)
    {"resource_type" => type, "resource_family" => family, "location" => location, "active_from" => active_from, "byoc" => byoc}
  end

  let(:full_rates) { described_class::MINIMUM_RATES.map { |type, family| rate("byoh-1", type, family) } }

  describe ".missing_rates" do
    it "lists the minimum rates the location lacks" do
      expect(described_class.missing_rates("byoh-1", [])).to eq described_class::MINIMUM_RATES
      expect(described_class.missing_rates("byoh-1", full_rates)).to eq []
    end

    it "ignores rates of other locations, byoc rates and rates that are not active yet" do
      rates = [
        rate("byoh-2", "VmVCpu", "standard"),
        rate("byoh-1", "VmVCpu", "burstable", byoc: true),
        rate("byoh-1", "VmStorage", "standard", active_from: Time.now + 3600),
        rate("byoh-1", "VmStorage", "burstable"),
        rate("byoh-1", "IPAddress", "IPv4"),
        rate("byoh-1", "MachineImageStorage", "standard"),
      ]
      expect(described_class.missing_rates("byoh-1", rates)).to eq [%w[VmVCpu standard], %w[VmVCpu burstable], %w[VmStorage standard]]
    end

    it "reads the rate files by default" do
      expect(described_class.missing_rates("hetzner-fsn1")).to eq []
    end
  end

  describe ".warnings" do
    before do
      # Load the memoised rates before any example points the overlay
      # directory at its temporary files.
      BillingRate.rates
      allow(Config).to receive_messages(base_url: "https://cloud.example.com", control_plane_outbound_cidrs: ["198.51.100.7/32"])
    end

    it "is empty for a configured control plane without BYOH locations" do
      expect(described_class.warnings).to eq []
    end

    it "warns about a local BASE_URL" do
      ["http://localhost:9292", "http://127.0.0.1:3000", "http://[::1]:3000", "not a url", "relative/path"].each do |url|
        allow(Config).to receive(:base_url).and_return(url)
        expect(described_class.warnings).to eq ["BASE_URL is #{url}; set it to the URL customers use to reach this control plane"]
      end
    end

    it "warns about open CONTROL_PLANE_OUTBOUND_CIDRS" do
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "::/0"])
      expect(described_class.warnings).to eq ["CONTROL_PLANE_OUTBOUND_CIDRS includes 0.0.0.0/0, ::/0, so Postgres and Kubernetes firewalls allow SSH from anywhere; set it to the control plane's source addresses"]
    end

    it "checks BYOH locations: the overlay directory, cp_source_cidrs and billing rates" do
      byoh_location("byoh-1", {"cp_source_cidrs" => ["198.51.100.7/32", "10.98.1.10/32"]})
      byoh_location("byoh-2")
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["198.51.100.0/24", "bad"])
      expect(described_class.warnings).to eq [
        "BILLING_RATES_EXTRA_DIR is unset, so web, respirate and monitor do not load the billing rates of BYOH locations",
        "location byoh-1: cp_source_cidrs 10.98.1.10/32 is not in CONTROL_PLANE_OUTBOUND_CIDRS",
        "location byoh-1: no billing rate for VmVCpu/standard, VmVCpu/burstable, VmStorage/standard, VmStorage/burstable, IPAddress/IPv4, MachineImageStorage/standard",
        "location byoh-2: no billing rate for VmVCpu/standard, VmVCpu/burstable, VmStorage/standard, VmStorage/burstable, IPAddress/IPv4, MachineImageStorage/standard",
      ]
    end

    it "is quiet for a BYOH location with an overlay directory and complete rates" do
      byoh_location("byoh-1", {"cp_source_cidrs" => ["198.51.100.7/32"]})
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "byoh-1.yml"), full_rates.to_yaml)
        allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
        expect(described_class.warnings).to eq []
      end
    end
  end
end
