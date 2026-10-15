# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "shellwords"

# `byoh-host add | preflight | watch`: adds a BYOH host with one command
# from the operator's own SSH login to it (ROADMAP §6.3, form A).
#
# add runs in two phases, which `--phase all` (the default) runs in one
# process and ubicloud-admin runs as two, so that the operator's key is
# gone before the long watch:
#
# prepare (needs --ssh and the operator's key)
#   1. Checks on the control plane only: the input, the location, the
#      services, --accept-check, and whether the host is registered
#      already (then it resumes, below). Nothing on the host is touched.
#   2. Logs in as the operator, checks passwordless sudo, runs
#      ubicloud-host preflight as root with the script on stdin, and
#      cross-checks the host keys ssh met with the host's own
#      /etc/ssh/ssh_host_*_key.pub.
#   3. Shows what it will change and the host-key fingerprints, and
#      needs --yes, --expect-host-key or a typed "yes". --expect-host-key
#      is checked against the key ssh met, which only the real host can
#      present, not against the keys the host reports.
#   4. Installs the registration key in root's authorized_keys, on a
#      line tagged with the site and the main IP that a re-run replaces,
#      and, only when sshd does not already allow it, a drop-in that
#      allows root key login.
#   5. PF2: logs in from the control plane as root with the registration
#      key, verifying the host keys of step 2.
#   6. Formats each --storage-disk with ubicloud-host storage-disk.
#   The registration key and what preflight learned are kept in the key
#   directory for the register phase.
#
# register (no operator key needed)
#   7. Registers the host (ByohRegistration#register!, which checks the
#      database again under a lock), pinned to the host keys, and
#      deletes the kept key, which then lives in sshable.
#   8. Watches the bring-up (ByohHostWatch) until the host accepts VMs,
#      then runs the database checks of `byoh-pool verify`.
#
# A host already registered at the main IP is resumed rather than
# registered again: the site, the pools and settings, and the host keys
# must match, and add then only watches. --storage-disk is refused then:
# prepare formats disks before it registers, and a registered host's
# prep may learn its storage at any moment.
#
# Exit status: 0 the host accepts VMs (or --no-wait, or --phase
# prepare, finished); 1 a validation, preflight, host-key or SSH
# failure; 2 a usage error; 3 a timeout, respirate is not running, or
# the host is outside a bring-up and not accepting; 4 `pool verify`
# failed; 130 interrupted.
class ByohHostAdd
  class Failure < StandardError
    attr_reader :status

    def initialize(message, status = 1)
      super(message)
      @status = status
    end
  end

  # The key directory of the packaged layout; a development checkout
  # keeps its keys under var/.
  PACKAGED_KEY_DIR = "/var/lib/ubicloud/byoh-keys"
  PACKAGED_ENV_FILE = "/etc/ubicloud/env"

  DROP_IN = "/etc/ssh/sshd_config.d/05-ubicloud-root.conf"

  # sshd settings that let root log in with a key.
  ROOT_KEY_LOGIN = %w[yes prohibit-password without-password].freeze

  # The status codes INSTALL_SCRIPT exits with when it cannot finish.
  INSTALL_FAILURES = {
    10 => "sshd -t rejects the configuration with the drop-in that allows root key login; the drop-in was removed",
    11 => "an earlier sshd setting still keeps root from logging in with a key; the drop-in was removed",
    12 => "sshd -T cannot read the sshd configuration",
    13 => "sshd does not read /etc/ssh/sshd_config.d/*.conf, so a drop-in cannot allow root key login",
    14 => "sshd could not be reloaded; the drop-in was removed",
  }.freeze

  # Installs the registration key for root, and allows root key login in
  # sshd when it is not already allowed. Runs as root through
  # ByohOperatorSsh#run_script with the public key, the tag and the
  # control plane's address as arguments.
  INSTALL_SCRIPT = <<~'BASH'
    set -euo pipefail
    exec </dev/null
    # sudo's secure_path may lack the sbin directories; keep its order.
    PATH=$PATH:/usr/sbin:/sbin
    key=$1 tag=$2 cp=$3
    ak=/root/.ssh/authorized_keys
    dropin=/etc/ssh/sshd_config.d/05-ubicloud-root.conf

    # The authorized_keys rewrite: every line but the one with our tag,
    # then ours, through a temporary file renamed over the old one.
    install -d -m 700 -o root -g root /root/.ssh
    tmp=$(mktemp /root/.ssh/.authorized_keys.ubicloud.XXXXXX)
    trap 'rm -f -- "$tmp" "$dropin.tmp"' EXIT
    if [[ -f $ak ]]; then
      awk -v t=" # $tag" 'length($0) < length(t) || substr($0, length($0) - length(t) + 1) != t' "$ak" >"$tmp"
    fi
    printf '%s # %s\n' "$key" "$tag" >>"$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$ak"
    echo "ubicloud-byoh: installed the registration key in $ak (tagged $tag)"

    # 0 root may log in with a key, 1 it may not, 2 sshd -T failed.
    allows_root() {
      local out
      out=$(sshd -T -C "user=root,host=$cp,addr=$cp" 2>/dev/null) || return 2
      grep -Eqi '^permitrootlogin (yes|prohibit-password|without-password)$' <<<"$out" &&
        grep -Eqi '^pubkeyauthentication yes$' <<<"$out"
    }
    reload_sshd() {
      systemctl try-reload-or-restart ssh.service 2>/dev/null && return 0
      local pid
      pid=$(cat /run/sshd.pid 2>/dev/null) && [[ -n $pid ]] && kill -HUP "$pid"
    }

    rc=0
    allows_root || rc=$?
    if ((rc == 0)); then
      echo "ubicloud-byoh: sshd already lets root log in with a key; no drop-in written"
      exit 0
    fi
    ((rc == 1)) || exit 12
    grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null || exit 13

    printf '%s\n' "# Written by ubicloud byoh-host add: the control plane logs in as root with a key." \
      "PermitRootLogin prohibit-password" "PubkeyAuthentication yes" >"$dropin.tmp"
    chmod 644 "$dropin.tmp"
    mv -f -- "$dropin.tmp" "$dropin"
    if ! sshd -t >&2; then
      rm -f -- "$dropin"
      exit 10
    fi
    if ! reload_sshd; then
      rm -f -- "$dropin"
      exit 14
    fi
    rc=0
    allows_root || rc=$?
    if ((rc != 0)); then
      winner=$(grep -Eil '^[[:space:]]*(PermitRootLogin|PubkeyAuthentication)[[:space:]]' /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config 2>/dev/null | grep -vxF -- "$dropin" | head -1 || true)
      rm -f -- "$dropin"
      reload_sshd || true
      echo "ubicloud-byoh: the setting comes from ${winner:-an earlier sshd setting}" >&2
      exit 11
    fi
    echo "ubicloud-byoh: wrote $dropin, which lets root log in with a key"
  BASH

  # What registration and bring-up change on the host, for the
  # confirmation.
  MUTATIONS = [
    "install the registration key in /root/.ssh/authorized_keys, on a line tagged %<tag>s",
    "allow root key login in sshd with #{DROP_IN}, if sshd does not already allow it",
    "%<disks>s",
    "delete any user named rhizome with its home, and create it afresh",
    "set AuthenticationMethods publickey for sshd, which disables password SSH logins for every user",
    "replace the nftables ruleset (flush ruleset) when nftables is enabled",
    "reserve 1G hugepages on the kernel command line (grub)",
    "reboot the host once",
  ].freeze

  def self.default_key_dir(env_file: PACKAGED_ENV_FILE)
    File.exist?(env_file) ? PACKAGED_KEY_DIR : File.expand_path("../var/byoh-keys", __dir__)
  end

  # runner stands in for the system ssh (ByohOperatorSsh), starter for
  # Net::SSH.start (ByohRootProbe), services for
  # ByohHostPreflight.service_states; clock and sleeper drive the watch.
  def initialize(out: $stdout, err: $stderr, input: $stdin, runner: nil, starter: nil, key_dir: self.class.default_key_dir,
    services: -> { ByohHostPreflight.service_states }, nonce: ByohHostPreflight.nonce, host_script: ByohRegistration::HOST_SCRIPT,
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: Kernel.method(:sleep))
    @out = out
    @err = err
    @input = input
    @runner = runner
    @starter = starter
    @key_dir = key_dir
    @services = services
    @nonce = nonce
    @host_script = host_script
    @clock = clock
    @sleeper = sleeper
  end

  # Runs add, preflight or watch; returns the exit status.
  def run(command, argv)
    case command
    when "add" then add(parse(argv, :add))
    when "preflight" then preflight(parse(argv, :preflight))
    else watch_command(argv)
    end
  rescue Failure => ex
    @err.puts "! #{ex.message}" unless ex.message.empty?
    ex.status
  rescue OptionParser::ParseError, ByohHostPreflight::UsageError => ex
    @err.puts "! #{ex.message}"
    2
  rescue ByohRegistration::ValidationError => ex
    @err.puts "! validation failed: #{ex.message}"
    1
  end

  private

  # --- options -------------------------------------------------------

  def parse(argv, command)
    o = {pools: [], default_boot_images: [], accept_checks: [], storage_disks: [], expect_host_keys: [], phase: "all", bmc: nil}
    help = false
    parser = OptionParser.new do |p|
      p.banner = (command == :add) ?
        "Usage: bin/byoh-host add --site NAME --ssh USER@HOST (--pool-file FILE | --routed-network CIDR ...) [options]" :
        "Usage: bin/byoh-host preflight --site NAME --ssh USER@HOST [--pool-file FILE | --routed-network CIDR ...] [options]"
      p.separator ""
      p.on("--site NAME", "BYOH location (site) to add the host to, from ubicloud-admin site add") { o[:site] = it }
      p.on("--ssh USER@HOST", "The operator's login to the host; USER needs passwordless sudo") { o[:ssh] = it }
      p.on("--ssh-port PORT", Integer, "Port of that login (default 22; the control plane always uses 22)") { o[:ssh_port] = it }
      p.on("--ssh-key FILE", "The operator's private key for that login (any type; never stored)") { o[:ssh_key] = it }
      p.on("--main-ip IP", "Address the control plane reaches the host at (default: the --ssh host, when it is an IPv4 address)") { o[:main_ip] = it }
      p.on("--uplink-ip IP", "Address the host's default route leaves from (default: detected)") { o[:uplink_ip] = it }
      p.on("--routed-network CIDR[,KEY=VALUE...]", "Address pool of the host, as for register-byoh-host (repeatable)") { o[:pools] << it }
      p.on("--pool-file FILE", "pools.yaml (version 2)") { o[:pool_file] = it }
      p.on("--ipv6-mode MODE", "gua or ula (default: derived from the IPv6 pool)") { o[:ipv6_mode] = it }
      p.on("--default-boot-image NAME", "Boot image to download (repeatable; default: #{ByohRegistration::DEFAULT_BOOT_IMAGES.join(", ")})") { o[:default_boot_images] << it }
      p.on("--accept-check ID", "Accept an overridable failed check, such as PF8-hybrid (repeatable)") { o[:accept_checks] << it }
      if command == :add
        p.on("--registration-key FILE", "Unencrypted OpenSSH Ed25519 key the control plane keeps (default: generate one)") { o[:registration_key] = it }
        p.on("--storage-disk BYID", "Format this blank disk (a /dev/disk/by-id name) for VM storage (repeatable)") { o[:storage_disks] << it }
        p.on("--allow-shared-transport", "Let --storage-disk format an iSCSI, FC, NVMe-oF or multipath disk") { o[:allow_shared] = true }
        p.on("--server-identifier ID", "Operator-assigned identifier (default: byoh-<vm_host uuid>)") { o[:server_identifier] = it }
        p.on("--expect-host-key FINGERPRINT", "SHA256:... fingerprint the host must present; confirms the changes (repeatable)") { o[:expect_host_keys] << it }
        p.on("--skip-preflight", "Do not stop on failed preflight checks") { o[:skip_preflight] = true }
        p.on("--yes", "Make the changes without asking") { o[:yes] = true }
        p.on("--phase PHASE", %w[prepare register all], "prepare, register or all (default)") { o[:phase] = it }
        p.on("--timeout SECONDS", Integer, "Give up watching the bring-up after this long") { o[:timeout] = it }
        p.on("--no-wait", "Exit once the host is registered") { o[:no_wait] = true }
        p.on("--bmc-endpoint URL", "Redfish base URL") { bmc(o)["endpoint"] = it }
        p.on("--bmc-user USERNAME", "BMC username") { bmc(o)["username"] = it }
        p.on("--bmc-pass-env VAR", "Env var of the respirate service holding the BMC password") { bmc(o)["password_env"] = it }
        p.on("--bmc-password PASSWORD", "Refused: use --bmc-pass-env") do
          raise Failure.new("--bmc-password would store the BMC password in plain text; pass --bmc-pass-env VAR", 2)
        end
        p.on("--bmc-system-id ID", "Explicit Redfish SystemId") { bmc(o)["system_id"] = it }
        p.on("--bmc-verify-ssl", "Verify the BMC's TLS certificate") { bmc(o)["verify_ssl"] = true }
        p.on("--bmc-reset-type TYPE", "Redfish ResetType (default: ForceRestart)") { bmc(o)["reset_type"] = it }
      end
      p.on("-h", "--help", "Show this help") { help = true }
    end
    rest = parser.parse(argv)
    if help
      @out.puts parser
      raise Failure.new("", 0)
    end
    raise OptionParser::InvalidArgument, "unexpected argument #{rest.first}" unless rest.empty?
    raise OptionParser::MissingArgument, "--site is required" unless o[:site]
    ssh_needed = command == :preflight || o[:phase] != "register"
    raise OptionParser::MissingArgument, "--ssh is required" if ssh_needed && !o[:ssh]
    raise OptionParser::InvalidArgument, "--ssh must be USER@HOST, not #{o[:ssh]}" if o[:ssh] && !ByohOperatorSsh.valid_target?(o[:ssh])
    unless o[:main_ip]
      host = o[:ssh].to_s.split("@", 2).last.to_s
      raise OptionParser::MissingArgument, "--main-ip is required when --ssh does not name an IPv4 address" unless ByohPoolDeclaration.parse_ipv4(host)
      o[:main_ip] = host
    end
    o[:storage_disks].each do |id|
      raise OptionParser::InvalidArgument, "--storage-disk takes a name from /dev/disk/by-id, not #{id}" unless id.match?(%r{\A[^/\s.][^/\s]*\z})
    end
    o[:expect_host_keys].each do |fp|
      raise OptionParser::InvalidArgument, "--expect-host-key takes a SHA256:... fingerprint, not #{fp}" unless fp.match?(%r{\ASHA256:[A-Za-z0-9+/]{43}\z})
    end
    o[:bmc]["verify_ssl"] = false if o[:bmc] && !o[:bmc]["verify_ssl"]
    o[:default_boot_images] = ByohRegistration::DEFAULT_BOOT_IMAGES if o[:default_boot_images].empty?
    ByohHostPreflight.validate_accept!(o[:accept_checks])
    o
  end

  def bmc(o) = (o[:bmc] ||= {"protocol" => "redfish"})

  def registration(o, ssh_key_source: :generate)
    ByohRegistration.new(main_ip: o[:main_ip], location: o[:site], pools: o[:pools], pool_file: o[:pool_file], ipv6_mode: o[:ipv6_mode],
      ssh_key_source:, server_identifier: o[:server_identifier], bmc_config: o[:bmc], default_boot_images: o[:default_boot_images],
      uplink_ip: o[:uplink_ip])
  end

  # Refuses to reach a host in the test environment unless specs injected
  # the stand-ins: the system ssh would change the host, and Net::SSH
  # raises there anyway.
  def refuse_in_tests(*needed)
    return unless Config.test? && needed.any?(&:nil?)

    raise Failure, "refusing to reach a host under RACK_ENV=test; inject the ssh runner and starter"
  end

  # --- add -----------------------------------------------------------

  def add(o)
    refuse_in_tests(@runner, @starter) unless o[:phase] == "register"
    requested = registration(o).requested_config
    if (host = registered_host(o[:main_ip]))
      return resume(o, host, requested)
    end

    prepare(o, requested) unless o[:phase] == "register"
    return 0 if o[:phase] == "prepare"

    register(o, requested)
  end

  def registered_host(main_ip)
    (sshable = Sshable.first(host: main_ip)) && VmHost[sshable.id]
  end

  def tag(site, main_ip) = "ubicloud-byoh site=#{site} ip=#{main_ip}"

  def undo_hint(site, main_ip)
    "To undo the key install on the host: sudo sed -i '/ # #{tag(site, main_ip).gsub(".", "\\.")}$/d' /root/.ssh/authorized_keys; " \
      "and, if it exists: sudo rm #{DROP_IN} && sudo systemctl reload ssh.service"
  end

  def prepare(o, requested)
    reg = registration(o, ssh_key_source: o[:registration_key] || :generate)
    reg.validate!
    reg.notes.each { @err.puts "note: #{it}" }
    site = reg.location.name
    services = @services.call
    if services && !(stopped = ByohHostPreflight::SERVICES.reject { services[it] }).empty?
      raise Failure, "PF21: #{stopped.join(" and ")} not active, so the host would never be set up; run systemctl start ubicloud.target first"
    end
    registration_key = read_registration_key(o[:registration_key]) if o[:registration_key]

    with_host_lock(o[:main_ip]) do
      ByohOperatorSsh.open(o[:ssh], port: o[:ssh_port], key: o[:ssh_key], runner: @runner || ByohOperatorSsh::OPEN3_RUNNER) do |ssh|
        @out.puts "Checking #{o[:ssh]} (preflight, read-only)"
        sudo!(ssh)
        keys, cp_ip = host_preflight(ssh, reg, o, services, adding: true)
        print_fingerprints(keys, ssh)
        expected!(o[:expect_host_keys], keys, ssh)
        confirm!(o, mutation_summary(ssh, o, site))

        key_path = keep_registration_key(site, o[:main_ip], registration_key)
        public_key = read_registration_key(key_path).public_key
        begin
          install_key(ssh, public_key, tag(site, o[:main_ip]), cp_ip)
          pf2!(o[:main_ip], key_path, keys)
          o[:storage_disks].each { storage_disk(ssh, it, o[:allow_shared]) }
        rescue Failure, ByohOperatorSsh::TransportError => ex
          raise Failure, "#{ex.message}\n  #{undo_hint(site, o[:main_ip])}"
        end
        write_state(site, o[:main_ip], requested, host_keys: keys.map(&:to_s), uplink_ip: reg.uplink_ip, gateway: reg.gateway)
      end
    end
    @out.puts "Prepared #{o[:main_ip]} for site #{site}."
    @out.puts "Register it with the same arguments and --phase register." if o[:phase] == "prepare"
  rescue ByohOperatorSsh::TransportError, ByohOperatorSsh::HostKeyError => ex
    raise Failure, ex.message
  end

  # --- preflight -----------------------------------------------------

  # Steps 1 and 2 of add: read-only.
  def preflight(o)
    refuse_in_tests(@runner)
    reg = registration(o)
    reg.validate!
    reg.notes.each { @err.puts "note: #{it}" }
    services = @services.call
    ByohOperatorSsh.open(o[:ssh], port: o[:ssh_port], key: o[:ssh_key], runner: @runner || ByohOperatorSsh::OPEN3_RUNNER) do |ssh|
      sudo!(ssh)
      keys, = host_preflight(ssh, reg, o, services, adding: false)
      print_fingerprints(keys, ssh)
    end
    @out.puts "Preflight passed; nothing on the host was changed."
    0
  rescue ByohOperatorSsh::TransportError, ByohOperatorSsh::HostKeyError => ex
    raise Failure, ex.message
  end

  def sudo!(ssh)
    return if ssh.sudo?

    raise Failure, "#{ssh.user} on #{ssh.host} cannot run sudo without a password; give it passwordless sudo (NOPASSWD), or use a user that has it"
  end

  # Runs ubicloud-host preflight as root, verifies the host keys, and
  # evaluates the report. Returns [host keys, the control plane's address
  # as the host sees it].
  def host_preflight(ssh, reg, o, services, adding:)
    facts = ssh.run("uname -m; echo \"$SSH_CONNECTION\"").stdout
    arch, connection = facts.lines.map(&:strip)
    cp_ip = connection.to_s.split(" ").first.to_s
    script = read_host_script
    result = ssh.run_script(script, ["preflight", *reg.host_script_args(@nonce, arch, connection)])
    report = if result.success?
      ByohHostPreflight.parse(result.stdout, @nonce)
    else
      ByohHostPreflight.new([ByohHostPreflight::Check.new(id: "preflight", status: "fail",
        detail: "ubicloud-host exited #{result.status}: #{result.stderr.to_s.strip.lines.last(3).join(" ").strip[0, 300]}",
        fix: "run scripts/byoh/host/ubicloud-host preflight on the host to see why", accepted: false)], {})
    end
    keys = report.readable? ? ssh.verified_host_keys(report.host_keys) : host_keys_of(ssh)
    report.checks.unshift(pf2_stand_in(report.facts["sshd"], adding))
    reg.evaluate_preflight(report, accept_checks: o[:accept_checks], services:, host_keys: keys)
    @out.print report.to_table
    if report.blocking?
      raise Failure, "preflight failed: fix the checks marked fail, or accept an overridable one with --accept-check; nothing on the host was changed" unless o[:skip_preflight]

      @err.puts "warning: preflight failed, but --skip-preflight goes on"
      reg.adopt_preflight(host_keys: keys, uplink_ip: report.uplink_ip, gateway: report.gateway)
    end
    [keys, cp_ip]
  end

  def read_host_script
    File.read(@host_script)
  rescue SystemCallError => ex
    raise Failure, "cannot read #{@host_script} on the control plane (#{ex.class}); reinstall the control plane"
  end

  # The host keys from /etc/ssh, when preflight could not report them.
  def host_keys_of(ssh)
    ssh.verified_host_keys(ssh.run("cat /etc/ssh/ssh_host_*_key.pub").stdout.lines.map(&:strip))
  end

  # PF2 runs only once the registration key is installed. Until then the
  # sshd settings of a root login stand in for it.
  def pf2_stand_in(sshd, adding)
    later = adding ? "runs once the key is installed" : "not run (no root key yet)"
    if sshd.nil?
      ByohHostPreflight::Check.new(id: "PF2", status: "warn", detail: "#{later}; sshd -T failed, so the root login settings are unknown",
        fix: "run sudo sshd -t on the host", accepted: false)
    elsif ROOT_KEY_LOGIN.include?(sshd["permitrootlogin"]) && sshd["pubkeyauthentication"] == "yes"
      ByohHostPreflight::Check.new(id: "PF2", status: "info", detail: "#{later}; sshd lets root log in with a key", fix: "", accepted: false)
    else
      ByohHostPreflight::Check.new(id: "PF2", status: "info",
        detail: "#{later}; sshd does not let root log in with a key now (PermitRootLogin #{sshd["permitrootlogin"]}), so host add writes #{DROP_IN}", fix: "", accepted: false)
    end
  end

  # The keys the host reports, marking the one ssh met: only that one
  # proves which machine answered, as the others are public.
  def print_fingerprints(keys, ssh)
    met = ssh.recorded_host_keys
    @out.puts "Host keys:"
    keys.each { @out.puts "  #{it.type} #{it.fingerprint}#{" (presented to ssh)" if met.include?(it)}" }
  end

  # Every key ssh met must be an expected one. The reported keys cannot
  # prove it: a man in the middle can report the real host's public keys
  # next to its own. Every expected key must also be the host's own.
  def expected!(fingerprints, keys, ssh)
    return if fingerprints.empty?

    met = ssh.recorded_host_keys.map(&:fingerprint)
    unless (met - fingerprints).empty?
      raise Failure, "ssh met the host key #{met.join(", ")} at #{ssh.host}, not the expected #{fingerprints.join(", ")}: " \
        "a man in the middle, or --ssh reaches a different machine; nothing was changed"
    end
    missing = fingerprints - keys.map(&:fingerprint)
    return if missing.empty?

    raise Failure, "the host does not have the expected host key #{missing.join(", ")}: a man in the middle, or --ssh reaches a different machine; nothing was changed"
  end

  # The confirmation text: what will change, with each storage disk's
  # size, model and serial.
  def mutation_summary(ssh, o, site)
    disks = o[:storage_disks].map do |id|
      res = ssh.run("lsblk -dnbPo SIZE,MODEL,SERIAL #{"/dev/disk/by-id/#{id}".shellescape}")
      raise Failure, "no disk /dev/disk/by-id/#{id} on the host; nothing was changed" unless res.success?

      info = res.stdout.scan(/(\w+)="([^"]*)"/).to_h
      "format /dev/disk/by-id/#{id} (#{(info["SIZE"].to_i / 2**30.0).round(1)} GiB, model #{info["MODEL"].to_s.strip}, serial #{info["SERIAL"].to_s.strip}) as ext4 for VM storage, erasing it"
    end
    disk_line = disks.empty? ? nil : disks.join("\n  - ")
    MUTATIONS.filter_map { |m| (m == "%<disks>s") ? disk_line : format(m, tag: tag(site, o[:main_ip])) }
  end

  def confirm!(o, mutations)
    @out.puts "Adding the host will:"
    mutations.each { @out.puts "  - #{it}" }
    return if o[:yes] || !o[:expect_host_keys].empty?
    raise Failure, "nothing was changed: pass --yes (or --expect-host-key) to confirm without a terminal" unless @input.tty?

    @out.print "Type yes to go on: "
    raise Failure, "aborted; nothing on the host was changed" unless @input.gets.to_s.strip == "yes"
  end

  def key_path(site, main_ip) = File.join(@key_dir, "#{site}-#{main_ip}")

  def state_path(site, main_ip) = "#{key_path(site, main_ip)}.json"

  # An SshKey from an unencrypted OpenSSH Ed25519 private key file.
  def read_registration_key(path)
    priv = Net::SSH::Authentication::ED25519::PrivKey.read(File.read(path), nil)
    SshKey.from_binary(priv.sign_key.keypair)
  rescue SystemCallError, ArgumentError, Net::SSH::Exception => ex
    raise Failure, "#{path} is not an unencrypted OpenSSH Ed25519 private key (#{ex.class}: #{ex.message})"
  end

  # The registration key, in the key directory: given, kept from an
  # earlier run, or generated, and written before it is installed so a
  # failed run can be repeated with the same key.
  def keep_registration_key(site, main_ip, given)
    path = key_path(site, main_ip)
    FileUtils.mkdir_p(@key_dir, mode: 0o700)
    if given
      write_private(path, given.private_key)
    elsif File.exist?(path)
      @out.puts "Reusing the registration key an earlier run generated (#{path})."
    else
      write_private(path, SshKey.generate.private_key)
      @out.puts "Generated a registration key (#{path}); it is deleted once the host is registered."
    end
    path
  end

  def write_private(path, text)
    tmp = "#{path}.#{Process.pid}.tmp"
    FileUtils.rm_f(tmp)
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { it.write(text) }
    File.rename(tmp, path)
  end

  def install_key(ssh, public_key, tag, cp_ip)
    result = ssh.run_script(INSTALL_SCRIPT, [public_key, tag, cp_ip.empty? ? "127.0.0.1" : cp_ip])
    result.stdout.each_line { @out.puts it.sub(/\Aubicloud-byoh: /, "  ") if it.start_with?("ubicloud-byoh: ") }
    return if result.success?

    why = INSTALL_FAILURES.fetch(result.status) { "the key install exited #{result.status}" }
    raise Failure, "#{why}: #{result.stderr.to_s.strip.lines.last(3).join(" ").strip[0, 300]}"
  end

  def pf2!(main_ip, key_path, keys)
    result = ByohRootProbe.new(main_ip, read_registration_key(key_path).private_key, pinned_host_keys: keys,
      starter: @starter || ByohRootProbe::NET_SSH_START).call
    @out.print ByohHostPreflight.new([result.check], {}).to_table
    raise Failure, "PF2 failed: the control plane cannot log in to #{main_ip} as root with the registration key" unless result.ok
  end

  def storage_disk(ssh, id, allow_shared)
    args = ["storage-disk", "--by-id", id]
    args << "--allow-shared-transport" if allow_shared
    result = ssh.run_script(read_host_script, args)
    raise Failure, "storage-disk #{id} failed (exit #{result.status}): #{result.stderr.to_s.strip.lines.last(3).join(" ").strip[0, 300]}" unless result.success?

    @out.puts "  #{result.stdout.lines.last.to_s.strip}"
  end

  def args_digest(requested)
    Digest::SHA256.hexdigest(JSON.generate(requested.merge(location: requested[:location].name)))
  end

  def write_state(site, main_ip, requested, **state)
    write_private("#{state_path(site, main_ip)}.new", JSON.generate(state.merge(args: args_digest(requested))))
    File.rename("#{state_path(site, main_ip)}.new", state_path(site, main_ip))
  end

  # Holds a session advisory lock for main_ip while the prepare phase
  # runs, so two runs never prepare one host at once.
  def with_host_lock(main_ip)
    key = Sequel.function(:hashtext, "byoh-host:#{main_ip}")
    DB.synchronize do
      raise Failure, "another byoh-host add is preparing #{main_ip}; wait for it to finish" unless DB.get(Sequel.function(:pg_try_advisory_lock, key))

      begin
        yield
      ensure
        DB.get(Sequel.function(:pg_advisory_unlock, key))
      end
    end
  end

  # --- register ------------------------------------------------------

  def register(o, requested)
    site = requested[:location].name
    path = key_path(site, o[:main_ip])
    state = begin
      JSON.parse(File.read(state_path(site, o[:main_ip])))
    rescue SystemCallError, JSON::ParserError
      raise Failure, "#{o[:main_ip]} has not been prepared for site #{site} (no #{state_path(site, o[:main_ip])}); run add with --phase prepare (or all) first"
    end
    raise Failure.new("the arguments differ from those the host was prepared with; prepare it again with these", 2) unless state["args"] == args_digest(requested)

    reg = registration(o, ssh_key_source: path)
    reg.validate!
    reg.adopt_preflight(host_keys: state["host_keys"], uplink_ip: state["uplink_ip"], gateway: state["gateway"])
    strand = reg.register!
    FileUtils.rm_f([path, state_path(site, o[:main_ip])])
    host = VmHost[strand.id]
    @out.puts "Registered host #{host.ubid} in site #{site}."
    return 0 if o[:no_wait]

    watch(host, o[:timeout])
  end

  # --- resume --------------------------------------------------------

  def resume(o, host, requested)
    if host.provider_name != HostProvider::GENERIC_PROVIDER_NAME
      raise Failure.new("#{o[:main_ip]} is registered to host #{host.ubid}, which is not a BYOH host", 2)
    end
    if host.location_id != requested[:location].id
      raise Failure.new("#{o[:main_ip]} is registered to host #{host.ubid} in site #{host.location.name}, not #{requested[:location].name}", 2)
    end
    raise Failure.new("host #{host.ubid} is being destroyed; add it again once it is gone", 2) if host.destroy_set?

    diff = config_diff(host, requested)
    raise Failure.new("host #{host.ubid} is registered with other settings:\n  #{diff.join("\n  ")}", 2) unless diff.empty?
    unless o[:storage_disks].empty?
      raise Failure.new("host #{host.ubid} is registered already, and add formats storage disks only before it registers a host, " \
        "as the host's prep may learn its storage at any moment; leave out --storage-disk to resume " \
        "(adding a disk to a registered host is not supported yet, M5)", 2)
    end

    @out.puts "Resuming: #{o[:main_ip]} is already registered as host #{host.ubid} (at #{host.strand.prog}.#{host.strand.label})."
    if o[:phase] != "register"
      ByohOperatorSsh.open(o[:ssh], port: o[:ssh_port], key: o[:ssh_key], runner: @runner || ByohOperatorSsh::OPEN3_RUNNER) do |ssh|
        reinstalled!(host, host_keys_of(ssh), ssh.recorded_host_keys)
      end
    end
    return 0 if o[:phase] == "prepare" || o[:no_wait]

    watch(host, o[:timeout])
  rescue ByohOperatorSsh::TransportError, ByohOperatorSsh::HostKeyError => ex
    raise Failure, ex.message
  end

  # keys are the host's reported keys, met the ones ssh met.
  def reinstalled!(host, keys, met)
    pinned = Array(host.sshable.host_keys)
    return if pinned.empty?

    unless (pinned - keys.map(&:to_s)).empty?
      raise Failure, "host #{host.ubid} no longer has the host keys pinned at registration: the host was reinstalled, " \
        "so destroy host #{host.ubid} and add it again"
    end
    return if (met.map(&:to_s) - pinned).empty?

    raise Failure, "ssh met the host key #{met.map(&:fingerprint).join(", ")} at #{host.sshable.host}, which is not one pinned at registration: " \
      "a man in the middle, or the address reaches a different machine"
  end

  # How the registered host's settings differ from the requested ones.
  def config_diff(host, requested)
    stored = host.provider.config.to_h
    diff = []
    # Hosts registered before M2 keep legacy entries; compare them as
    # every other reader of the config sees them.
    networks = Array(stored["routed_networks"]).map { ByohPoolDeclaration.parse(it, legacy: true).to_config }
    given = requested[:routed_networks]
    v4 = ->(list) { list.reject { it["cidr"].include?(":") } }
    diff << "pools: registered #{v4.call(networks).to_json}, given #{v4.call(given).to_json}" if v4.call(networks) != v4.call(given)
    stored_v6 = networks.find { it["cidr"].include?(":") }
    given_v6 = given.find { it["cidr"].include?(":") }
    if given_v6 ? stored_v6 != given_v6 : !derived_v6?(stored_v6, host.location)
      diff << "IPv6 pool: registered #{stored_v6&.to_json || "none"}, given #{given_v6&.to_json || "none (a /64 of the site's ula48)"}"
    end
    diff << "uplink: registered #{stored["uplink"].inspect}, given #{requested[:uplink].inspect}" if stored["uplink"] != requested[:uplink]
    diff << "BMC: registered #{stored["bmc"].to_json}, given #{requested[:bmc].to_json}" if stored["bmc"] != requested[:bmc]
    if requested[:uplink_ip] && stored["uplink_ip"] != requested[:uplink_ip]
      diff << "uplink IP: registered #{stored["uplink_ip"].inspect}, given #{requested[:uplink_ip]}"
    end
    images = host.strand.stack.last["default_boot_images"]
    diff << "boot images: registered #{images.inspect}, given #{requested[:default_boot_images].inspect}" if images != requested[:default_boot_images]
    if requested[:server_identifier] && host.provider.server_identifier != requested[:server_identifier]
      diff << "server identifier: registered #{host.provider.server_identifier}, given #{requested[:server_identifier]}"
    end
    diff
  end

  def derived_v6?(stored_v6, location)
    ula48 = location.byoh_profile.ula48
    !!(stored_v6 && ula48 && ByohNetworkProfile.covers?(ula48, ByohNetworkProfile.parse_cidr(stored_v6["cidr"])))
  end

  # --- watch ---------------------------------------------------------

  def watch_command(argv)
    o = {}
    parser = OptionParser.new do |p|
      p.banner = "Usage: bin/byoh-host watch HOST [--timeout SECONDS]  (HOST: a vh... ubid or the main IP)"
      p.on("--timeout SECONDS", Integer, "Give up after this long") { o[:timeout] = it }
    end
    rest = parser.parse(argv)
    raise OptionParser::InvalidArgument, "watch takes one host" unless rest.size == 1

    key = rest.first
    host = (VmHost[key] if key.match?(/\Avh[0-9a-z]{24}\z/)) || registered_host(key) || raise(Failure, "no host #{key}")
    raise Failure, "host #{host.ubid} is not a generic (BYOH) host" unless host.provider_name == HostProvider::GENERIC_PROVIDER_NAME

    watch(host, o[:timeout])
  end

  def watch(host, timeout)
    @out.puts "Watching the bring-up of host #{host.ubid}; it takes about 15-25 minutes on bare metal and reboots the host once."
    result = ByohHostWatch.new(host, out: @out, timeout:, clock: @clock, sleeper: @sleeper).run
    return ByohHostWatch::EXIT.fetch(result) unless result == :accepting

    verify(host)
  end

  def verify(host)
    results = ByohPool.new(VmHost[host.id]).verify
    results.each { |level, message| @out.puts "#{level}: #{message}" }
    if results.any? { it.first == :fail }
      @err.puts "! host #{host.ubid} accepts VMs, but bin/byoh-pool verify --host #{host.ubid} fails; fix the pools"
      return 4
    end
    @out.puts "Host #{host.ubid} accepts VMs."
    0
  end
end
