#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# CI and the no-mistakes gate both invoke this script. It owns the ShellCheck
# version and the canonical shell file set so those two checks cannot drift.
#
# Usage:
#   fm-lint.sh                    lint bin/*.sh and tests/*.sh
#   fm-lint.sh <path>...          lint selected paths with the same options
#   fm-lint.sh --required-version print the pinned ShellCheck version
set -eu

REQUIRED_SHELLCHECK=0.11.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = '--required-version' ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck %s is required but was not found\n' "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi

unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ { print $2; exit }')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" >&2
  exit 1
fi

cd "$ROOT" || exit 1
if [ "$#" -gt 0 ]; then
  exec shellcheck --norc -x -P SCRIPTDIR "$@"
fi
exec shellcheck --norc -x -P SCRIPTDIR bin/*.sh tests/*.sh
