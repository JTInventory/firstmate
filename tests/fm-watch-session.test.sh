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
  local dir fakebin state_a state_b out_a out_b status_a status_b after_stop log
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

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" --status > "$status_a" \
    || fail "watch-session status failed for home A"
  grep -F 'watch-session: running target=' "$status_a" >/dev/null || fail "home A status did not report running"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" stop >/dev/null \
    || fail "watch-session stop failed for home A"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" --status > "$after_stop" \
    && fail "home A status succeeded after stop"
  grep -F 'watch-session: stopped' "$after_stop" >/dev/null || fail "home A status after stop did not report stopped"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-b" "$WATCH_SESSION" --status > "$status_b" \
    || fail "stopping home A stopped home B too"
  grep -F 'watch-session: running target=' "$status_b" >/dev/null || fail "home B did not remain running"
  ! grep -F 'pkill -f' "$WATCH_SESSION" >/dev/null || fail "watch-session contains broad pkill -f"
  pass "watch-session start/status/stop are scoped to one FM_HOME and never use broad pkill"
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
  assert_grep 'if [ "$rc" -ne 0 ]; then sleep 9; fi' "$runner" "runner should delay after failed re-arm attempts"
  ! grep -F 'else sleep 1' "$runner" >/dev/null || fail "runner should re-arm immediately after a successful watcher wake"
  pass "watch-session delays failed re-arms but immediately re-arms after successful wakes"
}

test_watch_session_start_status_stop_are_home_scoped
test_watch_session_delays_only_after_failed_rearm
