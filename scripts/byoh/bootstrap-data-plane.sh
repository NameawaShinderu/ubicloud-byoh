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
#   5. Run host preflight (scripts/byoh/host/ubicloud-host preflight
#      --standalone, read-only) when the script is found, and print the
#      next steps on the control plane
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
#   ./scripts/byoh/bootstrap-data-plane.sh [--main-ip IP]
#       [--preflight-script PATH | --no-preflight]
#
#   --main-ip IP             the address the control plane will reach this
#                            host at; preflight checks that it is on this
#                            host (a NAT address in front of it only warns)
#   --preflight-script PATH  the ubicloud-host script to run preflight with.
#                            Default: ubicloud-host next to this script, or
#                            host/ubicloud-host below its directory (the
#                            repository layout)
#   --no-preflight           skip preflight
#
# Exit status: 0 the host is prepared and preflight found no failing
# check (or did not run); 1 a step failed, or preflight found a failing
# check or could not run; 2 a usage error. The steps are done and marked
# even when preflight fails, so a re-run after a fix only repeats the
# checks. ubicloud-admin host add runs the full preflight again, with
# the pools, from the control plane.
#
set -euo pipefail

usage() {
  echo "usage: bootstrap-data-plane.sh [--main-ip IP] [--preflight-script PATH | --no-preflight]" >&2
  echo "  (the options are described at the top of the script)" >&2
  exit 2
}
usage_error() {
  echo "bootstrap-data-plane.sh: $*" >&2
  exit 2
}

MAIN_IP=""
PREFLIGHT_SCRIPT=""
RUN_PREFLIGHT=1
while (($#)); do
  case $1 in
    --main-ip | --preflight-script)
      (($# >= 2)) || usage_error "$1 needs a value"
      if [ "$1" = --main-ip ]; then MAIN_IP=$2; else PREFLIGHT_SCRIPT=$2; fi
      shift
      ;;
    --no-preflight) RUN_PREFLIGHT=0 ;;
    -h | --help) usage ;;
    *) usage_error "unknown argument $1 (see --help)" ;;
  esac
  shift
done
[[ -z $MAIN_IP || $MAIN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "--main-ip must be an IPv4 address"
if [[ -n $PREFLIGHT_SCRIPT ]]; then
  ((RUN_PREFLIGHT)) || usage_error "--preflight-script and --no-preflight exclude each other"
  [[ -f $PREFLIGHT_SCRIPT ]] || usage_error "--preflight-script $PREFLIGHT_SCRIPT: no such file"
elif ((RUN_PREFLIGHT)); then
  # Found by the script's own location, never by the working directory;
  # piped into bash, the script has no location and preflight is skipped
  # with a hint.
  self=${BASH_SOURCE[0]:-}
  if [[ -f $self ]]; then
    self_dir=$(cd "$(dirname "$self")" && pwd)
    for candidate in "$self_dir/ubicloud-host" "$self_dir/host/ubicloud-host"; do
      if [[ -f $candidate ]]; then
        PREFLIGHT_SCRIPT=$candidate
        break
      fi
    done
  fi
fi

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
virt_hint="Enable VT-x/AMD-V in the firmware on bare metal. On a cloud VM, use an instance type with nested virtualization enabled (AWS m8i/c8i/r8i with nested virtualization, GCP --enable-nested-virtualization, an Azure size that supports nested virtualization) or a bare-metal type. On Proxmox: qm set <vmid> --cpu host. A VPS without nested virtualization cannot be a data plane."
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

# --- Step 5: preflight and next steps ---------------------------------
step "5. host preflight (read-only)"
MY_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1);exit}}}' || true)
PREFLIGHT_RC=0
PREFLIGHT_FAILS=0
if ((!RUN_PREFLIGHT)); then
  echo "  [skip] --no-preflight"
elif [[ -z $PREFLIGHT_SCRIPT ]]; then
  echo "  [skip] ubicloud-host was not found next to this script."
  echo "  ubicloud-admin host add runs it from the control plane anyway. To run it"
  echo "  now, copy scripts/byoh/host/ubicloud-host here and pass --preflight-script,"
  echo "  or from the control plane, without changing anything on this host:"
  echo "    sudo ubicloud-admin host preflight --site <site> --ssh <user>@${MY_IP:-<this host>} \\"
  echo "      --ssh-key <key> --pool-file pools.yaml"
else
  echo "  $PREFLIGHT_SCRIPT preflight --standalone${MAIN_IP:+ --main-ip $MAIN_IP}"
  preflight_args=(preflight --standalone)
  [[ -z $MAIN_IP ]] || preflight_args+=(--main-ip "$MAIN_IP")
  # Captured, so that a failing run neither stops this script (set -e)
  # nor hides what it printed.
  as_root=(sudo)
  [[ $EUID -ne 0 ]] || as_root=()
  preflight_out=$("${as_root[@]}" bash "$PREFLIGHT_SCRIPT" "${preflight_args[@]}" </dev/null) || PREFLIGHT_RC=$?
  [[ -z $preflight_out ]] || printf '%s\n' "$preflight_out" | sed 's/^/  /'
  # Human mode prints "STATUS ID DETAIL" rows; fix lines are indented.
  PREFLIGHT_FAILS=$(grep -c '^fail ' <<<"$preflight_out" || true)
  PREFLIGHT_WARNS=$(grep -c '^warn ' <<<"$preflight_out" || true)
  if ((PREFLIGHT_RC != 0)); then
    echo "  preflight could not run (exit $PREFLIGHT_RC)." >&2
  else
    echo "  preflight: $PREFLIGHT_FAILS failing, $PREFLIGHT_WARNS warning (docs/byoh/PLATFORMS.md §6, docs/byoh/TROUBLESHOOTING.md)"
  fi
fi

step "DONE — next steps on the control plane"
echo ""
echo "Primary IPv4 (the --main-ip, unless the control plane reaches this"
echo "host through NAT):  ${MY_IP:-<unknown — check 'ip -4 addr'>}"
echo ""
echo "Packaged control plane (scripts/byoh/install.sh), from any login on"
echo "this host with passwordless sudo, e.g. user ubuntu:"
echo ""
echo "  sudo ubicloud-admin site add <site> --display \"<name customers see>\" \\"
echo "    --rates-from <location> ...                     # once per site"
echo "  sudo ubicloud-admin host add --site <site> \\"
echo "    --ssh <user>@${MY_IP:-<this-host-primary-ip>} --ssh-key <that user's key> \\"
echo "    --pool-file pools.yaml"
echo ""
echo "host add runs preflight with the pools, installs its own root key here,"
echo "registers the host and watches it until it accepts VMs. On a development"
echo "control plane, run packaging/bin/ubicloud-admin --dev the same way, or"
echo "bin/register-byoh-host with a root key you install yourself"
echo "(docs/byoh/SETUP.md)."
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

if ((PREFLIGHT_RC != 0 || PREFLIGHT_FAILS > 0)); then
  echo "" >&2
  if ((PREFLIGHT_RC != 0)); then
    echo "ERROR: preflight could not run (exit $PREFLIGHT_RC); see its output above." >&2
  else
    echo "ERROR: preflight found $PREFLIGHT_FAILS failing check(s), listed above with their fixes." >&2
    echo "  Fix them and run this script again (the finished steps are skipped)." >&2
  fi
  exit 1
fi
