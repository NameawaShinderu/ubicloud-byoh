# frozen_string_literal: true

require "logger"
require "securerandom"
require_relative "net_ssh"

# PF2: can the control plane log in to a BYOH host as root with the
# registration key, and does that login reach a shell? It connects the
# way the control plane later will (Net::SSH with Sshable's arguments,
# but with no session cache and no Sshable row), and runs a single echo.
#
# With pinned_host_keys (ByohOperatorSsh#verified_host_keys, or
# "<type> <base64>" lines), the host must present one of them, so the
# operator's session and the control plane's reach the same machine. Without them (a plain
# register-byoh-host run) the first key the host presents is accepted
# and returned, to be pinned at registration: the control plane then
# trusts one key from its first connection on, as it does for every
# host.
#
# A block given to #call runs in the same connection once PF2 passes,
# with a Session that runs further commands as root; its value is the
# result's output. register-byoh-host runs host preflight this way. A
# connection error after PF2 passed (a disconnect, a refused command, a
# command that timed out) leaves PF2 passing and becomes the result's
# error instead, since the login itself worked.
class ByohRootProbe
  Result = Data.define(:ok, :detail, :fix, :host_keys, :output, :error) do
    def initialize(ok:, detail:, fix:, host_keys:, output: nil, error: nil) = super

    def check = ByohHostPreflight::Check.new(id: "PF2", status: ok ? "pass" : "fail", detail:, fix:, accepted: false)
  end

  # Raised by Session#exec for a command that outlives its timeout.
  class CommandTimeout < StandardError; end

  # Runs commands in the probe's connection.
  class Session
    def initialize(ssh)
      @ssh = ssh
    end

    # Runs command (built with NetSsh.command) with stdin; returns
    # [stdout, stderr, exit status], the status nil when a signal ended
    # the command. Closes the channel and raises CommandTimeout once the
    # command has run for timeout seconds: keepalive notices a dead host,
    # but not a live one whose command hangs.
    def exec(command, stdin: "", timeout: 60)
      out = +""
      err = +""
      status = nil
      channel = @ssh.open_channel do |ch|
        ch.exec(command) do |_, success|
          raise Net::SSH::Exception, "the host refused to run #{command[0, 60].inspect}" unless success

          ch.on_data { |_, data| out << data }
          ch.on_extended_data { |_, _, data| err << data }
          ch.on_request("exit-status") { |_, data| status = data.read_long }
          ch.send_data(stdin)
          ch.eof!
        end
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @ssh.loop(0.1) { channel.active? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline }
      if channel.active?
        channel.close
        raise CommandTimeout, "#{command[0, 60].inspect} did not finish within #{timeout} s"
      end
      [out, err, status]
    end
  end

  # Looked up on each call, not when the class loads: the web process
  # removes Net::SSH.start (lib/net_ssh.rb), and still loads every class
  # under forced autoload.
  NET_SSH_START = ->(host, user, **opts, &blk) { Net::SSH.start(host, user, **opts, &blk) }

  def initialize(main_ip, private_key, pinned_host_keys: nil, starter: NET_SSH_START, nonce: SecureRandom.hex(8))
    raise ArgumentError, "pinned_host_keys is empty" if pinned_host_keys&.empty?

    @main_ip = main_ip
    @private_key = private_key
    @pinned = pinned_host_keys && ByohOperatorSsh::HostKey.lines(pinned_host_keys)
    @starter = starter
    @nonce = nonce
  end

  def call
    collected = []
    output = nil
    logged_in = false
    expected = "ubi-pf2-#{@nonce}"
    args = Sshable::COMMON_SSH_ARGS.merge(
      key_data: [@private_key],
      known_hosts: Sshable::KnownHosts.new(@pinned || [], collected),
      verify_host_key: @pinned ? :always : :accept_new,
      logger: Logger.new(File::NULL),
    )
    out = @starter.call(@main_ip, "root", **args) do |ssh|
      echo = ssh.exec!("echo :expected", expected:)
      if echoed?(echo, expected)
        logged_in = true
        output = yield(Session.new(ssh)) if block_given?
      end
      echo
    end
    keys = @pinned || collected

    if echoed?(out, expected)
      passed(keys, output)
    else
      failed("root@#{@main_ip} logs in but does not run commands (exit #{out.exitstatus}: #{out.strip.lines.first.to_s.strip[0, 120].inspect}); " \
        "a command= option on the key or a ForceCommand runs instead",
        "remove the command= option from root's authorized_keys line for the registration key, or the ForceCommand for root", keys)
    end
  rescue Net::SSH::HostKeyMismatch, Net::SSH::HostKeyUnknown
    failed("#{@main_ip} presented a host key that is not pinned for this host",
      "the address reaches a different machine than the operator's session did, or the host was reinstalled; check the address and the host's /etc/ssh/ssh_host_*_key.pub")
  rescue Net::SSH::AuthenticationFailed
    failed("root@#{@main_ip} refused the registration key",
      "install the registration public key in /root/.ssh/authorized_keys and allow root publickey login (PermitRootLogin prohibit-password)")
  rescue Net::SSH::Exception, SystemCallError, SocketError, IOError, CommandTimeout => e
    reason = "#{e.class}: #{e.message.strip[0, 160]}"
    return passed(@pinned || collected, nil, reason) if logged_in

    failed("the control plane cannot reach #{@main_ip}:22 (#{reason})",
      "open TCP 22 from the control plane to the host's main IP, and check that sshd runs")
  end

  private

  def passed(keys, output, error = nil)
    Result.new(ok: true, detail: "root@#{@main_ip} logs in with the registration key and runs commands", fix: "", host_keys: keys, output:, error:)
  end

  def echoed?(out, expected) = out.exitstatus&.zero? && out.strip == expected

  def failed(detail, fix, keys = [])
    Result.new(ok: false, detail:, fix:, host_keys: keys)
  end
end
