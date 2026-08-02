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

if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
  _FM_BACKEND_WAKE_READ_ONLY_SET=${FM_WAKE_LIB_READ_ONLY+x}
  _FM_BACKEND_WAKE_READ_ONLY_VALUE=${FM_WAKE_LIB_READ_ONLY:-}
  FM_WAKE_LIB_READ_ONLY=1
  # shellcheck source=/dev/null
  . "$FM_BACKEND_LIB_DIR/fm-wake-lib.sh"
  if [ "$_FM_BACKEND_WAKE_READ_ONLY_SET" = x ]; then
    FM_WAKE_LIB_READ_ONLY=$_FM_BACKEND_WAKE_READ_ONLY_VALUE
  else
    unset FM_WAKE_LIB_READ_ONLY
  fi
  unset _FM_BACKEND_WAKE_READ_ONLY_SET _FM_BACKEND_WAKE_READ_ONLY_VALUE
fi
if ! command -v fm_agent_proc_cwd >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$FM_BACKEND_LIB_DIR/fm-agent-cwd-lib.sh"
fi

fm_backend_list_contains() {  # <space-delimited-list> <name>
  local list=$1 name=$2
  case "$name" in *[[:space:]]*) return 1 ;; esac
  case " $list " in *" $name "*) return 0 ;; esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
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

fm_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  command -v "$tool" >/dev/null 2>&1
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

FM_BACKEND_TMUX_META_WINDOW=
FM_BACKEND_TMUX_META_PANE=
FM_BACKEND_TMUX_META_GENERATION=
FM_BACKEND_TMUX_META_TARGET=
FM_BACKEND_TMUX_META_PROVIDER_IDENTITY=
FM_BACKEND_TMUX_META_LEGACY=0

fm_backend_tmux_meta_read() {  # <meta-file>
  local meta=$1 line key value
  local backend_count=0 window_count=0 pane_count=0 generation_count=0
  local herdr_count=0 backend='' window='' pane='' generation=''
  FM_BACKEND_TMUX_META_WINDOW=
  FM_BACKEND_TMUX_META_PANE=
  FM_BACKEND_TMUX_META_GENERATION=
  FM_BACKEND_TMUX_META_TARGET=
  FM_BACKEND_TMUX_META_PROVIDER_IDENTITY=
  FM_BACKEND_TMUX_META_LEGACY=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) continue ;;
    esac
    case "$key" in
      backend) backend_count=$((backend_count + 1)); backend=$value ;;
      window) window_count=$((window_count + 1)); window=$value ;;
      tmux_pane_id) pane_count=$((pane_count + 1)); pane=$value ;;
      endpoint_generation)
        generation_count=$((generation_count + 1))
        generation=$value
        ;;
      herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id)
        herdr_count=$((herdr_count + 1))
        ;;
    esac
  done < "$meta" || return 1
  [ "$backend_count" -le 1 ] && [ "$window_count" -eq 1 ] \
    && [ "$pane_count" -le 1 ] && [ "$generation_count" -le 1 ] \
    && [ "$herdr_count" -eq 0 ] || return 1
  [ "${backend:-tmux}" = tmux ] && [ -n "$window" ] || return 1
  case "$window" in *'|'*) return 1 ;; esac
  if [ "$generation_count" -eq 0 ]; then
    [ "$pane_count" -eq 0 ] || return 1
    FM_BACKEND_TMUX_META_LEGACY=1
  else
    case "$generation" in *[!A-Za-z0-9._-]*|""|*/*) return 1 ;; esac
  fi
  if [ "$pane_count" -eq 1 ]; then
    case "$pane" in %*) ;; *) return 1 ;; esac
    case "${pane#%}" in ''|*[!0-9]*) return 1 ;; esac
    case "$window" in @*) ;; *) return 1 ;; esac
    case "${window#@}" in ''|*[!0-9]*) return 1 ;; esac
    FM_BACKEND_TMUX_META_TARGET=$pane
    FM_BACKEND_TMUX_META_PROVIDER_IDENTITY="tmux:$window:$pane"
  else
    FM_BACKEND_TMUX_META_TARGET=$window
    # shellcheck disable=SC2034 # Read by fm-ff-lib.sh after this parser returns.
    FM_BACKEND_TMUX_META_PROVIDER_IDENTITY="tmux:$window"
  fi
  FM_BACKEND_TMUX_META_WINDOW=$window
  FM_BACKEND_TMUX_META_PANE=$pane
  FM_BACKEND_TMUX_META_GENERATION=$generation
}

fm_backend_meta_value_exact() {
  local meta=$1 wanted=$2 required=${3:-required}
  local line key value count=0 found=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) continue ;;
    esac
    if [ "$key" = "$wanted" ]; then
      count=$((count + 1))
      found=$value
    fi
  done < "$meta" || return 1
  [ "$count" -le 1 ] || return 1
  if [ "$required" = required ]; then
    [ "$count" -eq 1 ] && [ -n "$found" ] || return 1
  elif [ "$required" != optional ]; then
    return 1
  fi
  printf '%s' "$found"
}

fm_backend_tmux_legacy_process_pid() {
  local pane=$1 shell
  shell=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null \
    | tr -d '[:space:]') || return 1
  case "$shell" in ''|*[!0-9]*) return 1 ;; esac
  fm_agent_harness_pid_below "$shell"
}

FM_BACKEND_TMUX_LEGACY_PROCESS=
FM_BACKEND_TMUX_LEGACY_PROCESS_START=
FM_BACKEND_TMUX_LEGACY_PROCESS_IDENTITY=

fm_backend_tmux_legacy_process_owned() {
  local meta=$1 pane=$2 id=$3 home task kind harness home_real marker
  local pid start identity cwd env declared_task declared_home declared_home_real
  local declared_role task_count home_count role_count launch_receipt
  FM_BACKEND_TMUX_LEGACY_PROCESS=
  FM_BACKEND_TMUX_LEGACY_PROCESS_START=
  FM_BACKEND_TMUX_LEGACY_PROCESS_IDENTITY=
  home=$(fm_backend_meta_value_exact "$meta" home required) || return 1
  task=$(fm_backend_meta_value_exact "$meta" task optional) || return 1
  kind=$(fm_backend_meta_value_exact "$meta" kind required) || return 1
  harness=$(fm_backend_meta_value_exact "$meta" harness required) || return 1
  [ -z "$task" ] || [ "$task" = "$id" ] || return 1
  [ "$kind" = secondmate ] || return 1
  case "$harness" in claude|codex|opencode|grok|pi) ;; *) return 1 ;; esac
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  marker="$home_real/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    && [ "$(cat "$marker" 2>/dev/null)" = "$id" ] || return 1
  pid=$(fm_backend_tmux_legacy_process_pid "$pane") || return 1
  fm_harness_pid_alive "$pid" || return 1
  start=$(fm_session_process_start "$pid") || return 1
  identity=$(fm_session_process_identity "$pid") || return 1
  cwd=$(fm_agent_proc_cwd "$pid") || return 1
  cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || return 1
  [ "$cwd" = "$home_real" ] || return 1
  env=$(fm_agent_environ "$pid") || return 1
  declared_task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p')
  declared_home=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_OWNER_HOME=//p')
  declared_role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p')
  task_count=$(printf '%s\n' "$env" | grep -c '^FM_AGENT_TASK=' || true)
  home_count=$(printf '%s\n' "$env" | grep -c '^FM_AGENT_OWNER_HOME=' || true)
  role_count=$(printf '%s\n' "$env" | grep -c '^FM_AGENT_ROLE=' || true)
  [ "$task_count" -eq 1 ] && [ "$home_count" -eq 1 ] \
    && [ "$role_count" -eq 1 ] \
    && [ -n "$declared_task" ] \
    && [ -n "$declared_home" ] \
    && [ -n "$declared_role" ] || return 1
  declared_home_real=$(cd "$declared_home" 2>/dev/null && pwd -P) || return 1
  [ "$declared_task" = "$id" ] \
    && [ "$declared_home_real" = "$home_real" ] \
    && [ "$declared_role" = secondmate ] || return 1
  [ "$(fm_backend_tmux_legacy_process_pid "$pane" 2>/dev/null)" = "$pid" ] \
    && [ "$(fm_session_process_start "$pid" 2>/dev/null)" = "$start" ] \
    && [ "$(fm_session_process_identity "$pid" 2>/dev/null)" = "$identity" ] \
    || return 1
  launch_receipt="$(dirname "$meta")/.secondmate-launch-receipts/$id"
  fm_session_launch_receipt_validate \
    "$launch_receipt" "$id" "$home_real" "$pid" "$start" "$identity" || return 1
  FM_BACKEND_TMUX_LEGACY_PROCESS=$pid
  FM_BACKEND_TMUX_LEGACY_PROCESS_START=$start
  FM_BACKEND_TMUX_LEGACY_PROCESS_IDENTITY=$identity
}

fm_backend_tmux_legacy_migration_authorized() {
  local state=${1:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}
  local authority="$state/.session-authority" script home_real
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  fm_session_authority_capability_present \
    && fm_session_authority_read "$authority" \
    && [ "$FM_SESSION_AUTHORITY_HOME" = "$home_real" ] \
    && fm_session_authority_is_current_ancestor "$authority" || return 1
  script="$FM_SESSION_AUTHORITY_CHECKOUT/bin/fm-session-authority-exec.sh"
  fm_session_authority_broker_present "$script"
}

fm_backend_tmux_legacy_pane_unclaimed() {
  local meta=$1 pane=$2 other count
  for other in "$(dirname "$meta")"/*.meta; do
    [ -e "$other" ] || continue
    [ "$other" != "$meta" ] || continue
    count=$(grep -c "^tmux_pane_id=$pane$" "$other" 2>/dev/null || true)
    [ "$count" -eq 0 ] || return 1
  done
}

FM_BACKEND_TMUX_MIGRATION_META=
FM_BACKEND_TMUX_MIGRATION_META_SHA=
FM_BACKEND_TMUX_MIGRATION_ID=
FM_BACKEND_TMUX_MIGRATION_PANE=
FM_BACKEND_TMUX_MIGRATION_WINDOW=
FM_BACKEND_TMUX_MIGRATION_GENERATION=
FM_BACKEND_TMUX_MIGRATION_STATE=
FM_BACKEND_TMUX_MIGRATION_PROCESS=
FM_BACKEND_TMUX_MIGRATION_PROCESS_START=
FM_BACKEND_TMUX_MIGRATION_PROCESS_IDENTITY=

fm_backend_tmux_legacy_process_snapshot() {
  local pane=$1 pid=$2 start=$3 identity=$4
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] \
    && [ "$(fm_backend_tmux_legacy_process_pid "$pane" 2>/dev/null)" = "$pid" ] \
    && [ "$(fm_session_process_start "$pid" 2>/dev/null)" = "$start" ] \
    && [ "$(fm_session_process_identity "$pid" 2>/dev/null)" = "$identity" ]
}

fm_backend_tmux_migration_write() {
  local journal=$1 meta=$2 meta_sha=$3 id=$4 pane=$5 window=$6
  local generation=$7 state=$8 process=$9 process_start=${10}
  local process_identity=${11} body
  case "$meta:$meta_sha:$id:$pane:$window:$generation:$state:$process:$process_start:$process_identity" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  body=$(printf 'version=3\nmeta=%s\nmeta-sha256=%s\ntask=%s\npane=%s\nwindow=%s\ngeneration=%s\nstate=%s\nprocess=%s\nprocess-start=%s\nprocess-identity=%s\n' \
    "$meta" "$meta_sha" "$id" "$pane" "$window" "$generation" "$state" \
    "$process" "$process_start" "$process_identity") \
    || return 1
  body="${body}"$'\n'
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    fm_session_authority_record_validate "$journal" 12 || return 1
  fi
  fm_session_authority_record_write "$journal" "$body"
}

fm_backend_tmux_migration_read() {
  local journal=$1
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  fm_session_authority_record_validate "$journal" 12 || return 1
  [ "$(wc -l < "$journal" | tr -d ' ')" -eq 12 ] || return 1
  [ "$(sed -n '1p' "$journal")" = version=3 ] || return 1
  FM_BACKEND_TMUX_MIGRATION_META=$(sed -n '2s/^meta=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_META_SHA=$(sed -n '3s/^meta-sha256=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_ID=$(sed -n '4s/^task=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_PANE=$(sed -n '5s/^pane=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_WINDOW=$(sed -n '6s/^window=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_GENERATION=$(sed -n '7s/^generation=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_STATE=$(sed -n '8s/^state=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_PROCESS=$(sed -n '9s/^process=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_PROCESS_START=$(sed -n '10s/^process-start=//p' "$journal")
  FM_BACKEND_TMUX_MIGRATION_PROCESS_IDENTITY=$(sed -n '11s/^process-identity=//p' "$journal")
  case "$FM_BACKEND_TMUX_MIGRATION_META" in /*) ;; *) return 1 ;; esac
  [ "${#FM_BACKEND_TMUX_MIGRATION_META_SHA}" -eq 64 ] || return 1
  case "$FM_BACKEND_TMUX_MIGRATION_META_SHA" in *[!0-9a-f]*) return 1 ;; esac
  case "$FM_BACKEND_TMUX_MIGRATION_ID" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$FM_BACKEND_TMUX_MIGRATION_PANE" in %*) ;; *) return 1 ;; esac
  case "${FM_BACKEND_TMUX_MIGRATION_PANE#%}" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_BACKEND_TMUX_MIGRATION_WINDOW" in @*) ;; *) return 1 ;; esac
  case "${FM_BACKEND_TMUX_MIGRATION_WINDOW#@}" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_BACKEND_TMUX_MIGRATION_GENERATION" in
    fm-legacy-[A-Za-z0-9._-]*) ;;
    *) return 1 ;;
  esac
  case "$FM_BACKEND_TMUX_MIGRATION_STATE" in prepared|bound) ;; *) return 1 ;; esac
  case "$FM_BACKEND_TMUX_MIGRATION_PROCESS" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$FM_BACKEND_TMUX_MIGRATION_PROCESS_START" ] \
    && [ -n "$FM_BACKEND_TMUX_MIGRATION_PROCESS_IDENTITY" ] || return 1
}

fm_backend_tmux_migration_topology_matches() {
  local pane=$1 canonical=$2 current
  [ "$(fm_backend_tmux_pane_window_id "$pane" 2>/dev/null)" = "$canonical" ] \
    || return 1
  current=$(fm_backend_tmux_single_pane_id "$canonical" 2>/dev/null) || return 1
  [ "$current" = "$pane" ]
}

fm_backend_tmux_migration_commit_meta() {
  local meta=$1 meta_sha=$2 id=$3 pane=$4 canonical=$5 generation=$6
  local tmp task_count
  fm_backend_tmux_meta_read "$meta" \
    && [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 1 ] \
    && [ "$(fm_session_sha256_file "$meta")" = "$meta_sha" ] || return 1
  task_count=$(grep -c '^task=' "$meta" 2>/dev/null || true)
  [ "$task_count" -le 1 ] || return 1
  tmp=$(mktemp "${meta}.migration.XXXXXX") || return 1
  chmod 600 "$tmp" \
    && awk -v window="$canonical" '
        /^window=/ { print "window=" window; next }
        { print }
      ' "$meta" > "$tmp" \
    && printf 'tmux_pane_id=%s\nendpoint_generation=%s\n' \
      "$pane" "$generation" >> "$tmp" \
    && { [ "$task_count" -eq 1 ] || printf 'task=%s\n' "$id" >> "$tmp"; } \
    && fm_backend_tmux_migration_topology_matches "$pane" "$canonical" \
    && fm_backend_tmux_endpoint_matches "$canonical" "$pane" "$generation" \
    && mv "$tmp" "$meta" || {
      rm -f "$tmp"
      return 1
    }
}

fm_backend_tmux_migration_recover() {
  local journal=$1 pane=$2 canonical=$3 live
  fm_backend_tmux_migration_read "$journal" || return 1
  [ "$FM_BACKEND_TMUX_MIGRATION_PANE" = "$pane" ] \
    && [ "$FM_BACKEND_TMUX_MIGRATION_WINDOW" = "$canonical" ] || return 1
  if fm_backend_tmux_meta_read "$FM_BACKEND_TMUX_MIGRATION_META" \
    && [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 0 ]; then
    [ "$FM_BACKEND_TMUX_META_PANE" = "$pane" ] \
      && [ "$FM_BACKEND_TMUX_META_WINDOW" = "$canonical" ] \
      && [ "$FM_BACKEND_TMUX_META_GENERATION" \
        = "$FM_BACKEND_TMUX_MIGRATION_GENERATION" ] \
      && fm_backend_tmux_endpoint_matches "$canonical" "$pane" \
        "$FM_BACKEND_TMUX_MIGRATION_GENERATION" || return 1
    rm -f "$journal"
    return 0
  fi
  fm_backend_tmux_legacy_process_snapshot \
    "$pane" \
    "$FM_BACKEND_TMUX_MIGRATION_PROCESS" \
    "$FM_BACKEND_TMUX_MIGRATION_PROCESS_START" \
    "$FM_BACKEND_TMUX_MIGRATION_PROCESS_IDENTITY" || return 1
  [ "$(fm_session_sha256_file "$FM_BACKEND_TMUX_MIGRATION_META" 2>/dev/null)" \
    = "$FM_BACKEND_TMUX_MIGRATION_META_SHA" ] || return 1
  if live=$(fm_backend_tmux_pane_generation_recorded "$pane" 2>/dev/null); then
    [ "$live" = "$FM_BACKEND_TMUX_MIGRATION_GENERATION" ] || return 1
  else
    fm_backend_tmux_migration_topology_matches "$pane" "$canonical" || return 1
    fm_backend_tmux_pane_generation_unset "$pane" || return 1
    fm_backend_tmux_bind_endpoint_generation \
      "$pane" "$FM_BACKEND_TMUX_MIGRATION_GENERATION" || return 1
  fi
  fm_backend_tmux_migration_write "$journal" \
    "$FM_BACKEND_TMUX_MIGRATION_META" "$FM_BACKEND_TMUX_MIGRATION_META_SHA" \
    "$FM_BACKEND_TMUX_MIGRATION_ID" "$pane" "$canonical" \
    "$FM_BACKEND_TMUX_MIGRATION_GENERATION" bound \
    "$FM_BACKEND_TMUX_MIGRATION_PROCESS" \
    "$FM_BACKEND_TMUX_MIGRATION_PROCESS_START" \
    "$FM_BACKEND_TMUX_MIGRATION_PROCESS_IDENTITY" || return 1
  fm_backend_tmux_migration_topology_matches "$pane" "$canonical" || return 1
  fm_backend_tmux_migration_commit_meta \
    "$FM_BACKEND_TMUX_MIGRATION_META" "$FM_BACKEND_TMUX_MIGRATION_META_SHA" \
    "$FM_BACKEND_TMUX_MIGRATION_ID" "$pane" "$canonical" \
    "$FM_BACKEND_TMUX_MIGRATION_GENERATION" || return 1
  fm_backend_tmux_endpoint_matches "$canonical" "$pane" \
    "$FM_BACKEND_TMUX_MIGRATION_GENERATION" || return 1
  rm -f "$journal"
}

fm_backend_tmux_migration_retire_committed() {
  local meta=$1 state pane canonical journal lock attempts=0 status=1
  fm_backend_tmux_meta_read "$meta" || return 1
  [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 0 ] || return 1
  pane=$FM_BACKEND_TMUX_META_PANE
  canonical=$FM_BACKEND_TMUX_META_WINDOW
  [ -n "$pane" ] || return 1
  state=$(dirname "$meta")
  journal="$state/.tmux-endpoint-${canonical#@}.migration"
  mkdir -p "$state/.locks" || return 1
  lock="$state/.locks/tmux-endpoint-${canonical#@}.migration.lock"
  if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then
    return 0
  fi
  fm_backend_tmux_legacy_migration_authorized "$state" || return 1
  while ! fm_lock_try_acquire "$lock"; do
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.02
    attempts=$((attempts + 1))
  done
  if fm_lifecycle_admission_lock_owned_by_process "$lock" \
    && fm_backend_tmux_migration_recover "$journal" "$pane" "$canonical"; then
    status=0
  fi
  fm_lock_release "$lock"
  return "$status"
}

fm_backend_tmux_meta_migrate_legacy() {  # <meta-file>
  local meta=$1 pane current canonical state lock journal generation meta_sha id
  local process process_start process_identity attempts=0 status=1
  meta=$(cd "$(dirname "$meta")" 2>/dev/null && pwd -P)/${meta##*/} || return 1
  fm_backend_tmux_meta_read "$meta" || return 1
  [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 1 ] || return 0
  state=$(dirname "$meta")
  fm_backend_tmux_legacy_migration_authorized "$state" || return 1
  fm_backend_source tmux || return 1
  pane=$(fm_backend_tmux_single_pane_id \
    "$FM_BACKEND_TMUX_META_WINDOW" 2>/dev/null) || return 1
  canonical=$(fm_backend_tmux_pane_window_id "$pane") || return 1
  mkdir -p "$state/.locks" || return 1
  lock="$state/.locks/tmux-endpoint-${canonical#@}.migration.lock"
  journal="$state/.tmux-endpoint-${canonical#@}.migration"
  while ! fm_lock_try_acquire "$lock"; do
    fm_backend_tmux_meta_read "$meta" \
      && [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 0 ] \
      && fm_backend_tmux_endpoint_matches \
        "$FM_BACKEND_TMUX_META_WINDOW" "$FM_BACKEND_TMUX_META_PANE" \
        "$FM_BACKEND_TMUX_META_GENERATION" \
      && return 0
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.02
    attempts=$((attempts + 1))
  done
  if ! fm_lifecycle_admission_lock_owned_by_process "$lock"; then
    fm_lock_release "$lock"
    return 1
  fi
  fm_backend_tmux_legacy_migration_authorized "$state" || {
    fm_lock_release "$lock"
    return 1
  }
  current=$(fm_backend_tmux_single_pane_id \
    "$FM_BACKEND_TMUX_META_WINDOW" 2>/dev/null) || current=
  [ "$current" = "$pane" ] \
    && [ "$(fm_backend_tmux_pane_window_id "$pane" 2>/dev/null)" = "$canonical" ] || {
      fm_lock_release "$lock"
      return 1
    }
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    fm_backend_tmux_migration_recover "$journal" "$pane" "$canonical" || {
      fm_lock_release "$lock"
      return 1
    }
  fi
  if ! fm_backend_tmux_meta_read "$meta"; then
    fm_lock_release "$lock"
    return 1
  fi
  if [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 0 ]; then
    fm_lock_release "$lock"
    return 0
  fi
  id=${meta##*/}
  id=${id%.meta}
  case "$id" in ''|*[!A-Za-z0-9._-]*) pane= ;; esac
  if [ -n "$pane" ]; then
    if fm_backend_tmux_legacy_process_owned "$meta" "$pane" "$id" \
      && fm_backend_tmux_legacy_pane_unclaimed "$meta" "$pane"; then
      process=$FM_BACKEND_TMUX_LEGACY_PROCESS
      process_start=$FM_BACKEND_TMUX_LEGACY_PROCESS_START
      process_identity=$FM_BACKEND_TMUX_LEGACY_PROCESS_IDENTITY
    else
      pane=
    fi
  fi
  if [ -n "$pane" ]; then
    generation="fm-legacy-$(date +%s)-$$-$RANDOM-$RANDOM"
    meta_sha=$(fm_session_sha256_file "$meta") || pane=
  fi
  if [ -n "$pane" ] \
    && fm_backend_tmux_pane_generation_unset "$pane" \
    && fm_backend_tmux_migration_write "$journal" "$meta" "$meta_sha" "$id" \
      "$pane" "$canonical" "$generation" prepared \
      "$process" "$process_start" "$process_identity" \
    && fm_backend_tmux_migration_recover "$journal" "$pane" "$canonical" \
    && fm_backend_tmux_meta_read "$meta" \
    && [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 0 ] \
    && fm_backend_tmux_endpoint_matches \
      "$FM_BACKEND_TMUX_META_WINDOW" "$FM_BACKEND_TMUX_META_PANE" \
      "$FM_BACKEND_TMUX_META_GENERATION"; then
    status=0
  fi
  fm_lock_release "$lock"
  return "$status"
}

fm_backend_tmux_meta_ensure_live_bound() {  # <meta-file>
  fm_backend_tmux_meta_read "$1" || return 1
  if [ "$FM_BACKEND_TMUX_META_LEGACY" -eq 1 ]; then
    fm_backend_tmux_meta_migrate_legacy "$1" || return 1
    fm_backend_tmux_meta_read "$1" || return 1
  else
    fm_backend_tmux_migration_retire_committed "$1" || return 1
    fm_backend_tmux_meta_read "$1" || return 1
  fi
  fm_backend_tmux_endpoint_matches \
    "$FM_BACKEND_TMUX_META_WINDOW" "$FM_BACKEND_TMUX_META_PANE" \
    "$FM_BACKEND_TMUX_META_GENERATION"
}

fm_backend_tmux_endpoint_matches() {  # <window> <pane-or-empty> <generation>
  local window=$1 pane=$2 generation=$3 live
  if [ -n "$pane" ]; then
    live=$(fm_backend_endpoint_identity tmux "$pane" 2>/dev/null) || return 1
    [ "$live" = "$window|$pane|$generation" ]
  else
    live=$(fm_backend_endpoint_generation \
      tmux "$window" legacy-window 2>/dev/null) || return 1
    [ "$live" = "$generation" ]
  fi
}

fm_backend_recorded_target_of_meta() {  # <meta-file>
  local meta=$1 backend session pane window backend_count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  [ "$backend_count" -le 1 ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = herdr ]; then
    session=$(fm_meta_get "$meta" herdr_session)
    pane=$(fm_meta_get "$meta" herdr_pane_id)
    if [ -n "$session" ] && [ -n "$pane" ]; then
      printf '%s:%s' "$session" "$pane"
      return 0
    fi
  elif [ "$backend" = tmux ]; then
    fm_backend_tmux_meta_read "$meta" || return 1
    printf '%s' "$FM_BACKEND_TMUX_META_TARGET"
    return 0
  fi
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 backend target
  target=$(fm_backend_recorded_target_of_meta "$meta") || return 1
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = tmux ]; then
    fm_backend_tmux_meta_ensure_live_bound "$meta" || return 1
    target=$FM_BACKEND_TMUX_META_TARGET
  fi
  printf '%s' "$target"
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_backend_target_of_meta "$meta")" = "$target" ] || continue
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

fm_backend_agent_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_agent_state "$target" ;;
    herdr) fm_backend_herdr_agent_state "$target" ;;
    *) printf 'unverified' ;;
  esac
}

fm_backend_agent_alive() {  # <backend> <target>
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_inventory_target() {  # <state> <alias> [home] [session] [workspace] [display-label] [allow-legacy]
  local state=$1 alias=$2 home=${3:-$FM_HOME} session=${4:-} wsid=${5:-}
  local display_label=${6:-} allow_legacy=${7:-0} live target
  fm_backend_source herdr || return 2
  if [ -z "$session" ]; then
    session=$(fm_backend_herdr_session) || return 2
    [ -n "$session" ] || return 2
  fi
  if ! live=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    fm_backend_list_live herdr "$session" "$wsid"); then
    return 2
  fi
  if [ -n "$display_label" ]; then
    target=$(printf '%s\n' "$live" | awk -F '\t' -v alias="$alias" -v label="$display_label" '
      $2 == alias && $3 == label { if (++count == 1) found = $1 }
      END { if (count == 1) print found }
    ')
    [ -z "$target" ] || { printf '%s' "$target"; return 0; }
  fi
  if [ "$allow_legacy" = 1 ]; then
    target=$(printf '%s\n' "$live" | awk -F '\t' -v alias="$alias" '
      $2 == alias && $3 == alias { if (++count == 1) found = $1 }
      END { if (count == 1) print found }
    ')
    [ -z "$target" ] || { printf '%s' "$target"; return 0; }
  fi
  return 1
}

fm_backend_resolve_selector_with_backend() {  # <raw-target> <state-dir>; echoes backend<TAB>target
  local raw=$1 state=$2 meta window id backend session wsid recovery_record recovery_label recovery_home
  local recovery_display_label
  local inventory_status
  case "$raw" in
    *:*)
      printf '%s\t%s' "$(fm_backend_of_selector "$raw" "$raw" "$state")" "$raw"
      ;;
    *)
      case "$raw" in
        fm-*) id=${raw#fm-} ;;
        *) id=$raw ;;
      esac
      meta="$state/$id.meta"
      [ -f "$meta" ] || meta=
      if [ -n "$meta" ]; then
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; return 1; }
        backend=$(fm_backend_of_meta "$meta")
        if [ "$backend" != herdr ]; then
          printf '%s\t%s' "$backend" "$window"
          return 0
        fi
        if fm_backend_pane_readable herdr "$window"; then
          printf 'herdr\t%s' "$window"
          return 0
        fi
        recovery_home=$(fm_meta_get "$meta" home)
        session=$(fm_meta_get "$meta" herdr_session)
        wsid=$(fm_meta_get "$meta" herdr_workspace_id)
        recovery_display_label=$(fm_meta_get "$meta" display_label)
        if window=$(fm_backend_herdr_inventory_target "$state" "fm-$id" \
          "${recovery_home:-$FM_HOME}" "$session" "$wsid" "$recovery_display_label" 1); then
          printf 'herdr\t%s' "$window"
          return 0
        else
          inventory_status=$?
        fi
        if [ "$inventory_status" -eq 2 ]; then
          echo "error: could not inspect Herdr recovery inventory for $raw" >&2
        else
          echo "error: no live Herdr target found for $raw" >&2
        fi
        return 1
      fi
      recovery_record="$state/$id.herdr-label"
      if [ -f "$recovery_record" ]; then
        recovery_label="fm-$id"
        fm_backend_source herdr || return 1
        fm_task_label_read_record "$recovery_record" "$id" >/dev/null 2>&1 || {
          echo "error: malformed Herdr recovery journal for $raw" >&2
          return 1
        }
        recovery_home=$(fm_meta_get "$recovery_record" herdr_home)
        session=$(fm_meta_get "$recovery_record" herdr_session)
        wsid=$(fm_meta_get "$recovery_record" herdr_workspace_id)
        recovery_display_label=$(fm_meta_get "$recovery_record" display_label)
        if window=$(fm_backend_herdr_inventory_target "$state" "$recovery_label" \
          "${recovery_home:-$FM_HOME}" "$session" "$wsid" "$recovery_display_label" 1); then
          printf 'herdr\t%s' "$window"
          return 0
        else
          inventory_status=$?
        fi
        if [ "$inventory_status" -eq 2 ]; then
          echo "error: could not inspect Herdr recovery inventory for $raw" >&2
        else
          echo "error: no live Herdr target found for $raw" >&2
        fi
        return 1
      fi
      if [[ "$raw" == fm-* ]] && [ "$(fm_backend_name)" = herdr ]; then
        if window=$(fm_backend_herdr_inventory_target "$state" "fm-$id" \
          "$FM_HOME" "" "" "" 1); then
          printf 'herdr\t%s' "$window"
          return 0
        else
          inventory_status=$?
        fi
        if [ "$inventory_status" -eq 2 ]; then
          echo "error: could not inspect Herdr legacy inventory for $raw" >&2
          return 1
        fi
      fi
      if [[ "$raw" == fm-* ]]; then
        echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
        return 1
      fi
      fm_backend_source tmux || return 1
      window=$(fm_backend_tmux_resolve_bare_selector "$raw") || return 1
      printf 'tmux\t%s' "$window"
      ;;
  esac
}

fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local resolved
  resolved=$(fm_backend_resolve_selector_with_backend "$@") || return 1
  printf '%s' "${resolved#*$'\t'}"
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

fm_backend_submit_enter() {  # <backend> <target> <retries> <enter-sleep> [expected-text]
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

fm_backend_agent_alive() {  # <backend> <target> -> alive|dead|unknown
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf unknown ;;
  esac
}

fm_backend_pane_readable() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_pane_readable "$@" ;;
    herdr) fm_backend_herdr_target_ready "$@" ;;
    *) echo "error: no pane-readability implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# Cheap passive existence probe. In particular, the Herdr path must not call
# target_ready because that helper may start a server during a read-only fleet
# digest.
fm_backend_target_exists() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    herdr)
      fm_backend_source herdr || return 1
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    *)
      fm_backend_pane_readable "$@"
      ;;
  esac
}

fm_backend_composer_state() {  # <backend> <target> [text] -> empty|pending|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_composer_state "$@" ;;
    herdr) fm_backend_herdr_composer_state "${1:-}" "${2:-}" ;;
    *) printf 'unknown' ;;
  esac
}

# Native event waits are optional. A return code of 2 means the caller must
# use its normal polling sleep; Herdr remains experimental and this path is
# fail-closed when protocol/schema/socket capability is absent.
fm_backend_has_push() { [ "$1" = herdr ]; }

fm_backend_events_capable() {  # <backend> <session>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_events_capable "$@"
}

fm_backend_wait_transition() {  # <backend> <session> <timeout> <state> <target...>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 2
  fm_backend_source "$backend" || return 2
  fm_backend_herdr_wait_transition "$@"
}

fm_backend_commit_transition() {  # <backend> <state> <session> <record>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_commit_transition "$@"
}

fm_backend_clear_transition() {  # <backend> <state> <window>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 0
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_clear_transition "$@"
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

fm_backend_list_live() {  # <backend> <container-or-session>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_list_live "$@" ;;
    *) echo "error: no live-task inventory implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_create_labeled_task() {  # <backend> <container> <state> <id> <kind> <title> <backlog> <cwd> [seeded]
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_create_labeled_task "$@" ;;
    *) echo "error: no labeled-task create implementation for backend '$backend'" >&2; return 1 ;;
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

fm_backend_endpoint_generation() {
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_endpoint_generation "$@" ;;
    herdr) fm_backend_herdr_endpoint_generation "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_bind_endpoint_generation() {
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_bind_endpoint_generation "$@" ;;
    herdr) fm_backend_herdr_bind_endpoint_generation "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_endpoint_identity() {
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_endpoint_identity "$@" ;;
    herdr) fm_backend_herdr_endpoint_identity "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_foreground_process_pid() {
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_foreground_process_pid "$@" ;;
    herdr) fm_backend_herdr_foreground_process_pid "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_launch_trusted_process() {
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_launch_trusted_process "$@" ;;
    herdr) fm_backend_herdr_launch_trusted_process "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_launch_process_is_current() {
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_launch_process_is_current "$@" ;;
    herdr) fm_backend_herdr_launch_process_is_current "$@" ;;
    *) return 1 ;;
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
