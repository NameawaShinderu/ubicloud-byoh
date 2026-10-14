#!/bin/bash
# Moves a control plane that scripts/byoh/bootstrap-dev-ctrl-plane.sh (or
# its predecessor, bootstrap-ctrl-plane.sh) set up, with puma and
# respirate in tmux and database clover_test, to the packaged layout of
# scripts/byoh/install.sh: database ubicloud with peer authentication,
# /etc/ubicloud/env and the systemd units. The development database is
# copied, never changed: only its connections are switched off, so a
# rollback starts tmux against it again as it was at the copy. Run it as
# root, one phase at a time, from a checkout of the release
# (docs/byoh/MIGRATE_FROM_DEV.md is the runbook):
#
#   sudo bash migrate-from-dev.sh preflight --dev-user ubuntu \
#     --version v0.1.0-m3 --source-git ~/ubicloud-m3 --ref <commit> \
#     --admin-email ops@example.com --backup-recipient age1... \
#     [--dev-repo ~/ubicloud] [--dev-db clover_test] [--tls tunnel|none] \
#     [--url URL] [--mail-from ADDR] [--rack-env development|production] \
#     [--backup-recipient-file F] [--skip-check clock|mem|listen]...
#   sudo bash migrate-from-dev.sh install
#   (stop respirate, then puma, in tmux)
#   sudo bash migrate-from-dev.sh copy-db [--i-understand-this-drops-live-data]
#   sudo bash migrate-from-dev.sh start
#   sudo bash migrate-from-dev.sh flip-production [--back]
#   sudo bash migrate-from-dev.sh rollback
#   sudo bash migrate-from-dev.sh retire --restore-drill-done [--skip-backup-count]
#
# preflight  Read-only. Compares the development database's migrations
#            with the release's (a row the release lacks is a downgrade
#            and fatal; the pre-M1 name of the generic-provider migration
#            is renamed by copy-db, in ubicloud only), lists the keys
#            .env.rb sets (names only) and what happens to each, checks
#            the BMC password variables host_provider.config names, the
#            billing-rates directory, the cloudflared origin and disk
#            space, and says whether the hosts need install_rhizome. It
#            records the flags in /var/lib/ubicloud-migration/state; the
#            later phases take them from there (a flag given again must
#            be the same).
# install    preflight again, then /etc/ubicloud/env from .env.rb (the
#            secrets kept; CLOVER_DATABASE_URL and GIT_REV dropped,
#            RACK_ENV and BILLING_RATES_EXTRA_DIR rewritten, the BMC
#            password variables added) and install.sh --no-start, which
#            copies the billing rates.
# copy-db    Refuses while ubicloud services or the development processes
#            run, while clients use the development database, or when
#            database ubicloud holds a finished copy (unless
#            --i-understand-this-drops-live-data: it is then kept as
#            ubicloud_prev_<time>). Waits for strand leases to end,
#            dumps the development database to
#            <backup target>/pre-migration-<time>.dump, switches off its
#            connections, restores the dump as role ubicloud_restorer
#            without owners or privileges, hands every object to
#            ubicloud or ubicloud_password (migrate-role-map.sql), runs
#            the pending migrations as ubicloud-migrate and checks the
#            result against a database migrated from scratch at the
#            same release (migrate-compare.sql), the row counts against
#            the source (migrate-row-counts.sql) and the password-hash
#            isolation (bin/byoh-config-check).
# start      Refuses a copy that a rollback gave up or whose development
#            database accepts connections again. Enables and starts
#            ubicloud.target, checks that every
#            Sshable runs a command and that nothing listens on a
#            non-loopback address of the web port, runs install_rhizome
#            on every host when preflight found rhizome changes, then
#            ubicloud-admin smoke and status (status fails on the
#            bootstrap's trust rules until retire; that line is
#            expected).
# flip-production  ubicloud-admin backup now, then bin/byoh-config-check
#            --simulate-production, which must have no fail, then
#            install.sh again with --rack-env production. --back returns
#            to development the same way, without the check.
# rollback   Disables and stops ubicloud.target, marks database ubicloud
#            rolled back (start then refuses it, and copy-db replaces it
#            only with --i-understand-this-drops-live-data), switches the
#            development database's connections on again, prints what
#            the packaged
#            control plane did after the copy (VMs, pages, strands) and
#            the tmux commands that start the development control plane
#            again, with a warning when a BMC password variable came
#            from respirate's environment, not .env.rb. Run them as the
#            development user.
# retire     Once the packaged control plane ran 14 nights with backups
#            and a restore drill passed: the bootstrap's trust rules in
#            pg_hba.conf go back to Ubuntu's peer and scram-sha-256,
#            the role that owns the development tables (clover; never
#            postgres or a ubicloud role) can no longer log in and is no
#            superuser, the
#            development database is renamed to <db>_retired_<date>
#            (never dropped) and the bootstrap's marker directory is
#            moved aside. ubicloud-admin status then has no trust fail.
#
# Values from .env.rb or the environment are never printed or put on a
# command line. Exit status: 0 on success, 1 on a failure, 2 on a usage
# error or a refusal that changed nothing.
set -euo pipefail
umask 077

readonly OPT=/opt/ubicloud
readonly TOOLS=$OPT/tools
readonly CURRENT=$OPT/current
readonly STATE=/var/lib/ubicloud
readonly ETC=/etc/ubicloud
readonly ENV_FILE=$ETC/env
readonly BACKUP_CONF=$ETC/backup.conf
readonly ADMIN_BIN=/usr/local/bin/ubicloud-admin
readonly LOCK=/run/ubicloud-admin.lock
readonly MIG_LOCK=/run/ubicloud-migrate-from-dev.lock
readonly MIG_DIR=/var/lib/ubicloud-migration
readonly MIG_STATE=$MIG_DIR/state
readonly PG_VERSION=16
readonly PG_CONF=/etc/postgresql/$PG_VERSION/main
readonly SERVICE_PATH=$TOOLS/bin:/usr/bin:/bin
readonly DB_NAME=ubicloud
readonly RATES_DIR=$STATE/billing_rates.d
readonly SERVICES=(ubicloud-web ubicloud-respirate ubicloud-monitor)
# Migrations upstream renamed after the development bootstrap applied
# them (CLAUDE.md §8): OLD:NEW. copy-db renames them in the copy only.
readonly RENAMES=("20260412000000_add_generic_provider.rb:20260412_add_generic_provider.rb")
# How long copy-db waits for respirate's strand leases to end. A strand
# runs at most about 91 s before apoptosis ends respirate.
readonly LEASE_WAIT=150
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

# Keys the env file must never set (the same lists as install.sh and
# ubicloud-admin).
readonly KEY_RE='^[A-Z][A-Z0-9_]{0,63}$'
readonly DENIED_KEY_RE='^(PATH|IFS|BASH_ENV|ENV|HOME|SHELL|LD_[A-Z0-9_]*)$'
readonly INTERP_KEY_RE='^(RUBYOPT|RUBYLIB|RUBYSHELL|GEM_[A-Z0-9_]*|BUNDLE_[A-Z0-9_]*|BUNDLER_[A-Z0-9_]*|NODE_OPTIONS|NODE_PATH)$'

# --- output ---------------------------------------------------------------

FATALS=0 WARNS=0
report() { printf '%-7s %s\n' "$1" "$2"; }
fatal() {
  report fatal "$1"
  FATALS=$((FATALS + 1))
}
warn() {
  report warn "$1"
  WARNS=$((WARNS + 1))
}
die() {
  printf 'migrate-from-dev.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}
usage_die() { die "$1" 2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

WORK=""
cleanup_work() { [[ -z $WORK ]] || rm -rf "$WORK"; }
make_work() {
  [[ -n $WORK ]] && return 0
  WORK=$(mktemp -d /tmp/ubicloud-migrate.XXXXXX)
  trap cleanup_work EXIT
}

# --- the KEY='value' file format (M3-b), as in install.sh -------------------

declare -A KV=()
KV_KEYS=()
KV_LINES=()

# kv_read FILE: loads FILE into KV, KV_KEYS (in file order) and KV_LINES
# (every line, comments included). Errors name the line, never a value.
kv_read() {
  local file=$1 line n=0 re="^([A-Z][A-Z0-9_]{0,63})='([^']*)'$"
  KV=() KV_KEYS=() KV_LINES=()
  [[ -e $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    KV_LINES+=("$line")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ $re ]] || die "$file line $n is not KEY='value' (the value is not shown)"
    local key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ ! $key =~ $DENIED_KEY_RE ]] || die "$file line $n sets $key, which the env file must not set"
    [[ $value != *\\* && $value != *$'\r'* ]] || die "$file line $n: the value of $key has a backslash or CR"
    [[ -z ${KV[$key]+x} ]] || die "$file line $n sets $key a second time"
    KV[$key]=$value
    KV_KEYS+=("$key")
  done <"$file"
}

valid_value() { [[ $1 != *"'"* && $1 != *\\* && $1 != *$'\n'* && $1 != *$'\r'* ]]; }

# --- arguments ---------------------------------------------------------------

PHASE=""
declare -A ARG=()
SKIP_CHECKS=()
DROP_LIVE=0 BACK=0 SKIP_BACKUP_COUNT=0 DRILL_DONE=0

need_arg() { [[ $# -ge 2 && -n $2 ]] || usage_die "$1 needs a value"; }

parse_args() {
  PHASE=${1:-}
  shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dev-user | --dev-repo | --dev-db | --version | --source-git | --ref | --rack-env | --tls | --url | \
        --admin-email | --mail-from | --backup-recipient | --backup-recipient-file)
        need_arg "$@"
        ARG[${1#--}]=$2
        shift
        ;;
      --skip-check) need_arg "$@"; SKIP_CHECKS+=("$2"); shift ;;
      --i-understand-this-drops-live-data) DROP_LIVE=1 ;;
      --back) BACK=1 ;;
      --skip-backup-count) SKIP_BACKUP_COUNT=1 ;;
      --restore-drill-done) DRILL_DONE=1 ;;
      --import-env-rb) usage_die "--import-env-rb is what the install phase does; give --dev-user and --dev-repo to preflight" ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_die "unknown argument $1 (see --help)" ;;
    esac
    shift
  done
  case $PHASE in
    preflight | install | copy-db | start | flip-production | rollback | retire) ;;
    -h | --help | help | "")
      usage
      [[ -n $PHASE ]] || exit 2
      exit 0
      ;;
    *) usage_die "unknown phase $PHASE; the phases are preflight, install, copy-db, start, flip-production, rollback and retire" ;;
  esac
  ((DROP_LIVE == 0)) || [[ $PHASE == copy-db ]] || usage_die "--i-understand-this-drops-live-data goes with copy-db"
  ((BACK == 0)) || [[ $PHASE == flip-production ]] || usage_die "--back goes with flip-production"
  ((SKIP_BACKUP_COUNT + DRILL_DONE == 0)) || [[ $PHASE == retire ]] || usage_die "--skip-backup-count and --restore-drill-done go with retire"
}

# The flags preflight records. Every other phase reads them from the
# state file, and a flag given to it must say the same.
readonly PLAN_KEYS=(dev-user dev-repo dev-db version source-git ref rack-env tls url admin-email mail-from backup-recipient backup-recipient-file skip-checks)

state_key() {
  local k=${1^^}
  printf '%s' "${k//-/_}"
}

# Fills ARG from the state file for the phases after preflight.
load_state() {
  [[ -f $MIG_STATE ]] || usage_die "no $MIG_STATE; run the preflight phase first"
  kv_read "$MIG_STATE"
  declare -A st=()
  local k
  for k in "${KV_KEYS[@]}"; do st[$k]=${KV[$k]}; done
  local p sk
  for p in "${PLAN_KEYS[@]}"; do
    sk=$(state_key "$p")
    if [[ $p == skip-checks ]]; then
      local given="${SKIP_CHECKS[*]:-}"
      [[ -z $given || $given == "${st[$sk]:-}" ]] || usage_die "--skip-check differs from the preflight run; run preflight again with the new flags"
      read -r -a SKIP_CHECKS <<<"${st[$sk]:-}"
      continue
    fi
    if [[ -n ${ARG[$p]+x} && ${ARG[$p]} != "${st[$sk]:-}" ]]; then
      # Paths may be given in another spelling.
      if [[ $p == dev-repo || $p == source-git || $p == backup-recipient-file ]] &&
        [[ $(realpath -m -- "${ARG[$p]}") == "${st[$sk]:-}" ]]; then
        :
      elif [[ $p == ref && ${st[REV]:-} == "${ARG[$p]}" ]]; then
        :
      else
        usage_die "--$p differs from the preflight run; run preflight again with the new flags"
      fi
    fi
    ARG[$p]=${st[$sk]:-}
  done
  for k in "${STATE_KEYS[@]}"; do
    S[$k]=${st[$k]:-}
  done
}

declare -A S=()
# What preflight found and the later phases recorded. DEV_ROLE is the
# role that owns the development database's tables (retire demotes it);
# BMC_FROM_PROC names the BMC password variables found only in the
# running respirate's environment; ROLLED_BACK is the time of the last
# rollback, cleared by the copy-db after it.
readonly STATE_KEYS=(REV R0_REV RENAME RHIZOME CUTOVER_TS STARTED_TS RACK_ENV_NOW DEV_HOME DEV_ROLE BMC_FROM_PROC ROLLED_BACK)

# write_state: the flags and what preflight found, root 0600.
write_state() {
  local out=() p
  out+=("# $MIG_STATE: written by scripts/byoh/migrate-from-dev.sh preflight; the later phases read it.")
  for p in "${PLAN_KEYS[@]}"; do
    if [[ $p == skip-checks ]]; then
      out+=("$(state_key "$p")='${SKIP_CHECKS[*]:-}'")
    else
      out+=("$(state_key "$p")='${ARG[$p]:-}'")
    fi
  done
  local k
  for k in "${STATE_KEYS[@]}"; do
    out+=("$k='${S[$k]:-}'")
  done
  install -d -m 0700 -o root -g root "$MIG_DIR"
  install -m 0600 -o root -g root /dev/null "$MIG_STATE.new"
  printf '%s\n' "${out[@]}" >"$MIG_STATE.new"
  mv -f "$MIG_STATE.new" "$MIG_STATE"
}

set_state() {
  S[$1]=$2
  write_state
}

validate_plan() {
  local u=${ARG[dev-user]:-}
  [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || usage_die "--dev-user must name the user that runs the development control plane (such as ubuntu)"
  id "$u" >/dev/null 2>&1 || usage_die "--dev-user $u does not exist"
  S[DEV_HOME]=$(getent passwd "$u" | cut -d: -f6)
  ARG[dev-repo]=$(realpath -m -- "${ARG[dev-repo]:-${S[DEV_HOME]}/ubicloud}")
  [[ -f ${ARG[dev-repo]}/.env.rb ]] || usage_die "--dev-repo ${ARG[dev-repo]} has no .env.rb"
  ARG[dev-db]=${ARG[dev-db]:-clover_test}
  [[ ${ARG[dev-db]} =~ ^[a-z_][a-z0-9_]{0,62}$ && ${ARG[dev-db]} != "$DB_NAME"* ]] ||
    usage_die "--dev-db must be the development database's name (such as clover_test)"
  [[ ${ARG[version]:-} =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || usage_die "--version is required (such as v0.1.0-m3)"
  [[ -n ${ARG[source-git]:-} && -d ${ARG[source-git]} ]] || usage_die "--source-git DIR is required: a checkout of the release (such as ~/ubicloud-m3)"
  ARG[source-git]=$(realpath -e -- "${ARG[source-git]}")
  [[ -n ${ARG[ref]:-} ]] || usage_die "--ref is required: the commit of the release"
  ARG[rack-env]=${ARG[rack-env]:-development}
  case ${ARG[rack-env]} in development | production) ;; *) usage_die "--rack-env must be development or production" ;; esac
  ARG[tls]=${ARG[tls]:-tunnel}
  case ${ARG[tls]} in
    tunnel | none) ;;
    *) usage_die "--tls must be tunnel or none; move with one of them, then switch the front with install.sh" ;;
  esac
  [[ ${ARG[admin-email]:-} =~ ^[^@[:space:]\'\\]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || usage_die "--admin-email must be an email address"
  [[ -z ${ARG[backup-recipient]:-} || -z ${ARG[backup-recipient-file]:-} ]] ||
    usage_die "give --backup-recipient or --backup-recipient-file, not both"
  [[ -z ${ARG[backup-recipient]:-} || ${ARG[backup-recipient]} =~ ^age1[02-9ac-hj-np-z]{58}$ ]] ||
    usage_die "--backup-recipient must be an age public key (age1...)"
  if [[ -n ${ARG[backup-recipient-file]:-} ]]; then
    [[ -f ${ARG[backup-recipient-file]} ]] || usage_die "--backup-recipient-file is not a file"
    ARG[backup-recipient-file]=$(realpath -e -- "${ARG[backup-recipient-file]}")
  fi
  local c
  for c in "${SKIP_CHECKS[@]}"; do
    case $c in clock | mem | listen) ;; *) usage_die "--skip-check takes clock, mem or listen" ;; esac
  done
  local v
  for v in "${ARG[@]}"; do
    valid_value "$v" || usage_die "a flag value contains a quote, backslash, newline or CR"
  done
}

# --- helpers -------------------------------------------------------------------

psql_value() { runuser -u postgres -- psql -X -tA -v ON_ERROR_STOP=1 "$@"; }
psql_admin() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
db_exists() { [[ -n $(psql_value -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'") ]]; }
db_comment() { psql_value -d postgres -c "SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = '$1'"; }
unit_state() { systemctl is-active "$1" 2>/dev/null || true; }
db_allows_connections() { [[ $(psql_value -d postgres -c "SELECT datallowconn FROM pg_database WHERE datname = '$1'") == t ]]; }

# retirable_role ROLE: ROLE exists and is one retire may make NOLOGIN
# NOSUPERUSER: not the cluster's bootstrap superuser (oid 10, postgres),
# no pg_* role and none of the packaged control plane's.
retirable_role() {
  [[ $1 =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || return 1
  case $1 in postgres | ubicloud | ubicloud_* | pg_*) return 1 ;; esac
  [[ $(psql_value -d postgres -c "SELECT oid = 10 FROM pg_roles WHERE rolname = '$1'") == f ]]
}

# as_dev CMD...: CMD as the development user with a clean environment.
as_dev() {
  (cd / && runuser -u "${ARG[dev-user]}" -- env -i HOME="${S[DEV_HOME]}" LANG=C.UTF-8 \
    PATH="${S[DEV_HOME]}/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@")
}

# as_src CMD...: CMD as the owner of the release checkout (git refuses
# repositories that another user owns).
as_src() {
  local owner
  owner=$(stat -c %U "${ARG[source-git]}")
  (cd / && runuser -u "$owner" -- env -i HOME="$(getent passwd "$owner" | cut -d: -f6)" PATH=/usr/bin:/bin "$@")
}

# as_service USER CMD...: CMD in the current release as USER with exactly
# the env file, the release env, PATH, HOME and LANG=C.UTF-8, umask 0007,
# as the units run (the same as ubicloud-admin's). The values travel in
# the environment, never in argv.
as_service() {
  local user=$1 group
  shift
  group=$(id -gn "$user")
  (
    cd "$CURRENT" || exit 1
    local k f
    while IFS= read -r k; do unset "$k" 2>/dev/null || exit 1; done < <(compgen -e)
    export LANG=C.UTF-8
    for f in "$ENV_FILE" "$CURRENT/.release-env"; do
      kv_read "$f"
      for k in "${KV_KEYS[@]}"; do
        export "$k=${KV[$k]}" 2>/dev/null || die "$f sets $k, which bash cannot export"
      done
    done
    export PATH=$SERVICE_PATH HOME=$STATE
    umask 0007
    # fd 8 and 9 are this script's locks, which no unprivileged process
    # may hold.
    exec setpriv --reuid="$user" --regid="$group" --init-groups -- "$@" 8>&- 9>&-
  )
}

# The processes of the development control plane: puma and respirate
# (and monitor) of the development user, not the tmux server whose
# command line names them.
dev_processes() {
  ps -u "${ARG[dev-user]}" -o pid=,comm=,args= 2>/dev/null |
    awk '$2 !~ /^tmux/ && ($0 ~ /bin\/respirate/ || $0 ~ /bin\/monitor/ || $0 ~ /puma/) { print }' || true
}

# The Ruby that reads .env.rb as the development user: its own (mise),
# else the packaged one, else the system's.
dev_ruby() {
  local v="" r
  if [[ -f ${ARG[dev-repo]}/mise.toml ]]; then
    v=$(sed -n 's/^ruby = "\(.*\)"$/\1/p' "${ARG[dev-repo]}/mise.toml")
  elif [[ -f ${ARG[dev-repo]}/.tool-versions ]]; then
    v=$(awk '$1 == "ruby" { print $2 }' "${ARG[dev-repo]}/.tool-versions")
  fi
  for r in "${S[DEV_HOME]}/.local/share/mise/installs/ruby/$v/bin/ruby" "$TOOLS/bin/ruby" /usr/bin/ruby; do
    [[ -n $v || $r != "${S[DEV_HOME]}"* ]] || continue
    if as_dev test -x "$r"; then
      printf '%s' "$r"
      return 0
    fi
  done
  return 1
}

dev_ruby_version() {
  if [[ -f ${ARG[dev-repo]}/mise.toml ]]; then
    sed -n 's/^ruby = "\(.*\)"$/\1/p' "${ARG[dev-repo]}/mise.toml"
  elif [[ -f ${ARG[dev-repo]}/.tool-versions ]]; then
    awk '$1 == "ruby" { print $2 }' "${ARG[dev-repo]}/.tool-versions"
  fi
}

# --- .env.rb import --------------------------------------------------------------

# Loads .env.rb as the development user with an empty environment and
# prints, NUL-separated, every KEY and value it sets. The values reach
# only root's pipe. When loading fails, the last line on stderr is the
# exception class and the line of .env.rb, never Ruby's message, which
# quotes source tokens (an unquoted value in a NameError, the offending
# line in a SyntaxError). It runs on the system Ruby too, so no "it".
# shellcheck disable=SC2016 # Ruby code
readonly IMPORT_RB='before = ENV.to_h
path = File.expand_path(ARGV[0])
Dir.chdir(File.dirname(path))
begin
  load path
rescue Exception => e
  line = e.backtrace_locations&.find { |l| l.absolute_path == path }&.lineno
  line ||= e.message.to_s[/#{Regexp.escape(path)}:(\d+)/, 1] if e.is_a?(SyntaxError)
  warn "#{e.class.name}#{" at line #{line}" if line}"
  exit 1
end
ENV.to_h.sort.each { |k, v| $stdout.write(k, "\0", v, "\0") unless before[k] == v }'

declare -A IMP=() FINAL=()
IMP_KEYS=() FINAL_KEYS=()
RATES_SRC="" URL="" MAIL_FROM=""

read_env_rb() {
  local ruby k v
  IMP=() IMP_KEYS=()
  ruby=$(dev_ruby) || {
    fatal "env: no Ruby to read ${ARG[dev-repo]}/.env.rb with (the development user's mise Ruby, $TOOLS/bin/ruby or /usr/bin/ruby)"
    return 0
  }
  make_work
  if ! as_dev "$ruby" -e "$IMPORT_RB" "${ARG[dev-repo]}/.env.rb" >"$WORK/import" 2>"$WORK/import.err"; then
    # Only the line IMPORT_RB wrote, and only in its own shape.
    local why
    why=$(tail -1 "$WORK/import.err")
    [[ $why =~ ^[A-Z][A-Za-z0-9_:]{0,80}( at line [0-9]{1,6})?$ ]] || why="see the Ruby error by loading it yourself as ${ARG[dev-user]}; it is not shown here, as it may quote a value"
    rm -f "$WORK/import.err"
    fatal "env: loading ${ARG[dev-repo]}/.env.rb as ${ARG[dev-user]} failed: $why"
    return 0
  fi
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    IMP[$k]=$v
    IMP_KEYS+=("$k")
  done <"$WORK/import"
  rm -f "$WORK/import"
}

# The header IP_FROM_HEADER must name for the front (install.sh's rule).
front_header() {
  if [[ ${ARG[tls]} == tunnel ]]; then echo CF-Connecting-IP; fi
}

# plan_import: decides what becomes of every key .env.rb sets and fills
# FINAL with the env file's imported keys. Prints names, never values.
plan_import() {
  FINAL=() FINAL_KEYS=()
  local k v kept=() dropped=() rewritten=()
  local base=${IMP[BASE_URL]:-}
  URL=${ARG[url]:-${base%/}}
  if [[ -z $URL ]]; then
    fatal "env: .env.rb sets no BASE_URL; pass --url"
  elif [[ ${ARG[tls]} == tunnel && ! $URL =~ ^https://[A-Za-z0-9.-]+$ ]]; then
    fatal "env: the URL ($( [[ -n ${ARG[url]:-} ]] && echo --url || echo "BASE_URL of .env.rb")) must be https://HOST, with no port or path, for --tls tunnel; pass --url"
  elif [[ ${ARG[tls]} == none && ! $URL =~ ^http://localhost:[0-9]+$ ]]; then
    fatal "env: --tls none needs the URL http://localhost:PORT; pass --url"
  fi
  MAIL_FROM=${ARG[mail-from]:-${IMP[MAIL_FROM]:-${ARG[admin-email]}}}
  for k in "${IMP_KEYS[@]}"; do
    v=${IMP[$k]}
    if [[ ! $k =~ $KEY_RE || $k =~ $DENIED_KEY_RE ]]; then
      fatal "env: .env.rb sets $k, which the env file cannot hold (names are A-Z, 0-9 and _, and PATH, HOME, LD_* and the like are refused); remove it from .env.rb"
      continue
    fi
    if [[ $k =~ $INTERP_KEY_RE || $k == PRY_ALLOW_UNAUDITED ]]; then
      fatal "env: .env.rb sets $k, which loads code into or opens a console in every service; remove it from .env.rb"
      continue
    fi
    case $k in
      CLOVER_DATABASE_URL | GIT_REV)
        dropped+=("$k")
        continue
        ;;
      RACK_ENV) v=${ARG[rack-env]} rewritten+=("$k") ;;
      BILLING_RATES_EXTRA_DIR)
        RATES_SRC=$v
        v=$RATES_DIR
        rewritten+=("$k")
        ;;
      BASE_URL)
        v=$URL
        [[ ${IMP[$k]} == "$v" ]] || rewritten+=("$k")
        ;;
      MAIL_FROM)
        v=$MAIL_FROM
        [[ ${IMP[$k]} == "$v" ]] || rewritten+=("$k")
        ;;
      IP_FROM_HEADER)
        [[ $v == "$(front_header)" ]] ||
          fatal "env: .env.rb sets IP_FROM_HEADER to another header than --tls ${ARG[tls]} sets (${ARG[tls]} wants '$(front_header)'); remove it from .env.rb, install.sh sets it"
        ;;
      BIND)
        [[ $v == 127.0.0.1 || $v == localhost || $v == ::1 || $v == "[::1]" ]] ||
          fatal "env: .env.rb sets BIND to a non-loopback address; the packaged puma listens on 127.0.0.1 behind the front, so remove it from .env.rb"
        ;;
      PORT)
        [[ $v != 8081 ]] || fatal "env: .env.rb sets PORT 8081, which bin/production_check needs; remove it from .env.rb"
        ;;
      *) kept+=("$k") ;;
    esac
    if ! valid_value "$v"; then
      fatal "env: the value of $k in .env.rb has a quote, backslash, newline or CR, which /etc/ubicloud/env cannot hold"
      continue
    fi
    FINAL[$k]=$v
    FINAL_KEYS+=("$k")
  done
  [[ -n ${FINAL[CLOVER_COLUMN_ENCRYPTION_KEY]:-} ]] ||
    fatal "env: .env.rb sets no CLOVER_COLUMN_ENCRYPTION_KEY; the encrypted columns of ${ARG[dev-db]} cannot be read without it"
  [[ -n ${FINAL[CLOVER_SESSION_SECRET]:-} ]] ||
    fatal "env: .env.rb sets no CLOVER_SESSION_SECRET; without it every password hash of ${ARG[dev-db]} is useless"
  for k in RACK_ENV BASE_URL MAIL_FROM; do
    if [[ -z ${FINAL[$k]+x} ]]; then
      case $k in
        RACK_ENV) FINAL[$k]=${ARG[rack-env]} ;;
        BASE_URL) FINAL[$k]=$URL ;;
        MAIL_FROM) FINAL[$k]=$MAIL_FROM ;;
      esac
      FINAL_KEYS+=("$k")
      rewritten+=("$k")
    fi
  done
  report ok "env: .env.rb sets ${#IMP_KEYS[@]} key(s): ${IMP_KEYS[*]}"
  ((${#kept[@]} == 0)) || report ok "env: kept as they are: ${kept[*]}"
  ((${#rewritten[@]} == 0)) || report notice "env: set by this move: ${rewritten[*]} (RACK_ENV ${ARG[rack-env]}, BILLING_RATES_EXTRA_DIR $RATES_DIR, BASE_URL $URL)"
  ((${#dropped[@]} == 0)) || report notice "env: not imported: ${dropped[*]} (install.sh sets the database URL; the release sets GIT_REV)"
}

# check_bmc_envs: every password_env that host_provider.config names
# must have a value, from .env.rb or the environment of the running
# development respirate; the found ones join FINAL.
check_bmc_envs() {
  local has names n pid found v from_proc=()
  S[BMC_FROM_PROC]=""
  has=$(psql_value -d "${ARG[dev-db]}" -c "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'host_provider' AND column_name = 'config'") || {
    fatal "bmc: cannot read ${ARG[dev-db]}"
    return 0
  }
  if [[ $has != 1 ]]; then
    report ok "bmc: ${ARG[dev-db]} has no host_provider.config"
    return 0
  fi
  names=$(psql_value -d "${ARG[dev-db]}" -c "SELECT DISTINCT config->'bmc'->>'password_env' FROM host_provider WHERE config->'bmc'->>'password_env' IS NOT NULL ORDER BY 1")
  if [[ -z $names ]]; then
    report ok "bmc: no host names a password_env"
    return 0
  fi
  while IFS= read -r n; do
    if [[ ! $n =~ $KEY_RE || $n =~ $DENIED_KEY_RE || $n =~ $INTERP_KEY_RE ]]; then
      fatal "bmc: a host's password_env is '$n', which the env file cannot hold; re-register that host's BMC with --bmc-pass-env NAME (A-Z, 0-9, _)"
      continue
    fi
    if [[ -n ${FINAL[$n]+x} ]]; then
      report ok "bmc: $n comes from .env.rb"
      continue
    fi
    found=""
    for pid in $(dev_processes | awk '/bin\/respirate/ { print $1 }'); do
      v=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n "s/^$n=//p" | head -1) || true
      if [[ -n $v ]]; then
        found=$v
        break
      fi
    done
    if [[ -z $found ]]; then
      fatal "bmc: no value for $n, which a host's BMC config names: .env.rb does not set it and no running development respirate has it; add it to .env.rb"
    elif ! valid_value "$found"; then
      fatal "bmc: the value of $n has a quote, backslash, newline or CR, which /etc/ubicloud/env cannot hold"
    else
      FINAL[$n]=$found
      FINAL_KEYS+=("$n")
      from_proc+=("$n")
      warn "bmc: $n comes from the environment of the running development respirate, not .env.rb; the tmux commands of a rollback start respirate without it, so add it to .env.rb"
    fi
  done <<<"$names"
  S[BMC_FROM_PROC]="${from_proc[*]:-}"
}

# --- preflight ---------------------------------------------------------------------

# Migration file names of the release: MIG (migrate/) and MIG_PH
# (migrate/ph/), from git at the ref or from a release directory.
declare -A REL_MIG=() REL_PH=()
release_migrations_git() {
  local f
  REL_MIG=() REL_PH=()
  while IFS= read -r f; do
    case $f in
      migrate/ph/*.rb) REL_PH[${f#migrate/ph/}]=1 ;;
      migrate/*/*) ;;
      migrate/*.rb) REL_MIG[${f#migrate/}]=1 ;;
    esac
  done < <(as_src git -C "${ARG[source-git]}" ls-tree -r --name-only "${S[REV]}" -- migrate/)
}

release_migrations_dir() {
  local f
  REL_MIG=() REL_PH=()
  for f in "$1"/migrate/*.rb; do REL_MIG[${f##*/}]=1; done
  for f in "$1"/migrate/ph/*.rb; do REL_PH[${f##*/}]=1; done
}

# source_migrations DB: SRC_MIG and SRC_PH, the applied file names.
SRC_MIG=() SRC_PH=()
source_migrations() {
  mapfile -t SRC_MIG < <(psql_value -d "$1" -c "SELECT filename FROM schema_migrations ORDER BY 1")
  if [[ $(psql_value -d "$1" -c "SELECT to_regclass('public.schema_migrations_password') IS NOT NULL") == t ]]; then
    mapfile -t SRC_PH < <(psql_value -d "$1" -c "SELECT filename FROM schema_migrations_password ORDER BY 1")
  else
    SRC_PH=()
  fi
}

# compare_migrations: PENDING, PENDING_PH and NEED_RENAME from SRC_* and
# REL_*; MISSING lists what the release lacks.
PENDING=() PENDING_PH=() MISSING=() NEED_RENAME=0
compare_migrations() {
  local f r old new
  declare -A have=()
  PENDING=() PENDING_PH=() MISSING=() NEED_RENAME=0
  for f in "${SRC_MIG[@]}"; do
    for r in "${RENAMES[@]}"; do
      old=${r%%:*} new=${r#*:}
      if [[ $f == "$old" && -n ${REL_MIG[$new]:-} && -z ${REL_MIG[$old]:-} ]]; then
        f=$new
        NEED_RENAME=1
      fi
    done
    have[$f]=1
    [[ -n ${REL_MIG[$f]:-} ]] || MISSING+=("$f")
  done
  for f in "${!REL_MIG[@]}"; do [[ -n ${have[$f]:-} ]] || PENDING+=("$f"); done
  have=()
  for f in "${SRC_PH[@]}"; do
    have[$f]=1
    [[ -n ${REL_PH[$f]:-} ]] || MISSING+=("ph/$f")
  done
  for f in "${!REL_PH[@]}"; do [[ -n ${have[$f]:-} ]] || PENDING_PH+=("ph/$f"); done
  mapfile -t PENDING < <(printf '%s\n' "${PENDING[@]}" | sed '/^$/d' | sort)
  mapfile -t PENDING_PH < <(printf '%s\n' "${PENDING_PH[@]}" | sed '/^$/d' | sort)
}

pf_schema() {
  db_exists "${ARG[dev-db]}" || {
    fatal "schema: database ${ARG[dev-db]} does not exist"
    return 0
  }
  if [[ $(psql_value -d postgres -c "SELECT datallowconn FROM pg_database WHERE datname = '${ARG[dev-db]}'") != t ]]; then
    DEV_OFF=1
    report notice "schema: ${ARG[dev-db]} accepts no connections (copy-db ran); its migrations and BMC settings were checked then, and rollback switches them on again"
    return 0
  fi
  source_migrations "${ARG[dev-db]}"
  release_migrations_git
  ((${#REL_MIG[@]})) || {
    fatal "schema: the release at ${S[REV]} has no migrate/*.rb"
    return 0
  }
  compare_migrations
  if ((${#MISSING[@]})); then
    fatal "schema: ${ARG[dev-db]} has ${#MISSING[@]} migration(s) the release lacks (${MISSING[*]:0:5}); the release is older than the development database, which would be a downgrade"
  else
    report ok "schema: ${ARG[dev-db]} has ${#SRC_MIG[@]}/${#SRC_PH[@]} migrations, all in the release"
  fi
  ((NEED_RENAME == 0)) ||
    report notice "schema: ${ARG[dev-db]} applied ${RENAMES[0]%%:*}, which the release names ${RENAMES[0]#*:}; copy-db renames the row in database ubicloud only"
  S[RENAME]=$NEED_RENAME
  if ((${#PENDING[@]} + ${#PENDING_PH[@]})); then
    report notice "schema: copy-db runs ${#PENDING[@]} pending migration(s) and ${#PENDING_PH[@]} password-hash one(s):"
    printf '%s\n' "${PENDING[@]}" "${PENDING_PH[@]}" | sed '/^$/d; s/^/          pending: /' | head -20
    ((${#PENDING[@]} + ${#PENDING_PH[@]} <= 20)) || echo "          ... and $((${#PENDING[@]} + ${#PENDING_PH[@]} - 20)) more"
  else
    report ok "schema: no pending migrations"
  fi
  local ext
  ext=$(psql_value -d "${ARG[dev-db]}" -c "SELECT string_agg(extname, ',') FROM pg_extension WHERE extname NOT IN ('plpgsql', 'citext', 'btree_gist')")
  [[ -z $ext ]] || fatal "schema: ${ARG[dev-db]} uses extension(s) $ext; the copy creates only citext and btree_gist"
  local roles
  roles=$(psql_value -d "${ARG[dev-db]}" -c "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.schema_migrations'::regclass")
  if [[ ! $roles =~ ^[a-z_][a-z0-9_]*$ ]]; then
    fatal "schema: cannot tell which role owns ${ARG[dev-db]}"
  elif ! retirable_role "$roles"; then
    fatal "schema: the tables of ${ARG[dev-db]} belong to role $roles, which retire would demote; the development bootstrap's role is clover"
  else
    S[DEV_ROLE]=$roles
    report ok "schema: ${ARG[dev-db]} belongs to role $roles (password hashes: ${roles}_password)"
  fi
}

pf_rhizome() {
  local r0 dirty
  r0=$(as_dev git -C "${ARG[dev-repo]}" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  S[R0_REV]=$r0
  if [[ -z $r0 ]]; then
    S[RHIZOME]=1
    warn "rhizome: ${ARG[dev-repo]} is no git checkout, so R0 is unknown; start runs install_rhizome on every host"
    return 0
  fi
  report ok "R0: ${ARG[dev-repo]} is at $r0 (record it: rollback starts this tree again)"
  dirty=$(as_dev git -C "${ARG[dev-repo]}" status --porcelain --untracked-files=no 2>/dev/null | awk '{ print $2 }' | head -5 | tr '\n' ' ')
  [[ -z $dirty ]] || warn "R0: ${ARG[dev-repo]} has uncommitted changes (${dirty% }); rollback runs the tree as it is, not $r0"
  if ! as_src git -C "${ARG[source-git]}" cat-file -e "$r0^{commit}" 2>/dev/null; then
    S[RHIZOME]=1
    warn "rhizome: R0 $r0 is not in ${ARG[source-git]}; start runs install_rhizome on every host"
  elif ! as_src git -C "${ARG[source-git]}" diff --quiet "$r0" "${S[REV]}" -- rhizome; then
    S[RHIZOME]=1
    report notice "rhizome: rhizome/ changed since R0 ($(as_src git -C "${ARG[source-git]}" diff --shortstat "$r0" "${S[REV]}" -- rhizome | sed 's/^ //')); start runs install_rhizome on every host"
  elif [[ -n $(as_dev git -C "${ARG[dev-repo]}" status --porcelain --untracked-files=no -- rhizome 2>/dev/null) ]]; then
    S[RHIZOME]=1
    warn "rhizome: rhizome/ in ${ARG[dev-repo]} has uncommitted changes; start runs install_rhizome on every host"
  else
    S[RHIZOME]=0
    report ok "rhizome: unchanged since R0; the hosts keep their rhizome"
  fi
}

pf_rates() {
  if [[ -z $RATES_SRC ]]; then
    report notice "billing rates: .env.rb sets no BILLING_RATES_EXTRA_DIR; $RATES_DIR starts empty"
  elif [[ ! -d $RATES_SRC ]]; then
    fatal "billing rates: BILLING_RATES_EXTRA_DIR of .env.rb is not a directory"
  else
    report ok "billing rates: $(find "$RATES_SRC" -maxdepth 1 -name '*.yml' | wc -l) file(s) in $RATES_SRC go to $RATES_DIR"
  fi
}

# The cloudflared origin: which address its connections to the web port
# reach while a request goes through the tunnel.
pf_cloudflared() {
  if [[ ${ARG[tls]} != tunnel ]]; then
    report ok "cloudflared: --tls ${ARG[tls]}"
    return 0
  fi
  if ! systemctl cat cloudflared.service >/dev/null 2>&1; then
    report notice "cloudflared: no cloudflared.service; install needs --tls none or a tunnel token (install.sh --cloudflared-token-file) later"
    fatal "cloudflared: --tls tunnel keeps an existing cloudflared.service, and there is none"
    return 0
  fi
  if [[ $(systemctl show -p ExecStart --value cloudflared.service) =~ (^|[[:space:]])--token([[:space:]]|=) ]]; then
    report notice "cloudflared: token on the command line: yes (install.sh warns; the unit is not changed)"
  else
    report ok "cloudflared: token on the command line: no"
  fi
  local port=${IMP[PORT]:-3000} peers="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null -m 5 "$URL/login" >/dev/null 2>&1 &
    peers+=$(ss -Htnp state established "( dport = :$port )" 2>/dev/null | awk '/"cloudflared"/ { print $4 }')$'\n'
    sleep 0.5
  done
  wait || true
  peers=$(sed '/^$/d' <<<"$peers" | sort -u | tr '\n' ' ')
  if [[ -z $peers ]]; then
    warn "cloudflared: saw no connection from cloudflared to port $port; make sure the tunnel's origin is http://127.0.0.1:$port"
  else
    local p bad=""
    for p in $peers; do
      [[ $p == "127.0.0.1:$port" || $p == "[::1]:$port" ]] || bad+="$p "
    done
    if [[ -n $bad ]]; then
      fatal "cloudflared: the tunnel reaches puma at ${bad% }; the packaged puma listens on 127.0.0.1:$port only, so set the origin to http://127.0.0.1:$port (Cloudflare dashboard) before the move"
    else
      report ok "cloudflared: the tunnel's origin is ${peers% }"
    fi
  fi
}

pf_disk() {
  local size data avail target dir
  size=$(psql_value -d postgres -c "SELECT pg_database_size('${ARG[dev-db]}')") || return 0
  data=$(psql_value -d postgres -c "SHOW data_directory")
  avail=$(df --output=avail -B1 "$data" | tail -1)
  if ((avail < 3 * size)); then
    fatal "disk: $data has $((avail >> 20)) MiB free, under 3 times ${ARG[dev-db]} ($((size >> 20)) MiB): the copy, the reference database and the old one"
  else
    report ok "disk: ${ARG[dev-db]} is $((size >> 20)) MiB; $data has $((avail >> 20)) MiB free"
  fi
  target=/var/backups/ubicloud
  if [[ -f $BACKUP_CONF ]]; then
    kv_read "$BACKUP_CONF"
    target=${KV[BACKUP_TARGET]:-$target}
  fi
  dir=$target
  while [[ ! -d $dir ]]; do dir=$(dirname "$dir"); done
  avail=$(df --output=avail -B1 "$dir" | tail -1)
  ((avail >= size)) || fatal "disk: $dir has $((avail >> 20)) MiB free, less than the pre-migration dump needs"
}

DEV_OFF=0
run_preflight() {
  FATALS=0 WARNS=0
  local rev
  rev=$(as_src git -C "${ARG[source-git]}" rev-parse --verify --quiet "${ARG[ref]}^{commit}") ||
    usage_die "--ref ${ARG[ref]} is not a commit in ${ARG[source-git]}"
  S[REV]=$rev
  [[ -f $SCRIPT_DIR/install.sh ]] || die "$SCRIPT_DIR/install.sh is missing; run this script from the release checkout"
  report ok "release: ${ARG[version]} at $rev from ${ARG[source-git]}"
  if [[ -L $CURRENT ]]; then
    local cur
    cur=$(readlink "$CURRENT")
    [[ ${cur##*/} == "${ARG[version]}" ]] || fatal "release: $CURRENT is ${cur##*/}, not ${ARG[version]}"
  fi
  systemctl is-active -q "postgresql@$PG_VERSION-main" || fatal "postgres: postgresql@$PG_VERSION-main is not running"
  read_env_rb
  plan_import
  pf_schema
  ((DEV_OFF)) || check_bmc_envs
  pf_rates
  pf_rhizome
  pf_cloudflared
  pf_disk
  local procs
  procs=$(dev_processes | awk '{ print $1 }' | tr '\n' ' ')
  report ok "development: processes of ${ARG[dev-user]}: ${procs:-none}"
  echo
  if ((FATALS)); then
    echo "preflight: $FATALS fatal, $WARNS warn; resolve every fatal line, then run preflight again"
    return 1
  fi
  echo "preflight: ok ($WARNS warn). Plan:"
  echo "  1. install (install.sh --no-start; nothing stops)"
  echo "  2. stop respirate (tmux send-keys -t respirate C-c; wait for it to exit, never kill), then puma"
  echo "  3. copy-db: ${ARG[dev-db]} -> ubicloud (${#PENDING[@]} pending migration(s)$( ((S[RENAME])) && echo ', one renamed'))"
  echo "  4. start$( ((S[RHIZOME])) && echo ' (with install_rhizome on every host)')"
  echo "  Rollback: rollback, then the tmux commands it prints, in ${ARG[dev-repo]} (R0 ${S[R0_REV]:-unknown})"
}

phase_preflight() {
  # A preflight after copy-db keeps what the later phases recorded.
  if [[ -f $MIG_STATE ]]; then
    kv_read "$MIG_STATE"
    local k
    for k in RENAME CUTOVER_TS STARTED_TS RACK_ENV_NOW DEV_ROLE BMC_FROM_PROC ROLLED_BACK; do S[$k]=${KV[$k]:-}; done
  fi
  validate_plan
  run_preflight || exit 1
  # The flags and findings for the later phases; written only on success.
  write_state
}

# --- install ------------------------------------------------------------------------

write_env_file() {
  local out=() k
  out+=("# /etc/ubicloud/env: settings of the ubicloud services, KEY='value' per line, no text after the closing quote. Imported from ${ARG[dev-repo]}/.env.rb by migrate-from-dev.sh; change with ubicloud-admin env set KEY.")
  for k in $(printf '%s\n' "${FINAL_KEYS[@]}" | sort); do
    out+=("$k='${FINAL[$k]}'")
  done
  install -d -m 0755 -o root -g root "$ETC"
  install -m 0600 -o root -g root /dev/null "$ENV_FILE.new"
  printf '%s\n' "${out[@]}" >"$ENV_FILE.new"
  mv -f "$ENV_FILE.new" "$ENV_FILE"
  report changed "env: $ENV_FILE with ${#FINAL_KEYS[@]} imported key(s)"
}

install_args() {
  INSTALL_ARGS=(--version "${ARG[version]}" --url "$URL" --tls "${ARG[tls]}" --admin-email "${ARG[admin-email]}"
    --mail-from "$MAIL_FROM" --rack-env "$1" --source-git "${ARG[source-git]}" --ref "${S[REV]}")
  [[ -z ${ARG[backup-recipient]:-} ]] || INSTALL_ARGS+=(--backup-recipient "${ARG[backup-recipient]}")
  [[ -z ${ARG[backup-recipient-file]:-} ]] || INSTALL_ARGS+=(--backup-recipient-file "${ARG[backup-recipient-file]}")
  local c
  for c in "${SKIP_CHECKS[@]}"; do INSTALL_ARGS+=(--skip-check "$c"); done
}

phase_install() {
  load_state
  validate_plan
  run_preflight || die "preflight has fatal findings (above); nothing was installed"
  write_state
  echo
  if [[ -e $ENV_FILE ]]; then
    kv_read "$ENV_FILE"
    local k differ=()
    for k in "${FINAL_KEYS[@]}"; do
      [[ ${KV[$k]-} == "${FINAL[$k]}" ]] || differ+=("$k")
    done
    ((${#differ[@]} == 0)) ||
      die "$ENV_FILE exists and differs from ${ARG[dev-repo]}/.env.rb in ${differ[*]}; it was not written by this move or .env.rb changed since. Move it away (it may hold the only copy of a column key) and run install again" 2
    report ok "env: $ENV_FILE holds the imported keys"
  else
    write_env_file
  fi
  install_args "${ARG[rack-env]}"
  [[ -z $RATES_SRC ]] || INSTALL_ARGS+=(--billing-rates-dir "$RATES_SRC")
  echo "install.sh --no-start:"
  bash "$SCRIPT_DIR/install.sh" "${INSTALL_ARGS[@]}" --no-start 8>&- 9>&- || die "install.sh failed (above); fix the cause and run install again"
  S[RACK_ENV_NOW]=${ARG[rack-env]}
  write_state
  echo
  echo "install: done. Next: stop respirate (tmux send-keys -t respirate C-c; wait), then puma, then: migrate-from-dev.sh copy-db"
}

# --- copy-db -------------------------------------------------------------------------

take_locks() {
  exec 8>>"$MIG_LOCK"
  flock -n 8 || die "another migrate-from-dev.sh run holds $MIG_LOCK"
  exec 9>>"$LOCK"
  flock -w 60 9 || die "another install.sh or ubicloud-admin run holds $LOCK"
}

# The kind of the database ubicloud: none, migrating (a copy-db that did
# not finish), migrated (a finished copy, rolled back or not), pristine (install.sh's: no account, and no
# strand but the ones migrations seed) or used.
ubicloud_kind() {
  db_exists "$DB_NAME" || {
    echo none
    return 0
  }
  local c n
  c=$(db_comment "$DB_NAME")
  case $c in
    "migrated-from "* | "rolled-back-from "*) echo migrated ;;
    "migrating-from "*) echo migrating ;;
    *)
      # A fresh migrate seeds one LocationNexus strand per location; a
      # respirate that ran creates others (LogVmHostUtilizations).
      n=$(psql_value -d "$DB_NAME" -c "SELECT CASE WHEN to_regclass('public.accounts') IS NULL THEN 0 ELSE (SELECT count(*) FROM accounts) END + CASE WHEN to_regclass('public.strand') IS NULL THEN 0 ELSE (SELECT count(*) FROM strand WHERE prog <> 'LocationNexus') END")
      if [[ $n == 0 ]]; then echo pristine; else echo used; fi
      ;;
  esac
}

# rename_db_try FROM TO: renames a database nobody is connected to.
rename_db_try() {
  local _
  for _ in 1 2 3 4 5; do
    psql_value -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$1' AND pid <> pg_backend_pid()" >/dev/null
    psql_value -d postgres -c "ALTER DATABASE \"$1\" RENAME TO \"$2\"" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

migrate_as_service() {
  as_service ubicloud-migrate "$TOOLS/bin/ruby" bin/rake-task-runner migrate "" 0 >"$WORK/migrate-$1.log" 2>&1 || {
    grep -v -i 'password' "$WORK/migrate-$1.log" | tail -20 >&2
    return 1
  }
}

new_db() {
  runuser -u postgres -- createdb -O ubicloud "$1"
  psql_admin -d "$1" -c 'CREATE EXTENSION citext' -c 'CREATE EXTENSION btree_gist' -c 'ALTER SCHEMA public OWNER TO ubicloud'
}

backup_target() {
  kv_read "$BACKUP_CONF"
  local t=${KV[BACKUP_TARGET]:-/var/backups/ubicloud}
  printf '%s' "${t%/}"
}

COPY_ARMED=0
copy_exit_trap() {
  local rc=$? allow
  if ((COPY_ARMED && rc != 0)); then
    allow=$(psql_value -d postgres -c "SELECT CASE WHEN datallowconn THEN 'accepts connections' ELSE 'accepts no connections' END FROM pg_database WHERE datname = '${ARG[dev-db]}'" 2>/dev/null || echo "is in an unknown state")
    printf 'migrate-from-dev.sh: copy-db stopped (exit %s); %s %s and is unchanged otherwise. Fix the cause and run copy-db again, or run rollback to go back to the development control plane.\n' "$rc" "${ARG[dev-db]}" "$allow" >&2
  fi
  cleanup_work
}

phase_copy_db() {
  load_state
  take_locks
  make_work
  local dev=${ARG[dev-db]} u procs kind
  # 1. Refusals; nothing changes before these pass.
  [[ -d $CURRENT/ && -f $ENV_FILE && -x $ADMIN_BIN ]] || die "no packaged control plane here; run the install phase first" 2
  for u in ubicloud.target "${SERVICES[@]}"; do
    [[ $(unit_state "$u") != active ]] || die "$u is active; copy-db replaces the database it uses, so stop it first (systemctl stop ubicloud.target)" 2
  done
  procs=$(dev_processes)
  [[ -z $procs ]] || die "the development control plane still runs (stop respirate with tmux send-keys -t respirate C-c and wait for it to exit, then puma):
$procs" 2
  db_exists "$dev" || die "database $dev does not exist" 2
  local allow clients
  allow=$(psql_value -d postgres -c "SELECT datallowconn FROM pg_database WHERE datname = '$dev'")
  clients=$(psql_value -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$dev'")
  [[ $clients == 0 ]] || die "$clients client(s) are connected to $dev (SELECT * FROM pg_stat_activity WHERE datname = '$dev'); close them first" 2
  kind=$(ubicloud_kind)
  case $kind in
    migrated | used)
      ((DROP_LIVE)) || die "database $DB_NAME holds $( [[ $kind == migrated ]] && echo "a finished copy ($(db_comment "$DB_NAME"))" || echo "data of its own"); a new copy replaces it, and whatever the packaged control plane did there is no longer live. Pass --i-understand-this-drops-live-data to go on (the old database is kept as ${DB_NAME}_prev_<time>)" 2
      ;;
  esac
  for u in ubicloud ubicloud_password ubicloud_restorer; do
    [[ -n $(psql_value -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$u'") ]] || die "database role $u does not exist; run the install phase first" 2
  done
  local f
  for f in migrate-role-map.sql migrate-compare.sql migrate-row-counts.sql; do
    [[ -f $CURRENT/scripts/byoh/$f ]] || die "the release has no scripts/byoh/$f" 2
  done
  release_migrations_dir "$CURRENT"
  if [[ $allow == t ]]; then
    source_migrations "$dev"
    compare_migrations
    ((${#MISSING[@]} == 0)) || die "$dev has migration(s) the release lacks (${MISSING[*]:0:5}); that would be a downgrade" 2
  fi
  report ok "copy-db: checks passed ($dev, database $DB_NAME: $kind)"

  # 2. respirate's leases end (never forced).
  [[ $allow == t ]] || psql_value -d postgres -c "ALTER DATABASE \"$dev\" ALLOW_CONNECTIONS true" >/dev/null
  COPY_ARMED=1
  trap copy_exit_trap EXIT
  local i n=1
  for ((i = 0; i < LEASE_WAIT; i += 5)); do
    n=$(psql_value -d "$dev" -c "SELECT count(*) FROM strand WHERE lease > now()")
    [[ $n == 0 ]] && break
    sleep 5
  done
  if [[ $n != 0 ]]; then
    # datallowconn reads t or f; ALTER DATABASE takes only true or false.
    psql_value -d postgres -c "ALTER DATABASE \"$dev\" ALLOW_CONNECTIONS $([[ $allow == t ]] && echo true || echo false)" >/dev/null
    COPY_ARMED=0
    die "$n strand lease(s) in $dev are still held after $LEASE_WAIT s; a respirate may still run somewhere. Investigate; nothing was changed" 2
  fi
  report ok "copy-db: no strand holds a lease"
  source_migrations "$dev"
  compare_migrations
  ((${#MISSING[@]} == 0)) || die "$dev has migration(s) the release lacks (${MISSING[*]:0:5})" 2
  local dev_rename=$NEED_RENAME dev_n=${#SRC_MIG[@]}

  # 3. The dump, the row counts, and the development database switched
  # off. A client that slipped in between is a stop.
  local target ts dump src_role ph_tables ph_funcs
  target=$(backup_target)
  install -d -m 0700 -o root -g root "$target"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  dump=$target/pre-migration-$ts.dump
  runuser -u postgres -- pg_dump -Fc "$dev" >"$dump.partial" || die "pg_dump of $dev failed"
  chmod 0600 "$dump.partial"
  mv -f "$dump.partial" "$dump"
  report ok "copy-db: $dump ($(du -h "$dump" | cut -f1))"
  runuser -u postgres -- psql -X -q -d "$dev" -f "$CURRENT/scripts/byoh/migrate-row-counts.sql" >"$WORK/rows.src"
  src_role=$(psql_value -d "$dev" -c "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.schema_migrations'::regclass")
  retirable_role "$src_role" || die "the tables of $dev belong to role $src_role, which retire would demote; the development bootstrap's role is clover"
  [[ -z ${S[DEV_ROLE]:-} || ${S[DEV_ROLE]} == "$src_role" ]] || die "the tables of $dev belong to role $src_role, preflight found ${S[DEV_ROLE]}; run preflight again"
  ph_tables=$(psql_value -d "$dev" -c "SELECT coalesce(string_agg(relname, ',' ORDER BY relname), '') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND pg_get_userbyid(relowner) = '${src_role}_password'")
  ph_funcs=$(psql_value -d "$dev" -c "SELECT coalesce(string_agg(oid::regprocedure::text, '|' ORDER BY 1), '') FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND pg_get_userbyid(proowner) = '${src_role}_password'")
  psql_value -d postgres -c "ALTER DATABASE \"$dev\" ALLOW_CONNECTIONS false" >/dev/null
  clients=$(psql_value -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$dev'")
  [[ $clients == 0 ]] || die "a client connected to $dev during the dump, so the dump may miss its writes; close it and run copy-db again"
  report changed "copy-db: $dev no longer accepts connections (rollback switches them on again)"

  # 4. The reference: a database migrated from scratch at this release.
  for u in "${DB_NAME}_ref" "${DB_NAME}_restore"; do
    if db_exists "$u"; then
      runuser -u postgres -- dropdb "$u"
      report notice "copy-db: dropped $u, left by an earlier copy-db"
    fi
  done
  case $kind in
    migrating)
      runuser -u postgres -- dropdb "$DB_NAME"
      report notice "copy-db: dropped $DB_NAME, the copy of an earlier copy-db that did not finish"
      ;;
    migrated | used)
      local prev
      prev=${DB_NAME}_prev_$(date -u +%Y%m%d%H%M%S)
      rename_db_try "$DB_NAME" "$prev" || die "cannot rename $DB_NAME to $prev"
      report changed "copy-db: $DB_NAME is now $prev (drop it yourself once it is not needed)"
      ;;
  esac
  if [[ $kind == pristine ]]; then
    # install.sh migrated it at this release, unless a release switch
    # came in between: then it is no reference.
    source_migrations "$DB_NAME"
    local stale=0
    [[ ${#SRC_MIG[@]} == "${#REL_MIG[@]}" ]] || stale=1
    for f in "${SRC_MIG[@]}"; do [[ -n ${REL_MIG[$f]:-} ]] || stale=1; done
    if ((stale)); then
      runuser -u postgres -- dropdb "$DB_NAME"
    else
      rename_db_try "$DB_NAME" "${DB_NAME}_ref" || die "cannot rename $DB_NAME to ${DB_NAME}_ref"
      report ok "copy-db: the database install.sh migrated is the reference (${DB_NAME}_ref)"
    fi
  fi
  if ! db_exists "${DB_NAME}_ref"; then
    new_db "$DB_NAME"
    migrate_as_service ref || die "migrating the reference database failed (above)"
    rename_db_try "$DB_NAME" "${DB_NAME}_ref" || die "cannot rename $DB_NAME to ${DB_NAME}_ref"
    report ok "copy-db: built ${DB_NAME}_ref, migrated from scratch at this release"
  fi

  # 5. The copy, restored as ubicloud_restorer, never as a superuser.
  new_db "${DB_NAME}_restore"
  psql_value -d postgres -c "COMMENT ON DATABASE ${DB_NAME}_restore IS 'migrating-from $dev $ts'" >/dev/null
  local mgroup list_dir
  mgroup=$(id -gn ubicloud-migrate)
  list_dir=$(mktemp -d /tmp/ubicloud-migrate-restore.XXXXXX)
  chown "root:$mgroup" "$list_dir"
  chmod 0750 "$list_dir"
  runuser -u postgres -- pg_restore --list <"$dump" >"$WORK/toc"
  grep -vE '^[0-9]+; [0-9]+ [0-9]+ (EXTENSION - |COMMENT - EXTENSION |SCHEMA - public )' "$WORK/toc" >"$list_dir/toc" || true
  chown "root:$mgroup" "$list_dir/toc"
  chmod 0640 "$list_dir/toc"
  if ! env -i PATH=/usr/bin:/bin LANG=C.UTF-8 setpriv --reuid=ubicloud-migrate --regid="$mgroup" --init-groups -- \
    pg_restore --exit-on-error --no-password --no-owner --no-acl -U ubicloud_restorer -d "${DB_NAME}_restore" -L "$list_dir/toc" <"$dump" 2>"$WORK/restore.err" 8>&- 9>&-; then
    rm -rf "$list_dir"
    head -5 "$WORK/restore.err" >&2
    die "pg_restore into ${DB_NAME}_restore failed"
  fi
  rm -rf "$list_dir"
  runuser -u postgres -- psql -X -q -d "${DB_NAME}_restore" -f "$CURRENT/scripts/byoh/migrate-row-counts.sql" >"$WORK/rows.copy"
  if ! diff "$WORK/rows.src" "$WORK/rows.copy" >"$WORK/rows.diff"; then
    sed 's/^/  /' "$WORK/rows.diff" | head -20 >&2
    die "the row counts of the copy differ from $dev (above)"
  fi
  report ok "copy-db: restored as ubicloud_restorer; row counts equal $dev in all $(wc -l <"$WORK/rows.src") tables"

  # 6. The renamed migration, in the copy only.
  local r
  if ((dev_rename)); then
    for r in "${RENAMES[@]}"; do
      psql_value -d "${DB_NAME}_restore" -c "UPDATE schema_migrations SET filename = '${r#*:}' WHERE filename = '${r%%:*}'" >/dev/null
    done
    report changed "copy-db: renamed ${RENAMES[0]%%:*} to ${RENAMES[0]#*:} in the copy"
  fi

  # 7 and 8. Owners and the password-hash grants (migrate-role-map.sql).
  runuser -u postgres -- psql -X -q -d "${DB_NAME}_restore" -v app_role=ubicloud -v ph_role=ubicloud_password \
    -v src_ph_tables="$ph_tables" -v src_ph_funcs="$ph_funcs" -f "$CURRENT/scripts/byoh/migrate-role-map.sql" >"$WORK/map.log" 2>&1 || {
    cat "$WORK/map.log" >&2
    die "migrate-role-map.sql failed on the copy"
  }
  report ok "copy-db: objects of $src_role now belong to ubicloud, of ${src_role}_password to ubicloud_password (${ph_tables//,/, })"

  # 9. The copy becomes ubicloud and gets the pending migrations.
  rename_db_try "${DB_NAME}_restore" "$DB_NAME" || die "cannot rename ${DB_NAME}_restore to $DB_NAME"
  migrate_as_service copy || die "the pending migrations failed on the copy (above); run copy-db again once fixed, or rollback"
  report ok "copy-db: migrations ran as ubicloud-migrate ($(grep -c 'Finished applying migration' "$WORK/migrate-copy.log" || true) applied to the $dev_n of $dev)"

  # 10. Validation.
  local bad=0
  runuser -u postgres -- psql -X -q -d "$DB_NAME" -f "$CURRENT/scripts/byoh/migrate-compare.sql" >"$WORK/cmp.copy"
  runuser -u postgres -- psql -X -q -d "${DB_NAME}_ref" -f "$CURRENT/scripts/byoh/migrate-compare.sql" >"$WORK/cmp.ref"
  # Lines of objects both have that differ, objects only the copy has
  # (the partitions respirate made) unless they are ubicloud's without
  # grants, and every object only the reference has: no migration and no
  # respirate drops an object a fresh migrate makes, so one the copy
  # lacks was lost by the restore or the role map.
  awk -F'\t' '
    NR == FNR { ref[$1] = $2; order[++n] = $1; next }
    ($1 in ref) { if (ref[$1] != $2) print "differs: " $1 ": copy " $2 " / reference " ref[$1]; seen[$1] = 1; next }
    $1 !~ /^rel\|/ || $2 != "owner=ubicloud acl=" { print "only in the copy: " $1 ": " $2 }
    END { for (i = 1; i <= n; i++) if (!(order[i] in seen)) print "only in the reference: " order[i] ": " ref[order[i]] }
  ' "$WORK/cmp.ref" "$WORK/cmp.copy" >"$WORK/cmp.diff"
  if [[ -s $WORK/cmp.diff ]]; then
    sed 's/^/  /' "$WORK/cmp.diff" | head -30 >&2
    report fail "copy-db: owners or privileges of the copy differ from the reference (above)"
    bad=1
  else
    report ok "copy-db: owners, privileges and SECURITY DEFINER settings equal the reference ($(wc -l <"$WORK/cmp.ref") objects; $(awk -F'\t' 'NR == FNR { r[$1]; next } !($1 in r)' "$WORK/cmp.ref" "$WORK/cmp.copy" | wc -l) only in the copy, all ubicloud's)"
  fi
  local owners
  owners=$(awk -F'\t' '{ if (match($2, /owner=[^ ]+/)) print substr($2, RSTART + 6, RLENGTH - 6) }' "$WORK/cmp.copy" | sort | uniq -c | awk '{ printf "%s %s, ", $2, $1 }')
  report notice "copy-db: objects per owner in the copy: ${owners%, } ($src_role and ${src_role}_password in $dev)"
  source_migrations "$DB_NAME"
  local missing=()
  for f in "${!REL_MIG[@]}"; do grep -qxF "$f" < <(printf '%s\n' "${SRC_MIG[@]}") || missing+=("$f"); done
  for f in "${!REL_PH[@]}"; do grep -qxF "$f" < <(printf '%s\n' "${SRC_PH[@]}") || missing+=("ph/$f"); done
  if ((${#missing[@]})) || [[ ${#SRC_MIG[@]} != "${#REL_MIG[@]}" || ${#SRC_PH[@]} != "${#REL_PH[@]}" ]]; then
    report fail "copy-db: schema_migrations of the copy is not the release's (${#SRC_MIG[@]}/${#SRC_PH[@]} rows, ${#REL_MIG[@]}/${#REL_PH[@]} files${missing:+; missing ${missing[*]:0:3}})"
    bad=1
  else
    report ok "copy-db: schema_migrations ${#SRC_MIG[@]}/${#SRC_PH[@]}: the source's plus the pending ones"
  fi
  local out rc=0
  out=$(as_service ubicloud "$TOOLS/bin/ruby" bin/byoh-config-check 2>&1) || rc=$?
  if grep -qE '^ok +database role ubicloud: not a superuser' <<<"$out"; then
    report ok "copy-db: password hashes isolated (bin/byoh-config-check as ubicloud: not a superuser, not in ubicloud_password, no SELECT on the hash tables, PUBLIC cannot execute the hash functions)"
  else
    grep -E '^fail' <<<"$out" | sed 's/^/  /' >&2 || true
    report fail "copy-db: bin/byoh-config-check does not report the password-hash isolation of role ubicloud as ok (exit $rc)"
    bad=1
  fi
  ((bad == 0)) || die "the copy failed its checks (above); database $DB_NAME stays marked as unfinished, so copy-db can run again once fixed. Or rollback."
  runuser -u postgres -- dropdb "${DB_NAME}_ref"
  psql_value -d postgres -c "COMMENT ON DATABASE $DB_NAME IS 'migrated-from $dev $ts'" >/dev/null
  COPY_ARMED=0
  S[CUTOVER_TS]=$ts S[STARTED_TS]="" S[ROLLED_BACK]="" S[DEV_ROLE]=$src_role
  write_state
  report changed "copy-db: database $DB_NAME is the copy of $dev at $ts"
  echo
  echo "copy-db: done. Next: migrate-from-dev.sh start"
}

# --- start --------------------------------------------------------------------------

web_port() {
  kv_read "$ENV_FILE"
  printf '%s' "${KV[PORT]:-3000}"
}

wait_web() {
  local i port
  port=$(web_port)
  for ((i = 0; i < $1; i++)); do
    [[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$port/login" 2>/dev/null || true) == 200 ]] && return 0
    sleep 1
  done
  return 1
}

# Nothing may listen on the web port but a loopback address.
check_listen() {
  local port addrs a bad=""
  port=$(web_port)
  addrs=$(ss -Htln "sport = :$port" | awk '{ print $4 }')
  for a in $addrs; do
    [[ $a == "127.0.0.1:$port" || $a == "[::1]:$port" ]] || bad+="$a "
  done
  [[ -z $bad ]] || return 1
  report ok "start: port $port listens on ${addrs//$'\n'/ } only"
}

# require_live_copy: database ubicloud is a finished copy that no
# rollback gave up, and the development database still accepts no
# connections. After a rollback the development control plane may have
# run on, so the copy is stale: starting respirate on it would act on
# the hosts from an old snapshot.
require_live_copy() {
  local c dev=${ARG[dev-db]}
  c=$(db_comment "$DB_NAME")
  case $c in
    "migrated-from "*) ;;
    "rolled-back-from "*) die "database $DB_NAME was rolled back ($c) and $dev may have changed since; stop the development control plane and run copy-db --i-understand-this-drops-live-data first" 2 ;;
    *) die "database $DB_NAME is not a finished copy; run copy-db first" 2 ;;
  esac
  [[ $c == "migrated-from $dev "* ]] || die "database $DB_NAME is a copy of another database ($c), not of $dev" 2
  [[ -z ${S[ROLLED_BACK]:-} ]] || die "rollback ran at ${S[ROLLED_BACK]} after the copy; run copy-db --i-understand-this-drops-live-data first" 2
  if db_exists "$dev" && db_allows_connections "$dev"; then
    die "$dev accepts connections, so the development control plane may have run on it since the copy; stop it and run copy-db --i-understand-this-drops-live-data first" 2
  fi
}

console_code() { "$ADMIN_BIN" console -e - 2>/dev/null 8>&- 9>&-; }

# admin ARGS...: ubicloud-admin without this script's locks.
admin() { "$ADMIN_BIN" "$@" 8>&- 9>&-; }

phase_start() {
  load_state
  exec 8>>"$MIG_LOCK"
  flock -n 8 || die "another migrate-from-dev.sh run holds $MIG_LOCK"
  require_live_copy
  local procs
  procs=$(dev_processes)
  [[ -z $procs ]] || die "the development control plane runs again; stop it first:
$procs" 2
  local port
  port=$(web_port)
  [[ $(unit_state ubicloud-web) == active || -z $(ss -Htln "sport = :$port") ]] ||
    die "something listens on port $port (ss -tlnp 'sport = :$port'); stop it first" 2
  systemctl enable -q ubicloud.target
  systemctl start ubicloud.target
  report changed "start: ubicloud.target enabled and started"
  wait_web 180 || die "web does not answer on 127.0.0.1:$port after 180 s (ubicloud-admin logs web)"
  report ok "start: web answers"
  check_listen || die "something listens on a non-loopback address of port $port: $(ss -Htln "sport = :$port" | awk '{ print $4 }' | tr '\n' ' ')"
  local out rc=0
  out=$(console_code <<'EOF'
n = 0
bad = 0
Sshable.all.each do |s|
  n += 1
  s.cmd("true")
  puts "ok      start: Sshable #{s.ubid} (#{s.host}) runs a command"
rescue => e
  bad += 1
  puts "fail    start: Sshable #{s.ubid} (#{s.host}): #{e.class}: #{e.message.lines.first.to_s.strip[0, 160]}"
end
puts "ok      start: no Sshable" if n == 0
raise "#{bad} Sshable(s) failed" if bad > 0
EOF
  ) || rc=$?
  printf '%s\n' "$out" | grep -E '^(ok|fail) ' || true
  ((rc == 0)) || die "a Sshable cannot run a command (above); start the data plane hosts or check the column key in $ENV_FILE"
  if [[ ${S[RHIZOME]:-1} == 1 ]]; then
    out=$(console_code <<'EOF'
VmHost.all.each do |h|
  h.install_rhizome
  puts "changed start: install_rhizome started for #{h.ubid}"
end
EOF
    ) || die "install_rhizome failed"
    printf '%s\n' "$out" | grep -E '^changed ' || report ok "start: no host for install_rhizome"
  fi
  S[STARTED_TS]=$(date -u +%Y%m%dT%H%M%SZ)
  write_state
  echo
  admin smoke || die "ubicloud-admin smoke fails (above)"
  echo
  out=$(admin status 2>&1) || true
  printf '%s\n' "$out"
  local fails
  fails=$(grep -E '^fail ' <<<"$out" | grep -v 'use trust for database ubicloud or all' || true)
  [[ -z $fails ]] || die "status has fails besides the bootstrap's trust rules (above)"
  echo
  echo "start: done. The trust fail above is expected until retire. Operators now use sudo ubicloud-admin."
}

# --- flip-production ------------------------------------------------------------------

phase_flip() {
  load_state
  exec 8>>"$MIG_LOCK"
  flock -n 8 || die "another migrate-from-dev.sh run holds $MIG_LOCK"
  [[ $(unit_state ubicloud.target) == active ]] || die "ubicloud.target is not active; run start first" 2
  local want=production
  ((BACK == 0)) || want=development
  if ((BACK == 0)); then
    admin backup now || die "ubicloud-admin backup now failed; nothing was changed"
    local out rc=0
    out=$(admin run byoh-config-check --simulate-production 2>&1) || rc=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    ((rc == 0)) || die "bin/byoh-config-check --simulate-production has fails (above); fix them, then run flip-production again. Nothing was changed" 2
    report ok "flip-production: the production checks have no fail"
  fi
  read_env_rb_for_url
  install_args "$want"
  bash "$SCRIPT_DIR/install.sh" "${INSTALL_ARGS[@]}" --update-env RACK_ENV 8>&- 9>&- ||
    die "install.sh --rack-env $want failed (above); see ubicloud-admin logs web respirate"
  S[RACK_ENV_NOW]=$want
  write_state
  echo
  admin status || true
  echo "flip-production: RACK_ENV is $want."
}

# The URL install.sh got: BASE_URL in the env file.
read_env_rb_for_url() {
  kv_read "$ENV_FILE"
  URL=${KV[BASE_URL]:-}
  MAIL_FROM=${KV[MAIL_FROM]:-${ARG[admin-email]}}
  [[ -n $URL ]] || die "$ENV_FILE has no BASE_URL"
}

# --- rollback --------------------------------------------------------------------------

r0_commands() {
  local repo=${ARG[dev-repo]} home=${S[DEV_HOME]} v path rack
  v=$(dev_ruby_version)
  path="$home/.local/bin:$home/.local/share/mise/installs/ruby/$v/bin"
  rack=development
  echo "--- R0 commands: run as ${ARG[dev-user]} (sudo -iu ${ARG[dev-user]}) ---"
  echo "tmux new-session -d -s puma \"cd $repo && export PATH=$path:\\\$PATH && RACK_ENV=$rack bundle exec puma -C puma_config.rb > /tmp/puma.log 2> /tmp/puma.err\""
  echo "tmux new-session -d -s respirate \"cd $repo && export PATH=$path:\\\$PATH && RACK_ENV=$rack bundle exec bin/respirate > /tmp/respirate.log 2> /tmp/respirate.err\""
  echo "--- end ---"
}

phase_rollback() {
  load_state
  take_locks
  make_work
  local dev=${ARG[dev-db]} port u
  systemctl disable -q --now ubicloud.target 2>/dev/null || true
  systemctl stop "${SERVICES[@]}" ubicloud-backup.timer 2>/dev/null || true
  [[ $(systemctl is-enabled ubicloud.target 2>/dev/null || true) != enabled ]] || die "ubicloud.target is still enabled"
  for u in ubicloud.target "${SERVICES[@]}"; do
    [[ $(unit_state "$u") != active ]] || die "$u is still active"
  done
  port=3000
  [[ ! -f $ENV_FILE ]] || port=$(web_port)
  local i
  for ((i = 0; i < 30; i++)); do
    [[ -z $(ss -Htln "sport = :$port") ]] && break
    sleep 1
  done
  [[ -z $(ss -Htln "sport = :$port") ]] || die "port $port is still in use (ss -tlnp 'sport = :$port')"
  report changed "rollback: ubicloud.target disabled and stopped; port $port is free"
  db_exists "$dev" || die "database $dev does not exist (retired?); there is nothing to roll back to"
  # The copy is stale from here on: start and retire refuse it, and
  # copy-db replaces it only with --i-understand-this-drops-live-data.
  local rb_ts
  rb_ts=$(date -u +%Y%m%dT%H%M%SZ)
  if [[ $(db_comment "$DB_NAME" 2>/dev/null) == "migrated-from "* ]]; then
    psql_value -d postgres -c "COMMENT ON DATABASE $DB_NAME IS 'rolled-back-from $dev $rb_ts'" >/dev/null
    report changed "rollback: database $DB_NAME is marked rolled back; start refuses it until copy-db --i-understand-this-drops-live-data makes a new copy"
  fi
  set_state ROLLED_BACK "$rb_ts"
  psql_value -d postgres -c "ALTER DATABASE \"$dev\" ALLOW_CONNECTIONS true" >/dev/null
  report changed "rollback: $dev accepts connections again"
  if [[ -n ${S[CUTOVER_TS]:-} ]] && db_exists "$DB_NAME"; then
    local cut
    cut=$(sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3 \4:\5:\6+00/' <<<"${S[CUTOVER_TS]}")
    echo
    echo "What the packaged control plane did after the copy at ${S[CUTOVER_TS]}:"
    runuser -u postgres -- psql -X -q -d "$DB_NAME" -v cutover="$cut" -f "$CURRENT/scripts/byoh/migrate-rollback-report.sql" || true
    psql_value -d "$DB_NAME" -c "SELECT id || ' ' || prog || ' ' || label FROM strand ORDER BY 1" >"$WORK/strand.new" || true
    psql_value -d "$dev" -c "SELECT id || ' ' || prog || ' ' || label FROM strand ORDER BY 1" >"$WORK/strand.old" || true
    echo "Strands that differ (> only in ubicloud: created or moved on after the copy; < only in $dev: finished since):"
    diff "$WORK/strand.old" "$WORK/strand.new" | grep '^[<>]' || echo "  (none)"
    [[ ${S[STARTED_TS]:-} == "" || ${S[RHIZOME]:-0} != 1 ]] ||
      echo "start ran install_rhizome on every host: the hosts run the release's rhizome; run vm_host.install_rhizome from ${ARG[dev-repo]} to go back"
    echo "Review host-side changes (reboots, rhizome installs, VMs above) before the development control plane runs on $dev again."
  fi
  if [[ -n ${S[BMC_FROM_PROC]:-} ]]; then
    echo
    warn "rollback: preflight took the BMC password variable(s) ${S[BMC_FROM_PROC]} from the running respirate's environment, not .env.rb; the R0 commands below start respirate without them, and its Redfish calls then go out with no password. Add them to ${ARG[dev-repo]}/.env.rb first (they are in $ENV_FILE)"
  fi
  echo
  r0_commands
  echo "rollback: done. The database ubicloud is kept; copy-db --i-understand-this-drops-live-data replaces it on the next move."
}

# --- retire ------------------------------------------------------------------------------

phase_retire() {
  load_state
  take_locks
  make_work
  local dev=${ARG[dev-db]}
  ((DRILL_DONE)) || usage_die "retire needs --restore-drill-done: run a restore drill first (docs/byoh/OPERATIONS.md)"
  [[ $(unit_state ubicloud.target) == active && $(systemctl is-enabled ubicloud.target 2>/dev/null || true) == enabled ]] ||
    die "ubicloud.target is not active and enabled; retire only a moved control plane" 2
  require_live_copy
  [[ -z $(dev_processes) ]] || die "the development control plane runs; stop it first" 2
  local target n=0 d
  target=$(backup_target)
  for d in "$target"/*/manifest.json; do
    [[ -f $d ]] || continue
    d=${d%/manifest.json}
    d=${d##*/}
    [[ $d > ${S[CUTOVER_TS]:-} ]] && n=$((n + 1))
  done
  if ((n < 14)); then
    ((SKIP_BACKUP_COUNT)) || die "$target holds $n backup(s) since the copy at ${S[CUTOVER_TS]:-?}; retire after 14 (--skip-backup-count overrides, for a rehearsal)" 2
    report warn "retire: $n backup(s) since the copy (--skip-backup-count)"
  else
    report ok "retire: $n backups since the copy"
  fi
  db_exists "$dev" || die "database $dev does not exist; already retired?" 2
  # The role whose tables preflight and copy-db saw, never the
  # database's owner, which a hand-made database may give to postgres.
  local role=${S[DEV_ROLE]:-}
  [[ -n $role ]] || die "$MIG_STATE names no DEV_ROLE (the role of the development database's tables); run preflight again" 2
  retirable_role "$role" || die "retire would demote role $role, which is no development bootstrap role (postgres, pg_* and ubicloud* are refused, and the role must exist); nothing was changed" 2
  local hba=$PG_CONF/pg_hba.conf saved
  saved=$hba.before-retire-$(date -u +%Y%m%dT%H%M%SZ)
  cp -p "$hba" "$saved"
  sed -E \
    -e 's/^(local[[:space:]]+all[[:space:]]+postgres[[:space:]]+)trust[[:space:]]*$/\1peer/' \
    -e 's/^(local[[:space:]]+all[[:space:]]+all[[:space:]]+)trust[[:space:]]*$/\1peer/' \
    -e 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1\/32[[:space:]]+)trust[[:space:]]*$/\1scram-sha-256/' \
    -e 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+::1\/128[[:space:]]+)trust[[:space:]]*$/\1scram-sha-256/' \
    "$saved" >"$WORK/hba"
  if ! cmp -s "$WORK/hba" "$hba"; then
    install -m "$(stat -c %a "$hba")" -o "$(stat -c %U "$hba")" -g "$(stat -c %G "$hba")" "$WORK/hba" "$hba"
    systemctl reload "postgresql@$PG_VERSION-main"
    sleep 1
    report changed "retire: the bootstrap's trust rules in $hba are peer and scram-sha-256 again (the old file is $saved)"
  else
    rm -f "$saved"
    report ok "retire: $hba has none of the bootstrap's trust rules"
  fi
  local left
  left=$(psql_value -d postgres -c "SELECT string_agg(line_number::text, ',' ORDER BY line_number) FROM pg_hba_file_rules WHERE auth_method = 'trust'")
  [[ -z $left ]] || warn "retire: $hba line(s) $left still use trust; the bootstrap did not write them, so remove them yourself"
  local retired
  retired=${dev}_retired_$(date -u +%Y%m%d)
  runuser -u postgres -- psql -X -q -d postgres -v dev_db="$dev" -v retired_db="$retired" -v dev_role="$role" \
    -f "$CURRENT/scripts/byoh/migrate-retire.sql" || die "migrate-retire.sql failed"
  report changed "retire: $dev is now $retired (kept; it no longer accepts connections); role $role can no longer log in and is no superuser"
  local markers=${S[DEV_HOME]}/.ubi-bootstrap
  if [[ -d $markers ]]; then
    mv -T "$markers" "$markers.retired-$(date -u +%Y%m%d)"
    report changed "retire: $markers is now $markers.retired-$(date -u +%Y%m%d), so install.sh no longer sees a development control plane"
  fi
  report notice "retire: ${ARG[dev-repo]}/.env.rb still holds the secrets of /etc/ubicloud/env; keep an encrypted copy off the machine, then delete it (shred -u)"
  echo
  local out
  out=$(admin status 2>&1) || true
  printf '%s\n' "$out"
  ! grep -q 'use trust for database ubicloud or all' <<<"$out" || die "status still reports a trust rule (above)"
  echo "retire: done."
}

# --- main -------------------------------------------------------------------------------

main() {
  parse_args "$@"
  [[ $EUID == 0 ]] || die "run migrate-from-dev.sh as root (sudo)"
  case $PHASE in
    preflight)
      exec 8>>"$MIG_LOCK"
      flock -n 8 || die "another migrate-from-dev.sh run holds $MIG_LOCK"
      phase_preflight
      ;;
    install)
      exec 8>>"$MIG_LOCK"
      flock -n 8 || die "another migrate-from-dev.sh run holds $MIG_LOCK"
      phase_install
      ;;
    copy-db) phase_copy_db ;;
    start) phase_start ;;
    flip-production) phase_flip ;;
    rollback) phase_rollback ;;
    retire) phase_retire ;;
  esac
}

main "$@"
