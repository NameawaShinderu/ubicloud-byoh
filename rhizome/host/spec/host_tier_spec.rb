# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/host_tier"

RSpec.describe HostTier do
  let(:x64) { ArchClass.new(:x64) }
  let(:arm64) { ArchClass.new(:arm64) }
  let(:dpkg_query) { ["dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", "qemu-system-x86", "ovmf"] }
  let(:accel_help) { ["qemu-system-x86_64", "-accel", "help"] }

  describe ".prep_steps" do
    # The order bin/prep_host.rb ran its steps in before emulated hosts
    # existed (9e22d71ec). KVM hosts must keep it: a change here changes
    # how every cloud-hypervisor host is prepared.
    it "keeps the original step order for kvm" do
      expect(described_class.prep_steps("kvm")).to eq(%i[
        kvm_check
        hostname
        prompt
        motd
        timezone
        download_ch
        download_firmware
        needrestart
        forwarding_sysctls
        blacklist_irdma
        unload_irdma
        image_packages
        prod_packages
        disk_probe_packages
        uplink_mac_pin
        htcat
        spdk
        crypt_swap
        serial_log_cron
      ])
    end

    it "checks first, then runs the kvm steps without the KVM check and the cloud-hypervisor downloads for emulated" do
      expect(described_class.prep_steps("emulated")).to eq(%i[check_arch check_emulator kvm_hint] +
        described_class.prep_steps("kvm") - %i[kvm_check download_ch download_firmware])
    end

    it "checks first, then runs the kvm steps without the KVM check and the cloud-hypervisor downloads, plus the container setup, for container" do
      expect(described_class.prep_steps("container")).to eq(%i[check_container_arch check_container_runtime check_container_sysctls check_idmap_range kvm_hint hostname prompt motd timezone container_host_setup] +
        (described_class.prep_steps("kvm") - %i[kvm_check hostname prompt motd timezone download_ch download_firmware]))
    end

    it "refuses the tiers it cannot prepare yet" do
      expect { described_class.prep_steps("pvm") }.to raise_error(HostTier::Unsupported, "pvm hosts are not supported by this rhizome yet (docs/byoh/NO_KVM.md section 11)")
    end

    it "refuses an unknown tier" do
      expect { described_class.prep_steps("tcg") }.to raise_error(HostTier::Unsupported, 'unknown tier "tcg", expected one of kvm, container, pvm, emulated')
      expect { described_class.prep_steps(nil) }.to raise_error(HostTier::Unsupported, "unknown tier nil, expected one of kvm, container, pvm, emulated")
    end
  end

  describe ".check_arch!" do
    it "accepts x86_64" do
      expect(described_class.check_arch!(arch: x64)).to be_nil
    end

    it "refuses arm64" do
      expect { described_class.check_arch!(arch: arm64) }.to raise_error(HostTier::Unsupported, "emulated hosts must be x86_64; this host is arm64")
    end
  end

  describe ".missing_packages" do
    it "is empty when dpkg lists every package as installed" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 ii \novmf ii \n")
      expect(described_class.missing_packages).to eq([])
    end

    it "lists a package dpkg does not know" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 ii \n")
      expect(described_class.missing_packages).to eq(["ovmf"])
    end

    it "lists a package that was removed with its configuration kept" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 rc \novmf ii \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86"])
    end

    it "takes a package the operator holds" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 hi \novmf ui \n")
      expect(described_class.missing_packages).to eq([])
    end

    it "lists a package marked for removal or purge" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 ri \novmf pi \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end

    it "lists a package that is not fully installed or needs reinstalling" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("qemu-system-x86 iU \novmf iiR\n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end

    it "reports a dpkg-query failure as unsupported" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_raise(CommandFail.new("command failed: dpkg-query", "", "dpkg: error: database is locked"))
      expect { described_class.missing_packages }.to raise_error(HostTier::Unsupported, /\Adpkg-query failed: command failed: dpkg-query\n.*database is locked; run scripts\/byoh\/bootstrap-data-plane.sh --tier emulated/m)
    end

    it "reports a missing dpkg-query as unsupported" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_raise(Errno::ENOENT, "dpkg-query")
      expect { described_class.missing_packages }.to raise_error(HostTier::Unsupported, "dpkg-query failed: No such file or directory - dpkg-query; #{HostTier::INSTALL_HINT}")
    end

    it "does not take a package whose name only starts with a wanted one" do
      expect(described_class).to receive(:_run_command).with(*dpkg_query, expect: [0, 1]).and_return("ovmf-ia32 ii \n")
      expect(described_class.missing_packages).to eq(["qemu-system-x86", "ovmf"])
    end
  end

  describe ".accel_help_ok?" do
    it "is true when QEMU lists tcg" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_return("Accelerators supported in QEMU binary:\ntcg\nkvm\n")
      expect(described_class.accel_help_ok?).to be(true)
    end

    it "is false when QEMU does not list tcg" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_return("Accelerators supported in QEMU binary:\nkvm\n")
      expect(described_class.accel_help_ok?).to be(false)
    end

    it "is false when QEMU fails" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_raise(CommandFail.new("command failed", "", "boom"))
      expect(described_class.accel_help_ok?).to be(false)
    end

    it "is false when QEMU is not installed" do
      expect(described_class).to receive(:_run_command).with(*accel_help).and_raise(Errno::ENOENT)
      expect(described_class.accel_help_ok?).to be(false)
    end
  end

  describe ".check_emulator!" do
    let(:hint) { "run scripts/byoh/bootstrap-data-plane.sh --tier emulated (or apt-get install qemu-system-x86 ovmf)" }

    it "passes when the packages, TCG and the firmware are all there" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(true)
      expect(File).to receive(:file?).with("/usr/share/ovmf/OVMF.fd").and_return(true)
      expect(described_class.check_emulator!).to be_nil
    end

    it "refuses missing packages without installing them" do
      expect(described_class).to receive(:missing_packages).and_return(["qemu-system-x86", "ovmf"])
      expect(described_class).not_to receive(:accel_help_ok?)
      expect { described_class.check_emulator! }.to raise_error(HostTier::Unsupported, "missing packages: qemu-system-x86 ovmf; #{hint}")
    end

    it "refuses a QEMU without TCG" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(false)
      expect { described_class.check_emulator! }.to raise_error(HostTier::Unsupported, "qemu-system-x86_64 -accel help does not list tcg; #{hint}")
    end

    it "refuses a missing firmware file" do
      expect(described_class).to receive(:missing_packages).and_return([])
      expect(described_class).to receive(:accel_help_ok?).and_return(true)
      expect(File).to receive(:file?).with("/fw/OVMF.fd").and_return(false)
      expect { described_class.check_emulator!(firmware: "/fw/OVMF.fd") }.to raise_error(HostTier::Unsupported, "/fw/OVMF.fd is missing; #{hint}")
    end
  end

  describe ".kvm_hint" do
    it "suggests cloud-hypervisor when KVM works" do
      expect(described_class.kvm_hint(kvm_problem: nil)).to eq("KVM is available; register the host again as kvm (bin/register-byoh-host --virt-tier kvm) to use cloud-hypervisor")
    end

    it "says nothing when KVM is unavailable" do
      expect(described_class.kvm_hint(kvm_problem: "/dev/kvm is not a character device")).to be_nil
    end

    it "asks KvmCheck by default" do
      expect(KvmCheck).to receive(:problem).and_return(nil)
      expect(described_class.kvm_hint).to eq(HostTier::KVM_AVAILABLE_HINT)
    end
  end

  describe "container hosts" do
    around do |example|
      Dir.mktmpdir("tier") do |root|
        @root = root
        example.run
      end
    end

    let(:container_dpkg) { ["dpkg-query", "-W", "-f=${Package} ${db:Status-Abbrev}\n", *HostTier::CONTAINER_PACKAGES] }

    def put(path, content)
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def ready_root
      put("sys/fs/cgroup/cgroup.controllers", "cpu memory pids\n")
      put("sys/module/apparmor/parameters/enabled", "Y\n")
      put("sys/kernel/security/apparmor/profiles", "lxc-container-default-cgns (enforce)\nlsb_release (enforce)\n")
    end

    def installed
      HostTier::CONTAINER_PACKAGES.map { "#{_1} ii \n" }.join
    end

    it "names the tier when refusing another architecture" do
      expect { described_class.check_arch!(arch: arm64, tier: "container") }.to raise_error(HostTier::Unsupported, "container hosts must be x86_64; this host is arm64")
    end

    it "accepts a host with cgroup v2, a recent kernel and systemd, the packages and LXC's AppArmor profile" do
      ready_root
      expect(described_class).to receive(:_run_command).with("systemctl", "--version").and_return("systemd 255 (255.4-1ubuntu8)\n+PAM\n")
      expect(described_class).to receive(:_run_command).with(*container_dpkg, expect: [0, 1]).and_return(installed)
      expect(described_class.check_container_runtime!(root: @root, release: "6.8.0-134-generic")).to be_nil
    end

    it "refuses a host without cgroup v2" do
      expect { described_class.check_container_runtime!(root: @root, release: "6.8.0") }.to raise_error(HostTier::Unsupported, "containers need the unified cgroup hierarchy (cgroup v2)")
    end

    it "refuses an old or unreadable kernel release" do
      ready_root
      expect { described_class.check_container_runtime!(root: @root, release: "5.4.0-200-generic") }.to raise_error(HostTier::Unsupported, "containers need Linux 5.12 or newer; this host runs 5.4.0-200-generic")
      expect { described_class.check_container_runtime!(root: @root, release: "weird") }.to raise_error(HostTier::Unsupported, /Linux 5.12 or newer/)
    end

    it "refuses an old systemd" do
      ready_root
      expect(described_class).to receive(:_run_command).with("systemctl", "--version").and_return("systemd 249 (249.11)\n")
      expect { described_class.check_container_runtime!(root: @root, release: "6.8.0") }.to raise_error(HostTier::Unsupported, "containers need systemd 254 or newer (DelegateSubgroup=); this host has 249")
    end

    it "refuses missing packages with the install hint" do
      ready_root
      expect(described_class).to receive(:_run_command).with("systemctl", "--version").and_return("systemd 255\n")
      expect(described_class).to receive(:_run_command).with(*container_dpkg, expect: [0, 1]).and_return("lxc-utils ii \n")
      expect { described_class.check_container_runtime!(root: @root, release: "6.8.0") }.to raise_error(HostTier::Unsupported, /\Amissing packages: lxcfs uidmap xz-utils quota cryptsetup-bin e2fsprogs; run scripts\/byoh\/bootstrap-data-plane.sh --tier container/)
    end

    it "refuses a host without AppArmor or without LXC's profile" do
      ready_root
      allow(described_class).to receive(:_run_command).with("systemctl", "--version").and_return("systemd 255\n")
      allow(described_class).to receive(:_run_command).with(*container_dpkg, expect: [0, 1]).and_return(installed)
      put("sys/kernel/security/apparmor/profiles", "lsb_release (enforce)\n")
      expect { described_class.check_container_runtime!(root: @root, release: "6.8.0") }.to raise_error(HostTier::Unsupported, "AppArmor profile lxc-container-default-cgns is not loaded; install lxc and run systemctl reload apparmor")
      put("sys/module/apparmor/parameters/enabled", "N\n")
      expect { described_class.check_container_runtime!(root: @root, release: "6.8.0") }.to raise_error(HostTier::Unsupported, "containers need AppArmor enabled")
      File.unlink(File.join(@root, "sys/module/apparmor/parameters/enabled"))
      expect { described_class.check_container_runtime!(root: @root, release: "6.8.0") }.to raise_error(HostTier::Unsupported, /\Acannot check AppArmor: No such file or directory/)
    end

    it "accepts Ubuntu's kernel settings and lists every one that is too low or missing" do
      {"dmesg_restrict" => "1", "kptr_restrict" => "1", "unprivileged_bpf_disabled" => "2", "perf_event_paranoid" => "4"}.each { |key, value| put("proc/sys/kernel/#{key}", "#{value}\n") }
      expect(described_class.check_container_sysctls!(root: @root)).to be_nil
      put("proc/sys/kernel/kptr_restrict", "0\n")
      put("proc/sys/kernel/perf_event_paranoid", "junk\n")
      File.unlink(File.join(@root, "proc/sys/kernel/dmesg_restrict"))
      expect { described_class.check_container_sysctls!(root: @root) }.to raise_error(HostTier::Unsupported,
        "a container host needs these kernel settings; add them to /etc/sysctl.d/60-ubicloud-containers.conf and run sysctl --system: kernel.dmesg_restrict = 1, kernel.kptr_restrict = 1, kernel.perf_event_paranoid = 2")
    end

    it "refuses subordinate id ranges that reach the container slots" do
      put("subuid", "ubuntu:100000:65536\n")
      expect(described_class.check_idmap_range!(files: [File.join(@root, "subuid")])).to be_nil
      put("subuid", "big:999999999:5\n")
      expect { described_class.check_idmap_range!(files: [File.join(@root, "subuid")]) }.to raise_error(HostTier::Unsupported, /\Asubordinate id ranges overlap the container id range 1000000000\+: .*big:999999999:5/)
    end

    it "sets up root's id range, no subordinate ids for new users, the kvm group, no lxc-net and LXC's directories" do
      put("login.defs", "UMASK 022\nSUB_UID_COUNT\t\t65536\n")
      expect(ContainerIdmap).to receive(:ensure_root_entries)
      expect(described_class).to receive(:safe_write_to_file).with(File.join(@root, "login.defs"), "UMASK 022\nSUB_UID_COUNT\t\t0\nSUB_GID_COUNT\t\t0\n", perm: 0o644)
      expect(described_class).to receive(:_run_command).with("groupadd", "-f", "-r", "kvm")
      expect(described_class).to receive(:safe_write_to_file).with("/etc/default/lxc-net", "# Written by rhizome: rhizome sets up container networking.\nUSE_LXC_BRIDGE=\"false\"\n", perm: 0o644)
      expect(File).to receive(:exist?).with("/usr/lib/systemd/system/lxc-net.service").and_return(true)
      expect(described_class).to receive(:_run_command).with("systemctl", "disable", "--now", "lxc-net.service")
      expect(described_class).to receive(:_run_command).with("install", "-d", "-m", "0711", "/var/lib/ubicloud/lxc")
      expect(described_class).to receive(:_run_command).with("install", "-d", "-m", "0700", "/var/lib/ubicloud/idmap")
      described_class.container_host_setup(login_defs: File.join(@root, "login.defs"))
    end

    it "leaves an absent lxc-net alone" do
      put("login.defs", "SUB_UID_COUNT 1\nSUB_GID_COUNT 1\n")
      allow(ContainerIdmap).to receive(:ensure_root_entries)
      expect(described_class).to receive(:safe_write_to_file).with(File.join(@root, "login.defs"), "SUB_UID_COUNT\t\t0\nSUB_GID_COUNT\t\t0\n", perm: 0o644)
      allow(described_class).to receive(:safe_write_to_file).with("/etc/default/lxc-net", anything, perm: 0o644)
      expect(File).to receive(:exist?).with("/usr/lib/systemd/system/lxc-net.service").and_return(false)
      expect(described_class).to receive(:_run_command).with("groupadd", "-f", "-r", "kvm")
      expect(described_class).to receive(:_run_command).with("install", any_args).twice
      described_class.container_host_setup(login_defs: File.join(@root, "login.defs"))
    end
  end
end
