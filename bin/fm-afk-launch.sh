#!/usr/bin/env bash
# Start and stop the JT away-mode daemon with process-group detachment.
#
# A plain nohup/background child remains in a harness-owned process group and
# can be reaped with the harness. fm_detach_spawn creates a fresh session and
# process group, waits for the daemon exec handshake, and returns its pid. The
# daemon's own pinned pid/start/identity files are then used for safe return.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-detach-lib.sh
. "$SCRIPT_DIR/fm-detach-lib.sh"

DAEMON="${FM_AFK_DAEMON_PATH:-$SCRIPT_DIR/fm-supervise-daemon.sh}"
PIDFILE="$STATE/.supervise-daemon.pid"
PID_START_FILE="$STATE/.supervise-daemon.pid-start"
PID_IDENTITY_FILE="$STATE/.supervise-daemon.pid-identity"
LAUNCH_LOG="$STATE/.supervise-daemon.launch.log"
CONFIRM_TIMEOUT=${FM_AFK_LAUNCH_CONFIRM_TIMEOUT:-10}

# Keep the launcher's flag operation small and local. The daemon defines the
# same contract for its pure-function tests, but sourcing the long-lived daemon
# here would also import its supervisor classifier and runtime globals.
afk_enter() {
  mkdir -p "$1"
  date '+%s' > "$1/.afk"
}

afk_exit() {
  rm -f "$1/.afk"
}

usage() {
  printf '%s\n' "usage: $(basename "$0") [start|status|stop]" >&2
}

daemon_owned() {  # 0 only when the recorded daemon is this live launch
  local pid start identity
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  start=$(cat "$PID_START_FILE" 2>/dev/null || true)
  identity=$(cat "$PID_IDENTITY_FILE" 2>/dev/null || true)
  [ -n "$pid" ] && [ -n "$start" ] && [ -n "$identity" ] || return 1
  fm_pid_alive "$pid" || return 1
  fm_pid_is_zombie "$pid" && return 1
  fm_pid_start_matches_stored "$pid" "$start" || return 1
  fm_pid_identity_matches_stored "$pid" "$identity" || return 1
  fm_pid_command_matches_path "$pid" "$DAEMON"
}

wait_for_daemon() {  # <pid returned by fm_detach_spawn>
  local expected=$1 deadline=$((SECONDS + CONFIRM_TIMEOUT)) pid
  while [ "$SECONDS" -lt "$deadline" ]; do
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ "$pid" = "$expected" ] && daemon_owned; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

new_detach_token() {
  local token_file token
  token_file=$(mktemp "${TMPDIR:-/tmp}/firstmate-afk-token.XXXXXX") || return 1
  token=${token_file##*/}
  rm -f "$token_file"
  printf '%s\n' "$token"
}

start_afk() {
  local token child confirmed child_start
  mkdir -p "$STATE"
  if daemon_owned; then
    afk_enter "$STATE"
    printf 'afk: already running pid=%s\n' "$(cat "$PIDFILE")"
    return 0
  fi
  [ -x "$DAEMON" ] || { printf 'afk: daemon not executable: %s\n' "$DAEMON" >&2; return 1; }
  afk_enter "$STATE"
  token=$(new_detach_token) || { printf '%s\n' 'afk: could not create detach token' >&2; return 1; }
  child=$(fm_detach_spawn "$LAUNCH_LOG" "$DAEMON" "--fm-detach-token=$token") || {
    printf 'afk: detached daemon launch failed (away flag retained): %s\n' "$DAEMON" >&2
    return 1
  }
  confirmed=$(wait_for_daemon "$child") || {
    child_start=$(fm_pid_start "$child" 2>/dev/null || true)
    if [ -n "$child_start" ]; then
      fm_detach_cleanup_unconfirmed "$child" "$child_start" "$DAEMON" \
        "--fm-detach-token=$token" "__fm_detach_launcher__" || true
    fi
    printf '%s\n' 'afk: daemon did not publish a verified pid record (away flag retained)' >&2
    return 1
  }
  printf 'afk: started detached daemon pid=%s\n' "$confirmed"
}

stop_afk() {
  local pid start i=0
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    afk_exit "$STATE"
    printf '%s\n' 'afk: stopped (no daemon record)'
    return 0
  fi
  if ! daemon_owned; then
    if fm_pid_alive "$pid"; then
      printf 'afk: daemon identity unverified; not signaling pid=%s\n' "$pid" >&2
      return 1
    fi
    afk_exit "$STATE"
    printf '%s\n' 'afk: stopped (daemon already gone)'
    return 0
  fi
  start=$(cat "$PID_START_FILE")
  if ! fm_detach_kill "$pid" "$start"; then
    printf 'afk: daemon stop refused by pinned identity check (pid=%s)\n' "$pid" >&2
    return 1
  fi
  while [ "$i" -lt 100 ] && fm_pid_alive "$pid" && ! fm_pid_is_zombie "$pid"; do
    sleep 0.05
    i=$((i + 1))
  done
  if fm_pid_alive "$pid" && ! fm_pid_is_zombie "$pid"; then
    printf 'afk: daemon did not stop after TERM (pid=%s)\n' "$pid" >&2
    return 1
  fi
  afk_exit "$STATE"
  printf 'afk: stopped daemon pid=%s\n' "$pid"
}

status_afk() {
  if [ -e "$STATE/.afk" ]; then
    if daemon_owned; then
      printf 'afk: active daemon=running pid=%s\n' "$(cat "$PIDFILE")"
    else
      printf '%s\n' 'afk: active daemon=not-verified'
      return 1
    fi
  elif daemon_owned; then
    printf 'afk: inactive daemon=running pid=%s\n' "$(cat "$PIDFILE")"
  else
    printf '%s\n' 'afk: inactive daemon=stopped'
  fi
}

case "${1:-start}" in
  start|--start) start_afk ;;
  stop|--stop|return|--return) stop_afk ;;
  status|--status) status_afk ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
