#!/usr/bin/env bash
# ==============================================================
#  user-data for the control plane instance (ubi-byoh-ctrl)
# ==============================================================
#
# Runs ONCE via cloud-init on first boot. Keeps things minimal —
# just enough prerequisites so the operator can `git clone` + run
# scripts/byoh/bootstrap-ctrl-plane.sh to finish setup.
#
# Everything heavy (Ruby 4.0.2 via mise, Postgres 16, bundle install,
# npm run prod, migrations) lives in bootstrap-ctrl-plane.sh which
# the operator runs manually after SSH-ing in. That keeps the
# cloud-init path short and debuggable.
set -eu
exec > /var/log/user-data.log 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git tmux curl jq unzip

# Set a helpful MOTD so the operator knows what to do next
cat > /etc/update-motd.d/90-byoh <<'MOTD'
#!/bin/bash
cat <<BANNER

  ██    ██ ██████  ██  ██████ ██       ██████  ██    ██ ██████
  ██    ██ ██   ██ ██ ██      ██      ██    ██ ██    ██ ██   ██
  ██    ██ ██████  ██ ██      ██      ██    ██ ██    ██ ██   ██
  ██    ██ ██   ██ ██ ██      ██      ██    ██ ██    ██ ██   ██
   ██████  ██████  ██  ██████ ███████  ██████   ██████  ██████

  BYOH control plane host.

  To finish setting up Ubicloud:
    git clone <repo-url> ubicloud
    cd ubicloud && git checkout byoh-driver
    ./scripts/byoh/bootstrap-ctrl-plane.sh
    follow docs/byoh/QUICKSTART.md

  Web UI will be at http://$(curl -s https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}'):3000 after bootstrap.

BANNER
MOTD
chmod +x /etc/update-motd.d/90-byoh

touch /var/log/user-data.done
