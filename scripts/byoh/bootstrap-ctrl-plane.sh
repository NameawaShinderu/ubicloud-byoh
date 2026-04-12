#!/usr/bin/env bash
# ====================================================================
#  bootstrap-ctrl-plane.sh — idempotent Ubicloud control plane setup
# ====================================================================
#
# Bootstraps a fresh Ubuntu 24.04 LTS host into a full Ubicloud control
# plane: Postgres + Ruby 4.0.2 + Node 24 + clover (Roda/Puma) + respirate
# dispatcher + the bin/register-byoh-host CLI. Every step is idempotent —
# re-running the script skips already-completed phases via marker files
# under ~/.ubi-bootstrap/.
#
# This captures every manual command I ran on the AWS Mumbai test box
# during Phase 1-7 validation. If you want a fresh ctrl plane on OVH, on
# your Proxmox, or on another AWS region, run this script and it should
# produce a byte-identical setup modulo secrets and DB state.
#
# Tested against: Ubuntu 24.04.2 LTS (Noble Numbat) on AWS t3.medium
# and m5d.metal. Not tested on Debian/Rocky/Alma/Fedora — they'd likely
# need apt vs dnf porting.
#
# Usage:
#   ./scripts/byoh/bootstrap-ctrl-plane.sh
#
# Env overrides:
#   UBI_REPO_DIR        default: $HOME/ubicloud
#   UBI_RUBY_VERSION    default: 4.0.2
#   UBI_NODE_VERSION    default: 24.12.0
#   UBI_DB_NAME         default: clover_test
#   UBI_RACK_ENV        default: development
#   UBI_START_SERVICES  default: 1 (set to 0 to skip puma/respirate)
#
set -euo pipefail

# --- config ---------------------------------------------------------
UBI_REPO_DIR="${UBI_REPO_DIR:-$HOME/ubicloud}"
UBI_RUBY_VERSION="${UBI_RUBY_VERSION:-4.0.2}"
UBI_NODE_VERSION="${UBI_NODE_VERSION:-24.12.0}"
UBI_DB_NAME="${UBI_DB_NAME:-clover_test}"
UBI_RACK_ENV="${UBI_RACK_ENV:-development}"
UBI_START_SERVICES="${UBI_START_SERVICES:-1}"

MARKERS_DIR="$HOME/.ubi-bootstrap"
mkdir -p "$MARKERS_DIR"

RUBY_BIN="$HOME/.local/share/mise/installs/ruby/$UBI_RUBY_VERSION/bin"
NODE_BIN="$HOME/.local/share/mise/installs/node/$UBI_NODE_VERSION/bin"
MISE_BIN="$HOME/.local/bin"
PATH="$MISE_BIN:$RUBY_BIN:$NODE_BIN:$PATH"
export PATH

# --- helpers --------------------------------------------------------
step() { echo ""; echo "━━━━━ $* ━━━━━"; }
done_marker() { touch "$MARKERS_DIR/$1"; }
is_done() { [ -f "$MARKERS_DIR/$1" ]; }
skip_msg() { echo "  [skip] $1 already done (marker: $MARKERS_DIR/$2)"; }

assert_ubuntu_2404() {
  if ! grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
    echo "ERROR: This script requires Ubuntu 24.04 LTS (Noble)." >&2
    echo "  Detected: $(grep PRETTY_NAME /etc/os-release 2>/dev/null || echo unknown)" >&2
    exit 1
  fi
}

# --- Step 1: OS check + apt packages --------------------------------
step "1. OS check + apt packages"
if is_done apt-packages; then
  skip_msg "apt packages" apt-packages
else
  assert_ubuntu_2404
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update
  sudo apt-get install -y \
    git build-essential curl tmux jq \
    libpq-dev libyaml-dev libssl-dev libffi-dev libreadline-dev \
    zlib1g-dev libncurses-dev libedit-dev libxml2-dev libxslt1-dev \
    pkg-config \
    postgresql-16 postgresql-client-16 postgresql-contrib-16
  done_marker apt-packages
fi

# --- Step 2: mise + ruby + node -------------------------------------
step "2. mise + Ruby $UBI_RUBY_VERSION + Node $UBI_NODE_VERSION"
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh
fi
if is_done ruby-$UBI_RUBY_VERSION; then
  skip_msg "ruby $UBI_RUBY_VERSION" ruby-$UBI_RUBY_VERSION
else
  mise install ruby@$UBI_RUBY_VERSION
  done_marker ruby-$UBI_RUBY_VERSION
fi
if is_done node-$UBI_NODE_VERSION; then
  skip_msg "node $UBI_NODE_VERSION" node-$UBI_NODE_VERSION
else
  mise install node@$UBI_NODE_VERSION
  done_marker node-$UBI_NODE_VERSION
fi

# Sanity check the right binaries are on PATH
RUBY_ACTUAL=$("$RUBY_BIN/ruby" --version 2>&1)
NODE_ACTUAL=$("$NODE_BIN/node" --version 2>&1)
echo "  ruby: $RUBY_ACTUAL"
echo "  node: $NODE_ACTUAL"

# --- Step 3: Postgres users + DB ------------------------------------
step "3. Postgres users + $UBI_DB_NAME database"
if is_done postgres-setup; then
  skip_msg "postgres setup" postgres-setup
else
  sudo systemctl enable --now postgresql
  sudo -u postgres createuser clover --superuser 2>&1 | grep -v "already exists" || true
  sudo -u postgres createuser clover_password 2>&1 | grep -v "already exists" || true
  sudo -u postgres createdb -O clover "$UBI_DB_NAME" 2>&1 | grep -v "already exists" || true
  sudo -u postgres psql -d "$UBI_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citext; CREATE EXTENSION IF NOT EXISTS btree_gist;" > /dev/null
  sudo -u postgres psql -d "$UBI_DB_NAME" -c "GRANT ALL ON DATABASE $UBI_DB_NAME TO clover_password;" > /dev/null
  done_marker postgres-setup
fi

# --- Step 4: pg_hba.conf auth fix (LOCAL ONLY trust) ----------------
# The default Ubuntu postgres uses peer auth on the Unix socket, which
# requires OS user == DB user. We switch local auth to `trust` so the
# ubuntu user can connect as `clover`. This is safe ONLY on a single-user
# test env; never do this on a multi-tenant production host.
step "4. pg_hba.conf → trust local (test env only)"
if is_done pg-hba-trust; then
  skip_msg "pg_hba trust" pg-hba-trust
else
  PG_HBA=/etc/postgresql/16/main/pg_hba.conf
  if [ ! -f "$PG_HBA.byoh-original" ]; then
    sudo cp "$PG_HBA" "$PG_HBA.byoh-original"
  fi
  sudo sed -i \
    -e 's/^local\s\+all\s\+postgres\s\+.*/local   all             postgres                                trust/' \
    -e 's/^local\s\+all\s\+all\s\+.*/local   all             all                                     trust/' \
    -e 's/^host\s\+all\s\+all\s\+127.0.0.1\/32\s\+.*/host    all             all             127.0.0.1\/32            trust/' \
    -e 's/^host\s\+all\s\+all\s\+::1\/128\s\+.*/host    all             all             ::1\/128                 trust/' \
    "$PG_HBA"
  sudo systemctl reload postgresql
  done_marker pg-hba-trust
fi

# --- Step 5: verify ubicloud repo is present ------------------------
step "5. ubicloud repo at $UBI_REPO_DIR"
if [ ! -d "$UBI_REPO_DIR/.git" ] && [ ! -f "$UBI_REPO_DIR/Gemfile" ]; then
  echo "ERROR: $UBI_REPO_DIR does not contain a ubicloud checkout." >&2
  echo "  Either git clone the repo there, or scp a tarball + extract first." >&2
  exit 1
fi
cd "$UBI_REPO_DIR"
echo "  repo: $(git rev-parse --short HEAD 2>/dev/null || echo '(no git — extracted tarball)')"

# --- Step 6: bundle install -----------------------------------------
step "6. bundle install (gems for Ruby $UBI_RUBY_VERSION)"
if is_done bundle-install && [ -d vendor/bundle ] || bundle check > /dev/null 2>&1; then
  skip_msg "bundle install" bundle-install
else
  bundle config set --local deployment false
  bundle config set --local without 'production'
  bundle install --jobs 4
  done_marker bundle-install
fi

# --- Step 7: npm install + asset build ------------------------------
step "7. npm install + npm run prod (tailwind css/js)"
if is_done npm-assets && [ -s assets/css/app.css ]; then
  skip_msg "npm assets" npm-assets
else
  # Clean any previous partial state
  rm -rf node_modules
  npm install --no-audit --no-fund
  npm run prod
  [ -s assets/css/app.css ] || { echo "ERROR: assets/css/app.css not produced"; exit 1; }
  done_marker npm-assets
fi

# --- Step 8: .env.rb (with random secrets) --------------------------
step "8. .env.rb"
if [ -f .env.rb ]; then
  echo "  [skip] .env.rb already exists; not overwriting. Delete it manually if you want fresh secrets."
else
  SESSION_SECRET=$(openssl rand -base64 64 | tr -d '\n')
  RUNTIME_SECRET=$(openssl rand -base64 64 | tr -d '\n')
  ENC_KEY=$(openssl rand -base64 32)
  cat > .env.rb <<ENVRB
# frozen_string_literal: true
# Generated by bootstrap-ctrl-plane.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Secrets are random — never committed, never shared across environments.
ENV["RACK_ENV"] ||= "$UBI_RACK_ENV"
ENV["CLOVER_SESSION_SECRET"] ||= "$SESSION_SECRET"
ENV["CLOVER_DATABASE_URL"] ||= "postgres:///$UBI_DB_NAME?user=clover"
ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "$ENC_KEY"
ENV["CLOVER_RUNTIME_TOKEN_SECRET"] ||= "$RUNTIME_SECRET"
ENVRB
  chmod 600 .env.rb
  echo "  .env.rb created with random secrets (chmod 600)"
fi

# --- Step 9: run migrations -----------------------------------------
step "9. database migrations"
if is_done migrations; then
  skip_msg "migrations" migrations
else
  RACK_ENV=$UBI_RACK_ENV bundle exec bin/rake-task-runner migrate "" 0 2>&1 | tail -5
  done_marker migrations
fi

# --- Step 10: refresh sequel caches ---------------------------------
step "10. refresh sequel caches"
if is_done caches-refreshed; then
  skip_msg "sequel caches" caches-refreshed
else
  RACK_ENV=$UBI_RACK_ENV FORCE_AUTOLOAD=1 bundle exec bin/rake-task-runner refresh_sequel_caches 2>&1 | tail -3 || true
  done_marker caches-refreshed
fi

# --- Step 11: start services (puma + respirate in tmux) ------------
if [ "$UBI_START_SERVICES" = "1" ]; then
  step "11. start puma + respirate in tmux sessions"
  command -v tmux >/dev/null || { echo "ERROR: tmux not installed (should have been in step 1)"; exit 1; }

  # Puma
  if tmux has-session -t puma 2>/dev/null; then
    echo "  [skip] tmux session 'puma' already running (attach with: tmux attach -t puma)"
  else
    tmux new-session -d -s puma "cd $UBI_REPO_DIR && export PATH=$RUBY_BIN:\$PATH && RACK_ENV=$UBI_RACK_ENV bundle exec puma -C puma_config.rb > /tmp/puma.log 2> /tmp/puma.err"
    echo "  tmux session 'puma' started → http://<host>:3000  (logs: /tmp/puma.log, /tmp/puma.err)"
  fi

  # Respirate dispatcher
  if tmux has-session -t respirate 2>/dev/null; then
    echo "  [skip] tmux session 'respirate' already running (attach with: tmux attach -t respirate)"
  else
    tmux new-session -d -s respirate "cd $UBI_REPO_DIR && export PATH=$RUBY_BIN:\$PATH && RACK_ENV=$UBI_RACK_ENV bundle exec bin/respirate > /tmp/respirate.log 2> /tmp/respirate.err"
    echo "  tmux session 'respirate' started  (logs: /tmp/respirate.log, /tmp/respirate.err)"
  fi
else
  step "11. services skipped (UBI_START_SERVICES=$UBI_START_SERVICES)"
  echo "  To start manually:"
  echo "    tmux new-session -d -s puma      'cd $UBI_REPO_DIR && bundle exec puma -C puma_config.rb'"
  echo "    tmux new-session -d -s respirate 'cd $UBI_REPO_DIR && bundle exec bin/respirate'"
fi

step "DONE"
echo ""
echo "Ubicloud control plane is ready."
echo ""
echo "Next steps:"
echo "  1. Sign up via the web UI:     http://<this-host>:3000/create-account"
echo "  2. Register a BYOH data plane: bundle exec bin/register-byoh-host --help"
echo "  3. Watch strand progress:       tmux attach -t respirate"
echo ""
echo "Marker files: $MARKERS_DIR/"
echo "  rm -rf $MARKERS_DIR  # to force a full re-run"
