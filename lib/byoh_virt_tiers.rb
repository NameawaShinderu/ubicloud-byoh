# frozen_string_literal: true

# The lower rungs of the virtualization ladder (docs/byoh/NO_KVM.md) as
# data, and the one policy every lower-rung VM and host passes.
#
# A host is registered on one tier and keeps it (vm_host.virt_tier, a DB
# trigger refuses changes). "kvm" is every host as it was before tiers
# existed: cloud-hypervisor, or QEMU-KVM for some GPUs, with every
# upstream family. The other tiers each own exactly one family, so their
# hosts and VMs never mix with KVM ones (a CHECK on vm_host ties tier and
# family). tier_for_family therefore says "kvm" for any family not listed
# here, including AWS, GCP and GPU families.
#
# A lower-tier VM is created only when all of these hold (check_vm!):
# - the caller of Prog::Vm::Nexus.assemble allowed the tier (the default
#   is kvm only, so services, runners, Kubernetes and VM pools never get
#   one);
# - the tier is shipped (SHIPPED: its rhizome support exists);
# - the location is a BYOH location whose byoh_virt policy lists the
#   tier, which requires the operator's acknowledgement of it;
# - the project may use the location, and no other project has a
#   lower-tier VM there unless the tier's "multitenant" option is
#   acknowledged and its host checks exist (check_tenancy!, under a lock
#   on the location row);
# - it uses no GPU, no machine image, no remote storage and no explicit
#   hypervisor, and one of the tier's boot images.
module ByohVirtTiers
  KVM = "kvm"

  # Per tier:
  #   rung             the ladder rung, for display only
  #   prep_arg         the tier argument of rhizome's prep_host.rb
  #   hypervisor       what runs its VMs: "lxc", "ch" (cloud-hypervisor) or
  #                    "qemu" (the QEMU emulator, accel tcg)
  #   description      what customers and operators are told
  #   storage          "vhost" (ubiblk volumes, as on KVM hosts) or "none"
  #                    (the tier keeps its own disks; no vhost backend)
  #   options          what the operator can acknowledge beyond the tier
  #   boot_images      the boot images its VMs may use; its hosts download
  #                    the first unless registration names others of them
  #   host_reserve_mib memory kept for the host itself
  #   vm_overhead_mib  memory each VM needs beyond its own RAM
  #   min_vcpus        vCPUs of the smallest size, to bound the VM count
  # None of the tiers uses 1G hugepages; verify_tier_capacity keeps a
  # memory budget in the hugepage columns instead.
  Tier = Data.define(:id, :rung, :prep_arg, :hypervisor, :description, :storage, :options, :boot_images,
    :host_reserve_mib, :vm_overhead_mib, :min_vcpus) do
    def family = id

    def label = "#{id} (#{rung}, experimental)"
  end

  TIERS = {
    "container" => Tier.new(
      id: "container", rung: "L3", prep_arg: "container", hypervisor: "lxc",
      description: "System container: shared host kernel, near-native speed. Not a VM.",
      storage: "none", options: %w[multitenant unencrypted-disk nested-userns guest-firewall],
      boot_images: %w[ubuntu-noble-container],
      # Provisional (UNVERIFIED): lxc monitor, lxcfs share and dnsmasq.
      host_reserve_mib: 2048, vm_overhead_mib: 128, min_vcpus: 2,
    ),
    "pvm" => Tier.new(
      id: "pvm", rung: "L4", prep_arg: "pvm", hypervisor: "ch",
      description: "PVM: software virtualization (experimental). Weaker isolation than standard VMs; Ubicloud-supplied guest kernel without AppArmor. Linux only.",
      storage: "vhost", options: %w[multitenant],
      boot_images: %w[ubuntu-noble],
      # Provisional (UNVERIFIED): cloud-hypervisor, ubiblk, dnsmasq and
      # shadow page tables.
      host_reserve_mib: 2048, vm_overhead_mib: 384, min_vcpus: 2,
    ),
    "emulated" => Tier.new(
      id: "emulated", rung: "L5", prep_arg: "emulated", hypervisor: "qemu",
      description: "Emulated: slow, compatibility only. Not a security boundary.",
      # No multitenant option: not a security boundary, so one project
      # per location (docs/byoh/NO_KVM.md section 12).
      storage: "vhost", options: [],
      boot_images: %w[ubuntu-noble ubuntu-jammy],
      # docs/byoh/EMULATED_HOSTS.md section 6.4: QEMU's 256 MiB
      # translation cache plus about 128 MiB of QEMU itself (measured
      # 384 MiB together), ubiblk and dnsmasq, with headroom. Provisional.
      host_reserve_mib: 2048, vm_overhead_mib: 512, min_vcpus: 2,
    ),
  }.freeze

  IDS = [KVM, *TIERS.keys].freeze

  # The lower tiers whose rhizome support exists, so that a location can
  # offer them and hosts can be registered on them. A tier joins this
  # list in the commit that ships it (docs/byoh/NO_KVM.md section 11).
  SHIPPED = %w[container emulated].freeze

  # The tiers whose "multitenant" acknowledgement takes effect: those
  # whose hosts are checked for what sharing needs (docs/byoh/NO_KVM.md
  # section 6.5 and the policy table: for pvm SMT off or core scheduling
  # and CPUs not affected by l1tf and mds, for container whole-core
  # cpusets or SMT off). No such check exists yet, so until the WP that
  # ships a tier adds it, bin/byoh-location refuses the acknowledgement
  # and every lower tier stays single-project.
  MULTITENANT_CHECKED = [].freeze

  # The acknowledgement of a tier itself, stored as the tier's key in
  # byoh_virt["acks"].
  DEFAULT_POLICY = {"tiers" => [KVM], "acks" => {}}.freeze

  class Refused < StandardError; end

  # The billing rates a lower-tier VM is charged by, per family.
  RATE_TYPES = %w[VmVCpu VmStorage].freeze

  def self.fetch(id)
    TIERS.fetch(id) { raise Refused, "unknown tier #{id.inspect}; expected one of #{IDS.join(", ")}" }
  end

  def self.tier_for_family(family)
    TIERS.key?(family) ? family : KVM
  end

  def self.lower?(tier) = tier != KVM

  def self.shipped?(tier) = tier == KVM || SHIPPED.include?(tier)

  def self.family_for(tier) = lower?(tier) ? fetch(tier).family : "standard"

  # Whether hosts of the tier run cloud-hypervisor, so that downloading
  # it or its firmware there makes sense: KVM and PVM hosts do; container
  # and emulated hosts never start it.
  def self.runs_cloud_hypervisor?(tier) = !lower?(tier) || fetch(tier).hypervisor == "ch"

  # Emulated VMs boot under QEMU's software translator: 64-96 s to SSH on
  # an idle lab host (docs/byoh/EMULATED_HOSTS.md section 3), several
  # times that on a loaded one, and a guest shutdown is as slow. So on an
  # emulated host the VM path waits longer before paging or giving up
  # (Prog::Vm::Metal::Nexus); every other host keeps today's values.
  # Seconds, per host tier.
  SLOW_TIMINGS = {
    "emulated" => {start_deadline: 30 * 60, netns_probe: 28 * 60, soft_stop: 180},
  }.freeze

  def self.slow_timing(tier, key) = SLOW_TIMINGS.dig(tier, key)

  # The location's policy. Only BYOH locations have one; every other
  # location is KVM only.
  def self.policy(location)
    return DEFAULT_POLICY unless location.byoh? && location.byoh_virt

    DEFAULT_POLICY.merge(location.byoh_virt.to_h)
  end

  def self.tiers(location) = policy(location)["tiers"]

  def self.allows?(location, tier) = tiers(location).include?(tier)

  # Whether the operator acknowledged the tier, or one of its options.
  def self.acked?(location, tier, option = nil)
    acks = policy(location)["acks"]
    return false unless acks.key?(tier)

    option.nil? || Array(acks[tier]).include?(option)
  end

  def self.multitenant_checked?(tier) = MULTITENANT_CHECKED.include?(tier)

  # Whether projects may share the tier in a location with this policy:
  # the operator acknowledged "multitenant" and its host checks exist.
  def self.shared?(policy, tier)
    multitenant_checked?(tier) && Array(policy["acks"][tier]).include?("multitenant")
  end

  # The lower-tier families a customer may pick in the location: shipped
  # tiers that the location offers. Empty for every non-BYOH location.
  def self.offered_families(location)
    tiers(location).select { lower?(it) && shipped?(it) }.map { fetch(it).family }
  end

  # The boot images of the lower tier whose size the customer picked, if
  # the size is one of the offered families' (offered_families); [] for
  # every other size, so only those boot images widen what a VM create
  # accepts.
  def self.boot_images_for_size(size, families)
    vm_size = Option::TierVmSizes.find { it.name == size && families.include?(it.family) }
    vm_size ? fetch(tier_for_family(vm_size.family)).boot_images : []
  end

  # The families of allowed_tiers that Validation.validate_vm_size may
  # accept for a VM in the location.
  def self.size_families(location, allowed_tiers)
    lower = allowed_tiers.select { lower?(it) }
    return [] if lower.empty?

    offered_families(location) & lower.map { fetch(it).family }
  end

  # Whether a host's probe verdict matches the tier it was registered on:
  # a KVM host must run today's VMs; a lower-tier host must have that
  # tier's prerequisites in place (VirtProbe.fallbacks "ready"), and a PVM
  # host none of PVM's hard refusals (ByohVirtLadder.pvm_refusal).
  # Agreement is a safety check, never an authorization.
  def self.accepts_probe?(tier, verdict)
    return verdict.standard_vms? if tier == KVM
    return false if tier == "pvm" && ByohVirtLadder.pvm_refusal(verdict.report["facts"])

    verdict.ready.include?(tier)
  end

  def self.refuse(message)
    raise Validation::ValidationFailed.new({size: message})
  end

  # The policy of section 5.3 of docs/byoh/NO_KVM.md for a lower-tier VM,
  # except tenancy (check_tenancy!). Raises Validation::ValidationFailed.
  def self.check_vm!(tier, location:, project:, allowed_tiers:, gpu_count:, boot_image:, storage_volumes:, hypervisor:, ch_version:, remote_storage_server_id:)
    spec = fetch(tier)
    refuse "#{tier} VMs are not available to this caller" unless allowed_tiers.include?(tier)
    refuse "#{tier} VMs are not available yet" unless shipped?(tier)
    refuse "#{tier} VMs are only available in BYOH locations" unless location.byoh?
    refuse "location #{location.display_name} does not offer #{tier} VMs" unless allows?(location, tier) && acked?(location, tier)
    unless location.visible_or_for_project?(project.id, project.get_ff_visible_locations)
      refuse "location #{location.display_name} is not available to this project"
    end
    # Billing records charge the VM's family (Prog::Vm::Metal::Nexus).
    RATE_TYPES.each { Validation.validate_billing_rate(it, spec.family, location.name) }
    refuse "#{tier} VMs cannot have GPUs" if gpu_count.to_i > 0
    refuse "#{tier} VMs choose their hypervisor from the host" if hypervisor || ch_version
    refuse "#{tier} VMs can only boot #{spec.boot_images.join(", ")}" unless spec.boot_images.include?(boot_image)
    if remote_storage_server_id || storage_volumes.any? { it[:machine_image_version_id] || it[:remote_storage_server_id] }
      refuse "#{tier} VMs cannot use machine images or remote storage"
    end
    if spec.storage == "none"
      refuse "#{tier} VMs cannot track written blocks" if storage_volumes.any? { it[:track_written] }
      # The guest's root file system is its only disk (ContainerDisk).
      refuse "#{tier} VMs have exactly one disk" unless storage_volumes.size == 1 && !storage_volumes.first[:read_only]
    end
    nil
  end

  # Whether a container VM's disk is encrypted (crypt-loop) or a plain
  # directory under a project quota (dir): the location decides, by
  # acknowledging "container:unencrypted-disk" (docs/byoh/NO_KVM.md
  # section 4.2).
  def self.container_disk_encrypted?(location) = !acked?(location, "container", "unencrypted-disk")

  # The container options rhizome applies (ContainerSetup) that the
  # location acknowledged.
  def self.container_options(location)
    {"nested_userns" => acked?(location, "container", "nested-userns"), "guest_firewall" => acked?(location, "container", "guest-firewall")}
  end

  # Whether the VM keeps non-root users off the load balancer cert
  # server address: every VM but a container one in a location that did
  # not acknowledge container:guest-firewall (rhizome drops the guard and
  # the address there).
  def self.cert_server_guarded?(vm)
    vm.family != "container" || acked?(vm.location, "container", "guest-firewall")
  end

  # One project per location for every lower tier, unless the tier is
  # shared (shared?). Takes a lock on the location row, so two creates
  # for different projects cannot both pass; call it inside the create
  # transaction.
  def self.check_tenancy!(tier, location, project_id)
    Location.dataset.for_update.where(id: location.id).get(:id)
    return if shared?(policy(location), tier)

    others = Vm.where(location_id: location.id, family: TIERS.values.map(&:family)).exclude(project_id:)
    refuse "location #{location.display_name} already runs lower-tier VMs of another project, and its #{tier} tier is single-project" unless others.empty?
  end

  # The tier's smallest VM size: what a host must hold at least one of.
  def self.smallest_size(tier)
    family = fetch(tier).family
    Option::TierVmSizes.select { it.family == family }.min_by(&:vcpus)
  end

  # The guest memory budget in GiB of a lower-tier host
  # (docs/byoh/EMULATED_HOSTS.md section 6.4, for every tier): MemTotal
  # without hugepages and the kernel's 1/43 share for page tables and the
  # like, less the host reserve and the overhead of as many VMs of the
  # smallest size as the host has CPUs for. Never below 0.
  def self.memory_budget_gib(tier, mem_total_mib:, hugepages_mib:, total_cpus:)
    spec = fetch(tier)
    usable_mib = (mem_total_mib - hugepages_mib) * 42 / 43
    max_vms = total_cpus / spec.min_vcpus
    [(usable_mib - spec.host_reserve_mib - spec.vm_overhead_mib * max_vms) / 1024, 0].max
  end
end
