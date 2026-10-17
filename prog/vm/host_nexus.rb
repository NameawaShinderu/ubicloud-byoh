# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  subject_is :sshable, :vm_host
  frame_reader :vhost_block_backend_version, :default_boot_images, :install_os
  frame_accessor :accepting_before_patch, :pvm_patch_kernels, :pvm_status, :pvm_reinstall, :pvm_drained, :pvm_boot_waits

  def self.assemble(sshable_hostname, location_id: Location::HETZNER_FSN1_ID, family: "standard", net6: nil, ndp_needed: false, provider_name: nil, server_identifier: nil, provider_config: nil, ssh_private_key: nil, vhost_block_backend_version: Config.vhost_block_backend_version, default_boot_images: [], install_os: false, ipv6_mode: "gua", virt_tier: ByohVirtTiers::KVM, pinned_host_keys: nil, pvm_install: nil, pvm_facts: {})
    DB.transaction do
      unless (location = Location[location_id])
        raise "No existing Location"
      end

      # Only a BYOH location carries the network profile that BYOH hosts
      # are configured from.
      if provider_name == HostProvider::GENERIC_PROVIDER_NAME && !location.byoh?
        raise "A generic provider host needs a BYOH location, but #{location.name} is not one"
      end

      # BYOH hosts cannot rely on Prog::LearnNetwork because a typical
      # self-hosted server has no globally-routed IPv6 to auto-discover.
      # The operator declares the /64 (ULA is fine) in provider_config and
      # we pass it through as the net6 kwarg so LearnNetwork is skipped.
      if provider_name == HostProvider::GENERIC_PROVIDER_NAME && net6.nil? && provider_config
        declared = Array(provider_config["routed_networks"]).find { |n| n["cidr"].include?(":") }
        net6 = declared["cidr"] if declared
      end

      # A lower virtualization tier (docs/byoh/NO_KVM.md) only for BYOH
      # hosts in a location that offers it; such a host gets its tier's
      # family, which keeps its VMs apart from KVM ones.
      host_args = {location_id:, family:, net6:, ndp_needed:, ipv6_mode:}
      if ByohVirtTiers.lower?(virt_tier)
        ByohVirtTiers.fetch(virt_tier)
        raise "A host of virt tier #{virt_tier} must be a generic provider host in a BYOH location" unless provider_name == HostProvider::GENERIC_PROVIDER_NAME && location.byoh?
        raise "#{virt_tier} hosts are not available yet" unless ByohVirtTiers.shipped?(virt_tier)
        raise "Location #{location.name} does not offer #{virt_tier} hosts" unless ByohVirtTiers.allows?(location, virt_tier) && ByohVirtTiers.acked?(location, virt_tier)
        raise "A host of virt tier #{virt_tier} has family #{virt_tier}, not #{family}" unless family == "standard"
        # Its VMs boot only the tier's images; it downloads the first of
        # them unless registration names others.
        tier_images = ByohVirtTiers.fetch(virt_tier).boot_images
        default_boot_images = tier_images.first(1) if default_boot_images.empty?
        unless (other = default_boot_images - tier_images).empty?
          raise "A host of virt tier #{virt_tier} cannot boot #{other.join(", ")}; its images are #{tier_images.join(", ")}"
        end
        host_args[:family] = ByohVirtTiers.family_for(virt_tier)
        host_args[:virt_tier] = virt_tier
      elsif provider_name == HostProvider::GENERIC_PROVIDER_NAME && !ByohVirtTiers.allows?(location, virt_tier)
        raise "Location #{location.name} does not offer kvm hosts"
      end

      # A pvm host's PVM kernel (docs/byoh/NO_KVM.md section 6.7): the
      # control plane installs the location's pin (install_pending, the
      # operator's --install-pvm-kernel), or the host runs one already
      # (committed). A location that offers pvm pins both kernels (its
      # byoh_virt CHECK).
      if virt_tier == "pvm"
        raise "A pvm host is registered with pvm_install install_pending or committed, not #{pvm_install.inspect}" unless %w[install_pending committed].include?(pvm_install)
      elsif pvm_install
        raise "Only a pvm host takes pvm_install"
      end

      # Host keys the operator confirmed for a BYOH host. They are stored
      # before the first connection, and BootstrapRhizome verifies even
      # its first root login against them.
      if pinned_host_keys
        raise "Only a generic provider host takes pinned host keys" unless provider_name == HostProvider::GENERIC_PROVIDER_NAME
        raise "pinned_host_keys is empty" if pinned_host_keys.empty?

        pinned_host_keys = ByohOperatorSsh::HostKey.lines(pinned_host_keys)
      end

      id = VmHost.generate_uuid
      # Preloading raw_private_key_1 at creation time is the supported path
      # for BYOH hosts: the operator installs the matching public key on the
      # host out-of-band, the CLI passes the private key here, and
      # setup_ssh_keys later sees raw_private_key_1 is already set and skips
      # generation. Without this, there'd be a race between strand dispatch
      # and the CLI storing the key.
      sshable_args = {host: sshable_hostname}
      sshable_args[:raw_private_key_1] = ssh_private_key if ssh_private_key
      sshable_args[:host_keys] = Sequel.pg_array(pinned_host_keys, :text) if pinned_host_keys
      Sshable.create_with_id(id, **sshable_args)
      vmh = VmHost.create_with_id(id, **host_args)
      if pvm_install
        ByohPvmHost.create(vm_host_id: id, state: pvm_install, install: pvm_install == "install_pending",
          lockdown: pvm_facts["lockdown"], meltdown: pvm_facts["meltdown"], host_deb_sha256: pvm_facts["host_deb_sha256"])
      end

      if [HostProvider::HETZNER_PROVIDER_NAME, *HostProvider::LEASEWEB_PROVIDER_NAMES, HostProvider::GENERIC_PROVIDER_NAME].include?(provider_name)
        effective_server_identifier = server_identifier
        if provider_name == HostProvider::GENERIC_PROVIDER_NAME
          effective_server_identifier ||= "byoh-#{id}"
        end
        HostProvider.create do |hp|
          hp.id = id
          hp.provider_name = provider_name
          hp.server_identifier = effective_server_identifier
          hp.config = provider_config if provider_config
        end
      end

      if [HostProvider::HETZNER_PROVIDER_NAME, *HostProvider::LEASEWEB_PROVIDER_NAMES].include?(provider_name)
        vmh.create_addresses
        vmh.set_data_center
        vmh.create_inventory
        # Avoid overriding custom server names for development hosts.
        vmh.set_server_name unless Config.development?
      elsif provider_name == HostProvider::GENERIC_PROVIDER_NAME
        # Same pattern as Hetzner: GenericApis#pull_ips returns the declared
        # routed v4 blocks (auto-prepended with the management /32), and
        # create_addresses turns them into Address + ipv4_address rows that
        # the allocator can assign to VMs.
        vmh.create_addresses
      else
        Address.create_with_id(id, cidr: sshable_hostname, routed_to_host_id: id)
        AssignedHostAddress.create(ip: sshable_hostname, address_id: id, host_id: id)
      end

      frame = {"vhost_block_backend_version" => vhost_block_backend_version, "default_boot_images" => default_boot_images, "install_os" => install_os}
      frame["pin_host_keys"] = true if pinned_host_keys
      Strand.create_with_id(id,
        prog: "Vm::HostNexus",
        label: "start",
        stack: [frame])
    end
  end

  label def start
    hop_install_host_os if install_os

    hop_setup_ssh_keys
  end

  label def install_host_os
    hop_setup_ssh_keys unless vm_host.provider_name == HostProvider::HETZNER_PROVIDER_NAME

    register_deadline("setup_ssh_keys", 2 * 60 * 60)
    hop_setup_ssh_keys if retval&.dig("msg") == "operating system installed"

    push Prog::Hetzner::InstallOs
  end

  label def setup_ssh_keys
    # Generate a new SSH key if one is not set.
    sshable.update(raw_private_key_1: SshKey.generate.keypair) unless sshable.raw_private_key_1

    # BYOH hosts never carry the provider's preshared root key: the operator
    # installed the sshable key out-of-band, so the root-key bootstrap would
    # only fail against them.
    if vm_host.provider_name != HostProvider::GENERIC_PROVIDER_NAME && Config.hetzner_ssh_private_key
      root_key = Net::SSH::Authentication::ED25519::PrivKey.read(Config.hetzner_ssh_private_key, Config.hetzner_ssh_private_key_passphrase).sign_key
      root_ssh_key = SshKey.from_binary(root_key.keypair)

      public_keys = sshable.keys.first.public_key
      public_keys += "\n#{Config.operator_ssh_public_keys}" if Config.operator_ssh_public_keys

      Util.rootish_ssh(sshable.host, "root", root_ssh_key.private_key, "echo :public_keys > ~/.ssh/authorized_keys", public_keys:)
    end

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline("download_boot_images", 10 * 60)
    hop_check_ip_reachability if retval&.dig("msg") == "rhizome user bootstrapped and source installed"

    bootstrap_frame = {"target_folder" => "host"}
    bootstrap_frame["pin_host_keys"] = true if frame["pin_host_keys"]
    push Prog::BootstrapRhizome, bootstrap_frame
  end

  label def check_ip_reachability
    hop_prep if retval&.dig("msg") == "all ip addresses are reachable"

    # A BYOH host's pool must never be configured on the host (NETWORKING.md
    # contract C5), which the check does to test it, and the management
    # address may sit behind NAT or a firewall that drops ICMP. PrepHost's
    # downloads prove outbound reachability instead.
    hop_prep if vm_host.provider_name == HostProvider::GENERIC_PROVIDER_NAME

    push Prog::CheckIpReachability
  end

  label def prep
    bud Prog::Vm::PrepHost
    bud Prog::LearnNetwork unless vm_host.net6
    bud Prog::LearnMemory
    bud Prog::LearnOs
    bud Prog::LearnCpu
    bud Prog::LearnStorage, {"format_storage" => install_os}
    bud Prog::LearnPci
    bud Prog::InstallDnsmasq
    bud Prog::SetupSysstat
    bud Prog::SetupNftables
    bud Prog::SetupByohEgressNat if vm_host.byoh?
    bud Prog::LearnVirt if vm_host.byoh?
    bud Prog::SetupNdpProxy if vm_host.ndp_needed
    bud Prog::SetupNodeExporter
    hop_wait_prep
  end

  def os_supports_slices?(os_version)
    os_version == "ubuntu-24.04"
  end

  label def wait_prep
    reaper = lambda do |st|
      case st.prog
      when "LearnOs"
        os_version = st.exitval.fetch("os_version")
        # Slices are cgroups for cloud-hypervisor's dedicated CPUs; lower
        # tiers run their VMs without them.
        vm_host.update(os_version:, accepts_slices: os_supports_slices?(os_version) && !ByohVirtTiers.lower?(vm_host.virt_tier))
      when "LearnMemory"
        mem_gib = st.exitval.fetch("mem_gib")
        vm_host.update(total_mem_gib: mem_gib)
      when "LearnCpu"
        arch = st.exitval.fetch("arch")
        total_cores = st.exitval.fetch("total_cores")
        total_cpus = st.exitval.fetch("total_cpus")
        cpu_numa_nodes = st.exitval.fetch("cpu_numa_nodes")
        kwargs = {
          arch:,
          total_sockets: st.exitval.fetch("total_sockets"),
          total_dies: st.exitval.fetch("total_dies"),
          total_cores:,
          total_cpus:,
        }
        vm_host.update(**kwargs)
        # BYOH (generic) hosts run vhost-block-backend, never SPDK, so they
        # set no CPUs aside for IO. Decide once, so the reserved CPUs and
        # used_cores agree.
        io_cpu_count = (vm_host.provider_name == HostProvider::GENERIC_PROVIDER_NAME) ? 0 : vm_host.io_cpu_count
        # A lower-tier host keeps one core for the host itself: its VMs'
        # vCPUs are host threads that may use all of their cores
        # (docs/byoh/EMULATED_HOSTS.md section 6.4).
        reserved_cores = ByohVirtTiers.lower?(vm_host.virt_tier) ? 1 : 0
        # LearnCpu reports the online CPU numbers of a BYOH host, which can
        # have gaps; cpu_numa_nodes is aligned with them by position.
        cpu_numbers = st.exitval["cpu_numbers"] || (0..total_cpus - 1).to_a
        fail "LearnCpu reported #{cpu_numbers.size} cpu numbers for #{total_cpus} cpus" unless cpu_numbers.size == total_cpus
        cpu_numbers.each_with_index do |cpu, index|
          VmHostCpu.create(
            vm_host_id: vm_host.id,
            cpu_number: cpu,
            io: index < io_cpu_count,
            numa_node: cpu_numa_nodes[index],
          )
        end
        vm_host.update(used_cores: io_cpu_count * total_cores / total_cpus + reserved_cores)
      end
    end

    reap(ByohVirtTiers.lower?(vm_host.virt_tier) ? :verify_virt_tier : :setup_hugepages, reaper:)
  end

  # A lower-tier host goes on only once Prog::LearnVirt found the tier's
  # prerequisites on it; it pages with the fix otherwise. The check is
  # repeated (with the strand's backoff) until bin/byoh-virt refresh
  # records a probe that agrees. Lower tiers use no 1G hugepages. A pvm
  # host must also run an Ubuntu whose cloud-hypervisor PVM VMs run on
  # (ByohVirtTiers.pvm_os_ok?); rhizome checks the version again per VM.
  label def verify_virt_tier
    probe = vm_host.virt_probe&.to_h
    fail "#{vm_host.virt_tier} host has no virtualization probe yet; run bin/byoh-virt refresh --host #{vm_host.ubid}" if probe.nil? || probe["error"]

    verdict = ByohVirtLadder.verdict(probe)
    pvm_install = pvm_row&.state if pvm_host?
    unless ByohVirtTiers.accepts_probe?(vm_host.virt_tier, verdict, pvm_install:)
      fail "#{vm_host.virt_tier} host does not have the tier's prerequisites (probe: #{verdict.summary}); fix it, then run bin/byoh-virt refresh --host #{vm_host.ubid}"
    end
    if pvm_host? && !ByohVirtTiers.pvm_os_ok?(vm_host.os_version)
      fail "pvm host runs #{vm_host.os_version || "an unknown OS"}; pvm VMs need cloud-hypervisor #{ByohVirtTiers::PVM_MIN_CH} or later, which rhizome installs on Ubuntu #{ByohVirtTiers::PVM_MIN_UBUNTU} or later only; reinstall the host with Ubuntu #{ByohVirtTiers::PVM_MIN_UBUNTU} and register it again"
    end
    check_pvm_preflight if pvm_install == "install_pending"

    hop_download_boot_images if ByohVirtTiers.fetch(vm_host.virt_tier).storage == "none"
    hop_setup_storage_backend
  end

  label def setup_hugepages
    hop_setup_storage_backend if retval&.dig("msg") == "hugepages installed"

    push Prog::SetupHugepages
  end

  label def setup_storage_backend
    hop_download_boot_images if retval&.dig("msg") == "VhostBlockBackend was setup"

    push Prog::Storage::SetupVhostBlockBackend, {
      "version" => vhost_block_backend_version,
      "allocation_weight" => 100,
    }
  end

  label def download_boot_images
    register_deadline("prep_reboot", 4 * 60 * 60)
    default_boot_images.each { |image_name|
      bud Prog::DownloadBootImage, {
        "image_name" => image_name,
      }
    }
    if pvm_host?
      pin = Prog::DownloadPvmGuestKernel.location_pin(vm_host) || fail("location #{vm_host.location.name} has no PVM guest kernel pin; pin one with bin/byoh-location set")
      bud Prog::DownloadPvmGuestKernel, {"pin" => pin}
    end

    hop_wait_download_boot_images
  end

  label def wait_download_boot_images
    reap do
      hop_pvm_guest_kernel_refused if pvm_host? && !pvm_guest_kernel_ready?
      hop_patch
    end
  end

  # A pvm host whose guest kernel download was refused (or superseded by
  # a new pin) waits here, short of accepting, with the ByohPvmGuestKernel
  # page open, until a new pin (bin/byoh-location set starts its
  # download) gives it a ready kernel. A download that only fails is
  # never refused: it keeps the host at wait_download_boot_images until
  # it succeeds.
  label def pvm_guest_kernel_refused
    hop_patch if pvm_guest_kernel_ready?

    nap 60
  end

  def pvm_host? = vm_host.virt_tier == "pvm"

  # The byoh_pvm_host row of a pvm host, or nil.
  def pvm_row = ByohPvmHost[vm_host.id]

  # Whether the control plane installs this pvm host's PVM kernel
  # (rhizome's install-pvm-host-kernel). A host that ran a PVM kernel
  # already at registration (committed, install false) gets none of the
  # install's steps.
  def pvm_managed? = pvm_host? && !!pvm_row&.install

  # Whether the host holds a guest kernel PVM VMs can boot.
  def pvm_guest_kernel_ready? = !ByohPvmGuestKernel.where(vm_host_id: vm_host.id, state: "ready").empty?

  label def prep_reboot
    arm_pvm_boot if pvm_managed? && !pvm_uninstall_set?
    register_deadline("wait", 15 * 60)
    boot_id = get_boot_id
    vm_host.update(last_boot_id: boot_id)

    vm_host.active_vms_dataset.update(display_state: "rebooting")

    decr_reboot

    hop_reboot
  end

  label def reboot
    when_hardware_reset_set? do
      hop_prep_hardware_reset
    end

    nap 30 unless sshable.available?

    last_boot_id = vm_host.last_boot_id
    new_boot_id = sshable.cmd("sudo host/bin/reboot-host :last_boot_id", last_boot_id:).strip

    # If we didn't get a valid new boot id, nap. This can happen if reboot-host
    # issues a reboot and returns without closing the ssh connection.
    nap 30 if new_boot_id.length == 0

    vm_host.update(last_boot_id: new_boot_id)
    hop_verify_spdk unless vm_host.spdk_installations_dataset.empty?
    hop_verify_pvm_boot if pvm_host?
    hop_verify_tier_capacity if ByohVirtTiers.lower?(vm_host.virt_tier)
    hop_verify_hugepages
  end

  label def prep_hardware_reset
    register_deadline("wait", 20 * 60)
    vm_host.active_vms_dataset.update(display_state: "rebooting")
    decr_hardware_reset
    hop_hardware_reset
  end

  # Cuts power to a Server and starts it again. This forcefully stops it
  # without giving the Server operating system time to gracefully stop. This
  # may lead to data loss, it’s equivalent to pulling the power cord and
  # plugging it in again. Reset should only be used when reboot does not work.
  label def hardware_reset
    unless vm_host.allocation_state == "draining" || vm_host.vms_dataset.empty?
      fail "Host has VMs and is not in draining state"
    end

    vm_host.hardware_reset

    # Attempt to hop to reboot immediately after sending the hardware reset
    # signal.
    # The reboot may:
    # 1. Fail, if the host is unreachable, which is a typical reason for a
    #    hardware reset.
    # 2. Succeed, if the host is reachable; however, the hardware reset may
    #    interrupt the reboot.
    # Regardless, the hardware reset will proceed, and upon completion, the
    # host will receive a new boot id, allowing the sequence to continue
    # without an additional reboot.
    hop_reboot
  end

  label def verify_spdk
    vm_host.spdk_installations.each { |installation|
      version = installation.version
      sshable.cmd("sudo host/bin/setup-spdk verify :version", version:)
    }

    hop_verify_hugepages
  end

  label def verify_hugepages
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    fail "Couldn't set hugepage size to 1G" unless host_meminfo.match?(/^Hugepagesize:\s+1048576 kB$/)

    total_hugepages_match = host_meminfo.match(/^HugePages_Total:\s+(\d+)$/)
    fail "Couldn't extract total hugepage count" unless total_hugepages_match

    free_hugepages_match = host_meminfo.match(/^HugePages_Free:\s+(\d+)$/)
    fail "Couldn't extract free hugepage count" unless free_hugepages_match

    available_memory_match = host_meminfo.match(/^MemAvailable:\s+(\d+) kB$/)
    fail "Couldn't extract available memory" unless available_memory_match
    fail "Insufficient memory left for the host OS" if Integer(available_memory_match.captures.first) < 2 * 1024 * 1024

    total_hugepages = Integer(total_hugepages_match.captures.first)
    free_hugepages = Integer(free_hugepages_match.captures.first)

    spdk_hugepages = vm_host.spdk_installations.sum(&:hugepages)
    fail "Used hugepages exceed SPDK hugepages" unless total_hugepages - free_hugepages <= spdk_hugepages

    usable_hugepages = total_hugepages - spdk_hugepages
    min_slice_hugepages = vm_host.min_slice_hugepages
    if vm_host.accepts_slices && usable_hugepages < min_slice_hugepages
      fail "Only #{usable_hugepages} usable 1G hugepages; a host that runs dedicated slices needs at least #{min_slice_hugepages}"
    end

    vm_host.lock! # serialize the recompute against concurrent destroys decrementing used_hugepages_1g

    total_vm_mem_gib = if vm_host.accepts_slices
      vm_host.slices_dataset.sum(:total_memory_gib) || 0
    else
      vm_host.active_vms_dataset.sum(:memory_gib) || 0
    end
    fail "Not enough hugepages for VMs" unless total_hugepages - spdk_hugepages >= total_vm_mem_gib

    vm_host.update(
      total_hugepages_1g: total_hugepages,
      used_hugepages_1g: spdk_hugepages + total_vm_mem_gib,
    )

    hop_start_slices
  end

  # verify_hugepages for lower-tier hosts, which have no hugepages: the
  # guest memory budget (ByohVirtTiers.memory_budget_gib) goes into the
  # hugepage columns, so the allocator books VM memory against it
  # unchanged. On such a host the columns mean "guest RAM budget in GiB"
  # (docs/byoh/EMULATED_HOSTS.md section 6.4).
  label def verify_tier_capacity
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    mem_total = host_meminfo[/^MemTotal:\s+(\d+) kB$/, 1]
    available = host_meminfo[/^MemAvailable:\s+(\d+) kB$/, 1]
    hugepages = host_meminfo[/^HugePages_Total:\s+(\d+)$/, 1]
    hugepage_kib = host_meminfo[/^Hugepagesize:\s+(\d+) kB$/, 1]
    fail "Couldn't parse /proc/meminfo" unless mem_total && available && hugepages && hugepage_kib
    fail "Insufficient memory left for the host OS" if Integer(available) < 2 * 1024 * 1024
    # One VM of the tier's smallest size must fit beside the core kept
    # for the host (wait_prep), in the allocator's terms
    # (scheduling/allocator.rb), or the host would accept and never place.
    smallest = ByohVirtTiers.smallest_size(vm_host.virt_tier)
    cores_needed = [1, smallest.vcpus * vm_host.total_cores / vm_host.total_cpus].max
    if vm_host.total_cores - 1 < cores_needed
      fail "#{vm_host.virt_tier} hosts need #{cores_needed + 1} physical cores, one for the host and #{cores_needed} for one #{smallest.name} VM; this host has #{vm_host.total_cores} cores and #{vm_host.total_cpus} threads"
    end

    hugepages_mib = Integer(hugepages) * Integer(hugepage_kib) / 1024
    Clog.emit("lower-tier host keeps hugepages", {tier_capacity: {vm_host_id: vm_host.id, hugepages_mib:}}) if hugepages_mib > 0
    budget = ByohVirtTiers.memory_budget_gib(vm_host.virt_tier, mem_total_mib: Integer(mem_total) / 1024, hugepages_mib:, total_cpus: vm_host.total_cpus)

    vm_host.lock!
    used = vm_host.active_vms_dataset.sum(:memory_gib) || 0
    fail "Not enough memory budget for VMs (#{budget} GiB for #{used} GiB of VMs)" if used > budget
    fail "A #{budget} GiB memory budget cannot hold a #{smallest.name} VM (#{smallest.memory_gib} GiB); give the host more memory" if budget < smallest.memory_gib

    vm_host.update(total_hugepages_1g: budget, used_hugepages_1g: used)
    hop_start_slices
  end

  label def start_slices
    vm_host.slices.each { |slice|
      slice.incr_start_after_host_reboot
    }

    hop_start_vms
  end

  label def start_vms
    vm_host.vms.each { |vm|
      vm.incr_start_after_host_reboot
    }

    when_graceful_reboot_set? do
      fail "BUG: VmHost not in draining state" unless vm_host.allocation_state == "draining"

      unless vm_host.patch_set?
        vm_host.update(allocation_state: "accepting")
        decr_graceful_reboot
      end
    end

    if vm_host.allocation_state == "unprepared"
      vm_host.update(allocation_state: "accepting")
      delete_from_stack("install_os", "default_boot_images", "vhost_block_backend_version")
    end

    hop_configure_metrics
  end

  label def prep_graceful_reboot
    case vm_host.allocation_state
    when "accepting"
      vm_host.update(allocation_state: "draining")
    when "draining"
      # nothing
    else
      fail "BUG: VmHost not in accepting or draining state"
    end

    if vm_host.vms_dataset.empty?
      hop_prep_reboot
    end

    nap 30
  end

  label def configure_metrics
    metrics_dir = vm_host.metrics_config[:metrics_dir]
    sshable.cmd("mkdir -p :metrics_dir", metrics_dir:)
    sshable.write_file("#{metrics_dir}/config.json", vm_host.metrics_config.to_json, user: :current)

    metrics_service = <<SERVICE
[Unit]
Description=VmHost Metrics Collection
After=network-online.target

[Service]
Type=oneshot
User=rhizome
ExecStart=/home/rhizome/common/bin/metrics-collector #{metrics_dir}
StandardOutput=journal
StandardError=journal
SERVICE
    sshable.write_file("/etc/systemd/system/vmhost-metrics.service", metrics_service)

    metrics_interval = vm_host.metrics_config[:interval] || "15s"

    metrics_timer = <<TIMER
[Unit]
Description=Run VmHost Metrics Collection Periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=#{metrics_interval}
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
    sshable.write_file("/etc/systemd/system/vmhost-metrics.timer", metrics_timer)

    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable --now vmhost-metrics.timer")

    hop_wait
  end

  label def patch
    sshable = vm_host.sshable

    case sshable.d_check("apply_patches")
    when "Succeeded"
      sshable.d_clean("apply_patches")
      if pvm_host?
        record_pvm_patch_kernels("after")
        hop_install_pvm_host_kernel if pvm_row&.state == "install_pending"
      end
      hop_prep_reboot
    when "Failed", "NotStarted"
      record_pvm_patch_kernels("before") if pvm_host?
      sshable.d_run("apply_patches", "sudo", "bash", "-c", "apt update && apt full-upgrade -y")
    end

    nap 60
  end

  # The PVM host kernel of a pvm host whose control plane installs it
  # (docs/byoh/NO_KVM.md section 6.7, rhizome's install-pvm-host-kernel).
  # GRUB's default stays the stock kernel for good: the install, and
  # prep_reboot before every reboot, arm one boot of the PVM kernel, and on
  # it ubicloud-pvm-boot.service arms the next one once kvm_pvm gave a
  # usable /dev/kvm. A boot that fails or hangs returns to the stock
  # kernel on the next power cycle. verify_pvm_boot checks every boot,
  # and takes the PVM kernel out of the boot path (disarm) before it
  # pages on any refusal; the host then waits for bin/byoh-virt pvm retry
  # or pvm uninstall (the pvm_retry and pvm_uninstall semaphores).
  PVM_KERNEL_TOOL = "host/bin/install-pvm-host-kernel"
  PVM_INSTALL_UNIT = "install_pvm_host_kernel"
  PVM_UNINSTALL_UNIT = "uninstall_pvm_host_kernel"

  # The states of the host's state.json in which nothing of an install
  # is on the host: none, a refused install, or an uninstall.
  PVM_HOST_UNCHANGED = [nil, "refused", "uninstalled"].freeze

  # The patch run of an install host runs first (wait_download_boot_images
  # hops to patch), so the install pins the stock kernel the host runs
  # after it. It runs as a daemon: fetching and installing the package
  # takes minutes, far over a strand run's limit.
  label def install_pvm_host_kernel
    register_deadline("prep_reboot", 45 * 60)
    row = pvm_row
    case sshable.d_check(PVM_INSTALL_UNIT)
    when "Succeeded"
      status = pvm_kernel("status")
      sshable.d_clean(PVM_INSTALL_UNIT)
      state = status["state"]
      row.update(state: "armed", host_kver: state["kver"], stock_entry: state["stock_entry"], stock_kver: state["stock_kver"], last_error: nil, updated_at: Time.now)
      record_pvm_status(status)
      resolve_pvm_page("ByohPvmInstall")
      hop_prep_reboot
    when "Failed"
      status = pvm_kernel("status")
      logs = sshable.d_logs(PVM_INSTALL_UNIT, lines: 20).strip
      sshable.d_clean(PVM_INSTALL_UNIT)
      record_pvm_status(status)
      pvm_install_failed!(status, logs)
    when "NotStarted"
      pin = ByohPvmPolicy.pins(ByohVirtTiers.policy(vm_host.location))&.dig("host_deb")
      unless pin && pin["sha256"] == row.host_deb_sha256
        error = "location #{vm_host.location.name} pins #{pin ? "host-deb sha256 #{pin["sha256"]}" : "no PVM host kernel"}, but the operator acknowledged sha256 #{row.host_deb_sha256} for this host"
        row.update(state: "failed", last_error: error, updated_at: Time.now)
        pvm_page("ByohPvmInstall", "did not install the PVM host kernel: #{error}", error:,
          fix: "Nothing was changed on the host. Check the build the location pins now, then bin/byoh-virt pvm retry --host #{vm_host.ubid} --accept-host-deb #{pin ? pin["sha256"] : "SHA256"}; or pin the acknowledged build again with bin/byoh-location set.")
        hop_pvm_install_failed
      end
      row.update(state: "installing", updated_at: Time.now)
      sshable.d_run(PVM_INSTALL_UNIT, "sudo", PVM_KERNEL_TOOL, "install", stdin: JSON.generate("host_deb" => pin))
    end

    nap 30
  end

  # An install that failed or was refused waits here, with its page
  # open, for the operator: bin/byoh-virt pvm retry or pvm uninstall.
  label def pvm_install_failed
    unregister_deadline(deadline_target) if deadline_at
    when_pvm_uninstall_set? { hop_pvm_uninstall }
    when_pvm_retry_set? do
      decr_pvm_retry
      hop_pvm_retry
    end

    nap 6 * 60 * 60
  end

  # Installs again after pvm retry: at once when the failed install
  # changed nothing on the host, after an uninstall otherwise.
  label def pvm_retry
    status = pvm_kernel("status")
    record_pvm_status(status)
    if PVM_HOST_UNCHANGED.include?(status.dig("state", "state"))
      pvm_row.update(state: "install_pending", last_error: nil, updated_at: Time.now)
      hop_install_pvm_host_kernel
    end

    self.pvm_reinstall = true
    hop_pvm_uninstall
  end

  # Checks each boot of a pvm host: after prep_reboot's reboot and after
  # an out-of-band one (check_boot_id). The host must run its PVM kernel
  # with kvm_pvm giving a usable /dev/kvm, and the probe must agree with
  # the tier, before its VMs start. A host rebooted for an uninstall
  # (pvm_uninstall) goes back to it instead.
  label def verify_pvm_boot
    hop_pvm_uninstall if pvm_uninstall_set?

    row = pvm_row
    verdict = ByohVirtLadder.parse(sshable.cmd("sudo host/bin/virt-probe --json"))
    vm_host.update(virt_probe: Sequel.pg_jsonb(Prog::LearnVirt.record(vm_host, verdict)))
    status = pvm_kernel("status") if row&.install
    record_pvm_status(status) if status
    # SSH comes up before multi-user.target, so the boot unit may not
    # have run yet on a PVM kernel that boots fine.
    if status && pvm_boot_unit_pending?(status) && (pvm_boot_waits || 0) < PVM_BOOT_WAITS
      self.pvm_boot_waits = (pvm_boot_waits || 0) + 1
      nap 10
    end
    delete_from_stack("pvm_boot_waits")

    problems = pvm_boot_problems(verdict, status, row)
    if problems.empty?
      row&.update(state: "committed", host_kver: status ? status["kernel"] : row.host_kver, last_error: nil, updated_at: Time.now)
      resolve_pvm_page("ByohPvmBoot")
      Page.from_tag_parts("ByohVirtTier", vm_host.ubid)&.incr_resolve
      undrain_pvm_host
      hop_verify_tier_capacity
    end

    record_pvm_status(pvm_kernel("disarm").merge("kernel" => status["kernel"])) if status
    row&.update(last_error: problems.join("; "), updated_at: Time.now)
    drain_pvm_host
    stock = status && !status["running_pvm"] && !status["pti_off"]
    pvm_page("ByohPvmBoot", stock ? "booted its stock kernel #{status["kernel"]}, not the PVM kernel #{row.host_kver}" : "cannot run pvm VMs after its boot: #{problems.join("; ")}",
      problems:, kernel: status&.dig("kernel"), fix: pvm_boot_fix(row, stock))
    hop_pvm_boot_failed
  end

  # A pvm host whose PVM kernel boot failed waits here, with its VMs
  # stopped and its page open, for the operator: pvm retry arms one more
  # PVM boot and reboots the host; pvm uninstall abandons PVM.
  label def pvm_boot_failed
    unregister_deadline(deadline_target) if deadline_at
    when_pvm_uninstall_set? { hop_pvm_uninstall }
    when_pvm_retry_set? do
      decr_pvm_retry
      hop_prep_reboot
    end

    nap 6 * 60 * 60
  end

  # Takes the PVM kernel off the host (bin/byoh-virt pvm uninstall, which
  # refuses while the host has VMs, or pvm retry after a failed install
  # that changed the host). uninstall runs only on the stock kernel, so a
  # host on its PVM kernel is disarmed and rebooted first; the
  # pvm_uninstall semaphore stays set across that reboot.
  label def pvm_uninstall
    register_deadline("pvm_uninstalled", 45 * 60) unless pvm_reinstall
    vm_host.update(allocation_state: "draining") if vm_host.allocation_state == "accepting"
    unless vm_host.vms_dataset.empty?
      Clog.emit("pvm uninstall waits for the host's VMs to be deleted", {pvm_uninstall_waits: {vm_host_ubid: vm_host.ubid, vms: vm_host.vms_dataset.count}})
      nap 60
    end

    case sshable.d_check(PVM_UNINSTALL_UNIT)
    when "Succeeded"
      sshable.d_clean(PVM_UNINSTALL_UNIT)
      decr_pvm_uninstall
      record_pvm_status(pvm_kernel("status"))
      if pvm_reinstall
        delete_from_stack("pvm_reinstall")
        pvm_row.update(state: "install_pending", last_error: nil, updated_at: Time.now)
        hop_install_pvm_host_kernel
      end
      pvm_row.update(state: "uninstalled", last_error: nil, updated_at: Time.now)
      %w[ByohPvmInstall ByohPvmBoot ByohPvmHostKernel].each { resolve_pvm_page(it) }
      Prog::PageNexus.assemble("#{vm_host.ubid} had its PVM host kernel uninstalled and cannot run VMs", ["ByohPvmUninstalled", vm_host.ubid], vm_host.ubid,
        resource_id: vm_host.id, severity: "info",
        extra_data: {fix: "The host runs its stock kernel again. Destroy the host and register it again as kvm, container or emulated (bin/byoh-virt probe says which it can run)."})
      hop_pvm_uninstalled
    when "Failed"
      logs = sshable.d_logs(PVM_UNINSTALL_UNIT, lines: 20).strip
      sshable.d_clean(PVM_UNINSTALL_UNIT)
      decr_pvm_uninstall
      delete_from_stack("pvm_reinstall")
      status = pvm_kernel("status")
      record_pvm_status(status)
      error = status.dig("state", "last_result", "error") || last_json(logs)&.dig("error") || "see the log lines"
      pvm_row.update(state: "failed", last_error: "uninstall: #{error}", updated_at: Time.now)
      pvm_page("ByohPvmInstall", "could not uninstall its PVM host kernel: #{error}", error:, last_log_lines: logs,
        fix: "Fix the cause on the host (install-pvm-host-kernel status shows what is left), then bin/byoh-virt pvm uninstall --host #{vm_host.ubid} again.")
      hop_pvm_install_failed
    when "NotStarted"
      status = pvm_kernel("status")
      if status["running_pvm"]
        record_pvm_status(pvm_kernel("disarm").merge("kernel" => status["kernel"]))
        hop_prep_reboot
      end
      pvm_uninstall_refused!(status) if status["pti_off"]
      sshable.d_run(PVM_UNINSTALL_UNIT, "sudo", PVM_KERNEL_TOOL, "uninstall", stdin: "{}")
    end

    nap 30
  end

  # The stock kernel has pti=off on its own command line, which every
  # boot keeps, so another reboot cannot help and rhizome's uninstall
  # refuses: page the fix and wait for the operator, disarmed, at
  # pvm_install_failed.
  def pvm_uninstall_refused!(status)
    record_pvm_status(pvm_kernel("disarm").merge("kernel" => status["kernel"]))
    decr_pvm_uninstall
    delete_from_stack("pvm_reinstall")
    error = "the stock kernel #{status["kernel"]} has pti=off on its command line"
    pvm_row.update(state: "failed", last_error: "uninstall: #{error}", updated_at: Time.now)
    pvm_page("ByohPvmInstall", "could not uninstall its PVM host kernel: #{error}", error:,
      fix: "Nothing was uninstalled. Remove pti=off from GRUB_CMDLINE_LINUX* (/etc/default/grub and /etc/default/grub.d), run update-grub and reboot the host, " \
        "then bin/byoh-virt pvm uninstall --host #{vm_host.ubid} again.")
    hop_pvm_install_failed
  end

  # A host whose PVM kernel was uninstalled runs no VMs; its page says to
  # destroy it and register it again on another tier.
  label def pvm_uninstalled
    nap 6 * 60 * 60
  end

  # Runs one install-pvm-host-kernel subcommand: its JSON result, also
  # for a refusal (exit 2) or a failure (exit 3).
  def pvm_kernel(command, params = {})
    sshable.cmd_json("sudo host/bin/install-pvm-host-kernel :command", command:, stdin: JSON.generate(params))
  rescue Sshable::SshError => e
    raise unless [2, 3].include?(e.exit_code)

    JSON.parse(e.stdout)
  end

  # What the host's last install-pvm-host-kernel status (or arm, disarm)
  # said of its boot, for bin/byoh-virt show.
  def record_pvm_status(status)
    self.pvm_status = status.slice("kernel", "running_pvm", "pti_off", "grubenv", "dev_kvm", "boot_unit").merge("at" => Time.now.utc.iso8601)
  end

  # The installed kernel packages before and after a pvm host's patch
  # run: an apt full-upgrade may add a stock kernel, which the install
  # does not pin (it pins the running one) and a later boot may pick.
  def record_pvm_patch_kernels(phase)
    lines = sshable.cmd("dpkg-query -W -f :format :pattern", format: '${Package} ${db:Status-Status}\n', pattern: "linux-image-[0-9]*")
    installed = lines.lines.filter_map { |line| line.split[0] if line.split[1] == "installed" }.sort
    kernels = (phase == "after") ? (pvm_patch_kernels || {}) : {}
    self.pvm_patch_kernels = kernels.merge(phase => installed)
  end

  # Read-only, before the walk goes on: why the host cannot take the PVM
  # host kernel, from rhizome's own preflight. A refusal pages with the
  # reasons and checks again every 5 minutes, so a host the operator
  # fixes goes on by itself.
  def check_pvm_preflight
    when_pvm_uninstall_set? { hop_pvm_uninstall }
    result = pvm_kernel("preflight")
    if result["result"] == "ok"
      resolve_pvm_page("ByohPvmInstall")
      return
    end

    refusals = result["refusals"] || [result["error"]]
    pvm_page("ByohPvmInstall", "cannot take the PVM host kernel: #{refusals.join("; ")}", refusals:, facts: result["facts"],
      fix: "Nothing was changed on the host. Fix what each refusal names; this check runs again every 5 minutes and the bring-up goes on once it passes. " \
        "To give up on PVM: bin/byoh-virt pvm uninstall --host #{vm_host.ubid}, then destroy the host and register it again on another tier.")
    nap 5 * 60
  end

  # Pages an install that failed or was refused, from the host's state:
  # nothing of it on the host (exit 2), or a partial one that rhizome
  # took out of the boot path (exit 3).
  def pvm_install_failed!(status, logs)
    state = status["state"] || {}
    result = last_json(logs) || {}
    unchanged = PVM_HOST_UNCHANGED.include?(state["state"])
    error = (result["refusals"] || [result["error"] || state.dig("last_result", "error") || "see the log lines"]).join("; ")
    pvm_row.update(state: "failed", last_error: error, updated_at: Time.now)
    fix = if unchanged
      "The install was refused before any change on the host. Fix the cause, then bin/byoh-virt pvm retry --host #{vm_host.ubid}; to give up on PVM, bin/byoh-virt pvm uninstall --host #{vm_host.ubid}."
    else
      "The install failed after step #{state["steps"]&.last || "none"}; rhizome already un-armed the host, which boots its stock kernel. " \
        "bin/byoh-virt pvm retry --host #{vm_host.ubid} uninstalls what is there and installs again; bin/byoh-virt pvm uninstall --host #{vm_host.ubid} abandons PVM."
    end
    pvm_page("ByohPvmInstall", "#{unchanged ? "refused" : "failed"} to install the PVM host kernel: #{error}", error:, step: result["step"], last_log_lines: logs, fix:)
    hop_pvm_install_failed
  end

  # The last JSON object in a daemon's log lines: the tool's result.
  def last_json(logs)
    logs.lines.reverse_each do |line|
      text = line[/\{.*\}/]
      next unless text

      begin
        return JSON.parse(text)
      rescue JSON::ParserError
        next
      end
    end
    nil
  end

  # Before every reboot of an install host: arm one boot of the PVM
  # kernel, which also checks that the stock entry still boots. A host
  # that cannot be armed is not rebooted.
  def arm_pvm_boot
    result = pvm_kernel("arm")
    record_pvm_status(result.merge("kernel" => pvm_status&.dig("kernel")))
    return if result["result"] == "ok"

    error = result["error"]
    pvm_row.update(last_error: "arm: #{error}", updated_at: Time.now)
    drain_pvm_host
    pvm_page("ByohPvmBoot", "was not rebooted: its PVM kernel boot could not be armed: #{error}", error:,
      fix: "The host was not rebooted, so VMs it runs keep running, but it takes no new ones and boots the stock kernel next. " \
        "Fix the cause (install-pvm-host-kernel status on the host), then bin/byoh-virt pvm retry --host #{vm_host.ubid}, which arms the boot again and reboots the host.")
    hop_pvm_boot_failed
  end

  # A pvm host that cannot boot its PVM kernel takes no new VMs; the
  # frame remembers that the host accepted VMs before, so the boot that
  # works again (verify_pvm_boot) returns it to accepting.
  def drain_pvm_host
    return unless vm_host.allocation_state == "accepting"

    vm_host.update(allocation_state: "draining")
    self.pvm_drained = true
  end

  def undrain_pvm_host
    return unless pvm_drained

    vm_host.update(allocation_state: "accepting")
    delete_from_stack("pvm_drained")
  end

  # Why a pvm host cannot run pvm VMs after its boot.
  def pvm_boot_problems(verdict, status, row)
    facts = verdict.report["facts"]
    problems = []
    # A pvm probe has the tier's prerequisites (VirtProbe.fallbacks), so
    # it agrees with the tier unless one of PVM's hard refusals applies.
    if verdict.tier != "pvm"
      problems << "the probe says #{verdict.summary}, not pvm"
    elsif (refusal = ByohVirtLadder.pvm_refusal(facts))
      problems << refusal
    end
    problems << "the KVM API is #{facts["kvm_api"].inspect}, not 12" unless facts["kvm_api"] == 12
    return problems unless status

    problems << "the running kernel is #{status["kernel"]}, not the PVM kernel #{row.host_kver}" unless status["kernel"] == row.host_kver
    unit = status["boot_unit"] || {}
    problems << "#{PVM_BOOT_UNIT} is #{unit["ActiveState"]} (#{unit["Result"]}), not active" unless unit["ActiveState"] == "active" && unit["Result"] == "success"
    kvm = status["dev_kvm"] || {}
    problems << "/dev/kvm is #{kvm["chardev"] ? "#{kvm["mode"]} #{kvm["group"]}" : "missing"}, not 660 kvm" unless kvm == {"chardev" => true, "mode" => "660", "group" => "kvm"}
    problems
  end

  PVM_BOOT_UNIT = "ubicloud-pvm-boot.service"

  # How many times verify_pvm_boot waits 10 seconds for the boot unit.
  PVM_BOOT_WAITS = 30

  # Whether the boot unit is still to run on the PVM kernel: it is
  # starting, or not started yet (its condition, pti=off, holds).
  def pvm_boot_unit_pending?(status)
    unit = status["boot_unit"] || {}
    status["running_pvm"] && status["pti_off"] && (unit["ActiveState"] == "activating" || (unit["ActiveState"] == "inactive" && unit["Result"] == "success"))
  end

  def pvm_boot_fix(row, stock)
    if row.nil? || !row.install
      return "The host's PVM kernel was installed outside the control plane. Make kvm_pvm load at boot with a usable /dev/kvm (0660, group kvm), reboot the host, then bin/byoh-virt pvm retry --host #{vm_host.ubid}."
    end

    head = if stock
      "The host booted the stock kernel #{row.stock_kver}: its PVM kernel boot failed or hung, and GRUB fell back. Keep the serial console log of that boot (from the provider console), then run install-pvm-host-kernel status on the host."
    else
      "The host was taken out of the PVM boot path (disarm), so it boots the stock kernel #{row.stock_kver} next. Run install-pvm-host-kernel status on the host for the boot unit and /dev/kvm."
    end
    "#{head} Its VMs were not started. bin/byoh-virt pvm retry --host #{vm_host.ubid} arms one more PVM boot and reboots the host; bin/byoh-virt pvm uninstall --host #{vm_host.ubid} abandons PVM (delete its VMs first). " \
      "A host that does not come back: power-cycle it from the provider console; it boots the stock kernel."
  end

  def pvm_page(type, summary, **extra_data)
    Prog::PageNexus.assemble("#{vm_host.ubid} #{summary}", [type, vm_host.ubid], vm_host.ubid, resource_id: vm_host.id, extra_data:)
  end

  def resolve_pvm_page(type) = Page.from_tag_parts(type, vm_host.ubid)&.incr_resolve

  # A new guest kernel pin applies to a VM at its next stop and start
  # (docs/byoh/NO_KVM.md section 6.8): the page lists the VMs that still
  # boot another kernel than the host's current one.
  def check_pvm_guest_kernels
    tag = ["ByohPvmGuestKernelStale", vm_host.ubid]
    current = ByohVirtTiers.pvm_guest_kernel(vm_host)
    vms = current ? Vm.where(vm_host_id: vm_host.id, id: ByohVmGuestKernel.exclude(sha256: current.sha256).select(:vm_id)).order(:id).all.map(&:ubid) : []
    if vms.empty?
      Page.from_tag_parts(*tag)&.incr_resolve
      return
    end

    Prog::PageNexus.assemble("#{vm_host.ubid} has #{vms.size} pvm VMs on an older guest kernel than #{current.sha256}", tag, vm_host.ubid,
      resource_id: vm_host.id, severity: "warning",
      extra_data: {vms:, sha256: current.sha256, fix: "Stop and start each VM (a restart keeps its kernel); it then boots the host's current guest kernel."})
  end

  label def wait
    hardware_reset_and_reboot_checks

    when_checkup_set? do
      hop_unavailable if !available?
      check_boot_id
      decr_checkup
    end

    when_configure_metrics_set? do
      decr_configure_metrics
      hop_configure_metrics
    end

    when_patch_set? do
      unless vm_host.allocation_state == "draining"
        vm_host.update(allocation_state: "draining")
        self.accepting_before_patch = true
      end

      if vm_host.vms_dataset.empty?
        if accepting_before_patch
          # Move back to accepting post-reboot if it was accepting before patch semaphore set
          incr_graceful_reboot
          delete_from_stack("accepting_before_patch")
        end
        decr_patch
        register_deadline("prep_reboot", 10 * 60)
        hop_patch
      end

      nap 60
    end

    if pvm_host?
      when_pvm_uninstall_set? { hop_pvm_uninstall }
      check_pvm_guest_kernels
    end

    # A lower-tier host is probed again once a day, for the pages of
    # Prog::LearnVirt (a pending kernel reboot); KVM hosts are not.
    Prog::LearnVirt.assemble(vm_host.id) if ByohVirtTiers.lower?(vm_host.virt_tier) && Prog::LearnVirt.stale?(vm_host)

    nap 6 * 60 * 60
  end

  label def unavailable
    hardware_reset_and_reboot_checks

    if available?
      decr_checkup
      check_boot_id
      hop_wait
    end

    register_deadline("wait", 90)
    nap 30
  end

  label def destroy
    decr_destroy

    unless vm_host.allocation_state == "draining"
      vm_host.update(allocation_state: "draining")
      nap 5
    end

    unless vm_host.vms.empty?
      Clog.emit("Cannot destroy the vm host with active virtual machines, first clean them up", vm_host)
      nap 15
    end

    # Resolve host-keyed pages so they don't orphan after the host is gone.
    %w[VmHostDnsEgressIpv4 VmHostDnsEgressIpv6].each do |tag|
      Page.from_tag_parts(tag, vm_host.id)&.incr_resolve
    end
    vm_host.destroy
    sshable.destroy

    pop "vm host deleted"
  end

  def get_boot_id
    sshable.cmd("cat /proc/sys/kernel/random/boot_id").strip
  end

  def hardware_reset_and_reboot_checks
    when_graceful_reboot_set? do
      hop_prep_graceful_reboot
    end

    when_reboot_set? do
      hop_prep_reboot
    end

    when_hardware_reset_set? do
      hop_prep_hardware_reset
    end
  end

  # Detect an out-of-band reboot: if the host's live boot_id differs from the one we
  # recorded, it rebooted without us, so page, adopt the new id, and restart its VMs.
  # The host was already up, so we skip the fresh-reboot verify checks and start directly.
  def check_boot_id
    boot_id = get_boot_id
    return if boot_id == vm_host.last_boot_id || vm_host.last_boot_id.nil?

    Prog::PageNexus.assemble("Recorded last_boot_id of #{vm_host.ubid} differs from the actual boot_id; treating as an out-of-band reboot and restarting its VMs", ["LastBootIDDiscrepancy", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id, severity: "info")
    vm_host.update(last_boot_id: boot_id)
    # A pvm host may have come back on its stock kernel (a boot that
    # failed or hung returns there), where its VMs cannot run.
    hop_verify_pvm_boot if pvm_host?
    hop_start_slices
  end

  def available?
    session = sshable.connect
    vm_host.perform_health_checks(session, test_file_suffix: "respirate")
  rescue
    false
  end
end
