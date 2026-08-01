#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-concurrent-primary-identity)
PRIMARY_HOME="$TMP_ROOT/home"
START="$TMP_ROOT/start"
mkdir -p "$PRIMARY_HOME/state"

case "${FM_TEST_AUTHORITY_BROKER_PID:-}:${FM_TEST_AUTHORITY_OWNER_PID:-}" in
  *[!0-9:]*|:*|*:|*:*:*)
    fm_test_session_authority_fd "$TMP_ROOT"
    exec 19<&9
    export FM_TEST_AUTHORITY_FD=19 FM_TEST_DURABLE_AUTHORITY_FD=18
    export FM_TEST_SESSION_LOCK_STABLE_OWNER=1
    exec bash "$ROOT/bin/fm-session-authority-exec.sh" \
      --behavior-test-authority-broker "$ROOT/tests/fm-concurrent-primary-identity.test.sh"
    ;;
esac

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$ROOT/bin/fm-worker-isolation-lib.sh"

run_bounded() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", $pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  fi
}

if ! run_bounded 5 bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire() { return 1; }
  pids=()
  for worker in $(seq 1 40); do
    (
      if FM_LOCK_ACQUIRE_WAIT_TIMEOUT_MS=100 fm_lock_acquire_wait "$2"; then
        exit 1
      fi
      exit 0
    ) &
    pids+=("$!")
  done
  status=0
  for pid in "${pids[@]}"; do
    wait "$pid" || status=1
  done
  exit "$status"
' _ "$ROOT" "$TMP_ROOT/.lock.acquire" >/dev/null 2>&1; then
  fail "the 40-way session-lock race did not fail closed within its deadline"
fi
pass "the 40-way session-lock race is hard bounded and fail closed"

FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  fm_worker_test_primary_identity_bind \
    "$ROOT" "$PRIMARY_HOME" "$PRIMARY_HOME/state" \
  || fail "could not bind the concurrent primary fixture"

pids=()
for worker in 1 2 3 4 5 6 7 8; do
  (
    while [ ! -e "$START" ]; do sleep 0.01; done
    cd "$ROOT" || exit 1
    FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
      bash -c '
        . "$1/bin/fm-worker-isolation-lib.sh"
        if ! fm_worker_refuse_primary_operation spawn; then
          printf "%s\n" authority > "$2"
          exit 1
        fi
        printf "%s\n" pass > "$2"
      ' _ "$ROOT" "$TMP_ROOT/$worker.stage"
  ) > "$TMP_ROOT/$worker.out" 2> "$TMP_ROOT/$worker.err" &
  pids+=("$!")
done
touch "$START"

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
[ "$status" -eq 0 ] || {
  for worker in 1 2 3 4 5 6 7 8; do
    [ ! -s "$TMP_ROOT/$worker.stage" ] \
      || printf 'concurrent primary identity stage=%s\n' \
        "$(cat "$TMP_ROOT/$worker.stage")" >&2
  done
  fail "concurrent primary checks did not share the behavior authority safely"
}
IDENTITY_LOCK="$TMPDIR/.fm-test-primary-identity-$FM_TEST_AUTHORITY_BROKER_PID.lock"
[ ! -e "$IDENTITY_LOCK" ] \
  || fail "concurrent primary identity lock was not retired"
ln -s "$TMP_ROOT" "$IDENTITY_LOCK"
if FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  fm_worker_primary_authority_matches spawn; then
  rm -f "$IDENTITY_LOCK"
  fail "a symlinked primary identity lock was followed"
fi
[ -L "$IDENTITY_LOCK" ] || fail "identity refusal mutated a hostile lock path"
rm -f "$IDENTITY_LOCK"

pass "concurrent primary identity checks retain exact checkout authority"
