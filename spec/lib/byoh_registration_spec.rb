# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe ByohRegistration do
  let(:location) {
    Location.create(name: "byoh-test", display_name: "byoh-test-dn", ui_name: "BYOH test", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:1:2::/48"})
  }
  let(:base_args) {
    {
      main_ip: "203.0.113.42",
      location:,
      routed_networks: ["10.99.0.0/29", "fd00:feed::/64"],
    }
  }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  def audit_rows
    DB[:byoh_operator_action].order(:created_at).all
  end

  def pool_file(text)
    path = File.join(dir, "pools.yaml")
    File.write(path, text)
    path
  end

  describe "#validate!" do
    it "accepts a well-formed spec and notes the exposure it chose" do
      reg = described_class.new(**base_args)
      expect(reg.validate!).to be reg
      expect(reg.notes).to eq ["10.99.0.0/29: no exposure given, using internal because it is not globally routable"]
      expect(reg.entries.map { it.cidr.to_s }).to eq ["10.99.0.0/29", "fd00:feed::/64"]
    end

    it "requires a location" do
      expect {
        described_class.new(**base_args, location: nil).validate!
      }.to raise_error(described_class::ValidationError, "a BYOH location is required; create one with bin/byoh-location")
    end

    it "rejects an unknown location" do
      expect {
        described_class.new(**base_args, location: "nowhere").validate!
      }.to raise_error(described_class::ValidationError, /no location nowhere/)
    end

    it "rejects a location that is not a BYOH location" do
      expect {
        described_class.new(**base_args, location: "hetzner-fsn1").validate!
      }.to raise_error(described_class::ValidationError, "location hetzner-fsn1 is not a BYOH location; create one with bin/byoh-location")
    end

    it "finds the location by name, display name or ubid" do
      [location.name, location.display_name, location.ubid].each do |key|
        expect(described_class.new(**base_args, location: key).location).to eq location
      end
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

    it "rejects a malformed pool" do
      expect {
        described_class.new(**base_args.merge(routed_networks: ["not-a-cidr"])).validate!
      }.to raise_error(described_class::ValidationError, /"not-a-cidr" is not a CIDR/)
    end

    it "rejects an empty pool" do
      expect {
        described_class.new(**base_args.merge(routed_networks: [""])).validate!
      }.to raise_error(described_class::ValidationError, /nil is not a CIDR/)
    end

    it "rejects an IPv4 block that contains main_ip" do
      expect {
        described_class.new(**base_args.merge(routed_networks: ["203.0.113.40/29"])).validate!
      }.to raise_error(described_class::ValidationError, /contains main_ip 203.0.113.42/)
    end

    it "accepts main_ip declared as its own /32" do
      expect { described_class.new(**base_args.merge(routed_networks: ["203.0.113.42/32", "10.99.0.0/29"])).validate! }.not_to raise_error
    end

    it "rejects a non-/64 IPv6 pool" do
      expect {
        described_class.new(**base_args.merge(routed_networks: ["fd00::/48"])).validate!
      }.to raise_error(described_class::ValidationError, /must be a \/64/)
    end

    it "rejects a pool that overlaps another host's pool" do
      described_class.new(**base_args).register!
      expect {
        described_class.new(**base_args, main_ip: "203.0.113.43", routed_networks: ["10.99.0.4/30"]).validate!
      }.to raise_error(described_class::ValidationError, /10.99.0.4\/30 overlaps 10.99.0.0\/29, already registered/)
    end

    it "reads a bare IPv4 address as a /32, with a note" do
      reg = described_class.new(**base_args, routed_networks: ["198.51.100.5", "198.51.100.6,exposure=internal"])
      expect(reg.entries.map { it.cidr.to_s }).to eq ["198.51.100.5/32", "198.51.100.6/32"]
      expect(reg.notes).to include("198.51.100.5: no prefix given, read as 198.51.100.5/32", "198.51.100.6: no prefix given, read as 198.51.100.6/32")
    end

    it "accepts the inline syntax and pools given as hashes" do
      reg = described_class.new(**base_args, routed_networks: [],
        pools: ["185.0.2.0/29,exposure=public,reserve=185.0.2.1", {"cidr" => "10.99.0.0/29", "exposure" => "internal"}])
      expect(reg.entries.map(&:to_config)).to eq [
        {"cidr" => "185.0.2.0/29", "delivery" => "routed", "exposure" => "public", "reserve" => ["185.0.2.1"]},
        {"cidr" => "10.99.0.0/29", "delivery" => "routed", "exposure" => "internal"},
      ]
      expect(reg.notes).to eq []
    end

    it "rejects an ssh_key_source that points to a nonexistent file" do
      expect {
        described_class.new(**base_args.merge(ssh_key_source: "/no/such/file")).validate!
      }.to raise_error(described_class::ValidationError, /does not exist/)
    end

    it "accepts an ssh_key_source that is a readable file" do
      path = File.join(dir, "key")
      File.write(path, "x")
      expect { described_class.new(**base_args.merge(ssh_key_source: path)).validate! }.not_to raise_error
    end

    it "rejects an ssh_key_source that is neither :generate nor a path" do
      expect {
        described_class.new(**base_args.merge(ssh_key_source: :other)).validate!
      }.to raise_error(described_class::ValidationError, /does not exist/)
    end

    describe "pool file" do
      it "adds the pools, uplink and ipv6_mode of the file" do
        path = pool_file(<<~YAML)
          version: 2
          uplink: enp1s0
          ipv6_mode: gua
          routed_networks:
            - cidr: 185.0.2.0/29
              exposure: public
            - cidr: 2001:db8:1::/64
        YAML
        reg = described_class.new(**base_args, routed_networks: ["10.99.0.0/29"], pool_file: path)
        expect(reg.entries.map { it.cidr.to_s }).to eq ["185.0.2.0/29", "2001:db8:1::/64", "10.99.0.0/29"]
        expect(reg.ipv6_mode).to eq "gua"
        expect(reg.provider_config["uplink"]).to eq "enp1s0"
      end

      it "refuses an ipv6_mode that contradicts the file" do
        path = pool_file("version: 2\nipv6_mode: ula\nrouted_networks: []\n")
        expect {
          described_class.new(**base_args, pool_file: path, ipv6_mode: "gua").validate!
        }.to raise_error(described_class::ValidationError, "--ipv6-mode gua contradicts ipv6_mode ula of the pool file")
      end

      it "accepts an ipv6_mode that matches the file" do
        path = pool_file("version: 2\nipv6_mode: ula\nrouted_networks: []\n")
        reg = described_class.new(**base_args, pool_file: path, ipv6_mode: "ula")
        expect(reg.ipv6_mode).to eq "ula"
        expect(reg.provider_config).not_to have_key("uplink")
      end

      it "refuses a file it cannot read" do
        expect {
          described_class.new(**base_args, pool_file: File.join(dir, "missing.yaml")).validate!
        }.to raise_error(described_class::ValidationError, /cannot read pool file: No such file/)
      end

      it "refuses an invalid file" do
        expect {
          described_class.new(**base_args, pool_file: pool_file("version: 3\nrouted_networks: []\n")).validate!
        }.to raise_error(described_class::ValidationError, "pools file version must be 2")
      end
    end

    describe "bmc validation" do
      it "requires a Hash" do
        expect {
          described_class.new(**base_args, bmc_config: "https://bmc.example").validate!
        }.to raise_error(described_class::ValidationError, /must be a Hash/)
      end

      it "rejects an endpoint that is not a parseable URL" do
        expect {
          described_class.new(**base_args, bmc_config: {"endpoint" => "https://bmc example", "username" => "admin", "password" => "x"}).validate!
        }.to raise_error(described_class::ValidationError, /not a valid URL/)
      end

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
            "username" => "admin", "password" => "x",
          }).validate!
        }.to raise_error(described_class::ValidationError, /'ipmi' is not supported in v1/)
      end

      it "rejects non-http(s) endpoint schemes" do
        expect {
          described_class.new(**base_args, bmc_config: {
            "endpoint" => "tcp://192.168.1.11:623", "username" => "admin", "password" => "x",
          }).validate!
        }.to raise_error(described_class::ValidationError, /must be http/)
      end

      it "accepts a valid redfish config" do
        expect {
          described_class.new(**base_args, bmc_config: {
            "protocol" => "redfish", "endpoint" => "https://192.168.1.11",
            "username" => "admin", "password_env" => "TEST_BMC_PASS_SILENCED",
          }).validate!
        }.not_to raise_error
      end
    end
  end

  describe "#provider_config" do
    it "builds the host_provider.config payload with the normalised pools" do
      cfg = described_class.new(**base_args).provider_config
      expect(cfg).to eq(
        "main_ip4" => "203.0.113.42",
        "location_label" => "byoh-test",
        "routed_networks" => [
          {"cidr" => "10.99.0.0/29", "delivery" => "routed", "exposure" => "internal"},
          {"cidr" => "fd00:feed::/64", "ndp" => false},
        ],
      )
    end

    it "appends a /64 of the location's ula48 when no IPv6 is declared" do
      random = class_double(SecureRandom)
      expect(random).to receive(:random_number).with(65536).and_return(0xabcd)
      reg = described_class.new(**base_args, routed_networks: ["10.99.0.0/29"], random:)
      expect(reg.provider_config["routed_networks"].last).to eq("cidr" => "fd00:1:2:abcd::/64", "ndp" => false)
      # Computed once.
      expect(reg.provider_config["routed_networks"].last["cidr"]).to eq "fd00:1:2:abcd::/64"
      expect(reg.ipv6_mode).to eq "ula"
    end

    it "draws again when another host uses the /64" do
      described_class.new(**base_args, routed_networks: ["10.99.0.0/29", "fd00:1:2:1::/64"]).register!
      random = class_double(SecureRandom)
      expect(random).to receive(:random_number).and_return(1, 2)
      reg = described_class.new(**base_args, main_ip: "203.0.113.43", routed_networks: [], random:)
      expect(reg.provider_config["routed_networks"].last["cidr"]).to eq "fd00:1:2:2::/64"
    end

    it "gives up after 32 used /64s" do
      described_class.new(**base_args, routed_networks: ["10.99.0.0/29", "fd00:1:2:1::/64"]).register!
      random = class_double(SecureRandom)
      expect(random).to receive(:random_number).exactly(32).times.and_return(1)
      reg = described_class.new(**base_args, main_ip: "203.0.113.43", routed_networks: [], random:)
      expect { reg.provider_config }.to raise_error(described_class::ValidationError, "could not find an unused /64 in fd00:1:2::/48 after 32 attempts; declare an IPv6 /64")
    end

    it "refuses to derive a /64 when the location has no ula48" do
      location.update(byoh_network: Sequel.pg_jsonb({}))
      reg = described_class.new(**base_args, routed_networks: [])
      expect { reg.provider_config }.to raise_error(described_class::ValidationError, /location byoh-test has no ula48/)
    end

    it "includes bmc section when configured" do
      cfg = described_class.new(**base_args, bmc_config: {
        "protocol" => "redfish", "endpoint" => "https://192.168.1.11",
        "username" => "admin", "password_env" => "TEST_BMC_PASS_SILENCED",
      }).provider_config
      expect(cfg["bmc"]["endpoint"]).to eq("https://192.168.1.11")
      expect(cfg["bmc"]["password_env"]).to eq("TEST_BMC_PASS_SILENCED")
    end
  end

  describe "#ipv6_mode" do
    it "is gua for a globally routable /64" do
      expect(described_class.new(**base_args, routed_networks: ["2001:db8:1::/64"]).ipv6_mode).to eq "gua"
    end

    it "refuses gua for a ULA" do
      expect {
        described_class.new(**base_args, ipv6_mode: "gua").validate!
      }.to raise_error(described_class::ValidationError, /ipv6_mode gua needs a globally routable IPv6 \/64, but fd00:feed::\/64 is a ULA/)
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
      path = File.join(dir, "byoh_key")
      File.write(path, key.private_key)
      reg = described_class.new(**base_args.merge(ssh_key_source: path))
      expect(reg.keypair).to eq(key.keypair)
      expect(reg.public_key).to eq(key.public_key)
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
    it "creates the host in the location and records the registration" do
      reg = described_class.new(**base_args)
      strand = reg.register!
      expect(strand).to be_a(Strand)
      expect(strand.prog).to eq("Vm::HostNexus")
      expect(strand.label).to eq("start")

      vm_host = VmHost[strand.id]
      expect(vm_host.provider_name).to eq("generic")
      expect(vm_host.location_id).to eq(location.id)
      expect(vm_host.byoh?).to be true
      expect(vm_host.net6.to_s).to eq("fd00:feed::/64")
      expect(vm_host.ipv6_mode).to eq("ula")
      expect(vm_host.ndp_needed).to be false
      expect(vm_host.sshable.host).to eq("203.0.113.42")
      expect(vm_host.sshable.raw_private_key_1).to eq(reg.keypair)
      expect(vm_host.assigned_subnets.map { [it.cidr.to_s, it.exposure] }.sort).to eq [["10.99.0.0/29", "internal"], ["203.0.113.42/32", "public"]]

      rows = audit_rows
      expect(rows.size).to eq 1
      expect(rows.first).to include(command: "register-byoh-host", target_id: vm_host.id, result: "ok")
      expect(rows.first[:args].to_h).to eq(
        "main_ip" => "203.0.113.42", "location" => "byoh-test", "server_identifier" => nil,
        "pools" => [{"cidr" => "10.99.0.0/29", "delivery" => "routed", "exposure" => "internal"}, {"cidr" => "fd00:feed::/64", "ndp" => false}],
      )
    end

    it "passes ipv6_mode gua and ndp through to the host" do
      strand = described_class.new(**base_args, routed_networks: ["185.0.2.0/29", "2001:db8:1::/64,ndp"]).register!
      vm_host = VmHost[strand.id]
      expect(vm_host.ipv6_mode).to eq "gua"
      expect(vm_host.ndp_needed).to be true
      expect(vm_host.net6.to_s).to eq "2001:db8:1::/64"
    end

    it "records a failed registration outside its transaction" do
      expect(Prog::Vm::HostNexus).to receive(:assemble).and_raise(RuntimeError, "boom")
      expect { described_class.new(**base_args).register! }.to raise_error(RuntimeError, "boom")
      expect(VmHost.count).to eq 0
      expect(audit_rows.map { it.values_at(:command, :target_id, :result) }).to eq [["register-byoh-host", nil, "error: boom"]]
    end

    it "passes BMC config through to host_provider.config" do
      reg = described_class.new(**base_args, bmc_config: {
        "protocol" => "redfish", "endpoint" => "https://192.168.1.11",
        "username" => "admin", "password_env" => "TEST_BMC_PASS_SILENCED",
        "verify_ssl" => false,
      })
      strand = reg.register!
      vm_host = VmHost[strand.id]
      expect(vm_host.provider.config["bmc"]["endpoint"]).to eq("https://192.168.1.11")
    end

    it "passes default_boot_images through to the strand stack so respirate downloads them during prep" do
      reg = described_class.new(**base_args, default_boot_images: ["ubuntu-noble", "ubuntu-jammy"])
      strand = reg.register!
      expect(strand.stack.first["default_boot_images"]).to eq(["ubuntu-noble", "ubuntu-jammy"])
    end

    it "omits default_boot_images from the stack when the kwarg is empty" do
      reg = described_class.new(**base_args)
      strand = reg.register!
      expect(strand.stack.first["default_boot_images"]).to eq([])
    end

    it "honors an operator-supplied server_identifier" do
      reg = described_class.new(**base_args.merge(server_identifier: "homelab-r1-01"))
      strand = reg.register!
      expect(VmHost[strand.id].provider.server_identifier).to eq("homelab-r1-01")
    end
  end
end
