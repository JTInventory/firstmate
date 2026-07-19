#!/usr/bin/env bash
# Supervisor target discovery is shared by the away-mode daemon and launcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET_LIB="$ROOT/bin/fm-supervisor-target-lib.sh"
[ -f "$TARGET_LIB" ] || fail "supervisor target library is missing"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$TARGET_LIB"

test_backend_precedence() {
  local out
  out=$(FM_SUPERVISOR_BACKEND=herdr TMUX_PANE='%9' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "explicit supervisor backend override was ignored: $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='%9' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = tmux ] || fail "TMUX_PANE did not win over nested Herdr markers: $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "Herdr markers did not select Herdr: $out"

  if out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_backend); then
    fail "fallback backend unexpectedly returned success"
  fi
  [ "$out" = tmux ] || fail "fallback backend changed from tmux: $out"
  pass "supervisor backend precedence keeps tmux default and selects Herdr explicitly"
}

test_target_precedence() {
  local out
  out=$(FM_SUPERVISOR_TARGET=explicit:target TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_target)
  [ "$out" = explicit:target ] || fail "explicit supervisor target was ignored: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='%3' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_target)
  [ "$out" = '%3' ] || fail "TMUX_PANE did not win over nested Herdr target: $out"

  out=$(FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET='' TMUX_PANE='%3' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION=lab discover_supervisor_target)
  [ "$out" = lab:w1:p9 ] || fail "selected Herdr backend used the inherited tmux target: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION='' discover_supervisor_target)
  [ "$out" = default:w1:p9 ] || fail "Herdr target did not default the session: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION=lab discover_supervisor_target)
  [ "$out" = lab:w1:p9 ] || fail "Herdr target did not use HERDR_SESSION: $out"

  if out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target); then
    fail "fallback target unexpectedly returned success"
  fi
  [ "$out" = firstmate:0 ] || fail "fallback target changed from firstmate:0: $out"

  if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET='' TMUX_PANE='%3' HERDR_PANE_ID='' discover_supervisor_target >/dev/null 2>&1; then
    fail "Herdr target discovery succeeded without a pane marker"
  fi
  pass "supervisor target precedence composes Herdr session:pane targets"
}

test_backend_precedence
test_target_precedence

echo "all supervisor target tests passed"
