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

Live mode uses only already-exported environment variables:
  COGNEE_BASE_URL
  COGNEE_API_KEY
  COGNEE_DATASET_ID or FM_COGNEE_DATASET_ALIAS
  FM_COGNEE_MANIFEST or --manifest

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

has_live_dataset_selector() {
  if [ -n "${COGNEE_DATASET_ID:-}" ] && is_uuid "$COGNEE_DATASET_ID"; then
    return 0
  fi
  [ -n "${FM_COGNEE_DATASET_ALIAS:-}" ]
}

live_telemetry_log() {
  local status=$1 error_class=$2 http_status=$3 retryable=$4 retry_count=$5 latency_ms=$6 parsed_source_count=$7 verification_outcome=$8
  local telemetry_file dataset_alias_value dataset_id_hash_value
  telemetry_file=${FM_COGNEE_TELEMETRY_FILE:-$(fm_cognee_telemetry_default_path)}
  dataset_alias_value=$(dataset_alias)
  dataset_id_hash_value=$(dataset_id_hash)
  (
    set +e
    mkdir -p "$(dirname "$telemetry_file")" >/dev/null 2>&1 || exit 0
    FM_COGNEE_LIVE_TELEMETRY_FILE=$telemetry_file \
    FM_COGNEE_LIVE_STATUS=$(safe_label "$status") \
    FM_COGNEE_LIVE_ERROR=$(safe_label "$error_class") \
    FM_COGNEE_LIVE_HTTP_STATUS=$http_status \
    FM_COGNEE_LIVE_RETRYABLE=$retryable \
    FM_COGNEE_LIVE_RETRY_COUNT=$retry_count \
    FM_COGNEE_LIVE_LATENCY_MS=$latency_ms \
    FM_COGNEE_LIVE_PARSED_SOURCE_COUNT=$parsed_source_count \
    FM_COGNEE_LIVE_VERIFICATION=$(safe_label "$verification_outcome") \
    FM_COGNEE_LIVE_DATASET_ALIAS=$(safe_label "$dataset_alias_value") \
    FM_COGNEE_LIVE_DATASET_ID_HASH=$dataset_id_hash_value \
    FM_COGNEE_LIVE_SEARCH_TYPE=$(safe_label "${FM_COGNEE_SEARCH_TYPE:-RAG_COMPLETION}") \
    FM_COGNEE_LIVE_TOP_K=${FM_COGNEE_TOP_K:-8} \
    python3 - <<'PY' >/dev/null 2>&1
import datetime as dt
import json
import os
from pathlib import Path


def integer(name, default=0):
    try:
        return max(int(os.environ.get(name, "") or default), 0)
    except ValueError:
        return default


def maybe_int(name):
    value = os.environ.get(name, "")
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def boolean(name):
    return (os.environ.get(name, "") or "").lower() == "true"


now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
event = {
    "schema_version": "cognee_live_lookup.v1",
    "ts_utc": now,
    "event_type": "api_attempt",
    "operation_name": "cognee_lookup",
    "mode": "live",
    "dataset": {
        "dataset_alias": os.environ.get("FM_COGNEE_LIVE_DATASET_ALIAS") or "unknown",
        "dataset_id_hash": os.environ.get("FM_COGNEE_LIVE_DATASET_ID_HASH") or None,
    },
    "operation": {
        "operation_name": "search",
        "endpoint_template": "/api/v1/search",
        "http_method": "POST",
        "mutates_remote": False,
        "search_type": os.environ.get("FM_COGNEE_LIVE_SEARCH_TYPE") or "RAG_COMPLETION",
        "topK": integer("FM_COGNEE_LIVE_TOP_K", 8),
    },
    "status": {
        "status": os.environ.get("FM_COGNEE_LIVE_STATUS") or "unknown",
        "error_class": os.environ.get("FM_COGNEE_LIVE_ERROR") or "none",
        "http_status": maybe_int("FM_COGNEE_LIVE_HTTP_STATUS"),
        "retryable": boolean("FM_COGNEE_LIVE_RETRYABLE"),
    },
    "attempt": {
        "retry_count": integer("FM_COGNEE_LIVE_RETRY_COUNT", 0),
    },
    "latency": {
        "duration_ms": integer("FM_COGNEE_LIVE_LATENCY_MS", 0),
    },
    "results": {
        "parsed_source_count": integer("FM_COGNEE_LIVE_PARSED_SOURCE_COUNT", 0),
        "answer_body_logged": False,
    },
    "source_verification_outcome": os.environ.get("FM_COGNEE_LIVE_VERIFICATION") or "not_attempted",
    "external_action_authorized": False,
}
try:
    path = Path(os.environ["FM_COGNEE_LIVE_TELEMETRY_FILE"])
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")
except Exception:
    pass
PY
  ) || true
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
  while [ "$attempt" -le "$max_attempts" ]; do
    : > "$BODY"
    : > "$CURL_ERR"
    set +e
    http_status=$(curl -sS -o "$BODY" -w '%{http_code}' \
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
    if ! "$retryable" || [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi
    attempt=$((attempt + 1))
  done

  retry_count=$((attempt - 1))
  latency=$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")
  if [ "$curl_rc" -ne 0 ] || [ "$http_status" -lt 200 ] 2>/dev/null || [ "$http_status" -ge 300 ] 2>/dev/null; then
    live_telemetry_log blocked http_or_transport_failure "$http_status" "$retryable" "$retry_count" "$latency" 0 http_or_transport_failure
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
  live_telemetry_log "$tel_status" "$tel_error" "$http_status" false "$retry_count" "$latency" "$parsed_source_count" "$source_outcome"
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
