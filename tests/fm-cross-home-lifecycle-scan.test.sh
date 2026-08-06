#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cross-home-lifecycle-scan)
LOCAL_HOME="$TMP_ROOT/local-home"
FOREIGN_HOME="$TMP_ROOT/foreign-home"
SHARED_ROOT="$TMP_ROOT/firstmate-checkout"
SCRIPT="$SHARED_ROOT/bin/fm-spawn.sh"
mkdir -p "$LOCAL_HOME/state" "$FOREIGN_HOME/state" "${SCRIPT%/*}"

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

scope_result() {
  local rc=0
  SCOPE_ENVIRONMENT=$1
  fm_lifecycle_process_environment() {
    FM_LIFECYCLE_ENVIRONMENT_SOURCE=proc
    FM_LIFECYCLE_ENVIRONMENT=$SCOPE_ENVIRONMENT
  }
  fm_spawn_legacy_process_matches_scope \
    999 "$SCRIPT" "$LOCAL_HOME" "$LOCAL_HOME/state" || rc=$?
  printf '%s\n' "$rc"
}

foreign_environment="FM_LIFECYCLE_HOME=$FOREIGN_HOME
FM_LIFECYCLE_STATE=$FOREIGN_HOME/state
FM_HOME=$FOREIGN_HOME
FM_ROOT_OVERRIDE=$SHARED_ROOT
FM_STATE_OVERRIDE=$FOREIGN_HOME/state"
[ "$(scope_result "$foreign_environment")" -eq 1 ] \
  || fail "a complete foreign lifecycle declaration was blocked by its shared checkout root"

local_environment="FM_LIFECYCLE_HOME=$LOCAL_HOME
FM_LIFECYCLE_STATE=$LOCAL_HOME/state
FM_HOME=$LOCAL_HOME
FM_ROOT_OVERRIDE=$SHARED_ROOT
FM_STATE_OVERRIDE=$LOCAL_HOME/state"
[ "$(scope_result "$local_environment")" -eq 0 ] \
  || fail "a complete local lifecycle declaration escaped the local scan"

partial_environment="FM_LIFECYCLE_HOME=$FOREIGN_HOME
FM_HOME=$FOREIGN_HOME
FM_ROOT_OVERRIDE=$SHARED_ROOT"
[ "$(scope_result "$partial_environment")" -eq 2 ] \
  || fail "a partial authoritative lifecycle declaration did not fail closed"

conflicting_environment="FM_LIFECYCLE_HOME=$LOCAL_HOME
FM_LIFECYCLE_STATE=$FOREIGN_HOME/state
FM_HOME=$FOREIGN_HOME
FM_ROOT_OVERRIDE=$SHARED_ROOT"
[ "$(scope_result "$conflicting_environment")" -eq 2 ] \
  || fail "a split-home authoritative lifecycle declaration did not fail closed"

predeclaration_foreign_environment="FM_HOME=$FOREIGN_HOME
FM_ROOT_OVERRIDE=$SHARED_ROOT"
[ "$(scope_result "$predeclaration_foreign_environment")" -eq 1 ] \
  || fail "a foreign FM_HOME was conflated with its shared checkout before declaration export"

predeclaration_local_environment="FM_HOME=$LOCAL_HOME
FM_ROOT_OVERRIDE=$SHARED_ROOT"
[ "$(scope_result "$predeclaration_local_environment")" -eq 0 ] \
  || fail "a local FM_HOME escaped its target before declaration export"

pass "lifecycle scan scopes complete declarations to their operational home"

scan_with_one_ambiguous_lifecycle_pid() {
  local expected_live=$1 ambiguous_pid=$$
  fm_spawn_legacy_lifecycle_candidate_pids() {
    printf '%s\n' "$ambiguous_pid"
  }
  fm_lifecycle_process_script() {
    [ "$1" = "$ambiguous_pid" ] || return 1
    return 2
  }
  fm_lifecycle_process_live() {
    [ "$1" = "$ambiguous_pid" ] && [ "$expected_live" = yes ]
  }
  fm_spawn_legacy_lifecycle_process_busy \
    "$LOCAL_HOME" "$LOCAL_HOME/state"
}

scan_with_one_ambiguous_lifecycle_pid yes \
  || fail "a live lifecycle PID with unreadable identity did not fail closed"
if scan_with_one_ambiguous_lifecycle_pid no; then
  fail "an exited ambiguous lifecycle PID blocked home admission"
fi
pass "lifecycle scan ignores exited ambiguity but blocks live ambiguity"
