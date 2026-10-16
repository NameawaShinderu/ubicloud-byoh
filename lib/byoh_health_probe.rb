# frozen_string_literal: true

require "json"

# The SMART and clocksource half of a BYOH host's health check, gathered
# by one SSH exec per pulse and judged here. Upstream's checks fail every
# BYOH host whose disks have no SMART (EBS, virtio, other cloud and
# hypervisor disks) and every guest whose first clocksource is kvm-clock,
# so a monitored BYOH host on such a platform would flap to unavailable.
module ByohHealthProbe
  MARKER = "==ubicloud-probe "

  # stderr is dropped because Net::SSH's exec! mixes it into the output.
  # Each tool's exit status is ignored: smartctl sets status bits for a
  # failing disk and still prints its JSON, which is what is judged.
  SCRIPT = <<~SH
    printf '%s\\n' '==ubicloud-probe virt'
    systemd-detect-virt 2>/dev/null || true
    printf '%s\\n' '==ubicloud-probe clocksource'
    cat /sys/devices/system/clocksource/clocksource0/available_clocksource 2>/dev/null || true
    for d in :shelljoin_devices; do
      if [ ! -b "/dev/$d" ]; then
        printf '%s\\n' "==ubicloud-probe missing $d"
        continue
      fi
      if [ ! -e "/sys/block/$d" ]; then
        printf '%s\\n' "==ubicloud-probe notdisk $d"
        continue
      fi
      printf '%s\\n' "==ubicloud-probe smartctl $d"
      sudo smartctl -j -i -H "/dev/$d" 2>/dev/null || true
      case $d in nvme*)
        printf '%s\\n' "==ubicloud-probe nvme-id $d"
        sudo nvme id-ctrl -o json "/dev/$d" 2>/dev/null || true
        printf '%s\\n' "==ubicloud-probe nvme-smart $d"
        sudo nvme smart-log -o json "/dev/$d" 2>/dev/null || true
      esac
    done
  SH

  # Models of disks that a hypervisor or cloud emulates. Their SMART data,
  # if any, describes nothing physical, so they are not checked. Only the
  # EBS model was seen on a real host; the others are the models those
  # platforms document and are UNVERIFIED.
  VIRTUAL_MODEL = /\A(?:Amazon Elastic Block Store|QEMU|VBOX|VMware|Virtual disk|Msft Virtual Disk|MSFT NVMe Accelerator|nvme_card-pd|Google|PersistentDisk)|virtio/i

  Verdict = Data.define(:ok, :reason)

  def self.run(ssh_session, device_names)
    parse(ssh_session.exec!(SCRIPT, shelljoin_devices: device_names).to_s)
  end

  # Splits the probe output into {"virt" => text, "clocksource" => text,
  # "devices" => {name => {"smartctl" => text, ...}}}.
  def self.parse(output)
    result = {"virt" => "", "clocksource" => "", "devices" => {}}
    section = nil
    output.each_line do |line|
      if line.start_with?(MARKER)
        kind, device = line.delete_prefix(MARKER).split
        section = if device
          (result["devices"][device] ||= {})[kind] = +""
        else
          result[kind] = +""
        end
      elsif section
        section << line
      end
    end
    result
  end

  def self.virtual_host?(probe)
    virt = probe["virt"].strip
    !virt.empty? && virt != "none"
  end

  # Paravirtual clocksources a guest may list instead of a stable tsc.
  # The Hyper-V one is UNVERIFIED (no BYOH host has run on Hyper-V).
  VIRTUAL_CLOCKSOURCES = %w[kvm-clock hyperv_clocksource_tsc_page].freeze

  # x86 hosts need tsc anywhere among the available clocksources (upstream
  # wants it first), or a paravirtual clocksource on a virtual host; arm64
  # hosts need arch_sys_counter.
  def self.clock_ok?(probe, arch)
    available = probe["clocksource"].split
    if arch == "arm64"
      available.include?("arch_sys_counter")
    else
      available.include?("tsc") || (available.intersect?(VIRTUAL_CLOCKSOURCES) && virtual_host?(probe))
    end
  end

  def self.device_verdict(probe, device)
    sections = probe["devices"].fetch(device, {})
    # smartctl prints no SMART support for a device that does not exist,
    # which would pass a vanished disk as a SMART-less one.
    return Verdict.new(false, "/dev/#{device} is not a block device") if sections.key?("missing")
    # A partition passes smartctl as a SMART-less disk, which would hide
    # the disk under it. Hosts registered before ByohDeviceIdentity store
    # the df source, often a partition.
    return Verdict.new(false, "/dev/#{device} is not a whole disk; run bin/byoh-host relearn-device-ids") if sections.key?("notdisk")

    smartctl = json(sections["smartctl"])
    nvme_id = json(sections["nvme-id"])
    model = (nvme_id && nvme_id["mn"]) || smartctl_model(smartctl)
    return Verdict.new(true, "virtual disk #{model.strip}") if model&.match?(VIRTUAL_MODEL)

    if device.start_with?("nvme")
      nvme_verdict(json(sections["nvme-smart"]))
    else
      smartctl_verdict(smartctl)
    end
  end

  def self.nvme_verdict(smart)
    return Verdict.new(false, "no nvme smart-log output") unless smart
    return Verdict.new(false, "nvme smart-log failed: #{smart["error"]}") unless smart.key?("critical_warning")

    cw = Integer(smart["critical_warning"])
    avail_spare = Integer(smart["avail_spare"])
    spare_thresh = Integer(smart["spare_thresh"])
    if cw == 0 && avail_spare > spare_thresh
      Verdict.new(true, "nvme smart-log passed")
    else
      Verdict.new(false, "nvme smart-log critical_warning=#{cw} avail_spare=#{avail_spare} spare_thresh=#{spare_thresh}")
    end
  end

  # smartctl exit status bit 1: the device could not be opened. A virtio
  # disk sets only bit 0 ("Unable to detect device type").
  SMARTCTL_OPEN_FAILED = 2

  def self.smartctl_verdict(smartctl)
    return Verdict.new(false, "no smartctl output") unless smartctl

    if smartctl.dig("smartctl", "exit_status").to_i.anybits?(SMARTCTL_OPEN_FAILED)
      message = Array(smartctl.dig("smartctl", "messages")).map { it["string"] }.join("; ")
      return Verdict.new(false, "smartctl could not open the device: #{message}")
    end

    case smartctl.dig("smart_status", "passed")
    when true
      Verdict.new(true, "smartctl passed")
    when false
      Verdict.new(false, "smartctl reports a failing disk")
    else
      if smartctl.dig("smart_support", "available") == true
        Verdict.new(false, "smartctl gave no health status for a SMART-capable disk")
      else
        Verdict.new(true, "SMART not supported")
      end
    end
  end

  def self.smartctl_model(smartctl)
    return unless smartctl

    smartctl["model_name"] || smartctl["scsi_model_name"] || [smartctl["scsi_vendor"], smartctl["scsi_product"]].compact.join(" ")
  end

  # The parsed object, or nil when the tool printed nothing, or anything
  # but a JSON object.
  def self.json(text)
    return if text.nil? || text.strip.empty?

    value = JSON.parse(text)
    value if value.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end
end
