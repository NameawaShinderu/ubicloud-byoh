# frozen_string_literal: true

require "open3"
require "optparse"

# bin/byoh-virt: where a host stands on the virtualization ladder
# (docs/byoh/NO_KVM.md), before and after registration.
class ByohVirtCli
  class Error < StandardError; end

  USAGE = <<~USAGE
    Usage: bin/byoh-virt COMMAND [options]

    Commands:
      probe    --main-ip IP [--ssh-key FILE] [--user USER] [--json]
               Probe a host over SSH before registering it (needs ruby on
               the host; scripts/byoh/bootstrap-data-plane.sh installs it).
               A --user other than root needs passwordless sudo: the probe
               runs under sudo -n, since only root can open /dev/kvm.
      explain  [FILE]   Explain saved virt-probe --json output (default stdin)
      script            Print the probe as a script for "ruby -" on a host
      show     --host UBID   Show what the last probe of a host found
      refresh  --host UBID | --all
               Probe a registered host again, or every BYOH host (generic
               provider in a BYOH location) whose rhizome is installed
      pvm retry --host UBID [--accept-host-deb SHA256]
               After a failed PVM host kernel install: install it again
               (--accept-host-deb takes the location's new host-deb pin
               for this host). After a failed PVM kernel boot: arm one
               more PVM boot and reboot the host.
      pvm uninstall --host UBID
               Take the PVM host kernel the control plane installed off a
               pvm host without VMs; then destroy the host and register
               it again on another tier

    probe, explain and show exit 0 when the host can run VMs (L1), 3 when
    not; show judges a host registered on a lower tier by that tier's
    prerequisites instead. show exits 0 for a host that was never probed.
  USAGE

  NOT_L1 = 3

  # A generic host still in a non-BYOH location keeps its M1 behaviour
  # (VmHost#byoh?), so it is never probed.
  NOT_BYOH = "not in a BYOH location; move it with bin/byoh-host move-location first"

  def initialize(out: $stdout, err: $stderr, stdin: $stdin)
    @out = out
    @err = err
    @stdin = stdin
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when "probe", "explain", "script", "show", "refresh", "pvm"
      send(:"cmd_#{command}", argv) || 0
    when nil, "help", "-h", "--help"
      @out.puts USAGE
      0
    else
      raise Error, "unknown command #{command}\n#{USAGE}"
    end
  rescue Error, OptionParser::ParseError, ByohVirtLadder::ParseError => e
    @err.puts "! #{e.message}"
    1
  end

  private

  def cmd_probe(argv)
    opts = {user: "root"}
    parse(argv, "probe --main-ip IP [--ssh-key FILE] [--user USER] [--json]") do |o|
      o.on("--main-ip IP", "Address the control plane reaches the host on") { opts[:ip] = it }
      o.on("--ssh-key FILE", "Private key for the host (default: ssh's own)") { opts[:key] = it }
      o.on("--user USER", "SSH user (default root)") { opts[:user] = it }
      o.on("--json", "Print the raw probe report") { opts[:json] = true }
    end
    raise Error, "--main-ip is required" unless opts[:ip]

    remote = (opts[:user] == "root") ? "ruby - --json" : "sudo -n ruby - --json"
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    cmd.push("-i", opts[:key]) if opts[:key]
    cmd.push("#{opts[:user]}@#{opts[:ip]}", remote)
    out, err, status = Open3.capture3(*cmd, stdin_data: ByohVirtLadder.remote_script)
    unless status.success?
      err = ByohVirtLadder.sanitize(err.strip)
      if remote.start_with?("sudo") && err.start_with?("sudo:")
        raise Error, "sudo -n failed for #{opts[:user]} on #{opts[:ip]}: #{err}; the probe must run as root to open /dev/kvm, so give #{opts[:user]} passwordless sudo or use --user root"
      end
      raise Error, "probing #{opts[:ip]} failed (#{status.exitstatus}): #{err}; the host needs ruby (apt-get install ruby) and SSH from here"
    end

    if opts[:json]
      @out.puts out
      return ByohVirtLadder.parse(out).standard_vms? ? 0 : NOT_L1
    end
    show_verdict(ByohVirtLadder.parse(out))
  end

  def cmd_explain(argv)
    parse(argv, "explain [FILE]", max_args: 1) { |_| }
    input = argv.empty? ? @stdin.read : File.read(argv.first)
    show_verdict(ByohVirtLadder.parse(input))
  rescue SystemCallError => e
    raise Error, e.message
  end

  def cmd_script(argv)
    parse(argv, "script") { |_| }
    @out.print ByohVirtLadder.remote_script
  end

  def cmd_show(argv)
    host = find_host(argv, "show --host UBID")
    status = show_probe(host)
    show_pvm(host) if host.virt_tier == "pvm"
    status
  end

  def show_probe(host)
    unless host.virt_probe
      @out.puts "host #{host.ubid} was never probed; run bin/byoh-virt refresh --host #{host.ubid}"
      return
    end
    @out.puts "host #{host.ubid}#{", registered as #{ByohVirtTiers.fetch(host.virt_tier).label}" if ByohVirtTiers.lower?(host.virt_tier)}"
    if (error = host.virt_probe["error"])
      @out.puts "the last probe failed: #{error}"
      return NOT_L1
    end
    verdict = ByohVirtLadder.verdict(host.virt_probe.to_h)
    return show_verdict(verdict) unless ByohVirtTiers.lower?(host.virt_tier)

    # A lower-tier host is judged by its own tier's prerequisites.
    @out.puts verdict.text
    agrees = ByohVirtTiers.accepts_probe?(host.virt_tier, verdict)
    @out.puts "registered tier: #{host.virt_tier}, #{agrees ? "the probe agrees" : "the probe disagrees; see the ByohVirtTier page"}"
    agrees ? 0 : NOT_L1
  end

  def cmd_refresh(argv)
    key = nil
    all = false
    parse(argv, "refresh --host UBID | --all") do |o|
      o.on("--host UBID", "VmHost ubid") { key = it }
      o.on("--all", "Every BYOH host whose rhizome is installed") { all = true }
    end
    raise Error, "give either --host or --all" unless all ^ !key.nil?

    unless all
      host = lookup_host(key)
      raise Error, "host #{host.ubid} has no rhizome yet; its prep probes it" unless rhizome_installed?(host)
      return start_probe(host)
    end

    VmHost.where(id: HostProvider.where(provider_name: HostProvider::GENERIC_PROVIDER_NAME).select(:id)).order(:id).eager(:strand, :location, :provider).all.each do |h|
      if !h.byoh?
        @out.puts "Skipped host #{h.ubid}: #{NOT_BYOH}."
      elsif rhizome_installed?(h)
        start_probe(h)
      else
        @out.puts "Skipped host #{h.ubid}: no rhizome yet; its prep probes it."
      end
    end
    nil
  end

  # What the control plane knows of a pvm host's PVM kernels: the host
  # kernel's install (byoh_pvm_host), what the host said of its boot at
  # its last install-pvm-host-kernel run, the kernels its patch run found,
  # and the guest kernels it holds (byoh_pvm_guest_kernel).
  def show_pvm(host)
    row = ByohPvmHost[host.id]
    pins = ByohPvmPolicy.pins(ByohVirtTiers.policy(host.location)) || {}
    frame = host.strand&.stack&.first || {}
    if row
      @out.puts "PVM host kernel: #{row.state}, #{row.install ? "installed by the control plane" : "installed before registration"}"
      @out.puts "  PVM kernel #{row.host_kver || "-"}, stock kernel #{row.stock_kver || "-"} (GRUB default #{row.stock_entry ? "'#{row.stock_entry}'" : "-"})"
      pin = pins.dig("host_deb", "sha256")
      if row.host_deb_sha256
        @out.puts "  host-deb sha256 #{row.host_deb_sha256} (#{(pin == row.host_deb_sha256) ? "the location's pin" : "the location pins #{pin || "none"}"})"
      end
      @out.puts "  lockdown #{row.lockdown || "-"}, Meltdown #{row.meltdown || "-"}"
      @out.puts "  last error: #{row.last_error}" if row.last_error
    else
      @out.puts "PVM host kernel: not recorded"
    end
    if (st = frame["pvm_status"])
      @out.puts "  at #{st["at"]}: kernel #{st["kernel"] || "-"}, grubenv #{(st["grubenv"] || {}).map { |k, v| "#{k}=#{v}" }.join(" ")}"
      unit = st["boot_unit"]
      @out.puts "  boot unit #{unit.map { |k, v| "#{k}=#{v}" }.join(" ")}" if unit
    end
    if (kernels = frame["pvm_patch_kernels"])
      @out.puts "  kernel packages before patch: #{(kernels["before"] || []).join(" ")}; after: #{(kernels["after"] || ["(patch running)"]).join(" ")}"
    end
    @out.puts "  waiting for bin/byoh-virt pvm retry or pvm uninstall (#{host.strand.label})" if PVM_WAIT_LABELS.include?(host.strand&.label)
    guests = ByohPvmGuestKernel.where(vm_host_id: host.id).order(:sha256).all
    @out.puts(guests.empty? ? "PVM guest kernels: none" : "PVM guest kernels:")
    guests.each do |g|
      checked = g.config_checked ? "config checked" : "config unchecked"
      pinned = (g.sha256 == pins.dig("guest_kernel", "sha256")) ? ", the location's pin" : ""
      @out.puts "  #{g.sha256} #{g.state}#{" #{g.release}, console #{g.console}, #{checked}" if g.state == "ready"}#{pinned}"
    end
  end

  PVM_WAIT_LABELS = %w[pvm_install_failed pvm_boot_failed].freeze

  # Labels of a pvm host's strand where pvm uninstall can start: in
  # bring-up before the install, where an install or boot failed, and on
  # a host at work.
  PVM_UNINSTALL_LABELS = %w[verify_virt_tier pvm_install_failed pvm_boot_failed wait].freeze

  def cmd_pvm(argv)
    sub = argv.shift
    raise Error, "usage: bin/byoh-virt pvm retry|uninstall --host UBID" unless %w[retry uninstall].include?(sub)

    send(:"pvm_#{sub}", argv)
  end

  def pvm_retry(argv)
    key = nil
    accept = nil
    parse(argv, "pvm retry --host UBID [--accept-host-deb SHA256]") do |o|
      o.on("--host UBID", "VmHost ubid") { key = it }
      o.on("--accept-host-deb SHA256", "Install the location's current host-deb pin, which this host's registration did not acknowledge") { accept = it }
    end
    host, row = pvm_host(key)
    label = host.strand&.label || "no strand"
    raise Error, "host #{host.ubid} is at #{label}; pvm retry acts only where a PVM kernel install or boot failed (#{PVM_WAIT_LABELS.join(", ")})" unless PVM_WAIT_LABELS.include?(label)

    pin = ByohPvmPolicy.pins(ByohVirtTiers.policy(host.location))&.dig("host_deb", "sha256")
    if accept
      raise Error, "--accept-host-deb is for a failed install; this host's PVM kernel is installed" unless label == "pvm_install_failed"
      raise Error, "location #{host.location.name} pins host-deb sha256 #{pin || "none"}, not #{accept}" unless accept == pin
    elsif label == "pvm_install_failed" && row.install && pin != row.host_deb_sha256
      raise Error, "location #{host.location.name} pins host-deb sha256 #{pin || "none"}, but this host acknowledged #{row.host_deb_sha256}; check the new build, then pvm retry --host #{host.ubid} --accept-host-deb #{pin || "SHA256"}"
    end

    DB.transaction do
      row.update(host_deb_sha256: accept, updated_at: Time.now) if accept
      host.incr_pvm_retry
      args = {from: label}
      args[:accept_host_deb] = accept if accept
      ByohOperatorLog.record(command: "virt-pvm-retry", target_id: host.id, args:, result: "requested")
    end
    what = (label == "pvm_install_failed") ? "install the PVM host kernel again" : "arm one more PVM kernel boot and reboot it"
    @out.puts "Asked host #{host.ubid} to #{what}; follow it with bin/byoh-host watch #{host.ubid}."
    nil
  end

  def pvm_uninstall(argv)
    key = nil
    parse(argv, "pvm uninstall --host UBID") { |o| o.on("--host UBID", "VmHost ubid") { key = it } }
    host, row = pvm_host(key)
    raise Error, "the control plane did not install the PVM kernel of host #{host.ubid}; remove it by hand, then destroy the host and register it again" unless row.install
    raise Error, "host #{host.ubid} has its PVM kernel uninstalled already" if row.state == "uninstalled"
    unless (count = host.vms_dataset.count).zero?
      raise Error, "host #{host.ubid} has #{count} VMs; delete them first (an uninstall leaves the host unable to run them)"
    end
    label = host.strand&.label || "no strand"
    raise Error, "host #{host.ubid} is at #{label}; pvm uninstall starts only at #{PVM_UNINSTALL_LABELS.join(", ")}" unless PVM_UNINSTALL_LABELS.include?(label)

    DB.transaction do
      host.incr_pvm_uninstall
      ByohOperatorLog.record(command: "virt-pvm-uninstall", target_id: host.id, args: {from: label}, result: "requested")
    end
    @out.puts "Asked host #{host.ubid} to uninstall its PVM host kernel (it reboots to its stock kernel first if it runs the PVM one)."
    @out.puts "Then destroy it and register it again on another tier; bin/byoh-virt show --host #{host.ubid} shows where it stands."
    nil
  end

  def pvm_host(key)
    raise Error, "--host is required" unless key

    host = lookup_host(key)
    raise Error, "host #{host.ubid} is a #{host.virt_tier} host, not pvm" unless host.virt_tier == "pvm"

    row = ByohPvmHost[host.id] || raise(Error, "host #{host.ubid} has no PVM kernel record")
    [host, row]
  end

  def rhizome_installed?(host)
    !(host.strand && ByohHostCli::PRE_PREP_LABELS.include?(host.strand.label))
  end

  def start_probe(host)
    strand = DB.transaction do
      st = Prog::LearnVirt.assemble(host.id)
      ByohOperatorLog.record(command: "virt-refresh", target_id: host.id, args: {}, result: "started #{st.ubid}")
      st
    end
    @out.puts "Started #{strand.ubid} to probe host #{host.ubid}; see the result with bin/byoh-virt show --host #{host.ubid}."
    nil
  end

  def show_verdict(verdict)
    @out.puts verdict.text
    verdict.standard_vms? ? 0 : NOT_L1
  end

  def parse(argv, banner, max_args: 0)
    parser = OptionParser.new do |o|
      o.banner = "Usage: bin/byoh-virt #{banner}"
      yield o
    end
    parser.parse!(argv)
    raise Error, "unexpected argument #{argv[max_args]}" if argv.size > max_args
  end

  def find_host(argv, banner)
    key = nil
    parse(argv, banner) { |o| o.on("--host UBID", "VmHost ubid") { key = it } }
    raise Error, "--host is required" unless key

    lookup_host(key)
  end

  def lookup_host(key)
    host = (VmHost[key] if key.match?(/\Avh[0-9a-z]{24}\z/)) || raise(Error, "no host #{key}")
    raise Error, "host #{host.ubid} is not a generic (BYOH) host" unless host.provider_name == HostProvider::GENERIC_PROVIDER_NAME
    raise Error, "host #{host.ubid} is #{NOT_BYOH}" unless host.byoh?
    host
  end
end
