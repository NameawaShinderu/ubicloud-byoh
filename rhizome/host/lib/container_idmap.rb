# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/util"

# The host-local allocator of the uid and gid ranges that system
# containers (docs/byoh/NO_KVM.md section 4.2) map their ids to.
#
# Every container VM gets its own slot of 65536 ids, so no two containers
# share a host uid. The slots start at 1,000,000,000, above SUB_UID_MAX
# (600,100,000 on Ubuntu 24.04), so ranges that useradd hands out to
# ordinary users can never reach them. LXC writes the maps through
# newuidmap when the uidmap package is installed, which needs one
# /etc/subuid and /etc/subgid entry for root covering every slot
# (ROOT_ENTRY); container host prep adds it and refuses any other entry
# that overlaps the range.
#
# A slot is recorded as a file named after the VM holding its number,
# under a lock, and released only after the VM's root file system and
# disk are gone (ContainerDisk#purge), so a slot is never reused while a
# file owned by its ids remains.
module ContainerIdmap
  DIR = "/var/lib/ubicloud/idmap"
  BASE = 1_000_000_000
  SIZE = 65536
  SLOTS = 50_000
  ROOT_ENTRY = "root:#{BASE}:#{SIZE * SLOTS}"
  SUBID_FILES = %w[/etc/subuid /etc/subgid].freeze

  class Exhausted < RuntimeError
  end

  def self.base(slot) = BASE + slot * SIZE

  NAME = /\Avm[a-z0-9]{6}\z/

  def self.check_name!(vm_name)
    fail "unexpected VM name #{vm_name.inspect}" unless NAME.match?(vm_name)
  end

  # Writes a file through a temporary file and a rename, so a reader sees
  # the old or the new content, never a part.
  def self.replace_file(path, content, perm)
    File.write("#{path}.tmp", content, perm: perm)
    File.rename("#{path}.tmp", path)
  end

  # The VM's slot, allocating the lowest free one the first time.
  def self.allocate(vm_name, dir: DIR)
    check_name!(vm_name)
    with_lock(dir) do
      if (slot = read_slot(dir, vm_name))
        next slot
      end

      used = Dir.children(dir).grep(NAME).map { read_slot(dir, _1) }
      slot = (0...SLOTS).find { !used.include?(_1) }
      raise Exhausted, "all #{SLOTS} container id slots are in use" unless slot

      replace_file(File.join(dir, vm_name), "#{slot}\n", 0o600)
      slot
    end
  end

  # The VM's slot, or nil when it has none.
  def self.slot(vm_name, dir: DIR)
    check_name!(vm_name)
    read_slot(dir, vm_name)
  end

  def self.release(vm_name, dir: DIR)
    check_name!(vm_name)
    with_lock(dir) { rm_if_exists(File.join(dir, vm_name)) }
  end

  def self.read_slot(dir, vm_name)
    Integer(File.read(File.join(dir, vm_name)), 10)
  rescue Errno::ENOENT
    nil
  end

  # The directory is root's only; its parents keep the default mode (LXC's
  # child, running as a container's root, traverses /var/lib/ubicloud).
  def self.with_lock(dir)
    FileUtils.mkdir_p(File.dirname(dir))
    FileUtils.mkdir(dir, mode: 0o700) unless File.directory?(dir)
    File.open(File.join(dir, ".lock"), File::RDWR | File::CREAT, 0o600) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  # Lines of the subordinate id files, other than ROOT_ENTRY, whose range
  # overlaps the slots. Unreadable lines count as overlapping, so prep
  # stops instead of guessing.
  def self.overlaps(files: SUBID_FILES)
    last = BASE + SIZE * SLOTS
    files.flat_map do |file|
      lines = begin
        File.readlines(file, chomp: true)
      rescue Errno::ENOENT
        []
      end
      lines.filter_map do |line|
        next if line.strip.empty? || line.start_with?("#") || line == ROOT_ENTRY

        _, start, count = line.split(":")
        start = Integer(start, 10, exception: false)
        count = Integer(count, 10, exception: false)
        "#{file}: #{line}" if start.nil? || count.nil? || (start < last && start + count > BASE)
      end
    end
  end

  # Adds ROOT_ENTRY to each file that lacks it.
  def self.ensure_root_entries(files: SUBID_FILES)
    files.each do |file|
      content = begin
        File.read(file)
      rescue Errno::ENOENT
        ""
      end
      next if content.lines(chomp: true).include?(ROOT_ENTRY)

      content += "\n" unless content.empty? || content.end_with?("\n")
      replace_file(file, "#{content}#{ROOT_ENTRY}\n", 0o644)
    end
  end
end
