#!/usr/bin/env bash
# ssh to a role of the run as ubuntu: the control plane directly, every
# other role through the control plane (data planes have no inbound rule
# from the internet).
#
#   E2E_RUN=e2e1 ... scripts/byoh/test/aws-e2e/ssh.sh kvm 'uname -r'
source "$(dirname "$0")/lib.sh"

role=${1:?role}
shift
kh=$STATE_DIR/known_hosts
opts=(-i "$E2E_KEY" -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=15)
ctrl=$(state CTRL_PUB)
[[ -n $ctrl ]] || { echo "no control plane in this run" >&2; exit 2; }
if [[ $role == ctrl ]]; then
  exec ssh "${opts[@]}" "ubuntu@$ctrl" "$@"
fi
target=$(state "${role^^}_PRIV")
[[ -n $target ]] || { echo "no $role in this run" >&2; exit 2; }
exec ssh "${opts[@]}" -o ProxyCommand="ssh ${opts[*]} -W %h:%p ubuntu@$ctrl" "ubuntu@$target" "$@"
