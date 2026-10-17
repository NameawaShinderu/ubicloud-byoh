# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "../../common/lib/util"
require_relative "virt_probe"

# The PVM host kernel of a pvm-tier host (docs/byoh/NO_KVM.md section
# 6.7), installed the way scripts/byoh/test/real/pvm-go-no-go.sh proved on
# AWS, with these differences:
#
# - GRUB's default never becomes the PVM kernel. The stock kernel stays
#   saved_entry for good, and ubicloud-pvm-boot.service, which runs only
#   on the PVM kernel (pti=off), loads kvm_pvm, checks /dev/kvm and the
#   stock entry, and only then arms the next boot with grub-reboot. So
#   every boot that came up arms the next one (a panic, a maintenance
#   reboot, a stop and start), and one that fails or hangs returns to the
#   stock kernel on the next power cycle.
# - install never runs on the PVM kernel: it reads the stock entry once,
#   on the stock kernel, and keeps it in state.json for every later step.
#   Moving to another PVM kernel build is upgrade, which keeps that pin.
# - state.json is written after every step, with what the step changed
#   recorded before it changes it, so uninstall can undo any partial
#   install. A failure after GRUB was touched un-arms the host first.
#
# Every subcommand reads JSON parameters on stdin and prints one JSON
# object: result "ok" (exit 0), "refused" (exit 2, nothing on the host was
# changed), "failed" (exit 3, the host was changed and un-armed; run
# uninstall) or "error" (exit 1, an unexpected error, from a read-only
# subcommand).
class PvmHostKernel
  class Refused < StandardError; end

  class Failed < StandardError; end

  COMMANDS = %w[preflight install arm disarm status uninstall upgrade].freeze
  EXIT_CODES = {"ok" => 0, "error" => 1, "refused" => 2, "failed" => 3}.freeze

  ENTRY_ID = "ubicloud-pvm"
  STOCK_SUBMENU = "Advanced options for Ubuntu"
  STOCK_SUBMENU_LINE = /^submenu '#{STOCK_SUBMENU}'/

  WORK_DIR = "var/lib/ubicloud/pvm"
  STATE_FILE = "#{WORK_DIR}/state.json"
  LOCK_FILE = "#{WORK_DIR}/lock"
  DEB_FILE = "#{WORK_DIR}/host-kernel.deb"
  GRUB_CFG = "boot/grub/grub.cfg"
  GRUB_DROPIN = "etc/default/grub.d/98-ubicloud-pvm.cfg"
  GRUB_SCRIPT = "etc/grub.d/42_ubicloud_pvm"
  BOOT_UNIT_NAME = "ubicloud-pvm-boot.service"
  BOOT_UNIT = "etc/systemd/system/#{BOOT_UNIT_NAME}"
  BOOT_SCRIPT = "usr/local/sbin/ubicloud-pvm-boot"
  BLACKLIST = "etc/modprobe.d/ubicloud-pvm.conf"
  UDEV_RULE = "etc/udev/rules.d/60-ubicloud-kvm.rules"
  # Every file install writes outside WORK_DIR; uninstall removes them.
  OWNED_FILES = [BOOT_UNIT, BOOT_SCRIPT, GRUB_SCRIPT, GRUB_DROPIN, BLACKLIST, UDEV_RULE].freeze

  # apt and dpkg wait up to 5 minutes for a lock that unattended-upgrades
  # or the host's own patch run holds, instead of failing at once.
  APT_LOCK = ["-o", "DPkg::Lock::Timeout=300"].freeze
  APT_GET = ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", *APT_LOCK].freeze
  APT_MARK = ["apt-mark", *APT_LOCK].freeze

  # The host kernel package is about 100 MiB; the same cap and stall
  # limits as the control plane's ByohArtifactFetch.
  MAX_BYTES = 512 * 1024 * 1024
  CURL = ["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
    "--connect-timeout", "10", "--speed-limit", "1024", "--speed-time", "60",
    "--max-filesize", MAX_BYTES.to_s].freeze

  # dpkg-query's status of a package that is not on the host.
  GONE_STATUSES = ["", "not-installed"].freeze

  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  KVER_FORMAT = /\A[0-9A-Za-z][0-9A-Za-z.+~_-]*\z/
  DRIVER_FORMAT = /\A[0-9A-Za-z_.:-]+\z/

  INSTALL_STEPS = %w[fetch verify grub_pin hold_stock install_deb check_drivers grub_entry boot_unit arm].freeze
  UPGRADE_STEPS = %w[fetch verify install_deb check_drivers grub_entry boot_unit arm].freeze
  # The steps that change nothing on the host: a failure in them refuses.
  READ_ONLY_STEPS = %w[fetch verify].freeze

  # Free space in KiB that an install needs, summed per file system: the
  # download in WORK_DIR, the kernel's modules on / and its vmlinuz and
  # initrd in /boot (the go/no-go's figures).
  SPACE_KIB = {WORK_DIR => 600_000, "" => 1_500_000, "boot" => 300_000}.freeze

  GRUB_TOOLS = %w[grub-editenv grub-reboot grub-set-default update-grub curl dpkg-deb].freeze
  TOOL_DIRS = %w[usr/sbin usr/bin sbin bin].freeze

  # sysfs driver names whose module has another name (Xen's netfront and
  # blkfront register as vif and vbd, usbcore as usb and hub).
  DRIVER_MODULES = {
    "sd" => "sd_mod",
    "sr" => "sr_mod",
    "vbd" => "xen_blkfront",
    "vif" => "xen_netfront",
    "usb" => "usbcore",
    "hub" => "usbcore",
  }.freeze

  # Drivers that may sit on a disk or NIC path without a module name to
  # check: pcieport is a bool option, built into every x86_64 kernel with
  # PCIe, so it is never in modules.builtin.
  UNCHECKED_DRIVERS = %w[pcieport].freeze

  def self.main(argv, stdin: $stdin, out: $stdout, **kw)
    command = argv.first
    unless argv.size == 1 && COMMANDS.include?(command)
      out.puts JSON.generate("result" => "refused", "error" => "usage: install-pvm-host-kernel #{COMMANDS.join("|")}, with JSON parameters on stdin")
      return EXIT_CODES["refused"]
    end

    result = begin
      text = stdin.read.to_s.strip
      params = text.empty? ? {} : JSON.parse(text)
      raise Refused, "the parameters must be a JSON object" unless params.is_a?(Hash)

      new(**kw).public_send(command, params)
    rescue Refused => e
      {"result" => "refused", "error" => e.message}
    rescue JSON::ParserError => e
      {"result" => "refused", "error" => "the parameters are not JSON: #{e.message}"}
    rescue => e
      {"result" => "error", "error" => "#{e.class}: #{e.message}"}
    end
    out.puts JSON.generate(result)
    EXIT_CODES.fetch(result["result"])
  end

  def initialize(root: "/", runner: nil, uid: Process.uid, chardev: File.method(:chardev?), now: -> { Time.now })
    @root = root
    @runner = runner || ->(*argv, expect: [0]) { r(*argv, expect: expect) }
    @uid = uid
    @chardev = chardev
    @now = now
  end

  # Read-only. Every reason this host cannot take the PVM host kernel,
  # and the facts the control plane records (lockdown, meltdown).
  def preflight(params)
    refusals, facts = preflight_checks(params)
    {"result" => refusals.empty? ? "ok" : "refused", "refusals" => refusals, "facts" => facts}
  end

  def install(params)
    @host_deb = host_deb_param(params)
    with_lock do
      state = load_state
      resume = resumable?(state, @host_deb["sha256"])
      refusals, facts = preflight_checks(params)
      return {"result" => "refused", "refusals" => refusals, "facts" => facts} unless refusals.empty?

      state = fresh_state(facts) unless resume
      run_steps(state, INSTALL_STEPS, "steps", params)
    end
  end

  # Arms one boot of the PVM kernel on an installed host. Idempotent.
  def arm(_params)
    with_lock do
      state = load_state
      unless state && %w[armed disarmed].include?(state["state"])
        raise Refused, "no installed PVM kernel to arm (state: #{state_name(state)})"
      end
      raise Refused, stock_problem(state) unless stock_entry_resolves?(state)

      begin
        step_arm(state, {})
        save_state(state)
        {"result" => "ok", "grubenv" => grubenv}
      rescue => e
        unarm(state)
        state["state"] = "disarmed"
        record_result(state, "arm", e)
        {"result" => "failed", "error" => e.message, "grubenv" => grubenv}
      end
    end
  end

  # Takes the PVM kernel out of the boot path: the stock kernel boots
  # next and on every boot after, until arm or a new install.
  def disarm(_params)
    with_lock do
      state = load_state
      return {"result" => "ok", "note" => "no PVM kernel install is recorded here"} unless state && state["stock_entry"]

      run("grub-set-default", state["stock_entry"])
      run("grub-editenv", "-", "unset", "next_entry")
      run("systemctl", "disable", BOOT_UNIT_NAME) if File.exist?(path(BOOT_UNIT))
      if state["state"] == "armed"
        state["state"] = "disarmed"
        save_state(state)
      end
      {"result" => "ok", "grubenv" => grubenv}
    end
  end

  def status(_params)
    state = load_state
    kernel = run("uname", "-r").strip
    {
      "result" => "ok",
      "kernel" => kernel,
      "pti_off" => pti_off?,
      "kvm_pvm_loaded" => kvm_pvm_loaded?,
      "running_pvm" => running_pvm?(state, kernel),
      "grubenv" => grubenv,
      "stock_entry_resolves" => (state && state["stock_entry"]) ? stock_entry_resolves?(state) : nil,
      "dev_kvm" => dev_kvm,
      "boot_unit" => boot_unit_status,
      "state" => state,
    }
  end

  # Undoes any install, complete or partial, from the stock kernel.
  def uninstall(_params)
    with_lock do
      state = load_state
      kernel = run("uname", "-r").strip
      if running_pvm?(state, kernel) || pti_off?
        raise Refused, "the running kernel #{kernel} is the PVM kernel (or has pti=off); reboot to the stock kernel first"
      end

      begin
        uninstall_host(state)
        if state
          state["state"] = "uninstalled"
          state["steps"] = []
          state.delete("upgrade_steps")
          save_state(state)
        end
        {"result" => "ok", "grubenv" => grubenv}
      rescue => e
        record_result(state, "uninstall", e) if state
        {"result" => "failed", "error" => e.message, "fix" => "fix the cause, then run uninstall again"}
      end
    end
  end

  # Installs another PVM kernel build beside the running one and arms
  # one boot of it. UNVERIFIED on a real host. GRUB's default stays the
  # stored stock kernel, so a failed boot returns to stock, not to the
  # previous PVM kernel.
  def upgrade(params)
    @host_deb = host_deb_param(params)
    with_lock do
      state = load_state
      kernel = run("uname", "-r").strip
      raise Refused, "upgrade runs on the installed PVM kernel; install it first" unless state && %w[armed disarmed].include?(state["state"])
      raise Refused, "upgrade runs on the PVM kernel #{state["kver"]}, and this is #{kernel}" unless kernel == state["kver"]
      raise Refused, "the PVM kernel with sha256 #{@host_deb["sha256"]} is already installed" if @host_deb["sha256"] == state["host_deb_sha256"]
      raise Refused, stock_problem(state) unless stock_entry_resolves?(state)
      refusals = space_refusals
      raise Refused, refusals.join("; ") unless refusals.empty?

      state["upgrade_steps"] = []
      run_steps(state, UPGRADE_STEPS, "upgrade_steps", params)
    end
  end

  # The menu entry that boots the PVM kernel once: the stock command line
  # plus pti=off, on this entry only, so the stock kernel (the recovery
  # path) keeps PTI.
  def self.grub_script(kver)
    <<~SH
      #!/bin/sh
      # Written by rhizome's install-pvm-host-kernel: the one GRUB entry with pti=off.
      # grub-mkconfig provides the library and sets grub_probe.
      # shellcheck disable=SC1091,SC2154
      set -e
      . /usr/share/grub/grub-mkconfig_lib
      k=/boot/vmlinuz-#{kver}
      [ -f "$k" ] || exit 0
      echo "menuentry 'Ubuntu, with Linux #{kver} (Ubicloud PVM)' --id #{ENTRY_ID} {"
      prepare_grub_to_access_device "$(${grub_probe} --target=device "$k")" | sed 's/^/  /'
      echo "  linux $(make_system_path_relative_to_its_root "$k") root=UUID=${GRUB_DEVICE_UUID} ro ${GRUB_CMDLINE_LINUX} ${GRUB_CMDLINE_LINUX_DEFAULT} pti=off"
      echo "  initrd $(make_system_path_relative_to_its_root /boot/initrd.img-#{kver})"
      echo "}"
    SH
  end

  def self.boot_unit
    <<~UNIT
      [Unit]
      Description=Ubicloud PVM: load kvm_pvm and arm the next PVM boot
      ConditionKernelCommandLine=pti=off
      After=systemd-udevd.service systemd-modules-load.service local-fs.target
      Wants=systemd-udevd.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/#{BOOT_SCRIPT}

      [Install]
      WantedBy=multi-user.target
    UNIT
  end

  # What ubicloud-pvm-boot.service runs on the PVM kernel. It arms the
  # next PVM boot only once kvm_pvm gave a usable /dev/kvm and the stock
  # entry is still GRUB's default and still boots. Both kernel versions
  # match KVER_FORMAT, so the values need no quoting inside "".
  def self.boot_script(kver:, stock_entry:, stock_kver:)
    title = stock_entry.split(">").last
    <<~SH
      #!/bin/sh
      # Written by rhizome's install-pvm-host-kernel. Each PVM boot that gets
      # this far arms the next one; GRUB's default stays the stock kernel, so
      # a boot that fails or hangs returns to it on the next power cycle.
      set -eu
      fail() { echo "ubicloud-pvm-boot: $*" >&2; exit 1; }
      [ "$(uname -r)" = "#{kver}" ] || fail "running $(uname -r), not the PVM kernel"
      modprobe kvm_pvm
      udevadm trigger --action=change --sysname-match=kvm
      udevadm settle
      [ -c /dev/kvm ] || fail "/dev/kvm is not a character device"
      [ "$(stat -c '%a %G' /dev/kvm)" = "660 kvm" ] || fail "/dev/kvm is $(stat -c '%a %G' /dev/kvm), not 660 kvm"
      grub-editenv list | grep -qxF "saved_entry=#{stock_entry}" || fail "saved_entry is not the stock kernel"
      grep -qF "menuentry '#{title}'" /boot/grub/grub.cfg || fail "grub.cfg has no entry for the stock kernel"
      [ -f "/boot/vmlinuz-#{stock_kver}" ] || fail "the stock kernel is missing from /boot"
      grub-reboot #{ENTRY_ID}
    SH
  end

  BLACKLIST_TEXT = <<~CONF
    # Written by rhizome's install-pvm-host-kernel: kvm_intel and kvm_amd
    # cannot coexist with kvm_pvm.
    blacklist kvm_intel
    blacklist kvm_amd
  CONF

  # A backstop for Ubuntu's own rule, which needs the kvm group to exist.
  UDEV_RULE_TEXT = <<~RULES
    KERNEL=="kvm", GROUP="kvm", MODE="0660"
  RULES

  GRUB_DROPIN_TEXT = <<~CFG
    # Written by rhizome's install-pvm-host-kernel: boot saved_entry, which
    # stays the stock kernel; the PVM kernel boots only through grub-reboot.
    GRUB_DEFAULT=saved
  CFG

  private

  def run(*argv, expect: [0])
    @runner.call(*argv, expect: expect)
  end

  def path(rel)
    File.join(@root, rel)
  end

  def read(rel)
    File.read(path(rel))
  rescue Errno::ENOENT, Errno::EISDIR
    nil
  end

  def write(rel, content, mode: 0o644)
    full = path(rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write("#{full}.tmp", content)
    File.chmod(mode, "#{full}.tmp")
    File.rename("#{full}.tmp", full)
  end

  def with_lock
    FileUtils.mkdir_p(path(WORK_DIR), mode: 0o700)
    File.open(path(LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
      raise Refused, "another install-pvm-host-kernel run holds #{LOCK_FILE}" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      yield
    end
  end

  def load_state
    text = read(STATE_FILE)
    text && JSON.parse(text)
  end

  def save_state(state)
    state["updated_at"] = @now.call.utc.iso8601
    write(STATE_FILE, JSON.pretty_generate(state) + "\n", mode: 0o600)
  end

  def state_name(state)
    state ? state["state"] : "none"
  end

  def host_deb_param(params)
    deb = params["host_deb"]
    raise Refused, "host_deb {url, sha256} is required" unless deb.is_a?(Hash)
    raise Refused, "host_deb url must be an https URL" unless deb["url"].is_a?(String) && deb["url"].match?(%r{\Ahttps://[^\s/]+/\S*\z})
    raise Refused, "host_deb sha256 must be 64 lowercase hex digits" unless SHA256_FORMAT.match?(deb["sha256"].to_s)

    deb
  end

  def unchecked_drivers(params)
    list = params.fetch("unchecked_drivers", [])
    unless list.is_a?(Array) && list.all? { |d| d.is_a?(String) && DRIVER_FORMAT.match?(d) }
      raise Refused, "unchecked_drivers must be a list of sysfs driver names"
    end

    UNCHECKED_DRIVERS + list
  end

  # Whether install continues an earlier run: only an install that
  # finished (armed or disarmed) of the same package, which then re-arms.
  # A failed or interrupted one must be undone first.
  def resumable?(state, sha256)
    case state_name(state)
    when "none", "uninstalled", "refused"
      false
    when "armed", "disarmed"
      return true if state["host_deb_sha256"] == sha256

      raise Refused, "this host already has the PVM kernel #{state["kver"]} (sha256 #{state["host_deb_sha256"]}); use upgrade, or uninstall first"
    else
      raise Refused, "an earlier install stopped in state #{state["state"]} after step #{(state["steps"] || []).last || "none"}; run uninstall first"
    end
  end

  def preflight_checks(params)
    allowed = unchecked_drivers(params)
    refusals = []
    kernel = run("uname", "-r").strip
    machine = run("uname", "-m").strip
    meltdown = read("sys/devices/system/cpu/vulnerabilities/meltdown")&.strip
    facts = {
      "kernel" => kernel,
      "machine" => machine,
      "meltdown" => meltdown,
      "lockdown" => read("sys/kernel/security/lockdown").to_s[/\[(\w+)\]/, 1],
      "secure_boot" => VirtProbe.secure_boot(@root),
    }

    refusals << "run as root" unless @uid == 0
    refusals << "the running kernel's version #{kernel.inspect} has unexpected characters" unless KVER_FORMAT.match?(kernel)
    refusals << "PVM is x86_64 only, this is #{machine}" unless machine == "x86_64"
    refusals << "PVM hosts run Ubuntu 24.04" unless read("etc/os-release").to_s.match?(/^VERSION_ID="?24\.04"?$/)
    refusals.concat(container_refusals)
    if read("proc/cpuinfo").to_s.match?(/^flags\s*:.*\b(?:vmx|svm)\b/)
      refusals << "the CPU has vmx or svm: this host has hardware virtualization; register it as kvm"
    elsif @chardev.call(path("dev/kvm")) && !kvm_pvm_loaded?
      refusals << "/dev/kvm exists on the stock kernel: KVM already works here; register it as kvm"
    end
    refusals << "Secure Boot is on, and the PVM kernel is not signed; turn Secure Boot off" if facts["secure_boot"] == true
    unless meltdown == "Not affected"
      refusals << "this CPU's Meltdown status is #{meltdown ? "\"#{meltdown}\"" : "unknown"}, not \"Not affected\": the PVM kernel runs with pti=off, so a guest could read host memory"
    end
    refusals.concat(grub_refusals)
    refusals << "the running kernel #{kernel} has pti=off; remove it from GRUB_CMDLINE_LINUX* first" if pti_off?
    refusals << "the running kernel #{kernel} is a PVM kernel; install runs only on the stock kernel" if running_pvm?(load_state, kernel)
    stock_pkg = "linux-image-#{kernel}"
    refusals << "the running kernel is not from the package #{stock_pkg}, so it cannot be held" unless dpkg_status(stock_pkg) == "installed"
    facts["stock_entry"] = stock_entry_for(kernel)
    refusals << "grub.cfg has no entry for the running kernel #{kernel}" unless facts["stock_entry"]

    drivers = drivers_in_use
    unmapped = drivers.reject { |d| kernel_has_driver?(kernel, d) || allowed.include?(d) }
    facts["drivers"] = drivers
    facts["unchecked_drivers"] = drivers & allowed
    unless unmapped.empty?
      refusals << "cannot check the PVM kernel for the drivers this host's disks and NICs use: #{unmapped.join(" ")} (no module of that name in #{kernel}); check by hand that the PVM kernel has them, then pass them as unchecked_drivers"
    end
    refusals.concat(space_refusals)
    [refusals, facts]
  end

  def container_refusals
    container = run("systemd-detect-virt", "--container", expect: [0, 1]).strip
    if !container.empty? && container != "none"
      ["this is a container (#{container}); PVM needs a VM or bare metal"]
    elsif File.exist?(path(".dockerenv")) || File.exist?(path("run/.containerenv"))
      ["this is a container (/.dockerenv or /run/.containerenv); PVM needs a VM or bare metal"]
    else
      []
    end
  end

  def grub_refusals
    refusals = []
    ["etc/default/grub", *Dir.glob("etc/default/grub.d/*.cfg", base: @root).sort].each do |rel|
      if read(rel).to_s.match?(/^GRUB_SAVEDEFAULT=["']?true/)
        refusals << "GRUB_SAVEDEFAULT=true in /#{rel} would make a PVM boot the default"
      end
    end
    GRUB_TOOLS.each do |tool|
      refusals << "#{tool} is missing" unless TOOL_DIRS.any? { |dir| File.executable?(path("#{dir}/#{tool}")) }
    end
    refusals << "there is no /#{GRUB_CFG}: GRUB is not the boot loader" unless File.file?(path(GRUB_CFG))
    refusals
  end

  def space_refusals
    mounts = {}
    SPACE_KIB.each do |rel, kib|
      dir = path(rel)
      dir = File.dirname(dir) until File.directory?(dir)
      fields = run("df", "-Pk", dir).lines[1].split
      mount = mounts[fields[5]] ||= {"need" => 0, "avail" => fields[3].to_i, "paths" => []}
      mount["need"] += kib
      mount["paths"] << "/#{rel}"
    end
    mounts.filter_map do |mount, m|
      next if m["avail"] >= m["need"]

      "needs about #{m["need"] / 1024} MiB free on #{mount} (for #{m["paths"].join(" and ")}), has #{m["avail"] / 1024} MiB"
    end
  end

  def pti_off?
    read("proc/cmdline").to_s.split.include?("pti=off")
  end

  def kvm_pvm_loaded?
    File.directory?(path("sys/module/kvm_pvm"))
  end

  def running_pvm?(state, kernel)
    kvm_pvm_loaded? || !!(state && [state["kver"], *state["prev_kvers"]].include?(kernel))
  end

  def dpkg_status(pkg)
    run("dpkg-query", "-W", "-f", "${db:Status-Status}", pkg, expect: [0, 1]).strip
  end

  def apt_mark_has?(list, pkg)
    run(*APT_MARK, list, pkg).split.include?(pkg)
  end

  def grubenv
    run("grub-editenv", "list").lines.grep(/=/).to_h { |line| line.chomp.split("=", 2) }
  end

  # The stock kernel's menu path, as update-grub wrote it.
  def stock_entry_for(kver)
    cfg = read(GRUB_CFG).to_s
    title = "Ubuntu, with Linux #{kver}"
    return nil unless cfg.include?("menuentry '#{title}'")

    cfg.match?(STOCK_SUBMENU_LINE) ? "#{STOCK_SUBMENU}>#{title}" : title
  end

  # Whether saved_entry still boots the stock kernel. It names a menu
  # title, so had the kernel gone GRUB would fall back to entry 0, which
  # is a PVM kernel once one is installed.
  def stock_entry_resolves?(state)
    read(GRUB_CFG).to_s.include?("menuentry '#{state["stock_entry"].split(">").last}'") &&
      File.file?(path("boot/vmlinuz-#{state["stock_kver"]}"))
  end

  def stock_problem(state)
    "the stock entry '#{state["stock_entry"]}' no longer matches an entry with its kernel in /boot; reinstall #{state["stock_pkg"]} before rebooting"
  end

  # The sysfs drivers between each disk and NIC and /sys/devices.
  def drivers_in_use
    devices = File.realpath(path("sys/devices")) + "/"
    found = []
    (Dir.glob(path("sys/class/net/*/device")) + Dir.glob(path("sys/block/*/device"))).each do |dev|
      next unless File.exist?(dev)

      dir = File.realpath(dev)
      while dir.start_with?(devices)
        driver = File.join(dir, "driver")
        found << File.basename(File.readlink(driver)) if File.symlink?(driver)
        dir = File.dirname(dir)
      end
    end
    found.uniq.sort
  rescue Errno::ENOENT
    []
  end

  # Whether kernel kver has the driver, built in or as a module.
  def kernel_has_driver?(kver, driver)
    name = driver.tr("-", "_")
    name = DRIVER_MODULES.fetch(name, name)
    %w[modules.builtin modules.dep].any? do |file|
      read("lib/modules/#{kver}/#{file}").to_s.each_line.any? do |line|
        File.basename(line.split(":", 2).first.strip).sub(/\.ko.*\z/, "").tr("-", "_") == name
      end
    end
  end

  def dev_kvm
    kvm = path("dev/kvm")
    return {"chardev" => false} unless @chardev.call(kvm)

    mode, group = run("stat", "-c", "%a %G", kvm).split
    {"chardev" => true, "mode" => mode, "group" => group}
  end

  def boot_unit_status
    run("systemctl", "show", "-p", "ActiveState", "-p", "Result", "-p", "UnitFileState", BOOT_UNIT_NAME)
      .lines.to_h { |line| line.chomp.split("=", 2) }
  end

  # The state before anything is changed: what uninstall restores.
  def fresh_state(facts)
    stock_kver = facts["kernel"]
    stock_pkg = "linux-image-#{stock_kver}"
    {
      "state" => "installing",
      "steps" => [],
      "host_deb_url" => @host_deb["url"],
      "host_deb_sha256" => @host_deb["sha256"],
      "stock_kver" => stock_kver,
      "stock_entry" => facts["stock_entry"],
      "stock_pkg" => stock_pkg,
      "stock_pkg_held" => apt_mark_has?("showhold", stock_pkg),
      "stock_pkg_auto" => apt_mark_has?("showauto", stock_pkg),
      "orig_saved_entry" => grubenv["saved_entry"],
      "lockdown" => facts["lockdown"],
      "meltdown" => facts["meltdown"],
    }
  end

  def run_steps(state, steps, key, params)
    save_state(state)
    steps.each do |step|
      next if step != "arm" && state[key].include?(step)

      @step = step
      send(:"step_#{step}", state, params)
      state[key] |= [step]
      save_state(state)
    end
    state["last_result"] = {"result" => "ok", "at" => @now.call.utc.iso8601}
    save_state(state)
    {"result" => "ok", "kver" => state["kver"], "stock_entry" => state["stock_entry"], "grubenv" => grubenv}
  rescue => e
    rm_if_exists(path(DEB_FILE))
    if READ_ONLY_STEPS.include?(@step) && state[key].none? { |s| !READ_ONLY_STEPS.include?(s) }
      result = {"result" => "refused", "step" => @step, "error" => e.message}
      if key == "steps"
        state["state"] = "refused"
        state["steps"] = []
      end
    else
      unarm(state)
      state["state"] = "failed"
      result = {"result" => "failed", "step" => @step, "last_step" => state[key].last, "error" => e.message,
                "fix" => "the host was un-armed and boots the stock kernel; run uninstall, then install again"}
    end
    state["last_result"] = result.merge("at" => @now.call.utc.iso8601)
    save_state(state)
    result
  end

  def record_result(state, step, error)
    state["last_result"] = {"result" => "failed", "step" => step, "error" => error.message, "at" => @now.call.utc.iso8601}
    save_state(state)
  end

  # After a failure: the stock kernel is GRUB's default and nothing is
  # armed. Best effort, as the failure may be GRUB's own.
  def unarm(state)
    run("grub-set-default", state["stock_entry"])
    run("grub-editenv", "-", "unset", "next_entry")
  rescue => e
    state["unarm_error"] = e.message
  end

  def step_fetch(_state, _params)
    deb = path(DEB_FILE)
    rm_if_exists(deb)
    run(*CURL, "-o", deb, @host_deb["url"])
    raise Refused, "the download gave no file" unless File.file?(deb)
    raise Refused, "the download is larger than #{MAX_BYTES} bytes" if File.size(deb) > MAX_BYTES
  end

  def step_verify(state, _params)
    deb = path(DEB_FILE)
    got = Digest::SHA256.file(deb).hexdigest
    unless got == @host_deb["sha256"]
      raise Refused, "the host kernel package has sha256 #{got}, not the pinned #{@host_deb["sha256"]}"
    end

    pkg = run("dpkg-deb", "-f", deb, "Package").strip
    kver = pkg[/\Alinux-image-(.+)\z/, 1]
    raise Refused, "the package #{pkg} is not a linux-image package" unless kver && KVER_FORMAT.match?(kver)
    raise Refused, "the package's kernel #{kver} is the stock kernel" if kver == state["stock_kver"]
    raise Refused, "the package's kernel #{kver} is already installed by this tool" if kver == state["kver"] || (state["prev_kvers"] || []).include?(kver)

    if state["pkg"]
      state["prev_pkgs"] = (state["prev_pkgs"] || []) | [state["pkg"]]
      state["prev_kvers"] = (state["prev_kvers"] || []) | [state["kver"]]
    end
    state["pkg"] = pkg
    state["kver"] = kver
    state["host_deb_url"] = @host_deb["url"]
    state["host_deb_sha256"] = @host_deb["sha256"]
  end

  # Pins the running stock kernel as GRUB's saved default before the
  # package's own update-grub runs: the PVM kernel sorts above the stock
  # one and would become entry 0, which GRUB_DEFAULT=0 boots forever.
  def step_grub_pin(state, _params)
    write(GRUB_DROPIN, GRUB_DROPIN_TEXT)
    run("update-grub")
    cfg = read(GRUB_CFG).to_s
    raise Failed, "grub.cfg does not boot ${saved_entry}; check that #{GRUB_DROPIN} is read" unless cfg.include?('set default="${saved_entry}"')
    raise Failed, "grub.cfg cannot clear next_entry (no save_env), so a boot would not be one-shot" unless cfg.include?("save_env next_entry")
    raise Failed, stock_problem(state) unless stock_entry_resolves?(state)

    run("grub-set-default", state["stock_entry"])
    raise Failed, "saved_entry is not '#{state["stock_entry"]}'" unless grubenv["saved_entry"] == state["stock_entry"]
  end

  # Keeps the stock kernel installed while saved_entry names it: on the
  # PVM kernel apt's running-kernel protection covers the PVM one, and an
  # autoremove could take the stock kernel.
  def step_hold_stock(state, _params)
    run(*APT_MARK, "hold", state["stock_pkg"])
    run(*APT_MARK, "manual", state["stock_pkg"])
  end

  def step_install_deb(state, _params)
    run(*APT_GET, "install", "-y", path(DEB_FILE))
    run(*APT_MARK, "hold", state["pkg"])
    rm_if_exists(path(DEB_FILE))
    %W[boot/vmlinuz-#{state["kver"]} boot/initrd.img-#{state["kver"]}].each do |file|
      raise Failed, "/#{file} is missing after the install" unless File.file?(path(file))
    end
    raise Failed, "the package changed saved_entry" unless grubenv["saved_entry"] == state["stock_entry"]
  end

  # The PVM kernel must drive this host's disks and NICs and its root
  # file system. Preflight refused drivers it cannot check but the
  # allowed ones.
  def step_check_drivers(state, _params)
    running = run("uname", "-r").strip
    missing = drivers_in_use.select { |d| kernel_has_driver?(running, d) && !kernel_has_driver?(state["kver"], d) }
    raise Failed, "the PVM kernel #{state["kver"]} lacks drivers this host uses: #{missing.join(" ")}" unless missing.empty?

    rootfs = run("findmnt", "-no", "FSTYPE", "/").strip
    raise Failed, "the PVM kernel #{state["kver"]} lacks the root file system driver #{rootfs}" unless kernel_has_driver?(state["kver"], rootfs)
  end

  def step_grub_entry(state, _params)
    write(GRUB_SCRIPT, self.class.grub_script(state["kver"]), mode: 0o755)
    run("update-grub")
    lines = read(GRUB_CFG).to_s.lines
    pti = lines.each_index.select { |i| lines[i].match?(/^\s*linux\s/) && lines[i].split.include?("pti=off") }
    raise Failed, "pti=off must be on exactly one linux line in grub.cfg, it is on #{pti.size}" unless pti.size == 1

    start = lines.index { |l| l.start_with?("menuentry ") && l.include?("--id #{ENTRY_ID} ") }
    stop = start && (start...lines.size).find { |i| lines[i].start_with?("}") }
    raise Failed, "pti=off is not in the #{ENTRY_ID} entry" unless stop && pti[0] > start && pti[0] < stop
    raise Failed, "the #{ENTRY_ID} entry has no root=UUID" unless lines[pti[0]].match?(%r{vmlinuz-#{Regexp.escape(state["kver"])} root=UUID=[0-9a-fA-F-]{8,} })
  end

  def step_boot_unit(state, _params)
    run("groupadd", "-f", "-r", "kvm")
    write(BLACKLIST, BLACKLIST_TEXT)
    write(UDEV_RULE, UDEV_RULE_TEXT)
    write(BOOT_SCRIPT, self.class.boot_script(kver: state["kver"], stock_entry: state["stock_entry"], stock_kver: state["stock_kver"]), mode: 0o755)
    write(BOOT_UNIT, self.class.boot_unit)
    run("systemctl", "daemon-reload")
  end

  def step_arm(state, _params)
    raise Failed, stock_problem(state) unless stock_entry_resolves?(state)

    run("systemctl", "enable", BOOT_UNIT_NAME)
    run("grub-reboot", ENTRY_ID)
    env = grubenv
    raise Failed, "next_entry is '#{env["next_entry"]}', not #{ENTRY_ID}" unless env["next_entry"] == ENTRY_ID
    raise Failed, "saved_entry is '#{env["saved_entry"]}', not the stock '#{state["stock_entry"]}'" unless env["saved_entry"] == state["stock_entry"]

    state["state"] = "armed"
  end

  def uninstall_host(state)
    run("systemctl", "disable", BOOT_UNIT_NAME) if File.exist?(path(BOOT_UNIT))
    OWNED_FILES.each { |rel| rm_if_exists(path(rel)) }
    run("systemctl", "daemon-reload")
    run("grub-editenv", "-", "unset", "next_entry")
    rm_if_exists(path(DEB_FILE))
    return unless state

    stock_pkg = state["stock_pkg"]
    if dpkg_status(stock_pkg) == "installed"
      run(*APT_MARK, "unhold", stock_pkg) unless state["stock_pkg_held"]
      run(*APT_MARK, "auto", stock_pkg) if state["stock_pkg_auto"]
    end
    [state["pkg"], *state["prev_pkgs"]].compact.each do |pkg|
      next if GONE_STATUSES.include?(dpkg_status(pkg))

      run(*APT_MARK, "unhold", pkg)
      run(*APT_GET, "purge", "-y", pkg)
    end
    run("update-grub")
    if state["orig_saved_entry"]
      run("grub-set-default", state["orig_saved_entry"])
    else
      run("grub-editenv", "-", "unset", "saved_entry")
    end
  end
end
