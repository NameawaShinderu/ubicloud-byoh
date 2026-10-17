# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../lib/cloud_hypervisor"
require_relative "../lib/crypt_swap_setup"
require_relative "../lib/host_tier"
require_relative "../lib/htcat_setup"
require_relative "../lib/kvm_check"
require_relative "../lib/spdk_setup"
require_relative "../lib/uplink_mac_pin"
require "fileutils"
require "socket"

# The bin/prep_host.rb command line: every command and file write it makes,
# in order, for each tier. The kvm trace is what the script did before
# emulated hosts existed (9e22d71ec), so it pins that every
# cloud-hypervisor host is still prepared the same way.
# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "bin/prep_host.rb" do
  # rubocop:enable RSpec/DescribeClass
  let(:bin) { File.expand_path("../bin/prep_host.rb", __dir__) }
  let(:main) { TOPLEVEL_BINDING.receiver }
  let(:events) { [] }
  let(:irdma_loaded) { false }

  let(:motd) {
    <<~'MOTD'
      #!/bin/bash
      echo '%s       _     _      _                 _
       _   _| |__ (_) ___| | ___  _   _  __| |
      | | | |  _ \| |/ __| |/ _ \| | | |/ _  |
      | |_| | |_) | | (__| | (_) | |_| | (_| |
       \__,_|_.__/|_|\___|_|\___/ \__,_|\__,_|
      %s'
    MOTD
  }

  # Everything a production kvm host ran before emulated hosts, with
  # irdma loaded, in order.
  let(:kvm_trace) {
    [
      [:kvm_check],
      [:safe_write, "/etc/hosts", "127.0.0.1 localhost\n10.0.0.5 vhtest\n"],
      run("sudo", "hostnamectl", "set-hostname", "vhtest"),
      [:safe_write, "/root/.bashrc", "# bashrc\n PS1='\e[31m[\\u@\\h \\W]\\$ \e[0m'"],
      [:safe_write, "/etc/update-motd.d/99-clover-motd", format(motd, "\e[31m", "\e[0m")],
      run("chmod +x /etc/update-motd.d/99-clover-motd"),
      run("timedatectl set-timezone UTC"),
      [:download_ch],
      [:download_firmware],
      [:mkdir_p, "/etc/needrestart/conf.d"],
      [:write, "/etc/needrestart/conf.d/82-clover-default-list.conf", "$nrconf{restart} = 'l';\n"],
      [:write, "/etc/sysctl.d/72-clover-forward-packets.conf", <<~CONF],
        net.ipv6.conf.all.forwarding=1
        net.ipv6.conf.all.proxy_ndp=1
        net.ipv4.conf.all.forwarding=1
        net.ipv4.conf.all.proxy_arp=1
        net.ipv4.ip_forward=1
      CONF
      run("sysctl --system"),
      [:write, "/etc/modprobe.d/blacklist-irdma.conf", "blacklist irdma\n"],
      run("update-initramfs -u"),
      run("modprobe -r irdma"),
      run("apt-get -y install qemu-utils mtools acl"),
      run("apt-get -y install nvme-cli systemd-coredump"),
      run("apt-get -y install smartmontools nvme-cli jq ethtool"),
      [:uplink_mac_pin],
      [:htcat],
      [:spdk_prep],
      [:crypt_swap],
      [:mkdir_p, "/var/log/ubicloud/serials"],
      [:write, "/etc/cron.d/ubicloud-clean-serial-logs", "0 * * * * root /home/rhizome/host/bin/delete-old-serial-logs\n"],
      run("systemctl enable cron"),
      run("systemctl start cron"),
    ]
  }

  before do
    allow(main).to receive(:_run_command) { |*command, **kw| events << [:run, command, kw] && "" }
    allow(main).to receive(:safe_write_to_file) { |path, content| events << [:safe_write, path, content] }
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with("/etc/hosts").and_return("127.0.0.1 localhost\n10.0.0.5 ip-10-0-0-5\n")
    allow(File).to receive(:read).with("/root/.bashrc").and_return("# bashrc")
    allow(File).to receive(:write) { |path, content| events << [:write, path, content] }
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with("/sys/module/irdma").and_return(irdma_loaded)
    allow(FileUtils).to receive(:mkdir_p) { |path| events << [:mkdir_p, path] }
    allow(Socket).to receive(:gethostname).and_return("ip-10-0-0-5")
    allow(KvmCheck).to receive(:problem) { events << [:kvm_check] && nil }
    allow(CloudHypervisor::Version).to receive(:download) { events << [:download_ch] }
    allow(CloudHypervisor::Firmware).to receive(:download) { events << [:download_firmware] }
    uplink = instance_double(UplinkMacPin)
    allow(uplink).to receive(:run) { events << [:uplink_mac_pin] && "uplink mac pinned" }
    allow(UplinkMacPin).to receive(:new).and_return(uplink)
    htcat = instance_double(HtcatSetup)
    allow(htcat).to receive(:run) { events << [:htcat] && nil }
    allow(HtcatSetup).to receive(:new).and_return(htcat)
    allow(SpdkSetup).to receive(:prep) { events << [:spdk_prep] }
    allow(CryptSwapSetup).to receive(:run) { events << [:crypt_swap] }
  end

  def prep_host(*argv)
    stub_const("ARGV", argv)
    load bin
    nil
  rescue SystemExit => e
    e.status
  end

  def run(*command, **kw)
    [:run, command, kw]
  end

  context "with irdma loaded" do
    let(:irdma_loaded) { true }

    it "prepares a production kvm host as before" do
      expect { expect(prep_host("vhtest", "production", "kvm")).to be_nil }.to output("uplink mac pinned\n").to_stdout
      expect(events).to eq(kvm_trace)
    end

    it "defaults to kvm when no tier is given" do
      expect { expect(prep_host("vhtest", "production")).to be_nil }.to output("uplink mac pinned\n").to_stdout
      expect(events).to eq(kvm_trace)
    end
  end

  it "skips the production packages and the irdma unload on a development kvm host" do
    expect { expect(prep_host("vhtest", "development")).to be_nil }.to output("uplink mac pinned\n").to_stdout
    expected = kvm_trace - [run("modprobe -r irdma"), run("apt-get -y install nvme-cli systemd-coredump")]
    expected = expected.map { |event|
      (event[0] == :safe_write) ? [event[0], event[1], event[2].gsub("\e[31m", "\e[32m")] : event
    }
    expect(events).to eq(expected)
  end

  it "aborts a kvm host without KVM before changing anything" do
    allow(KvmCheck).to receive(:problem).and_return("/dev/kvm is not a character device")
    expect { expect(prep_host("vhtest", "production")).to eq(1) }.to output("/dev/kvm is not a character device\n").to_stderr
    expect(events).to eq([])
  end

  it "prepares an emulated host without the KVM check and the cloud-hypervisor downloads" do
    expect(HostTier).to receive(:check_arch!) { events << [:check_arch] }
    expect(HostTier).to receive(:check_emulator!) { events << [:check_emulator] }
    expect(HostTier).to receive(:kvm_hint).and_return(nil)
    expect { expect(prep_host("vhtest", "production", "emulated")).to be_nil }.to output("uplink mac pinned\n").to_stdout
    expect(events).to eq([[:check_arch], [:check_emulator]] + kvm_trace - [[:kvm_check], [:download_ch], [:download_firmware], run("modprobe -r irdma")])
    expect(events.flatten.grep(/qemu-system|ovmf/)).to eq([])
  end

  it "prints the KVM hint on an emulated host that has KVM, and carries on" do
    expect(HostTier).to receive(:check_arch!)
    expect(HostTier).to receive(:check_emulator!)
    expect(KvmCheck).to receive(:problem).once { events << [:kvm_hint_probe] && nil }
    expect { expect(prep_host("vhtest", "production", "emulated")).to be_nil }
      .to output("#{HostTier::KVM_AVAILABLE_HINT}\nuplink mac pinned\n").to_stdout
    expect(events).to eq([[:kvm_hint_probe]] + kvm_trace - [[:kvm_check], [:download_ch], [:download_firmware], run("modprobe -r irdma")])
  end

  it "aborts an emulated host without the emulator before changing anything" do
    expect(HostTier).to receive(:check_arch!)
    expect(HostTier).to receive(:missing_packages).and_return(["ovmf"])
    expect {
      expect(prep_host("vhtest", "production", "emulated")).to eq(1)
    }.to output("missing packages: ovmf; run scripts/byoh/bootstrap-data-plane.sh --tier emulated (or apt-get install qemu-system-x86 ovmf)\n").to_stderr
    expect(events).to eq([])
  end

  it "aborts an emulated host whose dpkg database fails before changing anything" do
    expect(HostTier).to receive(:check_arch!)
    expect(HostTier).to receive(:_run_command).with("dpkg-query", any_args).and_raise(CommandFail.new("command failed: dpkg-query", "", "dpkg: error: database is locked"))
    expect {
      expect(prep_host("vhtest", "production", "emulated")).to eq(1)
    }.to output(/\Adpkg-query failed: .*database is locked; run scripts\/byoh\/bootstrap-data-plane.sh --tier emulated/m).to_stderr
    expect(events).to eq([])
  end

  it "aborts an arm64 emulated host before changing anything" do
    expect(HostTier).to receive(:check_arch!).and_raise(HostTier::Unsupported, "emulated hosts must be x86_64; this host is arm64")
    expect(HostTier).not_to receive(:check_emulator!)
    expect { expect(prep_host("vhtest", "production", "emulated")).to eq(1) }.to output("emulated hosts must be x86_64; this host is arm64\n").to_stderr
    expect(events).to eq([])
  end

  it "aborts an unknown tier before changing anything" do
    expect { expect(prep_host("vhtest", "production", "hvf")).to eq(1) }.to output("unknown tier \"hvf\", expected one of kvm, container, pvm, emulated\n").to_stderr
    expect(events).to eq([])
  end

  it "prepares a pvm host: checks first, then the common steps, the kvm group, cloud-hypervisor and the late steps" do
    expect(HostTier).to receive(:check_arch!).with(tier: "pvm") { events << [:check_arch] }
    expect(HostTier).to receive(:check_pvm_host!) { events << [:check_pvm_host] }
    allow(HostTier).to receive(:_run_command) { |*command, **kw| events << [:run, command, kw] && "" }
    expect(KvmCheck).not_to receive(:problem)
    expect(CloudHypervisor::Firmware).not_to receive(:download)
    expect { expect(prep_host("vhtest", "production", "pvm")).to be_nil }.to output("uplink mac pinned\n").to_stdout
    common = kvm_trace[1, 6]
    expect(events).to eq([[:check_arch], [:check_pvm_host]] + common + [run("groupadd", "-f", "-r", "kvm"), [:download_ch]] +
      (kvm_trace - [[:kvm_check], [:download_ch], [:download_firmware], run("modprobe -r irdma")] - common))
  end

  it "aborts a pvm host that cannot take the PVM kernel before changing anything" do
    expect(HostTier).to receive(:check_arch!).with(tier: "pvm")
    kernel = instance_double(PvmHostKernel, prep_problem: "Secure Boot is on, and the PVM kernel is not signed; turn Secure Boot off")
    expect(PvmHostKernel).to receive(:new).and_return(kernel)
    expect { expect(prep_host("vhtest", "production", "pvm")).to eq(1) }.to output("this host cannot run pvm VMs: Secure Boot is on, and the PVM kernel is not signed; turn Secure Boot off\n").to_stderr
    expect(events).to eq([])
  end

  it "aborts an arm64 pvm host before changing anything" do
    expect(HostTier).to receive(:check_arch!).with(tier: "pvm").and_raise(HostTier::Unsupported, "pvm hosts must be x86_64; this host is arm64")
    expect(HostTier).not_to receive(:check_pvm_host!)
    expect { expect(prep_host("vhtest", "production", "pvm")).to eq(1) }.to output("pvm hosts must be x86_64; this host is arm64\n").to_stderr
    expect(events).to eq([])
  end

  it "prepares a container host: checks first, then the common steps, the container setup and the late steps" do
    expect(HostTier).to receive(:check_arch!).with(tier: "container") { events << [:check_arch] }
    expect(HostTier).to receive(:check_container_runtime!) { events << [:check_runtime] }
    expect(HostTier).to receive(:check_container_sysctls!) { events << [:check_sysctls] }
    expect(HostTier).to receive(:check_idmap_range!) { events << [:check_idmap] }
    expect(HostTier).to receive(:kvm_hint).and_return(nil)
    expect(HostTier).to receive(:container_host_setup) { events << [:container_host_setup] }
    expect { expect(prep_host("vhtest", "production", "container")).to be_nil }.to output("uplink mac pinned\n").to_stdout
    common = kvm_trace[1, 6]
    expect(events).to eq([[:check_arch], [:check_runtime], [:check_sysctls], [:check_idmap]] + common + [[:container_host_setup]] +
      (kvm_trace - [[:kvm_check], [:download_ch], [:download_firmware], run("modprobe -r irdma")] - common))
  end

  it "aborts a container host that fails a check before changing anything" do
    expect(HostTier).to receive(:check_arch!).with(tier: "container")
    expect(HostTier).to receive(:check_container_runtime!).and_raise(HostTier::Unsupported, "containers need the unified cgroup hierarchy (cgroup v2)")
    expect { expect(prep_host("vhtest", "production", "container")).to eq(1) }.to output("containers need the unified cgroup hierarchy (cgroup v2)\n").to_stderr
    expect(events).to eq([])
  end

  it "refuses missing arguments" do
    expect { expect(prep_host).to eq(1) }.to output("need host name as argument\n").to_stdout
    expect { expect(prep_host("vhtest")).to eq(1) }.to output("need environment type as argument\n").to_stdout
    expect(events).to eq([])
  end
end
