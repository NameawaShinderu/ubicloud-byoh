# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/container_setup"
require_relative "../lib/vm_setup"

# The LXC configuration, seccomp policy, network hook and unit of a
# system container are pinned by fixtures (UPDATE_GOLDEN=1 regenerates
# them; review the diff of rhizome/host/spec/fixtures/golden/container_*).
RSpec.describe ContainerSetup do
  def golden(name, actual)
    path = File.join(__dir__, "fixtures", "golden", name)
    if ENV["UPDATE_GOLDEN"] == "1"
      fail "UPDATE_GOLDEN=1 is refused under CI; regenerate golden fixtures locally and review the diff" if ENV["CI"]
      File.write(path, actual)
    end
    File.read(path)
  end

  let(:setup) { described_class.new("vmcont01") }
  let(:nics) { [VmSetup::Nic.new("fd10:9b0b:6b4b:8fbb::/64", "10.0.0.5/32", "nccont01", "52:54:00:12:34:56", "10.0.0.1/32")] }
  let(:config_args) { {rootfs: "/var/storage/vmcont01/0/rootfs", slot: 3, nics: nics, mem_gib: 8, max_vcpus: 2, slice_name: "system.slice"} }

  it "writes the LXC configuration with the slot's ids, the limits and one veth per NIC" do
    expect(setup.lxc_config(**config_args)).to eq golden("container_lxc.conf", setup.lxc_config(**config_args))
    expect(setup.lxc_config(**config_args)).to include("lxc.idmap = u 0 1000196608 65536\n")
  end

  it "runs containers only in system.slice" do
    expect { setup.lxc_config(**config_args, slice_name: "standard.slice") }.to raise_error(RuntimeError, "container VMs run in system.slice, not standard.slice")
  end

  it "denies new user namespaces and netfilter sockets unless acknowledged" do
    expect(setup.seccomp_policy).to eq golden("container_seccomp", setup.seccomp_policy)
    open = described_class.new("vmcont01", nested_userns: true, guest_firewall: true)
    expect(open.nested_userns?).to be true
    expect(open.guest_firewall?).to be true
    expect(open.seccomp_policy).to eq setup.seccomp_policy.lines.reject { _1.match?(/\A(clone3|clone|unshare|socket) /) }.join
  end

  it "writes the network hook, the unit and the stop command" do
    expect(setup.net_up_script).to eq golden("container_net_up", setup.net_up_script)
    expect(setup.unit(slice_name: "system.slice")).to eq golden("container_unit.service", setup.unit(slice_name: "system.slice"))
    expect(setup.stop_command).to eq ["/usr/bin/nsenter", "--net=/var/run/netns/vmcont01", "/usr/bin/lxc-stop", "-n", "vmcont01", "-P", "/var/lib/ubicloud/lxc", "--nowait"]
    expect(setup.payload_cgroup("system.slice")).to eq "system.slice/vmcont01.service/lxc.payload"
  end

  it "refuses names that are not VM names" do
    expect { described_class.new("../x") }.to raise_error(RuntimeError, /unexpected VM name/)
  end

  context "with a directory" do
    around do |example|
      Dir.mktmpdir("lxc") do |dir|
        @lxc_path = File.join(dir, "lxc")
        example.run
      end
    end

    let(:setup) { described_class.new("vmcont01", lxc_path: @lxc_path) }

    def expect_dirs
      expect(setup).to receive(:r).with("install", "-d", "-o", "root", "-g", "root", "-m", "0711", @lxc_path) { FileUtils.mkdir_p(@lxc_path) }
      expect(setup).to receive(:r).with("install", "-d", "-o", "root", "-g", "root", "-m", "0711", setup.dir) { FileUtils.mkdir_p(setup.dir) }
    end

    it "writes the configuration files root-only" do
      expect_dirs
      setup.write_config(**config_args)
      expect(File.read(setup.config_path)).to eq setup.lxc_config(**config_args)
      expect(File.read(setup.seccomp_path)).to eq setup.seccomp_policy
      expect(File.read(setup.net_up_path)).to eq setup.net_up_script
      expect(File.stat(setup.config_path).mode & 0o777).to eq 0o600
      expect(File.stat(setup.seccomp_path).mode & 0o777).to eq 0o600
      expect(File.stat(setup.net_up_path).mode & 0o777).to eq 0o700
    end

    it "writes the seed readable only for root and the container's root, and purges the directory" do
      expect_dirs
      gid = ContainerIdmap.base(3)
      expect(setup).to receive(:r).with("install", "-d", "-o", "root", "-g", gid.to_s, "-m", "0750", setup.seed_dir) { FileUtils.mkdir_p(setup.seed_dir) }
      %w[meta-data user-data network-config].each { |f| expect(File).to receive(:chown).with(nil, gid, File.join(setup.seed_dir, "#{f}.tmp")) }
      setup.write_seed(meta_data: "m\n", user_data: "u\n", network_config: "n\n", slot: 3)
      expect(File.read(File.join(setup.seed_dir, "user-data"))).to eq "u\n"
      expect(File.read(File.join(setup.seed_dir, "meta-data"))).to eq "m\n"
      expect(File.stat(File.join(setup.seed_dir, "network-config")).mode & 0o777).to eq 0o640
      setup.purge
      expect(File.exist?(setup.dir)).to be false
    end
  end
end
