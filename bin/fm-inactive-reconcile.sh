#!/usr/bin/env bash
# Replay an authoritative terminal crew state that stayed quiet long enough to
# be missed by the normal watcher. This is a reporting layer only: it never
# closes an endpoint, returns a slot, removes a worktree, or changes a PR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
if [ "${FM_SESSION_LOCK_BOOTSTRAP:-0}" != 1 ]; then
  fm_worker_refuse_primary_operation "inactive outcome reconciliation" || exit 1
fi

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
  local value=$1 fallback=$2 minimum=$3 maximum=$4
  case "$value" in ''|*[!0-9]*) value=$fallback ;; esac
  [ "$value" -lt "$minimum" ] && value=$minimum
  [ "$value" -gt "$maximum" ] && value=$maximum
  printf '%s' "$value"
}

RECONCILE_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_SECS:-900}" 900 60 1800)
SCAN_BUDGET_SECS=$(bounded_secs "${FM_INACTIVE_OUTCOME_BUDGET_SECS:-10}" 10 1 300)

meta_value() {  # <meta> <key>
  awk -F= -v wanted="$2" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$1" 2>/dev/null
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
    printf '%s' "$1" | cksum | awk '{print $1}'
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
  if [ ! -e "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  return 0
}

herdr_identity_allowed() {  # <meta>
  local meta=$1 backend session window
  backend=$(meta_value "$meta" backend)
  [ "$backend" = herdr ] || return 0
  session=$(meta_value "$meta" herdr_session)
  window=$(meta_value "$meta" window)
  case "$session" in
    firstmate) : ;;
    default|DEFAULT|CAPTAIN|captain) return 1 ;;
    *) return 1 ;;
  esac
  case "$window" in firstmate:*) return 0 ;; esac
  return 1
}

queue_contains() {  # <key>
  local key=$1
  [ -f "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' -v wanted="$key" '$4 == wanted { found=1 } END { exit(found ? 0 : 1) }' "$FM_WAKE_QUEUE" 2>/dev/null
}

run_bounded_child() {  # <seconds> <command> [args...]
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 125
  fi
}

receipt_path() {  # <fingerprint> <suffix>
  printf '%s/%s.%s' "$OUTCOME_DIR" "$1" "$2"
}

receipt_field() {  # <receipt> <key>
  meta_value "$1" "$2"
}

receipt_write() {  # globals: FP ID INC OUTCOME SNAPSHOT KIND SOURCE
  local pending tmp
  inactive_state_preflight || return 1
  pending=$(receipt_path "$FP" pending)
  RECEIPT_CREATED=0
  for suffix in pending presented reported; do
    local existing
    existing=$(receipt_path "$FP" "$suffix")
    [ ! -L "$existing" ] || return 1
    [ -e "$existing" ] || continue
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

read_incarnation() {  # <meta> <id>
  local meta=$1 id=$2 token tasktmp window worktree seed
  token=$(meta_value "$meta" spawn_incarnation)
  case "$token" in
    ''|legacy-unknown|*[!A-Za-z0-9._:-]*) token= ;;
  esac
  if [ -n "$token" ]; then
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
  printf 'legacy-%s' "$(hash_text "$seed" | cut -c1-32)"
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
  local snapshot token key route_rc
  valid_task_id "$id" || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  case "$kind" in ''|ship|scout) ;; *) return 0 ;; esac
  herdr_identity_allowed "$meta" || return 0
  now=$(date +%s)
  activity=$(latest_activity "$id")
  [ "$activity" -gt 0 ] || return 0
  age=$((now - activity))
  [ "$age" -ge "$RECONCILE_SECS" ] || return 0

  CHILD_LOCK="$STATE/.spawn-$id.lock"
  FM_LOCK_WAIT_SECS=${FM_INACTIVE_OUTCOME_LOCK_WAIT_SECS:-30}
  fm_lock_acquire_wait "$CHILD_LOCK" || return 0
  CHILD_LOCK_HELD=1
  trap child_cleanup EXIT INT TERM
  # Teardown/relaunch can replace or remove metadata only after the same lock is
  # released. Re-read it after acquiring the lock so the snapshot belongs to the
  # current incarnation.
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  herdr_identity_allowed "$meta" || return 0
  FM_CREW_STATE_NM_TIMEOUT=${FM_INACTIVE_OUTCOME_STATE_TIMEOUT_SECS:-10} \
    "$FM_CREW_STATE_BIN" "$id" > "$STATE/.$id.inactive-state.$$" 2>/dev/null || return 0
  line=$(cat "$STATE/.$id.inactive-state.$$" 2>/dev/null || true)
  rm -f "$STATE/.$id.inactive-state.$$"
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
  INC=$(read_incarnation "$meta" "$id")
  FP=$(hash_text "$id|$INC|$outcome|$snapshot")
  ID=$id
  OUTCOME=$outcome
  SNAPSHOT=$snapshot
  SOURCE=$source
  KIND=${kind:-ship}
  if is_secondmate_home; then
    route_rc=$?
    [ "$route_rc" = 0 ] || return 0
    fm_pending_reply_secondmate_route_validate "$FM_HOME" || return 0
    KIND=secondmate
  else
    [ "$?" = 1 ] || return 0
    KIND=${kind:-ship}
  fi
  receipt_write || return 1
  key="inactive-outcome:$FP"
  if [ "$RECEIPT_CREATED" = 1 ] || [ -f "$(receipt_path "$FP" pending)" ]; then
    if ! queue_contains "$key"; then
      fm_wake_append check "$key" "inactive terminal outcome: task=$id state=$outcome fingerprint=$FP" || return 1
      printf 'queued inactive outcome: task=%s state=%s fingerprint=%s\n' "$id" "$outcome" "$FP"
    fi
  fi
  return 0
}

ack_receipt() {  # <inactive-outcome:fingerprint>
  local key=$1 fp rec id kind outcome parent_status corr line target
  case "$key" in inactive-outcome:*) fp=${key#inactive-outcome:} ;; *) return 0 ;; esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  rec=$(receipt_path "$fp" pending)
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 0
  [ "$(receipt_field "$rec" fingerprint)" = "$fp" ] || return 2
  id=$(receipt_field "$rec" task_id)
  kind=$(receipt_field "$rec" kind)
  outcome=$(receipt_field "$rec" outcome)
  if [ "$kind" = secondmate ]; then
    fm_pending_reply_secondmate_route_validate "$FM_HOME" || return 2
    parent_status=$FM_PENDING_ROUTE_PARENT_STATUS
    corr=$FM_PENDING_ROUTE_CORR
    line="$outcome [corr=$corr]: inactive terminal outcome replayed: task=$id fingerprint=$fp"
    mkdir -p "$(dirname "$parent_status")" || return 2
    if ! grep -Fqx "$line" "$parent_status" 2>/dev/null; then
      printf '%s\n' "$line" >> "$parent_status" || return 2
    fi
    target=$(receipt_path "$fp" reported)
  else
    target=$(receipt_path "$fp" presented)
  fi
  [ ! -L "$target" ] || return 2
  [ ! -e "$target" ] || { rm -f "$rec"; return 0; }
  mv "$rec" "$target" || return 2
  [ "$kind" = secondmate ] || return 0
  fm_pending_reply_secondmate_route_clear "$FM_HOME" "$corr" || true
  return 0
}

scan_locked() {
  local startup=${1:-0} marker_mtime now age cursor meta id found=0 started=1
  local scan_started remaining rc complete=1 scan_failed=0
  inactive_state_preflight || return 1
  marker_mtime=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  now=$(date +%s)
  if [ "$startup" != 1 ] && [ -n "$marker_mtime" ]; then
    age=$((now - marker_mtime))
    [ "$age" -ge "$RECONCILE_SECS" ] || return 0
  fi
  scan_started=$now
  cursor=$(cat "$SCAN_CURSOR" 2>/dev/null || true)
  if [ -n "$cursor" ] && { [ ! -f "$STATE/$cursor.meta" ] || [ -L "$STATE/$cursor.meta" ]; }; then
    cursor=
  fi
  if [ -n "$cursor" ]; then started=0; fi
  for meta in "$STATE"/*.meta; do
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      continue
    fi
    id=$(basename "$meta" .meta)
    valid_task_id "$id" || continue
    if [ "$started" = 0 ]; then
      [ "$id" = "$cursor" ] || continue
      started=1
      continue
    fi
    now=$(date +%s)
    remaining=$((SCAN_BUDGET_SECS - (now - scan_started)))
    if [ "$remaining" -le 0 ]; then
      complete=0
      break
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
    found=1
  done
  [ "$scan_failed" = 0 ] || return "$rc"
  if [ "$complete" = 1 ]; then
    rm -f "$SCAN_CURSOR" || return 1
  fi
  date +%s > "$SCAN_MARKER" || return 1
  [ "$found" = 1 ] || true
  return 0
}

scan() {
  local startup=${1:-0}
  inactive_state_preflight || return 1
  fm_lock_acquire_wait "$SCAN_LOCK" || return 1
  trap 'fm_lock_release "$SCAN_LOCK" || true' EXIT INT TERM
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
    [ -n "${2:-}" ] || exit 2
    ack_receipt "$2"
    ;;
  _child)
    [ -n "${2:-}" ] || exit 2
    reconcile_child "$2"
    ;;
  *)
    echo "usage: fm-inactive-reconcile.sh scan [--startup] | ack <inactive-outcome:key>" >&2
    exit 2
    ;;
esac
