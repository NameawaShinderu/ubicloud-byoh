#!/bin/bash
# UNSUPPORTED: these scripts predate M2 and are broken (no BYOH
# location, dual-homed data plane, unscoped accepts_slices, VMID-based
# deletes). Use docs/byoh/SETUP_PROXMOX.md instead.
if [ "${BYOH_RUN_UNSUPPORTED_DEPLOY_SCRIPTS:-}" != "1" ]; then
  echo "$0 is unsupported; follow docs/byoh/SETUP_PROXMOX.md" >&2
  exit 1
fi
# Run on: ctrl plane VM (ubuntu@10.98.1.10)
# Purpose: Install Ruby/Postgres/Node, clone repo, start Puma + respirate
# Log: /tmp/ubicloud-deploy-03.log

set -e
exec > >(tee -a /tmp/ubicloud-deploy-03.log) 2>&1
echo "===== BOOTSTRAP CTRL PLANE $(date) ====="

REPO_URL=${REPO_URL:-https://github.com/NameawaShinderu/ubicloud-byoh.git}
REPO_BRANCH=${REPO_BRANCH:-byoh-driver}
BOOTSTRAP_URL=${BOOTSTRAP_URL:-https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh}

if [[ ! -d ~/ubicloud ]]; then
  echo "--- Cloning Ubicloud repo ---"
  git clone --branch $REPO_BRANCH $REPO_URL ~/ubicloud
fi
echo "OK repo"

echo "--- Running bootstrap (15-20 min) ---"
curl -sSL $BOOTSTRAP_URL | bash

echo "--- Verify services ---"
sleep 5
curl -sI http://localhost:3000/ | head -1 | grep -q "302 Found" \
  || { echo "ERR: Puma not responding"; exit 1; }
tmux ls | grep -q puma || { echo "ERR: puma tmux missing"; exit 1; }
tmux ls | grep -q respirate || { echo "ERR: respirate tmux missing"; exit 1; }
echo "OK services running"

echo
echo "===== BOOTSTRAP COMPLETE ====="
echo "Next: bash /tmp/04-register-host.sh"
