#!/usr/bin/env bash
# Acquire or inspect the per-home Firstmate session lock.
# Writes a descriptor-authenticated owner. Codex adds its stable thread marker.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#
# This script is the ONLY writer of state/.lock. The owner record is never
# hand-edited, and acquisition never displaces a live holder: an existing lock
# naming another live legacy owner refuses, and a declared task worker
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

fm_session_authority_broker_present "$SCRIPT_DIR/fm-session-authority-exec.sh" || {
  echo "error: trusted session authority broker is missing or invalid; operate read-only until resolved" >&2
  exit 1
}
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

fm_session_authority_capability_present || {
  echo "error: session authority capability is missing or invalid; operate read-only until resolved" >&2
  exit 1
}

fm_session_authority_admission_acquire || {
  echo "error: session authority admission could not be authenticated" >&2
  exit 1
}

fm_session_authority_transaction_recover "$STATE" || {
  echo "error: session authority recovery could not be verified; operate read-only until resolved" >&2
  exit 1
}
if [ -d "$STATE/.session-authority-transaction" ] \
  && [ ! -L "$STATE/.session-authority-transaction" ]; then
  fm_session_authority_transaction_finalize "$STATE" || {
    fm_session_authority_transaction_rollback "$STATE" || true
    echo "error: committed session authority recovery could not be finalized" >&2
    exit 1
  }
fi
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
if ! fm_lock_acquire_wait "$CLAIM_LOCK"; then
  echo "error: could not acquire the session-lock claim lock" >&2
  exit 1
fi
CLAIM_LOCK_HELD=1
AUTH_TXN="$STATE/.session-authority-transaction"
AUTHORITY="$STATE/.session-authority"
restore_session_authority_file() {
  local backup=$1 destination=$2 tmp
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
    tmp=$(mktemp "$STATE/.session-authority-restore.XXXXXX") || return 1
    cp -p "$backup" "$tmp" && mv "$tmp" "$destination" || {
      rm -f "$tmp"
      return 1
    }
    [ -f "$destination" ] && [ ! -L "$destination" ] \
      && cmp -s "$backup" "$destination"
    return
  fi
  rm -f "$destination" || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ]
}

restore_session_authority_from_transaction() {
  restore_session_authority_file "$AUTH_TXN/old-binding" "$STATE/.primary-checkout" \
    && restore_session_authority_file "$AUTH_TXN/old-authority" "$AUTHORITY" \
    && restore_session_authority_file "$AUTH_TXN/old-lock" "$LOCK"
}

session_authority_file_signature() {
  local file=$1 digest
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' absent
    return
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  digest=$(fm_session_sha256_file "$file") || return 1
  printf 'sha256:%s\n' "$digest"
}

session_authority_signature_valid() {
  local signature=$1 digest
  [ "$signature" != absent ] || return 0
  case "$signature" in sha256:*) digest=${signature#sha256:} ;; *) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
}

session_authority_manifest_read() {
  local manifest="$AUTH_TXN/manifest" key="$AUTH_TXN/key" body expected signature
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  [ -f "$key" ] && [ ! -L "$key" ] || return 1
  [ "$(wc -l < "$manifest" | tr -d ' ')" -eq 8 ] || return 1
  [ "$(sed -n '1p' "$manifest")" = version=2 ] || return 1
  body=$(sed -n '1,7p' "$manifest") || return 1
  expected=$(printf '%s\n' "$body" | fm_session_hmac_sha256_key_file "$key") || return 1
  [ "$(sed -n '8s/^hmac=//p' "$manifest")" = "$expected" ] || return 1
  AUTH_MANIFEST_HMAC=$expected
  AUTH_OLD_LOCK=${body#*$'\n'}; AUTH_OLD_LOCK=${AUTH_OLD_LOCK%%$'\n'*}; AUTH_OLD_LOCK=${AUTH_OLD_LOCK#old-lock=}
  AUTH_OLD_BINDING=$(sed -n '3s/^old-binding=//p' "$manifest")
  AUTH_OLD_AUTHORITY=$(sed -n '4s/^old-authority=//p' "$manifest")
  AUTH_NEW_LOCK=$(sed -n '5s/^new-lock=//p' "$manifest")
  AUTH_NEW_BINDING=$(sed -n '6s/^new-binding=//p' "$manifest")
  AUTH_NEW_AUTHORITY=$(sed -n '7s/^new-authority=//p' "$manifest")
  for signature in "$AUTH_OLD_LOCK" "$AUTH_OLD_BINDING" "$AUTH_OLD_AUTHORITY" \
    "$AUTH_NEW_LOCK" "$AUTH_NEW_BINDING" "$AUTH_NEW_AUTHORITY"; do
    session_authority_signature_valid "$signature" || return 1
  done
  [ "$(session_authority_file_signature "$AUTH_TXN/old-lock")" = "$AUTH_OLD_LOCK" ] \
    && [ "$(session_authority_file_signature "$AUTH_TXN/old-binding")" = "$AUTH_OLD_BINDING" ] \
    && [ "$(session_authority_file_signature "$AUTH_TXN/old-authority")" = "$AUTH_OLD_AUTHORITY" ]
}

if [ -d "$AUTH_TXN" ] && [ ! -L "$AUTH_TXN" ]; then
  [ -f "$AUTH_TXN/ready" ] && [ ! -L "$AUTH_TXN/ready" ] || {
    echo "error: session authority transaction is incomplete; operate read-only until resolved" >&2
    exit 1
  }
  session_authority_manifest_read || {
    echo "error: session authority transaction evidence is invalid; operate read-only until resolved" >&2
    exit 1
  }
  if [ -f "$AUTH_TXN/committed" ] && [ ! -L "$AUTH_TXN/committed" ] \
    && [ "$(cat "$AUTH_TXN/committed" 2>/dev/null)" = "manifest=$AUTH_MANIFEST_HMAC" ]; then
    [ "$(session_authority_file_signature "$LOCK")" = "$AUTH_NEW_LOCK" ] \
      && [ "$(session_authority_file_signature "$STATE/.primary-checkout")" = "$AUTH_NEW_BINDING" ] \
      && [ "$(session_authority_file_signature "$AUTHORITY")" = "$AUTH_NEW_AUTHORITY" ] || {
        echo "error: committed session authority transaction is not fully published; operate read-only until resolved" >&2
        exit 1
      }
    rm -rf -- "$AUTH_TXN"
  elif [ -e "$AUTH_TXN/committed" ] || [ -L "$AUTH_TXN/committed" ]; then
    echo "error: session authority transaction commit is invalid; operate read-only until resolved" >&2
    exit 1
  else
    restore_session_authority_from_transaction || {
      echo "error: session authority recovery could not be verified; operate read-only until resolved" >&2
      exit 1
    }
    rm -rf -- "$AUTH_TXN"
  fi
elif [ -e "$AUTH_TXN" ] || [ -L "$AUTH_TXN" ]; then
  echo "error: session authority transaction is ambiguous; operate read-only until resolved" >&2
  exit 1
fi

fm_worker_refuse_primary_operation "session lock acquisition" || exit 1
owner=$(fm_session_lock_owner) || {
  echo "error: cannot create keyed session authority" >&2
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
  if [ -f "$AUTHORITY" ] && [ ! -L "$AUTHORITY" ] \
    && fm_session_authority_read_shape "$AUTHORITY" \
    && [ "$FM_SESSION_AUTHORITY_OWNER" = "$old" ] \
    && { [ "$old_marker" = "$owner_marker" ] \
      || { [ -z "$old_marker" ] && [ -z "$owner_marker" ]; }; }; then
    if fm_session_authority_process_state "$AUTHORITY"; then
      owner=$old
    else
      authority_state=$?
      [ "$authority_state" -eq 1 ] || {
        echo "error: existing session authority lifecycle is ambiguous; operate read-only until resolved" >&2
        exit 1
      }
    fi
  elif [ ! -e "$AUTHORITY" ] && [ ! -L "$AUTHORITY" ] \
    && fm_session_legacy_owner_is_current "$old"; then
    owner=$old
  elif [ "$old" = "${owner%%|*}" ] && [ -n "$owner_marker" ]; then
    :
  elif [ "$old" != "$owner" ]; then
    holder_status=
    if [ -f "$AUTHORITY" ] && [ ! -L "$AUTHORITY" ] \
      && fm_session_authority_read_shape "$AUTHORITY" \
      && [ "$FM_SESSION_AUTHORITY_OWNER" = "$old" ]; then
      if fm_session_authority_process_state "$AUTHORITY"; then
        holder_status=0
      else
        holder_status=$?
        [ "$holder_status" -eq 1 ] || holder_status=2
      fi
    fi
    if [ -z "$holder_status" ]; then
      fm_session_lock_holder_state "$old"
      holder_status=$?
    fi
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
HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || exit 1
BINDING="$STATE/.primary-checkout"
_OLD_LOCK_PRESENT=0
_OLD_BINDING_PRESENT=0
_OLD_AUTHORITY_PRESENT=0
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  cat "$LOCK" >/dev/null || exit 1
  _OLD_LOCK_PRESENT=1
fi
if [ -e "$BINDING" ] || [ -L "$BINDING" ]; then
  if [ ! -f "$BINDING" ] || [ -L "$BINDING" ]; then
    echo "error: cannot bind the session lock to its primary checkout" >&2
    exit 1
  fi
  cat "$BINDING" >/dev/null || exit 1
  _OLD_BINDING_PRESENT=1
fi
if [ -e "$AUTHORITY" ] || [ -L "$AUTHORITY" ]; then
  if [ ! -f "$AUTHORITY" ] || [ -L "$AUTHORITY" ]; then
    echo "error: session authority record is ambiguous; operate read-only until resolved" >&2
    exit 1
  fi
  _OLD_AUTHORITY_PRESENT=1
fi
restore_session_authority() {
  restore_session_authority_from_transaction
}
BINDING_TMP=$(mktemp "$STATE/.primary-checkout.XXXXXX" 2>/dev/null) || exit 1
LOCK_TMP=$(mktemp "$STATE/.lock.XXXXXX" 2>/dev/null) || {
  rm -f "$BINDING_TMP"
  exit 1
}
AUTHORITY_TMP=$(mktemp "$STATE/.session-authority.XXXXXX" 2>/dev/null) || {
  rm -f "$BINDING_TMP" "$LOCK_TMP"
  exit 1
}
owner_pid=${owner%%|*}
case "$owner_pid" in ''|*[!0-9]*)
  rm -f "$BINDING_TMP" "$LOCK_TMP" "$AUTHORITY_TMP"
  exit 1
  ;;
esac
if ! printf '%s\n' "$ROOT_REAL" > "$BINDING_TMP" \
   || ! chmod 600 "$BINDING_TMP" \
   || ! printf '%s\n' "$owner" > "$LOCK_TMP" \
   || ! chmod 600 "$LOCK_TMP" \
   || ! fm_session_authority_write_file \
     "$AUTHORITY_TMP" "$owner_pid" "$owner" "$HOME_REAL" "$ROOT_REAL" \
   || ! chmod 600 "$AUTHORITY_TMP"; then
  rm -f "$BINDING_TMP" "$LOCK_TMP" "$AUTHORITY_TMP"
  echo "error: cannot bind the session lock to its primary checkout" >&2
  exit 1
fi
LIVE_TMP=
if [ -e "$STATE/.session-authority-live" ] \
  || [ -L "$STATE/.session-authority-live" ]; then
  [ -f "$STATE/.session-authority-live" ] \
    && [ ! -L "$STATE/.session-authority-live" ] || exit 1
  LIVE_TMP=$(mktemp "$STATE/.session-authority-live.XXXXXX") || exit 1
  cp -p "$STATE/.session-authority-live" "$LIVE_TMP" || {
    rm -f "$LIVE_TMP"
    exit 1
  }
fi
if ! fm_session_authority_transaction_stage \
    "$STATE" "$BINDING_TMP" "$LOCK_TMP" "$AUTHORITY_TMP" "$LIVE_TMP" \
  || ! fm_session_authority_transaction_commit "$STATE"; then
  fm_session_authority_transaction_recover "$STATE" || true
  rm -f "$BINDING_TMP" "$LOCK_TMP" "$AUTHORITY_TMP" "$LIVE_TMP"
  exit 1
fi
if ! written=$(cat "$LOCK" 2>/dev/null) \
  || [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$owner" ] \
  || ! fm_session_authority_read "$AUTHORITY" \
  || [ "$FM_SESSION_AUTHORITY_OWNER" != "$owner" ] \
  || [ "$FM_SESSION_AUTHORITY_HOME" != "$HOME_REAL" ] \
  || [ "$FM_SESSION_AUTHORITY_CHECKOUT" != "$ROOT_REAL" ]; then
  fm_session_authority_transaction_rollback "$STATE" || true
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
fm_session_authority_transaction_finalize "$STATE" || {
  fm_session_authority_transaction_rollback "$STATE" || true
  echo "error: session authority verification failed; operate read-only until resolved" >&2
  exit 1
}
release_claim_lock
fm_session_authority_admission_release || {
  echo "error: session authority admission could not be released" >&2
  exit 1
}
case "$owner" in
  *'|codex:'*) echo "lock acquired: Codex session owner $owner" ;;
  *) echo "lock acquired: harness pid $owner" ;;
esac
