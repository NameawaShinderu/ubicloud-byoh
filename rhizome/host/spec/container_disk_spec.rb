# frozen_string_literal: true

require_relative "../lib/container_disk"

RSpec.describe ContainerDisk do
  let(:kek) { {"algorithm" => "aes-256-gcm", "key" => "k", "init_vector" => "i", "auth_data" => "a"} }
  let(:params) { {"disk_index" => 0, "device_id" => "vmcont01_0", "size_gib" => 20, "encrypted" => true} }
  let(:disk) { described_class.new("vmcont01", params, 2) }
  let(:image) { "/var/storage/images/ubuntu-noble-container-20260926.tar.xz" }
  let(:base) { 1_000_131_072 }
  let(:rootfs) { "/var/storage/vmcont01/0/rootfs" }
  let(:userns) { ["lxc-usernsexec", "-m", "b:0:#{base}:65536", "--"] }
  let(:sek) { instance_double(StorageKeyEncryption) }

  before do
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:file?).and_call_original
  end

  def mounts(*lines)
    allow(File).to receive(:foreach).with("/proc/self/mounts").and_return(lines.each)
  end

  def expect_extract
    expect(disk).to receive(:r).with(*userns, "tar", "-C", rootfs, "-xpJf", image, "--numeric-owner", "--exclude=dev/*").ordered
    expect(disk).to receive(:r).with(*userns, "sh", "-c", ContainerDisk::TWEAK_SCRIPT, "sh", rootfs, "sys-kernel-config.mount", "sys-kernel-debug.mount", "systemd-remount-fs.service").ordered
    expect(File).to receive(:write).with("/var/storage/vmcont01/0/extracted", "#{image}\n").ordered
  end

  it "names its paths after the volume" do
    expect(disk.rootfs).to eq rootfs
    expect(disk.mapper_path).to eq "/dev/mapper/ubi-vmcont01-0"
    expect(disk.project_id).to eq 1_000_000_002
    expect(described_class.new("vmcont01", params.merge("storage_device" => "nvme1"), 2).storage_root).to eq "/var/storage/devices/nvme1/vmcont01"
  end

  describe "#prep" do
    before do
      allow(File).to receive(:exist?).with("/var/storage/vmcont01/0/extracted").and_return(false)
      allow(File).to receive(:file?).with(image).and_return(true)
    end

    it "formats an encrypted disk with a wrapped random key given on stdin, then extracts the image as the container's root" do
      mounts("proc /proc proc rw 0 0\n")
      allow(File).to receive(:exist?).with("/dev/mapper/ubi-vmcont01-0").and_return(false)
      expect(disk).to receive(:r).with("rm", "-rf", "--one-file-system", "--", "/var/storage/vmcont01/0").ordered
      expect(disk).to receive(:r).with("install", "-d", "-m", "0711", "/var/storage/vmcont01").ordered
      expect(disk).to receive(:r).with("install", "-d", "-m", "0711", "/var/storage/vmcont01/0").ordered
      expect(StorageKeyEncryption).to receive(:new).with(kek).and_return(sek)
      key = nil
      expect(sek).to receive(:write_encrypted_dek) do |path, dek|
        expect(path).to eq "/var/storage/vmcont01/0/data_encryption_key.json"
        expect(dek[:cipher]).to eq "luks2"
        key = dek[:key] + dek[:key2]
        expect(key).to match(/\A\h{128}\z/)
      end
      expect(disk).to receive(:r).with("truncate", "-s", "20G", "/var/storage/vmcont01/0/disk.raw").ordered
      the_key = satisfy { _1 == key }
      expect(disk).to receive(:r).with("cryptsetup", "luksFormat", "--batch-mode", "--type", "luks2", "--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000",
        "--key-file=-", "/var/storage/vmcont01/0/disk.raw", stdin: the_key).ordered
      expect(disk).to receive(:r).with("cryptsetup", "open", "--type", "luks2", "--key-file=-", "/var/storage/vmcont01/0/disk.raw", "ubi-vmcont01-0", stdin: the_key).ordered
      expect(disk).to receive(:r).with("mkfs.ext4", "-q", "-E", "root_owner=#{base}:#{base}", "/dev/mapper/ubi-vmcont01-0").ordered
      expect(disk).to receive(:r).with("install", "-d", "-m", "0755", rootfs).ordered
      expect(disk).to receive(:r).with("mount", "/dev/mapper/ubi-vmcont01-0", rootfs).ordered
      expect_extract
      disk.prep(kek, image)
    end

    it "makes an unencrypted disk a directory under a project quota" do
      params["encrypted"] = false
      expect(disk).to receive(:r).with("rm", "-rf", "--one-file-system", "--", "/var/storage/vmcont01/0").ordered
      expect(disk).to receive(:r).with("install", "-d", "-m", "0711", "/var/storage/vmcont01").ordered
      expect(disk).to receive(:r).with("install", "-d", "-m", "0711", "/var/storage/vmcont01/0").ordered
      expect(disk).to receive(:r).with("findmnt", "-n", "-o", "OPTIONS", "--target", "/var/storage/vmcont01/0").and_return("rw,relatime,prjquota\n").ordered
      expect(disk).to receive(:r).with("findmnt", "-n", "-o", "TARGET", "--target", "/var/storage/vmcont01/0").and_return("/var/storage\n").ordered
      expect(disk).to receive(:r).with("install", "-d", "-o", base.to_s, "-g", base.to_s, "-m", "0755", rootfs).ordered
      expect(disk).to receive(:r).with("chattr", "+P", "-p", "1000000002", rootfs).ordered
      expect(disk).to receive(:r).with("setquota", "-P", "1000000002", "0", "20971520", "0", "0", "/var/storage").ordered
      expect_extract
      disk.prep(kek, image)
    end

    it "refuses an unencrypted disk on a file system without project quotas" do
      params["encrypted"] = false
      expect(disk).to receive(:r).with("rm", any_args)
      expect(disk).to receive(:r).with("install", any_args).twice
      expect(disk).to receive(:r).with("findmnt", "-n", "-o", "OPTIONS", "--target", "/var/storage/vmcont01/0").and_return("rw,relatime\n")
      expect { disk.prep(kek, image) }.to raise_error(RuntimeError, /is not on a file system mounted with prjquota/)
    end

    it "refuses an unencrypted disk on a file system without device files or setuid" do
      params["encrypted"] = false
      expect(disk).to receive(:r).with("rm", any_args)
      expect(disk).to receive(:r).with("install", any_args).twice
      expect(disk).to receive(:r).with("findmnt", "-n", "-o", "OPTIONS", "--target", "/var/storage/vmcont01/0").and_return("rw,nosuid,nodev,prjquota\n")
      expect { disk.prep(kek, image) }.to raise_error(RuntimeError, /is on a file system mounted nosuid,nodev;/)
    end

    it "refuses a missing image before changing anything" do
      allow(File).to receive(:file?).with(image).and_return(false)
      expect(disk).not_to receive(:r)
      expect { disk.prep(kek, image) }.to raise_error(RuntimeError, "boot image #{image} is missing")
    end

    it "only starts a disk whose image is in place" do
      allow(File).to receive(:exist?).with("/var/storage/vmcont01/0/extracted").and_return(true)
      expect(disk).to receive(:start).with(kek)
      disk.prep(kek, image)
    end
  end

  describe "#start" do
    it "opens and mounts an encrypted disk with the unwrapped key" do
      allow(File).to receive(:exist?).with("/dev/mapper/ubi-vmcont01-0").and_return(false)
      mounts
      expect(StorageKeyEncryption).to receive(:new).with(kek).and_return(sek)
      expect(sek).to receive(:read_encrypted_dek).with("/var/storage/vmcont01/0/data_encryption_key.json").and_return({key: "a" * 64, key2: "b" * 64})
      expect(disk).to receive(:r).with("cryptsetup", "open", "--type", "luks2", "--key-file=-", "/var/storage/vmcont01/0/disk.raw", "ubi-vmcont01-0", stdin: "a" * 64 + "b" * 64)
      expect(disk).to receive(:r).with("mount", "/dev/mapper/ubi-vmcont01-0", rootfs)
      disk.start(kek)
    end

    it "leaves an open and mounted disk alone" do
      allow(File).to receive(:exist?).with("/dev/mapper/ubi-vmcont01-0").and_return(true)
      mounts("/dev/mapper/ubi-vmcont01-0 #{rootfs} ext4 rw 0 0\n")
      expect(disk).not_to receive(:r)
      disk.start(kek)
    end

    it "has nothing to start for a directory" do
      params["encrypted"] = false
      expect(disk).not_to receive(:r)
      disk.start(kek)
      disk.stop
    end
  end

  describe "#purge" do
    it "unmounts, closes and removes the disk" do
      mounts("/dev/mapper/ubi-vmcont01-0 #{rootfs} ext4 rw 0 0\n")
      allow(File).to receive(:exist?).with("/dev/mapper/ubi-vmcont01-0").and_return(true)
      expect(disk).to receive(:r).with("umount", rootfs).ordered
      expect(disk).to receive(:r).with("cryptsetup", "close", "ubi-vmcont01-0").ordered
      expect(disk).to receive(:r).with("rm", "-rf", "--one-file-system", "--", "/var/storage/vmcont01").ordered
      allow(File).to receive(:exist?).with("/var/storage/vmcont01").and_return(false)
      disk.purge
    end

    it "raises when files remain, such as under a mount it could not undo" do
      mounts
      allow(File).to receive(:exist?).with("/dev/mapper/ubi-vmcont01-0").and_return(false)
      expect(disk).to receive(:r).with("rm", "-rf", "--one-file-system", "--", "/var/storage/vmcont01")
      allow(File).to receive(:exist?).with("/var/storage/vmcont01").and_return(true)
      expect { disk.purge }.to raise_error(RuntimeError, "/var/storage/vmcont01 still exists after removal")
    end
  end
end
