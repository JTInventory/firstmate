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

test_local_fleet_directories_are_ignored
