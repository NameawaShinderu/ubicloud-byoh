#!/usr/bin/env bash
# ====================================================================
#  bootstrap-data-plane.sh — idempotent BYOH data plane prep
# ====================================================================
#
# Prepares a fresh Ubuntu 24.04 LTS host to be registered as a BYOH
# (generic provider) data plane by the Ubicloud control plane. This
# script does the absolute minimum — Ubicloud's rhizome agent + the
# prep_host.rb prog will install SPDK, cloud-hypervisor, nftables rules,
# hugepages, firmware, boot images, etc. via SSH after registration.
#
# What this script does:
#   1. Verify Ubuntu 24.04 LTS
#   2. Ensure openssh-server is installed and enabled
#   3. Permit root login with a public key (needed by Util.rootish_ssh)
#   4. Pre-install ruby-bundler to dodge the apt-get update race in
#      Prog::BootstrapRhizome.setup (see docs/providers/generic.md
#      troubleshooting section)
#   5. Print instructions for installing the control plane's SSH pubkey
#
# What this script does NOT do:
#   - Install SPDK, cloud-hypervisor, qemu, KVM — rhizome does that
#   - Configure network interfaces — that's your provider pre-work
#     (see docs/providers/generic.md → "Making declared routed_networks
#     actually reachable per environment")
#   - Open firewall ports — SSH 22 from the control plane is all you need
#
# Tested against: Ubuntu 24.04.2 LTS (Noble) on AWS m5d.metal.
#
# Usage:
#   ./scripts/byoh/bootstrap-data-plane.sh
#
set -euo pipefail

MARKERS_DIR="$HOME/.ubi-data-plane-bootstrap"
mkdir -p "$MARKERS_DIR"

step() { echo ""; echo "━━━━━ $* ━━━━━"; }
done_marker() { touch "$MARKERS_DIR/$1"; }
is_done() { [ -f "$MARKERS_DIR/$1" ]; }

# --- Step 1: OS check ------------------------------------------------
step "1. OS check"
if ! grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
  echo "ERROR: This script requires Ubuntu 24.04 LTS (Noble)." >&2
  echo "  Detected: $(grep PRETTY_NAME /etc/os-release 2>/dev/null || echo unknown)" >&2
  exit 1
fi
echo "  $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"

# --- Step 2: openssh-server ------------------------------------------
step "2. openssh-server"
if is_done sshd-installed; then
  echo "  [skip] sshd already set up"
else
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update
  sudo apt-get install -y openssh-server
  sudo systemctl enable --now ssh
  done_marker sshd-installed
fi

# --- Step 3: root SSH login via public key ---------------------------
# Ubicloud's Util.rootish_ssh (used by BootstrapRhizome) logs in as
# root using a keypair the control plane generated. We enable pubkey-
# only root login; we do NOT enable password login for root.
step "3. root pubkey login (PermitRootLogin prohibit-password)"
if is_done root-sshd-config; then
  echo "  [skip] sshd_config already updated"
else
  # Backup first
  if [ ! -f /etc/ssh/sshd_config.byoh-original ]; then
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.byoh-original
  fi
  sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  sudo mkdir -p /root/.ssh
  sudo chmod 700 /root/.ssh
  sudo touch /root/.ssh/authorized_keys
  sudo chmod 600 /root/.ssh/authorized_keys
  sudo systemctl reload ssh
  done_marker root-sshd-config
fi

# --- Step 4: pre-install ruby-bundler --------------------------------
# Prog::BootstrapRhizome.setup runs:
#   sudo apt-get update
#   sudo apt-get -y install ruby-bundler
#   sudo which bundle
# On a fresh AWS AMI, apt-get update must have JUST been run or
# ruby-bundler isn't in the package index. We pre-install it here so
# the rhizome bootstrap can't fail on that step — it's idempotent
# from the rhizome's POV.
step "4. pre-install ruby-bundler (dodges BootstrapRhizome apt race)"
if is_done bundler-preinstalled; then
  echo "  [skip] ruby-bundler already installed"
else
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update
  sudo apt-get install -y ruby-bundler
  which bundle
  done_marker bundler-preinstalled
fi

# --- Step 5: print next steps ----------------------------------------
step "DONE — next steps on the control plane"
MY_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1);exit}}}')
echo ""
echo "This host is now ready to be registered as a BYOH data plane."
echo ""
echo "Primary IPv4 (for sshable.host):  ${MY_IP:-<unknown — check 'ip -4 addr'>}"
echo ""
echo "BEFORE running bin/register-byoh-host on the control plane, you must"
echo "install the control plane's SSH public key here as root, so the"
echo "control plane can SSH into this host. The register-byoh-host CLI"
echo "prints the exact pubkey it'll use; install it with:"
echo ""
echo "  sudo bash -c 'echo \"<PUBKEY FROM CLI>\" >> /root/.ssh/authorized_keys'"
echo ""
echo "Then, on the control plane, run something like:"
echo ""
echo "  bundle exec bin/register-byoh-host \\"
echo "    --main-ip ${MY_IP:-<this-host-primary-ip>} \\"
echo "    --routed-network <your-provider-routed-cidr> \\"
echo "    --routed-network fd00:aa55::/64 \\"
echo "    --location byoh-\$LOCATION \\"
echo "    --ssh-key /path/to/ctrl-plane/privkey \\"
echo "    --yes"
echo ""
echo "Provider-specific routing pre-work (what CIDR you declare above"
echo "depends on your provider):"
echo "  • Hetzner/OVH/Equinix/Leaseweb/Cherry/Latitude: order a routed"
echo "    IP block via your provider panel, they handle the routing"
echo "  • Proxmox/homelab: add a static route on your LAN router"
echo "  • AWS: run scripts/byoh/providers/aws-routed-network-setup.sh"
echo "  • Colocation: you already have BGP/static routing from upstream"
echo ""
echo "See docs/providers/generic.md → 'Making declared routed_networks"
echo "actually reachable per environment' for the full matrix."
