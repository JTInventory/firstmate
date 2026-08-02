#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

_FM_PRIMARY_SCOPE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The declared-agent-role contract has one owner; this predicate only consumes it.
# shellcheck source=/dev/null
. "$_FM_PRIMARY_SCOPE_LIB_DIR/fm-worker-isolation-lib.sh"

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
# A declared task worker is never primary anywhere, whatever root and state it
# was handed: an inherited FM_HOME or FM_ROOT_OVERRIDE would otherwise let a
# worker launched inside a primary checkout fire that home's hooks.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  case "${FM_AGENT_ROLE:-}" in
    primary|"") fm_worker_primary_authority_matches || return 1 ;;
    crewmate) return 1 ;;
    secondmate)
      fm_worker_secondmate_scope_matches "$root" "$state" || return 1
      fm_worker_isolation_sweep_current || return 1
      ;;
    *) return 1 ;;
  esac
  git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -n "$git_common_dir" ] || return 1
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
