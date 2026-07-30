#!/usr/bin/env bash
set -eu

public_digest_arg=
if [ "${1:-}" = --public-sha256 ]; then
  [ "$#" -eq 9 ] || exit 2
  public_digest_arg=$2
  shift 2
fi
[ "$#" -eq 7 ] || exit 2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
if [ "${FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD:-}" != 10 ] \
  || [ ! -r /dev/fd/10 ] \
  || [ -z "${FM_SESSION_ENROLLMENT_PUBLIC_SHA256:-}" ]; then
  fm_session_enrollment_signer_prepare
fi
[ -n "$public_digest_arg" ] || exec "$SCRIPT_DIR/fm-session-enrollment-signer.sh" \
  --public-sha256 "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" "$@"
[ "$public_digest_arg" = "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" ] || exit 1
fm_session_enrollment_signer_run "$1" "$2" "$3" "$4" "$5" "$6" "$7"
