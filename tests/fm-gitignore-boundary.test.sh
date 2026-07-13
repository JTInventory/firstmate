#!/usr/bin/env bash
# Behavior guard for the documented local fleet directory boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_local_fleet_directories_are_ignored() {
  local path
  for path in config/foo.local reports/x.md backups/y.md; do
    git -C "$ROOT" check-ignore -q -- "$path" \
      || fail "$path must be ignored as local fleet material"
  done
  pass "local fleet directories are ignored"
}

test_nested_shared_surfaces_remain_trackable() {
  local path
  for path in docs/examples/config/foo.local docs/examples/reports/x.md tests/backups/y.md; do
    git -C "$ROOT" check-ignore -q --no-index -- "$path" \
      && fail "$path must remain trackable as a shared surface"
  done
  pass "nested shared surfaces remain trackable"
}

test_local_fleet_directories_are_ignored
test_nested_shared_surfaces_remain_trackable
