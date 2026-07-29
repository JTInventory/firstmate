#!/usr/bin/env bash
set -u
ROOT=$1
LOCK=$2
FM_WAKE_LIB_READ_ONLY=1
export FM_WAKE_LIB_READ_ONLY
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$LOCK" || exit 1
OWNER=$(fm_lock_link_owner "$LOCK") || exit 1
fm_lifecycle_admission_authorize_reexec "$LOCK" "$0" || exit 1
printf 'v1:stale identity\n' > "$OWNER/pid-identity"
fm_lifecycle_admission_lock_owned_by_process "$LOCK" || exit 1
printf 'wrong-token\n' > "$OWNER/process-token"
if fm_lifecycle_admission_lock_owned_by_process "$LOCK"; then
  exit 1
fi
printf '%s\n' "$FM_LOCK_PROCESS_TOKEN" > "$OWNER/process-token"
fm_lock_release "$LOCK"
