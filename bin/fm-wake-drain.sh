#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
if [ "${FM_SESSION_LOCK_BOOTSTRAP:-0}" != 1 ]; then
  fm_worker_refuse_primary_operation "wake drain" || exit 1
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DRAIN_DEDUPED=
DRAIN_RESTORE=
DRAIN_LOCK_HELD=false

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

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ]; then
    if [ -n "$DRAIN_RESTORE" ] && [ -e "$DRAIN_RESTORE" ]; then
      fm_wake_restore_queue "$DRAIN_RESTORE" || true
    elif [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
      fm_wake_restore_queue "$DRAIN_TMP" || true
    fi
  fi
  [ -z "$DRAIN_TMP" ] || rm -f "$DRAIN_TMP" || true
  [ -z "$DRAIN_RESTORE" ] || rm -f "$DRAIN_RESTORE" || true
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

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
DRAIN_DEDUPED="$STATE/.wake-queue.deduped.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
rm -f "$DRAIN_DEDUPED"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

fm_wake_print_deduped "$DRAIN_TMP" > "$DRAIN_DEDUPED" || exit "$?"
cat "$DRAIN_DEDUPED"
# Inactive-outcome rows are acknowledged only after their matching durable
# receipt is presented. The locked session-start/watcher context authorizes the
# helper; a failed correlation leaves the original drained rows restorable.
drain_line=0
while IFS= read -r drain_row || [ -n "$drain_row" ]; do
  drain_line=$((drain_line + 1))
  IFS=$(printf '\t') read -r _epoch _seq _kind _key _payload <<< "$drain_row"
  case "$_key" in
    inactive-outcome:*)
      "$SCRIPT_DIR/fm-inactive-reconcile.sh" ack "$_key" || {
        ack_status=$?
        # 1 means the receipt was already acknowledged or is not ours. Any
        # other failure keeps the drained row durable for a later turn.
        if [ "$ack_status" != 1 ]; then
          DRAIN_RESTORE="$STATE/.wake-queue.unprocessed.$(fm_current_pid)"
          awk -v start="$drain_line" 'NR >= start { print }' "$DRAIN_DEDUPED" > "$DRAIN_RESTORE" || exit 1
          exit "$ack_status"
        fi
      }
      ;;
  esac
done < "$DRAIN_DEDUPED"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
rm -f "$DRAIN_DEDUPED"
DRAIN_DEDUPED=
assert_watcher_liveness
exit 0
