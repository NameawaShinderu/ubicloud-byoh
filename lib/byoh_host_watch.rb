# frozen_string_literal: true

# Follows a BYOH host's bring-up (Prog::Vm::HostNexus) from the control
# plane's database until the host accepts VMs: `byoh-host add` after it
# registers a host, and `byoh-host watch`. It prints label changes of
# the host strand and its children, retries, and the pages raised for
# them, and gives up early when nothing can be happening:
#
# - respirate is not running when the host strand has neither left
#   start nor taken a lease within RESPIRATE_GRACE seconds;
# - each phase of the bring-up has a limit (PHASES), the deadlines that
#   HostNexus pages at, counted from when the watch first saw the phase;
# - timeout, when given, caps the whole watch;
# - a host that is not accepting at a HostNexus label outside the
#   bring-up (PHASES), such as wait on a host an operator set to
#   draining, will not turn accepting by itself, so the watch stops.
#
# Stopping the watch never stops the bring-up: the strand keeps running
# and reboots the host, and the watch can be resumed.
class ByohHostWatch
  # Bring-up phases by the host strand's HostNexus label, with their
  # limits in seconds: bootstrap_rhizome's deadline to reach
  # download_boot_images, download_boot_images' deadline to reach
  # prep_reboot, and prep_reboot's deadline to reach wait, which
  # prep_hardware_reset replaces with its own when reboot fails over to
  # a hardware reset. wait_download_boot_images reaps into patch (an apt
  # full-upgrade) on the way to prep_reboot, under the download's
  # deadline. A host of a lower virtualization tier passes
  # verify_virt_tier in place of setup_hugepages, and verify_tier_capacity
  # in place of verify_hugepages (docs/byoh/NO_KVM.md); a pvm host whose
  # guest kernel download was refused waits at pvm_guest_kernel_refused
  # under the download's deadline. A pvm host whose PVM kernel the control
  # plane installs does so after patch, under the install's own deadline
  # (pvm install, where a failed install waits for bin/byoh-virt pvm
  # retry), and checks its PVM kernel boot at verify_pvm_boot (where a
  # failed boot waits at pvm_boot_failed). Moving such a host to a new
  # host-deb pin (pvm_upgrade, bin/byoh-virt pvm upgrade) runs under the
  # same limit, then reboots like a bring-up until the host accepts VMs
  # again. Uninstalling the PVM kernel (pvm_uninstall) ends a bring-up.
  PHASES = {
    "bootstrap" => [600, %w[start install_host_os setup_ssh_keys bootstrap_rhizome check_ip_reachability prep wait_prep setup_hugepages verify_virt_tier setup_storage_backend]],
    "boot image download" => [4 * 60 * 60, %w[download_boot_images wait_download_boot_images pvm_guest_kernel_refused patch]],
    "pvm install" => [45 * 60, %w[install_pvm_host_kernel pvm_install_failed pvm_retry pvm_upgrade]],
    "reboot" => [15 * 60, %w[prep_reboot reboot verify_spdk verify_hugepages verify_pvm_boot pvm_boot_failed verify_tier_capacity start_slices start_vms]],
    "hardware reset" => [20 * 60, %w[prep_hardware_reset hardware_reset]],
  }.freeze
  PHASE_OF = PHASES.flat_map { |phase, (_, labels)| labels.map { [it, phase] } }.to_h.freeze

  RESPIRATE_GRACE = 120
  POLL = 5

  HOST_PROG = "Vm::HostNexus"

  # How the watch ended, and the exit status byoh-host gives it.
  EXIT = {accepting: 0, gone: 1, timeout: 3, respirate: 3, not_bringup: 3, interrupted: 130}.freeze

  # clock returns monotonic seconds, sleeper waits that many; specs pass
  # stand-ins.
  def initialize(host, out:, timeout: nil, poll: POLL, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: Kernel.method(:sleep))
    @host_id = host.id
    @ubid = host.ubid
    @out = out
    @timeout = timeout
    @poll = poll
    @clock = clock
    @sleeper = sleeper
  end

  # The command that resumes this watch.
  def resume_line = "bin/byoh-host watch #{@ubid} (packaged: ubicloud-admin host watch #{@ubid})"

  # Watches until the host accepts VMs or the watch gives up; returns
  # one of the EXIT keys.
  def run
    @start = @clock.call
    @seen = {}
    @pages = {}
    @phase = nil
    @progress = false
    loop do
      if (result = poll)
        return result
      end
      @sleeper.call(@poll)
    end
  rescue Interrupt
    stop("interrupted")
    :interrupted
  end

  # The HostNexus label of the strand: its own when HostNexus runs, else
  # the label HostNexus pushed the running prog from.
  def self.host_label(strand)
    return strand.label if strand.prog == HOST_PROG

    strand.stack.each do |frame|
      link = frame.is_a?(Hash) && frame["link"]
      return link[1] if link.is_a?(Array) && link[0] == HOST_PROG
    end
    nil
  end

  private

  def elapsed = @clock.call - @start

  def poll
    strand = Strand[@host_id]
    host = VmHost[@host_id]
    unless strand && host
      @out.puts "! host #{@ubid} no longer exists; it was destroyed"
      return :gone
    end

    report(strand, "host")
    children = Strand.where(parent_id: @host_id).order(:id).all
    children.each { report(it, "child") }
    report_pages(strand, children)

    if host.allocation_state == "accepting"
      @out.puts "#{stamp} host #{@ubid} is accepting VMs"
      return :accepting
    end

    unless PHASE_OF.key?(self.class.host_label(strand))
      @out.puts "! host #{@ubid} is #{host.allocation_state} at #{strand.prog}.#{strand.label}, which is not part of a bring-up, so it will not accept VMs by itself"
      @out.puts "  An operator set it to #{host.allocation_state}, or it is being rebooted or destroyed; see its page in the admin UI"
      return :not_bringup
    end

    @progress ||= strand.label != "start" || strand.prog != HOST_PROG || strand.lease > Time.now
    if !@progress && elapsed >= RESPIRATE_GRACE
      @out.puts "! host strand #{@ubid} has not started in #{RESPIRATE_GRACE} s: respirate is not running"
      @out.puts "  start it (systemctl start ubicloud.target, or bin/respirate on a development layout)"
      stop
      return :respirate
    end

    if (limit_hit = phase_limit(strand))
      @out.puts "! #{limit_hit}"
      stop
      return :timeout
    end

    if @timeout && elapsed >= @timeout
      @out.puts "! host #{@ubid} is not accepting VMs after #{@timeout} s (--timeout)"
      stop
      return :timeout
    end

    nil
  end

  # The limit message once the strand has spent longer in its phase than
  # the phase allows.
  def phase_limit(strand)
    phase = PHASE_OF[self.class.host_label(strand)]
    if phase != @phase
      @phase = phase
      @phase_start = elapsed
    end

    limit = PHASES[phase].first
    spent = elapsed - @phase_start
    "host #{@ubid} has been in its #{phase} phase (at #{strand.prog}.#{strand.label}) for #{spent.round} s, over its #{limit} s limit; see the pages and the respirate log" if spent > limit
  end

  def report(strand, kind)
    state = [strand.prog, strand.label, strand.try, strand.exitval.nil?]
    before = @seen[strand.id]
    return if before == state

    @seen[strand.id] = state
    name = (kind == "host") ? "host" : "  #{strand.ubid}"
    if !strand.exitval.nil?
      @out.puts "#{stamp} #{name} #{strand.prog} exited"
    elsif before && before[0..1] == state[0..1]
      @out.puts "#{stamp} #{name} #{strand.prog}.#{strand.label} retry #{strand.try}"
    else
      @out.puts "#{stamp} #{name} #{strand.prog}.#{strand.label}#{" (try #{strand.try})" if strand.try.positive?}"
    end
  end

  def report_pages(strand, children)
    ids = [strand.id, *children.map(&:id)]
    ubids = [strand.ubid, *children.map(&:ubid)]
    Page.where(resolved_at: nil)
      .where(Sequel.|({resource_id: ids}, Sequel.pg_jsonb_op(:details).get("related_resources").contain_any(ubids)))
      .order(:created_at).all.each do |page|
        next if @pages[page.id]

        @pages[page.id] = true
        @out.puts "#{stamp} page: #{page.summary}"
      end
  end

  def stamp = format("[%5ds]", elapsed.round)

  def stop(reason = nil)
    @out.puts "! watch #{reason}" if reason
    @out.puts "  The bring-up keeps running without the watch, and will reboot the host."
    @out.puts "  Resume the watch with: #{resume_line}"
  end
end
