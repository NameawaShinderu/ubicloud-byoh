#!/bin/bash
# Run on: Proxmox host
# Purpose: Destroy all Ubicloud VMs to start over

VMID_TMPL=${VMID_TMPL:-9000}
VMID_CTRL=${VMID_CTRL:-400}
VMID_DATA=${VMID_DATA:-401}

read -p "Destroy VMs $VMID_CTRL, $VMID_DATA, $VMID_TMPL? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 0

for vmid in $VMID_CTRL $VMID_DATA $VMID_TMPL; do
  qm status $vmid &>/dev/null || { echo "(VM $vmid not found, skipping)"; continue; }
  echo "--- Destroying VM $vmid ---"
  qm stop $vmid --skiplock 2>/dev/null || true
  sleep 2
  qm destroy $vmid --purge
done

# Clear stale host keys
ssh-keygen -f /root/.ssh/known_hosts -R 10.98.1.10 2>/dev/null || true
ssh-keygen -f /root/.ssh/known_hosts -R 10.98.1.30 2>/dev/null || true

echo "OK VMs destroyed"
echo "Re-deploy: bash /root/ubicloud-deploy/99-deploy-all.sh"
