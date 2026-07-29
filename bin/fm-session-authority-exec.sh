#!/usr/bin/env bash
set -eu

[ "$#" -gt 0 ] || {
  echo "usage: fm-session-authority-exec.sh command [args...]" >&2
  exit 2
}
case "${FM_AGENT_ROLE:-}" in
  ""|primary) ;;
  *) echo "error: task workers cannot create session authority" >&2; exit 1 ;;
esac
[ -z "${FM_AGENT_TASK:-}" ] && [ -z "${FM_AGENT_OWNER_HOME:-}" ] || {
  echo "error: task workers cannot create session authority" >&2
  exit 1
}

authority_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-authority.XXXXXX") || exit 1
cleanup_authority_file() {
  rm -f -- "$authority_file"
}
trap cleanup_authority_file EXIT HUP INT TERM
chmod 600 "$authority_file"
node -e 'process.stdout.write(require("crypto").randomBytes(48).toString("hex"))' \
  > "$authority_file"
exec {FM_SESSION_AUTHORITY_FD}<"$authority_file"
export FM_SESSION_AUTHORITY_FD
rm -f -- "$authority_file"
trap - EXIT HUP INT TERM
exec "$@"
