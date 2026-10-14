# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ByohAccountCli do
  let(:random) { class_double(SecureRandom, urlsafe_base64: "Generated-password-1") }

  # Runs one command; returns its exit status, stdout and stderr.
  def cli(*argv, stdin: "")
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(out:, err:, stdin: StringIO.new(stdin), random:).run(argv)
    [status, out.string, err.string]
  end

  def password_hash(account)
    DB[:account_password_hashes].where(id: account.id).get(:password_hash)
  end

  def verify(account, password)
    Argon2::Password.verify_password(password, password_hash(account), Config.clover_session_secret)
  end

  describe "#run" do
    it "prints the usage without a command" do
      expect(cli).to eq [0, described_class::USAGE, ""]
      expect(cli("help")[0]).to eq 0
    end

    it "refuses an unknown command, unknown options and extra arguments" do
      status, _, error = cli("frobnicate")
      expect(status).to eq 1
      expect(error).to start_with "! unknown command frobnicate\nUsage:"

      expect(cli("list", "--bogus")).to eq [1, "", "! invalid option: --bogus\n"]
      expect(cli("list", "extra")).to eq [1, "", "! unexpected argument extra\n"]
    end
  end

  describe "create" do
    it "creates a verified account with a generated password, a project and an audit row" do
      status, out, err = cli("create", "--email", "ops.team@example.com")
      expect([status, err]).to eq [0, ""]

      account = Account.first(email: "ops.team@example.com")
      expect(account.status_id).to eq 2
      expect(account.name).to eq "ops team"
      project = account.default_project
      expect(project.name).to eq "Default"
      expect(account.projects.map(&:id)).to eq [project.id]
      expect(DB[:access_control_entry].where(project_id: project.id).count).to eq 2
      expect(verify(account, "Generated-password-1")).to be true
      expect(password_hash(account)).to start_with "$argon2id$v=19$m=65536,t=2,p=1$"
      expect(out).to eq "Created account #{account.ubid} (ops.team@example.com) with project #{project.ubid} (Default).\nPassword: Generated-password-1\n"

      row = DB[:byoh_operator_action].first(target_id: account.id)
      expect(row[:command]).to eq "byoh-account create"
      expect(row[:args].to_h).to eq("email" => "ops.team@example.com", "project" => "Default")
    end

    it "reads the password from stdin and takes a name and project" do
      status, out, = cli("create", "--email", "a@example.com", "--name", "Alice Ops", "--project", "team-a", "--password-stdin", stdin: "Correct horse 1\nignored\n")
      expect(status).to eq 0
      expect(out).not_to include "Password"

      account = Account.first(email: "a@example.com")
      expect(account.name).to eq "Alice Ops"
      expect(account.default_project.name).to eq "team-a"
      expect(verify(account, "Correct horse 1")).to be true
      expect(verify(account, "Correct horse 1\n")).to be false
    end

    it "reads the password from the first line of a file" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "pw")
        File.write(file, "File-password-1\n")
        expect(cli("create", "--email", "b@example.com", "--password-file", file)[0]).to eq 0
        account = Account.first(email: "b@example.com")
        expect(verify(account, "File-password-1")).to be true
        expect(account.name).to eq "Ubicloud User"

        expect(cli("create", "--email", "c@example.com", "--password-file", File.join(dir, "missing"))).to eq [1, "", "! cannot read --password-file: No such file or directory @ rb_sysopen - #{dir}/missing\n"]

        File.write(file, "")
        expect(cli("create", "--email", "c@example.com", "--password-file", file)).to eq [1, "", "! no password in #{file}\n"]
      end
      expect(cli("create", "--email", "c@example.com", "--password-stdin")).to eq [1, "", "! no password in stdin\n"]
      expect(Account.where(email: "c@example.com").count).to eq 0
    end

    it "refuses an existing email, case-insensitively, but allows reusing a closed account's email" do
      expect(cli("create", "--email", "dup@example.com")[0]).to eq 0
      expect(cli("create", "--email", "DUP@example.com")).to eq [1, "", "! cannot create account DUP@example.com: email is already taken\n"]
      expect(Account.where(email: "dup@example.com").count).to eq 1
      expect(DB[:byoh_operator_action].count).to eq 1
      expect(DB[:account_password_hashes].count).to eq 1

      Account.create(email: "pending@example.com", status_id: 1)
      expect(cli("create", "--email", "pending@example.com")).to eq [1, "", "! cannot create account pending@example.com: email is already taken\n"]

      Account.first(email: "dup@example.com").update(status_id: 3)
      expect(cli("create", "--email", "dup@example.com")[0]).to eq 0
    end

    it "validates its options before writing anything" do
      expect(cli("create")).to eq [1, "", "! --email is required\n"]
      expect(cli("create", "--email", "not-an-email")).to eq [1, "", "! --email not-an-email is not a valid email address\n"]
      expect(cli("create", "--email", "d@example.com", "--password-stdin", "--password-file", "f")).to eq [1, "", "! give only one of --password-stdin and --password-file\n"]
      expect(cli("create", "--email", "d@example.com", "--name", "1")).to eq [1, "", "! --name \"1\" must start with a letter and have 2 to 63 letters, digits, spaces or hyphens\n"]
      length = "! the password does not meet the signup requirements: it must have at least 8 characters and at most 72 bytes\n"
      expect(cli("create", "--email", "d@example.com", "--password-stdin", stdin: "Short1\n")).to eq [1, "", length]
      expect(cli("create", "--email", "d@example.com", "--password-stdin", stdin: "Xy1" * 25)).to eq [1, "", length]
      # Three characters but nine bytes.
      expect(cli("create", "--email", "d@example.com", "--password-stdin", stdin: "\u20ac" * 3)).to eq [1, "", length]
      status, _, err = cli("create", "--email", "d@example.com", "--project", "bad name!")
      expect(status).to eq 1
      expect(err).to start_with "! --project bad name!: name must be less than 64 characters"
      expect(Account.where(email: "d@example.com").count).to eq 0
      expect(DB[:byoh_operator_action].count).to eq 0
    end
  end

  describe "password requirements" do
    # The test environment, like production, runs clover.rb's full
    # password policy.
    it "refuses what signup refuses: a common password, or one without a lowercase or uppercase letter or a digit" do
      expect(cli("create", "--email", "e@example.com", "--password-stdin", stdin: "Password1\n")).to eq [1, "", "! the password does not meet the signup requirements: is one of the most common passwords\n"]
      policy = "! the password does not meet the signup requirements: Password must have 8 characters minimum and contain at least one lowercase letter, one uppercase letter, and one digit. Password cannot be the same as your current password.\n"
      %w[aaaaaaaa1x AAAAAAAA1X aaaaAAAAxx \u00c4b\u00c7d\u00e9fg1].each do |weak|
        expect(cli("create", "--email", "e@example.com", "--password-stdin", stdin: "#{weak}\n")).to eq [1, "", policy]
      end
      expect(Account.where(email: "e@example.com").count).to eq 0
    end

    it "accepts a multibyte password of 8 characters" do
      expect(cli("create", "--email", "e@example.com", "--password-stdin", stdin: "\u00e9Abcdef1\n")[0]).to eq 0
      expect(verify(Account.first(email: "e@example.com"), "\u00e9Abcdef1")).to be true
    end

    it "generates passwords until one meets the requirements" do
      allow(random).to receive(:urlsafe_base64).and_return("short", "no-digits-or-upper-case", "Generated-password-1")
      status, out, = cli("create", "--email", "e@example.com")
      expect(status).to eq 0
      expect(out).to end_with "Password: Generated-password-1\n"
      expect(random).to have_received(:urlsafe_base64).with(18).exactly(3).times
    end
  end

  describe "list" do
    it "says when there are no accounts" do
      expect(cli("list")).to eq [0, "No accounts.\n", ""]
    end

    it "lists accounts with their status and never their hashes" do
      cli("create", "--email", "a@example.com")
      cli("create", "--email", "b@example.com")
      Account.create(email: "pending@example.com", status_id: 1)
      Account.first(email: "b@example.com").suspend
      closed = Account.create(email: "closed@example.com", status_id: 3)

      status, out, = cli("list")
      expect(status).to eq 0
      lines = out.lines
      expect(lines[0]).to match(/\AID +STATUS +CREATED +EMAIL\n\z/)
      statuses = lines.drop(1).to_h { [it.split.last, it.split[1]] }
      expect(statuses).to eq("a@example.com" => "verified", "b@example.com" => "suspended", "pending@example.com" => "pending", "closed@example.com" => "closed")
      expect(out).to include closed.ubid
      expect(out).not_to include "argon2"
    end
  end
end
