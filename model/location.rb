# frozen_string_literal: true

require_relative "../model"

class Location < Sequel::Model
  plugin ResourceMethods
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :destroy, :refresh_provider_ip_ranges
  dataset_module Pagination

  one_to_one :location_credential_aws, key: :id, read_only: true
  one_to_one :location_credential_gcp, key: :id, read_only: true
  many_to_one :project
  one_to_many :postgres_resources, read_only: true
  one_to_many :provider_ip_ranges, read_only: true

  plugin :association_dependencies, location_credential_aws: :destroy, location_credential_gcp: :destroy

  HETZNER_FSN1_ID = "caa7a807-36c5-8420-a75c-f906839dad71"
  HETZNER_HEL1_ID = "1f214853-0bc4-8020-b910-dffb867ef44f"
  GITHUB_RUNNERS_ID = "6b9ef786-b842-8420-8c65-c25e3d4bdf3d"
  LEASEWEB_WDC02_ID = "e0865080-9a3d-8020-a812-f5817c7afe7f"

  HETZNER_FSN1_UBID = "10saktg1sprp3mxefj1m3kppq2"
  HETZNER_HEL1_UBID = "103wgmgmrbrj0q48dzyw6fvt4z"
  GITHUB_RUNNERS_UBID = "10defff1nr8a2hhjw4qhx9ffkt"
  LEASEWEB_WDC02_UBID = "10w235104t7p1n09fb0bwfbz7z"

  dataset_module do
    def for_project(project_id)
      where(Sequel[project_id:] | {project_id: nil})
    end

    def visible_or_for_project(project_id, project_ff_visible_locations)
      where(Sequel.|([project_id:], {project_id: nil, visible: true}, name: project_ff_visible_locations || []))
    end
  end

  def self.postgres_locations(visible_gcp_names = nil)
    where(project_id: nil, name: ["hetzner-fsn1", "leaseweb-wdc02"])
      .or(provider: "aws", project_id: nil)
      .or(provider: "gcp", project_id: nil, name: visible_gcp_names || [])
      .order(:display_name)
      .all
  end

  def visible_or_for_project?(proj_id, project_ff_visible_locations)
    (visible && project_id.nil?) || project_id == proj_id || project_ff_visible_locations&.include?(name)
  end

  def path
    "/private-location/#{ui_name}"
  end

  # Private Locations only support Postgres resources for now
  def has_resources?
    !postgres_resources_dataset.empty?
  end

  def aws?
    provider == "aws"
  end

  def gcp?
    provider == "gcp"
  end

  def metal?
    !aws? && !gcp?
  end

  # A BYOH site: bring-your-own hosts with the network profile in
  # byoh_network (docs/byoh/NETWORKING.md section 5.3).
  def byoh?
    !byoh_network.nil?
  end

  def byoh_profile
    ByohNetworkProfile.new(byoh_network) if byoh?
  end

  # The IPv4 exposures a VM can ask for in each of the given BYOH
  # locations: those its hosts have unreserved pool addresses for, or
  # internet when they have none. Keyed by location id.
  def self.byoh_ip4_exposures(location_ids)
    exposures = DB[:ipv4_address]
      .join(:address, [:cidr])
      .join(:vm_host, id: :routed_to_host_id)
      .where(Sequel[:vm_host][:location_id] => location_ids, Sequel[:ipv4_address][:reserved] => false)
      .distinct
      .select_map([Sequel[:vm_host][:location_id], Sequel[:address][:exposure]])
      .group_by(&:first)
      .transform_values { |rows| rows.map { |_, exposure| VmHost::IP4_EXPOSURE_POOLS.find { it[1].include?(exposure) }[0] }.uniq }
    location_ids.to_h { [it, exposures.fetch(it, ["internet"])] }
  end

  def validate
    super
    return unless byoh?

    errors.add(:byoh_network, "is only allowed on metal locations") unless metal?
    ByohNetworkProfile.new(byoh_network).errors.each { errors.add(:byoh_network, it) }
  end

  def provider_dispatcher_group_name
    case provider
    when "aws", "gcp"
      provider
    else
      "metal"
    end
  end

  # Bare cloud region as expected by AWS ip-ranges.json / GCP cloud.json,
  # regardless of any operator-added prefixes (e.g. "gcp-us-east4" -> "us-east4").
  def metering_region
    name.sub(/^gcp-/, "")
  end
end

# Table: location
# Columns:
#  id           | uuid    | PRIMARY KEY
#  display_name | text    | NOT NULL
#  name         | text    | NOT NULL
#  ui_name      | text    | NOT NULL
#  visible      | boolean | NOT NULL
#  provider     | text    | NOT NULL
#  project_id   | uuid    |
#  dns_suffix   | text    |
#  byoc         | boolean | NOT NULL DEFAULT false
#  byoh_network | jsonb   |
#  byoh_virt    | jsonb   |
# Indexes:
#  location_pkey                         | PRIMARY KEY btree (id)
#  location_project_id_display_name_uidx | UNIQUE btree (project_id, display_name)
#  location_project_id_ui_name_uidx      | UNIQUE btree (project_id, ui_name)
# Check constraints:
#  location_byoh_virt_check | (byoh_virt IS NULL OR COALESCE(jsonb_typeof(byoh_virt -> 'tiers'::text) = 'array'::text, false) AND (byoh_virt -> 'tiers'::text) <@ '["kvm", "container", "pvm", "emulated"]'::jsonb AND COALESCE(jsonb_typeof(byoh_virt -> 'acks'::text) = 'object'::text, false) AND (NOT (byoh_virt -> 'tiers'::text) ? 'container'::text OR (byoh_virt -> 'acks'::text) ? 'container'::text) AND (NOT (byoh_virt -> 'tiers'::text) ? 'pvm'::text OR (byoh_virt -> 'acks'::text) ? 'pvm'::text) AND (NOT (byoh_virt -> 'tiers'::text) ? 'emulated'::text OR (byoh_virt -> 'acks'::text) ? 'emulated'::text) AND (NOT (byoh_virt -> 'tiers'::text) ? 'pvm'::text OR byoh_virt ? 'pvm_kernel'::text) AND (NOT byoh_virt ? 'pvm_kernel'::text OR COALESCE((byoh_virt #>> '{pvm_kernel,host_deb,url}'::text[]) ~~ 'https://_%'::text, false) AND COALESCE((byoh_virt #>> '{pvm_kernel,host_deb,sha256}'::text[]) ~ '^[0-9a-f]{64}$'::text, false) AND COALESCE((byoh_virt #>> '{pvm_kernel,guest_kernel,url}'::text[]) ~~ 'https://_%'::text, false) AND COALESCE((byoh_virt #>> '{pvm_kernel,guest_kernel,sha256}'::text[]) ~ '^[0-9a-f]{64}$'::text, false) AND
#    CASE
#        WHEN (byoh_virt -> 'pvm_kernel'::text) ? 'guest_config'::text THEN COALESCE((byoh_virt #>> '{pvm_kernel,guest_config,url}'::text[]) ~~ 'https://_%'::text, false) AND COALESCE((byoh_virt #>> '{pvm_kernel,guest_config,sha256}'::text[]) ~ '^[0-9a-f]{64}$'::text, false)
#        ELSE COALESCE(jsonb_typeof(byoh_virt #> '{pvm_kernel,guest_unchecked}'::text[]) = 'boolean'::text, false)
#    END))
# Foreign key constraints:
#  location_project_id_fkey | (project_id) REFERENCES project(id)
#  location_provider_fkey   | (provider) REFERENCES provider(name)
# Referenced By:
#  firewall                           | firewall_location_id_fkey                           | (location_id) REFERENCES location(id)
#  gcp_vpc                            | gcp_vpc_location_id_fkey                            | (location_id) REFERENCES location(id)
#  github_installation_private_subnet | github_installation_private_subnet_location_id_fkey | (location_id) REFERENCES location(id)
#  github_runner                      | github_runner_location_id_fkey                      | (location_id) REFERENCES location(id)
#  inference_endpoint                 | inference_endpoint_location_id_fkey                 | (location_id) REFERENCES location(id)
#  inference_router                   | inference_router_location_id_fkey                   | (location_id) REFERENCES location(id)
#  kubernetes_cluster                 | kubernetes_cluster_location_id_fkey                 | (location_id) REFERENCES location(id)
#  kubernetes_etcd_backup             | kubernetes_etcd_backup_location_id_fkey             | (location_id) REFERENCES location(id)
#  location_az                        | location_aws_az_location_id_fkey                    | (location_id) REFERENCES location(id) ON DELETE CASCADE
#  location_credential_aws            | location_credential_aws_id_fkey                     | (id) REFERENCES location(id)
#  location_credential_gcp            | location_credential_gcp_id_fkey                     | (id) REFERENCES location(id)
#  machine_image                      | machine_image_location_id_fkey                      | (location_id) REFERENCES location(id)
#  machine_image_store                | machine_image_store_location_id_fkey                | (location_id) REFERENCES location(id)
#  minio_cluster                      | minio_cluster_location_id_fkey                      | (location_id) REFERENCES location(id)
#  network_volume                     | network_volume_location_id_fkey                     | (location_id) REFERENCES location(id)
#  parseable_resource                 | parseable_resource_location_id_fkey                 | (location_id) REFERENCES location(id)
#  postgres_resource                  | postgres_resource_location_id_fkey                  | (location_id) REFERENCES location(id)
#  postgres_timeline                  | postgres_timeline_location_id_fkey                  | (location_id) REFERENCES location(id)
#  private_subnet                     | private_subnet_location_id_fkey                     | (location_id) REFERENCES location(id)
#  provider_ip_range                  | provider_ip_range_location_id_fkey                  | (location_id) REFERENCES location(id) ON DELETE CASCADE
#  victoria_metrics_resource          | victoria_metrics_resource_location_id_fkey          | (location_id) REFERENCES location(id)
#  vm                                 | vm_location_id_fkey                                 | (location_id) REFERENCES location(id)
#  vm_host                            | vm_host_location_id_fkey                            | (location_id) REFERENCES location(id)
#  vm_pool                            | vm_pool_location_id_fkey                            | (location_id) REFERENCES location(id)
