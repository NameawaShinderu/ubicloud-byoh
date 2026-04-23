#!/bin/bash
# Run on: Proxmox host
# Purpose: Fix root SSH on data plane, stage scripts for ctrl plane
# Log: /var/log/ubicloud-deploy-02.log

set -e
exec > >(tee -a /var/log/ubicloud-deploy-02.log) 2>&1
echo "===== POST-BOOT FIXUP $(date) ====="

CTRL_IP=${CTRL_IP:-10.98.1.10}
DATA_IP=${DATA_IP:-10.98.1.30}
SCRIPTS_DIR=${SCRIPTS_DIR:-/root/ubicloud-deploy}

# Clear stale host keys
ssh-keygen -f /root/.ssh/known_hosts -R $CTRL_IP 2>/dev/null || true
ssh-keygen -f /root/.ssh/known_hosts -R $DATA_IP 2>/dev/null || true

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts"

echo "--- Fix root SSH on data plane ---"
ssh $SSH_OPTS ubuntu@$DATA_IP "sudo sed -i 's/.*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
ssh $SSH_OPTS ubuntu@$DATA_IP "sudo systemctl restart ssh"
ssh $SSH_OPTS ubuntu@$DATA_IP "sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys"
ssh $SSH_OPTS ubuntu@$DATA_IP "sudo chmod 600 /root/.ssh/authorized_keys"

ssh $SSH_OPTS root@$DATA_IP "whoami" | grep -q root || { echo "ERR: root SSH broken"; exit 1; }
echo "OK root SSH"

echo "--- Stage scripts on ctrl plane ---"
scp $SSH_OPTS $SCRIPTS_DIR/03-bootstrap-ctrl.sh ubuntu@$CTRL_IP:/tmp/
scp $SSH_OPTS $SCRIPTS_DIR/04-register-host.sh ubuntu@$CTRL_IP:/tmp/
scp $SSH_OPTS $SCRIPTS_DIR/05-monitor.sh ubuntu@$CTRL_IP:/tmp/
ssh $SSH_OPTS ubuntu@$CTRL_IP "chmod +x /tmp/0*.sh"
echo "OK scripts staged"

echo
echo "===== POST-BOOT FIXUP COMPLETE ====="
echo "Next: ssh ubuntu@$CTRL_IP 'bash /tmp/03-bootstrap-ctrl.sh'"
