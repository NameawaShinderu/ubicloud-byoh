#!/bin/bash
# Run on: Proxmox host
# Purpose: Verify hardware, enable nested virt, create bridge vmbr1
# Log: /var/log/ubicloud-deploy-00.log

set -e
exec > >(tee -a /var/log/ubicloud-deploy-00.log) 2>&1
echo "===== PREFLIGHT $(date) ====="

# Proxmox version
PVE_VER=$(pveversion | grep -oP '(?<=pve-manager/)[0-9]+')
[[ "$PVE_VER" -lt 8 ]] && { echo "ERR: need PVE 8+"; exit 1; }
echo "OK PVE version"

# CPU virt
if grep -q vmx /proc/cpuinfo; then CPU=intel
elif grep -q svm /proc/cpuinfo; then CPU=amd
else echo "ERR: no VT-x/SVM - enable in BIOS"; exit 1; fi
echo "OK CPU: $CPU"

# Nested virt
NESTED_FILE=/sys/module/kvm_${CPU}/parameters/nested
if [[ "$(cat $NESTED_FILE 2>/dev/null)" != "Y" ]]; then
  echo "  enabling nested virt..."
  if [[ "$CPU" == "intel" ]]; then
    echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
  else
    echo "options kvm-amd nested=1" > /etc/modprobe.d/kvm-amd.conf
  fi
  update-initramfs -u -k all
  echo "REBOOT REQUIRED. Run: reboot. Then re-run this script."
  exit 2
fi
echo "OK nested virt enabled"

# Resources
RAM_GB=$(free -g | awk '/Mem:/{print $2}')
CPUS=$(nproc)
DISK_GB=$(df -BG /var/lib/vz | tail -1 | awk '{print $4}' | tr -d G)
[[ "$RAM_GB" -lt 20 ]] && { echo "ERR: need 20+ GB RAM (have $RAM_GB)"; exit 1; }
[[ "$CPUS" -lt 4 ]] && { echo "ERR: need 4+ CPUs (have $CPUS)"; exit 1; }
[[ "$DISK_GB" -lt 250 ]] && { echo "ERR: need 250+ GB disk (have $DISK_GB GB)"; exit 1; }
echo "OK resources: ${RAM_GB}GB RAM, ${CPUS} CPUs, ${DISK_GB}GB disk"

# vmbr1
if ! grep -q "^auto vmbr1" /etc/network/interfaces; then
  echo "  creating vmbr1 bridge..."
  cat >> /etc/network/interfaces << 'EOF'

auto vmbr1
iface vmbr1 inet static
    address 10.98.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -s 10.98.1.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.98.1.0/24 -o vmbr0 -j MASQUERADE
EOF
  ifreload -a
fi
ip -brief addr show vmbr1 | grep -q 10.98.1.1 || { echo "ERR: vmbr1 not up"; exit 1; }
echo "OK vmbr1 bridge"

# SSH key
[[ -f /root/.ssh/id_rsa.pub ]] || ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ''
echo "OK SSH key"

# Cloud image
cd /var/lib/vz/template/iso
if [[ ! -f noble-server-cloudimg-amd64.img ]]; then
  echo "  downloading Ubuntu 24.04 cloud image..."
  wget -q --show-progress https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
fi
echo "OK cloud image"

echo
echo "===== PREFLIGHT COMPLETE ====="
echo "Next: bash 01-create-vms.sh"
