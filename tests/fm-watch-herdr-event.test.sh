#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/bin/fm-watch-events-lib.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

capability_calls=0

fm_backend_events_capable() {
  capability_calls=$((capability_calls + 1))
  [ "$1" = herdr ] || fail "event capability used the wrong backend"
  [ "$2" = named-session ] || fail "event capability used the wrong session"
}

fm_backend_wait_transition() {
  [ "$1" = herdr ] || fail "event wait used the wrong backend"
  [ "$2" = named-session ] || fail "event wait used the wrong session"
  [ "$4" = state-dir ] || fail "event wait used the wrong state"
  [ "$5" = named-session:pane-1 ] || fail "event wait used the wrong target"
  printf 'pane-1\tworkspace-1\t\tblocked\tclaude'
}

fm_watch_herdr_events_capable named-session || fail "initial event capability probe failed"
out=$(fm_watch_wait_herdr_transition state-dir 3 named-session:pane-1)
[ "$out" = $'pane-1\tworkspace-1\t\tblocked\tclaude' ] \
  || fail "watch event helper returned '$out'"
[ "$capability_calls" -eq 1 ] || fail "event capability was not memoized per session"
out=$(fm_watch_wait_herdr_transition state-dir 3 named-session:pane-1)
[ "$out" = $'pane-1\tworkspace-1\t\tblocked\tclaude' ] \
  || fail "memoized watch event helper returned '$out'"
[ "$capability_calls" -eq 1 ] || fail "memoized event capability was probed twice"
printf 'PASS: watch event helper routes explicit Herdr transitions\n'
