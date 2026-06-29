#!/usr/bin/env bash
# Behavior tests for secret-safe Cognee telemetry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOOKUP="$ROOT/bin/fm-cognee-lookup.sh"
MEMORY_LOOKUP="$ROOT/bin/fm-memory-lookup.sh"
VERIFY="$ROOT/bin/fm-cognee-verify-source.sh"
MANIFEST_CHECK="$ROOT/bin/fm-cognee-manifest-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-cognee-telemetry)

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

json_field() {
  local file=$1 expr=$2
  python3 - "$file" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    event = json.loads(handle.readlines()[-1])

value = event
for part in expr.split("."):
    value = value[part]
if value is None:
    print("null")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

write_tsv_manifest() {
  local manifest=$1 row_id=$2 source_path=$3 raw_status=${4:-not_trusted}
  local size mtime sha
  size=$(wc -c < "$source_path" | tr -d ' ')
  mtime=$(date -u -r "$source_path" '+%Y-%m-%dT%H:%M:%SZ')
  sha=$(sha256_file "$source_path")
  {
    printf '%s\t' row_id source_group source_path source_truth_pointer source_kind recommended_tier decision_status redaction_status redaction_notes sensitivity_label stale_risk supersession_check source_size_bytes source_mtime_utc source_sha256 estimated_words estimated_tokens estimated_cost_formula import_text_prefix raw_readback_status verification_status cognee_source_id
    printf '\n'
    printf '%s\t' "$row_id" firstmate_reports "$source_path" "$source_path" report direct_import allowed passed "test scan" internal low checked_current "$size" "$mtime" "$sha" 12 16 "words * 1.3" "SOURCE_ID=$row_id SOURCE_PATH=$source_path SEED_FILE=$(basename "$source_path")" "$raw_status" verified_local_source "$row_id"
    printf '\n'
  } > "$manifest"
}

write_jsonl_manifest() {
  local manifest=$1 source=$2 checksum=$3
  cat > "$manifest" <<EOF
{"source_id":"seed-telemetry","source_path":"$source","seed_file":"seed/redacted.md","checksum_sha256":"$checksum","size_bytes":$(wc -c < "$source"),"estimated_tokens":9,"source_family":"firstmate-report","import_batch_id":"pilot-redacted","stale_risk":"low","redaction_status":"approved","data_ids":[],"chunk_ids":[],"raw_readback_status":"ok"}
EOF
}

test_lookup_telemetry_redacts_query_answer_and_secret_values() {
  local dir source manifest answer telemetry out rc
  dir="$TMP_ROOT/redaction"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  telemetry="$dir/telemetry.jsonl"
  printf 'local source truth with SECRET_SOURCE_BODY=never-log\n' > "$source"
  write_tsv_manifest "$manifest" seed-redact "$source"
  printf 'SOURCE_ID=seed-redact bearer token SECRET_ANSWER_BODY=never-log\n' > "$answer"

  set +e
  out=$(FM_COGNEE_TELEMETRY_FILE="$telemetry" "$LOOKUP" --dry-run --query "SECRET_QUERY_TEXT=never-log" --manifest "$manifest" --answer-file "$answer")
  rc=$?
  set -e
  expect_code 0 "$rc" "lookup should still pass"
  assert_contains "$out" "label=verified_local_source" "fixture should verify"
  assert_present "$telemetry" "telemetry jsonl should be written"
  assert_not_contains "$(cat "$telemetry")" "SECRET_QUERY_TEXT" "telemetry must not log query text"
  assert_not_contains "$(cat "$telemetry")" "SECRET_ANSWER_BODY" "telemetry must not log answer text"
  assert_not_contains "$(cat "$telemetry")" "SECRET_SOURCE_BODY" "telemetry must not log source body"
  [ "$(json_field "$telemetry" operation_name)" = "cognee_lookup" ] || fail "operation name should be logged"
  [ "$(json_field "$telemetry" mode)" = "dry-run" ] || fail "mode should be logged"
  [ "$(json_field "$telemetry" retry_count)" = "0" ] || fail "retry count should default to zero"
  [ "$(json_field "$telemetry" source_verification_outcome)" = "verified_local_source" ] || fail "source verification outcome should be logged"
  pass "cognee lookup telemetry redacts raw text and records safe fields"
}

test_unknown_vendor_cost_is_explicit_for_backend_lookup() {
  local dir fake telemetry out rc
  dir="$TMP_ROOT/vendor-cost"
  mkdir -p "$dir"
  telemetry="$dir/telemetry.jsonl"
  fake="$dir/fake-cognee"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Generated hint without source references.'
SH
  chmod +x "$fake"

  set +e
  out=$(FM_COGNEE_TELEMETRY_FILE="$telemetry" FM_COGNEE_LOOKUP_CMD="$fake" "$MEMORY_LOOKUP" -- "anything")
  rc=$?
  set -e
  expect_code 0 "$rc" "memory lookup remains non-blocking"
  assert_contains "$out" "memory hint:" "memory output should still render"
  [ "$(json_field "$telemetry" estimated_cost_usd)" = "null" ] || fail "vendor cost should not silently be zero"
  [ "$(json_field "$telemetry" estimated_cost_status)" = "unknown_vendor_cost" ] || fail "unknown vendor cost should be explicit"
  pass "unknown Cognee vendor cost is explicit"
}

test_local_source_verification_telemetry_cost_is_zero() {
  local dir source manifest answer telemetry out rc
  dir="$TMP_ROOT/local-zero"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.jsonl"
  answer="$dir/answer.txt"
  telemetry="$dir/telemetry.jsonl"
  printf 'Redacted local source.\n' > "$source"
  write_jsonl_manifest "$manifest" "$source" "$(sha256_file "$source")"
  printf 'SOURCE_ID=seed-telemetry\nSOURCE_PATH=%s\nSEED_FILE=seed/redacted.md\n' "$source" > "$answer"

  set +e
  out=$(FM_COGNEE_TELEMETRY_FILE="$telemetry" "$VERIFY" --manifest "$manifest" --answer "$answer")
  rc=$?
  set -e
  expect_code 0 "$rc" "local source verification should pass"
  [ "$(printf '%s' "$out" | jq -r '.verification_result.status')" = "verified" ] || fail "verification output should be verified"
  [ "$(json_field "$telemetry" estimated_cost_usd)" = "0" ] || fail "local verification cost should be zero"
  [ "$(json_field "$telemetry" estimated_cost_status)" = "known_zero_local" ] || fail "local verification cost status should be explicit"
  pass "local source verification telemetry records zero cost"
}

test_raw_404_manifest_check_is_durability_failure_not_proof() {
  local dir source manifest answer telemetry out rc
  dir="$TMP_ROOT/raw-404"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  telemetry="$dir/telemetry.jsonl"
  printf 'local source truth\n' > "$source"
  write_tsv_manifest "$manifest" seed-404 "$source" failed_404
  printf 'SOURCE_ID=seed-404\n' > "$answer"

  set +e
  out=$(FM_COGNEE_TELEMETRY_FILE="$telemetry" "$MANIFEST_CHECK" --manifest "$manifest" --answer-file "$answer")
  rc=$?
  set -e
  expect_code 1 "$rc" "raw 404 should block proof"
  assert_contains "$out" "reason=raw_readback_durability_failure" "raw 404 should be classified as durability failure"
  assert_not_contains "$out" "label=verified_local_source" "raw 404 must not verify"
  [ "$(json_field "$telemetry" source_verification_outcome)" = "raw_readback_durability_failure" ] || fail "telemetry should record raw durability failure"
  pass "raw 404 readback is not verified proof"
}

test_telemetry_write_failure_does_not_block_lookup() {
  local dir out rc
  dir="$TMP_ROOT/telemetry-is-dir"
  mkdir -p "$dir"

  set +e
  out=$(FM_COGNEE_TELEMETRY_FILE="$dir" "$LOOKUP" --dry-run --query "safe query")
  rc=$?
  set -e
  expect_code 0 "$rc" "lookup should remain usable when telemetry cannot be written"
  assert_contains "$out" "reason=no_manifest_or_answer_fixture" "lookup behavior should continue"
  pass "telemetry write failure does not block lookup"
}

test_lookup_telemetry_redacts_query_answer_and_secret_values
test_unknown_vendor_cost_is_explicit_for_backend_lookup
test_local_source_verification_telemetry_cost_is_zero
test_raw_404_manifest_check_is_durability_failure_not_proof
test_telemetry_write_failure_does_not_block_lookup
