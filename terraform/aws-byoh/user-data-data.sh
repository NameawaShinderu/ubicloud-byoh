#!/usr/bin/env bash
# ==============================================================
#  user-data for the BYOH data plane instance (ubi-byoh-data)
# ==============================================================
#
# Runs ONCE via cloud-init on first boot. Does just enough to
# be registrable as a BYOH host by the Ubicloud control plane:
#
#   1. Allow root login with the AWS key pair (so the operator can
#      SSH as root to drop the ctrl plane's Ubicloud-generated
#      SSH key into /root/.ssh/authorized_keys — that's the key
#      Ubicloud's BootstrapRhizome prog uses)
#
#   2. Pre-install ruby-bundler to dodge the apt-get update race in
#      Prog::BootstrapRhizome.setup. Without this, the bootstrap
#      script runs `apt-get install ruby-bundler` but the apt index
#      may be stale (Ubuntu 24.04 AMIs ship with a minimal cache),
#      causing a single-strand failure until the next retry.
#
#   3. Ensure net.ipv4.ip_forward and proxy_arp are enabled so the
#      kernel can forward packets destined for the BYOH secondary
#      private IPs to the VMs' taps. (Ubicloud's prep_host.rb prog
#      also does this, but setting it here means it's ready
#      immediately, before the rhizome install.)
#
# Everything else — SPDK, cloud-hypervisor, KVM, hugepages, the
# rhizome agent, boot images — is installed by the Ubicloud control
# plane via SSH after the operator runs bin/register-byoh-host.
set -eu
exec > /var/log/user-data.log 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server ruby-bundler

# --- root SSH pubkey login --------------------------------------
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# Copy the AWS keypair's pubkey from ubuntu's authorized_keys to
# root's so the operator can SSH as root immediately (needed to
# install the ctrl plane's Ubicloud SSH key into /root/.ssh/).
if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
  cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh

# --- kernel forwarding + proxy_arp ------------------------------
cat > /etc/sysctl.d/99-ubi-byoh-forwarding.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.proxy_arp=1
net.ipv6.conf.all.proxy_ndp=1
SYSCTL
sysctl --system

# --- helpful MOTD -----------------------------------------------
cat > /etc/update-motd.d/90-byoh <<'MOTD'
#!/bin/bash
cat <<BANNER

  ██    ██ ██████  ██    ██  ██████  ██   ██
  ██    ██ ██   ██  ██  ██  ██    ██ ██   ██
  ██    ██ ██████    ████   ██    ██ ███████
  ██    ██ ██   ██    ██    ██    ██ ██   ██
   ██████  ██████     ██     ██████  ██   ██

  BYOH data plane host.

  This host does NOT need manual setup — it's managed entirely by
  the Ubicloud control plane via SSH. The control plane's rhizome
  agent will install SPDK, cloud-hypervisor, nftables rules,
  hugepages, and everything else when the operator runs
  bin/register-byoh-host.

  Current state:
    - openssh-server: enabled
    - root login: PermitRootLogin prohibit-password (pubkey only)
    - ruby-bundler: pre-installed
    - ip_forward + proxy_arp: enabled

BANNER
MOTD
chmod +x /etc/update-motd.d/90-byoh

touch /var/log/user-data.done
