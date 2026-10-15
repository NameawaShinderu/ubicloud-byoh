# frozen_string_literal: true

require_relative "../lib/emulated_stop"
require "tmpdir"

RSpec.describe EmulatedStop do
  let(:vm_name) { "vmq00001" }
  let(:vm_uid) { 4242 }
  let(:vm_gid) { 4343 }

  # A VmPath whose run/ is in the test's tmpdir.
  let(:vp) {
    run = File.join(@dir, "run")
    Class.new(VmPath) {
      define_method(:run_dir) { run }
    }.new(vm_name)
  }

  around do |example|
    Dir.mktmpdir("estop") do |dir|
      @dir = dir
      example.run
    end
  end

  def make_run_dir
    Dir.mkdir(vp.run_dir, 0o700)
  end

  # A QMP server on vp.qmp_sock that answers every command with reply
  # (or with an empty return) and records the commands it got.
  def serve_qmp(reply: nil)
    make_run_dir
    commands = Queue.new
    server = UNIXServer.new(vp.qmp_sock)
    thread = Thread.new do
      conn = server.accept
      conn.write(%({"QMP": {"version": {}, "capabilities": []}}\n))
      while (line = conn.gets)
        req = JSON.parse(line)
        commands << req["execute"]
        conn.write(JSON.generate(reply || {"return" => {}, "id" => req["id"]}) + "\n")
      end
    ensure
      conn&.close
      server.close
    end
    [thread, commands]
  end

  # The uid and gid drop is stubbed at the Process::Sys boundary: the
  # specs do not run as root everywhere, and a real drop would make the
  # test's own socket unreachable.
  def stub_privilege_drop(ids = [vm_uid, vm_uid, vm_gid, vm_gid])
    allow(Process).to receive(:groups=).with([])
    allow(Process::Sys).to receive(:setresgid).with(vm_gid, vm_gid, vm_gid)
    allow(Process::Sys).to receive(:setresuid).with(vm_uid, vm_uid, vm_uid)
    allow(Process::Sys).to receive_messages(getuid: ids[0], geteuid: ids[1], getgid: ids[2], getegid: ids[3])
  end

  def stub_user(uid: vm_uid, gid: vm_gid)
    allow(Etc).to receive(:getpwnam).with(vm_name).and_return(Etc::Passwd.new(vm_name, "x", uid, gid))
    allow(VmPath).to receive(:new).with(vm_name).and_return(vp)
  end

  describe ".handles?" do
    it "is true only for QEMU VMs under TCG" do
      expect(described_class.handles?({"hypervisor" => "qemu", "accel" => "tcg"})).to be true
      expect(described_class.handles?({"hypervisor" => "qemu", "accel" => "kvm"})).to be false
      expect(described_class.handles?({"hypervisor" => "qemu"})).to be false
      expect(described_class.handles?({"hypervisor" => "ch", "accel" => "tcg"})).to be false
      expect(described_class.handles?({})).to be false
    end
  end

  describe ".powerdown" do
    it "presses the power button from a child with the VM user's ids" do
      stub_user
      stub_privilege_drop
      allow(described_class).to receive(:socket_present?).with(vp, vm_uid).and_return(true)
      thread, commands = serve_qmp
      expect(described_class.powerdown(vm_name)).to eq(:requested)
      thread.join(5)
      expect(Array.new(commands.size) { commands.pop }).to eq(["qmp_capabilities", "system_powerdown"])
    end

    it "reports a VM that was never started as already stopped" do
      stub_user
      expect(described_class).not_to receive(:in_child)
      expect(described_class.powerdown(vm_name)).to eq(:already_stopped)
    end

    it "reports a VM whose socket is stale as already stopped" do
      stub_user
      stub_privilege_drop
      allow(described_class).to receive(:socket_present?).with(vp, vm_uid).and_return(true)
      make_run_dir
      UNIXServer.new(vp.qmp_sock).close
      expect(described_class.powerdown(vm_name)).to eq(:already_stopped)
    end

    it "raises when QEMU refuses the command" do
      stub_user
      stub_privilege_drop
      allow(described_class).to receive(:socket_present?).with(vp, vm_uid).and_return(true)
      thread, _ = serve_qmp(reply: {"error" => {"class" => "GenericError", "desc" => "no"}})
      expect {
        expect { described_class.powerdown(vm_name) }.to raise_error(RuntimeError, /\AQMP powerdown of vmq00001 failed \(pid \d+ exit 1\)\z/)
      }.to output(/stop-vm: QmpClient::Error: unexpected QMP reply to qmp_capabilities/).to_stderr_from_any_process
      thread.join(5)
    end

    it "refuses a VM user with root's uid or gid" do
      stub_user(uid: 0)
      expect { described_class.powerdown(vm_name) }.to raise_error(RuntimeError, "VM user vmq00001 must not be root")
      stub_user(gid: 0)
      expect { described_class.powerdown(vm_name) }.to raise_error(RuntimeError, "VM user vmq00001 must not be root")
    end
  end

  describe ".socket_present?" do
    let(:uid) { Process.uid }

    it "is false when run/ does not exist" do
      expect(described_class.socket_present?(vp, uid)).to be false
    end

    it "is false when the socket does not exist" do
      make_run_dir
      expect(described_class.socket_present?(vp, uid)).to be false
    end

    it "is true for a socket the VM user owns" do
      make_run_dir
      UNIXServer.new(vp.qmp_sock).close
      expect(described_class.socket_present?(vp, uid)).to be true
    end

    it "refuses run/ when it is a symlink" do
      target = File.join(@dir, "other")
      Dir.mkdir(target)
      File.symlink(target, vp.run_dir)
      expect { described_class.socket_present?(vp, uid) }.to raise_error(RuntimeError, "#{vp.run_dir} is not a directory owned by uid #{uid}")
    end

    it "refuses run/ owned by another user" do
      make_run_dir
      expect { described_class.socket_present?(vp, uid + 1) }.to raise_error(RuntimeError, "#{vp.run_dir} is not a directory owned by uid #{uid + 1}")
    end

    it "refuses a symlinked socket" do
      make_run_dir
      other = File.join(@dir, "other.sock")
      UNIXServer.new(other).close
      File.symlink(other, vp.qmp_sock)
      expect { described_class.socket_present?(vp, uid) }.to raise_error(RuntimeError, "#{vp.qmp_sock} is not a socket")
    end

    it "refuses a regular file" do
      make_run_dir
      File.write(vp.qmp_sock, "")
      expect { described_class.socket_present?(vp, uid) }.to raise_error(RuntimeError, "#{vp.qmp_sock} is not a socket")
    end

    it "refuses a socket owned by another user" do
      make_run_dir
      UNIXServer.new(vp.qmp_sock).close
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(vp.qmp_sock).and_return(instance_double(File::Stat, socket?: true, uid: uid + 1))
      expect { described_class.socket_present?(vp, uid) }.to raise_error(RuntimeError, "#{vp.qmp_sock} is owned by uid #{uid + 1}, not #{uid}")
    end
  end

  describe ".in_child" do
    it "returns the child's exit status" do
      expect(described_class.in_child(5) { 3 }.exitstatus).to eq(3)
    end

    it "kills and reaps a child that outlives the limit" do
      pid = nil
      allow(Process).to receive(:fork).and_wrap_original { |m, &b| pid = m.call(&b) }
      expect { described_class.in_child(0.2) { sleep 30 } }.to raise_error(RuntimeError, "QMP child did not finish within 0.2s")
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end
  end

  describe ".child" do
    it "returns REQUESTED after QEMU accepted the power button" do
      stub_privilege_drop
      thread, commands = serve_qmp
      expect(described_class.child(vm_uid, vm_gid, vp.qmp_sock, 5)).to eq(EmulatedStop::REQUESTED)
      thread.join(5)
      expect(commands.size).to eq(2)
    end

    it "returns ALREADY_STOPPED when the socket is gone" do
      stub_privilege_drop
      expect(described_class.child(vm_uid, vm_gid, vp.qmp_sock, 5)).to eq(EmulatedStop::ALREADY_STOPPED)
    end

    it "returns FAILED when QEMU refuses the command" do
      stub_privilege_drop
      thread, _ = serve_qmp(reply: {"error" => {}})
      expect {
        expect(described_class.child(vm_uid, vm_gid, vp.qmp_sock, 5)).to eq(EmulatedStop::FAILED)
      }.to output("stop-vm: QmpClient::Error: unexpected QMP reply to qmp_capabilities: {\"error\":{}}\n").to_stderr
      thread.join(5)
    end

    it "returns FAILED, before connecting, when the ids did not change" do
      stub_privilege_drop([vm_uid, 0, vm_gid, vm_gid])
      expect(QmpClient).not_to receive(:new)
      expect {
        expect(described_class.child(vm_uid, vm_gid, vp.qmp_sock, 5)).to eq(EmulatedStop::FAILED)
      }.to output("stop-vm: RuntimeError: could not drop privileges to 4242:4343\n").to_stderr
    end

    it "drops supplementary groups, then the gid, then the uid" do
      stub_privilege_drop
      expect(Process).to receive(:groups=).with([]).ordered
      expect(Process::Sys).to receive(:setresgid).with(vm_gid, vm_gid, vm_gid).ordered
      expect(Process::Sys).to receive(:setresuid).with(vm_uid, vm_uid, vm_uid).ordered
      described_class.drop_privileges(vm_uid, vm_gid)
    end
  end
end
