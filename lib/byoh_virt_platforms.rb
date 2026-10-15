# frozen_string_literal: true

# Data table for the virtualization ladder (docs/byoh/NO_KVM.md): how to
# recognize the platform a host runs on from what VirtProbe reports, and
# how to get KVM there. Code never branches on a platform; it only looks
# rows up here, so a new platform is a new row.
#
# Each row:
#   key     stable identifier, also the anchor in NO_KVM.md section 4
#   name    shown to the operator
#   match   every listed fact must match its pattern. Keys are DMI fields
#           (/sys/class/dmi/id) or "virt_vm" (systemd-detect-virt --vm).
#   nested  :yes (offered everywhere), :some (on some types or when
#           switched on), :no (not offered), :ask (depends on whoever runs
#           the hypervisor)
#   fix     how to get a usable /dev/kvm on this platform
#   cost_hint  what the fix costs compared with staying put, or nil.
#           Prices are approximate and UNVERIFIED (docs/byoh/NO_KVM.md
#           section 7); only these texts talk about price.
#   rules   narrower advice inside the platform: the first rule whose
#           patterns all match replaces fix and cost_hint. AWS uses it
#           for the instance type in product_name.
#
# The first matching row wins, so narrower rows come first. The fix texts
# summarize the sources in NO_KVM.md section 4, which carries the
# citations and confidence; provider offerings change, and the doc says
# when each was checked.
module ByohVirtPlatforms
  Row = Data.define(:key, :name, :match, :nested, :fix, :cost_hint, :rules) do
    def initialize(cost_hint: nil, rules: [], **)
      super
    end
  end

  Rule = Data.define(:match, :fix, :cost_hint) do
    def initialize(cost_hint: nil, **)
      super
    end
  end

  AWS_COST = "C8i, M8i and R8i cost about the same per vCPU as other current families of the same size; .metal costs far more because it is a whole server (approximate and UNVERIFIED; check current pricing)."

  NESTED = %i[yes some no ask].freeze

  ROWS = [
    Row.new(
      key: "aws",
      name: "AWS EC2",
      match: {"sys_vendor" => /\AAmazon EC2\z/},
      nested: :some,
      fix: "This instance family does not expose VT-x. Move to C8i, M8i or R8i (the 8th-generation Intel families that offer nested virtualization) and enable nested virtualization in the CPU options, or to a .metal type.",
      cost_hint: AWS_COST,
      # On Nitro the DMI product_name is the instance type. The family
      # list is explicit and sourced (docs/byoh/NO_KVM.md section 4); no
      # generation is assumed to support nested virtualization.
      rules: [
        Rule.new(
          match: {"product_name" => /\A(?:c8i|m8i|r8i)\./},
          fix: "This instance family offers nested virtualization, but it is switched off: stop the instance, enable nested virtualization in its CPU options, and start it again.",
          cost_hint: "Enabling nested virtualization does not change the instance price (UNVERIFIED; check current pricing).",
        ),
        Rule.new(
          match: {"product_name" => /\.metal\z/},
          fix: "A .metal instance has VT-x, so this host should be L1: check that the KVM module loads (modprobe kvm_intel, or kvm_amd) and read the kernel log.",
          cost_hint: nil,
        ),
      ],
    ),
    Row.new(
      key: "aws_xen",
      name: "AWS EC2 (Xen-based instance type)",
      match: {"sys_vendor" => /\AXen\z/, "product_version" => /amazon/i},
      nested: :no,
      fix: "This is a Xen-based EC2 instance type (an older family such as t2 or m4), and Xen types never expose VT-x. Move to a Nitro type: C8i, M8i or R8i with nested virtualization enabled in the CPU options, or a .metal type.",
      cost_hint: AWS_COST,
    ),
    Row.new(
      key: "gcp",
      name: "Google Compute Engine",
      match: {"sys_vendor" => /\AGoogle\z/, "product_name" => /Google Compute Engine/},
      nested: :some,
      fix: "Recreate the VM with --enable-nested-virtualization on an Intel machine series (or AMD N4D); E2, memory-optimized and Arm series do not support it, and the organization policy constraints/compute.disableNestedVirtualization must not be enforced.",
      cost_hint: "Google charges nothing extra for nested virtualization; an Intel N2 or C3 VM costs about the same as an E2 VM of the same size or somewhat more (approximate; check current pricing).",
    ),
    Row.new(
      key: "azure",
      name: "Microsoft Azure",
      match: {"sys_vendor" => /\AMicrosoft Corporation\z/, "chassis_asset_tag" => /\A7783-7084-3265-9085-8269-3286-77\z/},
      nested: :some,
      fix: "Resize to a size whose documentation lists nested virtualization as supported (Dv3/Ev3 and newer general-purpose and memory families); B-series and A-series do not support it.",
      cost_hint: "Dv5 and Ev5 sizes cost about the same as B-series sizes with the same vCPUs and memory or somewhat more (approximate and UNVERIFIED; check current pricing).",
    ),
    Row.new(
      key: "hyperv",
      name: "Microsoft Hyper-V",
      match: {"sys_vendor" => /\AMicrosoft Corporation\z/, "product_name" => /\AVirtual Machine\z/},
      nested: :yes,
      fix: "With the VM off, run on the Hyper-V host: Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true",
    ),
    Row.new(
      key: "vmware",
      name: "VMware vSphere / Workstation",
      match: {"sys_vendor" => /\AVMware/},
      nested: :yes,
      fix: "Power the VM off, then enable \"Expose hardware assisted virtualization to the guest OS\" in its CPU settings (vhv.enable = \"TRUE\").",
    ),
    Row.new(
      key: "virtualbox",
      name: "VirtualBox",
      match: {"product_name" => /\AVirtualBox\z/},
      nested: :yes,
      fix: "Power the VM off, then run: VBoxManage modifyvm <vm> --nested-hw-virt on",
    ),
    Row.new(
      key: "oci",
      name: "Oracle Cloud Infrastructure",
      match: {"chassis_asset_tag" => /\AOracleCloud\.com\z/},
      nested: :some,
      fix: "Use an x86 VM shape that exposes nested virtualization (VM.Standard3.Flex on Intel, VM.Standard.E5.Flex on AMD) or a bare-metal shape; Ampere (Arm) VM shapes do not.",
    ),
    Row.new(
      key: "hetzner_cloud",
      name: "Hetzner Cloud",
      match: {"sys_vendor" => /\AHetzner\z/},
      nested: :no,
      fix: "Hetzner Cloud servers do not expose VT-x/AMD-V. Use a Hetzner dedicated server, which has full KVM.",
      cost_hint: "A Hetzner dedicated server (AX or EX line) costs about as much per month as a cloud server with 8 or more dedicated cores (approximate and UNVERIFIED; check current pricing).",
    ),
    Row.new(
      key: "digitalocean",
      name: "DigitalOcean",
      match: {"sys_vendor" => /\ADigitalOcean\z/},
      nested: :no,
      fix: "DigitalOcean does not support nested virtualization on Droplets (some Intel Droplets expose VT-x, unsupported and slow). Use bare metal elsewhere, or a fallback rung.",
    ),
    Row.new(
      key: "linode",
      name: "Akamai Cloud (Linode)",
      match: {"sys_vendor" => /Linode|Akamai/},
      nested: :no,
      fix: "Akamai Cloud (Linode) does not offer nested virtualization. Use bare metal elsewhere, or a fallback rung.",
    ),
    Row.new(
      key: "vultr",
      name: "Vultr",
      match: {"sys_vendor" => /\AVultr\z/},
      nested: :no,
      fix: "Vultr cloud instances do not expose hardware virtualization. Use Vultr Bare Metal, or a fallback rung.",
    ),
    Row.new(
      key: "scaleway",
      name: "Scaleway",
      match: {"sys_vendor" => /\AScaleway\z/},
      nested: :ask,
      fix: "Check whether the instance type exposes VT-x/AMD-V (some do); otherwise use a Scaleway Elastic Metal server.",
    ),
    Row.new(
      key: "openstack",
      name: "OpenStack cloud (OVHcloud Public Cloud and others)",
      match: {"product_name" => /OpenStack/},
      nested: :ask,
      fix: "Nested virtualization depends on the cloud operator (nova cpu_mode host-passthrough and kvm nested=1 on compute nodes). Ask the provider for a flavor with VT-x/AMD-V, or use a dedicated server.",
    ),
    Row.new(
      key: "qemu_kvm",
      name: "QEMU/KVM (Proxmox VE, libvirt, KVM-based VPS)",
      match: {"sys_vendor" => /\AQEMU\z/},
      nested: :ask,
      fix: "Proxmox VE: qm set <vmid> --cpu host, with nested enabled on the node (cat /sys/module/kvm_intel/parameters/nested prints Y; else add \"options kvm-intel nested=Y\" (or kvm-amd nested=1) under /etc/modprobe.d and reload the module). libvirt: <cpu mode='host-passthrough'/>. A VPS provider must enable it for you.",
    ),
    Row.new(
      key: "xen",
      name: "Xen",
      match: {"virt_vm" => /\Axen\z/},
      nested: :ask,
      fix: "Xen HVM guests see VT-x only with nestedhvm=1 in the domain configuration, which Xen marks experimental; most Xen-based VPS do not offer it.",
    ),
  ].freeze

  GENERIC_FIX = "Enable nested virtualization (expose VT-x/AMD-V) in the hypervisor below this VM, or use bare metal."

  # The row for a probe's facts, or nil when none matches.
  def self.match(facts)
    values = values(facts)
    ROWS.find { matches?(it.match, values) }
  end

  # The fix and cost hint for a probe's facts on a row, after the row's
  # rules.
  def self.advice(row, facts)
    values = values(facts)
    rule = row.rules.find { matches?(it.match, values) }
    rule ? [rule.fix, rule.cost_hint] : [row.fix, row.cost_hint]
  end

  def self.values(facts)
    dmi = facts.fetch("dmi", {})
    (dmi.is_a?(Hash) ? dmi : {}).merge("virt_vm" => facts["virt_vm"])
  end

  def self.matches?(patterns, values)
    patterns.all? { |field, pattern| values[field].is_a?(String) && pattern.match?(values[field]) }
  end
end
