#!/usr/bin/env bash
# Freeze the exact GitHub PR URL, head, base, and nonce presented to the captain.
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
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
NUMBER=$FM_PR_NUMBER
PRESENTATION_LOCK="$STATE/.$ID.pr-presentation.lock"
PRESENTATION_LOCK_HELD=0
release_presentation_lock() {
  [ "$PRESENTATION_LOCK_HELD" -eq 1 ] || return 0
  PRESENTATION_LOCK_HELD=0
  fm_lock_release "$PRESENTATION_LOCK"
}
trap release_presentation_lock EXIT
if fm_pr_presentation_lock_acquire "$PRESENTATION_LOCK"; then
  :
else
  lock_rc=$?
  if [ "$lock_rc" -eq 2 ]; then
    echo 'error: unsafe PR presentation lock; refusing presentation' >&2
  else
    echo 'error: PR presentation lock remained busy; retry presentation' >&2
  fi
  exit 1
fi
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
PRESENTED_PR=$(gh-axi api GET "/repos/$OWNER/$REPO/pulls/$NUMBER" \
  --jq '{head_b64: (.head.sha | @base64), base_ref_b64: (.base.ref | @base64), base_b64: (.base.sha | @base64)}' \
  2>/dev/null || true)
if PRESENTED_HEAD=$(fm_pr_toon_base64_field_parse "$PRESENTED_PR" head_b64); then
  :
else
  PRESENTED_HEAD=
fi
if PRESENTED_BASE=$(fm_pr_toon_base64_field_parse "$PRESENTED_PR" base_b64); then
  :
else
  PRESENTED_BASE=
fi
if PRESENTED_BASE_REF=$(fm_pr_toon_base64_field_parse "$PRESENTED_PR" base_ref_b64); then
  :
else
  PRESENTED_BASE_REF=
fi
fm_pr_head_valid "$PRESENTED_HEAD" && [ "$PRESENTED_HEAD" = "$recorded_head" ] \
  && git check-ref-format "refs/heads/$PRESENTED_BASE_REF" >/dev/null 2>&1 \
  && fm_pr_head_valid "$PRESENTED_BASE" || {
    echo 'error: could not verify the exact presented PR head and base' >&2; exit 1;
  }
PRESENTATION_NONCE=$(fm_pr_presentation_nonce_new) || {
  echo 'error: could not create a unique PR presentation identity' >&2; exit 1;
}
fm_pr_presentation_publish "$STATE" "$ID" "$URL" "$PRESENTED_HEAD" \
  "$PRESENTED_BASE_REF" "$PRESENTED_BASE" "$PRESENTATION_NONCE" || {
  echo 'error: could not publish protected PR presentation receipt' >&2; exit 1;
}
printf 'presented: %s at %s onto %s@%s with nonce %s\n' \
  "$URL" "$PRESENTED_HEAD" "$PRESENTED_BASE_REF" "$PRESENTED_BASE" "$PRESENTATION_NONCE"
