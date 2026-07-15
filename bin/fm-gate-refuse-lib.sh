#!/usr/bin/env bash
# Shared fail-closed refusal for no-mistakes gate agents.
#
# A no-mistakes gate runs inside a firstmate checkout. Its agent must not inherit
# firstmate's fleet-captain authority and then call spawn, send, or teardown.
# These entrypoints source this library before fleet lifecycle work begins.
# Either signal below is sufficient to refuse:
#   - NO_MISTAKES_GATE is set, including when explicitly set to an empty value;
#   - git-common-dir for the entrypoint or caller is a no-mistakes gate repository
#     under .no-mistakes/repos/.
# The second signal is the path-based backstop when an agent tampers with the
# environment marker. Normal primary and treehouse worktrees match neither case.
#
FM_GATE_REFUSE_EXIT=3

fm_gate_common_dir() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -n "$common" ] || return 0
  (cd "$common" 2>/dev/null && pwd -P) || true
}

fm_gate_source_dir() {
  local library=${BASH_SOURCE[0]} resolved
  if [ -e "$library" ]; then
    library="$(cd "$(dirname "$library")" 2>/dev/null && pwd -P)/$(basename "$library")"
    resolved=$(readlink -f "$library" 2>/dev/null || true)
    [ -z "$resolved" ] || library=$resolved
  fi
  cd "$(dirname "$library")" 2>/dev/null && pwd -P || true
}

fm_refuse_if_gate_agent() {
  if [ "${NO_MISTAKES_GATE+x}" = x ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
    exit "$FM_GATE_REFUSE_EXIT"
  fi

  local candidate common
  for candidate in "$(fm_gate_source_dir)" "$PWD"; do
    [ -n "$candidate" ] || continue
    common=$(fm_gate_common_dir "$candidate")
    case "$common" in
      */.no-mistakes/repos/*.git)
        echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($common)" >&2
        exit "$FM_GATE_REFUSE_EXIT"
        ;;
    esac
  done
}
