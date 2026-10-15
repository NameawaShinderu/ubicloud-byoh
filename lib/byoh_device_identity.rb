# frozen_string_literal: true

# Finds the disks under a mount point on a BYOH host and names each by its
# most stable /dev/disk/by-id link. Upstream (StorageDevice
# .convert_device_name_to_device_id) looks only for wwn- and nvme-eui.
# links of the df source, which is a partition, a device-mapper volume or
# /dev/root on most BYOH hosts and has neither link on EBS, virtio or
# WWN-less SCSI disks; it then stores "" or the partition name, and the
# health checks resolve a bogus device. Here the mount is resolved with
# findmnt, walked down with lsblk to every whole disk (an LVM volume over
# several PVs or an md array gives all of them), and each disk is named
# by the first link in PREFERENCE, or by its kernel name when it has none.
module ByohDeviceIdentity
  class Error < StandardError; end

  # Ordered from most to least stable. nvme-<model>_<serial> excludes the
  # nvme-nvme.<vendor>-<serial>-<model> form, which every NVMe disk also
  # has, so that EBS volumes are named by their vol- serial.
  PREFERENCE = [
    /\Awwn-/,
    /\Anvme-eui\./,
    /\Anvme-(?!eui\.|nvme\.)/,
    /\A(?:ata|scsi|virtio)-/,
  ].freeze

  # Matches a kernel disk name (sda, vda, xvda, nvme0n1, mmcblk0) and no
  # by-id link name, which always contains a "-".
  KERNEL_NAME = /\A[a-z][a-z0-9]*\z/

  BYID_LISTING = "if [ -d /dev/disk/by-id ]; then find /dev/disk/by-id -mindepth 1 -maxdepth 1 -type l -printf '%f %l\\n'; fi"

  def self.kernel_name?(id) = id.match?(KERNEL_NAME)

  # The by-id names of the disks under each mount point, keyed by mount.
  def self.device_ids(sshable, mounts)
    links = byid_links(sshable.cmd(BYID_LISTING))
    mounts.to_h do |mount|
      device = block_device(mount, sshable.cmd("findmnt -nP -o SOURCE,MAJ:MIN,FSTYPE --target :mount", mount:))
      disks = disks_from_lsblk(sshable.cmd("lsblk -nP -s -o NAME,TYPE :device", device:))
      raise Error, "no disk found under #{mount} (#{device})" if disks.empty?

      [mount, disks.map { pick(it, links.fetch(it, [])) }]
    end
  end

  # Parses the BYID_LISTING output into {kernel name => [link names]}.
  # Partition links point at partitions, so they never list under a disk.
  def self.byid_links(output)
    output.each_line.with_object({}) do |line, links|
      name, target = line.split
      next unless target

      (links[File.basename(target)] ||= []) << name
    end
  end

  # The block device findmnt reports for a mount. btrfs reports an
  # anonymous device number (major 0) and a "[/subvolume]" suffix on its
  # source, so the source path is used there; /dev/root has a real device
  # number, which /dev/block resolves.
  def self.block_device(mount, output)
    fields = pairs(output.lines.first.to_s)
    source = fields["SOURCE"].to_s
    unless source.start_with?("/dev/")
      raise Error, "#{mount} is on #{source.empty? ? "an unknown source" : source} (#{fields["FSTYPE"]}), not a block device; BYOH storage must be on a block device (ZFS is not supported, see PLATFORMS.md PF10)"
    end

    majmin = fields["MAJ:MIN"].to_s
    if majmin.match?(/\A[1-9]\d*:\d+\z/)
      "/dev/block/#{majmin}"
    else
      source.sub(/\[.*\]\z/, "")
    end
  end

  def self.disks_from_lsblk(output)
    output.each_line.filter_map {
      fields = pairs(it)
      fields["NAME"] if fields["TYPE"] == "disk"
    }.uniq
  end

  def self.pick(name, links)
    raise Error, "empty device name" if name.to_s.empty?

    sorted = links.sort
    PREFERENCE.each do |re|
      found = sorted.find { it.match?(re) }
      return found if found
    end
    name
  end

  def self.pairs(line)
    line.scan(/([A-Z:]+)="((?:[^"\\]|\\.)*)"/).to_h
  end
end
