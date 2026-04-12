# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe ByohRegistration do
  let(:base_args) {
    {
      main_ip: "203.0.113.42",
      routed_networks: ["10.99.0.0/29", "fd00:feed::/64"],
      location_label: "homelab-rack-A"
    }
  }

  describe "#validate!" do
    it "accepts a well-formed spec" do
      expect { described_class.new(**base_args).validate! }.not_to raise_error
    end

    it "rejects a non-IPv4 main_ip" do
      expect {
        described_class.new(**base_args.merge(main_ip: "not-an-ip")).validate!
      }.to raise_error(described_class::ValidationError, /main_ip is not a valid/)
    end

    it "rejects an IPv6 main_ip (management must be v4)" do
      expect {
        described_class.new(**base_args.merge(main_ip: "fd00::1")).validate!
      }.to raise_error(described_class::ValidationError, /main_ip must be IPv4/)
    end

    it "rejects a malformed routed_network CIDR" do
      expect {
        described_class.new(**base_args.merge(routed_networks: ["not-a-cidr"])).validate!
      }.to raise_error(described_class::ValidationError, /not a valid CIDR/)
    end

    it "rejects a non-/64 IPv6 routed_network" do
      expect {
        described_class.new(**base_args.merge(routed_networks: ["fd00::/48"])).validate!
      }.to raise_error(described_class::ValidationError, /must be \/64/)
    end

    it "rejects an ssh_key_source that points to a nonexistent file" do
      expect {
        described_class.new(**base_args.merge(ssh_key_source: "/no/such/file")).validate!
      }.to raise_error(described_class::ValidationError, /does not exist/)
    end

    describe "bmc validation" do
      it "requires endpoint" do
        expect {
          described_class.new(**base_args, bmc_config: {"username" => "admin", "password" => "x"}).validate!
        }.to raise_error(described_class::ValidationError, /endpoint is required/)
      end

      it "requires username" do
        expect {
          described_class.new(**base_args, bmc_config: {"endpoint" => "https://bmc.example", "password" => "x"}).validate!
        }.to raise_error(described_class::ValidationError, /username is required/)
      end

      it "requires password or password_env" do
        expect {
          described_class.new(**base_args, bmc_config: {"endpoint" => "https://bmc.example", "username" => "admin"}).validate!
        }.to raise_error(described_class::ValidationError, /password or bmc.password_env is required/)
      end

      it "rejects non-redfish protocols in v1" do
        expect {
          described_class.new(**base_args, bmc_config: {
            "protocol" => "ipmi", "endpoint" => "http://192.168.1.11",
            "username" => "admin", "password" => "x"
          }).validate!
        }.to raise_error(described_class::ValidationError, /'ipmi' is not supported in v1/)
      end

      it "rejects non-http(s) endpoint schemes" do
        expect {
          described_class.new(**base_args, bmc_config: {
            "endpoint" => "tcp://192.168.1.11:623", "username" => "admin", "password" => "x"
          }).validate!
        }.to raise_error(described_class::ValidationError, /must be http/)
      end

      it "accepts a valid redfish config" do
        expect {
          described_class.new(**base_args, bmc_config: {
            "protocol" => "redfish", "endpoint" => "https://192.168.1.11",
            "username" => "admin", "password_env" => "TEST_BMC_PASS_SILENCED"
          }).validate!
        }.not_to raise_error
      end
    end
  end

  describe "#provider_config" do
    it "builds the host_provider.config payload with declared routed networks" do
      cfg = described_class.new(**base_args).provider_config
      expect(cfg["main_ip4"]).to eq("203.0.113.42")
      expect(cfg["location_label"]).to eq("homelab-rack-A")
      expect(cfg["routed_networks"].map { |n| n["cidr"] }).to eq(["10.99.0.0/29", "fd00:feed::/64"])
      expect(cfg).not_to have_key("bmc")
    end

    it "auto-appends a ULA /64 when no IPv6 is declared (so VM allocation doesn't crash)" do
      cfg = described_class.new(**base_args.merge(routed_networks: ["10.99.0.0/29"])).provider_config
      cidrs = cfg["routed_networks"].map { |n| n["cidr"] }
      expect(cidrs.length).to eq(2)
      expect(cidrs.first).to eq("10.99.0.0/29")
      ula = cidrs.last
      expect(ula).to match(/\Afd[0-9a-f]{2}:[0-9a-f]{4}:[0-9a-f]{4}:0::\/64\z/)
    end

    it "includes bmc section when configured" do
      cfg = described_class.new(**base_args, bmc_config: {
        "protocol" => "redfish", "endpoint" => "https://192.168.1.11",
        "username" => "admin", "password_env" => "TEST_BMC_PASS_SILENCED"
      }).provider_config
      expect(cfg["bmc"]["endpoint"]).to eq("https://192.168.1.11")
      expect(cfg["bmc"]["password_env"]).to eq("TEST_BMC_PASS_SILENCED")
    end
  end

  describe "#prepare_keypair" do
    it "generates a fresh Ed25519 keypair by default" do
      reg = described_class.new(**base_args)
      expect(reg.keypair).to be_a(String)
      expect(reg.public_key).to start_with("ssh-ed25519 ")
    end

    it "reads an existing private key from disk when ssh_key_source is a path" do
      # SshKey#private_key emits a real OpenSSH-format PEM that
      # Net::SSH::Authentication::ED25519::PrivKey.read can parse back.
      key = SshKey.generate
      tmpdir = Dir.mktmpdir("byoh_reg_spec")
      path = File.join(tmpdir, "byoh_key")
      File.write(path, key.private_key)
      begin
        reg = described_class.new(**base_args.merge(ssh_key_source: path))
        expect(reg.keypair).to be_a(String)
        expect(reg.public_key).to start_with("ssh-ed25519 ")
        expect(reg.keypair).to eq(key.keypair)
        expect(reg.public_key).to eq(key.public_key)
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe "#install_instructions" do
    it "includes the public key and target hostname in human-readable form" do
      reg = described_class.new(**base_args)
      instructions = reg.install_instructions
      expect(instructions).to include("203.0.113.42")
      expect(instructions).to include(reg.public_key)
      expect(instructions).to include("/root/.ssh/authorized_keys")
    end
  end

  describe "#register!" do
    it "creates Sshable with preloaded raw_private_key_1, HostProvider, Address rows, and a Strand" do
      reg = described_class.new(**base_args)
      strand = reg.register!
      expect(strand).to be_a(Strand)
      expect(strand.prog).to eq("Vm::HostNexus")
      expect(strand.label).to eq("start")

      vm_host = VmHost[strand.id]
      expect(vm_host.provider_name).to eq("generic")
      expect(vm_host.net6.to_s).to eq("fd00:feed::/64")
      expect(vm_host.sshable.host).to eq("203.0.113.42")
      expect(vm_host.sshable.raw_private_key_1).to eq(reg.keypair)
      expect(vm_host.sshable.raw_private_key_1).not_to be_nil

      cidrs = vm_host.assigned_subnets.map { it.cidr.to_s }.sort
      expect(cidrs).to include("10.99.0.0/29")
      expect(cidrs).to include("203.0.113.42/32")
    end

    it "passes BMC config through to host_provider.config" do
      reg = described_class.new(**base_args, bmc_config: {
        "protocol" => "redfish", "endpoint" => "https://192.168.1.11",
        "username" => "admin", "password_env" => "TEST_BMC_PASS_SILENCED",
        "verify_ssl" => false
      })
      strand = reg.register!
      vm_host = VmHost[strand.id]
      expect(vm_host.provider.config["bmc"]["endpoint"]).to eq("https://192.168.1.11")
    end

    it "honors an operator-supplied server_identifier" do
      reg = described_class.new(**base_args.merge(server_identifier: "homelab-r1-01"))
      strand = reg.register!
      expect(VmHost[strand.id].provider.server_identifier).to eq("homelab-r1-01")
    end
  end

  describe ".generate_ula_64" do
    it "produces a /64 ULA in the fd00::/8 range" do
      ula = described_class.generate_ula_64
      parsed = IPAddr.new(ula)
      expect(parsed.ipv6?).to be(true)
      expect(parsed.prefix).to eq(64)
      expect(IPAddr.new("fd00::/8").include?(parsed)).to be(true)
    end

    it "produces different values on successive calls" do
      ulas = Array.new(5) { described_class.generate_ula_64 }
      expect(ulas.uniq.length).to eq(5)
    end
  end
end
