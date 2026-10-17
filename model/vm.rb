# frozen_string_literal: true

require "jwt"
require "shellwords"
require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  many_to_one :project, read_only: true
  one_to_many :nics, read_only: true
  many_to_many :private_subnets, join_table: :nic, read_only: true
  one_to_one :sshable, key: :id, read_only: true
  one_to_one :assigned_vm_address, key: :dst_vm_id
  one_to_many :vm_storage_volumes, order: Sequel.desc(:boot), remover: nil, clearer: nil
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active
  one_to_one :pinning_machine_image_version_metal, class: :MachineImageVersionMetal, key: :pinned_source_vm_id, read_only: true
  one_to_many :pci_devices, read_only: true
  one_to_many :run_commands, order: Sequel.desc(:created_at), read_only: true
  one_to_one :gpu_partition, read_only: true
  one_through_one :load_balancer, read_only: true
  one_to_one :load_balancer_vm, read_only: true
  many_to_many :load_balancer_vm_ports, join_table: :load_balancers_vms, right_key: :id, right_primary_key: :load_balancer_vm_id, read_only: true
  many_to_one :vm_host_slice, read_only: true
  many_to_one :location
  many_to_one :hypervisor, read_only: true
  one_to_one :aws_instance, key: :id, read_only: true
  one_to_one :vm_gcp_resource, key: :id, read_only: true
  one_to_one :init_script, class: :VmInitScript, key: :id, read_only: true
  one_to_one :github_runner, read_only: true

  many_through_many :private_subnet_firewalls,
    [
      [:nic, :vm_id, :private_subnet_id],
      [:firewalls_private_subnets, :private_subnet_id, :firewall_id],
    ],
    class: :Firewall
  many_to_many :vm_firewalls, class: :Firewall, right_key: :firewall_id, remover: nil, clearer: nil,
    before_add: :validate_firewall_cap,
    after_add: :fire_firewall_rules_update_for_vm_firewall

  plugin :association_dependencies, sshable: :destroy, assigned_vm_address: :destroy, vm_storage_volumes: :destroy, load_balancer_vm: :destroy, init_script: :destroy

  dataset_module Pagination
  dataset_module do
    def unattached_to_load_balancer(project)
      exclude(Sequel[:vm][:id] => LoadBalancerVm.where(vm_id: project.vms_dataset.select(:id)).select(:vm_id))
    end
  end

  plugin ResourceMethods, redacted_columns: :public_key
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :destroy, :start_after_host_reboot, :prevent_destroy, :update_firewall_rules,
    :checkup, :update_spdk_dependency, :waiting_for_capacity, :lb_expiry_started, :restart, :start, :stop, :migrate_to_separate_progs, :admin_stop, :stopping, :prepare_to_move, :clean_prep
  include HealthMonitorMethods

  include ObjectTag::Cleanup

  def self.from_runtime_jwt_payload(jwt_payload)
    jwt_payload && first(id: UBID.to_uuid(jwt_payload["sub"]))
  end

  def display_location
    location.display_name
  end

  def display_gpu
    gpu_devices = pci_devices.select { |d| ["0300", "0302"].include?(d.device_class) }
    "#{gpu_devices.count}x #{PciDevice.device_name(gpu_devices.first.device)}" if gpu_devices.any?
  end

  def load_balancer_state
    return nil unless load_balancer
    if load_balancer.stack == "dual"
      %w[ipv4 ipv6].map! { |stack| load_balancer_vm_ports.find { it.stack == stack }&.state }
    else
      [load_balancer_vm_ports.first&.state]
    end
  end

  def path
    "/location/#{display_location}/vm/#{name}"
  end

  def admin_ssh_user
    sshable.unix_user
  end

  def ip4
    ephemeral_net4&.nth(0)
  end

  def byoh_host? = !!vm_host&.byoh?

  # byoh_host? for the customer pages and API, which list many VMs with
  # their location already loaded. A VM is only placed on a host in its
  # own location, so a non-BYOH location answers without querying the
  # host and its provider.
  def byoh_addressing? = location.byoh? && byoh_host?

  # The host kernel a container or PVM VM shares or relies on
  # (docs/byoh/NO_KVM.md), as the host's last probe saw it; nil for
  # every other VM.
  def shared_host_kernel
    vm_host&.virt_probe&.dig("facts", "kernel") if Prog::LearnVirt::KERNEL_TIERS.include?(family)
  end

  # The guest kernel a PVM VM boots (docs/byoh/NO_KVM.md section 6.7):
  # its release, sha256 and whether its config was checked for what PVM
  # VMs need when the host downloaded it. nil for every other VM, and for
  # a PVM VM that has not started yet.
  def pvm_guest_kernel
    return unless family == "pvm" && (kernel = ByohVmGuestKernel[id])

    checked = ByohPvmGuestKernel.where(vm_host_id:, sha256: kernel.sha256).get(:config_checked)
    {release: kernel.release, sha256: kernel.sha256, config_checked: checked == true}
  end

  # The addresses service DNS (load balancers, Postgres) publishes for
  # the VM: its public ones on a BYOH host, and its own elsewhere. An
  # internal address is reachable only from the site, so it gets no
  # public record.
  def dns_ip4_string = byoh_host? ? (public_ip4_string unless internal_ip4?) : ip4_string

  def dns_ip6_string = byoh_host? ? public_ip6&.to_s : ip6_string

  # The address the internet reaches the VM's IPv4 at: the external IP a
  # nat pool address is 1:1 NATed to, otherwise the address itself.
  def public_ip4 = assigned_vm_address&.external_ip || ip4

  def public_ip4_string = public_ip4&.to_s

  # The pool address of a nat VM, which only the site's network reaches.
  # Nil when the VM's address is itself its public one.
  def ip4_internal = (ip4 if assigned_vm_address&.external_ip)

  # Whether the VM's IPv4 faces the internet. Only a BYOH host has
  # internal pools.
  def public_ip4_scope
    return unless ip4
    return "public" unless byoh_host?

    (assigned_vm_address.address.exposure == "internal") ? "internal" : "public"
  end

  def internal_ip4? = public_ip4_scope == "internal"

  # The IPv4 the control plane connects to: the pool address when the
  # control plane sits on the host's network (cp_reach onhost), the public
  # address otherwise, and none for an internal address it cannot reach.
  def cp_reach_ip4
    return ip4 unless byoh_host?
    return ip4 if vm_host.location.byoh_profile.cp_reach == "onhost"

    public_ip4 unless internal_ip4?
  end

  # The IPv6 customers reach the VM at. A BYOH host without a global
  # prefix hands out a ULA, which is reachable only inside the site.
  def public_ip6
    return ip6 unless byoh_host?

    ip6 if vm_host.ipv6_mode == "gua"
  end

  # Whether outbound IPv4 leaves through the BYOH host's shared NAT: for
  # a VM without IPv4, and for one with an internal address when the
  # location sends internal traffic through the host.
  def byoh_egress_nat4?
    return false unless byoh_host?

    profile = vm_host.location.byoh_profile
    return false unless profile.vm_egress_nat4

    ip4.nil? || (public_ip4_scope == "internal" && profile.internal_egress == "host_nat")
  end

  def ip4_string
    ip4&.to_s
  end

  def ip6_string
    ip6&.to_s
  end

  def user_nic
    nics.find { !it.is_management }
  end

  def management_nic
    nics.find { it.is_management }
  end

  def private_ipv4
    if (ipv4 = user_nic&.private_ipv4)
      (ipv4.netmask.prefix_len == 32) ? ipv4.network : ipv4.nth(1)
    end
  end

  def private_ipv4_string
    private_ipv4.to_s
  end

  def private_ipv6
    user_nic&.private_ipv6&.nth(2)
  end

  def private_ipv6_string
    private_ipv6.to_s
  end

  def firewalls(opts = {})
    private_subnet_firewalls(opts) + vm_firewalls(opts)
  end

  def firewall_rules
    firewalls(eager: :firewall_rules).flat_map(&:firewall_rules)
  end

  def runtime_token
    JWT.encode({sub: ubid, iat: Time.now.to_i}, Config.clover_runtime_token_secret, "HS256")
  end

  def most_recent_serial_log
    run_commands_dataset.first(command: "fetch_serial_log")
  end

  def display_state
    label = strand&.label
    return "deleting" if destroying_set? || destroy_set?
    return "stopped by admin" if admin_stop_set? || label == "stopped_by_admin"
    return "restarting" if restart_set? || label == "restart"
    return "starting" if start_set? || label == "start_after_stop"
    return "stopping" if stop_set? || stopping_set?
    return "stopped" if label == "stopped"
    return "unavailable" if label == "unavailable"

    if waiting_for_capacity_set?
      return "no capacity available" if Time.now - created_at > 15 * 60

      return "waiting for capacity"
    end
    super
  end

  def can_restart?
    display_state == "running"
  end

  def can_stop?
    %w[running starting restarting unavailable rebooting].freeze.include?(display_state)
  end

  def can_start?
    %w[unavailable stopped].freeze.include?(display_state)
  end

  # Reverse look-up the vm_size instance that was used to create this VM
  # and use its name as a display name. VMs whose shape is not in the
  # catalog (e.g. created with a custom shape) get a descriptive name
  # instead, so the pages and API listing them keep working.
  def display_size
    # Lower-tier families (ByohVirtTiers) never match an Option::VmSizes
    # entry, so searching their sizes after it changes no other VM.
    match = lambda {
      it.family == family &&
        it.arch == arch &&
        it.vcpus == vcpus &&
        (cpu_percent_limit.nil? || it.cpu_percent_limit == cpu_percent_limit)
    }
    vm_size = Option::VmSizes.find(&match) || Option::TierVmSizes.find(&match)
    vm_size&.name || "#{family}-#{vcpus}c-#{memory_gib}g"
  end

  def display_boot_image
    Option::BootImages.find { |bi| bi.name == boot_image }&.display_name || boot_image
  end

  def display_hypervisor
    hypervisor&.admin_label
  end

  # Various names in linux, like interface names, are obliged to be
  # short, so truncate the ubid. This does introduce the spectre of
  # collisions.  When the time comes, we'll have to ensure it doesn't
  # happen on a single host, pushing into the allocation process.
  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  # The VMs holding any of the given "a.b.c.d/32" addresses, as a pool
  # address or as the external IP a nat pool address is NATed to.
  def self.from_ips(ips)
    eager_graph(:assigned_vm_address, :project)
      .where(Sequel.|({Sequel[:assigned_vm_address][:ip] => ips}, {Sequel[:assigned_vm_address][:external_ip] => ips.map { it.delete_suffix("/32") }}))
      .all
  end

  def storage_size_gib
    vm_storage_volumes.map { it.size_gib }.sum
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:ssh_session].exec!("systemctl is-active :shelljoin_units", shelljoin_units: healthcheck_systemd_units).split("\n").all?("active") ? "up" : "down"
    rescue IOError, Errno::ECONNRESET
      raise
    rescue => e
      Clog.emit("Exception in Vm #{ubid}", Util.exception_to_hash(e))
      "down"
    end
    pulse = aggregate_readings(previous_pulse:, reading:)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !checkup_set?(cached: false)
      incr_checkup
    end

    pulse
  end

  def save_with_ephemeral_net6_error_retrying(vm_host, max_retries: 2)
    save_changes
  rescue Sequel::ValidationFailed
    if errors.keys == [:ephemeral_net6] && max_retries > 0
      max_retries -= 1
      self.ephemeral_net6 = vm_host.ip6_random_vm_network.to_s
      retry
    end
    raise
  end

  def in_maintenance_window?
    return true if maintenance_window_start_at.nil?
    offset = Time.now.utc.hour - maintenance_window_start_at
    (offset % 24) < MAINTENANCE_DURATION_IN_HOURS
  end

  def validate
    super
    validates_includes(0..23, :maintenance_window_start_at, allow_nil: true, message: "must be between 0 and 23")
  end

  MAINTENANCE_DURATION_IN_HOURS = 2
  def self.maintenance_hour_options
    Array.new(24) do
      [it, "#{"%02d" % it}:00 - #{"%02d" % ((it + MAINTENANCE_DURATION_IN_HOURS) % 24)}:00 (UTC)"]
    end
  end

  include Validation::PublicKeyValidation

  private

  def ephemeral_net4
    assigned_vm_address&.ip
  end

  # Fires semaphores when a firewall is attached to this VM directly
  # (firewalls_vms). For GCP, the VPC must re-sync tag keys/values and
  # policy rules to cover the new firewall, and this VM must re-bind its
  # tags. Non-GCP VMs fire only their own semaphore; callers typically
  # also fire it themselves, but firing twice is idempotent.
  #
  # Detach does not flow through here because vm_firewalls is declared
  # with remover: nil and detach paths (VM destroy) bypass Sequel via
  # ON DELETE CASCADE; VPC cleanup is covered by VpcUpdateFirewallRules's
  # orphan sweep.
  def fire_firewall_rules_update_for_vm_firewall(_firewall)
    incr_update_firewall_rules
    return unless location.gcp?
    # A GCP VM always has a nic with a private_subnet by the time any
    # caller can reach this hook (Prog::Vm::Nexus creates the nic before
    # provisioning); gcp_vpc may be nil only if private_subnet's VPC row
    # hasn't been linked yet.
    vpc = user_nic.private_subnet.gcp_vpc
    vpc&.incr_update_firewall_rules
  end
end

# Table: vm
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  ephemeral_net6              | cidr                     |
#  vm_host_id                  | uuid                     |
#  unix_user                   | text                     | NOT NULL
#  public_key                  | text                     | NOT NULL
#  display_state               | vm_display_state         | NOT NULL DEFAULT 'creating'::vm_display_state
#  name                        | text                     | NOT NULL
#  boot_image                  | text                     | NOT NULL
#  local_vetho_ip              | cidr                     |
#  ip4_enabled                 | boolean                  | NOT NULL DEFAULT false
#  family                      | text                     | NOT NULL
#  cores                       | integer                  | NOT NULL
#  pool_id                     | uuid                     |
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  arch                        | arch                     | NOT NULL DEFAULT 'x64'::arch
#  allocated_at                | timestamp with time zone |
#  provisioned_at              | timestamp with time zone |
#  vcpus                       | integer                  | NOT NULL
#  memory_gib                  | integer                  | NOT NULL
#  vm_host_slice_id            | uuid                     |
#  project_id                  | uuid                     | NOT NULL
#  cpu_percent_limit           | integer                  |
#  cpu_burst_percent_limit     | integer                  |
#  location_id                 | uuid                     | NOT NULL
#  hypervisor_id               | uuid                     |
#  maintenance_window_start_at | integer                  |
#  ip4_exposure                | text                     | NOT NULL DEFAULT 'internet'::text
# Indexes:
#  vm_pkey                             | PRIMARY KEY btree (id)
#  vm_ephemeral_net6_key               | UNIQUE btree (ephemeral_net6)
#  vm_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
#  vm_pool_id_index                    | btree (pool_id) WHERE pool_id IS NOT NULL
# Check constraints:
#  valid_maintenance_windows_start_at | (maintenance_window_start_at >= 0 AND maintenance_window_start_at <= 23)
#  vm_ip4_exposure_check              | (ip4_exposure = ANY (ARRAY['internet'::text, 'internal'::text]))
# Foreign key constraints:
#  vm_hypervisor_id_fkey    | (hypervisor_id) REFERENCES hypervisor(id)
#  vm_location_id_fkey      | (location_id) REFERENCES location(id)
#  vm_pool_id_fkey          | (pool_id) REFERENCES vm_pool(id)
#  vm_project_id_fkey       | (project_id) REFERENCES project(id)
#  vm_vm_host_id_fkey       | (vm_host_id) REFERENCES vm_host(id)
#  vm_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
# Referenced By:
#  assigned_vm_address         | assigned_vm_address_dst_vm_id_fkey                   | (dst_vm_id) REFERENCES vm(id)
#  byoh_vm_guest_kernel        | byoh_vm_guest_kernel_vm_id_fkey                      | (vm_id) REFERENCES vm(id) ON DELETE CASCADE
#  dns_servers_vms             | dns_servers_vms_vm_id_fkey                           | (vm_id) REFERENCES vm(id)
#  firewalls_vms               | firewalls_vms_vm_id_fkey                             | (vm_id) REFERENCES vm(id) ON DELETE CASCADE
#  gpu_partition               | gpu_partition_vm_id_fkey                             | (vm_id) REFERENCES vm(id)
#  inference_endpoint_replica  | inference_endpoint_replica_vm_id_fkey                | (vm_id) REFERENCES vm(id)
#  inference_router_replica    | inference_router_replica_vm_id_fkey                  | (vm_id) REFERENCES vm(id)
#  kubernetes_node             | kubernetes_node_vm_id_fkey                           | (vm_id) REFERENCES vm(id)
#  load_balancers_vms          | load_balancers_vms_vm_id_fkey                        | (vm_id) REFERENCES vm(id)
#  machine_image_version_metal | machine_image_version_metal_pinned_source_vm_id_fkey | (pinned_source_vm_id) REFERENCES vm(id)
#  minio_server                | minio_server_vm_id_fkey                              | (vm_id) REFERENCES vm(id)
#  nic                         | nic_vm_id_fkey                                       | (vm_id) REFERENCES vm(id)
#  parseable_server            | parseable_server_vm_id_fkey                          | (vm_id) REFERENCES vm(id)
#  pci_device                  | pci_device_vm_id_fkey                                | (vm_id) REFERENCES vm(id)
#  postgres_server             | postgres_server_vm_id_fkey                           | (vm_id) REFERENCES vm(id)
#  run_command                 | run_command_vm_id_fkey                               | (vm_id) REFERENCES vm(id) ON DELETE CASCADE
#  victoria_metrics_server     | victoria_metrics_server_vm_id_fkey                   | (vm_id) REFERENCES vm(id)
#  vm_gcp_resource             | vm_gcp_resource_id_fkey                              | (id) REFERENCES vm(id) ON DELETE CASCADE
#  vm_init_script              | vm_init_script_id_fkey                               | (id) REFERENCES vm(id)
#  vm_storage_volume           | vm_storage_volume_vm_id_fkey                         | (vm_id) REFERENCES vm(id)
