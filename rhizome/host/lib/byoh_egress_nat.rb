# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

# The host side of BYOH egress NAT (docs/byoh/NETWORKING.md 14.7). A VM
# without an internet-facing IPv4 has its namespace SNAT its IPv4 egress to
# the vethi link address (VmSetup#generate_host_nat4_rules), and this table
# masquerades that traffic out of the host. It also keeps every VM on the
# host away from the platform's link-local services, such as an instance
# metadata service, and keeps host-NAT traffic off the networks in deny4:
# the site underlay, the control plane and the hosts' management networks.
#
# Only connections a VM opens are dropped: replies to a host-NAT VM's
# vethi address, as from another VM on the host, must pass. The namespace
# NAT leaves traffic to RFC 1918 networks with the VM's private source, so
# the RFC 1918 part of deny4 is matched by interface, for every VM, as such
# traffic cannot be answered off the host anyway; traffic between VMs on
# the host is left alone.
#
# The table lives in its own file, included from /etc/nftables.conf like
# the other /etc/nftables.d files, so it survives reboots and the
# "systemctl reload nftables" that VM setup runs.
module ByohEgressNat
  PATH = "/etc/nftables.d/1-byoh-egress.conf"
  NFTABLES_CONF = "/etc/nftables.conf"
  INCLUDE_LINE = "include \"/etc/nftables.d/*.conf\""

  # Connections a single VM may have open through the host NAT.
  MAX_CONNECTIONS = 4096

  def self.render(deny4:, smtp:)
    elements = "    elements = { #{deny4.join(", ")} }\n" unless deny4.empty?
    smtp_drop = "    ip saddr 169.254.0.0/16 tcp dport 25 counter drop\n" unless smtp
    <<~NFT
      table inet byoh_egress;
      delete table inet byoh_egress;
      table inet byoh_egress {
        set deny4 {
          type ipv4_addr;
          flags interval;
          auto-merge;
      #{elements}  }

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
          iifname "vetho*" oifname != "vetho*" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } ip daddr @deny4 ct direction original counter drop
          ip saddr 169.254.0.0/16 ip daddr @deny4 counter drop
      #{smtp_drop}    ip saddr 169.254.0.0/16 ct state new add @per_src { ip saddr ct count over #{MAX_CONNECTIONS} } counter drop
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 169.254.0.0/16 ip daddr != 169.254.0.0/16 oifname != "vetho*" ct state new update @log_src { ip saddr limit rate 5/second } log prefix "byoh-egress " level info
          ip saddr 169.254.0.0/16 ip daddr != 169.254.0.0/16 oifname != "vetho*" counter masquerade
        }
      }
    NFT
  end

  # Writes and loads the table when its content changed. The new content is
  # loaded from the temporary file before it replaces the old one, so the
  # file on disk is always one that loaded. Returns whether it changed.
  #
  # With keep_existing, an installed table is left as it is. VM setup
  # passes it when it recreates a VM after a host reboot: the VM's
  # parameters date from its creation, and the table may since have been
  # installed from a newer profile (bin/byoh-host setup-egress-nat).
  def self.ensure_installed(deny4:, smtp:, path: PATH, nftables_conf: NFTABLES_CONF, keep_existing: false)
    content = render(deny4: deny4, smtp: smtp)
    ensure_include(nftables_conf)
    return false if File.exist?(path) && (keep_existing || File.read(path) == content)

    FileUtils.mkdir_p(File.dirname(path))
    temp_path = "#{path}.tmp"
    safe_write_to_file(path) do |f|
      f.write(content)
      f.flush
      r "nft", "-f", temp_path
    end
    true
  end

  def self.ensure_include(nftables_conf)
    File.open(nftables_conf, File::APPEND | File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX)
      text = f.read
      next if text.include?(INCLUDE_LINE)

      f.write("\n") unless text.empty? || text.end_with?("\n")
      f.write("#{INCLUDE_LINE}\n")
    end
  end
end
