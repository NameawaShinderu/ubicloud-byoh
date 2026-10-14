#!/bin/bash
# Runs as root INSIDE a throwaway ubi-m3-* container (never on a real
# host). It lays out a packaged control plane the way M3 describes it,
# just enough for the systemd scenarios in run.sh: tools under
# /opt/ubicloud/tools, a read-only release, the ubicloud database with
# peer auth and non-superuser roles, /etc/ubicloud/env and the units.
#
# This is a test fixture, not the installer. scripts/byoh/install.sh
# (WP4) replaces it in the scenarios once it exists.
#
#   fixture.sh tools            apt packages, pinned mise, ruby and node
#   fixture.sh release VERSION  release from /art/src.tgz, DB, env, migrate
#   fixture.sh units            install the units from /art/packaging/systemd
#   fixture.sh account EMAIL    create a verified account (password on stdin)
#   fixture.sh as-service CMD…  run CMD in the release as ubicloud, with the
#                               service environment (parsed by systemd)
set -euo pipefail
umask 077

TOOLS=/opt/ubicloud/tools
RELEASES=/opt/ubicloud/releases
STATE=/var/lib/ubicloud
MISE_VERSION=v2026.9.18
MISE_SHA256=d24fe0bf7e613824ad99f7b8dac3f2b381a37b9f75f84dd250855217095a8de4

log() { printf '[fixture] %s\n' "$*"; }

stage_tools() {
  local ruby_v node_v
  ruby_v=$(sed -n 's/^ruby = "\(.*\)"/\1/p' /art/mise.toml)
  node_v=$(sed -n 's/^node = "\(.*\)"/\1/p' /art/mise.toml)
  [[ -n $ruby_v && -n $node_v ]] || { echo "cannot read versions from mise.toml" >&2; exit 1; }

  log "apt packages"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    postgresql-16 postgresql-contrib-16 build-essential libssl-dev libyaml-dev \
    zlib1g-dev libffi-dev libpq-dev git curl jq >/dev/null
  rm -rf /var/lib/apt/lists/*

  log "mise $MISE_VERSION, ruby $ruby_v, node $node_v"
  install -d -m 0755 "$TOOLS" "$TOOLS/bin" "$TOOLS/mise" "$TOOLS/mise/bin"
  curl -fsSL -o "$TOOLS/mise/bin/mise" \
    "https://github.com/jdx/mise/releases/download/$MISE_VERSION/mise-$MISE_VERSION-linux-x64"
  echo "$MISE_SHA256  $TOOLS/mise/bin/mise" | sha256sum -c --quiet
  chmod 0755 "$TOOLS/mise/bin/mise"
  (
    # The tools are read and run by the service users.
    umask 022
    cd /
    export MISE_DATA_DIR=$TOOLS/mise MISE_CACHE_DIR=/var/cache/ubicloud-mise
    export MISE_CONFIG_DIR=/nonexistent MISE_RUBY_COMPILE=true MISE_YES=1
    "$TOOLS/mise/bin/mise" install "ruby@$ruby_v" "node@$node_v"
  )
  rm -rf /var/cache/ubicloud-mise
  # mise installs a rubygems plugin that runs `mise reshim` after every
  # gem install. There is no mise on the service PATH and no shims to
  # refresh, so bundle install fails with "No such file or directory -
  # mise" unless the plugin is removed.
  rm -f "$TOOLS/mise/installs/ruby/$ruby_v/lib/ruby/site_ruby/rubygems_plugin.rb"
  local t
  for t in ruby bundle gem erb; do
    ln -sfn "../mise/installs/ruby/$ruby_v/bin/$t" "$TOOLS/bin/$t"
  done
  # mise replaces bin/npm with a wrapper that runs `mise reshim` and
  # finds npm relative to the path it runs as, so npm and npx link
  # straight to npm's own entry points.
  local nd=$TOOLS/mise/installs/node/$node_v
  ln -sfn "$nd/bin/node" "$TOOLS/bin/node"
  ln -sfn "$nd/lib/node_modules/npm/bin/npm-cli.js" "$TOOLS/bin/npm"
  ln -sfn "$nd/lib/node_modules/npm/bin/npx-cli.js" "$TOOLS/bin/npx"
  chmod -R a+rX,go-w "$TOOLS"
  "$TOOLS/bin/ruby" -v
  "$TOOLS/bin/node" -v
  PATH=$TOOLS/bin:$PATH "$TOOLS/bin/npm" -v
  "$TOOLS/bin/bundle" -v
}

as_build() {
  # Builds run as ubicloud in the release, with a throwaway HOME so no
  # bundler or npm cache lands in /var/lib/ubicloud.
  runuser -u ubicloud -- env -i PATH="$TOOLS/bin:/usr/bin:/bin" HOME="$BUILD_HOME" "$@"
}

ensure_users() {
  getent group ubicloud >/dev/null || groupadd --system ubicloud
  id ubicloud >/dev/null 2>&1 ||
    useradd --system -g ubicloud -d "$STATE" -s /usr/sbin/nologin ubicloud
  id ubicloud-migrate >/dev/null 2>&1 ||
    useradd --system --user-group -G ubicloud -d /nonexistent -M -s /usr/sbin/nologin ubicloud-migrate
  install -d -m 0750 -o ubicloud -g ubicloud "$STATE"
  install -d -m 2770 -o ubicloud -g ubicloud "$STATE/var"
  install -d -m 0750 -o ubicloud -g ubicloud "$STATE/billing_rates.d"
}

stage_release() {
  local ver=$1 rev tmp
  rev=$(cat /art/src.rev)
  ensure_users
  install -d -m 0755 /opt/ubicloud "$RELEASES"
  tmp=$RELEASES/$ver.tmp
  rm -rf "$tmp"
  install -d -m 0755 -o ubicloud -g ubicloud "$tmp"
  tar -xzf /art/src.tgz -C "$tmp"
  chown -R ubicloud:ubicloud "$tmp"
  BUILD_HOME=$(mktemp -d)
  chown ubicloud:ubicloud "$BUILD_HOME"
  log "bundle install"
  (
    cd "$tmp"
    as_build bundle config set --local deployment true
    as_build bundle config set --local path vendor/bundle
    as_build bundle config set --local without 'test:rubocop:aws_kms:gcp_kms:aws_rds_iam:gcp_cloudsql_iam'
    as_build bundle install --jobs 4 --quiet
    log "npm ci and npm run prod"
    as_build npm ci --no-audit --no-fund --loglevel=error >/dev/null
    as_build npm run prod >/dev/null
    rm -rf node_modules
  )
  rm -rf "$BUILD_HOME"
  rm -rf "${tmp:?}/var"
  ln -s "$STATE/var" "$tmp/var"
  printf 'version=%s\nrev=%s\nbuilt=%s\n' "$ver" "$rev" "$(date -u +%FT%TZ)" >"$tmp/.ubicloud-release"
  printf "GIT_REV='%s'\n" "$rev" >"$tmp/.release-env"
  chown -R -h root:root "$tmp"
  chmod -R a+rX,go-w "$tmp"
  chmod 0644 "$tmp/.ubicloud-release" "$tmp/.release-env"
  mv -T "$tmp" "$RELEASES/$ver"
  ln -sfn "releases/$ver" /opt/ubicloud/current
  runuser -u ubicloud -- env -i PATH="$TOOLS/bin:/usr/bin:/bin" HOME="$STATE" \
    sh -c 'cd /opt/ubicloud/current && bundle check' >/dev/null

  stage_database
  stage_env
  log "migrate as ubicloud-migrate"
  service_env_run ubicloud-migrate bin/rake-task-runner migrate "" 0 >/dev/null
  stage_units
  systemctl enable ubicloud.target
}

psql_admin() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }

stage_database() {
  local conf=/etc/postgresql/16/main hba
  systemctl start postgresql@16-main
  psql_admin <<'SQL'
DO $$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ubicloud') THEN
    CREATE ROLE ubicloud LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ubicloud_password') THEN
    CREATE ROLE ubicloud_password LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END$$;
SQL
  if ! runuser -u postgres -- psql -XtAc "SELECT 1 FROM pg_database WHERE datname = 'ubicloud'" | grep -q 1; then
    runuser -u postgres -- createdb -O ubicloud ubicloud
  fi
  psql_admin -d ubicloud -c 'CREATE EXTENSION IF NOT EXISTS citext' \
    -c 'CREATE EXTENSION IF NOT EXISTS btree_gist' -c 'ALTER SCHEMA public OWNER TO ubicloud'

  cat >>"$conf/pg_ident.conf" <<'EOF'
ubicloud ubicloud ubicloud
ubicloud ubicloud-migrate ubicloud
ubicloud ubicloud-migrate ubicloud_password
ubicloud postgres postgres
EOF
  hba=$(mktemp)
  cat >"$hba" <<'EOF'
# BEGIN ubicloud
local ubicloud postgres peer
local ubicloud ubicloud,ubicloud_password peer map=ubicloud
local ubicloud all reject
host ubicloud all 127.0.0.1/32 reject
host ubicloud all ::1/128 reject
# END ubicloud
EOF
  cat "$conf/pg_hba.conf" >>"$hba"
  install -m 0640 -o postgres -g postgres "$hba" "$conf/pg_hba.conf"
  rm -f "$hba"
  systemctl reload postgresql@16-main
}

stage_env() {
  install -d -m 0755 /etc/ubicloud
  [[ -e /etc/ubicloud/env ]] && return 0
  local f
  f=$(mktemp)
  {
    echo "RACK_ENV='production'"
    echo "CLOVER_DATABASE_URL='postgres:///ubicloud?user=ubicloud'"
    echo "CLOVER_SESSION_SECRET='$(head -c 64 /dev/urandom | base64 -w0)'"
    echo "CLOVER_COLUMN_ENCRYPTION_KEY='$(head -c 32 /dev/urandom | base64 -w0)'"
    echo "CLOVER_RUNTIME_TOKEN_SECRET='$(head -c 64 /dev/urandom | base64 -w0)'"
    echo "BASE_URL='http://localhost:3000'"
    echo "ADMIN_URL='http://admin.localhost:3000'"
    echo "BIND='127.0.0.1'"
    echo "PORT='3000'"
    echo "DB_POOL_WEB='16'"
    echo "MAIL_DRIVER='logger'"
    echo "MAIL_FROM='ops@example.test'"
    echo "BOOT_IMAGE_SOURCE='public'"
    echo "DELETED_RECORD_DROP_UNARCHIVED='true'"
    echo "ALLOW_UNSPREAD_SERVERS='true'"
    echo "BILLING_RATES_EXTRA_DIR='$STATE/billing_rates.d'"
  } >"$f"
  install -m 0600 -o root -g root "$f" /etc/ubicloud/env
  rm -f "$f"
}

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
    -p WorkingDirectory=/opt/ubicloud/current \
    --setenv=PATH="$TOOLS/bin:/usr/bin:/bin" --setenv=HOME="$STATE" \
    "$TOOLS/bin/ruby" "$@"
}

case ${1:-} in
  tools) stage_tools ;;
  release) stage_release "${2:?version}" ;;
  units) stage_units ;;
  account)
    service_env_run ubicloud bin/byoh-account create --email "${2:?email}" --password-stdin
    ;;
  as-service)
    shift
    service_env_run ubicloud "$@"
    ;;
  *)
    echo "usage: fixture.sh tools|release VERSION|units|account EMAIL|as-service ARGS…" >&2
    exit 2
    ;;
esac
