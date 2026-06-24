#!/usr/bin/env bash
# Record a PR-ready task: upserts pr=<url> to state/<id>.meta and arms the
# watcher's merge poll by writing state/<id>.check.sh, which prints one line iff
# the PR is merged (the watcher's check contract: output = wake firstmate,
# silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url> [direct|no-mistakes] [nm-status]
#   nm-status is optional and may be pr_recorded|passed|failed|skipped.
#   For no-mistakes PRs, the default is pr_recorded; pass "passed" only when the
#   gate actually passed or produced the PR.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2
SOURCE=${3:-direct}
NM_STATUS=${4:-}
case "$SOURCE" in
  direct|no-mistakes) ;;
  *) echo "error: pr source must be direct or no-mistakes" >&2; exit 1 ;;
esac
case "$NM_STATUS" in
  ''|pr_recorded|passed|failed|skipped) ;;
  *) echo "error: nm-status must be pr_recorded, passed, failed, or skipped" >&2; exit 1 ;;
esac

META="$STATE/$ID.meta"
meta_upsert() {
  local key=$1 value=$2 tmp
  [ -f "$META" ] || return 0
  tmp=$(mktemp "$META.tmp.XXXXXX")
  awk -v key="$key" -v value="$value" -F= '
    $1 == key {
      if (!seen) {
        print key "=" value
        seen = 1
      }
      next
    }
    { print }
    END {
      if (!seen) print key "=" value
    }
  ' "$META" > "$tmp"
  mv "$tmp" "$META"
}

meta_has() {
  local key=$1 value=$2
  [ -f "$META" ] || return 1
  grep -qxF "$key=$value" "$META"
}

if [ "$SOURCE" = no-mistakes ] && [ -z "$NM_STATUS" ]; then
  NM_STATUS=pr_recorded
elif [ "$SOURCE" = direct ] && [ -z "$NM_STATUS" ] && meta_has nm_gate on; then
  NM_STATUS=skipped
fi

meta_upsert pr "$URL"
meta_upsert pr_source "$SOURCE"
[ -n "$NM_STATUS" ] && meta_upsert nm_status "$NM_STATUS"

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
