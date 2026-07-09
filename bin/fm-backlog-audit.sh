#!/usr/bin/env bash
# Read-only consistency audit for firstmate backlog/state drift.
#
# Checks data/backlog.md against state/*.meta for common supervision drift:
# duplicate In flight/Done entries, orphan meta files, In flight items without
# meta, PR-ready/merged work still parked In flight, and Watchlist items that
# already have local adoption signals.
# Usage: fm-backlog-audit.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG="$DATA/backlog.md"

declare -A IN_FLIGHT_LINES=()
declare -A DONE_LINES=()
declare -A WATCHLIST_LINES=()
declare -A SECONDMATE_BACKLOG_LINES=()
declare -A SECONDMATE_REGISTRY_LINES=()
FINDINGS=()

add_finding() {
  FINDINGS+=("$1")
}

parse_backlog() {
  awk '
    function task_id(line, rest, id) {
      rest = line
      sub(/^[[:space:]]*-[[:space:]]+/, "", rest)
      sub(/^\[[ xX]\][[:space:]]+/, "", rest)
      if (rest ~ /^\*\*/) {
        sub(/^\*\*/, "", rest)
        id = rest
        sub(/\*\*.*/, "", id)
        return id
      }
      id = rest
      sub(/[[:space:]].*/, "", id)
      return id
    }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "", section)
      next
    }
    /^[[:space:]]*-[[:space:]]+/ {
      id = task_id($0)
      if (id != "") {
        print section "\t" id "\t" $0
      }
    }
  ' "$BACKLOG"
}

looks_pr_ready_or_merged() {
  local line=$1
  case "$line" in
    *"PR ready"*|*"checks green"*|*"merged"*|*"MERGED"*)
      return 0
      ;;
  esac
  return 1
}

meta_kind() {
  local meta=$1
  awk -F= '$1 == "kind" { print $2; exit }' "$meta"
}

parse_secondmate_registry() {
  local registry=$1
  awk '
    function secondmate_id(line, rest, id) {
      rest = line
      sub(/^[[:space:]]*-[[:space:]]+/, "", rest)
      id = rest
      sub(/[[:space:]].*/, "", id)
      return id
    }
    /^[[:space:]]*-[[:space:]]+/ {
      id = secondmate_id($0)
      if (id != "") {
        print id "\t" $0
      }
    }
  ' "$registry"
}

is_registered_secondmate() {
  local id=$1
  [ -n "${SECONDMATE_BACKLOG_LINES[$id]+set}" ] || [ -n "${SECONDMATE_REGISTRY_LINES[$id]+set}" ]
}

if [ ! -f "$BACKLOG" ]; then
  echo "backlog-audit: missing backlog at $BACKLOG" >&2
  exit 1
fi

while IFS=$'\t' read -r section id line; do
  case "$section" in
    "In flight")
      IN_FLIGHT_LINES["$id"]=$line
      ;;
    "Done")
      DONE_LINES["$id"]=$line
      ;;
    "Watchlist")
      WATCHLIST_LINES["$id"]=$line
      ;;
    "Secondmate Backlogs")
      SECONDMATE_BACKLOG_LINES["$id"]=$line
      ;;
  esac
done < <(parse_backlog)

if [ -f "$DATA/secondmates.md" ]; then
  while IFS=$'\t' read -r id line; do
    SECONDMATE_REGISTRY_LINES["$id"]=$line
  done < <(parse_secondmate_registry "$DATA/secondmates.md")
fi

for id in "${!IN_FLIGHT_LINES[@]}"; do
  if [ -n "${DONE_LINES[$id]+set}" ]; then
    add_finding "duplicate-done: $id listed in both In flight and Done"
  fi
  if [ ! -f "$STATE/$id.meta" ]; then
    add_finding "inflight-without-meta: $id is In flight but has no state meta"
  fi
  if looks_pr_ready_or_merged "${IN_FLIGHT_LINES[$id]}"; then
    add_finding "inflight-pr-ready: $id is still In flight but looks PR-ready or merged"
  fi
done

if [ -d "$STATE" ]; then
  shopt -s nullglob
  for meta in "$STATE"/*.meta; do
    id=$(basename "$meta" .meta)
    if [ -z "${IN_FLIGHT_LINES[$id]+set}" ]; then
      if [ "$(meta_kind "$meta")" = "secondmate" ]; then
        if ! is_registered_secondmate "$id"; then
          add_finding "meta-without-inflight: $id has unregistered secondmate state meta and is not in In flight"
        fi
      else
        add_finding "meta-without-inflight: $id has state meta but is not in In flight"
      fi
    fi
  done
  shopt -u nullglob
fi

for id in "${!WATCHLIST_LINES[@]}"; do
  if [ -n "${IN_FLIGHT_LINES[$id]+set}" ]; then
    add_finding "watchlist-adopted: $id is still on Watchlist but already listed In flight"
  elif [ -f "$STATE/$id.meta" ]; then
    add_finding "watchlist-adopted: $id is still on Watchlist but already has local state meta"
  fi
done

if [ "${#FINDINGS[@]}" -eq 0 ]; then
  echo "No backlog/state drift found."
  echo "No changes made."
  exit 0
fi

echo "Backlog/state drift found:"
for finding in "${FINDINGS[@]}"; do
  printf -- '- %s\n' "$finding"
done
echo "No changes made."
exit 1
