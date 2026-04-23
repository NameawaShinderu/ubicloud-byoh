#!/bin/bash
# Run on: Proxmox host
# Purpose: Create VM template + ctrl plane + data plane
# Log: /var/log/ubicloud-deploy-01.log

set -e
exec > >(tee -a /var/log/ubicloud-deploy-01.log) 2>&1
echo "===== CREATE VMs $(date) ====="

# Tunables (override by exporting before running)
VMID_TMPL=${VMID_TMPL:-9000}
VMID_CTRL=${VMID_CTRL:-400}
VMID_DATA=${VMID_DATA:-401}
STORAGE=${STORAGE:-local-lvm}
PUBKEY=${PUBKEY:-/root/.ssh/id_rsa.pub}

# Ctrl plane sizing
CTRL_CORES=${CTRL_CORES:-2}
CTRL_MEM=${CTRL_MEM:-4096}
CTRL_DISK_ADD=${CTRL_DISK_ADD:-38}

# Data plane sizing (18 GB / 8 vCPU / 200 GB default)
DATA_CORES=${DATA_CORES:-8}
DATA_MEM=${DATA_MEM:-18432}
DATA_DISK_ADD=${DATA_DISK_ADD:-198}

# IPs
CTRL_IP=${CTRL_IP:-10.98.1.10}
DATA_IP=${DATA_IP:-10.98.1.30}
GATEWAY=${GATEWAY:-10.98.1.1}

# Template
if ! qm status $VMID_TMPL &>/dev/null; then
  echo "--- Creating template $VMID_TMPL ---"
  qm create $VMID_TMPL --name ubi-byoh-template --memory 2048 --cores 2 \
    --sockets 1 --net0 virtio,bridge=vmbr1 --serial0 socket \
    --vga serial0 --agent enabled=1 --ostype l26
  qm importdisk $VMID_TMPL /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img $STORAGE
  qm set $VMID_TMPL --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID_TMPL-disk-0
  qm set $VMID_TMPL --boot c --bootdisk scsi0
  qm set $VMID_TMPL --ide2 $STORAGE:cloudinit
  qm template $VMID_TMPL
fi
echo "OK template"

# Ctrl plane
if ! qm status $VMID_CTRL &>/dev/null; then
  echo "--- Creating ctrl plane $VMID_CTRL ---"
  qm clone $VMID_TMPL $VMID_CTRL --name ubi-byoh-ctrl --full
  qm set $VMID_CTRL --cores $CTRL_CORES --memory $CTRL_MEM
  qm set $VMID_CTRL --net0 virtio,bridge=vmbr1
  qm set $VMID_CTRL --net1 virtio,bridge=vmbr0
  qm set $VMID_CTRL --ipconfig0 ip=${CTRL_IP}/24,gw=${GATEWAY}
  qm set $VMID_CTRL --ipconfig1 ip=dhcp
  qm set $VMID_CTRL --sshkeys $PUBKEY
  qm set $VMID_CTRL --ciuser ubuntu --cipassword ubuntu
  qm set $VMID_CTRL --nameserver 1.1.1.1 --searchdomain local
  qm resize $VMID_CTRL scsi0 +${CTRL_DISK_ADD}G
  qm start $VMID_CTRL
else
  qm status $VMID_CTRL | grep -q running || qm start $VMID_CTRL
fi
echo "OK ctrl plane"

# Data plane - cpu=host is critical
if ! qm status $VMID_DATA &>/dev/null; then
  echo "--- Creating data plane $VMID_DATA ---"
  qm clone $VMID_TMPL $VMID_DATA --name ubi-byoh-data --full
  qm set $VMID_DATA --cores $DATA_CORES --memory $DATA_MEM --cpu host
  qm set $VMID_DATA --net0 virtio,bridge=vmbr1
  qm set $VMID_DATA --net1 virtio,bridge=vmbr0
  qm set $VMID_DATA --ipconfig0 ip=${DATA_IP}/24,gw=${GATEWAY}
  qm set $VMID_DATA --ipconfig1 ip=dhcp
  qm set $VMID_DATA --sshkeys $PUBKEY
  qm set $VMID_DATA --ciuser ubuntu --cipassword ubuntu
  qm set $VMID_DATA --nameserver 1.1.1.1 --searchdomain local
  qm resize $VMID_DATA scsi0 +${DATA_DISK_ADD}G
  qm start $VMID_DATA
else
  qm status $VMID_DATA | grep -q running || qm start $VMID_DATA
fi
echo "OK data plane (${DATA_CORES} vCPU / ${DATA_MEM}MB / +${DATA_DISK_ADD}GB)"

echo "--- Waiting 90s for cloud-init ---"
sleep 90

# Verify
echo "--- Verify ctrl ($CTRL_IP) ---"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$CTRL_IP "hostname && nproc && free -h | grep Mem" \
  || { echo "ERR: ctrl plane unreachable"; exit 1; }

echo "--- Verify data ($DATA_IP) ---"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$DATA_IP "hostname && nproc && free -h | grep Mem && ls /dev/kvm && grep -c vmx /proc/cpuinfo" \
  || { echo "ERR: data plane unreachable or nested virt broken"; exit 1; }

echo
echo "===== VMs CREATED ====="
echo "Next: bash 02-post-boot-fixup.sh"
