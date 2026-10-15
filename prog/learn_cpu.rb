# frozen_string_literal: true

class Prog::LearnCpu < Prog::Base
  subject_is :sshable, :vm_host

  def get_arch
    arch = sshable.cmd("common/bin/arch").strip
    fail "BUG: unexpected CPU architecture" unless ["arm64", "x64"].include?(arch)

    arch
  end

  def get_topology
    cpus = sshable.cmd_json("/usr/bin/lscpu -Jye").fetch("cpus")
    parsed = cpus.map { it.fetch_values("socket", "core") }
    total_cpus = parsed.count
    sockets = parsed.map { |socket, _| socket }.uniq.count
    cores = parsed.uniq.count
    cpu_numa_nodes = cpus.sort_by! { |cpu| cpu.fetch("cpu").to_i }.map! { |cpu| cpu["node"]&.to_i }

    {total_cpus:, total_cores: cores, total_sockets: sockets, cpu_numa_nodes:}
  end

  # BYOH hosts can have offline CPUs, partial SMT and hybrid CPUs. The
  # parsable format prints unknown values as empty fields, where the JSON
  # format of util-linux 2.39 prints a bare "-" for offline rows, which is
  # not JSON. Logical core IDs come from the thread sibling masks, so they
  # stay distinct where a kernel restarts core_id in each cluster.
  def get_byoh_topology
    rows = sshable.cmd("/usr/bin/lscpu -a -p=CPU,NODE,SOCKET,CORE,ONLINE").each_line.filter_map do |line|
      next if line.start_with?("#")

      cpu, node, socket, core, online = line.chomp.split(",", -1)
      next unless online == "Y"

      fail "lscpu reported no socket or core for online cpu #{cpu}" unless [socket, core].all? { /\A\d+\z/.match?(it) }
      [Integer(cpu, 10), /\A\d+\z/.match?(node) ? Integer(node, 10) : nil, socket, core]
    end.sort_by!(&:first)
    fail "lscpu reported no online cpus" if rows.empty?

    threads_per_core = rows.group_by { |_, _, socket, core| [socket, core] }.values.map(&:size)
    total_cpus = rows.size
    # With a non-uniform thread count per core, count every CPU as a core,
    # so the host has one thread per core.
    total_cores = threads_per_core.uniq.one? ? threads_per_core.size : total_cpus

    {
      total_cpus:,
      total_cores:,
      total_sockets: rows.map { it[2] }.uniq.count,
      cpu_numa_nodes: rows.map { it[1] },
      cpu_numbers: rows.map(&:first),
    }
  end

  def count_dies(arch:, total_sockets:, cpu_numbers: nil)
    # Linux kernel doesn't provide die_id information for arm64.
    return total_sockets if arch == "arm64"

    die_ids = if cpu_numbers
      # Offline CPUs have no topology directory.
      sshable.cmd("cat :shelljoin_paths", shelljoin_paths: cpu_numbers.map { "/sys/devices/system/cpu/cpu#{it}/topology/die_id" })
    else
      sshable.cmd("cat /sys/devices/system/cpu/cpu*/topology/die_id")
    end.split("\n")
    die_ids.uniq.count
  end

  label def start
    arch = get_arch
    topo = vm_host&.byoh? ? get_byoh_topology : get_topology
    total_dies = count_dies(total_sockets: topo[:total_sockets], arch:, cpu_numbers: topo[:cpu_numbers])
    pop(arch:, **topo, total_dies:)
  end
end
