# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "time"
require "zlib"

# The guest kernels (vmlinux) that PVM VMs boot directly
# (docs/byoh/NO_KVM.md section 6.7), one directory per pinned sha256:
#
#   /opt/pvm-guest/<sha256>/vmlinux     the kernel, checked against the pin
#   /opt/pvm-guest/<sha256>/config      the pinned .config, when one is
#   /opt/pvm-guest/<sha256>/meta.json   sha256, release, console,
#                                       config_checked
#   /opt/pvm-guest/<sha256>.refused     why the last download of that pin
#                                       was refused
#
# They live beside /opt/fw and /opt/cloud-hypervisor, world-readable,
# because cloud-hypervisor runs as each VM's own user; PvmHostKernel's
# /var/lib/ubicloud/pvm is root's alone.
#
# Subcommands, with JSON parameters on stdin, each printing one JSON
# object:
#
#   download  {guest_kernel {url, sha256}, guest_config {url, sha256}?,
#             guest_unchecked}: downloads into <sha256>.tmp and renames it
#             to <sha256> only once the kernel matches its pin and its
#             config has what PVM VMs need. An existing verified directory
#             is kept as it is.
#   show      {sha256}: state ready (with meta), refused (with the
#             error) or absent.
#   gc        {keep [sha256...]}: removes the kernels not kept and not
#             referenced by a VM's prep.json or by a systemd unit.
#
# Exit 0 ok, 2 refused (the pin cannot work: another download of it gives
# the same answer), 3 failed (a download that may work when tried again),
# 1 an unexpected error.
class PvmGuestKernel
  class Refused < StandardError; end

  class Failed < StandardError; end

  COMMANDS = %w[download show gc].freeze
  EXIT_CODES = {"ok" => 0, "error" => 1, "refused" => 2, "failed" => 3}.freeze

  DIR = "opt/pvm-guest"
  LOCK_FILE = "#{DIR}/.lock"
  VM_DIR = "vm"
  UNIT_DIR = "etc/systemd/system"
  # How a VM's unit names the kernel it boots.
  UNIT_REFERENCE = %r{/#{DIR}/([0-9a-f]{64})/}

  # What the guest kernel must have built in (=y): it boots with no
  # modules and no initramfs, from an ext4 root on virtio-blk, and reads
  # rhizome's vfat CIDATA seed. The list of
  # scripts/byoh/test/real/pvm-go-no-go.sh and the control plane's
  # ByohPvmPolicy.
  REQUIRED_CONFIG = %w[VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1 PVM_GUEST X86_PIE VIRTIO_BLK VIRTIO_NET VIRTIO_PCI EXT4_FS].freeze

  # The start of the kernel's embedded config (CONFIG_IKCONFIG,
  # kernel/configs.c): this marker, then the config gzipped.
  IKCONFIG_MAGIC = "IKCFG_ST\x1f\x8b\x08".b

  # The kernel's "Linux version ..." banner (init/version.c).
  BANNER = /Linux version ([0-9A-Za-z][0-9A-Za-z.+~_-]*) \(/n

  ELF_MAGIC = "\x7fELF".b

  # The same cap and stall limits as PvmHostKernel and the control
  # plane's ByohArtifactFetch.
  MAX_BYTES = 512 * 1024 * 1024
  CURL = ["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
    "--connect-timeout", "10", "--speed-limit", "1024", "--speed-time", "60",
    "--max-filesize", MAX_BYTES.to_s].freeze

  # curl exit codes that say the pin itself cannot be fetched: an http
  # URL or redirect (1), a malformed URL (3), a file over the cap (63).
  # Any other failure (DNS, a refused connection, a stall, an HTTP
  # error) may pass when tried again.
  CURL_REFUSALS = {
    1 => "an http:// URL or redirect is refused, only https is fetched",
    3 => "the URL is malformed",
    63 => "the file is larger than the #{MAX_BYTES}-byte cap",
  }.freeze

  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  HTTPS_URL = %r{\Ahttps://[^\s/]+/\S*\z}

  def self.main(argv, stdin: $stdin, out: $stdout, **kw)
    command = argv.first
    unless argv.size == 1 && COMMANDS.include?(command)
      out.puts JSON.generate("result" => "refused", "error" => "usage: download-pvm-guest-kernel #{COMMANDS.join("|")}, with JSON parameters on stdin")
      return EXIT_CODES["refused"]
    end

    result = begin
      text = stdin.read.to_s.strip
      params = text.empty? ? {} : JSON.parse(text)
      raise Refused, "the parameters must be a JSON object" unless params.is_a?(Hash)

      new(**kw).public_send(command, params)
    rescue Refused => e
      {"result" => "refused", "error" => e.message}
    rescue Failed => e
      {"result" => "failed", "error" => e.message}
    rescue JSON::ParserError => e
      {"result" => "refused", "error" => "the parameters are not JSON: #{e.message}"}
    rescue => e
      {"result" => "error", "error" => "#{e.class}: #{e.message}"}
    end
    out.puts JSON.generate(result)
    EXIT_CODES.fetch(result["result"])
  end

  # runner takes a command line and returns its output (stdout and
  # stderr) and exit status.
  def initialize(root: "/", runner: nil, now: -> { Time.now })
    @root = root
    @runner = runner || lambda do |*argv|
      out, status = Open3.capture2e(*argv)
      [out, status.exitstatus]
    end
    @now = now
  end

  def download(params)
    kernel = pin_param(params, "guest_kernel")
    config_pin = params["guest_config"] && pin_param(params, "guest_config")
    unchecked = params["guest_unchecked"] == true
    sha = kernel["sha256"]

    with_lock(wait: true) do
      if (meta = verified_meta(sha))
        return {"result" => "ok", "meta" => meta, "note" => "already downloaded"}
      end

      tmp = path("#{DIR}/#{sha}.tmp")
      FileUtils.rm_rf(tmp)
      FileUtils.rm_f(path("#{DIR}/#{sha}.refused"))
      FileUtils.mkdir_p(tmp, mode: 0o755)
      begin
        meta = fetch_and_check(tmp, kernel, config_pin, unchecked)
        final = path("#{DIR}/#{sha}")
        FileUtils.rm_rf(final)
        File.rename(tmp, final)
        {"result" => "ok", "meta" => meta}
      rescue Refused => e
        write(path("#{DIR}/#{sha}.refused"), JSON.generate("sha256" => sha, "error" => e.message, "at" => @now.call.utc.iso8601) + "\n")
        raise
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  def show(params)
    sha = sha_param(params["sha256"], "sha256")
    if (meta = read_meta(sha))
      {"result" => "ok", "state" => "ready", "meta" => meta}
    elsif (refused = read_json(path("#{DIR}/#{sha}.refused")))
      {"result" => "ok", "state" => "refused", "error" => refused["error"]}
    else
      {"result" => "ok", "state" => "absent"}
    end
  end

  # Removes every kernel that is neither kept nor referenced by a VM: a
  # VM's prep.json names the sha it boots, and its unit names the kernel's
  # path, which stays the kernel it boots until its next stop and start
  # rewrites the unit. It never waits for a download, and removes nothing
  # when a reference cannot be read.
  def gc(params)
    keep = params.fetch("keep", [])
    raise Refused, "keep must be a list of sha256 values" unless keep.is_a?(Array)
    keep.each { |sha| sha_param(sha, "keep") }

    with_lock(wait: false) do |locked|
      return {"result" => "ok", "removed" => [], "skipped" => "a download holds #{LOCK_FILE}"} unless locked

      begin
        referenced = referenced_shas
      rescue JSON::ParserError, TypeError, SystemCallError => e
        return {"result" => "ok", "removed" => [], "skipped" => "cannot read the VMs' references: #{e.message}"}
      end
      kept = keep | referenced
      removed = held_shas - kept
      removed.each do |sha|
        FileUtils.rm_rf(path("#{DIR}/#{sha}"))
        FileUtils.rm_f(path("#{DIR}/#{sha}.refused"))
      end
      {"result" => "ok", "removed" => removed, "kept" => held_shas & kept}
    end
  end

  # The console a kernel config gives PVM guests: ttyS0 with the 8250
  # serial console, else hvc0 with the virtio console. Raises Refused
  # when the config lacks what PVM VMs need.
  def self.guest_console(config)
    built_in = config.b.scan(/^CONFIG_(\w+)=y$/).flatten
    missing = REQUIRED_CONFIG - built_in
    console = if built_in.include?("SERIAL_8250_CONSOLE")
      "ttyS0"
    elsif built_in.include?("VIRTIO_CONSOLE")
      "hvc0"
    end
    missing << "SERIAL_8250_CONSOLE|VIRTIO_CONSOLE" unless console
    raise Refused, "the guest kernel config lacks (=y): #{missing.join(" ")}" unless missing.empty?

    console
  end

  # The kernel config embedded in a vmlinux, or nil.
  def self.extract_ikconfig(data)
    offset = 0
    while (at = data.index(IKCONFIG_MAGIC, offset))
      begin
        return Zlib::GzipReader.new(StringIO.new(data.byteslice(at + 8..))).read
      rescue Zlib::Error
        offset = at + 1
      end
    end
  end

  private

  def path(rel)
    File.join(@root, rel)
  end

  def pin_param(params, key)
    pin = params[key]
    raise Refused, "#{key} {url, sha256} is required" unless pin.is_a?(Hash)
    raise Refused, "#{key} url must be an https URL" unless pin["url"].is_a?(String) && HTTPS_URL.match?(pin["url"])

    sha_param(pin["sha256"], "#{key} sha256")
    pin
  end

  def sha_param(value, what)
    raise Refused, "#{what} must be 64 lowercase hex digits" unless SHA256_FORMAT.match?(value.to_s)

    value
  end

  # Holds the lock of DIR. With wait: false, yields whether it got it.
  def with_lock(wait:)
    FileUtils.mkdir_p(path(DIR), mode: 0o755)
    File.chmod(0o755, path(DIR))
    File.open(path(LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
      if wait
        lock.flock(File::LOCK_EX)
        yield true
      else
        yield lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end
  end

  def fetch_and_check(tmp, kernel, config_pin, unchecked)
    vmlinux = File.join(tmp, "vmlinux")
    fetch(kernel, vmlinux, "guest kernel")
    data = File.binread(vmlinux)
    raise Refused, "the guest kernel is not an ELF vmlinux (cloud-hypervisor boots it directly)" unless data.start_with?(ELF_MAGIC)

    config = if config_pin
      config_path = File.join(tmp, "config")
      fetch(config_pin, config_path, "guest kernel config")
      File.binread(config_path)
    else
      self.class.extract_ikconfig(data)
    end

    if config
      console = self.class.guest_console(config)
    elsif unchecked
      # Accepted unchecked by the operator: the virtio console, which the
      # PVM guest kernel builds proven so far have.
      console = "hvc0"
    else
      raise Refused, "the guest kernel has no embedded config (CONFIG_IKCONFIG) and none is pinned, so nothing can check that it boots PVM VMs"
    end

    meta = {
      "sha256" => kernel["sha256"],
      "url" => kernel["url"],
      "release" => data[BANNER, 1]&.encode(Encoding::UTF_8),
      "console" => console,
      "config_checked" => !config.nil?,
      "downloaded_at" => @now.call.utc.iso8601,
    }
    write(File.join(tmp, "meta.json"), JSON.pretty_generate(meta) + "\n")
    File.chmod(0o644, vmlinux)
    File.chmod(0o644, config_path) if config_pin
    File.chmod(0o755, tmp)
    meta
  end

  def fetch(pin, dest, what)
    out, status = @runner.call(*CURL, "-o", dest, pin["url"])
    unless status == 0
      detail = "downloading the #{what} #{pin["url"]} failed (curl exit #{status}"
      detail += "; #{CURL_REFUSALS[status]}" if CURL_REFUSALS.key?(status)
      detail += "): #{out.to_s.strip}"
      raise Refused, detail if CURL_REFUSALS.key?(status)

      raise Failed, detail
    end
    raise Failed, "downloading the #{what} #{pin["url"]} gave no file" unless File.file?(dest)
    raise Refused, "the #{what} #{pin["url"]} is larger than the #{MAX_BYTES}-byte cap" if File.size(dest) > MAX_BYTES

    got = Digest::SHA256.file(dest).hexdigest
    raise Refused, "the #{what} #{pin["url"]} has sha256 #{got}, not the pinned #{pin["sha256"]}" unless got == pin["sha256"]
  end

  def read_json(file)
    JSON.parse(File.read(file))
  rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
    nil
  end

  def read_meta(sha)
    meta = read_json(path("#{DIR}/#{sha}/meta.json"))
    meta if meta.is_a?(Hash) && meta["sha256"] == sha && File.file?(path("#{DIR}/#{sha}/vmlinux"))
  end

  # The meta of a kernel already downloaded whose file still matches it.
  def verified_meta(sha)
    meta = read_meta(sha)
    meta if meta && Digest::SHA256.file(path("#{DIR}/#{sha}/vmlinux")).hexdigest == sha
  end

  # The shas with a kernel directory (or a refusal) here.
  def held_shas
    Dir.children(path(DIR)).filter_map do |name|
      sha = name.delete_suffix(".refused")
      sha if SHA256_FORMAT.match?(sha) && (name.end_with?(".refused") || File.directory?(path("#{DIR}/#{name}")))
    end.uniq.sort
  end

  def referenced_shas
    shas = Dir.glob(path("#{VM_DIR}/*/prep.json")).filter_map do |file|
      sha = JSON.parse(File.read(file)).dig("pvm", "kernel_sha256")
      sha if SHA256_FORMAT.match?(sha.to_s)
    end
    Dir.glob(path("#{UNIT_DIR}/*.service")).each do |file|
      shas.concat(File.read(file).scan(UNIT_REFERENCE).flatten)
    end
    shas.uniq
  end

  def write(file, content)
    File.write("#{file}.tmp", content)
    File.chmod(0o644, "#{file}.tmp")
    File.rename("#{file}.tmp", file)
  end
end
