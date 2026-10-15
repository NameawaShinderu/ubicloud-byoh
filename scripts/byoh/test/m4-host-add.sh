#!/bin/bash
# M4 container gate (WP12): `bin/byoh-host add` end to end against
# fakehosts, with the real CLIs, the real ssh client and Net::SSH, and a
# real database.
#
# The control plane is ubi-m4-cp, a ubi-bundler-m1 container
# (UBI_M4_RUBY_IMAGE) with the working tree mounted read-only at /app
# and a tmpfs over /app/var, so the registration keys and anything else
# the CLIs write never reach the worktree. It runs RACK_ENV=development,
# because under RACK_ENV=test Net::SSH raises MissingMock and host add
# refuses to reach a host. The database is the worktree .env.rb's
# CLOVER_DATABASE_URL with TEST_ENV_NUMBER=$UBI_M4_DB_NUMBER (default 6,
# clover_m2_test6 here), shared with the spec suite: never run this while
# a pspec runs. m4-db-state refuses unless UBI_M4_GATE=1 and the database
# is named *_test<n> with <n> = TEST_ENV_NUMBER (never clover_test),
# snapshots it first, and on exit deletes every row the run added and
# checks that each table is back as it was.
#
# Runs (each asserts its exit status and output):
#   A  no /dev/kvm: add stops at preflight with PF3 "no /dev/kvm"; no
#      host row, root's authorized_keys and sshd untouched
#   B  a /29 that holds the fakehost's uplink address: PF17 fails after
#      the read-only login (docker logs show it), nothing changed
#   C  ubicloud-host preflight over the operator's ssh on the
#      intel-hybrid fixture: PF8-hybrid fails and blocks, and
#      ByohHostPreflight#accept downgrades it
#   D  --skip-preflight --yes --no-wait: registers the host; checks the
#      rows (uplink_ip, boot images, host keys pinned from the host's own
#      /etc/ssh/ssh_host_*_key.pub), the tagged authorized_keys line next
#      to the lines that were there, the HostNexus frame that makes
#      BootstrapRhizome verify those keys, no drop-in (sshd already allowed
#      root key login), PF2 passed, and the kept key deleted; a re-run
#      resumes without a second host, a re-run with --storage-disk is
#      refused (2), and `watch` through a pipe delivers its lines as
#      they happen, not in one block at exit
#   D2 on a second fakehost that denies root login, with an sshd shim
#      whose `sshd -t` fails: the drop-in is rolled back, exit 1, sshd
#      still serves, no host row
#   E  --storage-disk naming a missing disk stops before any change (1);
#      then storage-disk-fixtures.sh, whose holders, partition table,
#      backup GPT, iscsi and two-link refusals must pass
#   D3 the D2 host without the shim: the drop-in is written, sshd reloads,
#      PF2 passes with the kept key, and the host is registered
#
# Containers are named ubi-m4-*, join only ubi-test-net and publish no
# ports; cleanup removes only the ones this run created.
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"

RUBY_IMAGE=${UBI_M4_RUBY_IMAGE:-ubi-bundler-m1}
DB_NUMBER=${UBI_M4_DB_NUMBER:-6}
SITE=m4-gate
CP=$PREFIX-cp
AK=/root/.ssh/authorized_keys
DROPIN=/etc/ssh/sshd_config.d/05-ubicloud-root.conf
snapshot=0
N=0

finish() {
  local rc=$?
  if ((snapshot)); then
    docker exec "$CP" bundle exec scripts/byoh/test/m4-db-state restore /state/db.json 2>&1 | tee -a "$LOGS/harness.log" ||
      {
        say "FAIL: the database was not restored"
        rc=1
      }
  fi
  cleanup
  exit "$rc"
}
trap finish EXIT

[[ -f $WT/.env.rb ]] || fail "no $WT/.env.rb: the gate needs the test .env.rb (CLAUDE.md section 7)"
docker image inspect "$RUBY_IMAGE" >/dev/null 2>&1 || fail "no $RUBY_IMAGE image; docker build --target bundler -t $RUBY_IMAGE ."

# --- the control plane --------------------------------------------------

mkdir -p "$STATE/cp"
docker run -d --name "$CP" --network "$NET" -v "$WT:/app:ro" --tmpfs /app/var -v "$STATE/cp:/state" -w /app \
  -e RACK_ENV=development -e TEST_ENV_NUMBER="$DB_NUMBER" -e UBI_M4_GATE=1 "$RUBY_IMAGE" sleep infinity >/dev/null
echo "$CP" >>"$STATE/created"
docker exec "$CP" apk add --quiet bash openssh-client >/dev/null 2>&1 || fail "$CP: apk add bash openssh-client"
# The guard itself: refused without UBI_M4_GATE=1, and on the gate's own
# database with a TEST_ENV_NUMBER its name does not end in (the URL is
# fixed first, so the refusal is the guard's, not a failed connection).
out=$(docker exec -e UBI_M4_GATE=0 "$CP" bundle exec scripts/byoh/test/m4-db-state check 2>&1) &&
  fail "$CP: m4-db-state check passed without UBI_M4_GATE=1"
[[ $out == *"UBI_M4_GATE=1 is not set"* ]] || fail "$CP: m4-db-state without UBI_M4_GATE: $out"
# shellcheck disable=SC2016 # expanded by the container's shell
out=$(docker exec "$CP" sh -c 'CLOVER_DATABASE_URL=$(ruby -e "load %q(./.env.rb); print ENV.fetch(%q(CLOVER_DATABASE_URL))") TEST_ENV_NUMBER=${TEST_ENV_NUMBER}9 exec bundle exec scripts/byoh/test/m4-db-state check' 2>&1) &&
  fail "$CP: m4-db-state check passed with TEST_ENV_NUMBER=${DB_NUMBER}9"
[[ $out == *"refusing database "*"_test$DB_NUMBER: only a *_test<n>"* ]] || fail "$CP: m4-db-state with TEST_ENV_NUMBER=${DB_NUMBER}9: $out"
db=$(docker exec "$CP" bundle exec scripts/byoh/test/m4-db-state check) || fail "$CP: the database check refused (see above)"
docker exec "$CP" bundle exec bin/rake-task-runner migrate '' 0 >/dev/null || fail "$CP: migrate $db"
docker exec "$CP" bundle exec scripts/byoh/test/m4-db-state snapshot /state/db.json >>"$LOGS/harness.log"
snapshot=1
say "$CP: RACK_ENV=development on $db (snapshot taken)"

# rb CODE ARGS...: Ruby with the application loaded, in the control plane.
rb() {
  local code=$1
  shift
  docker exec -i "$CP" bundle exec ruby -r ./db -r ./loader -e "$code" -- "$@"
}

# add ARGS...: bin/byoh-host add as the operator would run it, with the
# per-run login key and no terminal; sets RC and OUT (stdout and stderr).
add() {
  local log
  N=$((N + 1))
  log=$LOGS/add.$N.log
  echo "### byoh-host add $*" >"$log"
  RC=0
  docker exec "$CP" bundle exec bin/byoh-host add --site "$SITE" --ssh-key /root/op "$@" </dev/null >>"$log" 2>&1 || RC=$?
  OUT=$(<"$log")
}

expect_rc() {
  [[ $RC == "$1" ]] || fail "$2: exit $RC, not $1 ($LOGS/add.$N.log):
$(tail -25 "$LOGS/add.$N.log")"
}

# has RUN REGEX: OUT has a line matching the extended REGEX.
has() {
  grep -qE -- "$2" <<<"$OUT" || fail "$1: no line matching '$2' in $LOGS/add.$N.log:
$(tail -25 "$LOGS/add.$N.log")"
}

lacks() {
  if grep -qE -- "$2" <<<"$OUT"; then fail "$1: a line matches '$2' in $LOGS/add.$N.log"; fi
}

# rows IP: "<sshables> <vm_hosts>" at that main IP.
rows() {
  rb 's = Sshable.where(host: ARGV[0]); puts "#{s.count} #{VmHost.where(id: s.select(:id)).count}"' "$1"
}

host_state() { dx "$1" bash -c "sha256sum $AK 2>/dev/null; ls /etc/ssh/sshd_config.d/; ls -A /root/.ssh 2>/dev/null" | sha256sum; }

logins() { docker logs "$PREFIX-$1" 2>&1 | grep -c "Accepted publickey for $2 " || true; }

serves() {
  docker exec "$CP" ssh -i /root/op -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ubuntu@$1" true
}

# --- the hosts and the site ---------------------------------------------

prepare_fakehost_image
start_fakehost host
start_fakehost host2
ip=$(fakehost_ip host)
ip2=$(fakehost_ip host2)
docker exec -i "$CP" install -m 0600 /dev/stdin /root/op <"$(fakehost_key)"

# Root's authorized_keys as cloud-init leaves it on a cloud image, plus a
# comment: add must keep both.
cloud='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="echo '"'"'Please login as the user \"ubuntu\" rather than the user \"root\".'"'"';echo;sleep 10;exit 142" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop'
for h in host host2; do
  printf '%s\n' "$cloud" "# kept by add" | dx "$h" install -D -m 600 /dev/stdin "$AK"
done

docker exec "$CP" bundle exec bin/byoh-location create --name "$SITE" >"$LOGS/site.log" 2>&1 || fail "site create: $(cat "$LOGS/site.log")"
say "site $SITE created; hosts $ip and $ip2"

# --- A: no /dev/kvm -------------------------------------------------------

before=$(host_state host)
add --ssh "ubuntu@$ip" --routed-network 10.77.9.0/29 --yes
expect_rc 1 "A"
has A "^fail +PF3 +no /dev/kvm$"
has A "preflight failed: .*nothing on the host was changed"
lacks A "installed the registration key"
[[ $(rows "$ip") == "0 0" ]] || fail "A: rows at $ip: $(rows "$ip")"
[[ $(host_state host) == "$before" ]] || fail "A: root's authorized_keys or sshd_config.d changed"
say "PASS A: no /dev/kvm stops add at PF3, nothing changed"

# --- B: a pool that holds the uplink IP -----------------------------------

IFS=. read -r o1 o2 o3 o4 <<<"$ip"
pool="$o1.$o2.$o3.$((o4 & ~7))/29"
login_before=$(logins host ubuntu)
add --ssh "ubuntu@$ip" --main-ip 192.0.2.10 --routed-network "$pool" --yes
expect_rc 1 "B"
has B "^fail +PF17 +.*$pool hands the uplink IP $ip to VMs"
lacks B "installed the registration key"
(($(logins host ubuntu) > login_before)) || fail "B: no operator login in docker logs; PF17 must fail after the read-only login"
[[ $(logins host root) == 0 ]] || fail "B: root logged in"
[[ $(rows 192.0.2.10) == "0 0" ]] || fail "B: rows at 192.0.2.10"
[[ $(host_state host) == "$before" ]] || fail "B: root's authorized_keys or sshd_config.d changed"
say "PASS B: PF17 refuses a pool holding the uplink IP $ip after a read-only login"

# --- C: a hybrid CPU --------------------------------------------------------

fx=$(pf_fixture intel-hybrid)
docker cp "$fx" "$PREFIX-host:/fx" >/dev/null
dx host chmod -R a+rX /fx
# As add runs it (script on stdin, sudo, the control plane's arguments),
# with the fixture root in place of the host's own /proc, /sys and tools.
docker exec -i "$CP" ssh -i /root/op -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR "ubuntu@$ip" \
  "sudo -n env UBICLOUD_HOST_TEST_ROOT=/fx bash -s -- preflight --json --nonce c4hybr1d --main-ip 203.0.113.10 --fixture-root /fx" \
  <"$WT/scripts/byoh/host/ubicloud-host" >"$LOGS/c.out" 2>"$LOGS/c.err" || fail "C: preflight exited $? ($(tail -3 "$LOGS/c.err"))"
dx host rm -rf /fx
# shellcheck disable=SC2016
verdict=$(rb '
  r = ByohHostPreflight.parse($stdin.read, "c4hybr1d")
  r.evaluate(main_ip: "203.0.113.10", location: Location[name: ARGV[0]], location_name: ARGV[0], boot_images: ["ubuntu-noble"])
  c = -> { r.checks.find { it.id == "PF8-hybrid" } }
  puts "#{c.call.status} blocking=#{r.blocking?}"
  r.accept(["PF8-hybrid"])
  puts "#{c.call.status} accepted=#{c.call.accepted} fails=#{r.checks.select { it.status == "fail" }.map(&:id).join(",")}"
' "$SITE" <"$LOGS/c.out")
[[ $verdict == $'fail blocking=true\nwarn accepted=true fails=' ]] || fail "C: PF8-hybrid verdicts: $verdict"
say "PASS C: PF8-hybrid fails and blocks on intel-hybrid, --accept-check PF8-hybrid downgrades it"

# --- D: registration ---------------------------------------------------------

add --ssh "ubuntu@$ip" --routed-network 10.77.9.0/29 --skip-preflight --yes --no-wait
expect_rc 0 "D"
has D "^fail +PF3 +no /dev/kvm$"
has D "warning: preflight failed, but --skip-preflight goes on"
has D "sshd already lets root log in with a key; no drop-in written"
has D "^pass +PF2 "
has D "^Registered host vh[0-9a-z]{24} in site $SITE\.$"
[[ $(rows "$ip") == "1 1" ]] || fail "D: rows at $ip: $(rows "$ip")"
# shellcheck disable=SC2016
facts=$(rb '
  s = Sshable.first(host: ARGV[0]); h = VmHost[s.id]
  puts "location #{h.location.name} byoh #{h.byoh?} provider #{h.provider_name}"
  puts "uplink_ip #{h.provider.config["uplink_ip"]}"
  puts "images #{h.strand.stack.last["default_boot_images"].join(",")}"
  puts "strand #{h.strand.prog}.#{h.strand.label} pin_host_keys #{h.strand.stack.last["pin_host_keys"]}"
  puts "public #{s.keys.first.public_key}"
  s.host_keys.sort.each { puts "host_key #{it}" }
' "$ip")
grep -qx "location $SITE byoh true provider generic" <<<"$facts" || fail "D: $facts"
grep -qx "uplink_ip $ip" <<<"$facts" || fail "D: uplink_ip: $facts"
grep -qx "images ubuntu-noble" <<<"$facts" || fail "D: boot images: $facts"
# BootstrapRhizome verifies the pinned keys on the first root login.
grep -qx "strand Vm::HostNexus.start pin_host_keys true" <<<"$facts" || fail "D: strand: $facts"
want=$(dx host bash -c 'cat /etc/ssh/ssh_host_*_key.pub' | cut -d' ' -f1,2 | sort)
[[ $(sed -n 's/^host_key //p' <<<"$facts") == "$want" ]] || fail "D: sshable.host_keys differ from the host's own keys:
$(grep host_key <<<"$facts")
host: $want"
pub=$(sed -n 's/^public //p' <<<"$facts")
expected=$(printf '%s\n' "$cloud" "# kept by add" "$pub # ubicloud-byoh site=$SITE ip=$ip")
[[ $(dx host cat "$AK") == "$expected" ]] || fail "D: $AK is:
$(dx host cat "$AK")"
if dx host test -e "$DROPIN"; then fail "D: $DROPIN written although sshd allowed root key login"; fi
(($(logins host root) >= 1)) || fail "D: no root login (PF2) in docker logs"
[[ -z $(docker exec "$CP" ls -A /app/var/byoh-keys) ]] || fail "D: the kept key outlived the registration: $(docker exec "$CP" ls -A /app/var/byoh-keys)"
say "PASS D: registered $ip (pinned $(wc -l <<<"$want") host keys, uplink_ip, ubuntu-noble, tagged key line)"

add --ssh "ubuntu@$ip" --routed-network 10.77.9.0/29 --skip-preflight --yes --no-wait
expect_rc 0 "D re-run"
has "D re-run" "^Resuming: $ip is already registered as host vh[0-9a-z]{24} "
lacks "D re-run" "Registered host"
[[ $(rows "$ip") == "1 1" ]] || fail "D re-run: rows at $ip: $(rows "$ip")"
add --ssh "ubuntu@$ip" --routed-network 10.77.9.0/29 --storage-disk ata-M4_DISK --skip-preflight --yes --no-wait
expect_rc 2 "D re-run with --storage-disk"
has "D re-run with --storage-disk" "is registered already, and add formats storage disks only before it registers"
say "PASS D re-run: resumes without a second host; --storage-disk refused (2)"

# The watch's label lines must reach a pipe as they happen (tee, a CI
# log, m4-e2.sh's timestamper), not in one block at exit. Respirate is
# not running, so the strand stays at start: the first poll prints its
# label at once and --timeout ends the watch about 10 s later.
vh=$(rb 'puts VmHost[Sshable.first(host: ARGV[0]).id].ubid' "$ip")
# shellcheck disable=SC2016
docker exec "$CP" sh -c 'bundle exec bin/byoh-host watch "$1" --timeout 8 2>&1 | while IFS= read -r l; do echo "$(date +%s) $l"; done' \
  sh "$vh" >"$LOGS/d-pipe.out" || true
first=$(grep -m1 " host Vm::HostNexus.start" "$LOGS/d-pipe.out" | cut -d' ' -f1)
last=$(grep -m1 "is not accepting VMs after 8 s" "$LOGS/d-pipe.out" | cut -d' ' -f1)
[[ -n $first && -n $last ]] || fail "D pipe: watch output: $(cat "$LOGS/d-pipe.out")"
((last - first >= 5)) || fail "D pipe: the watch's lines reached the pipe together (at $first and $last): stdout is buffered"
say "PASS D pipe: watch lines reach a pipe as they happen ($((last - first)) s apart)"

# --- D2: sshd -t fails with the drop-in ---------------------------------------

# PermitRootLogin no after the Include, so add needs its drop-in; sudo's
# secure_path puts /usr/local/sbin first, so the shim answers `sshd -t`.
dx host2 bash -c 'echo "PermitRootLogin no" >>/etc/ssh/sshd_config'
# shellcheck disable=SC2016
dx host2 bash -c 'printf "%s\n" "#!/bin/bash" "[[ \$1 == -t ]] && { echo forced sshd -t failure >&2; exit 1; }" "exec /usr/sbin/sshd \"\$@\"" >/usr/local/sbin/sshd && chmod 755 /usr/local/sbin/sshd'
add --ssh "ubuntu@$ip2" --routed-network 10.77.10.0/29 --skip-preflight --yes --no-wait
expect_rc 1 "D2"
has D2 "PF2 +runs once the key is installed; sshd does not let root log in with a key now \(PermitRootLogin no\)"
has D2 "sshd -t rejects the configuration with the drop-in that allows root key login; the drop-in was removed: forced sshd -t failure"
has D2 "To undo the key install on the host: sudo sed -i"
if dx host2 test -e "$DROPIN"; then fail "D2: $DROPIN left behind"; fi
serves "$ip2" || fail "D2: sshd stopped serving"
[[ $(rows "$ip2") == "0 0" ]] || fail "D2: rows at $ip2: $(rows "$ip2")"
[[ $(logins host2 root) == 0 ]] || fail "D2: root logged in"
say "PASS D2: a failing sshd -t rolls the drop-in back, exit 1, sshd serves"

# --- E: storage-disk refusals -------------------------------------------------

before=$(host_state host2)
add --ssh "ubuntu@$ip2" --routed-network 10.77.10.0/29 --storage-disk ata-M4_NOT_THERE --skip-preflight --yes --no-wait
expect_rc 1 "E missing disk"
has "E missing disk" "no disk /dev/disk/by-id/ata-M4_NOT_THERE on the host; nothing was changed"
lacks "E missing disk" "installed the registration key"
[[ $(host_state host2) == "$before" ]] || fail "E missing disk: the host changed"
"$HARNESS_DIR/storage-disk-fixtures.sh" >"$LOGS/storage-disk.log" 2>&1 || fail "E: storage-disk-fixtures.sh failed ($LOGS/storage-disk.log)"
for c in "holders" "blkid partition table" "backup GPT" "iscsi" "by-id matching two links"; do
  grep -qx "pass $c" "$LOGS/storage-disk.log" || fail "E: no 'pass $c' in $LOGS/storage-disk.log"
done
say "PASS E: a missing --storage-disk stops add unchanged; holders, partition table, GPT, iscsi and two-link refusals pass"

# --- D3: the drop-in path ------------------------------------------------------

dx host2 rm /usr/local/sbin/sshd
add --ssh "ubuntu@$ip2" --routed-network 10.77.10.0/29 --skip-preflight --yes --no-wait
expect_rc 0 "D3"
has D3 "^Reusing the registration key an earlier run generated "
has D3 "wrote $DROPIN, which lets root log in with a key"
has D3 "^pass +PF2 "
has D3 "^Registered host vh[0-9a-z]{24} in site $SITE\.$"
dx host2 test -f "$DROPIN" || fail "D3: no $DROPIN"
grep -q "root: systemctl try-reload-or-restart ssh.service" <<<"$(dx host2 cat /var/log/fakehost-systemctl.log)" || fail "D3: sshd was not reloaded"
[[ $(rows "$ip2") == "1 1" ]] || fail "D3: rows at $ip2: $(rows "$ip2")"
[[ $(dx host2 grep -c "# ubicloud-byoh site=$SITE ip=$ip2\$" "$AK") == 1 ]] || fail "D3: the tagged line is not in $AK once"
[[ -z $(docker exec "$CP" ls -A /app/var/byoh-keys) ]] || fail "D3: the kept key outlived the registration"
say "PASS D3: the drop-in is written, sshd reloads, PF2 passes with the kept key"

say "PASS m4 host add gate (logs: $LOGS)"
