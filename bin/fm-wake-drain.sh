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

present_inactive_row() {
  local key=$1 row=$2 status=0 go worker worker_status=0
  trap - INT TERM HUP
  go=$(mktemp "$STATE/.wake-presentation.XXXXXX") || return 1
  [ -f "$go" ] && [ ! -L "$go" ] || { rm -f "$go"; return 1; }
  rm -f "$go"
  (
    while [ ! -e "$go" ]; do
      if ! kill -0 "$DRAIN_PID" 2>/dev/null; then
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" FM_WAKE_DRAIN_DELEGATED=1 \
          FM_WAKE_DRAIN_PARENT_PID="$DRAIN_PID" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
          output-started "$key" "$row" || exit 1
        break
      fi
      sleep 0.01
    done
    printf '%s\n' "$row"
  ) &
  worker=$!
  if ! FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" output-started "$key" "$row"; then
    status=1
  fi
  if [ "$status" = 0 ]; then
    : > "$go" || status=1
  fi
  if [ "$status" = 0 ]; then
    wait "$worker" || worker_status=$?
    [ "$worker_status" = 0 ] || status=1
  else
    kill "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
  fi
  rm -f "$go"
  if [ "$status" -ne 0 ]; then
    FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
      presenting "$key" "$row" >/dev/null 2>&1 || true
  fi
  if [ "$status" = 0 ] && ! FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" presented "$key" "$row"; then
    status=1
  fi
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

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$? restore_status=0
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ]; then
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

fm_wake_print_deduped "$DRAIN_TMP" > "$DRAIN_DEDUPED" || exit "$?"
# Inactive-outcome rows are acknowledged only after their matching durable
# receipt is presented. A one-time claim binds the receipt to this locked drain.
drain_line=0
while IFS= read -r drain_row || [ -n "$drain_row" ]; do
  drain_line=$((drain_line + 1))
  IFS=$(printf '\t') read -r _epoch _seq _kind _key _payload <<< "$drain_row"
  case "$_key" in
    inactive-outcome:*)
      claim_status=0
      FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" claim "$_key" "$drain_row" || claim_status=$?
      case "$claim_status" in
        0)
          if ! FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" presenting "$_key" "$drain_row"; then
            restore_unprocessed_rows "$drain_line" || exit 1
            exit 1
          fi
          if ! present_inactive_row "$_key" "$drain_row"; then
            restore_unprocessed_rows "$drain_line" || exit 1
            exit 1
          fi
          ;;
        1|3) ;;
        *)
          restore_unprocessed_rows "$drain_line" || exit 1
          exit "$claim_status"
          ;;
      esac
      if [ "$claim_status" != 3 ] && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" != 1 ]; then
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" ack "$_key" "$drain_row" || {
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
      ;;
  esac
done < "$DRAIN_DEDUPED"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
rm -f "$DRAIN_DEDUPED"
DRAIN_DEDUPED=
assert_watcher_liveness
exit 0
