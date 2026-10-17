# frozen_string_literal: true

require "digest"
require "stringio"
require "tmpdir"
require "zlib"

RSpec.describe ByohPvmPolicy do
  # What cocoonstack/pvm v0.1.0's guest config has: no 8250 serial
  # driver, the virtio console instead.
  let(:hvc_config) { described_class::REQUIRED_GUEST_CONFIG.map { "CONFIG_#{it}=y\n" }.join + "# CONFIG_SERIAL_8250 is not set\nCONFIG_VIRTIO_CONSOLE=y\nCONFIG_HVC_DRIVER=y\n" }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  def gzip(text)
    io = StringIO.new("".b)
    gz = Zlib::GzipWriter.new(io)
    gz.write(text)
    gz.close
    io.string
  end

  # A vmlinux-like blob with the config embedded as kernel/configs.c
  # embeds it, after a false start that is not gzip.
  def vmlinux(config)
    "\x7FELF".b + ("\0" * 4096) + "IKCFG_ST\x1f\x8b\x08garbage".b + ("\0" * 64) + "IKCFG_ST".b + gzip(config) + "IKCFG_ED".b + ("\0" * 4096)
  end

  def pin(name, content)
    {"url" => "https://example.com/#{name}", "sha256" => Digest::SHA256.hexdigest(content)}
  end

  # Serves files by URL, recording what was fetched.
  def fetcher(files, fetched = [])
    ByohArtifactFetch.new(runner: lambda { |*argv|
      fetched << argv.last
      File.binwrite(argv[argv.index("-o") + 1], files.fetch(argv.last))
      ["", instance_double(Process::Status, success?: true, exitstatus: 0)]
    })
  end

  describe ".guest_console" do
    it "picks hvc0 without the 8250 serial driver and ttyS0 with it" do
      expect(described_class.guest_console(hvc_config)).to eq "hvc0"
      expect(described_class.guest_console(hvc_config + "CONFIG_SERIAL_8250_CONSOLE=y\n")).to eq "ttyS0"
    end

    it "refuses a config without what PVM VMs need" do
      config = hvc_config.sub("CONFIG_VFAT_FS=y\n", "CONFIG_VFAT_FS=m\n").sub("CONFIG_VIRTIO_CONSOLE=y\n", "")
      expect { described_class.guest_console(config) }.to raise_error(described_class::Refused, "the guest kernel config lacks (=y): VFAT_FS SERIAL_8250_CONSOLE|VIRTIO_CONSOLE")
    end

    it "checks what the go/no-go test checks" do
      script = File.read(File.expand_path("../../scripts/byoh/test/real/pvm-go-no-go.sh", __dir__))
      expect(script[/^  for c in ([A-Z0-9_ ]+); do$/, 1].split).to eq described_class::REQUIRED_GUEST_CONFIG
    end
  end

  describe ".extract_ikconfig" do
    it "reads the config a vmlinux embeds" do
      File.binwrite("#{dir}/vmlinux", vmlinux(hvc_config))
      expect(described_class.extract_ikconfig("#{dir}/vmlinux")).to eq hvc_config
    end

    it "is nil for a vmlinux without one" do
      File.binwrite("#{dir}/vmlinux", "\x7FELF".b + "IKCFG_ST\x1f\x8b\x08broken".b)
      expect(described_class.extract_ikconfig("#{dir}/vmlinux")).to be_nil
    end
  end

  describe ".merge" do
    let(:deb) { {"url" => "https://example.com/h.deb", "sha256" => "a" * 64} }
    let(:kernel) { {"url" => "https://example.com/vmlinux", "sha256" => "b" * 64} }
    let(:config) { {"url" => "https://example.com/config", "sha256" => "c" * 64} }

    it "needs the host package and the guest kernel, as https pins" do
      expect { described_class.merge(nil, {"host_deb" => deb}) }.to raise_error(described_class::Refused, "pin the PVM guest kernel: --pvm-guest-kernel URL --pvm-guest-kernel-sha256 HEX")
      expect { described_class.merge(nil, {"guest_kernel" => kernel}) }.to raise_error(described_class::Refused, "pin the PVM host kernel package: --pvm-host-deb URL --pvm-host-deb-sha256 HEX")
      expect { described_class.merge(nil, {"host_deb" => deb.merge("url" => "http://example.com/h.deb"), "guest_kernel" => kernel}) }
        .to raise_error(described_class::Refused, "the PVM host kernel package URL http://example.com/h.deb is not https")
      expect { described_class.merge(nil, {"host_deb" => deb, "guest_kernel" => kernel.merge("sha256" => "B" * 64)}) }
        .to raise_error(described_class::Refused, "the sha256 of the PVM guest kernel must be 64 lowercase hex digits")
      expect(described_class.merge(nil, {"host_deb" => deb, "guest_kernel" => kernel})).to eq("host_deb" => deb, "guest_kernel" => kernel, "guest_unchecked" => false)
    end

    it "keeps a config with its kernel only" do
      old = {"host_deb" => deb, "guest_kernel" => kernel, "guest_config" => config, "config_checked" => true, "guest_console" => "hvc0"}
      expect(described_class.merge(old, {"host_deb" => deb.merge("sha256" => "d" * 64)})).to eq old.merge("host_deb" => deb.merge("sha256" => "d" * 64))
      expect(described_class.merge(old, {"guest_kernel" => kernel})).to eq old
      new_kernel = kernel.merge("sha256" => "e" * 64)
      expect(described_class.merge(old, {"guest_kernel" => new_kernel})).to eq("host_deb" => deb, "guest_kernel" => new_kernel, "guest_unchecked" => false, "config_checked" => true, "guest_console" => "hvc0")
      expect(described_class.merge(old, {"guest_unchecked" => true}).slice(*described_class::GUEST_KEYS)).to eq("guest_kernel" => kernel, "guest_unchecked" => true)
      unchecked = old.except("guest_config").merge("guest_unchecked" => true)
      expect(described_class.merge(unchecked, {"guest_config" => config}).slice(*described_class::GUEST_KEYS)).to eq("guest_kernel" => kernel, "guest_config" => config)
      expect { described_class.merge(old, {"guest_config" => config, "guest_unchecked" => true}) }
        .to raise_error(described_class::Refused, "pass either --pvm-guest-config or --pvm-guest-unchecked, not both")
    end

    it "keeps the drivers the operator vouches for, and drops them with an empty list" do
      old = described_class.merge(nil, {"host_deb" => deb, "guest_kernel" => kernel, "unchecked_drivers" => %w[hv_storvsc hv_netvsc hv_storvsc]})
      expect(old["unchecked_drivers"]).to eq %w[hv_storvsc hv_netvsc]
      expect(described_class.unchecked_drivers(old)).to eq %w[hv_storvsc hv_netvsc]
      expect(described_class.merge(old, {"host_deb" => deb.merge("sha256" => "d" * 64)})["unchecked_drivers"]).to eq %w[hv_storvsc hv_netvsc]
      expect(described_class.merge(old, {"unchecked_drivers" => []})).not_to have_key("unchecked_drivers")
      expect(described_class.unchecked_drivers(old.except("unchecked_drivers"))).to eq []
      expect(described_class.unchecked_drivers(nil)).to eq []
      [["bad name"], ["a", nil], ["x/y"]].each do |list|
        expect { described_class.merge(old, {"unchecked_drivers" => list}) }
          .to raise_error(described_class::Refused, "--pvm-unchecked-drivers takes sysfs driver names, such as hv_storvsc,hv_netvsc")
      end
    end

    it "says whether a pinned file or the guest config check changed" do
      old = {"host_deb" => deb, "guest_kernel" => kernel, "guest_unchecked" => false}
      expect(described_class.files_changed?(old, old.merge("unchecked_drivers" => ["hv_storvsc"]))).to be false
      expect(described_class.files_changed?(old, old.merge("host_deb" => deb.merge("sha256" => "d" * 64)))).to be true
      expect(described_class.files_changed?(old, old.merge("guest_unchecked" => true))).to be true
      expect(described_class.files_changed?(nil, old)).to be true
    end
  end

  describe ".verify" do
    let(:deb_body) { "host kernel package" }
    let(:kernel_body) { vmlinux(hvc_config) }
    let(:pins) { {"host_deb" => pin("h.deb", deb_body), "guest_kernel" => pin("vmlinux", kernel_body), "guest_unchecked" => false} }
    let(:files) { {"https://example.com/h.deb" => deb_body, "https://example.com/vmlinux" => kernel_body} }

    it "downloads every new pin and checks the config the guest kernel embeds" do
      fetched = []
      expect(described_class.verify(nil, pins, fetcher: fetcher(files, fetched), dir:)).to eq pins.merge("config_checked" => true, "guest_console" => "hvc0")
      expect(fetched).to eq ["https://example.com/h.deb", "https://example.com/vmlinux"]
    end

    it "reads a pinned config instead, and downloads only what changed" do
      config = hvc_config + "CONFIG_SERIAL_8250_CONSOLE=y\n"
      old = pins.merge("config_checked" => true, "guest_console" => "hvc0")
      new = pins.except("guest_unchecked").merge("guest_config" => pin("config", config))
      fetched = []
      expect(described_class.verify(old, new, fetcher: fetcher(files.merge("https://example.com/config" => config), fetched), dir:)).to eq new.merge("config_checked" => true, "guest_console" => "ttyS0")
      expect(fetched).to eq ["https://example.com/config"]

      fetched.clear
      new_deb = pins.merge("host_deb" => pin("h2.deb", "newer"))
      expect(described_class.verify(old, new_deb, fetcher: fetcher({"https://example.com/h2.deb" => "newer"}, fetched), dir:)).to eq new_deb
      expect(fetched).to eq ["https://example.com/h2.deb"]
    end

    it "takes an unreadable config only when the operator accepted it unchecked" do
      bare = "\x7FELF no config".b
      new = pins.merge("guest_kernel" => pin("vmlinux", bare))
      plain = fetcher(files.merge("https://example.com/vmlinux" => bare))
      expect { described_class.verify(nil, new, fetcher: plain, dir:) }.to raise_error(described_class::Refused, /\Athe guest kernel has no embedded config \(CONFIG_IKCONFIG\).*--pvm-guest-unchecked\z/)
      accepted = new.merge("guest_unchecked" => true, "guest_console" => "hvc0")
      expect(described_class.verify(nil, accepted, fetcher: plain, dir:)).to eq accepted.except("guest_console").merge("config_checked" => false)
    end

    it "refuses a config that lacks what PVM VMs need, and a wrong sha256" do
      broken = vmlinux(hvc_config.sub("CONFIG_EXT4_FS=y\n", ""))
      expect { described_class.verify(nil, pins.merge("guest_kernel" => pin("vmlinux", broken)), fetcher: fetcher(files.merge("https://example.com/vmlinux" => broken)), dir:) }
        .to raise_error(described_class::Refused, "the guest kernel config lacks (=y): EXT4_FS")
      expect { described_class.verify(nil, pins.merge("host_deb" => pin("h.deb", "other")), fetcher: fetcher(files), dir:) }
        .to raise_error(ByohArtifactFetch::Refused, /has sha256 .*, not the pinned/)
    end

    it "refuses a guest kernel that is not an ELF vmlinux, even with a pinned config" do
      config = hvc_config
      bz = "MZ\xEA\x07 bzImage".b
      with_config = pins.except("guest_unchecked").merge("guest_kernel" => pin("vmlinux", bz), "guest_config" => pin("config", config))
      served = fetcher(files.merge("https://example.com/vmlinux" => bz, "https://example.com/config" => config))
      expect { described_class.verify(nil, with_config, fetcher: served, dir:) }
        .to raise_error(described_class::Refused, "the guest kernel https://example.com/vmlinux is not an ELF vmlinux (cloud-hypervisor boots it directly; a bzImage will not do)")
      empty = pins.merge("guest_kernel" => pin("vmlinux", ""), "guest_unchecked" => true)
      expect { described_class.verify(nil, empty, fetcher: fetcher(files.merge("https://example.com/vmlinux" => "")), dir:) }
        .to raise_error(described_class::Refused, /is not an ELF vmlinux/)
    end
  end

  it "summarizes the pins" do
    pins = {"host_deb" => {"url" => "https://e/h.deb", "sha256" => "a" * 64}, "guest_kernel" => {"url" => "https://e/v", "sha256" => "b" * 64}}
    expect(described_class.summary(pins.merge("guest_unchecked" => true, "config_checked" => false))).to eq [
      "host kernel package: https://e/h.deb sha256 #{"a" * 64}",
      "guest kernel: https://e/v sha256 #{"b" * 64}",
      "guest kernel config: none pinned (accepted unchecked)",
      "config checked: no",
    ]
    expect(described_class.summary(pins.merge("guest_unchecked" => false, "config_checked" => true, "guest_console" => "hvc0")).last(2)).to eq ["guest kernel config: none pinned", "config checked: yes, console hvc0"]
    expect(described_class.summary(pins.merge("guest_config" => {"url" => "https://e/c", "sha256" => "c" * 64})).last(2)).to eq ["guest kernel config: https://e/c sha256 #{"c" * 64}", "config checked: no"]
    expect(described_class.summary(pins.merge("unchecked_drivers" => %w[hv_storvsc hv_netvsc])).last).to eq "unchecked host drivers (operator vouched): hv_storvsc hv_netvsc"
  end
end
