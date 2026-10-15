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

    probe, explain and show exit 0 when the host can run VMs (L1), 3 when
    not. show exits 0 for a host that was never probed.
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
    when "probe", "explain", "script", "show", "refresh"
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
    unless host.virt_probe
      @out.puts "host #{host.ubid} was never probed; run bin/byoh-virt refresh --host #{host.ubid}"
      return
    end
    @out.puts "host #{host.ubid}"
    if (error = host.virt_probe["error"])
      @out.puts "the last probe failed: #{error}"
      return NOT_L1
    end
    show_verdict(ByohVirtLadder.verdict(host.virt_probe.to_h))
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
