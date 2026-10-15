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
class ByohRootProbe
  Result = Data.define(:ok, :detail, :fix, :host_keys) do
    def check = ByohHostPreflight::Check.new(id: "PF2", status: ok ? "pass" : "fail", detail:, fix:, accepted: false)
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
    expected = "ubi-pf2-#{@nonce}"
    args = Sshable::COMMON_SSH_ARGS.merge(
      key_data: [@private_key],
      known_hosts: Sshable::KnownHosts.new(@pinned || [], collected),
      verify_host_key: @pinned ? :always : :accept_new,
      logger: Logger.new(File::NULL),
    )
    out = @starter.call(@main_ip, "root", **args) { |ssh| ssh.exec!("echo :expected", expected:) }
    keys = @pinned || collected

    if out.exitstatus&.zero? && out.strip == expected
      result(true, "root@#{@main_ip} logs in with the registration key and runs commands", "", keys)
    else
      result(false, "root@#{@main_ip} logs in but does not run commands (exit #{out.exitstatus}: #{out.strip.lines.first.to_s.strip[0, 120].inspect}); " \
        "a command= option on the key or a ForceCommand runs instead",
        "remove the command= option from root's authorized_keys line for the registration key, or the ForceCommand for root", keys)
    end
  rescue Net::SSH::HostKeyMismatch, Net::SSH::HostKeyUnknown
    result(false, "#{@main_ip} presented a host key that is not pinned for this host",
      "the address reaches a different machine than the operator's session did, or the host was reinstalled; check the address and the host's /etc/ssh/ssh_host_*_key.pub")
  rescue Net::SSH::AuthenticationFailed
    result(false, "root@#{@main_ip} refused the registration key",
      "install the registration public key in /root/.ssh/authorized_keys and allow root publickey login (PermitRootLogin prohibit-password)")
  rescue Net::SSH::Exception, SystemCallError, SocketError, IOError => e
    result(false, "the control plane cannot reach #{@main_ip}:22 (#{e.class}: #{e.message.strip[0, 160]})",
      "open TCP 22 from the control plane to the host's main IP, and check that sshd runs")
  end

  private

  def result(ok, detail, fix, keys = [])
    Result.new(ok:, detail:, fix:, host_keys: keys)
  end
end
