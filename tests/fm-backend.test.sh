#!/usr/bin/env bash
# Runtime backend P1 unit coverage. The fake tmux records dispatch calls so
# this suite proves the selector/metadata contract without requiring a live
# firstmate session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tests)

make_fake_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_TMUX_LOG:?}
{ printf 'tmux'; for arg in "$@"; do printf '\x1f%s' "$arg"; done; printf '\n'; } >> "$log"
case "${1:-}" in
  has-session)
    [ "${FM_FAKE_TMUX_NO_SESSION:-0}" = 1 ] && exit 1
    ;;
  new-session)
    [ "${FM_FAKE_TMUX_NEW_SESSION_FAIL:-0}" = 1 ] && exit 1
    ;;
  list-windows)
    for arg in "$@"; do
      if [ "$arg" = '#{window_id}|#{session_name}:#{window_name}' ]; then
        [ "${FM_FAKE_TMUX_LIST_FAIL:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_TMUX_WINDOW_MISSING:-0}" = 1 ]; then
          printf '@1|firstmate:other\n'
        else
          printf '@1|firstmate:fm-demo\n'
        fi
        exit 0
      fi
    done
    printf 'firstmate:adhoc\n'
    ;;
  capture-pane) printf 'captured line\n' ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_id*) printf 'pane-1\n'; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
        '#S') printf 'firstmate\n'; exit 0 ;;
        *pane_current_path*) printf '/tmp/worktree\n'; exit 0 ;;
        *window_name*) printf 'fm-demo\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n' ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" = 1 ] && exit 1
    ;;
  *) ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_selection_and_metadata() {
  local config="$TMP_ROOT/config" meta="$TMP_ROOT/task.meta"
  mkdir -p "$config"
  FM_BACKEND_CONFIG_DIR="$config"

  [ "$(FM_BACKEND='' fm_backend_name)" = tmux ] || fail "backend should default to tmux"
  printf '\n tmux \n' > "$config/backend"
  [ "$(FM_BACKEND='' fm_backend_name)" = tmux ] || fail "config/backend was not selected"
  [ "$(FM_BACKEND=tmux fm_backend_name)" = tmux ] || fail "FM_BACKEND did not override config/backend"

  fm_write_meta "$meta" "window=firstmate:fm-demo" "harness=codex"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "missing backend= must mean tmux"
  printf 'backend=tmux\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "explicit backend=tmux was not read"

  fm_backend_validate tmux || fail "tmux should be known"
  if fm_backend_validate herdr >/dev/null 2>&1; then
    fail "unimplemented herdr backend was accepted"
  fi
  pass "backend selection precedence, metadata default, and unknown refusal"
}

test_spawn_rejects_unknown_selection() {
  local config="$TMP_ROOT/spawn-selection-config" out
  mkdir -p "$config"

  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND=herdr "$ROOT/bin/fm-spawn.sh" 2>&1) \
    && fail "FM_BACKEND=herdr should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'herdr'" "FM_BACKEND refusal did not name the backend"

  printf 'herdr\n' > "$config/backend"
  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND= FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-spawn.sh" 2>&1) \
    && fail "config/backend=herdr should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'herdr'" "config/backend refusal did not name the backend"

  out=$(FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" --backend herdr 2>&1) \
    && fail "--backend herdr should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'herdr'" "--backend refusal did not name the backend"
  pass "fm-spawn refuses unknown backends from FM_BACKEND, config/backend, and --backend"
}

test_selector_and_dispatch() {
  local dir fakebin log state out
  dir="$TMP_ROOT/dispatch"; mkdir -p "$dir/state"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"; : > "$log"
  state="$dir/state"
  fm_write_meta "$state/demo.meta" "window=firstmate:fm-demo"

  [ "$(fm_backend_resolve_selector sess:win "$state")" = sess:win ] \
    || fail "explicit session:window selector changed"
  [ "$(fm_backend_resolve_selector fm-demo "$state")" = firstmate:fm-demo ] \
    || fail "fm-<id> selector did not use metadata"
  out=$(PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_resolve_selector adhoc "$state")
  [ "$out" = firstmate:adhoc ] || fail "bare selector did not use fake tmux inventory"

  out=$(PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_capture tmux firstmate:fm-demo 12)
  [ "$out" = 'captured line' ] || fail "capture dispatch returned '$out'"
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_send_key tmux firstmate:fm-demo Escape \
    || fail "send-key dispatch failed"
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_pane_readable tmux firstmate:fm-demo \
    || fail "pane-readable dispatch failed"
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_kill tmux firstmate:fm-demo \
    || fail "kill dispatch failed"
  assert_contains "$(cat "$log")" $'\x1f''capture-pane' "capture did not reach fake tmux"
  assert_contains "$(cat "$log")" $'\x1f''Escape' "send-key did not reach fake tmux"
  assert_contains "$(cat "$log")" $'\x1f''kill-window' "kill did not reach fake tmux"
  pass "selector resolution and capture/key/readability/kill dispatch use tmux adapter"
}

test_backend_failures_propagate() {
  local dir fakebin log out
  dir="$TMP_ROOT/failures"; mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"; : > "$log"

  if PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    fm_backend_kill tmux firstmate:fm-demo; then
    fail "kill failure was swallowed by the tmux adapter"
  fi

  if out=$(PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_NO_SESSION=1 \
    FM_FAKE_TMUX_NEW_SESSION_FAIL=1 TMUX= fm_backend_container_ensure tmux /tmp); then
    fail "new-session failure was swallowed by container ensure"
  fi
  assert_contains "$(cat "$log")" $'\x1f''new-session' \
    "container ensure did not attempt new-session after has-session failed"
  if PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    fm_backend_kill tmux firstmate:fm-demo; then
    fail "kill failure was swallowed while the target was still present"
  fi
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    FM_FAKE_TMUX_WINDOW_MISSING=1 fm_backend_kill tmux firstmate:fm-demo \
    || fail "already-absent target was not idempotent"
  if PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    FM_FAKE_TMUX_LIST_FAIL=1 fm_backend_kill tmux firstmate:fm-demo; then
    fail "tmux inventory failure was treated as an absent target"
  fi
  pass "tmux adapter propagates kill and container-creation failures"
}

test_selection_and_metadata
test_spawn_rejects_unknown_selection
test_selector_and_dispatch
test_backend_failures_propagate
