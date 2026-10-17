# frozen_string_literal: true

require_relative "../lib/vm_setup"

# Golden fixtures freeze the systemd units VmSetup writes today for
# cloud-hypervisor VMs and for QEMU+KVM (GPU) VMs, so work on other
# hypervisor modes cannot change them by accident. A fixture changes only
# through a hand-reviewed diff: run this spec locally with UPDATE_GOLDEN=1,
# then review `git diff rhizome/host/spec/fixtures/golden`.
RSpec.describe VmSetup do
  def golden(name, actual)
    path = File.join(__dir__, "fixtures", "golden", name)
    if ENV["UPDATE_GOLDEN"] == "1"
      fail "UPDATE_GOLDEN=1 is refused under CI; regenerate golden fixtures locally and review the diff" if ENV["CI"]
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
    end.new("vmgold01")
  }

  let(:nics) { [VmSetup::Nic.new("fd10:9b0b:6b4b:8fbb::/64", "10.0.0.5/32", "nc5bn8tz4r0", "52:54:00:12:34:56", "10.0.0.1/32")] }
  let(:ubiblk_volume) {
    {"disk_index" => 0, "device_id" => "vmgold01_0", "encrypted" => true, "size_gib" => 40,
     "vhost_block_backend_version" => "v0.4.2", "num_queues" => 2, "queue_size" => 64}
  }
  let(:image_volume) {
    {"disk_index" => 1, "device_id" => "vmgold01_1", "encrypted" => false, "read_only" => true, "size_gib" => 0,
     "image" => "ai-model-test", "image_version" => "20250101", "vhost_block_backend_version" => "v0.4.2"}
  }
  let(:spdk_volume) {
    {"disk_index" => 0, "device_id" => "vmgold01_0", "encrypted" => true, "size_gib" => 40,
     "spdk_version" => "v23.09-ubi-0.3"}
  }

  before do
    stub_const("Arch", ArchClass.new(:x64))
    stub_const("CloudHypervisor::Version::INSTALLED", {"46.0" => CloudHypervisor::Version.new("46.0", "sha_ch", "sha_remote")})
    stub_const("CloudHypervisor::Firmware::INSTALLED", {"202311" => CloudHypervisor::Firmware.new("202311", "sha_fw")})
  end

  def install(vm_setup, *args)
    allow(vm_setup).to receive(:vp).and_return(capture_path)
    expect(vm_setup).to receive(:_run_command).with("systemctl daemon-reload")
    vm_setup.install_systemd_unit(*args)
    capture_path.writes
  end

  def new_setup(**kwargs)
    described_class.new("vmgold01", ch_version: "46.0", firmware_version: "202311", **kwargs)
  end

  it "writes the same cloud-hypervisor unit with hugepages, a slice and a CPU quota" do
    writes = install(new_setup, 4, "2:2:1:1", 4, [ubiblk_volume, image_volume], nics, [], "standard-gold.slice", 400, "ubuntu-noble")
    expect(writes.keys).to eq ["/etc/systemd/system/vmgold01-dnsmasq.service", "/etc/systemd/system/vmgold01.service"]
    expect(writes["/etc/systemd/system/vmgold01.service"]).to eq golden("ch_unit.service", writes["/etc/systemd/system/vmgold01.service"])
    expect(writes["/etc/systemd/system/vmgold01-dnsmasq.service"]).to eq golden("ch_dnsmasq.service", writes["/etc/systemd/system/vmgold01-dnsmasq.service"])
  end

  it "writes the same cloud-hypervisor unit without hugepages on an SPDK volume" do
    writes = install(new_setup(hugepages: false), 2, "1:1:1:2", 2, [spdk_volume], nics, [], "system.slice", 0, "ubuntu-noble")
    expect(writes["/etc/systemd/system/vmgold01.service"]).to eq golden("ch_unit_nohugepages.service", writes["/etc/systemd/system/vmgold01.service"])
  end

  it "writes the same QEMU+KVM unit with hugepages and a GPU on Intel" do
    vm_setup = new_setup(hypervisor: "qemu")
    expect(vm_setup).to receive(:cpu_vendor).and_return("GenuineIntel")
    writes = install(vm_setup, 4, "2:2:1:1", 8, [ubiblk_volume], nics, [["c1:00.0", "17"]], "system.slice", 0, "ubuntu-noble")
    expect(writes["/etc/systemd/system/vmgold01.service"]).to eq golden("qemu_kvm_hugepages.service", writes["/etc/systemd/system/vmgold01.service"])
  end

  it "writes the same QEMU+KVM unit with hugepages and a GPU on AMD" do
    vm_setup = new_setup(hypervisor: "qemu")
    expect(vm_setup).to receive(:cpu_vendor).and_return("AuthenticAMD")
    writes = install(vm_setup, 4, "2:2:1:1", 8, [ubiblk_volume], nics, [["c1:00.0", "17"]], "system.slice", 0, "ubuntu-noble")
    expect(writes["/etc/systemd/system/vmgold01.service"]).to eq golden("qemu_kvm_hugepages_amd.service", writes["/etc/systemd/system/vmgold01.service"])
  end

  # Captured from 9e22d71ec: QEMU+KVM without hugepages gives the guest
  # plain anonymous RAM (-m), not a shared memfd backend.
  it "writes the same QEMU+KVM unit without hugepages and a GPU on Intel" do
    vm_setup = new_setup(hypervisor: "qemu", hugepages: false)
    expect(vm_setup).to receive(:cpu_vendor).and_return("GenuineIntel")
    writes = install(vm_setup, 4, "2:2:1:1", 8, [ubiblk_volume], nics, [["c1:00.0", "17"]], "system.slice", 0, "ubuntu-noble")
    expect(writes["/etc/systemd/system/vmgold01.service"]).to eq golden("qemu_kvm_nohugepages.service", writes["/etc/systemd/system/vmgold01.service"])
  end

  describe "a PVM VM" do
    let(:sha) { "ab" * 32 }

    def pvm_setup(console, **kwargs)
      new_setup(firmware_version: nil, hugepages: false, pvm: {"kernel_sha256" => sha, "root" => "/dev/vda1"}, **kwargs).tap { |vm_setup|
        allow(vm_setup).to receive(:check_pvm_host)
        allow(vm_setup).to receive(:pvm_console).and_return(console)
      }
    end

    {"hvc0" => "ch_unit_pvm_hvc0.service", "ttyS0" => "ch_unit_pvm_ttys0.service"}.each do |console, fixture|
      it "boots the guest kernel directly with console #{console}, without firmware or hugepages" do
        stub_const("CloudHypervisor::Firmware::INSTALLED", {})
        writes = install(pvm_setup(console), 2, "1:1:1:2", 2, [ubiblk_volume], nics, [], "system.slice", 0, "ubuntu-noble")
        unit = writes["/etc/systemd/system/vmgold01.service"]
        expect(unit).to eq golden(fixture, unit)
        expect(unit).to include("--kernel /opt/pvm-guest/#{sha}/vmlinux \\\n--cmdline \"console=#{console} root=/dev/vda1 rw\"")
        expect(unit).not_to include("CLOUDHV")
        # download-pvm-guest-kernel gc keeps the kernel a unit names.
        expect(unit.scan(PvmGuestKernel::UNIT_REFERENCE).flatten).to eq [sha]
      end
    end

    it "keeps refusing a KVM VM on a host without its firmware" do
      stub_const("CloudHypervisor::Firmware::INSTALLED", {})
      expect { new_setup.install_systemd_unit(2, "1:1:1:2", 2, [ubiblk_volume], nics, [], "system.slice", 0, "ubuntu-noble") }
        .to raise_error("no valid cloud hypervisor firmware version")
    end

    it "refuses to append the serial console to the unit's output" do
      expect { pvm_setup("hvc0", append_serial_console: true) }.to raise_error("pvm VMs cannot append the serial console to the unit's output")
    end

    it "leaves every other unit as it was when pvm is nil" do
      writes = install(new_setup(pvm: nil), 4, "2:2:1:1", 4, [ubiblk_volume, image_volume], nics, [], "standard-gold.slice", 400, "ubuntu-noble")
      expect(writes["/etc/systemd/system/vmgold01.service"]).to eq golden("ch_unit.service", writes["/etc/systemd/system/vmgold01.service"])
    end
  end
end
