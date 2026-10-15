#!/usr/bin/env bash
# M4 E2 gate (docs/byoh/VERIFY.md G-M4-1 on AWS, G-M4-2 on Proxmox): adds
# a site and one host with exactly the commands an operator types,
# `ubicloud-admin site add` then `ubicloud-admin host add --ssh`, records
# the transcript with per-line and per-phase times, then runs the M2 gate
# against the new host. Run it on the control plane, from the repository
# root, after `install.sh` (the first of the three commands) or on a
# development control plane.
#
# UNVERIFIED: this script has run only against stub commands
# (scripts/byoh/test/m4-gate-scripts.sh), never on AWS or Proxmox.
#
# Usage: scripts/byoh/verify/m4-e2.sh [-- SITE-ADD-OPTION...]
#   The options after -- go to `site add SITE` unchanged, for example
#     -- --display "AWS Mumbai (BYOH)" --underlay 10.98.0.0/16 \
#        --overlay 172.20.0.0/14 --cp-reach onhost --rates-from hetzner-fsn1
#   (terraform/aws-byoh prints them as byoh_location_create_command;
#   docs/byoh/recipes/proxmox.md lists them for Proxmox). When the site
#   exists already, site add is skipped and the log says so.
#
# Settings (environment):
#   SITE             site (BYOH location) name
#   PLATFORM         aws or proxmox (names the log; nothing else differs)
#   HOST_SSH         the operator's login to the host, USER@HOST
#   HOST_KEY         the operator's private key for that login
#   POOL_FILE        pools.yaml of the host
#   EXPECT_HOST_KEY  SHA256:... fingerprint(s) of the host's SSH host keys,
#                    space-separated, from the console or terraform. Without
#                    it, HOST_ADD_YES=1 must be set: the run then confirms
#                    the changes with --yes and trusts the key ssh meets
#   HOST_ADD_ARGS    more host add options, split on spaces (for example
#                    "--storage-disk virtio-ubi-data1 --main-ip 10.77.0.20")
#   MAIN_IP          the host's main IP for the gate (default: the host part
#                    of HOST_SSH, as host add itself defaults)
#   GATE_STEPS       m2-gate.sh steps after host add (default "g1 g2 g4 g5",
#                    the ones that need no VMs). GATE_* settings of m2-gate.sh
#                    pass through; GATE_LOCATION, GATE_HOST and GATE_MAIN_IP
#                    are set here
#   GATE_HOST_KEY    root key the gate logs in to the host with. Default: a
#                    key this run generates and gives host add as
#                    --registration-key, so the control plane and the gate
#                    log in with the same key
#   ADMIN            the ubicloud-admin command (default: "sudo ubicloud-admin"
#                    where /etc/ubicloud or /opt/ubicloud exists, else
#                    "packaging/bin/ubicloud-admin --dev")
#   E2_LOG_DIR       where the log and the generated key go (default var)
#   E2_GATE          the gate script (default scripts/byoh/verify/m2-gate.sh)
#
# Exit status: 0 when host add exited 0 (the host accepts VMs and pool
# verify passed) and the gate passed; 1 when a phase failed; 2 on a usage
# error. The log is var/m4-e2-<platform>-<timestamp>.log.

set -euo pipefail

usage_die() {
  echo "! $*" >&2
  echo "  see the header of $0" >&2
  exit 2
}

SITE_ADD_ARGS=()
if (($#)); then
  [[ $1 == -- ]] || usage_die "unexpected argument $1; site add options go after --"
  shift
  SITE_ADD_ARGS=("$@")
fi

for name in SITE PLATFORM HOST_SSH HOST_KEY POOL_FILE; do
  [[ -n ${!name:-} ]] || usage_die "$name is not set"
done
case $PLATFORM in
  aws | proxmox) ;;
  *) usage_die "PLATFORM must be aws or proxmox, not $PLATFORM" ;;
esac
[[ $HOST_SSH == *@* ]] || usage_die "HOST_SSH must be USER@HOST, not $HOST_SSH"
[[ -r $HOST_KEY ]] || usage_die "HOST_KEY $HOST_KEY is not readable"
[[ -r $POOL_FILE ]] || usage_die "POOL_FILE $POOL_FILE is not readable"

EXPECT_ARGS=()
for fp in ${EXPECT_HOST_KEY:-}; do
  EXPECT_ARGS+=(--expect-host-key "$fp")
done
if ((${#EXPECT_ARGS[@]} == 0)); then
  [[ ${HOST_ADD_YES:-0} == 1 ]] || usage_die "set EXPECT_HOST_KEY to the host's fingerprints, or HOST_ADD_YES=1 to trust the key ssh meets"
  EXPECT_ARGS=(--yes)
fi
read -ra EXTRA_ARGS <<<"${HOST_ADD_ARGS:-}"

MAIN_IP=${MAIN_IP:-${HOST_SSH#*@}}
GATE_STEPS=${GATE_STEPS:-g1 g2 g4 g5}
E2_LOG_DIR=${E2_LOG_DIR:-var}
E2_GATE=${E2_GATE:-scripts/byoh/verify/m2-gate.sh}
if [[ -z ${ADMIN:-} ]]; then
  if [[ -e /etc/ubicloud || -e /opt/ubicloud ]]; then
    ADMIN="sudo ubicloud-admin"
  else
    ADMIN="packaging/bin/ubicloud-admin --dev"
  fi
fi
read -ra ADMIN_CMD <<<"$ADMIN"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$E2_LOG_DIR"
LOG="$E2_LOG_DIR/m4-e2-$PLATFORM-$STAMP.log"
: >"$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }

REG_ARGS=()
if [[ -z ${GATE_HOST_KEY:-} ]]; then
  GATE_HOST_KEY="$E2_LOG_DIR/m4-e2-$PLATFORM-$STAMP.key"
  ssh-keygen -q -t ed25519 -N '' -C "m4-e2 $SITE" -f "$GATE_HOST_KEY" </dev/null
  REG_ARGS=(--registration-key "$GATE_HOST_KEY")
  log "generated the registration key $GATE_HOST_KEY; the gate logs in with it"
fi

PHASES=()
# phase NAME COMMAND...: runs the command with its output timestamped in
# seconds since the phase began, and records the phase's duration.
phase() {
  local name=$1 start rc
  shift
  log "== $name: $*"
  start=$(date +%s)
  set +e
  "$@" </dev/null 2>&1 | while IFS= read -r line; do
    printf '[%5ds] %s\n' "$(($(date +%s) - start))" "$line"
  done | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  set -e
  PHASES+=("$name $(($(date +%s) - start))s exit $rc")
  log "== $name: exit $rc after $(($(date +%s) - start))s"
  return "$rc"
}

summary() {
  log "== summary ($PLATFORM, site $SITE, host $MAIN_IP)"
  local p
  for p in "${PHASES[@]}"; do log "   $p"; done
  log "== $1"
}

log "m4-e2 $PLATFORM $STAMP: site $SITE, host $HOST_SSH, pools $POOL_FILE, admin: $ADMIN"

if "${ADMIN_CMD[@]}" site show "$SITE" >/dev/null 2>&1; then
  log "== site add: skipped, site $SITE exists"
elif ! phase "site add" "${ADMIN_CMD[@]}" site add "$SITE" "${SITE_ADD_ARGS[@]}"; then
  summary "FAIL site add"
  exit 1
fi

if ! phase "host add" "${ADMIN_CMD[@]}" host add --site "$SITE" --ssh "$HOST_SSH" --ssh-key "$HOST_KEY" \
  --pool-file "$POOL_FILE" "${EXPECT_ARGS[@]}" "${REG_ARGS[@]}" "${EXTRA_ARGS[@]}"; then
  summary "FAIL host add (resume with the same command; the bring-up keeps running)"
  exit 1
fi

GATE_HOST=$(grep -oE 'host vh[0-9a-z]{24}' "$LOG" | tail -1 | cut -d' ' -f2 || true)
if [[ -z $GATE_HOST ]]; then
  summary "FAIL host add exited 0 but printed no host ubid"
  exit 1
fi
log "host $GATE_HOST accepts VMs"

read -ra STEPS <<<"$GATE_STEPS"
export GATE_LOCATION=$SITE GATE_HOST GATE_MAIN_IP=$MAIN_IP GATE_HOST_KEY
if ! phase "m2 gate" "$E2_GATE" "${STEPS[@]}"; then
  summary "FAIL m2 gate"
  exit 1
fi

summary "PASS: host add exited 0, $GATE_HOST accepts VMs, m2 gate ($GATE_STEPS) passed"
