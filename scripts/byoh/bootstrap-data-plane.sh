#!/usr/bin/env bash
# ====================================================================
#  bootstrap-data-plane.sh — idempotent BYOH data plane prep
# ====================================================================
#
# Prepares a fresh Ubuntu 24.04 LTS host to be registered as a BYOH
# (generic provider) data plane by the Ubicloud control plane. This
# script does the absolute minimum — Ubicloud's rhizome agent + the
# prep_host.rb prog will install cloud-hypervisor, vhost-block-backend,
# nftables rules, hugepages, firmware, boot images, etc. via SSH after
# registration.
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
#   - Install cloud-hypervisor or the storage backend — rhizome does that
#   - Configure network interfaces — that's your site's pre-work (see
#     docs/byoh/NETWORKING.md section 9). Never put pool IPs on the NIC.
#   - Open firewall ports — SSH 22 from the control plane is all you need
#
# Platform-neutral: the same steps on bare metal, a cloud VM with nested
# virtualization, or a Proxmox VM. Tested on AWS (m5d.metal and
# m8i.2xlarge); other platforms are UNVERIFIED.
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

# --- Step 1b: hardware virtualization ----------------------------------
# The same checks prep runs after registration (rhizome/host/lib/kvm_check.rb
# and Prog::SetupHugepages), made here so a host that can never run VMs,
# such as a VPS without nested virtualization, is refused before it is
# registered rather than looping in PrepHost.
step "1b. hardware virtualization"
# The virtualization ladder report (docs/byoh/NO_KVM.md): which rung this
# machine is on and why. It only reads; the checks below still decide.
# The probe needs ruby, which step 4 installs anyway. A copy of this
# script run outside a checkout skips the report.
probe="$(cd "$(dirname "$0")" && pwd)/../../rhizome/host/bin/virt-probe"
if [ -f "$probe" ]; then
  if ! command -v ruby >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ruby >/dev/null
  fi
  sudo ruby "$probe" | sed 's/^/  /'
fi
virt_hint="For the fix on this platform run, on the control plane: bin/byoh-virt probe --main-ip <this host>. Enable VT-x/AMD-V in the firmware on bare metal. On a cloud VM, use an instance type with nested virtualization enabled (AWS m8i/c8i/r8i with nested virtualization, GCP --enable-nested-virtualization, an Azure size that supports nested virtualization) or a bare-metal type. On Proxmox: qm set <vmid> --cpu host. A VPS without nested virtualization cannot be a data plane."
if [ ! -c /dev/kvm ]; then
  echo "ERROR: /dev/kvm is missing, so KVM is unavailable." >&2
  echo "  $virt_hint" >&2
  exit 1
fi
if [ "$(uname -m)" = "x86_64" ]; then
  if ! grep -Eqw 'vmx|svm' /proc/cpuinfo; then
    echo "ERROR: the CPU has neither the vmx nor the svm flag." >&2
    echo "  $virt_hint" >&2
    exit 1
  fi
  if ! grep -qw pdpe1gb /proc/cpuinfo; then
    echo "ERROR: the CPU lacks the pdpe1gb flag, so it cannot use 1G hugepages (Prog::SetupHugepages)." >&2
    echo "  On Proxmox use CPU type host; on a cloud VM pick a newer instance family." >&2
    exit 1
  fi
fi
echo "  /dev/kvm present$( [ "$(uname -m)" = "x86_64" ] && echo ", vmx/svm and pdpe1gb flags present")"

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
  # netcat-openbsd: the gate (scripts/byoh/verify/m2-gate.sh) reaches
  # VMs with "ip netns exec <vm> nc"; Ubuntu server images ship it.
  sudo apt-get install -y ruby-bundler netcat-openbsd
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
echo "  bundle exec bin/byoh-location create --name <site> ...   # once per site"
echo "  bundle exec bin/register-byoh-host \\"
echo "    --location <site> \\"
echo "    --main-ip ${MY_IP:-<this-host-primary-ip>} \\"
echo "    --pool-file pools.yaml \\"
echo "    --ssh-key /path/to/ctrl-plane/privkey \\"
echo "    --default-boot-image ubuntu-noble \\"
echo "    --yes"
echo ""
echo "How the pool addresses reach this host depends on the site"
echo "(docs/byoh/NETWORKING.md section 9):"
echo "  • Rented bare metal (Hetzner/OVH/Leaseweb): a routed block, routed + public"
echo "  • Proxmox or a LAN: pool IPs on the LAN segment, onlink + internal,"
echo "    or onlink + nat behind 1:1 NAT (docs/byoh/SETUP_PROXMOX.md)"
echo "  • AWS: ENI secondary IPs + EIPs from terraform/aws-byoh, fabric + nat"
echo "  • Colocation: a static route or BGP, routed + public"
echo ""
echo "Setup guides: docs/byoh/SETUP.md (any platform) and"
echo "docs/byoh/SETUP_PROXMOX.md."
