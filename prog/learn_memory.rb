# frozen_string_literal: true

class Prog::LearnMemory < Prog::Base
  subject_is :sshable

  # dmidecode prints a memory device's size in the largest unit that keeps
  # it integral, so a 512 MiB module, or the 7680 MiB device of a virtual
  # machine, is reported in MB.
  UNIT_MIB = {"kB" => Rational(1, 1024), "MB" => 1, "GB" => 1024, "TB" => 1024 * 1024}.freeze

  # Returns the summed size of the memory devices in whole GiB, rounded
  # down, or nil when dmidecode lists no installed device.
  def parse_sum(s)
    sizes = s.each_line.filter_map do |line|
      next unless line =~ /\A\s*Size: (\d+) (\w+)/
      # Fail noisily on a unit dmidecode is not known to print.
      mib = UNIT_MIB.fetch($2) { fail "BUG: unexpected dmidecode unit #{$2}" }

      Integer($1) * mib
    end
    (sizes.sum / 1024).floor unless sizes.empty?
  end

  # MemTotal is somewhat less than the installed memory, as the firmware
  # and the kernel keep part of it, so round it up to whole GiB.
  def parse_meminfo(s)
    kib = s[/^MemTotal:\s+(\d+) kB$/, 1] or fail "Couldn't extract total memory"
    (Integer(kib) + 1048575) / 1048576
  end

  label def start
    # Use dmidecode to get an integral amount of system memory.
    # Generally, there is a gigabyte or so less available to
    # applications than installed as reported by /proc/meminfo.
    #
    # Thus, in practice we can't run VMs at 100% system size anyway,
    # we'll have to leave padding, but to keep the ratios neat for the
    # customer, we compute CPU memory allocation ratio against
    # physical memory.
    #
    # Some virtual machines and boards expose no SMBIOS memory devices;
    # fall back to the kernel's total there.
    mem_gib = parse_sum(sshable.cmd("sudo /usr/sbin/dmidecode -t memory | fgrep Size: || true")) ||
      parse_meminfo(sshable.cmd("cat /proc/meminfo"))
    pop mem_gib:
  end
end
