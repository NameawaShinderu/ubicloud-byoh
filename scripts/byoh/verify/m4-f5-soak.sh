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
# then runs `m2-checks health --host H --since START --probe` for each
# host, START being the soak's start:
#   - the host strand is not at unavailable;
#   - allocation_state is accepting;
#   - checkup is not set (the monitor read the host as down);
#   - no open page other than info names the host, and none was raised
#     since START and resolved again (a mark-down that recovered between
#     two samples);
#   - the health checks pass over a fresh SSH session (SMART, read/write,
#     kernel log, clock source), as HostNexus#available? runs them.
# and reads the monitor's log since the last sample for a "down" pulse of
# each host: the monitor logs every down reading, also those that never
# set checkup or that recover within the 90 s before HostNexus pages.
# Pass: no failing line in any sample. Hosts registered before M4 need
# `byoh-host relearn-device-ids --yes` first, or they fail by design.
#
# Settings (environment):
#   SOAK_CHECKS    the m2-checks command (default under systemd "sudo
#                  ubicloud-admin run m2-checks", which runs it in the
#                  release with /etc/ubicloud/env; else "bundle exec
#                  scripts/byoh/verify/m2-checks"). It is run once before
#                  the first sample: a command that cannot run stops the
#                  soak with exit 2, apart from a host's failure
#   SOAK_SERVICES  how the control plane runs: auto (default), systemd or
#                  tmux; picks how the monitor is looked for
#   SOAK_MONITOR_LOG  the monitor's log: "journal" (the journal of
#                  ubicloud-monitor.service; default under systemd; read
#                  with sudo -n unless the user may read it), a file
#                  (default under tmux /tmp/monitor.log, where
#                  bootstrap-dev-ctrl-plane.sh writes it) or "none". A log
#                  that cannot be read is a WARN line, not a failure
#   SOAK_LOG_DIR   where the log goes (default var)
#   SOAK_SLEEP     the command that waits between samples (default sleep)
#
# Exit status: 0 every sample passed; 1 a sample failed; 2 a usage error
# or an m2-checks command that cannot run.
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
  systemd)
    SOAK_CHECKS=${SOAK_CHECKS:-sudo ubicloud-admin run m2-checks}
    SOAK_MONITOR_LOG=${SOAK_MONITOR_LOG:-journal}
    ;;
  tmux)
    SOAK_CHECKS=${SOAK_CHECKS:-bundle exec scripts/byoh/verify/m2-checks}
    SOAK_MONITOR_LOG=${SOAK_MONITOR_LOG:-/tmp/monitor.log}
    ;;
  *) usage_die "SOAK_SERVICES must be auto, systemd or tmux, not $SOAK_SERVICES" ;;
esac
read -ra CHECKS <<<"$SOAK_CHECKS"
# m2-checks loads the database settings first; a command that cannot
# run would fail every sample for a reason that is not the host's.
if ! checks_out=$("${CHECKS[@]}" help 2>&1 </dev/null); then
  printf '%s\n' "$checks_out" | sed 's/^/  | /' >&2
  usage_die "$SOAK_CHECKS does not run here; set SOAK_CHECKS (see the header)"
fi

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

START_EPOCH=$(date +%s)
START=$(date -u -d "@$START_EPOCH" +%FT%TZ)
# The part of the monitor log already read: a byte offset in a file, the
# end of the last window in the journal.
LOG_MARK=$START_EPOCH
if [[ $SOAK_MONITOR_LOG != journal && $SOAK_MONITOR_LOG != none ]]; then
  LOG_MARK=$(stat -c %s "$SOAK_MONITOR_LOG" 2>/dev/null || echo 0)
fi

# monitor_lines: prints the monitor log written since the last call and
# moves the mark; returns 1 when the log cannot be read. It runs in this
# shell (never in $(...)), so the mark it moves stays moved.
monitor_lines() {
  if [[ $SOAK_MONITOR_LOG == journal ]]; then
    local now jc=(journalctl)
    now=$(date +%s)
    if [[ $EUID != 0 ]] && ! grep -qwE 'adm|systemd-journal' <<<"$(id -nG)"; then jc=(sudo -n journalctl); fi
    "${jc[@]}" -q -u ubicloud-monitor -o cat --since "@$LOG_MARK" --until "@$now" || return 1
    LOG_MARK=$now
  else
    [[ -r $SOAK_MONITOR_LOG ]] || return 1
    local size
    size=$(stat -c %s "$SOAK_MONITOR_LOG") || return 1
    # A log that shrank was rotated or truncated: read it whole.
    ((size >= LOG_MARK)) || LOG_MARK=0
    head -c "$size" "$SOAK_MONITOR_LOG" | tail -c +"$((LOG_MARK + 1))"
    LOG_MARK=$size
  fi
}

PULSES=$(mktemp)
trap 'rm -f "$PULSES"' EXIT
declare -A FAILED=()
monitor_down=0
failed_samples=0
log "m4-f5-soak: hosts ${HOSTS[*]}, $SAMPLES sample(s) every ${INTERVAL}s from $START, services $SOAK_SERVICES, monitor log $SOAK_MONITOR_LOG"
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
  pulses="" pulses_read=0
  if [[ $SOAK_MONITOR_LOG != none ]]; then
    if monitor_lines >"$PULSES"; then
      pulses=$(<"$PULSES")
      pulses_read=1
    else
      log "WARN cannot read the monitor log $SOAK_MONITOR_LOG: down readings between samples go unseen"
    fi
  fi
  for host in "${HOSTS[@]}"; do
    out=$("${CHECKS[@]}" health --host "$host" --since "$START" --probe 2>&1 </dev/null) && rc=0 || rc=$?
    # Clog writes JSON without spaces; a VmHost's pulse has its ubid.
    downs=$(grep -F "\"ubid\":\"$host\"" <<<"$pulses" | grep -cF '"reading":"down"' || true)
    if ((downs)); then
      out+=$'\n'"FAIL the monitor logged $downs down reading(s) of the host since the last sample"
    elif ((pulses_read)); then
      out+=$'\n'"PASS the monitor logged no down reading of the host since the last sample"
    fi
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
