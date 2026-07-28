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
# This sweep is READ-ONLY and always exits 0. It prints one actionable
# `ISOLATION:` line per task whose live agent process is provably not where its
# record says it is or whose isolation cannot be proved from an authoritative
# process reading, so bin/fm-bootstrap.sh can surface it in the session-start
# digest exactly like TANGLE.
#
# Evidence discipline (bin/fm-agent-cwd-lib.sh owns the method of record): a
# collapse is reported only from an AUTHORITATIVE /proc reading of the agent
# process. A provider's pane cwd is never promoted to evidence here, because a
# pane field naming the wrong process is precisely what produced a false
# isolation violation on 2026-07-25.
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

HOME_REAL=$(fm_agent_canonical_dir "$FM_HOME") || HOME_REAL=$FM_HOME
ROOT_REAL=$(fm_agent_canonical_dir "$FM_ROOT") || ROOT_REAL=$FM_ROOT

# One /proc walk for the whole sweep, reused for every task below. Asking per
# task instead costs a full walk each time - O(tasks x processes) of forked
# environment reads on the session-start critical path, and the incident this
# sweep exists for had 17 concurrent tasks. An empty index is a real answer (no
# live process declares a task), not a missing one.
PID_INDEX=$(fm_agent_task_pid_index) || PID_INDEX=

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  recorded_count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
  recorded=$(fm_meta_get "$meta" worktree)
  case "$recorded" in
    /*) ;;
    *)
      echo "ISOLATION: task $id has corrupt scope metadata: worktree must be one non-empty absolute path; preserve its state and reconcile $meta before any mutation"
      continue
      ;;
  esac
  if [ "$recorded_count" -ne 1 ]; then
    echo "ISOLATION: task $id has corrupt scope metadata: worktree must appear exactly once; preserve its state and reconcile $meta before any mutation"
    continue
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")

  kind=$(fm_meta_get "$meta" kind)
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
        continue
        ;;
    esac
    if [ "$expected_count" -ne 1 ]; then
      echo "ISOLATION: task $id has corrupt secondmate scope metadata: home must appear exactly once; preserve its state and reconcile $meta before any mutation"
      continue
    fi
    expected_home=$(fm_agent_canonical_dir "$expected_declared") || expected_home=$expected_declared
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
      [ -n "$conflict_cwd" ] || continue
      conflict_cwd_real=$(fm_agent_canonical_dir "$conflict_cwd") || conflict_cwd_real=$conflict_cwd
      fm_agent_path_within "$recorded_real" "$conflict_cwd_real" || continue
      echo "ISOLATION: task $id has conflicting worker identity at process $conflict_pid: home=$conflict_home role=$conflict_role, expected home=$expected_home role=$role; stop it before it acts on either home's records"
    done <<EOF
$conflict_pids
EOF
  done <<EOF
$conflict_identities
EOF
  pids=$(fm_agent_root_pids_for_identity "$id" "$expected_home" "$role" "$PID_INDEX" 2>/dev/null || true)
  if [ -z "$pids" ]; then
    record=$(fm_agent_cwd_verdict "" "" "" "$backend" "$target" "$PID_INDEX")
    if [ "$(fm_agent_verdict_field "$record" source)" = proc ]; then
      pids=$(fm_agent_verdict_field "$record" pid)
    else
      echo "ISOLATION: task $id is unproven: no authoritative live agent process could be identified; treat the task as isolated-unsafe until its worker identity and process cwd are proved"
      continue
    fi
  fi

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cwd=$(fm_agent_proc_cwd "$pid" 2>/dev/null || true)
    if [ -z "$cwd" ]; then
      echo "ISOLATION: task $id is unproven for agent process $pid: authoritative process cwd is unavailable; stop or re-establish the worker before any mutation"
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
      continue
    fi
    echo "ISOLATION: task $id is not in its recorded worktree - agent process $pid is running in $cwd_real instead of $recorded_real; reconcile the record before any disposal or steer"
  done <<EOF
$pids
EOF
done

exit 0
