# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require_relative "../lib/pvm_host_kernel"
require_relative "pvm_host_kernel_fake"

# The commands, files and GRUB state of each subcommand, played against
# FakePvmHost. Golden fixtures in fixtures/pvm change only through a
# hand-reviewed diff: run this spec locally with UPDATE_GOLDEN=1, then
# review `git diff rhizome/host/spec/fixtures/pvm`.
RSpec.describe PvmHostKernel do
  let(:root) { Dir.mktmpdir("pvm-host") }
  let(:fake) { FakePvmHost.new(root) }
  let(:chardevs) { [] }
  let(:kernel) { described_class.new(root: root, runner: fake.runner, uid: 0, chardev: ->(p) { chardevs.include?(p.delete_prefix(root)) }, now: -> { Time.utc(2026, 10, 17) }) }
  let(:deb) { {"url" => FakePvmHost::DEB_URL, "sha256" => FakePvmHost::DEB_SHA256} }
  let(:stock_entry) { "Advanced options for Ubuntu>Ubuntu, with Linux #{FakePvmHost::STOCK}" }

  after { FileUtils.rm_rf(root) }

  def golden(name, actual)
    path = File.join(__dir__, "fixtures", "pvm", name)
    if ENV["UPDATE_GOLDEN"] == "1"
      fail "UPDATE_GOLDEN=1 is refused under CI; regenerate golden fixtures locally and review the diff" if ENV["CI"]
      File.write(path, actual)
    end
    File.read(path)
  end

  def commands
    fake.log.map { |argv| argv.join(" ") }
  end

  # The commands that change the host, as opposed to reading it.
  def mutating
    commands.grep(/\A(?:grub-set-default|grub-reboot|grub-editenv -|update-grub|env DEBIAN_FRONTEND|apt-mark -o DPkg::Lock::Timeout=300 (?:hold|unhold|auto|manual)|groupadd|systemctl (?:enable|disable|daemon-reload))/)
  end

  def state
    JSON.parse(fake.read(described_class::STATE_FILE))
  end

  def install(params = {"host_deb" => deb})
    kernel.install(params)
  end

  def fail_at(*words)
    fake.fail_on << FakePvmHost.command(*words)
  end

  def hook(*words, &block)
    fake.before << [FakePvmHost.command(*words), block]
  end

  describe ".main" do
    def main(argv, stdin = "")
      out = StringIO.new
      code = described_class.main(argv, stdin: StringIO.new(stdin), out: out, root: root, runner: fake.runner, uid: 0, chardev: ->(_) { false })
      [code, JSON.parse(out.string)]
    end

    it "prints the result and exits by it" do
      code, out = main(["status"])
      expect(code).to eq 0
      expect(out).to include("result" => "ok", "kernel" => FakePvmHost::STOCK)
    end

    it "refuses an unknown subcommand, a missing one and extra arguments" do
      [[], ["reinstall"], ["status", "now"]].each do |argv|
        code, out = main(argv)
        expect(code).to eq 2
        expect(out["error"]).to start_with "usage: install-pvm-host-kernel preflight|install|arm|disarm|status|uninstall|upgrade"
      end
    end

    it "refuses parameters that are not a JSON object" do
      expect(main(["preflight"], "{")).to match [2, include("error" => /\Athe parameters are not JSON/)]
      expect(main(["preflight"], "[1]")).to eq [2, {"result" => "refused", "error" => "the parameters must be a JSON object"}]
    end

    it "exits 2 for a refusal raised anywhere" do
      expect(main(["install"], "{}")).to eq [2, {"result" => "refused", "error" => "host_deb {url, sha256} is required"}]
    end

    it "exits 2 for a refused preflight and 3 for a failed install" do
      fake.write("proc/cmdline", "pti=off\n")
      expect(main(["preflight"]).first).to eq 2
      fake.write("proc/cmdline", "ro\n")
      fail_at("groupadd")
      expect(main(["install"], JSON.generate("host_deb" => deb)).first).to eq 3
    end

    it "exits 1 with the error for an unexpected one" do
      fake.fail_on << ->(argv) { argv == ["uname", "-r"] }
      code, out = main(["status"])
      expect(code).to eq 1
      expect(out["error"]).to start_with "CommandFail: command failed: uname -r"
    end

    it "runs commands through r by default" do
      host = described_class.new(root: root)
      expect(host).to receive(:_run_command).with("uname", "-r", expect: [0]).and_return("6.8.0-1-generic\n")
      expect(host.send(:run, "uname", "-r")).to eq "6.8.0-1-generic\n"
    end
  end

  describe "#preflight" do
    it "passes an EC2-like host, reading only" do
      result = kernel.preflight({})
      expect(result["result"]).to eq "ok"
      expect(result["refusals"]).to eq []
      expect(result["facts"]).to eq(
        "kernel" => FakePvmHost::STOCK, "machine" => "x86_64", "meltdown" => "Not affected", "lockdown" => "none",
        "secure_boot" => nil, "stock_entry" => stock_entry, "drivers" => %w[ena nvme pcieport], "unchecked_drivers" => ["pcieport"],
      )
      expect(mutating).to eq []
    end

    it "names the stock entry without the submenu when update-grub puts none" do
      flat = FakePvmHost.new(root, submenu: false)
      result = described_class.new(root: root, runner: flat.runner, uid: 0, chardev: ->(_) { false }).preflight({})
      expect(result["facts"]["stock_entry"]).to eq "Ubuntu, with Linux #{FakePvmHost::STOCK}"
    end

    it "checks Xen's vif and vbd under their module names" do
      xen = FakePvmHost.new(root, net: "vif", block: "vbd")
      result = described_class.new(root: root, runner: xen.runner, uid: 0, chardev: ->(_) { false }).preflight({})
      expect(result["result"]).to eq "ok"
      expect(result["facts"]["drivers"]).to eq %w[vbd vif]
    end

    it "reads modules.dep larger than 64 KiB to its end" do
      fake
      expect(File.size(File.join(root, "lib/modules", FakePvmHost::STOCK, "modules.dep"))).to be > 64 * 1024
      expect(fake.read("lib/modules/#{FakePvmHost::STOCK}/modules.dep").lines.last).to start_with "kernel/fs/ext4"
      expect(kernel.preflight({})["result"]).to eq "ok"
    end

    it "skips a device link that leads nowhere" do
      FileUtils.mkdir_p(File.join(fake.root, "sys/class/net/bond0"))
      File.symlink(File.join(fake.root, "sys/devices/gone"), File.join(fake.root, "sys/class/net/bond0/device"))
      expect(kernel.preflight({})["facts"]["drivers"]).to eq %w[ena nvme pcieport]
    end

    it "takes a host without sysfs devices" do
      fake
      FileUtils.rm_rf(File.join(root, "sys/devices"))
      expect(kernel.preflight({})["facts"]["drivers"]).to eq []
    end

    refusals = {
      "not root" => [->(_t, _f) {}, "run as root"],
      "arm64" => [->(_t, f) { f.machine = "aarch64" }, "PVM is x86_64 only, this is aarch64"],
      "Ubuntu 22.04" => [->(_t, f) { f.write("etc/os-release", "VERSION_ID=\"22.04\"\n") }, "PVM hosts run Ubuntu 24.04"],
      "a container" => [->(_t, f) { f.container = "lxc" }, "this is a container (lxc); PVM needs a VM or bare metal"],
      "a docker container" => [->(_t, f) { f.write(".dockerenv", "") }, "this is a container (/.dockerenv or /run/.containerenv); PVM needs a VM or bare metal"],
      "vmx" => [->(_t, f) { f.write("proc/cpuinfo", "flags\t\t: fpu vmx hypervisor\n") }, "the CPU has vmx or svm: this host has hardware virtualization; register it as kvm"],
      "a working /dev/kvm" => [->(t, _f) { t.chardevs << "/dev/kvm" }, "/dev/kvm exists on the stock kernel: KVM already works here; register it as kvm"],
      "Secure Boot" => [->(_t, f) { f.write("sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c", "\x06\x00\x00\x00\x01") }, "Secure Boot is on, and the PVM kernel is not signed; turn Secure Boot off"],
      "Meltdown" => [->(_t, f) { f.write("sys/devices/system/cpu/vulnerabilities/meltdown", "Mitigation: PTI\n") }, "this CPU's Meltdown status is \"Mitigation: PTI\", not \"Not affected\": the PVM kernel runs with pti=off, so a guest could read host memory"],
      "no Meltdown status" => [->(_t, f) { File.delete(File.join(f.root, "sys/devices/system/cpu/vulnerabilities/meltdown")) }, "this CPU's Meltdown status is unknown, not \"Not affected\": the PVM kernel runs with pti=off, so a guest could read host memory"],
      "GRUB_SAVEDEFAULT" => [->(_t, f) { f.write("etc/default/grub.d/50-cloudimg.cfg", "GRUB_SAVEDEFAULT=\"true\"\n") }, "GRUB_SAVEDEFAULT=true in /etc/default/grub.d/50-cloudimg.cfg would make a PVM boot the default"],
      "no grub-reboot" => [->(_t, f) { File.delete(File.join(f.root, "usr/sbin/grub-reboot")) }, "grub-reboot is missing"],
      "no grub.cfg" => [->(_t, f) { File.delete(File.join(f.root, "boot/grub/grub.cfg")) }, ["there is no /boot/grub/grub.cfg: GRUB is not the boot loader", "grub.cfg has no entry for the running kernel #{FakePvmHost::STOCK}"]],
      "pti=off" => [->(_t, f) { f.write("proc/cmdline", "ro pti=off\n") }, "the running kernel #{FakePvmHost::STOCK} has pti=off; remove it from GRUB_CMDLINE_LINUX* first"],
      "kvm_pvm loaded" => [->(_t, f) { FileUtils.mkdir_p(File.join(f.root, "sys/module/kvm_pvm")) }, "the running kernel #{FakePvmHost::STOCK} is a PVM kernel; install runs only on the stock kernel"],
      "a stock kernel not from dpkg" => [->(_t, f) { f.packages.clear }, "the running kernel is not from the package linux-image-#{FakePvmHost::STOCK}, so it cannot be held"],
      "an odd kernel version" => [->(_t, f) { f.kernel = "7.0\"x" }, nil],
      "no stock entry" => [->(_t, f) { f.kernel = "7.0.0-9999-custom" }, nil],
      "an unchecked driver" => [->(_t, f) { File.delete(File.join(f.root, "sys/devices/pci0000:00/0000:00:01.0/0000:00:00.0/driver")) && File.symlink("/sys/bus/drivers/foo_nic", File.join(f.root, "sys/devices/pci0000:00/0000:00:01.0/0000:00:00.0/driver")) }, "cannot check the PVM kernel for the drivers this host's disks and NICs use: foo_nic (no module of that name in #{FakePvmHost::STOCK}); check by hand that the PVM kernel has them, then pass them as unchecked_drivers"],
      "too little space" => [->(_t, f) { f.mount("boot", 200_000) }, "needs about 292 MiB free on /boot (for /boot), has 195 MiB"],
      "too little space, summed per file system" => [->(_t, f) { f.avail_kib["/"] = 2_000_000 }, "needs about 2343 MiB free on / (for /var/lib/ubicloud/pvm and / and /boot), has 1953 MiB"],
    }

    refusals.each do |name, (setup, message)|
      it "refuses #{name} before any change, also when installing" do
        setup.call(self, fake)
        host = (name == "not root") ? described_class.new(root: root, runner: fake.runner, uid: 1000, chardev: ->(_) { false }) : kernel
        result = host.preflight({})
        expect(result["result"]).to eq "refused"
        if message
          expect(result["refusals"]).to eq Array(message)
        else
          expect(result["refusals"]).to include("grub.cfg has no entry for the running kernel #{fake.kernel}")
        end

        before = fake.snapshot
        expect(host.install("host_deb" => deb)).to include("result" => "refused", "refusals" => result["refusals"])
        expect(mutating).to eq []
        expect(commands.grep(/\Acurl/)).to eq []
        expect(fake.snapshot).to eq before
      end
    end

    it "refuses a kernel version it would have to quote" do
      fake.kernel = "7.0\"x"
      expect(kernel.preflight({})["refusals"]).to include("the running kernel's version \"7.0\\\"x\" has unexpected characters")
    end

    it "refuses a running kernel this tool installed" do
      fake.write(described_class::STATE_FILE, JSON.generate("state" => "armed", "kver" => FakePvmHost::STOCK))
      expect(kernel.preflight({})["refusals"]).to eq ["the running kernel #{FakePvmHost::STOCK} is a PVM kernel; install runs only on the stock kernel"]
    end

    it "takes drivers the operator checked by hand" do
      fake
      driver = File.join(root, "sys/devices/pci0000:00/0000:00:01.0/0000:00:00.0/driver")
      File.delete(driver)
      File.symlink("/sys/bus/drivers/foo_nic", driver)
      expect(kernel.preflight("unchecked_drivers" => ["foo_nic"])).to include("result" => "ok")
      expect(kernel.preflight("unchecked_drivers" => ["foo_nic"])["facts"]["unchecked_drivers"]).to eq %w[foo_nic pcieport]
    end

    it "refuses unchecked_drivers that are not driver names" do
      [["foo bar"], "foo", [1]].each do |list|
        expect { kernel.preflight("unchecked_drivers" => list) }.to raise_error(described_class::Refused, "unchecked_drivers must be a list of sysfs driver names")
      end
    end
  end

  describe "#install" do
    it "installs, pins the stock kernel and arms one PVM boot" do
      result = install
      expect(result).to eq("result" => "ok", "kver" => FakePvmHost::PVM, "stock_entry" => stock_entry,
        "grubenv" => {"saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm"})
      expect(commands.join("\n") + "\n").to eq golden("install-commands.txt", commands.join("\n") + "\n")
      expect(fake.held).to eq ["linux-image-#{FakePvmHost::STOCK}", FakePvmHost::PVM_PKG]
      expect(fake.auto).to eq []
      expect(fake.groups).to eq ["kvm"]
      expect(fake.enabled).to eq ["ubicloud-pvm-boot.service"]
      expect(fake.exist?(described_class::DEB_FILE)).to be false
      expect(state).to eq(
        "state" => "armed",
        "steps" => described_class::INSTALL_STEPS,
        "host_deb_url" => deb["url"],
        "host_deb_sha256" => deb["sha256"],
        "stock_kver" => FakePvmHost::STOCK,
        "stock_entry" => stock_entry,
        "stock_pkg" => "linux-image-#{FakePvmHost::STOCK}",
        "stock_pkg_held" => false,
        "stock_pkg_auto" => true,
        "orig_saved_entry" => nil,
        "lockdown" => "none",
        "meltdown" => "Not affected",
        "pkg" => FakePvmHost::PVM_PKG,
        "kver" => FakePvmHost::PVM,
        "last_result" => {"result" => "ok", "at" => "2026-10-17T00:00:00Z"},
        "updated_at" => "2026-10-17T00:00:00Z",
      )
    end

    it "writes the files the goldens pin" do
      install
      {
        "42_ubicloud_pvm" => described_class::GRUB_SCRIPT,
        "98-ubicloud-pvm.cfg" => described_class::GRUB_DROPIN,
        "ubicloud-pvm-boot.service" => described_class::BOOT_UNIT,
        "ubicloud-pvm-boot" => described_class::BOOT_SCRIPT,
        "ubicloud-pvm.conf" => described_class::BLACKLIST,
        "60-ubicloud-kvm.rules" => described_class::UDEV_RULE,
        "grub-advanced.cfg" => described_class::GRUB_CFG,
      }.each do |name, rel|
        expect(fake.read(rel)).to eq golden(name, fake.read(rel))
      end
      expect(File.stat(File.join(root, described_class::GRUB_SCRIPT)).mode & 0o777).to eq 0o755
      expect(File.stat(File.join(root, described_class::BOOT_SCRIPT)).mode & 0o777).to eq 0o755
      expect(File.stat(File.join(root, described_class::STATE_FILE)).mode & 0o777).to eq 0o600
    end

    it "puts pti=off in one entry only, also without the submenu and on a GRUB_FORCE_PARTUUID image" do
      {"grub-flat.cfg" => {submenu: false}, "grub-partuuid.cfg" => {partuuid: true}}.each do |name, opts|
        Dir.mktmpdir do |dir|
          host = FakePvmHost.new(dir, **opts)
          result = described_class.new(root: dir, runner: host.runner, uid: 0, chardev: ->(_) { false }).install("host_deb" => deb)
          expect(result["result"]).to eq "ok"
          cfg = host.read("boot/grub/grub.cfg")
          expect(cfg).to eq golden(name, cfg)
          expect(cfg.scan("pti=off").size).to eq 1
        end
      end
    end

    it "counts pti=off on linux lines only, so a title may contain it" do
      fake.write("etc/grub.d/40_custom", "#!/bin/sh\nexec tail -n +3 $0\nmenuentry 'notes: pti=off' {\n  linux /boot/vmlinuz-#{FakePvmHost::STOCK} root=UUID=#{FakePvmHost::UUID} ro\n}\n")
      expect(install["result"]).to eq "ok"
    end

    it "records a saved_entry that was set before, for uninstall" do
      fake.send(:write_grubenv, {"saved_entry" => "1>2"})
      install
      expect(state["orig_saved_entry"]).to eq "1>2"
    end

    it "refuses a wrong sha256 before any change and keeps no download" do
      result = install("host_deb" => deb.merge("sha256" => "0" * 64))
      expect(result).to eq("result" => "refused", "step" => "verify", "error" => "the host kernel package has sha256 #{deb["sha256"]}, not the pinned #{"0" * 64}")
      expect(mutating).to eq []
      expect(fake.exist?(described_class::DEB_FILE)).to be false
      expect(state).to include("state" => "refused", "steps" => [], "last_result" => result.merge("at" => "2026-10-17T00:00:00Z"))
      expect(install["result"]).to eq "ok"
    end

    it "refuses a download that fails, is missing or is too large" do
      fake.serve("https://example.com/missing.deb", nil)
      expect(install("host_deb" => deb.merge("url" => "https://example.com/gone.deb"))).to include("result" => "refused", "step" => "fetch", "error" => /command failed: curl/)
      expect(install("host_deb" => deb.merge("url" => "https://example.com/missing.deb"))).to include("result" => "refused", "error" => "the download gave no file")
      stub_const("PvmHostKernel::MAX_BYTES", 10)
      expect(install).to include("result" => "refused", "error" => "the download is larger than 10 bytes")
      expect(mutating).to eq []
    end

    it "downloads https only, capped, with stall limits" do
      install
      expect(fake.log.find { |argv| argv.first == "curl" }).to eq ["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
        "--connect-timeout", "10", "--speed-limit", "1024", "--speed-time", "60", "--max-filesize", "536870912",
        "-o", "/#{described_class::DEB_FILE}", deb["url"]]
    end

    it "refuses a package that is not a kernel, or is the stock kernel" do
      {"Package: hello\n" => "the package hello is not a linux-image package",
       "Package: linux-image-a b\n" => "the package linux-image-a b is not a linux-image package",
       "Package: linux-image-#{FakePvmHost::STOCK}\n" => "the package's kernel #{FakePvmHost::STOCK} is the stock kernel"}.each do |content, error|
        url = "https://example.com/#{Digest::SHA256.hexdigest(content)}.deb"
        fake.serve(url, content)
        expect(install("host_deb" => {"url" => url, "sha256" => Digest::SHA256.hexdigest(content)})).to include("result" => "refused", "error" => error)
      end
      expect(mutating).to eq []
    end

    it "refuses bad parameters" do
      {
        {} => "host_deb {url, sha256} is required",
        {"host_deb" => "x"} => "host_deb {url, sha256} is required",
        {"host_deb" => deb.merge("url" => "http://example.com/k.deb")} => "host_deb url must be an https URL",
        {"host_deb" => deb.merge("url" => "HTTPS://example.com/k.deb")} => "host_deb url must be an https URL",
        {"host_deb" => deb.merge("url" => 1)} => "host_deb url must be an https URL",
        {"host_deb" => deb.merge("sha256" => "A" * 64)} => "host_deb sha256 must be 64 lowercase hex digits",
      }.each do |params, error|
        expect { kernel.install(params) }.to raise_error(described_class::Refused, error)
      end
      expect(fake.log).to eq []
    end

    it "refuses while another run holds the lock" do
      FileUtils.mkdir_p(File.join(root, described_class::WORK_DIR))
      File.open(File.join(root, described_class::LOCK_FILE), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        expect { install }.to raise_error(described_class::Refused, "another install-pvm-host-kernel run holds var/lib/ubicloud/pvm/lock")
      end
    end

    it "refuses on the PVM kernel it installed [C1]" do
      install
      fake.boot(FakePvmHost::PVM, pti_off: true)
      fake.log.clear
      result = install
      expect(result["result"]).to eq "refused"
      expect(result["refusals"]).to include("the running kernel #{FakePvmHost::PVM} is a PVM kernel; install runs only on the stock kernel",
        "the running kernel #{FakePvmHost::PVM} has pti=off; remove it from GRUB_CMDLINE_LINUX* first")
      expect(mutating).to eq []
    end

    it "re-arms a finished install of the same package and skips its steps" do
      install
      kernel.disarm({})
      fake.log.clear
      expect(install["result"]).to eq "ok"
      expect(mutating).to eq ["systemctl enable ubicloud-pvm-boot.service", "grub-reboot ubicloud-pvm"]
      expect(state["state"]).to eq "armed"
    end

    it "refuses another package over a finished install, and any install over an unfinished one" do
      install
      expect { install("host_deb" => deb.merge("sha256" => "1" * 64)) }.to raise_error(described_class::Refused,
        "this host already has the PVM kernel #{FakePvmHost::PVM} (sha256 #{deb["sha256"]}); use upgrade, or uninstall first")
      fake.write(described_class::STATE_FILE, JSON.generate(state.merge("state" => "installing", "steps" => %w[fetch verify grub_pin])))
      expect { install }.to raise_error(described_class::Refused, "an earlier install stopped in state installing after step grub_pin; run uninstall first")
      fake.write(described_class::STATE_FILE, JSON.generate("state" => "failed"))
      expect { install }.to raise_error(described_class::Refused, "an earlier install stopped in state failed after step none; run uninstall first")
    end

    # Each step's failure, the command that fails or the fault that makes
    # it fail, and the step that finished before it.
    failures = {
      "grub_pin: update-grub" => ["grub_pin", ->(t) { t.fail_at("update-grub") }, "verify", /command failed: update-grub/],
      "grub_pin: saved_entry not booted" => ["grub_pin", ->(t) { t.fake.write("etc/default/grub.d/99-local.cfg", "GRUB_DEFAULT=0\n") }, "verify", /grub.cfg does not boot \$\{saved_entry\}/],
      "grub_pin: no save_env" => ["grub_pin", ->(t) { t.hook("update-grub") { t.fake.noop << FakePvmHost.command("update-grub") && t.fake.write("boot/grub/grub.cfg", "set default=\"${saved_entry}\"\n") } }, "verify", /no save_env/],
      "grub_pin: the stock kernel gone" => ["grub_pin", ->(t) { t.hook("update-grub") { File.delete(File.join(t.fake.root, "boot/vmlinuz-#{FakePvmHost::STOCK}")) } }, "verify", /no longer matches an entry/],
      "grub_pin: grub-set-default" => ["grub_pin", ->(t) { t.fake.noop << FakePvmHost.command("grub-set-default") }, "verify", /saved_entry is not 'Advanced options/],
      "hold_stock" => ["hold_stock", ->(t) { t.fail_at("apt-mark", "hold") }, "grub_pin", /command failed: apt-mark/],
      "install_deb: apt-get" => ["install_deb", ->(t) { t.fail_at("apt-get", "install") }, "hold_stock", /command failed: env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install/],
      "install_deb: no initrd" => ["install_deb", ->(t) { t.fake.pvm_initrd = false }, "hold_stock", %r{/boot/initrd.img-6.12.33-pvm is missing after the install}],
      "install_deb: the package moved saved_entry" => ["install_deb", ->(t) { t.hook("apt-mark", "hold", FakePvmHost::PVM_PKG) { t.fake.send(:edit_env) { |env| env["saved_entry"] = "0" } } }, "hold_stock", /the package changed saved_entry/],
      "check_drivers: no ENA" => ["check_drivers", ->(t) { t.fake.pvm_modules = FakePvmHost::MODULES.grep_v(/ena/) }, "install_deb", /lacks drivers this host uses: ena\z/],
      "check_drivers: no root file system" => ["check_drivers", ->(t) { t.fake.rootfs = "xfs" }, "install_deb", /lacks the root file system driver xfs/],
      "grub_entry: pti=off twice" => ["grub_entry", ->(t) { t.fake.write("etc/grub.d/40_custom", "menuentry 'x' {\n  linux /boot/vmlinuz-x ro pti=off\n}\n") }, "check_drivers", /pti=off must be on exactly one linux line in grub.cfg, it is on 2/],
      "grub_entry: pti=off elsewhere" => ["grub_entry", ->(t) { t.fake.write("etc/grub.d/40_custom", "menuentry 'x' {\n  linux /boot/vmlinuz-x ro pti=off\n}\n") && t.hook("update-grub") {} && t.hook("update-grub") { File.chmod(0o644, File.join(t.fake.root, described_class::GRUB_SCRIPT)) } }, "check_drivers", /pti=off is not in the ubicloud-pvm entry/],
      "grub_entry: pti=off before the entry" => ["grub_entry", ->(t) { t.hook("update-grub") {} && t.hook("update-grub") { File.chmod(0o644, File.join(t.fake.root, described_class::GRUB_SCRIPT)) && t.fake.write("etc/grub.d/40_custom", "menuentry 'y' {\n  linux /boot/vmlinuz-x ro pti=off\n}\nmenuentry 'x' --id ubicloud-pvm {\n}\n") } }, "check_drivers", /pti=off is not in the ubicloud-pvm entry/],
      "grub_entry: no root=UUID" => ["grub_entry", ->(t) { t.fake.device_uuid = "" }, "check_drivers", /has no root=UUID/],
      "boot_unit" => ["boot_unit", ->(t) { t.fail_at("groupadd") }, "grub_entry", /command failed: groupadd/],
      "arm: enable" => ["arm", ->(t) { t.fail_at("systemctl", "enable") }, "boot_unit", /command failed: systemctl enable/],
      "arm: the stock kernel gone" => ["arm", ->(t) { t.hook("systemctl", "daemon-reload") { File.delete(File.join(t.fake.root, "boot/vmlinuz-#{FakePvmHost::STOCK}")) } }, "boot_unit", /no longer matches an entry/],
      "arm: next_entry not set" => ["arm", ->(t) { t.fake.noop << FakePvmHost.command("grub-reboot") }, "boot_unit", /next_entry is '', not ubicloud-pvm/],
      "arm: saved_entry moved" => ["arm", ->(t) { t.hook("grub-reboot") { t.fake.send(:edit_env) { |env| env["saved_entry"] = "0" } } }, "boot_unit", /saved_entry is '0', not the stock/],
    }

    failures.each do |name, (step, setup, last, error)|
      it "un-arms when #{name} fails, and uninstall then restores the host [C3, C4]" do
        before = fake.snapshot
        setup.call(self)
        result = install
        expect(result).to include("result" => "failed", "step" => step, "last_step" => last, "error" => error,
          "fix" => "the host was un-armed and boots the stock kernel; run uninstall, then install again")
        expect(fake.grubenv["next_entry"]).to be_nil
        expect(fake.grubenv["saved_entry"]).to eq(stock_entry) unless name.include?("gone") || name.include?("grub-set-default")
        expect(commands.last(2)).to eq ["grub-set-default #{stock_entry}", "grub-editenv - unset next_entry"]
        expect(state).to include("state" => "failed", "last_result" => result.merge("at" => "2026-10-17T00:00:00Z"))
        expect(fake.exist?(described_class::DEB_FILE)).to be false

        fake.noop.clear
        fake.before.clear
        fake.pvm_initrd = true
        fake.pvm_modules = FakePvmHost::MODULES
        fake.rootfs = "ext4"
        fake.device_uuid = FakePvmHost::UUID
        FileUtils.rm_f([File.join(root, "etc/grub.d/40_custom"), File.join(root, "etc/default/grub.d/99-local.cfg")])
        unless File.exist?(File.join(root, "boot/vmlinuz-#{FakePvmHost::STOCK}"))
          fake.write("boot/vmlinuz-#{FakePvmHost::STOCK}", "vmlinuz #{FakePvmHost::STOCK}\n")
        end
        expect(kernel.uninstall({})).to eq("result" => "ok", "grubenv" => {})
        expect(fake.snapshot).to eq before
        expect(state).to include("state" => "uninstalled", "steps" => [])
        expect(install["result"]).to eq "ok"
      end
    end

    it "records an un-arm that failed too" do
      hook("groupadd") { fail_at("grub-set-default") }
      fail_at("groupadd")
      result = install
      expect(result["result"]).to eq "failed"
      expect(state["unarm_error"]).to include("command failed: grub-set-default")
    end
  end

  describe "#arm" do
    it "re-arms a disarmed host and enables the boot unit" do
      install
      kernel.disarm({})
      expect(kernel.arm({})).to eq("result" => "ok", "grubenv" => {"saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm"})
      expect(fake.enabled).to eq ["ubicloud-pvm-boot.service"]
      expect(state["state"]).to eq "armed"
    end

    it "arms again on the PVM kernel, as each boot does" do
      install
      fake.boot(FakePvmHost::PVM, pti_off: true)
      expect(kernel.arm({})["grubenv"]).to eq("saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm")
    end

    it "refuses without a finished install" do
      expect { kernel.arm({}) }.to raise_error(described_class::Refused, "no installed PVM kernel to arm (state: none)")
      fake.write(described_class::STATE_FILE, JSON.generate("state" => "failed"))
      expect { kernel.arm({}) }.to raise_error(described_class::Refused, "no installed PVM kernel to arm (state: failed)")
    end

    it "refuses when the stock entry no longer boots, before any change" do
      install
      File.delete(File.join(root, "boot/vmlinuz-#{FakePvmHost::STOCK}"))
      fake.log.clear
      expect { kernel.arm({}) }.to raise_error(described_class::Refused, /\Athe stock entry '#{Regexp.escape(stock_entry)}' no longer matches/)
      expect(mutating).to eq []
    end

    it "un-arms when the arm does not take" do
      install
      fake.noop << FakePvmHost.command("grub-reboot")
      fake.send(:edit_env) { |env| env.delete("next_entry") }
      expect(kernel.arm({})).to include("result" => "failed", "error" => "next_entry is '', not ubicloud-pvm")
      expect(state).to include("state" => "disarmed", "last_result" => include("step" => "arm"))
    end
  end

  describe "#disarm" do
    it "does nothing without an install" do
      expect(kernel.disarm({})).to eq("result" => "ok", "note" => "no PVM kernel install is recorded here")
      expect(mutating).to eq []
    end

    it "boots the stock kernel next and disables the boot unit" do
      install
      fake.log.clear
      expect(kernel.disarm({})).to eq("result" => "ok", "grubenv" => {"saved_entry" => stock_entry})
      expect(mutating).to eq ["grub-set-default #{stock_entry}", "grub-editenv - unset next_entry", "systemctl disable ubicloud-pvm-boot.service"]
      expect(fake.enabled).to eq []
      expect(state["state"]).to eq "disarmed"
    end

    it "keeps a failed install failed, and skips a unit it never wrote" do
      fail_at("groupadd")
      install
      fake.log.clear
      kernel.disarm({})
      expect(mutating).not_to include("systemctl disable ubicloud-pvm-boot.service")
      expect(state["state"]).to eq "failed"
    end
  end

  describe "#status" do
    it "reports a host without an install" do
      expect(kernel.status({})).to eq(
        "result" => "ok", "kernel" => FakePvmHost::STOCK, "pti_off" => false, "kvm_pvm_loaded" => false, "running_pvm" => false,
        "grubenv" => {}, "stock_entry_resolves" => nil, "dev_kvm" => {"chardev" => false},
        "boot_unit" => {"ActiveState" => "inactive", "Result" => "success", "UnitFileState" => "disabled"}, "state" => nil,
      )
    end

    it "reports a PVM boot" do
      install
      fake.boot(FakePvmHost::PVM, pti_off: true)
      chardevs << "/dev/kvm"
      expect(kernel.status({})).to include(
        "kernel" => FakePvmHost::PVM, "pti_off" => true, "kvm_pvm_loaded" => true, "running_pvm" => true,
        "grubenv" => {"saved_entry" => stock_entry}, "stock_entry_resolves" => true,
        "dev_kvm" => {"chardev" => true, "mode" => "660", "group" => "kvm"},
        "boot_unit" => {"ActiveState" => "active", "Result" => "success", "UnitFileState" => "enabled"},
        "state" => include("state" => "armed"),
      )
    end
  end

  describe "#uninstall" do
    it "restores a host whose stock kernel was held and manual" do
      fake.held << "linux-image-#{FakePvmHost::STOCK}"
      fake.auto.clear
      before = fake.snapshot
      install
      kernel.uninstall({})
      expect(fake.snapshot).to eq before
    end

    it "puts back a saved_entry that was set before" do
      fake.send(:write_grubenv, {"saved_entry" => "1>2"})
      install
      kernel.uninstall({})
      expect(fake.grubenv).to eq("saved_entry" => "1>2")
    end

    it "refuses on the PVM kernel" do
      install
      fake.boot(FakePvmHost::PVM, pti_off: true)
      fake.log.clear
      expect { kernel.uninstall({}) }.to raise_error(described_class::Refused, "the running kernel #{FakePvmHost::PVM} is the PVM kernel (or has pti=off); reboot to the stock kernel first")
      expect(mutating).to eq []
      fake.write("proc/cmdline", "ro pti=off\n")
      FileUtils.rm_rf(File.join(root, "sys/module/kvm_pvm"))
      fake.kernel = FakePvmHost::STOCK
      expect { kernel.uninstall({}) }.to raise_error(described_class::Refused, /reboot to the stock kernel first/)
    end

    it "removes its files without a state file" do
      install
      File.delete(File.join(root, described_class::STATE_FILE))
      fake.log.clear
      expect(kernel.uninstall({})["result"]).to eq "ok"
      described_class::OWNED_FILES.each { |rel| expect(fake.exist?(rel)).to be false }
      expect(mutating).to eq ["systemctl disable ubicloud-pvm-boot.service", "systemctl daemon-reload", "grub-editenv - unset next_entry"]
    end

    it "purges a half-installed package and skips one that is gone" do
      install
      fake.pkg_status[FakePvmHost::PVM_PKG] = "half-configured"
      fake.log.clear
      kernel.uninstall({})
      expect(commands).to include("env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 purge -y #{FakePvmHost::PVM_PKG}")
      fake.pkg_status[FakePvmHost::PVM_PKG] = "not-installed"
      fake.log.clear
      kernel.uninstall({})
      expect(commands.grep(/purge/)).to eq []
    end

    it "leaves the stock kernel's marks alone once it is gone" do
      install
      fake.packages.delete("linux-image-#{FakePvmHost::STOCK}")
      fake.log.clear
      kernel.uninstall({})
      expect(commands.grep(/apt-mark .*linux-image-#{FakePvmHost::STOCK}/o)).to eq []
    end

    it "reports a failure and can run again" do
      install
      fail_at("apt-get", "purge")
      expect(kernel.uninstall({})).to include("result" => "failed", "error" => /command failed: env DEBIAN_FRONTEND/, "fix" => "fix the cause, then run uninstall again")
      expect(state["last_result"]).to include("step" => "uninstall")
      expect(kernel.uninstall({})["result"]).to eq "ok"
      expect(fake.packages).to eq ["linux-image-#{FakePvmHost::STOCK}"]
    end

    it "reports a failure without a state file" do
      fail_at("systemctl", "daemon-reload")
      expect(kernel.uninstall({})).to include("result" => "failed")
      expect(fake.exist?(described_class::STATE_FILE)).to be false
    end
  end

  describe "#upgrade" do
    let(:new_content) { "Package: linux-image-6.12.40-pvm\n" }
    let(:new_deb) { {"url" => "https://example.com/new.deb", "sha256" => Digest::SHA256.hexdigest(new_content)} }

    before { fake.serve(new_deb["url"], new_content) }

    def on_pvm
      install
      fake.boot(FakePvmHost::PVM, pti_off: true)
      fake.log.clear
    end

    it "installs a second build beside the first and arms it, keeping the stock pin" do
      on_pvm
      expect(kernel.upgrade("host_deb" => new_deb)).to include("result" => "ok", "kver" => "6.12.40-pvm", "stock_entry" => stock_entry)
      expect(commands.join("\n") + "\n").to eq golden("upgrade-commands.txt", commands.join("\n") + "\n")
      expect(fake.grubenv).to eq("saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm")
      expect(fake.read(described_class::GRUB_SCRIPT)).to include("k=/boot/vmlinuz-6.12.40-pvm")
      expect(fake.read(described_class::BOOT_SCRIPT)).to include("[ \"$(uname -r)\" = \"6.12.40-pvm\" ]")
      expect(state).to include("state" => "armed", "kver" => "6.12.40-pvm", "pkg" => "linux-image-6.12.40-pvm",
        "prev_kvers" => [FakePvmHost::PVM], "prev_pkgs" => [FakePvmHost::PVM_PKG], "host_deb_sha256" => new_deb["sha256"])
      expect(fake.held).to include("linux-image-6.12.40-pvm", FakePvmHost::PVM_PKG)

      fake.boot("6.12.40-pvm", pti_off: true)
      expect(kernel.status({})["running_pvm"]).to be true
      fake.boot(FakePvmHost::STOCK)
      kernel.uninstall({})
      expect(fake.packages).to eq ["linux-image-#{FakePvmHost::STOCK}"]
    end

    it "refuses off the PVM kernel, without an install, for the same build, and the same kernel" do
      expect { kernel.upgrade("host_deb" => new_deb) }.to raise_error(described_class::Refused, "upgrade runs on the installed PVM kernel; install it first")
      install
      expect { kernel.upgrade("host_deb" => new_deb) }.to raise_error(described_class::Refused, "upgrade runs on the PVM kernel #{FakePvmHost::PVM}, and this is #{FakePvmHost::STOCK}")
      fake.boot(FakePvmHost::PVM, pti_off: true)
      expect { kernel.upgrade("host_deb" => deb) }.to raise_error(described_class::Refused, "the PVM kernel with sha256 #{deb["sha256"]} is already installed")
      same = "Package: #{FakePvmHost::PVM_PKG}\nrebuilt\n"
      fake.serve("https://example.com/same.deb", same)
      expect(kernel.upgrade("host_deb" => {"url" => "https://example.com/same.deb", "sha256" => Digest::SHA256.hexdigest(same)}))
        .to include("result" => "refused", "error" => "the package's kernel #{FakePvmHost::PVM} is already installed by this tool")
      expect(state).to include("state" => "armed", "host_deb_sha256" => deb["sha256"])
    end

    it "refuses when the stock entry no longer boots, or space is short" do
      on_pvm
      fake.avail_kib["/"] = 10
      expect { kernel.upgrade("host_deb" => new_deb) }.to raise_error(described_class::Refused, /\Aneeds about 2343 MiB free on \//)
      File.delete(File.join(root, "boot/vmlinuz-#{FakePvmHost::STOCK}"))
      expect { kernel.upgrade("host_deb" => new_deb) }.to raise_error(described_class::Refused, /no longer matches an entry/)
      expect(mutating).to eq []
    end

    it "refuses a wrong sha256 and keeps the state" do
      on_pvm
      expect(kernel.upgrade("host_deb" => new_deb.merge("sha256" => "2" * 64))).to include("result" => "refused", "step" => "verify")
      expect(state).to include("state" => "armed", "kver" => FakePvmHost::PVM, "host_deb_sha256" => deb["sha256"])
      expect(mutating).to eq []
    end

    it "un-arms when the new build fails" do
      on_pvm
      fake.send(:edit_env) { |env| env["next_entry"] = "ubicloud-pvm" }
      fail_at("apt-get", "install")
      expect(kernel.upgrade("host_deb" => new_deb)).to include("result" => "failed", "step" => "install_deb", "last_step" => "verify")
      expect(fake.grubenv).to eq("saved_entry" => stock_entry)
      expect(state["state"]).to eq "failed"
    end
  end
end
