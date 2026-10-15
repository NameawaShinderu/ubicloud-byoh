# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  subject_is :sshable, :vm_host
  frame_reader :vhost_block_backend_version, :default_boot_images, :install_os
  frame_accessor :accepting_before_patch

  def self.assemble(sshable_hostname, location_id: Location::HETZNER_FSN1_ID, family: "standard", net6: nil, ndp_needed: false, provider_name: nil, server_identifier: nil, provider_config: nil, ssh_private_key: nil, vhost_block_backend_version: Config.vhost_block_backend_version, default_boot_images: [], install_os: false, ipv6_mode: "gua", virt_tier: ByohVirtTiers::KVM)
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
        raise "A #{virt_tier} host must be a generic provider host in a BYOH location" unless provider_name == HostProvider::GENERIC_PROVIDER_NAME && location.byoh?
        raise "#{virt_tier} hosts are not available yet" unless ByohVirtTiers.shipped?(virt_tier)
        raise "Location #{location.name} does not offer #{virt_tier} hosts" unless ByohVirtTiers.allows?(location, virt_tier) && ByohVirtTiers.acked?(location, virt_tier)
        raise "A #{virt_tier} host has family #{virt_tier}, not #{family}" unless family == "standard"
        # Its VMs boot only the tier's images.
        tier_images = ByohVirtTiers.fetch(virt_tier).boot_images
        default_boot_images = tier_images if default_boot_images.empty?
        unless (other = default_boot_images - tier_images).empty?
          raise "A #{virt_tier} host cannot boot #{other.join(", ")}; its images are #{tier_images.join(", ")}"
        end
        host_args[:family] = ByohVirtTiers.family_for(virt_tier)
        host_args[:virt_tier] = virt_tier
      elsif provider_name == HostProvider::GENERIC_PROVIDER_NAME && !ByohVirtTiers.allows?(location, virt_tier)
        raise "Location #{location.name} does not offer kvm hosts"
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
      Sshable.create_with_id(id, **sshable_args)
      vmh = VmHost.create_with_id(id, **host_args)

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

      Strand.create_with_id(id,
        prog: "Vm::HostNexus",
        label: "start",
        stack: [{"vhost_block_backend_version" => vhost_block_backend_version, "default_boot_images" => default_boot_images, "install_os" => install_os}])
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

    push Prog::BootstrapRhizome, {"target_folder" => "host"}
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
        (0..total_cpus - 1).each do |cpu|
          VmHostCpu.create(
            vm_host_id: vm_host.id,
            cpu_number: cpu,
            io: cpu < io_cpu_count,
            numa_node: cpu_numa_nodes[cpu],
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
  # records a probe that agrees. Lower tiers use no 1G hugepages.
  label def verify_virt_tier
    probe = vm_host.virt_probe&.to_h
    fail "#{vm_host.virt_tier} host has no virtualization probe yet; run bin/byoh-virt refresh --host #{vm_host.ubid}" if probe.nil? || probe["error"]

    verdict = ByohVirtLadder.verdict(probe)
    unless ByohVirtTiers.accepts_probe?(vm_host.virt_tier, verdict)
      fail "#{vm_host.virt_tier} host does not have the tier's prerequisites (probe: #{verdict.summary}); fix it, then run bin/byoh-virt refresh --host #{vm_host.ubid}"
    end

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

    hop_wait_download_boot_images
  end

  label def wait_download_boot_images
    reap(:patch)
  end

  label def prep_reboot
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
    fail "#{vm_host.virt_tier} hosts need at least 2 physical cores" if vm_host.total_cores < 2

    hugepages_mib = Integer(hugepages) * Integer(hugepage_kib) / 1024
    Clog.emit("lower-tier host keeps hugepages", {tier_capacity: {vm_host_id: vm_host.id, hugepages_mib:}}) if hugepages_mib > 0
    budget = ByohVirtTiers.memory_budget_gib(vm_host.virt_tier, mem_total_mib: Integer(mem_total) / 1024, hugepages_mib:, total_cpus: vm_host.total_cpus)

    vm_host.lock!
    used = vm_host.active_vms_dataset.sum(:memory_gib) || 0
    fail "Not enough memory budget for VMs (#{budget} GiB for #{used} GiB of VMs)" if used > budget

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
      hop_prep_reboot
    when "Failed", "NotStarted"
      sshable.d_run("apply_patches", "sudo", "bash", "-c", "apt update && apt full-upgrade -y")
    end

    nap 60
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
    hop_start_slices
  end

  def available?
    session = sshable.connect
    vm_host.perform_health_checks(session, test_file_suffix: "respirate")
  rescue
    false
  end
end
