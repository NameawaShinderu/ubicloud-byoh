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
#   ./scripts/byoh/bootstrap-data-plane.sh [--tier kvm|auto|container|pvm|emulated]
#       [--main-ip IP] [--preflight-script PATH | --no-preflight]
#
#   --tier TIER              the rung of the virtualization ladder
#                            (docs/byoh/NO_KVM.md) the host will be
#                            registered on; see below. Default kvm
#   --main-ip IP             the address the control plane will reach this
#                            host at; preflight checks that it is on this
#                            host (a NAT address in front of it only warns)
#   --preflight-script PATH  the ubicloud-host script to run preflight with
#                            (as root, as given). Default: ubicloud-host
#                            next to this script, or host/ubicloud-host
#                            below its directory (the repository layout),
#                            run only when it and the directories above it
#                            are owned by root or you and writable by no
#                            one else; otherwise preflight is skipped with
#                            the reason
#   --no-preflight           skip preflight
#
# --tier: the default, kvm, refuses a host without usable KVM, as this
# script always did; with the probe at hand it also refuses a host the
# probe finds kvm_blocked (KVM present but not usable for
# cloud-hypervisor), which registration would refuse. auto makes the
# choice bin/register-byoh-host --virt-tier auto makes: kvm on a host that
# runs KVM (the checks below then demand 1G pages, as registration does),
# pvm on a PVM host, the fastest fallback its kernel allows (container,
# then emulated) on a host without hardware virtualization, and a refusal
# with the probe's reasons otherwise, a kvm_blocked host included. Never
# silently: it prints the choice, and registration still needs
# --accept-fallback.
#
# A lower tier is refused before anything is installed until this
# checkout can register it (SHIPPED_TIERS below). Once shipped, a lower
# tier skips only the KVM checks and installs only that tier's userspace
# packages. This script never changes kernels, sysctls or GRUB.
#
# Exit status: 0 the host is prepared and preflight found no failing
# check (or did not run); 1 a step failed, or preflight found a failing
# check or could not run; 2 a usage error. The steps are done and marked
# even when preflight fails, so a re-run after a fix only repeats the
# checks. ubicloud-admin host add runs the full preflight again, with
# the pools, from the control plane.
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
  echo "usage: bootstrap-data-plane.sh [--tier kvm|auto|container|pvm|emulated] [--main-ip IP] [--preflight-script PATH | --no-preflight]" >&2
  echo "  (the options are described at the top of the script)" >&2
  exit 2
}
usage_error() {
  echo "bootstrap-data-plane.sh: $*" >&2
  exit 2
}
# unsafe_path PATH: prints why root must not run a file reached through
# PATH, or nothing when it may. PATH and every directory above it must
# be owned by root or by the user running this script, and writable by
# nobody else: never by others (a sticky /tmp too), and by the group
# only when that is the owner's own group, root's or this user's
# user-private group (Ubuntu's umask 002 makes clones group-writable).
unsafe_path() {
  local p=$1 owner group mode upg=""
  [[ $(id -gn) != "$(id -un)" ]] || upg=$(id -g)
  while :; do
    read -r owner group mode < <(stat -c '%u %g %a' -- "$p" 2>/dev/null) || {
      echo "cannot stat $p"
      return
    }
    if [[ $owner != 0 && $owner != "$EUID" ]]; then
      echo "$p is owned by uid $owner, neither root nor you"
      return
    fi
    if ((8#$mode & 8#002)); then
      echo "$p is writable by others (mode $mode)"
      return
    fi
    if ((8#$mode & 8#020)) && ! [[ ($owner == 0 && $group == 0) || ($owner == "$EUID" && $group == "$upg") ]]; then
      echo "$p is writable by group $group (mode $mode)"
      return
    fi
    [[ $p != / ]] || return 0
    p=$(dirname "$p")
  done
}

TIER=kvm
MAIN_IP=""
PREFLIGHT_SCRIPT=""
PREFLIGHT_FOUND=""
PREFLIGHT_UNSAFE=""
RUN_PREFLIGHT=1
while (($#)); do
  case $1 in
    --tier | --main-ip | --preflight-script)
      (($# >= 2)) || usage_error "$1 needs a value"
      case $1 in
        --tier) TIER=$2 ;;
        --main-ip) MAIN_IP=$2 ;;
        *) PREFLIGHT_SCRIPT=$2 ;;
      esac
      shift
      ;;
    --tier=*) TIER=${1#--tier=} ;;
    --no-preflight) RUN_PREFLIGHT=0 ;;
    -h | --help) usage ;;
    *) usage_error "unknown argument $1 (see --help)" ;;
  esac
  shift
done
case $TIER in
  kvm | auto | container | pvm | emulated) ;;
  *) usage_error "unknown tier $TIER" ;;
esac
[[ -z $MAIN_IP || $MAIN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "--main-ip must be an IPv4 address"
if [[ -n $PREFLIGHT_SCRIPT ]]; then
  ((RUN_PREFLIGHT)) || usage_error "--preflight-script and --no-preflight exclude each other"
  [[ -f $PREFLIGHT_SCRIPT ]] || usage_error "--preflight-script $PREFLIGHT_SCRIPT: no such file"
elif ((RUN_PREFLIGHT)); then
  # Found by the script's own location, never by the working directory;
  # piped into bash, the script has no location and preflight is skipped
  # with a hint. A found script runs as root, so it must sit where only
  # root or this user can change it (unsafe_path): a copy of this script
  # in /tmp must not run whatever another user put next to it.
  self=${BASH_SOURCE[0]:-}
  if [[ -f $self ]]; then
    self_dir=$(cd "$(dirname "$self")" && pwd -P)
    for candidate in "$self_dir/ubicloud-host" "$self_dir/host/ubicloud-host"; do
      [[ -f $candidate ]] || continue
      PREFLIGHT_FOUND=$candidate
      real=$(realpath -e -- "$candidate" 2>/dev/null) || real=$candidate
      for p in "$self_dir" "$(realpath -e -- "$(dirname "$candidate")" 2>/dev/null || dirname "$candidate")" "$real"; do
        PREFLIGHT_UNSAFE=$(unsafe_path "$p")
        [[ -z $PREFLIGHT_UNSAFE ]] || break
      done
      [[ -n $PREFLIGHT_UNSAFE ]] || PREFLIGHT_SCRIPT=$real
      break
    done
  fi
fi

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
virt_hint="For the fix on this platform run, on the control plane: bin/byoh-virt probe --main-ip <this host>. Enable VT-x/AMD-V in the firmware on bare metal. On a cloud VM, use an instance type with nested virtualization enabled (AWS m8i/c8i/r8i with nested virtualization, GCP --enable-nested-virtualization, an Azure size that supports nested virtualization) or a bare-metal type. On Proxmox: qm set <vmid> --cpu host. A VPS without nested virtualization can still be a data plane on a slower fallback tier: rerun with --tier auto (or --tier container or emulated); see docs/byoh/NO_KVM.md."
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
    if ! grep -qx tcg <<<"$(qemu-system-x86_64 -accel help 2>/dev/null)"; then
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

  # Prog::Vm::HostNexus#verify_tier_capacity, early: one VM of the
  # tier's smallest size (Option::TierVmSizes) must fit beside the core
  # kept for the host, within the memory budget of
  # ByohVirtTiers.memory_budget_gib (hugepages taken as none).
  case "$TIER" in
    container) min_gib=8 overhead_mib=128 ;;
    pvm) min_gib=8 overhead_mib=384 ;;
    *) min_gib=2 overhead_mib=512 ;;
  esac
  cores=$(lscpu -p=core,socket | grep -v '^#' | sort -u | wc -l)
  threads=$(nproc --all)
  cores_needed=$((2 * cores / threads))
  [ "$cores_needed" -ge 1 ] || cores_needed=1
  if [ $((cores - 1)) -lt "$cores_needed" ]; then
    echo "ERROR: a $TIER host needs $((cores_needed + 1)) physical cores, one for the host and $cores_needed for a $TIER-2 VM; this host has $cores cores and $threads threads." >&2
    exit 1
  fi
  mem_mib=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  budget_gib=$(((mem_mib * 42 / 43 - 2048 - overhead_mib * (threads / 2)) / 1024))
  if [ "$budget_gib" -lt "$min_gib" ]; then
    echo "ERROR: a $TIER host with $mem_mib MiB of memory has a VM memory budget of about $budget_gib GiB, less than the $min_gib GiB of a $TIER-2 VM; give it more memory." >&2
    exit 1
  fi
  echo "  capacity: $cores cores, $threads threads, about $budget_gib GiB for $TIER VMs"
fi

# --- Step 5: preflight and next steps ---------------------------------
step "5. host preflight (read-only)"
MY_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1);exit}}}' || true)
PREFLIGHT_RC=0
PREFLIGHT_FAILS=0
if ((!RUN_PREFLIGHT)); then
  echo "  [skip] --no-preflight"
elif [[ -z $PREFLIGHT_SCRIPT ]]; then
  if [[ -n $PREFLIGHT_UNSAFE ]]; then
    echo "  [skip] not running $PREFLIGHT_FOUND as root: $PREFLIGHT_UNSAFE."
    echo "  Keep this script in a directory only root or you can write, or pass"
    echo "  --preflight-script with a copy you trust."
  else
    echo "  [skip] ubicloud-host was not found next to this script."
  fi
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
if [ "$TIER" != kvm ]; then
  # A lower tier boots only its own images, and the host downloads the
  # first of them when no --default-boot-image is given.
  echo ""
  echo "This host was prepared for --tier $TIER: add --virt-tier $TIER --accept-fallback"
  echo "to host add (or register-byoh-host), and leave out --default-boot-image."
fi
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
