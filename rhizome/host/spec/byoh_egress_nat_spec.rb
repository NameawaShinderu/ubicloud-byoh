# frozen_string_literal: true

require_relative "../lib/byoh_egress_nat"
require "tmpdir"

RSpec.describe ByohEgressNat do
  let(:table) do
    <<~NFT
      table inet byoh_egress;
      delete table inet byoh_egress;
      table inet byoh_egress {
        set deny4 {
          type ipv4_addr;
          flags interval;
          auto-merge;
          elements = { 10.97.0.0/16, 203.0.113.0/24 }
        }

        set per_src {
          type ipv4_addr;
          size 65535;
          flags dynamic;
        }

        set log_src {
          type ipv4_addr;
          size 65535;
          flags dynamic,timeout;
          timeout 60s;
        }

        chain forward {
          type filter hook forward priority filter - 1; policy accept;
          iifname "vetho*" ip daddr 169.254.0.0/16 ct direction original counter drop
          iifname "vetho*" ip daddr 168.63.129.16 ct direction original counter drop
          iifname "vetho*" ip6 daddr { fd00:ec2::254, fd20:ce::254 } ct direction original counter drop
          iifname "vetho*" oifname != "vetho*" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } ip daddr @deny4 ct direction original counter drop
          ip saddr 169.254.0.0/16 ip daddr @deny4 counter drop
          ip saddr 169.254.0.0/16 tcp dport 25 counter drop
          ip saddr 169.254.0.0/16 ct state new add @per_src { ip saddr ct count over 4096 } counter drop
        }

        chain input {
          type filter hook input priority filter - 1; policy accept;
          iifname "vetho*" ip daddr @deny4 ct direction original counter drop
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 169.254.0.0/16 ip daddr != 169.254.0.0/16 oifname != "vetho*" ct state new update @log_src { ip saddr limit rate 5/second } log prefix "byoh-egress " level info
          ip saddr 169.254.0.0/16 ip daddr != 169.254.0.0/16 oifname != "vetho*" counter masquerade
        }
      }
    NFT
  end

  describe ".render" do
    it "denies the given networks and outbound SMTP" do
      expect(described_class.render(deny4: ["10.97.0.0/16", "203.0.113.0/24"], smtp: false)).to eq table
    end

    it "leaves the deny set empty and allows SMTP" do
      expected = table
        .sub("    elements = { 10.97.0.0/16, 203.0.113.0/24 }\n", "")
        .sub("    ip saddr 169.254.0.0/16 tcp dport 25 counter drop\n", "")
      expect(described_class.render(deny4: [], smtp: true)).to eq expected
    end
  end

  describe ".ensure_installed" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "nftables.d", "1-byoh-egress.conf") }
    let(:conf) { File.join(dir, "nftables.conf") }

    after { FileUtils.rm_rf(dir) }

    def install(deny4: ["10.97.0.0/16", "203.0.113.0/24"], smtp: false)
      described_class.ensure_installed(deny4: deny4, smtp: smtp, path: path, nftables_conf: conf)
    end

    it "loads a new table from the temporary file before it replaces the old one" do
      File.write(conf, "flush ruleset\n")
      expect(described_class).to receive(:_run_command).with("nft", "-f", "#{path}.tmp") do
        expect(File.read("#{path}.tmp")).to eq table
        expect(File.exist?(path)).to be false
        ""
      end

      expect(install).to be true
      expect(File.read(path)).to eq table
      expect(File.read(conf)).to eq "flush ruleset\ninclude \"/etc/nftables.d/*.conf\"\n"
    end

    it "rewrites the table only when it changes" do
      expect(described_class).to receive(:_run_command).with("nft", "-f", "#{path}.tmp").twice.and_return("")
      expect(install).to be true
      expect(install).to be false
      expect(install(smtp: true)).to be true
      expect(File.read(path)).not_to include("dport 25")
    end

    it "keeps an installed table with keep_existing" do
      expect(described_class).to receive(:_run_command).with("nft", "-f", "#{path}.tmp").and_return("")
      install
      expect(described_class.ensure_installed(deny4: [], smtp: true, path: path, nftables_conf: conf, keep_existing: true)).to be false
      expect(File.read(path)).to eq table
    end

    it "installs a missing table with keep_existing" do
      expect(described_class).to receive(:_run_command).with("nft", "-f", "#{path}.tmp").and_return("")
      expect(described_class.ensure_installed(deny4: ["10.97.0.0/16", "203.0.113.0/24"], smtp: false, path: path, nftables_conf: conf, keep_existing: true)).to be true
      expect(File.read(path)).to eq table
    end

    it "keeps the old table when the new one does not load" do
      expect(described_class).to receive(:_run_command).with("nft", "-f", "#{path}.tmp").and_return("")
      install
      expect(described_class).to receive(:_run_command).with("nft", "-f", "#{path}.tmp").and_raise(CommandFail.new("nft failed", "", "syntax error"))
      expect { install(deny4: ["bogus"]) }.to raise_error(CommandFail)
      expect(File.read(path)).to eq table
    end

    it "adds the include line once, after a last line without a newline" do
      File.write(conf, "flush ruleset")
      allow(described_class).to receive(:_run_command).and_return("")
      install
      install(smtp: true)
      expect(File.read(conf)).to eq "flush ruleset\ninclude \"/etc/nftables.d/*.conf\"\n"
    end

    it "creates a missing nftables.conf with the include line" do
      allow(described_class).to receive(:_run_command).and_return("")
      install
      expect(File.read(conf)).to eq "include \"/etc/nftables.d/*.conf\"\n"
    end
  end

  describe ".remove" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "1-byoh-egress.conf") }

    after { FileUtils.rm_rf(dir) }

    it "deletes the file and the table, present or not" do
      File.write(path, "table")
      expect(described_class).to receive(:_run_command).with("nft", "-f", "-", stdin: "table inet byoh_egress\ndelete table inet byoh_egress\n").twice.and_return("")
      described_class.remove(path: path)
      expect(File.exist?(path)).to be false
      described_class.remove(path: path)
    end
  end
end
