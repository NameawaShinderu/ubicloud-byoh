#!/bin/bash
# Runs the `ubicloud-host storage-disk` cases (storage-disk-cases.sh) in
# one throwaway ubi-m4-sd container (ubuntu:24.04, ubi-test-net, --rm, no
# ports). The cases use PATH shims (storage-disk-shim) and per-case
# fixture roots inside the container, so no real disk is touched and no
# file lands in the worktree.
#
#   storage-disk-fixtures.sh
set -euo pipefail
# shellcheck source=scripts/byoh/test/m4-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/m4-lib.sh"
trap cleanup EXIT

name=$PREFIX-sd
echo "$name" >>"$STATE/created"
docker run --rm --name "$name" --network "$NET" \
  -v "$WT/scripts/byoh:/b:ro" docker.io/library/ubuntu:24.04 \
  bash /b/test/storage-disk-cases.sh /b/host/ubicloud-host /b/test/storage-disk-shim ||
  fail "storage-disk cases failed"
say "PASS storage-disk fixtures"
