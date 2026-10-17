# frozen_string_literal: true

# Downloads a location's PVM guest kernel pin onto one pvm host
# (rhizome/host/lib/pvm_guest_kernel.rb, docs/byoh/NO_KVM.md section 6.7)
# and records the result in byoh_pvm_guest_kernel: the host checks the
# kernel against its sha256 and reads its config for the console PVM VMs
# get. HostNexus buds it at download_boot_images and holds the host short
# of accepting until a guest kernel is ready; bin/byoh-location set starts
# it on the location's pvm hosts past prep when the pin changes, which
# never blocks a host that already accepts VMs.
#
# The frame's pin is the location pin's guest side (ByohPvmPolicy::
# GUEST_KEYS). A refused pin (a wrong sha256, a config without what PVM
# VMs need) pages ByohPvmGuestKernel and pops "refused". A download that
# fails otherwise (DNS, a refused connection, a stall, an HTTP error) may
# pass when tried again, so it is never refused: it is tried again every
# 15 seconds, and after MAX_RESTARTS failures every RETRY_NAP seconds
# with a ByohPvmGuestKernelFailing page open, until it succeeds or the
# location pins another kernel ("superseded"). Once the location's
# current pin is ready the refusal page resolves, the host strand's wait
# is woken (so it pages the VMs still on an older kernel), and the host
# drops the kernels that neither the location nor any of its VMs use.
class Prog::DownloadPvmGuestKernel < Prog::Base
  subject_is :sshable, :vm_host
  frame_reader :pin
  frame_accessor :restarted

  MAX_RESTARTS = 10
  RETRY_NAP = 5 * 60

  # The guest side of the location's pin, as the frame takes it, or nil.
  def self.location_pin(vm_host)
    ByohPvmPolicy.pins(ByohVirtTiers.policy(vm_host.location))&.slice(*ByohPvmPolicy::GUEST_KEYS)
  end

  def sha256 = pin.dig("guest_kernel", "sha256")

  def unit_name = "download_pvm_guest_#{sha256}"

  def kernel = ByohPvmGuestKernel[vm_host_id: vm_host.id, sha256:]

  label def start
    register_deadline(nil, 2 * 60 * 60)

    if (row = kernel)
      # A ready kernel stays ready: the host keeps the verified directory.
      row.update(state: "downloading", updated_at: Time.now) unless row.state == "ready"
    else
      ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256:, state: "downloading")
    end
    hop_download
  end

  label def download
    case sshable.d_check(unit_name)
    when "Succeeded"
      sshable.d_clean(unit_name)
      hop_record
    when "NotStarted"
      sshable.d_run(unit_name, "sudo", "host/bin/download-pvm-guest-kernel", "download", stdin: JSON.generate(pin))
    when "Failed"
      shown = show
      if shown["state"] == "refused"
        sshable.d_clean(unit_name)
        refuse(shown["error"])
      end

      logs = sshable.d_logs(unit_name, lines: 5).strip
      sshable.d_clean(unit_name)
      supersede unless pinned_sha == sha256

      restarted = (self.restarted || 0) + 1
      self.restarted = restarted
      if restarted > MAX_RESTARTS
        page_failing(restarted, logs)
        nap RETRY_NAP
      end
    end

    nap 15
  end

  label def record
    shown = show
    fail "the PVM guest kernel #{sha256} is #{shown["state"]} on the host after its download succeeded" unless shown["state"] == "ready"

    meta = shown["meta"]
    kernel.update(state: "ready", release: meta["release"], console: meta["console"], config_checked: meta["config_checked"], updated_at: Time.now)
    if pinned_sha == sha256
      Page.from_tag_parts("ByohPvmGuestKernel", vm_host.ubid)&.incr_resolve
      # HostNexus#wait naps 6 hours; woken now, it pages the VMs that
      # still boot an older guest kernel (ByohPvmGuestKernelStale) at
      # once rather than hours after the rollout.
      Strand.where(id: vm_host.id, label: "wait").update(schedule: Sequel::CURRENT_TIMESTAMP)
    end
    resolve_failing
    collect_garbage
    pop "ready"
  end

  # The sha of the location's current guest kernel pin, or nil.
  def pinned_sha = self.class.location_pin(vm_host)&.dig("guest_kernel", "sha256")

  def show
    sshable.cmd_json("sudo host/bin/download-pvm-guest-kernel show", stdin: JSON.generate("sha256" => sha256))
  end

  # The shas the host keeps: this one, the location's current pin, the
  # downloads still running and the kernels its VMs boot. The host also
  # keeps whatever its VMs' prep.json and units name.
  def keep
    vm_shas = ByohVmGuestKernel.where(vm_id: vm_host.vms_dataset.select(:id)).select_map(:sha256)
    downloading = ByohPvmGuestKernel.where(vm_host_id: vm_host.id, state: "downloading").select_map(:sha256)
    [sha256, pinned_sha, *downloading, *vm_shas].compact.uniq.sort
  end

  def collect_garbage
    result = sshable.cmd_json("sudo host/bin/download-pvm-guest-kernel gc", stdin: JSON.generate("keep" => keep))
    if result["skipped"]
      Clog.emit("PVM guest kernel gc skipped", {pvm_guest_kernel_gc_skipped: {vm_host_ubid: vm_host.ubid, reason: result["skipped"]}})
    else
      ByohPvmGuestKernel.where(vm_host_id: vm_host.id, sha256: result["removed"]).destroy
    end
  end

  def failing_tag = ["ByohPvmGuestKernelFailing", vm_host.ubid, sha256]

  def resolve_failing = Page.from_tag_parts(*failing_tag)&.incr_resolve

  def page_failing(failures, logs)
    location = vm_host.location
    Prog::PageNexus.assemble("#{vm_host.ubid} cannot download the PVM guest kernel #{sha256} (#{failures} failures)",
      failing_tag, vm_host.ubid, resource_id: vm_host.id,
      extra_data: {
        sha256:, url: pin.dig("guest_kernel", "url"), failures:, last_log_lines: logs,
        fix: "The download failed for a reason that may pass (DNS, a refused connection, a stall, an HTTP error), not because the pin is wrong. " \
          "It is tried again every #{RETRY_NAP / 60} minutes and this page resolves once it succeeds; a host in bring-up goes on by itself then. " \
          "Check that the host reaches the URL over https. To use another kernel, pin it: bin/byoh-location set --location #{location.name} " \
          "--pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX (docs/byoh/NO_KVM.md section 6.7), which ends this download.",
      })
  end

  # The location pins another kernel now: this download is not needed. A
  # kernel the host already holds stays recorded, for its VMs.
  def supersede
    kernel.destroy unless kernel.state == "ready"
    resolve_failing
    pop "superseded"
  end

  def refuse(error)
    kernel.update(state: "refused", updated_at: Time.now)
    resolve_failing
    location = vm_host.location
    Prog::PageNexus.assemble("#{vm_host.ubid} refused the PVM guest kernel #{sha256}: #{error}",
      ["ByohPvmGuestKernel", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id,
      extra_data: {
        sha256:, url: pin.dig("guest_kernel", "url"), error:,
        fix: "Pin a guest kernel that downloads and has what PVM VMs need: bin/byoh-location set --location #{location.name} " \
          "--pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX (docs/byoh/NO_KVM.md section 6.7). " \
          "A host in bring-up goes on once one is ready; VMs keep the kernel they boot.",
      })
    pop "refused"
  end
end
