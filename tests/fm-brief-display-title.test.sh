#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-display-title)

test_failed_brief_does_not_publish_display_title() {
  local home status=0
  home="$TMP_ROOT/failed"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" invalid-shape --display-title "Stale title" \
    >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "invalid brief shape unexpectedly succeeded"
  assert_absent "$home/data/invalid-shape/display-title" \
    "failed brief left durable display-title intake"
  pass "fm-brief publishes display title only after task-shape validation"
}

test_valid_brief_publishes_display_title() {
  local home
  home="$TMP_ROOT/valid"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" valid alpha --display-title "Readable title" \
    >/dev/null 2>&1 || fail "valid brief failed"
  assert_grep "Readable title" "$home/data/valid/display-title" \
    "valid brief did not publish display title"
  pass "fm-brief publishes validated display title with the brief"
}

test_failed_brief_does_not_publish_display_title
test_valid_brief_publishes_display_title

echo "# all fm-brief display-title tests passed"
