#!/usr/bin/env bash
# Local and live read-only wrapper for Cognee lookup integration.
#
# Dry-run mode accepts a local answer fixture. Live mode calls only the read-only
# Cognee search endpoint, treats the response as an untrusted hint, and asks the
# local manifest checker to prove whether any cited source can be reopened and
# checksum-verified.
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: fm-cognee-lookup.sh [--dry-run] --query <text> [--manifest <manifest.tsv|manifest.jsonl> --answer-file <answer.txt>]
       fm-cognee-lookup.sh <query text>

Live mode uses already-exported environment variables, plus allowlisted names
from FM_COGNEE_ENV_FILE when set:
  COGNEE_BASE_URL
  COGNEE_API_KEY
  COGNEE_DATASET_ID or FM_COGNEE_DATASET_ALIAS
  FM_COGNEE_MANIFEST or --manifest
  FM_COGNEE_TIMEOUT_MS defaults to 30000 and sets connect/request timeouts

It can be used through:
  FM_COGNEE_LOOKUP_CMD=/absolute/path/to/bin/fm-cognee-lookup.sh

Live mode calls only POST /api/v1/search and never creates datasets, imports,
cognifies, deletes, syncs, mutates config, mutates MCP, or writes env files.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-cognee-telemetry-lib.sh"
TELEMETRY_START_MS=$(fm_cognee_telemetry_now_ms)
FM_COGNEE_RUN_ID=$(fm_cognee_new_id cognee-run)
FM_COGNEE_LOGICAL_SEARCH_ID=$(fm_cognee_new_id cognee-search)
DRY_RUN=false
QUERY=
MANIFEST=
ANSWER_FILE=
POSITIONAL=()

safe_label() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_.:-]+/_/g; s/^_+//; s/_+$//' | cut -c 1-120
}

dataset_alias() {
  printf '%s' "${FM_COGNEE_DATASET_ALIAS:-unknown}"
}

is_uuid() {
  printf '%s' "${1:-}" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

dataset_id_hash() {
  if [ -n "${COGNEE_DATASET_ID:-}" ] && is_uuid "$COGNEE_DATASET_ID"; then
    printf 'sha256:%s' "$(printf '%s' "$COGNEE_DATASET_ID" | sha256sum | awk '{print $1}')"
  fi
}

fm_cognee_timeout_ms() {
  local value=${FM_COGNEE_TIMEOUT_MS:-30000}
  case "$value" in ''|*[!0-9]*) value=30000 ;; esac
  [ "$value" -ge 1 ] || value=30000
  printf '%s' "$value"
}

fm_cognee_timeout_seconds() {
  awk -v ms="$(fm_cognee_timeout_ms)" 'BEGIN { printf "%.3f", ms / 1000 }'
}

has_live_dataset_selector() {
  if [ -n "${COGNEE_DATASET_ID:-}" ] && is_uuid "$COGNEE_DATASET_ID"; then
    return 0
  fi
  [ -n "${FM_COGNEE_DATASET_ALIAS:-}" ]
}

live_telemetry_log() {
  local status=$1 error_class=$2 http_status=$3 retryable=$4 retry_count=$5 latency_ms=$6 parsed_source_count=$7 verification_outcome=$8
  local request_id=${9:-}
  local attempt_number=${10:-}
  local final_attempt=${11:-true}
  local request_body_bytes=${12:-}
  local response_body_bytes=${13:-}
  local dataset_alias_value dataset_id_hash_value is_retry retry_reason top_k
  [ -n "$request_id" ] || request_id=$(fm_cognee_new_id cognee-req)
  [ -n "$attempt_number" ] || attempt_number=$((retry_count + 1))
  if [ "$attempt_number" -gt 1 ] 2>/dev/null; then
    is_retry=true
    retry_reason=retryable_http_or_transport
  else
    is_retry=false
    retry_reason=none
  fi
  dataset_alias_value=$(dataset_alias)
  dataset_id_hash_value=$(dataset_id_hash)
  top_k=${FM_COGNEE_TOP_K:-8}
  case "$top_k" in ''|*[!0-9]*) top_k=8 ;; esac
  fm_cognee_telemetry_log_api_attempt \
    search POST /api/v1/search false "$status" "$error_class" "$http_status" "$retryable" \
    "$attempt_number" "${FM_COGNEE_MAX_ATTEMPTS:-3}" "$is_retry" "$retry_reason" \
    "$latency_ms" "$(fm_cognee_timeout_ms)" "$verification_outcome" true "$parsed_source_count" \
    "" unknown missing_vendor_metadata false "$FM_COGNEE_RUN_ID" "$request_id" "$FM_COGNEE_LOGICAL_SEARCH_ID" \
    "$dataset_alias_value" "$dataset_id_hash_value" "${FM_COGNEE_SEARCH_TYPE:-RAG_COMPLETION}" "$top_k" true \
    "$request_body_bytes" "$response_body_bytes" "$parsed_source_count" "$final_attempt"
}

json_payload() {
  local output=$1
  FM_COGNEE_QUERY=$QUERY \
  FM_COGNEE_SEARCH_TYPE=${FM_COGNEE_SEARCH_TYPE:-RAG_COMPLETION} \
  FM_COGNEE_TOP_K=${FM_COGNEE_TOP_K:-8} \
  COGNEE_DATASET_ID=${COGNEE_DATASET_ID:-} \
  FM_COGNEE_DATASET_ALIAS=${FM_COGNEE_DATASET_ALIAS:-} \
  python3 - "$output" <<'PY'
import json
import os
import re
import sys

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)

try:
    top_k = int(os.environ.get("FM_COGNEE_TOP_K") or 8)
except ValueError:
    top_k = 8
payload = {
    "query": os.environ.get("FM_COGNEE_QUERY", ""),
    "searchType": os.environ.get("FM_COGNEE_SEARCH_TYPE") or "RAG_COMPLETION",
    "topK": top_k,
    "includeReferences": True,
}
dataset_id = os.environ.get("COGNEE_DATASET_ID") or ""
dataset_alias = os.environ.get("FM_COGNEE_DATASET_ALIAS") or ""
if UUID_RE.match(dataset_id):
    payload["datasetIds"] = [dataset_id]
elif dataset_alias:
    payload["datasets"] = [dataset_alias]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

extract_answer_text() {
  local response_file=$1 answer_file=$2 count_file=$3
  python3 - "$response_file" "$answer_file" "$count_file" <<'PY'
import json
import re
import sys
from pathlib import Path


response_path, answer_path, count_path = map(Path, sys.argv[1:])
SOURCE_RE = re.compile(r"\b(?:SOURCE_ID|SOURCE_PATH|SEED_FILE)\s*[:=]")

try:
    data = json.loads(response_path.read_text(encoding="utf-8"))
except Exception:
    data = response_path.read_text(encoding="utf-8", errors="replace")

strings = []


def walk(value, key=""):
    if isinstance(value, dict):
        for child_key, child in value.items():
            walk(child, str(child_key))
    elif isinstance(value, list):
        for child in value:
            walk(child, key)
    elif isinstance(value, str):
        if key in {"search_result", "answer", "text", "content", "result"} or SOURCE_RE.search(value):
            strings.append(value)


walk(data)
if not strings and isinstance(data, str):
    strings.append(data)
answer = "\n".join(strings)
answer_path.write_text(answer, encoding="utf-8")
count_path.write_text(str(len(SOURCE_RE.findall(answer))) + "\n", encoding="utf-8")
PY
}

verification_outcome() {
  local file=$1
  python3 - "$file" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
lines = [line for line in text.splitlines() if line.strip()]
for line in lines:
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    result = obj.get("verification_result", {})
    if result.get("outcome"):
        print(result["outcome"])
        raise SystemExit
for line in lines:
    for token in line.split():
        if token.startswith("reason="):
            print(token.split("=", 1)[1])
            raise SystemExit
        if token.startswith("label="):
            print(token.split("=", 1)[1])
            raise SystemExit
print("not_attempted")
PY
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --query)
      QUERY=${2:-}
      [ -n "$QUERY" ] || die "--query requires text"
      shift 2
      ;;
    --manifest)
      MANIFEST=${2:-}
      [ -n "$MANIFEST" ] || die "--manifest requires a path"
      shift 2
      ;;
    --answer-file)
      ANSWER_FILE=${2:-}
      [ -n "$ANSWER_FILE" ] || die "--answer-file requires a path"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ -z "$QUERY" ] && [ "${#POSITIONAL[@]}" -gt 0 ]; then
  QUERY=${POSITIONAL[*]}
fi

if ! "$DRY_RUN"; then
  [ -n "$QUERY" ] || die "--query is required in live mode"
  if ! fm_cognee_load_env_file; then
    env_error=${FM_COGNEE_ENV_FILE_LOAD_ERROR:-env_file_malformed}
    live_telemetry_log blocked "$env_error" "" false 0 \
      "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" 0 "$env_error"
    if [ -n "${FM_COGNEE_ENV_FILE_LOAD_LINE:-}" ]; then
      echo "label=blocked_missing_proof reason=$env_error line=$FM_COGNEE_ENV_FILE_LOAD_LINE external_action_authorized=false" >&2
    else
      echo "label=blocked_missing_proof reason=$env_error external_action_authorized=false" >&2
    fi
    exit 2
  fi
  MANIFEST=${MANIFEST:-${FM_COGNEE_MANIFEST:-}}

  missing_env=
  [ -n "${COGNEE_BASE_URL:-}" ] || missing_env="${missing_env:+$missing_env,}COGNEE_BASE_URL"
  [ -n "${COGNEE_API_KEY:-}" ] || missing_env="${missing_env:+$missing_env,}COGNEE_API_KEY"
  if [ -n "$missing_env" ]; then
    live_telemetry_log blocked missing_required_env "" false 0 \
      "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" 0 missing_required_env
    echo "label=blocked_missing_proof reason=missing_required_env missing_env=$missing_env external_action_authorized=false" >&2
    exit 2
  fi

  if [ -z "$MANIFEST" ]; then
    live_telemetry_log blocked missing_manifest "" false 0 \
      "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" 0 missing_manifest
    echo "label=blocked_missing_proof reason=missing_manifest external_action_authorized=false" >&2
    exit 2
  fi
  [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

  if ! has_live_dataset_selector; then
    live_telemetry_log blocked missing_dataset_selector "" false 0 \
      "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" 0 missing_dataset_selector
    echo "label=blocked_missing_proof reason=missing_dataset_selector external_action_authorized=false" >&2
    exit 2
  fi

  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cognee-live.XXXXXX")
  # shellcheck disable=SC2317 # Invoked by trap.
  cleanup_live() { rm -rf "$TMP_DIR"; }
  trap cleanup_live EXIT
  PAYLOAD="$TMP_DIR/search.json"
  BODY="$TMP_DIR/body.json"
  ANSWER="$TMP_DIR/answer.txt"
  VERIFY_OUT="$TMP_DIR/verify.out"
  COUNT_FILE="$TMP_DIR/source-count.txt"
  CURL_ERR="$TMP_DIR/curl.err"
  json_payload "$PAYLOAD"

  base=${COGNEE_BASE_URL%/}
  endpoint="$base/api/v1/search"
  max_attempts=${FM_COGNEE_MAX_ATTEMPTS:-3}
  case "$max_attempts" in ''|*[!0-9]*) max_attempts=3 ;; esac
  [ "$max_attempts" -ge 1 ] || max_attempts=1
  attempt=1
  http_status=0
  retryable=false
  curl_rc=0
  timeout_seconds=$(fm_cognee_timeout_seconds)
  request_body_bytes=$(wc -c < "$PAYLOAD" | tr -d ' ')
  response_body_bytes=0
  attempt_latency=0
  request_id=
  while [ "$attempt" -le "$max_attempts" ]; do
    : > "$BODY"
    : > "$CURL_ERR"
    request_id=$(fm_cognee_new_id cognee-req)
    attempt_start_ms=$(fm_cognee_telemetry_now_ms)
    set +e
    http_status=$(curl -sS -o "$BODY" -w '%{http_code}' \
      --connect-timeout "$timeout_seconds" \
      --max-time "$timeout_seconds" \
      -X POST "$endpoint" \
      -H "X-Api-Key: $COGNEE_API_KEY" \
      -H "Content-Type: application/json" \
      --data-binary "@$PAYLOAD" 2> "$CURL_ERR")
    curl_rc=$?
    set -e
    retryable=false
    if [ "$curl_rc" -ne 0 ]; then
      http_status=0
      retryable=true
    else
      case "$http_status" in
        429|500|502|503|504) retryable=true ;;
      esac
    fi
    attempt_latency=$(fm_cognee_telemetry_latency_ms "$attempt_start_ms")
    response_body_bytes=$(wc -c < "$BODY" | tr -d ' ')
    if ! "$retryable" || [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi
    live_telemetry_log blocked http_or_transport_failure "$http_status" true "$((attempt - 1))" \
      "$attempt_latency" 0 pending "$request_id" "$attempt" false "$request_body_bytes" "$response_body_bytes"
    attempt=$((attempt + 1))
  done

  retry_count=$((attempt - 1))
  if [ "$curl_rc" -ne 0 ] || [ "$http_status" -lt 200 ] 2>/dev/null || [ "$http_status" -ge 300 ] 2>/dev/null; then
    live_telemetry_log blocked http_or_transport_failure "$http_status" "$retryable" "$retry_count" \
      "$attempt_latency" 0 http_or_transport_failure "$request_id" "$attempt" true "$request_body_bytes" "$response_body_bytes"
    echo "label=blocked_missing_proof reason=http_or_transport_failure http_status=$http_status retry_count=$retry_count retryable=$retryable external_action_authorized=false" >&2
    exit 2
  fi

  extract_answer_text "$BODY" "$ANSWER" "$COUNT_FILE"
  parsed_source_count=$(cat "$COUNT_FILE")
  set +e
  case "$MANIFEST" in
    *.jsonl)
      "$SCRIPT_DIR/fm-cognee-verify-source.sh" --manifest "$MANIFEST" --answer "$ANSWER" > "$VERIFY_OUT"
      ;;
    *)
      "$SCRIPT_DIR/fm-cognee-manifest-check.sh" --manifest "$MANIFEST" --answer-file "$ANSWER" > "$VERIFY_OUT"
      ;;
  esac
  verify_rc=$?
  set -e
  cat "$VERIFY_OUT"
  source_outcome=$(verification_outcome "$VERIFY_OUT")
  if [ "$verify_rc" -eq 0 ]; then
    tel_status=verified
    tel_error=none
  else
    tel_status=blocked
    tel_error=$source_outcome
  fi
  live_telemetry_log "$tel_status" "$tel_error" "$http_status" false "$retry_count" "$attempt_latency" \
    "$parsed_source_count" "$source_outcome" "$request_id" "$attempt" true "$request_body_bytes" "$response_body_bytes"
  echo "mode=live"
  echo "dataset_alias=$(safe_label "$(dataset_alias)")"
  echo "endpoint=/api/v1/search"
  echo "http_status=$http_status"
  echo "retry_count=$retry_count"
  echo "retryable=false"
  echo "parsed_source_count=$parsed_source_count"
  echo "cognee_answer_status=hint_only"
  echo "source_verification_outcome=$source_outcome"
  echo "external_action_authorized=false"
  exit "$verify_rc"
fi

[ -n "$QUERY" ] || die "--query is required in dry-run mode"

query_hash=$(printf '%s' "$QUERY" | sha256sum | awk '{print $1}')
query_bytes=$(printf '%s' "$QUERY" | wc -c | tr -d ' ')

echo "mode=dry-run"
echo "query_sha256=$query_hash"
echo "query_bytes=$query_bytes"
echo "cognee_answer_status=hint_only"
echo "external_action_authorized=false"

if [ -z "$MANIFEST" ] && [ -z "$ANSWER_FILE" ]; then
  fm_cognee_telemetry_log \
    cognee_lookup dry-run hint_only none 0 \
    "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" \
    "" "" no_manifest_or_answer_fixture 0 known_zero_local "" not_called
  echo "label=hint_only reason=no_manifest_or_answer_fixture external_action_authorized=false"
  exit 0
fi

[ -n "$MANIFEST" ] || die "--manifest is required when --answer-file is used"
[ -n "$ANSWER_FILE" ] || die "--answer-file is required when --manifest is used"

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-cognee-lookup.XXXXXX")
# shellcheck disable=SC2317 # Invoked by trap.
cleanup_lookup() { rm -f "$TMP_OUT"; }
trap cleanup_lookup EXIT

set +e
"$SCRIPT_DIR/fm-cognee-manifest-check.sh" --manifest "$MANIFEST" --answer-file "$ANSWER_FILE" > "$TMP_OUT"
rc=$?
set -e
cat "$TMP_OUT"

source_outcome=$(
  awk '
    {
      label = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^reason=/) { sub(/^reason=/, "", $i); print $i; exit }
        if ($i ~ /^label=/) { label = $i; sub(/^label=/, "", label) }
      }
      if (label != "") { print label; exit }
    }
  ' "$TMP_OUT"
)
[ -n "$source_outcome" ] || source_outcome=manifest_check_exit_$rc
if [ "$rc" -eq 0 ]; then
  tel_status=verified
  tel_error=none
else
  tel_status=blocked
  tel_error=$source_outcome
fi
fm_cognee_telemetry_log \
  cognee_lookup dry-run "$tel_status" "$tel_error" 0 \
  "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" \
  "" "" "$source_outcome" 0 known_zero_local "" not_called
exit "$rc"
