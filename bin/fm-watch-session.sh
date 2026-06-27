#!/usr/bin/env bash
# Home-scoped durable active watcher runner.
#
# fm-watch-arm.sh intentionally keeps the watcher as its child. That is good for
# harness-tracked foreground tasks, but fragile when a harness cannot keep that
# foreground call alive. This wrapper gives active mode a durable process for the
# current FM_HOME: it starts a small runner that repeatedly arms the watcher,
# records the runner pid in state/.watch-session.lock, and can report or stop
# only that home-scoped runner.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH_ARM="$SCRIPT_DIR/fm-watch-arm.sh"
SESSION_LOCK="$STATE/.watch-session.lock"
LOG="$STATE/.watch-session.log"
RUNNER_PATH="$SCRIPT_DIR/fm-watch-session.sh"

usage() {
  echo "usage: $(basename "$0") [--start|--stop|--status|--foreground|--tmux]" >&2
}

session_lock_matches_pid() {
  local pid=$1 lock_home lock_path lock_identity current_identity
  lock_home=$(cat "$SESSION_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$SESSION_LOCK/runner-path" 2>/dev/null || true)
  lock_identity=$(cat "$SESSION_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$RUNNER_PATH" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

session_pid() {
  cat "$SESSION_LOCK/pid" 2>/dev/null || true
}

session_running() {
  local pid
  pid=$(session_pid)
  fm_pid_alive "$pid" || return 1
  session_lock_matches_pid "$pid"
}

write_session_identity() {
  local pid=$1
  printf '%s\n' "$FM_HOME" > "$SESSION_LOCK/fm-home" || true
  printf '%s\n' "$RUNNER_PATH" > "$SESSION_LOCK/runner-path" || true
  fm_pid_identity "$pid" > "$SESSION_LOCK/pid-identity" 2>/dev/null || true
}

status_cmd() {
  local pid
  if session_running; then
    pid=$(session_pid)
    echo "watch-session: running pid=$pid home=$FM_HOME log=$LOG"
    exit 0
  fi
  echo "watch-session: stopped home=$FM_HOME"
  exit 1
}

stop_cmd() {
  local pid i pgid
  if ! session_running; then
    fm_lock_remove_path "$SESSION_LOCK" 2>/dev/null || true
    echo "watch-session: stopped home=$FM_HOME"
    return 0
  fi
  pid=$(session_pid)
  kill -TERM "$pid" 2>/dev/null || true
  pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ' || true)
  i=0
  while [ "$i" -lt 80 ] && fm_pid_alive "$pid"; do
    if [ "$i" -eq 10 ] && [ "$pgid" = "$pid" ]; then
      kill -TERM "-$pid" 2>/dev/null || true
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid"; then
    echo "watch-session: FAILED - runner still alive pid=$pid" >&2
    return 1
  fi
  fm_lock_remove_path "$SESSION_LOCK" 2>/dev/null || true
  echo "watch-session: stopped pid=$pid home=$FM_HOME"
}

foreground_cmd() {
  if ! fm_lock_try_acquire "$SESSION_LOCK"; then
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && fm_pid_alive "$FM_LOCK_HELD_PID"; then
      echo "watch-session: already running pid=$FM_LOCK_HELD_PID home=$FM_HOME" >&2
    else
      echo "watch-session: already running home=$FM_HOME" >&2
    fi
    exit 1
  fi
  trap 'fm_lock_release "$SESSION_LOCK"; exit 143' TERM INT HUP
  trap 'fm_lock_release "$SESSION_LOCK"' EXIT
  write_session_identity "${BASHPID:-$$}"
  while :; do
    "$WATCH_ARM" >> "$LOG" 2>&1 || true
    sleep "${FM_WATCH_SESSION_REARM_DELAY:-1}"
  done
}

start_cmd() {
  local pid i
  if session_running; then
    pid=$(session_pid)
    echo "watch-session: running pid=$pid home=$FM_HOME log=$LOG"
    return 0
  fi
  fm_lock_remove_path "$SESSION_LOCK" 2>/dev/null || true
  : > "$LOG" || {
    echo "watch-session: FAILED - cannot write $LOG" >&2
    return 1
  }
  if command -v setsid >/dev/null 2>&1; then
    setsid "$RUNNER_PATH" --foreground >> "$LOG" 2>&1 < /dev/null &
  else
    nohup "$RUNNER_PATH" --foreground >> "$LOG" 2>&1 < /dev/null &
  fi
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    if session_running; then
      pid=$(session_pid)
      echo "watch-session: started pid=$pid home=$FM_HOME log=$LOG"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "watch-session: FAILED - runner did not confirm" >&2
  return 1
}

mode=${1:---status}
case "$mode" in
  --start|start) start_cmd ;;
  --stop|stop) stop_cmd ;;
  --status|status) status_cmd ;;
  --foreground|foreground) foreground_cmd ;;
  --tmux)
    echo "tmux new-window -n fm-watch-$(basename "$FM_HOME") 'cd \"$FM_ROOT\" && FM_HOME=\"$FM_HOME\" bin/fm-watch-session.sh --foreground'"
    ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
