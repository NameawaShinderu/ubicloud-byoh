# frozen_string_literal: true

require "openssl"
require_relative "../../common/lib/util"
require_relative "container_idmap"
require_relative "container_setup"
require_relative "storage_key_encryption"
require_relative "storage_path"

# The disk of a system container (ContainerSetup): the guest's root file
# system, extracted from a root tarball (BootImage) by the container's own
# root, so its files carry the container's ids and root never writes into
# a tree the guest controls.
#
# Two drivers, chosen by the volume's "encrypted" flag:
#
# - crypt-loop (encrypted): a sparse file of the volume's size, LUKS2,
#   ext4. The key is random, kept wrapped by the volume's key encryption
#   key exactly as ubiblk keeps its keys (StorageKeyEncryption), and given
#   to cryptsetup on stdin only. The mapping is opened and mounted by
#   prep and by recreate-unpersisted (after a host reboot), the only
#   commands that get the key encryption key, and stays open until the
#   disk is deleted or the host reboots: a stopped container is started
#   again by its unit alone, without the key. So the key is in the host
#   kernel from prep to delete, not only while the container runs.
#   UNVERIFIED: no lab here may use loop or device-mapper devices.
# - dir (not encrypted, only where the location acknowledged
#   "container:unencrypted-disk"): a directory limited to the volume's
#   size and to INODES_PER_GIB inodes per GiB by a project quota, so the
#   file system must be mounted with prjquota. The container cannot
#   change a file's project from inside its user namespace.
class ContainerDisk
  # The key is 512 random bits, so key stretching adds nothing.
  PBKDF_ITERATIONS = "1000"

  # The inode limit of a dir disk per GiB of its size: ext4's default of
  # one inode per 16 KiB. Without it a guest could fill the shared file
  # system's fixed inode table with empty files, which cost no blocks.
  INODES_PER_GIB = 65_536

  # Run as the container's root in the fresh root file system: masks the
  # units a container cannot run (ContainerSetup::MASKED_UNITS), keeps apt
  # from installing kernels the container never boots, and makes
  # cloud-init use the NoCloud seed only.
  TWEAK_SCRIPT = <<~'SH'
    set -eu
    cd "$1"
    shift
    mkdir -p etc/systemd/system etc/apt/preferences.d etc/cloud/cloud.cfg.d
    for unit in "$@"; do ln -sfn /dev/null "etc/systemd/system/$unit"; done
    printf '%s\n' 'Package: linux-image-* linux-modules-* linux-headers-* linux-generic* linux-virtual* linux-kvm*' 'Pin: version *' 'Pin-Priority: -1' > etc/apt/preferences.d/ubicloud-container-no-kernel
    printf '%s\n' 'datasource_list: [ NoCloud, None ]' > etc/cloud/cloud.cfg.d/90-ubicloud-container.cfg
  SH

  def initialize(vm_name, params, slot)
    @vm_name = vm_name
    @params = params
    @slot = slot
    @path = StoragePath.new(vm_name, params["storage_device"] || DEFAULT_STORAGE_DEVICE, params.fetch("disk_index"))
  end

  def encrypted? = @params.fetch("encrypted")

  def size_gib = @params.fetch("size_gib")

  def base = ContainerIdmap.base(@slot)

  def project_id = ContainerIdmap::BASE + @slot

  def storage_root = @path.storage_root

  def storage_dir = @path.storage_dir

  def rootfs = File.join(storage_dir, "rootfs")

  def disk_file = @path.disk_file

  def dek_path = @path.data_encryption_key

  def marker = File.join(storage_dir, "extracted")

  def mapper_name = "ubi-#{@vm_name}-#{@params.fetch("disk_index")}"

  def mapper_path = "/dev/mapper/#{mapper_name}"

  def usernsexec = ["lxc-usernsexec", "-m", "b:0:#{base}:#{ContainerIdmap::SIZE}", "--"]

  # Creates the disk and extracts the image into it. A prep that stopped
  # before the image was in place starts over; one that finished only
  # starts the disk.
  def prep(kek, image_path)
    return start(kek) if File.exist?(marker)

    fail "boot image #{image_path} is missing" unless File.file?(image_path)

    discard
    r "install", "-d", "-m", "0711", storage_root
    r "install", "-d", "-m", "0711", storage_dir
    encrypted? ? format_crypt(kek) : make_quota_dir
    r(*usernsexec, "tar", "-C", rootfs, "-xpJf", image_path, "--numeric-owner", "--exclude=dev/*")
    r(*usernsexec, "sh", "-c", TWEAK_SCRIPT, "sh", rootfs, *ContainerSetup::MASKED_UNITS)
    File.write(marker, "#{image_path}\n")
  end

  def start(kek)
    return unless encrypted?

    open_crypt(read_key(kek)) unless File.exist?(mapper_path)
    mount_crypt unless mounted?
  end

  def stop
    return unless encrypted?

    r "umount", rootfs if mounted?
    r "cryptsetup", "close", mapper_name if File.exist?(mapper_path)
  end

  # Removes the disk; raises unless it is gone, so the caller keeps the
  # id slot of files that may remain.
  def purge
    stop
    r "rm", "-rf", "--one-file-system", "--", storage_root
    fail "#{storage_root} still exists after removal" if File.exist?(storage_root)
  end

  def mounted?
    File.foreach("/proc/self/mounts").any? { _1.split(" ")[1] == rootfs }
  end

  private

  def discard
    stop
    r "rm", "-rf", "--one-file-system", "--", storage_dir
  end

  def format_crypt(kek)
    key = OpenSSL::Cipher.new("aes-256-xts").random_key.unpack1("H*")
    StorageKeyEncryption.new(kek).write_encrypted_dek(dek_path, {cipher: "luks2", key: key[..63], key2: key[64..]})
    r "truncate", "-s", "#{size_gib}G", disk_file
    r "cryptsetup", "luksFormat", "--batch-mode", "--type", "luks2", "--pbkdf", "pbkdf2",
      "--pbkdf-force-iterations", PBKDF_ITERATIONS, "--key-file=-", disk_file, stdin: key
    open_crypt(key)
    r "mkfs.ext4", "-q", "-E", "root_owner=#{base}:#{base}", mapper_path
    r "install", "-d", "-m", "0755", rootfs
    mount_crypt
  end

  def read_key(kek)
    dek = StorageKeyEncryption.new(kek).read_encrypted_dek(dek_path)
    dek[:key] + dek[:key2]
  end

  def open_crypt(key)
    r "cryptsetup", "open", "--type", "luks2", "--key-file=-", disk_file, mapper_name, stdin: key
  end

  # Without nodev or nosuid: LXC's /dev entries and the guest's setuid
  # programs (sudo) need neither (verified in the l3 lab on tmpfs).
  def mount_crypt
    r "mount", mapper_path, rootfs
  end

  def make_quota_dir
    options = r("findmnt", "-n", "-o", "OPTIONS", "--target", storage_dir).strip.split(",")
    unless options.include?("prjquota")
      fail "#{storage_dir} is not on a file system mounted with prjquota; unencrypted container disks need a project quota (docs/byoh/NO_KVM.md section 4.2)"
    end
    unless (bad = options & %w[nodev nosuid]).empty?
      fail "#{storage_dir} is on a file system mounted #{bad.join(",")}; a container's root file system needs device files and setuid programs"
    end

    mount_point = r("findmnt", "-n", "-o", "TARGET", "--target", storage_dir).strip
    r "install", "-d", "-o", base.to_s, "-g", base.to_s, "-m", "0755", rootfs
    r "chattr", "+P", "-p", project_id.to_s, rootfs
    r "setquota", "-P", project_id.to_s, "0", (size_gib * 1024 * 1024).to_s, "0", (size_gib * INODES_PER_GIB).to_s, mount_point
  end
end
