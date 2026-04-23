#!/bin/bash
# Run on: Proxmox host
# Purpose: Full end-to-end orchestrator
# Log: /var/log/ubicloud-deploy-99.log

set -e
exec > >(tee -a /var/log/ubicloud-deploy-99.log) 2>&1

SCRIPTS_DIR=${SCRIPTS_DIR:-/root/ubicloud-deploy}
CTRL_IP=${CTRL_IP:-10.98.1.10}

cd $SCRIPTS_DIR

echo "PHASE 1/5: Preflight"
bash 00-preflight.sh

echo "PHASE 2/5: Create VMs"
bash 01-create-vms.sh

echo "PHASE 3/5: Post-boot fixup"
bash 02-post-boot-fixup.sh

echo "PHASE 4/5: Bootstrap ctrl plane (via SSH)"
ssh -o StrictHostKeyChecking=accept-new ubuntu@$CTRL_IP "bash /tmp/03-bootstrap-ctrl.sh"

echo "PHASE 5/5: Register BYOH host (via SSH)"
ssh ubuntu@$CTRL_IP "bash /tmp/04-register-host.sh"

echo
echo "==== DEPLOYMENT COMPLETE ===="
LAN_IP=$(ssh ubuntu@$CTRL_IP "ip -4 addr show eth1 | grep -oP '(?<=inet\s)[0-9.]+' | head -1")
echo "Web UI: http://${LAN_IP}:3000/"
echo "Login:  admin@admin.com / password"
echo "Monitor: ssh ubuntu@$CTRL_IP 'bash /tmp/05-monitor.sh'"
