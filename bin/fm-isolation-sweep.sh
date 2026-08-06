#!/usr/bin/env bash
# fm-isolation-sweep.sh - re-assert task-worker isolation for a whole home,
# after a restart, restore, or resume.
#
# Spawn asserts isolation once, at launch. That assertion does not survive a
# restore: after the 2026-07-24 reboot a session provider restored every pane by
# resuming its recorded agent session but resolved each working directory back
# to the repository the worktree was derived from, collapsing 17 of 17 isolated
# worktrees onto their origin - four of them into the firstmate PRIMARY
# checkout. Isolation therefore has to be re-established from live evidence on
# every resume, not assumed from the launch that happened before the reboot.
#
# This sweep is READ-ONLY. It exits nonzero when it prints an actionable
# `ISOLATION:` line per task whose live agent process is provably not where its
# record says it is or whose isolation cannot be proved from an authoritative
# process reading, so bin/fm-bootstrap.sh can surface it in the session-start
# digest exactly like TANGLE.
#
# Evidence discipline (bin/fm-agent-cwd-lib.sh owns the method of record): a
# collapse is reported only from an AUTHORITATIVE process-interface reading of
# the agent process. A provider's pane cwd is never promoted to evidence here,
# because a pane field naming the wrong process is precisely what produced a
# false isolation violation on 2026-07-25.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# Usage: fm-isolation-sweep.sh
#   FM_ISOLATION_VERBOSE=1  also print successful BOOTSTRAP_INFO proof facts.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-agent-cwd-lib.sh
. "$SCRIPT_DIR/fm-agent-cwd-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ -d "$STATE" ] || exit 0

has_task_metadata=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  has_task_metadata=1
  break
done
[ "$has_task_metadata" -eq 1 ] || exit 0

HOME_REAL=$(fm_agent_canonical_dir "$FM_HOME") || HOME_REAL=$FM_HOME
ROOT_REAL=$(fm_agent_canonical_dir "$FM_ROOT") || ROOT_REAL=$FM_ROOT

# One process-list walk for the whole sweep (procfs on Linux, ps on macOS),
# reused for every task below. Asking per task instead costs a full walk each
# time - O(tasks x processes) of forked environment reads on the session-start
# critical path, and the incident this sweep exists for had 17 concurrent
# tasks. An empty index is a real answer (no live process declares a task), not
# a missing one.
PID_INDEX=$(fm_agent_task_pid_index) || PID_INDEX=
UNREADABLE_CANDIDATES=$(printf '%s\n' "$PID_INDEX" | awk -F'\t' \
  '$1 == "__FM_UNPROVEN__" && $3 == "unreadable" {print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')
ISOLATION_FAILED=0
FM_ISOLATION_ENDPOINT_PID=

fm_isolation_unreadable_candidate_matches_endpoint() {
  local candidates=$1 backend=$2 target=$3 endpoint_pid
  FM_ISOLATION_ENDPOINT_PID=
  endpoint_pid=$(fm_backend_foreground_process_pid "$backend" "$target" 2>/dev/null) || return 2
  case "$endpoint_pid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  printf '%s\n' "$candidates" | tr ',' '\n' | grep -qxF "$endpoint_pid"
  case "$?" in
    0)
      FM_ISOLATION_ENDPOINT_PID=$endpoint_pid
      return 0
      ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

fm_isolation_recorded_endpoint_identity_matches_live() {
  local meta=$1 live recorded_target
  fm_backend_recorded_endpoint_identity_of_meta "$meta" >/dev/null || return 2
  recorded_target=$(fm_backend_recorded_target_of_meta "$meta") || return 2
  [ "$recorded_target" = "$FM_BACKEND_RECORDED_ENDPOINT_TARGET" ] || return 2
  live=$(fm_backend_endpoint_identity \
    "$FM_BACKEND_RECORDED_ENDPOINT_BACKEND" \
    "$FM_BACKEND_RECORDED_ENDPOINT_TARGET" 2>/dev/null) || return 2
  [ -n "$live" ] || return 2
  [ "$live" = "$FM_BACKEND_RECORDED_ENDPOINT_IDENTITY" ] || return 1
}

fm_isolation_secondmate_recovery_state() {
  local meta=$1 kind kind_count backend target
  kind_count=$(grep -c '^kind=' "$meta" 2>/dev/null || true)
  [ "$kind_count" -eq 1 ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" = secondmate ] || return 1
  fm_backend_recorded_endpoint_identity_of_meta "$meta" >/dev/null || return 1
  backend=$FM_BACKEND_RECORDED_ENDPOINT_BACKEND
  target=$FM_BACKEND_RECORDED_ENDPOINT_TARGET
  case "$(fm_backend_agent_state "$backend" "$target")" in
    dead|missing) return 0 ;;
    *) return 1 ;;
  esac
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  recorded_count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
  recorded=$(fm_meta_get "$meta" worktree)
  case "$recorded" in
    /*) ;;
    *)
      echo "ISOLATION: task $id has corrupt scope metadata: worktree must be one non-empty absolute path; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
      continue
      ;;
  esac
  if [ "$recorded_count" -ne 1 ]; then
    echo "ISOLATION: task $id has corrupt scope metadata: worktree must appear exactly once; preserve its state and reconcile $meta before any mutation"
    ISOLATION_FAILED=1
    continue
  fi
  recoverable_endpoint=0
  fm_isolation_secondmate_recovery_state "$meta" && recoverable_endpoint=1
  endpoint_identity_status=0
  if [ "$recoverable_endpoint" -eq 0 ]; then
    fm_isolation_recorded_endpoint_identity_matches_live "$meta" || endpoint_identity_status=$?
  fi
  case "$endpoint_identity_status" in
    0) ;;
    1)
      echo "ISOLATION: task $id is unproven: recorded endpoint identity does not match the live endpoint; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
      continue
      ;;
    *)
      echo "ISOLATION: task $id is unproven: complete recorded endpoint identity or live endpoint identity could not be verified; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
      continue
      ;;
  esac
  target=$FM_BACKEND_RECORDED_ENDPOINT_TARGET
  backend=$FM_BACKEND_RECORDED_ENDPOINT_BACKEND
  endpoint_match_status=0
  if [ "$recoverable_endpoint" -eq 0 ] && [ -n "$UNREADABLE_CANDIDATES" ] \
    && fm_isolation_unreadable_candidate_matches_endpoint \
      "$UNREADABLE_CANDIDATES" "$backend" "$target"; then
    endpoint_pid=$FM_ISOLATION_ENDPOINT_PID
    echo "ISOLATION: task $id is unproven for recorded endpoint $target: candidate agent process environment is unreadable for pid $endpoint_pid; stop or make that endpoint process authoritative before any mutation"
    ISOLATION_FAILED=1
  elif [ "$recoverable_endpoint" -eq 0 ] && [ -n "$UNREADABLE_CANDIDATES" ]; then
    fm_isolation_unreadable_candidate_matches_endpoint \
      "$UNREADABLE_CANDIDATES" "$backend" "$target" \
      || endpoint_match_status=$?
    if [ "$endpoint_match_status" -eq 2 ]; then
      echo "ISOLATION: task $id is unproven for recorded endpoint $target: the endpoint process could not be read while unreadable candidate evidence exists; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
    fi
  fi

  kind_count=$(grep -c '^kind=' "$meta" 2>/dev/null || true)
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind_count" -ne 1 ]; then
    echo "ISOLATION: task $id is unproven: kind must appear exactly once; preserve its state and reconcile $meta before any mutation"
    ISOLATION_FAILED=1
    continue
  fi
  case "$kind" in
    ship|scout|secondmate) ;;
    *)
      echo "ISOLATION: task $id is unproven: kind must be one non-empty valid worker kind; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
      continue
      ;;
  esac
  role=crewmate
  expected_home=$HOME_REAL
  if [ "$kind" = secondmate ]; then
    role=secondmate
    expected_count=$(grep -c '^home=' "$meta" 2>/dev/null || true)
    expected_declared=$(fm_meta_get "$meta" home)
    case "$expected_declared" in
      /*) ;;
      *)
        echo "ISOLATION: task $id has corrupt secondmate scope metadata: home must be one non-empty absolute path; preserve its state and reconcile $meta before any mutation"
        ISOLATION_FAILED=1
        continue
        ;;
    esac
    if [ "$expected_count" -ne 1 ]; then
      echo "ISOLATION: task $id has corrupt secondmate scope metadata: home must appear exactly once; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
      continue
    fi
    expected_home=$(fm_agent_canonical_dir "$expected_declared") || expected_home=$expected_declared
  fi
  if [ "$recoverable_endpoint" -eq 0 ]; then
    endpoint_pid=$(fm_backend_foreground_process_pid "$backend" "$target" 2>/dev/null || true)
    case "$endpoint_pid" in
      ''|*[!0-9]*)
        echo "ISOLATION: task $id is unproven for recorded endpoint $target: its authoritative foreground process could not be identified; preserve its state and reconcile $meta before any mutation"
        ISOLATION_FAILED=1
        continue
        ;;
    esac
    pids=$(fm_agent_endpoint_identity_pid "$id" "$expected_home" "$role" "$endpoint_pid" 2>/dev/null || true)
    if [ -z "$pids" ]; then
      echo "ISOLATION: task $id is unproven for recorded endpoint $target: the endpoint process does not carry the exact task, home, and role declaration; preserve its state and reconcile $meta before any mutation"
      ISOLATION_FAILED=1
      continue
    fi
  else
    pids=
  fi
  recorded_real=$(fm_agent_canonical_dir "$recorded") || recorded_real=$recorded
  conflict_identities=$(printf '%s\n' "$PID_INDEX" | awk -F'\t' \
    -v t="$id" -v h="$expected_home" -v r="$role" \
    '$1 == t && ($2 != h || $3 != r) {print $2 "\t" $3}' | sort -u)
  while IFS=$'\t' read -r conflict_home conflict_role; do
    [ -n "$conflict_home" ] && [ -n "$conflict_role" ] || continue
    conflict_pids=$(fm_agent_root_pids_for_identity "$id" "$conflict_home" "$conflict_role" "$PID_INDEX" 2>/dev/null || true)
    while IFS= read -r conflict_pid; do
      [ -n "$conflict_pid" ] || continue
      conflict_cwd=$(fm_agent_proc_cwd "$conflict_pid" 2>/dev/null || true)
      if [ -z "$conflict_cwd" ]; then
        echo "ISOLATION: task $id is unproven for conflicting process $conflict_pid: home=$conflict_home role=$conflict_role and authoritative process cwd is unavailable"
        ISOLATION_FAILED=1
        continue
      fi
      conflict_cwd_real=$(fm_agent_canonical_dir "$conflict_cwd") || conflict_cwd_real=$conflict_cwd
      if ! fm_agent_path_within "$recorded_real" "$conflict_cwd_real" \
        && ! fm_agent_path_within "$ROOT_REAL" "$conflict_cwd_real" \
        && ! fm_agent_path_within "$HOME_REAL" "$conflict_cwd_real"; then
        continue
      fi
      echo "ISOLATION: task $id has conflicting worker identity at process $conflict_pid: home=$conflict_home role=$conflict_role, expected home=$expected_home role=$role; stop it before it acts on either home's records"
      ISOLATION_FAILED=1
    done <<EOF
$conflict_pids
EOF
  done <<EOF
$conflict_identities
EOF
  if [ -z "$pids" ]; then
    if [ "$recoverable_endpoint" -eq 1 ]; then
      continue
    fi
    echo "ISOLATION: task $id is unproven: no live agent process declares the required task=$id home=$expected_home role=$role identity; stop any undeclared endpoint process and relaunch the worker with complete isolation declarations"
    ISOLATION_FAILED=1
    continue
  fi

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cwd=$(fm_agent_proc_cwd "$pid" 2>/dev/null || true)
    if [ -z "$cwd" ]; then
      echo "ISOLATION: task $id is unproven for agent process $pid: authoritative process cwd is unavailable; stop or re-establish the worker before any mutation"
      ISOLATION_FAILED=1
      continue
    fi
    cwd_real=$(fm_agent_canonical_dir "$cwd") || cwd_real=$cwd
    if fm_agent_path_within "$recorded_real" "$cwd_real"; then
      if [ "${FM_ISOLATION_VERBOSE:-0}" = 1 ]; then
        echo "BOOTSTRAP_INFO: isolation for $id proved from agent process $pid in $cwd_real"
      fi
      continue
    fi

    if fm_agent_path_within "$ROOT_REAL" "$cwd_real" || fm_agent_path_within "$HOME_REAL" "$cwd_real"; then
      echo "ISOLATION: task $id collapsed onto the primary checkout - agent process $pid is running in $cwd_real instead of its worktree $recorded_real; stop that worker before it writes, then relaunch it in an isolated worktree"
      ISOLATION_FAILED=1
      continue
    fi
    echo "ISOLATION: task $id is not in its recorded worktree - agent process $pid is running in $cwd_real instead of $recorded_real; reconcile the record before any disposal or steer"
    ISOLATION_FAILED=1
  done <<EOF
$pids
EOF
done

exit "$ISOLATION_FAILED"
