#!/usr/bin/env bash
# tests/fm-watch-session.test.sh - durable active watcher runner wrapper.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION="$ROOT/bin/fm-watch-session.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-session-tests)
trap fm_test_watch_cleanup_exit EXIT

test_status_reports_missing_session() {
  local dir state out status
  dir=$(make_case status-missing)
  state="$dir/state"
  out="$dir/status.out"
  status=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SESSION" --status > "$out" || status=$?
  [ "$status" -ne 0 ] || fail "status exited zero when no watcher session existed"
  grep -F 'watch-session: stopped' "$out" >/dev/null || fail "status did not report stopped"
  pass "watch-session status reports stopped for an empty home"
}

test_start_status_stop_are_home_scoped() {
  local dir state other other_state fakebin out start_pid other_pid lock_pid i
  dir=$(make_case home-scoped)
  state="$dir/state"
  other=$(make_case other-home)
  other_state="$other/state"
  fakebin="$dir/fakebin"
  out="$dir/session.out"

  PATH="$fakebin:$PATH" FM_HOME="$other" FM_STATE_OVERRIDE="$other_state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$other/watch-arm.out" &
  other_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ -s "$other_state/.watch.lock/pid" ] && [ -e "$other_state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$other_state/.watch.lock/pid" ] && [ -e "$other_state/.last-watcher-beat" ] || fail "other home watcher did not start"
  start_pid=$(cat "$other_state/.watch.lock/pid")

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$SESSION" --start > "$out" || fail "watch-session start failed: $(cat "$out")"
  grep -F 'watch-session: started' "$out" >/dev/null || fail "start did not report a started session"
  lock_pid=$(cat "$state/.watch-session.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || fail "session did not record its runner pid"
  kill -0 "$lock_pid" 2>/dev/null || fail "recorded session runner is not alive"

  : > "$out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SESSION" --status > "$out" || fail "status failed for running session"
  grep -F "watch-session: running pid=$lock_pid" "$out" >/dev/null || fail "status did not report the running session pid"

  : > "$out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SESSION" --stop > "$out" || fail "stop failed for running session"
  grep -F "watch-session: stopped pid=$lock_pid" "$out" >/dev/null || fail "stop did not report the stopped session pid"
  i=0
  while [ "$i" -lt 80 ] && kill -0 "$lock_pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$lock_pid" 2>/dev/null || fail "session runner remained alive after stop"

  kill -0 "$start_pid" 2>/dev/null || fail "stopping this home killed another home's watcher"
  kill "$other_pid" "$start_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
  pass "watch-session starts, reports, and stops only the current FM_HOME"
}

test_source_contains_no_broad_pkill() {
  ! grep -Eq 'pkill[[:space:]].*fm-watch|pkill[[:space:]]+-f' "$SESSION" || fail "watch-session uses broad pkill"
  pass "watch-session does not use broad pkill"
}

test_status_reports_missing_session
test_start_status_stop_are_home_scoped
test_source_contains_no_broad_pkill
