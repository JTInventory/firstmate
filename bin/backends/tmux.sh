#!/usr/bin/env bash
# tmux session-provider adapter. This file is sourced by fm-backend.sh.
# The command shapes intentionally match the pre-abstraction JT scripts.

# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

fm_backend_tmux_send_key() {  # <target> <key>
  tmux send-keys -t "$1" "$2"
}

fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

fm_backend_tmux_submit_enter() {  # <target> <retries> <enter-sleep>
  fm_tmux_submit_enter_core "$@"
}

fm_backend_tmux_pane_readable() {  # <target>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

fm_backend_tmux_composer_state() {  # <target>
  fm_tmux_composer_state "$@"
}

fm_backend_tmux_container_ensure() {  # <cwd ignored>
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    if ! tmux has-session -t firstmate 2>/dev/null; then
      tmux new-session -d -s firstmate || return 1
    fi
    printf 'firstmate'
  fi
}

fm_backend_tmux_create_task() {  # <session> <window-name> <project-dir> -> window id
  local ses=$1 wname=$2 proj_abs=$3
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs"
}

fm_backend_tmux_list_task_ids() {  # <session>
  tmux list-windows -t "$1" -F '#{window_id}'
}

fm_backend_tmux_set_task_option() {  # <target> <option> <value>
  tmux set-window-option -t "$1" "$2" "$3"
}

fm_backend_tmux_pane_id() {
  local pane number
  pane=$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  case "$pane" in %*) ;; *) return 1 ;; esac
  number=${pane#%}
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pane"
}

fm_backend_tmux_single_pane_id() {
  local target=$1 panes pane count
  panes=$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null) || return 1
  count=$(printf '%s\n' "$panes" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || return 1
  pane=$(printf '%s\n' "$panes" | sed '/^$/d')
  fm_backend_tmux_pane_id "$pane"
}

fm_backend_tmux_bind_endpoint_generation() {
  local pane=$1 generation=$2 number
  case "$pane" in %*) ;; *) return 1 ;; esac
  number=${pane#%}
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
  tmux set-option -p -t "$pane" @firstmate_endpoint_generation "$generation" \
    || return 1
  [ "$(tmux show-options -p -v -t "$pane" \
    @firstmate_endpoint_generation 2>/dev/null)" = "$generation" ]
}

fm_backend_tmux_pane_generation_unset() {
  local pane=$1 options count
  case "$pane" in %*) ;; *) return 1 ;; esac
  case "${pane#%}" in ''|*[!0-9]*) return 1 ;; esac
  options=$(tmux show-options -p -t "$pane" 2>/dev/null) || return 1
  count=$(printf '%s\n' "$options" \
    | awk '$1 == "@firstmate_endpoint_generation" {count++} END {print count + 0}')
  [ "$count" -eq 0 ]
}

fm_backend_tmux_pane_generation_recorded() {
  local pane=$1 options values count
  case "$pane" in %*) ;; *) return 1 ;; esac
  case "${pane#%}" in ''|*[!0-9]*) return 1 ;; esac
  options=$(tmux show-options -p -t "$pane" 2>/dev/null) || return 1
  values=$(printf '%s\n' "$options" \
    | awk '$1 == "@firstmate_endpoint_generation" {print $2}')
  count=$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$values"
}

fm_backend_tmux_pane_window_id() {
  local pane=$1 window
  pane=$(fm_backend_tmux_pane_id "$pane") || return 1
  window=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  case "$window" in @*) ;; *) return 1 ;; esac
  case "${window#@}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$window"
}

fm_backend_tmux_endpoint_generation() {
  local target=$1 compatibility=${2:-} pane
  case "$target" in
    %*) tmux show-options -p -v -t "$target" \
      @firstmate_endpoint_generation 2>/dev/null ;;
    *)
      [ "$compatibility" = legacy-window ] || return 1
      pane=$(fm_backend_tmux_single_pane_id "$target") || return 1
      [ -n "$pane" ] || return 1
      local generation current
      generation=$(tmux show-options -w -v -t "$target" \
        @firstmate_endpoint_generation 2>/dev/null) || return 1
      current=$(fm_backend_tmux_single_pane_id "$target") || return 1
      [ "$current" = "$pane" ] || return 1
      printf '%s' "$generation"
      ;;
  esac
}

fm_backend_tmux_endpoint_identity() {
  local target=$1 pane window window_number generation
  case "$target" in %*) ;; *) return 1 ;; esac
  pane=$(fm_backend_tmux_pane_id "$target") || return 1
  window=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  case "$window" in @*) ;; *) return 1 ;; esac
  window_number=${window#@}
  case "$window_number" in ''|*[!0-9]*) return 1 ;; esac
  generation=$(fm_backend_tmux_endpoint_generation "$pane") || return 1
  [ -n "$generation" ] || return 1
  printf '%s|%s|%s' "$window" "$pane" "$generation"
}

fm_backend_tmux_foreground_process_pid() {
  local target=$1 shell foreground current
  shell=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  case "$shell" in ''|*[!0-9]*) return 1 ;; esac
  foreground=$(ps -o tpgid= -p "$shell" 2>/dev/null | tr -d '[:space:]') \
    || return 1
  case "$foreground" in ''|*[!0-9]*) return 1 ;; esac
  [ "$foreground" -gt 1 ] && [ "$foreground" != "$shell" ] || return 1
  current=$(ps -o pgid= -p "$foreground" 2>/dev/null | tr -d '[:space:]') \
    || return 1
  [ "$current" = "$foreground" ] || return 1
  printf '%s' "$foreground"
}

fm_backend_tmux_launch_trusted_process() {
  local target=$1 name=$2 cwd=$3 command=$4 expected=$5 pid current identity
  identity=$(fm_backend_tmux_endpoint_identity "$target") || return 1
  [ "$identity" = "$expected" ] || return 1
  pid=$(tmux respawn-pane -k -t "$target" -c "$cwd" "exec env $command" \; \
    display-message -p -t "$target" '#{pane_pid}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  current=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  [ "$current" = "$pid" ] || return 1
  identity=$(fm_backend_tmux_endpoint_identity "$target") || return 1
  [ "$identity" = "$expected" ] || return 1
  printf '%s' "$pid"
}

fm_backend_tmux_launch_process_is_current() {
  local target=$1 expected=$2 expected_identity=$3 current identity
  current=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  [ "$current" = "$expected" ] || return 1
  identity=$(fm_backend_tmux_endpoint_identity "$target") || return 1
  [ "$identity" = "$expected_identity" ]
}

fm_backend_tmux_rename_task() {  # <target> <name>
  tmux rename-window -t "$1" "$2"
}

fm_backend_tmux_task_name() {  # <target>
  tmux display-message -p -t "$1" '#{window_name}'
}

fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
    inventory_status=0
  else
    inventory_status=$?
  fi
  if [ "$inventory_status" -ne 0 ]; then
    case "$windows" in
      *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi
  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  comm=${comm#-}
  case "$comm" in
    *claude*|*codex*|*opencode*|*grok*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    '') printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

fm_backend_tmux_kill() {  # <target>
  local target=$1 windows window_id window_target
  tmux kill-window -t "$target" 2>/dev/null && return 0
  windows=$(tmux list-windows -a -F '#{window_id}|#{session_name}:#{window_name}' 2>/dev/null) || return 1
  while IFS='|' read -r window_id window_target; do
    case "$target" in
      @*) [ "$window_id" = "$target" ] || continue ;;
      *) [ "$window_target" = "$target" ] || continue ;;
    esac
    return 1
  done <<EOF
$windows
EOF
  return 0
}
