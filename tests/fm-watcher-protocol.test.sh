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
  local dir state peer
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
  [ "$(cat "$state/.watch-protocol-required" 2>/dev/null || true)" = pending-reply-ticket-v3 ] \
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

test_verified_restart_requires_tracked_rearm() {
  local dir state fakebin out arm_out old new first_arm second_arm rc
  dir=$(make_case verified-restart)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  arm_out="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >/dev/null 2>&1 &
  old=$!
  for _ in $(seq 1 60); do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$old" ] \
      && [ -f "$state/.watch.lock/pending-reply-protocol" ] && break
    sleep 0.1
  done
  [ -f "$state/.watch.lock/pending-reply-protocol" ] || fail "seed watcher did not publish protocol"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$old" ] \
    || fail "seed watcher did not start"
  FM_HOME="$dir" bash -c '
    . "$1"
    fm_lock_try_acquire "$2/.watch-arm.lock" "$3" "$4" "$3" || exit 1
    while fm_pid_alive "$5"; do sleep 0.1; done
    fm_lock_release "$2/.watch-arm.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$WATCH_ARM" "$dir" "$old" &
  first_arm=$!
  for _ in $(seq 1 40); do
    [ "$(cat "$state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$first_arm" ] && break
    sleep 0.1
  done
  [ "$(cat "$state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$first_arm" ] \
    || fail "legacy harness follower did not claim its slot"
  rm -f "$state/.watch.lock/pending-reply-protocol"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch-protocol-required"

  rc=0
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" --restart-verify >"$out" || rc=$?
  [ "$rc" -ne 0 ] || fail "restart reported success before a tracked follower handoff"
  grep -qF 'legacy cycle stopped; harness follower must re-arm' "$out" \
    || fail "restart did not request the tracked re-arm handoff: $(cat "$out")"
  ! is_live_non_zombie "$old" || fail "legacy watcher remained live after scoped stop"
  [ -f "$state/.watch-protocol-required" ] || fail "restart cleared the fence before tracked re-arm"
  [ -f "$state/.watch-protocol-reread-required" ] \
    || fail "restart did not preserve the post-update reread obligation"
  wait_for_exit "$first_arm" 80 || fail "original harness follower did not surface the stopped cycle"
  wait "$first_arm" 2>/dev/null || true

  : > "$arm_out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" >"$arm_out" 2>&1 &
  second_arm=$!
  for _ in $(seq 1 80); do
    grep -qF 'watcher: started pid=' "$arm_out" 2>/dev/null && break
    sleep 0.1
  done
  new=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$new" ] && [ "$new" != "$old" ] \
    || fail "restart did not replace the legacy watcher: arm=$(cat "$arm_out"); watch=$(cat "$state/.watch.out" 2>/dev/null); migration=$(cat "$state/.pr-check-migration.log" 2>/dev/null)"
  [ "$(cat "$state/.watch.lock/pending-reply-protocol" 2>/dev/null || true)" = pending-reply-ticket-v3 ] \
    || fail "replacement watcher did not publish protocol proof"
  [ ! -f "$state/.watch-protocol-required" ] || fail "replacement watcher left the durable fence"
  [ "$(cat "$state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$second_arm" ] \
    || fail "replacement watcher has no harness-tracked follower"
  kill "$new" 2>/dev/null || true
  wait_for_exit "$second_arm" 80 || true
  wait "$second_arm" 2>/dev/null || true
  pass "protocol restart stays fenced until tracked re-arm"
}

test_plain_arm_replaces_live_legacy_primary() {
  local dir state fakebin out old new arm_pid
  dir=$(make_case plain-arm-takeover)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >/dev/null 2>&1 &
  old=$!
  for _ in $(seq 1 60); do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$old" ] \
      && [ -f "$state/.watch.lock/pending-reply-protocol" ] && break
    sleep 0.1
  done
  [ -f "$state/.watch.lock/pending-reply-protocol" ] || fail "seed watcher did not publish protocol"
  printf '%s\n' pending-reply-ticket-v1 > "$state/.watch.lock/pending-reply-protocol"
  touch -t 200001010000 "$state/.last-watcher-beat"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch-protocol-required"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" >"$out" &
  arm_pid=$!
  for _ in $(seq 1 80); do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
  done
  new=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$new" ] && [ "$new" != "$old" ] || fail "plain arm did not replace legacy primary"
  grep -qF "watcher: started pid=$new" "$out" || fail "plain arm did not report replacement"
  [ ! -f "$state/.watch-protocol-required" ] || fail "plain arm did not clear migration fence"
  [ -f "$state/.watch-protocol-reread-required" ] \
    || fail "plain arm did not preserve the reread obligation"
  kill "$new" 2>/dev/null || true
  wait_for_exit "$arm_pid" 80 || true
  wait "$arm_pid" 2>/dev/null || true
  pass "plain arm performs verified legacy primary takeover"
}

test_nested_gate_uses_child_owner_scope() {
  local parent child state fakebin arm_out arm_pid watcher corr
  parent=$(make_case nested-parent)
  child=$(make_case nested-child)
  state="$child/state"
  fakebin="$child/fakebin"
  arm_out="$child/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$child" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" >"$arm_out" &
  arm_pid=$!
  for _ in $(seq 1 80); do
    grep -qF 'watcher: started pid=' "$arm_out" 2>/dev/null && break
    sleep 0.1
  done
  corr=$(FM_HOME="$child" FM_PENDING_REPLY_NOW=1234 bash -c \
    '. "$1"; fm_pending_reply_create "$2" "$3" task "nested handoff"' \
    _ "$PENDING_LIB" "$child" "$state") || fail "nested record setup failed"
  FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" bash -c \
    '. "$1"; fm_pending_reply_txn_lock_acquire "$2" "$3" token; fm_pending_reply_txn_lock_release "$2" "$3" "$token"' \
    _ "$PENDING_LIB" "$state" "$corr" || fail "nested gate validated the ambient parent watcher"
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill "$watcher" 2>/dev/null || true
  wait_for_exit "$arm_pid" 80 || true
  wait "$arm_pid" 2>/dev/null || true
  pass "nested pending-reply gate validates child owner scope"
}

test_protocol_restart_refuses_afk_and_preserves_x_cadence() {
  local dir state fake_root out rc
  dir=$(make_case restart-policy)
  state="$dir/state"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch-protocol-required"
  : > "$state/.afk"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_watcher_protocol_restart_if_required "$2" "$3" "$4"' \
    _ "$PROTOCOL_LIB" "$dir" "$state" "$ROOT" >"$dir/afk.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "protocol restart bypassed AFK ownership"
  grep -qF 'AFK daemon owns watcher lifecycle' "$dir/afk.out" \
    || fail "AFK restart refusal was not explicit"
  rm -f "$state/.afk"
  mkdir -p "$dir/config"
  printf '%s\n' 'export FM_CHECK_INTERVAL=30' > "$dir/config/x-mode.env"
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${FM_CHECK_INTERVAL:-missing}" > "$FM_HOME/cadence"' 'exit 1' \
    > "$fake_root/bin/fm-watch-arm.sh"
  chmod +x "$fake_root/bin/fm-watch-arm.sh"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_watcher_protocol_restart_if_required "$2" "$3" "$4"' \
    _ "$PROTOCOL_LIB" "$dir" "$state" "$fake_root" >"$dir/x.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "stub restart unexpectedly succeeded"
  [ "$(cat "$dir/cadence" 2>/dev/null || true)" = 30 ] \
    || fail "protocol restart did not preserve X-mode cadence"
  pass "protocol restart refuses AFK and preserves X cadence"
}

test_afk_daemon_ownership_satisfies_protocol_gate() {
  local dir state fake_root daemon watcher
  dir=$(make_case afk-daemon-proof)
  state="$dir/state"
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 30; done
SH
  cat > "$fake_root/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
"$(dirname "$0")/fm-watch.sh" &
printf '%s\n' "$!" > "$1/watcher-child"
wait "$!"
SH
  chmod +x "$fake_root/bin/fm-watch.sh" "$fake_root/bin/fm-supervise-daemon.sh"
  "$fake_root/bin/fm-supervise-daemon.sh" "$state" &
  daemon=$!
  for _ in $(seq 1 40); do
    [ -s "$state/watcher-child" ] && break
    sleep 0.1
  done
  watcher=$(cat "$state/watcher-child" 2>/dev/null || true)
  [ -n "$watcher" ] || fail "AFK daemon fixture did not start its watcher"
  mkdir "$state/.watch.lock"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_pid_start "$2" > "$3/.watch.lock/pid-start"
    fm_pid_identity "$2" > "$3/.watch.lock/pid-identity"
    fm_pid_start "$4" > "$3/.supervise-daemon.pid-start"
    fm_pid_identity "$4" > "$3/.supervise-daemon.pid-identity"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" "$state" "$daemon" \
    || fail "AFK daemon fixture could not write process proof"
  printf '%s\n' "$watcher" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$fake_root/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch.lock/pending-reply-protocol"
  printf '%s\n' "$daemon" > "$state/.supervise-daemon.pid"
  printf '%s\n' "$fake_root/bin/fm-supervise-daemon.sh" > "$state/.supervise-daemon.pid-path"
  : > "$state/.afk"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch-protocol-required"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_watcher_protocol_gate "$2" "$3" "$4"' \
    _ "$PROTOCOL_LIB" "$state" "$dir" "$fake_root/bin/fm-watch.sh" \
    || fail "verified AFK daemon ownership did not satisfy the protocol gate"
  [ ! -f "$state/.watch-protocol-required" ] || fail "AFK daemon proof left the fence active"
  kill "$watcher" "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "verified AFK daemon ownership satisfies protocol gate"
}

test_legacy_watcher_creates_durable_fence
test_verified_restart_requires_tracked_rearm
test_plain_arm_replaces_live_legacy_primary
test_nested_gate_uses_child_owner_scope
test_protocol_restart_refuses_afk_and_preserves_x_cadence
test_afk_daemon_ownership_satisfies_protocol_gate

echo "# all watcher protocol tests passed"
