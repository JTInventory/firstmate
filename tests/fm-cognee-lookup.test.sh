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
    FM_COGNEE_DATASET_ALIAS="firstmate-curated-memory-0629" \
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
  assert_contains "$(cat "$telemetry")" '"parsed_source_id_count": 2' "telemetry records parsed source count"
  assert_contains "$(cat "$telemetry")" '"source_verification_outcome": "verified_local_source"' "telemetry records verification outcome"
  assert_contains "$(cat "$telemetry")" '"external_action_authorized": false' "telemetry never authorizes action"
  assert_contains "$(cat "$telemetry")" '"answer_body_logged": false' "search telemetry never logs answer bodies"
  assert_contains "$(cat "$telemetry")" '"confidence": "unknown"' "search telemetry keeps missing vendor cost unknown"
  pass "fake live search is parsed, verified locally, and redacted in telemetry"
}

test_live_retry_attempts_keep_logical_id_and_rotate_request_id() {
  local dir source manifest fakebin out code sha telemetry count_file payload secret
  dir="$TMP_ROOT/live-retry-correlation"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  fakebin=$(fm_fakebin "$dir")
  telemetry="$dir/telemetry.jsonl"
  count_file="$dir/curl-count"
  payload="$dir/payload.json"
  secret="SECRET_RETRY_ANSWER_BODY_DO_NOT_LOG"
  printf 'local source truth from retry search\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" retry-live-01 "$source" "$sha"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
out=
payload=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    --data-binary) payload=\${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$payload" ] && cp "\$payload" "$payload"
count=0
[ -f "$count_file" ] && count=\$(cat "$count_file")
count=\$((count + 1))
printf '%s\n' "\$count" > "$count_file"
if [ "\$count" -eq 1 ]; then
  printf '{"error":"temporary %s"}\n' "$secret" > "\$out"
  printf '503'
  exit 0
fi
cat > "\$out" <<JSON
[{"search_result":["SOURCE_ID=retry-live-01 SOURCE_PATH=$source $secret"]}]
JSON
printf '200'
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(PATH="$fakebin:$PATH" COGNEE_BASE_URL="https://cognee.invalid" COGNEE_API_KEY="secret-value" \
    FM_COGNEE_DATASET_ALIAS="firstmate-curated-memory-0629" FM_COGNEE_MAX_ATTEMPTS=2 \
    FM_COGNEE_TELEMETRY_FILE="$telemetry" "$ROOT/bin/fm-cognee-lookup.sh" \
    --query "retry correlation" --manifest "$manifest" 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "retrying fake live lookup should verify"
  assert_contains "$out" "retry_count=1" "retry count should be visible"
  assert_not_contains "$out" "$secret" "retry output must not print answer body"
  assert_present "$telemetry" "retry lookup should write telemetry"
  assert_not_contains "$(cat "$telemetry")" "$secret" "retry telemetry must not contain response body text"
  assert_json_missing_field "$payload" "run_id" "local run id must not be sent to Cognee"
  assert_json_missing_field "$payload" "request_id" "local request id must not be sent to Cognee"
  assert_json_missing_field "$payload" "logical_search_id" "local logical search id must not be sent to Cognee"
  python3 - "$telemetry" <<'PY' || fail "retry telemetry correlation assertions failed"
import json
import sys
from pathlib import Path

events = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
attempts = [event for event in events if event.get("event_type") == "api_attempt"]
if len(attempts) != 2:
    raise SystemExit(f"expected 2 api attempts, got {len(attempts)}")
first, second = attempts
if not all(event.get("run_id") and event.get("request_id") and event.get("logical_search_id") for event in attempts):
    raise SystemExit("missing top-level correlation ids")
if first["logical_search_id"] != second["logical_search_id"]:
    raise SystemExit("logical search id changed across retry")
if first["request_id"] == second["request_id"]:
    raise SystemExit("request id did not rotate per attempt")
if first["correlation"]["logical_search_id"] != first["logical_search_id"]:
    raise SystemExit("nested logical id mismatch")
if second["correlation"]["wrapper_request_id"] != second["request_id"]:
    raise SystemExit("nested request id mismatch")
if first["attempt"]["attempt_number"] != 1 or second["attempt"]["attempt_number"] != 2:
    raise SystemExit("attempt numbers were not logged")
if first["attempt"]["final_attempt"] is not False or second["attempt"]["final_attempt"] is not True:
    raise SystemExit("final attempt flags were not logged")
if first["status"]["http_status"] != 503 or second["status"]["http_status"] != 200:
    raise SystemExit("HTTP statuses were not logged per attempt")
for event in attempts:
    if event["privacy"]["answer_body_logged"] is not False:
        raise SystemExit("privacy answer_body_logged must be false")
    if event["results"]["answer_body_logged"] is not False:
        raise SystemExit("results answer_body_logged must be false")
    if event["vendor_usage"]["vendor_usage_present"] is not False:
        raise SystemExit("vendor usage should be absent")
    if event["vendor_usage"]["cost_usd"] is not None:
        raise SystemExit("unknown vendor cost should be null")
    if event["cost_estimate"]["estimated_cost_usd"] is not None:
        raise SystemExit("unknown estimated cost should be null")
    if event["cost_estimate"]["estimate_source"] != "missing_vendor_metadata":
        raise SystemExit("missing vendor metadata source should be explicit")
PY
  pass "retry attempts share logical search id and rotate request id"
}

test_live_env_file_loads_allowlisted_names_safely() {
  local dir source manifest fakebin envfile out code sha telemetry marker complex_secret
  dir="$TMP_ROOT/live-env-file"
  mkdir -p "$dir"
  source="$dir/source.md"
  manifest="$dir/manifest.tsv"
  envfile="$dir/cognee.env"
  fakebin=$(fm_fakebin "$dir")
  telemetry="$dir/telemetry.jsonl"
  marker="$dir/should-not-exist"
  # shellcheck disable=SC2016 # Command substitution text must stay literal for env-loader safety coverage.
  complex_secret='value with spaces @ dollar$ backtick` double" single'\'' semi;colon $(touch '"$marker"')'
  printf 'local source truth from env-file lookup\n' > "$source"
  sha=$(sha256sum "$source" | awk '{print $1}')
  write_manifest "$manifest" env-file-01 "$source" "$sha"
  {
    printf '%s\n' '# safe dotenv fixture'
    printf 'COGNEE_BASE_URL=%s\n' 'https://env-file.invalid'
    printf 'COGNEE_API_KEY=%s\n' "$complex_secret"
    printf 'FM_COGNEE_DATASET_ALIAS=%s\n' 'firstmate-curated-memory-0629'
    printf 'FM_COGNEE_MANIFEST=%s\n' "$manifest"
    # shellcheck disable=SC2016 # Command substitution text must stay literal for env-loader safety coverage.
    printf 'UNSAFE_UNKNOWN=%s\n' '$(touch '"$marker"')'
  } > "$envfile"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=
saw_endpoint=false
saw_key=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H)
      [ "$2" = "X-Api-Key: $EXPECTED_COGNEE_API_KEY" ] && saw_key=true
      shift 2
      ;;
    https://env-file.invalid/api/v1/search)
      saw_endpoint=true
      shift
      ;;
    *) shift ;;
  esac
done
"$saw_endpoint" || exit 41
"$saw_key" || exit 42
cat > "$out" <<JSON
[{"search_result":["SOURCE_ID=env-file-01 SOURCE_PATH=$EXPECTED_SOURCE"]}]
JSON
printf '200'
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(PATH="$fakebin:$PATH" EXPECTED_COGNEE_API_KEY="$complex_secret" EXPECTED_SOURCE="$source" \
    FM_COGNEE_ENV_FILE="$envfile" FM_COGNEE_TELEMETRY_FILE="$telemetry" \
    "$ROOT/bin/fm-cognee-lookup.sh" --query "env file lookup" 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "env-file live lookup should verify"
  assert_contains "$out" "mode=live" "env-file lookup should reach live mode"
  assert_contains "$out" "label=verified_local_source" "env-file lookup should verify through manifest"
  assert_contains "$out" "external_action_authorized=false" "env-file lookup cannot authorize action"
  assert_not_contains "$out" "$complex_secret" "env-file output must not print loaded secret values"
  assert_present "$telemetry" "env-file lookup should write telemetry"
  assert_not_contains "$(cat "$telemetry")" "$complex_secret" "env-file telemetry must not print loaded secret values"
  assert_absent "$marker" "dotenv values and unknown keys must not be executed"
  pass "FM_COGNEE_ENV_FILE loads allowlisted names without executing or printing values"
}

test_live_env_file_ignores_unknown_names() {
  local dir manifest fakebin envfile payload out code marker
  dir="$TMP_ROOT/live-env-file-unknown"
  mkdir -p "$dir"
  manifest="$dir/manifest.tsv"
  payload="$dir/payload.json"
  fakebin=$(fm_fakebin "$dir")
  envfile="$dir/cognee.env"
  marker="$dir/unknown-executed"
  : > "$manifest"
  write_payload_capture_curl "$fakebin" "$payload" 404
  {
    printf 'COGNEE_BASE_URL=%s\n' 'https://cognee.invalid'
    printf 'COGNEE_API_KEY=%s\n' 'safe-test-key'
    printf 'FM_COGNEE_DATASET_ALIAS=%s\n' 'firstmate-curated-memory-0629'
    printf 'FM_COGNEE_MANIFEST=%s\n' "$manifest"
    printf 'FM_COGNEE_TELEMETRY_FILE=%s\n' "$dir/ignored-telemetry.jsonl"
    # shellcheck disable=SC2016 # Command substitution text must stay literal for env-loader safety coverage.
    printf 'UNKNOWN_NAME=%s\n' '$(touch '"$marker"')'
    printf '%s\n' "UNKNOWN_QUOTED='ignored"
  } > "$envfile"

  set +e
  out=$(PATH="$fakebin:$PATH" FM_COGNEE_ENV_FILE="$envfile" \
    "$ROOT/bin/fm-cognee-lookup.sh" --query "unknown names" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "fake HTTP failure should stop after env-file load"
  assert_json_field "$payload" "datasets" "firstmate-curated-memory-0629" "allowlisted dataset alias should load"
  assert_absent "$marker" "unknown env names must not execute"
  assert_absent "$dir/ignored-telemetry.jsonl" "unknown FM_COGNEE_TELEMETRY_FILE must be ignored"
  assert_not_contains "$out" "safe-test-key" "output must not print env-file API key"
  pass "FM_COGNEE_ENV_FILE ignores unknown names"
}

test_live_env_file_malformed_fails_closed_without_values() {
  local dir envfile out code secret
  dir="$TMP_ROOT/live-env-file-malformed"
  mkdir -p "$dir"
  envfile="$dir/cognee.env"
  secret="MALFORMED_SECRET_SHOULD_NOT_PRINT"
  {
    printf 'COGNEE_BASE_URL=%s\n' 'https://cognee.invalid'
    printf 'COGNEE_API_KEY=%s\n' "$secret"
    printf '%s\n' 'this is not dotenv'
  } > "$envfile"

  set +e
  out=$(FM_COGNEE_ENV_FILE="$envfile" "$ROOT/bin/fm-cognee-lookup.sh" --query "malformed env" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "malformed env file should fail closed"
  assert_contains "$out" "reason=env_file_malformed" "malformed env file reason is explicit"
  assert_contains "$out" "external_action_authorized=false" "malformed env file cannot authorize action"
  assert_not_contains "$out" "$secret" "malformed env failure must not print secret values"
  pass "malformed FM_COGNEE_ENV_FILE fails closed without values"
}

test_live_env_file_unreadable_fails_closed_without_values() {
  local dir envfile out code
  dir="$TMP_ROOT/live-env-file-unreadable"
  mkdir -p "$dir"
  envfile="$dir/missing.env"

  set +e
  out=$(FM_COGNEE_ENV_FILE="$envfile" "$ROOT/bin/fm-cognee-lookup.sh" --query "unreadable env" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "unreadable env file should fail closed"
  assert_contains "$out" "reason=env_file_unreadable" "unreadable env file reason is explicit"
  assert_contains "$out" "external_action_authorized=false" "unreadable env file cannot authorize action"
  assert_not_contains "$out" "$envfile" "unreadable env failure should not print env-file path"
  pass "unreadable FM_COGNEE_ENV_FILE fails closed without values"
}

test_live_env_file_missing_required_names_still_fails_closed() {
  local dir envfile out code secret
  dir="$TMP_ROOT/live-env-file-missing"
  mkdir -p "$dir"
  envfile="$dir/cognee.env"
  secret="PARTIAL_SECRET_SHOULD_NOT_PRINT"
  {
    printf 'COGNEE_API_KEY=%s\n' "$secret"
    printf 'FM_COGNEE_DATASET_ALIAS=%s\n' 'firstmate-curated-memory-0629'
  } > "$envfile"

  set +e
  out=$(FM_COGNEE_ENV_FILE="$envfile" "$ROOT/bin/fm-cognee-lookup.sh" --query "missing required" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "env file missing required names should fail closed"
  assert_contains "$out" "reason=missing_required_env" "missing required env is still explicit"
  assert_contains "$out" "missing_env=COGNEE_BASE_URL" "missing required name is reported by name only"
  assert_not_contains "$out" "$secret" "missing required env output must not print loaded secret values"
  pass "env-file loading does not bypass required env checks"
}

write_payload_capture_curl() {
  local fakebin=$1 capture=$2 status=${3:-404}
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
out=
payload=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    --data-binary) payload=\${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$out" ] && printf '{}\n' > "\$out"
[ -n "\$payload" ] && cp "\$payload" "$capture"
printf '%s' "$status"
SH
  chmod +x "$fakebin/curl"
}

assert_json_field() {
  local file=$1 expr=$2 expected=$3 msg=$4
  local actual
  actual=$(python3 - "$file" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)
for part in expr.split("."):
    value = value[part]
if isinstance(value, list):
    print(",".join(str(item) for item in value))
else:
    print(value)
PY
)
  [ "$actual" = "$expected" ] || fail "$msg: expected '$expected', got '$actual'"
}

assert_json_missing_field() {
  local file=$1 expr=$2 msg=$3
  python3 - "$file" "$expr" <<'PY' || return 0
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)
for part in expr.split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
raise SystemExit(0)
PY
  fail "$msg"
}

test_live_payload_uses_dataset_id_selector_when_uuid_is_set() {
  local dir manifest fakebin payload out code telemetry uuid hash
  dir="$TMP_ROOT/live-dataset-id"
  mkdir -p "$dir"
  manifest="$dir/manifest.tsv"
  payload="$dir/payload.json"
  telemetry="$dir/telemetry.jsonl"
  fakebin=$(fm_fakebin "$dir")
  uuid="123e4567-e89b-12d3-a456-426614174000"
  hash=$(printf '%s' "$uuid" | sha256sum | awk '{print $1}')
  : > "$manifest"
  write_payload_capture_curl "$fakebin" "$payload" 404

  set +e
  out=$(PATH="$fakebin:$PATH" COGNEE_BASE_URL="https://cognee.invalid" COGNEE_API_KEY="secret-value" \
    COGNEE_DATASET_ID="$uuid" FM_COGNEE_DATASET_ALIAS="alias-should-not-win" \
    FM_COGNEE_TELEMETRY_FILE="$telemetry" "$ROOT/bin/fm-cognee-lookup.sh" \
    --query "selector check" --manifest "$manifest" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "fake HTTP failure should stop after payload capture"
  assert_json_field "$payload" "datasetIds" "$uuid" "UUID dataset id should be sent as datasetIds"
  assert_json_missing_field "$payload" "datasets" "dataset alias should not be sent when UUID dataset id is available"
  assert_not_contains "$out" "$uuid" "raw dataset id must not be printed"
  assert_present "$telemetry" "HTTP failure should write telemetry"
  assert_not_contains "$(cat "$telemetry")" "$uuid" "telemetry must not contain raw dataset id"
  assert_contains "$(cat "$telemetry")" "\"dataset_id_hash\": \"sha256:$hash\"" "telemetry should keep only dataset id hash"
  pass "live payload uses datasetIds when COGNEE_DATASET_ID is a UUID"
}

test_live_payload_uses_dataset_alias_selector_without_uuid() {
  local dir manifest fakebin payload out code alias
  dir="$TMP_ROOT/live-dataset-alias"
  mkdir -p "$dir"
  manifest="$dir/manifest.tsv"
  payload="$dir/payload.json"
  fakebin=$(fm_fakebin "$dir")
  alias="firstmate-curated-memory-0629"
  : > "$manifest"
  write_payload_capture_curl "$fakebin" "$payload" 404

  set +e
  out=$(PATH="$fakebin:$PATH" COGNEE_BASE_URL="https://cognee.invalid" COGNEE_API_KEY="secret-value" \
    COGNEE_DATASET_ID="not-a-uuid" FM_COGNEE_DATASET_ALIAS="$alias" \
    "$ROOT/bin/fm-cognee-lookup.sh" --query "selector check" --manifest "$manifest" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "fake HTTP failure should stop after alias payload capture"
  assert_json_field "$payload" "datasets" "$alias" "dataset alias should be sent as datasets"
  assert_json_missing_field "$payload" "datasetIds" "invalid dataset id should not be sent"
  assert_not_contains "$out" "not-a-uuid" "invalid dataset id should not be printed"
  pass "live payload uses datasets when only FM_COGNEE_DATASET_ALIAS is usable"
}

test_live_mode_fails_closed_without_dataset_selector() {
  local dir manifest fakebin payload out code telemetry
  dir="$TMP_ROOT/live-no-selector"
  mkdir -p "$dir"
  manifest="$dir/manifest.tsv"
  payload="$dir/payload.json"
  telemetry="$dir/telemetry.jsonl"
  fakebin=$(fm_fakebin "$dir")
  : > "$manifest"
  write_payload_capture_curl "$fakebin" "$payload" 200

  set +e
  out=$(PATH="$fakebin:$PATH" env -u COGNEE_DATASET_ID -u FM_COGNEE_DATASET_ALIAS \
    COGNEE_BASE_URL="https://cognee.invalid" COGNEE_API_KEY="secret-value" \
    FM_COGNEE_TELEMETRY_FILE="$telemetry" "$ROOT/bin/fm-cognee-lookup.sh" \
    --query "selector check" --manifest "$manifest" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "live lookup without dataset selector should fail closed"
  assert_contains "$out" "reason=missing_dataset_selector" "missing selector reason is explicit"
  assert_contains "$out" "external_action_authorized=false" "missing selector cannot authorize action"
  assert_absent "$payload" "curl must not run without a dataset selector"
  assert_present "$telemetry" "missing selector should write telemetry"
  assert_contains "$(cat "$telemetry")" '"error_class": "missing_dataset_selector"' "telemetry records missing selector"
  pass "live mode fails closed before HTTP when no dataset selector is available"
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
test_live_mode_fails_closed_without_dataset_selector
test_live_payload_uses_dataset_alias_selector_without_uuid
test_live_payload_uses_dataset_id_selector_when_uuid_is_set
test_live_fake_search_parses_verifies_and_writes_redacted_telemetry
test_live_retry_attempts_keep_logical_id_and_rotate_request_id
test_live_env_file_loads_allowlisted_names_safely
test_live_env_file_ignores_unknown_names
test_live_env_file_malformed_fails_closed_without_values
test_live_env_file_unreadable_fails_closed_without_values
test_live_env_file_missing_required_names_still_fails_closed
test_generic_report_seed_file_does_not_verify_by_itself
