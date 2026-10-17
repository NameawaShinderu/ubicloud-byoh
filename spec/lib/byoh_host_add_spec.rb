# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "byoh_fake_root_login"

RSpec.describe ByohHostAdd do
  include ByohFakeRootLogin

  let(:location) {
    Location.create(name: "byoh-add", display_name: "byoh-add", ui_name: "BYOH add", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:1:2::/48"})
  }
  let(:dir) { Dir.mktmpdir }
  let(:key_dir) { File.join(dir, "keys") }
  let(:calls) { [] }
  let(:starts) { [] }
  let(:replies) { {} }
  let(:now) { [0] }
  let(:steps) { [] }
  let(:input) { StringIO.new }
  let(:tag) { "ubicloud-byoh site=byoh-add ip=203.0.113.10" }
  let(:base) { %w[--site byoh-add --ssh ubuntu@203.0.113.10 --routed-network 10.99.0.0/29,exposure=internal] }
  let(:fixture_keys) { preflight_fixture("base")[/"id":"host_keys","value":(\[[^\]]*\])/, 1].then { JSON.parse(it) } }
  # The fixture's ecdsa key is not a valid key, so only its ed25519 key
  # is pinned.
  let(:pinned) { fixture_keys.filter_map { ByohOperatorSsh::HostKey.parse(it)&.to_s } }
  # A key the host does not have, as a man in the middle presents it.
  let(:mitm_key) { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop" }

  after { FileUtils.rm_rf(dir) }

  before { location }

  # The operator's ssh: answers by the remote command, records each call,
  # and records the host key on the first call as ssh does on
  # accept-new.
  def runner(presented: ByohFakeRootLogin::FIXTURE_HOST_KEY)
    lambda do |argv, stdin|
      calls << [argv.last, stdin]
      kh = argv.find { it.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile=")
      File.write(kh, "203.0.113.10 #{presented}\n") unless File.exist?(kh)
      command = argv.last
      key = replies.keys.find { command.start_with?(it) } || command
      reply = replies.fetch(key) { default_reply(command) }
      reply.respond_to?(:call) ? reply.call : reply
    end
  end

  def default_reply(command)
    case command
    when "sudo -n true" then ["", "", 0]
    when "uname -m; echo \"$SSH_CONNECTION\"" then ["x86_64\n203.0.113.200 51234 203.0.113.10 22\n", "", 0]
    when /\Asudo -n bash -s -- preflight / then [preflight_fixture("base"), "", 0]
    when /\Asudo -n bash -s -- ssh-ed25519/ then ["noise from .bashrc\nubicloud-byoh: installed the key\nubicloud-byoh: sshd already lets root log in with a key; no drop-in written\n", "", 0]
    when /\Asudo -n bash -s -- storage-disk / then ["formatting\nstorage-disk: ok /var/storage/devices/disk1 UUID=u1\n", "", 0]
    when /\Acat / then [fixture_keys.join("\n") + "\n", "", 0]
    when /\Alsblk / then ["SIZE=\"107374182400\" MODEL=\"Amazon EBS \" SERIAL=\"vol0abc\"\n", "", 0]
    else raise "unexpected command #{command}"
    end
  end

  def tty_input(text)
    io = StringIO.new(text)
    io.define_singleton_method(:tty?) { true }
    io
  end

  def cli(*argv, command: "add", runner: self.runner, starter: fake_root_starter(starts:), input: self.input, services: -> {})
    out = StringIO.new
    err = StringIO.new
    clock = -> { now[0] }
    sleeper = lambda do |seconds|
      now[0] += seconds
      step = (steps.size > 1) ? steps.shift : steps.first
      step&.call
    end
    status = described_class.new(out:, err:, input:, runner:, starter:, key_dir:, services:, nonce: "f1x7ure", clock:, sleeper:)
      .run(command, argv)
    [status, out.string, err.string]
  end

  def remote_commands = calls.map(&:first)

  # The remote commands, a script run named by its first argument.
  def kinds = remote_commands.map { it.sub(/\Asudo -n bash -s -- ([\w-]+).*\z/m, 'script \\1') }

  def row(status, id, text) = format("%-5s %-18s %s", status, id, text)

  def host = VmHost.first

  # A host registered at 203.0.113.10, as add leaves it.
  def registered(args = ["10.99.0.0/29,exposure=internal"], images: ["ubuntu-noble"], **)
    key = File.join(dir, "reg")
    File.write(key, SshKey.generate.private_key)
    reg = ByohRegistration.new(main_ip: "203.0.113.10", location:, pools: args, ssh_key_source: key, default_boot_images: images, **)
    reg.adopt_preflight(host_keys: pinned, uplink_ip: "203.0.113.10", gateway: "203.0.113.1")
    VmHost[reg.register!.id]
  end

  describe "add" do
    it "prepares, registers and watches a host until it accepts VMs" do
      steps << -> { host.update(allocation_state: "accepting") }
      status, out, err = cli(*base, "--yes")
      expect([status, err]).to eq [0, ""]

      expect(kinds).to eq ["sudo -n true", "uname -m; echo \"$SSH_CONNECTION\"", "script preflight", "script ssh-ed25519"]
      expect(remote_commands[2]).to start_with "sudo -n bash -s -- preflight --json --nonce f1x7ure --main-ip 203.0.113.10 --images 1 --cp-ip 203.0.113.200"
      install_command, install_stdin = calls[3]
      args = install_command.shellsplit
      expect(args.first(5)).to eq %w[sudo -n bash -s --]
      public_key = args[5]
      expect(args[6..]).to eq [tag, "203.0.113.200"]
      expect(install_stdin).to include "PermitRootLogin prohibit-password"

      expect(starts.map { it.first(2) }).to eq [["203.0.113.10", "root"]]
      expect(starts.dig(0, 2, :verify_host_key)).to eq :always

      expect(host.sshable.host_keys).to eq pinned
      expect(host.sshable.keys.first.public_key).to eq public_key
      expect(host.provider.config["uplink_ip"]).to eq "203.0.113.10"
      expect(host.strand.stack.last["pin_host_keys"]).to be true
      expect(Dir.children(key_dir)).to be_empty

      expect(out).to include row("info", "PF2", "runs once the key is installed; sshd lets root log in with a key")
      expect(out).to match(/^pass +PF17-route /)
      expect(out).to include "Host keys:\n  ssh-ed25519 #{ByohOperatorSsh::HostKey.parse(ByohFakeRootLogin::FIXTURE_HOST_KEY).fingerprint} (presented to ssh)\n"
      expect(out).to include "  - install the registration key in /root/.ssh/authorized_keys, on a line tagged #{tag}"
      expect(out).not_to include "format /dev/disk"
      expect(out).to include "Generated a registration key (#{key_dir}/byoh-add-203.0.113.10)"
      expect(out).to include "  installed the key\n  sshd already lets root log in with a key; no drop-in written\n"
      expect(out).to include row("pass", "PF2", "root@203.0.113.10 logs in")
      expect(out).to include "Registered host #{host.ubid} in site byoh-add.", "host #{host.ubid} is accepting VMs"
      expect(out).to include "unverified: contracts C1-C7", "Host #{host.ubid} accepts VMs."
      expect(File.stat(key_dir).mode & 0o777).to eq 0o700
    end

    it "runs the two phases in separate invocations, keeping the key in between" do
      status, out, _ = cli(*base, "--yes", "--phase", "prepare")
      expect(status).to eq 0
      expect(out).to end_with "Prepared 203.0.113.10 for site byoh-add.\nRegister it with the same arguments and --phase register.\n"
      expect(Dir.children(key_dir).sort).to eq ["byoh-add-203.0.113.10", "byoh-add-203.0.113.10.json"]
      expect(File.stat(File.join(key_dir, "byoh-add-203.0.113.10")).mode & 0o777).to eq 0o600
      expect(VmHost.count).to eq 0

      calls.clear
      status, out, _ = cli("--site", "byoh-add", "--main-ip", "203.0.113.10", "--routed-network", "10.99.0.0/29,exposure=internal", "--phase", "register", "--no-wait",
        runner: nil, starter: nil)
      expect(status).to eq 0
      expect(calls).to be_empty
      expect(out).to eq "Registered host #{host.ubid} in site byoh-add.\n"
      expect(host.sshable.host_keys).to eq pinned
      expect(Dir.children(key_dir)).to be_empty
    end

    it "refuses a register phase that was not prepared, or prepared with other arguments" do
      status, _, err = cli("--site", "byoh-add", "--main-ip", "203.0.113.10", "--phase", "register")
      expect(status).to eq 1
      expect(err).to start_with "! 203.0.113.10 has not been prepared for site byoh-add"

      cli(*base, "--yes", "--phase", "prepare")
      status, _, err = cli(*base, "--phase", "register", "--default-boot-image", "ubuntu-jammy")
      expect([status, err]).to eq [2, "! the arguments differ from those the host was prepared with; prepare it again with these\n"]
      expect(VmHost.count).to eq 0
    end

    it "reuses the key a failed run generated, and installs a given registration key" do
      replies["sudo -n bash -s -- ssh-ed25519"] = ["", "boom\n", 1]
      status, _, err = cli(*base, "--yes")
      expect(status).to eq 1
      first = File.read(File.join(key_dir, "byoh-add-203.0.113.10"))
      expect(err).to include "! the key install exited 1: boom\n  To undo the key install on the host: sudo sed -i '/ # ubicloud-byoh site=byoh-add ip=203\\.0\\.113\\.10$/d' /root/.ssh/authorized_keys;"

      replies.clear
      status, out, _ = cli(*base, "--yes", "--phase", "prepare")
      expect(status).to eq 0
      expect(out).to include "Reusing the registration key an earlier run generated"
      expect(File.read(File.join(key_dir, "byoh-add-203.0.113.10"))).to eq first

      given = File.join(dir, "given")
      key = SshKey.generate
      File.write(given, key.private_key)
      calls.clear
      expect(cli(*base, "--yes", "--phase", "prepare", "--registration-key", given)[0]).to eq 0
      expect(calls[3].first.shellsplit[5]).to eq key.public_key
    end

    it "refuses a registration key that is not an unencrypted Ed25519 key" do
      bad = File.join(dir, "bad")
      File.write(bad, "not a key")
      status, _, err = cli(*base, "--yes", "--registration-key", bad)
      expect(status).to eq 1
      expect(err).to start_with "! #{bad} is not an unencrypted OpenSSH Ed25519 private key"
      expect(calls).to be_empty
    end

    it "explains each way the key install can fail" do
      described_class::INSTALL_FAILURES.each do |code, why|
        replies["sudo -n bash -s -- ssh-ed25519"] = ["", "ubicloud-byoh: the setting comes from /etc/ssh/sshd_config.d/01-harden.conf\n", code]
        status, _, err = cli(*base, "--yes")
        expect(status).to eq 1
        expect(err).to start_with "! #{why}: ubicloud-byoh: the setting comes from /etc/ssh/sshd_config.d/01-harden.conf\n  To undo"
      end
    end

    it "fails when PF2 fails after the key install" do
      status, out, err = cli(*base, "--yes", starter: fake_root_starter(echo_output: "nope", starts:))
      expect(status).to eq 1
      expect(out).to include row("fail", "PF2", "root@203.0.113.10 logs in but")
      expect(err).to start_with "! PF2 failed: the control plane cannot log in to 203.0.113.10 as root with the registration key\n  To undo"
      expect(VmHost.count).to eq 0
    end

    it "formats storage disks after PF2, and shows them in the confirmation" do
      steps << -> { host.update(allocation_state: "accepting") }
      status, out, _ = cli(*base, "--yes", "--storage-disk", "nvme-Amazon_EBS_vol0abc", "--storage-disk", "virtio-data", "--allow-shared-transport")
      expect(status).to eq 0
      expect(out).to include "  - format /dev/disk/by-id/nvme-Amazon_EBS_vol0abc (100.0 GiB, model Amazon EBS, serial vol0abc) as ext4 for VM storage, erasing it\n  - format /dev/disk/by-id/virtio-data"
      expect(out).to include "  storage-disk: ok /var/storage/devices/disk1 UUID=u1\n"
      expect(remote_commands).to include "lsblk -dnbPo SIZE,MODEL,SERIAL /dev/disk/by-id/nvme-Amazon_EBS_vol0abc",
        "sudo -n bash -s -- storage-disk --by-id nvme-Amazon_EBS_vol0abc --allow-shared-transport"
      expect(remote_commands.index { it.include?("storage-disk") }).to be > remote_commands.index { it.include?("ssh-ed25519") }
    end

    it "stops before changing anything when a storage disk is missing, and undoes nothing it did not do" do
      replies["lsblk"] = ["", "lsblk: not a block device\n", 32]
      status, _, err = cli(*base, "--yes", "--storage-disk", "virtio-nope")
      expect([status, err]).to eq [1, "! no disk /dev/disk/by-id/virtio-nope on the host; nothing was changed\n"]
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty
    end

    it "prints the undo line when storage-disk refuses a disk" do
      replies["sudo -n bash -s -- storage-disk"] = ["", "ubicloud-host storage-disk: refused: virtio-data has a partition\n", 1]
      status, _, err = cli(*base, "--yes", "--storage-disk", "virtio-data")
      expect(status).to eq 1
      expect(err).to start_with "! storage-disk virtio-data failed (exit 1): ubicloud-host storage-disk: refused: virtio-data has a partition\n  To undo"
      expect(Dir.children(key_dir)).to eq ["byoh-add-203.0.113.10"]
    end

    it "prints the undo line when ssh fails after the key install" do
      replies["sudo -n bash -s -- ssh-ed25519"] = ["", "Connection reset\n", 255]
      status, _, err = cli(*base, "--yes")
      expect(status).to eq 1
      expect(err).to start_with "! ssh ubuntu@203.0.113.10 failed: Connection reset\n  To undo"
    end

    it "needs passwordless sudo" do
      replies["sudo -n true"] = ["", "sudo: a password is required\n", 1]
      expect(cli(*base, "--yes")).to eq [1, "Checking ubuntu@203.0.113.10 (preflight, read-only)\n",
        "! ubuntu on 203.0.113.10 cannot run sudo without a password; give it passwordless sudo (NOPASSWD), or use a user that has it\n"]
    end

    it "reports an unreachable host" do
      replies["sudo -n true"] = ["", "ssh: connect to host 203.0.113.10 port 22: No route to host\n", 255]
      status, _, err = cli(*base, "--yes")
      expect([status, err]).to eq [1, "! ssh ubuntu@203.0.113.10 failed: ssh: connect to host 203.0.113.10 port 22: No route to host\n"]
    end

    it "refuses a host whose key differs from the one ssh met" do
      status, _, err = cli(*base, "--yes", runner: runner(presented: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop"))
      expect(status).to eq 1
      expect(err).to include "is not one of the host's own keys"
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty
    end

    it "stops on a failed preflight, and goes on with --skip-preflight" do
      replies["sudo -n bash -s -- preflight"] = [preflight_fixture("no-kvm"), "", 0]
      status, out, err = cli(*base, "--yes")
      expect(status).to eq 1
      expect(out).to match(/^fail +PF3 /)
      expect(err).to eq "! preflight failed: fix the checks marked fail, or accept an overridable one with --accept-check; nothing on the host was changed\n"
      expect(Dir.exist?(key_dir)).to be false

      status, _, err = cli(*base, "--yes", "--skip-preflight", "--no-wait")
      expect([status, err]).to eq [0, "warning: preflight failed, but --skip-preflight goes on\n" \
        "note: the host was not probed (preflight was skipped); prep goes on, and Prog::LearnVirt pages there if the host cannot run VMs\n"]
      expect(host.provider.config["uplink_ip"]).to eq "203.0.113.10"
      expect(host.sshable.host_keys).to eq pinned
    end

    it "downgrades an accepted check" do
      replies["sudo -n bash -s -- preflight"] = [preflight_fixture("intel-hybrid"), "", 0]
      status, out, _ = cli(*base, "--yes", "--accept-check", "PF8-hybrid", "--no-wait")
      expect(status).to eq 0
      expect(out).to include row("warn", "PF8-hybrid", "accepted:")
    end

    it "refuses a pool that holds the gateway, which only the host knows" do
      status, out, _ = cli("--site", "byoh-add", "--ssh", "ubuntu@203.0.113.10", "--routed-network", "203.0.113.0/29,exposure=internal", "--yes")
      expect(status).to eq 1
      expect(out).to match(/^fail +PF17 .*203\.0\.113\.1\b/)
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty
    end

    it "reads the host keys itself when preflight output is unreadable, and with --skip-preflight goes on" do
      replies["sudo -n bash -s -- preflight"] = ["garbage", "", 0]
      status, out, _ = cli(*base, "--yes", "--skip-preflight", "--no-wait")
      expect(status).to eq 0
      expect(out).to include row("fail", "preflight", "preflight output unreadable"), row("warn", "PF2", "runs once the key is installed; sshd -T failed")
      expect(remote_commands).to include "cat /etc/ssh/ssh_host_*_key.pub"
      expect(host.provider.config).not_to have_key "uplink_ip"
    end

    it "fails when the preflight script fails or cannot be read" do
      replies["sudo -n bash -s -- preflight"] = ["", "ubicloud-host: internal error: x\n", 3]
      status, out, _ = cli(*base, "--yes")
      expect(status).to eq 1
      expect(out).to include row("fail", "preflight", "ubicloud-host exited 3: ubicloud-host: internal error: x")

      status, _, err = described_class.new(out: StringIO.new, err: (e = StringIO.new), runner:, starter: fake_root_starter, key_dir:, services: -> {},
        host_script: File.join(dir, "missing")).run("add", [*base, "--yes"]).then { [it, nil, e.string] }
      expect(status).to eq 1
      expect(err).to start_with "! cannot read #{dir}/missing on the control plane (Errno::ENOENT)"
    end

    it "refuses when the control plane's services are stopped, before reaching the host" do
      status, _, err = cli(*base, "--yes", services: -> { {"ubicloud-web" => true, "ubicloud-respirate" => false} })
      expect([status, err]).to eq [1, "! PF21: ubicloud-respirate not active, so the host would never be set up; run systemctl start ubicloud.target first\n"]
      expect(calls).to be_empty
    end

    it "prints the notes of the pools" do
      status, _, err = cli("--site", "byoh-add", "--ssh", "ubuntu@203.0.113.10", "--routed-network", "10.99.0.0/29", "--yes", "--no-wait")
      expect(status).to eq 0
      expect(err).to start_with "note: 10.99.0.0/29: no exposure given"
    end

    it "takes --expect-host-key as the confirmation, and refuses a host without that key" do
      other = "SHA256:#{"A" * 43}"
      fingerprint = ByohOperatorSsh::HostKey.parse(ByohFakeRootLogin::FIXTURE_HOST_KEY).fingerprint
      status, _, err = cli(*base, "--expect-host-key", other)
      expect(status).to eq 1
      expect(err).to start_with "! ssh met the host key #{fingerprint} at 203.0.113.10, not the expected #{other}"
      status, _, err = cli(*base, "--expect-host-key", fingerprint, "--expect-host-key", other)
      expect(status).to eq 1
      expect(err).to start_with "! the host does not have the expected host key #{other}"
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty

      expect(cli(*base, "--expect-host-key", fingerprint, "--no-wait")[0]).to eq 0
    end

    it "checks --expect-host-key against the key ssh met, not the keys the host reports" do
      # A man in the middle reports the real host's public keys next to
      # its own, and presents its own to ssh.
      replies["sudo -n bash -s -- preflight"] = [preflight_fixture("base").sub('"id":"host_keys","value":[', "\\0#{mitm_key.to_json},"), "", 0]
      real = ByohOperatorSsh::HostKey.parse(ByohFakeRootLogin::FIXTURE_HOST_KEY).fingerprint
      fake = ByohOperatorSsh::HostKey.parse(mitm_key).fingerprint
      status, out, err = cli(*base, "--expect-host-key", real, runner: runner(presented: mitm_key))
      expect(status).to eq 1
      expect(err).to start_with "! ssh met the host key #{fake} at 203.0.113.10, not the expected #{real}: a man in the middle"
      expect(out).to include "  ssh-ed25519 #{fake} (presented to ssh)\n", "  ssh-ed25519 #{real}\n"
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty
      expect(Dir.exist?(key_dir)).to be false
    end

    it "exits 130 on Ctrl-C, with the undo line once the key may be installed" do
      replies["sudo -n true"] = -> { raise Interrupt }
      expect(cli(*base, "--yes")).to eq [130, "Checking ubuntu@203.0.113.10 (preflight, read-only)\n", "! interrupted\n"]

      replies.clear
      replies["sudo -n bash -s -- storage-disk"] = -> { raise Interrupt }
      status, _, err = cli(*base, "--yes", "--storage-disk", "virtio-data")
      expect(status).to eq 130
      expect(err).to start_with "! interrupted\n  To undo the key install on the host: sudo sed -i"
    end

    it "asks on a terminal, and needs --yes without one" do
      status, _, err = cli(*base)
      expect([status, err]).to eq [1, "! nothing was changed: pass --yes (or --expect-host-key) to confirm without a terminal\n"]

      status, out, err = cli(*base, input: tty_input("no\n"))
      expect([status, err]).to eq [1, "! aborted; nothing on the host was changed\n"]
      expect(out).to end_with "Type yes to go on: "
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty

      expect(cli(*base, "--no-wait", input: tty_input(""))[0]).to eq 1
      expect(cli(*base, "--no-wait", input: tty_input("yes\n"))[0]).to eq 0
    end

    it "refuses a second prepare of the same host while one runs" do
      allow(DB).to receive(:get).and_call_original
      allow(DB).to receive(:get).with(having_attributes(name: :pg_try_advisory_lock)).and_return(false)
      expect(cli(*base, "--yes")).to eq [1, "", "! another byoh-host add is preparing 203.0.113.10; wait for it to finish\n"]
    end

    it "refuses to reach a host under RACK_ENV=test without stand-ins" do
      expect(cli(*base, "--yes", runner: nil)).to eq [1, "", "! refusing to reach a host under RACK_ENV=test; inject the ssh runner and starter\n"]
      expect(cli(*base, "--yes", starter: nil)[0]).to eq 1
      expect(cli(*base, command: "preflight", runner: nil)[0]).to eq 1
    end

    it "reports validation failures before reaching the host" do
      status, _, err = cli("--site", "nowhere", "--ssh", "ubuntu@203.0.113.10", "--yes")
      expect([status, err]).to eq [1, "! validation failed: no location nowhere; create it with bin/byoh-location\n"]
      status, _, err = cli("--site", "byoh-add", "--ssh", "ubuntu@203.0.113.10", "--routed-network", "10.99.0.0/33", "--yes")
      expect(status).to eq 1
      expect(err).to start_with "! validation failed:"
      expect(calls).to be_empty
    end

    it "refuses a pool that holds an explicit --uplink-ip before reaching the host" do
      status, _, err = cli(*base, "--uplink-ip", "10.99.0.3", "--yes")
      expect([status, err]).to eq [1, "! validation failed: 10.99.0.0/29 hands the uplink IP 10.99.0.3 to VMs; declare pools without it, or reserve it\n"]
      expect(calls).to be_empty
      expect(starts).to be_empty
    end
  end

  describe "resume" do
    it "watches a host registered with the same settings instead of registering it again" do
      registered
      steps << -> { host.update(allocation_state: "accepting") }
      status, out, _ = cli(*base, "--yes")
      expect(status).to eq 0
      expect(out).to start_with "Resuming: 203.0.113.10 is already registered as host #{host.ubid} (at Vm::HostNexus.start).\n"
      expect(remote_commands).to eq ["cat /etc/ssh/ssh_host_*_key.pub"]
      expect(VmHost.count).to eq 1
      expect(cli(*base, "--phase", "prepare")).to eq [0, out.lines.first, ""]
      calls.clear
      expect(cli(*base, "--phase", "register", "--no-wait", runner: nil, starter: nil)[0]).to eq 0
      expect(calls).to be_empty
    end

    it "refuses a storage disk on any registered host, without reaching it" do
      registered
      status, _, err = cli(*base, "--storage-disk", "virtio-data", "--yes")
      expect(status).to eq 2
      expect(err).to start_with "! host #{host.ubid} is registered already, and add formats storage disks only before it registers a host"
      expect(calls).to be_empty
    end

    it "resumes a host that accepts VMs, whose stack no longer holds the boot images" do
      registered
      frame = host.strand.stack.last.except("install_os", "default_boot_images", "vhost_block_backend_version")
      host.strand.update(stack: [frame])
      host.update(allocation_state: "accepting")
      status, out, err = cli(*base)
      expect([status, err]).to eq [0, ""]
      expect(out).to include "Host #{host.ubid} accepts VMs."
    end

    it "compares the legacy pool entries of a host registered before M2 as current ones" do
      registered(["5.9.0.0/29,exposure=public"])
      v4, v6 = host.provider.config["routed_networks"]
      legacy = [{"cidr" => v4["cidr"], "source_host_ip" => "203.0.113.10"}, {"cidr" => v6["cidr"]}]
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => legacy)))
      status, _, err = cli(*base.first(4), "--routed-network", "5.9.0.0/29,exposure=public", "--no-wait")
      expect([status, err]).to eq [0, ""]
    end

    it "refuses a resume whose ssh met a key that was not pinned" do
      registered
      replies["cat"] = [[*fixture_keys, mitm_key].join("\n") + "\n", "", 0]
      status, _, err = cli(*base, runner: runner(presented: mitm_key))
      expect(status).to eq 1
      expect(err).to end_with "! ssh met the host key #{ByohOperatorSsh::HostKey.parse(mitm_key).fingerprint} at 203.0.113.10, which is not one pinned at registration: " \
        "a man in the middle, or the address reaches a different machine\n"
    end

    it "refuses a host in another site, of another provider, or being destroyed" do
      other = Location.create(name: "byoh-other", display_name: "byoh-other", ui_name: "o", visible: false, provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {"ula48" => "fd00:9::/48"})
      registered
      status, _, err = cli("--site", other.name, *base.drop(2), "--yes")
      expect([status, err]).to eq [2, "! 203.0.113.10 is registered to host #{host.ubid} in site byoh-add, not byoh-other\n"]

      host.incr_destroy
      expect(cli(*base)).to eq [2, "", "! host #{host.ubid} is being destroyed; add it again once it is gone\n"]
    end

    it "refuses an upstream host at the address" do
      Prog::Vm::HostNexus.assemble("203.0.113.10")
      status, _, err = cli(*base)
      expect(status).to eq 2
      expect(err).to end_with "which is not a BYOH host\n"
    end

    it "shows how the settings differ" do
      registered(["10.99.0.0/29,exposure=internal", "fd00:feed::/64"], server_identifier: "srv-1",
        bmc_config: {"protocol" => "redfish", "endpoint" => "https://10.0.0.9", "username" => "u", "password_env" => "HOME", "verify_ssl" => false})
      status, _, err = cli("--site", "byoh-add", "--ssh", "ubuntu@203.0.113.10", "--routed-network", "10.99.0.8/29,exposure=internal",
        "--uplink-ip", "203.0.113.11", "--default-boot-image", "ubuntu-jammy", "--server-identifier", "srv-2")
      expect(status).to eq 2
      expect(err.lines.map { it.strip.split(":").first }).to eq ["! host #{host.ubid} is registered with other settings", "pools", "IPv6 pool", "BMC",
        "uplink IP", "boot images", "server identifier"]
      expect(err).to match(/IPv6 pool: registered \{.*fd00:feed::\/64.*\}, given none \(a \/64 of the site's ula48\)/)

      expect(cli(*base, "--routed-network", "fd00:feed::/64", "--server-identifier", "srv-1", "--bmc-endpoint", "https://10.0.0.9", "--bmc-user", "u",
        "--bmc-pass-env", "HOME", "--no-wait")[0]).to eq 0
    end

    it "compares the uplink of a pools file and a declared IPv6 pool" do
      file = File.join(dir, "pools.yaml")
      File.write(file, "version: 2\nuplink: eno1\nrouted_networks:\n  - cidr: 10.99.0.0/29\n    exposure: internal\n")
      registered([], pool_file: file)
      status, _, err = cli(*base.first(4), "--routed-network", "10.99.0.0/29,exposure=internal", "--routed-network", "fd00:beef::/64")
      expect(status).to eq 2
      expect(err).to include "IPv6 pool: registered", "uplink: registered \"eno1\", given nil"
    end

    it "accepts a derived /64 only when the site's ula48 holds it" do
      registered
      location.update(byoh_network: {})
      status, _, err = cli(*base)
      expect(status).to eq 2
      expect(err).to include "IPv6 pool: registered"
      host.provider.update(config: Sequel.pg_jsonb(host.provider.config.to_h.merge("routed_networks" => [host.provider.config["routed_networks"].first])))
      expect(cli(*base)[2]).to include "IPv6 pool: registered none"
    end

    it "refuses a reinstalled host" do
      registered
      replies["cat"] = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop\n", "", 0]
      status, _, err = cli(*base, runner: runner(presented: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop"))
      expect(status).to eq 1
      expect(err).to eq "! host #{host.ubid} no longer has the host keys pinned at registration: the host was reinstalled, so destroy host #{host.ubid} and add it again\n"

      host.sshable.update(host_keys: Sequel.pg_array([], :text))
      expect(cli(*base, "--no-wait", runner: runner(presented: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop"))[0]).to eq 0
    end

    it "reports ssh failures" do
      registered
      replies["cat"] = ["", "Connection refused\n", 255]
      expect(cli(*base)).to eq [1, "Resuming: 203.0.113.10 is already registered as host #{host.ubid} (at Vm::HostNexus.start).\n", "! ssh ubuntu@203.0.113.10 failed: Connection refused\n"]
    end
  end

  describe "watch" do
    it "watches a host by ubid or main IP, and checks its pools" do
      registered
      steps << -> { host.update(allocation_state: "accepting") }
      status, out, _ = cli(host.ubid, command: "watch")
      expect(status).to eq 0
      expect(out).to start_with "Watching the bring-up of host #{host.ubid}"
      expect(cli("203.0.113.10", command: "watch")[0]).to eq 0
    end

    it "exits 4 when the pools fail verification" do
      registered
      host.update(net6: "fd00:1:2:3::/64")
      host.update(allocation_state: "accepting")
      status, out, err = cli(host.ubid, command: "watch")
      expect(status).to eq 4
      expect(out).to include "fail: net6"
      expect(err).to include "bin/byoh-pool verify --host #{host.ubid} fails"
    end

    it "exits 3 when respirate does not run or the watch times out" do
      registered
      expect(cli(host.ubid, command: "watch")[0]).to eq 3
      host.strand.update(label: "prep")
      now[0] = 0
      expect(cli(host.ubid, "--timeout", "30", command: "watch")[0]).to eq 3
    end

    it "uses the real clock, and the real service check, by default" do
      out = StringIO.new
      expect(described_class.new(out:, err: StringIO.new, runner:, nonce: "f1x7ure").run("preflight", base)).to eq 0
      expect(out.string).to include row("info", "PF21", "development layout")

      registered
      out = StringIO.new
      expect(described_class.new(out:, err: StringIO.new).run("watch", [host.ubid, "--timeout", "0"])).to eq 3
      expect(out.string).to include "is not accepting VMs after 0 s"
    end

    it "refuses unknown hosts, upstream hosts and wrong arguments" do
      missing = VmHost.generate_ubid.to_s
      expect(cli(missing, command: "watch")).to eq [1, "", "! no host #{missing}\n"]
      upstream = Prog::Vm::HostNexus.assemble("198.51.100.1").subject
      expect(cli(upstream.ubid, command: "watch")).to eq [1, "", "! host #{upstream.ubid} is not a generic (BYOH) host\n"]
      expect(cli(command: "watch")).to eq [2, "", "! invalid argument: watch takes one host\n"]
    end
  end

  describe "virtualization tier" do
    let(:container) { [*base, "--virt-tier", "auto", "--accept-fallback"] }

    before do
      ship_virt_tiers("container")
      replies["sudo -n bash -s -- preflight"] = [preflight_fixture("no-kvm-container"), "", 0]
    end

    def offer_container = location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm container], "acks" => {"container" => []}}))

    it "adds a host without KVM on the lower tier prepare decided, in two phases" do
      offer_container
      status, out, err = cli(*container, "--yes", "--phase", "prepare")
      expect([status, err]).to eq [0, ""]
      expect(out).to match(/^pass +PF3 +container: none \(L3-L5\)/)
      expect(out).to include "Virt tier: container (container (L3, experimental), accepted with --accept-fallback)\n"
      expect(remote_commands.grep(/preflight/).first).to include "--boot-image-url https://cloud-images.ubuntu.com/releases/noble/"

      expect(cli(*base, "--virt-tier", "container", "--accept-fallback", "--phase", "register", runner: nil, starter: nil))
        .to eq [2, "", "! the arguments differ from those the host was prepared with; prepare it again with these\n"]
      status, out, err = cli(*container, "--phase", "register", "--no-wait", runner: nil, starter: nil)
      expect([status, err]).to eq [0, ""]
      expect(out).to include "Registered host #{host.ubid}"
      expect(host.values.slice(:virt_tier, :family)).to eq(virt_tier: "container", family: "container")
      expect(host.strand.stack.last["default_boot_images"]).to eq ["ubuntu-noble-container"]
      expect(DB[:byoh_operator_action].where(command: "register-byoh-host").first[:args]["virt"])
        .to eq("declared" => "auto", "tier" => "container", "probe" => "none", "accepted_fallback" => true)

      # A re-run resumes: the host's tier brings its boot images.
      expect(cli(*container, "--no-wait")[0]).to eq 0
      status, _, err = cli(*base, "--virt-tier", "kvm", "--no-wait")
      expect(status).to eq 2
      expect(err).to include "virt tier: registered container, given kvm"
    end

    it "refuses a lower tier without --accept-fallback before changing anything" do
      offer_container
      status, _, err = cli(*base, "--virt-tier", "container", "--yes")
      expect(status).to eq 1
      expect(err).to start_with("! refused: the probe found none (L3-L5)").and include("Pass --accept-fallback")
      expect(remote_commands.grep(/ssh-ed25519/)).to be_empty
      expect(Dir.exist?(key_dir)).to be false
    end

    it "fails preflight on a lower tier the site does not offer" do
      status, out, _ = cli(*base, "--virt-tier", "container", "--accept-fallback", command: "preflight")
      expect(status).to eq 1
      expect(out).to match(/^fail +PF3-tier +location byoh-add does not offer container hosts$/)
    end

    it "takes an unknown tier as a usage error" do
      expect(cli(*base, "--virt-tier", "tcg")).to eq [2, "", "! invalid argument: --virt-tier tcg is not one of kvm, auto, container, pvm, emulated\n"]
    end

    describe "with --install-pvm-kernel" do
      let(:pvm) { [*base, "--virt-tier", "pvm", "--install-pvm-kernel", "--accept-fallback"] }

      before do
        ship_virt_tiers("container", "pvm")
        replies["sudo -n bash -s -- preflight"] = [preflight_fixture("no-kvm-pvm"), "", 0]
        location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins}))
      end

      it "shows the install among the changes, and registers the host for it in two phases" do
        status, out, err = cli(*pvm, "--yes", "--phase", "prepare")
        expect(status).to eq 0
        expect(err).to start_with "note: pvm: the control plane installs the PVM host kernel pinned by location byoh-add"
        expect(out).to include "Virt tier: pvm (pvm (L4, experimental), accepted with --accept-fallback)\nPVM kernel: installed by the control plane (--install-pvm-kernel), sha256 #{"a" * 64}\n"
        expect(out).to include "  - once registered, install the PVM host kernel the site pins (a third-party build, sha256 #{"a" * 64}) and reboot the host into it once"

        # The flag is one of the arguments prepare and register must share.
        expect(cli(*base, "--virt-tier", "pvm", "--accept-fallback", "--phase", "register", runner: nil, starter: nil))
          .to eq [2, "", "! the arguments differ from those the host was prepared with; prepare it again with these\n"]
        status, _, err = cli(*pvm, "--phase", "register", "--no-wait", runner: nil, starter: nil)
        expect([status, err]).to eq [0, ""]
        expect(ByohPvmHost[host.id].values.slice(:state, :install, :lockdown, :meltdown, :host_deb_sha256))
          .to eq(state: "install_pending", install: true, lockdown: "none", meltdown: "Not affected", host_deb_sha256: "a" * 64)
        expect(DB[:byoh_operator_action].where(command: "register-byoh-host").first[:args]["virt"])
          .to include("install_pvm_kernel" => true, "host_deb_sha256" => "a" * 64, "lockdown" => "none")
        expect(cli(*pvm, "--no-wait")[0]).to eq 0
      end

      it "refuses to register a host prepared for a host-deb pin the site no longer has" do
        expect(cli(*pvm, "--yes", "--phase", "prepare")[0]).to eq 0
        pins = pvm_test_pins.merge("host_deb" => pvm_test_pins["host_deb"].merge("sha256" => "c" * 64))
        location.update(byoh_virt: Sequel.pg_jsonb(location.byoh_virt.to_h.merge("pvm_kernel" => pins)))
        status, _, err = cli(*pvm, "--phase", "register", "--no-wait", runner: nil, starter: nil)
        expect(status).to eq 1
        expect(err).to eq "! validation failed: location byoh-add now pins the PVM host kernel sha256 #{"c" * 64}, not the #{"a" * 64} " \
          "acknowledged for this host with --install-pvm-kernel; run the registration again to acknowledge the current pin (byoh-host add: prepare again)\n"
        expect([VmHost.count, ByohPvmHost.count]).to eq [0, 0]
        expect(DB[:byoh_operator_action].where(command: "register-byoh-host").get(:result)).to start_with "error: location byoh-add now pins"

        # A site that stopped offering pvm pins nothing.
        location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm], "acks" => {}}))
        expect(cli(*pvm, "--phase", "register", "--no-wait", runner: nil, starter: nil)[1..])
          .to eq ["", "! validation failed: location byoh-add now pins the PVM host kernel sha256 (none), not the #{"a" * 64} " \
            "acknowledged for this host with --install-pvm-kernel; run the registration again to acknowledge the current pin (byoh-host add: prepare again)\n"]
      end

      it "refuses to resume a host registered without the flag as one to install" do
        ByohPvmHost.create(vm_host_id: registered(["10.99.0.0/29,exposure=internal"]).id, state: "committed", install: false)
        status, _, err = cli(*pvm, "--no-wait")
        expect(status).to eq 2
        expect(err).to include "PVM kernel: registered without --install-pvm-kernel, given it"
      end

      it "keeps the prepared-arguments digest of every run without the flag" do
        add = described_class.new(out: StringIO.new, err: StringIO.new)
        requested = {location:, routed_networks: []}
        virt = ByohVirtRegistration.new(declared: "auto", accept_fallback: true)
        old = Digest::SHA256.hexdigest(JSON.generate(requested.merge(location: "byoh-add", virt: ["auto", true, true])))
        expect(add.send(:args_digest, requested, virt)).to eq old
        expect(add.send(:args_digest, requested, ByohVirtRegistration.new(declared: "auto", accept_fallback: true, install_pvm_kernel: true))).not_to eq old
      end
    end
  end

  describe "preflight" do
    it "checks the host read-only" do
      status, out, err = cli(*base, command: "preflight")
      expect([status, err]).to eq [0, ""]
      expect(out).to include "Virt tier: kvm\n"
      expect(out).to include row("info", "PF2", "not run (no root key yet); sshd lets root log in with a key")
      expect(out).to end_with "Preflight passed; nothing on the host was changed.\n"
      expect(kinds).to eq ["sudo -n true", "uname -m; echo \"$SSH_CONNECTION\"", "script preflight"]
      expect(VmHost.count).to eq 0
    end

    it "gives sshd -T the loopback address when the login shows no client address" do
      replies["uname"] = ["x86_64\n", "", 0]
      expect(cli(*base, "--yes", "--phase", "prepare")[0]).to eq 0
      expect(remote_commands[2]).not_to include "--cp-ip"
      expect(remote_commands[3].shellsplit.last).to eq "127.0.0.1"
    end

    it "says when sshd does not yet allow root key login" do
      replies["sudo -n bash -s -- preflight"] = [preflight_fixture("base").sub('"permitrootlogin":"without-password"', '"permitrootlogin":"no"'), "", 0]
      expect(cli(*base, command: "preflight")[1]).to include "sshd does not let root log in with a key now (PermitRootLogin no), so host add writes #{described_class::DROP_IN}"
    end

    it "fails on a blocking check, and on ssh errors" do
      replies["sudo -n bash -s -- preflight"] = [preflight_fixture("kvm64-model"), "", 0]
      expect(cli(*base, command: "preflight")[0]).to eq 1
      replies["sudo -n true"] = ["", "Permission denied (publickey).\n", 255]
      expect(cli(*base, command: "preflight")).to eq [1, "", "! ssh ubuntu@203.0.113.10 failed: Permission denied (publickey).\n"]
    end
  end

  describe "options" do
    it "prints the help of add and preflight" do
      status, out, err = cli("--help")
      expect([status, err]).to eq [0, ""]
      expect(out).to start_with "Usage: bin/byoh-host add --site NAME"
      expect(out).to include "--registration-key", "--phase"
      status, out, = cli("-h", command: "preflight")
      expect(status).to eq 0
      expect(out).to start_with "Usage: bin/byoh-host preflight"
      expect(out).not_to include "--registration-key"
    end

    it "refuses bad usage with exit 2" do
      {
        ["extra"] => "! invalid argument: unexpected argument extra",
        ["--ssh", "ubuntu@203.0.113.10"] => "! missing argument: --site is required",
        ["--site", "s"] => "! missing argument: --ssh is required",
        ["--site", "s", "--phase", "register", "--main-ip", "203.0.113.10", "--ssh-port", "x"] => "! invalid argument: --ssh-port x",
        ["--site", "s", "--ssh", "203.0.113.10"] => "! invalid argument: --ssh must be USER@HOST, not 203.0.113.10",
        ["--site", "s", "--ssh", "ubuntu@host.example"] => "! missing argument: --main-ip is required when --ssh does not name an IPv4 address",
        ["--site", "s", "--phase", "register"] => "! missing argument: --main-ip is required when --ssh does not name an IPv4 address",
        %w[--site s --ssh u@203.0.113.10 --storage-disk ../sda] => "! invalid argument: --storage-disk takes a name from /dev/disk/by-id, not ../sda",
        %w[--site s --ssh u@203.0.113.10 --expect-host-key MD5:aa] => "! invalid argument: --expect-host-key takes a SHA256:... fingerprint, not MD5:aa",
        %w[--site s --ssh u@203.0.113.10 --bmc-password secret] => "! --bmc-password would store the BMC password in plain text; pass --bmc-pass-env VAR",
        %w[--site s --ssh u@203.0.113.10 --accept-check PF3] => "! --accept-check PF3: this check cannot be accepted",
        %w[--site s --ssh u@203.0.113.10 --phase later] => "! invalid argument: --phase later",
      }.each do |argv, message|
        status, _, err = cli(*argv)
        expect([status, err.lines.first.to_s.chomp.sub(/; only .*/, "")]).to eq [2, message]
      end
    end

    it "takes the main IP from --main-ip and keeps --bmc-verify-ssl" do
      steps << -> { host.update(allocation_state: "accepting") }
      status, _, _ = cli("--site", "byoh-add", "--ssh", "ubuntu@data-1.example", "--main-ip", "203.0.113.10", "--routed-network", "10.99.0.0/29,exposure=internal",
        "--ssh-port", "2222", "--ssh-key", "/keys/op", "--bmc-endpoint", "https://10.0.0.9", "--bmc-user", "u", "--bmc-pass-env", "HOME", "--bmc-verify-ssl",
        "--bmc-system-id", "1", "--bmc-reset-type", "GracefulRestart", "--server-identifier", "srv", "--timeout", "600", "--yes")
      expect(status).to eq 0
      expect(host.provider.config["bmc"]).to eq({"protocol" => "redfish", "endpoint" => "https://10.0.0.9", "username" => "u", "password_env" => "HOME",
        "verify_ssl" => true, "system_id" => "1", "reset_type" => "GracefulRestart"})
      expect(host.provider.server_identifier).to eq "srv"
    end
  end

  it "keeps its keys under /var/lib/ubicloud on the packaged layout" do
    env = File.join(dir, "env")
    expect(described_class.default_key_dir(env_file: env)).to eq File.expand_path("../../var/byoh-keys", __dir__)
    File.write(env, "")
    expect(described_class.default_key_dir(env_file: env)).to eq "/var/lib/ubicloud/byoh-keys"
  end
end
