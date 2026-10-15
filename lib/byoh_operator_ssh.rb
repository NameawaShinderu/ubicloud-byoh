# frozen_string_literal: true

require "digest"
require "open3"
require "shellwords"
require "tmpdir"
require_relative "net_ssh"

# The operator's own SSH session to a host that is being added
# (`byoh-host add --ssh USER@IP`). It runs the system ssh client, so any
# key type and the operator's own login setup work, but with a fixed
# argument list that ignores ~/.ssh/config, the agent and the user's
# known_hosts: the session is isolated from the operator account, and
# works under a service user with no home.
#
# Every call within one .open block shares a known-hosts file in a
# private temporary directory. The first connection records the host
# key (accept-new), and every later one must present the same key.
# #verified_host_keys then requires that recorded key to be one of the
# host's own /etc/ssh/ssh_host_*_key.pub, read over the authenticated
# session, before they are pinned for the control plane.
class ByohOperatorSsh
  class TransportError < StandardError; end

  class HostKeyError < StandardError; end

  Result = Data.define(:stdout, :stderr, :status) do
    def success? = status.zero?
  end

  # A host public key in the "<type> <base64 blob>" form that
  # Sshable::KnownHosts reads and writes.
  HostKey = Data.define(:type, :blob) do
    # nil unless line is "<type> <base64> [comment]" holding a key of
    # that type.
    def self.parse(line)
      type, blob = line.to_s.split(" ", 3)
      return unless type && blob

      # A blob that is not strict base64, is cut short, or holds an
      # unknown or malformed key raises one of these, or reads as nil.
      # Anything else is a bug, and surfaces.
      new(type:, blob:) if Net::SSH::Buffer.new(blob.unpack1("m0")).read_key&.ssh_type == type
    rescue NotImplementedError, ArgumentError, TypeError, Net::SSH::Exception, OpenSSL::OpenSSLError
      nil
    end

    # keys (HostKeys, or "<type> <base64> [comment]" lines) as the
    # "<type> <base64>" strings that Sshable::KnownHosts reads and
    # sshable.host_keys stores. Raises on anything else, so that a
    # malformed pin fails before it is stored rather than on every later
    # connection.
    def self.lines(keys)
      Array(keys).map { parse(it.to_s)&.to_s || raise(ArgumentError, "not an SSH host public key: #{it.to_s[0, 60].inspect}") }.uniq
    end

    def to_s = "#{type} #{blob}"

    # As ssh-keygen -l and the ssh client print it.
    def fingerprint = "SHA256:#{[Digest::SHA256.digest(blob.unpack1("m0"))].pack("m0").delete("=")}"
  end

  OPTIONS = %w[
    -F none -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none
    -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no
    -o ControlPath=none -o PermitLocalCommand=no -o UpdateHostKeys=no
    -o ConnectTimeout=10 -o ServerAliveInterval=15
    -o StrictHostKeyChecking=accept-new -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
  ].freeze

  # Ends run_script's stdin, after the script's subshell.
  SCRIPT_STATUS = "s=$?; [ \"$s\" -ne 255 ] || s=254; exit \"$s\"\n"

  TARGET = /\A[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9_][A-Za-z0-9_.:-]*\z/

  # Runs argv with stdin; returns [stdout, stderr, exit status]. A
  # process killed by a signal counts as a transport failure.
  OPEN3_RUNNER = lambda do |argv, stdin|
    out, err, status = Open3.capture3(*argv, stdin_data: stdin)
    [out, err, status.exitstatus || 255]
  end

  attr_reader :user, :host

  def self.valid_target?(target) = TARGET.match?(target.to_s)

  # Yields a session whose known-hosts file is removed with the block.
  def self.open(target, port: nil, key: nil, runner: OPEN3_RUNNER)
    Dir.mktmpdir("ubi-byoh-ssh") do |dir|
      yield new(target, dir, port:, key:, runner:)
    end
  end

  def initialize(target, dir, port: nil, key: nil, runner: OPEN3_RUNNER)
    raise ArgumentError, "--ssh must be USER@HOST, not #{target.inspect}" unless self.class.valid_target?(target)
    raise ArgumentError, "--ssh-port must be 1-65535, not #{port.inspect}" unless port.nil? || (1..65535).cover?(port)

    @target = target
    @user, @host = target.split("@", 2)
    @known_hosts = File.join(dir, "kh")
    @port = port
    @key = key
    @runner = runner
  end

  def argv(remote_command)
    args = ["ssh", *OPTIONS, "-o", "UserKnownHostsFile=#{@known_hosts}"]
    args.push("-i", @key) if @key
    args.push("-p", @port.to_s) if @port
    args.push("--", @target, remote_command)
  end

  # Runs remote_command (one shell string) on the host. ssh exits 255
  # for its own failures (no route, refused, auth, a changed host key),
  # and those raise TransportError. ssh also passes a remote command's
  # own status through, so a command that can itself exit 255 reads as a
  # transport failure here; run_script rules that out for scripts.
  def run(remote_command, stdin: "")
    out, err, status = @runner.call(argv(remote_command), stdin)
    raise TransportError, "ssh #{@target} failed: #{err.to_s.strip.lines.last(3).join.strip}" if status == 255

    Result.new(stdout: out, stderr: err, status:)
  end

  # Runs script as root through passwordless sudo, with the script on
  # stdin so that nothing is copied to the host. The script runs in a
  # subshell whose status 255 becomes 254, so that 255 always means ssh
  # itself failed and a failing script keeps its output.
  def run_script(script, args = [])
    run("sudo -n bash -s -- #{args.shelljoin}".strip, stdin: "(\n#{script.chomp}\n)\n#{SCRIPT_STATUS}")
  end

  def sudo? = run("sudo -n true").success?

  # The keys ssh recorded for the host in this session.
  def recorded_host_keys
    return [] unless File.exist?(@known_hosts)

    File.readlines(@known_hosts, chomp: true).filter_map do |line|
      next if line.start_with?("#", "@")

      HostKey.parse(line.split(" ", 2)[1])
    end.uniq
  end

  # Every host key the host reports (preflight's host_keys fact, the
  # content of its ssh_host_*_key.pub files), as HostKeys, once the key
  # ssh met in this session is shown to be one of them. ByohRootProbe
  # and HostNexus.assemble take them as they are. Anything else means the
  # session reached a different machine than the one that reported the
  # keys.
  def verified_host_keys(reported)
    keys = Array(reported).filter_map { HostKey.parse(it) }.uniq
    raise HostKeyError, "#{@host} reported no readable /etc/ssh/ssh_host_*_key.pub" if keys.empty?

    seen = recorded_host_keys
    raise HostKeyError, "ssh recorded no host key for #{@host}" if seen.empty?

    unless (seen - keys).empty?
      raise HostKeyError, "the key ssh met at #{@host} (#{seen.map(&:fingerprint).join(", ")}) is not one of the host's own keys " \
        "(#{keys.map(&:fingerprint).join(", ")}): a man in the middle, or the address reaches a different machine"
    end

    keys
  end
end
