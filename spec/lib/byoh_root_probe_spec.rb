# frozen_string_literal: true

require_relative "byoh_fake_root_login"

RSpec.describe ByohRootProbe do
  include ByohFakeRootLogin

  let(:reg_key) { SshKey.generate }
  let(:host_pub) { SshKey.generate.public_key }
  let(:starts) { [] }

  def server_key(pub) = Net::SSH::Buffer.new(pub.split(" ")[1].unpack1("m")).read_key

  # A fake Net::SSH.start: runs net-ssh's own verifier for the options
  # given against the key the host presents (adding it to known_hosts
  # on accept-new, as net-ssh does), then answers the command.
  def starter(presented: host_pub, output: nil, status: 0, raises: nil)
    lambda do |host, user, **opts, &blk|
      starts << [host, user, opts]
      raise raises if raises

      verifier = {always: Net::SSH::Verifiers::Always, accept_new: Net::SSH::Verifiers::AcceptNew}.fetch(opts[:verify_host_key]).new
      key = server_key(presented)
      transport = instance_double(Net::SSH::Transport::Session, host_keys: opts[:known_hosts].search_for(host, opts))
      verifier.verify(key:, key_blob: key.to_blob, fingerprint: "SHA256:test", session: transport)

      session = instance_double(Net::SSH::Connection::Session)
      expect(session).to receive(:exec!).with("echo :expected", expected: "ubi-pf2-n0nce").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(output || "ubi-pf2-n0nce\n", status))
      blk.call(session)
    end
  end

  def probe(pinned: nil, **)
    described_class.new("203.0.113.42", reg_key.private_key, pinned_host_keys: pinned, starter: starter(**), nonce: "n0nce")
  end

  it "passes with a pinned key the host presents, and connects as the control plane would" do
    result = probe(pinned: [SshKey.generate.public_key, host_pub]).call
    expect(result.ok).to be true
    expect(result.host_keys.last).to eq(host_pub)
    expect(result.check).to eq(ByohHostPreflight::Check.new(id: "PF2", status: "pass", detail: "root@203.0.113.42 logs in with the registration key and runs commands", fix: "", accepted: false))

    host, user, opts = starts.first
    expect([host, user]).to eq(["203.0.113.42", "root"])
    expect(opts.except(:known_hosts, :logger)).to eq(Sshable::COMMON_SSH_ARGS.merge(key_data: [reg_key.private_key], verify_host_key: :always))
    expect(opts[:logger]).to be_a(Logger)
    expect(opts[:use_agent]).to be false
  end

  it "fails when the host presents a key that is not pinned" do
    result = probe(pinned: [SshKey.generate.public_key]).call
    expect(result.ok).to be false
    expect(result.check.status).to eq("fail")
    expect(result.detail).to eq("203.0.113.42 presented a host key that is not pinned for this host")
    expect(result.fix).to include("reaches a different machine")
    expect(result.host_keys).to eq([])
  end

  it "fails when the host is unknown to the pin" do
    result = probe(pinned: [host_pub], raises: Net::SSH::HostKeyUnknown.new("unknown")).call
    expect(result.detail).to include("not pinned")
  end

  it "accepts and returns the first host key without a pin" do
    result = probe.call
    expect(result.ok).to be true
    expect(result.host_keys).to eq([host_pub])
    expect(starts.first[2][:verify_host_key]).to eq(:accept_new)
  end

  it "fails on a forced command" do
    result = probe(output: "Please login as the user \"ubuntu\" rather than the user \"root\".\n\n", status: 142).call
    expect(result.ok).to be false
    expect(result.detail).to eq("root@203.0.113.42 logs in but does not run commands (exit 142: \"Please login as the user \\\"ubuntu\\\" rather than the user \\\"root\\\".\"); a command= option on the key or a ForceCommand runs instead")
    expect(result.fix).to include("command= option")
  end

  it "fails when the echo is replaced though the exit status is 0" do
    expect(probe(output: "").call.detail).to include("(exit 0: \"\")")
  end

  it "fails when the command dies by a signal" do
    expect(probe(status: nil).call.ok).to be false
  end

  it "fails when root refuses the key" do
    result = probe(raises: Net::SSH::AuthenticationFailed.new("root")).call
    expect(result.detail).to eq("root@203.0.113.42 refused the registration key")
    expect(result.fix).to include("/root/.ssh/authorized_keys")
  end

  it "fails when the host cannot be reached" do
    [Errno::ECONNREFUSED.new, Net::SSH::ConnectionTimeout.new("timed out"), SocketError.new("getaddrinfo"), IOError.new("closed")].each do |error|
      result = probe(raises: error).call
      expect(result.ok).to be false
      expect(result.detail).to start_with("the control plane cannot reach 203.0.113.42:22 (#{error.class}: ")
    end
  end

  it "takes the keys ByohOperatorSsh#verified_host_keys returns, and returns them as lines" do
    other = SshKey.generate.public_key
    verified = ByohOperatorSsh.open("ubuntu@203.0.113.42", runner: lambda { |argv, _stdin|
      File.write(argv.find { it.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile="), "203.0.113.42 #{host_pub}\n")
      ["", "", 0]
    }) do |ssh|
      ssh.run("true")
      ssh.verified_host_keys(["#{other} root@h", "#{host_pub} root@h"])
    end
    expect(verified).to all(be_a(ByohOperatorSsh::HostKey))

    result = probe(pinned: verified).call
    expect(result.ok).to be true
    expect(result.host_keys).to eq([other, host_pub])
  end

  describe "with a block" do
    it "runs it in the same connection once PF2 passes, and returns its value as the output" do
      channel = ByohFakeRootLogin::Channel.new(out: "out\n", err: "err\n", status: 3)
      starter = fake_root_starter(channels: [channel])
      result = described_class.new("203.0.113.42", reg_key.private_key, starter:, nonce: "n0nce").call do |session|
        session.exec(NetSsh.command("cat"), stdin: "data")
      end
      expect(result.ok).to be true
      expect(result.output).to eq ["out\n", "err\n", 3]
      expect([channel.command, channel.stdin, channel.eof?]).to eq ["cat", "data", true]
      expect(result.host_keys).to eq [ByohFakeRootLogin::FIXTURE_HOST_KEY]
    end

    it "gives a nil status when a signal ends the command" do
      starter = fake_root_starter(channels: [ByohFakeRootLogin::Channel.new(status: nil)])
      result = described_class.new("203.0.113.42", reg_key.private_key, starter:, nonce: "n0nce").call { it.exec(NetSsh.command("true")) }
      expect(result.output).to eq ["", "", nil]
    end

    it "does not run it when PF2 fails" do
      starter = fake_root_starter(echo_output: "Please login as the user \"ubuntu\"\n", echo_status: 142)
      ran = false
      result = described_class.new("203.0.113.42", reg_key.private_key, starter:, nonce: "n0nce").call { ran = true }
      expect([result.ok, result.output, ran]).to eq [false, nil, false]
    end

    # PF2 passed: the login works, so an error in the block is not a
    # reachability failure.
    it "keeps PF2 passing and returns the error when the host refuses to run the command" do
      starter = fake_root_starter(channels: [ByohFakeRootLogin::Channel.new(success: false)])
      result = described_class.new("203.0.113.42", reg_key.private_key, starter:, nonce: "n0nce").call { it.exec(NetSsh.command("true")) }
      expect([result.ok, result.check.status, result.output]).to eq [true, "pass", nil]
      expect(result.error).to eq 'Net::SSH::Exception: the host refused to run "true"'
      expect(result.host_keys).to eq [ByohFakeRootLogin::FIXTURE_HOST_KEY]
    end

    it "keeps PF2 passing and returns the error when the host disconnects during the block" do
      result = described_class.new("203.0.113.42", reg_key.private_key, starter: fake_root_starter, nonce: "n0nce").call { raise Net::SSH::Disconnect, "connection closed by remote host" }
      expect([result.ok, result.error]).to eq [true, "Net::SSH::Disconnect: connection closed by remote host"]
    end

    it "closes a command that outlives its timeout and returns the timeout as the error" do
      channel = ByohFakeRootLogin::Channel.new(hang: true)
      result = described_class.new("203.0.113.42", reg_key.private_key, starter: fake_root_starter(channels: [channel]), nonce: "n0nce")
        .call { it.exec(NetSsh.command("sleep infinity"), timeout: 0.01) }
      expect([result.ok, result.check.status]).to eq [true, "pass"]
      expect(result.error).to eq 'ByohRootProbe::CommandTimeout: "sleep infinity" did not finish within 0.01 s'
      expect(channel).to be_closed
    end

    it "lets an error outside the connection classes through" do
      probe = described_class.new("203.0.113.42", reg_key.private_key, starter: fake_root_starter, nonce: "n0nce")
      expect { probe.call { raise ArgumentError, "bug" } }.to raise_error(ArgumentError, "bug")
    end
  end

  it "refuses a pin that is not a host public key" do
    expect { described_class.new("203.0.113.42", reg_key.private_key, pinned_host_keys: [host_pub, "ssh-ed25519"]) }
      .to raise_error(ArgumentError, 'not an SSH host public key: "ssh-ed25519"')
  end

  it "refuses an empty pin" do
    expect { described_class.new("203.0.113.42", reg_key.private_key, pinned_host_keys: []) }.to raise_error(ArgumentError, "pinned_host_keys is empty")
  end

  it "uses Net::SSH.start by default" do
    session = instance_double(Net::SSH::Connection::Session)
    expect(session).to receive(:exec!).and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("ubi-pf2-n0nce\n", 0))
    expect(Net::SSH).to receive(:start).with("203.0.113.42", "root", hash_including(key_data: [reg_key.private_key], verify_host_key: :accept_new)).and_yield(session)
    expect(described_class.new("203.0.113.42", reg_key.private_key, nonce: "n0nce").call.ok).to be true
  end

  # The web process undefines Net::SSH.start, and forced autoload then
  # loads every class under lib/, so none may touch it at load time.
  it "loads with every other class in a web process" do
    env = {"PROCESS_TYPE" => "web", "ALLOW_WEB_SSH" => nil, "FORCE_AUTOLOAD" => "1", "RUBYOPT" => nil, "COVERAGE" => nil}
    out, status = Open3.capture2e(env, RbConfig.ruby, "-r./loader", "-e", "print [ByohRootProbe, ByohOperatorSsh::HostKey].size, Net::SSH.respond_to?(:start)")
    expect([out, status.success?]).to eq(["2false", true])
  end
end
