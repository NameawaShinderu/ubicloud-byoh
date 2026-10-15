# frozen_string_literal: true

require "etc"
require_relative "qmp_client"
require_relative "vm_path"

# Graceful stop for QEMU VMs on emulated hosts (accel=tcg): presses the
# virtual power button over QMP, like `ch-remote power-button` does for
# cloud-hypervisor VMs.
#
# stop-vm runs as root, but the QMP socket sits in run/, a directory the
# VM user owns, and QEMU runs untrusted guest code under TCG, which QEMU
# does not treat as a security boundary. An escaped guest therefore
# controls run/ and could swap qmp.sock for a symlink to another VM's
# socket. So:
# - the socket must be a socket (not a symlink) owned by the VM user,
#   checked with lstat as root, which refuses the plain cases with a
#   clear message;
# - the connect itself happens in a child that has dropped to the VM
#   user's uid and gid with no supplementary groups, so a link swapped in
#   after the check can only reach sockets the VM user could reach
#   anyway (other VMs' run/ directories are 0700);
# - the QMP session has one deadline and bounded reads (QmpClient), and
#   the parent kills the child if it outlives that deadline.
module EmulatedStop
  QMP_TIMEOUT = 10

  # Extra time the parent gives the child beyond the QMP deadline before
  # killing it.
  CHILD_GRACE = 5

  # Child exit codes.
  REQUESTED = 0
  FAILED = 1
  ALREADY_STOPPED = 3

  def self.handles?(params)
    params["hypervisor"] == "qemu" && params["accel"] == "tcg"
  end

  # stop-vm's branch for emulated VMs. Returns stop-vm's exit status,
  # which is always 0.
  #
  # The soft stop is best effort. The control plane runs stop-vm inside
  # the strand's transaction (Metal::Nexus#soft_stop), and a nonzero exit
  # raises there and rolls back the `stopping` semaphore, so the strand
  # would retry the soft stop forever and never reach its hard_stop
  # (systemctl stop) fallback. An escaped guest controls run/ and the
  # QEMU process, so it could force such a failure at will (a refused
  # socket, a silent QMP, a stopped child). Any failure is therefore only
  # reported, and the stop window ends in hard_stop as usual.
  def self.run(vm_name)
    puts "#{vm_name} is already stopped" if powerdown(vm_name) == :already_stopped
    0
  rescue => e
    warn "stop-vm: #{e.message}; leaving the stop to the hard-stop fallback"
    0
  end

  # Returns :requested once QEMU accepted system_powerdown, or
  # :already_stopped when no QEMU listens on the socket (it is missing,
  # or stale after QEMU exited). Raises on anything else.
  def self.powerdown(vm_name, timeout: QMP_TIMEOUT)
    vp = VmPath.new(vm_name)
    pw = Etc.getpwnam(vm_name)
    fail "VM user #{vm_name} must not be root" if pw.uid == 0 || pw.gid == 0
    return :already_stopped unless socket_present?(vp, pw.uid)

    status = in_child(timeout + CHILD_GRACE) { child(pw.uid, pw.gid, vp.qmp_sock, timeout) }
    case status.exitstatus
    when REQUESTED then :requested
    when ALREADY_STOPPED then :already_stopped
    else fail "QMP powerdown of #{vm_name} failed (#{status})"
    end
  end

  # true when the socket exists and passes the ownership checks, false
  # when it (or run/) does not exist.
  def self.socket_present?(vp, uid)
    run = lstat_or_nil(vp.run_dir)
    return false unless run
    fail "#{vp.run_dir} is not a directory owned by uid #{uid}" unless run.directory? && run.uid == uid

    sock = lstat_or_nil(vp.qmp_sock)
    return false unless sock
    fail "#{vp.qmp_sock} is not a socket" unless sock.socket?
    fail "#{vp.qmp_sock} is owned by uid #{sock.uid}, not #{uid}" unless sock.uid == uid
    true
  end

  def self.lstat_or_nil(path)
    File.lstat(path)
  rescue Errno::ENOENT
    nil
  end

  # Runs the block in a forked child and returns its Process::Status.
  # The child exits with the block's value. A child still running after
  # limit seconds is killed, and that raises.
  def self.in_child(limit)
    pid = Process.fork { Process.exit!(yield) }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if status
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        Process.kill(:KILL, pid)
        Process.waitpid(pid)
        fail "QMP child did not finish within #{limit}s"
      end
      sleep 0.05
    end
  end

  # The body of the child. Returns its exit code.
  def self.child(uid, gid, path, timeout)
    drop_privileges(uid, gid)
    qmp = QmpClient.new(path, timeout: timeout)
    begin
      qmp.execute("system_powerdown")
    ensure
      qmp.close
    end
    REQUESTED
  rescue Errno::ENOENT, Errno::ECONNREFUSED
    ALREADY_STOPPED
  rescue => e
    warn "stop-vm: #{e.class}: #{e.message}"
    FAILED
  end

  # Drops to uid and gid for good: supplementary groups first (that needs
  # root), then real, effective and saved gid, then uid. Verifies the
  # result instead of trusting the calls.
  def self.drop_privileges(uid, gid)
    Process.groups = []
    Process::Sys.setresgid(gid, gid, gid)
    Process::Sys.setresuid(uid, uid, uid)
    ids = [Process::Sys.getuid, Process::Sys.geteuid, Process::Sys.getgid, Process::Sys.getegid]
    fail "could not drop privileges to #{uid}:#{gid}" unless ids == [uid, uid, gid, gid]
  end
end
