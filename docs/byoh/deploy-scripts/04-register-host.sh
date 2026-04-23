#!/bin/bash
# Run on: ctrl plane VM
# Purpose: Generate SSH key, install on data plane, register BYOH host
# Log: /tmp/ubicloud-deploy-04.log

set -e
exec > >(tee -a /tmp/ubicloud-deploy-04.log) 2>&1
echo "===== REGISTER HOST $(date) ====="

DATA_IP=${DATA_IP:-10.98.1.30}
VM_POOL_CIDR=${VM_POOL_CIDR:-10.98.1.128/29}
LOCATION=${LOCATION:-ovh-proxmox}

# Generate ctrl->data key
if [[ ! -f ~/.ssh/byoh_data ]]; then
  ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N '' -C 'ubi-byoh ctrl-to-data'
fi

# Install on data plane
PUBKEY=$(cat ~/.ssh/byoh_data.pub)
ssh -o StrictHostKeyChecking=accept-new ubuntu@$DATA_IP \
  "echo '$PUBKEY' | sudo tee -a /root/.ssh/authorized_keys > /dev/null"

# Verify
ssh -i ~/.ssh/byoh_data -o StrictHostKeyChecking=accept-new root@$DATA_IP 'hostname && ls /dev/kvm' \
  || { echo "ERR: ctrl->data root SSH broken"; exit 1; }
echo "OK ctrl->data SSH"

# Register
echo "--- Registering BYOH host ---"
cd ~/ubicloud
export PATH=$HOME/.local/share/mise/shims:$PATH
export RACK_ENV=development

# Split VM_POOL_CIDR into /32 routed networks for flag compatibility
POOL_BASE=$(echo $VM_POOL_CIDR | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
POOL_LAST=$(echo $VM_POOL_CIDR | cut -d/ -f1 | awk -F. '{print $4}')

bundle exec ruby bin/register-byoh-host \
  --main-ip $DATA_IP \
  --routed-network ${POOL_BASE}.${POOL_LAST}/32 \
  --routed-network ${POOL_BASE}.$((POOL_LAST+1))/32 \
  --routed-network ${POOL_BASE}.$((POOL_LAST+2))/32 \
  --ssh-key ~/.ssh/byoh_data \
  --location $LOCATION \
  --default-boot-image ubuntu-noble \
  --yes 2>&1 | tee /tmp/register-output.log

echo "--- Waiting for host to reach accepting state ---"
for i in $(seq 1 40); do
  sleep 30
  STATE=$(bundle exec ruby -e 'require_relative "loader"; h=DB[:vm_host].first; puts h ? h[:allocation_state] : "none"' 2>/dev/null)
  echo "  [$i/40] allocation_state=$STATE"
  [[ "$STATE" == "accepting" ]] && break
done
[[ "$STATE" != "accepting" ]] && { echo "ERR: host not accepting in 20 min"; exit 1; }

# Auto-disable slice allocation if few cores
CORES=$(bundle exec ruby -e 'require_relative "loader"; puts DB[:vm_host].first[:total_cores]')
if [[ "$CORES" -lt 6 ]]; then
  echo "--- Setting accepts_slices=false (low-tier, $CORES cores) ---"
  bundle exec ruby -e 'require_relative "loader"; DB[:vm_host].update(accepts_slices: false)'
else
  echo "OK keeping accepts_slices=true"
fi

echo
echo "===== REGISTRATION COMPLETE ====="
LAN_IP=$(ip -4 addr show eth1 2>/dev/null | grep -oP '(?<=inet\s)[0-9.]+' | head -1)
echo "Web UI: http://${LAN_IP:-$(hostname -I | awk '{print $2}')}:3000/"
echo "Login:  admin@admin.com / password"
echo "Monitor: bash /tmp/05-monitor.sh"
