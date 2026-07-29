#!/usr/bin/env bash
# Acquire or inspect the per-home Firstmate session lock.
# Writes a verified harness PID. Codex adds its stable thread marker and whether
# the PID came from verified ancestry or a PID-isolated fallback.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#
# This script is the ONLY writer of state/.lock. The owner record is never
# hand-edited, and acquisition never displaces a live holder: an existing lock
# naming another live harness refuses, and a declared task worker
# (bin/fm-worker-isolation-lib.sh) refuses acquisition before touching the
# record at all, while its read-only `status` inspection stays available.
# A task child that inherited a primary's FM_HOME would otherwise resolve THIS
# home's state directory and take the primary's own session ownership - the
# 2026-07-24 incident where a suspended-then-resumed primary came back locked
# out of its own home and stopped monitoring.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
# Refuse acquisition before any state directory is resolved or created, so a
# task worker cannot even publish a probe file into the home it inherited.
# Read-only `status` keeps its documented always-exit-0 contract.
if [ "${1:-}" != status ]; then
  fm_worker_refuse_primary_operation "session lock acquisition" || exit 1
fi
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = status ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || { echo "lock: unreadable"; exit 0; }
  fm_session_lock_holder_state "$old"
  holder_status=$?
  case "$holder_status" in
    0) case "$old" in
         *'|codex:'*) echo "lock: held by live Codex session owner $old" ;;
         *) echo "lock: held by live harness pid $old" ;;
       esac ;;
    1) echo "lock: stale (owner $old dead or not a harness)" ;;
    2) echo "lock: held by unverifiable Codex session owner $old" ;;
    *) echo "lock: invalid owner record; manual inspection required" ;;
  esac
  exit 0
fi

mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

owner=$(fm_session_lock_owner) || {
  echo "error: cannot locate harness process in ancestry" >&2
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  old_marker=$(fm_codex_owner_marker "$old" 2>/dev/null || true)
  owner_marker=$(fm_codex_owner_marker "$owner" 2>/dev/null || true)
  if [ -n "$old_marker" ] && [ "$old_marker" = "$owner_marker" ]; then
    owner=$old
  elif [ "$old" = "${owner%%|*}" ] && [ -n "$owner_marker" ]; then
    :
  elif [ "$old" != "$owner" ]; then
    fm_session_lock_holder_state "$old"
    holder_status=$?
    case "$holder_status" in
      0)
        echo "error: another live firstmate session holds the lock (owner $old); operate read-only until resolved" >&2
        exit 1 ;;
      2)
        echo "error: cannot verify whether another Codex session holds the lock (owner $old); operate read-only until resolved" >&2
        exit 1 ;;
      3)
        echo "error: session lock has an invalid owner record; operate read-only until resolved" >&2
        exit 1 ;;
    esac
  fi
fi
ROOT_REAL=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || exit 1
BINDING="$STATE/.primary-checkout"
OLD_LOCK_PRESENT=0
OLD_LOCK=
OLD_BINDING_PRESENT=0
OLD_BINDING=
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  OLD_LOCK=$(cat "$LOCK") || exit 1
  OLD_LOCK_PRESENT=1
fi
if [ -e "$BINDING" ] || [ -L "$BINDING" ]; then
  if [ ! -f "$BINDING" ] || [ -L "$BINDING" ]; then
    echo "error: cannot bind the session lock to its primary checkout" >&2
    exit 1
  fi
  OLD_BINDING=$(cat "$BINDING") || exit 1
  OLD_BINDING_PRESENT=1
fi
restore_session_authority() {
  local tmp
  if [ "$OLD_BINDING_PRESENT" -eq 1 ]; then
    tmp=$(mktemp "$STATE/.primary-checkout.restore.XXXXXX") || return 1
    printf '%s\n' "$OLD_BINDING" > "$tmp" && chmod 600 "$tmp" \
      && mv "$tmp" "$BINDING" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$BINDING" || return 1
  fi
  if [ "$OLD_LOCK_PRESENT" -eq 1 ]; then
    tmp=$(mktemp "$STATE/.lock.restore.XXXXXX") || return 1
    printf '%s\n' "$OLD_LOCK" > "$tmp" && chmod 600 "$tmp" \
      && mv "$tmp" "$LOCK" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$LOCK" || return 1
  fi
}
BINDING_TMP=$(mktemp "$STATE/.primary-checkout.XXXXXX" 2>/dev/null) || exit 1
LOCK_TMP=$(mktemp "$STATE/.lock.XXXXXX" 2>/dev/null) || {
  rm -f "$BINDING_TMP"
  exit 1
}
if ! printf '%s\n' "$ROOT_REAL" > "$BINDING_TMP" \
   || ! chmod 600 "$BINDING_TMP" \
   || ! printf '%s\n' "$owner" > "$LOCK_TMP" \
   || ! chmod 600 "$LOCK_TMP"; then
  rm -f "$BINDING_TMP" "$LOCK_TMP"
  echo "error: cannot bind the session lock to its primary checkout" >&2
  exit 1
fi
if ! mv "$BINDING_TMP" "$BINDING"; then
  rm -f "$BINDING_TMP" "$LOCK_TMP"
  echo "error: cannot bind the session lock to its primary checkout" >&2
  exit 1
fi
if ! mv "$LOCK_TMP" "$LOCK"; then
  rm -f "$LOCK_TMP"
  restore_session_authority || true
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
if ! written=$(cat "$LOCK" 2>/dev/null); then
  restore_session_authority || true
  exit 1
fi
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$owner" ]; then
  restore_session_authority || true
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
case "$owner" in
  *'|codex:'*) echo "lock acquired: Codex session owner $owner" ;;
  *) echo "lock acquired: harness pid $owner" ;;
esac
