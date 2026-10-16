#!/usr/bin/env bash
# Tear down one run: terminate its instances (their volumes are
# delete-on-termination), release its Elastic IPs and delete its two
# security groups. Only resources tagged both Project=ubicloud-byoh-test
# and E2E=<run> are touched; the VPC, subnet and key pair are kept.
#
#   E2E_RUN=e2e1 ... scripts/byoh/test/aws-e2e/down.sh [role...]
#
# With roles, only those instances are terminated and their addresses
# released; the security groups stay for the rest of the run.
source "$(dirname "$0")/lib.sh"

filters=("Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:E2E,Values=$E2E_RUN")
[[ $# -gt 0 ]] && filters+=("Name=tag:Role,Values=$(IFS=,; echo "$*")")

ids=$(aws ec2 describe-instances --filters "${filters[@]}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n $ids ]]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $ids --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $ids
fi

for alloc in $(aws ec2 describe-addresses --filters "${filters[@]}" --query 'Addresses[].AllocationId' --output text); do
  assoc=$(aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].AssociationId' --output text)
  [[ $assoc != None ]] && aws ec2 disassociate-address --association-id "$assoc"
  aws ec2 release-address --allocation-id "$alloc"
  echo "released $alloc"
done

if [[ $# -eq 0 ]]; then
  for which in data ctrl; do
    sg=$(sg_of "$which")
    [[ -n $sg ]] && aws ec2 delete-security-group --group-id "$sg" && echo "deleted security group $which $sg"
  done
  mv "$STATE_DIR/state" "$STATE_DIR/state.down.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
fi

echo "left in this run:"
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT_TAG" "Key=E2E,Values=$E2E_RUN" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
