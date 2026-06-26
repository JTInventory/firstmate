#!/usr/bin/env bash
# Shared task identity checks for helpers that act on a task worktree.
#
# Ship tasks conventionally live on branch fm/<task-id>. If a reused Treehouse
# pane keeps old state/<id>.meta while the worktree has moved to another branch,
# helpers must refuse instead of recording PRs, reviewing diffs, or tearing down
# the wrong task.

fm_meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" | tail -1 | cut -d= -f2- || true
}

fm_task_expected_branch() {
  printf 'fm/%s\n' "$1"
}

fm_assert_task_branch_matches_meta() {
  local id=$1 meta=$2 label=${3:-error} wt kind expected branch
  [ -f "$meta" ] || { echo "$label: no meta for task $id at $meta" >&2; return 1; }

  kind=$(fm_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship) ;;
    *) return 0 ;;
  esac

  wt=$(fm_meta_value "$meta" worktree)
  [ -n "$wt" ] || { echo "$label: meta for task $id is missing worktree=" >&2; return 1; }
  [ -d "$wt" ] || { echo "$label: worktree for task $id is missing: $wt" >&2; return 1; }

  expected=$(fm_task_expected_branch "$id")
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    echo "$label: task identity mismatch for $id: worktree $wt is detached; expected branch $expected." >&2
    echo "Use the matching task id or intentionally reconcile the metadata before continuing." >&2
    return 1
  fi
  if [ "$branch" != "$expected" ]; then
    echo "$label: task identity mismatch for $id: meta $meta points at worktree $wt, but that worktree is on branch $branch; expected $expected." >&2
    echo "Use the matching task id or intentionally reconcile the metadata before continuing." >&2
    return 1
  fi
}
