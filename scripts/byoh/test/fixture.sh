#!/bin/bash
# Runs as root INSIDE a throwaway ubi-m3-* container (never on a real
# host). Test helpers for the scenarios in run.sh; scripts/byoh/install.sh
# lays out the control plane itself.
#
#   fixture.sh units            install the units from /art/packaging/systemd
#                               and ubicloud-admin from /art/packaging/bin
#                               (the working tree's, over the release's)
#   fixture.sh account EMAIL    create a verified account (password on stdin)
#   fixture.sh as-service CMD…  run CMD in the release as ubicloud, with the
#                               service environment (parsed by systemd)
#   fixture.sh as-migrate CMD…  the same as ubicloud-migrate
#   fixture.sh argv-watch       while /root/argv-watch.run exists, scan
#                               every command line for the column key:
#                               argv-watch.leak holds the ps output of a
#                               hit, argv-watch.saw marks that a migrate
#                               ran (the positive control)
#
# FIXTURE_CWD replaces the release as the working directory, and
# FIXTURE_SETENV=KEY=value adds one variable.
set -euo pipefail
umask 077

TOOLS=/opt/ubicloud/tools
STATE=/var/lib/ubicloud

stage_units() {
  local changed=0 u
  for u in /art/packaging/systemd/*; do
    if ! cmp -s "$u" "/etc/systemd/system/${u##*/}"; then
      install -m 0644 "$u" /etc/systemd/system/
      changed=1
    fi
  done
  if ((changed)); then systemctl daemon-reload; fi
  install -m 0755 /art/packaging/bin/ubicloud-admin /usr/local/bin/ubicloud-admin
}

# Runs a command in the release as USER with exactly the environment the
# units get: systemd parses both env files, so this cannot drift from
# what web and respirate see.
service_env_run() {
  local user=$1
  shift
  systemd-run --quiet --wait --pipe --collect --uid="$user" -p UMask=0007 \
    -p EnvironmentFile=/etc/ubicloud/env \
    -p EnvironmentFile=/opt/ubicloud/current/.release-env \
    -p WorkingDirectory="${FIXTURE_CWD:-/opt/ubicloud/current}" \
    --setenv=PATH="$TOOLS/bin:/usr/bin:/bin" --setenv=HOME="$STATE" \
    ${FIXTURE_SETENV:+--setenv="$FIXTURE_SETENV"} \
    "$TOOLS/bin/ruby" "$@"
}

# The key is read from a file with grep -f, so no command line of the
# watcher itself ever carries it.
argv_watch() {
  local w=/root/argv-watch
  sed -n "s/^CLOVER_COLUMN_ENCRYPTION_KEY='\(.*\)'$/\1/p" /etc/ubicloud/env >"$w.key"
  test -s "$w.key"
  rm -f "$w.leak" "$w.saw"
  touch "$w.run"
  while [[ -e $w.run ]]; do
    ps -eo args >"$w.ps"
    grep -qF -f "$w.key" "$w.ps" && cp "$w.ps" "$w.leak"
    grep -q 'rake-task-runner migrate' "$w.ps" && touch "$w.saw"
  done
}

case ${1:-} in
  units) stage_units ;;
  argv-watch) argv_watch ;;
  account)
    service_env_run ubicloud bin/byoh-account create --email "${2:?email}" --password-stdin
    ;;
  as-service)
    shift
    service_env_run ubicloud "$@"
    ;;
  as-migrate)
    shift
    service_env_run ubicloud-migrate "$@"
    ;;
  *)
    echo "usage: fixture.sh units|account EMAIL|as-service ARGS…|as-migrate ARGS…|argv-watch" >&2
    exit 2
    ;;
esac
