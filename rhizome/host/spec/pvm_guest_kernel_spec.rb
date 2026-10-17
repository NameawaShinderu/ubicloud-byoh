# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "zlib"
require_relative "../lib/pvm_guest_kernel"
require_relative "../lib/pvm_host_kernel"

RSpec.describe PvmGuestKernel do
  let(:root) { Dir.mktmpdir("pvm-guest") }
  let(:files) { {} }
  let(:statuses) { {} }
  let(:log) { [] }
  # Plays curl: writes the file a spec registered for the URL, or exits
  # with the status a spec gave it.
  let(:runner) do
    lambda do |*argv|
      log << argv
      url = argv.last
      dest = argv[argv.index("-o") + 1]
      next ["curl: (#{statuses[url]}) failed", statuses[url]] if statuses.key?(url)

      File.binwrite(dest, files.fetch(url)) if files.key?(url)
      ["", 0]
    end
  end
  let(:guest) { described_class.new(root: root, runner: runner, now: -> { Time.utc(2026, 10, 17) }) }

  let(:kernel_url) { "https://example.com/pvm/vmlinux-pvm-amd64" }
  let(:config_url) { "https://example.com/pvm/config-pvm-amd64" }
  let(:required) { described_class::REQUIRED_CONFIG.map { |c| "CONFIG_#{c}=y\n" }.join }
  # The cocoonstack v0.1.0 guest: no 8250 driver, the virtio console.
  let(:hvc_config) { required + "# CONFIG_SERIAL_8250 is not set\nCONFIG_VIRTIO_CONSOLE=y\nCONFIG_HVC_DRIVER=y\n" }
  let(:serial_config) { required + "CONFIG_SERIAL_8250=y\nCONFIG_SERIAL_8250_CONSOLE=y\nCONFIG_VIRTIO_CONSOLE=y\n" }

  after { FileUtils.rm_rf(root) }

  def vmlinux(config: nil, banner: "Linux version 6.12.33-pvm (builder@cocoon) (gcc 13.3.0) #1 SMP")
    blob = "\x7fELF\x02\x01\x01".b + ("\0".b * 64) + banner.b + "\0".b
    if config
      gz = StringIO.new("".b)
      writer = Zlib::GzipWriter.new(gz)
      writer.write(config)
      writer.finish
      # A false start before the real one, as random kernel bytes can hold.
      blob += "IKCFG_ST\x1f\x8b\x08garbage".b + "IKCFG_ST".b + gz.string + "IKCFG_ED".b
    end
    blob
  end

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end

  def pin(url, content)
    files[url] = content
    {"url" => url, "sha256" => sha(content)}
  end

  def dir(*parts)
    File.join(root, "opt/pvm-guest", *parts)
  end

  def entries
    Dir.children(dir).sort
  end

  def run_main(command, params)
    out = StringIO.new
    status = described_class.main([command], stdin: StringIO.new(JSON.generate(params)), out: out, root: root, runner: runner, now: -> { Time.utc(2026, 10, 17) })
    [status, JSON.parse(out.string)]
  end

  describe "#download" do
    it "keeps a pinned kernel whose pinned config has the virtio console, for hvc0" do
      kernel = pin(kernel_url, vmlinux)
      status, result = run_main("download", "guest_kernel" => kernel, "guest_config" => pin(config_url, hvc_config), "guest_unchecked" => false)
      expect(status).to eq 0
      meta = {"sha256" => kernel["sha256"], "url" => kernel_url, "release" => "6.12.33-pvm", "console" => "hvc0", "config_checked" => true, "downloaded_at" => "2026-10-17T00:00:00Z"}
      expect(result).to eq("result" => "ok", "meta" => meta)
      expect(entries).to eq [".lock", kernel["sha256"]]
      expect(Dir.children(dir(kernel["sha256"])).sort).to eq %w[config meta.json vmlinux]
      expect(JSON.parse(File.read(dir(kernel["sha256"], "meta.json")))).to eq meta
      expect(File.binread(dir(kernel["sha256"], "vmlinux"))).to eq vmlinux
      expect(%w[vmlinux config meta.json].map { |f| File.stat(dir(kernel["sha256"], f)).mode & 0o777 }).to eq [0o644] * 3
      expect([dir, dir(kernel["sha256"])].map { |d| File.stat(d).mode & 0o777 }).to eq [0o755, 0o755]
      tmp = dir("#{kernel["sha256"]}.tmp")
      expect(log).to eq [
        [*described_class::CURL, "-o", "#{tmp}/vmlinux", kernel_url],
        [*described_class::CURL, "-o", "#{tmp}/config", config_url],
      ]
    end

    it "gives ttyS0 to a guest with the 8250 serial console" do
      result = guest.download("guest_kernel" => pin(kernel_url, vmlinux), "guest_config" => pin(config_url, serial_config))
      expect(result["meta"]).to include("console" => "ttyS0", "config_checked" => true)
    end

    it "reads the config the kernel embeds when none is pinned" do
      kernel = pin(kernel_url, vmlinux(config: serial_config))
      expect(guest.download("guest_kernel" => kernel)["meta"]).to include("console" => "ttyS0", "config_checked" => true)
      expect(Dir.children(dir(kernel["sha256"])).sort).to eq %w[meta.json vmlinux]
    end

    it "takes a kernel with no config only when the operator accepted it unchecked, on hvc0" do
      kernel = pin(kernel_url, vmlinux)
      status, result = run_main("download", "guest_kernel" => kernel, "guest_unchecked" => false)
      expect([status, result]).to eq [2, {"result" => "refused", "error" => "the guest kernel has no embedded config (CONFIG_IKCONFIG) and none is pinned, so nothing can check that it boots PVM VMs"}]
      expect(entries).to eq [".lock", "#{kernel["sha256"]}.refused"]

      result = guest.download("guest_kernel" => kernel, "guest_unchecked" => true)
      expect(result["meta"]).to include("console" => "hvc0", "config_checked" => false, "release" => "6.12.33-pvm")
      expect(entries).to eq [".lock", kernel["sha256"]]
    end

    it "records no release when the kernel has no banner" do
      kernel = pin(kernel_url, vmlinux(banner: "no banner", config: hvc_config))
      expect(guest.download("guest_kernel" => kernel)["meta"]["release"]).to be_nil
    end

    it "refuses a config without what PVM VMs need, leaving only the refusal" do
      kernel = pin(kernel_url, vmlinux)
      config = pin(config_url, hvc_config.sub("CONFIG_VFAT_FS=y\n", "").sub("CONFIG_VIRTIO_CONSOLE=y\n", ""))
      status, result = run_main("download", "guest_kernel" => kernel, "guest_config" => config)
      expect([status, result]).to eq [2, {"result" => "refused", "error" => "the guest kernel config lacks (=y): VFAT_FS SERIAL_8250_CONSOLE|VIRTIO_CONSOLE"}]
      expect(entries).to eq [".lock", "#{kernel["sha256"]}.refused"]
      expect(JSON.parse(File.read(dir("#{kernel["sha256"]}.refused")))).to eq("sha256" => kernel["sha256"], "error" => result["error"], "at" => "2026-10-17T00:00:00Z")
    end

    it "refuses a kernel whose sha256 is not the pin and leaves no directory" do
      kernel = pin(kernel_url, vmlinux)
      files[kernel_url] = vmlinux + "tampered".b
      status, result = run_main("download", "guest_kernel" => kernel, "guest_unchecked" => true)
      expect(status).to eq 2
      expect(result["error"]).to eq "the guest kernel #{kernel_url} has sha256 #{sha(vmlinux + "tampered".b)}, not the pinned #{kernel["sha256"]}"
      expect(entries).to eq [".lock", "#{kernel["sha256"]}.refused"]
    end

    it "refuses a config whose sha256 is not the pin" do
      config = pin(config_url, hvc_config)
      files[config_url] = serial_config
      expect { guest.download("guest_kernel" => pin(kernel_url, vmlinux), "guest_config" => config) }
        .to raise_error(described_class::Refused, /the guest kernel config #{config_url} has sha256 #{sha(serial_config)}, not the pinned/)
    end

    it "refuses a kernel that is not an ELF vmlinux" do
      expect { guest.download("guest_kernel" => pin(kernel_url, "MZ bzImage"), "guest_unchecked" => true) }
        .to raise_error(described_class::Refused, "the guest kernel is not an ELF vmlinux (cloud-hypervisor boots it directly)")
    end

    it "refuses an http redirect, a malformed URL and an oversized file, and retries other curl failures" do
      kernel = pin(kernel_url, vmlinux)
      statuses[kernel_url] = 1
      status, result = run_main("download", "guest_kernel" => kernel, "guest_unchecked" => true)
      expect([status, result["error"]]).to eq [2, "downloading the guest kernel #{kernel_url} failed (curl exit 1; an http:// URL or redirect is refused, only https is fetched): curl: (1) failed"]
      statuses[kernel_url] = 63
      expect(run_main("download", "guest_kernel" => kernel, "guest_unchecked" => true)).to match [2, include("error" => /curl exit 63; the file is larger than the 536870912-byte cap/)]
      statuses[kernel_url] = 3
      expect(run_main("download", "guest_kernel" => kernel, "guest_unchecked" => true)).to match [2, include("error" => /curl exit 3; the URL is malformed/)]

      statuses[kernel_url] = 6
      status, result = run_main("download", "guest_kernel" => kernel, "guest_unchecked" => true)
      expect([status, result]).to eq [3, {"result" => "failed", "error" => "downloading the guest kernel #{kernel_url} failed (curl exit 6): curl: (6) failed"}]
      # A failure that may pass again clears the last refusal and leaves nothing.
      expect(entries).to eq [".lock"]

      statuses.delete(kernel_url)
      files.delete(kernel_url)
      expect(run_main("download", "guest_kernel" => kernel, "guest_unchecked" => true)).to eq [3, {"result" => "failed", "error" => "downloading the guest kernel #{kernel_url} gave no file"}]
    end

    it "refuses a file over the cap even when curl kept it" do
      stub_const("#{described_class}::MAX_BYTES", 10)
      expect { guest.download("guest_kernel" => pin(kernel_url, vmlinux), "guest_unchecked" => true) }
        .to raise_error(described_class::Refused, "the guest kernel #{kernel_url} is larger than the 10-byte cap")
    end

    it "keeps a verified kernel as it is and downloads one that no longer matches again" do
      kernel = pin(kernel_url, vmlinux(config: hvc_config))
      guest.download("guest_kernel" => kernel)
      log.clear
      expect(guest.download("guest_kernel" => kernel)).to include("result" => "ok", "note" => "already downloaded")
      expect(log).to eq []

      File.binwrite(dir(kernel["sha256"], "vmlinux"), "corrupt")
      expect(guest.download("guest_kernel" => kernel)).not_to include("note")
      expect(log.size).to eq 1
      expect(File.binread(dir(kernel["sha256"], "vmlinux"))).to eq vmlinux(config: hvc_config)

      File.unlink(dir(kernel["sha256"], "vmlinux"))
      expect(guest.download("guest_kernel" => kernel)["result"]).to eq "ok"
      expect(log.size).to eq 2
    end

    it "refuses parameters it cannot use before downloading anything" do
      good = {"url" => kernel_url, "sha256" => "a" * 64}
      {
        {} => "guest_kernel {url, sha256} is required",
        {"guest_kernel" => good.merge("url" => "http://example.com/vmlinux")} => "guest_kernel url must be an https URL",
        {"guest_kernel" => good.merge("url" => 7)} => "guest_kernel url must be an https URL",
        {"guest_kernel" => good.merge("sha256" => "A" * 64)} => "guest_kernel sha256 must be 64 lowercase hex digits",
        {"guest_kernel" => good, "guest_config" => "https://example.com/config"} => "guest_config {url, sha256} is required",
      }.each do |params, error|
        expect(run_main("download", params)).to eq [2, {"result" => "refused", "error" => error}]
      end
      expect(log).to eq []
      expect(File.exist?(dir)).to be false
    end
  end

  describe "#show" do
    it "says whether a pin is ready, refused or absent" do
      kernel = pin(kernel_url, vmlinux(config: hvc_config))
      expect(run_main("show", "sha256" => kernel["sha256"])).to eq [0, {"result" => "ok", "state" => "absent"}]
      files[kernel_url] = "tampered"
      expect { guest.download("guest_kernel" => kernel) }.to raise_error(described_class::Refused)
      expect(guest.show("sha256" => kernel["sha256"])).to eq("result" => "ok", "state" => "refused", "error" => "the guest kernel #{kernel_url} has sha256 #{sha("tampered")}, not the pinned #{kernel["sha256"]}")
      files[kernel_url] = vmlinux(config: hvc_config)
      meta = guest.download("guest_kernel" => kernel)["meta"]
      expect(guest.show("sha256" => kernel["sha256"])).to eq("result" => "ok", "state" => "ready", "meta" => meta)
    end

    it "does not take a directory without its kernel or with another sha's meta as ready" do
      sha = "c" * 64
      FileUtils.mkdir_p(dir(sha))
      File.write(dir(sha, "meta.json"), JSON.generate("sha256" => sha))
      expect(guest.show("sha256" => sha)["state"]).to eq "absent"
      File.write(dir(sha, "vmlinux"), "x")
      File.write(dir(sha, "meta.json"), JSON.generate("sha256" => "d" * 64))
      expect(guest.show("sha256" => sha)["state"]).to eq "absent"
      File.write(dir(sha, "meta.json"), "[1]")
      expect(guest.show("sha256" => sha)["state"]).to eq "absent"
      File.write(dir(sha, "meta.json"), "{")
      expect(guest.show("sha256" => sha)["state"]).to eq "absent"
      expect(run_main("show", "sha256" => "x")).to eq [2, {"result" => "refused", "error" => "sha256 must be 64 lowercase hex digits"}]
    end
  end

  describe "#gc" do
    let(:shas) { %w[1 2 3 4 5].map { |c| c * 64 } }

    before do
      shas.each do |sha|
        FileUtils.mkdir_p(dir(sha))
        File.write(dir(sha, "vmlinux"), sha)
      end
      FileUtils.mkdir_p(dir("#{"6" * 64}.tmp"))
      File.write(dir("#{"7" * 64}.refused"), "{}")
      File.write(dir("#{shas[0]}.refused"), "{}")
      File.write(dir("notes"), "")
      FileUtils.mkdir_p(File.join(root, "vm/vm1"))
      File.write(File.join(root, "vm/vm1/prep.json"), JSON.generate("vm_name" => "vm1", "pvm" => {"kernel_sha256" => shas[1], "root" => "/dev/vda1"}))
      FileUtils.mkdir_p(File.join(root, "vm/vm2"))
      File.write(File.join(root, "vm/vm2/prep.json"), JSON.generate("vm_name" => "vm2"))
      FileUtils.mkdir_p(File.join(root, "etc/systemd/system"))
      # A VM whose prep.json already names a new pin keeps booting the
      # old kernel its unit names until its next stop and start.
      File.write(File.join(root, "etc/systemd/system/vm3.service"), "ExecStart=/opt/cloud-hypervisor/v46.0/cloud-hypervisor --kernel /opt/pvm-guest/#{shas[2]}/vmlinux\n")
      File.write(File.join(root, "etc/systemd/system/other.service"), "ExecStart=/bin/true\n")
    end

    it "keeps the kept kernels and those a VM's prep.json or unit names, and nothing else" do
      status, result = run_main("gc", "keep" => [shas[3]])
      expect(status).to eq 0
      expect(result).to eq("result" => "ok", "removed" => [shas[0], shas[4], "7" * 64], "kept" => shas[1..3])
      expect(entries).to eq [".lock", *shas[1..3], "#{"6" * 64}.tmp", "notes"]
      expect(guest.gc({})["removed"]).to eq [shas[3]]
    end

    it "removes nothing while a download holds the lock" do
      FileUtils.mkdir_p(dir)
      File.open(dir(".lock"), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        expect(guest.gc("keep" => [])).to eq("result" => "ok", "removed" => [], "skipped" => "a download holds opt/pvm-guest/.lock")
      end
      expect(entries).to include(*shas)
    end

    it "removes nothing when a VM's prep.json cannot be read" do
      File.write(File.join(root, "vm/vm2/prep.json"), "{")
      expect(guest.gc("keep" => [])).to include("removed" => [], "skipped" => start_with("cannot read the VMs' references: "))
      File.write(File.join(root, "vm/vm2/prep.json"), "[]")
      expect(guest.gc("keep" => [])).to include("removed" => [], "skipped" => start_with("cannot read the VMs' references: "))
      expect(entries).to include(*shas)
    end

    it "refuses a keep list that is not shas" do
      expect(run_main("gc", "keep" => "1" * 64)).to eq [2, {"result" => "refused", "error" => "keep must be a list of sha256 values"}]
      expect(run_main("gc", "keep" => ["x"])).to eq [2, {"result" => "refused", "error" => "keep must be 64 lowercase hex digits"}]
      expect(entries).to include(*shas)
    end
  end

  describe ".main" do
    it "refuses usage it does not know and parameters that are not a JSON object" do
      out = StringIO.new
      expect(described_class.main(%w[download extra], stdin: StringIO.new(""), out: out)).to eq 2
      expect(JSON.parse(out.string)).to eq("result" => "refused", "error" => "usage: download-pvm-guest-kernel download|show|gc, with JSON parameters on stdin")
      out = StringIO.new
      expect(described_class.main(["show"], stdin: StringIO.new("[1]"), out: out, root: root)).to eq 2
      expect(JSON.parse(out.string)["error"]).to eq "the parameters must be a JSON object"
      out = StringIO.new
      expect(described_class.main(["show"], stdin: StringIO.new("{"), out: out, root: root)).to eq 2
      expect(JSON.parse(out.string)["error"]).to start_with "the parameters are not JSON: "
    end

    it "reports an unexpected error with exit 1" do
      File.write(File.join(root, "blocker"), "")
      out = StringIO.new
      expect(described_class.main(["gc"], stdin: StringIO.new(""), out: out, root: File.join(root, "blocker"))).to eq 1
      expect(JSON.parse(out.string)["error"]).to start_with "Errno::"
    end

    it "runs curl through Open3 by default" do
      allow(Open3).to receive(:capture2e).and_return(["oops", instance_double(Process::Status, exitstatus: 6)])
      expect { described_class.new(root: root).download("guest_kernel" => {"url" => kernel_url, "sha256" => sha(vmlinux)}, "guest_unchecked" => true) }
        .to raise_error(described_class::Failed, "downloading the guest kernel #{kernel_url} failed (curl exit 6): oops")
    end
  end

  describe "parity" do
    let(:script) { File.read(File.expand_path("../../../scripts/byoh/test/real/pvm-go-no-go.sh", __dir__)) }

    it "requires the go/no-go's guest config and picks its console the same way" do
      expect(script[/^  for c in ([A-Z0-9_ ]+); do$/, 1].split).to eq described_class::REQUIRED_CONFIG
      expect(script).to match(/CONFIG_SERIAL_8250_CONSOLE=y.*\n\s+guest_console=ttyS0\n.*CONFIG_VIRTIO_CONSOLE=y.*\n\s+guest_console=hvc0/)
    end

    it "fetches with the host kernel installer's curl limits" do
      expect(described_class::CURL).to eq PvmHostKernel::CURL
    end

    it "requires what the control plane's pin check requires" do
      source = File.read(File.expand_path("../../../lib/byoh_pvm_policy.rb", __dir__))
      expect(source[/REQUIRED_GUEST_CONFIG = %w\[([A-Z0-9_ ]+)\]/, 1].split).to eq described_class::REQUIRED_CONFIG
      expect(source).to include('IKCONFIG_MAGIC = "IKCFG_ST\x1f\x8b\x08".b')
    end
  end
end
