#!/usr/bin/env bash
# fm-bearings-snapshot.sh - compact TOON-by-default operator projection.
#
# The default path is local-only. `--include-prs` is the only path that makes a
# soft-failing gh-axi read for currently open PRs; the canonical fleet snapshot
# never performs that remote read.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-tool-path-lib.sh
. "$SCRIPT_DIR/fm-tool-path-lib.sh"
fm_normalize_tool_path
MODE=toon
INCLUDE_PRS=0

usage() {
  cat <<'USAGE'
Usage: fm-bearings-snapshot.sh [--json] [--include-prs] [--help]

Default output is a compact TOON projection. --json prints the same projection
as JSON. Remote PR discovery is opt-in with --include-prs and soft-fails.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) MODE=json ;;
    --include-prs) INCLUDE_PRS=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || {
  printf '%s\n' 'fm-bearings-snapshot.sh: jq is required for the projection' >&2
  exit 127
}

snapshot=$($SNAPSHOT --json)
pr_mode=local-only
pr_state=not-requested
remote_summary='not requested'
if [ "$INCLUDE_PRS" -eq 1 ]; then
  pr_mode=include-prs
  if command -v gh-axi >/dev/null 2>&1; then
    repo=${FM_BEARINGS_REPO:-JTInventory/firstmate}
    if remote_summary=$(gh-axi pr list --state open --limit 100 -R "$repo" 2>&1); then
      pr_state=ok
    else
      pr_state=unavailable
      remote_summary='remote PR discovery unavailable; local evidence retained'
    fi
  else
    pr_state=unavailable
    remote_summary='gh-axi unavailable; local evidence retained'
  fi
fi

projection=$(printf '%s\n' "$snapshot" | jq -c \
  --arg pr_mode "$pr_mode" --arg pr_state "$pr_state" \
  --arg remote_summary "$remote_summary" '
  . as $root |
  ($root.tasks | map(select(.pr_url != "none") | .pr_url)) as $recorded_prs |
  ($root.tasks | map({id,kind,project,worktree,branch,current_state,last_status,pr_url})) as $tasks |
  {
    schema: "fm-bearings-snapshot.v1",
    generated: $root.generated,
    fm_home: $root.roots.fm_home,
    prs: {mode:$pr_mode,state:$pr_state,recorded:$recorded_prs,remote_summary:$remote_summary},
    captain_call: ($tasks | map(select(.current_state.state == "parked" or .current_state.state == "blocked" or .current_state.state == "failed"))),
    recently_landed: ($tasks | map(select(.current_state.state == "done"))),
    underway: ($tasks | map(select(.current_state.state == "working" or .current_state.state == "paused"))),
    charted_next: [],
    tasks: $tasks
  }')

if [ "$MODE" = json ]; then
  printf '%s\n' "$projection"
  exit 0
fi

printf '%s\n' "$projection" | jq -r '
  "schema: \(.schema)", "generated: \(.generated)", "home: \(.fm_home)",
  "prs: \(.prs.mode)", "pr_state: \(.prs.state)",
  "captain_call[\(.captain_call|length)]:",
  (.captain_call[]? | "  - \(.id): \(.current_state.state)"),
  "recently_landed[\(.recently_landed|length)]:",
  (.recently_landed[]? | "  - \(.id)"),
  "underway[\(.underway|length)]:",
  (.underway[]? | "  - \(.id): \(.current_state.state)"),
  "charted_next[\(.charted_next|length)]:"
'
