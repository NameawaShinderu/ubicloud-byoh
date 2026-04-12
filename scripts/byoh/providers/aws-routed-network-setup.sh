#!/usr/bin/env bash
# ====================================================================
#  aws-routed-network-setup.sh — AWS-specific BYOH routing pre-work
# ====================================================================
#
# Sets up the routing fabric so that a pool of real, publicly-reachable
# IPs are delivered to a BYOH data plane instance on AWS. This is the
# AWS equivalent of "ordering a routed /29 from Hetzner" — a one-time
# host-registration step that creates the pool Ubicloud will dynamically
# allocate from per-VM.
#
# The script does three things:
#
#   1. Disable source/dest check on the data plane instance so its
#      kernel can forward packets for IPs it doesn't own.
#
#   2. Assign N secondary private IPs to the data plane's ENI. These
#      become the routable pool — AWS's VPC fabric delivers any packet
#      destined for these IPs to the ENI natively (no route table hack).
#
#   3. Allocate M Elastic IPs (M <= N) and associate each with one of
#      the secondary private IPs. Each (private IP, EIP) pair is a
#      1:1 NAT: inbound traffic to the EIP from the public internet
#      gets DNAT'd by AWS's edge to the private IP -> delivered to the
#      ENI -> the host's kernel forwards it to the VM's tap. Outbound
#      traffic from the VM gets SNAT'd back to the EIP.
#
# After this, Ubicloud sees a pool of N private IPs in its routed_
# networks config. It allocates them to VMs dynamically. Each VM that
# gets an IP with an associated EIP is publicly reachable on the
# internet; each VM that doesn't is internal-only (reachable from the
# VPC or via the control plane as a jumpbox).
#
# Why this instead of "just use a route table entry":
# AWS VPC rejects route-table entries whose destination CIDR is inside
# the VPC's own main CIDR (InvalidParameterValue, "Route destination
# doesn't match any subnet CIDR blocks"). The ONLY supported way to
# route extra IPs inside the VPC CIDR to a specific instance is via
# secondary private IPs on its ENI. This script uses that supported
# path.
#
# Requirements:
#   - aws-cli installed and authenticated (env vars or ~/.aws)
#   - jq for JSON parsing
#   - The data plane instance ID (from bootstrap or user-provided)
#   - The number of private IPs + EIPs you want (default: 3 each)
#
# Usage:
#   INSTANCE_ID=i-0d358c50020234aac \
#   START_OFFSET=128 \
#   POOL_SIZE=3 \
#   EIP_COUNT=3 \
#   ./scripts/byoh/providers/aws-routed-network-setup.sh
#
set -euo pipefail

: "${INSTANCE_ID:?INSTANCE_ID env var required (e.g. i-0d358c50020234aac)}"
START_OFFSET="${START_OFFSET:-128}"
POOL_SIZE="${POOL_SIZE:-3}"
EIP_COUNT="${EIP_COUNT:-$POOL_SIZE}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo ap-south-1)}"

if [ "$EIP_COUNT" -gt "$POOL_SIZE" ]; then
  echo "ERROR: EIP_COUNT ($EIP_COUNT) must be <= POOL_SIZE ($POOL_SIZE)" >&2
  exit 1
fi

# Ubuntu 24.04 no longer ships awscli via apt. Install AWS CLI v2
# from the official bundle if missing. Idempotent — skips if already
# installed.
if ! command -v aws >/dev/null 2>&1; then
  echo "==> installing aws-cli v2 from official bundle (Ubuntu 24.04 dropped the apt package)..."
  TMPD=$(mktemp -d)
  (cd "$TMPD" && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && \
    unzip -q awscliv2.zip && \
    sudo ./aws/install)
  rm -rf "$TMPD"
fi

# jq is required for the JSON parsing in step 4
if ! command -v jq >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get install -y jq
fi

export AWS_DEFAULT_REGION="$AWS_REGION"

step() { echo ""; echo "=====  $*  ====="; }

# --- Step 1: inspect the instance -----------------------------------
step "1. inspect instance $INSTANCE_ID"
ENI=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' \
  --output text)
PRIMARY_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
SUBNET_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SubnetId' --output text)
SUBNET_CIDR=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].CidrBlock' --output text)

echo "  instance: $INSTANCE_ID"
echo "  eni: $ENI"
echo "  primary private IP: $PRIMARY_IP"
echo "  subnet: $SUBNET_ID ($SUBNET_CIDR)"

SUBNET_PREFIX=$(echo "$SUBNET_CIDR" | cut -d/ -f1 | cut -d. -f1-3)
POOL_IPS=()
for i in $(seq 0 $((POOL_SIZE - 1))); do
  POOL_IPS+=("$SUBNET_PREFIX.$((START_OFFSET + i))")
done
echo "  pool of $POOL_SIZE private IPs: ${POOL_IPS[*]}"

for ip in "${POOL_IPS[@]}"; do
  if [ "$ip" = "$PRIMARY_IP" ]; then
    echo "ERROR: pool IP $ip collides with primary IP. Increase START_OFFSET." >&2
    exit 1
  fi
done

# --- Step 2: disable source/dest check ------------------------------
step "2. disable source/dest check on $INSTANCE_ID"
CURRENT=$(aws ec2 describe-instance-attribute --instance-id "$INSTANCE_ID" \
  --attribute sourceDestCheck --query 'SourceDestCheck.Value' --output text)
if [ "$CURRENT" = "False" ]; then
  echo "  [skip] source/dest check already disabled"
else
  aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" \
    --source-dest-check '{"Value": false}'
  echo "  disabled"
fi

# --- Step 3: assign secondary private IPs --------------------------
step "3. assign $POOL_SIZE secondary private IPs to $ENI"
EXISTING_IPS=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --query 'NetworkInterfaces[0].PrivateIpAddresses[*].PrivateIpAddress' --output text)
IPS_TO_ADD=()
for ip in "${POOL_IPS[@]}"; do
  if echo "$EXISTING_IPS" | grep -qw "$ip"; then
    echo "  [skip] $ip already on ENI"
  else
    IPS_TO_ADD+=("$ip")
  fi
done
if [ "${#IPS_TO_ADD[@]}" -gt 0 ]; then
  aws ec2 assign-private-ip-addresses --network-interface-id "$ENI" \
    --private-ip-addresses "${IPS_TO_ADD[@]}"
  echo "  assigned: ${IPS_TO_ADD[*]}"
fi

# --- Step 4: allocate + associate EIPs -----------------------------
step "4. allocate $EIP_COUNT EIPs + associate with secondary IPs"

ENI_JSON=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --output json)
EIP_MAP_JSON="{}"
for i in $(seq 0 $((EIP_COUNT - 1))); do
  PRIVATE_IP="${POOL_IPS[$i]}"
  EXISTING_ASSOC=$(echo "$ENI_JSON" | jq -r --arg ip "$PRIVATE_IP" '.NetworkInterfaces[0].PrivateIpAddresses[] | select(.PrivateIpAddress==$ip) | .Association.PublicIp // empty')
  if [ -n "$EXISTING_ASSOC" ]; then
    echo "  [skip] $PRIVATE_IP already has EIP $EXISTING_ASSOC"
    EIP_PUBLIC="$EXISTING_ASSOC"
  else
    ALLOC_JSON=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=ubi-byoh-eip-${i}-$(date +%s)},{Key=Project,Value=ubicloud-byoh-test},{Key=PrivateTarget,Value=$PRIVATE_IP}]" \
      --output json)
    ALLOC_ID=$(echo "$ALLOC_JSON" | jq -r .AllocationId)
    EIP_PUBLIC=$(echo "$ALLOC_JSON" | jq -r .PublicIp)
    echo "  allocated $EIP_PUBLIC ($ALLOC_ID)"
    aws ec2 associate-address --allocation-id "$ALLOC_ID" \
      --network-interface-id "$ENI" --private-ip-address "$PRIVATE_IP" > /dev/null
    echo "  associated $EIP_PUBLIC -> $PRIVATE_IP"
  fi
  EIP_MAP_JSON=$(echo "$EIP_MAP_JSON" | jq --arg k "$PRIVATE_IP" --arg v "$EIP_PUBLIC" '. + {($k): $v}')
done

# --- Step 5: emit summary ------------------------------------------
step "DONE"
cat <<JSON
{
  "instance_id": "$INSTANCE_ID",
  "eni": "$ENI",
  "primary_private_ip": "$PRIMARY_IP",
  "subnet": "$SUBNET_ID",
  "subnet_cidr": "$SUBNET_CIDR",
  "pool": $(printf '%s\n' "${POOL_IPS[@]}" | jq -R . | jq -s .),
  "private_to_eip_map": $EIP_MAP_JSON
}
JSON

echo ""
echo "Next step - register this data plane with Ubicloud:"
echo ""
ROUTED_FLAGS=""
for ip in "${POOL_IPS[@]}"; do
  ROUTED_FLAGS="$ROUTED_FLAGS --routed-network $ip/32"
done
echo "  bundle exec bin/register-byoh-host \\"
echo "    --main-ip $PRIMARY_IP \\$ROUTED_FLAGS \\"
echo "    --routed-network fd00:aa55::/64 \\"
echo "    --location byoh-\$region \\"
echo "    --ssh-key \$HOME/.ssh/byoh_ctrl_key --yes"
echo ""
echo "Public SSH access to VMs uses the EIPs in private_to_eip_map above."
