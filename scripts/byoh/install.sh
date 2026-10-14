#!/bin/bash
# Installs the BYOH control plane as a packaged service on Ubuntu 24.04:
# Ruby and Node under /opt/ubicloud/tools, a root-owned release under
# /opt/ubicloud/releases, PostgreSQL with peer authentication and
# non-superuser roles, /etc/ubicloud/env, migrations and the systemd
# units. Run it as root. It is safe to run again: every step checks the
# real state and prints ok, changed or skip. It keeps no marker files.
#
#   sudo bash install.sh --version v0.1.0 --url https://cloud.example.com \
#     --tls acme|provided|tunnel|none --admin-email ops@example.com \
#     --source-git ~/ubicloud --ref <commit> \
#     [--cert F --key F] [--cloudflared-token-file F] \
#     [--rack-env production|development] [--mail-from ADDR] \
#     [--smtp-file F|-] [--billing-rates-dir DIR] \
#     [--backup-target DIR] [--backup-recipient age1...|--backup-recipient-file F] \
#     [--update-env KEY]... [--skip-check clock|mem|listen]... \
#     [--stage tools|all] [--no-start]
#
# Source: --source-git DIR --ref REF (git archive runs as the owner of
# DIR), or --source-tarball F --source-rev REV.
#
# A setting in /etc/ubicloud/env or /etc/ubicloud/backup.conf that a
# flag sets (BASE_URL, MAIL_FROM, RACK_ENV, the SMTP keys, IP_FROM_HEADER,
# BACKUP_TARGET, BACKUP_RECIPIENTS, TLS_FRONT) is never changed silently: a run whose flags differ
# exits 2, unless --update-env KEY allows that key to change. Keys that
# are missing are added; the secrets are generated once and kept.
#
# TLS front (--tls), in front of puma on 127.0.0.1:
#   acme      Caddy from Ubuntu universe gets a certificate for the --url
#             host (it needs ports 80 and 443 and public DNS; UNVERIFIED).
#   provided  Caddy with --cert F --key F (PEM, unencrypted key).
#   tunnel    cloudflared. An existing cloudflared.service is left as it
#             is; otherwise --cloudflared-token-file F (mode 0600) installs
#             a pinned cloudflared and ubicloud-cloudflared.service.
#   none      no front: --url http://localhost:PORT, reached over ssh -L.
# The services take the client address from the header the front sets
# (IP_FROM_HEADER): X-Real-IP for Caddy, CF-Connecting-IP for cloudflared.
# Changing --tls on an installed control plane needs --update-env
# TLS_FRONT, IP_FROM_HEADER (unless it was unset) and BASE_URL (unless
# the URL stays); the exit-2 message names them. The new front comes up
# first, then the old one is stopped. With --no-start the old front is
# left running and front.conf unchanged.
#
# --stage tools stops after the packages and the tools, which only needs
# a source (for mise.toml). The default stage, all, also needs --version,
# --url, --tls and --admin-email.
#
# Exit status: 0 on success, 1 on a failure, 2 on a usage error or when
# the run would change something it must not change silently (another
# rev for an existing version, another version than the current one,
# other tools than the current release runs on, a setting that differs
# from the flags), or would start the units while another process holds
# the port or a development control plane lives on the machine.
#
# Docs: docs/byoh/INSTALL.md (flags, settings), docs/byoh/OPERATIONS.md.
set -euo pipefail
umask 077

readonly OPT=/opt/ubicloud
readonly TOOLS=$OPT/tools
readonly RELEASES=$OPT/releases
readonly CURRENT=$OPT/current
readonly STATE=/var/lib/ubicloud
readonly ETC=/etc/ubicloud
readonly ENV_FILE=$ETC/env
readonly BACKUP_CONF=$ETC/backup.conf
readonly BACKUP_RECIPIENTS=$ETC/backup-recipients
readonly FRONT_CONF=$ETC/front.conf
readonly TLS_DIR=$ETC/tls
readonly CF_TOKEN=$ETC/cloudflared.token
readonly CF_UNIT=ubicloud-cloudflared.service
readonly CADDYFILE=/etc/caddy/Caddyfile
readonly CADDYFILE_MARK="# Written by scripts/byoh/install.sh for --tls "
# A cloudflared release at least two weeks old (2026-09-24) that has
# tunnel run --token-file; the checksum is the one in its release notes.
readonly CLOUDFLARED_VERSION=2026.9.3
readonly CLOUDFLARED_SHA256=bc073ef293d504cf5ac533bd0aa1c824ef6b4f358765ccaa6628a8a95cacb4b7
readonly LOCK=/run/ubicloud-admin.lock
readonly PG_VERSION=16
readonly PG_CONF=/etc/postgresql/$PG_VERSION/main
readonly PG_UNIT=postgresql@$PG_VERSION-main
readonly SERVICE_PATH=$TOOLS/bin:/usr/bin:/bin
readonly UNIT_DIR=/etc/systemd/system
# A mise release at least two weeks old; the checksum is the one
# published with it for the linux-x64 binary.
readonly MISE_VERSION=v2026.9.18
readonly MISE_SHA256=d24fe0bf7e613824ad99f7b8dac3f2b381a37b9f75f84dd250855217095a8de4
# postgresql-16 provides postgresql-contrib-16 (citext, btree_gist) on
# noble; the virtual name never shows as installed in dpkg-query.
readonly PACKAGES=(
  postgresql-16 age
  build-essential libssl-dev libyaml-dev zlib1g-dev libffi-dev libpq-dev
  git curl jq iproute2 openssl
)
readonly BUNDLE_WITHOUT='test:rubocop:aws_kms:gcp_kms:aws_rds_iam:gcp_cloudsql_iam'
# MemTotal of a machine sold as 4 GiB is a little lower, because the
# kernel keeps some memory for itself.
readonly MIN_MEM_KB=$((3584 * 1024))

# Keys the env file must never set: the services and this script build
# PATH and HOME themselves, and the others change how a shell or the
# dynamic loader behaves.
readonly KEY_RE='^[A-Z][A-Z0-9_]{0,63}$'
readonly DENIED_KEY_RE='^(PATH|IFS|BASH_ENV|ENV|HOME|SHELL|LD_[A-Z0-9_]*)$'

# --- output ---------------------------------------------------------------

report() { printf '%-7s %s\n' "$1" "$2"; }
die() {
  printf 'install.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}
usage_die() { die "$1" 2; }

# --- arguments -------------------------------------------------------------

STAGE=all
VERSION="" URL="" URL_PORT="" URL_HOST="" TLS="" ADMIN_EMAIL="" MAIL_FROM_ARG="" RACK_ENV_ARG=""
SRC_TARBALL="" SRC_REV="" SRC_GIT="" SRC_REF=""
CERT_FILE="" KEY_FILE="" CF_TOKEN_FILE=""
SMTP_FILE="" BILLING_DIR="" BACKUP_TARGET="" BACKUP_RECIPIENT="" BACKUP_RECIPIENT_FILE=""
NO_START=0
EFFECTIVE_PORT=3000
declare -A SKIP_CHECK=() UPDATE_ENV=()

need_arg() { [[ $# -ge 2 && -n $2 ]] || usage_die "$1 needs a value"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --version) need_arg "$@"; VERSION=$2; shift ;;
      --url) need_arg "$@"; URL=$2; shift ;;
      --tls) need_arg "$@"; TLS=$2; shift ;;
      --admin-email) need_arg "$@"; ADMIN_EMAIL=$2; shift ;;
      --mail-from) need_arg "$@"; MAIL_FROM_ARG=$2; shift ;;
      --rack-env) need_arg "$@"; RACK_ENV_ARG=$2; shift ;;
      --source-tarball) need_arg "$@"; SRC_TARBALL=$2; shift ;;
      --source-rev) need_arg "$@"; SRC_REV=$2; shift ;;
      --source-git) need_arg "$@"; SRC_GIT=$2; shift ;;
      --ref) need_arg "$@"; SRC_REF=$2; shift ;;
      --smtp-file) need_arg "$@"; SMTP_FILE=$2; shift ;;
      --cert) need_arg "$@"; CERT_FILE=$2; shift ;;
      --key) need_arg "$@"; KEY_FILE=$2; shift ;;
      --cloudflared-token-file) need_arg "$@"; CF_TOKEN_FILE=$2; shift ;;
      --billing-rates-dir) need_arg "$@"; BILLING_DIR=$2; shift ;;
      --backup-target) need_arg "$@"; BACKUP_TARGET=$2; shift ;;
      --backup-recipient) need_arg "$@"; BACKUP_RECIPIENT=$2; shift ;;
      --backup-recipient-file) need_arg "$@"; BACKUP_RECIPIENT_FILE=$2; shift ;;
      --update-env) need_arg "$@"; UPDATE_ENV[$2]=1; shift ;;
      --skip-check) need_arg "$@"; SKIP_CHECK[$2]=1; shift ;;
      --stage) need_arg "$@"; STAGE=$2; shift ;;
      --no-start) NO_START=1 ;;
      --mgmt-endpoint) usage_die "--mgmt-endpoint is available in M8" ;;
      --import-env-rb) usage_die "--import-env-rb is available with scripts/byoh/migrate-from-dev.sh" ;;
      --smtp) usage_die "--smtp would put a password on the command line; use --smtp-file F (mode 0600) or --smtp-file -" ;;
      -h | --help)
        sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
        exit 0
        ;;
      *) usage_die "unknown argument $1 (see --help)" ;;
    esac
    shift
  done
}

validate_args() {
  local k
  case $STAGE in tools | all) ;; *) usage_die "--stage must be tools or all" ;; esac
  for k in "${!SKIP_CHECK[@]}"; do
    case $k in clock | mem | listen) ;; *) usage_die "--skip-check takes clock, mem or listen" ;; esac
  done
  for k in "${!UPDATE_ENV[@]}"; do
    [[ $k =~ $KEY_RE ]] || usage_die "--update-env takes a key name, such as MAIL_FROM"
  done

  if [[ -n $SRC_TARBALL ]]; then
    [[ -z $SRC_GIT && -z $SRC_REF ]] || usage_die "give --source-tarball or --source-git, not both"
    [[ -f $SRC_TARBALL ]] || usage_die "--source-tarball $SRC_TARBALL is not a file"
    [[ $SRC_REV =~ ^[0-9a-f]{7,64}$ ]] || usage_die "--source-tarball needs --source-rev, a git commit or tree id"
    SRC_TARBALL=$(absolute "$SRC_TARBALL")
  elif [[ -n $SRC_GIT ]]; then
    [[ -z $SRC_REV ]] || usage_die "--source-rev goes with --source-tarball; use --ref with --source-git"
    [[ -d $SRC_GIT ]] || usage_die "--source-git $SRC_GIT is not a directory"
    [[ -n $SRC_REF ]] || usage_die "--source-git needs --ref"
    SRC_GIT=$(absolute "$SRC_GIT")
  else
    usage_die "give a source: --source-git DIR --ref REF, or --source-tarball F --source-rev REV"
  fi

  [[ $STAGE == tools ]] && return 0

  [[ $VERSION =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ && $VERSION != *.tmp ]] ||
    usage_die "--version must be letters, digits, '.', '_', '+' or '-' (such as v0.1.0)"
  case $TLS in
    none)
      # The port is required: BASE_URL must name the port puma listens
      # on, which check_settings compares with PORT.
      [[ $URL =~ ^http://localhost:([1-9][0-9]{0,4})/?$ ]] ||
        usage_die "--tls none serves plain http on 127.0.0.1 only, so --url must be http://localhost:PORT (such as http://localhost:3000)"
      URL_PORT=${BASH_REMATCH[1]}
      ;;
    acme | provided | tunnel)
      # The front serves the URL's host on 443; puma's port stays local.
      [[ $URL =~ ^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)/?$ ]] ||
        usage_die "--tls $TLS needs --url https://HOST, a DNS name with no port or path (such as https://cloud.example.com)"
      URL_HOST=${BASH_REMATCH[1],,}
      ;;
    "") usage_die "--tls is required (acme, provided, tunnel or none)" ;;
    *) usage_die "--tls must be acme, tunnel, provided or none" ;;
  esac
  if [[ $TLS == provided ]]; then
    [[ -n $CERT_FILE && -n $KEY_FILE ]] || usage_die "--tls provided needs --cert F and --key F"
    [[ -f $CERT_FILE ]] || usage_die "--cert $CERT_FILE is not a file"
    [[ -f $KEY_FILE ]] || usage_die "--key $KEY_FILE is not a file"
    CERT_FILE=$(absolute "$CERT_FILE")
    KEY_FILE=$(absolute "$KEY_FILE")
  else
    [[ -z $CERT_FILE && -z $KEY_FILE ]] || usage_die "--cert and --key go with --tls provided"
  fi
  if [[ -n $CF_TOKEN_FILE ]]; then
    [[ $TLS == tunnel ]] || usage_die "--cloudflared-token-file goes with --tls tunnel"
    [[ -f $CF_TOKEN_FILE ]] || usage_die "--cloudflared-token-file $CF_TOKEN_FILE is not a file"
    (($(stat -L -c '%#a' "$CF_TOKEN_FILE") & 077)) &&
      usage_die "--cloudflared-token-file $CF_TOKEN_FILE is readable by group or other; chmod 600 it"
    CF_TOKEN_FILE=$(absolute "$CF_TOKEN_FILE")
  fi
  URL=${URL%/}
  valid_email "$ADMIN_EMAIL" || usage_die "--admin-email must be an email address"
  # acme puts it in the Caddyfile as the ACME account address.
  [[ $TLS != acme || $ADMIN_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    usage_die "--tls acme registers --admin-email with the CA; use an address of letters, digits and ._%+-"
  MAIL_FROM_ARG=${MAIL_FROM_ARG:-$ADMIN_EMAIL}
  valid_email "$MAIL_FROM_ARG" || usage_die "--mail-from must be an email address"
  case ${RACK_ENV_ARG:-production} in production | development) ;; *) usage_die "--rack-env must be production or development" ;; esac

  if [[ -n $SMTP_FILE && $SMTP_FILE != - ]]; then
    [[ -f $SMTP_FILE ]] || usage_die "--smtp-file $SMTP_FILE is not a file"
    (($(stat -L -c '%#a' "$SMTP_FILE") & 077)) &&
      usage_die "--smtp-file $SMTP_FILE is readable by group or other; chmod 600 it"
    SMTP_FILE=$(absolute "$SMTP_FILE")
  fi
  [[ -z $BILLING_DIR || -d $BILLING_DIR ]] || usage_die "--billing-rates-dir $BILLING_DIR is not a directory"
  [[ -z $BILLING_DIR ]] || BILLING_DIR=$(absolute "$BILLING_DIR")

  case $BACKUP_TARGET in
    s3://*) usage_die "s3:// backup targets come with E5; give a directory" ;;
    "" | /*) ;;
    *) usage_die "--backup-target must be an absolute directory" ;;
  esac
  [[ $BACKUP_TARGET != *"'"* && $BACKUP_TARGET != *\\* ]] || usage_die "--backup-target must not contain a quote or backslash"
  BACKUP_TARGET=${BACKUP_TARGET%/}
  [[ -z $BACKUP_RECIPIENT || -z $BACKUP_RECIPIENT_FILE ]] ||
    usage_die "give --backup-recipient or --backup-recipient-file, not both"
  [[ -z $BACKUP_RECIPIENT || $BACKUP_RECIPIENT =~ ^age1[02-9ac-hj-np-z]{58}$ ]] ||
    usage_die "--backup-recipient must be an age public key (age1...)"
  [[ -z $BACKUP_RECIPIENT_FILE || -f $BACKUP_RECIPIENT_FILE ]] ||
    usage_die "--backup-recipient-file $BACKUP_RECIPIENT_FILE is not a file"
  [[ -z $BACKUP_RECIPIENT_FILE ]] || BACKUP_RECIPIENT_FILE=$(absolute "$BACKUP_RECIPIENT_FILE")
}

# absolute PATH: PATH made absolute, so that it means the same after a
# later cd (fetch_source runs git from /).
absolute() { realpath -e -- "$1" 2>/dev/null || usage_die "cannot resolve $1"; }

valid_email() { [[ $1 =~ ^[^@[:space:]\'\\]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# --- the KEY='value' file format (M3-b) -------------------------------------
#
# systemd's EnvironmentFile= and bash read these lines alike as long as
# each line ends at the closing quote (scripts/byoh/test, envfmt). Values
# must not contain a quote, a backslash, a newline, a CR or a NUL.

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

# as_service USER CMD...: runs CMD in the current release as USER with
# exactly the env file, the release env, PATH and HOME, umask 0007.
# The values travel in the environment, never in argv: /proc/PID/cmdline
# is readable by every local user, /proc/PID/environ only by its owner.
# export is a builtin, and setpriv execs CMD without a PAM session, so no
# process ever carries a value on its command line.
as_service() {
  local user=$1 group
  shift
  group=$(id -gn "$user")
  # The caller tests the status, so set -e is off in here: every step
  # that can fail exits by itself.
  (
    cd "$CURRENT" || exit 1
    local k f
    while IFS= read -r k; do unset "$k" 2>/dev/null || exit 1; done < <(compgen -e)
    for f in "$ENV_FILE" "$CURRENT/.release-env"; do
      kv_read "$f"
      for k in "${KV_KEYS[@]}"; do
        export "$k=${KV[$k]}" 2>/dev/null || die "$f sets $k, which bash cannot export"
      done
    done
    export PATH=$SERVICE_PATH HOME=$STATE
    umask 0007
    exec setpriv --reuid="$user" --regid="$group" --init-groups -- "$@"
  )
}

# --- step 1: checks -----------------------------------------------------------

step_checks() {
  local id version
  # shellcheck disable=SC1091
  id=$(. /etc/os-release && echo "${ID:-}")
  # shellcheck disable=SC1091
  version=$(. /etc/os-release && echo "${VERSION_ID:-}")
  [[ $id == ubuntu && $version == 24.04 ]] || die "install.sh needs Ubuntu 24.04 (found ${id:-?} ${version:-?})"
  local mem
  mem=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
  if ((mem < MIN_MEM_KB)); then
    [[ -n ${SKIP_CHECK[mem]:-} ]] || die "the control plane needs about 4 GiB of memory (MemTotal ${mem} kB); --skip-check mem overrides"
    report skip "checks: memory (${mem} kB, --skip-check mem)"
  fi
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) != yes ]]; then
    [[ -n ${SKIP_CHECK[clock]:-} ]] ||
      die "the clock is not NTP-synchronized (timedatectl); TLS, tokens and backups depend on it. --skip-check clock overrides"
    report skip "checks: clock not NTP-synchronized (--skip-check clock)"
  fi
  report ok "checks: Ubuntu 24.04, root, ${mem} kB memory"
}

# --- source ---------------------------------------------------------------------

WORK=""
SRC_DIR=""
SMTP_DIR=""

fetch_source() {
  WORK=$(mktemp -d /tmp/ubicloud-install.XXXXXX)
  trap 'rm -rf "$WORK" ${BUILD_HOME:+"$BUILD_HOME"} ${SMTP_DIR:+"$SMTP_DIR"}' EXIT
  if [[ -n $SRC_GIT ]]; then
    # git refuses repositories owned by another user, so it runs as the
    # repository's owner. root only writes the archive it prints.
    local owner
    owner=$(stat -c %U "$SRC_GIT")
    cd /
    SRC_REV=$(runuser -u "$owner" -- git -C "$SRC_GIT" rev-parse --verify --quiet "$SRC_REF^{commit}") ||
      usage_die "--ref $SRC_REF is not a commit in $SRC_GIT"
    runuser -u "$owner" -- git -C "$SRC_GIT" archive --format=tar.gz "$SRC_REV" >"$WORK/src.tgz" ||
      die "git archive of $SRC_REV failed"
  else
    cp "$SRC_TARBALL" "$WORK/src.tgz"
  fi
  SRC_DIR=$WORK/src
  mkdir "$SRC_DIR"
  tar -xzf "$WORK/src.tgz" -C "$SRC_DIR" --no-same-owner || die "cannot extract the source"
  [[ -f $SRC_DIR/mise.toml && -f $SRC_DIR/bin/rake-task-runner && -d $SRC_DIR/packaging/systemd ]] ||
    die "the source has no mise.toml, bin/rake-task-runner or packaging/systemd at its top level"
  # config.rb loads .env.rb before the environment, so a release must
  # never carry one.
  [[ ! -e $SRC_DIR/.env.rb ]] || die "the source contains .env.rb; build the source with git archive"
  RUBY_V=$(sed -n 's/^ruby = "\(.*\)"$/\1/p' "$SRC_DIR/mise.toml")
  NODE_V=$(sed -n 's/^node = "\(.*\)"$/\1/p' "$SRC_DIR/mise.toml")
  [[ $RUBY_V =~ ^[0-9.]+$ && $NODE_V =~ ^[0-9.]+$ ]] || die "cannot read the ruby and node versions from mise.toml"
  report ok "source: rev $SRC_REV (ruby $RUBY_V, node $NODE_V)"
}

# --- step 2: packages -------------------------------------------------------------

step_packages() {
  local missing=() p
  for p in "${PACKAGES[@]}"; do
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true) == installed ]] || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    report ok "packages: all installed"
    return
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  report changed "packages: installed ${missing[*]}"
}

# --- step 3: tools (M3-o) ------------------------------------------------------------

tools_current() {
  [[ $("$TOOLS/bin/ruby" -e 'print RUBY_VERSION' 2>/dev/null) == "$RUBY_V" &&
    $("$TOOLS/bin/node" -v 2>/dev/null) == "v$NODE_V" ]] &&
    PATH=$SERVICE_PATH "$TOOLS/bin/npm" -v >/dev/null 2>&1 &&
    "$TOOLS/bin/bundle" -v >/dev/null 2>&1
}

# check_tools: exits 2 before anything changes when this source wants
# other tools than the current release runs on. Every release runs on
# /opt/ubicloud/tools/bin, and bin/restarter starts a new respirate
# through it every hour, so rebuilding the tools changes the interpreter
# under the running services: that belongs to a release switch.
check_tools() {
  [[ -f $CURRENT/mise.toml ]] || return 0
  local ruby node
  ruby=$(sed -n 's/^ruby = "\(.*\)"$/\1/p' "$CURRENT/mise.toml")
  node=$(sed -n 's/^node = "\(.*\)"$/\1/p' "$CURRENT/mise.toml")
  [[ $ruby == "$RUBY_V" && $node == "$NODE_V" ]] ||
    usage_die "the current release runs ruby $ruby and node $node, and this source wants ruby $RUBY_V and node $NODE_V; the tools are shared, so changing them is a release switch, see docs/byoh/OPERATIONS.md (release switch)"
}

step_tools() {
  if tools_current; then
    report ok "tools: ruby $RUBY_V, node $NODE_V"
    return
  fi
  install -d -m 0755 "$OPT" "$TOOLS" "$TOOLS/bin" "$TOOLS/mise" "$TOOLS/mise/bin"
  if ! echo "$MISE_SHA256  $TOOLS/mise/bin/mise" | sha256sum -c --quiet >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$WORK/mise" \
      "https://github.com/jdx/mise/releases/download/$MISE_VERSION/mise-$MISE_VERSION-linux-x64"
    echo "$MISE_SHA256  $WORK/mise" | sha256sum -c --quiet || die "mise $MISE_VERSION does not match its pinned sha256"
    install -m 0755 "$WORK/mise" "$TOOLS/mise/bin/mise"
  fi
  (
    # The service users read and run the tools.
    umask 022
    cd /
    export MISE_DATA_DIR=$TOOLS/mise MISE_CACHE_DIR=$WORK/mise-cache
    export MISE_CONFIG_DIR=/nonexistent MISE_RUBY_COMPILE=true MISE_YES=1
    "$TOOLS/mise/bin/mise" install "ruby@$RUBY_V" "node@$NODE_V"
  ) >"$WORK/tools.log" 2>&1 || {
    tail -30 "$WORK/tools.log" >&2
    die "building ruby $RUBY_V and node $NODE_V failed"
  }
  # mise's rubygems plugin runs `mise reshim` after every gem install,
  # and there is no mise on the service PATH: bundle install would fail
  # with "No such file or directory - mise".
  rm -f "$TOOLS/mise/installs/ruby/$RUBY_V/lib/ruby/site_ruby/rubygems_plugin.rb"
  local t nd=$TOOLS/mise/installs/node/$NODE_V
  for t in ruby bundle gem erb; do
    ln -sfn "../mise/installs/ruby/$RUBY_V/bin/$t" "$TOOLS/bin/$t"
  done
  # mise's npm is a reshim wrapper that finds npm relative to the path it
  # runs as, so npm and npx link to npm's own entry points.
  ln -sfn "$nd/bin/node" "$TOOLS/bin/node"
  ln -sfn "$nd/lib/node_modules/npm/bin/npm-cli.js" "$TOOLS/bin/npm"
  ln -sfn "$nd/lib/node_modules/npm/bin/npx-cli.js" "$TOOLS/bin/npx"
  chmod -R a+rX,go-w "$TOOLS"
  tools_current || die "the tools do not run after the build"
  report changed "tools: ruby $RUBY_V, node $NODE_V (mise $MISE_VERSION)"
}

# --- settings: /etc/ubicloud/env (M3-b) and backup.conf ---------------------------
#
# Each wanted key has a kind:
#   secret  generated once; never compared or replaced
#   default appended when missing; an existing value is the operator's
#   flag    derived from the flags; a different existing value exits 2
#           unless --update-env KEY
# A flag key whose wanted value is empty must be absent.

declare -A WANT=() KIND=()
WANT_KEYS=()

want() {
  valid_value "$3" || usage_die "the value for $1 contains a quote, backslash, newline or CR"
  [[ -z ${KIND[$1]+x} ]] && WANT_KEYS+=("$1")
  KIND[$1]=$2
  WANT[$1]=$3
}

plan_env() {
  WANT=() KIND=() WANT_KEYS=()
  want RACK_ENV "$([[ -n $RACK_ENV_ARG ]] && echo flag || echo default)" "${RACK_ENV_ARG:-production}"
  want CLOVER_DATABASE_URL default "postgres:///ubicloud?user=ubicloud"
  want CLOVER_SESSION_SECRET secret ""
  want CLOVER_COLUMN_ENCRYPTION_KEY secret ""
  want CLOVER_RUNTIME_TOKEN_SECRET secret ""
  want BASE_URL flag "$URL"
  want ADMIN_URL default "http://admin.localhost:3000"
  want BIND default 127.0.0.1
  want PORT default 3000
  want DB_POOL_WEB default 16
  want MAIL_FROM flag "$MAIL_FROM_ARG"
  if [[ -n $SMTP_FILE ]]; then
    want MAIL_DRIVER flag smtp
    local line re="^([A-Z_]+)='([^']*)'$" k
    while IFS= read -r line; do
      [[ $line =~ $re ]] || die "bin/byoh-smtp-url printed an unexpected line"
      want "${BASH_REMATCH[1]}" flag "${BASH_REMATCH[2]}"
    done <<<"$SMTP_LINES"
    # A URL without credentials must not leave the old ones in place:
    # wanted empty, they conflict, or go with --update-env.
    for k in SMTP_USER SMTP_PASSWORD; do
      [[ -n ${KIND[$k]+x} ]] || want "$k" flag ""
    done
  else
    want MAIL_DRIVER default logger
  fi
  want BOOT_IMAGE_SOURCE default public
  want DELETED_RECORD_DROP_UNARCHIVED default true
  want ALLOW_UNSPREAD_SERVERS default true
  # M3-m: the header the TLS front sets, which a client cannot choose:
  # Caddy sets X-Real-IP from the connection, and Cloudflare sets
  # CF-Connecting-IP at its edge. none means no proxy.
  case $TLS in
    acme | provided) want IP_FROM_HEADER flag X-Real-IP ;;
    tunnel) want IP_FROM_HEADER flag CF-Connecting-IP ;;
    *) want IP_FROM_HEADER flag "" ;;
  esac
  want BILLING_RATES_EXTRA_DIR default "$STATE/billing_rates.d"
}

# diff_settings FILE: compares FILE (loaded into KV) with WANT. Sets
# ADD (missing keys), REPLACE and REMOVE (flag keys with --update-env)
# and CONFLICTS (flag keys without it).
diff_settings() {
  local k
  ADD=() REPLACE=() REMOVE=() CONFLICTS=()
  kv_read "$1"
  for k in "${WANT_KEYS[@]}"; do
    if [[ -z ${KV[$k]+x} ]]; then
      [[ ${KIND[$k]} == flag && -z ${WANT[$k]} ]] || ADD+=("$k")
    elif [[ ${KIND[$k]} == flag && ${KV[$k]} != "${WANT[$k]}" ]]; then
      if [[ -n ${UPDATE_ENV[$k]:-} ]]; then
        if [[ -z ${WANT[$k]} ]]; then REMOVE+=("$k"); else REPLACE+=("$k"); fi
      else
        CONFLICTS+=("$k")
      fi
    fi
  done
}

# check_settings: exits 2, before anything changes, when the env file or
# backup.conf has a setting that the flags would change.
check_settings() {
  local conflicts=() k
  if [[ -e $ENV_FILE ]]; then
    plan_env
    diff_settings "$ENV_FILE"
    conflicts+=("${CONFLICTS[@]}")
    # M3-q: the console sets this for one session; the services never may.
    [[ -z ${KV[PRY_ALLOW_UNAUDITED]+x} ]] ||
      usage_die "$ENV_FILE sets PRY_ALLOW_UNAUDITED, which lets bin/pry run unaudited in every service; remove the line (ubicloud-admin console sets it for its own session)"
    [[ -n ${KV[CLOVER_COLUMN_ENCRYPTION_KEY]+x} ]] ||
      die "$ENV_FILE has no CLOVER_COLUMN_ENCRYPTION_KEY; a new key would make every encrypted column unreadable, so restore it from the secrets backup"
    for k in "${KV_KEYS[@]}"; do
      [[ $k != GIT_REV ]] || report warn "env: $ENV_FILE sets GIT_REV; the release's .release-env overrides it"
    done
  fi
  # Without the env file, a run would generate a new column key, and an
  # existing database's encrypted columns could never be read again.
  if [[ ! -e $ENV_FILE ]] && database_has_schema; then
    die "database ubicloud has a schema but $ENV_FILE is missing; restore the env file from the secrets backup (it holds CLOVER_COLUMN_ENCRYPTION_KEY) before running install.sh"
  fi
  # BASE_URL must name the port puma listens on (PORT, 3000 unless the
  # env file says otherwise).
  EFFECTIVE_PORT=3000
  if [[ -e $ENV_FILE ]]; then
    kv_read "$ENV_FILE"
    EFFECTIVE_PORT=${KV[PORT]:-3000}
  fi
  [[ -z $URL_PORT || $URL_PORT == "$EFFECTIVE_PORT" ]] ||
    usage_die "--url names port $URL_PORT, but puma listens on PORT $EFFECTIVE_PORT"
  if [[ -e $BACKUP_CONF ]]; then
    plan_backup
    diff_settings "$BACKUP_CONF"
    conflicts+=("${CONFLICTS[@]}")
  fi
  if [[ -e $FRONT_CONF ]]; then
    plan_front
    diff_settings "$FRONT_CONF"
    OLD_FRONT=${KV[TLS_FRONT]:-none}
    conflicts+=("${CONFLICTS[@]}")
  fi
  if [[ -n $(recipients_wanted) && -e $BACKUP_RECIPIENTS ]] &&
    ! recipients_wanted | cmp -s - "$BACKUP_RECIPIENTS" && [[ -z ${UPDATE_ENV[BACKUP_RECIPIENTS]:-} ]]; then
    conflicts+=(BACKUP_RECIPIENTS)
  fi
  ((${#conflicts[@]} == 0)) && return 0
  # A front switch changes TLS_FRONT, IP_FROM_HEADER (unless it was
  # unset) and BASE_URL (unless the URL stays): name each one it needs.
  local switch=""
  for k in "${conflicts[@]}"; do
    [[ $k != BASE_URL && $k != IP_FROM_HEADER && $k != TLS_FRONT ]] || switch+=" --update-env $k"
  done
  for k in "${conflicts[@]}"; do
    case $k in
      TLS_FRONT)
        printf "install.sh: key TLS_FRONT differs; the front is --tls %s; to switch it to --tls %s (the old one stops once the new one runs), pass%s\n" "$OLD_FRONT" "$TLS" "$switch" >&2
        ;;
      IP_FROM_HEADER)
        # Set by hand, the header could name one the front does not set,
        # which clients could then choose.
        printf "install.sh: key IP_FROM_HEADER differs; it follows --tls (X-Real-IP for acme and provided, CF-Connecting-IP for tunnel, unset for none), so change it only with the front: pass --update-env IP_FROM_HEADER with --tls\n" >&2
        ;;
      *) printf "install.sh: key %s differs; edit with 'ubicloud-admin env set %s' or pass --update-env %s\n" "$k" "$k" "$k" >&2 ;;
    esac
  done
  exit 2
}

# A stopped server is not an empty one: postgres is started (step 5
# starts it anyway) and a database that cannot be queried is a refusal,
# never "no schema". Called in a condition, so set -e is off in here.
database_has_schema() {
  local db schema
  systemctl start "$PG_UNIT" || die "cannot start $PG_UNIT to check for an existing database ubicloud"
  wait_postgres
  db=$(psql_value -c "SELECT 1 FROM pg_database WHERE datname = 'ubicloud'") ||
    die "cannot query $PG_UNIT for an existing database ubicloud"
  [[ -n $db ]] || return 1
  schema=$(psql_value -d ubicloud -c "SELECT to_regclass('public.schema_migrations') IS NOT NULL") ||
    die "cannot tell whether database ubicloud has a schema; $ENV_FILE is missing, so install.sh stops"
  [[ $schema == t ]]
}

# write_settings FILE HEADER: applies ADD/REPLACE/REMOVE to FILE (as
# loaded by diff_settings) and reports the key names, never the values.
write_settings() {
  local file=$1 header=$2 k line out=() changes=()
  declare -A replace=() remove=()
  for k in "${REPLACE[@]}"; do replace[$k]=1; done
  for k in "${REMOVE[@]}"; do remove[$k]=1; done
  if ((${#ADD[@]} + ${#REPLACE[@]} + ${#REMOVE[@]} == 0)); then
    report ok "settings: $file"
    return 1
  fi
  if ((${#KV_LINES[@]} == 0)); then
    out+=("$header")
  fi
  for line in "${KV_LINES[@]}"; do
    k=${line%%=*}
    if [[ -n ${remove[$k]:-} && $line == "$k='"* ]]; then
      continue
    elif [[ -n ${replace[$k]:-} && $line == "$k='"* ]]; then
      out+=("$k='${WANT[$k]}'")
    else
      out+=("$line")
    fi
  done
  for k in "${ADD[@]}"; do
    out+=("$k='$(setting_value "$k")'")
  done
  # Callers test the status, which turns off set -e in here.
  { install -m 0600 -o root -g root /dev/null "$file.new" &&
    printf '%s\n' "${out[@]}" >"$file.new" &&
    mv -f "$file.new" "$file"; } || die "cannot write $file"
  ((${#ADD[@]})) && changes+=("added ${ADD[*]}")
  ((${#REPLACE[@]})) && changes+=("updated ${REPLACE[*]}")
  ((${#REMOVE[@]})) && changes+=("removed ${REMOVE[*]}")
  report changed "settings: $file: ${changes[*]}"
  return 0
}

setting_value() {
  case $1 in
    CLOVER_SESSION_SECRET | CLOVER_RUNTIME_TOKEN_SECRET) head -c 64 /dev/urandom | base64 -w0 ;;
    CLOVER_COLUMN_ENCRYPTION_KEY) head -c 32 /dev/urandom | base64 -w0 ;;
    *) printf '%s' "${WANT[$1]}" ;;
  esac
}

plan_backup() {
  WANT=() KIND=() WANT_KEYS=()
  if [[ -n $BACKUP_TARGET ]]; then
    want BACKUP_TARGET flag "$BACKUP_TARGET"
  else
    want BACKUP_TARGET default /var/backups/ubicloud
  fi
}

recipients_wanted() {
  if [[ -n $BACKUP_RECIPIENT ]]; then
    printf '%s\n' "$BACKUP_RECIPIENT"
  elif [[ -n $BACKUP_RECIPIENT_FILE ]]; then
    grep -v -e '^#' -e '^[[:space:]]*$' "$BACKUP_RECIPIENT_FILE" || true
  fi
}

# Turns --smtp-file into SMTP_* lines with the source's bin/byoh-smtp-url,
# which needs no database. The URL never reaches argv or the output.
# M3-n: root never runs source code, so the parser runs as nobody from a
# copy of its two files that user nobody can read.
read_smtp() {
  SMTP_LINES=""
  [[ -n $SMTP_FILE ]] || return 0
  local url dir
  if [[ $SMTP_FILE == - ]]; then url=$(cat); else url=$(cat "$SMTP_FILE"); fi
  dir=$(mktemp -d /tmp/ubicloud-smtp.XXXXXX)
  SMTP_DIR=$dir
  install -d -m 0755 "$dir/bin" "$dir/lib"
  install -m 0644 "$SRC_DIR/bin/byoh-smtp-url" "$dir/bin/byoh-smtp-url"
  install -m 0644 "$SRC_DIR/lib/byoh_smtp_url.rb" "$dir/lib/byoh_smtp_url.rb"
  chmod 0755 "$dir"
  SMTP_LINES=$(cd "$dir" && printf '%s' "$url" |
    setpriv --reuid=nobody --regid=nogroup --clear-groups -- \
      env -i PATH="$SERVICE_PATH" "$TOOLS/bin/ruby" "$dir/bin/byoh-smtp-url") ||
    usage_die "--smtp-file: the URL is not usable (see the message above)"
  rm -rf "$dir"
  SMTP_DIR=""
  SMTP_LINES=${SMTP_LINES%$'\n'}
}

# --- step 4: users and release (M3-c/d/n) -------------------------------------------

ensure_users() {
  local changed=0
  getent group ubicloud >/dev/null || { groupadd --system ubicloud; changed=1; }
  if ! id ubicloud >/dev/null 2>&1; then
    useradd --system -g ubicloud -d "$STATE" -s /usr/sbin/nologin ubicloud
    changed=1
  fi
  if ! id ubicloud-migrate >/dev/null 2>&1; then
    useradd --system --user-group -G ubicloud -d /nonexistent -M -s /usr/sbin/nologin ubicloud-migrate
    changed=1
  fi
  # M3-n: the only writable state. var/ is setgid 2770 so that
  # ubicloud-migrate and the services rewrite each other's ca_bundles.
  [[ -d $STATE/var && -d $STATE/billing_rates.d ]] || changed=1
  install -d -m 0750 -o ubicloud -g ubicloud "$STATE"
  install -d -m 2770 -o ubicloud -g ubicloud "$STATE/var"
  install -d -m 0750 -o ubicloud -g ubicloud "$STATE/billing_rates.d"
  if ((changed)); then report changed "users: ubicloud, ubicloud-migrate, $STATE"; else report ok "users: ubicloud, ubicloud-migrate"; fi
}

release_rev() { sed -n 's/^rev=//p' "$RELEASES/$1/.ubicloud-release" 2>/dev/null; }

# check_release: exits 2 before anything changes when this run would
# rebuild an existing version or switch versions.
check_release() {
  local cur
  if [[ -L $CURRENT ]]; then
    cur=$(readlink "$CURRENT")
    cur=${cur##*/}
    [[ $cur == "$VERSION" ]] ||
      usage_die "release $cur is current; switching to $VERSION is a release switch, see docs/byoh/OPERATIONS.md (release switch)"
  fi
  if [[ -d $RELEASES/$VERSION ]]; then
    [[ $(release_rev "$VERSION") == "$SRC_REV" ]] ||
      usage_die "release $VERSION exists with rev $(release_rev "$VERSION"), not $SRC_REV; give the new build another --version"
  fi
}

# as_build CMD...: runs CMD as ubicloud in the release being built, with
# a throwaway HOME so no bundler or npm cache lands in the state dir.
as_build() {
  runuser -u ubicloud -- env -i PATH="$SERVICE_PATH" HOME="$BUILD_HOME" "$@"
}

RELEASE_CHANGED=0

step_release() {
  if [[ -d $RELEASES/$VERSION ]]; then
    report ok "release: $VERSION at rev $SRC_REV"
  else
    build_release
  fi
  if [[ $(readlink "$CURRENT" 2>/dev/null) != "releases/$VERSION" ]]; then
    ln -sfn "releases/$VERSION" "$OPT/current.new"
    mv -T "$OPT/current.new" "$CURRENT"
    RELEASE_CHANGED=1
    report changed "release: current -> $VERSION"
  fi
}

build_release() {
  local tmp=$RELEASES/$VERSION.tmp
  install -d -m 0755 "$OPT" "$RELEASES"
  rm -rf "$tmp"
  install -d -m 0755 -o ubicloud -g ubicloud "$tmp"
  cp -a "$SRC_DIR/." "$tmp/"
  chown -R ubicloud:ubicloud "$tmp"
  [[ -f $tmp/cache/schema.cache ]] || die "the source has no cache/*.cache; install.sh uses the committed Sequel caches"
  # Not under $WORK, which only root can enter.
  BUILD_HOME=$(mktemp -d /tmp/ubicloud-build-home.XXXXXX)
  chown ubicloud:ubicloud "$BUILD_HOME"
  # Chained with &&: a subshell on the left of || runs without set -e.
  (
    cd "$tmp" &&
      as_build bundle config set --local deployment true &&
      as_build bundle config set --local path vendor/bundle &&
      as_build bundle config set --local without "$BUNDLE_WITHOUT" &&
      as_build bundle install --jobs 4 --quiet &&
      as_build npm ci --no-audit --no-fund --loglevel=error &&
      as_build npm run prod &&
      rm -rf node_modules
  ) >"$WORK/build.log" 2>&1 || {
    tail -40 "$WORK/build.log" >&2
    die "building release $VERSION failed"
  }
  rm -rf "$BUILD_HOME"
  [[ -s $tmp/assets/css/app.css ]] || die "npm run prod did not write assets/css/app.css"
  rm -rf "${tmp:?}/var"
  ln -s "$STATE/var" "$tmp/var"
  printf 'version=%s\nrev=%s\nbuilt=%s\n' "$VERSION" "$SRC_REV" "$(date -u +%FT%TZ)" >"$tmp/.ubicloud-release"
  printf "GIT_REV='%s'\n" "$SRC_REV" >"$tmp/.release-env"
  # M3-n: root owns the code, and the services can only read it.
  chown -R -h root:root "$tmp"
  chmod -R a+rX,go-w "$tmp"
  assert_release "$tmp"
  mv -T "$tmp" "$RELEASES/$VERSION"
  RELEASE_CHANGED=1
  report changed "release: built $VERSION at rev $SRC_REV"
}

# The bundler settings hold with an empty environment (as restarter and
# the units run ruby), and the development group is installed, so the
# release runs in either RACK_ENV. loader.rb itself connects to the
# database, so the check stops at the Bundler.setup it makes.
assert_release() {
  local dir=$1
  (
    cd "$dir"
    runuser -u ubicloud -- env -i PATH="$SERVICE_PATH" HOME="$STATE" bundle check >/dev/null ||
      die "bundle check fails in the release"
    runuser -u ubicloud -- env -i PATH="$SERVICE_PATH" HOME="$STATE" \
      ruby -e 'require "bundler"; Bundler.setup(:default, :development); require "pry"' >/dev/null ||
      die "the release lacks the gems of RACK_ENV=development"
  )
}

step_billing_rates() {
  [[ -n $BILLING_DIR ]] || return 0
  local f n=0 dest=$STATE/billing_rates.d
  shopt -s nullglob
  for f in "$BILLING_DIR"/*.yml; do
    if ! cmp -s "$f" "$dest/${f##*/}"; then
      install -m 0640 -o ubicloud -g ubicloud "$f" "$dest/${f##*/}"
      n=$((n + 1))
    fi
  done
  shopt -u nullglob
  if ((n)); then
    ENV_CHANGED=1
    report changed "billing rates: copied $n file(s) to $dest"
  else
    report ok "billing rates: $dest matches $BILLING_DIR"
  fi
}

# --- step 5: database (M3-e) ---------------------------------------------------------

psql_admin() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
psql_value() { runuser -u postgres -- psql -X -tA -v ON_ERROR_STOP=1 "$@"; }

wait_postgres() {
  local _
  for _ in $(seq 60); do
    runuser -u postgres -- pg_isready -q && return 0
    sleep 1
  done
  die "$PG_UNIT does not accept connections"
}

step_database() {
  local db_changes=()
  systemctl enable --now -q "$PG_UNIT" 2>/dev/null || systemctl start "$PG_UNIT"
  wait_postgres
  local r
  for r in ubicloud ubicloud_password; do
    if [[ -z $(psql_value -c "SELECT 1 FROM pg_roles WHERE rolname = '$r'") ]]; then
      psql_admin -c "CREATE ROLE $r LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE"
      db_changes+=("role $r")
    fi
    [[ $(psql_value -c "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR NOT rolcanlogin FROM pg_roles WHERE rolname = '$r'") == f ]] ||
      die "database role $r exists with superuser, createdb or createrole, or without login; fix it by hand"
  done
  if [[ -z $(psql_value -c "SELECT 1 FROM pg_database WHERE datname = 'ubicloud'") ]]; then
    runuser -u postgres -- createdb -O ubicloud ubicloud
    db_changes+=("database ubicloud")
  fi
  local ext
  for ext in citext btree_gist; do
    if [[ -z $(psql_value -d ubicloud -c "SELECT 1 FROM pg_extension WHERE extname = '$ext'") ]]; then
      psql_admin -d ubicloud -c "CREATE EXTENSION $ext"
      db_changes+=("$ext")
    fi
  done
  if [[ $(psql_value -d ubicloud -c "SELECT nspowner::regrole FROM pg_namespace WHERE nspname = 'public'") != ubicloud ]]; then
    psql_admin -d ubicloud -c 'ALTER SCHEMA public OWNER TO ubicloud'
    db_changes+=("schema owner")
  fi

  local ident hba
  ident=$(mktemp "$WORK/ident.XXXXXX")
  hba=$(mktemp "$WORK/hba.XXXXXX")
  # OS user ubicloud is role ubicloud; ubicloud-migrate may also be the
  # password-hash role, for migrations and restores only.
  cat >"$ident" <<'EOF'
# BEGIN ubicloud
ubicloud ubicloud ubicloud
ubicloud ubicloud-migrate ubicloud
ubicloud ubicloud-migrate ubicloud_password
ubicloud postgres postgres
# END ubicloud
EOF
  # First match wins, so the block goes before every other rule: database
  # ubicloud takes peer logins only, whatever trust lines follow.
  cat >"$hba" <<'EOF'
# BEGIN ubicloud
local ubicloud postgres peer
local ubicloud ubicloud,ubicloud_password peer map=ubicloud
local ubicloud all reject
host ubicloud all 127.0.0.1/32 reject
host ubicloud all ::1/128 reject
# END ubicloud
EOF
  BLOCK_CHANGED=0
  put_block "$PG_CONF/pg_ident.conf" "$ident" bottom
  put_block "$PG_CONF/pg_hba.conf" "$hba" top
  if ((BLOCK_CHANGED)); then
    systemctl reload "$PG_UNIT"
    db_changes+=("pg_hba/pg_ident")
  fi
  step_listen db_changes
  warn_trust
  if ((${#db_changes[@]})); then
    report changed "database: ${db_changes[*]}"
  else
    report ok "database: roles, ubicloud, extensions, peer map"
  fi
}

# The managed block keeps logins to database ubicloud peer-only, but a
# trust rule or a login superuser elsewhere (as the development bootstrap
# leaves them) still lets any local user reach a superuser, and a
# superuser can reach ubicloud, for example with COPY ... TO PROGRAM as
# the postgres OS user. That stays until the operator removes them, so
# install.sh warns on every run (M3-e; migrate-from-dev retires them).
warn_trust() {
  local lines supers
  lines=$(psql_value -c "SELECT string_agg(line_number::text, ',' ORDER BY line_number) FROM pg_hba_file_rules WHERE auth_method = 'trust'")
  [[ -z $lines ]] ||
    report warn "database: $PG_CONF/pg_hba.conf line(s) $lines use trust; any local user can log in to the databases they cover, and a superuser there can reach ubicloud"
  supers=$(psql_value -c "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles WHERE rolsuper AND rolcanlogin AND rolname <> 'postgres'")
  [[ -z $supers ]] ||
    report warn "database: role(s) $supers are superusers that can log in; a superuser can reach ubicloud"
}

# put_block FILE BLOCK top|bottom: makes BLOCK the only "# BEGIN
# ubicloud" .. "# END ubicloud" block in FILE, at its top or bottom.
# FILE is rewritten (keeping owner and mode) only when that changes it.
put_block() {
  local file=$1 block=$2 where=$3 rest new
  rest=$(mktemp "$WORK/rest.XXXXXX")
  new=$(mktemp "$WORK/new.XXXXXX")
  sed '/^# BEGIN ubicloud$/,/^# END ubicloud$/d' "$file" >"$rest"
  if [[ $where == top ]]; then cat "$block" "$rest" >"$new"; else cat "$rest" "$block" >"$new"; fi
  if ! cmp -s "$new" "$file"; then
    install -m "$(stat -c %a "$file")" -o "$(stat -c %U "$file")" -g "$(stat -c %G "$file")" "$new" "$file"
    BLOCK_CHANGED=1
  fi
}

# Postgres listens on localhost only. A host with other databases keeps
# its setting with --skip-check listen.
step_listen() {
  local -n acc=$1
  local cur conf=$PG_CONF/conf.d/90-ubicloud.conf
  cur=$(psql_value -c 'SHOW listen_addresses')
  [[ $cur == localhost ]] && return 0
  if [[ -n ${SKIP_CHECK[listen]:-} ]]; then
    report warn "database: listen_addresses is '$cur', not localhost (--skip-check listen)"
    return 0
  fi
  install -d -m 0755 -o postgres -g postgres "$PG_CONF/conf.d"
  printf "# Written by install.sh: the control plane needs no remote connections.\nlisten_addresses = 'localhost'\n" >"$WORK/listen.conf"
  install -m 0644 -o postgres -g postgres "$WORK/listen.conf" "$conf"
  report notice "database: restarting $PG_UNIT to set listen_addresses to localhost (was '$cur')"
  systemctl restart "$PG_UNIT"
  wait_postgres
  [[ $(psql_value -c 'SHOW listen_addresses') == localhost ]] ||
    die "listen_addresses is still not localhost; a later setting overrides $conf"
  acc+=("listen_addresses")
}

# --- step 6: env file ---------------------------------------------------------------------

ENV_CHANGED=0

step_env() {
  install -d -m 0755 -o root -g root "$ETC"
  plan_env
  diff_settings "$ENV_FILE"
  # check_settings already exited on conflicts.
  if write_settings "$ENV_FILE" "# /etc/ubicloud/env: settings of the ubicloud services, KEY='value' per line, no text after the closing quote. Change with ubicloud-admin env set KEY."; then
    ENV_CHANGED=1
  fi
  [[ $(stat -c '%U:%G %a' "$ENV_FILE") == "root:root 600" ]] || {
    chown root:root "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    report changed "settings: $ENV_FILE mode 0600"
  }
}

# --- step 7: migrations ---------------------------------------------------------------------

migration_count() {
  psql_value -d ubicloud -c "SELECT (SELECT count(*) FROM schema_migrations) || '/' || (SELECT count(*) FROM schema_migrations_password)" 2>/dev/null || echo none
}

step_migrate() {
  local before after
  before=$(migration_count)
  as_service ubicloud-migrate "$TOOLS/bin/ruby" bin/rake-task-runner migrate "" 0 >"$WORK/migrate.log" 2>&1 || {
    grep -v -i 'password' "$WORK/migrate.log" | tail -30 >&2
    die "migrations failed"
  }
  after=$(migration_count)
  if [[ $before == "$after" ]]; then
    report ok "migrations: none pending ($after applied)"
  else
    report changed "migrations: $before -> $after applied (schema_migrations/schema_migrations_password)"
  fi
}

# check_start: exits 2 before anything changes when this run would start
# the units while something else serves the port, or while a development
# control plane (scripts/byoh/bootstrap-ctrl-plane.sh) lives on this
# machine. Its tmux puma holds 0.0.0.0:3000: the packaged web would loop
# on EADDRINUSE, then take the port over when the tmux puma stops.
check_start() {
  ((NO_START)) && return 0
  [[ $(systemctl is-active ubicloud.target 2>/dev/null || true) == active ]] && return 0
  local m
  for m in /root/.ubi-bootstrap /home/*/.ubi-bootstrap; do
    [[ ! -d $m ]] ||
      usage_die "$m exists, so a development control plane lives on this machine; install with --no-start and move it with scripts/byoh/migrate-from-dev.sh"
  done
  if [[ $(systemctl is-active ubicloud-web 2>/dev/null || true) != active &&
    -n $(ss -Htln "sport = :$EFFECTIVE_PORT") ]]; then
    usage_die "something already listens on port $EFFECTIVE_PORT (ss -tlnp 'sport = :$EFFECTIVE_PORT'); stop it, or install with --no-start"
  fi
}

# --- step 9: units ------------------------------------------------------------------------------

step_units() {
  local u changed=0
  for u in "$CURRENT"/packaging/systemd/*; do
    if ! cmp -s "$u" "$UNIT_DIR/${u##*/}"; then
      install -m 0644 -o root -g root "$u" "$UNIT_DIR/${u##*/}"
      changed=1
    fi
  done
  if ((changed)); then
    systemctl daemon-reload
    report changed "units: installed from $(readlink "$CURRENT")"
  else
    report ok "units: installed"
  fi
  if ((NO_START)); then
    report skip "units: not enabled or started (--no-start)"
    if ((changed + RELEASE_CHANGED + ENV_CHANGED)) && systemctl -q is-active ubicloud-web ubicloud-respirate; then
      report notice "units: the running services keep the old settings until 'systemctl restart ubicloud.target'"
    fi
    return
  fi
  if [[ $(systemctl is-enabled ubicloud.target 2>/dev/null || true) != enabled ]]; then
    systemctl enable -q ubicloud.target
    report changed "units: enabled ubicloud.target"
  fi
  if [[ $(systemctl is-active ubicloud.target 2>/dev/null || true) != active ]]; then
    systemctl start ubicloud.target
    report changed "units: started ubicloud.target"
  elif ((changed + RELEASE_CHANGED + ENV_CHANGED)); then
    systemctl try-restart ubicloud.target
    report changed "units: restarted ubicloud.target"
  else
    report ok "units: ubicloud.target active"
  fi
  [[ $(systemctl is-enabled ubicloud-monitor.service 2>/dev/null || true) != enabled ]] ||
    report warn "units: ubicloud-monitor is enabled; it is meant to stay disabled until M9"
}

# --- step 10: TLS front (M3-g) ---------------------------------------------------------------

plan_front() {
  WANT=() KIND=() WANT_KEYS=()
  want TLS_FRONT flag "$TLS"
}

# The front the last run set up; none before front.conf existed.
OLD_FRONT=none

# Caddy may own /etc/caddy/Caddyfile only when it is absent, the
# package's own, or one this script wrote.
caddyfile_ours_or_stock() {
  [[ -e $CADDYFILE ]] || return 0
  [[ $(head -1 "$CADDYFILE") == "$CADDYFILE_MARK"* ]] && return 0
  local want
  want=$(dpkg-query -W -f='${Conffiles}\n' caddy 2>/dev/null | awk -v f="$CADDYFILE" '$1 == f { print $2 }')
  [[ -n $want && $(md5sum <"$CADDYFILE" | cut -d' ' -f1) == "$want" ]]
}

caddyfile_ours() { [[ -e $CADDYFILE && $(head -1 "$CADDYFILE") == "$CADDYFILE_MARK"* ]]; }

# Reads a certificate file as root; errors name the file, never its
# contents.
check_cert() {
  openssl x509 -in "$CERT_FILE" -noout 2>/dev/null </dev/null || usage_die "--cert $CERT_FILE is not a PEM certificate"
  openssl pkey -in "$KEY_FILE" -passin pass: -noout 2>/dev/null </dev/null ||
    usage_die "--key $KEY_FILE is not an unencrypted PEM private key"
  [[ $(openssl x509 -in "$CERT_FILE" -noout -pubkey 2>/dev/null) == "$(openssl pkey -in "$KEY_FILE" -passin pass: -pubout 2>/dev/null </dev/null)" ]] ||
    usage_die "--key $KEY_FILE is not the key of --cert $CERT_FILE"
  [[ $(openssl x509 -in "$CERT_FILE" -noout -checkhost "$URL_HOST" 2>/dev/null) == *" does match "* ]] ||
    usage_die "--cert $CERT_FILE is not valid for $URL_HOST"
  openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 || usage_die "--cert $CERT_FILE has expired"
  openssl x509 -in "$CERT_FILE" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 ||
    report warn "front: --cert $CERT_FILE expires within 30 days ($(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2))"
  (($(stat -L -c '%#a' "$KEY_FILE") & 077)) &&
    report warn "front: --key $KEY_FILE is readable by group or other; chmod 600 it (the installed copy is 0640 root:caddy)"
  return 0
}

has_existing_cloudflared() { [[ ! -e $UNIT_DIR/$CF_UNIT ]] && systemctl cat cloudflared.service >/dev/null 2>&1; }

# A cloudflared.service that install.sh did not write and that runs or
# starts at boot.
foreign_cloudflared_live() {
  systemctl cat cloudflared.service >/dev/null 2>&1 &&
    [[ $(systemctl is-active cloudflared.service 2>/dev/null || true) == active ||
      $(systemctl is-enabled cloudflared.service 2>/dev/null || true) == enabled ]]
}

# What check_front found out for step_front: the caddy version apt
# would install, and the checked cloudflared package.
CADDY_CANDIDATE="" CF_DEB=""

# check_front: exits 2 before anything changes when the front cannot be
# set up as asked. Everything step_front could fail on short of a
# broken package or service is checked here, so a switch never stops a
# working front for one that cannot come up.
check_front() {
  case $TLS in
    acme | provided)
      caddyfile_ours_or_stock ||
        usage_die "$CADDYFILE is neither the caddy package's nor one install.sh wrote; --tls $TLS would replace it, so move it away first or use --tls tunnel"
      [[ $TLS != provided ]] || check_cert
      # cloudflared passes a client's X-Real-IP through unchanged, so
      # while it forwards to puma, puma must not trust that header. This
      # holds with --no-start too: the next restart applies the env file.
      ! foreign_cloudflared_live ||
        usage_die "cloudflared.service is running or enabled and forwards its tunnel to puma; with --tls $TLS puma trusts X-Real-IP, which tunnel clients could then set to any address in the audit logs. Stop and disable it (systemctl disable --now cloudflared.service) once $URL_HOST points at this machine, then run install.sh again"
      ((NO_START)) && return 0
      local out
      out=$(ss -Htlnp '( sport = :80 or sport = :443 )')
      if [[ -n $out ]] && grep -qv 'users:(("caddy"' <<<"$out"; then
        usage_die "something other than caddy listens on port 80 or 443 (ss -tlnp '( sport = :80 or sport = :443 )'); --tls $TLS needs both"
      fi
      if [[ $(dpkg-query -W -f='${db:Status-Status}' caddy 2>/dev/null || true) != installed ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update failed"
        CADDY_CANDIDATE=$(apt-cache policy caddy | sed -n 's/^ *Candidate: //p')
        [[ -n $CADDY_CANDIDATE && $CADDY_CANDIDATE != "(none)" ]] ||
          usage_die "no caddy package is available for --tls $TLS; enable the universe component (add-apt-repository universe) and run install.sh again"
      fi
      ;;
    tunnel)
      [[ -n $CF_TOKEN_FILE ]] || has_existing_cloudflared || [[ -e $UNIT_DIR/$CF_UNIT ]] ||
        usage_die "--tls tunnel needs --cloudflared-token-file F (the tunnel token, mode 0600) on a machine without a cloudflared.service"
      if [[ -n $CF_TOKEN_FILE ]]; then
        ! has_existing_cloudflared ||
          usage_die "cloudflared.service exists and install.sh leaves it as it is, so it would never use --cloudflared-token-file; drop the flag, or remove that unit to let install.sh run its own tunnel"
        [[ $(tr -d '\n' <"$CF_TOKEN_FILE") =~ ^[A-Za-z0-9+/=_.-]{20,}$ ]] ||
          usage_die "--cloudflared-token-file $CF_TOKEN_FILE does not hold one tunnel token (the value is not shown)"
      fi
      ((NO_START)) && return 0
      has_existing_cloudflared && return 0
      if [[ $(dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null || true) != installed ]]; then
        local arch
        arch=$(dpkg --print-architecture)
        [[ $arch == amd64 ]] ||
          usage_die "install.sh pins cloudflared for amd64 only (this machine is $arch); install cloudflared yourself and run it as cloudflared.service"
        CF_DEB=$WORK/cloudflared.deb
        curl -fsSL --retry 3 -o "$CF_DEB" \
          "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64.deb" ||
          die "cannot download cloudflared $CLOUDFLARED_VERSION"
        echo "$CLOUDFLARED_SHA256  $CF_DEB" | sha256sum -c --quiet ||
          die "cloudflared $CLOUDFLARED_VERSION does not match its pinned sha256"
      else
        grep -q -- '--token-file' < <(cloudflared tunnel run --help 2>&1) ||
          usage_die "the installed cloudflared has no tunnel run --token-file; install $CLOUDFLARED_VERSION or later"
      fi
      ;;
  esac
  return 0
}

# The new front comes up before the old one stops, and front.conf
# records the switch last, so a run that dies leaves the old front
# running and recorded. With --no-start nothing changes here: the old
# front keeps serving the running services.
step_front() {
  if ((NO_START)); then
    if [[ $OLD_FRONT != "$TLS" ]]; then
      report skip "front: --tls $TLS not set up and --tls $OLD_FRONT left as it is (--no-start); a run without --no-start, with --update-env TLS_FRONT, switches it"
    elif [[ $TLS != none ]]; then
      report skip "front: --tls $TLS not set up (--no-start)"
    fi
    [[ $TLS != tunnel ]] || ! has_existing_cloudflared || existing_cloudflared
    return 0
  fi
  case $TLS in
    acme | provided) front_caddy ;;
    tunnel) front_tunnel ;;
    none) report ok "front: none; puma serves http on 127.0.0.1:$EFFECTIVE_PORT only" ;;
  esac
  [[ $OLD_FRONT == "$TLS" ]] || retire_front
  plan_front
  diff_settings "$FRONT_CONF"
  write_settings "$FRONT_CONF" "# /etc/ubicloud/front.conf: the TLS front install.sh set up (--tls), KEY='value' per line." || true
}

# Stops the front an earlier run set up for another --tls. An existing
# cloudflared.service was never ours, so install.sh only warns about it
# (check_front refuses Caddy next to it).
retire_front() {
  case $OLD_FRONT in
    acme | provided)
      if [[ $TLS != acme && $TLS != provided ]] && caddyfile_ours &&
        [[ $(systemctl is-enabled caddy 2>/dev/null || true) == enabled || $(systemctl is-active caddy 2>/dev/null || true) == active ]]; then
        systemctl disable --now -q caddy
        report changed "front: stopped and disabled caddy (was --tls $OLD_FRONT)"
      fi
      ;;
    tunnel)
      if [[ -e $UNIT_DIR/$CF_UNIT ]]; then
        if [[ $TLS != tunnel ]]; then
          systemctl disable --now -q "$CF_UNIT"
          report changed "front: stopped and disabled $CF_UNIT (was --tls tunnel); $CF_TOKEN is kept"
        fi
      elif foreign_cloudflared_live; then
        report warn "front: cloudflared.service still forwards the old tunnel to puma; stop and disable it yourself once nothing uses it"
      fi
      ;;
  esac
}

front_caddy() {
  local restart=0
  # check_front found the candidate.
  if [[ $(dpkg-query -W -f='${db:Status-Status}' caddy 2>/dev/null || true) != installed ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends caddy >/dev/null
    restart=1
    report changed "front: installed caddy $CADDY_CANDIDATE"
  fi
  if [[ $TLS == provided ]]; then
    local changed=0
    install -d -m 0750 -o root -g caddy "$TLS_DIR"
    if ! cmp -s "$CERT_FILE" "$TLS_DIR/cert.pem"; then
      install -m 0644 -o root -g caddy "$CERT_FILE" "$TLS_DIR/cert.pem"
      changed=1
    fi
    if ! cmp -s "$KEY_FILE" "$TLS_DIR/key.pem"; then
      install -m 0640 -o root -g caddy "$KEY_FILE" "$TLS_DIR/key.pem"
      changed=1
    fi
    if ((changed)); then
      restart=1
      report changed "front: certificate for $URL_HOST in $TLS_DIR (until $(openssl x509 -in "$TLS_DIR/cert.pem" -noout -enddate | cut -d= -f2))"
    else
      report ok "front: certificate for $URL_HOST in $TLS_DIR"
    fi
  fi
  render_caddyfile >"$WORK/Caddyfile"
  caddy adapt --adapter caddyfile --config "$WORK/Caddyfile" >/dev/null 2>"$WORK/caddy.err" || {
    cat "$WORK/caddy.err" >&2
    die "the rendered Caddyfile does not parse"
  }
  if ! cmp -s "$WORK/Caddyfile" "$CADDYFILE"; then
    install -m 0644 -o root -g root "$WORK/Caddyfile" "$CADDYFILE"
    restart=1
    report changed "front: $CADDYFILE for $URL_HOST (--tls $TLS)"
  else
    report ok "front: $CADDYFILE for $URL_HOST (--tls $TLS)"
  fi
  if [[ $(systemctl is-enabled caddy 2>/dev/null || true) != enabled ]]; then
    systemctl enable -q caddy
    report changed "front: enabled caddy"
  fi
  # admin off: caddy reload goes through the admin API, so restart.
  if ((restart)) || [[ $(systemctl is-active caddy 2>/dev/null || true) != active ]]; then
    systemctl restart caddy
    wait_for_listener 443 || die "caddy does not listen on 443; see journalctl -u caddy"
    report changed "front: restarted caddy"
  else
    report ok "front: caddy active"
  fi
  [[ $TLS != acme ]] ||
    report notice "front: caddy gets the certificate for $URL_HOST from Let's Encrypt in the background; it needs public DNS for $URL_HOST and ports 80 and 443 open (journalctl -u caddy)"
}

wait_for_listener() {
  local _
  for _ in $(seq 20); do
    [[ -n $(ss -Htln "sport = :$1") ]] && return 0
    sleep 0.5
  done
  return 1
}

# Placeholders are replaced as quoted strings, so & and \ in a value
# stay literal (bash 5.2 patsub_replacement).
render_caddyfile() {
  local t global tls
  t=$(<"$CURRENT/packaging/caddy/Caddyfile.tmpl")
  if [[ $TLS == provided ]]; then
    global="auto_https disable_certs"
    tls="tls $TLS_DIR/cert.pem $TLS_DIR/key.pem"
  else
    global="email $ADMIN_EMAIL"
    tls=""
  fi
  t=${t//@MODE@/"$TLS"}
  t=${t//@HOST@/"$URL_HOST"}
  t=${t//@PORT@/"$EFFECTIVE_PORT"}
  t=${t//@GLOBAL@/"$global"}
  t=${t//@TLS@/"$tls"}
  # An empty placeholder leaves a line of tabs.
  printf '%s\n' "$t" | sed '/^[[:space:]]\+$/d'
}

front_tunnel() {
  local restart=0
  if [[ -n $CF_TOKEN_FILE ]]; then
    if ! cmp -s "$CF_TOKEN_FILE" "$CF_TOKEN"; then
      install -m 0600 -o root -g root "$CF_TOKEN_FILE" "$CF_TOKEN"
      restart=1
      report changed "front: tunnel token in $CF_TOKEN"
    else
      report ok "front: tunnel token in $CF_TOKEN"
    fi
  fi
  # check_front refused a token file next to an existing unit.
  if has_existing_cloudflared; then
    existing_cloudflared
    return 0
  fi
  # check_front checked the architecture and downloaded and checked the
  # package.
  if [[ $(dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null || true) != installed ]]; then
    dpkg -i "$CF_DEB" >/dev/null
    restart=1
    report changed "front: installed cloudflared $CLOUDFLARED_VERSION"
  fi
  grep -q -- '--token-file' < <(cloudflared tunnel run --help 2>&1) ||
    die "the installed cloudflared has no tunnel run --token-file; install $CLOUDFLARED_VERSION or later"
  if ! cmp -s "$CURRENT/packaging/cloudflared/$CF_UNIT" "$UNIT_DIR/$CF_UNIT"; then
    install -m 0644 -o root -g root "$CURRENT/packaging/cloudflared/$CF_UNIT" "$UNIT_DIR/$CF_UNIT"
    systemctl daemon-reload
    restart=1
    report changed "front: installed $CF_UNIT"
  fi
  if [[ $(systemctl is-enabled "$CF_UNIT" 2>/dev/null || true) != enabled ]]; then
    systemctl enable -q "$CF_UNIT"
    report changed "front: enabled $CF_UNIT"
  fi
  if ((restart)) || [[ $(systemctl is-active "$CF_UNIT" 2>/dev/null || true) != active ]]; then
    # It connects to Cloudflare in the background; a bad token shows in
    # its journal, not here.
    systemctl restart --no-block "$CF_UNIT"
    report changed "front: started $CF_UNIT"
    local _
    for _ in $(seq 30); do
      [[ $(systemctl is-active "$CF_UNIT" 2>/dev/null || true) == active ]] && break
      sleep 0.5
    done
    [[ $(systemctl is-active "$CF_UNIT" 2>/dev/null || true) == active ]] ||
      report warn "front: $CF_UNIT is not active after 15 s; check the token (journalctl -u $CF_UNIT)"
  else
    report ok "front: $CF_UNIT active"
  fi
  tunnel_ingress_notice
}

# The live case: a cloudflared.service someone else installed (often by
# cloudflared service install, which puts the token on its command
# line). It is never changed; install.sh only reports on it.
existing_cloudflared() {
  report ok "front: cloudflared.service exists; install.sh leaves it as it is"
  [[ $(systemctl is-active cloudflared.service 2>/dev/null || true) == active ]] ||
    report warn "front: cloudflared.service is not running, so nothing serves $URL; start it (systemctl start cloudflared.service)"
  [[ $(systemctl is-enabled cloudflared.service 2>/dev/null || true) == enabled ]] ||
    report warn "front: cloudflared.service is not enabled, so the tunnel stays down after a reboot; enable it (systemctl enable cloudflared.service)"
  if [[ $(systemctl show -p ExecStart --value cloudflared.service) =~ (^|[[:space:]])--token([[:space:]]|=) ]]; then
    report warn "front: cloudflared.service passes the tunnel token on its command line, where every local user can read it (ps); move it to a 0600 file with --token-file"
  fi
  if [[ $(systemctl show -p Environment --value cloudflared.service) =~ (^|[[:space:]])TUNNEL_TOKEN= ]]; then
    report warn "front: cloudflared.service sets TUNNEL_TOKEN in its unit, which every local user can read (systemctl show); move it to a 0600 file with --token-file"
  fi
  tunnel_ingress_notice
}

tunnel_ingress_notice() {
  report notice "front: the tunnel's public hostname $URL_HOST must route to http://127.0.0.1:$EFFECTIVE_PORT (Cloudflare dashboard or ingress rules); puma listens on 127.0.0.1 only, so a route to localhost fails where localhost resolves to ::1"
}

# --- step 11: backup settings and key custody --------------------------------------------------

step_backup() {
  plan_backup
  diff_settings "$BACKUP_CONF"
  write_settings "$BACKUP_CONF" "# /etc/ubicloud/backup.conf: where ubicloud-admin backup writes, KEY='value' per line." || true
  local target
  kv_read "$BACKUP_CONF"
  target=${KV[BACKUP_TARGET]}
  if [[ ! -d $target ]]; then
    install -d -m 0700 -o root -g root "$target"
    report changed "backups: created $target"
  fi
  local want
  want=$(recipients_wanted)
  if [[ -n $want ]]; then
    if ! printf '%s\n' "$want" | cmp -s - "$BACKUP_RECIPIENTS"; then
      printf '%s\n' "$want" >"$WORK/recipients"
      age -R "$WORK/recipients" -o /dev/null </dev/null 2>"$WORK/age.err" ||
        usage_die "the backup recipient is not a valid age recipient: $(head -1 "$WORK/age.err")"
      install -m 0644 -o root -g root "$WORK/recipients" "$BACKUP_RECIPIENTS"
      report changed "backups: recipients in $BACKUP_RECIPIENTS"
    else
      report ok "backups: recipients in $BACKUP_RECIPIENTS"
    fi
  elif [[ ! -s $BACKUP_RECIPIENTS ]]; then
    report warn "backups: no --backup-recipient, so the secrets in $ETC are not backed up, and ubicloud-admin status fails until one is set"
  fi
  if [[ ! -e $target/KEYS-README.txt ]]; then
    keys_readme >"$WORK/KEYS-README.txt"
    install -m 0600 -o root -g root "$WORK/KEYS-README.txt" "$target/KEYS-README.txt"
    report changed "backups: wrote $target/KEYS-README.txt"
  fi
}

keys_readme() {
  cat <<EOF
Ubicloud control plane backups ($(hostname -f 2>/dev/null || hostname), written by install.sh $(date -u +%F))

<timestamp>/db.dump       pg_dump -Fc of the database "ubicloud", made as the
                          postgres OS user, so it includes the password-hash
                          tables. Most secret columns are encrypted with
                          CLOVER_COLUMN_ENCRYPTION_KEY, so the dump is useless
                          without that key, but it still holds sensitive data
                          (accounts, configuration, audit logs): protect it.
<timestamp>/globals.sql   pg_dumpall --globals-only (roles, no passwords: the
                          roles use peer authentication).
<timestamp>/manifest.json version, rev, applied migrations, sha256 of each file.
secrets/<timestamp>.age   tar of $ETC/env (with CLOVER_COLUMN_ENCRYPTION_KEY,
                          CLOVER_SESSION_SECRET, CLOVER_RUNTIME_TOKEN_SECRET and
                          any SMTP or BMC passwords), $ETC/tls and the
                          cloudflared token, encrypted with age to the
                          recipients in $BACKUP_RECIPIENTS.

The age identity (private key) that decrypts secrets/*.age must NOT live on
this machine or next to these backups. Keep it offline or in your password
manager. Without it, and without a copy of $ETC/env, a restore
cannot read the encrypted columns.

Without a backup recipient, secrets are not backed up at all; keep your own
encrypted copy of $ETC/env.

Restore: ubicloud-admin restore <timestamp> --key-file <age identity>
(docs/byoh/OPERATIONS.md). Test a restore every month.
EOF
}

# --- main ------------------------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args
  [[ $EUID == 0 ]] || die "run install.sh as root"
  exec 9>>"$LOCK"
  flock -w 60 9 || die "another install.sh or ubicloud-admin run holds $LOCK"

  step_checks
  fetch_source
  # The release and tools checks need only the source, so they run
  # before the packages and the tools change anything. With them passed,
  # step_tools can change the tools only where no release runs on them.
  [[ $STAGE == tools ]] || check_release
  check_tools
  step_packages
  step_tools
  [[ $STAGE == tools ]] && {
    report ok "stage tools done"
    return 0
  }

  # These need postgres and the tools (the SMTP parser) from the steps
  # above, which are the same as the current release's by now.
  read_smtp
  check_settings
  check_start
  check_front

  ensure_users
  step_release
  step_billing_rates
  step_database
  step_env
  step_migrate
  # The services restart with the new IP_FROM_HEADER in step_units.
  # Caddy drops CF-Connecting-IP, so it comes up before that restart
  # and the old tunnel stops before puma trusts X-Real-IP. cloudflared
  # passes X-Real-IP through, so a tunnel comes up only after puma
  # stopped trusting it.
  if [[ $TLS == tunnel ]]; then
    step_units
    step_front
  else
    step_front
    step_units
  fi
  step_backup

  echo
  echo "Ubicloud $VERSION (rev $SRC_REV) is installed."
  echo "  URL:      $URL"
  echo "  RACK_ENV: $(kv_read "$ENV_FILE" && echo "${KV[RACK_ENV]}")"
  echo "Next:"
  if [[ -x /usr/local/bin/ubicloud-admin ]]; then
    echo "  sudo ubicloud-admin account create --email $ADMIN_EMAIL"
    echo "  sudo ubicloud-admin status"
  else
    echo "  (ubicloud-admin is not installed by this build; see docs/byoh/INSTALL.md)"
  fi
  echo "  Front:    --tls $TLS"
  [[ $TLS != none ]] || echo "  --tls none serves 127.0.0.1:3000 only; reach it with ssh -L 3000:127.0.0.1:3000 (browser use UNVERIFIED)"
}

main "$@"
