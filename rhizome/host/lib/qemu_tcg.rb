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
end
