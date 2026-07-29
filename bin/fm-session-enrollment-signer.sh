#!/usr/bin/env bash
set -eu

[ "$#" -eq 7 ] || exit 2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
if [ "${FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD:-}" != 10 ] \
  || [ ! -r /dev/fd/10 ] \
  || [ -z "${FM_SESSION_ENROLLMENT_PUBLIC_SHA256:-}" ]; then
  fm_session_enrollment_signer_prepare
fi
fm_session_enrollment_signer_run "$1" "$2" "$3" "$4" "$5" "$6" "$7"
