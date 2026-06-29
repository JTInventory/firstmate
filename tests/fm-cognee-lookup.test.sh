#!/usr/bin/env bash
# Behavior tests for local-only Cognee lookup and manifest verification.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cognee-lookup-tests)

write_manifest() {
  local manifest=$1 row_id=$2 source_path=$3 source_sha=$4 redaction=${5:-passed} stale=${6:-low}
  local size mtime
  size=$(wc -c < "$source_path" | tr -d ' ')
  mtime=$(date -u -r "$source_path" '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf '%s\t' row_id source_group source_path source_truth_pointer source_kind recommended_tier decision_status redaction_status redaction_notes sensitivity_label stale_risk supersession_check source_size_bytes source_mtime_utc source_sha256 estimated_words estimated_tokens estimated_cost_formula import_text_prefix raw_readback_status verification_status cognee_source_id
    printf '\n'
    printf '%s\t' "$row_id" firstmate_reports "$source_path" "$source_path" report direct_import allowed "$redaction" "test scan" internal "$stale" checked_current "$size" "$mtime" "$source_sha" 12 16 "words * 1.3" "SOURCE_ID=$row_id SOURCE_PATH=$source_path SEED_FILE=$(basename "$source_path")" not_trusted verified_local_source "$row_id"
    printf '\n'
  } > "$manifest"
}

test_live_missing_env_fails_closed_without_secret_values() {
  local out code telemetry secret
  telemetry="$TMP_ROOT/missing-env-telemetry.jsonl"
  secret="SECRET_API_KEY_SHOULD_NOT_PRINT"

  set +e
  out=$(env -u COGNEE_BASE_URL COGNEE_API_KEY="$secret" FM_COGNEE_TELEMETRY_FILE="$telemetry" \
    "$ROOT/bin/fm-cognee-lookup.sh" --query "find cognee proof" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "live lookup missing env should fail closed"
  assert_contains "$out" "reason=missing_required_env" "missing env reason is explicit"
  assert_contains "$out" "missing_env=COGNEE_BASE_URL" "missing env names are reported"
  assert_contains "$out" "external_action_authorized=false" "missing env cannot authorize action"
  assert_not_contains "$out" "$secret" "missing env output must not print secret values"
  assert_present "$telemetry" "missing env should write telemetry"
  assert_not_contains "$(cat "$telemetry")" "$secret" "telemetry must not contain API key"
  assert_contains "$(cat "$telemetry")" '"external_action_authorized": false' "telemetry keeps action authorization false"
  pass "live lookup missing env fails closed without printing secret values"
}

test_live_fake_search_parses_verifies_and_writes_redacted_telemetry() {
  local dir source manifest fakebin out code sha telemetry secret
  dir="$TMP_ROOT/live-fake"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  fakebin=$(fm_fakebin "$dir")
  telemetry="$dir/telemetry.jsonl"
  secret="SECRET_LIVE_API_KEY_DO_NOT_LOG"
  printf 'local source truth from fake live search\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" batch-live-01 "$source" "$sha"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
out=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "\$out" <<'JSON'
[{"dataset_name":"firstmate-curated-memory-0629","search_result":["**SOURCE_ID:** batch-live-01\\n**SOURCE_PATH:** $source\\nEvidence mentions generated ids 123e4567-e89b-12d3-a456-426614174000 and Markdown, but local proof comes from the manifest row."]}]
JSON
printf '200'
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(PATH="$fakebin:$PATH" COGNEE_BASE_URL="https://cognee.invalid" COGNEE_API_KEY="$secret" \
    FM_COGNEE_TELEMETRY_FILE="$telemetry" "$ROOT/bin/fm-cognee-lookup.sh" \
    --query "which source matters" --manifest "$manifest")
  code=$?
  set -e
  expect_code 0 "$code" "fake live lookup should verify"
  assert_contains "$out" "mode=live" "live mode should be visible"
  assert_contains "$out" "http_status=200" "HTTP status should be reported"
  assert_contains "$out" "parsed_source_count=2" "source labels should be counted"
  assert_contains "$out" "label=verified_local_source" "manifest plus local reopen verifies source"
  assert_contains "$out" "external_action_authorized=false" "verified lookup still cannot authorize action"
  assert_not_contains "$out" "$secret" "live output must not print API key"
  assert_present "$telemetry" "live lookup should write telemetry"
  assert_not_contains "$(cat "$telemetry")" "$secret" "live telemetry must not contain API key"
  assert_contains "$(cat "$telemetry")" '"endpoint_template": "/api/v1/search"' "telemetry records read-only search endpoint"
  assert_contains "$(cat "$telemetry")" '"http_status": 200' "telemetry records HTTP status"
  assert_contains "$(cat "$telemetry")" '"parsed_source_count": 2' "telemetry records parsed source count"
  assert_contains "$(cat "$telemetry")" '"source_verification_outcome": "verified_local_source"' "telemetry records verification outcome"
  assert_contains "$(cat "$telemetry")" '"external_action_authorized": false' "telemetry never authorizes action"
  pass "fake live search is parsed, verified locally, and redacted in telemetry"
}

test_dry_run_blocks_live_mode() {
  local out code
  out=$("$ROOT/bin/fm-cognee-lookup.sh" --query "find cognee proof" 2>&1)
  code=$?
  expect_code 2 "$code" "live lookup without env fails closed"
  assert_contains "$out" "reason=missing_required_env" "live mode states missing env names"
  assert_contains "$out" "external_action_authorized=false" "live failure cannot authorize action"
  pass "cognee lookup live mode fails closed without env"
}

test_dry_run_verifies_local_source_without_echoing_answer() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/verified"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-001 "$source" "$sha"
  printf 'Generated answer with SOURCE_ID=fm-cognee-001 and secret-like body DO_NOT_PRINT_ME.\n' > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "which report matters" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 0 "$code" "verified dry-run exits successfully"
  assert_contains "$out" "cognee_answer_status=hint_only" "raw Cognee answer remains hint-only"
  assert_contains "$out" "label=verified_local_source" "manifest and source checksum produce verified label"
  assert_contains "$out" "external_action_authorized=false" "verified lookup still cannot authorize action"
  assert_not_contains "$out" "DO_NOT_PRINT_ME" "wrapper does not echo answer body"
  assert_not_contains "$out" "which report matters" "wrapper does not echo query text"
  pass "dry-run verifies local source without echoing raw query or answer"
}

test_missing_citation_blocks_proof() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/missing-citation"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-002 "$source" "$sha"
  printf 'Generated answer with no source labels.\n' > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 3 "$code" "missing citation exits as blocked"
  assert_contains "$out" "label=blocked_missing_proof" "missing citation cannot verify"
  assert_contains "$out" "reason=no_usable_citations" "missing citation reason is explicit"
  pass "missing Cognee citations fail closed"
}

test_source_path_and_seed_file_references_verify() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/path-seed"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-002b "$source" "$sha"
  printf 'Generated answer cites SOURCE_PATH=%s.\n' "$source" > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 0 "$code" "source path dry-run exits successfully"
  assert_contains "$out" "label=verified_local_source" "SOURCE_PATH references can verify"
  assert_contains "$out" "matched_ref=SOURCE_PATH" "source path reference is recognized"

  printf 'Generated answer cites SEED_FILE=%s.\n' "$(basename "$source")" > "$answer"
  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 0 "$code" "seed file dry-run exits successfully"
  assert_contains "$out" "label=verified_local_source" "SEED_FILE references can verify"
  assert_contains "$out" "matched_ref=SEED_FILE" "seed file reference is recognized"
  pass "SOURCE_PATH and SEED_FILE references can verify local sources"
}

test_generic_report_seed_file_does_not_verify_by_itself() {
  local dir source_a source_b manifest answer out code sha_a sha_b
  dir="$TMP_ROOT/generic-seed"
  mkdir -p "$dir/a" "$dir/b"
  source_a="$dir/a/report.md"
  source_b="$dir/b/report.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth a\n' > "$source_a"
  printf 'local source truth b\n' > "$source_b"
  sha_a=$(sha256sum "$source_a" | awk '{print $1}')
  sha_b=$(sha256sum "$source_b" | awk '{print $1}')
  write_manifest "$manifest" batch-report-a "$source_a" "$sha_a"
  tail -n 1 "$manifest" > "$dir/row-a.tsv"
  write_manifest "$dir/manifest-b.tsv" batch-report-b "$source_b" "$sha_b"
  tail -n 1 "$dir/manifest-b.tsv" >> "$manifest"
  printf 'Generated answer cites only SEED_FILE=report.md and a Markdown UUID 123e4567-e89b-12d3-a456-426614174000.\n' > "$answer"

  set +e
  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  set -e
  expect_code 3 "$code" "generic report.md seed file should not prove a source"
  assert_contains "$out" "reason=manifest_reference_not_found" "generic seed file is not precise attribution"
  assert_not_contains "$out" "label=verified_local_source" "generic seed file cannot verify"
  pass "generic report.md seed references do not create false proof"
}

test_checksum_mismatch_blocks_proof() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/checksum"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth\n' > "$source"
  sha=$(printf 'wrong' | sha256sum | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-003 "$source" "$sha"
  printf 'SOURCE_ID=fm-cognee-003\n' > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 1 "$code" "checksum mismatch exits as invalid"
  assert_contains "$out" "reason=checksum_mismatch" "checksum mismatch is reported"
  assert_not_contains "$out" "label=verified_local_source" "bad checksum cannot verify"
  pass "checksum mismatch blocks proof"
}

test_redaction_not_checked_blocks_proof() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/redaction"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-004 "$source" "$sha" not_checked
  printf 'SOURCE_ID=fm-cognee-004\n' > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 1 "$code" "unchecked redaction exits as invalid"
  assert_contains "$out" "reason=redaction_not_passed" "redaction status blocks local verification"
  pass "unchecked redaction blocks proof"
}

test_secret_risk_path_blocks_without_echoing_path() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/secret-token-source"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'local source truth\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-004b "$source" "$sha"
  printf 'SOURCE_ID=fm-cognee-004b\n' > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 1 "$code" "secret-looking path exits as invalid"
  assert_contains "$out" "reason=path_risk_scan_failed" "path risk scan blocks local verification"
  assert_not_contains "$out" "$dir" "risky source path is not echoed"
  pass "secret-risk paths block without echoing the risky path"
}

test_high_stale_risk_warns_after_local_verification() {
  local dir source manifest answer out code sha
  dir="$TMP_ROOT/stale"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  answer="$dir/answer.txt"
  printf 'historical source truth\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" fm-cognee-005 "$source" "$sha" passed high
  printf 'SOURCE_ID=fm-cognee-005\n' > "$answer"

  out=$("$ROOT/bin/fm-cognee-lookup.sh" --dry-run --query "lookup" --manifest "$manifest" --answer-file "$answer")
  code=$?
  expect_code 0 "$code" "stale warning exits successfully"
  assert_contains "$out" "label=stale_warning" "high stale risk is not plain proof"
  assert_contains "$out" "stale_risk=high" "stale risk is surfaced"
  pass "high stale risk remains visible after local verification"
}

test_dry_run_blocks_live_mode
test_dry_run_verifies_local_source_without_echoing_answer
test_missing_citation_blocks_proof
test_source_path_and_seed_file_references_verify
test_checksum_mismatch_blocks_proof
test_redaction_not_checked_blocks_proof
test_secret_risk_path_blocks_without_echoing_path
test_high_stale_risk_warns_after_local_verification
test_live_missing_env_fails_closed_without_secret_values
test_live_fake_search_parses_verifies_and_writes_redacted_telemetry
test_generic_report_seed_file_does_not_verify_by_itself
