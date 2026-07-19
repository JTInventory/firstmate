#!/usr/bin/env bash
# bin/backends/herdr.sh - experimental Herdr session-provider adapter.
#
# Herdr is a session provider only. Treehouse remains the worktree provider,
# just as it does for tmux. This JT port targets Herdr protocol >=14 and the
# 0.7.x CLI. Event waits are optional and fail closed unless protocol 16 and
# the verified event schema are present; AFK/supervisor injection uses the
# adapter's pane send and read primitives when Herdr is selected.
#
# One Herdr workspace is kept per firstmate home: `firstmate` for the primary
# and `2ndmate-<id>` for a seeded secondmate home. Each task is one tab with a
# single root pane. Targets are `<session>:<pane-id>`; pane ids contain a colon,
# so parsing always splits on the first colon only.

FM_BACKEND_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_HERDR_MIN_PROTOCOL=14
FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL=16
FM_BACKEND_HERDR_SECONDMATE_MARKER=.fm-secondmate-home
FM_BACKEND_HERDR_HOME_TOKEN=firstmate_home
FM_BACKEND_HERDR_ESCALATED_PREFIX=.herdr-escalated-
FM_BACKEND_HERDR_VERSION_VERIFIED=0
FM_BACKEND_HERDR_VERSION_VERIFIED_SESSION=
FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS=${FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS:-100}

# shellcheck source=bin/fm-transition-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-transition-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-composer-lib.sh"

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
  local session=${1:-}
  [ -n "$session" ] && [ "$FM_BACKEND_HERDR_VERSION_VERIFIED_SESSION" = "$session" ] && return 0
  fm_backend_herdr_tool_check || return 1
  local out protocol version
  if [ -n "$session" ]; then
    out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null) || {
      echo "error: Herdr status --json failed for session '$session'; is Herdr available?" >&2
      return 1
    }
  else
    out=$(herdr status --json 2>/dev/null) || {
      echo "error: Herdr status --json failed for the default session; is Herdr installed correctly?" >&2
      return 1
    }
  fi
  [ -n "$out" ] || {
    echo "error: Herdr status --json failed for ${session:-the default session}; is Herdr installed correctly?" >&2
    return 1
  }
  protocol=$(printf '%s' "$out" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$out" | jq -r '.client.version // empty' 2>/dev/null)
  local version_tail
  case "$version" in
    0.7.*) version_tail=${version#0.7.} ;;
    *) version_tail= ;;
  esac
  case "$version_tail" in
    ''|*[!0-9]*)
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
  if [ -n "$session" ]; then
    FM_BACKEND_HERDR_VERSION_VERIFIED_SESSION=$session
  else
    FM_BACKEND_HERDR_VERSION_VERIFIED=1
  fi
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

fm_backend_herdr_pid_start() {
  local pid=$1 proc_stat out
  local -a proc_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/stat" ]; then
    proc_stat=$(cat "/proc/$pid/stat" 2>/dev/null || true)
    if [ -n "$proc_stat" ]; then
      proc_stat=${proc_stat##*) }
      read -r -a proc_fields <<< "$proc_stat"
      [ "${#proc_fields[@]}" -ge 20 ] && { printf 'proc:%s\n' "${proc_fields[19]}"; return 0; }
    fi
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' | awk 'NF { print "ps:" $0; exit }') || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_backend_herdr_lock_owner_status() {
  local lock=$1 pid start current owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null || true)
    [ -n "$owner" ] && [ -f "$owner" ] || return 1
    pid=$(sed -n '1p' "$owner" 2>/dev/null || true)
    start=$(sed -n '2p' "$owner" 2>/dev/null || true)
  elif [ -d "$lock" ]; then
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    start=$(cat "$lock/pid-start" 2>/dev/null || true)
  else
    return 2
  fi
  if [ -d "$lock" ] && [ -z "$start" ]; then
    case "$pid" in
      ''|*[!0-9]*)
        return 0
        ;;
      *)
        if ! kill -0 "$pid" 2>/dev/null; then
          return 1
        fi
        case "$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null)" in
          Z*) return 1 ;;
        esac
        return 0
        ;;
    esac
  fi
  case "$pid" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac
  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  case "$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null)" in
    Z*) return 1 ;;
  esac
  [ -n "$start" ] || return 0
  current=$(fm_backend_herdr_pid_start "$pid") || return 2
  [ "$current" = "$start" ] && return 0
  return 1
}

fm_backend_herdr_lock_discard() {
  local lock=$1 owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null || true)
    rm -f "$lock"
    case "$owner" in
      "$FM_HOME"/.fm-herdr-workspace.owner.*) rm -f "$owner" ;;
    esac
  elif [ -d "$lock" ]; then
    rm -f "$lock/pid" "$lock/pid-start"
    rmdir "$lock" 2>/dev/null || true
  else
    rm -f "$lock"
  fi
}

fm_backend_herdr_workspace_lock_acquire() {
  local lock=$1 attempt=0 stale_status quarantine pid start owner acquired=0
  [ -d "$FM_HOME" ] || return 1
  owner=$(mktemp "$FM_HOME/.fm-herdr-workspace.owner.XXXXXX" 2>/dev/null) || return 1
  pid=${BASHPID:-$$}
  start=$(fm_backend_herdr_pid_start "$pid") || { rm -f "$owner"; return 1; }
  printf '%s\n%s\n' "$pid" "$start" > "$owner" || { rm -f "$owner"; return 1; }
  while [ "$acquired" -eq 0 ]; do
    if [ ! -e "$lock" ] && [ ! -L "$lock" ] && ln -s "$owner" "$lock" 2>/dev/null; then
      acquired=1
      break
    fi
    fm_backend_herdr_lock_owner_status "$lock"
    stale_status=$?
    if [ "$stale_status" -eq 1 ]; then
      quarantine="$lock.stale.${BASHPID:-$$}.${RANDOM}"
      if [ ! -e "$quarantine" ] && mv "$lock" "$quarantine" 2>/dev/null; then
        fm_backend_herdr_lock_discard "$quarantine"
        continue
      fi
    fi
    if [ "$attempt" -ge "$FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS" ]; then
      rm -f "$owner"
      return 1
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
}

fm_backend_herdr_workspace_lock_release() {
  local lock=$1 owner_path owner stored_start current_start
  if [ -L "$lock" ]; then
    owner_path=$(readlink "$lock" 2>/dev/null || true)
    owner=$(sed -n '1p' "$owner_path" 2>/dev/null || true)
    stored_start=$(sed -n '2p' "$owner_path" 2>/dev/null || true)
  elif [ -d "$lock" ]; then
    owner_path=
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    stored_start=$(cat "$lock/pid-start" 2>/dev/null || true)
  else
    return 1
  fi
  [ "$owner" = "${BASHPID:-$$}" ] || return 1
  if [ -n "$stored_start" ]; then
    current_start=$(fm_backend_herdr_pid_start "$owner") || return 1
    [ "$stored_start" = "$current_start" ] || return 1
  fi
  if [ -n "$owner_path" ]; then
    rm -f "$lock" "$owner_path"
  else
    rm -f "$lock/pid" "$lock/pid-start"
    rmdir "$lock" 2>/dev/null
  fi
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
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_version_check "$session" || return 1
  fm_backend_herdr_server_ensure "$session" || return 1
  ws=$(fm_backend_herdr_workspace_ensure "$session" "$cwd") || {
    echo "error: failed to ensure Herdr workspace '$(fm_backend_herdr_workspace_label)' in session '$session'" >&2
    return 1
  }
  printf '%s:%s' "$session" "$ws"
}

fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 seeded=$3 tabs tab_count label pane state
  [ -n "$seeded" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$tab_count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  label=$(printf '%s' "$tabs" | jq -r --arg tabid "$seeded" \
    '.result.tabs[]? | select(.tab_id == $tabid) | .label' 2>/dev/null)
  [ "$label" = 1 ] || return 0
  pane=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$seeded") || return 0
  if [ -n "$pane" ]; then
    state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
  else
    state=dead
  fi
  [ "$state" != live ] || return 0
  [ "$state" = no-agent ] || [ "$state" = dead ] || return 0
  fm_backend_herdr_tab_close_exact "$session" "$wsid" "$seeded"
}

fm_backend_herdr_pane_for_tab() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e '
    (.result | type) == "object"
    and (.result.panes | type) == "array"
    and all(.result.panes[]; type == "object" and (.pane_id | type) == "string" and (.tab_id | type) == "string")
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

fm_backend_herdr_tab_id_for_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -r --arg want "$label" '
    if (.result | type) != "object" or (.result.tabs | type) != "array" then
      error("invalid tab list response")
    elif any(.result.tabs[]; type != "object" or (.tab_id | type) != "string" or (.label | type) != "string") then
      error("invalid tab entry")
    else
      [.result.tabs[] | select(.label == $want) | .tab_id] as $matches
      | if ($matches | length) == 1 then $matches[0] elif ($matches | length) == 0 then empty else error("multiple matching tabs") end
    end
  ' 2>/dev/null
}

fm_backend_herdr_tab_ids_for_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '
    (.result | type) == "object"
    and (.result.tabs | type) == "array"
    and all(.result.tabs[]; type == "object" and (.tab_id | type) == "string" and (.label | type) == "string")
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$tabs" | jq -r --arg want "$label" '.result.tabs[] | select(.label == $want) | .tab_id' 2>/dev/null
}

fm_backend_herdr_tab_absent() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 tab_id=$3 tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tabid "$tab_id" '
    (.result | type) == "object"
    and (.result.tabs | type) == "array"
    and all(.result.tabs[]; type == "object" and (.tab_id | type) == "string" and (.label | type) == "string")
    and all(.result.tabs[]; .tab_id != $tabid)
  ' >/dev/null 2>&1
}

fm_backend_herdr_tab_close_exact() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 tab_id=$3
  [ -n "$tab_id" ] || return 1
  fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || return 1
  fm_backend_herdr_tab_absent "$session" "$wsid" "$tab_id"
}

fm_backend_herdr_tab_close_by_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tab_id
  tab_id=$(fm_backend_herdr_tab_id_for_label "$session" "$wsid" "$label") || return 1
  [ -n "$tab_id" ] || return 1
  fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || return 1
  fm_backend_herdr_tab_absent "$session" "$wsid" "$tab_id"
}

# Classify a pane without creating a server or mutating Herdr. Error responses
# are intentionally read from stderr: Herdr reports pane_not_found and
# agent_not_found there on real installs. Unknown shapes always fail closed.
fm_backend_herdr_pane_agent_state() {  # <session> <pane> -> dead|no-agent|live|unknown
  local session=$1 pane_id=$2 out code echoed status
  out=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1) || true
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = pane_not_found ] && printf dead || printf unknown
    return 0
  fi
  echoed=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ "$echoed" = "$pane_id" ] || { printf unknown; return 0; }
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>&1) || true
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = agent_not_found ] && printf no-agent || printf unknown
    return 0
  fi
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working|idle|done|blocked) printf live ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdr_tab_is_husk() {  # <session> <pane>
  case "$(fm_backend_herdr_pane_agent_state "$1" "$2")" in
    dead|no-agent) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_agent_alive() {  # <target> -> alive|dead|unknown
  fm_backend_herdr_parse_target "$1" || { printf unknown; return 0; }
  case "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" in
    dead|no-agent) printf dead ;;
    live) printf alive ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdr_create_task() {  # <container> <label> <cwd> [seeded-default-tab]
  local container=$1 label=$2 cwd=$3 seeded=${4:-} lock session wsid dup dup_pane out tab_id pane_id dup_tabs remaining_dup_tabs
  lock=$(fm_backend_herdr_workspace_lock_path) || return 1
  (
    local -a husks=()
    fm_backend_herdr_workspace_lock_acquire "$lock" || exit 1
    trap 'fm_backend_herdr_workspace_lock_release "$lock"' EXIT
    session=${container%%:*}
    wsid=${container#*:}
    if [[ "$wsid" == *$'\t'* ]]; then
      [ -n "$seeded" ] || seeded=${wsid#*$'\t'}
      wsid=${wsid%%$'\t'*}
    fi
    dup_tabs=$(fm_backend_herdr_tab_ids_for_label "$session" "$wsid" "$label") || exit 1
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      dup_pane=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$dup") || exit 1
      if fm_backend_herdr_tab_is_husk "$session" "$dup_pane"; then
        husks+=("$dup")
      else
        echo "error: Herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
        exit 1
      fi
    done <<EOF
$dup_tabs
EOF
    # Create first. This keeps the workspace alive even if the husk is its only
    # tab, and means a failed create never destroys a recoverable husk.
    out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || exit 1
    tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
    pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
      fm_backend_herdr_tab_close_by_label "$session" "$wsid" "$label" >/dev/null 2>&1 || true
      echo "error: could not parse Herdr tab/pane id from tab create output" >&2
      exit 1
    fi
    fm_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded" || exit 1
    for dup in "${husks[@]:-}"; do
      [ -n "$dup" ] || continue
      fm_backend_herdr_cli "$session" tab close "$dup" >/dev/null 2>&1 || true
    done
    if [ "${#husks[@]}" -gt 0 ]; then
      out=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || exit 1
      remaining_dup_tabs=$(printf '%s' "$out" | jq -r --arg want "$label" --arg replacement "$tab_id" \
        '.result.tabs[]? | select(.label == $want and .tab_id != $replacement) | .tab_id' 2>/dev/null)
      [ -z "$remaining_dup_tabs" ] || {
        echo "error: failed to remove husk tab(s) for label '$label' in workspace $wsid" >&2
        exit 1
      }
    fi
    printf '%s %s' "$tab_id" "$pane_id"
  )
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
  fm_backend_herdr_version_check "$FM_BACKEND_HERDR_SESSION" || return 1
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
    Enter|enter) printf enter ;;
    Escape|escape|Esc|esc) printf escape ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf ctrl+c ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_herdr_send_key() {
  fm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

fm_backend_herdr_submit_enter() { fm_backend_herdr_send_key "$1" Enter; }

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

fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 verdict baseline confirm_sleep
  fm_backend_herdr_parse_target "$target" || { printf unknown; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf send-failed; return 0; }
  sleep "$settle"
  baseline=$(fm_backend_herdr_classify_submit_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    fm_backend_herdr_send_key "$target" Enter || true
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "${FM_BACKEND_HERDR_SUBMIT_POLLS:-6}")
    else
      sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target")
    fi
    case "$verdict" in
      busy|empty) printf empty; return 0 ;;
      unknown) printf unknown; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf pending; return 0; }
  done
}

fm_backend_herdr_capture_ansi() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-40} fetch out
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fetch=$lines
  [ "$fetch" -ge 200 ] 2>/dev/null || fetch=200
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source recent --lines "$fetch" --format ansi 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# Shared composer classification for Herdr. Herdr has no cursor-row query, but
# its visible source is the current composer row; ANSI is retained so the shared
# ghost extractor can distinguish a suggestion from typed input. A bare shell
# prompt is deliberately unknown, never an injection-safe empty composer.
fm_backend_herdr_composer_state() {  # <target> [text] -> empty|pending|unknown
  local target=$1 line plain stripped bordered=0 out
  fm_backend_herdr_parse_target "$target" || { printf unknown; return 0; }
  fm_backend_herdr_target_ready "$target" || { printf unknown; return 0; }
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source visible --lines 1 --format ansi 2>/dev/null) || { printf unknown; return 0; }
  line=$(printf '%s\n' "$out" | tail -n 1)
  plain=$(printf '%s\n' "$line" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  stripped=$(printf '%s\n' "$line" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  fm_composer_classify_content "$bordered" "$stripped" \
    "${FM_BACKEND_HERDR_IDLE_RE:-^Type a message\.\.\.$}" insensitive "$plain"
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

fm_backend_herdr_agent_status_raw() {  # <session> <pane> -> raw status
  local out
  out=$(fm_backend_herdr_cli "$1" agent get "$2" 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

fm_backend_herdr_classify_agent_status() {  # <raw-agent_status> -> busy|idle|unknown
  case "$1" in
    working) printf busy ;;
    idle|done|blocked) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdr_classify_submit_agent_status() {  # <raw-agent_status> -> busy|idle|unknown
  case "$1" in
    working|blocked) printf busy ;;
    idle|done) printf idle ;;
    *) printf unknown ;;
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
  fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")"
}

FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=${FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP:-0.6}

fm_backend_herdr_submit_confirm_budget() {  # <caller-budget-seconds>
  awk -v budget="${1:-0}" -v minimum="$FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP" 'BEGIN {
    budget += 0
    minimum += 0
    if (budget < 0) budget = 0
    if (minimum < 0) minimum = 0
    if (minimum > budget) budget = minimum
    printf "%.4f", budget
  }' 2>/dev/null || printf '%s' "${1:-0}"
}

fm_backend_herdr_wait_for_working() {  # <session> <pane> <budget-seconds> <polls>
  local session=$1 pane_id=$2 budget=$3 polls=${4:-1} i interval raw state saw_idle=0
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(awk -v budget="$budget" -v polls="$polls" \
    'BEGIN { divisor = polls - 1; if (divisor < 1) divisor = 1; value = budget / divisor; if (value < 0) value = 0; printf "%.4f", value }' \
    2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=0 ;; esac
  for ((i = 0; i < polls; i++)); do
    if [ "$polls" -eq 1 ] || [ "$i" -gt 0 ]; then
      sleep "$interval"
    fi
    raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
    state=$(fm_backend_herdr_classify_submit_agent_status "$raw")
    case "$state" in
      busy) printf busy; return 0 ;;
      idle) saw_idle=1 ;;
    esac
  done
  if [ "$saw_idle" -eq 1 ]; then
    printf idle
  else
    printf unknown
  fi
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
# fm_backend_herdr_socket_path: the control-socket path for <session>, read from
# `herdr session list --json` (the default session's socket differs from a named
# session's - verified: default -> ~/.config/herdr/herdr.sock, named ->
# ~/.config/herdr/sessions/<name>/herdr.sock). Empty on any failure.
fm_backend_herdr_socket_path() {  # <session>
  local session=$1
  herdr session list --json 2>/dev/null \
    | jq -r --arg name "$session" '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | head -1
}

# fm_backend_herdr_events_capable: the version/capability gate for the event
# fast-path (report section 5c trigger 1). Fails closed to the poll loop unless
# ALL hold: herdr+jq present; the raw-socket reader available (python3, unless a
# reader override is configured); client protocol >= FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL;
# and both `events.subscribe` and `pane.agent_status_changed` present in `herdr
# api schema`. FM_BACKEND_HERDR_EVENTS_FORCE overrides the whole verdict for
# tests (1 = capable, 0 = incapable) without touching the real binary. The
# `api schema` read is ~220KB, so callers (the watcher) memoize this per session
# for a process lifetime rather than probing every poll.
fm_backend_herdr_events_capable() {  # <session>
  local session=$1 protocol schema
  case "${FM_BACKEND_HERDR_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_herdr_tool_check || return 1
  if [ -z "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    command -v python3 >/dev/null 2>&1 || return 1
  fi
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge "$FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL" ] || return 1
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | grep -Fq 'events.subscribe' || return 1
  printf '%s' "$schema" | grep -Fq 'pane.agent_status_changed' || return 1
  return 0
}

# fm_backend_herdr_normalize_event: THE single normalize point (report section 5
# refinement: one backend transition shape, one parse point). Both the stream
# reader's projected lines AND the level-reconcile's `agent get` reads flow
# through here into the shared normalized-transition record. herdr's event
# carries no previous status and its stream is edge-triggered, so from_status is
# left empty; to_status drives the policy.
fm_backend_herdr_normalize_event() {  # <pane_id> <workspace_id> <agent_status> <agent>
  fm_transition_record "${1:-}" "${2:-}" "" "${3:-}" "${4:-}"
}

# fm_backend_herdr_event_reader_cmd: emit the reader argv (one word per line) for
# the raw-socket subscriber. Default: `python3 <this dir>/herdr-eventwait.py`.
# FM_BACKEND_HERDR_EVENT_READER overrides it with a whitespace-split command so
# tests can substitute a fake reader that replays canned stream lines.
fm_backend_herdr_event_reader_cmd() {
  local word
  if [ -n "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    for word in $FM_BACKEND_HERDR_EVENT_READER; do
      printf '%s\n' "$word"
    done
    return 0
  fi
  printf 'python3\n'
  printf '%s\n' "$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-eventwait.py"
}

# fm_backend_herdr_escalation_marker: the per-pane dedupe marker path for a
# <window> ("<session>:<pane_id>"), keyed identically to the watcher's
# .stale-<key> (tr ':/.' '___'), under <state_dir>.
fm_backend_herdr_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$FM_BACKEND_HERDR_ESCALATED_PREFIX" "$key"
}

# fm_backend_herdr_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-pane dedupe marker under <state_dir>.
# On a fresh `actionable` (blocked) edge - policy actionable AND no marker yet -
# it prints the record on stdout and returns 0 (the caller stops and hands the
# record up). The caller commits the marker only after handling the record.
# `absorb` (working) clears the marker and
# returns 1. `defer`/`fallback`, and an already-marked `actionable`, return 1
# with no output. <session> reconstructs the window ("<session>:<pane_id>") for
# the marker key, matching the watcher's own key scheme.
fm_backend_herdr_apply_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id to action window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

fm_backend_herdr_commit_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  : > "$marker"
}

fm_backend_herdr_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2 marker
  [ -n "$window" ] || return 0
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  rm -f "$marker" 2>/dev/null || true
}

# fm_backend_herdr_wait_transition: the bounded event wait. Blocks up to
# <timeout_secs> for one of <pane_window...> ("<session>:<pane_id>") to reach a
# fresh `blocked` edge, then prints the normalized record and returns 0.
# Returns 1 on a clean timeout (the reader ran the full budget, no fresh
# actionable edge - the caller has effectively already slept and just continues)
# and 2 when the event path is unusable (not capable, socket unresolved, reader
# failed to run/subscribe - the caller sleeps the budget itself, the fail-closed
# backstop). See the header block above for the full contract.
fm_backend_herdr_wait_transition() {  # <session> <timeout_secs> <state_dir> <pane_window...>
  local session=$1 timeout=$2 state=$3
  shift 3
  local windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_herdr_events_capable "$session" || return 2
  fi
  local sock
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 2

  # Map each window to its herdr pane id (strip the leading "<session>:").
  local w pane_id
  local pane_ids=()
  for w in "${windows[@]}"; do
    pane_id=${w#*:}
    if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
      continue
    fi
    pane_ids+=("$pane_id")
  done
  [ "${#pane_ids[@]}" -gt 0 ] || return 2

  # Start the raw-socket reader and wait for its subscription acknowledgement
  # before level reconciliation, so edges occurring during reconciliation are
  # already buffered in the live stream.
  local reader=()
  while IFS= read -r w; do
    reader+=("$w")
  done < <(fm_backend_herdr_event_reader_cmd)
  [ "${#reader[@]}" -gt 0 ] || return 2

  local fifo_dir fifo reader_pid line ws status agent raw record hit rc=1 reader_rc=0
  fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  "${reader[@]}" "$sock" "$timeout" "${pane_ids[@]}" > "$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9< "$fifo"; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  if ! IFS= read -r -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  fi

  # Level reconcile on (re)connect (report section 3d): a pane already `blocked`
  # during the gap since the last subscription is returned now, once, while
  # newer edges accumulate in the active stream. `working` panes clear their
  # marker here too.
  if [ "$rc" -ne 2 ]; then
    for w in "${windows[@]}"; do
      pane_id=${w#*:}
      if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
        continue
      fi
      raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
      [ -n "$raw" ] || continue
      record=$(fm_backend_herdr_normalize_event "$pane_id" "" "$raw" "")
      if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
        printf '%s' "$hit"
        rc=0
        break
      fi
    done
  fi

  # Drain stream edges until a fresh blocked edge or the timeout. The reader is
  # a subprocess of this call (NOT a second watcher), and is killed the instant
  # a blocked edge is found.
  # Split each raw projected line (pane_id\tworkspace_id\tagent_status\tagent)
  # with `cut`, NOT `IFS=$'\t' read`: a tab is IFS-whitespace, so `read` would
  # collapse an empty middle field (e.g. an absent workspace_id) and shift the
  # status into the wrong column. `cut` preserves empty fields.
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    [ -n "$line" ] || continue
    pane_id=$(printf '%s' "$line" | cut -f1)
    ws=$(printf '%s' "$line" | cut -f2)
    status=$(printf '%s' "$line" | cut -f3)
    agent=$(printf '%s' "$line" | cut -f4)
    [ -n "$pane_id" ] || continue
    record=$(fm_backend_herdr_normalize_event "$pane_id" "$ws" "$status" "$agent")
    if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
      printf '%s' "$hit"
      rc=0
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  if [ "$rc" -eq 2 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  # No actionable edge: distinguish a clean full-budget wait (reader exit 0 ->
  # return 1, caller already waited) from a reader error (connect/subscribe
  # failure, exit non-zero -> return 2, caller sleeps and counts toward the
  # runtime-disable threshold).
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$fifo_dir" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ "$reader_rc" -eq 0 ] && return 1
  return 2
}
