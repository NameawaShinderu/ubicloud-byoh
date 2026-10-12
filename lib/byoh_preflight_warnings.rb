# frozen_string_literal: true

require "uri"

# Control-plane settings that are wrong for a BYOH deployment but that
# nothing else reports. The operator CLIs print these; none of them stops
# a command.
module ByohPreflightWarnings
  OPEN_CIDRS = %w[0.0.0.0/0 ::/0].freeze

  # The rates a BYOH location needs before customers can use it: VM
  # create, its IPv4 address and machine images all look up one of these
  # and fail without it.
  MINIMUM_RATES = [
    %w[VmVCpu standard],
    %w[VmVCpu burstable],
    %w[VmStorage standard],
    %w[VmStorage burstable],
    %w[IPAddress IPv4],
    %w[MachineImageStorage standard],
  ].freeze

  # The [resource_type, resource_family] pairs of MINIMUM_RATES that have
  # no active rate for the location. Reads the rate files afresh by
  # default, because this process may have loaded BillingRate.rates
  # before the overlay was written.
  def self.missing_rates(location_name, rates = BillingRate.load_rates(BillingRate.rate_globs))
    now = Time.now
    MINIMUM_RATES.reject do |type, family|
      rates.any? {
        it["resource_type"] == type && it["resource_family"] == family && it["location"] == location_name && it["byoc"] == false && it["active_from"] < now
      }
    end
  end

  def self.warnings
    warnings = []

    unless public_base_url?(Config.base_url)
      warnings << "BASE_URL is #{Config.base_url}; set it to the URL customers use to reach this control plane"
    end

    open = Config.control_plane_outbound_cidrs & OPEN_CIDRS
    if open.any?
      warnings << "CONTROL_PLANE_OUTBOUND_CIDRS includes #{open.join(", ")}, so Postgres and Kubernetes firewalls allow SSH from anywhere; set it to the control plane's source addresses"
    end

    locations = Location.exclude(byoh_network: nil).order(:name).all
    return warnings if locations.empty?

    unless BillingRate.extra_dir
      warnings << "BILLING_RATES_EXTRA_DIR is unset, so web, respirate and monitor do not load the billing rates of BYOH locations"
    end

    outbound = Config.control_plane_outbound_cidrs.filter_map { ByohNetworkProfile.parse_cidr(it) }
    rates = BillingRate.load_rates(BillingRate.rate_globs)
    locations.each do |location|
      location.byoh_profile.cp_source_cidrs.each do |cidr|
        unless outbound.any? { ByohNetworkProfile.covers?(it, cidr) }
          warnings << "location #{location.name}: cp_source_cidrs #{cidr} is not in CONTROL_PLANE_OUTBOUND_CIDRS"
        end
      end

      missing = missing_rates(location.name, rates)
      if missing.any?
        warnings << "location #{location.name}: no billing rate for #{missing.map { it.join("/") }.join(", ")}"
      end
    end

    warnings
  end

  def self.public_base_url?(url)
    host = URI(url).hostname
    !host.nil? && !%w[localhost ::1].include?(host) && !host.start_with?("127.")
  rescue URI::InvalidURIError
    false
  end
end
