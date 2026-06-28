#!/usr/bin/env bash
# Behavior tests for local Cognee source parsing and verification.
#
# These fixtures are saved/redacted local files only. They prove Cognee text is
# only a hint until a manifest row and readable local source file agree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-cognee-verify-source.sh"
TMP_ROOT=$(fm_test_tmproot fm-cognee-source-verify)

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

write_manifest() {
  local manifest=$1 source=$2 checksum=$3
  cat > "$manifest" <<EOF
{"source_id":"seed-07","source_path":"$source","seed_file":"seed/redacted-07.md","checksum_sha256":"$checksum","size_bytes":$(wc -c < "$source"),"source_family":"firstmate-report","import_batch_id":"pilot-redacted","stale_risk":"medium","redaction_status":"approved","data_ids":["123e4567-e89b-12d3-a456-426614174000"],"chunk_ids":["223e4567-e89b-12d3-a456-426614174001"],"raw_readback_status":"ok"}
{"source_id":"seed-raw-404","source_path":"$source","seed_file":"seed/raw-404.md","checksum_sha256":"$checksum","size_bytes":$(wc -c < "$source"),"source_family":"firstmate-report","import_batch_id":"pilot-redacted","stale_risk":"low","redaction_status":"approved","data_ids":["323e4567-e89b-12d3-a456-426614174002"],"chunk_ids":[],"raw_readback_status":"404"}
EOF
}

test_verified_source_requires_manifest_and_local_reopen() {
  local case_dir source manifest answer out
  case_dir="$TMP_ROOT/pass"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\nLocal proof line.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  cat > "$answer" <<EOF
Cognee hint only.
SOURCE_ID=seed-07
SOURCE_PATH=$source
SEED_FILE=seed/redacted-07.md
DATA_ID=123e4567-e89b-12d3-a456-426614174000
CHUNK_ID=223e4567-e89b-12d3-a456-426614174001
EOF

  out=$("$VERIFY" --manifest "$manifest" --answer "$answer") || fail "verified fixture should pass"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.status')" = "verified" ] || fail "status should be verified"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "verified_local_source" ] || fail "outcome should be local source"
  [ "$(printf '%s' "$out" | jq -r '.manifest.manifest_row_found')" = "true" ] || fail "manifest row must be found"
  [ "$(printf '%s' "$out" | jq -r '.local_file.local_file_opened')" = "true" ] || fail "local source must be opened"
  [ "$(printf '%s' "$out" | jq -r '.policy.action_authorized')" = "false" ] || fail "memory must not authorize action"
}

test_quoted_source_path_with_spaces_verifies() {
  local case_dir source manifest answer out
  case_dir="$TMP_ROOT/path with spaces"
  mkdir -p "$case_dir"
  source="$case_dir/redacted source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  cat > "$answer" <<EOF
SOURCE_ID=seed-07
SOURCE_PATH="$source"
SEED_FILE="seed/redacted-07.md"
EOF

  out=$("$VERIFY" --manifest "$manifest" --answer "$answer") || fail "quoted source path should pass"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.status')" = "verified" ] || fail "quoted path status"
  [ "$(printf '%s' "$out" | jq -r '.source_reference.source_paths[0]')" = "$source" ] || fail "quoted path must parse whole value"
}

test_invalid_utf8_answer_fails_closed_without_traceback() {
  local case_dir source manifest answer out code
  case_dir="$TMP_ROOT/invalid-utf8"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.bin"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  printf '\377' > "$answer"

  set +e
  out=$("$VERIFY" --manifest "$manifest" --answer "$answer" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "invalid UTF-8 answer"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "failed_closed_answer_unreadable" ] || fail "invalid UTF-8 outcome"
  assert_not_contains "$out" "Traceback" "invalid UTF-8 must not print traceback"
}

test_unknown_source_id_fails_closed() {
  local case_dir source manifest answer out code
  case_dir="$TMP_ROOT/unknown"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  printf 'SOURCE_ID=seed-missing\n' > "$answer"

  set +e
  out=$("$VERIFY" --manifest "$manifest" --answer "$answer")
  code=$?
  set -e
  expect_code 2 "$code" "unknown source id"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.status')" = "failed_closed" ] || fail "unknown id must fail closed"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "hint_only_manifest_miss" ] || fail "unknown id outcome"
}

test_checksum_mismatch_fails_closed() {
  local case_dir source manifest answer out code
  case_dir="$TMP_ROOT/checksum"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "0000000000000000000000000000000000000000000000000000000000000000"
  printf 'SOURCE_ID=seed-07\nSOURCE_PATH=%s\nSEED_FILE=seed/redacted-07.md\n' "$source" > "$answer"

  set +e
  out=$("$VERIFY" --manifest "$manifest" --answer "$answer")
  code=$?
  set -e
  expect_code 2 "$code" "checksum mismatch"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "failed_closed_checksum_mismatch" ] || fail "checksum mismatch outcome"
  [ "$(printf '%s' "$out" | jq -r '.manifest.manifest_checksum_match')" = "false" ] || fail "checksum match must be false"
}

test_extra_source_id_fails_closed() {
  local case_dir source manifest answer out code
  case_dir="$TMP_ROOT/extra-source-id"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  cat > "$answer" <<EOF
SOURCE_ID=seed-07
SOURCE_ID=seed-missing
SOURCE_PATH=$source
SEED_FILE=seed/redacted-07.md
EOF

  set +e
  out=$("$VERIFY" --manifest "$manifest" --answer "$answer")
  code=$?
  set -e
  expect_code 2 "$code" "extra source id"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.status')" = "failed_closed" ] || fail "extra source id must fail closed"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "failed_closed_missing_proof" ] || fail "extra source id outcome"
}

test_raw_404_stays_durability_blocker() {
  local case_dir source manifest answer out code
  case_dir="$TMP_ROOT/raw-404"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  printf 'SOURCE_ID=seed-raw-404\nSOURCE_PATH=%s\nSEED_FILE=seed/raw-404.md\n' "$source" > "$answer"

  set +e
  out=$("$VERIFY" --manifest "$manifest" --answer "$answer")
  code=$?
  set -e
  expect_code 2 "$code" "raw 404 durability blocker"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "failed_closed_raw_durability" ] || fail "raw 404 outcome"
  [ "$(printf '%s' "$out" | jq -r '.local_file.local_file_opened')" = "true" ] || fail "local file still reopens for diagnostics"
}

test_malformed_uuid_is_ignored_but_unknown_well_formed_uuid_fails() {
  local case_dir source manifest answer out code
  case_dir="$TMP_ROOT/uuid"
  mkdir -p "$case_dir"
  source="$case_dir/redacted-source.md"
  manifest="$case_dir/manifest.jsonl"
  answer="$case_dir/answer.txt"
  printf 'Redacted report fixture.\n' > "$source"
  write_manifest "$manifest" "$source" "$(sha256_file "$source")"
  cat > "$answer" <<EOF
SOURCE_ID=seed-07
SOURCE_PATH=$source
SEED_FILE=seed/redacted-07.md
DATA_ID=not-a-real-uuid
CHUNK_ID=423e4567-e89b-12d3-a456-426614174003
EOF

  set +e
  out=$("$VERIFY" --manifest "$manifest" --answer "$answer")
  code=$?
  set -e
  expect_code 2 "$code" "unknown chunk uuid"
  [ "$(printf '%s' "$out" | jq -r '.source_reference.malformed_uuid_count')" = "1" ] || fail "malformed UUID should be counted"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.outcome')" = "failed_closed_identifier_mismatch" ] || fail "unknown well formed UUID must fail closed"
}

test_verified_source_requires_manifest_and_local_reopen
test_quoted_source_path_with_spaces_verifies
test_invalid_utf8_answer_fails_closed_without_traceback
test_unknown_source_id_fails_closed
test_checksum_mismatch_fails_closed
test_extra_source_id_fails_closed
test_raw_404_stays_durability_blocker
test_malformed_uuid_is_ignored_but_unknown_well_formed_uuid_fails
pass "cognee source parser and local verification fail closed"
