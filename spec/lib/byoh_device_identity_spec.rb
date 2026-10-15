# frozen_string_literal: true

RSpec.describe ByohDeviceIdentity do
  def fixture(kind, name)
    File.read(File.expand_path("../fixtures/byoh/#{kind}/#{name}.txt", __dir__)).lines.reject { it.start_with?("# fixture:") }.join
  end

  let(:sshable) { Sshable.new }

  # Mocks the three commands device_ids runs for one mount.
  def expect_host(byid:, mounts:)
    expect(sshable).to receive(:_cmd).with(described_class::BYID_LISTING).and_return(fixture("byid", byid))
    mounts.each do |mount, (findmnt, device, lsblk)|
      expect(sshable).to receive(:_cmd).with("findmnt -nP -o SOURCE,MAJ:MIN,FSTYPE --target #{mount}").and_return(fixture("findmnt", findmnt))
      expect(sshable).to receive(:_cmd).with("lsblk -nP -s -o NAME,TYPE #{device}").and_return(fixture("lsblk", lsblk)) if device
    end
  end

  describe ".device_ids" do
    it "names an EBS root disk by its volume serial link" do
      expect_host(byid: "ebs", mounts: {"/var/storage" => ["ebs-root", "/dev/block/259:1", "ebs-root"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f60718"])
    end

    it "resolves /dev/root through its device number and names a virtio disk without by-id links by its kernel name" do
      expect_host(byid: "virtio-no-byid", mounts: {"/var/storage" => ["dev-root-vda", "/dev/block/253:1", "vda1"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["vda"])
    end

    it "names a virtio disk with a serial by its virtio link" do
      expect_host(byid: "virtio-serial", mounts: {"/var/storage" => ["dev-root-vda", "/dev/block/253:1", "vda1"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["virtio-ubi-root-0001"])
    end

    it "records every disk under an LVM volume, preferring wwn over ata links" do
      expect_host(byid: "lvm", mounts: {"/var/storage" => ["lvm", "/dev/block/252:0", "lvm-two-pv"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["wwn-0x5002538e40000001", "ata-CT1000MX500SSD1_2001E0000002"])
    end

    it "names a QEMU SCSI disk without a wwn by its scsi link" do
      expect_host(byid: "scsi-qemu", mounts: {"/var/storage" => ["scsi-qemu", "/dev/block/8:1", "scsi-qemu"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"])
    end

    it "names a real NVMe disk by its eui link" do
      expect_host(byid: "nvme-eui", mounts: {"/var/storage" => ["nvme-eui", "/dev/block/259:4", "nvme-eui"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["nvme-eui.343337304e0000010025384100000001"])
    end

    it "records both members of an md mirror and resolves several mounts with one by-id listing" do
      expect_host(byid: "md-raid1", mounts: {
        "/var/storage" => ["md", "/dev/block/9:2", "md-raid1"],
        "/var/storage/devices/extra" => ["vdb-whole", "/dev/block/253:16", "vdb-whole"],
      })
      expect(described_class.device_ids(sshable, ["/var/storage", "/var/storage/devices/extra"])).to eq(
        "/var/storage" => ["nvme-eui.0025388b91000001", "nvme-eui.0025388b91000002"],
        "/var/storage/devices/extra" => ["vdb"],
      )
    end

    it "walks a btrfs source path, as its device number is anonymous" do
      expect_host(byid: "lvm", mounts: {"/var/storage" => ["btrfs", "/dev/sda2", "btrfs-sda2"]})
      expect(described_class.device_ids(sshable, ["/var/storage"])).to eq("/var/storage" => ["wwn-0x5002538e40000001"])
    end

    it "refuses a ZFS dataset with a clear error" do
      expect_host(byid: "lvm", mounts: {"/var/storage" => ["zfs", nil, nil]})
      expect { described_class.device_ids(sshable, ["/var/storage"]) }.to raise_error(described_class::Error,
        "/var/storage is on rpool/ROOT/ubuntu_x1y2z3 (zfs), not a block device; BYOH storage must be on a block device (ZFS is not supported, see PLATFORMS.md PF10)")
    end

    it "refuses a walk that finds no disk" do
      expect_host(byid: "lvm", mounts: {"/var/storage" => ["vdb-whole", "/dev/block/253:16", "empty"]})
      expect { described_class.device_ids(sshable, ["/var/storage"]) }.to raise_error(described_class::Error, "no disk found under /var/storage (/dev/block/253:16)")
    end
  end

  describe ".byid_links" do
    it "groups links by the device they point at and skips lines without a target" do
      expect(described_class.byid_links("wwn-1 ../../sda\nstray\nata-2 ../../sda\nwwn-1-part1 ../../sda1\n"))
        .to eq("sda" => ["wwn-1", "ata-2"], "sda1" => ["wwn-1-part1"])
    end
  end

  describe ".block_device" do
    it "refuses empty findmnt output" do
      expect { described_class.block_device("/var/storage", "") }.to raise_error(described_class::Error, /\A\/var\/storage is on an unknown source \(\), not a block device/)
    end
  end

  describe ".pick" do
    it "never returns an empty id" do
      expect { described_class.pick("", []) }.to raise_error(described_class::Error, "empty device name")
      expect { described_class.pick(nil, []) }.to raise_error(described_class::Error, "empty device name")
    end

    it "prefers the nvme model and serial link over the nvme-nvme form" do
      expect(described_class.pick("nvme0n1", ["nvme-nvme.1d0f-abc-00000001", "nvme-Amazon_Elastic_Block_Store_vol0"])).to eq "nvme-Amazon_Elastic_Block_Store_vol0"
      expect(described_class.pick("nvme0n1", ["nvme-nvme.1d0f-abc-00000001"])).to eq "nvme0n1"
    end
  end

  describe ".kernel_name?" do
    it "tells kernel names from by-id link names" do
      expect(%w[sda vda xvda nvme0n1 mmcblk0].map { described_class.kernel_name?(it) }).to all(be true)
      expect(%w[wwn-0x5 nvme-eui.1 virtio-x scsi-0QEMU disk/by-id].map { described_class.kernel_name?(it) }).to all(be false)
    end
  end
end
