# frozen_string_literal: true

require "etc"
require "json"
require "open3"

# Read-only detection of how this machine can run VMs: the input to the
# virtualization ladder of docs/byoh/NO_KVM.md.
#
# It gathers facts (CPU flags and model, /dev/kvm and what it can do, the
# KVM modules, BIOS evidence in the kernel log, what systemd-detect-virt
# says, DMI strings, and what each fallback tier needs) and sorts the
# machine into one tier:
#
#   kvm                 /dev/kvm answers and has what cloud-hypervisor
#                       needs. "nested" says whether this machine is
#                       itself a VM.
#   pvm                 /dev/kvm comes from the out-of-tree kvm_pvm module
#                       (pagetable-based virtualization, no hardware support).
#   kvm_blocked         The hardware can virtualize but KVM is not usable:
#                       the firmware disabled VT-x/AMD-V, the module is not
#                       loaded, the hypervisor below gives a generic CPU
#                       model, or /dev/kvm lacks a capability.
#   pvm_blocked         No hardware virtualization, but the running kernel
#                       ships kvm_pvm and it is not loaded.
#   none                No hardware virtualization and no PVM.
#   container           This is a container; a data plane must be a VM or
#                       bare metal.
#   unknown_permission  /dev/kvm refused to open (EACCES/EPERM): run the
#                       probe as root before concluding anything.
#   unknown             The facts do not say whether /dev/kvm exists, or
#                       which CPU flags or architecture the machine has
#                       (facts gathered another way, such as a shell
#                       preflight that skipped them). This probe always
#                       gathers them.
#
# classify is a pure function of the facts. The control plane runs it
# again on the facts a host reports (ByohVirtLadder.classify), so an old
# probe on a host never decides for a newer control plane, and facts
# gathered another way (M4's shell preflight) classify the same way.
# A fact that is missing (nil) is unknown and never makes a host L2: the
# tier is then "unknown", or the reason says what was not gathered.
#
# It never changes the machine and needs no gems, and it runs on the
# distribution's Ruby (3.0 on Ubuntu 22.04: no "it" block parameter, no
# hash shorthand), so the control plane
# can pipe it to a host that has no rhizome yet:
#   (cat virt_probe.rb; echo 'exit VirtProbe.main(ARGV)') | ssh root@host ruby - --json
# It names no platform: the control plane matches the DMI strings against
# its data table (lib/byoh_virt_platforms.rb) to give the fix.
#
# With --root DIR the facts come from a directory tree instead of this
# machine: files are read under DIR, and the results of commands and of
# /dev/kvm come from DIR/.virt-probe/ (detect-virt-vm,
# detect-virt-container, kernel-log, kvm.json). Nothing runs and no device
# is opened, so fixture trees classify the same anywhere.
module VirtProbe
  VERSION = 2

  TIERS = %w[kvm pvm kvm_blocked pvm_blocked none container unknown_permission unknown].freeze

  # Lower tiers a host without usable KVM can fall back to, fastest first
  # (docs/byoh/NO_KVM.md section 1).
  FALLBACKS = %w[container pvm emulated].freeze

  KVMIO = 0xAE
  # _IO(KVMIO, 0x00): every KVM since Linux 2.6.22 answers 12.
  KVM_GET_API_VERSION = (KVMIO << 8) | 0x00
  KVM_CREATE_VM = (KVMIO << 8) | 0x01
  KVM_CHECK_EXTENSION = (KVMIO << 8) | 0x03
  KVM_API_VERSION = 12

  # The capabilities cloud-hypervisor v46 checks before it starts a VM on
  # x86_64 (check_required_kvm_extensions in hypervisor/src/kvm/x86_64/mod.rs
  # at tag v46.0), with their numbers from linux/kvm.h.
  REQUIRED_CAPS_X86 = {
    "AdjustClock" => 39,
    "ExtCpuid" => 7,
    "GetTscKhz" => 61,
    "ImmediateExit" => 136,
    "Ioeventfd" => 36,
    "Irqchip" => 0,
    "Irqfd" => 32,
    "IrqRouting" => 25,
    "MpState" => 14,
    "SetIdentityMapAddr" => 37,
    "SetTssAddr" => 4,
    "SplitIrqchip" => 121,
    "TscDeadlineTimer" => 72,
    "UserMemory" => 3,
    "UserNmi" => 22,
    "VcpuEvents" => 41,
    "Xcrs" => 56,
    "Xsave" => 55,
  }.freeze

  CPU_FLAGS = %w[vmx svm hypervisor pdpe1gb].freeze

  MODULES = %w[kvm kvm_intel kvm_amd kvm_pvm].freeze

  NESTED_ON = %w[Y y 1].freeze

  # Never *_serial or product_uuid: they identify the machine and say
  # nothing about virtualization.
  DMI_FIELDS = %w[sys_vendor product_name product_version bios_vendor board_vendor chassis_vendor chassis_asset_tag].freeze

  VULNERABILITIES = %w[meltdown l1tf mds retbleed spec_rstack_overflow].freeze

  # What a hypervisor gives a guest when it passes no host CPU model:
  # QEMU's kvm64/qemu64 and Proxmox's default. Such a guest cannot run
  # cloud-hypervisor's guests even when it sees vmx (docs/byoh/NO_KVM.md
  # section 2.2; the same rule as M4's PF3).
  GENERIC_CPU_MODEL = /Common (?:32-bit )?KVM processor|QEMU Virtual CPU|\b(?:kvm|qemu)(?:32|64)\b/i

  # DMI strings only a hypervisor reports, after systemd-detect-virt's
  # table. A machine with one is a VM even when the hypervisor hides the
  # CPUID bit, so it is never taken for bare metal with VT-x switched off.
  # Cloud vendors with bare-metal products (Amazon EC2 .metal) are not
  # listed.
  VM_DMI = {
    "sys_vendor" => /\A(?:QEMU|VMware|innotek GmbH|Xen|Bochs|Parallels|BHYVE|OpenStack|Red Hat)\b/,
    "product_name" => /\A(?:KVM|VirtualBox|Virtual Machine|VMware|HVM domU|Standard PC|OpenStack|Droplet|vServer)/,
    "bios_vendor" => /\A(?:SeaBIOS|Xen|innotek GmbH|Bochs|Parallels)\b/,
  }.freeze

  # The kernel's lines for VT-x/AMD-V locked off by the firmware: the
  # x86 feature setup ("VMX (outside TXT) disabled by BIOS"), kvm_intel
  # ("VMX not enabled (disabled by BIOS) in MSR_IA32_FEAT_CTL"), kvm_amd
  # ("SVM disabled (by BIOS) in MSR_VM_CR") and older kernels' "kvm:
  # disabled by bios". Other features print the phrase too ("SGX disabled
  # by BIOS"), so it is anchored to virtualization.
  BIOS_DISABLED = /VMX \((?:outside|inside) TXT\) disabled by BIOS|VMX not enabled \((?:disabled )?by BIOS\)|SVM disabled \(by BIOS\)|\bkvm(?:_intel|_amd)?: disabled by bios/i

  MIN_CONTAINER_KERNEL = [5, 12].freeze

  # A command of each package a container host needs
  # (HostTier::CONTAINER_PACKAGES, in that order).
  CONTAINER_COMMANDS = %w[lxc-start lxcfs newuidmap xz setquota cryptsetup mkfs.ext4].freeze

  BIN_DIRS = %w[usr/local/sbin usr/local/bin usr/sbin usr/bin sbin bin].freeze

  OVMF_PATHS = %w[usr/share/OVMF/OVMF_CODE_4M.fd usr/share/OVMF/OVMF_CODE.fd usr/share/ovmf/OVMF.fd usr/share/qemu/OVMF.fd].freeze

  # Longest host-supplied string kept, and the most array or hash entries.
  MAX_STRING = 128
  MAX_ENTRIES = 64

  def self.facts(root: "/", uname: root_uname(root))
    cpuinfo = read(root, "proc/cpuinfo").to_s
    flags = cpuinfo[/^flags\s*:(.*)$/, 1].to_s.split
    modules = MODULES.select { |mod| File.directory?(File.join(root, "sys/module", mod)) }
    kvm = kvm_facts(root)
    log = command_fact(root, "kernel-log") { kernel_log }
    {
      "arch" => uname[:machine],
      "kernel" => uname[:release],
      "euid" => Process.euid,
      "cpu_vendor" => cpuinfo[/^vendor_id\s*:\s*(.*)$/, 1],
      "cpu_model" => cpuinfo[/^model name\s*:\s*(.*)$/, 1],
      "cpu_flags" => CPU_FLAGS & flags,
      "tdp" => tdp(root, cpuinfo),
      **kvm,
      "modules" => modules,
      "nested_param" => nested_param(root),
      "pvm_module_available" => read(root, "lib/modules/#{uname[:release]}/modules.dep").to_s.match?(%r{(?:\A|/)kvm-pvm\.ko}),
      # Left out when the log could not be read, so it stays unknown.
      **(log ? {"bios_log" => bios_line(log)} : {}),
      "virt_vm" => command_fact(root, "detect-virt-vm") { detect_virt("--vm") },
      "virt_container" => command_fact(root, "detect-virt-container") { detect_virt("--container") } || container_marker(root),
      "dmi" => DMI_FIELDS.to_h { |field| [field, read(root, "sys/class/dmi/id/#{field}")&.strip] },
      "secure_boot" => secure_boot(root),
      "lockdown" => read(root, "sys/kernel/security/lockdown").to_s[/\[(\w+)\]/, 1],
      "vulnerabilities" => VULNERABILITIES.to_h { |v| [v, read(root, "sys/devices/system/cpu/vulnerabilities/#{v}")&.strip] },
      "smt" => read(root, "sys/devices/system/cpu/smt/control")&.strip,
      "reboot_required" => File.exist?(File.join(root, "var/run/reboot-required")),
      "cgroup2" => File.exist?(File.join(root, "sys/fs/cgroup/cgroup.controllers")),
      "apparmor" => read(root, "sys/module/apparmor/parameters/enabled")&.strip == "Y",
      "userns_restricted" => read(root, "proc/sys/kernel/apparmor_restrict_unprivileged_userns")&.strip == "1",
      "prjquota" => prjquota(root),
      "commands" => [*CONTAINER_COMMANDS, "qemu-system-x86_64"].to_h { |cmd| [cmd, BIN_DIRS.any? { |dir| File.executable?(File.join(root, dir, cmd)) }] },
      "ovmf" => OVMF_PATHS.any? { |path| File.exist?(File.join(root, path)) },
    }
  end

  # The file's content, or nil when it is missing or unreadable.
  def self.read(root, path)
    File.read(File.join(root, path))
  rescue SystemCallError
    nil
  end

  # uname(2) of this machine, or of the fixture tree (.virt-probe/uname
  # holds "machine release").
  def self.root_uname(root)
    machine, release = read(root, ".virt-probe/uname")&.split if root != "/"
    machine ? {machine: machine.to_s, release: release.to_s} : Etc.uname
  end

  # What a command said: from the fixture tree under a --root other than
  # "/", else from running it.
  def self.command_fact(root, name)
    return yield if root == "/"

    read(root, ".virt-probe/#{name}")&.strip
  end

  # /dev/kvm: whether it is a character device, its mode and group, and
  # what opening it, KVM_GET_API_VERSION, KVM_CREATE_VM and
  # KVM_CHECK_EXTENSION answered.
  def self.kvm_facts(root)
    path = File.join(root, "dev/kvm")
    if root != "/"
      fixture = read(root, ".virt-probe/kvm.json")
      return empty_kvm_facts.merge(fixture ? JSON.parse(fixture) : {})
    end

    return empty_kvm_facts unless File.chardev?(path)

    stat = File.stat(path)
    group = begin
      Etc.getgrgid(stat.gid).name
    rescue ArgumentError
      stat.gid.to_s
    end
    {"dev_kvm" => true, "kvm_dev_mode" => format("%04o", stat.mode & 0o7777), "kvm_dev_group" => group}.merge(kvm_check(path))
  end

  def self.empty_kvm_facts
    {"dev_kvm" => false, "kvm_dev_mode" => nil, "kvm_dev_group" => nil, "kvm_api" => nil, "kvm_errno" => nil, "kvm_create_vm" => nil, "kvm_caps_missing" => nil}
  end

  # Asks KVM what cloud-hypervisor would ask before starting a VM. The VM
  # it creates has no memory and no vCPU, and is closed at once.
  #   kvm_api           12, or the error message
  #   kvm_errno         the errno name of the step that failed
  #   kvm_create_vm     true, the error message, or nil when not reached
  #   kvm_caps_missing  the required capabilities KVM lacks, or nil when
  #                     not reached
  def self.kvm_check(path)
    result = {"kvm_api" => nil, "kvm_errno" => nil, "kvm_create_vm" => nil, "kvm_caps_missing" => nil}
    step = "kvm_api"
    File.open(path, "r+") do |kvm|
      result["kvm_api"] = kvm.ioctl(KVM_GET_API_VERSION)
      next unless result["kvm_api"] == KVM_API_VERSION

      step = "kvm_create_vm"
      IO.for_fd(kvm.ioctl(KVM_CREATE_VM, 0), autoclose: true).close
      result["kvm_create_vm"] = true
      step = "kvm_caps_missing"
      result["kvm_caps_missing"] = REQUIRED_CAPS_X86.reject { |_, cap| kvm.ioctl(KVM_CHECK_EXTENSION, cap) > 0 }.keys
    end
    result
  rescue SystemCallError => e
    result[step] = e.message unless step == "kvm_caps_missing"
    result["kvm_errno"] = e.class.name.split("::").last
    result
  end

  # Whether the CPU has EPT (Intel) or NPT (AMD) for KVM's guests, or nil
  # when nothing says.
  def self.tdp(root, cpuinfo)
    {"kvm_intel" => "ept", "kvm_amd" => "npt"}.each do |mod, param|
      if (value = read(root, "sys/module/#{mod}/parameters/#{param}"))
        return NESTED_ON.include?(value.strip)
      end
    end
    vmx_flags = cpuinfo[/^vmx flags\s*:(.*)$/, 1]
    vmx_flags&.split&.include?("ept")
  end

  # The line of the kernel log that says the firmware switched
  # virtualization off, or nil. The kernel prints it when KVM (or the VMX
  # feature setup) finds VT-x/AMD-V locked off, also on AMD machines whose
  # cpuinfo still lists svm.
  def self.bios_line(log)
    log.each_line.find { |line| BIOS_DISABLED.match?(line) }&.strip
  end

  # This boot's kernel log from journald, else from dmesg, or nil when
  # neither can be read (dmesg_restrict without root).
  def self.kernel_log
    [%w[journalctl -k -b -q --no-pager -o cat], %w[dmesg]].each do |cmd|
      out, status = Open3.capture2(*cmd, stdin_data: "", err: File::NULL)
      return out if status.success? && !out.empty?
    rescue SystemCallError
      next
    end
    nil
  end

  # Secure Boot from efivars (the last byte of SecureBoot-*), or nil on a
  # machine without EFI variables.
  def self.secure_boot(root)
    var = Dir.glob(File.join(root, "sys/firmware/efi/efivars/SecureBoot-*")).first
    var && File.binread(var).bytes.last == 1
  rescue SystemCallError
    nil
  end

  # Whether the filesystem holding /var/storage, where rhizome keeps VM
  # disks and boot images, is mounted with project quotas, which the
  # container tier's "dir" disks need. The mount table decides, so it
  # works before the directory exists.
  def self.prjquota(root)
    target = "/var/storage"
    mounts = read(root, "proc/mounts").to_s.lines.map(&:split).select { |m| m.size >= 4 }
    mount = mounts.select { |m| target == m[1] || target.start_with?(m[1].chomp("/") + "/") }.max_by { |m| m[1].size }
    mount && mount[3].split(",").include?("prjquota")
  end

  # Whether the loaded KVM module lets this machine's own guests run
  # hypervisors, or nil when no hardware KVM module is loaded.
  def self.nested_param(root)
    %w[kvm_intel kvm_amd].each do |mod|
      if (value = read(root, "sys/module/#{mod}/parameters/nested"))
        return NESTED_ON.include?(value.strip)
      end
    end
    nil
  end

  # What systemd-detect-virt prints for the flag: "none", a technology
  # such as "kvm" or "lxc", or nil when it cannot tell.
  def self.detect_virt(flag)
    out, _status = Open3.capture2("systemd-detect-virt", flag, stdin_data: "")
    out = out.strip
    out.empty? ? nil : out
  rescue SystemCallError
    nil
  end

  # The container manager named by the files container runtimes leave,
  # for machines without systemd-detect-virt, or nil.
  def self.container_marker(root)
    if File.exist?(File.join(root, ".dockerenv"))
      "docker"
    elsif File.exist?(File.join(root, "run/.containerenv"))
      "podman"
    else
      read(root, "proc/1/environ").to_s[/(?:\A|\0)container=([^\0]+)/, 1]
    end
  end

  # Host-supplied data made safe to print and store: control characters
  # removed, strings capped at MAX_STRING, arrays and hashes at
  # MAX_ENTRIES entries, nesting at four levels.
  def self.sanitize(value, depth = 0)
    case value
    when String
      value.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/[[:cntrl:]]/, "")[0, MAX_STRING]
    when Array
      (depth < 4) ? value.first(MAX_ENTRIES).map { |v| sanitize(v, depth + 1) } : []
    when Hash
      (depth < 4) ? value.first(MAX_ENTRIES).to_h { |k, v| [sanitize(k.to_s, depth + 1), sanitize(v, depth + 1)] } : {}
    when Integer, Float, true, false, nil
      value
    else
      sanitize(value.to_s, depth)
    end
  end

  def self.permission_error?(facts)
    %w[EACCES EPERM].include?(facts["kvm_errno"]) ||
      (facts["kvm_errno"].nil? && facts["kvm_api"].is_a?(String) && facts["kvm_api"].match?(/\A(?:Permission denied|Operation not permitted)/))
  end

  def self.vm_dmi?(facts)
    dmi = facts["dmi"].is_a?(Hash) ? facts["dmi"] : {}
    VM_DMI.any? { |field, pattern| dmi[field].is_a?(String) && pattern.match?(dmi[field]) }
  end

  # The tier, the reasons for it, and the cause: a stable word the
  # control plane picks the fix by (nil for kvm and container).
  def self.classify(facts)
    flags = Array(facts["cpu_flags"])
    modules = Array(facts["modules"])
    x64 = facts["arch"] == "x86_64"
    vm = facts["virt_vm"]
    hw_virt = (flags & %w[vmx svm]).any?
    generic_cpu = facts["cpu_model"].is_a?(String) && GENERIC_CPU_MODEL.match?(facts["cpu_model"])
    container = facts["virt_container"]

    if container && container != "none"
      return ["container", ["this is a #{container} container"], nil]
    end

    if facts["dev_kvm"] && permission_error?(facts)
      return ["unknown_permission", ["opening /dev/kvm was refused (#{facts["kvm_errno"] || facts["kvm_api"]}); run the probe as root"], "permission"]
    end

    if facts["dev_kvm"] && [nil, KVM_API_VERSION].include?(facts["kvm_api"])
      if modules.include?("kvm_pvm") && (modules & %w[kvm_intel kvm_amd]).empty?
        return ["pvm", ["/dev/kvm is provided by the kvm_pvm module, without hardware virtualization"], nil]
      end

      if generic_cpu
        return ["kvm_blocked", ["the CPU model is the hypervisor's generic \"#{facts["cpu_model"]}\", not the host's"], "cpu_model"]
      end

      if facts["kvm_create_vm"].is_a?(String)
        return ["kvm_blocked", ["/dev/kvm refuses KVM_CREATE_VM (#{facts["kvm_create_vm"]})"], "create_vm"]
      end

      missing = facts["kvm_caps_missing"]
      if x64 && missing.is_a?(Array) && !missing.empty?
        return ["kvm_blocked", ["KVM lacks capabilities cloud-hypervisor requires: #{missing.join(", ")}"], "missing_caps"]
      end

      answer = facts["kvm_api"] ? "answers KVM_GET_API_VERSION #{KVM_API_VERSION}" : "exists (not opened)"
      return ["kvm", ["/dev/kvm #{answer}"], nil]
    end

    if facts["bios_log"]
      return ["kvm_blocked", ["the kernel log says the firmware disabled virtualization: #{facts["bios_log"]}"], "firmware"]
    end

    if generic_cpu
      return ["kvm_blocked", ["the CPU model is the hypervisor's generic \"#{facts["cpu_model"]}\", not the host's"], "cpu_model"]
    end

    if facts["dev_kvm"]
      return ["kvm_blocked", ["/dev/kvm exists but does not answer KVM_GET_API_VERSION (#{facts["kvm_api"]})"], "unresponsive"]
    end

    missing = %w[dev_kvm cpu_flags arch].select { |key| facts[key].nil? }
    unless missing.empty?
      return ["unknown", ["#{missing.join(", ")} not gathered, so whether KVM can work here is unknown"], "not_gathered"]
    end

    if x64 && hw_virt
      mod = flags.include?("vmx") ? "kvm_intel" : "kvm_amd"
      unread = facts.key?("bios_log") ? "" : "; the kernel log was not read, so the firmware may have disabled it"
      return ["kvm_blocked", ["#{mod} is loaded but there is no /dev/kvm#{unread}"], "no_device"] if modules.include?(mod)
      loaded = facts["modules"].nil? ? "was not seen loaded (the loaded modules were not gathered)" : "is not loaded"
      return ["kvm_blocked", ["the CPU has #{(flags & %w[vmx svm]).join(" and ")} but #{mod} #{loaded}#{unread}"], "module"]
    end

    if vm == "none" && !flags.include?("hypervisor") && !vm_dmi?(facts)
      return ["kvm_blocked", [x64 ? "bare metal without the vmx or svm flag: the firmware has VT-x/AMD-V disabled" : "bare metal without /dev/kvm: the kernel was not booted at EL2 or KVM is not loaded"], "firmware"]
    end

    if facts["pvm_module_available"]
      return ["pvm_blocked", ["the running kernel ships kvm_pvm but it is not loaded"], "pvm_module"]
    end

    reason = if vm && vm != "none"
      "this VM (#{vm}) gets no hardware virtualization from its hypervisor"
    elsif vm_dmi?(facts)
      "this is a VM (its DMI names a hypervisor) without hardware virtualization"
    else
      "no /dev/kvm and no hardware virtualization flags"
    end
    ["none", [reason], "no_virt"]
  end

  def self.nested?(facts, tier)
    (tier == "kvm") && (Array(facts["cpu_flags"]).include?("hypervisor") || ![nil, "none"].include?(facts["virt_vm"]) || vm_dmi?(facts))
  end

  # Whether an x86_64 CPU lacks 1G pages, which today's VMs need for
  # their hugepages; nil-safe, so missing flags never count.
  def self.no_1g_pages?(facts)
    facts["arch"] == "x86_64" && facts["cpu_flags"].is_a?(Array) && !facts["cpu_flags"].include?("pdpe1gb")
  end

  # The fallback tiers this machine could run ("possible": the kernel and
  # CPU allow it), those whose userspace is already installed ("ready"),
  # and those whose kernel needs were not gathered ("unchecked"), fastest
  # first. A PVM host offers only pvm, a container nothing, and an L1 host
  # nothing unless it lacks 1G pages (it cannot take today's VMs).
  def self.fallbacks(facts, tier)
    none = {"possible" => [], "ready" => [], "unchecked" => []}
    return none if %w[container unknown_permission unknown].include?(tier)
    return none if tier == "kvm" && !no_1g_pages?(facts)
    return {"possible" => ["pvm"], "ready" => ["pvm"], "unchecked" => []} if tier == "pvm"

    commands = facts["commands"].is_a?(Hash) ? facts["commands"] : {}
    version = facts["kernel"].to_s.scan(/\d+/).first(2).map(&:to_i)
    possible = []
    ready = []
    unchecked = []
    # What HostTier's container prep checks that the probe can see: an
    # x86_64 host with cgroup v2, AppArmor and Linux 5.12 or newer, and
    # every command of its CONTAINER_PACKAGES. Prep still checks systemd,
    # LXC's AppArmor profile and the kernel settings.
    container_needs = [facts["arch"].nil? ? nil : facts["arch"] == "x86_64", facts["cgroup2"], facts["apparmor"], version.empty? ? nil : (version <=> MIN_CONTAINER_KERNEL) >= 0]
    if container_needs.all?
      possible << "container"
      ready << "container" if CONTAINER_COMMANDS.all? { commands[_1] }
    elsif !container_needs.include?(false)
      unchecked << "container"
    end
    possible << "pvm" if tier == "pvm_blocked"
    if facts["arch"] == "x86_64"
      possible << "emulated"
      ready << "emulated" if commands["qemu-system-x86_64"] && facts["ovmf"]
    elsif facts["arch"].nil?
      unchecked << "emulated"
    end
    {"possible" => possible, "ready" => ready, "unchecked" => unchecked}
  end

  def self.report(facts)
    tier, reasons, cause = classify(facts)
    {
      "version" => VERSION,
      "tier" => tier,
      "cause" => cause,
      "reasons" => reasons,
      "nested" => nested?(facts, tier),
      **fallbacks(facts, tier),
      "facts" => facts,
    }
  end

  def self.text(report)
    facts = sanitize(report["facts"])
    dmi = facts["dmi"].values_at("sys_vendor", "product_name").compact.join(" / ")
    kvm = "/dev/kvm=#{facts["dev_kvm"]}"
    kvm += " api=#{facts["kvm_api"].inspect} create_vm=#{facts["kvm_create_vm"].inspect} caps_missing=#{facts["kvm_caps_missing"].inspect}" if facts["dev_kvm"]
    <<~TEXT
      tier: #{report["tier"]}#{" (nested: this machine is itself a VM)" if report["nested"]}
      why: #{sanitize(report["reasons"]).join("; ")}
      cpu: #{facts["arch"]} #{facts["cpu_model"]} flags=#{facts["cpu_flags"].join(",")}
      kvm: #{kvm} modules=#{facts["modules"].join(",")} nested_param=#{facts["nested_param"].inspect}
      virt: vm=#{facts["virt_vm"].inspect} container=#{facts["virt_container"].inspect} dmi=#{dmi.empty? ? "unknown" : dmi}
      fallbacks: possible=#{report["possible"].join(",")} ready=#{report["ready"].join(",")}#{" unchecked=#{report["unchecked"].join(",")}" unless report["unchecked"].empty?}
      For the fix on this platform run bin/byoh-virt probe --main-ip <this host> on the control plane; see docs/byoh/NO_KVM.md.
    TEXT
  end

  USAGE = "usage: virt-probe [--json] [--root DIR]"

  def self.main(argv, out: $stdout, err: $stderr)
    json = false
    root = "/"
    args = argv.dup
    while (arg = args.shift)
      case arg
      when "--json" then json = true
      when "--root" then root = args.shift || (return usage(err))
      else return usage(err)
      end
    end

    report = report(facts(root: root))
    out.puts(json ? JSON.generate(report) : text(report))
    0
  end

  def self.usage(err)
    err.puts USAGE
    2
  end
end
