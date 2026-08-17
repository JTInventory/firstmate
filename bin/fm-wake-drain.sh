#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "wake drain" || exit 1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pane-idle-lib.sh
. "$SCRIPT_DIR/fm-pane-idle-lib.sh"

DRAIN_TMP=
DRAIN_DEDUPED=
DRAIN_RESTORE=
DRAIN_PID=${BASHPID:-$$}
DRAIN_PID_START=
DRAIN_LOCK_HELD=false
DRAIN_ACTIONABLE=0
DRAIN_RESUMING=false
DRAIN_OFFSET=0
DRAIN_BATCH_COUNT=0
DRAIN_CURSOR=
DRAIN_CURRENT_RETAINED=0
DRAIN_CURRENT_OFFSET=0
DRAIN_NEXT_OFFSET=0
DRAIN_RETAINED_ANY=0
DRAIN_RETAINED_OFFSET=0
DRAIN_BATCH_ROWS=${FM_WAKE_DRAIN_BATCH_ROWS:-16}
DRAIN_RESTORE_MANIFEST="$STATE/.wake-queue.restore"
DRAIN_RESTORE_PENDING=false
DRAIN_RESTORE_OFFSET=0
DRAIN_RESTORE_SOURCE=
DRAIN_RESTORE_SOURCE_RETIRED=0
DRAIN_RESTORE_RAW_SOURCE=
DRAIN_RESTORE_RAW_SOURCE_RETIRED=1
DRAIN_DEDUPED_READY=0
DRAIN_FINALIZED_KEYS=()
FM_WAKE_DRAIN_RESUMED_SOURCE=0
export FM_WAKE_DRAIN_RESUMED_SOURCE
DRAIN_PID_START=$(fm_pid_start "$DRAIN_PID" 2>/dev/null || true)
export FM_WAKE_DRAIN_PARENT_START="$DRAIN_PID_START"
case "$DRAIN_BATCH_ROWS" in
  ''|*[!0-9]*|0) DRAIN_BATCH_ROWS=16 ;;
esac
PRESENTATION_TIMEOUT_SECS=${FM_WAKE_DRAIN_PRESENTATION_TIMEOUT_SECS:-30}
case "$PRESENTATION_TIMEOUT_SECS" in
  ''|*[!0-9]*|0) PRESENTATION_TIMEOUT_SECS=30 ;;
esac
while [ "${PRESENTATION_TIMEOUT_SECS#0}" != "$PRESENTATION_TIMEOUT_SECS" ]; do
  PRESENTATION_TIMEOUT_SECS=${PRESENTATION_TIMEOUT_SECS#0}
done
[ -n "$PRESENTATION_TIMEOUT_SECS" ] || PRESENTATION_TIMEOUT_SECS=30
case "${#PRESENTATION_TIMEOUT_SECS}" in
  1|2) ;;
  3) [ "$PRESENTATION_TIMEOUT_SECS" -le 300 ] || PRESENTATION_TIMEOUT_SECS=300 ;;
  *) PRESENTATION_TIMEOUT_SECS=300 ;;
esac

presentation_reconcile() {
  local timeout=$1
  shift
  fm_pane_idle_run_bounded_child "$timeout" env "$@"
}

presentation_parent_alive() {
  local pid=$1 start=${2:-}
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$start" ] || return 1
  fm_pid_start_matches_stored "$pid" "$start"
}

wake_marker_write() {
  local path=$1 value=$2
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use Fcntl qw(:DEFAULT);
    my ($path, $value) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    my $fh;
    sysopen($fh, $path, O_WRONLY | O_TRUNC | $nofollow) or exit 1;
    binmode($fh);
    print($fh $value) or exit 1;
    close($fh) or exit 1;
  ' "$path" "$value"
}

present_inactive_worker() {
  local key=$1 row=$2 deduped=$3 parent_pid=$4 parent_start=$5 go=$6 emitted=$7 script_dir=$8 timeout=$9
  while [ ! -s "$go" ]; do
    presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
    sleep 0.01
  done
  presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
  presentation_reconcile "$timeout" FM_WAKE_DRAIN_FILE="$deduped" FM_WAKE_DRAIN_DELEGATED=1 \
    FM_WAKE_DRAIN_PARENT_PID="$parent_pid" FM_WAKE_DRAIN_PARENT_START="$parent_start" \
    "$script_dir/fm-inactive-reconcile.sh" \
    output-started "$key" "$row" || exit 1
  presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
  presentation_reconcile "$timeout" FM_WAKE_DRAIN_FILE="$deduped" FM_WAKE_DRAIN_DELEGATED=1 \
    FM_WAKE_DRAIN_PARENT_PID="$parent_pid" FM_WAKE_DRAIN_PARENT_START="$parent_start" \
    "$script_dir/fm-inactive-reconcile.sh" \
    output-emitted "$key" "$row" || exit 1
  presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
  printf '%s\n' "$row" || exit 1
  presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
  presentation_reconcile "$timeout" FM_WAKE_DRAIN_FILE="$deduped" FM_WAKE_DRAIN_DELEGATED=1 \
    FM_WAKE_DRAIN_PARENT_PID="$parent_pid" FM_WAKE_DRAIN_PARENT_START="$parent_start" \
    "$script_dir/fm-inactive-reconcile.sh" \
    output-confirmed "$key" "$row" || exit 1
  presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
  wake_marker_write "$emitted" emitted || exit 1
  presentation_parent_alive "$parent_pid" "$parent_start" || exit 125
  presentation_reconcile "$timeout" FM_WAKE_DRAIN_FILE="$deduped" FM_WAKE_DRAIN_DELEGATED=1 \
    FM_WAKE_DRAIN_PARENT_PID="$parent_pid" FM_WAKE_DRAIN_PARENT_START="$parent_start" \
    "$script_dir/fm-inactive-reconcile.sh" \
    output-complete "$key" "$row" || exit 1
}

presentation_worker_stop() {
  local worker=$1 pgid=$2 attempts=0
  case "$pgid" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -TERM -- "-$pgid" 2>/dev/null || true
  while kill -0 -- "-$pgid" 2>/dev/null && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 -- "-$pgid" 2>/dev/null; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
    attempts=0
    while kill -0 -- "-$pgid" 2>/dev/null && [ "$attempts" -lt 200 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
  fi
  wait "$worker" 2>/dev/null || true
  ! kill -0 -- "-$pgid" 2>/dev/null
}

inactive_generation_valid() {
  local generation=${FM_WAKE_DRAIN_GENERATION:-}
  case "${FM_WAKE_DRAIN_DEFER_ACK:-0}" in 0|1) ;; *) return 1 ;; esac
  case "$generation" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$generation" 2>/dev/null || return 1
  fm_pid_start "$generation" >/dev/null 2>&1
}

present_inactive_row() {
  local key=$1 row=$2 status=0 go emitted worker worker_status=0 generation
  local defer_pending=0 defer_payload=
  local worker_timed_out=0 worker_stopped=1 worker_pgid presentation_deadline
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
    defer_pending=1
    defer_payload=$payload
    if [ "$DRAIN_RESUMING" = true ]; then
      if [ "$DRAIN_RETAINED_ANY" = 0 ]; then
        DRAIN_RETAINED_OFFSET=$DRAIN_CURRENT_OFFSET
        DRAIN_RETAINED_ANY=1
      fi
    fi
  fi
  trap - INT TERM HUP
  go=$(mktemp "$STATE/.wake-presentation.XXXXXX") || return 1
  [ -f "$go" ] && [ ! -L "$go" ] || { rm -f "$go"; return 1; }
  emitted=$(mktemp "$STATE/.wake-emitted.XXXXXX") || { rm -f "$go"; return 1; }
  [ -f "$emitted" ] && [ ! -L "$emitted" ] || { rm -f "$go" "$emitted"; return 1; }
  export -f fm_pane_idle_run_bounded_child presentation_reconcile presentation_parent_alive wake_marker_write \
    present_inactive_worker fm_pid_start_ps_token fm_pid_start fm_pid_start_matches_stored
  if command -v perl >/dev/null 2>&1; then
    perl -e 'use POSIX (); POSIX::setpgid(0, 0) == 0 or exit 125; exec @ARGV or exit 127' \
      "$BASH" -c 'present_inactive_worker "$@"' present-inactive-worker \
      "$key" "$row" "$DRAIN_DEDUPED" "$DRAIN_PID" "$DRAIN_PID_START" "$go" "$emitted" "$SCRIPT_DIR" \
      "$PRESENTATION_TIMEOUT_SECS" &
    worker=$!
  else
    rm -f "$go" "$emitted"
    return 1
  fi
  worker_pgid=$worker
  wake_marker_write "$go" go || {
    status=1
    worker_stopped=0
    presentation_worker_stop "$worker" "$worker_pgid" && worker_stopped=1
  }
  if [ "$status" = 0 ]; then
    presentation_deadline=$(( $(date +%s) + PRESENTATION_TIMEOUT_SECS ))
    while kill -0 "$worker" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$presentation_deadline" ] && kill -0 "$worker" 2>/dev/null; then
        worker_timed_out=1
        worker_status=124
        worker_stopped=0
        presentation_worker_stop "$worker" "$worker_pgid" && worker_stopped=1
        break
      fi
      sleep 0.01
    done
    if [ "$worker_timed_out" = 0 ]; then
      wait "$worker" || worker_status=$?
      worker_stopped=0
      presentation_worker_stop "$worker" "$worker_pgid" && worker_stopped=1
    fi
    [ "$worker_status" = 0 ] || status=1
  fi
  [ "$worker_stopped" = 1 ] || return 1
  rm -f "$go"
  if [ "$status" -ne 0 ]; then
    if [ -s "$emitted" ]; then
      if FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
          presentation_reconcile "$PRESENTATION_TIMEOUT_SECS" FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" \
          "$SCRIPT_DIR/fm-inactive-reconcile.sh" output-complete "$key" "$row" \
          >/dev/null 2>&1; then
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
      FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        caller-output-complete-locked "$key" "$row" "$generation" >/dev/null 2>&1 || status=3
    fi
  fi
  if [ "$status" = 0 ] && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" != 1 ]; then
    if ! FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" presented "$key" "$row"; then
      status=1
      if [ -s "$emitted" ] \
        && FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
          FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
          presented "$key" "$row" >/dev/null 2>&1; then
        status=0
      fi
    fi
  fi
  if [ "$status" = 0 ] && [ "$defer_pending" = 1 ]; then
    if [ "$DRAIN_RESUMING" = true ]; then
      DRAIN_CURRENT_RETAINED=1
    else
      if fm_wake_append_if_absent_locked retained check "$key" "$defer_payload"; then
        DRAIN_CURRENT_RETAINED=1
      else
        status=1
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
  local _start=${1:-0} offset
  case "$_start" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$DRAIN_CURRENT_RETAINED" = 1 ]; then
    offset=$DRAIN_NEXT_OFFSET
  else
    offset=$DRAIN_CURRENT_OFFSET
  fi
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  DRAIN_RESTORE_OFFSET=$offset
  DRAIN_RESTORE_SOURCE=$DRAIN_DEDUPED
  restore_pending_write "$DRAIN_DEDUPED" "$offset" "$DRAIN_TMP" || {
    DRAIN_RESTORE_SOURCE=
    return 1
  }
  DRAIN_RESTORE_PENDING=true
  restore_pending_retire_raw_source || return 1
  rm -f "$DRAIN_TMP" || return 1
  DRAIN_TMP=
}

restore_source_path_valid() {
  local source=$1 base
  base=${source##*/}
  [ "$source" = "$STATE/$base" ] || return 1
  case "$base" in
    .wake-queue.deduped.*|.wake-queue.drain.*) ;;
    *) return 1 ;;
  esac
  case "${base##*.}" in ''|*[!0-9]*) return 1 ;; esac
}

restore_pending_manifest_write() {
  local source=$1 offset=$2 source_retired=$3 raw_source=${4:-} raw_source_retired=${5:-1}
  local source_base raw_base tmp
  source_base=${source##*/}
  restore_source_path_valid "$source" || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  case "$source_retired" in 0|1) ;; *) return 1 ;; esac
  if [ -n "$raw_source" ]; then
    raw_base=${raw_source##*/}
    restore_source_path_valid "$raw_source" || return 1
    [ "$raw_source" != "$source" ] || return 1
    case "$raw_source_retired" in 0|1) ;; *) return 1 ;; esac
  else
    raw_base=
    raw_source_retired=1
  fi
  [ ! -L "$DRAIN_RESTORE_MANIFEST" ] || return 1
  tmp=$(mktemp "$DRAIN_RESTORE_MANIFEST.XXXXXX") || return 1
  if ! printf 'schema=fm-wake-queue-restore.v1\nsource=%s\noffset=%s\nsource_retired=%s\nraw_source=%s\nraw_source_retired=%s\n' \
    "$source_base" "$offset" "$source_retired" "$raw_base" "$raw_source_retired" | fm_nofollow_write "$tmp" \
    || [ -L "$DRAIN_RESTORE_MANIFEST" ] || ! mv -f "$tmp" "$DRAIN_RESTORE_MANIFEST"; then
    rm -f "$tmp"
    return 1
  fi
}

restore_pending_write() {
  local source=$1 offset=$2 raw_source=${3:-} raw_source_retired=1
  [ -z "$raw_source" ] || raw_source_retired=0
  restore_pending_manifest_write "$source" "$offset" 0 "$raw_source" "$raw_source_retired" || return 1
  DRAIN_RESTORE_SOURCE=$source
  DRAIN_RESTORE_OFFSET=$offset
  DRAIN_RESTORE_SOURCE_RETIRED=0
  DRAIN_RESTORE_RAW_SOURCE=${raw_source:+$STATE/${raw_source##*/}}
  DRAIN_RESTORE_RAW_SOURCE_RETIRED=$raw_source_retired
}

restore_pending_read() {
  local schema source offset source_retired raw_source raw_source_retired base raw_base
  [ -f "$DRAIN_RESTORE_MANIFEST" ] && [ ! -L "$DRAIN_RESTORE_MANIFEST" ] || return 1
  schema=$(awk -F= '$1 == "schema" { print $2; n++ } END { exit(n == 1 ? 0 : 1) }' \
    "$DRAIN_RESTORE_MANIFEST" 2>/dev/null) || return 1
  [ "$schema" = fm-wake-queue-restore.v1 ] || return 1
  source=$(awk -F= '$1 == "source" { print $2; n++ } END { exit(n == 1 ? 0 : 1) }' \
    "$DRAIN_RESTORE_MANIFEST" 2>/dev/null) || return 1
  offset=$(awk -F= '$1 == "offset" { print $2; n++ } END { exit(n == 1 ? 0 : 1) }' \
    "$DRAIN_RESTORE_MANIFEST" 2>/dev/null) || return 1
  if ! source_retired=$(awk -F= '$1 == "source_retired" { print $2; n++ } END { exit(n == 0 || n == 1 ? 0 : 1) }' \
    "$DRAIN_RESTORE_MANIFEST" 2>/dev/null); then
    return 1
  fi
  case "$source_retired" in ''|0) source_retired=0 ;; 1) ;; *) return 1 ;; esac
  if ! raw_source=$(awk -F= '$1 == "raw_source" { print $2; n++ } END { exit(n == 0 || n == 1 ? 0 : 1) }' \
    "$DRAIN_RESTORE_MANIFEST" 2>/dev/null); then
    return 1
  fi
  if ! raw_source_retired=$(awk -F= '$1 == "raw_source_retired" { print $2; n++ } END { if (n == 0) print 1; exit(n == 0 || n == 1 ? 0 : 1) }' \
    "$DRAIN_RESTORE_MANIFEST" 2>/dev/null); then
    return 1
  fi
  case "$raw_source_retired" in 0|1) ;; *) return 1 ;; esac
  restore_source_path_valid "$STATE/$source" || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  base="$STATE/$source"
  if [ "$source_retired" = 1 ]; then
    if [ -e "$base" ] || [ -L "$base" ]; then
      [ -f "$base" ] && [ ! -L "$base" ] || return 1
      fm_wake_queue_offset_valid "$base" "$offset" || return 1
    fi
  else
    [ -f "$base" ] && [ ! -L "$base" ] || return 1
    fm_wake_queue_offset_valid "$base" "$offset" || return 1
  fi
  if [ -n "$raw_source" ]; then
    raw_base=${raw_source##*/}
    restore_source_path_valid "$STATE/$raw_source" || return 1
    [ "$raw_source" != "$source" ] || return 1
    raw_base="$STATE/$raw_source"
    if [ "$raw_source_retired" = 1 ]; then
      if [ -e "$raw_base" ] || [ -L "$raw_base" ]; then
        [ -f "$raw_base" ] && [ ! -L "$raw_base" ] || return 1
        fm_wake_queue_offset_valid "$raw_base" "$offset" || return 1
      fi
    else
      [ -f "$raw_base" ] && [ ! -L "$raw_base" ] || return 1
      fm_wake_queue_offset_valid "$raw_base" "$offset" || return 1
    fi
  else
    [ "$raw_source_retired" = 1 ] || return 1
  fi
  DRAIN_RESTORE_SOURCE=$base
  DRAIN_RESTORE_OFFSET=$offset
  DRAIN_RESTORE_SOURCE_RETIRED=$source_retired
  DRAIN_RESTORE_RAW_SOURCE=${raw_source:+$STATE/$raw_source}
  DRAIN_RESTORE_RAW_SOURCE_RETIRED=$raw_source_retired
}

restore_pending_mark_source_retired() {
  local source=$1 offset=$2
  restore_pending_manifest_write "$source" "$offset" 1 \
    "$DRAIN_RESTORE_RAW_SOURCE" "$DRAIN_RESTORE_RAW_SOURCE_RETIRED" || return 1
  DRAIN_RESTORE_SOURCE_RETIRED=1
}

restore_pending_mark_raw_source_retired() {
  [ -n "$DRAIN_RESTORE_RAW_SOURCE" ] || return 0
  restore_pending_manifest_write "$DRAIN_RESTORE_SOURCE" "$DRAIN_RESTORE_OFFSET" \
    "$DRAIN_RESTORE_SOURCE_RETIRED" "$DRAIN_RESTORE_RAW_SOURCE" 1 || return 1
  DRAIN_RESTORE_RAW_SOURCE_RETIRED=1
}

restore_pending_retire_raw_source() {
  [ -n "$DRAIN_RESTORE_RAW_SOURCE" ] || return 0
  if [ "$DRAIN_RESTORE_RAW_SOURCE_RETIRED" != 1 ]; then
    restore_pending_mark_raw_source_retired || return 1
  fi
  rm -f "$DRAIN_RESTORE_RAW_SOURCE"
}

restore_queue_fallback() {
  local source=$1
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
    DRAIN_LOCK_HELD=false
  fi
  fm_wake_restore_queue_atomic "$source"
}

drain_recover_orphaned_sources_locked() {
  local orphan base tmp
  [ ! -L "$FM_WAKE_QUEUE" ] || return 1
  [ ! -e "$DRAIN_RESTORE_MANIFEST" ] && [ ! -L "$DRAIN_RESTORE_MANIFEST" ] || return 0
  for orphan in "$STATE"/.wake-queue.drain.*; do
    [ -e "$orphan" ] || continue
    [ -f "$orphan" ] && [ ! -L "$orphan" ] || return 1
    base=${orphan##*/}
    case "$base" in .wake-queue.drain.*) ;; *) return 1 ;; esac
    case "${base##*.}" in ''|*[!0-9]*) return 1 ;; esac
    if [ -e "$FM_WAKE_QUEUE" ]; then
      [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 1
      tmp=$(mktemp "$STATE/.wake-queue.recover.XXXXXX") || return 1
      if ! cat "$orphan" "$FM_WAKE_QUEUE" | fm_nofollow_write "$tmp" \
        || [ -L "$FM_WAKE_QUEUE" ] || ! mv -f "$tmp" "$FM_WAKE_QUEUE"; then
        rm -f "$tmp"
        return 1
      fi
      rm -f "$orphan" || return 1
    else
      mv -f "$orphan" "$FM_WAKE_QUEUE" || return 1
    fi
  done
}

drain_restore_remaining() {
  [ "$DRAIN_RESUMING" = true ] && return 0
  restore_unprocessed_rows "$1"
}

drain_resume_advance() {
  local removed=${1:-0}
  [ "$DRAIN_RESUMING" = true ] && [ "$DRAIN_RESTORE_PENDING" != true ] || return 0
  [ "$DRAIN_CURRENT_RETAINED" = 1 ] && return 0
  [ "$DRAIN_RETAINED_ANY" = 1 ] && return 0
  if [ "$removed" = 0 ]; then
    fm_wake_queue_cursor_write "$DRAIN_NEXT_OFFSET" || return 1
  fi
  fm_wake_queue_cursor_read || return 1
  DRAIN_OFFSET=$FM_WAKE_QUEUE_CURSOR_OFFSET
}

drain_batch_stop() {
  local next_offset
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    if [ "$DRAIN_RESTORE_PENDING" = true ]; then
      if [ "$DRAIN_RETAINED_ANY" = 1 ]; then
        next_offset=$DRAIN_RETAINED_OFFSET
      else
        next_offset=$(fm_wake_queue_offset_after_rows "$DRAIN_DEDUPED" \
          "$DRAIN_OFFSET" "$DRAIN_BATCH_COUNT") || return 1
      fi
      restore_pending_write "$DRAIN_DEDUPED" "$next_offset" || return 1
      DRAIN_OFFSET=$next_offset
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
      DRAIN_LOCK_HELD=false
    elif [ "$DRAIN_RESUMING" = true ]; then
      if [ "$DRAIN_RETAINED_ANY" = 1 ]; then
        next_offset=$DRAIN_RETAINED_OFFSET
        fm_wake_queue_cursor_write "$next_offset" || return 1
        DRAIN_OFFSET=$next_offset
      else
        fm_wake_queue_cursor_read || return 1
        DRAIN_OFFSET=$FM_WAKE_QUEUE_CURSOR_OFFSET
      fi
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
      DRAIN_LOCK_HELD=false
    else
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
      DRAIN_LOCK_HELD=false
      next_offset=$(fm_wake_queue_offset_after_rows "$DRAIN_DEDUPED" 0 \
        "$DRAIN_BATCH_COUNT") || return 1
      fm_wake_install_queue_cursor_atomic "$DRAIN_DEDUPED" "$next_offset" || return 1
      if [ "${#DRAIN_FINALIZED_KEYS[@]}" -gt 0 ]; then
        fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
        DRAIN_LOCK_HELD=true
        finalized_status=0
        for finalized_key in "${DRAIN_FINALIZED_KEYS[@]}"; do
          fm_wake_remove_key_locked "$finalized_key" || { finalized_status=1; break; }
        done
        if [ "$finalized_status" -ne 0 ]; then
          fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
          DRAIN_LOCK_HELD=false
          return 1
        fi
        fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
        DRAIN_LOCK_HELD=false
        DRAIN_FINALIZED_KEYS=()
      fi
      rm -f "$DRAIN_RESTORE" "$DRAIN_TMP" "$DRAIN_DEDUPED"
      DRAIN_RESTORE=
      DRAIN_TMP=
      DRAIN_DEDUPED=
      DRAIN_CURSOR=$(fm_wake_queue_cursor_path)
    fi
  fi
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
    && { [ -n "$DRAIN_TMP" ] || [ -n "$DRAIN_RESTORE" ] || [ -n "$DRAIN_DEDUPED" ]; }; then
    if fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; then
      DRAIN_LOCK_HELD=true
    else
      restore_status=1
    fi
  fi
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && [ "$DRAIN_LOCK_HELD" = true ]; then
    if [ "$DRAIN_RESTORE_PENDING" = true ]; then
      :
    elif [ "$DRAIN_DEDUPED_READY" = 1 ] && [ -n "$DRAIN_DEDUPED" ] \
      && [ -e "$DRAIN_DEDUPED" ]; then
      if restore_pending_write "$DRAIN_DEDUPED" "$DRAIN_CURRENT_OFFSET" "$DRAIN_TMP"; then
        DRAIN_RESTORE_PENDING=true
        if restore_pending_retire_raw_source && rm -f "$DRAIN_TMP"; then
          DRAIN_TMP=
        else
          restore_status=1
        fi
      else
        if [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ] \
          && restore_queue_fallback "$DRAIN_TMP"; then
          rm -f "$DRAIN_TMP" || restore_status=1
          [ "$restore_status" = 0 ] && DRAIN_TMP=
        else
          restore_status=1
        fi
      fi
    elif [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
      if restore_pending_write "$DRAIN_TMP" 0; then
        DRAIN_RESTORE_PENDING=true
      else
        if restore_queue_fallback "$DRAIN_TMP"; then
          rm -f "$DRAIN_TMP" || restore_status=1
          [ "$restore_status" = 0 ] && DRAIN_TMP=
        else
          restore_status=1
        fi
      fi
    fi
  fi
  if [ "$restore_status" = 0 ]; then
    if [ "$DRAIN_RESTORE_PENDING" != true ]; then
      [ -z "$DRAIN_TMP" ] || rm -f "$DRAIN_TMP" || true
      [ -z "$DRAIN_RESTORE" ] || rm -f "$DRAIN_RESTORE" || true
    fi
  fi
  if [ "$restore_status" = 0 ] && [ "$DRAIN_RESTORE_PENDING" != true ] && [ -n "$DRAIN_DEDUPED" ] \
    && [ "$DRAIN_DEDUPED" != "$FM_WAKE_QUEUE" ]; then
    rm -f "$DRAIN_DEDUPED" || true
  fi
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
fm_wake_queue_txn_recover_transactions_locked || {
  echo "error: wake queue transaction recovery failed; refusing to drain" >&2
  exit 1
}
drain_recover_orphaned_sources_locked || {
  echo "error: orphaned wake drain source recovery failed; refusing to drain" >&2
  exit 1
}

DRAIN_CURSOR=$(fm_wake_queue_cursor_path)
if [ -e "$DRAIN_RESTORE_MANIFEST" ] || [ -L "$DRAIN_RESTORE_MANIFEST" ]; then
  restore_pending_read || {
    echo "error: wake restoration manifest is invalid; refusing to drain" >&2
    exit 1
  }
  DRAIN_RESTORE_PENDING=true
  DRAIN_RESUMING=true
  FM_WAKE_DRAIN_RESUMED_SOURCE=1
  DRAIN_DEDUPED=$DRAIN_RESTORE_SOURCE
  DRAIN_OFFSET=$DRAIN_RESTORE_OFFSET
  restore_pending_retire_raw_source || {
    echo "error: wake restoration raw source retirement failed; refusing to drain" >&2
    exit 1
  }
  if [ "$DRAIN_RESTORE_SOURCE_RETIRED" = 1 ]; then
    rm -f "$DRAIN_RESTORE_SOURCE" || exit 1
    rm -f "$DRAIN_RESTORE_MANIFEST" || exit 1
    DRAIN_RESTORE_SOURCE=
    DRAIN_RESTORE_SOURCE_RETIRED=0
    DRAIN_RESTORE_RAW_SOURCE=
    DRAIN_RESTORE_RAW_SOURCE_RETIRED=1
    DRAIN_RESTORE_PENDING=false
    DRAIN_RESUMING=false
    DRAIN_DEDUPED=
  fi
elif [ -e "$DRAIN_CURSOR" ] || [ -L "$DRAIN_CURSOR" ]; then
  fm_wake_queue_cursor_read || {
    echo "error: wake queue cursor is invalid; refusing to drain" >&2
    exit 1
  }
  DRAIN_RESUMING=true
  FM_WAKE_DRAIN_RESUMED_SOURCE=1
  DRAIN_OFFSET=$FM_WAKE_QUEUE_CURSOR_OFFSET
  DRAIN_DEDUPED=$FM_WAKE_QUEUE
fi

if [ "$DRAIN_RESTORE_PENDING" != true ] && [ ! -s "$FM_WAKE_QUEUE" ]; then
  rm -f "$DRAIN_CURSOR"
  : | fm_nofollow_write "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

if [ "$DRAIN_RESUMING" != true ]; then
  DRAIN_TMP="$STATE/.wake-queue.drain.$DRAIN_PID"
  DRAIN_DEDUPED="$STATE/.wake-queue.deduped.$DRAIN_PID"
  rm -f "$DRAIN_TMP"
  rm -f "$DRAIN_DEDUPED"
  mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
  : | fm_nofollow_write "$FM_WAKE_QUEUE" || exit 1

  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || exit 1
  DRAIN_LOCK_HELD=false
  if ! fm_wake_print_deduped "$DRAIN_TMP" | fm_nofollow_write "$DRAIN_DEDUPED"; then
    exit 1
  fi
  DRAIN_DEDUPED_READY=1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
  DRAIN_LOCK_HELD=true
fi
# Inactive-outcome rows are acknowledged only after their matching durable
# receipt is presented. A one-time claim binds the receipt to this locked drain.
drain_line=0
DRAIN_BATCH_COUNT=0
if [ "$DRAIN_RESUMING" = true ]; then
  exec 7< <(fm_wake_queue_stream_from_offset "$DRAIN_DEDUPED" "$DRAIN_OFFSET")
else
  exec 7< "$DRAIN_DEDUPED"
fi
while IFS= read -r drain_row || [ -n "$drain_row" ]; do
  drain_line=$((drain_line + 1))
  DRAIN_BATCH_COUNT=$((DRAIN_BATCH_COUNT + 1))
  if [ "$DRAIN_RESUMING" = true ] && [ "$DRAIN_RESTORE_PENDING" != true ]; then
    fm_wake_queue_cursor_read || exit 1
    DRAIN_OFFSET=$FM_WAKE_QUEUE_CURSOR_OFFSET
    DRAIN_CURRENT_OFFSET=$DRAIN_OFFSET
    DRAIN_NEXT_OFFSET=$(fm_wake_queue_offset_after_rows "$DRAIN_DEDUPED" \
      "$DRAIN_CURRENT_OFFSET" 1) || exit 1
  else
    DRAIN_CURRENT_OFFSET=$(fm_wake_queue_offset_after_rows "$DRAIN_DEDUPED" \
      "$DRAIN_OFFSET" "$((DRAIN_BATCH_COUNT - 1))") || exit 1
    DRAIN_NEXT_OFFSET=$(fm_wake_queue_offset_after_rows "$DRAIN_DEDUPED" \
      "$DRAIN_OFFSET" "$DRAIN_BATCH_COUNT") || exit 1
  fi
  DRAIN_CURRENT_REMOVED=0
  IFS=$(printf '\t') read -r _epoch _seq _kind _key _payload <<< "$drain_row"
  case "$_key" in
    inactive-outcome:*)
      if ! inactive_generation_valid; then
        drain_restore_remaining "$drain_line" || exit 1
        exit 2
      fi
      claim_status=0
      FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        claim "$_key" "$drain_row" || claim_status=$?
      case "$claim_status" in
        0)
          DRAIN_ACTIONABLE=1
          if ! FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
            FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK="${FM_WAKE_DRAIN_DEFER_ACK:-0}" \
            FM_WAKE_DRAIN_GENERATION="${FM_WAKE_DRAIN_GENERATION:-}" \
            FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" presenting "$_key" "$drain_row"; then
            drain_restore_remaining "$drain_line" || exit 1
            exit 1
          fi
          present_status=0
          DRAIN_CURRENT_RETAINED=0
          present_inactive_row "$_key" "$drain_row" || present_status=$?
          if [ "$present_status" -ne 0 ]; then
            restore_start=$drain_line
            [ "$DRAIN_CURRENT_RETAINED" = 1 ] && restore_start=$((drain_line + 1))
            drain_restore_remaining "$restore_start" || exit 1
            exit 1
          fi
          ;;
        1|5) ;;
        3)
          if [ "$DRAIN_RESUMING" = true ] && [ "$DRAIN_RESTORE_PENDING" != true ]; then
            fm_wake_remove_key_locked "$_key" || {
              drain_restore_remaining "$drain_line" || exit 1
              exit 1
            }
            DRAIN_CURRENT_REMOVED=1
          else
            DRAIN_FINALIZED_KEYS+=("$_key")
          fi
          ;;
        4)
          if [ "$DRAIN_RESUMING" != true ]; then
            drain_restore_remaining "$drain_line" || exit 1
          fi
          exit 0
          ;;
        6)
          drain_restore_remaining "$drain_line" || exit 1
          exit 1
          ;;
        *)
          drain_restore_remaining "$drain_line" || exit 1
          exit "$claim_status"
          ;;
      esac
      if [ "$claim_status" != 3 ] && [ "$claim_status" != 4 ] \
        && { [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" != 1 ] || [ "$claim_status" = 5 ]; }; then
        ack_status=0
      FM_WAKE_DRAIN_DELEGATED=0 FM_WAKE_DRAIN_PARENT_PID= \
        FM_WAKE_DRAIN_FILE="$DRAIN_DEDUPED" "$SCRIPT_DIR/fm-inactive-reconcile.sh" \
        ack "$_key" "$drain_row" 0 "${FM_WAKE_DRAIN_GENERATION:-}" || ack_status=$?
        if [ "$ack_status" != 0 ] && [ "$ack_status" != 1 ]; then
          drain_restore_remaining "$drain_line" || exit 1
          exit "$ack_status"
        fi
        DRAIN_CURRENT_REMOVED=1
      fi
      ;;
    *)
      if ! printf '%s\n' "$drain_row"; then
        drain_restore_remaining "$drain_line" || exit 1
        exit 1
      fi
      if [ "$_kind" = signal ] && ! fm_wake_mark_surface_consumed "$_key"; then
        drain_restore_remaining "$drain_line" || exit 1
        exit 1
      fi
      DRAIN_ACTIONABLE=1
      ;;
  esac
  drain_resume_advance "$DRAIN_CURRENT_REMOVED" || exit 1
  if [ "$DRAIN_BATCH_COUNT" -ge "$DRAIN_BATCH_ROWS" ]; then
    drain_batch_stop
    batch_status=$?
    [ "$batch_status" = 0 ] || exit "$batch_status"
    exit 0
  fi
done <&7
exec 7<&-
if [ "$DRAIN_RESTORE_PENDING" = true ]; then
  if [ "$DRAIN_RETAINED_ANY" = 1 ]; then
    drain_batch_stop
    batch_status=$?
    [ "$batch_status" = 0 ] || [ "$batch_status" = 3 ] || exit "$batch_status"
    exit "$batch_status"
  fi
  restore_pending_mark_source_retired "$DRAIN_RESTORE_SOURCE" "$DRAIN_RESTORE_OFFSET" || exit 1
  rm -f "$DRAIN_RESTORE_SOURCE" || exit 1
  restore_pending_retire_raw_source || exit 1
  rm -f "$DRAIN_RESTORE_MANIFEST" || exit 1
  DRAIN_DEDUPED=
  DRAIN_RESTORE_SOURCE=
  DRAIN_RESTORE_SOURCE_RETIRED=0
  DRAIN_RESTORE_RAW_SOURCE=
  DRAIN_RESTORE_RAW_SOURCE_RETIRED=1
  DRAIN_RESTORE_PENDING=false
elif [ "$DRAIN_RESUMING" = true ]; then
  if [ "$DRAIN_RETAINED_ANY" = 1 ]; then
    next_offset=$DRAIN_RETAINED_OFFSET
    fm_wake_queue_cursor_write "$next_offset" || exit 1
  else
    : | fm_nofollow_write "$FM_WAKE_QUEUE" || exit 1
    rm -f "$DRAIN_CURSOR" || exit 1
  fi
  DRAIN_DEDUPED=
else
  rm -f "$DRAIN_TMP"
  DRAIN_TMP=
  rm -f "$DRAIN_DEDUPED"
  DRAIN_DEDUPED=
fi
assert_watcher_liveness
if [ "${FM_WAKE_DRAIN_DIRECT:-0}" = 1 ] && [ "$DRAIN_ACTIONABLE" = 1 ]; then
  exit 3
fi
exit 0
