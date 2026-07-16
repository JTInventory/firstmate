#!/usr/bin/env bash
# fm-cd-pretool-check.sh - stable harness transport for the primary cd guard.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-cd-pretool-check.sh
#   bin/fm-cd-pretool-check.sh --command '<shell command>'
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
COMMAND=""
COMMAND_SET=0
CLAUDE_MODE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      shift
      [ "$#" -gt 0 ] || exit 2
      COMMAND=$1
      COMMAND_SET=1
      ;;
    --claude) CLAUDE_MODE=1 ;;
    --help|-h)
      printf '%s\n' 'Usage: fm-cd-pretool-check.sh [--claude] [--command <shell-command>]' 'Reads PreToolUse JSON on stdin when --command is omitted.'
      exit 0
      ;;
    *) exit 2 ;;
  esac
  shift
done

real_path() {
  (cd "$1" 2>/dev/null && pwd -P)
}

ROOT=$(real_path "$ROOT" 2>/dev/null) || exit 0
[ -f "$ROOT/AGENTS.md" ] || exit 0
[ -d "$ROOT/bin" ] || exit 0

git_dir=$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
git_common_dir=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$git_dir" in
  /*) git_dir_abs=$git_dir ;;
  *) git_dir_abs=$(real_path "$ROOT/$git_dir" 2>/dev/null || true) ;;
esac
case "$git_common_dir" in
  /*) git_common_abs=$git_common_dir ;;
  *) git_common_abs=$(real_path "$ROOT/$git_common_dir" 2>/dev/null || true) ;;
esac
[ -n "$git_dir_abs" ] && [ "$git_dir_abs" = "$git_common_abs" ] || exit 0

if [ "$COMMAND_SET" -eq 0 ]; then
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  COMMAND=$(printf '%s' "$payload" | jq -r '(.toolInput.command // .tool_input.command // .input.command // empty) | if type == "string" then . else empty end' 2>/dev/null) || exit 0
fi
[ -n "$COMMAND" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ -f "$SCRIPT_DIR/fm-cd-command-policy.mjs" ] || exit 0

RESULT=$(node "$SCRIPT_DIR/fm-cd-command-policy.mjs" --root "$ROOT" --home "$ROOT" --command "$COMMAND" 2>/dev/null) || exit 0
case "$RESULT" in
  *'"decision":"deny"'*)
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '%s\n' "$RESULT" >&2
    else
      printf '%s\n' "$RESULT"
    fi
    printf '%s\n' 'fm-cd-pretool-check: persistent top-level directory change in the primary firstmate checkout is blocked' >&2
    exit 2
    ;;
  *) exit 0 ;;
esac
