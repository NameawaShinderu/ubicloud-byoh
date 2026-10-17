# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm show" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    @ref = [@vm.display_location, @vm.name].join("/")
    add_ipv4_to_vm(@vm, "128.0.0.1")
    subnet = @project.default_private_subnet(@vm.location)
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "#{@vm.name}-nic").subject
    nic.update(vm_id: @vm.id)
    @fw = subnet.firewalls.first
  end

  it "shows information for VM" do
    expect(cli(%W[vm #{@ref} show])).to eq <<~END
      id: #{@vm.ubid}
      name: test-vm
      state: running
      location: eu-central-h1
      size: standard-2
      unix-user: ubi
      storage-size-gib: 0
      boot-image: ubuntu-jammy
      ip6: 128:1234::2
      ip4-enabled: false
      ip4: 128.0.0.1
      private-ipv4: #{@vm.private_ipv4}
      private-ipv6: #{@vm.private_ipv6}
      subnet: default-eu-central-h1
      maintenance-window-start-at: 
      firewall 1:
        id: #{@fw.ubid}
        name: default-eu-central-h1-default
        description: Default firewall
        location: eu-central-h1
        path: /location/eu-central-h1/firewall/default-eu-central-h1-default
        rules:
          1: #{@fw.firewall_rules[0].ubid}  0.0.0.0/0  0..65535  tcp  
          2: #{@fw.firewall_rules[1].ubid}  0.0.0.0/0  0..65535  udp  
          3: #{@fw.firewall_rules[2].ubid}  ::/0  0..65535  tcp  
          4: #{@fw.firewall_rules[3].ubid}  ::/0  0..65535  udp  
    END
  end

  it "shows the BYOH address fields only for a VM on a BYOH host, unless asked for" do
    expect(cli(%W[vm #{@ref} show -f ip4,ip4-scope,ip4-internal])).to eq <<~END
      ip4: 128.0.0.1
      ip4-scope: 
      ip4-internal: 
    END

    location = create_byoh_location
    @project.set_ff_visible_locations([location.name])
    vm = create_vm(project_id: @project.id, name: "byoh-vm", location_id: location.id)
    Prog::Vnet::NicNexus.assemble(@project.default_private_subnet(location).id, name: "byoh-vm-nic").subject.update(vm_id: vm.id)
    add_byoh_ipv4_to_vm(vm, create_byoh_vm_host(location), "10.98.1.129", exposure: "nat", external_ip: "203.0.113.9")
    expect(cli(%W[vm #{location.display_name}/byoh-vm show])).to include("ip4: 203.0.113.9\nip4-scope: public\nip4-internal: 10.98.1.129\nprivate-ipv4: ")
  end

  it "shows the virtualization tier only for a lower-tier VM, unless asked for" do
    expect(cli(%W[vm #{@ref} show -f id,virt-tier])).to eq "id: #{@vm.ubid}\nvirt-tier: \n"
    expect(cli(%W[vm #{@ref} show])).not_to include("virt-tier")

    location = create_byoh_location
    @project.set_ff_visible_locations([location.name])
    host = create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm", virt_probe: Sequel.pg_jsonb({"facts" => {"kernel" => "6.12.33-pvm"}}))
    vm = create_vm(project_id: @project.id, name: "pvm-vm", family: "pvm", location_id: location.id, vm_host_id: host.id)
    Prog::Vnet::NicNexus.assemble(@project.default_private_subnet(location).id, name: "pvm-vm-nic").subject.update(vm_id: vm.id)
    description = ByohVirtTiers.fetch("pvm").description
    ref = "#{location.display_name}/pvm-vm"
    expect(cli(%W[vm #{ref} show -f virt-tier])).to eq "virt-tier: pvm (experimental) #{description}\n  host-kernel: 6.12.33-pvm\n"
    ByohVmGuestKernel.create(vm_id: vm.id, sha256: "b" * 64, release: nil, console: "hvc0")
    expect(cli(%W[vm #{ref} show])).to include("boot-image: ubuntu-jammy\nvirt-tier: pvm (experimental) #{description}\n  host-kernel: 6.12.33-pvm\n  guest-kernel: unknown release sha256 #{"b" * 64} config unchecked\nip6: ")
    ByohVmGuestKernel[vm.id].update(release: "6.12.33-pvm-guest")
    ByohPvmGuestKernel.create(vm_host_id: host.id, sha256: "b" * 64, state: "ready", console: "hvc0", config_checked: true)
    host.update(virt_probe: nil)
    expect(cli(%W[vm #{ref} show -f virt-tier])).to eq "virt-tier: pvm (experimental) #{description}\n  guest-kernel: 6.12.33-pvm-guest sha256 #{"b" * 64} config checked\n"
  end

  it "-f option controls which fields are shown for VM" do
    expect(cli(%W[vm #{@ref} show -f id,name])).to eq <<~END
      id: #{@vm.ubid}
      name: test-vm
    END
  end

  it "-w option controls which fields are shown for VM's firewalls" do
    expect(cli(%W[vm #{@ref} show -f id,firewalls -w id,name])).to eq <<~END
      id: #{@vm.ubid}
      firewall 1:
        id: #{@fw.ubid}
        name: default-eu-central-h1-default
    END
  end

  it "-r option controls which fields are shown rules for VM's firewalls" do
    expect(cli(%W[vm #{@ref} show -f firewalls -w firewall-rules -r cidr,port-range])).to eq <<~END
      firewall 1:
        rules:
          1: 0.0.0.0/0  0..65535  
          2: 0.0.0.0/0  0..65535  
          3: ::/0  0..65535  
          4: ::/0  0..65535  
    END
  end
end
