#!/usr/bin/env bash

FM_WATCHER_PROTOCOL_VERSION='pending-reply-ticket-v3'
_FM_WATCHER_PROTOCOL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" \
  || _FM_WATCHER_PROTOCOL_LIB_DIR="."
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_WATCHER_PROTOCOL_LIB_DIR/fm-wake-lib.sh"

fm_watcher_protocol_marker() {
  printf '%s/.watch-protocol-required' "$1"
}

fm_watcher_protocol_reread_marker() {
  printf '%s/.watch-protocol-reread-required' "$1"
}

fm_watcher_protocol_lock_proves_current() {
  local state=$1 home=$2 watch=$3 lock pid
  lock="$state/.watch.lock"
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  fm_watcher_lock_matches_pid "$lock" "$pid" "$home" "$watch" || return 1
  [ "$(cat "$lock/pending-reply-protocol" 2>/dev/null || true)" = "$FM_WATCHER_PROTOCOL_VERSION" ]
}

fm_watcher_protocol_follower_proves_current() {
  local state=$1 home=$2 arm=$3 lock pid stored_start stored_identity
  lock="$state/.watch-arm.lock"
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_pid_is_zombie "$pid" && return 1
  [ "$(cat "$lock/fm-home" 2>/dev/null || true)" = "$home" ] || return 1
  [ "$(cat "$lock/owner-path" 2>/dev/null || true)" = "$arm" ] || return 1
  stored_start=$(cat "$lock/pid-start" 2>/dev/null || true)
  [ -n "$stored_start" ] || return 1
  fm_pid_start_matches_stored "$pid" "$stored_start" || return 1
  stored_identity=$(cat "$lock/pid-identity" 2>/dev/null || true)
  [ -n "$stored_identity" ] || return 1
  fm_pid_identity_matches_stored "$pid" "$stored_identity"
}

fm_watcher_protocol_daemon_proves_current() {
  local state=$1 home=$2 watch=$3 daemon pid start identity path watcher_pid watcher_parent
  [ -e "$state/.afk" ] || return 1
  daemon="$(dirname "$watch")/fm-supervise-daemon.sh"
  pid=$(cat "$state/.supervise-daemon.pid" 2>/dev/null || true)
  start=$(cat "$state/.supervise-daemon.pid-start" 2>/dev/null || true)
  identity=$(cat "$state/.supervise-daemon.pid-identity" 2>/dev/null || true)
  path=$(cat "$state/.supervise-daemon.pid-path" 2>/dev/null || true)
  [ "$path" = "$daemon" ] || return 1
  fm_pid_alive "$pid" || return 1
  fm_pid_is_zombie "$pid" && return 1
  fm_pid_start_matches_stored "$pid" "$start" || return 1
  fm_pid_identity_matches_stored "$pid" "$identity" || return 1
  fm_pid_command_matches_path "$pid" "$daemon" || return 1
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  watcher_parent=$(LC_ALL=C ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  [ "$watcher_parent" = "$pid" ]
}

fm_watcher_protocol_mark_required() {
  local state=$1 marker tmp
  marker=$(fm_watcher_protocol_marker "$state")
  mkdir -p "$state" || return 1
  [ "$(cat "$marker" 2>/dev/null || true)" = "$FM_WATCHER_PROTOCOL_VERSION" ] && return 0
  tmp=$(mktemp "$state/.watch-protocol-required.XXXXXX") || return 1
  printf '%s\n' "$FM_WATCHER_PROTOCOL_VERSION" > "$tmp" \
    && chmod 600 "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$marker" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

fm_watcher_protocol_mark_reread_required() {
  local state=$1 marker tmp
  marker=$(fm_watcher_protocol_reread_marker "$state")
  mkdir -p "$state" || return 1
  tmp=$(mktemp "$state/.watch-protocol-reread-required.XXXXXX") || return 1
  printf '%s\n' "$FM_WATCHER_PROTOCOL_VERSION" > "$tmp" \
    && chmod 600 "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$marker" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

fm_watcher_protocol_gate() {
  local state=$1 home=$2 watch=$3 marker lock_pid arm
  marker=$(fm_watcher_protocol_marker "$state")
  arm="$(dirname "$watch")/fm-watch-arm.sh"
  if fm_watcher_protocol_lock_proves_current "$state" "$home" "$watch" \
    && { fm_watcher_protocol_follower_proves_current "$state" "$home" "$arm" \
      || fm_watcher_protocol_daemon_proves_current "$state" "$home" "$watch"; }; then
    rm -f "$marker" 2>/dev/null || return 1
    return 0
  fi
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -f "$marker" ] || { [ -n "$lock_pid" ] && fm_pid_alive "$lock_pid"; }; then
    fm_watcher_protocol_mark_required "$state" || return 1
    return 1
  fi
  return 0
}

fm_watcher_protocol_acknowledge() {
  local state=$1 home=$2 watch=$3 lock marker tmp
  lock="$state/.watch.lock"
  marker=$(fm_watcher_protocol_marker "$state")
  [ "$(cat "$lock/fm-home" 2>/dev/null || true)" = "$home" ] || return 1
  [ "$(cat "$lock/watcher-path" 2>/dev/null || true)" = "$watch" ] || return 1
  tmp="$lock/.pending-reply-protocol.$$.$RANDOM"
  printf '%s\n' "$FM_WATCHER_PROTOCOL_VERSION" > "$tmp" \
    && mv -f "$tmp" "$lock/pending-reply-protocol" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  [ -f "$marker" ] || return 0
}

fm_watcher_protocol_restart_if_required() {
  local home=$1 state=$2 root=$3 watch arm out x_mode restart_required
  watch="$root/bin/fm-watch.sh"
  arm="$root/bin/fm-watch-arm.sh"
  FM_WATCHER_PROTOCOL_RESTARTED=0
  restart_required=0
  [ -f "$(fm_watcher_protocol_marker "$state")" ] && restart_required=1
  if fm_watcher_protocol_gate "$state" "$home" "$watch"; then
    [ "$restart_required" -eq 1 ] && FM_WATCHER_PROTOCOL_RESTARTED=1
    return 0
  fi
  [ -x "$arm" ] || return 1
  [ ! -e "$state/.afk" ] || {
    printf '%s\n' 'watcher: FAILED - AFK daemon owns watcher lifecycle' >&2
    return 1
  }
  x_mode="$home/config/x-mode.env"
  if [ -f "$x_mode" ]; then
    out=$(
      # shellcheck source=/dev/null
      . "$x_mode" || exit 1
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" \
        "$arm" --restart-verify 2>&1
    ) || {
      printf '%s\n' "$out" >&2
      return 1
    }
  else
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" \
      "$arm" --restart-verify 2>&1) || {
        printf '%s\n' "$out" >&2
        return 1
      }
  fi
  fm_watcher_protocol_gate "$state" "$home" "$watch" || {
      printf '%s\n' "$out" >&2
      return 1
    }
  [ ! -f "$(fm_watcher_protocol_marker "$state")" ] || return 1
  # Read by callers after this function returns.
  # shellcheck disable=SC2034
  FM_WATCHER_PROTOCOL_RESTARTED=1
  printf '%s\n' "$out"
}
