# frozen_string_literal: true

# A stand-in for Net::SSH.start in the specs of ByohRootProbe and of the
# registration preflight. It runs net-ssh's own host-key verifier for the
# options given against the key the host presents (adding it to
# known_hosts on accept-new, as net-ssh does), answers the PF2 echo, and
# hands out the given channels, in order, to open_channel.
module ByohFakeRootLogin
  # The ed25519 host key of the preflight fixture hosts
  # (spec/fixtures/byoh/preflight/*.txt).
  FIXTURE_HOST_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

  class Channel
    attr_reader :command, :stdin

    # A channel with hang: true never finishes, like a command that hangs
    # on a live host.
    def initialize(out: "", err: "", status: 0, success: true, hang: false)
      @out = out
      @err = err
      @status = status
      @success = success
      @hang = hang
      @requests = {}
    end

    def exec(command)
      @command = command
      yield self, @success
    end

    def on_data(&blk) = (@on_data = blk)

    def on_extended_data(&blk) = (@on_extended_data = blk)

    def on_request(name, &blk) = (@requests[name] = blk)

    def send_data(data) = (@stdin = data)

    def eof! = (@eof = true)

    def eof? = @eof

    def close = (@closed = true)

    def closed? = @closed

    # Delivers the output and the exit status on the first poll, then
    # reports the channel closed, unless it hangs.
    def active?
      return true if @hang
      unless @delivered
        @delivered = true
        @on_data.call(self, @out)
        @on_extended_data.call(self, 1, @err)
        @requests.fetch("exit-status").call(self, Net::SSH::Buffer.from(:long, @status)) if @status
      end
      false
    end
  end

  class Session
    def initialize(channels, echo_output, echo_status)
      @channels = channels
      @echo_output = echo_output
      @echo_status = echo_status
    end

    def exec!(command, expected:)
      raise "unexpected command #{command}" unless command == "echo :expected"

      Net::SSH::Connection::Session::StringWithExitstatus.new(@echo_output || "#{expected}\n", @echo_status)
    end

    def open_channel
      channel = @channels.shift or raise "no channel left for this session"
      yield channel
      channel
    end

    # Net::SSH::Connection::Session#loop: processes until the block is
    # false.
    def loop(_wait)
      nil while yield
    end
  end

  # The channels that a passing registration preflight opens: the facts
  # the script needs, then the script printing output.
  def preflight_channels(output, status: 0, err: "", arch: "x86_64")
    [
      Channel.new(out: "#{arch}\n203.0.113.200 51234 203.0.113.10 22\n"),
      Channel.new(out: output, err:, status:),
    ]
  end

  def preflight_fixture(name) = File.read(File.join(__dir__, "../fixtures/byoh/preflight/#{name}.txt"))

  def fake_root_starter(presented: FIXTURE_HOST_KEY, channels: [], echo_output: nil, echo_status: 0, raises: nil, starts: [])
    lambda do |host, user, **opts, &blk|
      starts << [host, user, opts]
      raise raises if raises

      verifier = {always: Net::SSH::Verifiers::Always, accept_new: Net::SSH::Verifiers::AcceptNew}.fetch(opts[:verify_host_key]).new
      key = Net::SSH::Buffer.new(presented.split(" ")[1].unpack1("m")).read_key
      transport = Struct.new(:host_keys).new(opts[:known_hosts].search_for(host, opts))
      verifier.verify(key:, key_blob: key.to_blob, fingerprint: "SHA256:test", session: transport)
      blk.call(Session.new(channels, echo_output, echo_status))
    end
  end
end
