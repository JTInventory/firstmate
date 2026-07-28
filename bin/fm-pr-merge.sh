#!/usr/bin/env bash
# Captain-gated merge bound atomically to the exact head shown to the captain.
# Usage: FM_CAPTAIN_APPROVED_MERGE=1 fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge method>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge method>]}
RAW_URL=${2:?usage: fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge method>]}
shift 2
[ "${1:-}" = -- ] && shift
[ "${FM_CAPTAIN_APPROVED_MERGE:-}" = 1 ] || {
  echo 'error: captain approval is required; set FM_CAPTAIN_APPROVED_MERGE=1 for an explicitly approved merge' >&2; exit 1;
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_BIN="${FM_PR_CHECK_BIN:-$SCRIPT_DIR/fm-pr-check.sh}"
. "$SCRIPT_DIR/fm-pr-lib.sh"

fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || {
  echo 'error: merge requires a canonical GitHub PR URL' >&2; exit 1;
}
URL=$FM_PR_URL; OWNER=$FM_PR_OWNER; REPO=$FM_PR_REPO; NUMBER=$FM_PR_NUMBER
META="$STATE/$ID.meta"; RECEIPT="$STATE/$ID.pr-presentation"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe meta for task $ID" >&2; exit 1; }

method=squash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) method=squash ;;
    --merge) method=merge ;;
    --rebase) method=rebase ;;
    --method=squash|--method=merge|--method=rebase) method=${1#--method=} ;;
    --method)
      shift; case "${1:-}" in squash|merge|rebase) method=$1 ;; *) echo 'error: invalid merge method' >&2; exit 1 ;; esac ;;
    *) echo "error: unsupported merge argument: $1" >&2; exit 1 ;;
  esac
  shift
done

fm_pr_presentation_parse "$RECEIPT" \
  && [ "$FM_PR_PRESENTATION_URL" = "$URL" ] || {
    echo 'error: missing, malformed, or foreign PR presentation receipt; present the PR again' >&2; exit 1;
  }
PRESENTED_HEAD=$FM_PR_PRESENTATION_HEAD

# Refresh mutable poll/meta state, but never the separate presentation receipt.
"$CHECK_BIN" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo 'error: PR validation did not preserve identity' >&2; exit 1; }

CURRENT_HEAD=$(gh-axi api GET "/repos/$OWNER/$REPO/pulls/$NUMBER" --jq .head.sha 2>/dev/null || true)
if ! fm_pr_head_valid "$CURRENT_HEAD" || [ "$CURRENT_HEAD" != "$PRESENTED_HEAD" ]; then
  fm_pr_presentation_invalidate "$STATE" "$ID" || true
  echo 'error: PR head changed or could not be verified; captain approval is stale and presentation was invalidated' >&2
  exit 1
fi

# GitHub checks the supplied sha atomically at mutation time, closing the gap
# between the preceding read and merge. Any failure requires re-presentation.
if ! gh-axi api PUT "/repos/$OWNER/$REPO/pulls/$NUMBER/merge" \
  --field "sha=$PRESENTED_HEAD" --field "merge_method=$method"; then
  fm_pr_presentation_invalidate "$STATE" "$ID" || true
  echo 'error: atomic merge failed; presentation was invalidated' >&2
  exit 1
fi
if ! fm_pr_presentation_invalidate "$STATE" "$ID"; then
  echo 'warning: merge succeeded but the consumed presentation receipt could not be removed; teardown must reconcile it' >&2
fi
