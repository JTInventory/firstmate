#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree or retire a
# secondmate home, kill the session-provider endpoint, clear volatile state, refresh/prune
# the project's clone for PR-based ship tasks, then print a backlog-refresh
# reminder.
# REFUSES if the worktree holds work that has not LANDED, because treehouse return
# hard-resets the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge on the captain's approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# Before destructive cleanup, teardown validates task check artifacts and any
# matching quarantine entries as ordinary single-link files on the state
# device. It refuses and preserves task state when that proof fails; otherwise
# it removes the task's check, trust record, PR sidecar, publication record,
# retirement receipt, and quarantine entries with the rest of the volatile state.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child windows, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Worktree disposal never trusts a recorded worktree= as current ownership.
# Before returning a pooled slot, bin/fm-slot-owner-lib.sh checks other metadata,
# the private owner stamp, and live declared agents. A conflict retains the
# directory and retires its lease; --force does not waive another task's claim.
# A contested secondmate home refuses teardown and preserves every record.
# A `treehouse return` failure that reports an existing git `index.lock` is
# retried because that lock can be transient; other return failures still stop
# teardown. FM_TREEHOUSE_RETURN_LOCK_RETRIES controls additional attempts
# (default 3) and FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS controls the whole-
# second wait between them (default 1).
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "teardown" || exit 1
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_LIFECYCLE_HOME="$FM_HOME" FM_LIFECYCLE_STATE="$STATE"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tool-path-lib.sh
. "$SCRIPT_DIR/fm-tool-path-lib.sh"
fm_normalize_tool_path
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-task-identity-lib.sh
. "$SCRIPT_DIR/fm-task-identity-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-slot-owner-lib.sh
. "$SCRIPT_DIR/fm-slot-owner-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
FORCE=${2:-}
FORCE_RETIRE_STAGED=0
FORCE_RETIRE_SOURCE=
TEARDOWN_LOCKS=()
TEARDOWN_LOCK_DIRS_CREATED=()
TEARDOWN_RETURN_CLAIMS=()
TEARDOWN_RETURN_LEGACIES=()
TEARDOWN_DEFER_RETURN_FINALIZE=0
TEARDOWN_PENDING_STATES=()
TEARDOWN_PENDING_IDS=()
TEARDOWN_PENDING_SOURCES=()
TEARDOWN_RELINQUISH_WTS=()
TEARDOWN_RELINQUISH_IDS=()
TEARDOWN_RELINQUISH_HOMES=()
TEARDOWN_RELINQUISH_VERDICTS=()
TEARDOWN_TXN_DIR="$STATE/.teardown-transactions/$ID"
TEARDOWN_TXN_COMMITTED=0
PARENT_PENDING_OPEN=0
TOP_HOME_ALREADY_RETURNED=0

teardown_task_lock_acquire() {
  local state_dir=$1 id=$2 lock held
  lock="$state_dir/.spawn-$id.lock"
  for held in "${TEARDOWN_LOCKS[@]}"; do
    [ "$held" != "$lock" ] || return 0
  done
  if ! fm_lock_try_acquire "$lock"; then
    echo "REFUSED: spawn or teardown is already changing task $id in $state_dir" >&2
    return 1
  fi
  TEARDOWN_LOCKS+=("$lock")
}

teardown_admission_lock_acquire() {
  local state_dir=$1 target_home=$2 lock held lock_dir already acquired=0 current_pid
  current_pid=${BASHPID:-$$}
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    already=0
    for held in "${TEARDOWN_LOCKS[@]}"; do
      [ "$held" != "$lock" ] || already=1
    done
    [ "$already" = 1 ] && continue
    lock_dir=$(dirname "$lock")
    if [ ! -d "$lock_dir" ]; then
      mkdir -p "$lock_dir" || return 1
      TEARDOWN_LOCK_DIRS_CREATED+=("$lock_dir")
    fi
    if ! fm_lock_try_acquire "$lock"; then
      echo "REFUSED: spawn is already publishing work in $state_dir" >&2
      return 1
    fi
    TEARDOWN_LOCKS+=("$lock")
    acquired=1
  done < <(fm_spawn_admission_lock_paths "$state_dir")
  [ "$acquired" = 1 ] || return 0
  if fm_spawn_legacy_task_lock_busy "$state_dir"; then
    echo "REFUSED: an older spawn or teardown is still changing $state_dir" >&2
    return 1
  fi
  if ! fm_spawn_legacy_lifecycle_quiescent \
    "$target_home" "$state_dir" "$$ $current_pid"; then
    echo "REFUSED: an older spawn or teardown is still starting in $target_home" >&2
    return 1
  fi
}

teardown_locks_release() {
  local status=$? i
  if [ "$TEARDOWN_TXN_COMMITTED" -ne 1 ]; then
    teardown_restore_transaction_evidence >/dev/null 2>&1 || true
  fi
  for ((i=${#TEARDOWN_LOCKS[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${TEARDOWN_LOCKS[$i]}" || true
  done
  for ((i=${#TEARDOWN_LOCK_DIRS_CREATED[@]} - 1; i >= 0; i--)); do
    rmdir "${TEARDOWN_LOCK_DIRS_CREATED[$i]}" 2>/dev/null || true
  done
  return "$status"
}

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] && [ -r "$META" ] \
  || { echo "REFUSED: task metadata is missing, unreadable, or not a regular file: $META" >&2; exit 1; }

teardown_meta_value_exact() {
  local meta=$1 key=$2 required=$3 count value
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null) || count=0
  if [ "$required" = required ]; then
    [ "$count" -eq 1 ] || {
      echo "REFUSED: task metadata must contain exactly one non-empty $key= field: $meta" >&2
      return 1
    }
  elif [ "$count" -gt 1 ]; then
    echo "REFUSED: task metadata contains ambiguous $key= fields: $meta" >&2
    return 1
  elif [ "$count" -eq 0 ]; then
    printf ''
    return 0
  fi
  value=$(sed -n "s/^${key}=//p" "$meta")
  [ -n "$value" ] || {
    echo "REFUSED: task metadata contains an empty $key= field: $meta" >&2
    return 1
  }
  printf '%s' "$value"
}

WT=$(teardown_meta_value_exact "$META" worktree required) || exit 1
T=$(teardown_meta_value_exact "$META" window required) || exit 1
PROJ=$(teardown_meta_value_exact "$META" project required) || exit 1
KIND=$(teardown_meta_value_exact "$META" kind required) || exit 1
META_TASK=$(teardown_meta_value_exact "$META" task required) || exit 1
HOME_PATH=$(teardown_meta_value_exact "$META" home required) || exit 1
BACKEND=$(teardown_meta_value_exact "$META" backend optional) || exit 1
ENDPOINT_GENERATION=$(teardown_meta_value_exact "$META" endpoint_generation required) || exit 1
[ -n "$BACKEND" ] || BACKEND=tmux
case "$WT" in /*) ;; *) echo "REFUSED: task worktree scope is not absolute: $WT" >&2; exit 1 ;; esac
case "$PROJ" in /*) ;; *) echo "REFUSED: task project scope is not absolute: $PROJ" >&2; exit 1 ;; esac
case "$KIND" in ship|scout|secondmate) ;; *) echo "REFUSED: task kind is invalid: $KIND" >&2; exit 1 ;; esac
[ "$META_TASK" = "$ID" ] || { echo "REFUSED: task metadata identity does not match $ID" >&2; exit 1; }
case "$ENDPOINT_GENERATION" in
  *[!A-Za-z0-9._-]*|""|*/*)
    echo "REFUSED: task endpoint generation is invalid" >&2
    exit 1
    ;;
esac
case "$HOME_PATH" in
  /*) ;;
  *) echo "REFUSED: task home scope is missing or not absolute" >&2; exit 1 ;;
esac
if [ "$KIND" = secondmate ]; then
  fm_slot_same_path "$HOME_PATH" "$WT" || {
    echo "REFUSED: secondmate home and worktree scopes conflict" >&2
    exit 1
  }
else
  fm_slot_same_path "$HOME_PATH" "$FM_HOME" || {
    echo "REFUSED: task home scope does not match the active owner home" >&2
    exit 1
  }
fi
fm_backend_validate "$BACKEND" || exit 1
if [ "$BACKEND" = herdr ]; then
  HERDR_SCOPE_SESSION=$(teardown_meta_value_exact "$META" herdr_session required) || exit 1
  HERDR_SCOPE_WORKSPACE=$(teardown_meta_value_exact "$META" herdr_workspace_id required) || exit 1
  HERDR_SCOPE_TAB=$(teardown_meta_value_exact "$META" herdr_tab_id required) || exit 1
  HERDR_SCOPE_PANE=$(teardown_meta_value_exact "$META" herdr_pane_id required) || exit 1
  [ "$T" = "$HERDR_SCOPE_SESSION:$HERDR_SCOPE_PANE" ] || {
    echo "REFUSED: task endpoint metadata representations conflict" >&2
    exit 1
  }
fi

teardown_endpoint_transaction_path() {
  local backend=$1 target=$2 generation=$3 key
  key=$(printf '%s' "$backend|$target|$generation" \
    | cksum | awk '{printf "%s-%s", $1, $2}') || return 1
  printf '%s/closing-endpoints/%s' "$TEARDOWN_TXN_DIR" "$key"
}

teardown_endpoint_close_is_staged() {
  local backend=$1 target=$2 generation=$3 record
  record=$(teardown_endpoint_transaction_path "$backend" "$target" "$generation") \
    || return 1
  [ -f "$record" ] && [ ! -L "$record" ] \
    && [ "$(sed -n '1p' "$record")" = "$backend" ] \
    && [ "$(sed -n '2p' "$record")" = "$target" ] \
    && [ "$(sed -n '3p' "$record")" = "$generation" ] \
    && [ "$(wc -l < "$record" | tr -d ' ')" -eq 3 ]
}

teardown_stage_endpoint_close() {
  local backend=$1 target=$2 generation=$3 record dir tmp
  [ -d "$TEARDOWN_TXN_DIR" ] || return 0
  record=$(teardown_endpoint_transaction_path "$backend" "$target" "$generation") \
    || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    teardown_endpoint_close_is_staged "$backend" "$target" "$generation"
    return
  fi
  dir=${record%/*}
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.endpoint.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$backend" "$target" "$generation" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$record" || {
    rm -f "$tmp"
    return 1
  }
}

teardown_home_transaction_path() {
  local id=$1 home=$2 key
  key=$(printf '%s' "$id|$home" | cksum | awk '{printf "%s-%s", $1, $2}') \
    || return 1
  printf '%s/removing-homes/%s' "$TEARDOWN_TXN_DIR" "$key"
}

teardown_home_removal_is_staged() {
  local id=$1 home=$2 record
  record=$(teardown_home_transaction_path "$id" "$home") || return 1
  [ -f "$record" ] && [ ! -L "$record" ] \
    && [ "$(sed -n '1p' "$record")" = "$id" ] \
    && [ "$(sed -n '2p' "$record")" = "$home" ] \
    && [ "$(wc -l < "$record" | tr -d ' ')" -eq 2 ]
}

teardown_stage_home_removal() {
  local id=$1 home=$2 record dir tmp
  [ -d "$TEARDOWN_TXN_DIR" ] || return 0
  record=$(teardown_home_transaction_path "$id" "$home") || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    teardown_home_removal_is_staged "$id" "$home"
    return
  fi
  dir=${record%/*}
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.home.XXXXXX") || return 1
  printf '%s\n%s\n' "$id" "$home" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$record" || {
    rm -f "$tmp"
    return 1
  }
}

teardown_endpoint_generation_matches() {
  local backend=$1 target=$2 generation=$3 meta=$4 actual session workspace tab pane expected
  TEARDOWN_ENDPOINT_ALREADY_CLOSED=0
  case "$backend" in
    tmux)
      actual=$(fm_backend_endpoint_generation tmux "$target" 2>/dev/null || true)
      if [ -n "$actual" ]; then
        [ "$actual" = "$generation" ]
      else
        teardown_endpoint_close_is_staged "$backend" "$target" "$generation" \
          && TEARDOWN_ENDPOINT_ALREADY_CLOSED=1
      fi
      ;;
    herdr)
      session=$(teardown_meta_value_exact "$meta" herdr_session required) || return 1
      workspace=$(teardown_meta_value_exact "$meta" herdr_workspace_id required) || return 1
      tab=$(teardown_meta_value_exact "$meta" herdr_tab_id required) || return 1
      pane=$(teardown_meta_value_exact "$meta" herdr_pane_id required) || return 1
      expected=$(printf '%s' "$session|$workspace|$tab|$pane" \
        | cksum | awk '{printf "herdr-%s-%s", $1, $2}') || return 1
      [ "$target" = "$session:$pane" ] && [ "$generation" = "$expected" ] || return 1
      if fm_backend_pane_readable herdr "$target"; then
        :
      else
        teardown_endpoint_close_is_staged "$backend" "$target" "$generation" \
          && TEARDOWN_ENDPOINT_ALREADY_CLOSED=1
      fi
      ;;
    *) return 1 ;;
  esac
}

META_IDENTITY=$(cksum "$META") || exit 1

trap teardown_locks_release EXIT
teardown_admission_lock_acquire "$STATE" "$FM_HOME" || exit 1
teardown_task_lock_acquire "$STATE" "$ID" || exit 1
[ "$(cksum "$META" 2>/dev/null || true)" = "$META_IDENTITY" ] || {
  echo "REFUSED: task metadata changed while teardown acquired lifecycle locks" >&2
  exit 1
}
teardown_endpoint_generation_matches "$BACKEND" "$T" "$ENDPOINT_GENERATION" "$META" || {
  echo "REFUSED: task endpoint generation is stale or cannot be verified; preserving task state" >&2
  exit 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)

validated_task_tmp_cleanup_path() {
  local recorded=$1 expected
  [ -n "$recorded" ] || return 0
  case "$ID" in
    ''|*[!A-Za-z0-9._-]*)
      echo "REFUSED: unsafe task id $ID for task temp cleanup" >&2
      return 1
      ;;
  esac
  expected="/tmp/fm-$ID"
  if [ "$recorded" != "$expected" ]; then
    echo "REFUSED: unsafe tasktmp $recorded for task $ID (expected $expected)" >&2
    return 1
  fi
  printf '%s\n' "$expected"
}

MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
TASK_TMP_CLEANUP=$(validated_task_tmp_cleanup_path "$TASK_TMP") || exit 1

validate_direct_pr_state_cleanup() {
  local artifact mode
  for artifact in "$STATE/$ID.direct-pr-lease" "$STATE/$ID.direct-pr-lease.tmp"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ -L "$artifact" ] || [ ! -f "$artifact" ] || [ ! -O "$artifact" ]; then
      echo "REFUSED: unsafe direct-PR task state $artifact; preserving task state." >&2
      return 1
    fi
    if [ "$artifact" = "$STATE/$ID.direct-pr-lease" ]; then
      mode=$(fm_pr_file_mode "$artifact") || return 1
      if [ "$mode" != 600 ]; then
        echo "REFUSED: unsafe direct-PR task state $artifact; preserving task state." >&2
        return 1
      fi
    fi
  done
}

DIRECT_PR_REF_GIT_DIR=
validate_direct_pr_ref_cleanup() {
  local candidate prefix ref refs
  [ "$MODE" = direct-PR ] || return 0
  for candidate in "$WT" "$PROJ"; do
    [ -d "$candidate" ] || continue
    git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 || continue
    DIRECT_PR_REF_GIT_DIR=$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir) || return 1
    break
  done
  [ -n "$DIRECT_PR_REF_GIT_DIR" ] || return 0
  prefix="refs/firstmate/direct-pr/$ID"
  refs=$(git --git-dir="$DIRECT_PR_REF_GIT_DIR" for-each-ref --format='%(refname)' "$prefix/") || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "$prefix/base"|"$prefix/feature") ;;
      *)
        echo "REFUSED: ambiguous direct-PR private ref namespace $prefix; preserving task state." >&2
        return 1
        ;;
    esac
  done <<EOF
$refs
EOF
}

cleanup_direct_pr_refs() {
  local prefix refs
  [ -n "$DIRECT_PR_REF_GIT_DIR" ] || return 0
  prefix="refs/firstmate/direct-pr/$ID"
  {
    printf 'delete %s\n' "$prefix/base"
    printf 'delete %s\n' "$prefix/feature"
  } | git --git-dir="$DIRECT_PR_REF_GIT_DIR" update-ref --stdin || return 1
  refs=$(git --git-dir="$DIRECT_PR_REF_GIT_DIR" for-each-ref --format='%(refname)' "$prefix/") || return 1
  [ -z "$refs" ]
}

TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-1}
case "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS" in
  ''|*[!0-9]*)
    echo "teardown: invalid transient-lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
    TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
    ;;
esac

treehouse_return_is_index_lock_error() {
  printf '%s\n' "$1" | grep -Fq 'index.lock' && printf '%s\n' "$1" | grep -Fq 'File exists'
}

teardown_stage_return_claim_record() {
  local claim=$1 legacy=$2 dir key record tmp
  case "$claim:$legacy" in *$'\n'*|*$'\r'*) return 1 ;; esac
  dir="$TEARDOWN_TXN_DIR/return-claims"
  mkdir -p "$dir" || return 1
  key=$(printf '%s' "$claim" | cksum | awk '{printf "%s-%s", $1, $2}') || return 1
  record="$dir/$key"
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] \
      && [ "$(sed -n '1p' "$record")" = "$claim" ] \
      && [ "$(sed -n '2p' "$record")" = "$legacy" ]
    return
  fi
  tmp=$(mktemp "$dir/.claim.XXXXXX") || return 1
  printf '%s\n%s\n' "$claim" "$legacy" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$record" || {
    rm -f "$tmp"
    return 1
  }
}

teardown_unstage_return_claim_record() {
  local claim=$1 key record
  key=$(printf '%s' "$claim" | cksum | awk '{printf "%s-%s", $1, $2}') || return 1
  record="$TEARDOWN_TXN_DIR/return-claims/$key"
  [ ! -e "$record" ] && [ ! -L "$record" ] || rm -f "$record"
}

teardown_load_staged_return_claims() {
  local record claim legacy seen existing
  [ -d "$TEARDOWN_TXN_DIR/return-claims" ] || return 0
  for record in "$TEARDOWN_TXN_DIR/return-claims"/*; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    [ "$(wc -l < "$record" | tr -d ' ')" -eq 2 ] || return 1
    claim=$(sed -n '1p' "$record")
    legacy=$(sed -n '2p' "$record")
    case "$claim:$legacy" in /*:/*) ;; *) return 1 ;; esac
    seen=0
    for existing in "${TEARDOWN_RETURN_CLAIMS[@]}"; do
      [ "$existing" != "$claim" ] || seen=1
    done
    if [ "$seen" -eq 0 ]; then
      TEARDOWN_RETURN_CLAIMS+=("$claim")
      TEARDOWN_RETURN_LEGACIES+=("$legacy")
    fi
  done
}

teardown_return_commit_transaction_path() {
  local claim=$1 key
  key=$(printf '%s' "$claim" | cksum | awk '{printf "%s-%s", $1, $2}') || return 1
  printf '%s/committed-return-claims/%s' "$TEARDOWN_TXN_DIR" "$key"
}

teardown_return_transaction_is_committed() {
  local claim=$1 legacy=$2 record
  record=$(teardown_return_commit_transaction_path "$claim") || return 1
  [ -f "$record" ] && [ ! -L "$record" ] \
    && [ "$(sed -n '1p' "$record")" = "$claim" ] \
    && [ "$(sed -n '2p' "$record")" = "$legacy" ] \
    && [ "$(wc -l < "$record" | tr -d ' ')" -eq 2 ]
}

teardown_mark_return_transaction_committed() {
  local claim=$1 legacy=$2 record dir tmp
  record=$(teardown_return_commit_transaction_path "$claim") || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    teardown_return_transaction_is_committed "$claim" "$legacy"
    return
  fi
  dir=${record%/*}
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.commit.XXXXXX") || return 1
  printf '%s\n%s\n' "$claim" "$legacy" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$record" || {
    rm -f "$tmp"
    return 1
  }
}

teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_check=${4:-} state_scope=${5:-}
  local stamp_id=${6:-} stamp_home=${7:-} lease_holder=${8:-}
  local out attempt=0 retries claim= legacy= stamp_path= staged=0 return_status
  retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$retries" in ''|*[!0-9]*) retries=3 ;; esac
  if [ -n "$post_check" ]; then
    "$post_check" || return 1
  fi
  if [ -n "$state_scope" ] && [ -n "$stamp_id" ] && [ -n "$stamp_home" ]; then
    [ -n "$lease_holder" ] || lease_holder=$stamp_id
    fm_slot_stamp_stage_return "$dir" "$stamp_id" "$stamp_home" "$state_scope" \
      "$lease_holder" || return 1
    staged=${FM_SLOT_RETURN_STAGED:-0}
    claim=${FM_SLOT_RETURN_CLAIM:-}
    legacy=${FM_SLOT_RETURN_LEGACY:-}
    stamp_path=${FM_SLOT_RETURN_STAMP_PATH:-}
    if [ "$staged" -eq 1 ] && [ "$TEARDOWN_DEFER_RETURN_FINALIZE" -eq 1 ]; then
      teardown_stage_return_claim_record "$claim" "$legacy" || return 1
      fm_slot_stamp_mark_return_committed "$claim" "$legacy" || return 1
    fi
  fi
  while :; do
    if [ -n "$lease_holder" ]; then
      out=$( ( cd "$cd_dir" && treehouse return --force "$dir" \
        --if-lease-holder "$lease_holder" ) 2>&1 ) && return_status=0 || return_status=$?
    else
      out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ) \
        && return_status=0 || return_status=$?
    fi
    if [ "$return_status" -eq 0 ]; then
      [ -n "$out" ] && printf '%s\n' "$out"
      if [ "$staged" -eq 1 ]; then
        if [ "$TEARDOWN_DEFER_RETURN_FINALIZE" -eq 1 ]; then
          teardown_mark_return_transaction_committed "$claim" "$legacy" || {
            echo "error: returned $label $dir but could not record its committed transition" >&2
            return 1
          }
          TEARDOWN_RETURN_CLAIMS+=("$claim")
          TEARDOWN_RETURN_LEGACIES+=("$legacy")
        elif ! fm_slot_stamp_finalize_return "$claim" "$legacy"; then
          echo "error: returned $label $dir but could not retire its transition claim" >&2
          return 1
        fi
      fi
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    if ! treehouse_return_is_index_lock_error "$out" || [ "$attempt" -ge "$retries" ]; then
      if [ "$staged" -eq 1 ]; then
        [ "$TEARDOWN_DEFER_RETURN_FINALIZE" -ne 1 ] \
          || fm_slot_stamp_unmark_return_committed "$claim" || {
            echo "error: could not roll back committed ownership evidence for $label $dir" >&2
            return 1
          }
        fm_slot_stamp_restore_return "$dir" "$stamp_id" "$stamp_home" "$claim" \
          "$lease_holder" "$stamp_path" "$legacy" || {
          echo "error: could not restore ownership evidence for $label $dir" >&2
        }
        [ "$TEARDOWN_DEFER_RETURN_FINALIZE" -ne 1 ] \
          || teardown_unstage_return_claim_record "$claim" || true
      fi
      return 1
    fi
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return hit a transient git index lock; retrying ($attempt/$retries)" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"
  done
}

teardown_commit_staged_returns() {
  local i
  for ((i=0; i<${#TEARDOWN_RETURN_CLAIMS[@]}; i++)); do
    if [ -e "${TEARDOWN_RETURN_CLAIMS[$i]}" ] \
       || [ -L "${TEARDOWN_RETURN_CLAIMS[$i]}" ]; then
      fm_slot_stamp_mark_return_committed \
        "${TEARDOWN_RETURN_CLAIMS[$i]}" "${TEARDOWN_RETURN_LEGACIES[$i]}" \
        || return 1
      teardown_mark_return_transaction_committed \
        "${TEARDOWN_RETURN_CLAIMS[$i]}" "${TEARDOWN_RETURN_LEGACIES[$i]}" \
        || return 1
    else
      teardown_return_transaction_is_committed \
        "${TEARDOWN_RETURN_CLAIMS[$i]}" "${TEARDOWN_RETURN_LEGACIES[$i]}" \
        || return 1
    fi
  done
}

teardown_reconcile_staged_returns() {
  local i
  for ((i=0; i<${#TEARDOWN_RETURN_CLAIMS[@]}; i++)); do
    fm_slot_stamp_reconcile_committed_return "${TEARDOWN_RETURN_CLAIMS[$i]}" || {
      echo "warning: committed return evidence remains for later reconciliation" >&2
    }
  done
  TEARDOWN_RETURN_CLAIMS=()
  TEARDOWN_RETURN_LEGACIES=()
}

if [ "$KIND" = ship ] && [ "$FORCE" != "--force" ]; then
  fm_assert_task_branch_matches_meta "$ID" "$META" "REFUSED" || exit 1
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" | cut -d= -f2- || true
}

teardown_herdr_endpoint_focus_safe() {
  local target=$1 session pane state lock attempt=0 held=0 close_status=1
  fm_backend_source herdr || return 1
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
  [ "$state" = dead ] && return 0
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      held=1
      break
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ "$held" = 1 ] || return 1
  if fm_backend_herdr_projection_teardown_close "$session" "$pane"; then
    close_status=0
  else
    close_status=$?
  fi
  fm_lock_release "$lock" || true
  return "$close_status"
}

teardown_backend_endpoint() {
  local backend=$1 target=$2
  case "$backend" in
    herdr) teardown_herdr_endpoint_focus_safe "$target" ;;
    *) fm_backend_kill "$backend" "$target" ;;
  esac
}

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact presentation meta expected_url has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.pr-poll-replacement" \
    "$state_dir/$id.pr-presentation" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.pr-poll-replacement" \
    "$state_dir/$id.pr-presentation" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  presentation="$state_dir/$id.pr-presentation"
  if [ -e "$presentation" ] || [ -L "$presentation" ]; then
    meta="$state_dir/$id.meta"
    fm_pr_metadata_identity_parse "$meta" && expected_url=$FM_PR_META_URL || {
      echo "REFUSED: task metadata cannot identify its PR-presentation receipt; preserving task state." >&2
      return 1
    }
    fm_pr_presentation_cleanup_parse "$presentation" \
      && [ "$FM_PR_PRESENTATION_URL" = "$expected_url" ] || {
        echo "REFUSED: invalid or foreign PR-presentation receipt; preserving task state." >&2
        return 1
      }
  fi
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
  if [ -e "$state_dir/$id.pr-poll-replacement" ] \
    || [ -L "$state_dir/$id.pr-poll-replacement" ]; then
    fm_pr_poll_replacement_parse "$state_dir/$id.pr-poll-replacement" \
      && fm_pr_poll_replacement_receipt_valid "$state_dir" "$id" \
        "$FM_PR_REPLACE_EXPECTED_HEAD" || {
          echo "REFUSED: invalid PR-poll replacement receipt; preserving task state." >&2
          return 1
        }
  fi
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.pr-poll-replacement" \
    "$state_dir/$id.pr-presentation" \
    "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  [ "$KIND" = secondmate ] && return 0
  if fm_tasks_axi_backend_available "$CONFIG"; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registration_verdict() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || { printf '%s\n' unknown; return; }
  [ -d "$project" ] || { printf '%s\n' unknown; return; }
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 \
    || { printf '%s\n' unknown; return; }
  abs_target=$(removal_target_abs_path "$target" 2>/dev/null) \
    || { printf '%s\n' unknown; return; }
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) \
    || { printf '%s\n' unknown; return; }
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && { printf '%s\n' registered; return; }
        ;;
    esac
  done <<EOF
$listed
EOF
  printf '%s\n' unregistered
}

firstmate_home_treehouse_slot_verdict() {
  worktree_registration_verdict "$FM_ROOT" "$1"
}

repository_origin_identity() {
  local repo=$1 origin repo_real
  repo_real=$(cd "$repo" && pwd -P) || return 1
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  case "$origin" in
    file:///*) origin=${origin#file://} ;;
    file://*) return 1 ;;
    *://*|*:*) printf '%s\n' "$origin"; return ;;
  esac
  case "$origin" in
    /*) removal_target_abs_path "$origin" ;;
    *) removal_target_abs_path "$repo_real/$origin" ;;
  esac
}

plain_legacy_firstmate_clone() {
  local target=$1 target_common root_origin target_origin entry
  fm_slot_is_plain_checkout "$target" || return 1
  target_common=$(git -C "$target" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$target_common" in
    /*) ;;
    *) target_common="$target/$target_common" ;;
  esac
  target_common=$(removal_target_abs_path "$target_common" 2>/dev/null) || return 1
  root_origin=$(repository_origin_identity "$FM_ROOT") || return 1
  target_origin=$(repository_origin_identity "$target") || return 1
  [ "$root_origin" = "$target_origin" ] || return 1
  [ ! -e "$target_common/$FM_SLOT_OWNER_STAMP_NAME" ] \
    && [ ! -L "$target_common/$FM_SLOT_OWNER_STAMP_NAME" ] || return 1
  if [ -d "$target_common/worktrees" ]; then
    for entry in "$target_common"/worktrees/*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] || return 1
    done
  fi
}

require_treehouse_return_capability() {
  local label=$1 target=$2 lease_holder=${3:-}
  command -v treehouse >/dev/null 2>&1 || {
    echo "REFUSED: treehouse command not found; preserving $label $target and all lifecycle state" >&2
    return 1
  }
  if [ -n "$lease_holder" ] \
    && ! treehouse return --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--if-lease-holder([^[:alnum:]_-]|$)'; then
    echo "REFUSED: conditional Treehouse lease-holder return is unavailable; preserving $label $target and all lifecycle state" >&2
    return 1
  fi
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 label=${3:-child worktree} abs_target abs_home abs_root registration
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "$label") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  registration=$(worktree_registration_verdict "$project" "$target")
  [ "$registration" = registered ] || {
    echo "REFUSED: unsafe $label removal target $target has ${registration} git worktree registration for ${project:-the recorded project}" >&2
    return 1
  }
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

TEARDOWN_SLOT_RETAINED=0
TEARDOWN_SLOT_RETAIN_VERDICT=
slot_release_allowed() {  # <state-dir> <task-id> <worktree> <stamp-home> <worker-home> <role> <label> <retire|refuse>
  local state=$1 id=$2 wt=$3 stamp_home=$4 worker_home=$5 role=$6 label=$7 disposition=$8 verdict
  TEARDOWN_SLOT_RETAIN_VERDICT=
  case "$disposition" in
    retire|refuse) ;;
    *)
      echo "error: slot gate for $label $wt was asked for an unknown disposition '$disposition'" >&2
      return 1
      ;;
  esac
  verdict=$(fm_slot_disposal_verdict "$state" "$id" "$wt" "$stamp_home" "$worker_home" "$role")
  [ "$verdict" = dispose ] && return 0
  TEARDOWN_SLOT_RETAINED=1
  echo "teardown: $label $wt lease RETAINED, not returned to the pool: ${verdict#retain: }" >&2
  echo "teardown: the directory is left untouched on disk; --force does not waive this ownership gate." >&2
  if [ "$disposition" = retire ]; then
    TEARDOWN_SLOT_RETAIN_VERDICT=$verdict
    echo "teardown: once nothing references the slot, tearing down its remaining holder releases it; docs/worker-isolation.md owns manual reclaim." >&2
  else
    echo "teardown: refusing to continue for $label $wt and leaving every record for $id in place." >&2
  fi
  return 1
}

require_secondmate_slot_claim() {
  local wt=$1 id=$2 owner_home=$3 label=$4
  if fm_slot_stamp_record "$wt"; then
    [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
      && fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$owner_home" || {
        echo "REFUSED: $label $wt ownership stamp does not prove lease holder $id" >&2
        return 1
      }
    return 0
  fi
  fm_slot_return_claim_record "$wt" \
    && [ "$FM_SLOT_RETURN_CLAIM_TASK" = "$id" ] \
    && [ "$FM_SLOT_RETURN_CLAIM_HOLDER" = "$id" ] \
    && fm_slot_same_path "$FM_SLOT_RETURN_CLAIM_HOME" "$owner_home" || {
      echo "REFUSED: $label $wt has no complete ownership or return-transition claim for lease holder $id" >&2
      return 1
    }
}

remove_firstmate_home() {  # <home> <label> [expected-id] [state-dir] [home-scope]
  local home=$1 label=$2 expected_id=${3:-} state_scope=${4:-$STATE} home_scope=${5:-$FM_HOME} abs_home_path slot_verdict
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  teardown_stage_home_removal "${expected_id:-$ID}" "$abs_home_path" || return 1
  slot_verdict=$(firstmate_home_treehouse_slot_verdict "$abs_home_path")
  case "$slot_verdict" in
    registered)
      command -v treehouse >/dev/null 2>&1 || {
        echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
        return 1
      }
      require_secondmate_slot_claim "$abs_home_path" "${expected_id:-$ID}" \
        "$home_scope" "$label" || return 1
      slot_release_allowed "$state_scope" "${expected_id:-$ID}" "$abs_home_path" \
        "$home_scope" "$abs_home_path" secondmate "$label" refuse || return 1
      teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" "" \
        "$state_scope" "${expected_id:-$ID}" "$home_scope" "${expected_id:-$ID}" || {
        echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
        return 1
      }
      ;;
    unregistered)
      plain_legacy_firstmate_clone "$abs_home_path" || {
        echo "REFUSED: unregistered $label $abs_home_path is not a proven plain legacy clone without foreign ownership evidence" >&2
        return 1
      }
      safe_rm_rf "$abs_home_path" "$label" || return 1
      ;;
    *)
      echo "REFUSED: pooled-slot classification is unknown for $label $abs_home_path" >&2
      return 1
      ;;
  esac
}

teardown_stage_evidence_home() {
  local home=$1 prefix=$2 meta child_id child_kind child_home index=0 dest state_entry
  [ -d "$home/state" ] || return 0
  for meta in "$home/state"/*.meta; do
    [ -e "$meta" ] || continue
    child_id=$(basename "$meta" .meta)
    dest="$TEARDOWN_TXN_DIR/evidence/$prefix/$index"
    mkdir -p "$dest" || return 1
    printf '%s\n' "$meta" > "$dest/source" || return 1
    cp -p "$meta" "$dest/meta" || return 1
    for state_entry in "$home/state/$child_id".*; do
      [ -f "$state_entry" ] && [ ! -L "$state_entry" ] || continue
      cp -p "$state_entry" "$dest/" || return 1
    done
    if [ -f "$home/.firstmate-owner" ] && [ ! -L "$home/.firstmate-owner" ]; then
      cp -p "$home/.firstmate-owner" "$dest/firstmate-owner" || return 1
    fi
    if [ -f "$home/.firstmate-owner.returning" ] \
       && [ ! -L "$home/.firstmate-owner.returning" ]; then
      cp -p "$home/.firstmate-owner.returning" \
        "$dest/firstmate-owner.returning" || return 1
    fi
    child_kind=$(teardown_meta_value_exact "$meta" kind required) || return 1
    if [ "$child_kind" = secondmate ]; then
      child_home=$(teardown_meta_value_exact "$meta" home required) || return 1
      teardown_stage_evidence_home "$child_home" "$prefix-$child_id" || return 1
    fi
    index=$((index + 1))
  done
}

teardown_stage_hierarchy_evidence() {
  local parent tmp state_entry
  if [ -d "$TEARDOWN_TXN_DIR" ] && [ ! -L "$TEARDOWN_TXN_DIR" ]; then
    return 0
  fi
  [ ! -e "$TEARDOWN_TXN_DIR" ] && [ ! -L "$TEARDOWN_TXN_DIR" ] || return 1
  parent=${TEARDOWN_TXN_DIR%/*}
  mkdir -p "$parent" || return 1
  tmp=$(mktemp -d "$parent/.${ID}.XXXXXX") || return 1
  TEARDOWN_TXN_DIR=$tmp
  mkdir -p "$TEARDOWN_TXN_DIR/evidence/top" || return 1
  printf '%s\n' "$META" > "$TEARDOWN_TXN_DIR/evidence/top/source" || return 1
  cp -p "$META" "$TEARDOWN_TXN_DIR/evidence/top/meta" || return 1
  for state_entry in "$STATE/$ID".*; do
    [ -f "$state_entry" ] && [ ! -L "$state_entry" ] || continue
    cp -p "$state_entry" "$TEARDOWN_TXN_DIR/evidence/top/" || return 1
  done
  if [ -f "$HOME_PATH/.firstmate-owner" ] \
     && [ ! -L "$HOME_PATH/.firstmate-owner" ]; then
    cp -p "$HOME_PATH/.firstmate-owner" \
      "$TEARDOWN_TXN_DIR/evidence/top/firstmate-owner" || return 1
  fi
  if [ "$KIND" = secondmate ]; then
    teardown_stage_evidence_home "$HOME_PATH" home || return 1
  fi
  mv "$TEARDOWN_TXN_DIR" "$parent/$ID" || return 1
  TEARDOWN_TXN_DIR="$parent/$ID"
}

teardown_stage_transaction_evidence() {
  local path index=0 ref oid
  teardown_stage_hierarchy_evidence || return 1
  mkdir -p "$TEARDOWN_TXN_DIR/evidence/ownership" \
    "$TEARDOWN_TXN_DIR/evidence/direct-refs" || return 1
  for path in \
    "$(fm_slot_stamp_path "$WT" 2>/dev/null || true)" \
    "$(fm_slot_return_claim_path "$WT" 2>/dev/null || true)" \
    "$(fm_slot_return_legacy_path "$WT" 2>/dev/null || true)"; do
    [ -n "$path" ] || continue
    [ -e "$path" ] || [ -L "$path" ] || continue
    printf '%s\n' "$path" > "$TEARDOWN_TXN_DIR/evidence/ownership/$index.path" || return 1
    cp -a "$path" "$TEARDOWN_TXN_DIR/evidence/ownership/$index.value" || return 1
    index=$((index + 1))
  done
  [ -n "$DIRECT_PR_REF_GIT_DIR" ] || return 0
  for ref in "refs/firstmate/direct-pr/$ID/base" "refs/firstmate/direct-pr/$ID/feature"; do
    oid=$(git --git-dir="$DIRECT_PR_REF_GIT_DIR" rev-parse --verify "$ref" 2>/dev/null || true)
    [ -n "$oid" ] || continue
    printf '%s\n%s\n' "$ref" "$oid" \
      > "$TEARDOWN_TXN_DIR/evidence/direct-refs/$index" || return 1
    index=$((index + 1))
  done
  printf '%s\n' "$DIRECT_PR_REF_GIT_DIR" \
    > "$TEARDOWN_TXN_DIR/evidence/direct-refs/git-dir" || return 1
}

teardown_restore_transaction_evidence() {
  local top source item path value git_dir ref oid
  [ -d "$TEARDOWN_TXN_DIR/evidence" ] || return 0
  top="$TEARDOWN_TXN_DIR/evidence/top"
  source=$(cat "$top/source" 2>/dev/null || true)
  if [ -n "$source" ]; then
    mkdir -p "$(dirname "$source")" || return 1
    for item in "$top"/"$ID".*; do
      [ -f "$item" ] || continue
      cp -p "$item" "$(dirname "$source")/$(basename "$item")" || return 1
    done
  fi
  for item in "$TEARDOWN_TXN_DIR/evidence/ownership/"*.path; do
    [ -f "$item" ] || continue
    path=$(cat "$item") || return 1
    value="${item%.path}.value"
    mkdir -p "$(dirname "$path")" || return 1
    rm -f "$path" || return 1
    cp -a "$value" "$path" || return 1
  done
  git_dir=$(cat "$TEARDOWN_TXN_DIR/evidence/direct-refs/git-dir" 2>/dev/null || true)
  [ -n "$git_dir" ] || return 0
  for item in "$TEARDOWN_TXN_DIR/evidence/direct-refs/"[0-9]*; do
    [ -f "$item" ] || continue
    ref=$(sed -n '1p' "$item")
    oid=$(sed -n '2p' "$item")
    git --git-dir="$git_dir" update-ref "$ref" "$oid" || return 1
  done
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_backend child_wt child_proj child_kind child_home slot_verdict
  sub_state="$home/state"
  teardown_admission_lock_acquire "$sub_state" "$home" || return 1
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    teardown_task_lock_acquire "$sub_state" "$child_id" || return 1
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    teardown_child_meta_read "$child_meta" "$child_id" "$home" || return 1
    child_backend=$TEARDOWN_CHILD_BACKEND
    child_wt=$TEARDOWN_CHILD_WORKTREE
    child_proj=$TEARDOWN_CHILD_PROJECT
    child_kind=$TEARDOWN_CHILD_KIND
    teardown_endpoint_generation_matches "$child_backend" "$TEARDOWN_CHILD_WINDOW" \
      "$TEARDOWN_CHILD_ENDPOINT_GENERATION" "$child_meta" || {
      echo "REFUSED: child $child_id endpoint generation is stale or cannot be verified" >&2
      return 1
    }
    if [ "$child_kind" = secondmate ]; then
      child_home=$TEARDOWN_CHILD_HOME
      if [ ! -e "$child_home" ] \
         && teardown_home_removal_is_staged "$child_id" "$child_home"; then
        continue
      fi
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      if ! fm_pending_reply_task_force_retirable "$sub_state" "$child_id"; then
        echo "REFUSED: child secondmate $child_id has a pending reply that has not reached escalation." >&2
        return 1
      fi
      validate_firstmate_home_children_removal "$child_home" || return 1
      slot_verdict=$(firstmate_home_treehouse_slot_verdict "$child_home")
      case "$slot_verdict" in
        registered)
          require_treehouse_return_capability "child firstmate home" "$child_home" "$child_id" || return 1
          require_secondmate_slot_claim "$child_home" "$child_id" "$home" \
            "child firstmate home" || return 1
          slot_release_allowed "$sub_state" "$child_id" "$child_home" "$home" "$child_home" \
            secondmate "child firstmate home" refuse || return 1
          ;;
        unregistered)
          if ! plain_legacy_firstmate_clone "$child_home"; then
            echo "REFUSED: unregistered child secondmate home is not a proven plain legacy clone: $child_home" >&2
            return 1
          fi
          ;;
        *)
          echo "REFUSED: pooled-slot classification is unknown for child firstmate home $child_home" >&2
          return 1
          ;;
      esac
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      require_treehouse_return_capability "child worktree" "$child_wt" || return 1
    fi
  done
}

teardown_child_meta_read() {
  local meta=$1 expected_id=$2 expected_home=$3 task home
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || {
    echo "REFUSED: child metadata is missing, unreadable, or not a regular file: $meta" >&2
    return 1
  }
  TEARDOWN_CHILD_WINDOW=$(teardown_meta_value_exact "$meta" window required) || return 1
  TEARDOWN_CHILD_WORKTREE=$(teardown_meta_value_exact "$meta" worktree required) || return 1
  TEARDOWN_CHILD_PROJECT=$(teardown_meta_value_exact "$meta" project required) || return 1
  TEARDOWN_CHILD_KIND=$(teardown_meta_value_exact "$meta" kind required) || return 1
  task=$(teardown_meta_value_exact "$meta" task required) || return 1
  home=$(teardown_meta_value_exact "$meta" home required) || return 1
  TEARDOWN_CHILD_ENDPOINT_GENERATION=$(teardown_meta_value_exact \
    "$meta" endpoint_generation required) || return 1
  TEARDOWN_CHILD_BACKEND=$(teardown_meta_value_exact "$meta" backend optional) || return 1
  [ -n "$TEARDOWN_CHILD_BACKEND" ] || TEARDOWN_CHILD_BACKEND=tmux
  [ "$task" = "$expected_id" ] || {
    echo "REFUSED: child metadata identity does not match $expected_id" >&2
    return 1
  }
  case "$TEARDOWN_CHILD_KIND" in ship|scout|secondmate) ;; *) return 1 ;; esac
  case "$TEARDOWN_CHILD_WORKTREE" in /*) ;; *) return 1 ;; esac
  case "$TEARDOWN_CHILD_PROJECT" in /*) ;; *) return 1 ;; esac
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$TEARDOWN_CHILD_ENDPOINT_GENERATION" in
    *[!A-Za-z0-9._-]*|""|*/*) return 1 ;;
  esac
  if ! fm_backend_validate "$TEARDOWN_CHILD_BACKEND" >/dev/null 2>&1; then
    echo "REFUSED: child $expected_id uses unsupported backend '$TEARDOWN_CHILD_BACKEND'; refusing force teardown" >&2
    return 1
  fi
  if [ "$TEARDOWN_CHILD_KIND" = secondmate ]; then
    fm_slot_same_path "$home" "$TEARDOWN_CHILD_WORKTREE" || return 1
  else
    fm_slot_same_path "$home" "$expected_home" || return 1
  fi
  TEARDOWN_CHILD_HOME=$home
}

validate_child_backend() {
  local child_id=$1 child_meta=$2 child_backend
  child_backend=$(fm_backend_of_meta "$child_meta")
  if ! fm_backend_validate "$child_backend" >/dev/null 2>&1; then
    echo "REFUSED: child $child_id uses unsupported backend '$child_backend'; refusing force teardown" >&2
    return 1
  fi
  printf '%s\n' "$child_backend"
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_backend child_t child_wt child_proj child_kind child_home
  local child_retire_staged child_retire_source child_resolved_handoff child_slot_retain_verdict
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    teardown_child_meta_read "$child_meta" "$child_id" "$home" || return 1
    child_backend=$TEARDOWN_CHILD_BACKEND
    child_t=$TEARDOWN_CHILD_WINDOW
    child_wt=$TEARDOWN_CHILD_WORKTREE
    child_proj=$TEARDOWN_CHILD_PROJECT
    child_kind=$TEARDOWN_CHILD_KIND
    child_retire_staged=0
    child_retire_source=
    child_resolved_handoff=0
    child_slot_retain_verdict=
    if [ "$child_kind" = secondmate ]; then
      child_retire_source=$(fm_pending_reply_source_identity "$sub_state") || return 1
      if fm_pending_reply_task_has_open "$sub_state" "$child_id"; then
        if ! fm_pending_reply_stage_force_retire_task "$sub_state" "$child_id" "$STATE"; then
          echo "REFUSED: could not stage pending replies for child secondmate $child_id." >&2
          return 1
        fi
        child_retire_staged=1
      fi
      if ! fm_pending_reply_handoff_resolved_task_history \
        "$sub_state" "$child_id" "$STATE" "$child_retire_source" child_resolved_handoff; then
        echo "REFUSED: could not hand off resolved reply history for child secondmate $child_id." >&2
        return 1
      fi
      [ "$child_resolved_handoff" = 0 ] || child_retire_staged=1
      if [ "$child_retire_staged" = 1 ]; then
        TEARDOWN_PENDING_STATES+=("$sub_state")
        TEARDOWN_PENDING_IDS+=("$child_id")
        TEARDOWN_PENDING_SOURCES+=("$child_retire_source")
      fi
    fi
    teardown_endpoint_generation_matches "$child_backend" "$child_t" \
      "$TEARDOWN_CHILD_ENDPOINT_GENERATION" "$child_meta" || {
      echo "REFUSED: child $child_id endpoint generation changed before cleanup" >&2
      return 1
    }
    if [ -n "$child_t" ]; then
      teardown_stage_endpoint_close \
        "$child_backend" "$child_t" "$TEARDOWN_CHILD_ENDPOINT_GENERATION" || return 1
      if [ "$TEARDOWN_ENDPOINT_ALREADY_CLOSED" -ne 1 ] \
         && ! teardown_backend_endpoint "$child_backend" "$child_t" 2>/dev/null; then
        echo "REFUSED: could not kill child $child_id window $child_t; refusing to delete child state" >&2
        return 1
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$TEARDOWN_CHILD_HOME
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home" || return 1
        teardown_commit_staged_returns || return 1
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" \
          "$sub_state" "$home" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      if slot_release_allowed "$sub_state" "$child_id" "$child_wt" "$home" "$home" \
        crewmate "child worktree" retire; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        command -v treehouse >/dev/null 2>&1 || {
          echo "REFUSED: treehouse command not found; preserving child worktree $child_wt and its metadata" >&2
          return 1
        }
        teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" \
          "" "$sub_state" "$child_id" "$home" || return 1
      else
        child_slot_retain_verdict=$TEARDOWN_SLOT_RETAIN_VERDICT
      fi
    fi
    if [ -n "$child_slot_retain_verdict" ]; then
      TEARDOWN_RELINQUISH_WTS+=("$child_wt")
      TEARDOWN_RELINQUISH_IDS+=("$child_id")
      TEARDOWN_RELINQUISH_HOMES+=("$home")
      TEARDOWN_RELINQUISH_VERDICTS+=("$child_slot_retain_verdict")
    fi
  done
}

teardown_finalize_hierarchy_state() {
  local i
  for ((i=0; i<${#TEARDOWN_PENDING_STATES[@]}; i++)); do
    fm_pending_reply_finalize_force_retire_task \
      "${TEARDOWN_PENDING_STATES[$i]}" "${TEARDOWN_PENDING_IDS[$i]}" "$STATE" \
      "${TEARDOWN_PENDING_SOURCES[$i]}" || return 1
  done
  for ((i=0; i<${#TEARDOWN_RELINQUISH_WTS[@]}; i++)); do
    fm_slot_stamp_relinquish \
      "${TEARDOWN_RELINQUISH_WTS[$i]}" "${TEARDOWN_RELINQUISH_IDS[$i]}" \
      "${TEARDOWN_RELINQUISH_HOMES[$i]}" "${TEARDOWN_RELINQUISH_VERDICTS[$i]}" \
      || return 1
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  if [ ! -e "$HOME_PATH" ] \
     && teardown_home_removal_is_staged "$ID" "$HOME_PATH"; then
    TOP_HOME_ALREADY_RETURNED=1
  else
    validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
    teardown_admission_lock_acquire "$HOME_PATH/state" "$HOME_PATH" || exit 1
    TOP_HOME_SLOT_VERDICT=$(firstmate_home_treehouse_slot_verdict "$HOME_PATH")
    case "$TOP_HOME_SLOT_VERDICT" in
      registered)
        require_treehouse_return_capability "secondmate home" "$HOME_PATH" "$ID" || exit 1
        require_secondmate_slot_claim "$HOME_PATH" "$ID" "$FM_HOME" \
          "secondmate home" || exit 1
        slot_release_allowed "$STATE" "$ID" "$HOME_PATH" "$FM_HOME" "$HOME_PATH" \
          secondmate "secondmate home" refuse || exit 1
        ;;
      unregistered)
        if ! plain_legacy_firstmate_clone "$HOME_PATH"; then
          echo "REFUSED: unregistered secondmate home is not a proven plain legacy clone: $HOME_PATH" >&2
          exit 1
        fi
        ;;
      *)
        echo "REFUSED: pooled-slot classification is unknown for secondmate home $HOME_PATH" >&2
        exit 1
        ;;
    esac
  fi
  if [ "$TOP_HOME_ALREADY_RETURNED" -eq 1 ]; then
    :
  elif [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  elif [ -d "$HOME_PATH/state" ]; then
    for child_meta in "$HOME_PATH/state"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $HOME_PATH/state." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
  if fm_pending_reply_task_has_open "$STATE" "$ID"; then
    FORCE_RETIRE_SOURCE=$(fm_pending_reply_source_identity "$STATE") || exit 1
    if [ "$FORCE" != "--force" ]; then
      echo "REFUSED: secondmate $ID still has an open pending reply in $STATE/pending-replies." >&2
      echo "Wait for a correlated report or escalation before captain-approved forced teardown." >&2
      exit 1
    fi
    PARENT_PENDING_OPEN=1
  fi
  teardown_stage_hierarchy_evidence || {
    echo "REFUSED: could not stage durable hierarchy evidence" >&2
    exit 1
  }
  teardown_load_staged_return_claims || {
    echo "REFUSED: staged hierarchy return claims are ambiguous" >&2
    exit 1
  }
  TEARDOWN_DEFER_RETURN_FINALIZE=1
  if [ "$PARENT_PENDING_OPEN" -eq 1 ]; then
    if fm_pending_reply_stage_force_retire_task "$STATE" "$ID"; then
      FORCE_RETIRE_STAGED=1
    else
      echo "REFUSED: secondmate $ID pending reply could not be staged for retirement." >&2
      exit 1
    fi
  fi
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = secondmate ]; then
    :
  elif [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$DATA/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true)
    # Reachability test: is HEAD reachable from ANY remote-tracking branch? Empty
    # means the work is already pushed (a fork is a remote too, so upstream-
    # contribution PRs pushed to a fork pass here). Non-empty does NOT prove the work
    # is unlanded: a squash or rebase merge rewrites the branch into a new commit on
    # the default branch, and a repo that auto-deletes the head branch on merge also
    # drops its remote-tracking ref - so a merged-and-deleted branch trips this test
    # while being fully landed. We therefore treat reachability as a fast accept, not
    # the sole verdict, and fall through to a landed-work check before refusing.
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
      # local-only ships have no remote in the common case, so the "on a remote"
      # test above is expected to be non-empty. The work is safe once it is merged
      # into the local default branch (firstmate does that merge on the captain's
      # approval). Refuse until then.
      DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
      unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
      if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
        echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
        [ -n "$dirty" ] && echo "uncommitted changes present" >&2
        [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
        echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    elif [ -n "$dirty" ]; then
      # Uncommitted changes are never landed and the reset would discard them; always
      # refuse, regardless of whether the committed work itself has landed.
      echo "REFUSED: worktree $WT has uncommitted changes." >&2
      echo "uncommitted changes present" >&2
      echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    elif [ -n "$unpushed" ]; then
      # Commits not reachable from any remote. Before refusing, recognize LANDED work:
      # a merged PR whose head contains the current local work, or content already in
      # the up-to-date default branch. On a gh lookup error work_is_landed falls back
      # to the content check, and if that is also inconclusive it returns false - so
      # we never silently allow teardown of possibly-unlanded work; only genuinely
      # unlanded work is refused.
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      if ! work_is_landed "$branch"; then
        echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
        printf 'unpushed commits:\n%s\n' "$unpushed" >&2
        echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    fi
  fi
fi

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1
validate_direct_pr_state_cleanup || exit 1
validate_direct_pr_ref_cleanup || exit 1
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ -d "$WT" ]; then
  validate_child_worktree_for_removal "$WT" "$PROJ" "worktree" >/dev/null || exit 1
  require_treehouse_return_capability "worktree" "$WT" || exit 1
fi
TEARDOWN_DEFER_RETURN_FINALIZE=1
teardown_load_staged_return_claims || {
  echo "REFUSED: staged teardown return claims are ambiguous" >&2
  exit 1
}
teardown_stage_transaction_evidence || {
  echo "REFUSED: could not stage recoverable teardown evidence" >&2
  exit 1
}

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_WORKSPACE=
if [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || {
    echo "REFUSED: could not load Herdr teardown support for $ID; preserving task state and worktree" >&2
    exit 1
  }
  fm_backend_herdr_parse_target "$T" || {
    echo "REFUSED: invalid Herdr target $T for $ID; preserving task state and worktree" >&2
    exit 1
  }
fi
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  HERDR_META_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_META_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_META_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_META_PANE" ] \
     && [ "$T" = "$HERDR_META_SESSION:$HERDR_META_PANE" ]; then
    if fm_backend_herdr_projection_endpoint_matches_journal \
      "$HERDR_META_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
      "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
      HERDR_PRESENTATION_RETIRE_CANDIDATE=1
    fi
  fi
fi

if [ "$BACKEND" = herdr ]; then
  teardown_endpoint_generation_matches "$BACKEND" "$T" "$ENDPOINT_GENERATION" "$META" || {
    echo "REFUSED: task endpoint generation changed before cleanup; preserving task state" >&2
    exit 1
  }
  teardown_stage_endpoint_close "$BACKEND" "$T" "$ENDPOINT_GENERATION" || {
    echo "REFUSED: could not stage exact endpoint retirement for $ID" >&2
    exit 1
  }
  if [ "$TEARDOWN_ENDPOINT_ALREADY_CLOSED" -ne 1 ] \
     && ! teardown_herdr_endpoint_focus_safe "$T"; then
    echo "REFUSED: exact focus-safe Herdr task-pane close could not be confirmed for $ID; preserving task state and worktree" >&2
    exit 1
  fi
  if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  elif [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
    echo "warning: herdr presentation journal for $ID remains quarantined; no workspace cleanup was attempted" >&2
  fi
elif [ "$BACKEND" != orca ]; then
  teardown_endpoint_generation_matches "$BACKEND" "$T" "$ENDPOINT_GENERATION" "$META" || {
    echo "REFUSED: task endpoint generation changed before cleanup; preserving task state" >&2
    exit 1
  }
  teardown_stage_endpoint_close "$BACKEND" "$T" "$ENDPOINT_GENERATION" || {
    echo "REFUSED: could not stage exact endpoint retirement for $ID" >&2
    exit 1
  }
  if [ "$TEARDOWN_ENDPOINT_ALREADY_CLOSED" -ne 1 ] \
     && ! teardown_backend_endpoint "$BACKEND" "$T" 2>/dev/null; then
    echo "REFUSED: could not kill task $ID window $T; refusing to delete task state or worktree" >&2
    exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  if ! cleanup_firstmate_home_children "$HOME_PATH"; then
    echo "REFUSED: child cleanup failed for secondmate $ID; preserving parent state and home" >&2
    exit 1
  fi
  teardown_commit_staged_returns || {
    echo "error: child retirement commit could not be recorded" >&2
    exit 1
  }
fi

# Ownership gate first. A retained lease leaves the slot untouched while the
# rest of teardown retires this task's endpoint and records.
if [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  TOP_SLOT_RETAIN_VERDICT=
  if slot_release_allowed "$STATE" "$ID" "$WT" "$FM_HOME" "$FM_HOME" \
    crewmate "worktree" retire; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "REFUSED: treehouse command not found; preserving worktree $WT and its metadata" >&2
      exit 1
    }
    # Kills remaining processes in the worktree (including the agent), resets, returns
    # to pool. treehouse resolves the pool from the working directory, so run it from
    # the project. teardown_treehouse_return tolerates transient and stale git locks
    # left by a killed crew process; see the script header for retry and stale-lock proof.
    post_lock_cleanup_check=
    if [ "$FORCE" != "--force" ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ]; then
      post_lock_cleanup_check=validate_worktree_teardown_safety
    fi
    teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" \
      "$STATE" "$ID" "$FM_HOME" || {
      echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
      exit 1
    }
  else
    TOP_SLOT_RETAIN_VERDICT=$TEARDOWN_SLOT_RETAIN_VERDICT
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" || exit 1
fi
cleanup_direct_pr_refs || {
  echo "REFUSED: transactional direct-PR private ref cleanup failed for $ID; preserving task state" >&2
  exit 1
}
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
remove_grok_turnend_auth "$STATE" "$ID"
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP_CLEANUP" ] && rm -rf -- "$TASK_TMP_CLEANUP"
if [ "$KIND" = secondmate ]; then
  teardown_commit_staged_returns || {
    echo "error: secondmate retirement commit could not be recorded" >&2
    exit 1
  }
  teardown_finalize_hierarchy_state || {
    echo "error: secondmate hierarchy retirement remains recoverably staged" >&2
    exit 1
  }
  if [ "$FORCE_RETIRE_STAGED" = 1 ] \
     && ! fm_pending_reply_finalize_force_retire_task \
       "$STATE" "$ID" "$STATE" "$FORCE_RETIRE_SOURCE"; then
    echo "error: secondmate pending-reply retirement remains recoverably staged" >&2
    exit 1
  fi
  remove_secondmate_registry_entry "$ID" || exit 1
fi
teardown_commit_staged_returns || {
  echo "error: teardown return commit could not be recorded; preserving ownership evidence and task state" >&2
  exit 1
}
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token" \
  "$STATE/$ID.direct-pr-lease" "$STATE/$ID.direct-pr-lease.tmp"
if [ -n "${TOP_SLOT_RETAIN_VERDICT:-}" ]; then
  fm_slot_stamp_relinquish "$WT" "$ID" "$FM_HOME" "$TOP_SLOT_RETAIN_VERDICT" || exit 1
fi
teardown_reconcile_staged_returns
TEARDOWN_TXN_COMMITTED=1
rm -rf -- "$TEARDOWN_TXN_DIR"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
if [ "$TEARDOWN_SLOT_RETAINED" = 1 ]; then
  echo "teardown $ID complete (window $T, worktree $WT retained on disk - its lease was retired, not returned)"
else
  echo "teardown $ID complete (window $T, worktree $WT)"
fi
backlog_refresh_reminder
