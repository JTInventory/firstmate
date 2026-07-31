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

pass "lifecycle scan scopes complete declarations to their operational home"
