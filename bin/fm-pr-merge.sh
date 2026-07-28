#!/usr/bin/env bash
# Captain-gated merge bound to one exact URL, head, base, and presentation nonce.
# Usage: FM_CAPTAIN_APPROVED_MERGE=1 FM_CAPTAIN_APPROVED_PR_HEAD=<sha> FM_CAPTAIN_APPROVED_PRESENTATION_NONCE=<nonce> fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge args>]}
RAW_URL=${2:?usage: fm-pr-merge.sh <task-id> <full-pr-url> [-- <merge args>]}
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
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || {
  echo 'error: merge requires a canonical GitHub PR URL' >&2; exit 1;
}
URL=$FM_PR_URL; OWNER=$FM_PR_OWNER; REPO=$FM_PR_REPO; NUMBER=$FM_PR_NUMBER
META="$STATE/$ID.meta"; RECEIPT="$STATE/$ID.pr-presentation"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe meta for task $ID" >&2; exit 1; }

method=squash
commit_title=
commit_message=
delete_branch=0
match_head=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash|-s) method=squash ;;
    --merge|-m) method=merge ;;
    --rebase|-r) method=rebase ;;
    --method=squash|--method=merge|--method=rebase) method=${1#--method=} ;;
    --method)
      shift; case "${1:-}" in squash|merge|rebase) method=$1 ;; *) echo 'error: invalid merge method' >&2; exit 1 ;; esac ;;
    --subject=*) commit_title=${1#--subject=} ;;
    --subject|-t)
      shift; [ "$#" -gt 0 ] || { echo 'error: merge subject requires a value' >&2; exit 1; }
      commit_title=$1
      ;;
    --body=*) commit_message=${1#--body=} ;;
    --body|-b)
      shift; [ "$#" -gt 0 ] || { echo 'error: merge body requires a value' >&2; exit 1; }
      commit_message=$1
      ;;
    --body-file=*) body_file=${1#--body-file=}; commit_message=$(cat -- "$body_file") ;;
    --body-file|-F)
      shift; [ "$#" -gt 0 ] || { echo 'error: merge body file requires a value' >&2; exit 1; }
      commit_message=$(cat -- "$1")
      ;;
    --delete-branch|-d) delete_branch=1 ;;
    --match-head-commit=*) match_head=${1#--match-head-commit=} ;;
    --match-head-commit)
      shift; [ "$#" -gt 0 ] || { echo 'error: matched head requires a SHA' >&2; exit 1; }
      match_head=$1
      ;;
    --auto|--disable-auto|--admin|-A|--author-email|--author-email=*)
      echo "error: $1 is incompatible with an immediate merge bound to the captain-approved head" >&2
      exit 1
      ;;
    *) echo "error: unsupported merge argument: $1" >&2; exit 1 ;;
  esac
  shift
done

APPROVED_HEAD=${FM_CAPTAIN_APPROVED_PR_HEAD:-}
APPROVED_NONCE=${FM_CAPTAIN_APPROVED_PRESENTATION_NONCE:-}
fm_pr_head_valid "$APPROVED_HEAD" || {
  echo 'error: captain approval must include the exact presented head in FM_CAPTAIN_APPROVED_PR_HEAD' >&2
  exit 1
}
fm_pr_presentation_nonce_valid "$APPROVED_NONCE" || {
  echo 'error: captain approval must include the exact presentation nonce in FM_CAPTAIN_APPROVED_PRESENTATION_NONCE' >&2
  exit 1
}
[ -z "$match_head" ] || {
  fm_pr_head_valid "$match_head" && [ "$match_head" = "$APPROVED_HEAD" ] || {
    echo 'error: matched head does not equal the captain-approved presented head' >&2
    exit 1
  }
}

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

fm_pr_presentation_parse "$RECEIPT" \
  && [ "$FM_PR_PRESENTATION_URL" = "$URL" ] \
  && [ "$FM_PR_PRESENTATION_HEAD" = "$APPROVED_HEAD" ] \
  && [ "$FM_PR_PRESENTATION_NONCE" = "$APPROVED_NONCE" ] || {
    echo 'error: missing, malformed, or foreign PR presentation receipt; present the PR again' >&2; exit 1;
  }
PRESENTED_HEAD=$FM_PR_PRESENTATION_HEAD
PRESENTED_BASE_REF=$FM_PR_PRESENTATION_BASE_REF
PRESENTED_BASE=$FM_PR_PRESENTATION_BASE

# Refresh mutable poll/meta state, but never the separate presentation receipt.
"$CHECK_BIN" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo 'error: PR validation did not preserve identity' >&2; exit 1; }

CURRENT_PR=$(gh-axi api GET "/repos/$OWNER/$REPO/pulls/$NUMBER" \
  --jq '{head_b64: (.head.sha | @base64), base_ref_b64: (.base.ref | @base64), base_b64: (.base.sha | @base64), head_repo_b64: (.head.repo.full_name | @base64), head_ref_b64: (.head.ref | @base64)}' \
  2>/dev/null || true)
if fm_pr_toon_base64_field_parse "$CURRENT_PR" head_b64; then CURRENT_HEAD=$FM_PR_TOON_VALUE; else CURRENT_HEAD=; fi
if fm_pr_toon_base64_field_parse "$CURRENT_PR" base_ref_b64; then CURRENT_BASE_REF=$FM_PR_TOON_VALUE; else CURRENT_BASE_REF=; fi
if fm_pr_toon_base64_field_parse "$CURRENT_PR" base_b64; then CURRENT_BASE=$FM_PR_TOON_VALUE; else CURRENT_BASE=; fi
if ! fm_pr_head_valid "$CURRENT_HEAD" || [ "$CURRENT_HEAD" != "$PRESENTED_HEAD" ] \
  || [ "$CURRENT_BASE_REF" != "$PRESENTED_BASE_REF" ] \
  || ! fm_pr_head_valid "$CURRENT_BASE" || [ "$CURRENT_BASE" != "$PRESENTED_BASE" ]; then
  fm_pr_presentation_invalidate "$STATE" "$ID" || true
  echo 'error: PR head or base changed or could not be verified; captain approval is stale and presentation was invalidated' >&2
  exit 1
fi

merge_fields=(--raw-field "sha=$PRESENTED_HEAD" --raw-field "merge_method=$method")
[ -z "$commit_title" ] || merge_fields+=(--raw-field "commit_title=$commit_title")
[ -z "$commit_message" ] || merge_fields+=(--raw-field "commit_message=$commit_message")
if [ "$delete_branch" -eq 1 ]; then
  fm_pr_toon_base64_field_parse "$CURRENT_PR" head_repo_b64 || {
    echo 'error: could not verify the PR head repository for branch deletion' >&2; exit 1;
  }
  HEAD_REPO=$FM_PR_TOON_VALUE
  fm_pr_toon_base64_field_parse "$CURRENT_PR" head_ref_b64 || {
    echo 'error: could not verify the PR head branch for deletion' >&2; exit 1;
  }
  HEAD_REF=$FM_PR_TOON_VALUE
  fm_pr_url_parse "https://github.com/$HEAD_REPO/pull/1" \
    && [ "$FM_PR_PROVIDER" = github ] \
    && git check-ref-format "refs/heads/$HEAD_REF" >/dev/null 2>&1 || {
      echo 'error: unsafe PR head repository or branch; refusing requested branch deletion' >&2
      exit 1
    }
  ENCODED_HEAD_REF=$(fm_pr_url_encode_ref_path "$HEAD_REF") || {
    echo 'error: could not encode the PR head branch for deletion' >&2
    exit 1
  }
fi

if ! gh api --method PUT "/repos/$OWNER/$REPO/pulls/$NUMBER/merge" "${merge_fields[@]}"; then
  fm_pr_presentation_invalidate "$STATE" "$ID" || true
  echo 'error: atomic merge failed; presentation was invalidated' >&2
  exit 1
fi
if ! fm_pr_presentation_invalidate "$STATE" "$ID"; then
  echo 'warning: merge succeeded but the consumed presentation receipt could not be removed; teardown must reconcile it' >&2
fi
if [ "$delete_branch" -eq 1 ] \
  && ! gh-axi api DELETE "/repos/$HEAD_REPO/git/refs/heads/$ENCODED_HEAD_REF"; then
  echo 'warning: merge succeeded but the requested remote branch deletion failed' >&2
fi
