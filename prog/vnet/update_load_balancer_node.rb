# frozen_string_literal: true

class Prog::Vnet::UpdateLoadBalancerNode < Prog::Base
  subject_is :vm
  frame_reader :load_balancer_id

  def load_balancer
    @load_balancer ||= LoadBalancer[load_balancer_id]
  end

  def inhost_name
    vm.inhost_name
  end

  def before_run
    super
    pop "VM is destroyed" unless vm
  end

  label def update_load_balancer
    vm.load_balancer_vm_ports.select { |lvp| lvp.state == "detaching" }.sort_by(&:stack).each do |load_balancer_vm_port|
      load_balancer.remove_vm_port(load_balancer_vm_port)
    end

    # if there is literally no up resources to balance for, we simply not do
    # load balancing.
    hop_remove_load_balancer if load_balancer.active_vm_ports_dataset.empty?

    vm.vm_host.sshable.cmd("sudo ip netns exec :inhost_name nft --file -", inhost_name:, stdin: generate_lb_based_nat_rules)
    pop "load balancer is updated"
  end

  label def remove_load_balancer
    vm.vm_host.sshable.cmd("sudo ip netns exec :inhost_name nft --file -", inhost_name:, stdin: generate_nat_rules(vm.ip4_string, vm.private_ipv4.to_s))

    pop "load balancer is removed"
  end

  def load_balancer_ports_to_work_on
    @load_balancer_ports_to_work_on ||= load_balancer.active_vm_ports { |ds| ds.eager_graph(:load_balancer_port).eager(load_balancer_vm: {vm: :nics}).order(:src_port) }
  end

  def generate_lb_based_nat_rules
    public_ipv4 = vm.ip4_string
    public_ipv6 = vm.ip6_string
    private_ipv4 = vm.private_ipv4
    private_ipv6 = vm.private_ipv6
    host_nat_ipv4 = self.host_nat_ipv4
    neighbor_ips_v4_set, neighbor_ips_v6_set = generate_lb_ip_set_definition(load_balancer_ports_to_work_on.reject { it.load_balancer_vm.vm_id == vm.id })

    balance_mode_ip4, balance_mode_ip6 = if load_balancer.algorithm == "round_robin"
      ["numgen inc", "numgen inc"]
    elsif load_balancer.algorithm == "hash_based"
      ["jhash ip saddr . tcp sport . ip daddr . tcp dport", "jhash ip6 saddr . tcp sport . ip6 daddr . tcp dport"]
    else
      fail ArgumentError, "Unsupported load balancer algorithm: #{load_balancer.algorithm}"
    end

    ipv4_prerouting = if load_balancer.ipv4_enabled?
      load_balancer_ports_to_work_on.select { |vm_port| vm_port.stack == "ipv4" }.uniq(&:load_balancer_port_id).map do |vm_port|
        port = vm_port.load_balancer_port
        ipv4_map_def = generate_lb_map_defs_ipv4(port)
        modulo = ipv4_map_def.count
        if public_ipv4.nil? && host_nat_ipv4
          # Without an IPv4 of its own, the VM has no public address to
          # balance on; its neighbors still reach it on its private one.
          "ip daddr #{private_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{private_ipv4}:#{port.dst_port}\n"
        else
          <<-IPV4_PREROUTING
ip daddr #{public_ipv4} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip daddr #{public_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip4} mod #{modulo} map { #{ipv4_map_def.join(", ")} }
ip daddr #{private_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{private_ipv4}:#{port.dst_port}
          IPV4_PREROUTING
        end
      end.join("\n")
    end

    ipv6_prerouting = if load_balancer.ipv6_enabled?
      load_balancer_ports_to_work_on.select { |vm_port| vm_port.stack == "ipv6" }.uniq(&:load_balancer_port_id).map do |vm_port|
        port = vm_port.load_balancer_port
        ipv6_map_def = generate_lb_map_defs_ipv6(port)
        modulo = ipv6_map_def.count
        <<-IPV6_PREROUTING
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip6} mod #{modulo} map { #{ipv6_map_def.join(", ")} }
ip6 daddr #{private_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to [#{public_ipv6}]:#{port.dst_port}
        IPV6_PREROUTING
      end.join("\n")
    end

    sorted_ports = load_balancer.ports.sort_by { |port| port.src_port }
    ipv4_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv4_enabled?
        "ip daddr @neighbor_ips_v4 tcp dport #{port.src_port} ct state established,related,new counter snat to #{private_ipv4}"
      end
    end.join("\n")

    ipv6_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv6_enabled?
        "ip6 daddr @neighbor_ips_v6 tcp dport #{port.src_port} ct state established,related,new counter snat to #{private_ipv6}"
      end
    end.join("\n")

    basic_dnat4, basic_snat4 = basic_nat4_rules(public_ipv4, private_ipv4, host_nat_ipv4)

    <<TEMPLATE
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
#{neighbor_ips_v4_set}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
#{neighbor_ips_v6_set}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
#{ipv4_prerouting}
#{ipv6_prerouting}

    # Basic NAT for public IPv4 to private IPv4
#{basic_dnat4}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
#{ipv4_postrouting_rule}
#{ipv6_postrouting_rule}

    # Basic NAT for private IPv4 to public IPv4
#{basic_snat4}
  }
}
TEMPLATE
  end

  def generate_lb_ip_set_definition(neighbor_vm_ports)
    return ["", ""] if neighbor_vm_ports.empty?
    ipv4_ips = neighbor_vm_ports.select { it.stack == "ipv4" }.map { it.vm.private_ipv4 }.uniq.join(", ")
    ipv6_ips = neighbor_vm_ports.select { it.stack == "ipv6" }.map { it.vm.private_ipv6 }.uniq.join(", ")
    [ipv4_ips.empty? ? "" : "elements = {#{ipv4_ips}}",
      ipv6_ips.empty? ? "" : "elements = {#{ipv6_ips}}"]
  end

  def generate_lb_map_defs(current_port, stack)
    items = load_balancer.active_vm_ports
      .select { |vm_port| vm_port.load_balancer_port.dst_port == current_port.dst_port && vm_port.stack == stack }
      .map do |vm_port|
        address = yield vm_port
        port = (vm_port.load_balancer_vm.vm_id == vm.id) ? vm_port.load_balancer_port.dst_port : vm_port.load_balancer_port.src_port
        [address.to_s, port.to_i]
      end

    items.sort!.map!.with_index do |(address, port), index|
      "#{index} : #{address} . #{port}"
    end
  end

  def generate_lb_map_defs_ipv4(current_port)
    generate_lb_map_defs(current_port, "ipv4") do |vm_port|
      vm_port.load_balancer_vm.vm.private_ipv4
    end
  end

  def generate_lb_map_defs_ipv6(current_port)
    generate_lb_map_defs(current_port, "ipv6") do |vm_port|
      (vm_port.load_balancer_vm.vm_id == vm.id) ? vm.ip6 : vm_port.load_balancer_vm.vm.private_ipv6
    end
  end

  # The VM's IPv4 egress source on a BYOH host that masquerades it
  # (Vm#byoh_egress_nat4?): the vethi link address, as in rhizome's
  # VmSetup#generate_host_nat4_rules. Nil elsewhere.
  def host_nat_ipv4
    vm.local_vetho_ip.next_sib.network.to_s if vm.byoh_egress_nat4?
  end

  # The DNAT and SNAT lines for the VM's own IPv4. Under host NAT,
  # internet-bound traffic leaves from vethi, and a VM without an IPv4 has
  # nothing to DNAT or hairpin. Like the rest of these templates, neither
  # variant SNATs dnsmasq's port-53 traffic.
  def basic_nat4_rules(public_ipv4, private_ipv4, host_nat_ipv4)
    own_ipv4 = public_ipv4 || !host_nat_ipv4
    dnat = own_ipv4 ? ["ip daddr #{public_ipv4} dnat to #{private_ipv4}"] : []
    snat = ["ip saddr #{private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{host_nat_ipv4 || public_ipv4}"]
    snat << "ip saddr #{private_ipv4} ip daddr #{private_ipv4} snat to #{public_ipv4}" if own_ipv4
    [dnat, snat].map { |lines| lines.map { "    #{it}" }.join("\n") }
  end

  def generate_nat_rules(current_public_ipv4, current_private_ipv4)
    dnat, snat = basic_nat4_rules(current_public_ipv4, current_private_ipv4, host_nat_ipv4)
    <<NAT
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
#{dnat}
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
#{snat}
  }
}
NAT
  end
end
