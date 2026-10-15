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
#   ./scripts/byoh/bootstrap-data-plane.sh [--tier kvm|auto|container|pvm|emulated]
#
# --tier picks the rung of the virtualization ladder (docs/byoh/NO_KVM.md)
# the host will be registered on. The default, kvm, refuses a host
# without usable KVM, as this script always did; with the probe at hand
# it also refuses a host the probe finds kvm_blocked (KVM present but not
# usable for cloud-hypervisor), which registration would refuse. auto
# makes the choice bin/register-byoh-host --virt-tier auto makes: kvm on
# a host that runs KVM (the checks below then demand 1G pages, as
# registration does), pvm on a PVM host, the fastest fallback its kernel
# allows (container, then emulated) on a host without hardware
# virtualization, and a refusal with the probe's reasons otherwise, a
# kvm_blocked host included. Never silently: it prints the choice, and
# registration still needs --accept-fallback.
#
# A lower tier is refused before anything is installed until this
# checkout can register it (SHIPPED_TIERS below). Once shipped, a lower
# tier skips only the KVM checks and installs only that tier's userspace
# packages. This script never changes kernels, sysctls or GRUB.
#
# Environment:
#   BYOH_ALLOW_UNSHIPPED_TIER=1  prepare a lower tier that cannot be
#                                registered yet (lab work only)
#
set -euo pipefail

# The lower tiers this checkout can register; keep it equal to
# ByohVirtTiers::SHIPPED (spec/lib/byoh_virt_tiers_spec.rb checks).
SHIPPED_TIERS="container emulated"

usage() {
  echo "usage: $0 [--tier kvm|auto|container|pvm|emulated]"
}

TIER=kvm
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)
      if [ $# -lt 2 ]; then
        echo "ERROR: --tier needs a value" >&2
        usage >&2
        exit 2
      fi
      TIER="$2"
      shift 2
      ;;
    --tier=*)
      TIER="${1#--tier=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done
case "$TIER" in
  kvm|auto|container|pvm|emulated) ;;
  *)
    echo "ERROR: unknown tier $TIER" >&2
    usage >&2
    exit 2
    ;;
esac

# Refuses a lower tier this checkout cannot register yet, before any
# package is installed for it.
require_shipped_tier() {
  case "$1" in
    kvm|auto) return 0 ;;
  esac
  case " $SHIPPED_TIERS " in
    *" $1 "*) return 0 ;;
  esac
  if [ "${BYOH_ALLOW_UNSHIPPED_TIER:-0}" = 1 ]; then
    echo "  WARNING: tier $1 cannot be registered yet; preparing it anyway (BYOH_ALLOW_UNSHIPPED_TIER=1)." >&2
    return 0
  fi
  echo "ERROR: $1 hosts cannot be registered yet (docs/byoh/NO_KVM.md section 11), so this script installs nothing for them." >&2
  echo "  Run the data plane where KVM works instead; for lab work only, set BYOH_ALLOW_UNSHIPPED_TIER=1." >&2
  exit 1
}
require_shipped_tier "$TIER"

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
if [ "$TIER" = auto ] && [ ! -f "$probe" ]; then
  echo "ERROR: --tier auto needs the virtualization probe; run this script from a checkout, or pass --tier explicitly." >&2
  exit 1
fi
if [ -f "$probe" ] && { [ "$TIER" = auto ] || [ "$TIER" = kvm ]; }; then
  # The choice of bin/register-byoh-host --virt-tier auto
  # (ByohVirtRegistration#auto_tier): kvm where KVM runs, pvm on a PVM
  # host, the fastest fallback without hardware virtualization, a refusal
  # otherwise. A kvm_blocked host is refused in both modes: registration
  # refuses it whether declared kvm or auto. Prints "<tier>" or
  # "refuse:<why>".
  choice=$(sudo ruby "$probe" --json | ruby -rjson -e '
    r = JSON.parse(STDIN.read)
    auto = ARGV[0] == "auto"
    why = "the probe found #{r["tier"]}#{" (#{r["cause"]})" if r["cause"]}: #{Array(r["reasons"]).join("; ")}"
    case r["tier"]
    when "kvm" then puts "kvm"
    when "kvm_blocked" then puts "refuse:#{why}. KVM is there but not usable, and registration refuses such a host; fix KVM first"
    when "pvm" then puts(auto ? "pvm" : "kvm")
    when "none", "pvm_blocked"
      pick = %w[container emulated].find { |t| (r["possible"] + r["unchecked"]).include?(t) } if auto
      puts(pick || (auto ? "refuse:#{why}. No fallback fits this host" : "kvm"))
    else puts(auto ? "refuse:#{why}. There is no automatic choice for it" : "kvm")
    end' "$TIER")
  case "$choice" in
    refuse:*)
      echo "ERROR: ${choice#refuse:}; see the report above and docs/byoh/NO_KVM.md." >&2
      echo "  For the fix on this platform run, on the control plane: bin/byoh-virt probe --main-ip <this host>." >&2
      exit 1
      ;;
  esac
  if [ "$TIER" = auto ]; then
    TIER=$choice
    echo "  --tier auto chose: $TIER"
    require_shipped_tier "$TIER"
  fi
fi
virt_hint="For the fix on this platform run, on the control plane: bin/byoh-virt probe --main-ip <this host>. Enable VT-x/AMD-V in the firmware on bare metal. On a cloud VM, use an instance type with nested virtualization enabled (AWS m8i/c8i/r8i with nested virtualization, GCP --enable-nested-virtualization, an Azure size that supports nested virtualization) or a bare-metal type. On Proxmox: qm set <vmid> --cpu host. A VPS without nested virtualization cannot be a data plane."
if [ "$TIER" = kvm ]; then
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
else
  # A lower tier needs no KVM. Install only that tier's userspace; its
  # prep (prep_host.rb) checks the rest after registration.
  echo "  tier $TIER: skipping the KVM checks (docs/byoh/NO_KVM.md)"
  case "$TIER" in
    container)
      # prep_host.rb refuses others (HostTier check_container_arch).
      if [ "$(uname -m)" != x86_64 ]; then
        echo "ERROR: container hosts must be x86_64; this is $(uname -m)." >&2
        exit 1
      fi
      if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        echo "ERROR: containers need the unified cgroup hierarchy (cgroup v2)." >&2
        exit 1
      fi
      kver=$(uname -r | cut -d- -f1)
      if [ "$(printf '%s\n' 5.12 "$kver" | sort -V | head -n1)" != 5.12 ]; then
        echo "ERROR: containers need Linux 5.12 or newer (idmapped mounts); this is $kver." >&2
        exit 1
      fi
      # rhizome/host/lib/host_tier.rb CONTAINER_PACKAGES, which prep
      # checks: LXC, lxcfs, newuidmap, xz for the root tarballs, setquota
      # for unencrypted disks, cryptsetup and mkfs.ext4 for encrypted
      # ones. Ubuntu's lxc package enables lxc-net (an lxcbr0 bridge with
      # its own dnsmasq and NAT); prep_host.rb turns it off
      # (HostTier.container_host_setup), so it never runs beside the BYOH
      # nftables and per-VM dnsmasq.
      tier_packages="lxc lxcfs uidmap xz-utils quota cryptsetup-bin e2fsprogs"
      ;;
    emulated)
      # prep_host.rb refuses others (HostTier check_arch).
      if [ "$(uname -m)" != x86_64 ]; then
        echo "ERROR: emulated hosts must be x86_64; this is $(uname -m)." >&2
        exit 1
      fi
      # The last rung: say so, and say what is faster (docs/byoh/NO_KVM.md).
      echo "  WARNING: emulated VMs run under QEMU's software translator: about a quarter of native"
      echo "  CPU speed, far less for memory-heavy work, minutes to boot, and no security boundary"
      echo "  between tenants. Prefer KVM (bin/byoh-virt probe prints the fix) or --tier container."
      if [ -c /dev/kvm ]; then
        echo "  NOTE: /dev/kvm exists here; register this host as kvm instead if the probe above agrees."
      fi
      if awk '$1 == "SwapTotal:" && $2 > 0 { found = 1 } END { exit !found }' /proc/meminfo; then
        echo "  NOTE: swap is on. Emulated guest RAM can be swapped out, which makes slow VMs slower."
      fi
      echo "  NOTE: on burstable instances (AWS T, Azure B) emulated VMs burn CPU credits all the time: demo only."
      # rhizome/host/lib/host_tier.rb PACKAGES, which prep checks:
      # QEMU's x86_64 system emulator and the OVMF firmware the VMs boot.
      tier_packages="qemu-system-x86 ovmf"
      ;;
    pvm)
      if [ ! -d /sys/module/kvm_pvm ]; then
        echo "ERROR: kvm_pvm is not loaded. This script never changes kernels: boot a PVM host kernel and modprobe kvm_pvm first (docs/byoh/NO_KVM.md)." >&2
        exit 1
      fi
      tier_packages=""
      ;;
  esac
  if [ -n "$tier_packages" ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086 # the package list is meant to split
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $tier_packages >/dev/null
    echo "  installed: $tier_packages"
  fi
  # The check prep runs (HostTier.check_emulator!), made here so a broken
  # QEMU is found before registration.
  if [ "$TIER" = emulated ]; then
    if ! qemu-system-x86_64 -accel help 2>/dev/null | grep -qx tcg; then
      echo "ERROR: qemu-system-x86_64 does not list the tcg accelerator." >&2
      exit 1
    fi
    if [ ! -f /usr/share/ovmf/OVMF.fd ]; then
      echo "ERROR: /usr/share/ovmf/OVMF.fd is missing; reinstall ovmf." >&2
      exit 1
    fi
    echo "  qemu-system-x86_64 lists tcg; OVMF present"
  fi
fi

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
if [ "$TIER" != kvm ]; then
  echo "    --virt-tier $TIER --accept-fallback \\"
fi
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
