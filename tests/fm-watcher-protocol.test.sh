#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
PROTOCOL_LIB="$ROOT/bin/fm-watcher-protocol-lib.sh"
PENDING_LIB="$ROOT/bin/fm-pending-reply-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-protocol-tests)
trap fm_test_watch_cleanup_exit EXIT

test_legacy_watcher_creates_durable_fence() {
  local dir state peer token
  dir=$(make_case legacy-fence)
  state="$dir/state"
  sleep 300 &
  peer=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"

  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_watcher_protocol_gate "$2" "$3" "$4"' \
    _ "$PROTOCOL_LIB" "$state" "$dir" "$WATCH"; then
    fail "legacy watcher passed the protocol gate"
  fi
  [ "$(cat "$state/.watch-protocol-required" 2>/dev/null || true)" = pending-reply-ticket-v1 ] \
    || fail "legacy watcher did not create a durable protocol fence"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_pending_reply_txn_lock_acquire "$2" abcdef0123456789 token' \
    _ "$PENDING_LIB" "$state"; then
    fail "pending-reply transaction bypassed the protocol fence"
  fi
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "legacy watcher creates a durable pending-reply fence"
}

test_verified_restart_clears_fence() {
  local dir state fakebin out old new
  dir=$(make_case verified-restart)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >/dev/null 2>&1 &
  old=$!
  for _ in $(seq 1 60); do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$old" ] \
      && [ -f "$state/.watch.lock/pending-reply-protocol" ] && break
    sleep 0.1
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$old" ] \
    || fail "seed watcher did not start"
  rm -f "$state/.watch.lock/pending-reply-protocol"
  printf '%s\n' pending-reply-ticket-v1 > "$state/.watch-protocol-required"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" --restart-verify >"$out" \
    || fail "verified restart failed: $(cat "$out")"
  new=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$new" ] && [ "$new" != "$old" ] || fail "restart did not replace the legacy watcher"
  [ "$(cat "$state/.watch.lock/pending-reply-protocol" 2>/dev/null || true)" = pending-reply-ticket-v1 ] \
    || fail "replacement watcher did not publish protocol proof"
  [ ! -f "$state/.watch-protocol-required" ] || fail "replacement watcher left the durable fence"
  grep -qF "watcher: healthy pid=$new" "$out" || fail "restart did not report verified watcher health"
  kill "$new" 2>/dev/null || true
  wait "$new" 2>/dev/null || true
  pass "verified restart publishes proof and clears the fence"
}

test_legacy_watcher_creates_durable_fence
test_verified_restart_clears_fence

echo "# all watcher protocol tests passed"
