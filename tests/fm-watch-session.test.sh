#!/usr/bin/env bash
# tests/fm-watch-session.test.sh - home-scoped durable active watcher runner.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_SESSION="$ROOT/bin/fm-watch-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-session-tests)

install_fake_tmux() {
  local dir=$1 fakebin log root
  fakebin=$(fm_fakebin "$dir")
  log="$dir/tmux.log"
  root="$dir/tmux-state"
  mkdir -p "$root"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?}
root=${FM_FAKE_TMUX_ROOT:?}
cmd=${1:-}
shift || true
printf '%s\n' "tmux $cmd $*" >> "$log"
case "$cmd" in
  has-session)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    target=${target%%:*}
    [ -n "$target" ] && [ -d "$root/$target" ]
    ;;
  new-session)
    session= window= command=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) shift ;;
        -s) session=$2; shift 2 ;;
        -n) window=$2; shift 2 ;;
        *) command=$1; shift ;;
      esac
    done
    mkdir -p "$root/$session"
    printf '%s\n' "$command" > "$root/$session/$window"
    ;;
  new-window)
    target= window= command=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) shift ;;
        -t) target=$2; shift 2 ;;
        -n) window=$2; shift 2 ;;
        *) command=$1; shift ;;
      esac
    done
    session=${target%%:*}
    mkdir -p "$root/$session"
    printf '%s\n' "$command" > "$root/$session/$window"
    ;;
  list-windows)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; -F) shift 2 ;; *) shift ;; esac
    done
    session=${target%%:*}
    [ -d "$root/$session" ] || exit 1
    for f in "$root/$session"/*; do
      [ -f "$f" ] || continue
      basename "$f"
    done | sort
    ;;
  kill-window)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    session=${target%%:*}
    window=${target#*:}
    rm -f "$root/$session/$window"
    ;;
  *)
    echo "unsupported fake tmux command: $cmd" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_watch_session_start_status_stop_are_home_scoped() {
  local dir fakebin state_a state_b out_a out_b status_a status_b after_stop log live identity start
  dir=$(make_case session-home-scope)
  fakebin=$(install_fake_tmux "$dir")
  log="$dir/tmux.log"
  state_a="$dir/home-a/state"
  state_b="$dir/home-b/state"
  mkdir -p "$state_a" "$state_b"
  out_a="$dir/a.out"
  out_b="$dir/b.out"
  status_a="$dir/a.status"
  status_b="$dir/b.status"
  after_stop="$dir/after-stop.status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" start > "$out_a" \
    || fail "watch-session did not start home A: $(cat "$out_a" 2>/dev/null || true)"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-b" "$WATCH_SESSION" start > "$out_b" \
    || fail "watch-session did not start home B: $(cat "$out_b" 2>/dev/null || true)"

  grep -F 'watch-session: started target=' "$out_a" >/dev/null || fail "home A start did not report started"
  grep -F 'watch-session: started target=' "$out_b" >/dev/null || fail "home B start did not report started"
  [ "$(find "$dir/tmux-state/firstmate-watch" -type f | wc -l | tr -d '[:space:]')" = 2 ] \
    || fail "expected separate tmux windows for two FM_HOME values"

  sleep 300 &
  live=$!
  identity=$(FM_HOME="$dir/home-a" FM_STATE_OVERRIDE="$state_a" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not identify the home A watcher"
  start=$(FM_HOME="$dir/home-a" FM_STATE_OVERRIDE="$state_a" bash -c '. "$1"; fm_pid_start "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not pin the home A watcher start"
  mkdir "$state_a/.watch.lock"
  printf '%s\n' "$live" > "$state_a/.watch.lock/pid"
  printf '%s\n' "$start" > "$state_a/.watch.lock/pid-start"
  printf '%s\n' "$identity" > "$state_a/.watch.lock/pid-identity"
  printf '%s\n' "$dir/home-a" > "$state_a/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state_a/.watch.lock/watcher-path"
  touch "$state_a/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" --status > "$status_a" \
    || fail "watch-session status failed for home A"
  grep -F 'watch-session: running target=' "$status_a" >/dev/null || fail "home A status did not report running"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" stop >/dev/null \
    || fail "watch-session stop failed for home A"
  ! is_live_non_zombie "$live" || fail "watch-session stop left the detached home A watcher alive"
  wait "$live" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" --status > "$after_stop" \
    && fail "home A status succeeded after stop"
  grep -F 'watch-session: stopped' "$after_stop" >/dev/null || fail "home A status after stop did not report stopped"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-b" "$WATCH_SESSION" --status > "$status_b" \
    || fail "stopping home A stopped home B too"
  grep -F 'watch-session: running target=' "$status_b" >/dev/null || fail "home B did not remain running"
  ! grep -F 'pkill -f' "$WATCH_SESSION" >/dev/null || fail "watch-session contains broad pkill -f"
  pass "watch-session start/status/stop are scoped to one FM_HOME and never use broad pkill"
}

test_watch_session_stop_waits_for_starting_watcher() {
  local dir fakebin state live identity start racer
  dir=$(make_case session-stop-start-race)
  fakebin=$(install_fake_tmux "$dir")
  state="$dir/home/state"
  mkdir -p "$state"

  sleep 300 &
  live=$!
  identity=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not identify the starting home watcher"
  start=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_start "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not pin the starting home watcher"
  (
    sleep 0.2
    mkdir "$state/.watch.lock"
    printf '%s\n' "$live" > "$state/.watch.lock/pid"
    printf '%s\n' "$start" > "$state/.watch.lock/pid-start"
    printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
    printf '%s\n' "$dir/home" > "$state/.watch.lock/fm-home"
    printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  ) &
  racer=$!

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" FM_WATCH_SESSION_STOP_POLLS=30 "$WATCH_SESSION" stop >/dev/null \
    || fail "watch-session stop failed during watcher startup"
  wait "$racer" 2>/dev/null || true
  ! is_live_non_zombie "$live" || fail "watch-session stop returned before killing a delayed watcher lock"
  wait "$live" 2>/dev/null || true
  pass "watch-session stop waits through delayed watcher lock startup"
}

test_watch_session_delays_only_after_failed_rearm() {
  local dir fakebin state out runner
  dir=$(make_case session-rearm-delay)
  fakebin=$(install_fake_tmux "$dir")
  state="$dir/home/state"
  mkdir -p "$state"
  out="$dir/start.out"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" FM_WATCH_SESSION_REARM_DELAY=9 "$WATCH_SESSION" start > "$out" \
    || fail "watch-session did not start with documented rearm delay"
  runner="$state/.watch-session/runner.sh"
  assert_present "$runner" "watch-session should write runner file"
  # shellcheck disable=SC2016 # Literal runner source pattern.
  assert_grep 'grep -Eq '\''^(signal:|stale:|check:|heartbeat($|:))'\'' "$arm_out"' "$runner" "runner should distinguish wake output from healthy no-op output"
  # shellcheck disable=SC2016 # Literal runner source pattern.
  assert_grep 'if [ "$rc" -ne 0 ]; then rm -f "$arm_out"; sleep 9; continue; fi' "$runner" "runner should delay after failed re-arm attempts"
  assert_grep '  sleep 9' "$runner" "runner should delay after healthy no-op re-arm attempts"
  ! grep -F 'else sleep 1' "$runner" >/dev/null || fail "runner should re-arm immediately after a successful watcher wake"
  pass "watch-session delays failed and no-op re-arms but immediately re-arms after successful wakes"
}

test_watch_session_status_reports_runner_not_inner_arm_health() {
  local dir fakebin state out status arm_out
  dir=$(make_case session-status-runner-contract)
  fakebin=$(install_fake_tmux "$dir")
  state="$dir/home/state"
  mkdir -p "$state"
  out="$dir/start.out"
  status="$dir/status.out"
  arm_out="$state/.watch-session/arm.out"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" "$WATCH_SESSION" start > "$out" \
    || fail "watch-session did not start for runner-status contract"
  mkdir -p "$(dirname "$arm_out")"
  printf '%s\n' 'watcher: FAILED - no live watcher with a fresh beacon' > "$arm_out"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" "$WATCH_SESSION" --status > "$status" \
    || fail "watch-session status should report live runner even when last arm output failed"
  grep -F 'watch-session: running target=' "$status" >/dev/null \
    || fail "watch-session status did not report runner window as running"
  ! grep -F 'FAILED' "$status" >/dev/null \
    || fail "watch-session status should not report inner arm health"
  pass "watch-session status reports runner-window liveness, not inner arm health"
}

test_watch_session_start_status_stop_are_home_scoped
test_watch_session_stop_waits_for_starting_watcher
test_watch_session_delays_only_after_failed_rearm
test_watch_session_status_reports_runner_not_inner_arm_health
