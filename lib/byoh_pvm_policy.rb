# frozen_string_literal: true

require "stringio"
require "zlib"

# The PVM kernel pins of a location (location.byoh_virt["pvm_kernel"],
# docs/byoh/NO_KVM.md section 6.7): which host kernel package and which
# guest kernel its pvm hosts and VMs run, each an https URL with its
# sha256. The operator picks them; the code has no default pin.
#
#   host_deb         {url, sha256} of the host kernel package
#   guest_kernel     {url, sha256} of the guest vmlinux
#   guest_config     {url, sha256} of the guest kernel's .config, or absent
#   guest_unchecked  absent with guest_config; otherwise whether the
#                    operator accepted a guest kernel whose config cannot
#                    be read (no guest_config and no embedded IKCONFIG)
#   config_checked   whether bin/byoh-location read the guest config and
#                    found what PVM VMs need in it
#   guest_console    the console that config gives the guest: ttyS0 with
#                    the 8250 serial driver, else hvc0 (virtio console)
module ByohPvmPolicy
  class Refused < StandardError; end

  FILES = {
    "host_deb" => "host kernel package",
    "guest_kernel" => "guest kernel",
    "guest_config" => "guest kernel config",
  }.freeze

  GUEST_KEYS = %w[guest_kernel guest_config guest_unchecked].freeze

  # What the guest kernel must have built in (=y): it boots with no
  # modules and no initramfs, from an ext4 root on virtio-blk, and reads
  # rhizome's vfat CIDATA seed. The same list as
  # scripts/byoh/test/real/pvm-go-no-go.sh.
  REQUIRED_GUEST_CONFIG = %w[VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1 PVM_GUEST X86_PIE VIRTIO_BLK VIRTIO_NET VIRTIO_PCI EXT4_FS].freeze

  # The start of the kernel's embedded config (CONFIG_IKCONFIG,
  # kernel/configs.c): this marker, then the config gzipped.
  IKCONFIG_MAGIC = "IKCFG_ST\x1f\x8b\x08".b

  # Cloud Hypervisor boots the guest kernel directly, so it must be an
  # ELF vmlinux; rhizome's PvmGuestKernel refuses anything else.
  ELF_MAGIC = "\x7fELF".b

  # What the operator acknowledges by pinning PVM kernels.
  ACK = "PVM kernels are third-party builds: you own watching them for CVEs and pinning fixed builds " \
    "(docs/byoh/NO_KVM.md section 6.8). pvm stays single project: keep the location hidden and grant it to one project."

  def self.pins(policy) = policy["pvm_kernel"]

  # The pins after the operator's changes: changes maps FILES keys to
  # {url, sha256}, and may set "guest_unchecked" => true. A new guest
  # kernel drops the old one's config and unchecked acknowledgement.
  # Raises Refused unless the result pins the host package and the guest
  # kernel.
  def self.merge(old, changes)
    pins = (old || {}).slice("host_deb", *GUEST_KEYS, "config_checked", "guest_console")
    if changes.key?("guest_kernel") && changes["guest_kernel"] != pins["guest_kernel"]
      pins = pins.except("guest_config", "guest_unchecked")
    end
    raise Refused, "pass either --pvm-guest-config or --pvm-guest-unchecked, not both" if changes.key?("guest_config") && changes["guest_unchecked"]

    pins = pins.except("guest_unchecked") if changes.key?("guest_config")
    pins = pins.except("guest_config") if changes["guest_unchecked"]
    pins = pins.merge(changes)
    pins["guest_unchecked"] = false unless pins.key?("guest_config") || pins.key?("guest_unchecked")
    {"host_deb" => "--pvm-host-deb", "guest_kernel" => "--pvm-guest-kernel"}.each do |key, flag|
      raise Refused, "pin the PVM #{FILES[key]}: #{flag} URL #{flag}-sha256 HEX" unless pins[key]
    end
    pins.each do |key, pin|
      next unless FILES.key?(key)
      raise Refused, "the PVM #{FILES[key]} URL #{pin["url"]} is not https" unless ByohArtifactFetch.https_url?(pin["url"])
      raise Refused, "the sha256 of the PVM #{FILES[key]} must be 64 lowercase hex digits" unless ByohArtifactFetch::SHA256_FORMAT.match?(pin["sha256"].to_s)
    end
    pins
  end

  # Whether a host's guest kernel download must start again: the guest
  # kernel or how its config is checked changed.
  def self.guest_changed?(old, new) = (old || {}).slice(*GUEST_KEYS) != new.slice(*GUEST_KEYS)

  # Downloads into dir, verifying each sha256, every file whose pin
  # changed, and reads the guest config when the guest side changed.
  # Returns the pins with config_checked and guest_console set. Raises
  # Refused (or ByohArtifactFetch::Refused) before anything is stored.
  def self.verify(old, new, fetcher:, dir:)
    needed = FILES.keys.select { new[it] && new[it] != old&.dig(it) }
    needed |= [new["guest_config"] ? "guest_config" : "guest_kernel"] if guest_changed?(old, new)
    paths = needed.to_h { [it, fetcher.fetch(new[it]["url"], new[it]["sha256"], File.join(dir, it))] }
    if paths["guest_kernel"] && !File.binread(paths["guest_kernel"], ELF_MAGIC.bytesize).to_s.start_with?(ELF_MAGIC)
      raise Refused, "the guest kernel #{new["guest_kernel"]["url"]} is not an ELF vmlinux (cloud-hypervisor boots it directly; a bzImage will not do)"
    end
    return new unless guest_changed?(old, new)

    config = new["guest_config"] ? File.binread(paths["guest_config"]) : extract_ikconfig(paths["guest_kernel"])
    if config
      new.merge("config_checked" => true, "guest_console" => guest_console(config))
    elsif new["guest_unchecked"]
      unchecked(new)
    else
      raise Refused, "the guest kernel has no embedded config (CONFIG_IKCONFIG), so nothing can check that it boots PVM VMs; " \
        "pin its config with --pvm-guest-config URL --pvm-guest-config-sha256 HEX, or accept it unchecked with --pvm-guest-unchecked"
    end
  end

  # The pins when nothing read the guest config.
  def self.unchecked(pins) = pins.merge("config_checked" => false).except("guest_console")

  # The kernel config embedded in a vmlinux, or nil.
  def self.extract_ikconfig(path)
    data = File.binread(path)
    offset = 0
    while (at = data.index(IKCONFIG_MAGIC, offset))
      begin
        return Zlib::GzipReader.new(StringIO.new(data.byteslice(at + 8..))).read
      rescue Zlib::Error
        offset = at + 1
      end
    end
  end

  # The guest console a kernel config gives (ttyS0 or hvc0); raises
  # Refused when the config lacks what PVM VMs need.
  def self.guest_console(config)
    built_in = config.scan(/^CONFIG_(\w+)=y$/).flatten
    missing = REQUIRED_GUEST_CONFIG - built_in
    console = if built_in.include?("SERIAL_8250_CONSOLE")
      "ttyS0"
    elsif built_in.include?("VIRTIO_CONSOLE")
      "hvc0"
    end
    missing << "SERIAL_8250_CONSOLE|VIRTIO_CONSOLE" unless console
    raise Refused, "the guest kernel config lacks (=y): #{missing.join(" ")}" unless missing.empty?
    console
  end

  # One line per pin, for bin/byoh-location show.
  def self.summary(pins)
    lines = FILES.filter_map { |key, what| "#{what}: #{pins[key]["url"]} sha256 #{pins[key]["sha256"]}" if pins[key] }
    lines << "guest kernel config: none pinned#{" (accepted unchecked)" if pins["guest_unchecked"]}" unless pins["guest_config"]
    lines << "config checked: #{pins["config_checked"] ? "yes, console #{pins["guest_console"]}" : "no"}"
    lines
  end
end
