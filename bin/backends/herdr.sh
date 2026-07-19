#!/usr/bin/env bash
# bin/backends/herdr.sh - experimental Herdr session-provider adapter.
#
# Herdr is a session provider only. Treehouse remains the worktree provider,
# just as it does for tmux. This JT port targets Herdr protocol >=14 and the
# 0.7.x CLI. It deliberately uses the pull primitives needed by PR1; native
# event delivery and AFK/supervisor injection remain PR3 work.
#
# One Herdr workspace is kept per firstmate home: `firstmate` for the primary
# and `2ndmate-<id>` for a seeded secondmate home. Each task is one tab with a
# single root pane. Targets are `<session>:<pane-id>`; pane ids contain a colon,
# so parsing always splits on the first colon only.

FM_BACKEND_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_HERDR_MIN_PROTOCOL=14
FM_BACKEND_HERDR_SECONDMATE_MARKER=.fm-secondmate-home
FM_BACKEND_HERDR_HOME_TOKEN=firstmate_home
FM_BACKEND_HERDR_VERSION_VERIFIED=0
FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS=${FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS:-100}

fm_backend_herdr_workspace_label() {
  local marker="$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" id
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    [ -n "$id" ] && { printf '2ndmate-%s' "$id"; return 0; }
  fi
  printf 'firstmate'
}

# Herdr 0.7.x has ambient environment support, but the CLI can silently route
# to another running server when only HERDR_SESSION is set. Keep the env marker
# for compatibility and always append the explicit session flag.
fm_backend_herdr_cli() {  # <session> <herdr args...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

fm_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || {
    echo "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev; dual-licensed AGPL-3.0-or-later/commercial)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=herdr selected but 'jq' is not installed (required for Herdr JSON output)" >&2
    return 1
  }
}

fm_backend_herdr_version_check() {
  [ "$FM_BACKEND_HERDR_VERSION_VERIFIED" -eq 1 ] && return 0
  fm_backend_herdr_tool_check || return 1
  local out protocol version
  out=$(herdr status --json 2>/dev/null) || {
    echo "error: 'herdr status --json' failed; is Herdr installed correctly?" >&2
    return 1
  }
  protocol=$(printf '%s' "$out" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$out" | jq -r '.client.version // empty' 2>/dev/null)
  case "$version" in
    0.7.[0-9]*|v0.7.[0-9]*) ;;
    *)
      echo "error: Herdr client version ${version:-unknown} is outside the verified 0.7.x range" >&2
      return 1
      ;;
  esac
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read Herdr client protocol; refusing an unverified build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: Herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL" >&2
    return 1
  fi
  FM_BACKEND_HERDR_VERSION_VERIFIED=1
}

fm_backend_herdr_home_identity() {
  local home=$FM_HOME
  if [ -d "$home" ]; then
    home=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  fi
  command -v sha256sum >/dev/null 2>&1 || return 1
  printf '%s' "$home" | sha256sum | cut -d' ' -f1
}

fm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

fm_backend_herdr_workspace_lock_path() {
  printf '%s/.fm-herdr-workspace.lock' "$FM_HOME"
}

fm_backend_herdr_workspace_lock_acquire() {
  local lock=$1 attempt=0
  [ -d "$FM_HOME" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    [ "$attempt" -lt "$FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS" ] || return 1
    sleep 0.1
    attempt=$((attempt + 1))
  done
  printf '%s\n' "${BASHPID:-$$}" > "$lock/pid" || {
    rmdir "$lock" 2>/dev/null || true
    return 1
  }
}

fm_backend_herdr_workspace_lock_release() {
  local lock=$1 owner
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  [ "$owner" = "${BASHPID:-$$}" ] || return 1
  rm -f "$lock/pid"
  rmdir "$lock" 2>/dev/null
}

fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null || true)
  running=$(printf '%s' "$out" | jq -r '.server.running // false' 2>/dev/null || true)
  [ "$running" = true ] && return 0
  (fm_backend_herdr_cli "$session" server >/dev/null 2>&1 &)
  for i in $(seq 1 20); do
    out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null || true)
    running=$(printf '%s' "$out" | jq -r '.server.running // false' 2>/dev/null || true)
    [ "$running" = true ] && return 0
    sleep 0.5
  done
  echo "error: Herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

fm_backend_herdr_server_available() {  # <session>
  local session=$1 out running
  out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null) || return 1
  running=$(printf '%s' "$out" | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = true ]
}

fm_backend_herdr_workspace_find() {  # <session>
  local session=$1 out label home_id
  label=$(fm_backend_herdr_workspace_label)
  home_id=$(fm_backend_herdr_home_identity) || return 1
  out=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r --arg want "$label" --arg home "$home_id" --arg token "$FM_BACKEND_HERDR_HOME_TOKEN" '
    if (.result | type) != "object" or (.result.workspaces | type) != "array" then
      error("invalid workspace list response")
    elif any(.result.workspaces[]; type != "object" or (.workspace_id | type) != "string" or (.label | type) != "string") then
      error("invalid workspace entry")
    else
      [.result.workspaces[] | select(.label == $want and (.tokens | type) == "object" and .tokens[$token] == $home) | .workspace_id] as $matches
      | if ($matches | length) > 1 then error("multiple matching workspaces") else ($matches[0] // empty) end
    end
  ' 2>/dev/null
}

fm_backend_herdr_workspace_bind_home() {  # <session> <workspace>
  local session=$1 wsid=$2 home_id
  home_id=$(fm_backend_herdr_home_identity) || return 1
  fm_backend_herdr_cli "$session" workspace report-metadata "$wsid" \
    --source firstmate --token "$FM_BACKEND_HERDR_HOME_TOKEN=$home_id" >/dev/null 2>&1
}

fm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 lock
  lock=$(fm_backend_herdr_workspace_lock_path) || return 1
  (
    local label wsid out seeded
    fm_backend_herdr_workspace_lock_acquire "$lock" || exit 1
    trap 'fm_backend_herdr_workspace_lock_release "$lock"' EXIT
    label=$(fm_backend_herdr_workspace_label)
    wsid=$(fm_backend_herdr_workspace_find "$session") || exit 1
    if [ -n "$wsid" ]; then
      printf '%s' "$wsid"
      exit 0
    fi
    out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || exit 1
    wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    seeded=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
    [ -n "$wsid" ] || exit 1
    if ! fm_backend_herdr_workspace_bind_home "$session" "$wsid"; then
      fm_backend_herdr_cli "$session" workspace close "$wsid" >/dev/null 2>&1 || true
      exit 1
    fi
    if [ -n "$seeded" ]; then
      printf '%s\t%s' "$wsid" "$seeded"
    else
      printf '%s' "$wsid"
    fi
  )
}

fm_backend_herdr_container_ensure() {  # <cwd> -> session:workspace<TAB>seeded-tab
  local cwd=${1:-$PWD} session ws
  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  ws=$(fm_backend_herdr_workspace_ensure "$session" "$cwd") || {
    echo "error: failed to ensure Herdr workspace '$(fm_backend_herdr_workspace_label)' in session '$session'" >&2
    return 1
  }
  printf '%s:%s' "$session" "$ws"
}

fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 seeded=$3 tabs
  [ -n "$seeded" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  printf '%s' "$tabs" | jq -e --arg tabid "$seeded" \
    '.result.tabs[]? | select(.tab_id == $tabid and .label == "1")' >/dev/null 2>&1 || return 0
  fm_backend_herdr_cli "$session" tab close "$seeded" >/dev/null 2>&1 || true
}

fm_backend_herdr_tab_close_by_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tabs tab_id
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$tabs" | jq -r --arg want "$label" '
    if (.result | type) != "object" or (.result.tabs | type) != "array" then
      error("invalid tab list response")
    elif any(.result.tabs[]; type != "object" or (.tab_id | type) != "string" or (.label | type) != "string") then
      error("invalid tab entry")
    else
      [.result.tabs[] | select(.label == $want) | .tab_id] as $matches
      | if ($matches | length) == 1 then $matches[0] elif ($matches | length) == 0 then empty else error("multiple matching tabs") end
    end
  ' 2>/dev/null)
  [ -n "$tab_id" ] || return 1
  fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1
}

fm_backend_herdr_create_task() {  # <container> <label> <cwd> [seeded-default-tab]
  local container=$1 label=$2 cwd=$3 seeded=${4:-} session wsid tabs dup out tab_id pane_id
  session=${container%%:*}
  wsid=${container#*:}
  if [[ "$wsid" == *$'\t'* ]]; then
    [ -n "$seeded" ] || seeded=${wsid#*$'\t'}
    wsid=${wsid%%$'\t'*}
  fi
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup=$(printf '%s' "$tabs" | jq -r --arg want "$label" \
    '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null | head -1)
  if [ -n "$dup" ]; then
    echo "error: Herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
    return 1
  fi
  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    fm_backend_herdr_tab_close_by_label "$session" "$wsid" "$label" >/dev/null 2>&1 || true
    echo "error: could not parse Herdr tab/pane id from tab create output" >&2
    return 1
  fi
  fm_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded"
  printf '%s %s' "$tab_id" "$pane_id"
}

fm_backend_herdr_parse_target() {  # <session>:<pane-id>
  local target=$1
  FM_BACKEND_HERDR_SESSION=${target%%:*}
  FM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$FM_BACKEND_HERDR_SESSION" ] && [ -n "$FM_BACKEND_HERDR_PANE" ] \
    && [ "$FM_BACKEND_HERDR_PANE" != "$target" ]
}

fm_backend_herdr_target_ready() {
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_version_check || return 1
  fm_backend_herdr_server_available "$FM_BACKEND_HERDR_SESSION"
}

fm_backend_herdr_pane_readable() {
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1
}

fm_backend_herdr_current_path() {
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

fm_backend_herdr_send_text_line() {
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane run "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

fm_backend_herdr_send_literal() {
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-text "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

fm_backend_herdr_normalize_key() {
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_herdr_send_key() {
  fm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

fm_backend_herdr_submit_enter() {
  fm_backend_herdr_send_key "$1" Enter
}

fm_backend_herdr_capture() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-40} fetch out
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fetch=$lines
  [ "$fetch" -ge 200 ] 2>/dev/null || fetch=200
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 composer_state i=0
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_herdr_send_key "$target" Enter || true
    sleep "$sleep_s"
    composer_state=$(fm_backend_herdr_composer_state "$target" "$text")
    case "$composer_state" in
      empty) printf 'empty'; return 0 ;;
      pending) ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_backend_herdr_composer_state() {  # <target> <text> -> empty|pending|unknown
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local text=$2 out last
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source visible --lines 1 2>/dev/null) || { printf 'unknown'; return 0; }
  last=$(printf '%s' "$out" | tail -n 1)
  if [ -n "$text" ] && printf '%s' "$last" | grep -F -- "$text" >/dev/null 2>&1; then
    printf 'pending'
  else
    printf 'empty'
  fi
}

fm_backend_herdr_agent_status() {  # <target> -> idle|working|blocked|done|unknown
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local out status
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" agent get "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    idle|working|blocked|done) printf '%s' "$status" ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_kill() {
  local panes
  fm_backend_herdr_target_ready "$1" || return 1
  if ! fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1; then
    fm_backend_herdr_pane_absent || return 1
    return 0
  fi
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane close "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || return 1
  fm_backend_herdr_pane_absent
}

fm_backend_herdr_pane_absent() {
  local panes
  panes=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane list 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg pane "$FM_BACKEND_HERDR_PANE" '
    (.result | type) == "object"
    and (.result.panes | type) == "array"
    and all(.result.panes[]; type == "object" and (.pane_id | type) == "string")
    and all(.result.panes[]; .pane_id != $pane)
  ' >/dev/null 2>&1
}

fm_backend_herdr_busy_state() {
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local out status
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" agent get "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working) printf 'busy' ;;
    idle|done|blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_list_task_ids() {  # <session:workspace>
  local container=$1 session=${1%%:*} wsid=${1#*:} tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -r '.result.tabs[]?.tab_id // empty' 2>/dev/null
}

# These lifecycle operations are tmux-only in the generic spawn setup. They
# remain explicit no-ops for callers that probe the shared interface.
fm_backend_herdr_set_task_option() { return 0; }
fm_backend_herdr_rename_task() { return 0; }
fm_backend_herdr_task_name() { fm_backend_herdr_parse_target "$1" && printf '%s' "$FM_BACKEND_HERDR_PANE"; }
