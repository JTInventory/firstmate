#!/usr/bin/env bash
# Durable, home-scoped active watcher runner.
#
# Use this in harnesses where a tracked background task is not durable enough.
# It creates one tmux window per FM_HOME/STATE pair and runs fm-watch-arm.sh in a
# loop there. The watcher itself remains the same singleton: it is still scoped by
# this home's state/.watch.lock, and no broad process matching is used.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

SESSION_NAME=${FM_WATCH_SESSION_TMUX_SESSION:-firstmate-watch}
HASH=$(printf '%s\n%s\n' "$FM_HOME" "$STATE" | cksum | awk '{print $1}')
WINDOW_NAME=${FM_WATCH_SESSION_TMUX_WINDOW:-fm-watch-$HASH}
TARGET="$SESSION_NAME:$WINDOW_NAME"
SESSION_DIR="$STATE/.watch-session"
ENV_FILE="$SESSION_DIR/env.sh"
RUNNER_FILE="$SESSION_DIR/runner.sh"
STOP_FILE="$SESSION_DIR/stop"
RETRY_DELAY=${FM_WATCH_SESSION_REARM_DELAY:-${FM_WATCH_SESSION_RETRY_DELAY:-1}}
AFK_DELAY=${FM_WATCH_SESSION_AFK_DELAY:-15}

usage() {
  echo "usage: $(basename "$0") [start|--status|status|stop|restart]" >&2
}

shell_quote() {
  # POSIX single-quote escaping.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

tmux_window_exists() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 1
  tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -Fx "$WINDOW_NAME" >/dev/null
}

write_runner_files() {
  mkdir -p "$SESSION_DIR"
  {
    printf 'export FM_HOME=%s\n' "$(shell_quote "$FM_HOME")"
    printf 'export FM_ROOT_OVERRIDE=%s\n' "$(shell_quote "$FM_ROOT")"
    printf 'export FM_STATE_OVERRIDE=%s\n' "$(shell_quote "$STATE")"
    printf 'export PATH=%s\n' "$(shell_quote "$PATH")"
  } > "$ENV_FILE"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '. %s\n' "$(shell_quote "$ENV_FILE")"
    printf 'rm -f %s\n' "$(shell_quote "$STOP_FILE")"
    printf 'while :; do\n'
    printf '  [ -e %s ] && exit 0\n' "$(shell_quote "$STOP_FILE")"
    # shellcheck disable=SC2016 # Generated runner expands FM_STATE_OVERRIDE at runtime.
    printf '  if [ -e "$FM_STATE_OVERRIDE/.afk" ]; then sleep %s; continue; fi\n' "$AFK_DELAY"
    printf '  %s/fm-watch-arm.sh\n' "$(shell_quote "$SCRIPT_DIR")"
    printf '  rc=$?\n'
    printf '  [ -e %s ] && exit 0\n' "$(shell_quote "$STOP_FILE")"
    # shellcheck disable=SC2016 # Generated runner expands rc at runtime.
    printf '  if [ "$rc" -ne 0 ]; then sleep %s; else sleep 1; fi\n' "$RETRY_DELAY"
    printf 'done\n'
  } > "$RUNNER_FILE"
  chmod +x "$RUNNER_FILE"
}

start_runner() {
  local command
  if ! command -v tmux >/dev/null 2>&1; then
    echo "watch-session: FAILED - tmux not found" >&2
    return 1
  fi
  if tmux_window_exists; then
    echo "watch-session: running target=$TARGET home=$FM_HOME"
    return 0
  fi
  command="bash $(shell_quote "$RUNNER_FILE")"
  write_runner_files
  rm -f "$STOP_FILE"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux new-window -d -t "$SESSION_NAME:" -n "$WINDOW_NAME" "$command" || {
      echo "watch-session: FAILED - could not start target=$TARGET" >&2
      return 1
    }
  else
    tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" "$command" || {
      echo "watch-session: FAILED - could not start target=$TARGET" >&2
      return 1
    }
  fi
  echo "watch-session: started target=$TARGET home=$FM_HOME"
}

status_runner() {
  if tmux_window_exists; then
    echo "watch-session: running target=$TARGET home=$FM_HOME"
    return 0
  fi
  echo "watch-session: stopped home=$FM_HOME"
  return 1
}

stop_runner() {
  touch "$STOP_FILE" 2>/dev/null || true
  if tmux_window_exists; then
    tmux kill-window -t "$TARGET"
    echo "watch-session: stopped target=$TARGET home=$FM_HOME"
    return 0
  fi
  echo "watch-session: stopped home=$FM_HOME"
  return 0
}

mode=${1:-start}
case "$mode" in
  start|--start) start_runner ;;
  status|--status) status_runner ;;
  stop|--stop) stop_runner ;;
  restart|--restart) stop_runner >/dev/null; start_runner ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
