#!/usr/bin/env bash
# Create (or complete) one end-to-end run on AWS: two security groups,
# the instances in ROLES (default: all of lib.sh's ROLE_TABLE), and their
# Elastic IPs. Safe to re-run; it only adds what is missing.
#
#   E2E_RUN=e2e1 ... scripts/byoh/test/aws-e2e/up.sh [role...]
#
# Data planes get no inbound rule from the internet: VM ingress stays
# closed until host_guard (M7) exists. The control plane takes SSH and
# 443 from the operator address only, and 80 from anywhere for ACME.
source "$(dirname "$0")/lib.sh"

roles=("$@")
if [[ ${#roles[@]} -eq 0 ]]; then
  for r in "${ROLE_TABLE[@]}"; do roles+=("${r%%:*}"); done
fi

vpc_project=$(aws ec2 describe-vpcs --vpc-ids "$E2E_VPC" --query "Vpcs[0].Tags[?Key=='Project'].Value|[0]" --output text)
[[ $vpc_project == "$PROJECT_TAG" ]] || { echo "refusing: $E2E_VPC is not tagged Project=$PROJECT_TAG" >&2; exit 2; }

ensure_sg() { # ctrl|data
  local id
  id=$(sg_of "$1")
  if [[ -z $id ]]; then
    id=$(aws ec2 create-security-group --vpc-id "$E2E_VPC" --group-name "$(name_of "$1")" \
      --description "ubicloud BYOH e2e $E2E_RUN $1" \
      --tag-specifications "$(tag_spec security-group "sg-$1")" --query GroupId --output text)
    echo "created security group $1 $id" >&2
  fi
  echo "$id"
}

allow() { # sg-id ip-permissions-json
  aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$2" >/dev/null 2>&1 || true
}

SG_CTRL=$(ensure_sg ctrl)
SG_DATA=$(ensure_sg data)
allow "$SG_CTRL" "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"$E2E_OPERATOR_CIDR\"}]}]"
allow "$SG_CTRL" "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"$E2E_OPERATOR_CIDR\"}]}]"
allow "$SG_CTRL" '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]'
allow "$SG_DATA" "[{\"IpProtocol\":\"-1\",\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_CTRL\"},{\"GroupId\":\"$SG_DATA\"}]}]"

AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
{ echo "SG_CTRL=$SG_CTRL"; echo "SG_DATA=$SG_DATA"; echo "AMI=$AMI"; } >>"$STATE_DIR/state"

for role in "${roles[@]}"; do
  type=$(role_field "$role" 1); root=$(role_field "$role" 2); nested=$(role_field "$role" 3)
  secondaries=$(role_field "$role" 4); extra=$(role_field "$role" 6); ud=$(role_field "$role" 7)
  if [[ -n $(instance_of "$role") ]]; then
    echo "$role: exists"
    continue
  fi
  sg=$SG_DATA; [[ $role == ctrl ]] && sg=$SG_CTRL
  bdm="[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$root,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}"
  [[ $extra -gt 0 ]] && bdm+=",{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":$extra,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}"
  bdm+="]"
  nic="{\"DeviceIndex\":0,\"SubnetId\":\"$E2E_SUBNET\",\"Groups\":[\"$sg\"],\"AssociatePublicIpAddress\":true"
  [[ $secondaries -gt 0 ]] && nic+=",\"SecondaryPrivateIpAddressCount\":$secondaries"
  nic+="}"
  # shellcheck disable=SC2054 # the commas belong to the option value
  args=(--image-id "$AMI" --instance-type "$type" --key-name "$E2E_KEY_NAME"
    --network-interfaces "[$nic]"
    --block-device-mappings "$bdm"
    --metadata-options HttpTokens=required,HttpEndpoint=enabled
    --tag-specifications "$(tag_spec instance "$role")" "$(tag_spec volume "$role")" "$(tag_spec network-interface "$role")")
  [[ $nested == yes ]] && args+=(--cpu-options NestedVirtualization=enabled)
  [[ $ud == data ]] && args+=(--user-data "file://$REPO/terraform/aws-byoh/user-data-data.sh")
  id=$(aws ec2 run-instances "${args[@]}" --query 'Instances[0].InstanceId' --output text)
  echo "$role: launched $id ($type)"
done

for role in "${roles[@]}"; do
  id=$(instance_of "$role")
  aws ec2 wait instance-running --instance-ids "$id"
  read -r priv pub eni < <(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,NetworkInterfaces[0].NetworkInterfaceId]' --output text)
  # shellcheck disable=SC2016 # JMESPath literal, not shell
  secs=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
    --query 'NetworkInterfaces[0].PrivateIpAddresses[?Primary==`false`].PrivateIpAddress' --output text | tr '\t' ',')
  eip_on=$(role_field "$role" 5)
  eip=""
  if [[ $eip_on != none ]]; then
    target=$priv; [[ $eip_on == secondary ]] && target=${secs%%,*}
    eip=$(aws ec2 describe-addresses --filters "Name=tag:E2E,Values=$E2E_RUN" "Name=tag:Role,Values=$role" --query 'Addresses[0].PublicIp' --output text)
    if [[ $eip == None || -z $eip ]]; then
      alloc=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tag_spec elastic-ip "$role")" --query AllocationId --output text)
      aws ec2 associate-address --allocation-id "$alloc" --network-interface-id "$eni" --private-ip-address "$target" >/dev/null
      eip=$(aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].PublicIp' --output text)
    fi
    [[ $eip_on == primary ]] && pub=$eip
  fi
  {
    echo "${role^^}_ID=$id"; echo "${role^^}_PRIV=$priv"; echo "${role^^}_PUB=$pub"
    echo "${role^^}_SECONDARY=$secs"; echo "${role^^}_EIP=$eip"
  } >>"$STATE_DIR/state"
  echo "$role: $id private=$priv public=$pub secondary=$secs eip=$eip"
done
