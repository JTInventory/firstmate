#!/usr/bin/env bash
# Captain-gated task PR merge: records landed-work evidence before delegating.
# Usage: FM_CAPTAIN_APPROVED_MERGE=1 fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

[ "${FM_CAPTAIN_APPROVED_MERGE:-}" = 1 ] || { echo 'error: captain approval is required; set FM_CAPTAIN_APPROVED_MERGE=1 for an explicitly approved merge' >&2; exit 1; }
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

if [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]] && [[ "${BASH_REMATCH[1]}" != *- ]]; then
  OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; NUMBER="${BASH_REMATCH[3]}"
else
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $URL)" >&2; exit 1
fi
for arg in "$@"; do
  case "$arg" in --repo|--repo=*|-R|-R?*) echo "error: merge args must not override the repository parsed from the PR URL" >&2; exit 1;; esac
done

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL; refusing to merge" >&2; exit 1; }
method=(--squash)
for arg in "$@"; do case "$arg" in --squash|--merge|--rebase|--method|--method=*) method=(); break;; esac; done
gh-axi pr merge "$NUMBER" --repo "$OWNER/$REPO" "${method[@]}" "$@"
