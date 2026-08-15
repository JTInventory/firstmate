#!/usr/bin/env bash
# Replay an authoritative terminal crew state that stayed quiet long enough to
# be missed by the normal watcher. This is a reporting layer only: it never
# closes an endpoint, returns a slot, removes a worktree, or changes a PR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "inactive outcome reconciliation" || exit 1
# shellcheck source=bin/fm-pane-idle-lib.sh
. "$SCRIPT_DIR/fm-pane-idle-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
OUTCOME_DIR="$STATE/terminal-outcomes"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_CURSOR="$STATE/.inactive-outcome-reconcile.cursor"
REPORTED_ROUTE_CURSOR="$STATE/.reported-secondmate-route-repair.cursor"
PENDING_RECEIPT_CURSOR="$STATE/.pending-receipt-republish.cursor"
MAINTENANCE_PHASE_CURSOR="$STATE/.inactive-outcome-maintenance.cursor"
MAINTENANCE_ORDER_CURSOR="$STATE/.inactive-outcome-maintenance-order.cursor"
DIRECT_FIND_PENDING="$STATE/.inactive-outcome-find.pending"
REPORTED_ROUTE_PENDING="$STATE/.reported-secondmate-route-repair.pending"
PENDING_RECEIPT_PENDING="$STATE/.pending-receipt-republish.pending"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
PANE_IDLE_DIR="$STATE/.pane-idle"

inactive_state_path_is_safe() {
  local path=$1 kind=$2
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    case "$kind" in
      dir) [ -d "$path" ] || return 1 ;;
      file) [ -f "$path" ] || return 1 ;;
      *) return 1 ;;
    esac
  fi
}

inactive_state_preflight() {
  if [ -L "$STATE" ] || { [ -e "$STATE" ] && [ ! -d "$STATE" ]; }; then
    return 1
  fi
  if [ ! -e "$STATE" ] && ! mkdir -p "$STATE"; then
    return 1
  fi
  inactive_state_path_is_safe "$STATE" dir || return 1
  inactive_state_path_is_safe "$OUTCOME_DIR" dir || return 1
  inactive_state_path_is_safe "$SCAN_MARKER" file || return 1
  inactive_state_path_is_safe "$SCAN_CURSOR" file || return 1
  inactive_state_path_is_safe "$REPORTED_ROUTE_CURSOR" file || return 1
  inactive_state_path_is_safe "$PENDING_RECEIPT_CURSOR" file || return 1
  inactive_state_path_is_safe "$MAINTENANCE_PHASE_CURSOR" file || return 1
  inactive_state_path_is_safe "$MAINTENANCE_ORDER_CURSOR" file || return 1
  inactive_state_path_is_safe "$DIRECT_FIND_PENDING" file || return 1
  inactive_state_path_is_safe "$REPORTED_ROUTE_PENDING" file || return 1
  inactive_state_path_is_safe "$PENDING_RECEIPT_PENDING" file || return 1
  inactive_state_path_is_safe "$PANE_IDLE_DIR" dir || return 1
  inactive_state_path_is_safe "$FM_WAKE_QUEUE" file || return 1
}

inactive_state_preflight || {
  echo "error: inactive reconciliation state must be local regular state under $FM_HOME" >&2
  exit 1
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
ROUTE_MARKER="$FM_HOME/.fm-secondmate-home"
CHILD_LOCK_HELD=0
CHILD_LOCK=
WAKE_QUEUE_LOCK_HELD=0
MAINTENANCE_ITEMS_PROCESSED=0

wake_queue_lock_acquire() {
  [ "$WAKE_QUEUE_LOCK_HELD" = 1 ] && return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  WAKE_QUEUE_LOCK_HELD=1
}

wake_queue_lock_release() {
  [ "$WAKE_QUEUE_LOCK_HELD" = 1 ] || return 0
  WAKE_QUEUE_LOCK_HELD=0
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

bounded_secs() {
  local value=$1 fallback=$2 minimum=$3 maximum=$4 value_len minimum_len maximum_len LC_ALL=C
  case "$value" in ''|*[!0-9]*) value=$fallback ;; esac
  while [ "${value#0}" != "$value" ]; do value=${value#0}; done
  [ -n "$value" ] || value=0
  value_len=${#value}
  minimum_len=${#minimum}
  maximum_len=${#maximum}
  if [ "$value_len" -lt "$minimum_len" ] \
    || { [ "$value_len" -eq "$minimum_len" ] && [[ "$value" < "$minimum" ]]; }; then
    value=$minimum
  elif [ "$value_len" -gt "$maximum_len" ] \
    || { [ "$value_len" -eq "$maximum_len" ] && [[ "$value" > "$maximum" ]]; }; then
    value=$maximum
  fi
  printf '%s' "$value"
}

clock_millis() {
  local stamp
  stamp=$(date +%s%N 2>/dev/null || true)
  case "$stamp" in
    ''|*[!0-9]*) printf '%s000' "$(date +%s)" ;;
    *)
      if [ "${#stamp}" -gt 10 ]; then
        printf '%s' "${stamp:0:${#stamp}-6}"
      else
        printf '%s000' "$stamp"
      fi
      ;;
  esac
}

budget_remaining_secs() {
  local deadline_ms=$1 now_ms remaining_ms
  now_ms=$(clock_millis)
  remaining_ms=$((deadline_ms - now_ms))
  if [ "$remaining_ms" -le 0 ]; then
    printf '0'
  else
    printf '%s' "$(((remaining_ms + 999) / 1000))"
  fi
}

inactive_copy_nul_prefix() {
  local source=$1 target=$2 value
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  [ ! -L "$target" ] || return 1
  : > "$target" || return 1
  while IFS= read -r -d '' value; do
    printf '%s\0' "$value" >> "$target" || return 1
  done < "$source"
}

inactive_append_nul_records() {
  local source=$1 target=$2 value
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  while IFS= read -r -d '' value; do
    printf '%s\0' "$value" >> "$target" || return 1
  done < "$source"
}

inactive_append_nul_value() {
  local target=$1 value=$2
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  printf '%s\0' "$value" >> "$target"
}

inactive_persist_nul_suffix() {
  local source=$1 target=$2 skip=$3 retry_source=${4:-} tmp value
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  [ ! -L "$target" ] || return 1
  case "$skip" in ''|*[!0-9]*) return 1 ;; esac
  tmp=$(mktemp "$target.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  if ! {
    while [ "$skip" -gt 0 ] && IFS= read -r -d '' value; do
      skip=$((skip - 1))
    done
    while IFS= read -r -d '' value; do
      printf '%s\0' "$value" || exit 1
    done
    true
  } < "$source" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -n "$retry_source" ]; then
    inactive_append_nul_records "$retry_source" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  [ ! -L "$target" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

inactive_persist_nul_prefix() {
  local source=$1 target=$2 tmp
  [ ! -L "$target" ] || return 1
  tmp=$(mktemp "$target.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  if ! inactive_copy_nul_prefix "$source" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  [ ! -L "$target" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

RECONCILE_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_SECS:-900}" 900 60 1800)
SCAN_BUDGET_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_BUDGET_SECS:-10}" 10 1 300)
REPORTED_ROUTE_REPAIR_LIMIT=$(bounded_secs "${FM_REPORTED_ROUTE_REPAIR_LIMIT:-32}" 32 1 256)
PENDING_RECEIPT_REPUBLISH_LIMIT=$(bounded_secs "${FM_PENDING_RECEIPT_REPUBLISH_LIMIT:-32}" 32 1 256)
MAINTENANCE_TURN_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_MAINTENANCE_RESERVE_SECS:-1}" 1 1 60)
DIRECT_SCAN_BUDGET_SECS=$SCAN_BUDGET_SECS

meta_value() {  # <meta> <key>
  awk -F= -v wanted="$2" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$1" 2>/dev/null
}

meta_value_unique() {  # <meta> <key>
  awk -F= -v wanted="$2" '
    $1 == wanted { count++; value=substr($0, index($0, "=") + 1) }
    END {
      if (count == 1) { print value; exit 0 }
      if (count == 0) exit 1
      exit 2
    }
  ' "$1" 2>/dev/null
}

file_mtime() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%m' "$1" 2>/dev/null
  else
    stat -c '%Y' "$1" 2>/dev/null
  fi
}

latest_activity() {
  local id=$1 meta="$STATE/$1.meta" path m latest=0
  for path in "$meta" "$STATE/$id.status" "$STATE/$id.turn-ended"; do
    if [ ! -e "$path" ] || [ -L "$path" ]; then
      continue
    fi
    m=$(file_mtime "$path") || continue
    [ "$m" -gt "$latest" ] && latest=$m
  done
  printf '%s' "$latest"
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

single_line() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

valid_task_id() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

is_secondmate_home() {
  local marker=$ROUTE_MARKER value
  [ ! -L "$marker" ] || return 2
  if [ ! -e "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] || return 2
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  return 0
}

herdr_identity_allowed() {  # <meta>
  local meta=$1 backend session window rc
  if backend=$(meta_value_unique "$meta" backend); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] && return 0
    return 1
  fi
  [ "$backend" = herdr ] || return 0
  session=$(meta_value_unique "$meta" herdr_session) || return 1
  window=$(meta_value_unique "$meta" window) || return 1
  case "$session" in
    firstmate) : ;;
    default|DEFAULT|CAPTAIN|captain) return 1 ;;
    *) return 1 ;;
  esac
  case "$window" in firstmate:*) return 0 ;; esac
  return 1
}

run_bounded_child() {  # <seconds> <command> [args...]
  local seconds=$1
  shift
  if [ "${FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT:-0}" != 1 ] \
    && command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif [ "${FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT:-0}" != 1 ] \
    && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; my $status = $?; exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8))' "$seconds" "$@"
  else
    return 125
  fi
}

receipt_path() {  # <fingerprint> <suffix>
  printf '%s/%s.%s' "$OUTCOME_DIR" "$1" "$2"
}

receipt_field() {  # <receipt> <key>
  meta_value_unique "$1" "$2"
}

claim_path() {  # <fingerprint>
  printf '%s/.%s.claim' "$OUTCOME_DIR" "$1"
}

claim_field() {  # <claim> <key>
  meta_value_unique "$1" "$2"
}

claim_binary_field() {  # <claim> <key>
  local value
  value=$(claim_field "$1" "$2") || return 1
  case "$value" in
    0|1) printf '%s' "$value" ;;
    *) return 1 ;;
  esac
}

claim_binary_fields_valid() {
  local claim=$1 field value rc
  for field in output_started output_emitted output_complete output_confirmed caller_confirmed; do
    value=$(awk -F= -v wanted="$field" '
      $1 == wanted { count++; value=substr($0, index($0, "=") + 1) }
      END {
        if (count == 0) exit 1
        if (count != 1) exit 2
        print value
      }
    ' "$claim" 2>/dev/null)
    rc=$?
    case "$rc" in
      1) continue ;;
      0)
        case "$value" in 0|1) ;; *) return 1 ;; esac
        ;;
      *) return 1 ;;
    esac
  done
}

claim_receipt_state() {
  local fp=$1 suffix path found=
  for suffix in pending presented reported; do
    path=$(receipt_path "$fp" "$suffix")
    [ ! -L "$path" ] || return 2
    [ -e "$path" ] || continue
    [ -f "$path" ] || return 2
    prepare_pending_receipt "$path" || return 2
    [ -z "$found" ] || return 2
    found=$suffix
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

claim_defer_generation_live() {
  local generation=$1 stored_start=${2:-}
  case "$generation" in ''|*[!0-9]*) return 1 ;; esac
  [ "$generation" != 0 ] || return 1
  [ -n "$stored_start" ] || return 1
  kill -0 "$generation" 2>/dev/null || return 1
  fm_pid_start_matches_stored "$generation" "$stored_start"
}

drain_claim_owner() {
  local row=$1 owner parent_pid drain_file drain_dir state_dir
  owner=$(fm_lock_link_owner "$FM_WAKE_QUEUE_LOCK" 2>/dev/null || true)
  if [ "${FM_WAKE_DRAIN_DELEGATED:-0}" = 1 ]; then
    parent_pid=${FM_WAKE_DRAIN_PARENT_PID:-}
  else
    parent_pid=${PPID:-}
  fi
  drain_file=${FM_WAKE_DRAIN_FILE:-}
  [ -n "$owner" ] && [ -n "$parent_pid" ] && [ -n "$row" ] && [ -n "$drain_file" ] || return 1
  [ "$(cat "$owner/pid" 2>/dev/null || true)" = "$parent_pid" ] || return 1
  fm_lock_points_to_owner "$FM_WAKE_QUEUE_LOCK" "$owner" || return 1
  [ -f "$drain_file" ] && [ ! -L "$drain_file" ] || return 1
  drain_dir=$(cd "$(dirname "$drain_file")" 2>/dev/null && pwd -P) || return 1
  state_dir=$(cd "$STATE" 2>/dev/null && pwd -P) || return 1
  [ "$drain_dir" = "$state_dir" ] || return 1
  [ "$(basename "$drain_file")" = ".wake-queue.deduped.$parent_pid" ] || return 1
  awk -v wanted="$row" '$0 == wanted { found=1; exit } END { exit !found }' "$drain_file"
}

claim_validate() {  # <claim> <fingerprint> <row>
  local claim=$1 fp=$2 row=$3 state
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  [ "$(claim_field "$claim" schema)" = fm-inactive-outcome-claim.v1 ] || return 1
  [ "$(claim_field "$claim" fingerprint)" = "$fp" ] || return 1
  [ "$(claim_field "$claim" row)" = "$row" ] || return 1
  state=$(claim_field "$claim" state)
  case "$state" in reserved|presenting|presented) printf '%s' "$state" ;; *) return 1 ;; esac
}

claim_validate_caller_owner() {  # <claim> <caller-pid>
  local claim=$1 caller_pid=$2 caller_start
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  case "$caller_pid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$(claim_field "$claim" defer_ack 2>/dev/null || true)" = 1 ] || return 1
  [ "$(claim_field "$claim" defer_generation 2>/dev/null || true)" = "$caller_pid" ] || return 1
  caller_start=$(claim_field "$claim" defer_generation_start 2>/dev/null || true)
  fm_pid_start_matches_stored "$caller_pid" "$caller_start"
}

claim_rewrite_row() {
  local claim=$1 row=$2 tmp line
  tmp=$(mktemp "$OUTCOME_DIR/.claim-row.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in row=*) printf 'row=%s\n' "$row" ;; *) printf '%s\n' "$line" ;; esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 1; }
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 1; }
}

claim_recover_deferred_handoff() {
  local key=$1 row=$2 generation=${FM_WAKE_DRAIN_GENERATION:-} generation_start
  local fp claim state tmp line seen_generation=0 seen_generation_start=0 seen_caller_confirmed=0
  [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ] || return 2
  case "$generation" in ''|*[!0-9]*|0) return 2 ;; esac
  generation_start=$(fm_pid_start "$generation") || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 0 ] || return 2
  [ "$(claim_field "$claim" defer_ack 2>/dev/null || true)" = 1 ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presented\n' ;;
      defer_generation=*) printf 'defer_generation=%s\n' "$generation"; seen_generation=1 ;;
      defer_generation_start=*) printf 'defer_generation_start=%s\n' "$generation_start"; seen_generation_start=1 ;;
      caller_confirmed=*) printf 'caller_confirmed=1\n'; seen_caller_confirmed=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_generation" = 1 ] || printf 'defer_generation=%s\n' "$generation" >> "$tmp"
  [ "$seen_generation_start" = 1 ] || printf 'defer_generation_start=%s\n' "$generation_start" >> "$tmp"
  [ "$seen_caller_confirmed" = 1 ] || printf 'caller_confirmed=1\n' >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_rebind_deferred_generation() {
  local key=$1 row=$2 generation=${FM_WAKE_DRAIN_GENERATION:-} generation_start
  local fp claim state tmp line seen_generation=0 seen_generation_start=0
  case "$generation" in ''|*[!0-9]*|0) return 2 ;; esac
  generation_start=$(fm_pid_start "$generation") || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  case "$state" in presenting|presented) ;; *) return 2 ;; esac
  [ "$(claim_field "$claim" defer_ack 2>/dev/null || true)" = 1 ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      defer_generation=*) printf 'defer_generation=%s\n' "$generation"; seen_generation=1 ;;
      defer_generation_start=*) printf 'defer_generation_start=%s\n' "$generation_start"; seen_generation_start=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_generation" = 1 ] || printf 'defer_generation=%s\n' "$generation" >> "$tmp"
  [ "$seen_generation_start" = 1 ] || printf 'defer_generation_start=%s\n' "$generation_start" >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_recorded_presented() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line field value
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  case "$state" in reserved|presenting) ;; *) return 2 ;; esac
  claim_binary_fields_valid "$claim" || return 2
  for field in output_started output_emitted output_complete output_confirmed caller_confirmed; do
    value=$(claim_binary_field "$claim" "$field" 2>/dev/null || true)
    case "$value" in ''|0) ;; *) return 2 ;; esac
  done
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presented\n' ;;
      output_started=*) printf 'output_started=1\n' ;;
      output_emitted=*) printf 'output_emitted=1\n' ;;
      output_complete=*) printf 'output_complete=1\n' ;;
      output_confirmed=*) printf 'output_confirmed=1\n' ;;
      caller_confirmed=*) printf 'caller_confirmed=1\n' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  for field in output_started output_emitted output_complete output_confirmed caller_confirmed; do
    grep -Fq "$field=" "$tmp" || printf '%s=1\n' "$field" >> "$tmp"
  done
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_reserve() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim tmp state existing old_row line output_started output_emitted output_complete output_confirmed caller_confirmed defer_ack
  local defer_generation defer_generation_start receipt_state receipt_rc=0 recorded_report=0 report_rc=1 recorded_ready=1 value
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  inactive_state_preflight || return 2
  receipt_state=$(claim_receipt_state "$fp" 2>/dev/null) || receipt_rc=$?
  [ "$receipt_rc" = 0 ] || return 2
  case "$receipt_state" in
    presented|reported)
      claim=$(claim_path "$fp")
      [ ! -L "$claim" ] || return 2
      if [ -e "$claim" ]; then
        [ -f "$claim" ] || return 2
        [ "$(claim_field "$claim" schema)" = fm-inactive-outcome-claim.v1 ] || return 2
        [ "$(claim_field "$claim" fingerprint)" = "$fp" ] || return 2
        [ -n "$(claim_field "$claim" row)" ] || return 2
        case "$(claim_field "$claim" state)" in reserved|presenting|presented) ;; *) return 2 ;; esac
        rm -f "$claim" || return 2
      fi
      return 3
      ;;
    pending) ;;
    *) return 2 ;;
  esac
  prepare_pending_receipt "$(receipt_path "$fp" pending)" || return 2
  report_rc=0
  pending_secondmate_report_recorded "$fp" >/dev/null || report_rc=$?
  case "$report_rc" in
    0) recorded_report=1 ;;
    1) ;;
    *) return 2 ;;
  esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  if [ -e "$claim" ]; then
    [ -f "$claim" ] || return 2
    [ "$(claim_field "$claim" schema)" = fm-inactive-outcome-claim.v1 ] || return 2
    [ "$(claim_field "$claim" fingerprint)" = "$fp" ] || return 2
    state=$(claim_field "$claim" state)
    case "$state" in presented|presenting|reserved) ;; *) return 2 ;; esac
    old_row=$(claim_field "$claim" row)
    [ -n "$old_row" ] || return 2
    claim_binary_fields_valid "$claim" || return 2
    if [ "$state" = presented ]; then
      defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null || true)
      if [ "$defer_ack" = 1 ]; then
        defer_generation=$(claim_field "$claim" defer_generation 2>/dev/null || true)
        defer_generation_start=$(claim_field "$claim" defer_generation_start 2>/dev/null || true)
        [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
      fi
    fi
    if [ "$state" = presenting ]; then
      output_started=$(claim_field "$claim" output_started 2>/dev/null || true)
      output_emitted=$(claim_field "$claim" output_emitted 2>/dev/null || true)
      output_complete=$(claim_field "$claim" output_complete 2>/dev/null || true)
      output_confirmed=$(claim_field "$claim" output_confirmed 2>/dev/null || true)
      caller_confirmed=$(claim_field "$claim" caller_confirmed 2>/dev/null || true)
      defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null || true)
      if [ "$defer_ack" = 1 ]; then
        defer_generation=$(claim_field "$claim" defer_generation 2>/dev/null || true)
        defer_generation_start=$(claim_field "$claim" defer_generation_start 2>/dev/null || true)
        if [ "${FM_WAKE_DRAIN_DIRECT:-0}" != 1 ] \
          && claim_defer_generation_live "$defer_generation" "$defer_generation_start"; then
          return 4
        fi
      fi
    fi
    if [ "$old_row" != "$row" ]; then
      claim_rewrite_row "$claim" "$row" || return 2
    fi
    if [ "$state" = presented ] && [ "$(claim_field "$claim" defer_ack 2>/dev/null || true)" = 1 ]; then
      [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
      [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
      [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
      [ "$(claim_binary_field "$claim" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
      [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
      if [ -n "${FM_WAKE_DRAIN_GENERATION:-}" ] \
        && { [ "${FM_WAKE_DRAIN_DIRECT:-0}" = 1 ] \
          || ! claim_defer_generation_live "$defer_generation" "$defer_generation_start"; }; then
        claim_rebind_deferred_generation "$key" "$row" || return 2
      fi
      return 5
    fi
    if [ "$state" = presenting ] && [ "$defer_ack" = 1 ]; then
      if [ "$recorded_report" = 1 ]; then
        recorded_ready=1
        for value in "$output_started" "$output_emitted" "$output_complete" "$output_confirmed" "$caller_confirmed"; do
          case "$value" in ''|0) ;; *) recorded_ready=0 ;; esac
        done
        if [ "$recorded_ready" = 1 ]; then
          claim_mark_presenting "$key" "$row" || return 2
          claim_mark_recorded_presented "$key" "$row" || return 2
          return 5
        fi
      fi
      if [ "$caller_confirmed" = 0 ] \
        && [ "$output_started" = 1 ] \
        && [ "$output_emitted" = 1 ] \
        && [ "$output_complete" = 1 ] \
        && [ "$output_confirmed" = 1 ] \
        && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ] \
        && [ "${FM_WAKE_DRAIN_DIRECT:-0}" != 1 ] \
        && ! claim_defer_generation_live "$defer_generation" "$defer_generation_start"; then
        claim_recover_deferred_handoff "$key" "$row" || return 2
        return 5
      fi
      case "$caller_confirmed" in
        1)
          [ "$output_started" = 1 ] || return 2
          [ "$output_emitted" = 1 ] || return 2
          [ "$output_complete" = 1 ] || return 2
          [ "$output_confirmed" = 1 ] || return 2
          if [ -n "${FM_WAKE_DRAIN_GENERATION:-}" ]; then
            claim_rebind_deferred_generation "$key" "$row" || return 2
          fi
          claim_mark_presented_recovered "$key" "$row" || return 2
          return 5
          ;;
        ''|0) ;;
        *) return 2 ;;
      esac
      case "$output_emitted" in
        ''|0) ;;
        1) [ "$output_confirmed" = 1 ] || return 2 ;;
        *) return 2 ;;
      esac
      case "$output_complete" in
        ''|0) ;;
        1) return 4 ;;
        *) return 2 ;;
      esac
      [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ] || return 4
      return 0
    fi
    if [ "$recorded_report" = 1 ]; then
      if [ "$state" = presented ]; then
        return 5
      fi
      if [ "$state" = reserved ]; then
        claim_mark_presenting "$key" "$row" || return 2
        state=presenting
        output_started=0
        output_emitted=0
        output_complete=0
        output_confirmed=0
        caller_confirmed=0
      fi
      for value in "$output_started" "$output_emitted" "$output_complete" "$output_confirmed" "$caller_confirmed"; do
        case "$value" in ''|0) ;; *) recorded_ready=0 ;; esac
      done
      if [ "$state" = presenting ] && [ "$recorded_ready" = 1 ]; then
        claim_mark_presenting "$key" "$row" || return 2
        claim_mark_recorded_presented "$key" "$row" || return 2
        return 5
      fi
    fi
    if [ "$recorded_report" = 1 ]; then
      case "$state" in
        presented) return 5 ;;
        presenting|reserved)
          claim_mark_presenting "$key" "$row" || return 2
          claim_mark_output_complete "$key" "$row" || return 2
          claim_mark_output_confirmed "$key" "$row" || return 2
          claim_mark_presented "$key" "$row" || return 2
          return 5
          ;;
      esac
    fi
    if [ "$state" = presenting ]; then
      output_complete=$(claim_binary_field "$claim" output_complete 2>/dev/null || true)
      defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null || true)
      if [ "$defer_ack" = 1 ]; then
        defer_generation=$(claim_field "$claim" defer_generation 2>/dev/null || true)
        defer_generation_start=$(claim_field "$claim" defer_generation_start 2>/dev/null || true)
        if [ "${FM_WAKE_DRAIN_DIRECT:-0}" != 1 ] \
          && claim_defer_generation_live "$defer_generation" "$defer_generation_start"; then
          return 4
        fi
      fi
      if [ "$output_complete" = 1 ]; then
        [ "$output_confirmed" = 1 ] || return 4
        claim_mark_presented "$key" "$row" || return 2
        return 5
      fi
      if [ "$output_emitted" = 1 ]; then
        [ "$output_confirmed" = 1 ] || return 4
        if claim_mark_output_complete "$key" "$row"; then
          claim_mark_presented "$key" "$row" || return 2
          return 5
        fi
        return 6
      fi
      if [ "$defer_ack" = 1 ]; then
        return 0
      fi
    fi
    if [ "$state" = presented ]; then
      defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null || true)
      if [ "$defer_ack" = 1 ]; then
        tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
        chmod 600 "$tmp" 2>/dev/null || true
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            state=*) printf 'state=reserved\n' ;;
            defer_ack=*) printf 'defer_ack=0\n' ;;
            defer_generation=*) printf 'defer_generation=\n' ;;
            defer_generation_start=*) printf 'defer_generation_start=\n' ;;
            *) printf '%s\n' "$line" ;;
          esac
        done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
        [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
        mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
        return 0
      fi
      return 5
    fi
    return 0
  fi
  mkdir -p "$OUTCOME_DIR" || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  {
    printf 'schema=fm-inactive-outcome-claim.v1\n'
    printf 'fingerprint=%s\n' "$fp"
    printf 'row=%s\n' "$row"
    printf 'state=reserved\n'
    printf 'created_epoch=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f "$tmp"; return 2; }
  if ln "$tmp" "$claim" 2>/dev/null; then
    rm -f "$tmp"
    if [ "$recorded_report" = 1 ]; then
      claim_mark_presenting "$key" "$row" || return 2
      claim_mark_recorded_presented "$key" "$row" || return 2
      return 5
    fi
    return 0
  fi
  rm -f "$tmp"
  [ -e "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presented ] && return 1
  return 0
}

claim_mark_presenting() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line defer_ack=0 defer_generation= defer_generation_start=
  local preserve_output=0 seen_pid=0 seen_output=0 seen_emitted=0 seen_complete=0 seen_caller_confirmed=0
  local seen_defer_ack=0 seen_defer_generation=0 seen_defer_generation_start=0
  if [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ] || [ -n "${FM_WAKE_DRAIN_GENERATION:-}" ]; then
    defer_ack=1
  fi
  if [ "$defer_ack" = 1 ]; then
    defer_generation=${FM_WAKE_DRAIN_GENERATION:-}
    case "$defer_generation" in ''|*[!0-9]*|0) return 2 ;; esac
    defer_generation_start=$(fm_pid_start "$defer_generation") || return 2
  fi
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  case "$state" in
    presenting|reserved) ;;
    *) return 2 ;;
  esac
  claim_binary_fields_valid "$claim" || return 2
  if [ "$state" = presenting ] \
    && [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ]; then
    preserve_output=1
  fi
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presenting\n' ;;
      presentation_pid=*) printf 'presentation_pid=%s\n' "${BASHPID:-$$}"; seen_pid=1 ;;
      output_started=*)
        if [ "$preserve_output" = 1 ]; then printf '%s\n' "$line"; else printf 'output_started=0\n'; fi
        seen_output=1
        ;;
      output_emitted=*)
        if [ "$preserve_output" = 1 ]; then printf '%s\n' "$line"; else printf 'output_emitted=0\n'; fi
        seen_emitted=1
        ;;
      output_complete=*)
        if [ "$preserve_output" = 1 ]; then printf '%s\n' "$line"; else printf 'output_complete=0\n'; fi
        seen_complete=1
        ;;
      caller_confirmed=*)
        if [ "$preserve_output" = 1 ]; then printf '%s\n' "$line"; else printf 'caller_confirmed=0\n'; fi
        seen_caller_confirmed=1
        ;;
      defer_ack=*) printf 'defer_ack=%s\n' "$defer_ack"; seen_defer_ack=1 ;;
      defer_generation=*) printf 'defer_generation=%s\n' "$defer_generation"; seen_defer_generation=1 ;;
      defer_generation_start=*) printf 'defer_generation_start=%s\n' "$defer_generation_start"; seen_defer_generation_start=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_pid" = 1 ] || printf 'presentation_pid=%s\n' "${BASHPID:-$$}" >> "$tmp"
  [ "$seen_output" = 1 ] || printf 'output_started=0\n' >> "$tmp"
  [ "$seen_emitted" = 1 ] || printf 'output_emitted=0\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=0\n' >> "$tmp"
  [ "$seen_caller_confirmed" = 1 ] || printf 'caller_confirmed=0\n' >> "$tmp"
  [ "$seen_defer_ack" = 1 ] || printf 'defer_ack=%s\n' "$defer_ack" >> "$tmp"
  [ "$seen_defer_generation" = 1 ] || printf 'defer_generation=%s\n' "$defer_generation" >> "$tmp"
  [ "$seen_defer_generation_start" = 1 ] || printf 'defer_generation_start=%s\n' "$defer_generation_start" >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_output_complete() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 owner_required=${3:-1} expected_generation=${4:-}
  local fp claim state tmp line seen_output=0 seen_complete=0
  local seen_emitted=0 seen_confirmed=0 seen_caller_confirmed=0 confirmed_value caller_confirmed_value
  case "$owner_required" in
    1) drain_claim_owner "$row" || return 2 ;;
    0)
      case "$expected_generation" in ''|*[!0-9]*|0) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  if [ "$owner_required" = 0 ]; then
    claim_validate_caller_owner "$claim" "$expected_generation" || return 2
    [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
    [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
  fi
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      output_started=*) printf 'output_started=1\n'; seen_output=1 ;;
      output_emitted=*) printf 'output_emitted=1\n'; seen_emitted=1 ;;
      output_complete=*) printf 'output_complete=1\n'; seen_complete=1 ;;
      output_confirmed=*)
        [ "$seen_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        confirmed_value=${line#output_confirmed=}
        case "$confirmed_value" in 0|1) ;; *) rm -f "$tmp"; return 2 ;; esac
        [ "$owner_required" = 0 ] && confirmed_value=1
        printf 'output_confirmed=%s\n' "$confirmed_value"
        seen_confirmed=1
        ;;
      caller_confirmed=*)
        [ "$seen_caller_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        caller_confirmed_value=${line#caller_confirmed=}
        case "$caller_confirmed_value" in 0|1) ;; *) rm -f "$tmp"; return 2 ;; esac
        [ "$owner_required" = 0 ] && caller_confirmed_value=1
        printf 'caller_confirmed=%s\n' "$caller_confirmed_value"
        seen_caller_confirmed=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_emitted" = 1 ] || printf 'output_emitted=1\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=1\n' >> "$tmp"
  [ "$seen_confirmed" = 1 ] || \
    printf 'output_confirmed=%s\n' "$([ "$owner_required" = 0 ] && printf 1 || printf 0)" >> "$tmp"
  [ "$seen_caller_confirmed" = 1 ] || \
    printf 'caller_confirmed=%s\n' "$([ "$owner_required" = 0 ] && printf 1 || printf 0)" >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_output_started() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line seen_output=0 seen_complete=0
  local seen_emitted=0 seen_confirmed=0 seen_caller_confirmed=0
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      output_started=*) printf 'output_started=1\n'; seen_output=1 ;;
      output_emitted=*) printf 'output_emitted=0\n'; seen_emitted=1 ;;
      output_complete=*) printf 'output_complete=0\n'; seen_complete=1 ;;
      output_confirmed=*)
        [ "$seen_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'output_confirmed=0\n'
        seen_confirmed=1
        ;;
      caller_confirmed=*)
        [ "$seen_caller_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'caller_confirmed=0\n'
        seen_caller_confirmed=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_emitted" = 1 ] || printf 'output_emitted=0\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=0\n' >> "$tmp"
  [ "$seen_confirmed" = 1 ] || printf 'output_confirmed=0\n' >> "$tmp"
  [ "$seen_caller_confirmed" = 1 ] || printf 'caller_confirmed=0\n' >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_output_emitted() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line seen_output=0 seen_emitted=0 seen_complete=0
  local seen_confirmed=0 seen_caller_confirmed=0
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      output_started=*) printf 'output_started=1\n'; seen_output=1 ;;
      output_emitted=*) printf 'output_emitted=1\n'; seen_emitted=1 ;;
      output_complete=*) printf 'output_complete=0\n'; seen_complete=1 ;;
      output_confirmed=*)
        [ "$seen_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'output_confirmed=0\n'
        seen_confirmed=1
        ;;
      caller_confirmed=*)
        [ "$seen_caller_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'caller_confirmed=0\n'
        seen_caller_confirmed=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_emitted" = 1 ] || printf 'output_emitted=1\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=0\n' >> "$tmp"
  [ "$seen_confirmed" = 1 ] || printf 'output_confirmed=0\n' >> "$tmp"
  [ "$seen_caller_confirmed" = 1 ] || printf 'caller_confirmed=0\n' >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_output_emitted() {
  local key=$1 row=$2 fp claim state emitted
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  emitted=$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)
  case "$emitted" in
    1) return 0 ;;
    0|'') return 1 ;;
    *) return 2 ;;
  esac
}

claim_mark_output_confirmed() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line seen_confirmed=0 seen_caller_confirmed=0
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      output_confirmed=*)
        [ "$seen_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'output_confirmed=1\n'
        seen_confirmed=1
        ;;
      caller_confirmed=*)
        [ "$seen_caller_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'caller_confirmed=0\n'
        seen_caller_confirmed=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_confirmed" = 1 ] || printf 'output_confirmed=1\n' >> "$tmp"
  [ "$seen_caller_confirmed" = 1 ] || printf 'caller_confirmed=0\n' >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_presented() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line defer_ack defer_generation defer_generation_start
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
  defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null) || return 2
  case "$defer_ack" in 0) ;; 1)
    defer_generation=$(claim_field "$claim" defer_generation 2>/dev/null) || return 2
    defer_generation_start=$(claim_field "$claim" defer_generation_start 2>/dev/null) || return 2
    case "$defer_generation" in ''|*[!0-9]*|0) return 2 ;; esac
    [ -n "$defer_generation_start" ] || return 2
    [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
    ;;
    *) return 2 ;;
  esac
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presented\n' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_presented_recovered() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  claim_binary_fields_valid "$claim" || return 2
  [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in state=*) printf 'state=presented\n' ;; *) printf '%s\n' "$line" ;; esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_confirmed() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 owner_required=${3:-1} expected_generation=${4:-}
  local fp claim state tmp line seen_output=0 seen_emitted=0 seen_complete=0 seen_confirmed=0 seen_caller_confirmed=0
  case "$owner_required" in
    1) drain_claim_owner "$row" || return 2 ;;
    0) ;; 
    *) return 2 ;;
  esac
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  claim_binary_fields_valid "$claim" || return 2
  if [ "$owner_required" = 0 ]; then
    claim_validate_caller_owner "$claim" "$expected_generation" || return 2
    [ "$(claim_binary_field "$claim" output_started 2>/dev/null || true)" = 1 ] || return 2
    [ "$(claim_binary_field "$claim" output_emitted 2>/dev/null || true)" = 1 ] || return 2
    [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
    [ "$(claim_binary_field "$claim" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
    [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
  fi
  case "$state" in
    presented)
      [ "$(claim_binary_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
      [ "$(claim_binary_field "$claim" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
      if [ "$(claim_field "$claim" defer_ack 2>/dev/null || true)" = 1 ]; then
        [ "$(claim_binary_field "$claim" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
      fi
      return 0
      ;;
    presenting) ;;
    *) return 2 ;;
  esac
  [ "$(claim_field "$claim" defer_ack 2>/dev/null || true)" = 1 ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presented\n' ;;
      output_started=*) printf 'output_started=1\n'; seen_output=1 ;;
      output_emitted=*) printf 'output_emitted=1\n'; seen_emitted=1 ;;
      output_complete=*) printf 'output_complete=1\n'; seen_complete=1 ;;
      output_confirmed=*)
        [ "$seen_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'output_confirmed=1\n'
        seen_confirmed=1
        ;;
      caller_confirmed=*)
        [ "$seen_caller_confirmed" = 0 ] || { rm -f "$tmp"; return 2; }
        [ "$owner_required" = 0 ] || { rm -f "$tmp"; return 2; }
        printf 'caller_confirmed=1\n'
        seen_caller_confirmed=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_emitted" = 1 ] || printf 'output_emitted=1\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=1\n' >> "$tmp"
  [ "$seen_confirmed" = 1 ] || printf 'output_confirmed=1\n' >> "$tmp"
  [ "$owner_required" = 0 ] && [ "$seen_caller_confirmed" = 1 ] || { rm -f "$tmp"; return 2; }
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_remove() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 owner_required=${3:-1} expected_generation=${4:-} fp claim
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  case "$owner_required" in
    0) claim_validate_caller_owner "$claim" "$expected_generation" || return 2 ;;
    1) drain_claim_owner "$row" || return 2 ;;
    *) return 2 ;;
  esac
  [ ! -L "$claim" ] || return 2
  [ -e "$claim" ] || return 0
  claim_validate "$claim" "$fp" "$row" >/dev/null || return 2
  rm -f "$claim"
}

receipt_write() {  # globals: FP ID INC OUTCOME SNAPSHOT KIND SOURCE
  local pending tmp existing
  inactive_state_preflight || return 1
  pending=$(receipt_path "$FP" pending)
  RECEIPT_CREATED=0
  for suffix in pending presented reported; do
    existing=$(receipt_path "$FP" "$suffix")
    [ ! -L "$existing" ] || return 1
    [ -e "$existing" ] || continue
    [ -f "$existing" ] || return 1
    [ "$(receipt_field "$existing" schema)" = fm-jt-terminal-outcome.v1 ] || return 1
    [ "$(receipt_field "$existing" fingerprint)" = "$FP" ] || return 1
    [ "$(receipt_field "$existing" task_id)" = "$ID" ] || return 1
    [ "$(receipt_field "$existing" incarnation)" = "$INC" ] || return 1
    [ "$(receipt_field "$existing" outcome)" = "$OUTCOME" ] || return 1
    [ "$(receipt_field "$existing" terminal_source)" = "$SOURCE" ] || return 1
    [ "$(receipt_field "$existing" terminal_snapshot)" = "$SNAPSHOT" ] || return 1
    [ "$(receipt_field "$existing" kind)" = "$KIND" ] || return 1
    if [ "$KIND" = secondmate ]; then
      [ "$(receipt_field "$existing" parent_task_id)" = "${FM_PENDING_ROUTE_SECOND_MATE_ID:-}" ] || return 1
      [ "$(receipt_field "$existing" parent_home)" = "${FM_PENDING_ROUTE_PARENT_HOME:-}" ] || return 1
      [ "$(receipt_field "$existing" parent_status)" = "${FM_PENDING_ROUTE_PARENT_STATUS:-}" ] || return 1
      [ "$(receipt_field "$existing" parent_corr)" = "${FM_PENDING_ROUTE_CORR:-}" ] || return 1
    else
      [ -z "$(receipt_field "$existing" parent_task_id)" ] || return 1
      [ -z "$(receipt_field "$existing" parent_home)" ] || return 1
      [ -z "$(receipt_field "$existing" parent_status)" ] || return 1
      [ -z "$(receipt_field "$existing" parent_corr)" ] || return 1
    fi
    return 0
  done
  mkdir -p "$OUTCOME_DIR" || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.receipt.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  {
    printf 'schema=fm-jt-terminal-outcome.v1\n'
    printf 'fingerprint=%s\n' "$FP"
    printf 'task_id=%s\n' "$ID"
    printf 'incarnation=%s\n' "$INC"
    printf 'outcome=%s\n' "$OUTCOME"
    printf 'terminal_source=%s\n' "$SOURCE"
    printf 'terminal_snapshot=%s\n' "$SNAPSHOT"
    printf 'kind=%s\n' "$KIND"
    printf 'parent_task_id=%s\n' "${FM_PENDING_ROUTE_SECOND_MATE_ID:-}"
    printf 'parent_home=%s\n' "${FM_PENDING_ROUTE_PARENT_HOME:-}"
    printf 'parent_status=%s\n' "${FM_PENDING_ROUTE_PARENT_STATUS:-}"
    printf 'parent_corr=%s\n' "${FM_PENDING_ROUTE_CORR:-}"
    printf 'created_epoch=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  # ln is an exclusive, same-filesystem publication. A concurrent scanner can
  # therefore never replace a receipt for another incarnation.
  if ln "$tmp" "$pending" 2>/dev/null; then
    rm -f "$tmp"
    RECEIPT_CREATED=1
  else
    rm -f "$tmp"
    [ -e "$pending" ] || return 1
  fi
  return 0
}

replay_pane_idle_publication_valid() {
  local meta=$1 id=$2 window=$3 backend=$4 incarnation=$5
  (
    unset FM_PANE_IDLE_META_INDEX_DIR
    fm_pane_idle_proof_valid "$STATE" "$meta" "$id" "$window" "$backend" "$incarnation" "$RECONCILE_SECS"
  )
}

publish_receipt_and_wake() {
  local status=0 release_lock=0
  local pane_meta=${1:-} pane_id=${2:-} pane_window=${3:-} pane_backend=${4:-} pane_incarnation=${5:-}
  FM_WAKE_APPEND_CREATED=0
  if [ "$WAKE_QUEUE_LOCK_HELD" != 1 ]; then
    if ! wake_queue_lock_acquire; then
      [ -z "$pane_meta" ] || return 1
      receipt_write || return 1
      return 1
    fi
    release_lock=1
  fi
  if [ -n "$pane_meta" ] \
    && ! replay_pane_idle_publication_valid "$pane_meta" "$pane_id" "$pane_window" "$pane_backend" "$pane_incarnation"; then
    [ "$release_lock" = 1 ] && wake_queue_lock_release || true
    return 75
  fi
  if receipt_write; then
    if [ -f "$(receipt_path "$FP" pending)" ]; then
      fm_wake_append_if_absent_locked FM_WAKE_APPEND_CREATED check "inactive-outcome:$FP" \
        "inactive terminal outcome: task=$ID state=$OUTCOME fingerprint=$FP" || status=$?
    fi
  else
    status=$?
  fi
  if [ "$release_lock" = 1 ]; then
    wake_queue_lock_release || status=1
  fi
  return "$status"
}

receipt_existing_core() {
  local suffix existing expected_fp existing_kind parent_id parent_home parent_status parent_corr
  RECEIPT_EXISTING_SUFFIX=
  expected_fp=$(hash_text "$ID|$INC|$OUTCOME|$SNAPSHOT|$KIND") || return 1
  [ "$expected_fp" = "$FP" ] || return 1
  for suffix in pending presented reported; do
    existing=$(receipt_path "$FP" "$suffix")
    [ ! -L "$existing" ] || return 2
    [ -e "$existing" ] || continue
    [ -f "$existing" ] || return 2
    [ "$(receipt_field "$existing" schema)" = fm-jt-terminal-outcome.v1 ] || return 2
    [ "$(receipt_field "$existing" fingerprint)" = "$FP" ] || return 2
    [ "$(receipt_field "$existing" task_id)" = "$ID" ] || return 2
    [ "$(receipt_field "$existing" incarnation)" = "$INC" ] || return 2
    [ "$(receipt_field "$existing" outcome)" = "$OUTCOME" ] || return 2
    [ "$(receipt_field "$existing" terminal_source)" = "$SOURCE" ] || return 2
    [ "$(receipt_field "$existing" terminal_snapshot)" = "$SNAPSHOT" ] || return 2
    existing_kind=$(receipt_field "$existing" kind)
    case "$existing_kind" in
      ship|scout)
        parent_id=$(receipt_field "$existing" parent_task_id)
        parent_home=$(receipt_field "$existing" parent_home)
        parent_status=$(receipt_field "$existing" parent_status)
        parent_corr=$(receipt_field "$existing" parent_corr)
        [ -z "$parent_id" ] && [ -z "$parent_home" ] && [ -z "$parent_status" ] && [ -z "$parent_corr" ] || return 2
        ;;
      secondmate)
        parent_id=$(receipt_field "$existing" parent_task_id)
        parent_home=$(receipt_field "$existing" parent_home)
        parent_status=$(receipt_field "$existing" parent_status)
        parent_corr=$(receipt_field "$existing" parent_corr)
        if [ "$suffix" = pending ]; then
          [ "$parent_id" = "${FM_PENDING_ROUTE_SECOND_MATE_ID:-}" ] || return 2
          [ "$parent_home" = "${FM_PENDING_ROUTE_PARENT_HOME:-}" ] || return 2
          [ "$parent_status" = "${FM_PENDING_ROUTE_PARENT_STATUS:-}" ] || return 2
          [ "$parent_corr" = "${FM_PENDING_ROUTE_CORR:-}" ] || return 2
        else
          [ -n "$parent_id" ] || return 2
        fi
        case "$parent_home" in /*) ;; *) return 2 ;; esac
        case "$parent_status" in /*) ;; *) return 2 ;; esac
        printf '%s' "$parent_corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 2
        ;;
      *) return 2 ;;
    esac
    RECEIPT_EXISTING_SUFFIX=$suffix
    return 0
  done
  return 1
}

republish_existing_receipt_wake() {
  local existing task outcome status=0 existing_rc release_lock=0
  local pane_meta=${1:-} pane_id=${2:-} pane_window=${3:-} pane_backend=${4:-} pane_incarnation=${5:-}
  FM_WAKE_APPEND_CREATED=0
  if [ "$WAKE_QUEUE_LOCK_HELD" != 1 ]; then
    wake_queue_lock_acquire || return 75
    release_lock=1
  fi
  if receipt_existing_core; then
    if [ "$RECEIPT_EXISTING_SUFFIX" = pending ]; then
      existing=$(receipt_path "$FP" pending)
      task=$(receipt_field "$existing" task_id)
      outcome=$(receipt_field "$existing" outcome)
      if [ -n "$pane_meta" ] \
        && ! replay_pane_idle_publication_valid "$pane_meta" "$pane_id" "$pane_window" "$pane_backend" "$pane_incarnation"; then
        status=75
      else
        fm_wake_append_if_absent_locked FM_WAKE_APPEND_CREATED check "inactive-outcome:$FP" \
          "inactive terminal outcome: task=$task state=$outcome fingerprint=$FP" || status=$?
      fi
    fi
  else
    existing_rc=$?
    [ "$existing_rc" = 1 ] || status=1
  fi
  if [ "$release_lock" = 1 ]; then
    wake_queue_lock_release || status=1
  fi
  return "$status"
}

publish_secondmate_receipt_and_wake() {
  local route_lock status=0 route_invalid=0 existing_rc pending pending_corr pending_parent_id pending_parent_home pending_parent_status
  local release_lock=0
  local pane_meta=${1:-} pane_id=${2:-} pane_window=${3:-} pane_backend=${4:-} pane_incarnation=${5:-}
  FM_WAKE_APPEND_CREATED=0
  if [ "$WAKE_QUEUE_LOCK_HELD" != 1 ]; then
    wake_queue_lock_acquire || return 75
    release_lock=1
  fi
  if [ -L "$FM_HOME" ] || [ ! -d "$FM_HOME" ] || [ -L "$STATE" ] || [ ! -d "$STATE" ]; then
    [ "$release_lock" = 1 ] && wake_queue_lock_release || true
    return 75
  fi
  route_lock=$(fm_pending_reply_secondmate_route_lock_path "$FM_HOME")
  if ! fm_lock_acquire_wait "$route_lock"; then
    [ "$release_lock" = 1 ] && wake_queue_lock_release || true
    return 75
  fi
  KIND=secondmate
  pending=$(receipt_path "$FP" pending)
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    [ -f "$pending" ] && [ ! -L "$pending" ] || route_invalid=1
    if [ "$route_invalid" = 0 ]; then
      pending_corr=$(receipt_field "$pending" parent_corr)
      printf '%s' "$pending_corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || route_invalid=1
    fi
    if [ "$route_invalid" = 0 ] && ! fm_pending_reply_secondmate_route_validate "$FM_HOME" "$pending_corr"; then
      route_invalid=1
    fi
    if [ "$route_invalid" = 0 ]; then
      pending_parent_id=$(receipt_field "$pending" parent_task_id)
      pending_parent_home=$(receipt_field "$pending" parent_home)
      pending_parent_status=$(receipt_field "$pending" parent_status)
      [ "$pending_parent_id" = "$FM_PENDING_ROUTE_SECOND_MATE_ID" ] || route_invalid=1
      [ "$pending_parent_home" = "$FM_PENDING_ROUTE_PARENT_HOME" ] || route_invalid=1
      [ "$pending_parent_status" = "$FM_PENDING_ROUTE_PARENT_STATUS" ] || route_invalid=1
    fi
  elif ! fm_pending_reply_secondmate_route_validate "$FM_HOME"; then
    route_invalid=1
  fi
  if [ "$route_invalid" = 1 ]; then
    fm_lock_release "$route_lock" || true
    [ "$release_lock" = 1 ] && wake_queue_lock_release || true
    return 75
  fi
  if [ -n "$pane_meta" ] \
    && ! replay_pane_idle_publication_valid "$pane_meta" "$pane_id" "$pane_window" "$pane_backend" "$pane_incarnation"; then
    fm_lock_release "$route_lock" || true
    [ "$release_lock" = 1 ] && wake_queue_lock_release || true
    return 75
  fi
  if receipt_existing_core; then
    if [ "$RECEIPT_EXISTING_SUFFIX" = pending ]; then
      fm_wake_append_if_absent_locked FM_WAKE_APPEND_CREATED check "inactive-outcome:$FP" \
        "inactive terminal outcome: task=$ID state=$OUTCOME fingerprint=$FP" || status=$?
    fi
  else
    existing_rc=$?
    if [ "$existing_rc" = 1 ]; then
      if receipt_write; then
        if [ -f "$(receipt_path "$FP" pending)" ]; then
          fm_wake_append_if_absent_locked FM_WAKE_APPEND_CREATED check "inactive-outcome:$FP" \
            "inactive terminal outcome: task=$ID state=$OUTCOME fingerprint=$FP" || status=$?
        fi
      else
        status=$?
      fi
    else
      status=1
    fi
  fi
  fm_lock_release "$route_lock" || status=1
  if [ "$release_lock" = 1 ]; then
    wake_queue_lock_release || status=1
  fi
  return "$status"
}

prepare_pending_receipt() {
  local pending=$1 expected_fp schema task_id incarnation outcome terminal_source terminal_snapshot kind key
  local parent_task_id parent_home parent_status parent_corr
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  FP=${pending##*/}
  case "$FP" in
    *.pending) FP=${FP%.pending} ;;
    *.presented) FP=${FP%.presented} ;;
    *.reported) FP=${FP%.reported} ;;
    *) return 1 ;;
  esac
  case "$FP" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  awk -F= '
    BEGIN {
      allowed["schema"]=1; allowed["fingerprint"]=1; allowed["task_id"]=1
      allowed["incarnation"]=1; allowed["outcome"]=1; allowed["terminal_source"]=1
      allowed["terminal_snapshot"]=1; allowed["kind"]=1; allowed["parent_task_id"]=1
      allowed["parent_home"]=1; allowed["parent_status"]=1; allowed["parent_corr"]=1
      allowed["created_epoch"]=1; valid=1
    }
    /^[^=]+=/ {
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      next
    }
    { valid=0 }
    END {
      for (key in allowed) {
        if (key == "schema" || key == "fingerprint" || key == "task_id" ||
            key == "incarnation" || key == "outcome" || key == "terminal_source" ||
            key == "terminal_snapshot" || key == "kind") {
          if (!(key in seen)) valid=0
        }
      }
      exit !valid
    }
  ' "$pending" 2>/dev/null || return 1
  schema=$(receipt_field "$pending" schema) || return 1
  task_id=$(receipt_field "$pending" task_id) || return 1
  incarnation=$(receipt_field "$pending" incarnation) || return 1
  outcome=$(receipt_field "$pending" outcome) || return 1
  terminal_source=$(receipt_field "$pending" terminal_source) || return 1
  terminal_snapshot=$(receipt_field "$pending" terminal_snapshot) || return 1
  kind=$(receipt_field "$pending" kind) || return 1
  parent_task_id=$(receipt_field "$pending" parent_task_id 2>/dev/null || true)
  parent_home=$(receipt_field "$pending" parent_home 2>/dev/null || true)
  parent_status=$(receipt_field "$pending" parent_status 2>/dev/null || true)
  parent_corr=$(receipt_field "$pending" parent_corr 2>/dev/null || true)
  [ "$schema" = fm-jt-terminal-outcome.v1 ] || return 1
  [ -n "$task_id" ] && [ -n "$incarnation" ] && [ -n "$terminal_source" ] \
    && [ -n "$terminal_snapshot" ] || return 1
  case "$outcome" in done|failed) ;; *) return 1 ;; esac
  case "$kind" in ship|scout)
    [ -z "$parent_task_id" ] && [ -z "$parent_home" ] \
      && [ -z "$parent_status" ] && [ -z "$parent_corr" ] || return 1
    ;;
    secondmate)
      [ -n "$parent_task_id" ] && [ -n "$parent_home" ] && [ -n "$parent_status" ] || return 1
      printf '%s' "$parent_corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 1
      ;;
    *) return 1 ;;
  esac
  expected_fp=$(hash_text "$task_id|$incarnation|$outcome|$terminal_snapshot|$kind") || return 1
  [ "$expected_fp" = "$FP" ] || return 1
  ID=$task_id
  INC=$incarnation
  OUTCOME=$outcome
  SOURCE=$terminal_source
  SNAPSHOT=$terminal_snapshot
  KIND=$kind
  return 0
}

pending_secondmate_report_recorded() {
  local fp=$1 pending kind task_id outcome parent_status parent_corr line
  pending=$(receipt_path "$fp" pending)
  kind=$(receipt_field "$pending" kind) || return 2
  case "$kind" in
    ship|scout) return 1 ;;
    secondmate) ;;
    *) return 2 ;;
  esac
  prepare_pending_receipt "$pending" || return 2
  task_id=$(receipt_field "$pending" task_id) || return 2
  outcome=$(receipt_field "$pending" outcome) || return 2
  parent_status=$(receipt_field "$pending" parent_status) || return 2
  parent_corr=$(receipt_field "$pending" parent_corr) || return 2
  [ -f "$parent_status" ] && [ ! -L "$parent_status" ] || return 1
  line="$outcome [corr=$parent_corr]: inactive terminal outcome replayed: task=$task_id fingerprint=$fp"
  while IFS= read -r existing_line || [ -n "$existing_line" ]; do
    [ "$existing_line" = "$line" ] && return 0
  done < "$parent_status"
  return 1
}

reported_secondmate_receipt_valid() {
  local reported=$1 parent_task_id parent_home parent_status parent_corr
  prepare_pending_receipt "$reported" || return 1
  [ "$KIND" = secondmate ] || return 1
  parent_task_id=$(receipt_field "$reported" parent_task_id) || return 1
  parent_home=$(receipt_field "$reported" parent_home) || return 1
  parent_status=$(receipt_field "$reported" parent_status) || return 1
  parent_corr=$(receipt_field "$reported" parent_corr) || return 1
  [ -n "$parent_task_id" ] && [ -n "$parent_home" ] && [ -n "$parent_status" ] || return 1
  printf '%s' "$parent_corr" | grep -Eq '^[A-Fa-f0-9]{16}$'
}

receipt_candidates() {
  local suffix=$1 seconds=${2:-1}
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 0
  case "$seconds" in ''|*[!0-9]*|0) return 0 ;; esac
  if command -v perl >/dev/null 2>&1; then
    run_bounded_child "$seconds" perl - "$OUTCOME_DIR" "$suffix" <<'PERL'
use strict;
use warnings;
my ($dir, $suffix) = @ARGV;
opendir(my $dh, $dir) or exit 1;
while (defined(my $entry = readdir($dh))) {
  next unless $entry =~ /\.\Q$suffix\E\z/;
  my $path = "$dir/$entry";
  next unless -f $path && !-l $path;
  print "$path\0" or exit 1;
}
closedir($dh) or exit 1;
PERL
  else
    return 124
  fi
}

repair_reported_secondmate_routes() {
  local scan_deadline=$1 reported kind corr parent_task_id parent_home parent_status remaining status=0
  local cursor='' cursor_found=0 started=1 pass base last processed=0 cursor_tmp candidate_tmp enum_rc enum_deferred=0
  local candidate_pending=0 candidate_retain=0 item_status batch_consumed=0 batch_complete=1 retry_tmp=
  MAINTENANCE_ENUM_DEFERRED=0
  MAINTENANCE_ENUM_FAILED=0
  MAINTENANCE_ITEMS_PROCESSED=0
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 0
  remaining=$(budget_remaining_secs "$scan_deadline")
  [ "$remaining" -gt 0 ] || return 1
  FM_LOCK_WAIT_SECS="$remaining" fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  candidate_tmp=$(mktemp "$STATE/.inactive-outcome-candidates.XXXXXX") || {
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 1
  }
  [ -f "$candidate_tmp" ] && [ ! -L "$candidate_tmp" ] || {
    rm -f "$candidate_tmp"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 1
  }
  if [ -e "$REPORTED_ROUTE_PENDING" ] || [ -L "$REPORTED_ROUTE_PENDING" ]; then
    [ -f "$REPORTED_ROUTE_PENDING" ] && [ ! -L "$REPORTED_ROUTE_PENDING" ] || {
      rm -f "$candidate_tmp"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
      return 1
    }
    if [ -s "$REPORTED_ROUTE_PENDING" ]; then
      inactive_copy_nul_prefix "$REPORTED_ROUTE_PENDING" "$candidate_tmp" || {
        rm -f "$candidate_tmp"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
        return 1
      }
      candidate_pending=1
      candidate_retain=1
    else
      rm -f "$REPORTED_ROUTE_PENDING" || {
        rm -f "$candidate_tmp"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
        return 1
      }
    fi
  fi
  cursor=$(cat "$REPORTED_ROUTE_CURSOR" 2>/dev/null || true)
  case "$cursor" in
    '') ;;
    *.reported) case "$cursor" in *[!A-Za-z0-9._-]*) cursor=;; esac ;;
    *) cursor=;;
  esac
  if [ -n "$cursor" ] && { [ ! -f "$OUTCOME_DIR/$cursor" ] || [ -L "$OUTCOME_DIR/$cursor" ]; }; then
    cursor=
  fi
  if [ "$candidate_pending" = 1 ]; then
    cursor=
    cursor_found=1
    started=1
  else
    [ -n "$cursor" ] && started=0
  fi
  for pass in 1 2; do
    [ "$candidate_pending" = 0 ] || [ "$pass" = 1 ] || break
    if [ "$pass" = 2 ]; then
      [ -n "$cursor" ] || break
      started=1
    fi
    remaining=$(budget_remaining_secs "$scan_deadline")
    [ "$remaining" -gt 0 ] || { status=1; break; }
    batch_consumed=0
    batch_complete=1
    enum_rc=0
    if [ "$candidate_pending" = 1 ]; then
      :
    else
      receipt_candidates reported "$remaining" > "$candidate_tmp" || enum_rc=$?
    fi
    if [ "$enum_rc" -ne 0 ]; then
      status=1
      if [ "$enum_rc" = 124 ]; then
        MAINTENANCE_ENUM_DEFERRED=1
        enum_deferred=1
        batch_complete=0
      else
        MAINTENANCE_ENUM_FAILED=1
      fi
    fi
    while [ "$MAINTENANCE_ENUM_FAILED" = 0 ] && IFS= read -r -d '' reported; do
      batch_consumed=$((batch_consumed + 1))
      case "$reported" in "$OUTCOME_DIR"/*/*) continue ;; esac
      base=${reported##*/}
      if [ "$pass" = 1 ] && [ -n "$cursor" ] && [ "$started" = 0 ]; then
        if [ "$base" = "$cursor" ]; then
          started=1
          cursor_found=1
        fi
        continue
      fi
      if [ "$pass" = 2 ] && [ "$processed" -gt 0 ] && [ -n "$cursor" ] \
        && [ "$cursor_found" = 1 ] && [ "$base" = "$cursor" ]; then
        break
      fi
      remaining=$(budget_remaining_secs "$scan_deadline")
      if [ "$remaining" -le 0 ]; then
        status=1
        batch_complete=0
        break 2
      fi
      [ -f "$reported" ] && [ ! -L "$reported" ] || { status=1; continue; }
      kind=$(receipt_field "$reported" kind 2>/dev/null || true)
      item_status=0
      case "$kind" in
        ship|scout) : ;;
        secondmate)
          if ! reported_secondmate_receipt_valid "$reported"; then
            item_status=1
          else
            corr=$(receipt_field "$reported" parent_corr)
            parent_task_id=$(receipt_field "$reported" parent_task_id)
            parent_home=$(receipt_field "$reported" parent_home)
            parent_status=$(receipt_field "$reported" parent_status)
            FM_LOCK_WAIT_SECS="$remaining" fm_pending_reply_secondmate_route_clear_reported \
              "$FM_HOME" "$corr" "$parent_task_id" "$parent_home" "$parent_status" || item_status=1
          fi
          ;;
        *) item_status=1 ;;
      esac
      if [ "$item_status" != 0 ]; then
        status=1
        candidate_retain=1
        if [ -z "$retry_tmp" ]; then
          retry_tmp=$(mktemp "$STATE/.inactive-outcome-retry.XXXXXX") || {
            MAINTENANCE_ENUM_FAILED=1
            break 2
          }
          [ -f "$retry_tmp" ] && [ ! -L "$retry_tmp" ] || {
            rm -f "$retry_tmp"
            retry_tmp=
            MAINTENANCE_ENUM_FAILED=1
            break 2
          }
        fi
        inactive_append_nul_value "$retry_tmp" "$reported" || {
          MAINTENANCE_ENUM_FAILED=1
          break 2
        }
        continue
      fi
      last=$base
      processed=$((processed + 1))
      if [ "$processed" -ge "$REPORTED_ROUTE_REPAIR_LIMIT" ]; then
        batch_complete=0
        break 2
      fi
    done < "$candidate_tmp"
    [ "$enum_deferred" = 0 ] || break
  done
  if [ "$candidate_pending" = 1 ] && [ "$batch_complete" = 1 ] \
    && [ "$MAINTENANCE_ENUM_FAILED" = 0 ]; then
    rm -f "$REPORTED_ROUTE_PENDING" || status=1
  elif [ "$enum_deferred" = 1 ] || [ "$candidate_retain" = 1 ] || [ "$candidate_pending" = 1 ]; then
    inactive_persist_nul_suffix "$candidate_tmp" "$REPORTED_ROUTE_PENDING" "$batch_consumed" "$retry_tmp" || status=1
  fi
  rm -f "$candidate_tmp" || status=1
  [ -z "$retry_tmp" ] || rm -f "$retry_tmp" || status=1
  if [ "$processed" -gt 0 ]; then
    if cursor_tmp=$(mktemp "$STATE/.reported-route-repair.cursor.XXXXXX"); then
      if [ ! -f "$cursor_tmp" ] || [ -L "$cursor_tmp" ] \
        || ! printf '%s\n' "$last" > "$cursor_tmp" \
        || ! mv -f "$cursor_tmp" "$REPORTED_ROUTE_CURSOR"; then
        status=1
        rm -f "$cursor_tmp"
      fi
    else
      status=1
    fi
  fi
  MAINTENANCE_ITEMS_PROCESSED=$processed
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

republish_pending_receipt() {
  local pending=$1
  prepare_pending_receipt "$pending" || return 1
  case "$KIND" in
    ship|scout)
      republish_existing_receipt_wake
      ;;
    secondmate)
      publish_secondmate_receipt_and_wake
      ;;
  esac
}

republish_pending_receipts() {
  local scan_deadline=$1 pending remaining status=0
  local cursor='' cursor_found=0 pass started=1
  local base last='' processed=0 cursor_tmp candidate_tmp enum_rc enum_deferred=0
  local candidate_pending=0 candidate_retain=0 batch_consumed=0 batch_complete=1 retry_tmp=
  local LC_ALL=C
  MAINTENANCE_ENUM_DEFERRED=0
  MAINTENANCE_ENUM_FAILED=0
  MAINTENANCE_RETRYABLE=0
  MAINTENANCE_ITEMS_PROCESSED=0
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 0
  candidate_tmp=$(mktemp "$STATE/.inactive-outcome-candidates.XXXXXX") || return 1
  [ -f "$candidate_tmp" ] && [ ! -L "$candidate_tmp" ] || {
    rm -f "$candidate_tmp"
    return 1
  }
  if [ -e "$PENDING_RECEIPT_PENDING" ] || [ -L "$PENDING_RECEIPT_PENDING" ]; then
    [ -f "$PENDING_RECEIPT_PENDING" ] && [ ! -L "$PENDING_RECEIPT_PENDING" ] || {
      rm -f "$candidate_tmp"
      return 1
    }
    if [ -s "$PENDING_RECEIPT_PENDING" ]; then
      inactive_copy_nul_prefix "$PENDING_RECEIPT_PENDING" "$candidate_tmp" || {
        rm -f "$candidate_tmp"
        return 1
      }
      candidate_pending=1
      candidate_retain=1
    else
      rm -f "$PENDING_RECEIPT_PENDING" || {
        rm -f "$candidate_tmp"
        return 1
      }
    fi
  fi
  cursor=$(cat "$PENDING_RECEIPT_CURSOR" 2>/dev/null || true)
  case "$cursor" in
    '') ;;
    *.pending)
      base=${cursor%.pending}
      case "$base" in ''|*[!A-Fa-f0-9]*) cursor=;; esac
      ;;
    *) cursor=;;
  esac
  if [ "$candidate_pending" = 1 ]; then
    cursor=
    cursor_found=1
    started=1
  else
    [ -n "$cursor" ] && started=0
  fi
  for pass in 1 2; do
    [ "$candidate_pending" = 0 ] || [ "$pass" = 1 ] || break
    if [ "$pass" = 2 ]; then
      [ -n "$cursor" ] || break
      started=1
    fi
    remaining=$(budget_remaining_secs "$scan_deadline")
    [ "$remaining" -gt 0 ] || { status=1; break; }
    batch_consumed=0
    batch_complete=1
    enum_rc=0
    if [ "$candidate_pending" = 1 ]; then
      :
    else
      receipt_candidates pending "$remaining" > "$candidate_tmp" || enum_rc=$?
    fi
    if [ "$enum_rc" -ne 0 ]; then
      status=1
      if [ "$enum_rc" = 124 ]; then
        MAINTENANCE_ENUM_DEFERRED=1
        enum_deferred=1
        batch_complete=0
      else
        MAINTENANCE_ENUM_FAILED=1
      fi
    fi
    while [ "$MAINTENANCE_ENUM_FAILED" = 0 ] && IFS= read -r -d '' pending; do
      batch_consumed=$((batch_consumed + 1))
      case "$pending" in "$OUTCOME_DIR"/*/*) continue ;; esac
      base=${pending##*/}
      if [ "$pass" = 1 ] && [ -n "$cursor" ] && [ "$started" = 0 ]; then
        if [ "$base" = "$cursor" ]; then
          started=1
          cursor_found=1
          continue
        fi
        continue
      fi
      if [ "$pass" = 2 ] && [ "$processed" -gt 0 ] && [ -n "$cursor" ] \
        && [ "$cursor_found" = 1 ] && [ "$base" = "$cursor" ]; then
        break
      fi
      remaining=$(budget_remaining_secs "$scan_deadline")
      if [ "$remaining" -le 0 ]; then
        status=1
        batch_complete=0
        break 2
      fi
      if FM_LOCK_WAIT_SECS="$remaining" republish_pending_receipt "$pending"; then
        if [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
          printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$ID" "$OUTCOME" "$FP"
        fi
      else
        enum_rc=$?
        status=1
        if [ "$enum_rc" = 75 ]; then
          MAINTENANCE_RETRYABLE=1
          candidate_retain=1
          if [ -z "$retry_tmp" ]; then
            retry_tmp=$(mktemp "$STATE/.inactive-outcome-retry.XXXXXX") || {
              MAINTENANCE_ENUM_FAILED=1
              break 2
            }
            [ -f "$retry_tmp" ] && [ ! -L "$retry_tmp" ] || {
              rm -f "$retry_tmp"
              retry_tmp=
              MAINTENANCE_ENUM_FAILED=1
              break 2
            }
          fi
          inactive_append_nul_value "$retry_tmp" "$pending" || {
            MAINTENANCE_ENUM_FAILED=1
            break 2
          }
          continue
        fi
        MAINTENANCE_ENUM_FAILED=1
        break 2
      fi
      last=$base
      processed=$((processed + 1))
      if [ "$processed" -ge "$PENDING_RECEIPT_REPUBLISH_LIMIT" ]; then
        batch_complete=0
        break 2
      fi
    done < "$candidate_tmp"
    [ "$enum_deferred" = 0 ] || break
  done
  if [ "$candidate_pending" = 1 ] && [ "$batch_complete" = 1 ] \
    && [ "$MAINTENANCE_ENUM_FAILED" = 0 ]; then
    rm -f "$PENDING_RECEIPT_PENDING" || status=1
  elif [ "$enum_deferred" = 1 ] || [ "$candidate_retain" = 1 ] || [ "$candidate_pending" = 1 ]; then
    inactive_persist_nul_suffix "$candidate_tmp" "$PENDING_RECEIPT_PENDING" "$batch_consumed" "$retry_tmp" || status=1
  fi
  rm -f "$candidate_tmp" || status=1
  [ -z "$retry_tmp" ] || rm -f "$retry_tmp" || status=1
  if [ "$processed" -gt 0 ]; then
    if cursor_tmp=$(mktemp "$STATE/.pending-receipt-republish.cursor.XXXXXX"); then
      if [ ! -f "$cursor_tmp" ] || [ -L "$cursor_tmp" ] \
        || ! printf '%s\n' "$last" > "$cursor_tmp" \
        || ! mv -f "$cursor_tmp" "$PENDING_RECEIPT_CURSOR"; then
        status=1
        rm -f "$cursor_tmp"
      fi
    else
      status=1
    fi
  fi
  MAINTENANCE_ITEMS_PROCESSED=$processed
  return "$status"
}

read_incarnation() { fm_pane_idle_read_incarnation "$@"; }

surface_retry_valid() {
  awk -F= '
    BEGIN {
      allowed["schema"]=1; allowed["task"]=1; allowed["snapshot"]=1
      allowed["spawn_incarnation"]=1; allowed["tasktmp"]=1
      allowed["window"]=1; allowed["worktree"]=1; allowed["wake_key"]=1
      allowed["wake_published"]=1
      required["schema"]=1; required["task"]=1; required["snapshot"]=1
      required["spawn_incarnation"]=1; required["tasktmp"]=1
      required["window"]=1; required["worktree"]=1; required["wake_key"]=1
      required["wake_published"]=1
      valid=1
    }
    /^[^=]+=/ {
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      values[key]=substr($0, index($0, "=") + 1)
      next
    }
    { valid=0 }
    END {
      for (key in required) if (!(key in seen)) valid=0
      exit !(valid && values["schema"] == "fm-hb-surface-retry.v1" && values["task"] != "" && values["snapshot"] != "" && values["wake_key"] != "" && values["wake_published"] ~ /^[012]$/)
    }
  ' "$1" 2>/dev/null
}

surface_retry_matches_current() {
  local retry=$1 id=$2 meta=$3 status_file current_snapshot saved_snapshot saved_spawn
  local current_spawn current_tasktmp current_window current_worktree rc
  [ -f "$retry" ] && [ ! -L "$retry" ] || return 1
  surface_retry_valid "$retry" || return 1
  [ "$(meta_value_unique "$retry" task 2>/dev/null)" = "$id" ] || return 1
  status_file="$STATE/$id.status"
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
  current_snapshot=$(awk 'NF { line=$0 } END { if (line == "") exit 1; print line }' "$status_file" 2>/dev/null) || return 1
  saved_snapshot=$(meta_value_unique "$retry" snapshot 2>/dev/null) || return 1
  [ "$saved_snapshot" = "$current_snapshot" ] || return 1
  saved_spawn=$(meta_value_unique "$retry" spawn_incarnation 2>/dev/null) || return 1
  if current_spawn=$(meta_value_unique "$meta" spawn_incarnation 2>/dev/null); then
    [ "$saved_spawn" = "$current_spawn" ] || return 1
    return 0
  fi
  rc=$?
  [ "$rc" = 1 ] || return 1
  [ -z "$saved_spawn" ] || return 1
  current_tasktmp=$(meta_value "$meta" tasktmp)
  current_window=$(meta_value "$meta" window)
  current_worktree=$(meta_value "$meta" worktree)
  [ "$(meta_value_unique "$retry" tasktmp 2>/dev/null)" = "$current_tasktmp" ] || return 1
  [ "$(meta_value_unique "$retry" window 2>/dev/null)" = "$current_window" ] || return 1
  [ "$(meta_value_unique "$retry" worktree 2>/dev/null)" = "$current_worktree" ] || return 1
}

surface_retry_mark_published() {
  local retry=$1 tmp line seen=0
  tmp=$(mktemp "$STATE/.hb-surface-retry.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      wake_published=*) printf 'wake_published=1\n'; seen=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$retry" > "$tmp" || { rm -f "$tmp"; return 1; }
  [ "$seen" = 1 ] || printf 'wake_published=1\n' >> "$tmp"
  [ ! -L "$retry" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$retry" || { rm -f "$tmp"; return 1; }
}

surface_retry_published_current() {
  local id=$1 meta=$2 retry=$3 wake_key=$4 published fp suffix receipt_state=
  if [ -L "$retry" ] || [ -e "$retry" ]; then
    [ -f "$retry" ] && [ ! -L "$retry" ] && surface_retry_valid "$retry" || return 2
  else
    return 1
  fi
  surface_retry_matches_current "$retry" "$id" "$meta" || return 1
  [ "$(meta_value_unique "$retry" wake_key 2>/dev/null)" = "$wake_key" ] || return 2
  published=$(meta_value_unique "$retry" wake_published 2>/dev/null) || return 2
  fp=${wake_key#inactive-outcome:}
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  for suffix in pending presented reported; do
    receipt_state=
    [ ! -L "$(receipt_path "$fp" "$suffix")" ] || return 2
    if [ -f "$(receipt_path "$fp" "$suffix")" ]; then
      receipt_state=$suffix
      break
    fi
  done
  case "$published" in
    1) [ -n "$receipt_state" ] || return 1; return 0 ;;
    2)
      [ -n "$receipt_state" ] || return 1
      case "$receipt_state" in
        presented|reported)
          surface_retry_mark_published "$retry" || return 2
          return 0
          ;;
        pending)
          [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 1
          awk -F '\t' -v wanted="$wake_key" '$4 == wanted { found=1; exit } END { exit !found }' \
            "$FM_WAKE_QUEUE" 2>/dev/null || return 1
          surface_retry_mark_published "$retry" || return 2
          return 0
          ;;
        *) return 2 ;;
      esac
      ;;
    0) ;;
    *) return 2 ;;
  esac
  [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' -v wanted="$wake_key" '$4 == wanted { found=1; exit } END { exit !found }' \
    "$FM_WAKE_QUEUE" 2>/dev/null || return 1
  surface_retry_mark_published "$retry" || return 2
}

terminal_outcome_surfaced() {
  local id=$1 meta=$2 outcome=$3 wake_key=${4:-}
  local key raw marker retry marker_snapshot marker_spawn current_snapshot retry_status
  local current_spawn current_tasktmp current_window current_worktree status_file
  key=$(printf '%s' "$id" | tr ':/.' '___')
  raw="$STATE/.hb-surfaced-$key"
  marker="$STATE/.hb-terminal-surfaced-$key"
  retry="$STATE/.hb-surface-retry-$key"
  if [ -n "$wake_key" ]; then
    surface_retry_published_current "$id" "$meta" "$retry" "$wake_key" || retry_status=$?
    case "${retry_status:-0}" in
      0) return 0 ;;
      1) ;;
      *) return 2 ;;
    esac
  fi
  [ -f "$raw" ] && [ ! -L "$raw" ] || return 1
  raw=$(cat "$raw" 2>/dev/null || true)
  [ -n "$raw" ] || return 1
  case "$raw" in
    done:*|failed:*) ;;
    *) return 1 ;;
  esac
  [ "${raw%%:*}" = "$outcome" ] || return 1
  status_file="$STATE/$id.status"
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
  current_snapshot=$(awk 'NF { line=$0 } END { if (line == "") exit 1; print line }' "$status_file" 2>/dev/null) || return 1
  [ "$raw" = "$current_snapshot" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  awk -F= '
    BEGIN {
      allowed["schema"]=1; allowed["snapshot"]=1; allowed["spawn_incarnation"]=1
      allowed["tasktmp"]=1; allowed["window"]=1; allowed["worktree"]=1
      required["schema"]=1; required["snapshot"]=1; required["spawn_incarnation"]=1
      required["tasktmp"]=1; required["window"]=1; required["worktree"]=1
      valid=1
    }
    /^[^=]+=/{
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      values[key]=substr($0, index($0, "=") + 1)
      next
    }
    { valid=0 }
    END {
      for (key in required) if (!(key in seen)) valid=0
      exit !(valid && values["schema"] == "fm-hb-terminal-surfaced.v1")
    }
  ' "$marker" 2>/dev/null || return 1
  marker_snapshot=$(meta_value_unique "$marker" snapshot 2>/dev/null) || return 1
  [ "$marker_snapshot" = "$raw" ] || return 1
  marker_spawn=$(meta_value_unique "$marker" spawn_incarnation 2>/dev/null) || return 1
  current_spawn=
  if current_spawn=$(meta_value_unique "$meta" spawn_incarnation 2>/dev/null); then
    [ "$marker_spawn" = "$current_spawn" ] || return 1
  else
    [ -z "$marker_spawn" ] || return 1
    current_tasktmp=$(meta_value "$meta" tasktmp)
    current_window=$(meta_value "$meta" window)
    current_worktree=$(meta_value "$meta" worktree)
    [ "$(meta_value_unique "$marker" tasktmp 2>/dev/null)" = "$current_tasktmp" ] || return 1
    [ "$(meta_value_unique "$marker" window 2>/dev/null)" = "$current_window" ] || return 1
    [ "$(meta_value_unique "$marker" worktree 2>/dev/null)" = "$current_worktree" ] || return 1
  fi
  return 0
}

replay_surface_retry_write() {
  local id=$1 meta=$2 snapshot=$3 incarnation=$4 key=$5 published=$6
  local retry tmp tasktmp window worktree marker_incarnation explicit_incarnation rc
  case "$published" in 0|1|2) ;; *) return 1 ;; esac
  tasktmp=$(meta_value "$meta" tasktmp)
  window=$(meta_value "$meta" window)
  worktree=$(meta_value "$meta" worktree)
  if explicit_incarnation=$(meta_value_unique "$meta" spawn_incarnation); then
    marker_incarnation=$incarnation
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    marker_incarnation=
  fi
  retry="$STATE/.hb-surface-retry-$(printf '%s' "$id" | tr ':/.' '___')"
  if [ -e "$retry" ]; then
    [ -f "$retry" ] && [ ! -L "$retry" ] && surface_retry_valid "$retry" || return 1
    if surface_retry_matches_current "$retry" "$id" "$meta"; then
      [ "$(meta_value_unique "$retry" wake_key 2>/dev/null)" = "$key" ] || return 2
    fi
  fi
  tmp=$(mktemp "$STATE/.hb-surface-retry.XXXXXX") || return 1
  if ! printf 'schema=fm-hb-surface-retry.v1\ntask=%s\nsnapshot=%s\nspawn_incarnation=%s\ntasktmp=%s\nwindow=%s\nworktree=%s\nwake_key=%s\nwake_published=%s\n' \
    "$id" "$snapshot" "$marker_incarnation" "$tasktmp" "$window" "$worktree" "$key" "$published" > "$tmp" \
    || ! mv -f "$tmp" "$retry"; then
    rm -f "$tmp"
    return 1
  fi
}

replay_surface_marker() {
  local id=$1 meta=$2 snapshot=$3 incarnation=$4 wake_key=$5 key raw marker retry tmp tasktmp window worktree
  local marker_incarnation explicit_incarnation rc
  key=$(printf '%s' "$id" | tr ':/.' '___')
  raw="$STATE/.hb-surfaced-$key"
  marker="$STATE/.hb-terminal-surfaced-$key"
  retry="$STATE/.hb-surface-retry-$key"
  tasktmp=$(meta_value "$meta" tasktmp)
  window=$(meta_value "$meta" window)
  worktree=$(meta_value "$meta" worktree)
  if explicit_incarnation=$(meta_value_unique "$meta" spawn_incarnation); then
    marker_incarnation=$incarnation
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    marker_incarnation=
  fi
  replay_surface_retry_write "$id" "$meta" "$snapshot" "$incarnation" "$wake_key" 1 || return 1
  tmp=$(mktemp "$STATE/.hb-terminal-surfaced.XXXXXX") || return 1
  if ! printf 'schema=fm-hb-terminal-surfaced.v1\nsnapshot=%s\nspawn_incarnation=%s\ntasktmp=%s\nwindow=%s\nworktree=%s\n' \
    "$snapshot" "$marker_incarnation" "$tasktmp" "$window" "$worktree" > "$tmp" \
    || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
  tmp=$(mktemp "$STATE/.hb-surfaced.XXXXXX") || return 1
  if ! printf '%s' "$snapshot" > "$tmp" || ! mv -f "$tmp" "$raw"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$retry" || return 1
}

replay_receipt_exists() {
  local suffix path
  for suffix in pending presented reported; do
    path=$(receipt_path "$FP" "$suffix")
    [ -f "$path" ] && [ ! -L "$path" ] && return 0
  done
  return 1
}

child_cleanup() {
  local status=$?
  if [ "$WAKE_QUEUE_LOCK_HELD" = 1 ]; then
    wake_queue_lock_release || true
  fi
  if [ "$CHILD_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CHILD_LOCK" || true
  fi
  exit "$status"
}

reconcile_child() {
  local id=$1 meta="$STATE/$1.meta" kind backend window now activity age line outcome source
  local snapshot token key route_rc state_tmp state_rc existing_rc surface_status publication_status state_timeout scan_remaining
  valid_task_id "$id" || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  case "$kind" in ''|ship|scout) ;; *) return 0 ;; esac
  herdr_identity_allowed "$meta" || return 0
  CHILD_LOCK="$STATE/.spawn-$id.lock"
  FM_LOCK_WAIT_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_LOCK_WAIT_SECS:-30}" 30 0 300)
  fm_lock_acquire_wait "$CHILD_LOCK" || return 75
  CHILD_LOCK_HELD=1
  trap child_cleanup EXIT INT TERM
  # Teardown/relaunch can replace or remove metadata only after the same lock is
  # released. Re-read it after acquiring the lock so the snapshot belongs to the
  # current incarnation.
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  herdr_identity_allowed "$meta" || return 0
  now=$(date +%s)
  activity=$(latest_activity "$id")
  [ "$activity" -gt 0 ] || return 0
  age=$((now - activity))
  [ "$age" -ge "$RECONCILE_SECS" ] || return 0
  if ! wake_queue_lock_acquire; then
    return 75
  fi
  state_tmp=$(mktemp "$STATE/.$id.inactive-state.XXXXXX") || return 1
  [ -f "$state_tmp" ] && [ ! -L "$state_tmp" ] || { rm -f "$state_tmp"; return 1; }
  state_timeout=$(bounded_secs "${FM_INACTIVE_OUTCOME_STATE_TIMEOUT_SECS:-10}" 10 1 300)
  scan_remaining=${FM_INACTIVE_OUTCOME_SCAN_REMAINING_SECS:-}
  case "$scan_remaining" in
    ''|*[!0-9]*) scan_remaining=;;
    *)
      while [ "${scan_remaining#0}" != "$scan_remaining" ]; do scan_remaining=${scan_remaining#0}; done
      [ -n "$scan_remaining" ] || scan_remaining=0
      [ "$scan_remaining" -gt 0 ] && [ "$scan_remaining" -lt "$state_timeout" ] \
        && state_timeout=$scan_remaining
      ;;
  esac
  state_rc=0
  export FM_CREW_STATE_NM_TIMEOUT="$state_timeout"
  run_bounded_child "$state_timeout" "$FM_CREW_STATE_BIN" "$id" \
    > "$state_tmp" 2>/dev/null || state_rc=$?
  line=
  if [ "$state_rc" -eq 0 ]; then
    line=$(cat "$state_tmp" 2>/dev/null) || state_rc=$?
  fi
  rm -f "$state_tmp" || [ "$state_rc" -ne 0 ] || state_rc=1
  [ "$state_rc" -eq 0 ] || return "$state_rc"
  case "$line" in *$'\n'*) return 0 ;; esac
  case "$line" in
    state:\ done\ *|state:\ failed\ *) ;;
    *) return 0 ;;
  esac
  case "$line" in
    *'source: none'*|*'source: status-log'*|*'state: unknown'*|*'occupancy unknown'*) return 0 ;;
  esac
  outcome=${line#state: }
  outcome=${outcome%% *}
  case "$outcome" in done|failed) ;; *) return 0 ;; esac
  source=$(printf '%s\n' "$line" | sed -n 's/.*source: \([^ ·]*\).*/\1/p')
  [ -n "$source" ] && [ "$source" != none ] || return 0
  snapshot=$(single_line "$line")
  INC=$(read_incarnation "$meta" "$id") || return 0
  window=$(meta_value_unique "$meta" window) || return 0
  if backend=$(meta_value_unique "$meta" backend 2>/dev/null); then
    :
  else
    state_rc=$?
    [ "$state_rc" = 1 ] || return 0
    backend=tmux
  fi
  fm_pane_idle_proof_valid "$STATE" "$meta" "$id" "$window" "$backend" "$INC" "$RECONCILE_SECS" || return 0
  ID=$id
  OUTCOME=$outcome
  SNAPSHOT=$snapshot
  SOURCE=$source
  KIND=${kind:-ship}
  is_secondmate_home
  route_rc=$?
  case "$route_rc" in
    0|1) ;;
    *) return 0 ;;
  esac
  [ "$route_rc" = 0 ] && KIND=secondmate
  FP=$(hash_text "$id|$INC|$outcome|$snapshot|$KIND") || return 1
  surface_status=0
  terminal_outcome_surfaced "$id" "$meta" "$outcome" "inactive-outcome:$FP" || surface_status=$?
  case "$surface_status" in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  if [ "$route_rc" = 0 ]; then
    key="inactive-outcome:$FP"
    replay_surface_retry_write "$id" "$meta" "$snapshot" "$INC" "$key" 2 || return 1
    publish_secondmate_receipt_and_wake "$meta" "$id" "$window" "$backend" "$INC" \
      || { publication_status=$?; return "$publication_status"; }
    if replay_receipt_exists; then
      replay_surface_marker "$id" "$meta" "$snapshot" "$INC" "$key" || return 1
    fi
    if [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
      printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$id" "$outcome" "$FP"
    fi
    return 0
  fi
  if receipt_existing_core; then
    key="inactive-outcome:$FP"
    replay_surface_retry_write "$id" "$meta" "$snapshot" "$INC" "$key" 2 || return 1
    if [ "$RECEIPT_EXISTING_SUFFIX" = pending ]; then
      republish_existing_receipt_wake "$meta" "$id" "$window" "$backend" "$INC" \
        || { publication_status=$?; return "$publication_status"; }
      if [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
        printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$id" "$outcome" "$FP"
      fi
    fi
    replay_surface_marker "$id" "$meta" "$snapshot" "$INC" "$key" || return 1
    return 0
  else
    existing_rc=$?
    [ "$existing_rc" = 1 ] || return 1
  fi
  key="inactive-outcome:$FP"
  replay_surface_retry_write "$id" "$meta" "$snapshot" "$INC" "$key" 2 || return 1
  publish_receipt_and_wake "$meta" "$id" "$window" "$backend" "$INC" \
    || { publication_status=$?; return "$publication_status"; }
  replay_surface_marker "$id" "$meta" "$snapshot" "$INC" "$key" || return 1
  if [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
    printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$id" "$outcome" "$FP"
  fi
  return 0
}

ack_receipt() {  # <inactive-outcome:fingerprint>
  local key=$1 row=${2:-} owner_required=${3:-1} expected_generation=${4:-}
  local fp rec id kind incarnation outcome snapshot expected_fp parent_task_id parent_home parent_status corr line target existing existing_kind existing_corr claim_state
  [ -n "$row" ] || return 2
  case "$owner_required" in 0|1) ;; *) return 2 ;; esac
  [ "$owner_required" = 0 ] || drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 0 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  claim_state=$(claim_validate "$(claim_path "$fp")" "$fp" "$row") || return 2
  [ "$claim_state" = presented ] || return 2
  [ "$(claim_binary_field "$(claim_path "$fp")" output_started 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$(claim_path "$fp")" output_emitted 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$(claim_path "$fp")" output_complete 2>/dev/null || true)" = 1 ] || return 2
  [ "$(claim_binary_field "$(claim_path "$fp")" output_confirmed 2>/dev/null || true)" = 1 ] || return 2
  if [ "$(claim_field "$(claim_path "$fp")" defer_ack 2>/dev/null || true)" = 1 ]; then
    [ "$(claim_binary_field "$(claim_path "$fp")" caller_confirmed 2>/dev/null || true)" = 1 ] || return 2
  fi
  if [ "$owner_required" = 0 ]; then
    claim_validate_caller_owner "$(claim_path "$fp")" "$expected_generation" || return 2
  fi
  rec=$(receipt_path "$fp" pending)
  [ ! -L "$rec" ] || return 2
  if [ ! -e "$rec" ]; then
    for existing in "$(receipt_path "$fp" presented)" "$(receipt_path "$fp" reported)"; do
      [ ! -L "$existing" ] || return 2
      if [ -e "$existing" ]; then
        [ -f "$existing" ] || return 2
        prepare_pending_receipt "$existing" || return 2
        existing_kind=$KIND
        if [ "$existing_kind" = secondmate ]; then
          reported_secondmate_receipt_valid "$existing" || return 2
          existing_corr=$(receipt_field "$existing" parent_corr)
          fm_pending_reply_secondmate_route_clear_reported "$FM_HOME" "$existing_corr" \
            "$(receipt_field "$existing" parent_task_id)" \
            "$(receipt_field "$existing" parent_home)" \
            "$(receipt_field "$existing" parent_status)" || return 2
        fi
        claim_remove "$key" "$row" "$owner_required" "$expected_generation" || return 2
        fm_wake_remove_key_locked "$key" || return 2
        return 1
      fi
    done
    return 2
  fi
  [ -f "$rec" ] || return 2
  prepare_pending_receipt "$rec" || return 2
  id=$(receipt_field "$rec" task_id)
  kind=$(receipt_field "$rec" kind)
  incarnation=$(receipt_field "$rec" incarnation)
  parent_task_id=$(receipt_field "$rec" parent_task_id)
  outcome=$(receipt_field "$rec" outcome)
  snapshot=$(receipt_field "$rec" terminal_snapshot)
  expected_fp=$(hash_text "$id|$incarnation|$outcome|$snapshot|$kind") || return 2
  [ "$expected_fp" = "$fp" ] || return 2
  case "$kind" in ship|scout|secondmate) ;; *) return 2 ;; esac
  if [ "$kind" = secondmate ]; then
    parent_home=$(receipt_field "$rec" parent_home)
    parent_status=$(receipt_field "$rec" parent_status)
    corr=$(receipt_field "$rec" parent_corr)
    [ -n "$parent_task_id" ] || return 2
    secondmate_ack_report "$FM_HOME" "$parent_task_id" "$parent_home" \
      "$parent_status" "$corr" "$outcome" "$id" "$fp" || return 2
    target=$(receipt_path "$fp" reported)
  else
    target=$(receipt_path "$fp" presented)
  fi
  [ ! -L "$target" ] || return 2
  if [ -e "$target" ]; then
    [ -f "$target" ] || return 2
    [ "$(receipt_field "$target" fingerprint)" = "$fp" ] || return 2
    if [ "$kind" = secondmate ]; then
      reported_secondmate_receipt_valid "$target" || return 2
      fm_pending_reply_secondmate_route_clear_reported "$FM_HOME" "$corr" \
        "$parent_task_id" "$parent_home" "$parent_status" || return 2
    fi
    rm -f "$rec" || return 2
    claim_remove "$key" "$row" "$owner_required" "$expected_generation" || return 2
    fm_wake_remove_key_locked "$key" || return 2
    return 1
  fi
  mv "$rec" "$target" || return 2
  if [ "$kind" = secondmate ]; then
    fm_pending_reply_secondmate_route_clear_reported "$FM_HOME" "$corr" \
      "$parent_task_id" "$parent_home" "$parent_status" || return 2
  fi
  claim_remove "$key" "$row" "$owner_required" "$expected_generation" || return 2
  fm_wake_remove_key_locked "$key" || return 2
  return 0
}

confirm_receipt() {
  local status=0 caller_pid=${PPID:-}
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 2
  claim_mark_confirmed "$1" "$2" 0 "$caller_pid" || status=$?
  if [ "$status" = 0 ]; then
    ack_receipt "$1" "$2" 0 "$caller_pid" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=2
  return "$status"
}

caller_output_complete() {
  local status=0 caller_pid=${3:-${PPID:-}}
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 2
  claim_mark_output_complete "$1" "$2" 0 "$caller_pid" || status=$?
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=2
  return "$status"
}

secondmate_ack_report() {  # <secondmate-home> <parent-id> <parent-home> <parent-status> <corr> <outcome> <task-id> <fingerprint>
  local secondmate_home=$1 parent_task_id=$2 parent_home=$3 parent_status=$4 corr=$5 outcome=$6 task_id=$7 fp=$8
  local parent_state token route_lock route_marker route_history line phase rc=0 route_lock_held=0 marker_present=0 report_recorded=0
  fm_pending_reply_secondmate_receipt_validate \
    "$secondmate_home" "$parent_task_id" "$parent_home" "$parent_status" "$corr" || return 2
  parent_state=${FM_PENDING_ROUTE_STATE:-}
  [ -n "$parent_state" ] || return 2
  fm_pending_reply_txn_lock_acquire "$parent_state" "$corr" token || return 2
  if ! fm_pending_reply_secondmate_receipt_validate \
    "$secondmate_home" "$parent_task_id" "$parent_home" "$parent_status" "$corr"; then
    rc=2
  else
    phase=$FM_PENDING_ROUTE_PHASE
    line="$outcome [corr=$corr]: inactive terminal outcome replayed: task=$task_id fingerprint=$fp"
    [ ! -L "$parent_status" ] || rc=2
    if [ "$rc" = 0 ] && [ -e "$parent_status" ]; then
      [ -f "$parent_status" ] || rc=2
    fi
    if [ "$rc" = 0 ] && [ -f "$parent_status" ] \
      && grep -Fqx "$line" "$parent_status" 2>/dev/null; then
      report_recorded=1
    fi
    route_lock=$(fm_pending_reply_secondmate_route_lock_path "$secondmate_home")
    if [ "$rc" = 0 ] && fm_lock_acquire_wait "$route_lock"; then
      route_lock_held=1
    elif [ "$rc" = 0 ]; then
      rc=2
    fi
    if [ "$route_lock_held" = 1 ]; then
      route_marker=$(fm_pending_reply_secondmate_route_path "$secondmate_home")
      route_history=$(fm_pending_reply_secondmate_route_history_path "$secondmate_home" "$corr")
      if [ -e "$route_marker" ] || [ -L "$route_marker" ] \
        || [ -e "$route_history" ] || [ -L "$route_history" ]; then
        marker_present=1
      fi
      if [ "$marker_present" = 1 ]; then
        fm_pending_reply_secondmate_route_validate "$secondmate_home" "$corr" || rc=2
      elif [ "$phase" != resolved ] \
        && [ "$phase" != retired ] \
        && [ "$report_recorded" != 1 ]; then
        rc=2
      fi
      if [ "$rc" = 0 ] \
        && [ "$phase" != resolved ] \
        && [ "$phase" != retired ] \
        && [ "$report_recorded" != 1 ]; then
        if [ ! -e "$parent_status" ]; then
          : > "$parent_status" || rc=2
        fi
        if [ "$rc" = 0 ] && ! grep -Fqx "$line" "$parent_status" 2>/dev/null; then
          printf '%s\n' "$line" >> "$parent_status" || rc=2
        fi
      fi
      fm_lock_release "$route_lock" || rc=2
      route_lock_held=0
    fi
  fi
  if [ "$route_lock_held" = 1 ]; then
    fm_lock_release "$route_lock" || rc=2
  fi
  fm_pending_reply_txn_lock_release "$parent_state" "$corr" "$token" || rc=2
  return "$rc"
}

scan_locked() {
  local startup=${1:-0} marker_mtime now age cursor meta id started=1 cursor_seen=1
  local scan_started scan_deadline maintenance_deadline remaining rc complete=1 scan_failed=0 find_tmp maintenance_status=0
  local maintenance_started maintenance_phase maintenance_next_phase maintenance_phase_tmp
  local maintenance_order next_order maintenance_order_tmp maintenance_ran=0 maintenance_deferred=0 direct_deferred=0
  local find_pending_source=0 find_retain=0 batch_consumed=0 batch_complete=1 retry_tmp=
  local pane_idle_index_dir= pane_idle_index_ready=0
  inactive_state_preflight || return 1
  marker_mtime=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  now=$(date +%s)
  if [ "$startup" != 1 ] && [ -n "$marker_mtime" ]; then
    age=$((now - marker_mtime))
    [ "$age" -ge "$RECONCILE_SECS" ] || return 0
  fi
  run_maintenance() {
    maintenance_phase=$(cat "$MAINTENANCE_PHASE_CURSOR" 2>/dev/null || true)
    case "$maintenance_phase" in pending|reported) ;; *) maintenance_phase=pending ;; esac
    maintenance_next_phase=$maintenance_phase
    MAINTENANCE_ENUM_DEFERRED=0
    MAINTENANCE_ENUM_FAILED=0
    MAINTENANCE_RETRYABLE=0
    maintenance_started=$(clock_millis)
    if [ "$maintenance_started" -ge "$scan_deadline" ]; then
      maintenance_deferred=1
      return 0
    fi
    maintenance_deadline=$((maintenance_started + MAINTENANCE_TURN_SECS * 1000))
    [ "$maintenance_deadline" -gt "$scan_deadline" ] && maintenance_deadline=$scan_deadline
    if [ "$maintenance_phase" = pending ]; then
      if ! republish_pending_receipts "$maintenance_deadline"; then
        if [ "$MAINTENANCE_RETRYABLE" = 1 ]; then
          maintenance_deferred=1
        elif [ "$MAINTENANCE_ENUM_DEFERRED" = 1 ]; then
          maintenance_deferred=1
        elif [ "$MAINTENANCE_ENUM_FAILED" = 1 ]; then
          maintenance_status=1
        elif [ "$(clock_millis)" -ge "$scan_deadline" ]; then
          maintenance_deferred=1
        else
          maintenance_status=1
        fi
      fi
      if [ "$maintenance_status" = 0 ] && [ "$maintenance_deferred" = 0 ] \
        && [ "$MAINTENANCE_ITEMS_PROCESSED" = 0 ]; then
        if ! repair_reported_secondmate_routes "$maintenance_deadline"; then
          if [ "$MAINTENANCE_ENUM_DEFERRED" = 1 ]; then
            maintenance_deferred=1
          elif [ "$MAINTENANCE_ENUM_FAILED" = 1 ]; then
            maintenance_status=1
          elif [ "$(clock_millis)" -ge "$scan_deadline" ]; then
            maintenance_deferred=1
          else
            maintenance_status=1
          fi
        fi
        if [ "$maintenance_status" = 0 ] && [ "$maintenance_deferred" = 0 ]; then
          maintenance_next_phase=pending
        fi
      elif [ "$maintenance_status" = 0 ] && [ "$maintenance_deferred" = 0 ]; then
        maintenance_next_phase=reported
      fi
    else
      if ! repair_reported_secondmate_routes "$maintenance_deadline"; then
        if [ "$MAINTENANCE_ENUM_DEFERRED" = 1 ]; then
          maintenance_deferred=1
        elif [ "$MAINTENANCE_ENUM_FAILED" = 1 ]; then
          maintenance_status=1
        elif [ "$(clock_millis)" -ge "$scan_deadline" ]; then
          maintenance_deferred=1
        else
          maintenance_status=1
        fi
      fi
      if [ "$maintenance_status" = 0 ] && [ "$maintenance_deferred" = 0 ] \
        && [ "$MAINTENANCE_ITEMS_PROCESSED" = 0 ]; then
        if ! republish_pending_receipts "$maintenance_deadline"; then
          if [ "$MAINTENANCE_RETRYABLE" = 1 ]; then
            maintenance_deferred=1
          elif [ "$MAINTENANCE_ENUM_DEFERRED" = 1 ]; then
            maintenance_deferred=1
          elif [ "$MAINTENANCE_ENUM_FAILED" = 1 ]; then
            maintenance_status=1
          elif [ "$(clock_millis)" -ge "$scan_deadline" ]; then
            maintenance_deferred=1
          else
            maintenance_status=1
          fi
        fi
        if [ "$maintenance_status" = 0 ] && [ "$maintenance_deferred" = 0 ]; then
          maintenance_next_phase=reported
        fi
      elif [ "$maintenance_status" = 0 ] && [ "$maintenance_deferred" = 0 ]; then
        maintenance_next_phase=pending
      fi
    fi
    maintenance_phase_tmp=$(mktemp "$STATE/.inactive-outcome-maintenance.cursor.XXXXXX") || {
      maintenance_status=1
      return 0
    }
    if [ ! -f "$maintenance_phase_tmp" ] || [ -L "$maintenance_phase_tmp" ] \
      || ! printf '%s\n' "$maintenance_next_phase" > "$maintenance_phase_tmp" \
      || ! mv -f "$maintenance_phase_tmp" "$MAINTENANCE_PHASE_CURSOR"; then
      maintenance_status=1
      rm -f "$maintenance_phase_tmp"
    fi
  }
  maintenance_order=$(cat "$MAINTENANCE_ORDER_CURSOR" 2>/dev/null || true)
  case "$maintenance_order" in direct|maintenance) ;; *) maintenance_order=direct ;; esac
  if [ "$maintenance_order" = direct ]; then
    next_order=maintenance
  else
    next_order=direct
  fi
  maintenance_order_tmp=$(mktemp "$STATE/.inactive-outcome-maintenance-order.XXXXXX") || return 1
  if [ ! -f "$maintenance_order_tmp" ] || [ -L "$maintenance_order_tmp" ] \
    || ! printf '%s\n' "$next_order" > "$maintenance_order_tmp" \
    || ! mv -f "$maintenance_order_tmp" "$MAINTENANCE_ORDER_CURSOR"; then
    rm -f "$maintenance_order_tmp"
    return 1
  fi
  scan_started=$(clock_millis)
  scan_deadline=$((scan_started + DIRECT_SCAN_BUDGET_SECS * 1000))
  if [ "$maintenance_order" = maintenance ]; then
    maintenance_ran=1
    run_maintenance
  fi
  cursor=$(cat "$SCAN_CURSOR" 2>/dev/null || true)
  if [ -n "$cursor" ] && { [ ! -f "$STATE/$cursor.meta" ] || [ -L "$STATE/$cursor.meta" ]; }; then
    cursor=
  fi
  if [ -n "$cursor" ]; then started=0; fi
  [ -n "$cursor" ] && cursor_seen=0
  find_tmp=$(mktemp "$STATE/.inactive-outcome-find.XXXXXX") || {
    [ "$maintenance_ran" = 1 ] || run_maintenance
    return 1
  }
  [ -f "$find_tmp" ] && [ ! -L "$find_tmp" ] || {
    rm -f "$find_tmp"
    [ "$maintenance_ran" = 1 ] || run_maintenance
    return 1
  }
  if [ -e "$DIRECT_FIND_PENDING" ] || [ -L "$DIRECT_FIND_PENDING" ]; then
    [ -f "$DIRECT_FIND_PENDING" ] && [ ! -L "$DIRECT_FIND_PENDING" ] || {
      rm -f "$find_tmp"
      [ "$maintenance_ran" = 1 ] || run_maintenance
      return 1
    }
    if [ -s "$DIRECT_FIND_PENDING" ]; then
      inactive_copy_nul_prefix "$DIRECT_FIND_PENDING" "$find_tmp" || {
        rm -f "$find_tmp"
        [ "$maintenance_ran" = 1 ] || run_maintenance
        return 1
      }
      find_pending_source=1
      find_retain=1
    else
      rm -f "$DIRECT_FIND_PENDING" || {
        rm -f "$find_tmp"
        [ "$maintenance_ran" = 1 ] || run_maintenance
        return 1
      }
    fi
  fi
  if [ "$find_pending_source" = 0 ]; then
    remaining=$(budget_remaining_secs "$scan_deadline")
    if [ "$remaining" -le 0 ]; then
      direct_deferred=1
      find_retain=1
    else
      if run_bounded_child "$remaining" find "$STATE" \( -type d ! -path "$STATE" -prune \) -o \
        \( -type f -name '*.meta' -print0 \) > "$find_tmp"; then
        :
      else
        rc=$?
        [ "$rc" -ne 0 ] || rc=1
        complete=0
        if [ "$rc" = 124 ]; then
          direct_deferred=1
          find_retain=1
        else
          scan_failed=1
        fi
      fi
    fi
  fi
  if [ "$find_pending_source" = 1 ]; then
    cursor=
    started=1
    cursor_seen=1
  fi
  remaining=$(budget_remaining_secs "$scan_deadline")
  if [ "$remaining" -gt 0 ]; then
    pane_idle_index_dir=$(mktemp -d "$STATE/.inactive-outcome-pane-idle-index.XXXXXX" 2>/dev/null || true)
    if [ -n "$pane_idle_index_dir" ] \
      && fm_pane_idle_meta_index_persist "$STATE" "$pane_idle_index_dir"; then
      pane_idle_index_ready=1
    else
      if [ -n "$pane_idle_index_dir" ] && [ -d "$pane_idle_index_dir" ] \
        && [ ! -L "$pane_idle_index_dir" ]; then
        rm -f "$pane_idle_index_dir"/* 2>/dev/null || true
        rmdir "$pane_idle_index_dir" 2>/dev/null || true
      fi
      pane_idle_index_dir=
      complete=0
      direct_deferred=1
      find_retain=1
    fi
  else
    complete=0
    direct_deferred=1
    find_retain=1
  fi
  while [ "$scan_failed" = 0 ] && IFS= read -r -d '' meta; do
    batch_consumed=$((batch_consumed + 1))
    remaining=$(budget_remaining_secs "$scan_deadline")
    if [ "$remaining" -le 0 ]; then
      complete=0
      direct_deferred=1
      find_retain=1
      batch_complete=0
      break
    fi
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      continue
    fi
    id=$(basename "$meta" .meta)
    valid_task_id "$id" || continue
    if [ "$started" = 0 ]; then
      if [ ! -f "$STATE/$cursor.meta" ] || [ -L "$STATE/$cursor.meta" ]; then
        cursor=
        started=1
        cursor_seen=1
        complete=0
        direct_deferred=1
        find_retain=1
      else
        [ "$id" = "$cursor" ] || continue
        started=1
        cursor_seen=1
        continue
      fi
    fi
    rc=0
    (
      export FM_LOCK_WAIT_SECS="$remaining"
      export FM_INACTIVE_OUTCOME_SCAN_REMAINING_SECS="$remaining"
      export FM_PANE_IDLE_META_INDEX_DIR="${pane_idle_index_dir:-}"
      run_bounded_child "$remaining" "$SCRIPT_DIR/fm-inactive-reconcile.sh" _child "$id"
    ) || rc=$?
    if [ "$rc" -ne 0 ]; then
      complete=0
      case "$rc" in
        75|124)
          direct_deferred=1
          find_retain=1
          if [ -z "$retry_tmp" ]; then
            retry_tmp=$(mktemp "$STATE/.inactive-outcome-retry.XXXXXX") || {
              scan_failed=1
              break
            }
            [ -f "$retry_tmp" ] && [ ! -L "$retry_tmp" ] || {
              rm -f "$retry_tmp"
              retry_tmp=
              scan_failed=1
              break
            }
          fi
          inactive_append_nul_value "$retry_tmp" "$meta" || {
            scan_failed=1
            break
          }
          continue
          ;;
        *)
          scan_failed=1
          batch_complete=0
          ;;
      esac
      [ "$scan_failed" = 0 ] || break
      continue
    fi
    if printf '%s\n' "$id" > "$SCAN_CURSOR"; then
      :
    else
      rc=$?
      complete=0
      scan_failed=1
      break
    fi
  done < "$find_tmp"
  if [ "$find_pending_source" = 1 ] && [ "$batch_complete" = 1 ] \
    && [ "$scan_failed" = 0 ]; then
    find_retain=0
  fi
  if [ "$direct_deferred" = 1 ] && [ "$scan_failed" = 0 ]; then
    find_retain=1
  fi
  if [ "$find_retain" = 1 ] && [ "$scan_failed" = 0 ]; then
    inactive_persist_nul_suffix "$find_tmp" "$DIRECT_FIND_PENDING" "$batch_consumed" "$retry_tmp" || {
      rc=$?
      [ "$rc" -ne 0 ] || rc=1
      complete=0
      scan_failed=1
    }
  elif [ "$find_pending_source" = 1 ]; then
    rm -f "$DIRECT_FIND_PENDING" || {
      rc=$?
      [ "$rc" -ne 0 ] || rc=1
      complete=0
      scan_failed=1
    }
  fi
  [ -z "$retry_tmp" ] || rm -f "$retry_tmp" || scan_failed=1
  if [ -n "$pane_idle_index_dir" ] && [ -d "$pane_idle_index_dir" ] \
    && [ ! -L "$pane_idle_index_dir" ]; then
    rm -f "$pane_idle_index_dir"/* 2>/dev/null || true
    rmdir "$pane_idle_index_dir" 2>/dev/null || true
  fi
  if rm -f "$find_tmp"; then
    :
  else
    rc=$?
    [ "$rc" -ne 0 ] || rc=1
    complete=0
    scan_failed=1
  fi
  if [ "$maintenance_ran" = 0 ]; then
    run_maintenance
  fi
  if [ "$scan_failed" = 1 ]; then
    [ "$rc" -ne 0 ] || rc=1
    return "$rc"
  fi
  [ "$maintenance_status" = 0 ] || return 1
  if [ "$maintenance_deferred" = 1 ] || [ "$direct_deferred" = 1 ]; then
    return 0
  fi
  [ "$complete" = 1 ] || return 1
  if [ "$cursor_seen" = 0 ]; then
    if [ -n "$cursor" ] && { [ ! -f "$STATE/$cursor.meta" ] || [ -L "$STATE/$cursor.meta" ]; }; then
      return 0
    fi
    return 1
  fi
  if [ "$complete" = 1 ]; then
    rm -f "$SCAN_CURSOR" || return 1
  fi
  date +%s > "$SCAN_MARKER" || return 1
  return 0
}

scan() {
  local startup=${1:-0} rc
  scan_abort() {
    local status=$1
    fm_lock_release "$SCAN_LOCK" || true
    trap - EXIT INT TERM
    exit "$status"
  }
  inactive_state_preflight || return 1
  fm_lock_acquire_wait "$SCAN_LOCK" || return 1
  trap 'fm_lock_release "$SCAN_LOCK" || true' EXIT
  trap 'scan_abort 130' INT
  trap 'scan_abort 143' TERM
  scan_locked "$startup"
  rc=$?
  fm_lock_release "$SCAN_LOCK" || true
  trap - EXIT INT TERM
  return "$rc"
}

case "${1:-}" in
  scan)
    if [ "${2:-}" = --startup ]; then
      scan 1
    else
      scan 0
    fi
    ;;
  ack)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    ack_receipt "$2" "$3" "${4:-1}" "${5:-}"
    ;;
  confirm)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    confirm_receipt "$2" "$3"
    ;;
  claim)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_reserve "$2" "$3"
    ;;
  presenting)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_presenting "$2" "$3"
    ;;
  output-started)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_output_started "$2" "$3"
    ;;
  output-emitted)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_output_emitted "$2" "$3"
    ;;
  output-emitted-state)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_output_emitted "$2" "$3"
    ;;
  output-confirmed)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_output_confirmed "$2" "$3"
    ;;
  output-complete)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_output_complete "$2" "$3"
    ;;
  caller-output-complete)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    caller_output_complete "$2" "$3" "${4:-}"
    ;;
  caller-output-complete-locked)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_output_complete "$2" "$3" 0 "${4:-}"
    ;;
  presented)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_presented "$2" "$3"
    ;;
  _child)
    [ -n "${2:-}" ] || exit 2
    reconcile_child "$2"
    ;;
  *)
    echo "usage: fm-inactive-reconcile.sh scan [--startup] | ack <inactive-outcome:key> <wake-row>" >&2
    exit 2
    ;;
esac
