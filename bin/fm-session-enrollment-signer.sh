#!/usr/bin/env bash
set -eu

[ "$#" -eq 4 ] || exit 2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_enrollment_signer_run "$1" "$2" "$3" "$4"
