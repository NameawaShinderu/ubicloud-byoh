# frozen_string_literal: true

require "yaml"
require_relative "../lib/vm_setup"

# VmSetup for system containers (hypervisor "lxc", ContainerSetup). The
# cloud-hypervisor and QEMU paths these branches skip are pinned by
# vm_setup_spec.rb and vm_setup_golden_spec.rb.
RSpec.describe VmSetup do
  let(:vm) { "vmcont01" }
  let(:vs) { described_class.new(vm, hypervisor: "lxc", hugepages: false, container: {"nested_userns" => false, "guest_firewall" => false}) }
  let(:nic) { VmSetup::Nic.new("fd48:666c:a296:ce4b:2cc6::/79", "192.168.5.50/32", "nccont01", "3e:bd:a5:96:f7:b9", "10.0.0.254/32") }
  let(:nics) { [nic] }
  let(:volume) { {"disk_index" => 0, "device_id" => "vmcont01_0", "encrypted" => true, "size_gib" => 20, "image" => "ubuntu-noble-container", "image_version" => "20260926"} }
  let(:kek) { {"algorithm" => "aes-256-gcm"} }

  it "is a container only with hypervisor lxc, and refuses container options for another hypervisor" do
    expect(vs.container?).to be true
    expect(described_class.new(vm).container?).to be false
    expect { described_class.new(vm, container: {}) }.to raise_error(RuntimeError, "container VMs need hypervisor lxc, not ch")
  end

  it "passes the container options of prep.json through" do
    built = described_class.from_params(vm, {"hypervisor" => "lxc", "container" => {"nested_userns" => true, "guest_firewall" => true}})
    expect(built.container_setup.nested_userns?).to be true
    expect(built.container_setup.guest_firewall?).to be true
    expect(described_class.new(vm, hypervisor: "lxc").container_setup.guest_firewall?).to be false
  end

  it "refuses what a container cannot have" do
    expect { vs.check_container(nics + nics, nil, []) }.to raise_error(RuntimeError, "container VMs have exactly one network interface, not 2")
    expect { vs.check_container(nics, 1024, []) }.to raise_error(RuntimeError, "container VMs cannot have swap")
    expect { vs.check_container(nics, nil, [["c1:00.0", "17"]]) }.to raise_error(RuntimeError, "container VMs cannot have PCI devices")
    expect(vs.check_container(nics, nil, [])).to be_nil
  end

  it "reads the slot prep allocated, and refuses without one" do
    expect(ContainerIdmap).to receive(:slot).with(vm).and_return(nil)
    expect { vs.container_slot }.to raise_error(RuntimeError, "vmcont01 has no container id slot; prep it first")
    expect(ContainerIdmap).to receive(:slot).with(vm).and_return(4)
    expect(vs.container_slot).to eq 4
  end

  it "has exactly one writable disk" do
    allow(vs).to receive(:container_slot).and_return(1)
    image = {"read_only" => true, "disk_index" => 1}
    expect(vs.container_disk([volume, image]).rootfs).to eq "/var/storage/vmcont01/0/rootfs"
    expect { vs.container_disk([volume, volume]) }.to raise_error(RuntimeError, "container VMs have exactly one disk, not 2")
  end

  describe "#prep" do
    it "allocates the slot, sets up and starts the container, and leaves the tap routes to the network hook" do
      expect(vs).to receive(:check_container).with(nics, nil, []).ordered
      expect(ContainerIdmap).to receive(:allocate).with(vm).and_return(7).ordered
      expect(vs).to receive(:cloudinit).ordered
      expect(vs).to receive(:setup_networking)
      expect(vs).to receive(:storage).with([volume], {"vmcont01_0" => kek}, true)
      expect(vs).to receive(:hugepages).with(4)
      expect(vs).to receive(:prepare_gpus).with([], nil)
      expect(vs).to receive(:install_systemd_unit)
      expect(vs).to receive(:start_systemd_unit)
      expect(vs).not_to receive(:update_via_routes)
      vs.prep("ubi", ["key"], nics, "fddf:53d2:4c89:2305:46a0::/79", "", "169.254.0.0/32", 2, "1:1:1:2", 4, false,
        [volume], {"vmcont01_0" => kek}, nil, [], "ubuntu-noble-container", "10.0.0.2", "system.slice", 0, 0, "", false, nil)
      expect(vs.container_slot).to eq 7
    end

    it "skips the tap routes when recreating or reassigning" do
      expect(vs).to receive(:setup_networking).twice
      expect(vs).to receive(:hugepages).twice
      expect(vs).to receive(:storage).twice
      expect(vs).to receive(:prepare_gpus)
      expect(vs).to receive(:start_systemd_unit).twice
      expect(vs).to receive(:cloudinit)
      expect(vs).to receive(:install_systemd_unit)
      expect(vs).not_to receive(:update_via_routes)
      vs.recreate_unpersisted("fddf::/79", "", "169.254.0.0/32", nics, 4, false, [volume], {}, "10.0.0.2", [], "system.slice", 0, nil, multiqueue: true)
      vs.reassign_ip6("ubi", ["key"], nics, "fddf::/79", "", "169.254.0.0/32", 2, "1:1:1:2", 4, false, [volume], {}, nil, [], "ubuntu-noble-container",
        "10.0.0.2", "system.slice", 0, 0, false, "")
    end
  end

  describe "networking" do
    it "creates no tap: LXC does when the container starts" do
      expect(vs).to receive(:_run_command).with("ip", "netns", "del", vm)
      expect(File).to receive(:exist?).with("/sys/class/net/vetho#{vm}").and_return(false)
      expect(vs).to receive(:_run_command).with("ip", "netns", "add", vm)
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "link", "set", "lo", "up")
      expect(vs).to receive(:gen_mac).and_return("00:00:00:00:00:00").twice
      expect(vs).to receive(:_run_command).with("ip", "link", "add", "vetho#{vm}", "addr", "00:00:00:00:00:00", "type", "veth", "peer", "name", "vethi#{vm}", "addr", "00:00:00:00:00:00", "netns", vm)
      vs.interfaces(nics, true)
    end

    it "leaves the tap's addresses and routes out of setup_networking" do
      expect(vs).to receive(:interfaces)
      expect(vs).to receive(:setup_veths_6)
      expect(vs).not_to receive(:setup_taps_6)
      expect(vs).to receive(:routes4)
      expect(vs).to receive(:write_nftables_conf)
      expect(vs).to receive(:forwarding)
      vs.setup_networking(true, "fddf:53d2:4c89:2305:46a0::/79", "", "169.254.0.0/32", nics, false, "10.0.0.2", multiqueue: false)
    end

    it "routes nothing through the tap in routes4" do
      expect(vs).to receive(:_run_command).with("ip", "addr", "replace", "10.0.0.0/32", "dev", "vetho#{vm}")
      expect(vs).to receive(:_run_command).with("ip", "route", "replace", "10.0.0.2/32", "dev", "vetho#{vm}")
      expect(vs).to receive(:_run_command).with("echo 1 > /proc/sys/net/ipv4/conf/vetho#{vm}/proxy_arp")
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "addr", "replace", "10.0.0.2/32", "dev", "vethi#{vm}")
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "route", "replace", "10.0.0.0", "dev", "vethi#{vm}")
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "route", "replace", "default", "via", "10.0.0.0", "dev", "vethi#{vm}")
      expect(vs).to receive(:_run_command).with("ip netns exec #{vm} bash -c echo\\ 1\\ \\>\\ /proc/sys/net/ipv4/conf/vethi#{vm}/proxy_arp")
      vs.routes4("10.0.0.2/32", "10.0.0.0/31", nics)
    end

    it "gives the tap the addresses and routes of a cloud-hypervisor tap from the network hook" do
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "addr", "replace", "10.0.0.254/32", "dev", "nccont01").ordered
      expect(vs).to receive(:setup_taps_6).with("fddf::/79", nics, "10.0.0.2").ordered
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "route", "replace", "203.0.113.5/32", "dev", "nccont01").ordered
      expect(vs).to receive(:_run_command).with("ip netns exec #{vm} bash -c echo\\ 1\\ \\>\\ /proc/sys/net/ipv4/conf/nccont01/proxy_arp").ordered
      vs.container_net_up("fddf::/79", "203.0.113.5/32", nics, "10.0.0.2")
    end

    it "routes a private subnet larger than /32 through its gateway, and skips the IPv4 route without a public IPv4" do
      subnet_nic = VmSetup::Nic.new("fd48::/79", "10.5.0.0/30", "nccont01", "3e:bd:a5:96:f7:b9", "10.5.0.1/32")
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "addr", "replace", "10.5.0.1/32", "dev", "nccont01")
      expect(vs).to receive(:setup_taps_6)
      expect(vs).to receive(:_run_command).with("ip netns exec #{vm} bash -c echo\\ 1\\ \\>\\ /proc/sys/net/ipv4/conf/nccont01/proxy_arp")
      expect(vs).to receive(:_run_command).with("ip", "-n", vm, "route", "replace", "10.5.0.0/30", "via", "10.5.0.1", "dev", "nccont01")
      vs.container_net_up("fddf::/79", "", [subnet_nic], "10.0.0.2")
    end
  end

  describe "#cloudinit" do
    let(:writes) { {} }
    let(:vps) {
      w = writes
      Class.new(VmPath) {
        define_method(:write) { |path, s| w[File.basename(path)] = s.end_with?("\n") ? s : "#{s}\n" }
      }.new(vm)
    }

    before do
      allow(vs).to receive(:vp).and_return(vps)
      allow(File).to receive(:read).and_call_original
      %w[meta-data user-data network-config].each { |f| allow(File).to receive(:read).with("/vm/#{vm}/#{f}") { writes.fetch(f) } }
    end

    it "writes a seed instead of a CIDATA image, binds dnsmasq dynamically and keeps the root file system as it is" do
      expect(vs.container_setup).to receive(:write_seed) do |meta_data:, user_data:, network_config:|
        expect(meta_data).to eq writes["meta-data"]
        expect(network_config).to eq writes["network-config"]
        expect(user_data).to eq writes["user-data"]
      end
      expect(vs).not_to receive(:_run_command)
      vs.cloudinit("ubi", ["key"], "fddf:53d2:4c89:2305:46a0::/79", nics, nil, "ubuntu-noble-container", "10.0.0.2", ipv6_disabled: false)
      expect(writes["dnsmasq.conf"]).to include("\nbind-dynamic\n")
      expect(writes["dnsmasq.conf"]).not_to include("bind-interfaces")
      user_data = YAML.safe_load(writes["user-data"])
      expect(user_data["growpart"]).to eq({"mode" => "off"})
      expect(user_data["resize_rootfs"]).to be false
      expect(user_data["bootcmd"]).to eq []
      expect(YAML.safe_load(writes["network-config"])).to eq({"version" => 2, "ethernets" => {"eth0" => {"dhcp6" => true, "dhcp4" => true}}})
    end

    it "keeps the guest's nftables rule where guest firewalls are acknowledged" do
      fw = described_class.new(vm, hypervisor: "lxc", container: {"guest_firewall" => true})
      allow(fw).to receive(:vp).and_return(vps)
      expect(fw.container_setup).to receive(:write_seed)
      fw.cloudinit("ubi", ["key"], "fddf:53d2:4c89:2305:46a0::/79", nics, nil, "ubuntu-noble-container", "10.0.0.2", ipv6_disabled: false)
      expect(YAML.safe_load(writes["user-data"])["bootcmd"].size).to eq 3
    end
  end

  describe "storage" do
    let(:disk) { instance_double(ContainerDisk) }

    before { allow(vs).to receive(:container_disk).with([volume]).and_return(disk) }

    it "preps the disk from the boot image's root tarball" do
      expect(disk).to receive(:prep).with(kek, "/var/storage/images/ubuntu-noble-container-20260926.tar.xz")
      vs.storage([volume], {"vmcont01_0" => kek}, true)
    end

    it "starts the disk otherwise" do
      expect(disk).to receive(:start).with(kek)
      vs.storage([volume], {"vmcont01_0" => kek}, false)
    end
  end

  it "writes the dnsmasq unit, the LXC configuration and the container unit" do
    writes = {}
    vps = Class.new(VmPath) { define_method(:write) { |path, s| writes[path] = s } }.new(vm)
    allow(vs).to receive_messages(vp: vps, container_slot: 3)
    expect(vs.container_setup).to receive(:write_config).with(rootfs: "/var/storage/vmcont01/0/rootfs", slot: 3, nics: nics, mem_gib: 4, max_vcpus: 2, slice_name: "system.slice")
    expect(vs).to receive(:_run_command).with("systemctl daemon-reload")
    vs.install_systemd_unit(2, "1:1:1:2", 4, [volume], nics, [], "system.slice", 0, "ubuntu-noble-container")
    expect(writes.keys).to eq ["/etc/systemd/system/vmcont01-dnsmasq.service", "/etc/systemd/system/vmcont01.service"]
    expect(writes["/etc/systemd/system/vmcont01.service"]).to eq vs.container_setup.unit(slice_name: "system.slice")
  end

  describe "#purge_storage" do
    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/vm/#{vm}/prep.json").and_return(true)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/vm/#{vm}/prep.json").and_return(JSON.generate({"storage_volumes" => [volume, {"read_only" => true}]}))
    end

    it "removes the disk and LXC's files, then frees the slot" do
      disk = instance_double(ContainerDisk)
      expect(ContainerIdmap).to receive(:slot).with(vm).and_return(5)
      expect(ContainerDisk).to receive(:new).with(vm, volume, 5).and_return(disk)
      expect(disk).to receive(:purge).ordered
      expect(vs.container_setup).to receive(:purge).ordered
      expect(ContainerIdmap).to receive(:release).with(vm).ordered
      vs.purge_storage
    end

    it "keeps the slot when the disk is not gone" do
      disk = instance_double(ContainerDisk)
      expect(ContainerIdmap).to receive(:slot).with(vm).and_return(nil)
      expect(ContainerDisk).to receive(:new).with(vm, volume, 0).and_return(disk)
      expect(disk).to receive(:purge).and_raise(RuntimeError, "still exists")
      expect(ContainerIdmap).not_to receive(:release)
      expect { vs.purge_storage }.to raise_error(RuntimeError, "still exists")
    end
  end
end
