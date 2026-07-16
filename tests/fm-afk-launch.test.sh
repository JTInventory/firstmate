#!/usr/bin/env bash
# JT-scoped AFK launch/return coverage. The launcher must put the daemon in a
# fresh session/process group so a harness reap of the launcher's group cannot
# kill away-mode supervision, and return must stop only that owned daemon.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCH="$ROOT/bin/fm-afk-launch.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-launch-tests)
AFK_TEST_PIDS=()

cleanup_afk_tests() {
  local pid
  for pid in "${AFK_TEST_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_afk_tests EXIT

make_fake_daemon() {
  local dir=$1 daemon="$1/fake-daemon.sh"
  cat > "$daemon" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:?FM_STATE_OVERRIDE unset}
mkdir -p "$state"
. "${FM_AFK_TEST_WAKE_LIB:?FM_AFK_TEST_WAKE_LIB unset}"
printf '%s\n' "$$" > "$state/.supervise-daemon.pid"
fm_pid_start "$$" > "$state/.supervise-daemon.pid-start"
fm_pid_identity "$$" > "$state/.supervise-daemon.pid-identity"
printf '%s\n' started > "$state/fake-daemon.started"
cleanup() {
  printf '%s\n' returned > "$state/fake-daemon.returned"
  rm -f "$state/.supervise-daemon.pid" "$state/.supervise-daemon.pid-start" \
    "$state/.supervise-daemon.pid-identity"
  exit 0
}
if [ "${FM_AFK_TEST_IGNORE_TERM:-0}" = 1 ]; then
  trap ':' TERM INT
else
  trap cleanup TERM INT
fi
while :; do sleep 0.1; done
SH
  chmod +x "$daemon"
  printf '%s\n' "$daemon"
}

wait_for_file() {
  local file=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$file" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

daemon_pid() { cat "$1/.supervise-daemon.pid" 2>/dev/null || true; }

test_afk_launch_detaches_from_harness_group() {
  local dir state daemon harness pid group_pid
  dir="$TMP_ROOT/detach"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")

  # The outer setsid shell is the harness-owned process group. It starts the
  # launcher and then waits, so killing that group simulates harness reap.
  # shellcheck disable=SC2016 # the inner shell must expand its own positional args
  FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" setsid bash -c '
    "$1" start
    printf "%s\n" "$$" > "$2/harness.pid"
    while :; do sleep 0.1; done
  ' _ "$LAUNCH" "$state" \
    >"$dir/harness.out" 2>"$dir/harness.err" &
  harness=$!
  AFK_TEST_PIDS+=("$harness")
  wait_for_file "$state/fake-daemon.started" 80 || {
    kill "$harness" 2>/dev/null || true; wait "$harness" 2>/dev/null || true
    fail "detached AFK launcher did not start the daemon: $(cat "$dir/harness.err" 2>/dev/null || true)"
  }
  pid=$(daemon_pid "$state")
  [ -n "$pid" ] || fail "detached AFK launcher did not leave a daemon pid"
  AFK_TEST_PIDS+=("$pid")
  wait_for_file "$state/harness.pid" 80 || fail "harness did not publish its process-group identity"
  pid=$(daemon_pid "$state")
  group_pid=$(cat "$state/harness.pid")
  kill -TERM -- "-$group_pid" 2>/dev/null || fail "could not reap the harness process group"
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || fail "daemon died with the harness process group"

  FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null \
    || fail "AFK return could not stop the detached daemon"
  wait_for_file "$state/fake-daemon.returned" 50 || fail "AFK return did not stop the owned daemon"
  wait "$harness" 2>/dev/null || true
  pass "AFK daemon survives harness process-group reap and stops on return"
}

test_afk_launch_return_clears_flag_and_is_idempotent() {
  local dir state daemon pid out
  dir="$TMP_ROOT/return"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" start) \
    || fail "AFK launch failed: $out"
  [ -e "$state/.afk" ] || fail "AFK launch did not set the durable away flag"
  pid=$(daemon_pid "$state")
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    fail "AFK launch did not leave a live daemon"
  fi
  AFK_TEST_PIDS+=("$pid")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" start) \
    || fail "idempotent AFK launch failed: $out"
  printf '%s' "$out" | grep -F 'already running' >/dev/null \
    || fail "idempotent AFK launch did not report the existing daemon"
  FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null \
    || fail "AFK return failed"
  wait_for_file "$state/fake-daemon.returned" 50 || fail "AFK return marker missing"
  [ ! -e "$state/.afk" ] || fail "AFK return left the durable away flag"
  pass "AFK launch is idempotent and return clears the away flag"
}

test_afk_return_keeps_flag_on_identity_failure() {
  local dir state daemon pid identity out
  dir="$TMP_ROOT/identity-failure"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" start) \
    || fail "AFK launch failed: $out"
  pid=$(daemon_pid "$state")
  AFK_TEST_PIDS+=("$pid")
  printf '%s\n' wrong-identity > "$state/.supervise-daemon.pid-identity"
  if FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null 2>&1; then
    fail "AFK return succeeded with an unverified daemon identity"
  fi
  [ -e "$state/.afk" ] || fail "identity failure cleared the durable away flag"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$pid")
  printf '%s\n' "$identity" > "$state/.supervise-daemon.pid-identity"
  FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null \
    || fail "AFK return failed after restoring the pinned identity"
  wait_for_file "$state/fake-daemon.returned" 50 || fail "identity recovery did not stop the daemon"
  [ ! -e "$state/.afk" ] || fail "successful identity recovery left the durable away flag"
  pass "AFK return retains the away flag when identity verification fails"
}

test_afk_return_keeps_flag_on_missing_record_for_live_daemon() {
  local dir state daemon pid out
  dir="$TMP_ROOT/missing-record-live"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" start) \
    || fail "AFK launch failed: $out"
  pid=$(daemon_pid "$state")
  AFK_TEST_PIDS+=("$pid")
  rm -f "$state/.supervise-daemon.pid"
  if FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null 2>&1; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "AFK return succeeded without a live daemon record"
  fi
  [ -e "$state/.afk" ] || fail "missing live daemon record cleared the durable away flag"
  kill -KILL "$pid" 2>/dev/null || true
  pass "AFK return retains the away flag when a live daemon record is missing"
}

test_afk_return_keeps_flag_on_stale_record_for_live_daemon() {
  local dir state daemon pid out
  dir="$TMP_ROOT/stale-record-live"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" start) \
    || fail "AFK launch failed: $out"
  pid=$(daemon_pid "$state")
  AFK_TEST_PIDS+=("$pid")
  printf '%s\n' 999999999 > "$state/.supervise-daemon.pid"
  if FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null 2>&1; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "AFK return succeeded with a stale daemon record"
  fi
  [ -e "$state/.afk" ] || fail "stale live daemon record cleared the durable away flag"
  kill -KILL "$pid" 2>/dev/null || true
  pass "AFK return retains the away flag when a stale daemon record remains live"
}

test_afk_status_keeps_unverified_daemon_visible() {
  local dir state daemon pid out
  dir="$TMP_ROOT/status-stale-record-live"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" start) \
    || fail "AFK launch failed: $out"
  pid=$(daemon_pid "$state")
  AFK_TEST_PIDS+=("$pid")
  rm -f "$state/.afk"
  printf '%s\n' 999999999 > "$state/.supervise-daemon.pid"
  if out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" status 2>&1); then
    kill -KILL "$pid" 2>/dev/null || true
    fail "AFK status succeeded with an unverified daemon record"
  fi
  printf '%s' "$out" | grep -F 'inactive daemon=not-verified' >/dev/null \
    || fail "AFK status did not expose the unverified daemon: $out"
  printf '%s' "$out" | grep -F 'inactive daemon=stopped' >/dev/null \
    && fail "AFK status hid the live daemon as stopped"
  kill -KILL "$pid" 2>/dev/null || true
  pass "AFK status keeps a live unverified daemon visible"
}

test_afk_return_clears_flag_after_confirmed_missing_daemon() {
  local dir state daemon
  dir="$TMP_ROOT/missing-record-gone"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  date '+%s' > "$state/.afk"
  FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null \
    || fail "AFK return rejected a confirmed-absent daemon"
  [ ! -e "$state/.afk" ] || fail "confirmed-absent daemon left the durable away flag"
  pass "AFK return clears the away flag after confirmed daemon absence"
}

test_afk_return_keeps_flag_on_term_failure() {
  local dir state daemon pid out
  dir="$TMP_ROOT/term-failure"; state="$dir/state"; mkdir -p "$state"
  daemon=$(make_fake_daemon "$dir")
  out=$(FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" FM_AFK_TEST_IGNORE_TERM=1 "$LAUNCH" start) \
    || fail "AFK launch failed: $out"
  pid=$(daemon_pid "$state")
  AFK_TEST_PIDS+=("$pid")
  if FM_STATE_OVERRIDE="$state" FM_AFK_DAEMON_PATH="$daemon" \
    FM_AFK_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" "$LAUNCH" stop >/dev/null 2>&1; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "AFK return succeeded after TERM was ignored"
  fi
  [ -e "$state/.afk" ] || fail "TERM failure cleared the durable away flag"
  kill -KILL "$pid" 2>/dev/null || true
  pass "AFK return retains the away flag when TERM does not stop the daemon"
}

test_afk_launch_detaches_from_harness_group
test_afk_launch_return_clears_flag_and_is_idempotent
test_afk_return_keeps_flag_on_identity_failure
test_afk_return_keeps_flag_on_missing_record_for_live_daemon
test_afk_return_keeps_flag_on_stale_record_for_live_daemon
test_afk_status_keeps_unverified_daemon_visible
test_afk_return_clears_flag_after_confirmed_missing_daemon
test_afk_return_keeps_flag_on_term_failure

echo "all fm-afk-launch tests passed"
