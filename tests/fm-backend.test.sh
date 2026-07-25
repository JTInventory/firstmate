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
  fm_backend_validate herdr || fail "Herdr should be accepted as the experimental opt-in backend"
  pass "backend selection precedence, metadata default, and known/unknown validation"
}

test_spawn_rejects_unknown_selection() {
  local config="$TMP_ROOT/spawn-selection-config" out
  mkdir -p "$config"

  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND=orca "$ROOT/bin/fm-spawn.sh" 2>&1) \
    && fail "FM_BACKEND=orca should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'orca'" "FM_BACKEND refusal did not name the backend"

  printf 'orca\n' > "$config/backend"
  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND='' FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-spawn.sh" 2>&1) \
    && fail "config/backend=orca should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'orca'" "config/backend refusal did not name the backend"

  out=$(FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" --backend orca 2>&1) \
    && fail "--backend orca should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'orca'" "--backend refusal did not name the backend"
  pass "fm-spawn refuses unknown backends from FM_BACKEND, config/backend, and --backend"
}

test_selector_and_dispatch() {
  local dir fakebin log state out
  dir="$TMP_ROOT/dispatch"; mkdir -p "$dir/state"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"; : > "$log"
  state="$dir/state"
  fm_write_meta "$state/demo.meta" "window=firstmate:fm-demo"
  fm_write_meta "$state/foo.meta" "window=firstmate:fm-foo"
  fm_write_meta "$state/fm-foo.meta" "window=firstmate:fm-fm-foo"

  [ "$(fm_backend_resolve_selector sess:win "$state")" = sess:win ] \
    || fail "explicit session:window selector changed"
  [ "$(fm_backend_resolve_selector fm-demo "$state")" = firstmate:fm-demo ] \
    || fail "fm-<id> selector did not use metadata"
  [ "$(fm_backend_resolve_selector fm-foo "$state")" = firstmate:fm-foo ] \
    || fail "fm-<id> selector did not retain its stripped-id meaning"
  [ "$(fm_backend_resolve_selector fm-fm-foo "$state")" = firstmate:fm-fm-foo ] \
    || fail "fm-prefixed task id was not addressable through its canonical selector"
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

test_selector_recovers_precreate_herdr_journal() {
  local state out resolution
  state="$TMP_ROOT/herdr-recovery/state"
  mkdir -p "$state"
  fm_write_meta "$state/exact-c1db.meta" "window=stale:w0:p0" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=w-second" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
    "display_label=Crew - Exact recovery · c1db" "task_key=c1db" \
    "home=$TMP_ROOT/secondmate-home"
  fm_write_meta "$state/stale-d2e3.meta" "window=stale:w0:p0" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=w-second" \
    "herdr_tab_id=w-old:t1" "herdr_pane_id=w-old:p1" \
    "display_label=Crew - Stale recovery · d2e3" "task_key=d2e3" \
    "home=$TMP_ROOT/secondmate-home"
  fm_write_meta "$state/legacy-e3f4.meta" "window=stale:w0:p0" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=w-second" \
    "herdr_tab_id=w-gone:t1" "herdr_pane_id=w-gone:p1" \
    "display_label=Crew - Missing display · e3f4" "task_key=e3f4" \
    "home=$TMP_ROOT/secondmate-home"
  printf 'version=1\ntask_id=crash-c1db\ndisplay_label=Crew - Crash recovery · c1db\ntask_key=c1db\nherdr_home=%s\nherdr_session=fmtest\nherdr_workspace_id=w-second\n' \
    "$TMP_ROOT/secondmate-home" \
    > "$state/crash-c1db.herdr-label"
  fm_backend_source herdr || fail "Herdr backend could not be loaded"
  fm_backend_pane_readable() {
    [ "$1" = herdr ] && [ "$2" = fmtest:w1:p1 ]
  }
  fm_backend_list_live() {
    [ "$1" = herdr ] || return 1
    [ "$FM_STATE_OVERRIDE" = "$state" ] || return 1
    case "${3:-}" in
      w-second)
        [ "$2" = fmtest ] || return 1
        [ "$FM_HOME" = "$TMP_ROOT/secondmate-home" ] || return 1
        printf 'fmtest:w1:p2\tfm-stale-d2e3\tCrew - Stale recovery · d2e3\n'
        printf 'fmtest:w1:p5\tfm-stale-d2e3\tfm-stale-d2e3\n'
        printf 'fmtest:w1:p3\tfm-crash-c1db\tCrew - Crash recovery · c1db\n'
        printf 'fmtest:w1:p7\tfm-crash-c1db\tfm-crash-c1db\n'
        printf 'fmtest:w1:p6\tfm-legacy-e3f4\tfm-legacy-e3f4\n'
        ;;
      '')
        printf 'fmtest:w1:p4\tfm-legacy-z9\tfm-legacy-z9\n'
        ;;
      *) return 1 ;;
    esac
  }
  resolution=$(fm_backend_resolve_selector_with_backend exact-c1db "$state") \
    || fail "readable exact Herdr ids did not resolve"
  [ "$resolution" = $'herdr\tfmtest:w1:p1' ] \
    || fail "readable exact Herdr ids were not preferred: '$resolution'"
  resolution=$(fm_backend_resolve_selector_with_backend stale-d2e3 "$state") \
    || fail "stale exact Herdr ids did not fall back through live inventory"
  [ "$resolution" = $'herdr\tfmtest:w1:p2' ] \
    || fail "stale exact Herdr ids did not recover by display label: '$resolution'"
  resolution=$(fm_backend_resolve_selector_with_backend legacy-e3f4 "$state") \
    || fail "stale Herdr ids did not use final legacy fallback"
  [ "$resolution" = $'herdr\tfmtest:w1:p6' ] \
    || fail "final legacy Herdr fallback resolved incorrectly: '$resolution'"
  out=$(HERDR_SESSION=fmtest fm_backend_resolve_selector crash-c1db "$state") \
    || fail "bare task id did not recover through the Herdr journal"
  [ "$out" = fmtest:w1:p3 ] || fail "recovered Herdr target mismatch: '$out'"
  out=$(HERDR_SESSION=fmtest fm_backend_resolve_selector fm-crash-c1db "$state") \
    || fail "legacy fm-<id> selector did not recover through the Herdr journal"
  [ "$out" = fmtest:w1:p3 ] || fail "legacy recovered Herdr target mismatch: '$out'"
  resolution=$(HERDR_SESSION=fmtest fm_backend_resolve_selector_with_backend fm-crash-c1db "$state") \
    || fail "journal-only selector did not return backend-aware recovery"
  [ "$resolution" = $'herdr\tfmtest:w1:p3' ] || fail "journal-only selector lost Herdr backend routing: '$resolution'"
  resolution=$(FM_BACKEND=herdr HERDR_SESSION=fmtest \
    fm_backend_resolve_selector_with_backend fm-legacy-z9 "$state") \
    || fail "legacy-only Herdr tab was not discovered through live inventory"
  [ "$resolution" = $'herdr\tfmtest:w1:p4' ] \
    || fail "legacy-only Herdr tab resolved incorrectly: '$resolution'"
  pass "selector recovery retains Herdr routing and persisted workspace identity"
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
    FM_FAKE_TMUX_NEW_SESSION_FAIL=1 TMUX='' fm_backend_container_ensure tmux /tmp); then
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

test_teardown_preserves_state_on_kill_failure() {
  local dir fakebin fake_root log project state treehouse_log worktree out
  dir="$TMP_ROOT/teardown-kill-failure"
  fake_root="$dir/root"
  project="$dir/project"
  state="$fake_root/state"
  worktree="$dir/worktree"
  mkdir -p "$fake_root/bin/backends" "$state"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  : > "$log"
  : > "$treehouse_log"
  fm_git_worktree "$project" "$worktree" kill-fail
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/treehouse"

  ln -s "$ROOT/bin/fm-teardown.sh" "$fake_root/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake_root/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake_root/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake_root/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-tool-path-lib.sh" "$fake_root/bin/fm-tool-path-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake_root/bin/fm-gate-refuse-lib.sh"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"
  cat > "$fake_root/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake_root/bin/fm-task-identity-lib.sh" <<'SH'
fm_assert_task_branch_matches_meta() { return 0; }
SH

  fm_write_meta "$state/kill-fail.meta" \
    "window=firstmate:fm-demo" \
    "worktree=$worktree" \
    "project=$project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working\n' > "$state/kill-fail.status"

  if out=$(cd "$fake_root" && PATH="$fakebin:$PATH" FM_HOME="$fake_root" \
    FM_ROOT_OVERRIDE="$fake_root" FM_STATE_OVERRIDE="$state" \
    FM_TMUX_LOG="$log" FM_TREEHOUSE_LOG="$treehouse_log" \
    FM_FAKE_TMUX_KILL_FAIL=1 \
    "$fake_root/bin/fm-teardown.sh" kill-fail --force 2>&1); then
    fail "teardown swallowed a backend kill failure"
  fi
  assert_contains "$out" \
    "REFUSED: could not kill task kill-fail window firstmate:fm-demo; refusing to delete task state" \
    "teardown did not report the failed backend kill"
  [ -f "$state/kill-fail.meta" ] || fail "teardown deleted metadata after kill failure"
  [ -f "$state/kill-fail.status" ] || fail "teardown deleted status after kill failure"
  [ -d "$worktree" ] || fail "teardown removed the worktree after kill failure"
  assert_contains "$(git -C "$project" worktree list --porcelain)" \
    "worktree $worktree" "teardown unregistered the worktree after kill failure"
  git -C "$project" show-ref --verify --quiet refs/heads/kill-fail \
    || fail "teardown deleted the task branch after kill failure"
  [ ! -s "$treehouse_log" ] || fail "teardown returned the worktree before killing its endpoint"
  pass "teardown preserves task state when backend kill fails"
}

test_selection_and_metadata
test_spawn_rejects_unknown_selection
test_selector_and_dispatch
test_selector_recovers_precreate_herdr_journal
test_backend_failures_propagate
test_teardown_preserves_state_on_kill_failure
