#!/usr/bin/env bash
# M4 F5 soak (docs/byoh/VERIFY.md G-M4-3 EBS, G-M4-4 virtio, G-M4-5 LVM
# root): with bin/monitor running, samples every BYOH host named with
# --host for the given time and fails on any sample where the monitor or
# HostNexus judged the host down. Run it on the control plane, from the
# repository root.
#
# UNVERIFIED: this script has run only against stub commands
# (scripts/byoh/test/m4-gate-scripts.sh), never on a real host.
#
# Usage: scripts/byoh/verify/m4-f5-soak.sh --host vh... [--host vh...]
#          [--hours 24] [--interval 600] [--samples N]
#
# The monitor is not started here: start it by hand first (packaged:
# sudo systemctl start ubicloud-monitor; development: bin/monitor in a
# tmux session), and stop it afterwards unless you mean to keep it
# (docs/byoh/OPERATIONS.md section 9). Each sample checks that it runs,
# then runs `m2-checks health --host H --probe` for each host:
#   - the host strand is not at unavailable;
#   - allocation_state is accepting;
#   - checkup is not set (the monitor read the host as down);
#   - no open page other than info names the host;
#   - the health checks pass over a fresh SSH session (SMART, read/write,
#     kernel log, clock source), as HostNexus#available? runs them.
# Pass: no failing line in any sample. Hosts registered before M4 need
# `byoh-host relearn-device-ids --yes` first, or they fail by design.
#
# Settings (environment):
#   SOAK_CHECKS    the m2-checks command (default
#                  "bundle exec scripts/byoh/verify/m2-checks")
#   SOAK_SERVICES  how the control plane runs: auto (default), systemd or
#                  tmux; picks how the monitor is looked for
#   SOAK_LOG_DIR   where the log goes (default var)
#   SOAK_SLEEP     the command that waits between samples (default sleep)
#
# Exit status: 0 every sample passed; 1 a sample failed; 2 a usage error.
# The log is var/m4-f5-soak-<timestamp>.log.

set -euo pipefail

usage_die() {
  echo "! $*" >&2
  echo "  usage: $0 --host vh... [--host vh...] [--hours H] [--interval SECONDS] [--samples N]" >&2
  exit 2
}

HOSTS=()
HOURS=24
INTERVAL=600
SAMPLES=0
while (($#)); do
  case $1 in
    --host)
      (($# > 1)) || usage_die "--host needs a value"
      [[ $2 =~ ^vh[0-9a-z]{24}$ ]] || usage_die "--host takes a VmHost ubid, not $2"
      HOSTS+=("$2")
      shift 2
      ;;
    --hours | --interval | --samples)
      (($# > 1)) || usage_die "$1 needs a value"
      [[ $2 =~ ^[0-9]+$ ]] || usage_die "$1 takes a whole number, not $2"
      case $1 in
        --hours) HOURS=$2 ;;
        --interval) INTERVAL=$2 ;;
        --samples) SAMPLES=$2 ;;
      esac
      shift 2
      ;;
    *) usage_die "unknown argument $1" ;;
  esac
done
((${#HOSTS[@]})) || usage_die "--host is required"
((INTERVAL > 0)) || usage_die "--interval must be above 0"
# Without --samples, the hours decide: one sample at the start and one
# per interval until the time is up.
((SAMPLES > 0)) || SAMPLES=$((HOURS * 3600 / INTERVAL + 1))

read -ra CHECKS <<<"${SOAK_CHECKS:-bundle exec scripts/byoh/verify/m2-checks}"
read -ra SLEEP <<<"${SOAK_SLEEP:-sleep}"
SOAK_SERVICES=${SOAK_SERVICES:-auto}
if [[ $SOAK_SERVICES == auto ]]; then
  if [[ $(systemctl is-active ubicloud.target 2>/dev/null || true) == active ]]; then
    SOAK_SERVICES=systemd
  else
    SOAK_SERVICES=tmux
  fi
fi
case $SOAK_SERVICES in
  systemd | tmux) ;;
  *) usage_die "SOAK_SERVICES must be auto, systemd or tmux, not $SOAK_SERVICES" ;;
esac

SOAK_LOG_DIR=${SOAK_LOG_DIR:-var}
mkdir -p "$SOAK_LOG_DIR"
LOG="$SOAK_LOG_DIR/m4-f5-soak-$(date -u +%Y%m%dT%H%M%SZ).log"
: >"$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }

monitor_runs() {
  if [[ $SOAK_SERVICES == systemd ]]; then
    systemctl is-active --quiet ubicloud-monitor
  else
    pgrep -f 'bin/monitor' >/dev/null
  fi
}

declare -A FAILED=()
monitor_down=0
failed_samples=0
log "m4-f5-soak: hosts ${HOSTS[*]}, $SAMPLES sample(s) every ${INTERVAL}s, services $SOAK_SERVICES"
for ((i = 1; i <= SAMPLES; i++)); do
  bad=0
  log "== sample $i/$SAMPLES at $(date -u +%FT%TZ)"
  if monitor_runs; then
    log "PASS the monitor runs"
  else
    log "FAIL the monitor does not run; start it by hand (see the header)"
    monitor_down=$((monitor_down + 1))
    bad=1
  fi
  for host in "${HOSTS[@]}"; do
    out=$("${CHECKS[@]}" health --host "$host" --probe 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" | sed "s/^/$host /" | tee -a "$LOG"
    if ((rc != 0)) || grep -q '^FAIL' <<<"$out"; then
      FAILED[$host]=$((${FAILED[$host]:-0} + 1))
      bad=1
    fi
  done
  failed_samples=$((failed_samples + bad))
  ((i == SAMPLES)) || "${SLEEP[@]}" "$INTERVAL"
done

log "== summary: $SAMPLES sample(s), $failed_samples failing, monitor down in $monitor_down"
for host in "${HOSTS[@]}"; do
  log "   $host: ${FAILED[$host]:-0} failing sample(s)"
done
if ((failed_samples)); then
  log "== FAIL"
  exit 1
fi
log "== PASS"
