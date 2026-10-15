#!/bin/bash
# Self-check for the M4 fakehost (WP1): builds ubi-m4-fakehost, starts
# two containers on ubi-test-net, logs in from one to the other with
# the per-run RSA key, and checks sudo, the systemctl shim and that
# auth events reach `docker logs`. Removes what it created, and fails
# if any ubi-m4-* container is left.
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

prepare_fakehost_image
start_fakehost fakehost -e "FAKEHOST_ACTIVE=docker ufw.service"
start_fakehost client
ip=$(fakehost_ip fakehost)
docker exec -i "$PREFIX-client" install -m 0600 /dev/stdin /root/key <"$(fakehost_key)"

rssh() {
  docker exec "$PREFIX-client" ssh -i /root/key -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/kh "ubuntu@$ip" "$@"
}

[[ $(rssh 'sudo -n id -u') == 0 ]] || fail "passwordless sudo"
grep -q "Accepted publickey for ubuntu" <<<"$(docker logs "$PREFIX-fakehost" 2>&1)" ||
  fail "auth event not in docker logs"
[[ -z $(dx fakehost find /dev -maxdepth 1 -name kvm) ]] || fail "/dev/kvm present"

# The host key the client pinned is the container's own, not the image's.
pinned=$(docker exec "$PREFIX-client" ssh-keygen -lf /root/kh -E sha256 | awk '{print $2}' | sort)
# shellcheck disable=SC2016
host=$(dx fakehost bash -c 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f" -E sha256; done' | awk '{print $2}')
grep -qxF "$pinned" <<<"$host" || fail "pinned host key $pinned not among the container's"
[[ $(dx client bash -c 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $2}') != \
  $(dx fakehost bash -c 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $2}') ]] ||
  fail "host keys shared between containers"

# is-active answers from FAKEHOST_ACTIVE.
[[ $(rssh 'systemctl is-active docker') == active ]] || fail "is-active docker"
rssh 'systemctl is-active --quiet ufw' || fail "is-active ufw"
if rssh 'systemctl is-active tailscaled' >/dev/null; then fail "is-active tailscaled"; fi
rssh 'sudo systemctl daemon-reload' || fail "other verbs exit 0"

# reload ssh: sshd rereads its config and keeps serving.
rssh 'echo "Banner /etc/issue.net" | sudo tee /etc/ssh/sshd_config.d/50-check.conf >/dev/null && sudo sshd -t && sudo systemctl reload ssh.service' ||
  fail "reload ssh"
wait_for 10 bash -c "docker logs $PREFIX-fakehost 2>&1 | grep 'Received SIGHUP'" >/dev/null || fail "no SIGHUP in docker logs"
wait_for 10 docker exec "$PREFIX-fakehost" bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' >/dev/null || fail "sshd gone after reload"
[[ $(rssh 'sudo sshd -T | grep -i "^banner"') == "banner /etc/issue.net" ]] || fail "sshd -T after reload"
rssh true || fail "login after reload"
grep -q "root: systemctl reload ssh.service" <<<"$(dx fakehost cat /var/log/fakehost-systemctl.log)" || fail "shim log"

# A reload fails, and sends no SIGHUP, without root (polkit refuses it
# on a real host) or with a config `sshd -t` rejects; sshd keeps serving.
hups() { docker logs "$PREFIX-fakehost" 2>&1 | grep -c 'Received SIGHUP' || true; }
before=$(hups)
if rssh 'systemctl reload ssh' 2>/dev/null; then fail "reload without sudo exited 0"; fi
rssh 'echo "NotAnOption yes" | sudo tee /etc/ssh/sshd_config.d/60-bad.conf >/dev/null' || fail "write bad drop-in"
if rssh 'sudo systemctl reload ssh' 2>/dev/null; then fail "reload with a bad drop-in exited 0"; fi
if rssh 'sudo systemctl restart sshd' 2>/dev/null; then fail "restart with a bad drop-in exited 0"; fi
[[ $(docker inspect -f '{{.State.Running}}' "$PREFIX-fakehost") == true ]] || fail "fakehost died on a failed reload"
[[ $(hups) == "$before" ]] || fail "a failed reload sent SIGHUP"
rssh true || fail "login after a failed reload"
rssh 'sudo rm /etc/ssh/sshd_config.d/60-bad.conf' || fail "remove bad drop-in"

cleanup
left=$(docker ps -aq --filter "name=^$PREFIX-")
[[ -z $left ]] || fail "left behind: $(docker ps -a --filter "name=^$PREFIX-" --format '{{.Names}}' | tr '\n' ' ')"
say "PASS m4 fakehost (logs: $LOGS)"
