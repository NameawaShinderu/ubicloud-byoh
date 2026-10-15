# frozen_string_literal: true

RSpec.describe ByohRootProbe do
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

  it "refuses an empty pin" do
    expect { described_class.new("203.0.113.42", reg_key.private_key, pinned_host_keys: []) }.to raise_error(ArgumentError, "pinned_host_keys is empty")
  end

  it "uses Net::SSH.start by default" do
    expect(described_class::NET_SSH_START).to eq(Net::SSH.method(:start))
    expect(described_class.new("203.0.113.42", reg_key.private_key).instance_variable_get(:@starter)).to equal(described_class::NET_SSH_START)
  end
end
