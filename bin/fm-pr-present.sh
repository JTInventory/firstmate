#!/usr/bin/env bash
# Freeze the exact GitHub PR head that was presented to the captain.
# Usage: fm-pr-present.sh <task-id> <full-pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_BIN="${FM_PR_CHECK_BIN:-$SCRIPT_DIR/fm-pr-check.sh}"

. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "$#" -eq 2 ] || { echo 'usage: fm-pr-present.sh <task-id> <full-pr-url>' >&2; exit 2; }
ID=$1
RAW_URL=$2
fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || {
  echo 'error: presentation requires a canonical GitHub PR URL' >&2; exit 1;
}
URL=$FM_PR_URL
PRESENTATION_LOCK="$STATE/.$ID.pr-presentation.lock"
PRESENTATION_LOCK_HELD=0
release_presentation_lock() {
  [ "$PRESENTATION_LOCK_HELD" -eq 1 ] || return 0
  PRESENTATION_LOCK_HELD=0
  fm_lock_release "$PRESENTATION_LOCK"
}
trap release_presentation_lock EXIT
fm_lock_acquire_wait "$PRESENTATION_LOCK"
PRESENTATION_LOCK_HELD=1
"$CHECK_BIN" "$ID" "$URL"
META="$STATE/$ID.meta"
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || {
  echo 'error: task metadata is unavailable after PR validation' >&2; exit 1;
}
pr_count=0; head_count=0; recorded_url=; recorded_head=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*) pr_count=$((pr_count + 1)); recorded_url=${line#pr=} ;;
    pr_head=*) head_count=$((head_count + 1)); recorded_head=${line#pr_head=} ;;
  esac
done < "$META"
[ "$pr_count" -eq 1 ] && [ "$recorded_url" = "$URL" ] \
  && [ "$head_count" -eq 1 ] && fm_pr_head_valid "$recorded_head" || {
    echo 'error: PR validation did not produce one exact head; refusing presentation' >&2; exit 1;
  }
fm_pr_presentation_publish "$STATE" "$ID" "$URL" "$recorded_head" || {
  echo 'error: could not publish protected PR presentation receipt' >&2; exit 1;
}
printf 'presented: %s at %s\n' "$URL" "$recorded_head"
