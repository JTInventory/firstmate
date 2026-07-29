#!/usr/bin/env bash
set -u
ROOT=$1
LOCK=$2
PHASE=${3:-old}
FM_WAKE_LIB_READ_ONLY=1
export FM_WAKE_LIB_READ_ONLY
. "$ROOT/bin/fm-wake-lib.sh"
if [ "$PHASE" = old ]; then
  fm_lock_try_acquire "$LOCK" || exit 1
  OWNER=$(fm_lock_link_owner "$LOCK") || exit 1
  rm -f "$OWNER/process-token"
  export FM_UPDATE_REEXECED=1
  exec "$0" "$ROOT" "$LOCK" new
fi
fm_lifecycle_admission_adopt_legacy_update_reexec \
  "$LOCK" "$0" || exit 1
fm_lifecycle_admission_lock_owned_by_process "$LOCK" || exit 1
fm_lock_release "$LOCK"
