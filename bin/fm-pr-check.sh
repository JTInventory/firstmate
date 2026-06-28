#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and a verified pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-task-identity-lib.sh
. "$SCRIPT_DIR/fm-task-identity-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
fm_assert_task_branch_matches_meta "$ID" "$META" "error" || exit 1

EXPECTED_BRANCH=$(fm_task_expected_branch "$ID")
PR_BRANCH=$(gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null || true)
[ -n "$PR_BRANCH" ] || { echo "error: could not determine head branch for PR $URL" >&2; exit 1; }
if [ "$PR_BRANCH" != "$EXPECTED_BRANCH" ]; then
  echo "error: task identity mismatch for $ID: PR $URL head branch is $PR_BRANCH; expected $EXPECTED_BRANCH." >&2
  echo "Use the matching task id or intentionally reconcile the metadata before continuing." >&2
  exit 1
fi

if ! grep -qxF "pr=$URL" "$META"; then
  echo "pr=$URL" >> "$META"
fi

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
LOCAL_HEAD=
PR_HEAD=
if [ -n "$WT" ] && [ -d "$WT" ]; then
  LOCAL_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
  if [ -n "$LOCAL_HEAD" ] && command -v gh >/dev/null 2>&1; then
    if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
      if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
        PR_HEAD=$LOCAL_HEAD
      fi
    fi
  fi
fi
if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
  echo "pr_head=$PR_HEAD" >> "$META"
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
