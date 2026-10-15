# frozen_string_literal: true

RSpec.describe ByohOperatorSsh do
  # SshKey.new(Ed25519::SigningKey.new("\x00" * 32)).public_key, and
  # what ssh-keygen -lf prints for it.
  let(:fixed_key) { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop" }
  let(:fixed_fingerprint) { "SHA256:tAXFyTXI8xtDaujAEcwJslAYc9/6FKcUkd2Lw0xDhPo" }

  let(:calls) { [] }

  # A fake ssh: records each call, writes the presented key to the
  # session's known-hosts file as ssh does on accept-new, and answers
  # from replies (one [stdout, stderr, status] per call, the last one
  # repeated).
  def runner(*replies, presented: fixed_key, host_field: "198.51.100.7")
    lambda do |argv, stdin|
      calls << [argv, stdin]
      kh = argv.find { it.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile=")
      File.write(kh, "#{host_field} #{presented}\n") if presented && !File.exist?(kh)
      (replies.size > 1) ? replies.shift : replies.first
    end
  end

  def session(run = runner(["", "", 0]), **, &)
    described_class.open("ubuntu@198.51.100.7", runner: run, **, &)
  end

  describe ".open" do
    it "runs ssh with a fixed, isolated argument list and removes its known-hosts file" do
      dir = nil
      session(runner(["out", "err", 0])) do |ssh|
        expect(ssh.user).to eq("ubuntu")
        expect(ssh.host).to eq("198.51.100.7")
        expect(ssh.run("uptime")).to eq(ByohOperatorSsh::Result.new(stdout: "out", stderr: "err", status: 0))
        dir = File.dirname(calls.dig(0, 0).find { it.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile="))
        expect(File.stat(dir).mode & 0o777).to eq(0o700)
      end

      argv, stdin = calls.first
      expect(argv).to eq(["ssh", *ByohOperatorSsh::OPTIONS, "-o", "UserKnownHostsFile=#{dir}/kh", "--", "ubuntu@198.51.100.7", "uptime"])
      expect(argv).to include("StrictHostKeyChecking=accept-new", "BatchMode=yes", "IdentityAgent=none", "ControlPath=none")
      expect(argv.first(3)).to eq(["ssh", "-F", "none"])
      expect(stdin).to eq("")
      expect(File.exist?(dir)).to be false
    end

    it "passes the key and the port" do
      session(key: "/keys/op key", port: 2222) { it.run("true") }
      expect(calls.dig(0, 0).last(7)).to eq(["-i", "/keys/op key", "-p", "2222", "--", "ubuntu@198.51.100.7", "true"])
    end

    it "refuses a target that is not USER@HOST or could read as an option" do
      ["198.51.100.7", "-oProxyCommand=x@h", "ubuntu@-oProxyCommand=x", "ubuntu@host name", "@h", nil].each do |target|
        expect { described_class.open(target, runner:) {} }.to raise_error(ArgumentError, /--ssh must be USER@HOST/)
      end
      expect(calls).to be_empty
      expect(described_class.valid_target?("root@fe80::1")).to be true
      expect(described_class.valid_target?("deploy.user@host-1.example.com")).to be true
    end

    it "refuses a port outside 1-65535" do
      [0, 65536, "22"].each do |port|
        expect { session(port:) {} }.to raise_error(ArgumentError, /--ssh-port must be 1-65535/)
      end
    end
  end

  describe "#run" do
    it "raises a transport error when ssh itself fails" do
      session(runner(["", "debug\nssh: connect to host 198.51.100.7 port 22: Connection refused\n", 255], presented: nil)) do |ssh|
        expect { ssh.run("true") }.to raise_error(ByohOperatorSsh::TransportError, "ssh ubuntu@198.51.100.7 failed: debug\nssh: connect to host 198.51.100.7 port 22: Connection refused")
      end
    end

    it "passes any other exit status through" do
      session(runner(["", "nope", 3])) do |ssh|
        result = ssh.run("false")
        expect(result.status).to eq(3)
        expect(result.success?).to be false
      end
    end
  end

  describe "#run_script" do
    it "feeds the script to root bash on stdin with escaped arguments" do
      session { it.run_script("echo hi\n", ["preflight", "--json", "a b;c"]) }
      expect(calls.dig(0, 0).last).to eq("sudo -n bash -s -- preflight --json a\\ b\\;c")
      expect(calls.dig(0, 1)).to eq("echo hi\n")
    end

    it "runs with no arguments" do
      session { it.run_script("true") }
      expect(calls.dig(0, 0).last).to eq("sudo -n bash -s --")
    end
  end

  describe "#sudo?" do
    it "is true when passwordless sudo works" do
      session { expect(it.sudo?).to be true }
      expect(calls.dig(0, 0).last).to eq("sudo -n true")
    end

    it "is false when sudo wants a password" do
      session(runner(["", "sudo: a password is required", 1])) { expect(it.sudo?).to be false }
    end
  end

  describe "#verified_host_keys" do
    let(:other_key) { SshKey.generate.public_key }

    it "returns every key the host reports once the key ssh met is among them" do
      session do |ssh|
        ssh.run("true")
        keys = ssh.verified_host_keys(["#{other_key} root@h\n", "#{fixed_key} root@h", "#{fixed_key} dup"])
        expect(keys.map(&:to_s)).to eq([other_key, fixed_key])
        expect(keys.last.fingerprint).to eq(fixed_fingerprint)
      end
    end

    it "reads hashed known-hosts entries" do
      session(runner(["", "", 0], host_field: "|1|c2FsdA==|aGFzaA==")) do |ssh|
        ssh.run("true")
        expect(ssh.recorded_host_keys.map(&:to_s)).to eq([fixed_key])
      end
    end

    it "refuses when the key ssh met is not one the host reports" do
      session(runner(["", "", 0], presented: other_key)) do |ssh|
        ssh.run("true")
        expect { ssh.verified_host_keys([fixed_key]) }.to raise_error(ByohOperatorSsh::HostKeyError,
          /\Athe key ssh met at 198\.51\.100\.7 \(SHA256:\S+\) is not one of the host's own keys \(#{Regexp.escape(fixed_fingerprint)}\): a man in the middle/)
      end
    end

    it "refuses when the host reports no readable key" do
      session do |ssh|
        ssh.run("true")
        expect { ssh.verified_host_keys(["", "ssh-ed25519", "ssh-ed25519 !!notbase64", "ssh-rsa #{fixed_key.split.last}"]) }
          .to raise_error(ByohOperatorSsh::HostKeyError, "198.51.100.7 reported no readable /etc/ssh/ssh_host_*_key.pub")
        expect { ssh.verified_host_keys(nil) }.to raise_error(ByohOperatorSsh::HostKeyError, /no readable/)
      end
    end

    it "refuses before any connection recorded a key" do
      session do |ssh|
        expect(ssh.recorded_host_keys).to eq([])
        expect { ssh.verified_host_keys([fixed_key]) }.to raise_error(ByohOperatorSsh::HostKeyError, "ssh recorded no host key for 198.51.100.7")
      end
    end

    it "skips comments, markers and unreadable lines in the known-hosts file" do
      run = lambda do |argv, _stdin|
        kh = argv.find { it.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile=")
        File.write(kh, "# comment\n@revoked * #{other_key}\nh garbage\nh\n198.51.100.7 #{fixed_key}\n")
        ["", "", 0]
      end
      session(run) do |ssh|
        ssh.run("true")
        expect(ssh.recorded_host_keys.map(&:to_s)).to eq([fixed_key])
      end
    end
  end

  describe ByohOperatorSsh::HostKey do
    it "parses ed25519, ecdsa and rsa keys and refuses malformed ones" do
      ecdsa = "ecdsa-sha2-nistp256 #{[Net::SSH::Buffer.from(:string, "ecdsa-sha2-nistp256", :string, "nistp256", :string, OpenSSL::PKey::EC.generate("prime256v1").public_key.to_bn.to_s(2)).to_s].pack("m0")}"
      rsa = OpenSSL::PKey::RSA.new(2048)
      rsa_line = "ssh-rsa #{[rsa.public_key.to_blob].pack("m0")}"
      [fixed_key, ecdsa, rsa_line].each { expect(described_class.parse("#{it} comment").to_s).to eq(it) }

      blob = fixed_key.split.last
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("ssh-ed25519 #{blob[0, 20]}")).to be_nil
      expect(described_class.parse("ssh-ed25519 ")).to be_nil
      expect(described_class.parse("ssh-ed25519 AAAA")).to be_nil
      expect(described_class.parse("foo-bar #{[Net::SSH::Buffer.from(:string, "foo-bar").to_s].pack("m0")}")).to be_nil
      expect(described_class.parse("ecdsa-sha2-nistp256 #{[Net::SSH::Buffer.from(:string, "ecdsa-sha2-nistp256", :string, "nistp256", :string, "ab").to_s].pack("m0")}")).to be_nil
    end
  end

  describe "OPEN3_RUNNER" do
    it "returns stdout, stderr and the exit status" do
      expect(ByohOperatorSsh::OPEN3_RUNNER.call(["sh", "-c", "cat; echo e >&2; exit 4"], "in")).to eq(["in", "e\n", 4])
    end

    it "reports a process killed by a signal as a transport failure" do
      expect(ByohOperatorSsh::OPEN3_RUNNER.call(["sh", "-c", "kill -9 $$"], "")).to eq(["", "", 255])
    end
  end
end
