#!/bin/bash
# Runs as root INSIDE a throwaway ubi-m3-* container (never on a real
# host). Test helpers for the scenarios in run.sh; scripts/byoh/install.sh
# lays out the control plane itself.
#
#   fixture.sh units            install the units from /art/packaging/systemd
#                               (the working tree's, over the release's)
#   fixture.sh account EMAIL    create a verified account (password on stdin)
#   fixture.sh as-service CMD…  run CMD in the release as ubicloud, with the
#                               service environment (parsed by systemd)
#   fixture.sh as-migrate CMD…  the same as ubicloud-migrate
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

case ${1:-} in
  units) stage_units ;;
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
    echo "usage: fixture.sh units|account EMAIL|as-service ARGS…|as-migrate ARGS…" >&2
    exit 2
    ;;
esac
