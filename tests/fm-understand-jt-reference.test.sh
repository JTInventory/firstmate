#!/usr/bin/env bash
# Tests for the JT Understand Anything brief reference helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFERENCE="$ROOT/bin/fm-understand-jt-reference"
TMP_ROOT=$(fm_test_tmproot fm-understand-jt-reference)

write_fake_refresh() {
  local file=$1
  cat > "$file" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_HOME:?}/state
mkdir -p "$state"
case "${1:-}" in
  --status)
    printf '{"fresh":true}\n' > "$state/jt-understand-graph.summary.json"
    ;;
  --refresh)
    printf '{"fresh":true}\n' > "$state/jt-understand-graph.summary.json"
    ;;
  --reference)
    cat > "$state/jt-understand-graph.reference.md" <<'MD'
<!-- firstmate:jt-understand-anything:start -->

# JT Control Room structure reference

- Fresh: yes

<!-- firstmate:jt-understand-anything:end -->
MD
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod +x "$file"
}

test_should_attach_detects_jt_context() {
  local home brief
  home="$TMP_ROOT/should-attach"
  mkdir -p "$home/state" "$home/data"
  brief="$home/brief.md"
  printf '%s\n' 'Investigate JT Control Room refresh:doctor behavior.' > "$brief"

  FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$home/missing-refresh" "$REFERENCE" should-attach "$brief" demo task-1 \
    || fail "JT Control Room brief should attach"
  FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$home/missing-refresh" "$REFERENCE" should-attach "$brief" demo jt-123 \
    || fail "jt-* task id should attach"
  printf '%s\n' 'Generic Firstmate task.' > "$brief"
  FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$home/missing-refresh" "$REFERENCE" should-attach "$brief" firstmate task-1 \
    && fail "generic brief should not attach"
  pass "JT reference helper detects matching task context"
}

test_append_brief_is_idempotent_and_uses_reference_packet() {
  local home brief refresh marker_count
  home="$TMP_ROOT/append"
  mkdir -p "$home/state" "$home/data"
  brief="$home/brief.md"
  refresh="$home/fake-refresh"
  write_fake_refresh "$refresh"
  printf '%s\n' 'Fix JT Automation 4187 freshness.' > "$brief"

  FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$refresh" "$REFERENCE" append-brief-if-jt "$brief" firstmate task-1 \
    || fail "append should succeed for JT context"
  FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$refresh" "$REFERENCE" append-brief-if-jt "$brief" firstmate task-1 \
    || fail "second append should remain idempotent"

  assert_grep '# JT Control Room structure reference' "$brief" "reference packet should be appended"
  marker_count=$(grep -Fc '<!-- firstmate:jt-understand-anything:start -->' "$brief")
  [ "$marker_count" = 1 ] || fail "reference packet should be appended once, got $marker_count"
  pass "JT reference append is idempotent and uses the generated packet"
}

test_append_skips_non_jt_context() {
  local home brief refresh before after
  home="$TMP_ROOT/skip"
  mkdir -p "$home/state" "$home/data"
  brief="$home/brief.md"
  refresh="$home/fake-refresh"
  write_fake_refresh "$refresh"
  printf '%s\n' 'Clean up firstmate docs.' > "$brief"
  before=$(sha256sum "$brief")

  FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$refresh" "$REFERENCE" append-brief-if-jt "$brief" firstmate docs-cleanup \
    || fail "non-JT append command should no-op successfully"
  after=$(sha256sum "$brief")
  [ "$before" = "$after" ] || fail "non-JT brief should not be modified"
  pass "JT reference append skips non-JT briefs"
}

test_brief_block_falls_back_when_refresh_unavailable() {
  local home out
  home="$TMP_ROOT/fallback"
  mkdir -p "$home/state" "$home/data"
  out=$(FM_HOME="$home" FM_UNDERSTAND_REFRESH_BIN="$home/missing-refresh" "$REFERENCE" brief-block) \
    || fail "brief-block fallback should not fail when refresh helper is unavailable"
  assert_contains "$out" 'Understand Anything reference is unavailable' "fallback block should explain unavailable reference"
  assert_contains "$out" '<!-- firstmate:jt-understand-anything:start -->' "fallback block should keep the marker"
  pass "JT reference helper falls back when graph reference is unavailable"
}

test_reference_uses_repo_root_helper_with_external_home() {
  local root home reference out
  root="$TMP_ROOT/external-home-root"
  home="$TMP_ROOT/external-home"
  mkdir -p "$root/bin" "$home/state"
  cp "$REFERENCE" "$root/bin/fm-understand-jt-reference"
  write_fake_refresh "$root/bin/fm-understand-jt-refresh"
  reference="$root/bin/fm-understand-jt-reference"

  out=$(FM_HOME="$home" "$reference" brief-block) \
    || fail "brief-block should use sibling refresh helper with external FM_HOME"

  assert_contains "$out" '# JT Control Room structure reference' "reference should come from sibling helper"
  assert_present "$home/state/jt-understand-graph.reference.md" "reference should still be written under external FM_HOME"
  [ ! -e "$home/bin/fm-understand-jt-refresh" ] || fail "test setup should not provide helper under FM_HOME"
  pass "JT reference helper uses repo root helper with external FM_HOME"
}

test_jt_understand_helpers_default_home_to_repo_root() {
  local helper
  for helper in \
    "$ROOT/bin/fm-understand-jt-reference" \
    "$ROOT/bin/fm-understand-jt-refresh" \
    "$ROOT/bin/fm-understand-jt-dashboard"; do
    assert_no_grep 'FM_HOME="${FM_HOME:-/root/firstmate}"' "$helper" "$(basename "$helper") should not hardcode /root/firstmate"
    assert_grep 'FM_HOME="${FM_HOME:-$FM_ROOT}"' "$helper" "$(basename "$helper") should default FM_HOME to its repo root"
  done
  pass "JT Understand helpers derive default FM_HOME from their repo root"
}

test_should_attach_detects_jt_context
test_append_brief_is_idempotent_and_uses_reference_packet
test_append_skips_non_jt_context
test_brief_block_falls_back_when_refresh_unavailable
test_reference_uses_repo_root_helper_with_external_home
test_jt_understand_helpers_default_home_to_repo_root
