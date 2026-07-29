#!/usr/bin/env bash
set -eu

[ "$#" -gt 0 ] || {
  echo "usage: fm-session-authority-exec.sh command [args...]" >&2
  exit 2
}
case "${FM_AGENT_ROLE:-}" in
  ""|primary)
    [ -z "${FM_AGENT_TASK:-}" ] && [ -z "${FM_AGENT_OWNER_HOME:-}" ] || {
      echo "error: task workers cannot create session authority" >&2
      exit 1
    }
    ;;
  secondmate)
    [ -n "${FM_AGENT_TASK:-}" ] && [ -n "${FM_AGENT_OWNER_HOME:-}" ] || {
      echo "error: incomplete secondmate identity cannot create session authority" >&2
      exit 1
    }
    ;;
  *) echo "error: task workers cannot create session authority" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
authority="$STATE/.session-authority"
home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || exit 1
fm_session_authority_read "$authority" \
  && [ "$FM_SESSION_AUTHORITY_HOME" = "$home_real" ] \
  && fm_session_authority_is_current_ancestor "$authority" || {
  echo "error: trusted session enrollment capability is missing or invalid" >&2
  exit 1
}

authority_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-authority.XXXXXX") || exit 1
cleanup_authority_file() {
  rm -f -- "$authority_file"
}
trap cleanup_authority_file EXIT HUP INT TERM
chmod 600 "$authority_file"
fm_session_random_hex 48 > "$authority_file"
enrollment_fd=$FM_SESSION_AUTHORITY_FD
if [ "$enrollment_fd" != 9 ] && ( : <&9 ) 2>/dev/null; then
  echo "error: session authority descriptor 9 is already in use" >&2
  exit 1
fi
if [ "$enrollment_fd" = 9 ]; then
  exec 9<&-
else
  eval "exec ${enrollment_fd}<&-"
fi
exec 9<"$authority_file"
FM_SESSION_AUTHORITY_FD=9
export FM_SESSION_AUTHORITY_FD
rm -f -- "$authority_file"
trap - EXIT HUP INT TERM
exec "$@"
