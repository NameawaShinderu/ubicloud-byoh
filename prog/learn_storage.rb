# frozen_string_literal: true

require_relative "../lib/system_parser"

class Prog::LearnStorage < Prog::Base
  subject_is :sshable, :vm_host
  frame_reader :format_storage

  def make_model_instances
    devices = SystemParser.extract_disk_info_from_df(sshable.cmd("df -B1 --output=source,target,size,avail"))
    rec = SystemParser.extract_disk_info_from_df(sshable.cmd("df -B1 --output=source,target,size,avail /var/storage")).first
    sds = [StorageDevice.new(
      vm_host_id: vm_host.id, name: "DEFAULT",
      # reserve 5G the host.
      available_storage_gib: [rec.avail_gib - 5, 0].max,
      total_storage_gib: rec.size_gib,
      unix_device_list: find_underlying_unix_device_ids(rec.unix_device),
    )]

    devices.each do |rec|
      next unless (name = rec.optional_name)

      sds << StorageDevice.new(
        vm_host_id: vm_host.id, name:,
        available_storage_gib: rec.avail_gib,
        total_storage_gib: rec.size_gib,
        unix_device_list: find_underlying_unix_device_ids(rec.unix_device),
      )
    end

    learn_byoh_device_ids(sds) if byoh?
    sds
  end

  def byoh?
    return @byoh if defined?(@byoh)

    @byoh = vm_host.byoh?
  end

  # BYOH hosts name their disks with ByohDeviceIdentity, which resolves
  # the mount point rather than the df source; see that module for why.
  def learn_byoh_device_ids(sds)
    ids = ByohDeviceIdentity.device_ids(sshable, sds.map { it.path.chomp("/") })
    sds.each { it.unix_device_list = ids.fetch(it.path.chomp("/")) }
  end

  def find_underlying_unix_device_ids(unix_device)
    return [] if byoh?

    device_names = find_underlying_unix_device_names(unix_device)
    device_names.map { |device_name| StorageDevice.convert_device_name_to_device_id(sshable, device_name) }
  end

  def find_underlying_unix_device_names(unix_device)
    return [unix_device.delete_prefix("/dev/")] unless unix_device.start_with?("/dev/md")

    SystemParser.extract_underlying_raid_devices_from_mdstat(sshable.cmd("cat /proc/mdstat"), unix_device)
  end

  label def start
    # The upsert below resets available_storage_gib to what df reports, which
    # would drop the reservations of volumes already placed on the device.
    # Check before formatting too, which would destroy those volumes.
    unless VmStorageVolume.where(storage_device_id: vm_host.storage_devices_dataset.select(:id)).empty?
      fail "Refusing to relearn storage of #{vm_host.ubid}: VM storage volumes already use its storage devices, and relearning would reset their available_storage_gib"
    end

    sshable.cmd("sudo host/bin/format-storage-disks") if format_storage

    update = {
      total_storage_gib: Sequel[:excluded][:total_storage_gib],
      available_storage_gib: Sequel[:excluded][:available_storage_gib],
    }
    # A BYOH host relearned before it has volumes also takes the new disk
    # ids, which replace ids learned by an earlier, wrong resolution.
    update[:unix_device_list] = Sequel[:excluded][:unix_device_list] if byoh?
    make_model_instances.each do |sd|
      sd.skip_auto_validations(:unique) do
        sd.insert_conflict(target: [:vm_host_id, :name], update:).save_changes
      end
    end

    pop("created StorageDevice records")
  end
end
