# shellcheck shell=bash
# Shared settings for the AWS end-to-end harness (see README.md).
#
# Everything this harness creates carries Project=ubicloud-byoh-test and
# E2E=<run>, and teardown only ever touches resources that carry both:
# the account is shared with production.

set -euo pipefail

: "${E2E_RUN:?set E2E_RUN, a short run name such as e2e1}"
[[ $E2E_RUN =~ ^[a-z0-9-]{1,16}$ ]] || { echo "E2E_RUN must match [a-z0-9-]{1,16}" >&2; exit 2; }

export AWS_PROFILE=${AWS_PROFILE:-ubi-byoh}
export AWS_REGION=${AWS_REGION:-ap-south-1}
: "${E2E_VPC:?set E2E_VPC, an existing VPC tagged Project=ubicloud-byoh-test}"
: "${E2E_SUBNET:?set E2E_SUBNET, a public subnet in E2E_VPC}"
: "${E2E_KEY_NAME:?set E2E_KEY_NAME, the EC2 key pair name}"
: "${E2E_KEY:?set E2E_KEY, the private key file of that key pair}"
: "${E2E_OPERATOR_CIDR:?set E2E_OPERATOR_CIDR, the operator address as a /32}"

PROJECT_TAG=ubicloud-byoh-test
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
STATE_DIR=$REPO/var/aws-e2e/$E2E_RUN
mkdir -p "$STATE_DIR"
chmod 700 "$REPO/var/aws-e2e" "$STATE_DIR"

# role:type:root_gib:nested:secondary_ips:eip_on(primary|secondary|none):extra_gib:user_data(data|none)
ROLE_TABLE=(
  "ctrl:t3.large:40:no:0:primary:0:none"
  "kvm:m8i.2xlarge:120:yes:2:secondary:50:data"
  "ct:t3.xlarge:100:no:1:secondary:0:data"
  "emu:t3.xlarge:60:no:1:none:0:data"
  "pvm:m6i.large:60:no:0:none:0:none"
)

role_field() { # role field-index
  local r
  for r in "${ROLE_TABLE[@]}"; do
    IFS=: read -r -a f <<<"$r"
    [[ ${f[0]} == "$1" ]] && { echo "${f[$2]}"; return; }
  done
  echo "unknown role $1" >&2
  return 2
}

name_of() { echo "ubi-e2e-$E2E_RUN-$1"; }

tag_spec() { # resource-type role
  echo "ResourceType=$1,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=E2E,Value=$E2E_RUN},{Key=Role,Value=$2},{Key=Name,Value=$(name_of "$2")}]"
}

instance_of() { # role -> instance id of a live instance, or nothing
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:E2E,Values=$E2E_RUN" "Name=tag:Role,Values=$1" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

sg_of() { # ctrl|data -> group id, or nothing
  aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$E2E_VPC" "Name=tag:E2E,Values=$E2E_RUN" "Name=tag:Project,Values=$PROJECT_TAG" "Name=group-name,Values=$(name_of "$1")" \
    --query 'SecurityGroups[].GroupId' --output text
}

state() { # key -> value from the state file
  sed -n "s/^$1=//p" "$STATE_DIR/state" 2>/dev/null | tail -1
}
