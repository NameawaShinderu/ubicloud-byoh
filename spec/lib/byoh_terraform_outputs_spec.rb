# frozen_string_literal: true

require "open3"
require "shellwords"
require "stringio"
require "tmpdir"

# terraform/aws-byoh prints commands that operators paste. Terraform is
# never run here, so these examples render the two command outputs the
# way terraform would for sample values and feed the commands to the
# tools that parse them.
# rubocop:disable RSpec/DescribeClass
RSpec.describe "terraform/aws-byoh outputs" do
  let(:tf_dir) { File.expand_path("../../terraform/aws-byoh", __dir__) }
  let(:outputs) { File.read(File.join(tf_dir, "outputs.tf")) }
  let(:values) {
    {
      "local.byoh_location_name" => "byoh-aws-canary",
      "var.aws_region" => "ap-south-1",
      "var.vpc_cidr" => "10.98.0.0/16",
      "local.byoh_overlay_ipv4_cidr" => "172.20.0.0/14",
      "aws_instance.ctrl.private_ip" => "10.98.1.10",
      "local.byoh_mgmt_allow" => "10.98.1.10/32,198.51.100.7/32",
      "local.byoh_rates_dir" => "/var/lib/ubicloud/billing_rates.d",
      "aws_instance.data.id" => "i-0123456789abcdef0",
      "aws_instance.data.private_ip" => "10.98.1.20",
      "aws_instance.data.public_ip" => "13.0.0.2",
      "local.ssh_key_file" => "./.generated/canary/byoh_ssh_key",
      "local_file.pools_yaml.filename" => "./.generated/canary/pools.yaml",
      "local.ctrl_login" => "ubuntu@13.0.0.1",
    }
  }
  let(:fingerprints) { ["SHA256:#{"a" * 43}", "SHA256:#{"B/+9" * 10}xyz"] }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  # The value of output NAME as terraform renders it: directive lines
  # dropped (the 0.0.0.0/0 warning is comments only), ${...} replaced.
  def render(name)
    block = outputs[/^output "#{name}" \{\n.*?^\}\n/m] || raise("no output #{name}")
    body = block[/value = <<-EOT\n(.*?)^\s*EOT\n/m, 1] || raise("no heredoc in #{name}")
    indent = body.lines.reject { it.strip.empty? }.map { it[/\A */].size }.min
    body.lines.map { it.sub(/\A {0,#{indent}}/, "") }.reject { it.start_with?("%{") }.join
      .gsub(/\$\{([^}]+)\}/) { values.fetch($1) }
  end

  # The command lines, continuations joined, comments and blanks dropped.
  def commands(text)
    text.gsub("\\\n", " ").lines.map(&:strip).reject { it.empty? || it.start_with?("#") }
  end

  it "keeps the CIDRs required and the rates in the packaged directory" do
    variables = File.read(File.join(tf_dir, "variables.tf"))
    %w[operator_ssh_cidr web_ui_cidr].each do |var|
      expect(variables[/^variable "#{var}" \{\n.*?^\}\n/m]).not_to match(/^\s*default\s*=/)
    end
    Dir[File.join(tf_dir, "*")].each do |file|
      expect(File.read(file)).not_to include("/etc/ubicloud/billing_rates.d"), file
    end
    expect(File.read(File.join(tf_dir, "terraform.tfvars.example"))).not_to match(/^\s*\w+_cidr\s*=\s*"0\.0\.0\.0\/0"/)
  end

  it "prints a site add that ubicloud-admin site add accepts" do
    allow(Config).to receive_messages(billing_rates_extra_dir: dir, base_url: "https://cloud.example.com", control_plane_outbound_cidrs: ["10.98.1.10/32"])
    BillingRate.rates
    lines = commands(render("byoh_location_create_command"))
    expect(lines.size).to eq 1
    argv = Shellwords.split(lines.first)
    expect(argv.shift(3)).to eq %w[sudo ubicloud-admin site]

    err = StringIO.new
    expect(ByohLocationCli.new(out: StringIO.new, err:).run(argv)).to eq(0), err.string
    location = Location.first(name: "byoh-aws-canary")
    expect(location.ui_name).to eq "AWS ap-south-1 (BYOH)"
    expect(location.byoh_network.to_h).to include("underlay_cidrs" => ["10.98.0.0/16"], "overlay_ipv4_cidrs" => ["172.20.0.0/14"],
      "cp_reach" => "onhost", "cp_source_cidrs" => ["10.98.1.10/32"], "host_mgmt_allow" => ["10.98.1.10/32", "198.51.100.7/32"],
      "ula_underlay" => "none")
    expect(Dir.children(dir)).to eq ["byoh-aws-canary.yml"]
  end

  describe "host_add_command" do
    let(:lines) { commands(render("host_add_command")) }

    # The arguments the control plane shell passes to ubicloud-admin for
    # the host add line, with EXPECT set to expect.
    def host_add_argv(expect)
      line = lines.find { it.start_with?("sudo ubicloud-admin host add ") }.split(" && ").first
      line = line.gsub("~/", "/home/ubuntu/").sub("$EXPECT") { expect.shellsplit.shelljoin }
      Shellwords.split(line).drop(4)
    end

    it "copies the files, then adds, shreds and watches in one chain" do
      expect(lines.map { it.split.first(3).join(" ") }).to eq [
        "aws ec2 get-console-output",
        "scp -i ./.generated/canary/byoh_ssh_key",
        "EXPECT='<the --expect-host-key flags",
        "sudo ubicloud-admin host",
      ]
      expect(lines[1]).to eq "scp -i ./.generated/canary/byoh_ssh_key ./.generated/canary/pools.yaml ./.generated/canary/byoh_ssh_key ubuntu@13.0.0.1:"
      expect(lines.last.split(/\s+&&\s+/).drop(1)).to eq ["shred -u ~/byoh_ssh_key", "sudo ubicloud-admin host watch 10.98.1.20"]
    end

    # Runs the control plane lines in bash, as pasted, with sudo and shred
    # recording their arguments; host add exits add_status.
    def paste_on_control_plane(add_status)
      log = File.join(dir, "calls")
      text = render("host_add_command")[/^# On the control plane.*/m]
      script = <<~SH
        sudo() { echo "sudo $*" >>"$LOG"; [ "$3" != add ] || return #{add_status}; }
        shred() { echo "shred $*" >>"$LOG"; }
        #{text}
      SH
      _, status = Open3.capture2e({"HOME" => dir, "LOG" => log}, "bash", "-c", script)
      [status.exitstatus, File.exist?(log) ? File.readlines(log, chomp: true) : []]
    end

    it "keeps the key and skips the watch when host add fails" do
      status, calls = paste_on_control_plane(2)
      expect(status).to eq 2
      expect(calls.size).to eq 1
      expect(calls.first).to start_with "sudo ubicloud-admin host add --site byoh-aws-canary "
    end

    it "shreds the key and watches after host add succeeds" do
      status, calls = paste_on_control_plane(0)
      expect(status).to eq 0
      expect(calls.drop(1)).to eq ["shred -u #{dir}/byoh_ssh_key", "sudo ubicloud-admin host watch 10.98.1.20"]
    end

    it "prints a host add that byoh-host add parses" do
      flags = fingerprints.map { "--expect-host-key #{it}" }.join(" ")
      o = ByohHostAdd.new.send(:parse, host_add_argv(flags), :add)
      expect(o.slice(:site, :ssh, :ssh_key, :pool_file, :main_ip, :no_wait, :expect_host_keys, :phase)).to eq(
        site: "byoh-aws-canary", ssh: "ubuntu@10.98.1.20", ssh_key: "/home/ubuntu/byoh_ssh_key", pool_file: "/home/ubuntu/pools.yaml",
        main_ip: "10.98.1.20", no_wait: true, expect_host_keys: fingerprints, phase: "all",
      )

      o = ByohHostAdd.new.send(:parse, host_add_argv(""), :add)
      expect(o[:expect_host_keys]).to eq []
    end

    it "stops with a usage error, before any SSH, when EXPECT is left as printed" do
      # The whole value, word-split as the unquoted $EXPECT is: OptionParser
      # takes "--expect-host-key flags" and the other words are left over.
      placeholder = lines.find { it.start_with?("EXPECT=") }.delete_prefix("EXPECT=").shellsplit.first
      expect(placeholder).to eq "<the --expect-host-key flags printed by step 1>"
      argv = host_add_argv(placeholder)
      expect(argv).to include("<the", "--expect-host-key", "flags", "1>")
      err = StringIO.new
      runner = ->(*) { raise "no SSH may run" }
      status = ByohHostAdd.new(out: StringIO.new, err:, runner:, services: -> {}).run("add", argv)
      expect(status).to eq 2
      # Either the leftover words or the bad fingerprint, whichever parse
      # checks first; both stop before any SSH.
      expect(err.string).to match(/\A! invalid argument: .*(<the|flags)/)
      expect(err.string.lines.size).to eq 1
    end

    describe "the optional root key cleanup" do
      let(:ec2) { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEc2 ubi-byoh-canary" }
      let(:tagged) { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHad # ubicloud-byoh site=byoh-aws-canary ip=10.98.1.20" }
      let(:home) { File.join(dir, "home") }
      let(:root) { File.join(dir, "root") }

      # Runs the commented step 4 with sudo as a no-op and both .ssh
      # directories under dir; root's authorized_keys holds root_lines.
      def clean_root_keys(root_lines, ubuntu_lines: [ec2])
        line = render("host_add_command").lines.find { it.start_with?("#   ssh -i ") }
        argv = Shellwords.split(line.delete_prefix("#"))
        expect(argv.first(4)).to eq ["ssh", "-i", "./.generated/canary/byoh_ssh_key", "ubuntu@13.0.0.2"]
        expect(argv.size).to eq 5
        remote = argv.last.gsub("/home/ubuntu/.ssh", home).gsub("/root/.ssh", root)
        FileUtils.mkdir_p([home, root])
        File.write(File.join(home, "authorized_keys"), ubuntu_lines.map { "#{it}\n" }.join) if ubuntu_lines
        File.write(File.join(root, "authorized_keys"), root_lines.map { "#{it}\n" }.join)
        _, status = Open3.capture2e("bash", "-c", "sudo() { \"$@\"; }; #{remote}")
        [status.exitstatus, File.readlines(File.join(root, "authorized_keys"), chomp: true), Dir.children(root)]
      end

      it "drops only the EC2 key once host add's key is there" do
        status, lines, files = clean_root_keys([ec2, "ssh-ed25519 AAAAother other", tagged])
        expect([status, lines, files]).to eq [0, ["ssh-ed25519 AAAAother other", tagged], ["authorized_keys"]]
        expect(File.stat(File.join(root, "authorized_keys")).mode & 0o777).to eq 0o600
      end

      it "leaves root's keys alone before host add has installed its key" do
        expect(clean_root_keys([ec2])).to eq [1, [ec2], ["authorized_keys"]]
      end

      it "leaves root's keys alone when ubuntu's keys cannot be read" do
        expect(clean_root_keys([ec2, tagged], ubuntu_lines: nil)).to eq [1, [ec2, tagged], ["authorized_keys"]]
      end
    end

    it "parses the --expect-host-key flags out of the console output" do
      awk = Shellwords.split(lines.first.split(" | ", 2).last).drop(1).first
      # Synthesised from cloud-init's ssh key fingerprint block; not
      # captured from a current AMI (UNVERIFIED).
      console = <<~CONSOLE
        [   12.3] cloud-init[812]: Cloud-init v. 24.1 running 'modules:config'
        ec2: SHA256:#{"z" * 43} not in the block
        -----BEGIN SSH HOST KEY FINGERPRINTS-----
        256 #{fingerprints[0]} root@ip-10-98-1-20 (ECDSA)
        ec2: 256 #{fingerprints[1]} root@ip-10-98-1-20 (ED25519)
        -----END SSH HOST KEY FINGERPRINTS-----
        -----BEGIN SSH HOST KEY KEYS-----
      CONSOLE
      out, status = Open3.capture2("awk", awk, stdin_data: console)
      expect(status).to be_success
      expect(out.split).to eq fingerprints.flat_map { ["--expect-host-key", it] }
    end
  end
end
# rubocop:enable RSpec/DescribeClass
