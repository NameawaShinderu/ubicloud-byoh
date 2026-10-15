# frozen_string_literal: true

require "etc"
require "json"
require "open3"

# Read-only detection of how this machine can run VMs: the input to the
# virtualization ladder of docs/byoh/NO_KVM.md.
#
# It gathers facts (CPU flags, /dev/kvm, the KVM modules, what
# systemd-detect-virt says, DMI strings) and sorts the machine into one
# tier:
#
#   kvm          /dev/kvm answers; cloud-hypervisor runs as on any host.
#                "nested" says whether this machine is itself a VM.
#   pvm          /dev/kvm comes from the out-of-tree kvm_pvm module
#                (pagetable-based virtualization, no hardware support).
#   kvm_blocked  The hardware can virtualize but KVM is not usable: the
#                module is not loaded, the firmware disabled VT-x/AMD-V,
#                or the hypervisor below does not expose it.
#   pvm_blocked  No hardware virtualization, but the running kernel ships
#                kvm_pvm and it is not loaded.
#   none         No hardware virtualization and no PVM.
#   container    This is a container; a data plane must be a VM or bare
#                metal.
#
# It never changes the machine and needs no gems, so the control plane
# can pipe it to a host that has no rhizome yet:
#   (cat virt_probe.rb; echo 'exit VirtProbe.main(ARGV)') | ssh root@host ruby - --json
# It names no platform: the control plane matches the DMI strings against
# its data table (lib/byoh_virt_platforms.rb) to give the fix.
module VirtProbe
  VERSION = 1

  TIERS = %w[kvm pvm kvm_blocked pvm_blocked none container].freeze

  # _IO(KVMIO, 0x00): every KVM since Linux 2.6.22 answers 12.
  KVM_GET_API_VERSION = 0xAE00
  KVM_API_VERSION = 12

  CPU_FLAGS = %w[vmx svm hypervisor pdpe1gb].freeze

  MODULES = %w[kvm kvm_intel kvm_amd kvm_pvm].freeze

  NESTED_ON = %w[Y 1].freeze

  DMI_FIELDS = %w[sys_vendor product_name product_version bios_vendor board_vendor chassis_vendor chassis_asset_tag].freeze

  def self.facts(root: "/", uname: Etc.uname)
    cpuinfo = read(root, "proc/cpuinfo").to_s
    flags = cpuinfo[/^flags\s*:(.*)$/, 1].to_s.split
    kvm_path = File.join(root, "dev/kvm")
    dev_kvm = File.chardev?(kvm_path)
    {
      "arch" => uname[:machine],
      "kernel" => uname[:release],
      "cpu_vendor" => cpuinfo[/^vendor_id\s*:\s*(.*)$/, 1],
      "cpu_model" => cpuinfo[/^model name\s*:\s*(.*)$/, 1],
      "cpu_flags" => CPU_FLAGS & flags,
      "dev_kvm" => dev_kvm,
      "kvm_api" => dev_kvm ? kvm_api_version(kvm_path) : nil,
      "modules" => MODULES.select { |mod| File.directory?(File.join(root, "sys/module", mod)) },
      "nested_param" => nested_param(root),
      "pvm_module_available" => read(root, "lib/modules/#{uname[:release]}/modules.dep").to_s.match?(%r{(?:\A|/)kvm-pvm\.ko}),
      "virt_vm" => detect_virt("--vm"),
      "virt_container" => detect_virt("--container") || container_marker(root),
      "dmi" => DMI_FIELDS.to_h { |field| [field, read(root, "sys/class/dmi/id/#{field}")&.strip] },
    }
  end

  # The file's content, or nil when it is missing or unreadable.
  def self.read(root, path)
    File.read(File.join(root, path))
  rescue SystemCallError
    nil
  end

  # KVM_GET_API_VERSION's answer, or why it failed. A /dev/kvm node that
  # exists but does not answer is a container or a broken module, not KVM.
  def self.kvm_api_version(path)
    File.open(path, "r+") { |kvm| kvm.ioctl(KVM_GET_API_VERSION) }
  rescue SystemCallError, IOError => e
    e.message
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

  # The tier and the reasons for it, from facts.
  def self.classify(facts)
    flags = facts["cpu_flags"]
    modules = facts["modules"]
    x64 = facts["arch"] == "x86_64"
    vm = facts["virt_vm"]
    bare_metal = (vm == "none") && !flags.include?("hypervisor")
    hw_virt = (flags & %w[vmx svm]).any?

    if facts["virt_container"] && facts["virt_container"] != "none"
      return ["container", ["this is a #{facts["virt_container"]} container"]]
    end

    if facts["dev_kvm"]
      unless facts["kvm_api"] == KVM_API_VERSION
        return ["kvm_blocked", ["/dev/kvm exists but does not answer KVM_GET_API_VERSION (#{facts["kvm_api"]})"]]
      end

      if modules.include?("kvm_pvm") && (modules & %w[kvm_intel kvm_amd]).empty?
        return ["pvm", ["/dev/kvm is provided by the kvm_pvm module, without hardware virtualization"]]
      end

      return ["kvm", ["/dev/kvm answers KVM_GET_API_VERSION #{KVM_API_VERSION}"]]
    end

    if x64 && hw_virt
      mod = flags.include?("vmx") ? "kvm_intel" : "kvm_amd"
      reason = modules.include?(mod) ? "#{mod} is loaded but there is no /dev/kvm" : "the CPU has #{(flags & %w[vmx svm]).join(" and ")} but #{mod} is not loaded"
      return ["kvm_blocked", [reason]]
    end

    if bare_metal
      return ["kvm_blocked", [x64 ? "bare metal without the vmx or svm flag: the firmware has VT-x/AMD-V disabled" : "bare metal without /dev/kvm: the kernel was not booted at EL2 or KVM is not loaded"]]
    end

    if facts["pvm_module_available"]
      return ["pvm_blocked", ["the running kernel ships kvm_pvm but it is not loaded"]]
    end

    reason = if vm
      "this is a #{vm} VM whose hypervisor does not expose hardware virtualization"
    else
      "no /dev/kvm and no hardware virtualization flags"
    end
    ["none", [reason]]
  end

  def self.report(facts)
    tier, reasons = classify(facts)
    {
      "version" => VERSION,
      "tier" => tier,
      "reasons" => reasons,
      "nested" => (tier == "kvm") && (facts["cpu_flags"].include?("hypervisor") || ![nil, "none"].include?(facts["virt_vm"])),
      "facts" => facts,
    }
  end

  def self.text(report)
    facts = report["facts"]
    dmi = facts["dmi"].values_at("sys_vendor", "product_name").compact.join(" / ")
    <<~TEXT
      tier: #{report["tier"]}#{" (nested: this machine is itself a VM)" if report["nested"]}
      why: #{report["reasons"].join("; ")}
      cpu: #{facts["arch"]} #{facts["cpu_model"]} flags=#{facts["cpu_flags"].join(",")}
      kvm: /dev/kvm=#{facts["dev_kvm"]} modules=#{facts["modules"].join(",")} nested_param=#{facts["nested_param"].inspect}
      virt: vm=#{facts["virt_vm"].inspect} container=#{facts["virt_container"].inspect} dmi=#{dmi.empty? ? "unknown" : dmi}
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
