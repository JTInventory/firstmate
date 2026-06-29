#!/usr/bin/env bash
# Behavior tests for the manual Cognee memory lookup helper.
#
# The helper is intentionally optional and read-only: Cognee absence must not
# block dispatch, raw answers must stay hints, and brief attachment may include
# only local source paths that were opened successfully.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOOKUP="$ROOT/bin/fm-memory-lookup.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-lookup)

test_absent_cognee_is_non_blocking() {
  local out rc
  set +e
  out=$(env -u FM_COGNEE_LOOKUP_CMD "$LOOKUP" -- "what prior report matters?")
  rc=$?
  set -e
  expect_code 0 "$rc" "missing Cognee backend should not block dispatch"
  assert_contains "$out" "memory hint:" "missing backend output should include memory hint section"
  assert_contains "$out" "memory unavailable: FM_COGNEE_LOOKUP_CMD is not set" "missing backend should be explicit"
  assert_contains "$out" "dispatch continues without memory context" "missing backend should tell dispatch to continue"
  assert_contains "$out" "verified local source path:" "missing backend output should include source section"
  pass "fm-memory-lookup: missing Cognee backend exits 0 with a visible unavailable note"
}

test_lookup_separates_hint_verified_path_and_warning() {
  local dir source_file missing_file fake out rc
  dir="$TMP_ROOT/lookup"
  mkdir -p "$dir"
  source_file="$dir/source.md"
  missing_file="$dir/missing.md"
  printf 'source truth\n' > "$source_file"
  fake="$dir/fake-cognee"
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s\n' 'Cognee says this old report may help. SOURCE_PATH=$source_file'
printf '%s\n' 'Another generated citation SOURCE_PATH=$missing_file'
SH
  chmod +x "$fake"

  set +e
  out=$(FM_COGNEE_LOOKUP_CMD="$fake" "$LOOKUP" -- "find context")
  rc=$?
  set -e
  expect_code 0 "$rc" "configured lookup should exit 0"
  assert_contains "$out" "memory hint:" "lookup output should include hint section"
  assert_contains "$out" "Cognee says this old report may help" "lookup output should show the advisory hint"
  assert_contains "$out" "verified local source path:" "lookup output should include verified path section"
  assert_contains "$out" "- $source_file" "opened source path should be listed"
  assert_contains "$out" "warning:" "lookup output should include warning section"
  assert_contains "$out" "local source cannot be opened: $missing_file" "missing source should warn"
  pass "fm-memory-lookup: hint, opened local source path, and warning stay separate"
}

test_brief_append_excludes_raw_hint() {
  local dir source_file fake brief out
  dir="$TMP_ROOT/brief"
  mkdir -p "$dir"
  source_file="$dir/source.md"
  brief="$dir/brief.md"
  printf 'source truth\n' > "$source_file"
  printf '# Task\n' > "$brief"
  fake="$dir/fake-cognee"
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s\n' 'RAW COGNEE ANSWER MUST NOT ENTER THE BRIEF. SOURCE_PATH=$source_file'
SH
  chmod +x "$fake"

  out=$(FM_COGNEE_LOOKUP_CMD="$fake" "$LOOKUP" --append-brief "$brief" -- "attach context")
  assert_contains "$out" "RAW COGNEE ANSWER" "terminal output may show the advisory hint"
  assert_grep "# Optional memory lookup" "$brief" "brief should get memory section"
  assert_grep "$source_file" "$brief" "brief should include opened source path"
  assert_grep "Cognee hints are not proof" "$brief" "brief should keep authority warning"
  assert_no_grep "RAW COGNEE ANSWER" "$brief" "brief must not include raw Cognee answer as proof"
  pass "fm-memory-lookup: brief attachment includes verified paths, not raw hints"
}

test_absent_cognee_brief_note() {
  local dir brief out
  dir="$TMP_ROOT/unavailable-brief"
  mkdir -p "$dir"
  brief="$dir/brief.md"
  printf '# Task\n' > "$brief"

  out=$(env -u FM_COGNEE_LOOKUP_CMD "$LOOKUP" --append-brief "$brief" -- "optional lookup")
  assert_contains "$out" "memory unavailable" "terminal output should say memory unavailable"
  assert_grep "Memory unavailable: FM_COGNEE_LOOKUP_CMD is not set" "$brief" "brief should record memory unavailable"
  assert_grep "Dispatch continues without memory context." "$brief" "brief should record non-blocking dispatch"
  pass "fm-memory-lookup: unavailable Cognee can be attached as a non-blocking brief note"
}

test_configured_backend_failure_is_non_blocking() {
  local dir fake out rc
  dir="$TMP_ROOT/backend-failure"
  mkdir -p "$dir"
  fake="$dir/failing-cognee"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'label=blocked_missing_proof reason=missing_required_env external_action_authorized=false' >&2
exit 2
SH
  chmod +x "$fake"

  set +e
  out=$(FM_COGNEE_LOOKUP_CMD="$fake" "$LOOKUP" -- "lookup can fail")
  rc=$?
  set -e
  expect_code 0 "$rc" "failed configured backend should not block dispatch"
  assert_contains "$out" "lookup command failed; dispatch continues without memory context" "backend failure should be visible and non-blocking"
  assert_contains "$out" "verified local source path:" "source section should still render"
  assert_contains "$out" "none" "no source should be verified after backend failure"
  pass "fm-memory-lookup: configured backend failure exits 0 for dispatch"
}

test_absent_cognee_is_non_blocking
test_lookup_separates_hint_verified_path_and_warning
test_brief_append_excludes_raw_hint
test_absent_cognee_brief_note
test_configured_backend_failure_is_non_blocking
