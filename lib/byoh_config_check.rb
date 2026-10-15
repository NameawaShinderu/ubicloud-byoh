# frozen_string_literal: true

require "find"
require "ipaddr"
require "optparse"
require "time"
require "uri"

# bin/byoh-config-check: reports the control-plane settings and database
# state that a BYOH deployment needs, as ok/warn/fail lines. It exits 1
# when any check fails. ByohPreflightWarnings entries are reported as
# warnings. Checks that need root (pg_hba.conf, backup age) belong to
# ubicloud-admin status instead.
#
# --simulate-production evaluates the production-only checks as if
# RACK_ENV were production, which is how a development control plane is
# checked before it is switched over.
class ByohConfigCheck
  Result = Data.define(:level, :message)

  USAGE = "Usage: bin/byoh-config-check [--simulate-production]"

  # puma_config.rb runs 15 threads, each of which may hold a connection.
  MIN_DB_POOL_WEB = 16

  # Range-partitioned tables that reject inserts once the last partition
  # ends, unless they have a DEFAULT partition.
  PARTITIONED_TABLES = %w[audit_log account_authentication_audit_log admin_account_authentication_audit_log].freeze
  RUNWAY_FAIL_DAYS = 30
  RUNWAY_WARN_DAYS = 90

  # Rodauth keeps password hashes away from the application role: only
  # the <role>_password role may read them, and only through these
  # functions, which PUBLIC must not be able to execute (migrate/ph).
  HASH_TABLES = %w[account_password_hashes account_previous_password_hashes admin_password_hash].freeze
  HASH_FUNCTIONS = %w[
    rodauth_get_salt(uuid) rodauth_valid_password_hash(uuid,text)
    rodauth_get_previous_salt(uuid) rodauth_previous_password_hash_match(uuid,text)
    rodauth_admin_get_salt(uuid) rodauth_admin_valid_password_hash(uuid,text)
  ].freeze

  # Role attributes the services never need; a role with them can widen
  # its own privileges or skip row security.
  ROLE_ATTRIBUTES = {createrole: "CREATEROLE", createdb: "CREATEDB", bypassrls: "BYPASSRLS"}.freeze

  ROLE_FACTS_SQL = <<~SQL.freeze
    SELECT current_user AS role, r.rolsuper AS superuser,
      r.rolcreaterole AS createrole, r.rolcreatedb AS createdb, r.rolbypassrls AS bypassrls,
      pg_has_role(current_user, (SELECT oid FROM pg_roles WHERE rolname = current_user || '_password'), 'MEMBER') AS ph_member,
      #{HASH_TABLES.each_index.map { "has_table_privilege(current_user, to_regclass(?), 'SELECT') AS table#{it}" }.join(", ")},
      #{HASH_FUNCTIONS.each_index.map { "has_function_privilege('public', to_regprocedure(?), 'EXECUTE') AS function#{it}" }.join(", ")}
    FROM pg_roles r WHERE r.rolname = current_user
  SQL

  # root is the release directory, and code_owner the uid that must own
  # every entry in it outside var/.
  def initialize(out: $stdout, err: $stderr, env: ENV, root: Dir.pwd, code_owner: 0, now: Time.now, preflight: ByohPreflightWarnings)
    @out = out
    @err = err
    @env = env
    @root = root
    @code_owner = code_owner
    @now = now
    @preflight = preflight
  end

  # Returns the process exit status.
  def run(argv)
    simulate = false
    rest = OptionParser.new do |o|
      o.banner = USAGE
      o.on("--simulate-production", "Check as if RACK_ENV were production") { simulate = true }
    end.parse(argv)
    raise OptionParser::InvalidArgument, rest.first unless rest.empty?

    results = check(production: simulate || Config.production?)
    results.each { @out.puts format("%-4s %s", it.level, it.message) }
    (results.any? { it.level == "fail" }) ? 1 : 0
  rescue OptionParser::ParseError => e
    @err.puts "! #{e.message}\n#{USAGE}"
    2
  end

  def check(production:)
    @production = production
    [
      *preflight,
      pry_opt_in,
      base_url,
      client_ip,
      *mail,
      boot_images,
      *billing_rates_dir,
      db_pool,
      deleted_records,
      runtime_token,
      *writability,
      *role_isolation,
      *partition_runway,
    ].compact
  end

  # The attributes and privileges of the connected role that decide
  # whether password hashes are isolated from it. table<i> and
  # function<i> follow HASH_TABLES and HASH_FUNCTIONS.
  def role_facts
    DB.fetch(ROLE_FACTS_SQL, *HASH_TABLES, *HASH_FUNCTIONS).first
  end

  # Where hosts fetch boot images from, as [level, message]. Shared with
  # ByohHostPreflight (PF20).
  def self.boot_image_source(production:)
    return ["ok", "boot images: BOOT_IMAGE_SOURCE=#{Config.boot_image_source}, not production"] unless production
    return ["ok", "boot images: public upstream mirrors"] if Config.boot_image_source == "public"

    r2 = [Config.ubicloud_images_r2_bucket_name, Config.ubicloud_images_r2_endpoint, Config.ubicloud_images_r2_access_key, Config.ubicloud_images_r2_secret_key]
    if r2.all?
      ["ok", "boot images: Ubicloud R2 storage"]
    else
      ["fail", "BOOT_IMAGE_SOURCE=auto fetches every boot image from Ubicloud's R2 storage in production, but UBICLOUD_IMAGES_R2_* are not all set; set BOOT_IMAGE_SOURCE=public"]
    end
  end

  private

  def ok(message) = Result.new("ok", message)

  def warning(message) = Result.new("warn", message)

  def failure(message) = Result.new("fail", message)

  def preflight
    warnings = @preflight.warnings
    return [ok("preflight: no BYOH warnings")] if warnings.empty?
    warnings.map { warning(it) }
  end

  def pry_opt_in
    return unless Config.pry_allow_unaudited
    message = "PRY_ALLOW_UNAUDITED is set for every process; set it only in the environment of ubicloud-admin console"
    @production ? failure(message) : warning(message)
  end

  def base_url
    return unless @production
    uri = begin
      URI(Config.base_url)
    rescue URI::InvalidURIError
      return failure("BASE_URL #{Config.base_url.inspect} is not a valid URL")
    end
    if !%w[http https].include?(uri.scheme) || uri.hostname.to_s.empty?
      failure("BASE_URL #{Config.base_url.inspect} is not an http or https URL with a host, such as https://cloud.example.com")
    elsif uri.scheme == "http" && !%w[localhost 127.0.0.1 ::1].include?(uri.hostname)
      failure("BASE_URL #{Config.base_url} is http, but production cookies are Secure, so browsers drop them and login fails; use https")
    else
      ok("BASE_URL #{Config.base_url}")
    end
  end

  # M3-m: behind a TLS front, puma sees the front's address, so the
  # audit logs record 127.0.0.1 unless IP_FROM_HEADER names the header
  # the front sets. A header is only trustworthy when nothing but the
  # front can reach puma, so puma must bind a loopback address (BIND,
  # read the same way as puma_config.rb).
  def client_ip
    bind = @env["BIND"] || "0.0.0.0"
    if (header = Config.ip_from_header)
      if loopback?(bind)
        ok("client IP: from the #{header} header; puma binds #{bind}, so only the local TLS front can set it")
      else
        message = "IP_FROM_HEADER is #{header} but puma binds #{bind}, so any client that reaches puma directly sets its own audit-log IP; set BIND=127.0.0.1"
        @production ? failure(message) : warning(message)
      end
    elsif URI(Config.base_url).scheme == "https"
      warning("IP_FROM_HEADER is unset, so behind a TLS front the audit logs record the front's address; set it to X-Real-IP (Caddy) or CF-Connecting-IP (cloudflared)")
    else
      ok("client IP: from the connection (no TLS front)")
    end
  rescue URI::InvalidURIError
    # In production, base_url fails on the URL; elsewhere it checks
    # nothing, so report it here.
    warning("BASE_URL #{Config.base_url.inspect} is not a valid URL, so the client IP check cannot tell whether a TLS front is in use") unless @production
  end

  def loopback?(host)
    host = host.delete_prefix("[").delete_suffix("]")
    host == "localhost" || IPAddr.new(host).loopback?
  rescue IPAddr::Error
    false
  end

  def mail
    return [ok("mail: driver #{Config.mail_driver}, not production")] unless @production

    driver = (Config.production? || @env.key?("MAIL_DRIVER")) ? Config.mail_driver : :smtp
    from = (Config.production? || @env.key?("MAIL_FROM")) ? Config.mail_from : nil
    results = []
    results << failure("MAIL_FROM is unset; production needs a sender address for account and alert mail") unless from
    case driver
    when :smtp
      results << failure("MAIL_DRIVER is smtp but SMTP_HOSTNAME is unset") unless Config.smtp_hostname
    when :logger
      results << warning("MAIL_DRIVER is logger: verification and reset links land in journald, readable by the adm and systemd-journal groups")
    end
    results.empty? ? [ok("mail: driver #{driver}, from #{from}")] : results
  end

  def boot_images
    level, message = self.class.boot_image_source(production: @production)
    Result.new(level, message)
  end

  def billing_rates_dir
    return [] unless (dir = Config.billing_rates_extra_dir)
    if File.directory?(dir) && File.readable?(dir) && File.writable?(dir)
      [ok("BILLING_RATES_EXTRA_DIR #{dir} is readable and writable")]
    else
      [failure("BILLING_RATES_EXTRA_DIR #{dir} is not a directory that uid #{Process.euid} can read and write; byoh-location writes rates there")]
    end
  end

  def db_pool
    pool = Config.db_pool_web
    if pool < MIN_DB_POOL_WEB
      warning("DB_POOL_WEB is #{pool}, but puma runs 15 threads; set it to at least #{MIN_DB_POOL_WEB}")
    else
      ok("DB_POOL_WEB is #{pool}")
    end
  end

  def deleted_records
    if Config.deleted_record_archive_bucket
      ok("deleted records: archived to #{Config.deleted_record_archive_bucket}")
    elsif !@production || Config.deleted_record_drop_unarchived
      ok("deleted records: expired partitions are dropped unarchived")
    else
      warning("deleted records: no DELETED_RECORD_ARCHIVE_BUCKET, so expired deleted_record partitions are kept forever; set DELETED_RECORD_DROP_UNARCHIVED=true or an archive bucket")
    end
  end

  def runtime_token
    if Config.clover_runtime_token_secret
      ok("CLOVER_RUNTIME_TOKEN_SECRET is set")
    else
      warning("CLOVER_RUNTIME_TOKEN_SECRET is unset, so VM runtime tokens cannot be signed")
    end
  end

  def writability
    var = File.join(@root, "var")
    results = []
    results << if File.directory?(var) && File.writable?(var)
      ok("#{var} is writable")
    else
      failure("#{var} is not a directory that uid #{Process.euid} can write; CA bundles and API metrics are written there")
    end
    results.concat(code_ownership) if @production
    results
  end

  # Walks the release, skipping var/ (runtime state, a symlink to
  # /var/lib/ubicloud in the packaged layout), for entries a service user
  # could change: not owned by @code_owner, or writable by group or
  # others. Symlinks are not followed, and only their owner counts since
  # their own mode is never used.
  def code_ownership
    root = File.realpath(@root)
    var = File.join(root, "var")
    loose = []
    Find.find(root) do |path|
      Find.prune if path == var
      stat = File.lstat(path)
      loose << path if stat.uid != @code_owner || (!stat.symlink? && stat.mode & 0o022 != 0)
    end
    return [] if loose.empty?
    [warning("#{loose.size} entries under #{root} are not owned by uid #{@code_owner} or are writable by group or others, first #{loose.first}; production code should be root:root and go-w so a compromised service cannot change it")]
  end

  def role_isolation
    facts = role_facts
    role = facts[:role]
    results = []
    if facts[:superuser]
      results << failure("database role #{role} is a superuser, which bypasses the password-hash isolation; run the services as a non-superuser role")
    else
      case facts[:ph_member]
      when nil then results << failure("database role #{role}_password does not exist; password hashes are not isolated")
      when true then results << failure("database role #{role} is a member of #{role}_password, so it can read password hashes")
      end
      HASH_TABLES.each_with_index do |table, i|
        case facts[:"table#{i}"]
        when nil then results << failure("table #{table} does not exist")
        when true then results << failure("database role #{role} can SELECT #{table}")
        end
      end
      # A superuser has every attribute, so these would only repeat it.
      ROLE_ATTRIBUTES.each do |key, attribute|
        results << warning("database role #{role} has #{attribute}, which the services never need; ALTER ROLE #{role} NO#{attribute}") if facts[key]
      end
    end
    HASH_FUNCTIONS.each_with_index do |function, i|
      case facts[:"function#{i}"]
      when nil then results << failure("function #{function} does not exist")
      when true then results << failure("PUBLIC can execute #{function}")
      end
    end
    if results.empty?
      [ok("database role #{role}: not a superuser, not in #{role}_password, no SELECT on #{HASH_TABLES.join(", ")}, PUBLIC cannot execute the rodauth hash functions, no #{ROLE_ATTRIBUTES.values.join("/")}")]
    else
      results
    end
  end

  def partition_runway(tables = PARTITIONED_TABLES)
    bounds = DB.fetch(<<~SQL, Sequel.pg_array(tables, :text)).all.group_by { it[:parent] }
      SELECT p.relname::text AS parent, pg_get_expr(c.relpartbound, c.oid) AS bound
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      WHERE p.relname = ANY(?) AND p.relnamespace = 'public'::regnamespace
    SQL

    tables.map do |table|
      exprs = (bounds[table] || []).map { it[:bound] }
      if exprs.include?("DEFAULT")
        next ok("#{table} has a DEFAULT partition")
      elsif exprs.any? { it.include?("MAXVALUE") }
        next ok("#{table} has an unbounded partition")
      end

      ends = exprs.filter_map { (m = /\bTO \('([^']+)'\)/.match(it)) && Time.parse(m[1]) }
      next failure("#{table} has no partitions, so every insert fails") if ends.empty?

      last = ends.max
      days = ((last - @now) / 86400).floor
      message = "#{table} partitions end #{last.utc.strftime("%Y-%m-%d")} (#{days} days); inserts fail after that, so add partitions (an upstream merge brings them) before then"
      if days < RUNWAY_FAIL_DAYS
        failure(message)
      elsif days < RUNWAY_WARN_DAYS
        warning(message)
      else
        ok("#{table} partitions end #{last.utc.strftime("%Y-%m-%d")} (#{days} days)")
      end
    end
  end
end
