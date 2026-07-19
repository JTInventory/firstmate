#!/usr/bin/env bash
# fm-backend.sh - runtime session-provider selection, metadata helpers, and
# operation dispatch. Tmux remains the default; Herdr is experimental and
# opt-in through FM_BACKEND, config/backend, or its runtime marker.
#
# A missing backend= in task metadata is the compatibility spelling for tmux.
# New default-tmux spawns deliberately omit backend= so existing metadata and
# the default path remain unchanged. Later adapters add dispatch arms here and
# do not need to change callers.

FM_BACKEND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_BACKEND_KNOWN="tmux herdr"

fm_backend_is_known() {  # <name>
  local name=$1 known
  for known in $FM_BACKEND_KNOWN; do
    [ "$name" = "$known" ] && return 0
  done
  return 1
}

# Detect the innermost session provider. A tmux pane nested inside Herdr has
# both markers; $TMUX wins because it describes the provider running this shell.
fm_backend_detect() {
  FM_BACKEND_DETECTED=
  FM_BACKEND_DETECT_SIGNAL=
  if [ -n "${TMUX:-}" ]; then
    FM_BACKEND_DETECTED=tmux
    FM_BACKEND_DETECT_SIGNAL=TMUX
    export FM_BACKEND_DETECT_SIGNAL
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ]; then
    FM_BACKEND_DETECTED=herdr
    FM_BACKEND_DETECT_SIGNAL=HERDR_ENV
    export FM_BACKEND_DETECT_SIGNAL
    printf 'herdr'
    return 0
  fi
  return 1
}

# Resolve a backend for a new task. Explicit --backend is handled by the
# caller and has higher precedence than this helper.
fm_backend_name() {
  local line value detected
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  if [ -f "$FM_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      value=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
      fi
    done < "$FM_BACKEND_CONFIG_DIR/backend"
  fi
  if fm_backend_detect >/dev/null; then
    detected=$FM_BACKEND_DETECTED
    if [ "$detected" = herdr ]; then
      echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    printf '%s' "$detected"
    return 0
  fi
  printf 'tmux'
}

# Bootstrap checks only dependencies for the backend resolved for new spawns.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    tmux) printf '%s' 'tmux treehouse' ;;
    herdr) printf '%s' 'herdr jq treehouse' ;;
    *) return 1 ;;
  esac
}

fm_backend_validate() {  # <name>
  local name=$1
  if ! fm_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
    return 1
  fi
}

fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_backend_of_meta() {  # <meta-file>
  local value
  value=$(fm_meta_get "$1" backend)
  printf '%s' "${value:-tmux}"
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" window)" = "$target" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  case "$raw" in
    fm-*)
      meta="$state/${raw#fm-}.meta"
      [ -f "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
      ;;
  esac
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

fm_backend_source() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  case "$name" in
    tmux)
      if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/tmux.sh
        . "$FM_BACKEND_LIB_DIR/backends/tmux.sh"
        _FM_BACKEND_TMUX_SOURCED=1
      fi
      ;;
    herdr)
      if [ -z "${_FM_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/herdr.sh
        . "$FM_BACKEND_LIB_DIR/backends/herdr.sh"
        _FM_BACKEND_HERDR_SOURCED=1
      fi
      ;;
  esac
}

fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      ;;
    fm-*)
      meta="$state/${raw#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
        return 1
      fi
      window=$(fm_meta_get "$meta" window)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; return 1; }
      printf '%s' "$window"
      ;;
    *)
      fm_backend_source tmux || return 1
      fm_backend_tmux_resolve_bare_selector "$raw"
      ;;
  esac
}

# Generic dispatch wrappers. Backend-specific adapters own command spelling;
# callers pass an opaque backend and target.
fm_backend_capture() {  # <backend> <target> <lines>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_capture "$@" ;;
    herdr) fm_backend_herdr_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_send_key() {  # <backend> <target> <key>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_key "$@" ;;
    herdr) fm_backend_herdr_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_text_submit "$@" ;;
    herdr) fm_backend_herdr_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_submit_enter() {  # <backend> <target> <retries> <enter-sleep>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_submit_enter "$@" ;;
    herdr) fm_backend_herdr_submit_enter "$@" ;;
    *) echo "error: no submit-enter implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_kill() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_kill "$@" ;;
    herdr) fm_backend_herdr_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_busy_state() {  # <backend> <target> -> busy|idle|unknown
  local backend=$1; shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) printf 'unknown' ;;
    herdr) fm_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_pane_readable() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_pane_readable "$@" ;;
    herdr) fm_backend_herdr_pane_readable "$@" ;;
    *) echo "error: no pane-readability implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_container_ensure() {  # <backend> <cwd>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_container_ensure "$@" ;;
    herdr) fm_backend_herdr_container_ensure "$@" ;;
    *) echo "error: no container implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_create_task() {  # <backend> <container> <label> <cwd>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_create_task "$@" ;;
    herdr) fm_backend_herdr_create_task "$@" ;;
    *) echo "error: no task-create implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_list_task_ids() {  # <backend> <container>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_list_task_ids "$@" ;;
    herdr) fm_backend_herdr_list_task_ids "$@" ;;
    *) echo "error: no task-list implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_set_task_option() {  # <backend> <target> <option> <value>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_set_task_option "$@" ;;
    herdr) fm_backend_herdr_set_task_option "$@" ;;
    *) echo "error: no task-option implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_rename_task() {  # <backend> <target> <name>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_rename_task "$@" ;;
    herdr) fm_backend_herdr_rename_task "$@" ;;
    *) echo "error: no task-rename implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_task_name() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_task_name "$@" ;;
    herdr) fm_backend_herdr_task_name "$@" ;;
    *) echo "error: no task-name implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_current_path() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_current_path "$@" ;;
    herdr) fm_backend_herdr_current_path "$@" ;;
    *) echo "error: no current-path implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_send_text_line() {  # <backend> <target> <text>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_text_line "$@" ;;
    herdr) fm_backend_herdr_send_text_line "$@" ;;
    *) echo "error: no send-text-line implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_send_literal() {  # <backend> <target> <text>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_literal "$@" ;;
    herdr) fm_backend_herdr_send_literal "$@" ;;
    *) echo "error: no literal-send implementation for backend '$backend'" >&2; return 1 ;
  esac
}
