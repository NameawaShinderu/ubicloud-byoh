#!/bin/env ruby
# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../lib/cloud_hypervisor"
require_relative "../lib/crypt_swap_setup"
require_relative "../lib/host_tier"
require_relative "../lib/htcat_setup"
require_relative "../lib/kvm_check"
require_relative "../lib/spdk_setup"
require_relative "../lib/uplink_mac_pin"
require "fileutils"
require "socket"

unless (hostname = ARGV.shift)
  puts "need host name as argument"
  exit 1
end

unless (env_type = ARGV.shift)
  puts "need environment type as argument"
  exit 1
end

# The virtualization tier the host was registered on: kvm
# (cloud-hypervisor VMs; the default) or a lower tier of
# docs/byoh/NO_KVM.md. HostTier.prep_steps lists the steps below that each
# one runs.
tier = ARGV.shift || "kvm"

begin
  steps = HostTier.prep_steps(tier)
rescue HostTier::Unsupported => e
  abort e.message
end

is_prod_env = (env_type == "production")

# Color prompt and MOTD to cue operators as to production-level
# status.
color_code = is_prod_env ? "\e[31m" : "\e[32m"

reset_color_code = "\e[0m"

step_actions = {
  # Fail before this script changes anything if the host cannot run VMs at
  # all. Other prep steps run in parallel with this one and may already have
  # changed the host; checking before any of them is a job for a preflight.
  kvm_check: -> {
    if (kvm_problem = KvmCheck.problem)
      abort kvm_problem
    end
  },

  # The same, for an emulated host: x86_64, with QEMU and OVMF installed.
  check_arch: -> { HostTier.check_arch! },
  check_emulator: -> { HostTier.check_emulator! },
  # The same, for a container host (HostTier::CONTAINER_STEPS).
  check_container_arch: -> { HostTier.check_arch!(tier: "container") },
  check_container_runtime: -> { HostTier.check_container_runtime! },
  check_container_sysctls: -> { HostTier.check_container_sysctls! },
  check_idmap_range: -> { HostTier.check_idmap_range! },
  container_host_setup: -> { HostTier.container_host_setup },
  kvm_hint: -> {
    if (hint = HostTier.kvm_hint)
      puts hint
    end
  },

  # Set up hostname to better identify servers in transcripts.
  hostname: -> {
    original_hostname = Socket.gethostname
    safe_write_to_file("/etc/hosts", File.read("/etc/hosts").gsub(original_hostname, hostname))
    r "sudo", "hostnamectl", "set-hostname", hostname
  },

  prompt: -> {
    bashrc_content = File.read("/root/.bashrc")
    colored_prompt_code = color_code + '[\u@\h \W]\$ ' + reset_color_code
    safe_write_to_file("/root/.bashrc", "#{bashrc_content}\n PS1='#{colored_prompt_code}'")
  },

  motd: -> {
    motd_message = <<~'MOTD_MESSAGE'
           _     _      _                 _
     _   _| |__ (_) ___| | ___  _   _  __| |
    | | | |  _ \| |/ __| |/ _ \| | | |/ _  |
    | |_| | |_) | | (__| | (_) | |_| | (_| |
     \__,_|_.__/|_|\___|_|\___/ \__,_|\__,_|
    MOTD_MESSAGE

    safe_write_to_file("/etc/update-motd.d/99-clover-motd", <<~MOTD_SCRIPT)
    #!/bin/bash
    echo '#{color_code}#{motd_message}#{reset_color_code}'
    MOTD_SCRIPT

    r "chmod +x /etc/update-motd.d/99-clover-motd"
  },

  # Set up time zone.
  timezone: -> { r "timedatectl set-timezone UTC" },

  # Download cloud hypervisor binaries.
  download_ch: -> { CloudHypervisor::Version.download },

  # Download firmware binaries.
  download_firmware: -> { CloudHypervisor::Firmware.download },

  # Err towards listing ('l') and not restarting services by default,
  # otherwise a stray keystroke when using "apt install" for unrelated
  # packages can restart systemd services that interrupt customers.
  needrestart: -> {
    FileUtils.mkdir_p("/etc/needrestart/conf.d")
    File.write("/etc/needrestart/conf.d/82-clover-default-list.conf", <<CONF)
$nrconf{restart} = 'l';
CONF
  },

  # Host-level network packet forwarding, otherwise packets cannot leave
  # the physical interface.
  forwarding_sysctls: -> {
    File.write("/etc/sysctl.d/72-clover-forward-packets.conf", <<CONF)
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.all.proxy_arp=1
net.ipv4.ip_forward=1
CONF
    r "sysctl --system"
  },

  # VmHosts make no use of RDMA, and the irdma driver that auto-loads on
  # Intel E810/X710 NICs preallocates gigabytes of DMA memory, starving
  # the non-hugepage remainder the host OS runs in.
  blacklist_irdma: -> {
    File.write("/etc/modprobe.d/blacklist-irdma.conf", <<CONF)
blacklist irdma
CONF
    r "update-initramfs -u"
  },

  # The blacklist only applies from the next boot, but SetupHugepages sizes the
  # reservation from MemAvailable before that reboot, and it would then hold the
  # driver's memory back from hugepages for the host's whole life. Unload the
  # driver now so the measurement matches the host the reservation lands on.
  unload_irdma: -> { r "modprobe -r irdma" if File.directory?("/sys/module/irdma") },

  # OS images.

  # For qemu-image convert and mcopy for cloud-init with the nocloud
  # driver.
  # acl is for setfacl, which is used to set permissions and not installed
  # by default in Leaseweb servers.
  image_packages: -> { r "apt-get -y install qemu-utils mtools acl" },

  # We need nvme-cli to inspect installed NVMe cards in prod servers when
  # looking into I/O performance issues. systemd-coredump is useful when
  # debugging crashes.
  prod_packages: -> { r "apt-get -y install nvme-cli systemd-coredump" if is_prod_env },

  # We need smartmontools, nvme-cli and jq in order to probe the disk status of VmHosts
  disk_probe_packages: -> { r "apt-get -y install smartmontools nvme-cli jq ethtool" },

  uplink_mac_pin: -> { puts UplinkMacPin.new.run },

  htcat: -> { HtcatSetup.new.run },

  spdk: -> { SpdkSetup.prep },

  crypt_swap: -> { CryptSwapSetup.run },

  # cron job to store serial.log files
  serial_log_cron: -> {
    FileUtils.mkdir_p("/var/log/ubicloud/serials")
    File.write("/etc/cron.d/ubicloud-clean-serial-logs", <<CRON)
0 * * * * root /home/rhizome/host/bin/delete-old-serial-logs
CRON

    r "systemctl enable cron"
    r "systemctl start cron"
  },
}

steps.each do |step|
  step_actions.fetch(step).call
rescue HostTier::Unsupported => e
  abort e.message
end
