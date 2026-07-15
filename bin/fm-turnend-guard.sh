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
if [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi
if [ -n "$PAYLOAD" ]; then
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

stop_hook_active_from_payload() {
  local value
  if command -v jq >/dev/null 2>&1; then
    value=$(printf '%s' "$1" | jq -er 'if type == "object" and (.stop_hook_active | type) == "boolean" then .stop_hook_active else empty end' 2>/dev/null) || return 1
    [ "$value" = true ]
    return
  fi
  [[ "$1" =~ ^[[:space:]]*\{[[:space:]]*\"stop_hook_active\"[[:space:]]*:[[:space:]]*true[[:space:]]*\}[[:space:]]*$ ]]
}

stop_hook_active_from_payload "$STOP_INPUT" && exit 0

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
