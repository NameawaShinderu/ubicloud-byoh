# frozen_string_literal: true

require_relative "../spec_helper"
require "open3"
require "tmpdir"

# The PVM go/no-go script, scripts/byoh/test/real/pvm-go-no-go.sh (L4-T1,
# docs/byoh/NO_KVM.md section 14), runs only on a throwaway host, so these
# checks guard what can drift without running it.
RSpec.describe ByohVirtTiers, "pvm" do
  let(:path) { File.expand_path("../../scripts/byoh/test/real/pvm-go-no-go.sh", __dir__) }
  let(:script) { File.read(path) }

  it "pins the cloud-hypervisor builds rhizome pins" do
    versions = script[/^CH_VERSIONS="([^"]*)"$/, 1].split
    expect(versions).to eq %w[46.0 53.0]
    versions.each do |v|
      pin = script[/^CH_SHA256_#{v.split(".").first}="(\h{64})"$/, 1]
      expect(pin).to eq Prog::DownloadCloudHypervisor::HASHES[["ch-bin", "x64", v]]
    end
  end

  it "pins the default PVM release files" do
    %w[HOST_DEB GUEST_KERNEL GUEST_CONFIG].each do |f|
      expect(script[/^DEFAULT_#{f}_SHA256=(\h{64})$/, 1]).not_to be_nil
    end
  end

  it "keeps pvm unoffered until the test reports GO" do
    expect(described_class::SHIPPED).not_to include("pvm")
  end

  # These run the script, which needs bash. The alpine test image has
  # none unless the run adds it, so they skip there instead of failing.
  context "when run by bash" do
    let(:bash) { ENV.fetch("PATH", "").split(":").map { File.join(it, "bash") }.find { File.executable?(it) } }

    before { skip "bash is not installed" unless bash }

    it "refuses to do anything without BYOH_REAL_HOST=1" do
      out, status = Open3.capture2e({"BYOH_REAL_HOST" => nil}, bash, path, "install")
      expect(status.exitstatus).to eq 2
      expect(out).to include("refusing")
    end

    # Runs the script's own shell functions, under its set -euo pipefail.
    def run_functions(names, call, vars = {})
      defs = names.map { script[/^#{it}\(\) \{[^\n]*\n.*?^\}\n/m] || raise("no function #{it}") }
      env = vars.map { |k, v| "#{k}=#{Shellwords.escape(v)}\n" }.join
      Open3.capture2e(bash, "-c", "set -euo pipefail\n#{env}#{defs.join}#{call}")
    end

    it "lets only pcieport and the operator's PVM_UNCHECKED_DRIVERS go unchecked" do
      allowed = %w[pcieport vmbus vif].select do |drv|
        run_functions(%w[driver_unchecked_ok], "driver_unchecked_ok #{drv}", PVM_UNCHECKED_DRIVERS: "hv_x vmbus")[1].success?
      end
      expect(allowed).to eq %w[pcieport vmbus]
      expect(run_functions(%w[driver_unchecked_ok], "driver_unchecked_ok vmbus")[1].success?).to be false
    end

    it "fetches again when a cached file came from another URL" do
      Dir.mktmpdir do |dir|
        curl = <<~SH
          curl() {
            local o="" u=""
            while [ $# -gt 0 ]; do
              case $1 in -o) o=$2; shift ;; --retry) shift ;; -*) ;; *) u=$1 ;; esac
              shift
            done
            echo "$u" >>"$DIR/calls"
            echo "from $u" >"$o"
          }
        SH
        call = "#{curl}fetch https://a/f \"$DIR/f\"\nfetch https://a/f \"$DIR/f\"\nfetch https://b/f \"$DIR/f\"\ncat \"$DIR/f\""
        out, status = run_functions(%w[die fetch], call, DIR: dir)
        expect([out, status.success?]).to eq ["from https://b/f\n", true]
        expect(File.read("#{dir}/calls")).to eq "https://a/f\nhttps://b/f\n"
      end
    end

    describe "the release pins" do
      let(:defaults) { script.scan(/^(DEFAULT_\w+)=(\S+)$/).to_h }
      let(:release) { {PVM_RELEASE_URL: defaults["DEFAULT_RELEASE_URL"], PVM_HOST_DEB: defaults["DEFAULT_HOST_DEB"], PVM_GUEST_KERNEL: defaults["DEFAULT_GUEST_KERNEL"], PVM_GUEST_CONFIG: defaults["DEFAULT_GUEST_CONFIG"]} }

      def pins(vars)
        run_functions(%w[die default_pins require_pins], "default_pins\nrequire_pins\necho \"$PVM_HOST_DEB_SHA256\"", defaults.merge(vars))
      end

      it "default to the recorded sums for the default release" do
        out, status = pins(release)
        expect(status.success?).to be true
        expect(out).to eq "#{defaults["DEFAULT_HOST_DEB_SHA256"]}\n"
      end

      it "are required when the release URL or a file name is overridden" do
        out, status = pins(release.merge(PVM_RELEASE_URL: "https://example.com/my-pvm"))
        expect(status.exitstatus).to eq 1
        expect(out).to include("no sha256 pin (64 lowercase hex) for: PVM_HOST_DEB_SHA256 PVM_GUEST_KERNEL_SHA256 PVM_GUEST_CONFIG_SHA256.")
        sums = {PVM_HOST_DEB_SHA256: "a" * 64, PVM_GUEST_KERNEL_SHA256: "b" * 64, PVM_GUEST_CONFIG_SHA256: "c" * 64}
        out, status = pins(release.merge(PVM_GUEST_KERNEL: "vmlinux-mine", **sums))
        expect([out, status.success?]).to eq ["#{"a" * 64}\n", true]
      end
    end

    describe "kernel_has_driver" do
      let(:modules) { Dir.mktmpdir }

      after { FileUtils.rm_rf(modules) }

      def lookup(drv)
        _, status = run_functions(%w[kernel_has_driver], "kernel_has_driver 6.12-pvm #{drv}", MODULES_DIR: modules)
        status.success?
      end

      before do
        FileUtils.mkdir_p("#{modules}/6.12-pvm")
        File.write("#{modules}/6.12-pvm/modules.builtin", "kernel/fs/ext4/ext4.ko\nkernel/drivers/virtio/virtio_pci.ko\n")
        # Larger than a pipe buffer, with the hits near the start: a
        # `| grep -q` here dies of SIGPIPE under pipefail.
        filler = (1..20000).map { "kernel/drivers/misc/filler-#{it}.ko: kernel/lib/dep.ko.zst\n" }.join
        File.write("#{modules}/6.12-pvm/modules.dep", "kernel/drivers/net/ethernet/amazon/ena/ena.ko.zst:\nkernel/drivers/nvme/host/nvme.ko.zst: kernel/drivers/nvme/host/nvme-core.ko.zst\nkernel/drivers/nvme/host/nvme-core.ko.zst:\n" + filler)
      end

      it "finds a loadable module early in a large modules.dep" do
        expect(File.size("#{modules}/6.12-pvm/modules.dep")).to be > 65536
        expect(%w[ena nvme nvme-core nvme_core].map { lookup(it) }).to all be true
      end

      it "finds built-in drivers and the sysfs names that differ" do
        expect(%w[ext4 virtio-pci].map { lookup(it) }).to all be true
      end

      it "maps the Xen and USB core sysfs names to their modules" do
        File.write("#{modules}/6.12-pvm/modules.builtin", "kernel/drivers/usb/core/usbcore.ko\nkernel/drivers/net/xen-netfront.ko\nkernel/drivers/block/xen-blkfront.ko\n")
        expect(%w[vif vbd usb hub].map { lookup(it) }).to all be true
      end

      it "reports missing drivers and kernels" do
        expect(lookup("xfs")).to be false
        _, status = run_functions(%w[kernel_has_driver], "kernel_has_driver 6.8-stock ena", MODULES_DIR: modules)
        expect(status.success?).to be false
      end
    end
  end
end
