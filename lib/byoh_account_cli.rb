# frozen_string_literal: true

require "argon2"
require "optparse"
require "securerandom"

# bin/byoh-account: creates verified customer accounts without email, for
# a control plane whose mail is not set up yet, and lists accounts. Admin
# accounts come from the upstream create_prod_admin_account task instead.
class ByohAccountCli
  class Error < StandardError; end

  USAGE = <<~USAGE
    Usage: bin/byoh-account COMMAND [options]

    Commands:
      create   --email EMAIL [--name NAME] [--project NAME]
               [--password-stdin | --password-file FILE]
      list

    Without a password option, create generates one and prints it once.
  USAGE

  # The accounts.valid_email check constraint.
  EMAIL_FORMAT = /\A[^,;@ \r\n]+@[^,@; \r\n]+\.[^,@; \r\n]+\z/

  # The floor in every environment: clover.rb's password_minimum_length
  # (characters) and password_maximum_bytes. Outside development signup
  # also wants a lowercase letter, an uppercase letter, a digit and no
  # common password; password_problem asks Clover's Rodauth for those.
  PASSWORD_MIN_CHARS = 8
  PASSWORD_MAX_BYTES = 72

  # Rodauth's production argon2 cost, so a CLI-made hash is as strong as
  # one made by signing up.
  HASH_COST = {t_cost: 2, m_cost: 16, p_cost: 1}.freeze

  # account_statuses: 1 unverified, 2 verified, 3 closed.
  VERIFIED = 2
  STATUS_NAMES = {1 => "pending", 2 => "verified"}.freeze

  # The account name when --name is not given and the email's local part
  # is not a valid name.
  DEFAULT_NAME = "Ubicloud User"

  LIST_ROW = "%-26s %-8s %-20s %s"

  def initialize(out: $stdout, err: $stderr, stdin: $stdin, random: SecureRandom)
    @out = out
    @err = err
    @stdin = stdin
    @random = random
  end

  # Returns the process exit status.
  def run(argv)
    argv = argv.dup
    command = argv.shift
    case command
    when "create", "list"
      send(:"cmd_#{command}", argv)
    when nil, "help", "-h", "--help"
      @out.puts USAGE
    else
      raise Error, "unknown command #{command}\n#{USAGE}"
    end
    0
  rescue Error, OptionParser::ParseError => e
    @err.puts "! #{e.message}"
    1
  end

  private

  def cmd_create(argv)
    opts = {project: "Default"}
    parse(argv, "create --email EMAIL [options]") do |o|
      o.on("--email EMAIL", "Login email of the account") { opts[:email] = it }
      o.on("--name NAME", "Name shown in the console (default: from the email)") { opts[:name] = it }
      o.on("--project NAME", "Name of the account's first project (default: Default)") { opts[:project] = it }
      o.on("--password-stdin", "Read the password from the first line of stdin") { opts[:password_stdin] = true }
      o.on("--password-file FILE", "Read the password from the first line of FILE") { opts[:password_file] = it }
    end

    email = opts[:email] || raise(Error, "--email is required")
    raise Error, "--email #{email} is not a valid email address" unless EMAIL_FORMAT.match?(email)
    raise Error, "give only one of --password-stdin and --password-file" if opts[:password_stdin] && opts[:password_file]

    if (name = opts[:name])
      unless Validation::ALLOWED_ACCOUNT_NAME.match?(name)
        raise Error, "--name #{name.inspect} must start with a letter and have 2 to 63 letters, digits, spaces or hyphens"
      end
    else
      name = email.split("@").first.gsub(/[^\p{L}0-9-]+/, " ").strip
      name = DEFAULT_NAME unless Validation::ALLOWED_ACCOUNT_NAME.match?(name)
    end

    password, generated = read_password(opts)
    if (problem = password_problem(password))
      raise Error, "the password does not meet the signup requirements: #{problem}"
    end

    hash = Argon2::Password.new(**HASH_COST, secret: Config.clover_session_secret).create(password)
    account = create_account(email:, name:, hash:, opts:)

    @out.puts "Created account #{account.ubid} (#{email}) with project #{account.default_project.ubid} (#{opts[:project]})."
    @out.puts "Password: #{password}" if generated
  end

  # The accounts unique index on open accounts' emails (case-insensitive)
  # refuses a duplicate atomically, so concurrent creates cannot both
  # win; the model reports it as "email is already taken".
  def create_account(email:, name:, hash:, opts:)
    DB.transaction do
      account = Account.create(email:, name:, status_id: VERIFIED)
      DB[:account_password_hashes].insert(id: account.id, password_hash: hash)
      begin
        account.default_project = account.create_project_with_default_policy(opts[:project])
      rescue Sequel::ValidationFailed => e
        raise Error, "--project #{opts[:project]}: #{e.message}"
      end
      ByohOperatorLog.record(command: "byoh-account create", target_id: account.id, args: {"email" => email, "project" => opts[:project]}, result: "ok")
      account
    end
  rescue Sequel::ValidationFailed => e
    raise Error, "cannot create account #{email}: #{e.message}"
  end

  def cmd_list(argv)
    parse(argv, "list")
    accounts = Account.order(:created_at, :email).all
    if accounts.empty?
      @out.puts "No accounts."
      return
    end

    @out.puts format(LIST_ROW, "ID", "STATUS", "CREATED", "EMAIL")
    accounts.each do |account|
      status = STATUS_NAMES.fetch(account.status_id, "closed")
      status = "suspended" if account.suspended_at
      @out.puts format(LIST_ROW, account.ubid, status, account.created_at.utc.strftime("%Y-%m-%d %H:%M UTC"), account.email)
    end
  end

  # Returns the password and whether it was generated.
  def read_password(opts)
    if opts[:password_stdin]
      [first_line(@stdin.gets, "stdin"), false]
    elsif (file = opts[:password_file])
      line = begin
        File.open(file, &:gets)
      rescue SystemCallError => e
        raise Error, "cannot read --password-file: #{e.message}"
      end
      [first_line(line, file), false]
    else
      # A random password can lack a digit or a case.
      password = nil
      password = @random.urlsafe_base64(18) while password.nil? || password_problem(password)
      [password, true]
    end
  end

  # Returns why signup would refuse password, or nil.
  def password_problem(password)
    if password.length < PASSWORD_MIN_CHARS || password.bytesize > PASSWORD_MAX_BYTES
      return "it must have at least #{PASSWORD_MIN_CHARS} characters and at most #{PASSWORD_MAX_BYTES} bytes"
    end
    rodauth = Clover.rodauth.new(Clover.allocate)
    return if rodauth.password_meets_requirements?(password)
    rodauth.send(:password_requirement_message) || rodauth.send(:password_does_not_meet_requirements_message)
  end

  def first_line(line, source)
    raise Error, "no password in #{source}" if line.nil?
    line.chomp
  end

  def parse(argv, banner)
    parser = OptionParser.new do |o|
      o.banner = "Usage: bin/byoh-account #{banner}"
      yield o if block_given?
    end
    rest = parser.parse(argv)
    raise Error, "unexpected argument #{rest.first}" unless rest.empty?
  end
end
