#!/bin/bash
# Cases for ByohHostAdd::INSTALL_SCRIPT, the script `byoh-host add`
# runs as root to install the registration key and, when needed, a
# drop-in that lets root log in with a key. The Ruby specs only feed it
# canned exit statuses; this runs the script itself on a fakehost.
#
# The script and its argument line are rendered by ByohOperatorSsh#
# run_script in a ubi-bundler-m1 container (UBI_M4_RUBY_IMAGE), so the
# fakehost gets exactly the stdin and remote command add sends. Each
# case then logs in from a second fakehost as `ubuntu`, as an operator
# would, and checks root's authorized_keys, the drop-in, the exit
# status and that sshd still serves. Exit statuses 10 (sshd -t fails)
# and 14 (no reload) are forced with per-case shims in /usr/local/sbin,
# which sudo's secure_path puts before the real tools.
#
# Not covered: a socket-activated ssh.socket (the fakehost has no
# systemd), so a reload there stays UNVERIFIED.
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

RUBY_IMAGE=${UBI_M4_RUBY_IMAGE:-ubi-bundler-m1}
AK=/root/.ssh/authorized_keys
DROPIN=/etc/ssh/sshd_config.d/05-ubicloud-root.conf

prepare_fakehost_image
start_fakehost host
start_fakehost client
ip=$(fakehost_ip host)
cp_ip=$(fakehost_ip client)
docker exec -i "$PREFIX-client" install -m 0600 /dev/stdin /root/key <"$(fakehost_key)"

rm -f "$STATE/reg" "$STATE/reg.pub"
ssh-keygen -q -t ed25519 -N "" -C "" -f "$STATE/reg"
docker exec -i "$PREFIX-client" install -m 0600 /dev/stdin /root/reg <"$STATE/reg"
key=$(cut -d' ' -f1,2 "$STATE/reg.pub")
tag="ubicloud-byoh site=s1 ip=$ip"

# The remote command and stdin that add sends, from the Ruby code.
# shellcheck disable=SC2016
docker run --rm --name "$PREFIX-render" --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$WT:/app:ro" -v "$STATE:/out" -w /app "$RUBY_IMAGE" \
  bundle exec ruby -e '
    require "tmpdir"
    # lib/net_ssh.rb reads Config as it loads; run_script never uses
    # it, so the database and the env file stay out of this.
    module Config
      def self.unfrozen_test? = false
      def self.test? = false
    end
    require "./lib/byoh_operator_ssh"
    require "./lib/byoh_host_add"
    key, tag, cp = ARGV
    Dir.mktmpdir do |dir|
      runner = lambda do |argv, stdin|
        File.write("/out/install.cmd", argv.last)
        File.write("/out/install.stdin", stdin)
        ["", "", 0]
      end
      ByohOperatorSsh.new("ubuntu@#{cp}", dir, runner:).run_script(ByohHostAdd::INSTALL_SCRIPT, [key, tag, cp])
    end
  ' "$key" "$tag" "$cp_ip"
[[ -s $STATE/install.cmd && -s $STATE/install.stdin ]] || fail "rendering INSTALL_SCRIPT"
say "rendered: $(cut -c1-60 "$STATE/install.cmd")..."

dx host cp -a /etc/ssh/sshd_config /root/sshd_config.orig
dx host bash -c 'test -s /run/sshd.pid' || fail "fakehost sshd wrote no /run/sshd.pid"

# install: runs the script as add does; sets rc, and leaves its output
# in $STATE/out and $STATE/err.
install() {
  rc=0
  docker exec -i "$PREFIX-client" ssh -i /root/key -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/kh "ubuntu@$ip" "$(cat "$STATE/install.cmd")" \
    <"$STATE/install.stdin" >"$STATE/out" 2>"$STATE/err" || rc=$?
}

expect_rc() {
  [[ $rc == "$1" ]] || fail "$2: exit $rc, not $1 (stdout: $(tr '\n' ' ' <"$STATE/out"); stderr: $(tr '\n' ' ' <"$STATE/err"))"
}

# The fakehost as the image left it, sshd serving that config.
reset_host() {
  # shellcheck disable=SC2016
  dx host bash -c '
    rm -f /etc/ssh/sshd_config.d/*.conf /usr/local/sbin/sshd /usr/local/sbin/systemctl
    cp /root/sshd_config.orig /etc/ssh/sshd_config
    [[ -f /root/sshd.pid ]] && mv /root/sshd.pid /run/sshd.pid
    rm -rf /root/.ssh
    kill -HUP "$(cat /run/sshd.pid)"'
  wait_for 10 docker exec "$PREFIX-host" bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' >/dev/null || fail "sshd gone after reset"
}

root_login() {
  docker exec "$PREFIX-client" ssh -i /root/reg -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/kh "root@$ip" true 2>/dev/null
}

# Root's authorized_keys keeps every other line and holds the key once.
check_keys() {
  local ak
  ak=$(dx host cat "$AK")
  [[ $(grep -cxF "$key # $tag" <<<"$ak") == 1 ]] || fail "$1: the tagged key is not in $AK once"
  [[ $(dx host stat -c %a "$AK") == 600 ]] || fail "$1: $AK is not mode 600"
}

no_dropin() {
  if dx host test -e "$DROPIN"; then fail "$1: $DROPIN left behind"; fi
  docker exec "$PREFIX-client" ssh -i /root/key -o BatchMode=yes -o UserKnownHostsFile=/root/kh "ubuntu@$ip" true ||
    fail "$1: sshd stopped serving"
}

deny_root_late() { dx host bash -c 'echo "PermitRootLogin no" >>/etc/ssh/sshd_config'; }

# 1. sshd already lets root in with a key: only authorized_keys
# changes. Every untagged line stays, cloud-init's forced-command line
# and another site's line included; a stale line with our tag is
# replaced. A re-run leaves the same file.
reset_host
cloud='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="echo '"'"'Please login as the user \"ubuntu\" rather than the user \"root\".'"'"';echo;sleep 10;exit 142" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop'
other="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl # ubicloud-byoh site=s2 ip=$ip"
stale="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl # $tag"
printf '%s\n' "$cloud" "$stale" "$other" "# a comment" | dx host install -D -m 600 /dev/stdin "$AK"
install
expect_rc 0 "already allowed"
grep -q "already lets root log in with a key; no drop-in written" "$STATE/out" || fail "already allowed: no message"
no_dropin "already allowed"
check_keys "already allowed"
expected=$(printf '%s\n' "$cloud" "$other" "# a comment" "$key # $tag")
[[ $(dx host cat "$AK") == "$expected" ]] || fail "already allowed: $AK is $(dx host cat "$AK")"
install
expect_rc 0 "re-run"
[[ $(dx host cat "$AK") == "$expected" ]] || fail "re-run changed $AK"
root_login || fail "already allowed: root cannot log in with the registration key"
say "PASS already allowed, re-run"

# 2. PermitRootLogin no after the Include: the drop-in wins, sshd
# reloads, and root logs in with the key.
reset_host
deny_root_late
install
expect_rc 0 "drop-in"
grep -q "wrote $DROPIN" "$STATE/out" || fail "drop-in: no message"
dx host test -f "$DROPIN" || fail "drop-in: $DROPIN missing"
[[ $(dx host stat -c %a "$DROPIN") == 644 ]] || fail "drop-in: not mode 644"
grep -q "root: systemctl try-reload-or-restart ssh.service" <<<"$(dx host cat /var/log/fakehost-systemctl.log)" || fail "drop-in: no reload"
check_keys "drop-in"
wait_for 10 root_login >/dev/null || fail "drop-in: root cannot log in after the reload"
install
expect_rc 0 "drop-in re-run"
grep -q "already lets root" "$STATE/out" || fail "drop-in re-run wrote the drop-in again"
say "PASS drop-in, re-run"

# 3. An earlier drop-in keeps root out: exit 11, naming it.
reset_host
dx host bash -c 'echo "PermitRootLogin no" >/etc/ssh/sshd_config.d/01-harden.conf'
install
expect_rc 11 "earlier setting"
grep -q "the setting comes from /etc/ssh/sshd_config.d/01-harden.conf" "$STATE/err" || fail "earlier setting: winner not named"
no_dropin "earlier setting"
check_keys "earlier setting"
say "PASS exit 11"

# 4. sshd -T cannot read the configuration: exit 12.
reset_host
dx host bash -c 'echo "NotAnOption yes" >/etc/ssh/sshd_config.d/60-bad.conf'
install
expect_rc 12 "sshd -T fails"
if dx host test -e "$DROPIN"; then fail "sshd -T fails: $DROPIN written"; fi
check_keys "sshd -T fails"
say "PASS exit 12"

# 5. No Include of sshd_config.d: exit 13.
reset_host
dx host bash -c 'sed -i "/^Include/d" /etc/ssh/sshd_config'
deny_root_late
install
expect_rc 13 "no Include"
no_dropin "no Include"
say "PASS exit 13"

# 6. sshd -t rejects the configuration with the drop-in: exit 10.
reset_host
deny_root_late
# shellcheck disable=SC2016
dx host bash -c 'printf "%s\n" "#!/bin/bash" "[[ \$1 == -t ]] && { echo forced sshd -t failure >&2; exit 1; }" "exec /usr/sbin/sshd \"\$@\"" >/usr/local/sbin/sshd && chmod 755 /usr/local/sbin/sshd'
install
expect_rc 10 "sshd -t fails"
no_dropin "sshd -t fails"
say "PASS exit 10"

# 7. Neither systemctl nor the pid file reloads sshd: exit 14.
reset_host
deny_root_late
dx host bash -c 'printf "%s\n" "#!/bin/bash" "echo Job for ssh.service failed >&2" "exit 1" >/usr/local/sbin/systemctl && chmod 755 /usr/local/sbin/systemctl && mv /run/sshd.pid /root/sshd.pid'
install
expect_rc 14 "no reload"
no_dropin "no reload"
reset_host
say "PASS exit 14"

say "PASS m4 install-key cases (logs: $LOGS)"
