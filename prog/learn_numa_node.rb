# frozen_string_literal: true

class Prog::LearnNumaNode < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    fail "No existing VmHost" unless VmHost[vm_host_id]

    Strand.create(prog: "LearnNumaNode", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    if retval
      cpu_numa_nodes = retval.fetch("cpu_numa_nodes")
      cpu_rows = VmHostCpu.where(vm_host_id: vm_host.id)
      cpu_count = cpu_rows.count
      fail "VmHost has no vm_host_cpu rows to update" if cpu_count.zero?
      if (cpu_numbers = retval["cpu_numbers"])
        # A BYOH host reports its online CPU numbers, which can have gaps.
        # A host registered before LearnCpu skipped offline CPUs still has
        # rows for them; their numa_node is left as it is.
        missing = cpu_numbers - cpu_rows.select_map(:cpu_number)
        fail "lscpu reported cpus #{missing.join(",")} that have no vm_host_cpu row" unless missing.empty?

        cpu_rows.where(cpu_number: cpu_numbers)
          .update(numa_node: Sequel.case(cpu_numbers.zip(cpu_numa_nodes).to_h, nil, :cpu_number))
        updated = cpu_numbers.size
      else
        fail "lscpu reported #{cpu_numa_nodes.size} cpus, but VmHost has #{cpu_count} vm_host_cpu rows" if cpu_numa_nodes.size != cpu_count

        cpu_rows.update(numa_node: Sequel.case(cpu_numa_nodes.each_with_index.to_h { |numa_node, cpu_number| [cpu_number, numa_node] }, nil, :cpu_number))
        updated = cpu_count
      end

      pop("updated numa_node for #{updated} cpus")
    end

    push Prog::LearnCpu
  end
end
