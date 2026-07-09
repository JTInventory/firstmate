#!/usr/bin/env bash
# Read-only consistency audit for firstmate backlog/state drift.
#
# Checks data/backlog.md and data/secondmates.md against state/*.meta for common
# supervision drift: duplicate In flight/Done entries, orphan ordinary meta
# files, unregistered secondmate meta files, In flight items without meta,
# PR-ready/merged work still parked In flight, and Watchlist items that already
# have local adoption signals.
# Usage: fm-backlog-audit.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-backlog-audit-lib.sh
. "$SCRIPT_DIR/fm-backlog-audit-lib.sh"

if [ ! -f "$BACKLOG" ]; then
  echo "backlog-audit: missing backlog at $BACKLOG" >&2
  exit 1
fi

mapfile -t FINDINGS < <(fm_backlog_audit_collect "$DATA" "$STATE" | awk -F '\t' '$1 == "finding" { print $2 ": " $5 }')

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
