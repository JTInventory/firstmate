#!/usr/bin/env bash
# Codex SessionStart/SessionEnd adapter for the per-home session lock.
# Usage: <Codex hook JSON> | fm-codex-session-lock-hook.sh
#
# SessionStart claims the lock before the first model turn with the externally
# provisioned descriptor capability. Later PID-isolated calls transfer that keyed
# authority without binding ownership to this short-lived hook process.
#
# SessionEnd removes only a regular lock whose Codex thread marker exactly
# matches the ending session. The comparison and removal run under the same
# acquisition lock as fm-lock.sh. A missing, malformed, unreadable, symlinked,
# differently owned, or concurrently busy lock is left untouched. Codex allows
# at most three seconds for SessionEnd hooks, so this adapter never waits for a
# busy acquisition lock and never delays a clean /quit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
AUTHORITY="$STATE/.session-authority"
PAYLOAD=$(cat 2>/dev/null || true)

command -v node >/dev/null 2>&1 || exit 0
PARSED=$(printf '%s' "$PAYLOAD" | node -e '
let payload = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => payload += chunk);
process.stdin.on("end", () => {
  try {
    const value = JSON.parse(payload);
    if (!value || Array.isArray(value)
      || typeof value.hook_event_name !== "string"
      || typeof value.session_id !== "string") process.exit(1);
    process.stdout.write(value.hook_event_name + "\n" + value.session_id);
  } catch {
    process.exit(1);
  }
});
' 2>/dev/null) || exit 0
case "$PARSED" in *$'\n'*) ;; *) exit 0 ;; esac
EVENT=${PARSED%%$'\n'*}
SESSION_ID=${PARSED#*$'\n'}
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in *[!A-Za-z0-9._:-]*) exit 0 ;; esac
if [ -n "${CODEX_THREAD_ID:-}" ] && [ "$CODEX_THREAD_ID" != "$SESSION_ID" ]; then
  exit 0
fi
export CODEX_THREAD_ID="$SESSION_ID"

if [ "$EVENT" = SessionStart ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || true
  exit 0
fi
[ "$EVENT" = SessionEnd ] || exit 0
[ -e "$LOCK" ] || [ -L "$LOCK" ] || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  exit 0
fi
release_claim_lock() {
  fm_lock_release "$CLAIM_LOCK"
}
trap release_claim_lock EXIT
trap 'exit 0' HUP INT TERM

[ -f "$LOCK" ] && [ ! -L "$LOCK" ] || exit 0
OWNER=$(cat "$LOCK" 2>/dev/null) || exit 0
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
MARKER=$(fm_codex_owner_marker "$OWNER" 2>/dev/null || true)
[ -n "$(fm_codex_owner_kind "$OWNER" 2>/dev/null || true)" ] || exit 0
[ "$MARKER" = "$SESSION_ID" ] || exit 0
if [ -e "$AUTHORITY" ] || [ -L "$AUTHORITY" ]; then
  [ -f "$AUTHORITY" ] && [ ! -L "$AUTHORITY" ] || exit 0
  fm_session_authority_read "$AUTHORITY" || exit 0
  [ "$FM_SESSION_AUTHORITY_OWNER" = "$OWNER" ] || exit 0
  fm_session_authority_is_current_ancestor "$AUTHORITY" || exit 0
else
  fm_session_authority_capability_present || exit 0
  fm_session_legacy_owner_is_current "$OWNER" || exit 0
fi
rm -f "$AUTHORITY" "$LOCK" 2>/dev/null || true
