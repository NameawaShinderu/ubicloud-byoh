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
      cpu_count = VmHostCpu.where(vm_host_id: vm_host.id).count
      fail "VmHost has no vm_host_cpu rows to update" if cpu_count.zero?
      numa_node_by_cpu_number = if (cpu_numbers = retval["cpu_numbers"])
        # A BYOH host reports its online CPU numbers, which can have gaps.
        fail "lscpu reported #{cpu_numbers.size} online cpus, but VmHost has #{cpu_count} vm_host_cpu rows" if cpu_numbers.size != cpu_count
        missing = cpu_numbers - VmHostCpu.where(vm_host_id: vm_host.id).select_map(:cpu_number)
        fail "lscpu reported cpus #{missing.join(",")} that have no vm_host_cpu row" unless missing.empty?

        cpu_numbers.zip(cpu_numa_nodes).to_h
      else
        fail "lscpu reported #{cpu_numa_nodes.size} cpus, but VmHost has #{cpu_count} vm_host_cpu rows" if cpu_numa_nodes.size != cpu_count

        cpu_numa_nodes.each_with_index.to_h { |numa_node, cpu_number| [cpu_number, numa_node] }
      end
      VmHostCpu
        .where(vm_host_id: vm_host.id)
        .update(numa_node: Sequel.case(numa_node_by_cpu_number, nil, :cpu_number))

      pop("updated numa_node for #{cpu_count} cpus")
    end

    push Prog::LearnCpu
  end
end
