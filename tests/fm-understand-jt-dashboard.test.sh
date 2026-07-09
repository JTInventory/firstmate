#!/usr/bin/env bash
# Tests for the managed JT Understand Anything dashboard helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASHBOARD="$ROOT/bin/fm-understand-jt-dashboard"
TMP_ROOT=$(fm_test_tmproot fm-understand-jt-dashboard)

test_status_rejects_live_pid_without_recorded_identity() {
  local home run_dir pid out rc
  home="$TMP_ROOT/status-no-identity"
  run_dir="$home/state/jt-understand-dashboard"
  mkdir -p "$run_dir"
  ( sleep 30 ) &
  pid=$!
  printf '%s\n' "$pid" > "$run_dir/pid"
  printf '%s\n' 'Dashboard URL: http://127.0.0.1:5173/?token=status-token' > "$run_dir/dashboard.log"

  set +e
  out=$(FM_HOME="$home" "$DASHBOARD" status 2>&1)
  rc=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 1 "$rc" "dashboard status with unverified live pid"
  assert_contains "$out" '"state": "stale"' "unverified live pid should be stale"
  assert_not_contains "$out" '"state": "running"' "pid liveness alone must not report running"
  assert_not_contains "$out" 'status-token' "status output must redact dashboard token"
  pass "JT dashboard status rejects live pid without matching identity"
}

test_stop_does_not_kill_live_pid_without_recorded_identity() {
  local home run_dir pid out rc
  home="$TMP_ROOT/stop-no-identity"
  run_dir="$home/state/jt-understand-dashboard"
  mkdir -p "$run_dir"
  ( sleep 30 ) &
  pid=$!
  printf '%s\n' "$pid" > "$run_dir/pid"

  set +e
  out=$(FM_HOME="$home" "$DASHBOARD" stop 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dashboard stop with stale live pid"
  kill -0 "$pid" 2>/dev/null || fail "stop should not kill a pid without matching identity"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" '"state": "stopped"' "stop should clear stale pid and report stopped"
  pass "JT dashboard stop skips stale live pid without matching identity"
}

test_status_accepts_live_pid_with_matching_identity() {
  local home run_dir identity_file pid identity out rc
  home="$TMP_ROOT/status-matching-identity"
  run_dir="$home/state/jt-understand-dashboard"
  identity_file="$run_dir/pid.identity"
  mkdir -p "$run_dir"
  ( sleep 30 ) &
  pid=$!
  identity=$(ps -p "$pid" -o lstart= -o command= | head -n 1)
  printf '%s\n' "$pid" > "$run_dir/pid"
  printf '%s\n' "$identity" > "$identity_file"
  printf '%s\n' 'Dashboard URL: http://127.0.0.1:5173/?token=running-token' > "$run_dir/dashboard.log"

  set +e
  out=$(FM_HOME="$home" "$DASHBOARD" status 2>&1)
  rc=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 0 "$rc" "dashboard status with matching identity"
  assert_contains "$out" '"state": "running"' "matching identity should report running"
  assert_contains "$out" "\"pid\": $pid" "running status should include the pid"
  assert_not_contains "$out" 'running-token' "running status must redact dashboard token"
  pass "JT dashboard status accepts live pid with matching identity"
}

test_status_rejects_live_pid_with_mismatched_identity() {
  local home run_dir identity_file pid out rc
  home="$TMP_ROOT/status-mismatched-identity"
  run_dir="$home/state/jt-understand-dashboard"
  identity_file="$run_dir/pid.identity"
  mkdir -p "$run_dir"
  ( sleep 30 ) &
  pid=$!
  printf '%s\n' "$pid" > "$run_dir/pid"
  printf '%s\n' 'Mon Jan  1 00:00:00 2001 unrelated-process' > "$identity_file"

  set +e
  out=$(FM_HOME="$home" "$DASHBOARD" status 2>&1)
  rc=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 1 "$rc" "dashboard status with mismatched identity"
  assert_contains "$out" '"state": "stale"' "mismatched identity should be stale"
  assert_not_contains "$out" '"state": "running"' "mismatched identity must not report running"
  pass "JT dashboard status rejects mismatched process identity"
}

test_status_rejects_live_pid_without_recorded_identity
test_stop_does_not_kill_live_pid_without_recorded_identity
test_status_accepts_live_pid_with_matching_identity
test_status_rejects_live_pid_with_mismatched_identity
