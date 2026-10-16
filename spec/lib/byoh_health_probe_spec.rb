# frozen_string_literal: true

RSpec.describe ByohHealthProbe do
  def fixture(kind, name)
    File.read(File.expand_path("../fixtures/byoh/#{kind}/#{name}.txt", __dir__)).lines.reject { it.start_with?("# fixture:") }.join
  end

  # Builds the output SCRIPT prints. devices maps a device name to
  # {"smartctl" => fixture name, "nvme-id" => ..., "nvme-smart" => ...}.
  def probe_output(virt: "none", clocksource: "bare-metal-tsc", devices: {})
    out = "==ubicloud-probe virt\n#{virt}\n==ubicloud-probe clocksource\n#{fixture("clocksource", clocksource)}"
    devices.each do |device, sections|
      sections.each do |kind, name|
        dir = (kind == "smartctl") ? "smartctl" : "nvme"
        out << "==ubicloud-probe #{kind} #{device}\n" << (name ? fixture(dir, name) : "")
      end
    end
    out
  end

  def probe(**)
    described_class.parse(probe_output(**))
  end

  describe ".run" do
    it "runs the script once with the device names shell-escaped" do
      session = Net::SSH::Connection::Session.allocate
      expect(session).to receive(:_exec!) do |command|
        expect(command).to include("for d in vda nvme0n1\\;\\ reboot; do")
        expect(command).to include("sudo smartctl -j -i -H \"/dev/$d\" 2>/dev/null || true")
        expect(command).to include("if [ ! -e \"/sys/block/$d\" ]; then")
        Net::SSH::Connection::Session::StringWithExitstatus.new(probe_output(virt: "kvm"), 0)
      end
      result = described_class.run(session, ["vda", "nvme0n1; reboot"])
      expect(result["virt"]).to eq "kvm\n"
      expect(result["devices"]).to eq({})
    end
  end

  describe ".parse" do
    it "splits the sections and ignores text before the first marker" do
      result = described_class.parse("motd\n==ubicloud-probe virt\nkvm\n==ubicloud-probe smartctl vda\n{}\n==ubicloud-probe nvme-id nvme0n1\n")
      expect(result).to eq("virt" => "kvm\n", "clocksource" => "", "devices" => {"vda" => {"smartctl" => "{}\n"}, "nvme0n1" => {"nvme-id" => ""}})
    end
  end

  describe ".device_verdict" do
    def verdict(device, sections, **)
      described_class.device_verdict(probe(devices: {device => sections}, **), device)
    end

    it "skips an EBS volume by its nvme id-ctrl model" do
      expect(verdict("nvme0n1", {"smartctl" => "ebs-nvme", "nvme-id" => "id-ctrl-ebs", "nvme-smart" => nil}))
        .to eq described_class::Verdict.new(true, "virtual disk Amazon Elastic Block Store")
    end

    it "falls back to the smartctl model when nvme id-ctrl printed nothing" do
      expect(verdict("nvme0n1", {"smartctl" => "ebs-nvme", "nvme-id" => nil, "nvme-smart" => nil}).ok).to be true
    end

    it "falls back to the smartctl model when nvme id-ctrl has no model" do
      sections = described_class.parse("==ubicloud-probe nvme-id nvme0n1\n{\"vid\":1}\n==ubicloud-probe smartctl nvme0n1\n#{fixture("smartctl", "ebs-nvme")}")
      expect(described_class.device_verdict(sections, "nvme0n1").reason).to eq "virtual disk Amazon Elastic Block Store"
    end

    it "skips a QEMU SCSI disk by its vendor and product" do
      expect(verdict("sda", {"smartctl" => "scsi-qemu"})).to eq described_class::Verdict.new(true, "virtual disk QEMU QEMU HARDDISK")
    end

    it "skips a virtio disk smartctl cannot open, as it has no SMART" do
      expect(verdict("vda", {"smartctl" => "virtio-unavailable"})).to eq described_class::Verdict.new(true, "SMART not supported")
    end

    it "skips a disk smartctl cannot identify, as captured on a loop device" do
      expect(verdict("vda", {"smartctl" => "loop-undetected"})).to eq described_class::Verdict.new(true, "SMART not supported")
    end

    it "fails a disk smartctl cannot open" do
      expect(verdict("sda", {"smartctl" => "open-failed"}))
        .to eq described_class::Verdict.new(false, "smartctl could not open the device: Smartctl open device: /dev/nvme0n1 failed: Operation not permitted")
    end

    it "fails an NVMe disk whose smart-log cannot be read" do
      expect(verdict("nvme0n1", {"smartctl" => "open-failed", "nvme-id" => "smart-log-error", "nvme-smart" => "smart-log-error"}))
        .to eq described_class::Verdict.new(false, "nvme smart-log failed: /dev/nvme0n1: Operation not permitted")
    end

    it "skips a real disk without SMART support" do
      expect(verdict("sdc", {"smartctl" => "usb-unsupported"})).to eq described_class::Verdict.new(true, "SMART not supported")
    end

    it "passes and fails real SATA disks on their SMART status" do
      expect(verdict("sda", {"smartctl" => "ata-passed"})).to eq described_class::Verdict.new(true, "smartctl passed")
      expect(verdict("sdb", {"smartctl" => "ata-failed"})).to eq described_class::Verdict.new(false, "smartctl reports a failing disk")
    end

    it "fails a SMART-capable disk without a health status" do
      expect(verdict("sdb", {"smartctl" => "ata-no-status"})).to eq described_class::Verdict.new(false, "smartctl gave no health status for a SMART-capable disk")
    end

    it "fails a disk smartctl printed nothing or no JSON object for" do
      expect(verdict("sda", {"smartctl" => nil})).to eq described_class::Verdict.new(false, "no smartctl output")
      expect(described_class.device_verdict(described_class.parse("==ubicloud-probe smartctl sda\nnot json\n"), "sda").ok).to be false
      expect(described_class.device_verdict(described_class.parse("==ubicloud-probe smartctl sda\ntrue\n"), "sda").ok).to be false
    end

    it "fails a device that is not a block device on the host" do
      expect(described_class.device_verdict(described_class.parse("==ubicloud-probe missing vdz\n"), "vdz")).to eq described_class::Verdict.new(false, "/dev/vdz is not a block device")
    end

    it "fails a partition or other device that is not a whole disk, naming the fix" do
      expect(described_class.device_verdict(described_class.parse("==ubicloud-probe notdisk vda1\n"), "vda1")).to eq described_class::Verdict.new(false, "/dev/vda1 is not a whole disk; run bin/byoh-host relearn-device-ids")
    end

    it "fails a device missing from the probe" do
      expect(described_class.device_verdict(probe, "sdz")).to eq described_class::Verdict.new(false, "no smartctl output")
    end

    it "checks a real NVMe disk's smart-log" do
      real = {"smartctl" => "nvme-samsung", "nvme-id" => "id-ctrl-samsung"}
      expect(verdict("nvme0n1", real.merge("nvme-smart" => "smart-log-ok"))).to eq described_class::Verdict.new(true, "nvme smart-log passed")
      expect(verdict("nvme0n1", real.merge("nvme-smart" => "smart-log-critical")))
        .to eq described_class::Verdict.new(false, "nvme smart-log critical_warning=4 avail_spare=100 spare_thresh=10")
      expect(verdict("nvme0n1", real.merge("nvme-smart" => "smart-log-low-spare")).ok).to be false
      expect(verdict("nvme0n1", real.merge("nvme-smart" => nil))).to eq described_class::Verdict.new(false, "no nvme smart-log output")
    end
  end

  describe ".clock_ok?" do
    it "accepts tsc anywhere in the list on x86" do
      expect(described_class.clock_ok?(probe(clocksource: "bare-metal-tsc"), "x64")).to be true
      expect(described_class.clock_ok?(probe(clocksource: "kvm-guest"), "x64")).to be true
    end

    it "accepts a paravirtual clocksource only on a virtual host" do
      expect(described_class.clock_ok?(probe(clocksource: "kvm-guest-no-tsc", virt: "kvm"), "x64")).to be true
      expect(described_class.clock_ok?(probe(clocksource: "hyperv-guest", virt: "microsoft"), "x64")).to be true
      expect(described_class.clock_ok?(probe(clocksource: "kvm-guest-no-tsc", virt: "none"), "x64")).to be false
      expect(described_class.clock_ok?(probe(clocksource: "kvm-guest-no-tsc", virt: ""), "x64")).to be false
    end

    it "fails an x86 host with neither" do
      expect(described_class.clock_ok?(probe(clocksource: "hpet-only", virt: "kvm"), "x64")).to be false
    end

    it "needs arch_sys_counter on arm64" do
      expect(described_class.clock_ok?(probe(clocksource: "arm64"), "arm64")).to be true
      expect(described_class.clock_ok?(probe(clocksource: "bare-metal-tsc"), "arm64")).to be false
    end
  end
end
