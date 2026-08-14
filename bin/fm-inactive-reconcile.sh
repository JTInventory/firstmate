#!/usr/bin/env bash
# Replay an authoritative terminal crew state that stayed quiet long enough to
# be missed by the normal watcher. This is a reporting layer only: it never
# closes an endpoint, returns a slot, removes a worktree, or changes a PR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "inactive outcome reconciliation" || exit 1

FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
OUTCOME_DIR="$STATE/terminal-outcomes"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_CURSOR="$STATE/.inactive-outcome-reconcile.cursor"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"

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
  inactive_state_path_is_safe "$FM_WAKE_QUEUE" file || return 1
}

inactive_state_preflight || {
  echo "error: inactive reconciliation state must be local regular state under $FM_HOME" >&2
  exit 1
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
ROUTE_MARKER="$FM_HOME/.fm-secondmate-home"
CHILD_LOCK_HELD=0
CHILD_LOCK=

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

RECONCILE_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_SECS:-900}" 900 60 1800)
SCAN_BUDGET_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_BUDGET_SECS:-10}" 10 1 300)

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

claim_receipt_state() {
  local fp=$1 suffix path found=
  for suffix in pending presented reported; do
    path=$(receipt_path "$fp" "$suffix")
    [ ! -L "$path" ] || return 2
    [ -e "$path" ] || continue
    [ -f "$path" ] || return 2
    [ "$(receipt_field "$path" schema)" = fm-jt-terminal-outcome.v1 ] || return 2
    [ "$(receipt_field "$path" fingerprint)" = "$fp" ] || return 2
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

claim_reserve() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim tmp state existing old_row line output_complete defer_ack
  local defer_generation defer_generation_start receipt_state receipt_rc=0 recorded_report=0 report_rc=1
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
    if [ "$old_row" != "$row" ]; then
      tmp=$(mktemp "$OUTCOME_DIR/.claim-row.XXXXXX") || return 2
      chmod 600 "$tmp" 2>/dev/null || true
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in row=*) printf 'row=%s\n' "$row" ;; *) printf '%s\n' "$line" ;; esac
      done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
      [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
      mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
    fi
    if [ "$state" = presented ]; then
      defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null || true)
      if [ "$defer_ack" = 1 ]; then
        defer_generation=$(claim_field "$claim" defer_generation 2>/dev/null || true)
        defer_generation_start=$(claim_field "$claim" defer_generation_start 2>/dev/null || true)
        if claim_defer_generation_live "$defer_generation" "$defer_generation_start"; then
          return 4
        fi
        [ "$(claim_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
        return 5
      fi
    fi
    if [ "$recorded_report" = 1 ]; then
      case "$state" in
        presented) return 5 ;;
        presenting|reserved)
          claim_mark_presenting "$key" "$row" || return 2
          claim_mark_output_complete "$key" "$row" || return 2
          claim_mark_presented "$key" "$row" || return 2
          return 5
          ;;
      esac
    fi
    if [ "$state" = presenting ]; then
      output_complete=$(claim_field "$claim" output_complete 2>/dev/null || true)
      if [ "$output_complete" = 1 ]; then
        claim_mark_presented "$key" "$row" || return 2
        return 5
      fi
      defer_ack=$(claim_field "$claim" defer_ack 2>/dev/null || true)
      if [ "$defer_ack" = 1 ]; then
        defer_generation=$(claim_field "$claim" defer_generation 2>/dev/null || true)
        defer_generation_start=$(claim_field "$claim" defer_generation_start 2>/dev/null || true)
        if claim_defer_generation_live "$defer_generation" "$defer_generation_start"; then
          return 4
        fi
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
      claim_mark_output_complete "$key" "$row" || return 2
      claim_mark_presented "$key" "$row" || return 2
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
  local seen_pid=0 seen_output=0 seen_complete=0
  local seen_defer_ack=0 seen_defer_generation=0 seen_defer_generation_start=0
  [ "${FM_WAKE_DRAIN_DIRECT:-0}" != 1 ] \
    && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ] && defer_ack=1
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
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presenting\n' ;;
      presentation_pid=*) printf 'presentation_pid=%s\n' "${BASHPID:-$$}"; seen_pid=1 ;;
      output_started=*) printf 'output_started=0\n'; seen_output=1 ;;
      output_complete=*) printf 'output_complete=0\n'; seen_complete=1 ;;
      defer_ack=*) printf 'defer_ack=%s\n' "$defer_ack"; seen_defer_ack=1 ;;
      defer_generation=*) printf 'defer_generation=%s\n' "$defer_generation"; seen_defer_generation=1 ;;
      defer_generation_start=*) printf 'defer_generation_start=%s\n' "$defer_generation_start"; seen_defer_generation_start=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_pid" = 1 ] || printf 'presentation_pid=%s\n' "${BASHPID:-$$}" >> "$tmp"
  [ "$seen_output" = 1 ] || printf 'output_started=0\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=0\n' >> "$tmp"
  [ "$seen_defer_ack" = 1 ] || printf 'defer_ack=%s\n' "$defer_ack" >> "$tmp"
  [ "$seen_defer_generation" = 1 ] || printf 'defer_generation=%s\n' "$defer_generation" >> "$tmp"
  [ "$seen_defer_generation_start" = 1 ] || printf 'defer_generation_start=%s\n' "$defer_generation_start" >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_output_complete() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 owner_required=${3:-1} expected_generation=${4:-}
  local fp claim state tmp line seen_output=0 seen_complete=0
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
  if [ "$owner_required" = 0 ]; then
    claim_validate_caller_owner "$claim" "$expected_generation" || return 2
  fi
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      output_started=*) printf 'output_started=1\n'; seen_output=1 ;;
      output_complete=*) printf 'output_complete=1\n'; seen_complete=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=1\n' >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_output_started() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim state tmp line seen_output=0 seen_complete=0
  drain_claim_owner "$row" || return 2
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 2 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  claim=$(claim_path "$fp")
  [ ! -L "$claim" ] || return 2
  state=$(claim_validate "$claim" "$fp" "$row") || return 2
  [ "$state" = presenting ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      output_started=*) printf 'output_started=1\n'; seen_output=1 ;;
      output_complete=*) printf 'output_complete=0\n'; seen_complete=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=0\n' >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_presented() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 fp claim tmp line defer_ack=0 defer_generation= defer_generation_start=
  local seen_defer_ack=0 seen_defer_generation=0 seen_defer_generation_start=0
  [ "${FM_WAKE_DRAIN_DIRECT:-0}" != 1 ] \
    && [ "${FM_WAKE_DRAIN_DEFER_ACK:-0}" = 1 ] && defer_ack=1
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
  [ "$(claim_validate "$claim" "$fp" "$row")" = presenting ] || return 2
  tmp=$(mktemp "$OUTCOME_DIR/.claim-state.XXXXXX") || return 2
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*) printf 'state=presented\n' ;;
      defer_ack=*) printf 'defer_ack=%s\n' "$defer_ack"; seen_defer_ack=1 ;;
      defer_generation=*) printf 'defer_generation=%s\n' "$defer_generation"; seen_defer_generation=1 ;;
      defer_generation_start=*) printf 'defer_generation_start=%s\n' "$defer_generation_start"; seen_defer_generation_start=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_defer_ack" = 1 ] || printf 'defer_ack=%s\n' "$defer_ack" >> "$tmp"
  [ "$seen_defer_generation" = 1 ] || printf 'defer_generation=%s\n' "$defer_generation" >> "$tmp"
  [ "$seen_defer_generation_start" = 1 ] || printf 'defer_generation_start=%s\n' "$defer_generation_start" >> "$tmp"
  [ ! -L "$claim" ] || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$claim" || { rm -f "$tmp"; return 2; }
}

claim_mark_confirmed() {  # <inactive-outcome:fingerprint> <wake-row>
  local key=$1 row=$2 owner_required=${3:-1} expected_generation=${4:-}
  local fp claim state tmp line seen_output=0 seen_complete=0
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
  if [ "$owner_required" = 0 ]; then
    claim_validate_caller_owner "$claim" "$expected_generation" || return 2
  fi
  case "$state" in
    presented)
      [ "$(claim_field "$claim" output_complete 2>/dev/null || true)" = 1 ] || return 2
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
      output_complete=*) printf 'output_complete=1\n'; seen_complete=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$claim" > "$tmp" || { rm -f "$tmp"; return 2; }
  [ "$seen_output" = 1 ] || printf 'output_started=1\n' >> "$tmp"
  [ "$seen_complete" = 1 ] || printf 'output_complete=1\n' >> "$tmp"
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

publish_receipt_and_wake() {
  local status=0
  FM_WAKE_APPEND_CREATED=0
  if ! fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; then
    receipt_write || return 1
    return 1
  fi
  if receipt_write; then
    if [ -f "$(receipt_path "$FP" pending)" ]; then
      fm_wake_append_if_absent_locked FM_WAKE_APPEND_CREATED check "inactive-outcome:$FP" \
        "inactive terminal outcome: task=$ID state=$OUTCOME fingerprint=$FP" || status=$?
    fi
  else
    status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
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
  local existing task outcome status=0 existing_rc
  FM_WAKE_APPEND_CREATED=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if receipt_existing_core; then
    if [ "$RECEIPT_EXISTING_SUFFIX" = pending ]; then
      existing=$(receipt_path "$FP" pending)
      task=$(receipt_field "$existing" task_id)
      outcome=$(receipt_field "$existing" outcome)
      fm_wake_append_if_absent_locked FM_WAKE_APPEND_CREATED check "inactive-outcome:$FP" \
        "inactive terminal outcome: task=$task state=$outcome fingerprint=$FP" || status=$?
    fi
  else
    existing_rc=$?
    [ "$existing_rc" = 1 ] || status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

publish_secondmate_receipt_and_wake() {
  local route_lock status=0 existing_rc pending pending_corr pending_parent_id pending_parent_home pending_parent_status
  FM_WAKE_APPEND_CREATED=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if [ -L "$FM_HOME" ] || [ ! -d "$FM_HOME" ] || [ -L "$FM_HOME/state" ] || [ ! -d "$FM_HOME/state" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 0
  fi
  route_lock=$(fm_pending_reply_secondmate_route_lock_path "$FM_HOME")
  if ! fm_lock_acquire_wait "$route_lock"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 1
  fi
  KIND=secondmate
  pending=$(receipt_path "$FP" pending)
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    [ -f "$pending" ] && [ ! -L "$pending" ] || status=1
    if [ "$status" = 0 ]; then
      pending_corr=$(receipt_field "$pending" parent_corr)
      printf '%s' "$pending_corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || status=1
    fi
    if [ "$status" = 0 ] && ! fm_pending_reply_secondmate_route_validate "$FM_HOME" "$pending_corr"; then
      fm_lock_release "$route_lock" || true
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
      return 0
    fi
    if [ "$status" = 0 ]; then
      pending_parent_id=$(receipt_field "$pending" parent_task_id)
      pending_parent_home=$(receipt_field "$pending" parent_home)
      pending_parent_status=$(receipt_field "$pending" parent_status)
      [ "$pending_parent_id" = "$FM_PENDING_ROUTE_SECOND_MATE_ID" ] || status=1
      [ "$pending_parent_home" = "$FM_PENDING_ROUTE_PARENT_HOME" ] || status=1
      [ "$pending_parent_status" = "$FM_PENDING_ROUTE_PARENT_STATUS" ] || status=1
    fi
  elif ! fm_pending_reply_secondmate_route_validate "$FM_HOME"; then
    fm_lock_release "$route_lock" || true
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 0
  fi
  [ "$status" = 0 ] || {
    fm_lock_release "$route_lock" || true
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 1
  }
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
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
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
  local fp=$1 pending kind parent_status parent_corr line
  pending=$(receipt_path "$fp" pending)
  kind=$(receipt_field "$pending" kind) || return 2
  case "$kind" in
    ship|scout) return 1 ;;
    secondmate) ;;
    *) return 2 ;;
  esac
  prepare_pending_receipt "$pending" || return 2
  parent_status=$(receipt_field "$pending" parent_status) || return 2
  parent_corr=$(receipt_field "$pending" parent_corr) || return 2
  [ -f "$parent_status" ] && [ ! -L "$parent_status" ] || return 1
  line="$OUTCOME [corr=$parent_corr]: inactive terminal outcome replayed: task=$ID fingerprint=$fp"
  grep -Fqx "$line" "$parent_status" 2>/dev/null
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

repair_reported_secondmate_routes() {
  local scan_started=$1 reported kind corr parent_task_id parent_home parent_status now remaining status=0
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 0
  now=$(date +%s)
  remaining=$((SCAN_BUDGET_SECS - (now - scan_started)))
  [ "$remaining" -gt 0 ] || return 1
  FM_LOCK_WAIT_SECS="$remaining" fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  for reported in "$OUTCOME_DIR"/*.reported; do
    now=$(date +%s)
    remaining=$((SCAN_BUDGET_SECS - (now - scan_started)))
    [ "$remaining" -gt 0 ] || { status=1; break; }
    [ -e "$reported" ] || [ -L "$reported" ] || continue
    [ -f "$reported" ] && [ ! -L "$reported" ] || { status=1; continue; }
    kind=$(receipt_field "$reported" kind 2>/dev/null || true)
    case "$kind" in
      ship|scout) continue ;;
      secondmate)
        if ! reported_secondmate_receipt_valid "$reported"; then
          status=1
          continue
        fi
        corr=$(receipt_field "$reported" parent_corr)
        parent_task_id=$(receipt_field "$reported" parent_task_id)
        parent_home=$(receipt_field "$reported" parent_home)
        parent_status=$(receipt_field "$reported" parent_status)
        FM_LOCK_WAIT_SECS="$remaining" fm_pending_reply_secondmate_route_clear_reported \
          "$FM_HOME" "$corr" "$parent_task_id" "$parent_home" "$parent_status" || status=1
        ;;
      *) status=1 ;;
    esac
  done
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
  local scan_started=$1 pending now remaining status=0
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 0
  for pending in "$OUTCOME_DIR"/*.pending; do
    [ -e "$pending" ] || [ -L "$pending" ] || continue
    now=$(date +%s)
    remaining=$((SCAN_BUDGET_SECS - (now - scan_started)))
    [ "$remaining" -gt 0 ] || return 1
    if ! FM_LOCK_WAIT_SECS="$remaining" republish_pending_receipt "$pending"; then
      status=1
    elif [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
      printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$ID" "$OUTCOME" "$FP"
    fi
  done
  return "$status"
}

read_incarnation() {  # <meta> <id>
  local meta=$1 id=$2 token tasktmp window worktree seed digest rc token_present=0
  if token=$(meta_value_unique "$meta" spawn_incarnation); then
    token_present=1
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    token=
  fi
  if [ "$token_present" = 1 ]; then
    case "$token" in
      ''|legacy-unknown|*[!A-Za-z0-9._:-]*) return 1 ;;
    esac
    printf '%s' "$token"
    return 0
  fi
  # Legacy metadata has no incarnation token. Prefer the per-task temp root,
  # then bind the fallback to the old endpoint/worktree identity. This is only
  # a compatibility boundary; a new spawn always writes spawn_incarnation.
  tasktmp=$(meta_value "$meta" tasktmp)
  window=$(meta_value "$meta" window)
  worktree=$(meta_value "$meta" worktree)
  if [ -n "$tasktmp" ]; then
    seed="legacy|tasktmp=$tasktmp"
  else
    seed="legacy|window=$window|worktree=$worktree"
  fi
  digest=$(hash_text "$seed") || return 1
  printf 'legacy-%s' "${digest:0:32}"
}

child_cleanup() {
  local status=$?
  if [ "$CHILD_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CHILD_LOCK" || true
  fi
  exit "$status"
}

reconcile_child() {
  local id=$1 meta="$STATE/$1.meta" kind backend now activity age line outcome source
  local snapshot token key route_rc state_tmp state_rc existing_rc
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
  state_tmp=$(mktemp "$STATE/.$id.inactive-state.XXXXXX") || return 1
  [ -f "$state_tmp" ] && [ ! -L "$state_tmp" ] || { rm -f "$state_tmp"; return 1; }
  state_rc=0
  FM_CREW_STATE_NM_TIMEOUT=${FM_INACTIVE_OUTCOME_STATE_TIMEOUT_SECS:-10} \
    "$FM_CREW_STATE_BIN" "$id" > "$state_tmp" 2>/dev/null || state_rc=$?
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
  if [ "$route_rc" = 0 ]; then
    publish_secondmate_receipt_and_wake || return 1
    if [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
      printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$id" "$outcome" "$FP"
    fi
    return 0
  fi
  if receipt_existing_core; then
    if [ "$RECEIPT_EXISTING_SUFFIX" = pending ]; then
      republish_existing_receipt_wake || return 1
      if [ "$FM_WAKE_APPEND_CREATED" = 1 ]; then
        printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$id" "$outcome" "$FP"
      fi
    fi
    return 0
  else
    existing_rc=$?
    [ "$existing_rc" = 1 ] || return 1
  fi
  key="inactive-outcome:$FP"
  publish_receipt_and_wake || return 1
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
        [ "$(receipt_field "$existing" fingerprint)" = "$fp" ] || return 2
        existing_kind=$(receipt_field "$existing" kind)
        if [ "$existing_kind" = secondmate ]; then
          reported_secondmate_receipt_valid "$existing" || return 2
          existing_corr=$(receipt_field "$existing" parent_corr)
          fm_pending_reply_secondmate_route_clear_reported "$FM_HOME" "$existing_corr" \
            "$(receipt_field "$existing" parent_task_id)" \
            "$(receipt_field "$existing" parent_home)" \
            "$(receipt_field "$existing" parent_status)" || return 2
        fi
        claim_remove "$key" "$row" "$owner_required" "$expected_generation" || return 2
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
    return 1
  fi
  mv "$rec" "$target" || return 2
  if [ "$kind" = secondmate ]; then
    fm_pending_reply_secondmate_route_clear_reported "$FM_HOME" "$corr" \
      "$parent_task_id" "$parent_home" "$parent_status" || return 2
  fi
  claim_remove "$key" "$row" "$owner_required" "$expected_generation" || return 2
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
  local status=0 caller_pid=${PPID:-}
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
  parent_state="$parent_home/state"
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
  local scan_started remaining rc complete=1 scan_failed=0 find_tmp maintenance_status=0
  inactive_state_preflight || return 1
  marker_mtime=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  now=$(date +%s)
  if [ "$startup" != 1 ] && [ -n "$marker_mtime" ]; then
    age=$((now - marker_mtime))
    [ "$age" -ge "$RECONCILE_SECS" ] || return 0
  fi
  scan_started=$now
  run_maintenance() {
    if ! republish_pending_receipts "$scan_started"; then
      maintenance_status=1
    fi
    if ! repair_reported_secondmate_routes "$scan_started"; then
      maintenance_status=1
    fi
  }
  cursor=$(cat "$SCAN_CURSOR" 2>/dev/null || true)
  if [ -n "$cursor" ] && { [ ! -f "$STATE/$cursor.meta" ] || [ -L "$STATE/$cursor.meta" ]; }; then
    cursor=
  fi
  if [ -n "$cursor" ]; then started=0; fi
  [ -n "$cursor" ] && cursor_seen=0
  find_tmp=$(mktemp "$STATE/.inactive-outcome-find.XXXXXX") || {
    run_maintenance
    return 1
  }
  [ -f "$find_tmp" ] && [ ! -L "$find_tmp" ] || {
    rm -f "$find_tmp"
    run_maintenance
    return 1
  }
  now=$(date +%s)
  remaining=$((SCAN_BUDGET_SECS - (now - scan_started)))
  if [ "$remaining" -le 0 ]; then
    rm -f "$find_tmp"
    run_maintenance
    return 1
  fi
  if run_bounded_child "$remaining" find "$STATE" \( -type d ! -path "$STATE" -prune \) -o \
    \( -type f -name '*.meta' -print0 \) > "$find_tmp"; then
    :
  else
    rc=$?
    [ "$rc" -ne 0 ] || rc=1
    complete=0
    scan_failed=1
  fi
  while [ "$scan_failed" = 0 ] && IFS= read -r -d '' meta; do
    now=$(date +%s)
    remaining=$((SCAN_BUDGET_SECS - (now - scan_started)))
    if [ "$remaining" -le 0 ]; then
      complete=0
      break
    fi
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      continue
    fi
    id=$(basename "$meta" .meta)
    valid_task_id "$id" || continue
    if [ "$started" = 0 ]; then
      [ "$id" = "$cursor" ] || continue
      started=1
      cursor_seen=1
      continue
    fi
    rc=0
    FM_LOCK_WAIT_SECS="$remaining" run_bounded_child "$remaining" \
      "$SCRIPT_DIR/fm-inactive-reconcile.sh" _child "$id" || rc=$?
    if [ "$rc" -ne 0 ]; then
      complete=0
      scan_failed=1
      break
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
  if rm -f "$find_tmp"; then
    :
  else
    rc=$?
    [ "$rc" -ne 0 ] || rc=1
    complete=0
    scan_failed=1
  fi
  run_maintenance
  if [ "$scan_failed" = 1 ]; then
    [ "$rc" -ne 0 ] || rc=1
    return "$rc"
  fi
  [ "$complete" = 1 ] || return 1
  [ "$maintenance_status" = 0 ] || return 1
  if [ "$cursor_seen" = 0 ]; then
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
    ack_receipt "$2" "$3"
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
  output-complete)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    claim_mark_output_complete "$2" "$3"
    ;;
  caller-output-complete)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2
    caller_output_complete "$2" "$3"
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
