# frozen_string_literal: true

class Prog::SetupHugepages < Prog::Base
  subject_is :sshable, :vm_host

  # update-grub sources this after /etc/default/grub, and it is rewritten on
  # every run, so running the setup again never adds a second set of tokens.
  GRUB_DROP_IN = "/etc/default/grub.d/99-ubicloud-hugepages.cfg"

  # Earlier versions appended the tokens to GRUB_CMDLINE_LINUX in
  # /etc/default/grub on every run. Strip them so only the drop-in sets them.
  STRIP_GRUB_TOKENS = "sudo sed -i -E '/^GRUB_CMDLINE_LINUX=/ s/[[:space:]]*\\b(hugetlb_free_vmemmap|default_hugepagesz|hugepagesz|hugepages)=[^[:space:]\"]*//g' /etc/default/grub"

  GRUB_CHECK = "[ -f /etc/default/grub ] && sudo sh -c 'command -v update-grub' > /dev/null && echo ok || true"

  label def start
    if vm_host.arch == "x64" && sshable.cmd("grep -cw pdpe1gb /proc/cpuinfo || true").to_i.zero?
      fail "CPU lacks the pdpe1gb flag, so it cannot use 1G hugepages"
    end

    # The drop-in appends to $GRUB_CMDLINE_LINUX, which works even when no
    # GRUB_CMDLINE_LINUX line exists, so only GRUB itself is required.
    unless sshable.cmd(GRUB_CHECK).strip == "ok"
      fail "/etc/default/grub or update-grub is missing; the host must boot with GRUB"
    end

    hugepage_size = "1G"

    # Reserve 5G of overhead for the host. SPDK will use 2 of the hugepages +
    # upto about 1G of the 5G as not all SPDK allocations are from hugepages.
    # On production servers we have observed total memory to be up to ~1/43
    # lower than the reported physical memory. We therefore use 42/43 as a
    # safety ratio to avoid overcommitting memory for hugepages. Small hosts
    # get no hugepages rather than a negative count.
    hugepage_cnt = [vm_host.total_mem_gib * 42 / 43 - 5, 0].max

    # Platforms with large kernel or driver preallocations keep less usable
    # memory than physical memory implies; clamp against measured
    # MemAvailable so the reservation cannot starve the host OS. With
    # hugetlb_free_vmemmap=on, the kernel returns 16380 KiB of struct page
    # memory per 1G page once the pages are reserved at boot, so add it back
    # to the measurement taken before the reservation exists.
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    available_memory_match = host_meminfo.match(/^MemAvailable:\s+(\d+) kB$/)
    fail "Couldn't extract available memory" unless available_memory_match
    available_kib = Integer(available_memory_match.captures.first)

    # When the setup runs again on a host that booted with hugepages
    # reserved, MemAvailable no longer includes them. Add them back, minus
    # the struct page memory already returned for 1G pages, so the clamp
    # measures the same memory as on the first run.
    reserved_hugepages = host_meminfo[/^HugePages_Total:\s+(\d+)$/, 1].to_i
    reserved_hugepage_kib = host_meminfo[/^Hugepagesize:\s+(\d+) kB$/, 1].to_i
    freed_vmemmap_kib = (reserved_hugepage_kib == 1048576) ? reserved_hugepages * 16380 : 0
    available_kib += reserved_hugepages * reserved_hugepage_kib - freed_vmemmap_kib

    vmemmap_kib = hugepage_cnt * 16380
    available_limit = [(available_kib + vmemmap_kib) / 1048576 - 4, 0].max
    if available_limit < hugepage_cnt
      Clog.emit("hugepage count clamped to available memory", {hugepage_clamp: {formula_count: hugepage_cnt, clamped_count: available_limit}})
      hugepage_cnt = available_limit
    end

    sshable.cmd(STRIP_GRUB_TOKENS)
    sshable.cmd("sudo mkdir -p /etc/default/grub.d")
    sshable.write_file(GRUB_DROP_IN, <<~CFG)
      GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX hugetlb_free_vmemmap=on default_hugepagesz=#{hugepage_size} hugepagesz=#{hugepage_size} hugepages=#{hugepage_cnt}"
    CFG
    sshable.cmd("sudo update-grub")

    pop "hugepages installed"
  end
end
