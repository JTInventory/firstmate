#!/usr/bin/env bash
set -eu

[ "$#" -eq 7 ] || exit 2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
[ -n "${FM_SESSION_ENROLLMENT_PUBLIC_SHA256:-}" ] \
  || fm_session_enrollment_signer_prepare "$SCRIPT_DIR/fm-session-enrollment-signer.sh" "$@"
fm_session_enrollment_signer_run "$1" "$2" "$3" "$4" "$5" "$6" "$7"
