# frozen_string_literal: true

# Settings for QEMU VMs on emulated hosts (accel=tcg): hosts without KVM,
# where QEMU translates guest code in software. See
# docs/byoh/EMULATED_HOSTS.md sections 4.2 and 6.5.
module QemuTcg
  # The translation-block cache per VM, in MiB. QEMU's default is
  # min(1 GiB, host RAM / 8) per VM, and it fills: an idle guest held
  # ~1.15 GiB of anonymous memory with it. 256 MiB kept boot time inside
  # the noise band and cut that to ~350 MiB. The control plane's per-VM
  # overhead (EMULATED_VM_OVERHEAD_MIB) is derived from this value.
  TB_SIZE_MIB = 256

  # Memory the QEMU unit may use beyond guest RAM: the translation cache,
  # QEMU's own heap and device state, and headroom. MemoryMax in the unit
  # is guest RAM plus this, so a runaway QEMU is killed by its own cgroup
  # instead of pushing the host into swap.
  UNIT_OVERHEAD_MIB = 512

  # UEFI firmware from the Ubuntu ovmf package. Cloud images boot with it
  # and with SeaBIOS at the same speed under TCG; UEFI matches the
  # firmware cloud-hypervisor VMs use.
  FIRMWARE = "/usr/share/ovmf/OVMF.fd"

  # -cpu max without the virtualization extensions, so guests do not try
  # nested KVM on an emulator.
  CPU = "max,-svm,-vmx"

  # QEMU's seccomp filter. QEMU runs in the foreground under systemd: with
  # spawn=deny, -daemonize dies with "Bad system call".
  SANDBOX = "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"

  # QEMU documents TCG as no security boundary, so the unit gets the same
  # class of systemd confinement as the vhost-user block backend. The
  # translator needs writable executable memory, so the unit cannot set
  # MemoryDenyWriteExecute. ProtectSystem=strict keeps an escaped QEMU from
  # writing under /var/storage, where root writes by path. Connecting to the
  # vhost-user socket there should still work, because connect() takes no
  # write access to the mount (not yet run under systemd; see
  # docs/byoh/EMULATED_HOSTS.md section 4.2).
  #
  # @system-service lacks seccomp(), which QEMU needs to install its own
  # -sandbox filter, so it is listed explicitly. Other calls outside the set
  # fail with EPERM instead of killing QEMU with SIGSYS.
  def self.hardening(vm_name, mem_gib)
    <<~HARDENING
      NoNewPrivileges=yes
      PrivateTmp=yes
      PrivateMounts=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/vm/#{vm_name}
      ProtectKernelTunables=yes
      ProtectKernelModules=yes
      ProtectKernelLogs=yes
      ProtectControlGroups=yes
      ProtectClock=yes
      ProtectHostname=yes
      ProtectProc=invisible
      ProcSubset=pid
      RestrictNamespaces=yes
      RestrictRealtime=yes
      RestrictSUIDSGID=yes
      RemoveIPC=yes
      LockPersonality=yes
      SystemCallArchitectures=native
      SystemCallFilter=@system-service seccomp
      SystemCallErrorNumber=EPERM
      CapabilityBoundingSet=
      RestrictAddressFamilies=AF_UNIX
      IPAddressDeny=any
      DevicePolicy=closed
      DeviceAllow=/dev/net/tun rw
      UMask=0077
      MemoryMax=#{mem_gib * 1024 + UNIT_OVERHEAD_MIB}M
      TasksMax=4096
    HARDENING
  end

  # The [Service] settings an emulated VM's unit must carry before it may
  # start (check_unit!), each exactly once and with this value: every
  # hardening line, the VM user, its network namespace and the removal of
  # a stale QMP socket. MemoryMax= varies with the VM's memory, so it is
  # checked on its own.
  def self.required_settings(vm_name)
    hardening(vm_name, 0).lines.map(&:chomp).reject { |line| line.start_with?("MemoryMax=") } +
      ["User=#{vm_name}", "Group=#{vm_name}", "NetworkNamespacePath=/var/run/netns/#{vm_name}", "ExecStartPre=/usr/bin/rm -f /vm/#{vm_name}/run/qmp.sock"]
  end

  # The [Unit] keys VmSetup#install_systemd_unit writes. They only order
  # the unit after its storage and dnsmasq units, so any value may repeat.
  UNIT_KEYS = %w[Description After Requires Wants].freeze

  # [Service] keys that carry no confinement: at most once, any value.
  OPTIONAL_SERVICE_KEYS = %w[KillSignal TimeoutStopSec Restart LimitNOFILE LimitMEMLOCK CPUQuota].freeze

  # [Service] keys that must appear exactly once, with a value of this form.
  SHAPED_SERVICE_KEYS = {
    "Slice" => /\A[\w@.-]+\.slice\z/,
    "MemoryMax" => /\A\d+M\z/,
    "ExecStart" => /\Aqemu-system-x86_64\s/,
  }.freeze

  ACCEL = "tcg,thread=multi,tb-size=#{TB_SIZE_MIB}"

  # The unit's assignments as [section, key, value], read the way
  # systemd's parser reads them: comment lines are skipped (also inside a
  # continuation), a line ending in an unescaped backslash continues on the
  # next one with the backslash turned into a space, and key and value lose
  # the whitespace around them. A line that is neither a section header nor
  # an assignment raises.
  def self.assignments(unit, vm_name)
    section = nil
    pending = nil
    result = []
    parse = lambda do |text|
      line = text.strip
      return if line.empty?
      if (header = line[/\A\[(.*)\]\z/, 1])
        section = header
        return
      end
      key, value = line.split("=", 2)
      refuse!(vm_name, "has a line systemd cannot assign, #{line}") unless value
      result << [section, key.strip, value.strip]
    end

    unit.each_line(chomp: true) do |raw|
      next if raw.lstrip.start_with?("#", ";")
      text = pending ? pending + raw : raw
      if text[/\\+\z/].to_s.size.odd?
        pending = text.delete_suffix("\\") + " "
      else
        pending = nil
        parse.call(text)
      end
    end
    parse.call(pending) if pending
    result
  end

  # Raises unless the unit text keeps the confinement QEMU's TCG needs,
  # because TCG is no security boundary (docs/byoh/NO_KVM.md section
  # 8.1). The caller passes `systemctl cat`, the unit together with every
  # drop-in (VmSetup#check_emulated_unit). Only the sections and keys the
  # generated unit has may appear; each required setting appears exactly
  # once with its value, so no drop-in can reset, add to or override one
  # (systemd takes the last value of most keys, and adds up others); a
  # single ExecStart runs QEMU under tcg with its sandbox; and the only
  # ExecStartPre is the generated one, so nothing runs before QEMU outside
  # the confinement.
  def self.check_unit!(unit, vm_name)
    assignments = assignments(unit, vm_name)
    required = required_settings(vm_name).to_h { |line| line.split("=", 2) }
    service_keys = required.keys + SHAPED_SERVICE_KEYS.keys + OPTIONAL_SERVICE_KEYS

    stray = assignments.reject { |section, key, _|
      (section == "Unit" && UNIT_KEYS.include?(key)) || (section == "Service" && service_keys.include?(key))
    }
    refuse!(vm_name, "sets #{stray.map { |section, key, value| "[#{section}] #{key}=#{value}" }.join(", ")}, which it may not carry") unless stray.empty?

    service = assignments.filter_map { |section, key, value| [key, value] if section == "Service" }
    values = service.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

    missing = required.reject { |key, _| values.key?(key) }
    refuse!(vm_name, "lacks #{pairs(missing)}") unless missing.empty?
    conflicting = service.select { |key, value| required.key?(key) && value != required[key] }
    refuse!(vm_name, "overrides #{pairs(conflicting)}") unless conflicting.empty?
    repeated = values.select { |_, list| list.size > 1 }.keys
    refuse!(vm_name, "repeats #{repeated.join(", ")}") unless repeated.empty?

    SHAPED_SERVICE_KEYS.each do |key, shape|
      refuse!(vm_name, "sets no #{key}") unless values.key?(key)
      refuse!(vm_name, "sets #{key}=#{values[key].first}") unless shape.match?(values[key].first)
    end

    args = values["ExecStart"].first.split
    refuse!(vm_name, "lacks -accel #{ACCEL}") unless once?(args, "-accel", ACCEL) && args.none? { |arg| arg.include?("accel=") }
    refuse!(vm_name, "lacks -sandbox #{SANDBOX}") unless once?(args, "-sandbox", SANDBOX)
    nil
  end

  def self.refuse!(vm_name, why)
    fail "emulated unit of #{vm_name} #{why}; refusing to start it"
  end

  def self.pairs(pairs) = pairs.map { |key, value| "#{key}=#{value}" }.join(", ")

  # Whether flag appears exactly once in the QEMU arguments, followed by value.
  def self.once?(args, flag, value)
    at = args.each_index.select { |i| args[i] == flag }
    at.size == 1 && args[at.first + 1] == value
  end
end
