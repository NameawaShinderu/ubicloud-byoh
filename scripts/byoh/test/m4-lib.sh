# shellcheck shell=bash
# Helpers for the M4 container harness (host add, preflight). Sourced on
# the docker host. Wraps lib.sh with the ubi-m4 prefix: every container
# is named ubi-m4-*, joins only ubi-test-net, publishes no ports, and
# cleanup removes only the containers this run recorded.
#
#   prepare_fakehost_image   build ubi-m4-fakehost (Dockerfile.fakehost)
#   start_fakehost NAME      run ubi-m4-NAME from it; extra docker run
#                            args after NAME (e.g. -e FAKEHOST_ACTIVE=docker)
#   fakehost_ip NAME         its address on ubi-test-net
#   fakehost_key             the per-run RSA login key for user ubuntu
#   pf_fixture CASE          lay out the preflight fixture host CASE
#
# The login key is generated per run in $STATE and never committed.
# Never `set -x` here.

# lib.sh reads these. They come only from UBI_M4_STATE/UBI_M4_LOGS/
# UBI_M4_KEEP, never from an inherited UBI_M3_*, so an M4 run gets its
# own state dir unless asked otherwise (empty means unset in lib.sh).
# shellcheck disable=SC2034
UBI_TEST_PREFIX=ubi-m4
UBI_M3_STATE=${UBI_M4_STATE:-}
UBI_M3_LOGS=${UBI_M4_LOGS:-}
UBI_M3_KEEP=${UBI_M4_KEEP:-0}
# shellcheck source=scripts/byoh/test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAKEHOST_IMAGE=${UBI_M4_FAKEHOST_IMAGE:-ubi-m4-fakehost}

prepare_fakehost_image() {
  docker build -q -t "$FAKEHOST_IMAGE" -f "$HARNESS_DIR/Dockerfile.fakehost" "$HARNESS_DIR/fakehost" >/dev/null
  say "built $FAKEHOST_IMAGE"
}

fakehost_key() {
  if [[ ! -f $STATE/fakehost_rsa ]]; then
    ssh-keygen -q -t rsa -b 3072 -N "" -C ubi-m4-harness -f "$STATE/fakehost_rsa"
  fi
  echo "$STATE/fakehost_rsa"
}

start_fakehost() {
  local name=$PREFIX-$1 key
  shift
  key=$(fakehost_key)
  docker run -d --name "$name" --hostname "$name" --network "$NET" "$@" "$FAKEHOST_IMAGE" >/dev/null
  echo "$name" >>"$STATE/created"
  docker exec -i "$name" install -m 0600 -o ubuntu -g ubuntu /dev/stdin /home/ubuntu/.ssh/authorized_keys <"$key.pub"
  wait_for 30 docker exec "$name" bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' >/dev/null ||
    fail "$name: sshd did not listen ($(docker logs "$name" 2>&1 | tail -3 | tr '\n' ' '))"
  say "$name: $(fakehost_ip "${name#"$PREFIX"-}") $(docker exec "$name" sshd -V 2>&1 | head -1)"
}

fakehost_ip() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$PREFIX-$1"
}

# pf_fixture CASE: lays out fixtures/host/base with fixtures/host/CASE
# over it under $STATE/pf/CASE (CASE/.remove lists base paths it
# deletes), and prints that directory.
FIXTURES=$HARNESS_DIR/fixtures/host
pf_fixture() {
  local dir=$STATE/pf/$1 p
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$FIXTURES/base/." "$dir/"
  cp -R "$FIXTURES/$1/." "$dir/"
  if [[ -f $FIXTURES/$1/.remove ]]; then
    while read -r p; do
      [[ -n $p ]] && rm -rf "${dir:?}/$p"
    done <"$FIXTURES/$1/.remove"
  fi
  chmod -R a+rX "$dir"
  echo "$dir"
}
