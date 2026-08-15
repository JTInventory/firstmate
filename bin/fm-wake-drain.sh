#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "wake drain" || exit 1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DRAIN_DEDUPED=
DRAIN_RESTORE=
DRAIN_PID=${BASHPID:-$$}
DRAIN_LOCK_HELD=false
DRAIN_ACTIONABLE=0
DRAIN_CURRENT_RETAINED=0
DRAIN_BATCH_ROWS=${FM_WAKE_DRAIN_BATCH_ROWS:-16}
case "$DRAIN_BATCH_ROWS" in
  ''|*[!0-9]*|0) DRAIN_BATCH_ROWS=16 ;;
esac

inactive_generation_valid() {
  local generation=${FM_WAKE_DRAIN_GENERATION:-}
  case "${FM_WAKE_DRAIN_DEFER_ACK:-0}" in 0|1) ;; *) return 1 ;; esac
  case "$generation" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$generation" 2>/dev/null || return 1
  fm_pid_start "$generation" >/dev/null 2>&1
}

present_inactive_row() {
  local key=$1 row=$2 status=0 go emitted worker worker_status=0 generation
  local _epoch _seq _kind _queued_key payload
  generation=${FM_WAKE_DRAIN_GENERATION:-}
  if [ "${FM_WAKE_DRAIN_DIRECT:-0}" = 1 ]; then
    emitted=0
    if FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
      FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-emitted-state "$key" "$row" >/dev/null 2>&1; then
      emitted=1
    else
      worker_status=$?
      [ "$worker_status" = 1 ] || return 1
    fi
    if [ "$emitted" = 0 ]; then
      FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        output-started "$key" "$row" >/dev/null 2>&1 || return 1
      FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        output-emitted "$key" "$row" >/dev/null 2>&1 || return 1
      printf '%s\n' "$row" || return 1
    fi
    FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
      FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-confirmed "$key" "$row" >/dev/null 2>&1 || return 1
    if FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
      FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-complete "$key" "$row"; then
      FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        caller-output-complete-locked "$key" "$row" "$generation" >/dev/null 2>&1 || return 3
      FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        presented "$key" "$row" >/dev/null 2>&1 || return 3
      FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$generation" \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        ack "$key" "$row" 0 "$generation" >/dev/null 2>&1 || return 3
      return 0
    fi
    return 3
  fi
  if [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ]; then
    IFS=$(printf '\t') read -r _epoch _seq _kind _queued_key payload <<< "$row"
    [ "$_queued_key" = "$key" ] || return 3
    fm_wake_append_if_absent_locked retained check "$key" "$payload" || return 3
    DRAIN_CURRENT_RETAINED=1
  fi
  trap - INT TERM HUP
  go=$(mktemp "$STATE/.wake-presentation.XXXXXX") || return 1
  [ -f "$go" ] && [ ! -L "$go" ] || { rm -f "$go"; return 1; }
  rm -f "$go"
  emitted=$(mktemp "$STATE/.wake-emitted.XXXXXX") || { rm -f "$go"; return 1; }
  [ -f "$emitted" ] && [ ! -L "$emitted" ] || { rm -f "$go" "$emitted"; return 1; }
  rm -f "$emitted"
  (
    while [ ! -e "$go" ]; do
      if ! kill -0 "$DRAIN_PID" 2>/dev/null; then
        break
      fi
      sleep 0.01
    done
    FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" FM_WAKE_DRAIN_DELEGATED=1 \
      FM_WAKE_DRAIN_PARENT_PID="$DRAIN_PID" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-started "$key" "$row" || exit 1
    FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" FM_WAKE_DRAIN_DELEGATED=1 \
      FM_WAKE_DRAIN_PARENT_PID="$DRAIN_PID" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-emitted "$key" "$row" || exit 1
    printf '%s\n' "$row" || exit 1
    FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" FM_WAKE_DRAIN_DELEGATED=1 \
      FM_WAKE_DRAIN_PARENT_PID="$DRAIN_PID" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-confirmed "$key" "$row" || exit 1
    : > "$emitted" || exit 1
    FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" FM_WAKE_DRAIN_DELEGATED=1 \
      FM_WAKE_DRAIN_PARENT_PID="$DRAIN_PID" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      output-complete "$key" "$row" || exit 1
  ) &
  worker=$!
  : > "$go" || status=1
  if [ "$status" = 0 ]; then
    wait "$worker" || worker_status=$?
    [ "$worker_status" = 0 ] || status=1
  else
    kill "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
  fi
  rm -f "$go"
  if [ "$status" -ne 0 ]; then
    if [ -e "$emitted" ]; then
      if FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
          output-complete "$key" "$row" >/dev/null 2>&1; then
        status=0
      else
        status=3
      fi
    else
      :
    fi
  fi
  if [ "$status" = 0 ] && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" != 1 ]; then
    if [ -n "$generation" ]; then
      FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        caller-output-complete-locked "$key" "$row" "$generation" >/dev/null 2>&1 || status=3
    fi
  fi
  if [ "$status" = 0 ] && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" != 1 ]; then
    if ! FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" presented "$key" "$row"; then
      status=1
      if [ -e "$emitted" ] \
        && FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
          presented "$key" "$row" >/dev/null 2>&1; then
        status=0
      fi
    fi
  fi
  rm -f "$emitted"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  return "$status"
}

# Defense in depth for the watcher re-arm chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based banner (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

restore_unprocessed_rows() {
  local start=$1 restored
  restored=$(mktemp "$STATE/.wake-queue.unprocessed.XXXXXX") || return 1
  [ -f "$restored" ] && [ ! -L "$restored" ] || { rm -f "$restored"; return 1; }
  awk -v start="$start" 'NR >= start { print }' "$DRAIN_DEDUPED" > "$restored" || {
    rm -f "$restored"
    return 1
  }
  DRAIN_RESTORE=$restored
}

drain_batch_stop() {
  local start=$1
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
    DRAIN_LOCK_HELD=false
  fi
  restore_unprocessed_rows "$start" || return 1
  if [ -s "$DRAIN_RESTORE" ]; then
    fm_wake_restore_queue_atomic "$DRAIN_RESTORE" || return 1
  fi
  rm -f "$DRAIN_RESTORE" "$DRAIN_TMP" "$DRAIN_DEDUPED"
  DRAIN_RESTORE=
  DRAIN_TMP=
  DRAIN_DEDUPED=
  assert_watcher_liveness
  if [ "${FM_WAKE_DRAIN_DIRECT:-0}" = 1 ] && [ "$DRAIN_ACTIONABLE" = 1 ]; then
    return 3
  fi
  return 0
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$? restore_status=0
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ] \
    && [ "$DRAIN_LOCK_HELD" = false ] \
    && { [ -n "$DRAIN_TMP" ] || [ -n "$DRAIN_RESTORE" ]; }; then
    if fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; then
      DRAIN_LOCK_HELD=true
    else
      restore_status=1
    fi
  fi
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && [ "$DRAIN_LOCK_HELD" = true ]; then
    if [ -n "$DRAIN_RESTORE" ] && [ -e "$DRAIN_RESTORE" ]; then
      fm_wake_restore_queue "$DRAIN_RESTORE" || restore_status=1
    elif [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
      fm_wake_restore_queue "$DRAIN_TMP" || restore_status=1
    fi
  fi
  if [ "$restore_status" = 0 ]; then
    [ -z "$DRAIN_TMP" ] || rm -f "$DRAIN_TMP" || true
    [ -z "$DRAIN_RESTORE" ] || rm -f "$DRAIN_RESTORE" || true
  fi
  [ -z "$DRAIN_DEDUPED" ] || rm -f "$DRAIN_DEDUPED" || true
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || {
  echo "error: could not serialize the wake queue; refusing to drain" >&2
  exit 1
}
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$DRAIN_PID"
DRAIN_DEDUPED="$STATE/.wake-queue.deduped.$DRAIN_PID"
rm -f "$DRAIN_TMP"
rm -f "$DRAIN_DEDUPED"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

fm_lock_release "$FM_WAKE_QUEUE_LOCK" || exit 1
DRAIN_LOCK_HELD=false
if ! fm_wake_print_deduped "$DRAIN_TMP" > "$DRAIN_DEDUPED"; then
  exit 1
fi
fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
DRAIN_LOCK_HELD=true
# Inactive-outcome rows are acknowledged only after their matching durable
# receipt is presented. A one-time claim binds the receipt to this locked drain.
drain_line=0
while IFS= read -r drain_row || [ -n "$drain_row" ]; do
  drain_line=$((drain_line + 1))
  IFS=$(printf '\t') read -r _epoch _seq _kind _key _payload <<< "$drain_row"
  case "$_key" in
    inactive-outcome:*)
      if ! inactive_generation_valid; then
        restore_unprocessed_rows "$drain_line" || exit 1
        exit 2
      fi
      claim_status=0
      FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" claim "$_key" "$drain_row" || claim_status=$?
      case "$claim_status" in
        0)
          DRAIN_ACTIONABLE=1
          if ! FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK="${FM_WAKE_DRAIN_DEFER_ACK:-0}" \
            FM_WAKE_DRAIN_GENERATION="${FM_WAKE_DRAIN_GENERATION:-}" \
            FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" presenting "$_key" "$drain_row"; then
            restore_unprocessed_rows "$drain_line" || exit 1
            exit 1
          fi
          present_status=0
          DRAIN_CURRENT_RETAINED=0
          present_inactive_row "$_key" "$drain_row" || present_status=$?
          if [ "$present_status" -ne 0 ]; then
            restore_start=$drain_line
            [ "$DRAIN_CURRENT_RETAINED" = 1 ] && restore_start=$((drain_line + 1))
            restore_unprocessed_rows "$restore_start" || exit 1
            exit 1
          fi
          ;;
        1|5) ;;
        3) ;;
        4)
          restore_unprocessed_rows "$drain_line" || exit 1
          fm_wake_restore_queue "$DRAIN_RESTORE" || exit 1
          rm -f "$DRAIN_RESTORE"
          DRAIN_RESTORE=
          exit 0
          ;;
        6)
          restore_unprocessed_rows "$drain_line" || exit 1
          exit 1
          ;;
        *)
          restore_unprocessed_rows "$drain_line" || exit 1
          exit "$claim_status"
          ;;
      esac
      if [ "$claim_status" != 3 ] && [ "$claim_status" != 4 ] \
        && { [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" != 1 ] || [ "$claim_status" = 5 ]; }; then
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
          ack "$_key" "$drain_row" 0 "${FM_WAKE_DRAIN_GENERATION:-}" || {
          ack_status=$?
          # 1 means the receipt was already acknowledged or is not ours. Any
          # other failure keeps the drained row durable for a later turn.
          if [ "$ack_status" != 1 ]; then
            restore_unprocessed_rows "$drain_line" || exit 1
            exit "$ack_status"
          fi
        }
      fi
      ;;
    *)
      if ! printf '%s\n' "$drain_row"; then
        restore_unprocessed_rows "$drain_line" || exit 1
        exit 1
      fi
      if [ "$_kind" = signal ] && ! fm_wake_mark_surface_consumed "$_key"; then
        restore_unprocessed_rows "$drain_line" || exit 1
        exit 1
      fi
      DRAIN_ACTIONABLE=1
      ;;
  esac
  if [ "$drain_line" -ge "$DRAIN_BATCH_ROWS" ]; then
    drain_batch_stop "$((drain_line + 1))"
    batch_status=$?
    [ "$batch_status" = 0 ] || exit "$batch_status"
    exit 0
  fi
done < "$DRAIN_DEDUPED"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
rm -f "$DRAIN_DEDUPED"
DRAIN_DEDUPED=
assert_watcher_liveness
if [ "${FM_WAKE_DRAIN_DIRECT:-0}" = 1 ] && [ "$DRAIN_ACTIONABLE" = 1 ]; then
  exit 3
fi
exit 0
