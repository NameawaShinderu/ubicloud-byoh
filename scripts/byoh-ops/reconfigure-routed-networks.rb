#!/usr/bin/env ruby
# frozen_string_literal: true
# ====================================================================
#  reconfigure-routed-networks.rb — update a BYOH host's IP pool
# ====================================================================
#
# Replaces the `routed_networks` list on an already-registered BYOH
# host with a new set of CIDRs. Intended for cases where the operator's
# upstream routing has changed after host registration — e.g. they got
# a new IP block from their provider, or (on AWS) they assigned a new
# set of secondary private IPs to the ENI.
#
# What it does (all in one DB transaction where possible):
#   1. Destroys any VMs currently running on the host via
#      vm.incr_destroy (same path the UI "Delete" button uses). Waits
#      until the VM rows are gone.
#   2. Updates host_provider.config.routed_networks to the new list.
#   3. Deletes the old Address rows (Address#before_destroy cascades to
#      ipv4_address + assigned_host_address + assigned_vm_address).
#   4. Calls vm_host.create_addresses to re-populate from the new
#      config via the existing Hosting::GenericApis.pull_ips flow. The
#      populate_ipv4_addresses hook fires automatically for each new
#      Address, refilling the allocator's pool.
#
# Safe to re-run: if the new CIDRs are already present, the script
# detects that and just re-emits the final state.
#
# Usage (on the control plane, from the ubicloud repo root):
#
#   RACK_ENV=development bundle exec ruby scripts/byoh-ops/reconfigure-routed-networks.rb \
#     --vm-host-ubid vhbx7bnhswet3q8e2pmjvt9yjt \
#     --cidrs 10.99.1.128/32,10.99.1.129/32,10.99.1.130/32 \
#     --v6 fd00:aa55::/64
#
# Flags:
#   --vm-host-ubid UBID   target VmHost (shown in Ubicloud UI as "vh...")
#   --cidrs CIDR[,CIDR]   comma-separated new routed_network CIDRs (IPv4).
#                         Each can be /29, /30, /31, /32 — the operator's
#                         choice based on what they've pre-provisioned.
#   --v6 CIDR             optional IPv6 /64 (default: keep existing net6)
#   --dry-run             print what would change without applying
#   --yes                 skip the interactive "are you sure" prompt when
#                         VMs will be destroyed
#
# This script is deliberately idempotent and surgical — it does NOT
# re-run host bootstrap, it does NOT touch the rhizome agent, it does
# NOT reconfigure the BYOH driver. Only the Address/ipv4_address/
# host_provider.config tables change.

require "optparse"

options = {dry_run: false, yes: false, v6: nil, cidrs: []}
OptionParser.new do |o|
  o.banner = "Usage: reconfigure-routed-networks.rb [options]"
  o.on("--vm-host-ubid UBID") { |v| options[:ubid] = v }
  o.on("--cidrs CIDRS", Array) { |v| options[:cidrs] = v }
  o.on("--v6 CIDR") { |v| options[:v6] = v }
  o.on("--dry-run") { options[:dry_run] = true }
  o.on("--yes") { options[:yes] = true }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

abort("! --vm-host-ubid is required") unless options[:ubid]
abort("! at least one --cidrs entry is required") if options[:cidrs].empty?

require_relative "../../loader"

vmh = UBID.decode(options[:ubid])
abort("! no VmHost with ubid #{options[:ubid]}") if vmh.nil?
abort("! ubid #{options[:ubid]} resolved to #{vmh.class} not VmHost") unless vmh.is_a?(VmHost)

puts "=" * 60
puts "target host: #{vmh.ubid}  (id=#{vmh.id})"
puts "  allocation_state: #{vmh.allocation_state}"
puts "  provider: #{vmh.provider_name}"
puts "  location:  #{vmh.location.name}"
puts

# Show current state
hp = vmh.provider
abort("! host has no HostProvider row (dev/legacy mode?)") unless hp
old_routed_networks = (hp.config || {})["routed_networks"] || []
puts "current routed_networks:"
old_routed_networks.each { |n| puts "  - #{n["cidr"]}" }
puts

puts "new routed_networks (from --cidrs + --v6):"
new_entries = options[:cidrs].map { |c| {"cidr" => c} }
new_entries << {"cidr" => options[:v6]} if options[:v6]
new_entries.each { |n| puts "  - #{n["cidr"]}" }
puts

running_vms = vmh.vms.reject { |v| v.destroy_set? }
if running_vms.any?
  puts "⚠  #{running_vms.length} VM(s) on this host will be DESTROYED:"
  running_vms.each { |v| puts "  - #{v.ubid} #{v.name} (display_state=#{v.display_state})" }
  unless options[:yes] || options[:dry_run]
    print "type 'yes' to proceed: "
    $stdout.flush
    abort("! aborted") unless $stdin.readline.chomp == "yes"
  end
end

if options[:dry_run]
  puts
  puts "[DRY RUN] would apply above changes and re-populate Address rows. Exiting."
  exit 0
end

puts
puts "=" * 60
puts "applying..."

# Step 1: destroy running VMs
running_vms.each do |v|
  print "  destroy VM #{v.ubid}... "
  DB.transaction { v.incr_destroy }
  60.times do
    break if Vm[v.id].nil?
    sleep 2
  end
  puts Vm[v.id] ? "(still present after 120s, continuing anyway)" : "gone"
end

DB.transaction do
  # Step 2: update host_provider.config
  cfg = (hp.config || {}).dup
  cfg["routed_networks"] = new_entries
  hp.update(config: cfg)
  puts "  host_provider.config.routed_networks updated"

  # Step 3: delete old Address rows for the OLD CIDRs (only those the
  # new list doesn't contain). Address#before_destroy cascades to the
  # ipv4_address table via the `DB[:ipv4_address].where(cidr:).delete`
  # hook — no orphaned rows.
  new_cidr_set = new_entries.map { |n| n["cidr"] }.to_set
  vmh.assigned_subnets_dataset.each do |addr|
    cidr_str = addr.cidr.to_s
    next if new_cidr_set.include?(cidr_str)
    # Also clean up AssignedHostAddress explicitly (the Address destroy
    # cascade doesn't touch it)
    DB[:assigned_host_address].where(address_id: addr.id).delete
    addr.destroy
    puts "  deleted old Address #{cidr_str}"
  end

  # Step 4: re-populate by calling create_addresses. It'll call
  # Hosting::Apis.pull_ips(vmh) which routes to
  # Hosting::GenericApis#pull_ips → reads the new config → auto-prepends
  # mgmt /32 if needed → returns the list → create_addresses inserts
  # Address rows → populate_ipv4_addresses hook fires per Address →
  # ipv4_address pool refilled.
  vmh.create_addresses
  puts "  create_addresses re-ran from new config"
end

vmh.reload
puts
puts "=" * 60
puts "done. new state:"
puts "  assigned_subnets: #{vmh.assigned_subnets.map { |a| a.cidr.to_s }.sort.join(", ")}"
puts "  ipv4_address pool: #{DB[:ipv4_address].count} rows"
DB[:ipv4_address].all.each { |r| puts "    #{r[:ip]} (parent #{r[:cidr]})" }
