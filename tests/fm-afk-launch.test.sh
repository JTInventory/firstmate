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
trap cleanup TERM INT
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

test_afk_launch_detaches_from_harness_group
test_afk_launch_return_clears_flag_and_is_idempotent

echo "all fm-afk-launch tests passed"
