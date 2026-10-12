# frozen_string_literal: true

require "optparse"

# bin/byoh-pool: lists, exports, changes and checks the address pools of a
# registered BYOH host (docs/byoh/NETWORKING.md section 10). The work is
# done by ByohPool; every change is written to byoh_operator_action.
class ByohPoolCli
  class Error < StandardError; end

  USAGE = <<~USAGE
    Usage: bin/byoh-pool COMMAND [options]

    Commands:
      list      --host UBID
      export    --host UBID [--set delivery=D,exposure=E] [--external-map FILE]
      add       --host UBID (--pool CIDR[,key=value...] ... | --pool-file FILE)
      remove    --host UBID --pool CIDR [--drain [--drain-timeout SECONDS]]
      remap     --host UBID --ip POOL_IP --external EXTERNAL_IP
      annotate  --host UBID (--pool CIDR[,key=value...] ... | --pool-file FILE)
      ipv6 set  --host UBID --cidr IPV6/64[,ndp] [--mode gua|ula]
      verify    --host UBID
      trace     IP

    Run a command with --help for its options.
  USAGE

  COMMANDS = %w[list export add remove remap annotate ipv6 verify trace].freeze

  LIST_ROW = "%-16s %-16s %-9s %s"

  def initialize(out: $stdout, err: $stderr, sleeper: Kernel.method(:sleep))
    @out = out
    @err = err
    @sleeper = sleeper
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when *COMMANDS
      send(:"cmd_#{command}", argv)
    when nil, "help", "-h", "--help"
      @out.puts USAGE
      0
    else
      raise Error, "unknown command #{command}\n#{USAGE}"
    end
  rescue Error, ByohPool::Error, ByohPoolDeclaration::ValidationError, OptionParser::ParseError => e
    @err.puts "! #{e.message}"
    1
  end

  private

  def cmd_list(argv)
    opts = {}
    parse(argv, "list --host UBID") { host_option(it, opts) }
    host = find_host(opts)
    pool = ByohPool.new(host)

    @out.puts "Host #{host.ubid}, location #{host.location.name}, IPv6 #{host.net6} (#{host.ipv6_mode})"
    pool.pool_addresses.each { @out.puts "Pool #{it.cidr}: delivery #{it.delivery}, exposure #{it.exposure}" }
    rows = pool.rows
    vms = Vm.where(id: rows.filter_map { it[:vm_id] }).to_hash(:id)
    @out.puts format(LIST_ROW, "IP", "EXTERNAL", "EXPOSURE", "STATE")
    rows.each do |row|
      state = if (vm = vms[row[:vm_id]])
        "#{vm.ubid} #{vm.name}"
      else
        row[:reserved] ? "reserved" : "free"
      end
      @out.puts format(LIST_ROW, row[:ip], row[:external_ip] || "-", row[:exposure], state)
    end
    0
  end

  def cmd_export(argv)
    opts = {set: {}}
    parse(argv, "export --host UBID [--set delivery=D,exposure=E] [--external-map FILE]") do |o|
      host_option(o, opts)
      o.on("--set KEY=VALUE,...", Array, "Override delivery and exposure for every pool") do |pairs|
        pairs.each do |pair|
          key, value = pair.split("=", 2)
          raise Error, "--set takes key=value pairs, not #{pair}" unless value
          opts[:set][key] = value
        end
      end
      o.on("--external-map FILE", "YAML {pool IP: external IP}, or the JSON of aws ec2 describe-addresses") { opts[:external_map] = it }
    end
    host = find_host(opts)
    external_map = opts[:external_map] ? ByohPool.load_external_map(read(opts[:external_map])) : {}

    yaml, notes = ByohPool.new(host).export(set: opts[:set], external_map:)
    notes.each { @err.puts "note: #{it}" }
    @out.print yaml
    0
  end

  def cmd_add(argv)
    pools_command(argv, "add") { |pool, document| pool.add(document.entries) }
  end

  def cmd_annotate(argv)
    pools_command(argv, "annotate") do |pool, document|
      pool.annotate(document.entries, uplink: document.uplink, ipv6_mode: document.ipv6_mode)
    end
  end

  def cmd_remove(argv)
    opts = {drain_timeout: 600}
    parse(argv, "remove --host UBID --pool CIDR [--drain [--drain-timeout SECONDS]]") do |o|
      host_option(o, opts)
      o.on("--pool CIDR", "The pool to remove") { opts[:pool] = it }
      o.on("--drain", "Destroy the pool's VMs and wait for them to be gone") { opts[:drain] = true }
      o.on("--drain-timeout SECONDS", Integer, "How long to wait for drained VMs (default 600)") { opts[:drain_timeout] = it }
    end
    raise Error, "--pool is required" unless opts[:pool]

    host = mutable_host(opts)
    pool = ByohPool.new(host, sleeper: @sleeper, drain_polls: opts[:drain_timeout] / ByohPool::DRAIN_POLL_SECONDS)
    finish(pool.remove(opts[:pool], drain: opts[:drain]), "Removed pool #{opts[:pool]} from host #{host.ubid}.")
  end

  def cmd_remap(argv)
    opts = {}
    parse(argv, "remap --host UBID --ip POOL_IP --external EXTERNAL_IP") do |o|
      host_option(o, opts)
      o.on("--ip POOL_IP", "The nat pool address") { opts[:ip] = it }
      o.on("--external EXTERNAL_IP", "Its new external IP") { opts[:external] = it }
    end
    raise Error, "--ip and --external are required" unless opts[:ip] && opts[:external]

    host = mutable_host(opts)
    finish(ByohPool.new(host).remap(opts[:ip], opts[:external]), "Mapped #{opts[:ip]} to #{opts[:external]} on host #{host.ubid}.")
  end

  def cmd_ipv6(argv)
    subcommand = argv.shift
    raise Error, "ipv6 takes the subcommand set" unless subcommand == "set"

    opts = {}
    parse(argv, "ipv6 set --host UBID --cidr IPV6/64[,ndp] [--mode gua|ula]") do |o|
      host_option(o, opts)
      o.on("--cidr IPV6/64[,ndp]", "The host's new IPv6 network") { opts[:cidr] = it }
      o.on("--mode MODE", "gua or ula (default: derived from the network)") { opts[:mode] = it }
    end
    raise Error, "--cidr is required" unless opts[:cidr]

    host = mutable_host(opts)
    notes = ByohPool.new(host).ipv6_set(opts[:cidr], mode: opts[:mode])
    finish(notes, "Set the IPv6 network of host #{host.ubid} to #{host.net6} (#{host.ipv6_mode}).")
  end

  def cmd_verify(argv)
    opts = {}
    parse(argv, "verify --host UBID") { host_option(it, opts) }
    host = find_host(opts)

    results = ByohPool.new(host).verify
    results.each { |level, message| @out.puts "#{level}: #{message}" }
    failures = results.count { it.first == :fail }
    @out.puts "Host #{host.ubid}: #{failures} failed, #{results.count { it.first == :warn }} warnings."
    failures.zero? ? 0 : 1
  end

  def cmd_trace(argv)
    parser = OptionParser.new { it.banner = "Usage: bin/byoh-pool trace IP" }
    rest = parser.parse(argv)
    raise Error, "trace takes one IP address" unless rest.size == 1

    ByohPool.trace(rest.first).each { @out.puts it }
    0
  end

  # add and annotate take the same pools, inline or from a pools.yaml.
  def pools_command(argv, command)
    opts = {pools: []}
    parse(argv, "#{command} --host UBID (--pool CIDR[,key=value...] ... | --pool-file FILE)") do |o|
      host_option(o, opts)
      o.on("--pool CIDR[,key=value...]", "A pool in the registration syntax; repeatable") { opts[:pools] << it }
      o.on("--pool-file FILE", "pools.yaml (version 2)") { opts[:pool_file] = it }
    end

    entries = opts[:pools].map { ByohPoolDeclaration.parse(it) }
    document = if opts[:pool_file]
      file = ByohPoolDeclaration.parse_yaml(read(opts[:pool_file]))
      file.with(entries: file.entries + entries)
    else
      ByohPoolDeclaration::Document.new(entries:, uplink: nil, ipv6_mode: nil)
    end

    host = mutable_host(opts)
    finish(yield(ByohPool.new(host), document), "Updated the pools of host #{host.ubid}; check them with bin/byoh-pool verify --host #{host.ubid}.")
  end

  def finish(notes, message)
    notes.each { @err.puts "note: #{it}" }
    @out.puts message
    0
  end

  def parse(argv, banner)
    parser = OptionParser.new do |o|
      o.banner = "Usage: bin/byoh-pool #{banner}"
      yield o
    end
    rest = parser.parse(argv)
    raise Error, "unexpected argument #{rest.first}" unless rest.empty?
  end

  def host_option(o, opts)
    o.on("--host UBID", "VmHost ubid") { opts[:host] = it }
  end

  def read(path)
    File.read(path)
  rescue SystemCallError => ex
    raise Error, "cannot read #{path}: #{ex.message}"
  end

  def find_host(opts)
    key = opts[:host] || raise(Error, "--host is required")
    host = (VmHost[key] if key.match?(/\Avh[0-9a-z]{24}\z/)) || raise(Error, "no host #{key}")
    raise Error, "host #{host.ubid} is not a generic (BYOH) host" unless host.provider_name == HostProvider::GENERIC_PROVIDER_NAME
    host
  end

  # Pools change only on hosts the network contract applies to.
  def mutable_host(opts)
    host = find_host(opts)
    unless host.byoh?
      raise Error, "host #{host.ubid} is in location #{host.location.name}, which is not a BYOH location; move it with bin/byoh-host move-location first"
    end
    host
  end
end
