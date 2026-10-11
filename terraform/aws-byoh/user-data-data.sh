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

# --- keep the BYOH pool IPs OFF the host NIC --------------------
# cloud-init's EC2 datasource configures every secondary private IP
# of the ENI as a local address of the host (50-cloud-init.yaml).
# The kernel then answers for the pool IPs itself, so traffic for a
# VM's IP never reaches the VM (and wait_sshable passes against the
# host's own sshd). Disable that for future boots and drop whatever
# cloud-init already applied on this first boot.
cat > /etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg <<'CLOUDCFG'
datasource:
  Ec2:
    apply_full_imds_network_config: false
CLOUDCFG
primary_ip=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)" http://169.254.169.254/latest/meta-data/local-ipv4)
for f in /etc/netplan/50-cloud-init.yaml; do
  [ -f "$f" ] && sed -i '/^      addresses:/,/^      [a-z]/{/^      addresses:/d;/^      - /d}' "$f"
done
dev=$(ip -4 -o addr show | awk -v p="$primary_ip" '$4 ~ "^"p"/" {print $2; exit}')
sysctl -w "net.ipv4.conf.${dev}.promote_secondaries=1"
ip -4 -o addr show dev "$dev" | awk '{print $4}' | grep -v "^${primary_ip}/" | sort -r | while read -r cidr; do
  ip addr del "$cidr" dev "$dev"
done

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
