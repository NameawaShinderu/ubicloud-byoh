# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohConfigCheck do
  let(:code_root) { Dir.mktmpdir }
  let(:check_env) { {"MAIL_DRIVER" => "smtp", "MAIL_FROM" => "ops@example.com", "BIND" => "127.0.0.1"} }
  let(:check_now) { Time.utc(2026, 1, 1) }
  let(:preflight) { class_double(ByohPreflightWarnings, warnings: []) }
  let(:checker) { new_checker }

  # The isolated role facts of a correctly set-up control plane.
  let(:isolated) {
    {role: "ubicloud", superuser: false, createrole: false, createdb: false, bypassrls: false, ph_member: false}
      .merge(described_class::HASH_TABLES.each_index.to_h { [:"table#{it}", false] })
      .merge(described_class::HASH_FUNCTIONS.each_index.to_h { [:"function#{it}", false] })
  }
  let(:isolated_ok) { "database role ubicloud: not a superuser, not in ubicloud_password, no SELECT on account_password_hashes, account_previous_password_hashes, admin_password_hash, PUBLIC cannot execute the rodauth hash functions, no CREATEROLE/CREATEDB/BYPASSRLS" }

  # Every table and function fact set to value.
  def all_hash_facts(value)
    isolated.to_h { |k, v| [k, k.match?(/\A(table|function)\d+\z/) ? value : v] }
  end

  # The role facts that checkers made by new_checker report; nil queries
  # the real database.
  def stub_role_facts(facts)
    @role_facts = facts
  end

  def new_checker(**)
    checker = described_class.new(env: check_env, root: code_root, code_owner: Process.euid, now: check_now, preflight:, **)
    allow(checker).to receive(:role_facts).and_wrap_original { |original| @role_facts || original.call }
    checker
  end

  def messages(results, level)
    results.select { it.level == level }.map(&:message)
  end

  # A configuration with nothing to report besides the role and partition
  # checks.
  def stub_good_config
    allow(Config).to receive_messages(
      pry_allow_unaudited: false, base_url: "https://cloud.example.com", ip_from_header: "X-Real-IP", mail_driver: :smtp, mail_from: "ops@example.com",
      smtp_hostname: "smtp.example.com", boot_image_source: "public", billing_rates_extra_dir: nil, db_pool_web: 16,
      deleted_record_archive_bucket: nil, deleted_record_drop_unarchived: true, clover_runtime_token_secret: "secret",
    )
    FileUtils.mkdir_p(File.join(code_root, "var"))
    File.chmod(0o755, code_root)
    stub_role_facts(isolated)
  end

  after { FileUtils.rm_rf(code_root) }

  describe "#run" do
    it "prints every result and exits 0 without a failure" do
      stub_good_config
      out = StringIO.new
      expect(new_checker(out:).run([])).to eq 0
      expect(out.string).to include "ok   preflight: no BYOH warnings\n", "ok   #{isolated_ok}\n", "ok   audit_log partitions end 2027-01-01 (365 days)\n"
      expect(out.string.lines.map { it[0, 5] }.uniq).to eq ["ok   "]
    end

    it "exits 1 when a check fails" do
      stub_good_config
      allow(Config).to receive(:db_pool_web).and_return(4)
      stub_role_facts(isolated.merge(superuser: true))
      out = StringIO.new
      expect(new_checker(out:).run([])).to eq 1
      expect(out.string).to include "warn DB_POOL_WEB is 4, but puma runs 15 threads; set it to at least 16\n", "fail database role ubicloud is a superuser"
    end

    it "simulates production" do
      stub_good_config
      allow(Config).to receive(:base_url).and_return("http://cloud.example.com")
      out = StringIO.new
      expect(new_checker(out:).run([])).to eq 0
      expect(new_checker(out:).run(["--simulate-production"])).to eq 1
      expect(out.string).to include "fail BASE_URL http://cloud.example.com is http"
    end

    it "refuses unknown options and arguments" do
      err = StringIO.new
      expect(described_class.new(err:).run(["--bogus"])).to eq 2
      expect(described_class.new(err:).run(["extra"])).to eq 2
      expect(err.string).to eq "! invalid option: --bogus\n#{described_class::USAGE}\n! invalid argument: extra\n#{described_class::USAGE}\n"
    end
  end

  describe "#check" do
    before { stub_good_config }

    it "uses ByohPreflightWarnings by default" do
      allow(Config).to receive_messages(base_url: "http://localhost:9292", control_plane_outbound_cidrs: [])
      checker = described_class.new(env: check_env, root: code_root, code_owner: Process.euid, now: check_now)
      allow(checker).to receive(:role_facts).and_return(isolated)
      results = checker.check(production: false)
      expect(messages(results, "warn")).to eq ["BASE_URL is http://localhost:9292; set it to the URL customers use to reach this control plane"]
    end

    it "reports every BYOH preflight warning as a warning" do
      allow(preflight).to receive(:warnings).and_return(["one", "two"])
      results = checker.check(production: false)
      expect(messages(results, "warn")).to eq ["one", "two"]
      expect(messages(results, "ok")).not_to include "preflight: no BYOH warnings"
    end

    it "warns about PRY_ALLOW_UNAUDITED, and fails on it in production" do
      allow(Config).to receive(:pry_allow_unaudited).and_return(true)
      message = "PRY_ALLOW_UNAUDITED is set for every process; set it only in the environment of ubicloud-admin console"
      expect(messages(checker.check(production: false), "warn")).to eq [message]
      expect(messages(checker.check(production: true), "fail")).to eq [message]
    end

    it "checks BASE_URL only in production, allowing http only for localhost" do
      allow(Config).to receive(:base_url).and_return("http://cloud.example.com")
      expect(checker.check(production: false).map(&:message).grep(/BASE_URL/)).to eq []
      expect(messages(checker.check(production: true), "fail")).to eq ["BASE_URL http://cloud.example.com is http, but production cookies are Secure, so browsers drop them and login fails; use https"]

      ["http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000", "https://cloud.example.com"].each do |url|
        allow(Config).to receive(:base_url).and_return(url)
        expect(messages(checker.check(production: true), "ok")).to include "BASE_URL #{url}"
      end
    end

    it "fails on a BASE_URL that is not an http or https URL, and still runs every other check" do
      allow(Config).to receive(:base_url).and_return("https://cloud example.com")
      out = StringIO.new
      expect(new_checker(out:).run(["--simulate-production"])).to eq 1
      expect(out.string).to include "fail BASE_URL \"https://cloud example.com\" is not a valid URL\n", "ok   DB_POOL_WEB is 16\n"

      ["cloud.example.com", "ftp://cloud.example.com", "https:///path"].each do |url|
        allow(Config).to receive(:base_url).and_return(url)
        expect(messages(checker.check(production: true), "fail")).to eq ["BASE_URL #{url.inspect} is not an http or https URL with a host, such as https://cloud.example.com"]
      end
    end

    describe "client IP" do
      it "accepts a header when puma binds a loopback address" do
        ["127.0.0.1", "127.0.0.2", "::1", "[::1]", "localhost"].each do |bind|
          check_env["BIND"] = bind
          expect(messages(checker.check(production: true), "ok")).to include "client IP: from the X-Real-IP header; puma binds #{bind}, so only the local TLS front can set it"
        end
      end

      it "warns about a header when puma binds every address, and fails on it in production" do
        message = "IP_FROM_HEADER is X-Real-IP but puma binds 0.0.0.0, so any client that reaches puma directly sets its own audit-log IP; set BIND=127.0.0.1"
        check_env.delete("BIND")
        expect(messages(checker.check(production: false), "warn")).to eq [message]
        expect(messages(checker.check(production: true), "fail")).to eq [message]
        check_env["BIND"] = "cp.example.com"
        expect(messages(checker.check(production: true), "fail")).to eq [message.sub("0.0.0.0", "cp.example.com")]
      end

      it "warns without a header behind https" do
        allow(Config).to receive(:ip_from_header).and_return(nil)
        expect(messages(checker.check(production: true), "warn")).to eq ["IP_FROM_HEADER is unset, so behind a TLS front the audit logs record the front's address; set it to X-Real-IP (Caddy) or CF-Connecting-IP (cloudflared)"]
      end

      it "takes the address from the connection without a header for http" do
        allow(Config).to receive_messages(ip_from_header: nil, base_url: "http://localhost:3000")
        expect(messages(checker.check(production: true), "ok")).to include "client IP: from the connection (no TLS front)"
      end
    end

    describe "mail" do
      it "only reports the driver outside production" do
        allow(Config).to receive_messages(mail_driver: :logger, mail_from: nil)
        expect(checker.check(production: false)).to include described_class::Result.new("ok", "mail: driver logger, not production")
      end

      it "accepts smtp with a sender and host" do
        expect(messages(checker.check(production: true), "ok")).to include "mail: driver smtp, from ops@example.com"
      end

      it "fails without a sender or SMTP host" do
        allow(Config).to receive_messages(mail_from: nil, smtp_hostname: nil)
        expect(messages(checker.check(production: true), "fail")).to eq ["MAIL_FROM is unset; production needs a sender address for account and alert mail", "MAIL_DRIVER is smtp but SMTP_HOSTNAME is unset"]
      end

      it "warns that the logger driver puts links in the journal" do
        allow(Config).to receive(:mail_driver).and_return(:logger)
        expect(messages(checker.check(production: true), "warn")).to eq ["MAIL_DRIVER is logger: verification and reset links land in journald, readable by the adm and systemd-journal groups"]
      end

      it "accepts another driver" do
        allow(Config).to receive(:mail_driver).and_return(:test)
        expect(messages(checker.check(production: true), "ok")).to include "mail: driver test, from ops@example.com"
      end

      it "uses the production defaults for unset variables when simulating production" do
        check_env.delete("MAIL_DRIVER")
        check_env.delete("MAIL_FROM")
        allow(Config).to receive_messages(mail_driver: :logger, mail_from: "dev@example.com", smtp_hostname: nil)
        expect(messages(checker.check(production: true), "fail")).to eq ["MAIL_FROM is unset; production needs a sender address for account and alert mail", "MAIL_DRIVER is smtp but SMTP_HOSTNAME is unset"]

        check_env.merge!("MAIL_DRIVER" => "logger", "MAIL_FROM" => "dev@example.com")
        expect(messages(checker.check(production: true), "warn")).to eq ["MAIL_DRIVER is logger: verification and reset links land in journald, readable by the adm and systemd-journal groups"]
        expect(messages(checker.check(production: true), "fail")).to eq []
      end

      it "uses the configured values when RACK_ENV is production" do
        allow(Config).to receive_messages(production?: true, mail_driver: :logger, mail_from: "ops@example.com")
        expect(messages(checker.check(production: true), "warn")).to include(/MAIL_DRIVER is logger/)
        expect(messages(checker.check(production: true), "fail")).to eq []
      end
    end

    describe "boot images" do
      it "reports the source outside production and the public mirrors in production" do
        allow(Config).to receive(:boot_image_source).and_return("auto")
        expect(messages(checker.check(production: false), "ok")).to include "boot images: BOOT_IMAGE_SOURCE=auto, not production"
        allow(Config).to receive(:boot_image_source).and_return("public")
        expect(messages(checker.check(production: true), "ok")).to include "boot images: public upstream mirrors"
      end

      it "fails for auto in production unless every R2 setting is present" do
        allow(Config).to receive_messages(boot_image_source: "auto", ubicloud_images_r2_bucket_name: "b", ubicloud_images_r2_endpoint: "https://r2", ubicloud_images_r2_access_key: "a", ubicloud_images_r2_secret_key: nil)
        expect(messages(checker.check(production: true), "fail")).to eq ["BOOT_IMAGE_SOURCE=auto fetches every boot image from Ubicloud's R2 storage in production, but UBICLOUD_IMAGES_R2_* are not all set; set BOOT_IMAGE_SOURCE=public"]
        allow(Config).to receive(:ubicloud_images_r2_secret_key).and_return("s")
        expect(messages(checker.check(production: true), "ok")).to include "boot images: Ubicloud R2 storage"
      end
    end

    it "checks that BILLING_RATES_EXTRA_DIR is a readable and writable directory" do
      dir = File.join(code_root, "rates")
      allow(Config).to receive(:billing_rates_extra_dir).and_return(dir)
      expect(messages(checker.check(production: false), "fail")).to eq ["BILLING_RATES_EXTRA_DIR #{dir} is not a directory that uid #{Process.euid} can read and write; byoh-location writes rates there"]
      Dir.mkdir(dir)
      expect(messages(checker.check(production: false), "ok")).to include "BILLING_RATES_EXTRA_DIR #{dir} is readable and writable"
    end

    it "reports how deleted records are handled" do
      allow(Config).to receive(:deleted_record_drop_unarchived).and_return(false)
      expect(messages(checker.check(production: false), "ok")).to include "deleted records: expired partitions are dropped unarchived"
      expect(messages(checker.check(production: true), "warn")).to eq ["deleted records: no DELETED_RECORD_ARCHIVE_BUCKET, so expired deleted_record partitions are kept forever; set DELETED_RECORD_DROP_UNARCHIVED=true or an archive bucket"]
      allow(Config).to receive(:deleted_record_drop_unarchived).and_return(true)
      expect(messages(checker.check(production: true), "ok")).to include "deleted records: expired partitions are dropped unarchived"
      allow(Config).to receive(:deleted_record_archive_bucket).and_return("archive")
      expect(messages(checker.check(production: true), "ok")).to include "deleted records: archived to archive"
    end

    it "warns without CLOVER_RUNTIME_TOKEN_SECRET" do
      allow(Config).to receive(:clover_runtime_token_secret).and_return(nil)
      expect(messages(checker.check(production: false), "warn")).to eq ["CLOVER_RUNTIME_TOKEN_SECRET is unset, so VM runtime tokens cannot be signed"]
    end

    it "fails without a writable var directory" do
      FileUtils.rm_rf(File.join(code_root, "var"))
      expect(messages(checker.check(production: false), "fail")).to eq ["#{code_root}/var is not a directory that uid #{Process.euid} can write; CA bundles and API metrics are written there"]
      FileUtils.mkdir_p(File.join(code_root, "var"))
      expect(messages(checker.check(production: false), "ok")).to include "#{code_root}/var is writable"
    end

    describe "code ownership in production" do
      # The specs run as any uid, so the expected owner is the runner's.
      let(:tree) { File.realpath(code_root) }

      def ownership_warnings(chk = checker)
        messages(chk.check(production: true), "warn")
      end

      def loose_warning(count, first, owner: Process.euid)
        "#{count} entries under #{tree} are not owned by uid #{owner} or are writable by group or others, first #{first}; production code should be root:root and go-w so a compromised service cannot change it"
      end

      before do
        FileUtils.mkdir_p(File.join(code_root, "lib", "deep"))
        File.write(File.join(code_root, "lib", "deep", "code.rb"), "")
        File.chmod(0o644, File.join(code_root, "lib", "deep", "code.rb"))
        File.chmod(0o755, File.join(code_root, "lib"))
        File.chmod(0o755, File.join(code_root, "lib", "deep"))
        File.chmod(0o777, File.join(code_root, "var"))
        File.write(File.join(code_root, "var", "loose"), "")
        File.chmod(0o666, File.join(code_root, "var", "loose"))
        File.symlink("lib/deep/code.rb", File.join(code_root, "link"))
      end

      it "accepts a tree owned by the code owner and not writable by others, ignoring var/ and symlink modes" do
        expect(ownership_warnings).to eq []
        expect(messages(checker.check(production: false), "warn")).to eq []
      end

      it "warns about a group- or world-writable entry anywhere in the tree" do
        File.chmod(0o666, File.join(code_root, "lib", "deep", "code.rb"))
        expect(ownership_warnings).to eq [loose_warning(1, "#{tree}/lib/deep/code.rb")]
        File.chmod(0o775, File.join(code_root, "lib"))
        expect(ownership_warnings).to eq [loose_warning(2, "#{tree}/lib")]
        File.chmod(0o775, code_root)
        expect(ownership_warnings).to eq [loose_warning(3, tree)]
      end

      it "warns about entries owned by another uid, symlinks included" do
        other = Process.euid + 1
        expect(ownership_warnings(new_checker(code_owner: other))).to eq [loose_warning(5, tree, owner: other)]
      end

      it "walks the release behind a symlinked root" do
        Dir.mktmpdir do |dir|
          current = File.join(dir, "current")
          File.symlink(code_root, current)
          File.chmod(0o666, File.join(code_root, "lib", "deep", "code.rb"))
          expect(ownership_warnings(new_checker(root: current))).to eq [loose_warning(1, "#{tree}/lib/deep/code.rb")]
        end
      end
    end
  end

  describe "role isolation" do
    before { stub_good_config }

    def role_messages(facts = nil)
      stub_role_facts(facts) if facts
      checker.check(production: false).select { /role|function|table |PUBLIC/.match?(it.message) }.map { [it.level, it.message] }
    end

    it "queries the real database, where the test role is a superuser" do
      stub_role_facts(nil)
      expect(role_messages).to eq [["fail", "database role clover is a superuser, which bypasses the password-hash isolation; run the services as a non-superuser role"]]
    end

    it "is ok for an isolated role" do
      expect(role_messages).to eq [["ok", isolated_ok]]
    end

    it "fails on membership of the password role and on readable hashes" do
      expect(role_messages(all_hash_facts(true).merge(ph_member: true))).to eq [
        ["fail", "database role ubicloud is a member of ubicloud_password, so it can read password hashes"],
        ["fail", "database role ubicloud can SELECT account_password_hashes"],
        ["fail", "database role ubicloud can SELECT account_previous_password_hashes"],
        ["fail", "database role ubicloud can SELECT admin_password_hash"],
        ["fail", "PUBLIC can execute rodauth_get_salt(uuid)"],
        ["fail", "PUBLIC can execute rodauth_valid_password_hash(uuid,text)"],
        ["fail", "PUBLIC can execute rodauth_get_previous_salt(uuid)"],
        ["fail", "PUBLIC can execute rodauth_previous_password_hash_match(uuid,text)"],
        ["fail", "PUBLIC can execute rodauth_admin_get_salt(uuid)"],
        ["fail", "PUBLIC can execute rodauth_admin_valid_password_hash(uuid,text)"],
      ]
    end

    it "fails when the password role, tables or functions are missing" do
      expect(role_messages(all_hash_facts(nil).merge(ph_member: nil))).to eq [
        ["fail", "database role ubicloud_password does not exist; password hashes are not isolated"],
        ["fail", "table account_password_hashes does not exist"],
        ["fail", "table account_previous_password_hashes does not exist"],
        ["fail", "table admin_password_hash does not exist"],
        *described_class::HASH_FUNCTIONS.map { ["fail", "function #{it} does not exist"] },
      ]
    end

    it "warns about role attributes the services never need" do
      expect(role_messages(isolated.merge(createrole: true, createdb: true, bypassrls: true))).to eq %w[CREATEROLE CREATEDB BYPASSRLS].map {
        ["warn", "database role ubicloud has #{it}, which the services never need; ALTER ROLE ubicloud NO#{it}"]
      }
    end

    it "checks every table and function the ph migrations protect against the real database" do
      stub_role_facts(nil)
      facts = checker.role_facts
      expect(facts[:superuser]).to be true
      expect(facts.keys).to eq isolated.keys
      expect(facts.values_at(*isolated.keys.grep(/\A(table|function)\d+\z/))).to all(be(true).or(be(false)))
    end
  end

  describe "partition runway" do
    before { stub_good_config }

    def runway(at)
      new_checker(now: at).check(production: false).select { it.message.include?(" partitions end ") }.map { [it.level, it.message] }
    end

    it "warns 90 days before the audit partitions end" do
      expect(runway(Time.utc(2026, 10, 14))).to eq described_class::PARTITIONED_TABLES.map {
        ["warn", "#{it} partitions end 2027-01-01 (79 days); inserts fail after that, so add partitions (an upstream merge brings them) before then"]
      }
    end

    it "fails 30 days before the audit partitions end" do
      expect(runway(Time.utc(2026, 12, 15)).map(&:first)).to eq ["fail"] * 3
      expect(runway(Time.utc(2026, 12, 15))[0][1]).to start_with "audit_log partitions end 2027-01-01 (17 days)"
    end

    it "accepts a DEFAULT or unbounded partition and fails without partitions" do
      DB.run "CREATE TABLE byoh_cc_default (at timestamptz NOT NULL) PARTITION BY RANGE (at)"
      DB.run "CREATE TABLE byoh_cc_default_d PARTITION OF byoh_cc_default DEFAULT"
      DB.run "CREATE TABLE byoh_cc_open (at timestamptz NOT NULL) PARTITION BY RANGE (at)"
      DB.run "CREATE TABLE byoh_cc_open_1 PARTITION OF byoh_cc_open FOR VALUES FROM ('2026-01-01') TO (MAXVALUE)"
      DB.run "CREATE TABLE byoh_cc_none (at timestamptz NOT NULL) PARTITION BY RANGE (at)"
      DB.run "CREATE TABLE byoh_cc_plain (at timestamp NOT NULL) PARTITION BY RANGE (at)"
      DB.run "CREATE TABLE byoh_cc_plain_1 PARTITION OF byoh_cc_plain FOR VALUES FROM ('2026-01-01') TO ('2027-06-01')"

      results = checker.send(:partition_runway, %w[byoh_cc_default byoh_cc_open byoh_cc_none byoh_cc_plain byoh_cc_missing])
      expect(results.map { [it.level, it.message] }).to eq [
        ["ok", "byoh_cc_default has a DEFAULT partition"],
        ["ok", "byoh_cc_open has an unbounded partition"],
        ["fail", "byoh_cc_none has no partitions, so every insert fails"],
        ["ok", "byoh_cc_plain partitions end 2027-06-01 (516 days)"],
        ["fail", "byoh_cc_missing has no partitions, so every insert fails"],
      ]
    end
  end
end
