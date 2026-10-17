# frozen_string_literal: true

require_relative "../spec_helper"
require "open3"
require "shellwords"
require "tmpdir"

# The read-only PVM checks of scripts/byoh/bootstrap-data-plane.sh
# --tier pvm (pvm_checks), run as the script's own shell function
# against a fake host tree (HOST_ROOT).
# rubocop:disable RSpec/DescribeClass
# The subject is a shell script, not a class.
RSpec.describe "bootstrap-data-plane.sh --tier pvm" do
  # rubocop:enable RSpec/DescribeClass
  let(:path) { File.expand_path("../../scripts/byoh/bootstrap-data-plane.sh", __dir__) }
  let(:script) { File.read(path) }
  let(:bash) { ENV.fetch("PATH", "").split(":").map { File.join(it, "bash") }.find { File.executable?(it) } }
  let(:root) { Dir.mktmpdir }

  after { FileUtils.rm_rf(root) }

  # The alpine test image has no bash unless the run adds it.
  before { skip "bash is not installed" unless bash }

  def write(rel, content)
    FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
    File.binwrite(File.join(root, rel), content)
  end

  # A stock AWS m6i kernel: no vmx, Meltdown not affected, Secure Boot
  # off, lockdown none, GRUB.
  def stock_host
    write("proc/cpuinfo", "processor\t: 0\nflags\t\t: fpu vme hypervisor pdpe1gb\n")
    write("sys/devices/system/cpu/vulnerabilities/meltdown", "Not affected\n")
    write("sys/kernel/security/lockdown", "[none] integrity confidentiality\n")
    write("sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d0-aa0d-00e098032b8c", "\x06\x00\x00\x00\x00".b)
    write("boot/grub/grub.cfg", "menuentry 'Ubuntu' {\n}\n")
    write("etc/default/grub", "GRUB_DEFAULT=0\n")
  end

  # Runs pvm_checks under the script's set -euo pipefail; uname answers
  # for arch.
  def pvm_checks(arch: "x86_64")
    fn = script[/^pvm_checks\(\) \{\n.*?^\}\n/m] or raise "no pvm_checks"
    uname = "uname() { case $1 in -m) echo #{arch} ;; -r) echo 7.0.0-1014-aws ;; esac; }\n"
    out, status = Open3.capture2e(bash, "-c", "set -euo pipefail\nHOST_ROOT=#{Shellwords.escape(root)}\n#{uname}#{fn}pvm_checks\necho \"rc=0 loaded=$PVM_KERNEL_LOADED\"")
    [out, status.success?]
  end

  it "passes a stock host, and says the control plane installs the PVM kernel" do
    stock_host
    out, ok = pvm_checks
    expect(ok).to be true
    expect(out).to eq "  stock kernel 7.0.0-1014-aws: the control plane installs the site's PVM host kernel after registration (--install-pvm-kernel)\n" \
      "  PVM checks passed: x86_64 without vmx/svm, Secure Boot off, Meltdown not affected\nrc=0 loaded=0\n"
  end

  it "says a host whose kvm_pvm is loaded needs no install, without GRUB" do
    stock_host
    FileUtils.mkdir_p(File.join(root, "sys/module/kvm_pvm"))
    FileUtils.rm_rf(File.join(root, "boot"))
    out, ok = pvm_checks
    expect([ok, out.lines.first, out.lines.last]).to eq [true, "  kvm_pvm is loaded: a PVM host kernel runs; register without --install-pvm-kernel\n", "rc=0 loaded=1\n"]
  end

  it "refuses each hard refusal, read-only" do
    {
      "ERROR: PVM hosts must be x86_64; this is aarch64." => [-> {}, "aarch64"],
      "ERROR: the CPU has the vmx or svm flag" => [-> { write("proc/cpuinfo", "flags\t\t: fpu vmx\n") }],
      "ERROR: /dev/kvm exists on this stock kernel" => [-> { write("dev/kvm", "") }],
      "ERROR: Secure Boot is on" => [-> { write("sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d0-aa0d-00e098032b8c", "\x06\x00\x00\x00\x01".b) }],
      "ERROR: this CPU's Meltdown status is \"Mitigation: PTI\"" => [-> { write("sys/devices/system/cpu/vulnerabilities/meltdown", "Mitigation: PTI\n") }],
      "ERROR: this CPU's Meltdown status is \"unknown\"" => [-> { FileUtils.rm(File.join(root, "sys/devices/system/cpu/vulnerabilities/meltdown")) }],
      "ERROR: there is no /boot/grub/grub.cfg" => [-> { FileUtils.rm_rf(File.join(root, "boot")) }],
      "ERROR: GRUB_SAVEDEFAULT=true in /etc/default/grub.d/50-x.cfg would make a one-time PVM boot the default" => [-> { write("etc/default/grub.d/50-x.cfg", "GRUB_SAVEDEFAULT=\"true\"\n") }],
    }.each do |message, (setup, arch)|
      FileUtils.rm_rf(Dir.glob(File.join(root, "*")))
      stock_host
      setup.call
      tree = Dir.glob("**/*", base: root).sort.to_h { [it, File.file?(File.join(root, it)) ? File.binread(File.join(root, it)) : :dir] }
      out, ok = pvm_checks(arch: arch || "x86_64")
      expect([ok, out]).to match [false, include(message)]
      expect(out).not_to include "rc=0"
      expect(Dir.glob("**/*", base: root).sort.to_h { [it, File.file?(File.join(root, it)) ? File.binread(File.join(root, it)) : :dir] }).to eq tree
    end
  end

  it "warns of a kernel lockdown, and passes" do
    stock_host
    write("sys/kernel/security/lockdown", "none [integrity] confidentiality\n")
    out, ok = pvm_checks
    expect(ok).to be true
    expect(out).to include "  WARNING: kernel lockdown is integrity; the unsigned kvm_pvm module does not load under lockdown"
  end

  it "names --install-pvm-kernel in the next steps of a stock pvm host" do
    expect(script).to include 'pvm_install=" --install-pvm-kernel"'
    expect(script).to include 'echo "This host was prepared for --tier $TIER: add --virt-tier $TIER$pvm_install --accept-fallback"'
    expect(script).not_to include "boot a PVM host kernel and modprobe kvm_pvm first"
  end
end
