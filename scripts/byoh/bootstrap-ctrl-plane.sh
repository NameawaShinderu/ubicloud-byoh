#!/usr/bin/env bash
# Compatibility shim. The development bootstrap is now
# scripts/byoh/bootstrap-dev-ctrl-plane.sh, and a production control
# plane is installed with scripts/byoh/install.sh. Older docs, terraform
# user data and `curl ... | bash` one-liners still name this file, so it
# warns and runs the development script with the same arguments and
# environment.
#
# The target is, in this order:
#   1. bootstrap-dev-ctrl-plane.sh next to this file, when this file was
#      run from disk;
#   2. ${UBI_REPO_DIR:-$HOME/ubicloud}/scripts/byoh/bootstrap-dev-ctrl-plane.sh,
#      which covers `curl ... | bash` and `cat ... | bash` (the
#      development script never cloned the repository; neither does this);
#   3. otherwise it exits 1: with the clone step when that directory is
#      missing, and with the pull step when it holds a checkout from
#      before the rename (such as a control plane kept at an older
#      revision on purpose).
#
# Everything is in main, which runs only after bash has read the whole
# file, so a truncated download runs nothing.

# Empty when bash reads the script from a pipe. Inside a function it
# would be "main" instead, which a file of that name could match.
SHIM_SOURCE=${BASH_SOURCE[0]:-}

main() {
  set -euo pipefail
  local here="" target=""
  echo "WARNING: scripts/byoh/bootstrap-ctrl-plane.sh is renamed to scripts/byoh/bootstrap-dev-ctrl-plane.sh," >&2
  echo "WARNING: which sets up a DEVELOPMENT/LAB control plane only. For production use scripts/byoh/install.sh." >&2

  if [[ -n $SHIM_SOURCE && -f $SHIM_SOURCE ]]; then
    here=$(cd "$(dirname "$SHIM_SOURCE")" && pwd)
    if [[ -f $here/bootstrap-dev-ctrl-plane.sh ]]; then
      target=$here/bootstrap-dev-ctrl-plane.sh
    fi
  fi
  if [[ -z $target ]]; then
    local repo=${UBI_REPO_DIR:-$HOME/ubicloud}
    if [[ -f $repo/scripts/byoh/bootstrap-dev-ctrl-plane.sh ]]; then
      target=$repo/scripts/byoh/bootstrap-dev-ctrl-plane.sh
    elif [[ -f $repo/scripts/byoh/bootstrap-ctrl-plane.sh ]]; then
      echo "ERROR: the checkout at $repo predates the rename: it has no scripts/byoh/bootstrap-dev-ctrl-plane.sh." >&2
      echo "  Either update it and run this again:" >&2
      echo "    git -C $repo pull" >&2
      echo "  or run the bootstrap of that revision from disk, which leaves it at its revision:" >&2
      echo "    bash $repo/scripts/byoh/bootstrap-ctrl-plane.sh" >&2
      exit 1
    elif [[ -e $repo ]]; then
      echo "ERROR: $repo is not an ubicloud checkout (no scripts/byoh/bootstrap-dev-ctrl-plane.sh)." >&2
      echo "  Set UBI_REPO_DIR to the checkout." >&2
      exit 1
    else
      echo "ERROR: no ubicloud checkout at $repo." >&2
      echo "  Clone it first (or set UBI_REPO_DIR to where it is):" >&2
      echo "    git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git $repo" >&2
      exit 1
    fi
  fi
  echo "WARNING: running $target" >&2

  # Read from a pipe, this script's stdin is the pipe itself; the
  # development script gets /dev/null instead (sudo asks on the tty).
  if [[ -t 0 || -n $here ]]; then
    exec bash "$target" "$@"
  fi
  exec bash "$target" "$@" </dev/null
}

main "$@"
