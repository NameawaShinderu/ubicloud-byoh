#!/bin/bash
# Runs scripts/byoh/bootstrap-data-plane.sh's preflight hook (M4 WP11) in
# one throwaway ubi-m4-bs container (the ubi-m4-fakehost image, on
# ubi-test-net, no ports), as user ubuntu with passwordless sudo.
#
#   bootstrap-preflight.sh
#
# The install steps are pre-marked done, so nothing is installed and no
# package archive is needed; /dev/kvm is a node made with mknod, enough
# for the script's own step 1b (-c /dev/kvm). The cases:
#   live         the repository layout (host/ubicloud-host below the
#                script's directory), real commands: exit 1 exactly when
#                a row is "fail", main-ip-local passes for the container
#   base         a fixture host with no failing check: exit 0
#   hybrid       --preflight-script with fixtures/host/intel-hybrid:
#                exit 1 on PF8-hybrid
#   kvm64        ubicloud-host next to the script, kvm64-model: exit 1
#                on PF3
#   not-found    the script alone: preflight skipped with a hint, exit 0
#   no-preflight --no-preflight: skipped, exit 0
#   broken       a preflight script that exits 3: exit 1
#   usage        a missing --preflight-script, a bad --main-ip, both
#                --no-preflight and --preflight-script: exit 2 before
#                step 1
#   no-kvm       without /dev/kvm the existing step 1b exit stays: exit
#                1, and preflight never runs
#   unsafe-*     a found ubicloud-host that another user could have put
#                there is skipped with the reason, never run as root:
#                a sticky world-writable directory (like /tmp) with a file
#                planted by nobody, a host/ directory owned by nobody, a
#                directory writable by a group other than the owner's
#                own; exit 0 and the planted script leaves no mark
#   upg          a clone owned by ubuntu:ubuntu with mode 775 (Ubuntu's
#                umask 002, a user-private group) still runs: exit 0
# Fixture runs wrap ubicloud-host so that it reads fixtures/host/<case>
# laid over fixtures/host/base (as preflight-fixtures.sh does).
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

FIXTURES=$HARNESS_DIR/fixtures/host
BYOH=$WT/scripts/byoh
CTR=$PREFIX-bs
MAIN_IP=203.0.113.10

# lay_out CASE: builds the case's fixture tree under $STATE/bs/fx/CASE.
lay_out() {
  local dir=$STATE/bs/fx/$1 p
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$FIXTURES/base/." "$dir/"
  cp -R "$FIXTURES/$1/." "$dir/"
  if [[ -f $FIXTURES/$1/.remove ]]; then
    while read -r p; do
      [[ -n $p ]] && rm -rf "${dir:?}/$p"
    done <"$FIXTURES/$1/.remove"
  fi
}

# wrapper FILE CASE: a stand-in ubicloud-host that runs the real one on a
# fixture tree. sudo drops the environment, so the wrapper sets it.
wrapper() {
  cat >"$1" <<EOF
#!/bin/bash
UBICLOUD_HOST_TEST_ROOT=/t/fx/$2 exec bash /t/ubicloud-host "\$@" --fixture-root /t/fx/$2
EOF
}

# The trees under /t in the container:
#   live/      bootstrap-data-plane.sh, host/ubicloud-host (the real one)
#   base/      bootstrap-data-plane.sh, host/ubicloud-host -> fixture base
#   next/      bootstrap-data-plane.sh, ubicloud-host -> fixture kvm64-model
#   alone/     bootstrap-data-plane.sh only
#   hybrid     a wrapper -> fixture intel-hybrid
#   broken     a preflight script that exits 3
#   shared/    bootstrap-data-plane.sh, ubicloud-host planted (1777, nobody)
#   owned/     bootstrap-data-plane.sh, host/ubicloud-host planted (host/ is nobody's)
#   grp/       bootstrap-data-plane.sh, ubicloud-host planted (dir 775 root:ubuntu)
#   upg/       bootstrap-data-plane.sh, ubicloud-host -> fixture base (ubuntu:ubuntu 775)
T=$STATE/bs/t
rm -rf "$T"
mkdir -p "$T"/{live/host,base/host,next,alone,shared,owned/host,grp,upg}
cp "$BYOH/host/ubicloud-host" "$T/ubicloud-host"
for d in live base next alone shared owned grp upg; do
  cp "$BYOH/bootstrap-data-plane.sh" "$T/$d/"
done
for f in shared/ubicloud-host owned/host/ubicloud-host grp/ubicloud-host; do
  printf '#!/bin/bash\ntouch /t/pwned\necho "pass  PF1 planted"\n' >"$T/$f"
done
wrapper "$T/upg/ubicloud-host" base
cp "$BYOH/host/ubicloud-host" "$T/live/host/ubicloud-host"
for c in base intel-hybrid kvm64-model; do
  lay_out "$c"
done
cp -R "$STATE/bs/fx" "$T/fx"
wrapper "$T/base/host/ubicloud-host" base
wrapper "$T/next/ubicloud-host" kvm64-model
wrapper "$T/hybrid" intel-hybrid
printf '#!/bin/bash\necho "ubicloud-host: internal error: simulated" >&2\nexit 3\n' >"$T/broken"
chmod -R a+rX "$T"

prepare_fakehost_image
echo "$CTR" >>"$STATE/created"
docker run -d --name "$CTR" --hostname "$CTR" --network "$NET" --entrypoint sleep "$FAKEHOST_IMAGE" infinity >/dev/null
docker cp "$T/." "$CTR:/t/" >/dev/null
docker exec "$CTR" bash -c 'chmod -R a+rX /t &&
  mknod -m 0660 /dev/kvm c 10 232 &&
  install -d -o ubuntu -g ubuntu /home/ubuntu/.ubi-data-plane-bootstrap &&
  for m in sshd-installed root-sshd-config bundler-preinstalled; do
    install -o ubuntu -g ubuntu /dev/null /home/ubuntu/.ubi-data-plane-bootstrap/$m
  done &&
  chown -R root:root /t && chmod 1777 /t/shared && chown nobody /t/shared/ubicloud-host &&
  chown -R nobody /t/owned/host &&
  chgrp ubuntu /t/grp && chmod 775 /t/grp &&
  chown -R ubuntu:ubuntu /t/upg && chmod 775 /t/upg'
LIVE_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$CTR")

# bs NAME WANT_RC ARGS...: runs a bootstrap as ubuntu; its output (stdout
# and stderr) is in $OUT and $LOGS/bs-NAME.out.
bs() {
  local name=$1 want=$2 rc=0
  shift 2
  OUT=$(docker exec -u ubuntu -e HOME=/home/ubuntu -w /home/ubuntu "$CTR" bash "$@" 2>&1) || rc=$?
  printf '%s\n' "$OUT" >"$LOGS/bs-$name.out"
  ((rc == want)) || fail "$name: exit $rc, expected $want (see $LOGS/bs-$name.out)"
}

has() {
  grep -qE -- "$2" <<<"$OUT" || fail "$1: output lacks /$2/ (see $LOGS/bs-$1.out)"
}

lacks() {
  if grep -qE -- "$2" <<<"$OUT"; then fail "$1: output has /$2/ (see $LOGS/bs-$1.out)"; fi
}

# live: the real checks, which here fail on the package archive (no apt
# lists in the image) and maybe egress; the exit status must follow the
# rows either way.
rc=0
OUT=$(docker exec -u ubuntu -e HOME=/home/ubuntu -w /home/ubuntu "$CTR" \
  bash /t/live/bootstrap-data-plane.sh --main-ip "$LIVE_IP" 2>&1) || rc=$?
printf '%s\n' "$OUT" >"$LOGS/bs-live.out"
has live "/t/live/host/ubicloud-host preflight --standalone --virt-tier kvm --main-ip $LIVE_IP"
has live "^  pass  main-ip-local +$LIVE_IP is on this host"
has live "^  [a-z]+ +PF1 "
fails=$(grep -c '^  fail ' <<<"$OUT" || true)
if ((fails > 0)); then
  ((rc == 1)) || fail "live: $fails failing rows but exit $rc"
  has live "ERROR: preflight found $fails failing check"
else
  ((rc == 0)) || fail "live: no failing row but exit $rc"
fi
has live "sudo ubicloud-admin host add --site <site>"
say "pass live (exit $rc, $fails failing)"

bs base 0 /t/base/bootstrap-data-plane.sh --main-ip "$MAIN_IP"
has base "/t/base/host/ubicloud-host preflight --standalone --virt-tier kvm --main-ip $MAIN_IP"
has base "^  pass  PF3 "
has base "^  pass  main-ip-local "
has base "preflight: 0 failing"
lacks base "ERROR"
say "pass base"

bs hybrid 1 /t/alone/bootstrap-data-plane.sh --preflight-script /t/hybrid --main-ip "$MAIN_IP"
has hybrid "^  fail  PF8-hybrid "
has hybrid "ERROR: preflight found 1 failing check"
has hybrid "Primary IPv4"
say "pass hybrid"

bs kvm64 1 /t/next/bootstrap-data-plane.sh
has kvm64 "/t/next/ubicloud-host preflight --standalone --virt-tier kvm$"
has kvm64 "^  fail  PF3 +kvm64-class CPU model"
has kvm64 "^  info  main-ip-local +no --main-ip given"
has kvm64 "ERROR: preflight found [0-9]+ failing check"
say "pass kvm64"

bs not-found 0 /t/alone/bootstrap-data-plane.sh
has not-found "\[skip\] ubicloud-host was not found next to this script"
has not-found "sudo ubicloud-admin host preflight --site <site>"
lacks not-found "ERROR"
say "pass not-found"

bs no-preflight 0 /t/live/bootstrap-data-plane.sh --no-preflight
has no-preflight "\[skip\] --no-preflight"
lacks no-preflight "PF1"
say "pass no-preflight"

bs broken 1 /t/alone/bootstrap-data-plane.sh --preflight-script /t/broken
has broken "preflight could not run \(exit 3\)"
has broken "internal error: simulated"
say "pass broken"

bs usage-missing 2 /t/live/bootstrap-data-plane.sh --preflight-script /t/nope
has usage-missing "--preflight-script /t/nope: no such file"
lacks usage-missing "OS check"
bs usage-ip 2 /t/live/bootstrap-data-plane.sh --main-ip 10.0.0
has usage-ip "--main-ip must be an IPv4 address"
bs usage-both 2 /t/live/bootstrap-data-plane.sh --no-preflight --preflight-script /t/hybrid
has usage-both "exclude each other"
bs usage-unknown 2 /t/live/bootstrap-data-plane.sh --bogus
has usage-unknown "unknown argument --bogus"
bs usage-value 2 /t/live/bootstrap-data-plane.sh --main-ip
has usage-value "--main-ip needs a value"
lacks usage-value "OS check"
say "pass usage"

# unsafe NAME DIR WHY: the planted ubicloud-host under DIR is skipped.
unsafe() {
  bs "$1" 0 "/t/$2/bootstrap-data-plane.sh"
  has "$1" "\[skip\] not running /t/$2/[a-z/]*ubicloud-host as root: $3"
  has "$1" "sudo ubicloud-admin host preflight --site <site>"
  lacks "$1" "planted|ERROR"
  if docker exec "$CTR" test -e /t/pwned; then fail "$1: the planted script ran"; fi
  say "pass $1"
}
unsafe unsafe-shared shared "/t/shared is writable by others \(mode 1777\)"
unsafe unsafe-owned owned "/t/owned/host is owned by uid 65534, neither root nor you"
unsafe unsafe-grp grp "/t/grp is writable by group [0-9]+ \(mode 775\)"

bs upg 0 /t/upg/bootstrap-data-plane.sh --main-ip "$MAIN_IP"
has upg "/t/upg/ubicloud-host preflight --standalone --virt-tier kvm --main-ip $MAIN_IP"
has upg "preflight: 0 failing"
say "pass upg"

docker exec "$CTR" rm -f /dev/kvm
bs no-kvm 1 /t/base/bootstrap-data-plane.sh
has no-kvm "/dev/kvm is missing"
lacks no-kvm "host preflight"
say "pass no-kvm (the early exit stays)"

say "bootstrap-preflight: all cases pass"
