#!/usr/bin/env bash
# Shared fail-closed refusal for no-mistakes gate agents.
#
# A no-mistakes gate runs inside a firstmate checkout. Its agent must not inherit
# firstmate's fleet-captain authority and then call spawn, send, or teardown.
# These entrypoints source this library before fleet lifecycle work begins.
# Either signal below is sufficient to refuse:
#   - NO_MISTAKES_GATE is set, including when explicitly set to an empty value;
#   - git-common-dir is a no-mistakes gate repository under .no-mistakes/repos/.
# The second signal is the path-based backstop when an agent tampers with the
# environment marker. Normal primary and treehouse worktrees match neither case.
#
# Firstmate's own tests run from a gate worktree during no-mistakes validation.
# tests/lib.sh exports FM_GATE_REFUSE_BYPASS=1 for those hermetic fixtures; the
# dedicated refusal test removes it so the real boundary remains covered.

FM_GATE_REFUSE_EXIT=3

fm_refuse_if_gate_agent() {
  [ "${FM_GATE_REFUSE_BYPASS:-}" = 1 ] && return 0

  if [ "${NO_MISTAKES_GATE+x}" = x ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
    exit "$FM_GATE_REFUSE_EXIT"
  fi

  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    if common=$(cd "$common" 2>/dev/null && pwd -P); then
      :
    else
      common=
    fi
  fi
  case "$common" in
    */.no-mistakes/repos/*.git)
      echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($common)" >&2
      exit "$FM_GATE_REFUSE_EXIT"
      ;;
  esac
}
