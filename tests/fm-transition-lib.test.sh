#!/usr/bin/env bash
# Unit tests for the normalized transition record and policy table.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-transition-lib.sh"

record=$(fm_transition_record 'w1:p2' 'w1' '' 'blocked' 'claude')
[ "$(fm_transition_pane_id "$record")" = 'w1:p2' ] || fail "pane accessor changed"
[ "$(fm_transition_to_status "$record")" = blocked ] || fail "status accessor changed"
[ "$(fm_transition_policy blocked)" = actionable ] || fail "blocked was not actionable"
[ "$(fm_transition_policy working)" = absorb ] || fail "working was not absorb"
[ "$(fm_transition_policy idle)" = defer ] || fail "idle was not defer"
[ "$(fm_transition_policy unknown)" = fallback ] || fail "unknown was not fallback"
echo "# fm-transition-lib.test.sh: all assertions passed"
