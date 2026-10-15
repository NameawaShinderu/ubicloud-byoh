#!/bin/bash
# M4 WP10: ubicloud-admin site, host and pool on the packaged layout.
# Boots a ubi-m4-admin container from the M3 harness image
# ubi-m3-release (run.sh --prepare-image/--prepare-tools/--prepare-release
# build it), lays the working tree over its release (M4 adds no
# migration and no gem, so the release's database and bundle still fit)
# and installs the working tree's ubicloud-admin and units. Then:
#
#   - site add with --rates-from writes billing_rates.d/<name>.yml and
#     restarts ubicloud.target (a new web PID); a site rates that changes
#     no file and a site set restart nothing
#   - site show NAME, site --help, the M8 and --postgres refusals (2)
#   - UBICLOUD_ADMIN_DRYRUN=1 mappings of site add and of the two-phase
#     host add
#   - --dev (and UBICLOUD_ADMIN_DEV=1) refused on the packaged layout
#   - host add with the real byoh-host and an unknown site: the prepare
#     phase fails, the register phase never runs, the staged keys go
#   - host add with a probe in place of bin/byoh-host: in the register
#     phase the staged --ssh-key and --registration-key copies are gone
#     (a listing of the staging directory proves it) while the staged
#     --pool-file is still there, and neither key option is passed;
#     byoh-keys/ exists as ubicloud 0700 although the old release's
#     install.sh never made it
#   - host add with a missing --ssh-key or --pool-file exits 2 and never
#     runs the tool; site --help as a non-root user gets the root refusal
#   - --dev in a ubi-m4-admin-dev container with no packaged layout:
#     the dry run makes the file options absolute against the caller's
#     directory; root without SUDO_USER gets the bundle exec line and 2;
#     with SUDO_USER a stand-in bundle runs as that user in the checkout
#     with mise's PATH; a copy outside a checkout stops before bundle
#
# Containers are named ubi-m4-*, join only ubi-test-net and publish no
# ports; cleanup removes only the containers this run created.
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

RELEASE_IMAGE=${UBI_M4_RELEASE_IMAGE:-ubi-m3-release}
C="admin"

web_up() { [[ $(dx "$1" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/login) == 200 ]]; }
web_pid() { dx "$1" systemctl show -p MainPID --value ubicloud-web; }

# adm ARGS...: ubicloud-admin as root from /root; output to $LOGS/adm.log,
# the exit status on stdout.
adm() {
  local rc=0
  {
    echo "### ubicloud-admin $*"
    docker exec -i -w /root "$PREFIX-$C" ubicloud-admin "$@" 2>&1 || rc=$?
  } </dev/null >>"$LOGS/adm.log"
  echo "$rc"
}
adm_last() { awk '/^### ubicloud-admin /{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$LOGS/adm.log"; }

docker image inspect "$RELEASE_IMAGE" >/dev/null 2>&1 ||
  fail "no $RELEASE_IMAGE image; build it with scripts/byoh/test/run.sh --prepare-image --prepare-tools --prepare-release"

stage_art
src_tarball
start_sys "$C" "$RELEASE_IMAGE"
# shellcheck disable=SC2016
dx "$C" bash -c 'tar -xzf /art/src.tgz -C "$(readlink -f /opt/ubicloud/current)" --no-same-owner &&
  chmod -R a+rX,go-w "$(readlink -f /opt/ubicloud/current)"'
dx "$C" bash /art/fixture.sh units
# The image may start the units at boot, before the overlay.
dx "$C" systemctl restart ubicloud.target
t=$(wait_for 180 web_up "$C") || fail "web did not answer within 180 s"
say "$C: web answers after ${t}s (release with the working tree $(cat "$ART/src.rev") laid over it)"

# --- site -----------------------------------------------------------------
pid=$(web_pid "$C")
[[ $(adm site add m4-site --display "M4 Site" --cp-reach onhost --rates-from hetzner-fsn1) == 0 ]] ||
  fail "site add: $(adm_last)"
out=$(adm_last)
grep -q 'restarted ubicloud.target to load the new rates; web answers' <<<"$out" || fail "site add did not restart: $out"
grep -q 'Next: ubicloud-admin host add --site m4-site' <<<"$out" || fail "site add printed no next step: $out"
grep -q 'ubicloud-admin restarts the services' <<<"$out" || fail "site add printed the manual restart note: $out"
[[ $(web_pid "$C") != "$pid" ]] || fail "site add: web kept its PID"
[[ $(dx "$C" stat -c '%U' /var/lib/ubicloud/billing_rates.d/m4-site.yml) == ubicloud ]] ||
  fail "site add wrote no billing_rates.d/m4-site.yml"
[[ $(dx "$C" runuser -u postgres -- psql -XtAq -d ubicloud -c "SELECT ui_name FROM location WHERE name = 'm4-site'") == "M4 Site" ]] ||
  fail "site add: --display did not set ui_name"
say "site add: rate file written, ubicloud.target restarted, --display is the UI name"

wait_for 120 web_up "$C" >/dev/null || fail "web down after site add"
pid=$(web_pid "$C")
[[ $(adm site rates m4-site --rates-from hetzner-fsn1) == 0 ]] || fail "site rates again: $(adm_last)"
grep -q 'restarted' <<<"$(adm_last)" && fail "site rates that changed no file restarted: $(adm_last)"
[[ $(adm site set m4-site --guest-mtu 1400) == 0 ]] || fail "site set: $(adm_last)"
[[ $(web_pid "$C") == "$pid" ]] || fail "site rates (no change) or site set restarted web"
[[ $(adm site show m4-site) == 0 ]] || fail "site show NAME: $(adm_last)"
grep -q 'Location      m4-site' <<<"$(adm_last)" || fail "site show NAME: $(adm_last)"
[[ $(adm site --help) == 0 ]] || fail "site --help: $(adm_last)"
grep -q 'Usage: bin/byoh-location' <<<"$(adm_last)" || fail "site --help: $(adm_last)"
[[ $(adm site add --help) == 0 ]] || fail "site add --help: $(adm_last)"
grep -q -- '--mgmt MODE' <<<"$(adm_last)" || fail "site add --help lists no create options: $(adm_last)"
rc=0
out=$(docker exec -u nobody -w / "$PREFIX-$C" ubicloud-admin site --help 2>&1) || rc=$?
[[ $rc == 1 && $out == *"run ubicloud-admin as root"* ]] || fail "site --help as nobody exited $rc: $out"
[[ $(adm site add m4-two --postgres yes) == 2 ]] || fail "site add --postgres yes was not refused with 2"
[[ $(adm site add m4-two --mgmt wireguard) == 2 ]] || fail "site add --mgmt wireguard was not refused with 2"
[[ $(adm site bogus) == 2 ]] || fail "site bogus was not refused with 2"
[[ $(adm host add --site m4-site --ssh u@10.0.0.9 --bmc-password x) == 2 ]] || fail "host add --bmc-password was not refused"
say "site: rates without change and set restart nothing; show NAME, --help and the refusals"

# --- dry run and --dev ---------------------------------------------------
out=$(docker exec -w /root -e UBICLOUD_ADMIN_DRYRUN=1 "$PREFIX-$C" ubicloud-admin site add m4-x --display "X Y" 2>&1) ||
  fail "dry run site add: $out"
grep -qF 'bin/byoh-location add m4-x --display X\ Y' <<<"$out" || fail "dry run site add mapping: $out"
out=$(docker exec -w /root -e UBICLOUD_ADMIN_DRYRUN=1 "$PREFIX-$C" ubicloud-admin host add --site m4-site --ssh ubuntu@10.0.0.9 \
  --ssh-key k --registration-key r --pool-file p.yaml --yes 2>&1) || fail "dry run host add: $out"
[[ $(grep -c '^  bin/byoh-host add ' <<<"$out") == 2 ]] || fail "dry run host add is not two runs: $out"
grep -q -- '--ssh-key k --registration-key r --pool-file p.yaml --yes --phase prepare$' <<<"$out" || fail "dry run prepare line: $out"
grep -q -- '--ssh ubuntu@10.0.0.9 --pool-file p.yaml --yes --phase register$' <<<"$out" || fail "dry run register line: $out"
[[ $(dx "$C" runuser -u postgres -- psql -XtAq -d ubicloud -c "SELECT count(*) FROM location WHERE name = 'm4-x'") == 0 ]] ||
  fail "the dry run created a location"
[[ $(adm --dev site list) == 2 ]] || fail "--dev on the packaged layout: $(adm_last)"
grep -q 'packaged control plane' <<<"$(adm_last)" || fail "--dev on the packaged layout: $(adm_last)"
rc=0
docker exec -w /root -e UBICLOUD_ADMIN_DEV=1 "$PREFIX-$C" ubicloud-admin site list >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "UBICLOUD_ADMIN_DEV=1 on the packaged layout exited $rc"
say "dry run: site add and the two-phase host add; --dev refused on the packaged layout"

# --- host add ---------------------------------------------------------------
# The control plane image has no ssh-keygen; the keys come from here.
rm -f "$STATE/k" "$STATE/k.pub" "$STATE/reg" "$STATE/reg.pub"
ssh-keygen -q -t ed25519 -N "" -C "" -f "$STATE/k"
ssh-keygen -q -t ed25519 -N "" -C "" -f "$STATE/reg"
docker exec -i "$PREFIX-$C" install -m 0600 /dev/stdin /root/k <"$STATE/k"
docker exec -i "$PREFIX-$C" install -m 0600 /dev/stdin /root/reg <"$STATE/reg"
printf 'version: 2\n' | docker exec -i "$PREFIX-$C" install -m 0600 /dev/stdin /root/pools.yaml
[[ $(adm host add --site nope --ssh ubuntu@10.0.0.9 --ssh-key k --registration-key reg --yes) == 1 ]] ||
  fail "host add for an unknown site: $(adm_last)"
out=$(adm_last)
grep -q 'deleted the staged copies of the SSH keys' <<<"$out" || fail "host add did not delete the staged keys: $out"
[[ $(dx "$C" bash -c 'ls -d /tmp/ubicloud-admin-files.* 2>/dev/null | wc -l') == 0 ]] || fail "staging directory left behind"
say "host add (real byoh-host): the failed prepare phase stops it before register"

# The probe stands in for bin/byoh-host: it records what each phase gets.
rel=$(dx "$C" readlink -f /opt/ubicloud/current)
dx "$C" cp -p "$rel/bin/byoh-host" /root/byoh-host.orig
dx "$C" bash -c "cat >'$rel/bin/byoh-host'" <<'RUBY'
#!/usr/bin/env ruby
# frozen_string_literal: true

# Harness probe (m4-admin.sh), never in a release.
args = ARGV
arg = ->(name) { (i = args.index(name)) && args[i + 1] }
log = "/var/lib/ubicloud/var/m4-probe.log"
keys = "/var/lib/ubicloud/var/m4-probe.keys"
if arg.call("--phase") == "prepare"
  File.write(keys, [arg.call("--ssh-key"), arg.call("--registration-key")].join("\n"))
  File.write(log, "prepare readable=#{[arg.call("--ssh-key"), arg.call("--registration-key"), arg.call("--pool-file")].all? { File.readable?(it) }}\n", mode: "a")
else
  staged = File.read(keys).split("\n")
  listing = Dir.children(File.dirname(staged.first)).sort.join(",")
  File.write(log, "register keyopts=#{args.include?("--ssh-key") || args.include?("--registration-key")} " \
    "gone=#{staged.none? { File.exist?(it) }} pool=#{File.readable?(arg.call("--pool-file").to_s)} listing=#{listing}\n", mode: "a")
end
RUBY
dx "$C" chmod 0755 "$rel/bin/byoh-host"
# A missing file stops the script before the tool, though host add runs
# the prepare phase where errexit could be off.
for bad in "--ssh-key missing --pool-file pools.yaml" "--ssh-key k --pool-file missing.yaml"; do
  # shellcheck disable=SC2086
  [[ $(adm host add --site m4-site --ssh ubuntu@10.0.0.9 $bad --yes) == 2 ]] || fail "host add $bad: $(adm_last)"
  out=$(adm_last)
  grep -q 'is not a readable file' <<<"$out" || fail "host add $bad: $out"
  grep -q 'deleted the staged copies' <<<"$out" && fail "host add $bad went on after the refusal: $out"
  [[ $(dx "$C" bash -c 'ls /var/lib/ubicloud/var/m4-probe.log 2>/dev/null | wc -l') == 0 ]] ||
    fail "host add $bad ran bin/byoh-host"
done
[[ $(dx "$C" bash -c 'ls -d /tmp/ubicloud-admin-files.* 2>/dev/null | wc -l') == 0 ]] || fail "staging directory left behind"
say "host add: a missing --ssh-key or --pool-file exits 2 and never runs the tool"
[[ $(adm host add --site m4-site --ssh ubuntu@10.0.0.9 --ssh-key k --registration-key reg --pool-file pools.yaml --yes) == 0 ]] ||
  fail "host add with the probe: $(adm_last)"
dx "$C" cp -p /root/byoh-host.orig "$rel/bin/byoh-host"
probe=$(dx "$C" cat /var/lib/ubicloud/var/m4-probe.log)
say "probe: $(tr '\n' ' ' <<<"$probe")"
grep -qx 'prepare readable=true' <<<"$probe" || fail "the prepare phase could not read the staged files: $probe"
# The listing holds only pool file copies (one per phase), no key.
grep -qE '^register keyopts=false gone=true pool=true listing=in\.[A-Za-z0-9]+,in\.[A-Za-z0-9]+$' <<<"$probe" ||
  fail "the register phase saw the keys or lost the pool file: $probe"
[[ $(dx "$C" stat -c '%U:%G %a' /var/lib/ubicloud/byoh-keys) == "ubicloud:ubicloud 700" ]] || fail "byoh-keys is not ubicloud 0700"
say "host add: the staged keys are gone before the register phase; byoh-keys made"

grep -q ' by root ' <<<"$(dx "$C" journalctl -t ubicloud-admin --no-pager)" || fail "no ubicloud-admin audit lines"

# --- --dev, with no packaged layout ------------------------------------------
D="$PREFIX-admin-dev"
docker run -d --name "$D" --network "$NET" ubuntu:24.04 sleep infinity >/dev/null
echo "$D" >>"$STATE/created"
ruby_ver=$(sed -n 's/^ruby *= *"\([^"]*\)".*/\1/p' "$WT/mise.toml" | head -1)
docker cp "$WT/packaging/bin/ubicloud-admin" "$D:/ubicloud-admin"
# shellcheck disable=SC2016
docker exec -i -e RUBY_VER="$ruby_ver" "$D" bash -euo pipefail <<'SH'
useradd -m dev
mkdir -p /repo/bin /repo/packaging/bin /work/rel /elsewhere
touch /repo/Gemfile /repo/bin/byoh-location /repo/bin/byoh-host /repo/bin/byoh-pool
printf '[tools]\nruby = "%s"\n' "$RUBY_VER" >/repo/mise.toml
install -m 0755 /ubicloud-admin /repo/packaging/bin/ubicloud-admin
install -m 0755 /ubicloud-admin /elsewhere/ubicloud-admin
chmod -R a+rX /repo /work
# The stand-in bundle, on the PATH only through mise's ~/.local/bin.
install -d -o dev -g dev /home/dev/.local/bin "/home/dev/.local/share/mise/installs/ruby/$RUBY_VER/bin"
cat >/home/dev/.local/bin/bundle <<'B'
#!/bin/bash
printf 'user=%s pwd=%s path=%s args=%s\n' "$(id -un)" "$PWD" "$PATH" "$*" >>/tmp/bundle.log
B
chmod 0755 /home/dev/.local/bin/bundle
SH
dev_adm() { docker exec -w /work "$@"; }

out=$(dev_adm -e UBICLOUD_ADMIN_DRYRUN=1 "$D" /repo/packaging/bin/ubicloud-admin --dev host add --site s --ssh u@h \
  --ssh-key rel/k --registration-key=/abs/r --pool-file=p.yaml --yes 2>&1) || fail "--dev dry run host add: $out"
grep -q '^ubicloud-admin: dry run; in the checkout /repo it would run:$' <<<"$out" || fail "--dev dry run header: $out"
grep -qx -- '  bundle exec bin/byoh-host add --site s --ssh u@h --ssh-key /work/rel/k --registration-key /abs/r --pool-file /work/p.yaml --yes --phase prepare' <<<"$out" ||
  fail "--dev dry run prepare line: $out"
grep -qx -- '  bundle exec bin/byoh-host add --site s --ssh u@h --pool-file /work/p.yaml --yes --phase register' <<<"$out" ||
  fail "--dev dry run register line: $out"

rc=0
out=$(dev_adm "$D" /repo/packaging/bin/ubicloud-admin --dev site list 2>&1) || rc=$?
[[ $rc == 2 ]] || fail "--dev as root without SUDO_USER exited $rc: $out"
grep -qx '  cd /repo && bundle exec bin/byoh-location list' <<<"$out" || fail "--dev as root printed no bundle exec line: $out"

[[ $(dx admin-dev bash -c 'ls /tmp/bundle.log 2>/dev/null | wc -l') == 0 ]] || fail "--dev ran bundle without SUDO_USER or in a dry run"
dev_adm -e SUDO_USER=dev "$D" /repo/packaging/bin/ubicloud-admin --dev pool export --out o.yaml >/dev/null 2>&1 ||
  fail "--dev pool export with SUDO_USER failed"
log=$(dx admin-dev cat /tmp/bundle.log)
[[ $log == "user=dev pwd=/repo path=/home/dev/.local/bin:/home/dev/.local/share/mise/installs/ruby/$ruby_ver/bin:"*" args=exec bin/byoh-pool export --out /work/o.yaml" ]] ||
  fail "--dev with SUDO_USER: $log"

rc=0
out=$(dev_adm -e SUDO_USER=dev "$D" /elsewhere/ubicloud-admin --dev site list 2>&1) || rc=$?
[[ $rc == 1 && $out == *"is not a checkout"* ]] || fail "--dev outside a checkout exited $rc: $out"
rc=0
out=$(dev_adm -e UBICLOUD_ADMIN_DRYRUN=1 "$D" /elsewhere/ubicloud-admin --dev site list 2>&1) || rc=$?
[[ $rc == 1 && $out != *"dry run"* ]] || fail "--dev dry run outside a checkout exited $rc: $out"
[[ $(dx admin-dev bash -c 'wc -l </tmp/bundle.log') == 1 ]] || fail "--dev outside a checkout ran bundle"
say "--dev: absolute file options, the root refusal, SUDO_USER with mise's PATH, no run outside a checkout"
say "m4-admin: ok"
