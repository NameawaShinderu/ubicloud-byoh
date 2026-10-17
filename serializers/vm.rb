# frozen_string_literal: true

class Serializers::Vm < Serializers::Base
  def self.serialize_internal(vm, options = {})
    # A VM on a BYOH host shows the addresses customers reach it at
    # (docs/byoh/NETWORKING.md section 5.5). Other VMs keep their own.
    byoh = vm.byoh_addressing?
    base = {
      id: vm.ubid,
      name: vm.name,
      state: vm.display_state,
      location: vm.display_location,
      size: vm.display_size,
      unix_user: vm.unix_user,
      storage_size_gib: vm.storage_size_gib,
      boot_image: vm.boot_image,
      ip6: byoh ? vm.public_ip6 : vm.ip6,
      ip4_enabled: vm.ip4_enabled,
      ip4: byoh ? vm.public_ip4 : vm.ip4,
      maintenance_window_start_at: vm.maintenance_window_start_at,
    }
    base[:ip4_scope] = vm.public_ip4_scope if byoh
    # A lower-tier VM (docs/byoh/NO_KVM.md) says what it is; a standard
    # VM's output is as it was.
    tier = ByohVirtTiers.tier_for_family(vm.family)
    if ByohVirtTiers.lower?(tier)
      base[:virt_tier] = {tier:, description: ByohVirtTiers.fetch(tier).description, experimental: true}
      if options[:detailed] && (host_kernel = vm.shared_host_kernel)
        base[:virt_tier][:host_kernel] = host_kernel
      end
      if options[:detailed] && (guest_kernel = vm.pvm_guest_kernel)
        base[:virt_tier][:guest_kernel] = guest_kernel
      end
    end

    if options[:detailed]
      base.merge!(
        firewalls: Serializers::Firewall.serialize(vm.firewalls(eager: [:location, :firewall_rules]), {include_path: true}),
        private_ipv4: vm.private_ipv4,
        private_ipv6: vm.private_ipv6,
        subnet: vm.user_nic&.private_subnet&.name,
        gpu: vm.display_gpu,
      )
      base[:ip4_internal] = vm.ip4_internal if byoh
    end

    base
  end
end
