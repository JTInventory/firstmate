#!/usr/bin/env bash
# Callable "no turn ends blind" guard for a firstmate primary session.
#
# The main firstmate checkout and a genuinely marked secondmate home are
# primary sessions. A linked child crew/scout worktree is not: its git-dir and
# git-common-dir differ, and it never carries the secondmate-home marker.
#
# This is intentionally a script-only backstop in JT. fm-spawn does not install
# live harness hooks for it. A harness or session wrapper may call it with a
# JSON stop payload on stdin. Exit 0 allows the turn; exit 2 blocks a blind turn
# and prints the bounded re-arm instruction.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE="${FM_TURNEND_GUARD_GRACE:-${FM_GUARD_GRACE:-300}}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Harness stop payloads are JSON. A direct CLI invocation has no stdin and is
# treated as the first stop attempt.
PAYLOAD=
PAYLOAD_HAS_NUL=false
if [ ! -t 0 ]; then
  if IFS= read -r -d '' PAYLOAD; then
    PAYLOAD_HAS_NUL=true
  fi
fi
if [ "$PAYLOAD_HAS_NUL" = true ]; then
  STOP_INPUT=
elif [ -n "$PAYLOAD" ]; then
  STOP_INPUT=$PAYLOAD
else
  STOP_INPUT='{}'
fi

# Return 0 only for a genuine seeded secondmate marker. The marker is local and
# gitignored, so child worktrees do not inherit it. Validate its shape to avoid
# force-including an arbitrary linked worktree because of an empty or symlinked
# file.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || [ -n "${id:-}" ] || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Only plain firstmate checkouts and marked secondmate homes are primaries.
# Linked child worktrees stay exempt even when they contain in-flight metadata.
if ! fm_root_is_secondmate_home "$FM_ROOT"; then
  GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
  GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
  [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
fi
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

in_flight=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  in_flight=$((in_flight + 1))
done
[ "$in_flight" -gt 0 ] || exit 0

json_input=
json_pos=0
json_len=0
json_string=
json_string_had_escape=false
json_stop_active=false
json_stop_seen=false
json_stop_valid=true

json_skip_ws() {
  while [ "$json_pos" -lt "$json_len" ]; do
    case "${json_input:json_pos:1}" in
      ' '|$'\t'|$'\n'|$'\r') json_pos=$((json_pos + 1)) ;;
      *) return 0 ;;
    esac
  done
}

json_parse_string() {
  local char escape i
  [ "${json_input:json_pos:1}" = '"' ] || return 1
  json_pos=$((json_pos + 1))
  json_string=
  json_string_had_escape=false
  while [ "$json_pos" -lt "$json_len" ]; do
    char=${json_input:json_pos:1}
    case "$char" in
      '"')
        json_pos=$((json_pos + 1))
        return 0
        ;;
      \\)
        json_pos=$((json_pos + 1))
        json_string_had_escape=true
        [ "$json_pos" -lt "$json_len" ] || return 1
        escape=${json_input:json_pos:1}
        case "$escape" in
          '"'|'/'|b|f|n|r|t|\\) json_pos=$((json_pos + 1)) ;;
          u)
            json_pos=$((json_pos + 1))
            for ((i = 0; i < 4; i++)); do
              [ "$json_pos" -lt "$json_len" ] || return 1
              [[ "${json_input:json_pos:1}" =~ ^[0-9A-Fa-f]$ ]] || return 1
              json_pos=$((json_pos + 1))
            done
            ;;
          *) return 1 ;;
        esac
        ;;
      [[:cntrl:]]) return 1 ;;
      *)
        json_string+=$char
        json_pos=$((json_pos + 1))
        ;;
    esac
  done
  return 1
}

json_parse_literal() {
  local literal=$1
  [ "${json_input:json_pos:${#literal}}" = "$literal" ] || return 1
  json_pos=$((json_pos + ${#literal}))
}

json_parse_number() {
  local rest token
  rest=${json_input:json_pos}
  if [[ "$rest" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)? ]]; then
    token=${BASH_REMATCH[0]}
    json_pos=$((json_pos + ${#token}))
    return 0
  fi
  return 1
}

json_parse_value() {
  local depth=$1 char
  json_skip_ws
  char=${json_input:json_pos:1}
  case "$char" in
    '{') json_parse_object "$depth" ;;
    '[') json_parse_array "$depth" ;;
    '"') json_parse_string ;;
    t) json_parse_literal true ;;
    f) json_parse_literal false ;;
    n) json_parse_literal null ;;
    -|[0-9]) json_parse_number ;;
    *) return 1 ;;
  esac
}

json_parse_array() {
  local depth=$1 char
  [ "${json_input:json_pos:1}" = '[' ] || return 1
  json_pos=$((json_pos + 1))
  json_skip_ws
  char=${json_input:json_pos:1}
  if [ "$char" = ']' ]; then
    json_pos=$((json_pos + 1))
    return 0
  fi
  while :; do
    json_parse_value "$((depth + 1))" || return 1
    json_skip_ws
    char=${json_input:json_pos:1}
    case "$char" in
      ',')
        json_pos=$((json_pos + 1))
        ;;
      ']')
        json_pos=$((json_pos + 1))
        return 0
        ;;
      *) return 1 ;;
    esac
  done
}

json_parse_object() {
  local depth=$1 char key
  [ "${json_input:json_pos:1}" = '{' ] || return 1
  json_pos=$((json_pos + 1))
  json_skip_ws
  char=${json_input:json_pos:1}
  if [ "$char" = '}' ]; then
    json_pos=$((json_pos + 1))
    return 0
  fi
  while :; do
    json_skip_ws
    json_parse_string || return 1
    [ "$json_string_had_escape" = false ] || return 1
    key=$json_string
    json_skip_ws
    [ "${json_input:json_pos:1}" = ':' ] || return 1
    json_pos=$((json_pos + 1))
    if [ "$depth" -eq 0 ] && [ "$key" = stop_hook_active ]; then
      [ "$json_stop_seen" = false ] || json_stop_valid=false
      json_stop_seen=true
      json_skip_ws
      case "${json_input:json_pos:4}" in
        true)
          json_parse_literal true || return 1
          [ "$json_stop_valid" = true ] && json_stop_active=true
          ;;
        false)
          json_parse_literal false || return 1
          ;;
        *)
          json_stop_valid=false
          json_parse_value "$((depth + 1))" || return 1
          ;;
      esac
    else
      json_parse_value "$((depth + 1))" || return 1
    fi
    json_skip_ws
    char=${json_input:json_pos:1}
    case "$char" in
      ',')
        json_pos=$((json_pos + 1))
        ;;
      '}')
        json_pos=$((json_pos + 1))
        return 0
        ;;
      *) return 1 ;;
    esac
  done
}

stop_hook_active_without_jq() {
  json_input=$1
  json_pos=0
  json_len=${#json_input}
  json_string=
  json_string_had_escape=false
  json_stop_active=false
  json_stop_seen=false
  json_stop_valid=true
  json_parse_object 0 || return 1
  json_skip_ws
  [ "$json_pos" -eq "$json_len" ] || return 1
  [ "$json_stop_valid" = true ] && [ "$json_stop_active" = true ]
}

stop_hook_active_from_payload() {
  local value
  if command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$1" | jq -n --stream -e 'reduce inputs as $event (0; if ($event | length == 2 and .[0] == ["stop_hook_active"]) then . + 1 else . end) == 1' >/dev/null 2>&1; then
      return 1
    fi
    value=$(printf '%s' "$1" | jq -e -s 'if length == 1 and (.[0] | type == "object") and (.[0].stop_hook_active | type == "boolean") then .[0].stop_hook_active else empty end' 2>/dev/null) || return 1
    [ "$value" = true ]
    return
  fi
  stop_hook_active_without_jq "$1"
}

if [ "$PAYLOAD_HAS_NUL" = false ] && stop_hook_active_from_payload "$STOP_INPUT"; then
  exit 0
fi

if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
watch_lock_matches_pid() {
  fm_watcher_lock_matches_pid "$WATCH_LOCK" "$1" "$FM_HOME" "$WATCH_PATH"
}

BEAT="$STATE/.last-watcher-beat"
beacon_fresh=false
beacon_desc=never
if [ -e "$BEAT" ]; then
  m=$(stat_mtime "$BEAT")
  if [ -n "$m" ]; then
    age=$(( $(date +%s) - m ))
    beacon_desc="${age}s ago"
    [ "$age" -lt "$GRACE" ] && beacon_fresh=true
  else
    beacon_desc=unknown
  fi
fi

lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
watcher_confirmed=false
if [ "$beacon_fresh" = true ] && fm_pid_alive "$lock_pid" \
  && watch_lock_matches_pid "$lock_pid"; then
  watcher_confirmed=true
fi
[ "$watcher_confirmed" = true ] && exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but no watcher has a confirmed live lock (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
  printf '●  Re-arm supervision before ending this turn: run bin/fm-watch-arm.sh as the harness-tracked background task.\n'
  printf '●%s\n' "$rule"
} >&2
exit 2
