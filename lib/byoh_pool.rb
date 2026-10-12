# frozen_string_literal: true

require "yaml"

# The address pools of one registered BYOH host (docs/byoh/NETWORKING.md
# section 10): what bin/byoh-pool lists, exports, changes and checks.
#
# A pool lives in two places: its declaration in host_provider.config
# routed_networks, and its address, ipv4_address and assigned_vm_address
# rows. Every change updates both in one transaction that holds the
# vm_host row lock, validates the result with
# ByohPoolDeclaration.validate_set! and writes an operator log row.
class ByohPool
  class Error < StandardError; end

  # Address exposures whose VMs face the internet. A pool with VMs keeps
  # its side of this line: the VMs were placed for that exposure.
  INTERNET_EXPOSURES = VmHost::IP4_EXPOSURE_POOLS.fetch("internet")

  SET_KEYS = %w[delivery exposure].freeze

  DRAIN_POLL_SECONDS = 5

  attr_reader :host

  # sleeper and drain_polls pace the wait for drained VMs to go away.
  def initialize(host, sleeper: Kernel.method(:sleep), drain_polls: 120)
    @host = host
    @sleeper = sleeper
    @drain_polls = drain_polls
  end

  # Reads an external IP map: YAML {pool IP: external IP}, or the JSON of
  # aws ec2 describe-addresses, whose Addresses map PrivateIpAddress to
  # PublicIp. Addresses without a private IP are not associated with one.
  def self.load_external_map(text)
    data = begin
      YAML.safe_load(text)
    rescue Psych::Exception => ex
      raise Error, "external map is not valid YAML or JSON: #{ex.message}"
    end

    if data.is_a?(Hash) && data["Addresses"].is_a?(Array)
      data["Addresses"].select { it.is_a?(Hash) && it["PrivateIpAddress"] && it["PublicIp"] }
        .to_h { [it["PrivateIpAddress"], it["PublicIp"]] }
    elsif data.is_a?(Hash) && data.all? { |ip, external| ip.is_a?(String) && external.is_a?(String) }
      data
    else
      raise Error, "external map must map pool IPs to external IPs, or be the output of aws ec2 describe-addresses"
    end
  end

  # Where an IPv4 address, a pool address or an external IP, leads. Reads
  # only the database; the host commands to inspect the data path are
  # printed for the operator.
  def self.trace(text)
    ip = ByohPoolDeclaration.parse_ipv4(text.delete_suffix("/32")) or raise Error, "#{text} is not an IPv4 address"
    row = DB[:ipv4_address].where(Sequel.|({ip: ip.to_s}, {external_ip: ip.to_s})).first
    unless row
      cidr = DB[:address].where(Sequel.lit("cidr >>= ?::inet", ip.to_s)).get(:cidr) or
        raise Error, "#{ip} is neither a pool address nor an external IP of any host"
      return ["#{ip} is inside #{cidr}, but no VM can take it: it is a host's own address"]
    end

    address = Address.first(cidr: row[:cidr])
    host = address.vm_host
    lines = [
      "pool address  #{row[:ip]}",
      "external IP   #{row[:external_ip] || "none"}",
      "pool          #{address.cidr} (delivery #{address.delivery}, exposure #{address.exposure})",
      "host          #{host.ubid} (#{host.sshable.host}, location #{host.location.name})",
    ]
    avm = AssignedVmAddress.first(ip: row[:ip].to_s)
    if avm
      vm = avm.vm
      lines << "vm            #{vm.ubid} #{vm.name} (#{vm.display_state}), external IP #{avm.external_ip || "none"}"
      lines << "The NAT rules and connections are not read from the host. On the host, run:"
      lines << "  sudo ip netns exec #{vm.inhost_name} nft list table ip nat"
      lines << "  sudo ip netns exec #{vm.inhost_name} conntrack -L"
    else
      lines << "state         #{row[:reserved] ? "reserved" : "free"}"
    end
    lines
  end

  # The host's VM pool addresses with their state, by address.
  def rows
    DB[:ipv4_address]
      .join(:address, [:cidr])
      .left_join(:assigned_vm_address, {ip: Sequel[:ipv4_address][:ip]})
      .where(Sequel[:address][:routed_to_host_id] => host.id)
      .order(Sequel[:ipv4_address][:ip])
      .select(Sequel[:ipv4_address][:ip], Sequel[:ipv4_address][:cidr], :exposure, :reserved, Sequel[:ipv4_address][:external_ip],
        Sequel[:assigned_vm_address][:dst_vm_id].as(:vm_id), Sequel[:assigned_vm_address][:external_ip].as(:vm_external_ip))
      .all
  end

  # The host's registered VM pools; the management address is not one.
  def pool_addresses(vm_host = host)
    vm_host.assigned_subnets_dataset
      .where { {family(cidr) => 4} }
      .exclude(id: AssignedHostAddress.select(:address_id))
      .order(:cidr)
      .all
  end

  # The declared pools, each as [stored config element, parsed entry].
  def declared(vm_host = host)
    Array(vm_host.provider.config.to_h["routed_networks"]).map { [it, ByohPoolDeclaration.parse(it, legacy: true)] }
  end

  # A pools.yaml v2 document built from the registered pools, so it has
  # their shape (one /29, or eight /32s), and the notes on what it changed.
  # set overrides delivery and exposure for every pool. A nat pool takes
  # its external IPs from external_map, then from the database; an address
  # left without one is reserved in a block, and turns a /32 internal.
  def export(set: {}, external_map: {})
    unknown = set.keys - SET_KEYS
    raise Error, "--set takes #{SET_KEYS.join(" and ")}, not #{unknown.join(", ")}" unless unknown.empty?

    stored = declared.map(&:last)
    by_cidr = stored.to_h { [it.cidr.to_s, it] }
    rows_by_cidr = rows.group_by { it[:cidr].to_s }
    notes = []

    networks = pool_addresses.map do |address|
      cidr = address.cidr.to_s
      entry = by_cidr[cidr]
      pool_rows = rows_by_cidr.fetch(cidr, [])
      hash = {"cidr" => cidr, "delivery" => set.fetch("delivery", address.delivery), "exposure" => set.fetch("exposure", address.exposure)}
      reserve = pool_rows.select { it[:reserved] }.map { it[:ip].to_s }
      if entry&.onlink?
        # The segment's network, broadcast and gateway are reserved by the
        # onlink declaration itself. A pool that leaves onlink delivery
        # keeps them in its reserve, so no VM takes the LAN gateway.
        auto_reserved = entry.reserved_ips - entry.reserve
        if hash["delivery"] == "onlink"
          hash.merge!("segment" => entry.segment.to_s, "gateway" => entry.gateway.to_s, "usable" => entry.usable)
          reserve -= auto_reserved
        elsif !auto_reserved.empty?
          notes << "#{cidr}: leaves onlink delivery but keeps #{auto_reserved.join(", ")} reserved"
        end
      end

      if hash["exposure"] == "nat"
        external = pool_rows.reject { it[:reserved] }.to_h { [it[:ip].to_s, external_map[it[:ip].to_s] || it[:external_ip]&.to_s] }
        missing = external.select { |_, external_ip| external_ip.nil? }.keys
        if address.cidr.netmask.prefix_len == 32 && !missing.empty?
          hash["exposure"] = "internal"
          notes << "#{cidr}: no external IP, exported as exposure internal"
        else
          reserve += missing
          missing.each { notes << "#{it}: no external IP, exported as reserved" }
          external.compact!
          hash["external"] = external unless external.empty?
        end
      end
      hash["reserve"] = reserve unless reserve.empty?

      begin
        ByohPoolDeclaration.parse(hash).to_config
      rescue ByohPoolDeclaration::ValidationError => ex
        raise Error, "cannot export #{cidr}: #{ex.message}"
      end
    end
    networks.concat(stored.select(&:ipv6?).map(&:to_config))

    document = {"version" => 2}
    uplink = host.provider.config.to_h["uplink"]
    document["uplink"] = uplink if uplink
    document["ipv6_mode"] = host.ipv6_mode
    document["routed_networks"] = networks
    [document.to_yaml, notes]
  end

  # Declares and registers new IPv4 pools. No VM is touched; the host's
  # firewall sets are rebuilt.
  def add(entries)
    raise Error, "no pools given" if entries.empty?
    raise Error, "add takes IPv4 pools; change the IPv6 network with ipv6 set" if entries.any?(&:ipv6?)

    change("add", {pools: entries.map(&:to_config)}) do |locked, current|
      cidrs = current.map { it.last.cidr.to_s }
      if (existing = entries.find { cidrs.include?(it.cidr.to_s) })
        raise Error, "#{existing.cidr} is already declared; change it with annotate"
      end

      notes = validate(entries, current.map(&:last))
      write_config(locked, current.map(&:first) + entries.map(&:to_config))
      locked.create_addresses
      notes
    end
  end

  # Removes a pool. A pool with VMs is refused unless drain is set: then
  # its free addresses are reserved so no VM takes them, its VMs are
  # destroyed, and the removal waits for them to be gone.
  def remove(text, drain: false)
    cidr = ByohPoolDeclaration.parse_cidr(text) or raise Error, "#{text} is not a CIDR (address/prefix, no host bits)"
    raise Error, "#{cidr} is IPv6; change the IPv6 network with ipv6 set" unless cidr.is_a?(NetAddr::IPv4Net)

    address = host.assigned_subnets_dataset.first(cidr: cidr.to_s)
    unless address || declared.any? { it.last.cidr.to_s == cidr.to_s }
      raise Error, "#{cidr} is not a pool of host #{host.ubid}"
    end
    raise Error, "#{cidr} is the host's management address" if address && !address.assigned_host_addresses_dataset.empty?

    args = {cidr: cidr.to_s}
    if drain && address && !(vms = pool_vms([address.id])).empty?
      drain!(address, vms)
      args[:drained_vms] = vms.map(&:ubid)
    end

    change("remove", args) do |locked, current|
      if address
        vms = pool_vms([address.id])
        raise Error, "#{cidr} has VMs #{vms.map(&:ubid).join(", ")}; destroy them first, or pass --drain to destroy them" unless vms.empty?
        address.destroy
      end
      remaining = current.reject { it.last.cidr.to_s == cidr.to_s }
      notes = validate([], remaining.map(&:last))
      write_config(locked, remaining.map(&:first))
      rebuild_firewall(locked)
      notes
    end
  end

  # Maps a nat pool address to another external IP, in both tables, and
  # refreshes what follows from it for the VM that holds the address.
  def remap(ip_text, external_text)
    ip = ByohPoolDeclaration.parse_ipv4(ip_text) or raise Error, "#{ip_text} is not an IPv4 address"

    args = {ip: ip.to_s, external: external_text}
    change("remap", args) do |locked, current|
      row = DB[:ipv4_address].where(ip: ip.to_s, cidr: locked.assigned_subnets_dataset.select(:cidr)).first or
        raise Error, "#{ip} is not a pool address of host #{host.ubid}"
      address = Address.first(cidr: row[:cidr])
      unless address.exposure == "nat"
        raise Error, "#{ip} is in the #{address.exposure} pool #{address.cidr}; only nat pools map external IPs (change the exposure with annotate)"
      end
      cidr = address.cidr.to_s
      replaced, others = current.partition { it.last.cidr.to_s == cidr }
      raise Error, "#{cidr} is not declared in the host's config; declare it with annotate first" if replaced.empty?

      config = replaced.first.last.to_config
      config["external"] = replaced.first.last.external.merge(ip.to_s => external_text)
      entry = parse(config)
      notes = validate([entry], others.map(&:last))

      args[:from] = row[:external_ip]&.to_s
      DB[:ipv4_address].where(ip: ip.to_s).update(external_ip: entry.external.fetch(ip.to_s))
      sync_vm_external_ips([address.id])
      write_config(locked, current.map { (it.last.cidr.to_s == cidr) ? entry.to_config : it.first })
      refresh_vms(pool_vms([address.id]))
      notes
    end
  end

  # Sets delivery, exposure, reserved and external IPs on registered pools,
  # for example from a pools.yaml made by export. Every entry must name a
  # registered pool exactly; an IPv6 entry must match the declared one.
  def annotate(entries, uplink: nil, ipv6_mode: nil)
    raise Error, "no pools given" if entries.empty?
    if ipv6_mode && ipv6_mode != host.ipv6_mode
      raise Error, "the host's IPv6 mode is #{host.ipv6_mode}; change it with ipv6 set"
    end

    v6, v4 = entries.partition(&:ipv6?)
    cidrs = v4.map { it.cidr.to_s }
    args = {pools: entries.map(&:to_config), uplink:}
    change("annotate", args) do |locked, current|
      v6.each do |entry|
        unless current.any? { it.last.to_config == entry.to_config }
          raise Error, "#{entry.cidr}: annotate does not change the IPv6 network; use ipv6 set"
        end
      end

      addresses = pool_addresses(locked).to_h { [it.cidr.to_s, it] }
      v4.each do |entry|
        address = addresses[entry.cidr.to_s] or
          raise Error, "#{entry.cidr} is not a registered pool of host #{host.ubid}; annotate takes the registered pools (see export), add declares new ones"
        vm_ips = AssignedVmAddress.where(address_id: address.id).select_map(:ip).map { it.network.to_s }
        if (ip = (vm_ips & entry.reserved_ips).first)
          raise Error, "#{ip} is held by a VM, so it cannot be reserved"
        end
        if !vm_ips.empty? && INTERNET_EXPOSURES.include?(address.exposure) != INTERNET_EXPOSURES.include?(entry.exposure)
          raise Error, "#{entry.cidr} has VMs, so its exposure cannot change from #{address.exposure} to #{entry.exposure}"
        end
      end

      notes = validate(v4, current.reject { cidrs.include?(it.last.cidr.to_s) }.map(&:last))

      address_ids = addresses.values_at(*cidrs).map(&:id)
      DB[:ipv4_address].where(cidr: cidrs).update(external_ip: nil)
      v4.each do |entry|
        addresses[entry.cidr.to_s].update(delivery: entry.delivery, exposure: entry.exposure)
        DB[:ipv4_address].where(cidr: entry.cidr.to_s).update(reserved: Sequel.expr(ip: entry.reserved_ips))
        entry.external.each { |ip, external_ip| DB[:ipv4_address].where(ip:).update(external_ip:) }
      end
      sync_vm_external_ips(address_ids)

      replacements = v4.to_h { [it.cidr.to_s, it.to_config] }
      list = current.map { |raw, entry| replacements.delete(entry.cidr.to_s) || raw } + replacements.values
      write_config(locked, list, uplink ? {"uplink" => uplink} : {})
      refresh_vms(pool_vms(address_ids))
      notes
    end
  end

  # Changes the host's IPv6 network, which only an empty host may do: VM
  # addresses are drawn from it.
  def ipv6_set(text, mode: nil)
    entry = parse(text)
    raise Error, "#{entry.cidr} is not IPv6; ipv6 set takes the host's IPv6 /64" unless entry.ipv6?

    args = {cidr: entry.cidr.to_s, ndp: entry.ndp, from: host.net6.to_s}
    change("ipv6-set", args) do |locked, current|
      vms = locked.vms_dataset.count
      raise Error, "host #{host.ubid} has #{vms} VMs; ipv6 set changes the IPv6 network of an empty host only" unless vms.zero?

      others = current.reject { it.last.ipv6? }
      notes = validate([entry], others.map(&:last), ipv6_mode: mode)
      args[:ipv6_mode] = ByohPoolDeclaration.ipv6_mode([entry], mode)
      locked.update(net6: entry.cidr.to_s, ipv6_mode: args[:ipv6_mode], ndp_needed: entry.ndp)
      write_config(locked, others.map(&:first) + [entry.to_config])
      if entry.ndp && locked.allocation_state != "unprepared"
        Strand.create(prog: "SetupNdpProxy", label: "start", stack: [{subject_id: locked.id}])
      end
      notes
    end
  end

  # Database-only checks of the host's pools, as [level, message] pairs
  # with level :fail, :warn or :unverified.
  def verify
    results = []
    stored = declared.map(&:last)
    by_cidr = stored.select(&:ipv4?).to_h { [it.cidr.to_s, it] }
    addresses = pool_addresses
    all_rows = rows
    rows_by_cidr = all_rows.group_by { it[:cidr].to_s }

    by_cidr.each_key do |cidr|
      next if cidr == "#{host.sshable.host}/32" || addresses.any? { it.cidr.to_s == cidr }
      results << [:fail, "#{cidr} is declared but not registered; register it with add"]
    end

    addresses.each do |address|
      cidr = address.cidr.to_s
      pool_rows = rows_by_cidr.fetch(cidr, [])
      results.concat(declaration_mismatches(address, by_cidr[cidr], pool_rows))

      if address.exposure == "public" && !ByohPoolDeclaration.global_ipv4?(address.cidr)
        results << [:warn, "#{cidr} is public but not globally routable; set its exposure to internal or nat with annotate"]
      end
      if address.exposure == "nat" && !(missing = pool_rows.reject { it[:reserved] || it[:external_ip] }).empty?
        results << [:fail, "#{cidr} is nat, but #{missing.map { it[:ip].to_s }.join(", ")} have no external IP"]
      end
      pool_rows.each do |row|
        next if !row[:vm_id] || row[:vm_external_ip]&.to_s == row[:external_ip]&.to_s
        results << [:fail, "#{row[:ip]}: the VM's external IP #{row[:vm_external_ip] || "none"} differs from the pool's #{row[:external_ip] || "none"}"]
      end
    end

    if all_rows.none? { !it[:reserved] && !it[:vm_id] && INTERNET_EXPOSURES.include?(it[:exposure]) }
      results << [:warn, "no free public or nat IPv4 address: no VM with IPv4 can be placed on this host"]
    end

    v6 = stored.find(&:ipv6?)
    if v6 && v6.cidr.to_s != host.net6.to_s
      results << [:fail, "net6 #{host.net6} differs from the declared IPv6 network #{v6.cidr}"]
    end
    if host.ipv6_mode == "gua" && ByohNetworkProfile.covers?(ByohNetworkProfile::ULA, host.net6)
      results << [:fail, "ipv6_mode is gua, but net6 #{host.net6} is a ULA"]
    end

    host.vms_dataset.order(:name).all.each do |vm|
      expected = vm.cp_reach_ip4&.to_s || vm.ip6_string
      if vm.sshable && vm.sshable.host != expected
        results << [:warn, "#{vm.ubid}: the control plane reaches it at #{vm.sshable.host}, expected #{expected}; remap or annotate refreshes it"]
      end
      if VmHost::APIPA_EXCLUDED.any? { ByohNetworkProfile.covers?(it, vm.local_vetho_ip) }
        results << [:warn, "#{vm.ubid}: its veth address #{vm.local_vetho_ip} is in a link-local range cloud services use; recreate the VM"]
      end
    end

    results << if host.byoh?
      [:unverified, "/etc/nftables.d/1-byoh-egress.conf is not checked from the database; on the host, run: sudo nft list table inet byoh_egress"]
    else
      [:warn, "location #{host.location.name} is not a BYOH location, so the network contract does not apply to this host yet"]
    end
  end

  private

  # Runs the block in a transaction holding the vm_host row lock, with the
  # locked host and its declared pools, and logs the change. Returns the
  # block's notes.
  def change(command, args)
    notes = DB.transaction do
      locked = VmHost.dataset.for_update.with_pk(host.id)
      result = yield(locked, declared(locked))
      ByohOperatorLog.record(command: "byoh-pool #{command}", target_id: host.id, args:, result: "ok")
      result
    end
    host.refresh
    notes
  end

  def parse(input)
    ByohPoolDeclaration.parse(input)
  rescue ByohPoolDeclaration::ValidationError => ex
    raise Error, ex.message
  end

  def validate(entries, others, ipv6_mode: nil)
    ByohPoolDeclaration.validate_set!(entries, main_ip: host.sshable.host, location: host.location, host:, stored: others, ipv6_mode:)
  rescue ByohPoolDeclaration::ValidationError => ex
    raise Error, ex.message
  end

  def write_config(locked, routed_networks, extra = {})
    provider = locked.provider
    provider.update(config: Sequel.pg_jsonb(provider.config.to_h.merge("routed_networks" => routed_networks, **extra)))
  end

  def rebuild_firewall(locked)
    Strand.create(prog: "SetupNftables", label: "start", stack: [{subject_id: locked.id}]) unless locked.allocation_state == "unprepared"
  end

  def pool_vms(address_ids)
    Vm.where(id: AssignedVmAddress.where(address_id: address_ids).select(:dst_vm_id)).order(:id).all
  end

  # Copies the pool's external IPs to the VM addresses that hold them,
  # clearing first so that moving an external IP between two addresses
  # never trips the unique index.
  def sync_vm_external_ips(address_ids)
    vm_addresses = AssignedVmAddress.where(address_id: address_ids)
    vm_addresses.update(external_ip: nil)
    vm_addresses.update(external_ip: DB[:ipv4_address].where(ip: Sequel[:assigned_vm_address][:ip]).select(:external_ip))
  end

  # The VM's control-plane address, IPv4 billing name and DNS records
  # follow its external IP.
  def refresh_vms(vms)
    vms.each do |vm|
      vm.sshable&.update(host: vm.cp_reach_ip4&.to_s || vm.ip6_string)
      vm_address = vm.assigned_vm_address
      resource_name = vm_address.external_ip&.to_s || vm_address.ip.to_s
      vm.active_billing_records.each do |record|
        record.update(resource_name:) if record.billing_rate["resource_type"] == "IPAddress"
      end
      LoadBalancer.where(id: LoadBalancerVm.where(vm_id: vm.id).select(:load_balancer_id)).all.each(&:incr_rewrite_dns_records)
      PostgresResource.where(id: PostgresServer.where(vm_id: vm.id).select(:resource_id)).all.each(&:incr_refresh_dns_record)
    end
  end

  def drain!(address, vms)
    DB.transaction do
      DB[:ipv4_address].where(cidr: address.cidr.to_s).update(reserved: true)
      vms.each(&:incr_destroy)
      ByohOperatorLog.record(command: "byoh-pool remove-drain", target_id: host.id, args: {cidr: address.cidr.to_s, vms: vms.map(&:ubid)}, result: "ok")
    end

    @drain_polls.times do
      return if AssignedVmAddress.where(address_id: address.id).empty?
      @sleeper.call(DRAIN_POLL_SECONDS)
    end
    raise Error, "#{address.cidr}: its VMs are still being destroyed; run remove again once they are gone (its addresses stay reserved meanwhile)"
  end

  def declaration_mismatches(address, entry, pool_rows)
    cidr = address.cidr.to_s
    return [[:warn, "#{cidr} is registered but not declared in the host's config; declare it with annotate"]] unless entry

    results = []
    if [address.delivery, address.exposure] != [entry.delivery, entry.exposure]
      results << [:fail, "#{cidr} is registered as #{address.delivery}/#{address.exposure} but declared as #{entry.delivery}/#{entry.exposure}"]
    end
    reserved = pool_rows.select { it[:reserved] }.map { it[:ip].to_s }
    if reserved.sort != entry.reserved_ips.sort
      results << [:fail, "#{cidr} has reserved addresses #{reserved.join(", ")} but declares #{entry.reserved_ips.join(", ")}"]
    end
    external = pool_rows.select { it[:external_ip] }.to_h { [it[:ip].to_s, it[:external_ip].to_s] }
    if external != entry.external
      results << [:fail, "#{cidr} maps external IPs #{external} but declares #{entry.external}"]
    end
    results
  end
end
