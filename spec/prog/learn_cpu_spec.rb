# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnCpu do
  subject(:lc) { described_class.new(Strand.create_with_id(sshable, prog: "LearnCpu", label: "start")) }

  let(:sshable) { Sshable.create(host: "test") }

  # Gin up a topologically complex processor to test summations.
  let(:eight_thread_four_core_four_numa_two_socket) do
    <<JSON
{
   "cpus": [
      {
         "cpu": 0,
         "node": 0,
         "socket": 0,
         "core": 0
      },{
         "cpu": 1,
         "node": 0,
         "socket": 0,
         "core": 0
      },{
         "cpu": 2,
         "node": 1,
         "socket": 0,
         "core": 1
      },{
         "cpu": 3,
         "node": 1,
         "socket": 0,
         "core": 1
      },{
         "cpu": 4,
         "node": 2,
         "socket": 1,
         "core": 0
      },{
         "cpu": 5,
         "node": 2,
         "socket": 1,
         "core": 0
      },{
         "cpu": 6,
         "node": 3,
         "socket": 1,
         "core": 1
      },{
         "cpu": 7,
         "node": 3,
         "socket": 1,
         "core": 1
      }
   ]
}
JSON
  end

  # Ubuntu 22.04's older util-linux quotes every lscpu field, including
  # "cpu" and "node", as a JSON string, and lists cpus out of numeric
  # order across sockets/NUMA nodes.
  let(:twelve_thread_six_core_two_numa_two_socket_string_fields) do
    <<JSON
{
   "cpus": [
      {"cpu": "0", "node": "0", "socket": "0", "core": "0", "l1d:l1i:l2:l3": "0:0:0:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "1", "node": "0", "socket": "0", "core": "0", "l1d:l1i:l2:l3": "0:0:0:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "3100.000"},
      {"cpu": "2", "node": "0", "socket": "0", "core": "1", "l1d:l1i:l2:l3": "1:1:1:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "3", "node": "0", "socket": "0", "core": "1", "l1d:l1i:l2:l3": "1:1:1:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2900.000"},
      {"cpu": "10", "node": "1", "socket": "1", "core": "4", "l1d:l1i:l2:l3": "4:4:4:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "11", "node": "1", "socket": "1", "core": "4", "l1d:l1i:l2:l3": "4:4:4:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2700.000"},
      {"cpu": "4", "node": "1", "socket": "1", "core": "2", "l1d:l1i:l2:l3": "2:2:2:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "5", "node": "1", "socket": "1", "core": "2", "l1d:l1i:l2:l3": "2:2:2:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2600.000"},
      {"cpu": "6", "node": "0", "socket": "0", "core": "3", "l1d:l1i:l2:l3": "3:3:3:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "7", "node": "0", "socket": "0", "core": "3", "l1d:l1i:l2:l3": "3:3:3:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "3000.000"},
      {"cpu": "8", "node": "1", "socket": "1", "core": "5", "l1d:l1i:l2:l3": "5:5:5:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "9", "node": "1", "socket": "1", "core": "5", "l1d:l1i:l2:l3": "5:5:5:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2800.000"}
   ]
}
JSON
  end

  # Ubuntu 24.04's util-linux emits numeric lscpu fields as JSON numbers,
  # and includes extra columns LearnCpu doesn't use.
  let(:eight_thread_four_core_two_numa_two_socket_numeric_fields) do
    <<JSON
{
   "cpus": [
      {"cpu": 0, "node": 0, "socket": 0, "core": 0, "l1d:l1i:l2:l3": "0:0:0:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4312.5000},
      {"cpu": 1, "node": 0, "socket": 0, "core": 0, "l1d:l1i:l2:l3": "0:0:0:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000},
      {"cpu": 2, "node": 0, "socket": 0, "core": 1, "l1d:l1i:l2:l3": "1:1:1:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4801.2200},
      {"cpu": 3, "node": 0, "socket": 0, "core": 1, "l1d:l1i:l2:l3": "1:1:1:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000},
      {"cpu": 4, "node": 1, "socket": 1, "core": 2, "l1d:l1i:l2:l3": "2:2:2:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4600.3300},
      {"cpu": 5, "node": 1, "socket": 1, "core": 2, "l1d:l1i:l2:l3": "2:2:2:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000},
      {"cpu": 6, "node": 1, "socket": 1, "core": 3, "l1d:l1i:l2:l3": "3:3:3:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4700.4400},
      {"cpu": 7, "node": 1, "socket": 1, "core": 3, "l1d:l1i:l2:l3": "3:3:3:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000}
   ]
}
JSON
  end

  # Hosts without NUMA support at the kernel/sysfs level (no
  # /sys/devices/system/node) omit the "node" field entirely.
  let(:four_thread_two_core_no_numa) do
    <<JSON
{
   "cpus": [
      {"cpu": 0, "socket": 0, "core": 0},
      {"cpu": 1, "socket": 0, "core": 0},
      {"cpu": 2, "socket": 0, "core": 1},
      {"cpu": 3, "socket": 0, "core": 1}
   ]
}
JSON
  end

  describe "#get_arch" do
    it "returns the architecture" do
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("x64")
      expect(lc.get_arch).to eq("x64")
    end

    it "fails when there's an unexpected architecture" do
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("s390x")
      expect { lc.get_arch }.to raise_error RuntimeError, "BUG: unexpected CPU architecture"
    end
  end

  describe "#get_topology" do
    it "returns the CPU topology" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        eight_thread_four_core_four_numa_two_socket,
      )
      expect(lc.get_topology).to eq({total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3]})
    end

    it "ignores extra lscpu columns and a boolean online field (Ubuntu 24.04-style output)" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        eight_thread_four_core_two_numa_two_socket_numeric_fields,
      )
      expect(lc.get_topology).to eq({total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 0, 0, 1, 1, 1, 1]})
    end

    it "coerces string cpu/node fields to integers and sorts numerically, not lexicographically (Ubuntu 22.04-style output)" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        twelve_thread_six_core_two_numa_two_socket_string_fields,
      )
      expect(lc.get_topology).to eq(
        {total_cpus: 12, total_cores: 6, total_sockets: 2, cpu_numa_nodes: [0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1]},
      )
    end

    it "reports nil numa nodes when the host has no NUMA data at all" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(four_thread_two_core_no_numa)
      expect(lc.get_topology).to eq({total_cpus: 4, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [nil, nil, nil, nil]})
    end
  end

  describe "#count_dies" do
    it "returns the number of dies" do
      expect(lc.sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu*/topology/die_id").and_return("0\n1\n0\n1\n")
      expect(lc.count_dies(arch: "x64", total_sockets: 2)).to eq(2)
    end

    it "returns the number of sockets when on arm64" do
      expect(lc.count_dies(arch: "arm64", total_sockets: 2)).to eq(2)
    end
  end

  describe "#get_byoh_topology" do
    def lscpu_fixture(name)
      File.read(File.expand_path("../fixtures/byoh/lscpu/#{name}.txt", __dir__))
    end

    def topology_of(name)
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -a -p=CPU,NODE,SOCKET,CORE,ONLINE").and_return(lscpu_fixture(name))
      lc.get_byoh_topology
    end

    it "counts every cpu as a core on a hybrid cpu" do
      expect(topology_of("i7-12700-hybrid")).to eq(
        {total_cpus: 20, total_cores: 20, total_sockets: 1, cpu_numa_nodes: [0] * 20, cpu_numbers: (0..19).to_a},
      )
    end

    it "keeps the SMT core count when every core has the same number of threads" do
      expect(topology_of("epyc-uniform-smt")).to eq(
        {total_cpus: 16, total_cores: 8, total_sockets: 1, cpu_numa_nodes: [0, 0, 0, 0, 1, 1, 1, 1] * 2, cpu_numbers: (0..15).to_a},
      )
      expect(topology_of("captured-x64-16cpu")).to eq(
        {total_cpus: 16, total_cores: 8, total_sockets: 1, cpu_numa_nodes: [0] * 16, cpu_numbers: (0..15).to_a},
      )
    end

    it "counts every online cpu as a core when only some cores lost their second thread" do
      expect(topology_of("partial-nosmt")).to eq(
        {total_cpus: 6, total_cores: 6, total_sockets: 1, cpu_numa_nodes: [0] * 6, cpu_numbers: (0..5).to_a},
      )
    end

    it "skips offline cpus and keeps the gap in the cpu numbers" do
      expect(topology_of("two-of-sixteen-offline")).to eq(
        {total_cpus: 14, total_cores: 7, total_sockets: 1, cpu_numa_nodes: [0] * 14, cpu_numbers: [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15]},
      )
      expect(topology_of("captured-sysroot-two-offline")).to eq(
        {total_cpus: 2, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [nil, nil], cpu_numbers: [0, 1]},
      )
    end

    it "reads uniform arm64 hosts, including big.LITTLE ones whose core ids restart per cluster" do
      expect(topology_of("arm64-uniform")).to eq(
        {total_cpus: 8, total_cores: 8, total_sockets: 1, cpu_numa_nodes: [0] * 8, cpu_numbers: (0..7).to_a},
      )
      expect(topology_of("arm-big-little")).to eq(
        {total_cpus: 8, total_cores: 8, total_sockets: 1, cpu_numa_nodes: [nil] * 8, cpu_numbers: (0..7).to_a},
      )
    end

    it "reads a small virtual machine without NUMA data" do
      expect(topology_of("vm-4-vcpu")).to eq(
        {total_cpus: 4, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [nil] * 4, cpu_numbers: (0..3).to_a},
      )
    end

    it "sorts cpus numerically and counts sockets" do
      expect(lc.sshable).to receive(:_cmd).and_return("10,1,1,3,Y\n2,0,0,1,Y\n3,0,0,1,Y\n11,1,1,3,Y\n")
      expect(lc.get_byoh_topology).to eq(
        {total_cpus: 4, total_cores: 2, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1], cpu_numbers: [2, 3, 10, 11]},
      )
    end

    it "counts one socket on an arm64 host in cluster mode, where lscpu leaves every socket empty" do
      expect(topology_of("arm64-cluster-mode")).to eq(
        {total_cpus: 8, total_cores: 8, total_sockets: 1, cpu_numa_nodes: [0] * 8, cpu_numbers: (0..7).to_a},
      )
    end

    it "fails when an online cpu has no core" do
      expect(lc.sshable).to receive(:_cmd).and_return("0,0,0,0,Y\n1,0,0,,Y\n")
      expect { lc.get_byoh_topology }.to raise_error RuntimeError, "lscpu reported no core for online cpu 1"
    end

    it "fails when an online cpu has a socket that is not a number" do
      expect(lc.sshable).to receive(:_cmd).and_return("0,0,0,0,Y\n1,0,-,1,Y\n")
      expect { lc.get_byoh_topology }.to raise_error RuntimeError, 'lscpu reported socket "-" for online cpu 1'
    end

    it "fails when only some online cpus have a socket" do
      expect(lc.sshable).to receive(:_cmd).and_return("0,0,0,0,Y\n1,0,,1,Y\n")
      expect { lc.get_byoh_topology }.to raise_error RuntimeError, "lscpu reported a socket for only some online cpus"
    end

    it "fails when no cpu is online" do
      expect(lc.sshable).to receive(:_cmd).and_return("# CPU,Node,Socket,Core,Online\n0,0,0,,N\n")
      expect { lc.get_byoh_topology }.to raise_error RuntimeError, "lscpu reported no online cpus"
    end
  end

  describe "#count_dies with cpu numbers" do
    it "reads die_id of the given cpus only" do
      expect(lc.sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu0/topology/die_id /sys/devices/system/cpu/cpu8/topology/die_id").and_return("0\n1\n")
      expect(lc.count_dies(arch: "x64", total_sockets: 1, cpu_numbers: [0, 8])).to eq(2)
    end

    it "returns the number of sockets when on arm64" do
      expect(lc.count_dies(arch: "arm64", total_sockets: 2, cpu_numbers: [0, 8])).to eq(2)
    end
  end

  describe "#start on a BYOH host" do
    let(:sshable) { vm_host.sshable }
    let(:vm_host) do
      location = Location.create(name: "byoh-cpu", display_name: "byoh-cpu", ui_name: "byoh-cpu", visible: false,
        provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {})
      create_vm_host(location_id: location.id).tap do |vmh|
        HostProvider.create { |hp|
          hp.id = vmh.id
          hp.provider_name = HostProvider::GENERIC_PROVIDER_NAME
          hp.server_identifier = "byoh-cpu"
        }
      end
    end

    it "pops the online cpu numbers and dies of the online cpus" do
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("x64")
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -a -p=CPU,NODE,SOCKET,CORE,ONLINE").and_return("0,0,0,0,Y\n1,0,0,0,N\n2,0,0,1,Y\n")
      expect(lc.sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu0/topology/die_id /sys/devices/system/cpu/cpu2/topology/die_id").and_return("0\n0\n")
      expect { lc.start }.to exit(arch: "x64", total_cpus: 2, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [0, 0], cpu_numbers: [0, 2], total_dies: 1)
    end

    it "pops one socket for an arm64 host whose lscpu leaves every socket empty" do
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("arm64")
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -a -p=CPU,NODE,SOCKET,CORE,ONLINE").and_return("0,0,,0,Y\n1,0,,1,Y\n")
      expect { lc.start }.to exit(arch: "arm64", total_cpus: 2, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [0, 0], cpu_numbers: [0, 1], total_dies: 1)
    end

    it "takes the upstream path for a generic host outside a BYOH location" do
      vm_host.update(location_id: Location::HETZNER_FSN1_ID)
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("x64")
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(four_thread_two_core_no_numa)
      expect(lc.sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu*/topology/die_id").and_return("0\n0\n0\n0\n")
      expect { lc.start }.to exit(arch: "x64", total_cpus: 4, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [nil] * 4, total_dies: 1)
    end
  end

  describe "#start" do
    it "pops with cpu info" do
      allow(lc).to receive_messages(
        get_arch: "x64",
        get_topology: {total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3]},
        count_dies: 2,
      )
      expect { lc.start }.to exit(arch: "x64", total_cpus: 8, total_cores: 4, total_dies: 2, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3])
    end
  end
end
