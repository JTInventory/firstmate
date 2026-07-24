#!/usr/bin/env bash
# Unit tests for deterministic Herdr task display labels.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-task-label-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-label-lib)

test_kind_mapping() {
  local out
  out=$(bash -c '. "$1"; printf "%s|%s|%s|%s" "$(fm_task_label_kind ship)" "$(fm_task_label_kind crew)" "$(fm_task_label_kind scout)" "$(fm_task_label_kind secondmate)"' _ "$LIB")
  [ "$out" = "Crew|Crew|Scout|2nd" ] || fail "kind mapping mismatch: $out"
  pass "task labels: ship/crew, scout, and secondmate map to Crew, Scout, and 2nd"
}

test_phrase_sanitization_and_truncation() {
  local out
  out=$(bash -c '. "$1"; fm_task_label_sanitize_phrase "  UI@@  Design/// + polish -  "' _ "$LIB")
  [ "$out" = "UI Design + polish" ] || fail "phrase sanitization mismatch: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_sanitize_phrase "Readable operator dashboard wording"' _ "$LIB")
  [ "$out" = "Readable operator dashboard" ] || fail "word-boundary truncation mismatch: '$out'"
  [ "${#out}" -le 28 ] || fail "sanitized phrase exceeds 28 characters: '$out'"
  pass "task labels: printable punctuation is sanitized and long phrases truncate at a word boundary"
}

test_control_and_bidi_input_refused() {
  local status
  bash -c '. "$1"; fm_task_label_sanitize_phrase "$2"' _ "$LIB" $'unsafe\nmetadata' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "newline-bearing title must be refused"
  bash -c '. "$1"; fm_task_label_sanitize_phrase "$2"' _ "$LIB" $'unsafe\e[31mred' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "ANSI/control-bearing title must be refused"
  bash -c '. "$1"; fm_task_label_sanitize_phrase "$2"' _ "$LIB" $'safe\u202Etxt' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "bidi-control-bearing title must be refused"
  pass "task labels: control, ANSI, newline, and bidi input is refused"
}

test_task_keys_and_semantic_fallback() {
  local out expected
  out=$(bash -c '. "$1"; fm_task_label_base_key herdr-tab-labels-c1db' _ "$LIB")
  [ "$out" = c1db ] || fail "random-looking suffix should be reused, got '$out'"
  expected=3a14b9
  out=$(bash -c '. "$1"; fm_task_label_base_key opaque-task-name' _ "$LIB")
  [ "$out" = "$expected" ] || fail "hash-derived key mismatch: '$out' != '$expected'"
  out=$(bash -c '. "$1"; fm_task_label_semantic_phrase herdr-tab-labels-ship-c1db' _ "$LIB")
  [ "$out" = "Herdr tab labels" ] || fail "semantic fallback mismatch: '$out'"
  pass "task labels: stable suffix/hash keys and semantic task-id fallback"
}

test_collision_extends_key_and_journal_reuses_label() {
  local state out label key
  state="$TMP_ROOT/collision/state"
  mkdir -p "$state"
  cat > "$state/other.meta" <<'EOF'
display_label=Crew - UI Design · c1db
task_key=c1db
EOF
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" scout "Herdr labels" ""' _ "$LIB" "$state" herdr-tab-labels-c1db)
  label=${out%%$'\t'*}
  key=${out#*$'\t'}
  [ "${#key}" -eq 10 ] || fail "collision should extend task key to 10 chars, got '$key'"
  [ "$label" = "Scout - Herdr labels · $key" ] || fail "extended label mismatch: '$label'"
  assert_grep "task_id=herdr-tab-labels-c1db" "$state/herdr-tab-labels-c1db.herdr-label" "journal missing task id"
  assert_grep "display_label=$label" "$state/herdr-tab-labels-c1db.herdr-label" "journal missing display label"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" scout "Changed title" ""' _ "$LIB" "$state" herdr-tab-labels-c1db)
  [ "$out" = "$label"$'\t'"$key" ] || fail "same task did not reuse its journaled label exactly"
  pass "task labels: collisions extend deterministically and the same task reuses its journal"
}

test_empty_title_falls_back_and_label_is_bounded() {
  local state out label key
  state="$TMP_ROOT/fallback/state"
  mkdir -p "$state"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" ship "@:/=" ""' _ "$LIB" "$state" 1234)
  label=${out%%$'\t'*}
  key=${out#*$'\t'}
  [ "$label" = "Crew - Task $key · $key" ] || fail "opaque fallback mismatch: '$label'"
  [ "${#label}" -le 50 ] || fail "full label exceeds 50 characters: '$label'"
  pass "task labels: fully rejected phrases use Task <key> and full labels stay within 50 chars"
}

test_backlog_title_precedes_semantic_id_fallback() {
  local home state out
  home="$TMP_ROOT/backlog/home"
  state="$home/state"
  mkdir -p "$home/data" "$state"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] opaque-work-c9d2 - Operator-friendly Herdr naming (repo: firstmate, kind: ship)
- [ ] quick-fix-a1b2 - Fix UI (repo: demo, kind: ship)
- **bold-work-b2c3** - Bold work (repo: demo, since 2026-07-24)
- [ ] blocked-work-c3d4 - Blocked work (repo: demo) blocked-by: prior-task - waits
## Done
- [x] done-pr-d4e5 - Fix PR - https://github.com/example/repo/pull/12 (merged 2026-07-24)
- [X] done-local-e5f6 - Fix local - local main (merged 2026-07-24)
- [x] done-report-f6a7 - Fix report - data/done-report-f6a7/report.md (reported 2026-07-24)
EOF
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" ship "" "" "$4"' \
    _ "$LIB" "$state" opaque-work-c9d2 "$home/data/backlog.md")
  [ "$out" = "Crew - Operator-friendly Herdr · c9d2"$'\t'"c9d2" ] \
    || fail "canonical backlog title was not preferred and bounded: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" ship "" "" "$4"' \
    _ "$LIB" "$state" quick-fix-a1b2 "$home/data/backlog.md")
  [ "$out" = "Crew - Fix UI · a1b2"$'\t'"a1b2" ] \
    || fail "backlog routing metadata leaked into a short display label: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" scout "" "" "$4"' \
    _ "$LIB" "$state" bold-work-b2c3 "$home/data/backlog.md")
  [ "$out" = "Scout - Bold work · b2c3"$'\t'"b2c3" ] \
    || fail "bold in-flight backlog title was not parsed: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" scout "" "" "$4"' \
    _ "$LIB" "$state" blocked-work-c3d4 "$home/data/backlog.md")
  [ "$out" = "Scout - Blocked work · c3d4"$'\t'"c3d4" ] \
    || fail "blocked-by routing metadata leaked into the display label: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" ship "" "" "$4"' \
    _ "$LIB" "$state" done-pr-d4e5 "$home/data/backlog.md")
  [ "$out" = "Crew - Fix PR · d4e5"$'\t'"d4e5" ] \
    || fail "PR completion metadata leaked into the display label: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" ship "" "" "$4"' \
    _ "$LIB" "$state" done-local-e5f6 "$home/data/backlog.md")
  [ "$out" = "Crew - Fix local · e5f6"$'\t'"e5f6" ] \
    || fail "local-main completion metadata leaked into the display label: '$out'"
  out=$(bash -c '. "$1"; fm_task_label_prepare "$2" "$3" scout "" "" "$4"' \
    _ "$LIB" "$state" done-report-f6a7 "$home/data/backlog.md")
  [ "$out" = "Scout - Fix report · f6a7"$'\t'"f6a7" ] \
    || fail "report completion metadata leaked into the display label: '$out'"
  pass "task labels: canonical backlog title precedes semantic task-id fallback"
}

test_persisted_phrase_must_match_safe_ascii_grammar() {
  local state phrase record
  state="$TMP_ROOT/persisted-grammar/state"
  mkdir -p "$state"
  for phrase in "" "Bad/Path" "Bad:Value" 'Bad"Quote' "Café" " Leading"; do
    record="$state/record-${RANDOM}.meta"
    printf 'display_label=Crew - %s · c1db\ntask_key=c1db\n' "$phrase" > "$record"
    if bash -c '. "$1"; fm_task_label_read_record "$2" task' _ "$LIB" "$record" >/dev/null 2>&1; then
      fail "unsafe persisted phrase was accepted: '$phrase'"
    fi
  done
  printf 'display_label=Crew - Safe phrase_1 + polish · c1db\ntask_key=c1db\n' > "$state/safe.meta"
  bash -c '. "$1"; fm_task_label_read_record "$2" task' _ "$LIB" "$state/safe.meta" >/dev/null \
    || fail "safe persisted phrase was rejected"
  pass "task labels: persisted phrases enforce the generated ASCII grammar"
}

test_full_label_limit_counts_characters_in_c_and_utf8_locales() {
  local state locale_name candidate out label key utf8_locale= locales
  locales=$(locale -a 2>/dev/null || true)
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ "$(LC_ALL="$candidate" locale charmap 2>/dev/null || true)" = UTF-8 ]; then
      utf8_locale=$candidate
      break
    fi
  done <<<"$locales"
  for locale_name in C ${utf8_locale:+"$utf8_locale"}; do
    state="$TMP_ROOT/locale-${locale_name//./-}/state"
    mkdir -p "$state"
    printf 'display_label=Crew - Other · c1db\ntask_key=c1db\n' > "$state/other.meta"
    out=$(LC_ALL="$locale_name" bash -c '. "$1"; fm_task_label_prepare "$2" "$3" scout "1234567890123456789012345678" ""' \
      _ "$LIB" "$state" locale-task-c1db) || fail "$locale_name rejected a 49-character display label"
    label=${out%%$'\t'*}
    key=${out#*$'\t'}
    [ "${#key}" -eq 10 ] || fail "$locale_name did not exercise the extended key"
    [ "$(bash -c '. "$1"; fm_task_label_character_count "$2"' _ "$LIB" "$label")" -eq 49 ] \
      || fail "$locale_name counted the display label incorrectly"
  done
  pass "task labels: the 50-character cap is locale-independent with optional UTF-8 comparison"
}

test_kind_mapping
test_phrase_sanitization_and_truncation
test_control_and_bidi_input_refused
test_task_keys_and_semantic_fallback
test_collision_extends_key_and_journal_reuses_label
test_empty_title_falls_back_and_label_is_bounded
test_backlog_title_precedes_semantic_id_fallback
test_persisted_phrase_must_match_safe_ascii_grammar
test_full_label_limit_counts_characters_in_c_and_utf8_locales

echo "# all fm-task-label-lib tests passed"
