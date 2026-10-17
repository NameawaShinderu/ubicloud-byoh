# frozen_string_literal: true

# Records where a host stands on the virtualization ladder
# (docs/byoh/NO_KVM.md) in vm_host.virt_probe. A host that cannot run
# today's VMs gets a page carrying the fix for its platform, so the
# operator learns why PrepHost refuses it; the page resolves once a
# later probe finds KVM. HostNexus runs it at prep on BYOH hosts, and
# bin/byoh-virt refresh runs it again after the operator fixed the host.
#
# It fails open: whatever goes wrong (no ruby, an SSH error, output it
# cannot read, a probe crash) is recorded as {"error" => ...} with one
# page, and the strand pops, so a broken probe never holds up prep. The
# probe only explains; PrepHost and KvmCheck still decide.
#
# The verdict is compared with the tier the host was registered on
# (vm_host.virt_tier, ByohVirtTiers.accepts_probe?): a KVM host must run
# today's VMs, a lower-tier host must have its tier's prerequisites. The
# page is raised on disagreement and resolved on agreement. HostNexus
# holds a lower-tier host at verify_virt_tier until a probe agrees.
#
# On a lower-tier host the probe also runs once a day from HostNexus#wait
# (stale?). On a tier whose guests rely on the host kernel (KERNEL_TIERS)
# it records since when a reboot is pending (/var/run/reboot-required).
# Containers share the host kernel, so one that waits REBOOT_GRACE pages
# ByohKernelReboot: every tenant shares that unpatched kernel, and the page
# resolves once the flag clears. A pvm host runs a held PVM kernel that no
# apt upgrade replaces, so instead a host whose control plane installed
# PVM kernel is not the one it runs, or not the location's host-deb pin,
# pages ByohPvmHostKernel.
#
# A pvm host whose PVM kernel the control plane installs probes as its
# stock kernel until that kernel first boots, which agrees with its tier
# (ByohVirtTiers.accepts_probe? with its byoh_pvm_host state).
class Prog::LearnVirt < Prog::Base
  subject_is :sshable, :vm_host

  KERNEL_TIERS = %w[container pvm].freeze

  REBOOT_GRACE = 7 * 24 * 60 * 60

  PROBE_INTERVAL = 24 * 60 * 60

  # Whether a lower-tier host's last probe is older than PROBE_INTERVAL.
  def self.stale?(vm_host)
    probed_at = vm_host.virt_probe&.[]("probed_at")
    probed_at.nil? || Time.now - Time.parse(probed_at) >= PROBE_INTERVAL
  end

  def self.assemble(vm_host_id)
    Strand.create(prog: "LearnVirt", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    verdict = begin
      ByohVirtLadder.parse(sshable.cmd("sudo host/bin/virt-probe --json"))
    rescue => e
      error = ByohVirtLadder.sanitize("#{e.class}: #{e.message}")
      vm_host.update(virt_probe: Sequel.pg_jsonb({"error" => error, **probed_at}))
      page("the virtualization probe failed: #{error}", {error:, fix: "Check that rhizome is installed (vm_host.install_rhizome) and that ruby runs on the host, then bin/byoh-virt refresh --host #{vm_host.ubid}."})
      pop "virt probe failed"
    end

    tier = vm_host.virt_tier
    record = self.class.record(vm_host, verdict)
    if tier == "pvm"
      check_pvm_host_kernel(verdict)
    elsif KERNEL_TIERS.include?(tier)
      check_kernel_reboot(record["reboot_required_since"], verdict)
    end
    vm_host.update(virt_probe: Sequel.pg_jsonb(record))
    pvm_install = (tier == "pvm") ? ByohPvmHost[vm_host.id]&.state : nil
    if ByohVirtTiers.accepts_probe?(tier, verdict, pvm_install:)
      Page.from_tag_parts("ByohVirtTier", vm_host.ubid)&.incr_resolve
    elsif ByohVirtTiers.lower?(tier)
      fix = if verdict.standard_vms?
        "The host runs KVM (L1) now; destroy it and register it again as kvm, which is far faster than #{tier}."
      else
        "Prepare the host for #{tier} (#{ByohVirtLadder::FALLBACK_PACKAGES.fetch(tier)}), then bin/byoh-virt refresh --host #{vm_host.ubid}."
      end
      page("is registered as #{tier} but the probe disagrees: #{verdict.summary}", {tier: verdict.tier, rung: verdict.rung, virt_tier: tier, fix:})
    else
      page("cannot run VMs: #{verdict.summary}", {tier: verdict.tier, rung: verdict.rung, fix: verdict.fix})
    end

    pop "virt tier #{verdict.tier}"
  end

  # What vm_host.virt_probe records of verdict: a lower-tier host also
  # when it was probed (stale?), and on a KERNEL_TIERS host when it was
  # first seen waiting for a reboot, kept across probes. A KVM host's
  # record stays as it was. HostNexus#verify_pvm_boot records its probe
  # the same way.
  def self.record(vm_host, verdict)
    record = verdict.record
    return record unless ByohVirtTiers.lower?(vm_host.virt_tier)

    record = record.merge("probed_at" => Time.now.utc.iso8601)
    if KERNEL_TIERS.include?(vm_host.virt_tier)
      record["reboot_required_since"] = if verdict.report.dig("facts", "reboot_required")
        vm_host.virt_probe&.[]("reboot_required_since") || Time.now.utc.iso8601
      end
    end
    record
  end

  # What a failed probe records of when it ran.
  def probed_at
    ByohVirtTiers.lower?(vm_host.virt_tier) ? {"probed_at" => Time.now.utc.iso8601} : {}
  end

  # A pvm host whose PVM kernel the control plane installed and
  # committed must run that kernel, built from the location's host-deb
  # pin. A new pin is not rolled out by itself (docs/byoh/NO_KVM.md
  # section 6.8): the page says so until the host is moved to it.
  def check_pvm_host_kernel(verdict)
    row = ByohPvmHost[vm_host.id]
    pin = ByohPvmPolicy.pins(ByohVirtTiers.policy(vm_host.location))&.dig("host_deb", "sha256")
    kernel = verdict.report.dig("facts", "kernel")
    problem = if row&.install && row.state == "committed"
      if kernel != row.host_kver
        "runs kernel #{kernel}, not its PVM kernel #{row.host_kver}"
      elsif pin != row.host_deb_sha256
        "runs the PVM host kernel #{row.host_kver} (host-deb sha256 #{row.host_deb_sha256}), but location #{vm_host.location.name} pins #{pin ? "sha256 #{pin}" : "no host kernel"}"
      end
    end
    tag = ["ByohPvmHostKernel", vm_host.ubid]
    unless problem
      Page.from_tag_parts(*tag)&.incr_resolve
      return
    end

    Prog::PageNexus.assemble("#{vm_host.ubid} #{problem}", tag, vm_host.ubid, resource_id: vm_host.id, severity: "warning",
      extra_data: {kernel:, pvm_kernel: row.host_kver, host_deb_sha256: row.host_deb_sha256, pinned_sha256: pin,
                   fix: "A PVM host kernel is never replaced in place. To move the host to the location's host-deb pin, delete or move its VMs, then " \
                     "bin/byoh-virt pvm upgrade --host #{vm_host.ubid} --accept-host-deb #{pin || "SHA256"}: it drains the host, installs the new build beside the running one and boots it once (UNVERIFIED on a real host). " \
                     "A host that runs another kernel booted outside the control plane; see bin/byoh-virt show --host #{vm_host.ubid}."})
  end

  def check_kernel_reboot(since, verdict)
    if since && Time.now - Time.parse(since) >= REBOOT_GRACE
      kernel = verdict.report.dig("facts", "kernel")
      Prog::PageNexus.assemble("#{vm_host.ubid} has waited for a reboot since #{since}; its #{vm_host.virt_tier} guests share kernel #{kernel}",
        ["ByohKernelReboot", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id,
        extra_data: {kernel:, since:, fix: "Drain the host (its guests stop), reboot it into the updated kernel, then bin/byoh-virt refresh --host #{vm_host.ubid}."})
    else
      Page.from_tag_parts("ByohKernelReboot", vm_host.ubid)&.incr_resolve unless since
    end
  end

  def page(summary, extra_data)
    Prog::PageNexus.assemble("#{vm_host.ubid} #{summary}", ["ByohVirtTier", vm_host.ubid], vm_host.ubid,
      resource_id: vm_host.id, extra_data:)
  end
end
