# frozen_string_literal: true

require_relative "../lib/vm_setup"

# Units for VMs on emulated hosts (accel=tcg). The fixtures hold the exact
# unit text, so every change to the QEMU command line or the systemd
# confinement shows up as a reviewed diff. Regenerate locally with
# UPDATE_FIXTURES=1, then review `git diff rhizome/host/spec/fixtures/qemu_tcg`.
RSpec.describe VmSetup do
  def fixture(name, actual)
    path = File.join(__dir__, "fixtures", "qemu_tcg", name)
    if ENV["UPDATE_FIXTURES"] == "1"
      fail "UPDATE_FIXTURES=1 is refused under CI; regenerate fixtures locally and review the diff" if ENV["CI"]
      File.write(path, actual)
    end
    File.read(path)
  end

  let(:capture_path) {
    Class.new(VmPath) do
      attr_reader :writes

      def write(path, s)
        s += "\n" unless s.end_with?("\n")
        (@writes ||= {})[path] = s
      end
    end.new("vmtcg001")
  }

  let(:nics) { [VmSetup::Nic.new("fd10:9b0b:6b4b:8fbb::/64", "10.0.0.5/32", "nc5bn8tz4r0", "52:54:00:12:34:56", "10.0.0.1/32")] }
  let(:ubiblk_volume) {
    {"disk_index" => 0, "device_id" => "vmtcg001_0", "encrypted" => true, "size_gib" => 20,
     "vhost_block_backend_version" => "v0.4.2", "num_queues" => 2, "queue_size" => 64}
  }
  let(:service) { "/etc/systemd/system/vmtcg001.service" }

  before do
    stub_const("Arch", ArchClass.new(:x64))
    # Emulated hosts have no cloud-hypervisor and no CH firmware.
    stub_const("CloudHypervisor::Version::INSTALLED", {}.freeze)
    stub_const("CloudHypervisor::Firmware::INSTALLED", {}.freeze)
  end

  def new_setup(**kwargs)
    described_class.new("vmtcg001", hypervisor: "qemu", accel: "tcg", **kwargs)
  end

  def install(vm_setup, *args)
    allow(vm_setup).to receive(:vp).and_return(capture_path)
    expect(vm_setup).not_to receive(:cpu_vendor)
    expect(vm_setup).to receive(:_run_command).with("systemctl daemon-reload")
    vm_setup.install_systemd_unit(*args)
    capture_path.writes
  end

  it "writes the TCG unit without hugepages" do
    writes = install(new_setup(hugepages: false), 2, "1:2:1:1", 2, [ubiblk_volume], nics, [], "system.slice", 200, "ubuntu-noble")
    expect(writes[service]).to eq fixture("tcg_unit.service", writes[service])
  end

  it "writes the TCG unit with hugepages" do
    writes = install(new_setup, 2, "1:2:1:1", 2, [ubiblk_volume], nics, [], "system.slice", 200, "ubuntu-noble")
    expect(writes[service]).to eq fixture("tcg_unit_hugepages.service", writes[service])
  end

  it "writes the TCG unit for 4 vCPUs with 9 network queues" do
    writes = install(new_setup(hugepages: false), 4, "1:4:1:1", 4, [ubiblk_volume], nics, [], "standard.slice", 400, "ubuntu-noble")
    expect(writes[service]).to eq fixture("tcg_unit_4vcpu.service", writes[service])
    expect(writes[service]).to include("queues=9,vhost=off")
  end

  it "never asks KVM for anything" do
    unit = install(new_setup(hugepages: false), 2, "1:2:1:1", 2, [ubiblk_volume], nics, [], "system.slice", 0, "ubuntu-noble")[service]
    expect(unit).not_to match(/kvm|vhost=on|-cpu host|\/opt\/fw|CLOUDHV|-daemonize/)
    expect(unit).not_to include("MemoryDenyWriteExecute")
  end

  it "writes the dnsmasq unit unchanged" do
    writes = install(new_setup(hugepages: false), 2, "1:2:1:1", 2, [ubiblk_volume], nics, [], "system.slice", 0, "ubuntu-noble")
    expect(writes["/etc/systemd/system/vmtcg001-dnsmasq.service"]).to eq File.read(File.join(__dir__, "fixtures", "golden", "ch_dnsmasq.service")).gsub("vmgold01", "vmtcg001").sub("standard-gold.slice", "system.slice")
  end

  it "refuses arm64 hosts" do
    stub_const("Arch", ArchClass.new(:arm64))
    vm_setup = new_setup
    allow(vm_setup).to receive(:vp).and_return(capture_path)
    expect { vm_setup.install_systemd_unit(2, "1:2:1:1", 2, [ubiblk_volume], nics, [], "system.slice", 0, "ubuntu-noble") }.to raise_error("emulated hosts support x86_64 only")
  end

  it "refuses PCI passthrough" do
    vm_setup = new_setup
    allow(vm_setup).to receive(:vp).and_return(capture_path)
    expect { vm_setup.install_systemd_unit(2, "1:2:1:1", 2, [ubiblk_volume], nics, [["c1:00.0", "17"]], "system.slice", 0, "ubuntu-noble") }.to raise_error("PCI passthrough is not available on emulated hosts")
  end

  it "sizes MemoryMax as guest RAM plus the unit overhead" do
    expect(QemuTcg.hardening("vmtcg001", 4)).to include("MemoryMax=#{4096 + QemuTcg::UNIT_OVERHEAD_MIB}M\n")
  end

  describe "#prep" do
    it "lays out run/ and serial.log before writing the unit" do
      vm_setup = new_setup(hugepages: false)
      expect(vm_setup).to receive(:cloudinit)
      expect(vm_setup).to receive(:setup_networking)
      expect(vm_setup).to receive(:storage)
      expect(vm_setup).to receive(:hugepages)
      expect(vm_setup).to receive(:prepare_gpus)
      expect(vm_setup).to receive(:emulated_layout).ordered
      expect(vm_setup).to receive(:install_systemd_unit).ordered
      expect(vm_setup).to receive(:start_systemd_unit).ordered
      expect(vm_setup).to receive(:update_via_routes)

      vm_setup.prep(
        "user", ["key"], nics, "fddf::/79", "", "10.0.0.0/31", 2, "1:2:1:1", 2,
        false, [ubiblk_volume], {}, nil, [], "ubuntu-noble", "10.0.0.2", "system.slice", 200, 0, nil, false, nil,
      )
    end
  end

  describe "#emulated_layout" do
    it "makes run/ private to the VM user and serial.log root-owned" do
      vm_setup = new_setup
      expect(vm_setup).to receive(:_run_command).with("install", "-d", "-o", "vmtcg001", "-g", "vmtcg001", "-m", "0700", "/vm/vmtcg001/run").ordered
      expect(vm_setup).to receive(:_run_command).with("install", "-o", "root", "-g", "vmtcg001", "-m", "0660", File::NULL, "/vm/vmtcg001/serial.log").ordered
      vm_setup.emulated_layout
    end
  end
end
