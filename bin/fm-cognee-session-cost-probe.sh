#!/usr/bin/env bash
# Disabled metadata-only planner for Cognee session/cost probes.
#
# This helper never calls Cognee. It reads local telemetry, validates an explicit
# allowlist of GET-only endpoint templates, and writes redacted local JSONL probe
# plan events for a separately approved live probe lane.
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: fm-cognee-session-cost-probe.sh --telemetry <telemetry.jsonl> --window-start-utc <ts> --window-end-utc <ts> --output-jsonl <path> [options]

Required:
  --telemetry <path>          local Cognee telemetry JSONL to inspect
  --window-start-utc <ts>     UTC window start, e.g. 2026-06-30T00:00:00Z
  --window-end-utc <ts>       UTC window end, e.g. 2026-06-30T01:00:00Z
  --output-jsonl <path>       metadata-only local JSONL output

Options:
  --endpoint "GET <template>" endpoint template to prepare; may repeat
  --max-sessions <n>          maximum sessions a future approved probe may read
  --env-file <path>           load allowlisted Cognee env names with the shared safe loader

Allowed endpoint templates:
  GET /health
  GET /openapi.json
  GET /api/v1/sessions
  GET /api/v1/sessions/{session_id}
  GET /api/v1/sessions/cost-by-model

No network calls are made by this helper.
USAGE
}

die() {
  local reason=$1
  shift || true
  printf 'label=blocked_missing_proof reason=%s external_action_authorized=false' "$reason" >&2
  if [ "$#" -gt 0 ]; then
    printf ' %s' "$*" >&2
  fi
  printf '\n' >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-cognee-telemetry-lib.sh
. "$SCRIPT_DIR/fm-cognee-telemetry-lib.sh"

TELEMETRY=
WINDOW_START_UTC=
WINDOW_END_UTC=
OUTPUT_JSONL=
MAX_SESSIONS=100
ENV_FILE=
ENDPOINTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --telemetry)
      TELEMETRY=${2:-}
      [ -n "$TELEMETRY" ] || die missing_required_args
      shift 2
      ;;
    --window-start-utc)
      WINDOW_START_UTC=${2:-}
      [ -n "$WINDOW_START_UTC" ] || die missing_required_args
      shift 2
      ;;
    --window-end-utc)
      WINDOW_END_UTC=${2:-}
      [ -n "$WINDOW_END_UTC" ] || die missing_required_args
      shift 2
      ;;
    --output-jsonl|--output)
      OUTPUT_JSONL=${2:-}
      [ -n "$OUTPUT_JSONL" ] || die missing_required_args
      shift 2
      ;;
    --endpoint)
      [ -n "${2:-}" ] || die missing_required_args
      ENDPOINTS+=("$2")
      shift 2
      ;;
    --max-sessions)
      MAX_SESSIONS=${2:-}
      [ -n "$MAX_SESSIONS" ] || die missing_required_args
      shift 2
      ;;
    --env-file)
      ENV_FILE=${2:-}
      [ -n "$ENV_FILE" ] || die missing_required_args
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      die unknown_argument
      ;;
    *)
      if [ -z "$OUTPUT_JSONL" ]; then
        OUTPUT_JSONL=$1
        shift
      else
        die unknown_argument
      fi
      ;;
  esac
done

[ -n "$TELEMETRY" ] || die missing_required_args
[ -n "$WINDOW_START_UTC" ] || die missing_required_args
[ -n "$WINDOW_END_UTC" ] || die missing_required_args
[ -n "$OUTPUT_JSONL" ] || die missing_required_args
if [ ! -r "$TELEMETRY" ] || [ -d "$TELEMETRY" ]; then
  die telemetry_unreadable
fi

case "$MAX_SESSIONS" in
  ''|*[!0-9]*) die invalid_max_sessions ;;
esac
[ "$MAX_SESSIONS" -ge 1 ] || die invalid_max_sessions

if [ -n "$ENV_FILE" ]; then
  FM_COGNEE_ENV_FILE=$ENV_FILE
  export FM_COGNEE_ENV_FILE
  if ! fm_cognee_load_env_file; then
    die "${FM_COGNEE_ENV_FILE_LOAD_ERROR:-env_file_malformed}"
  fi
  ENV_FILE_LOADED=true
else
  ENV_FILE_LOADED=false
fi

if [ "${#ENDPOINTS[@]}" -eq 0 ]; then
  ENDPOINTS=(
    "GET /health"
    "GET /openapi.json"
    "GET /api/v1/sessions"
    "GET /api/v1/sessions/{session_id}"
    "GET /api/v1/sessions/cost-by-model"
  )
fi

validate_endpoint() {
  local spec=$1 method path
  method=${spec%%[[:space:]]*}
  path=${spec#*[[:space:]]}
  if [ "$method" = "$spec" ] || [ -z "$method" ] || [ -z "$path" ]; then
    return 1
  fi
  [ "$method" = GET ] || return 1
  case "$path" in
    /health|/openapi.json|/api/v1/sessions|"/api/v1/sessions/{session_id}"|/api/v1/sessions/cost-by-model)
      ;;
    *)
      return 1
      ;;
  esac
  case "$path" in
    */search*|*/add_text*|*/cognify*|*/delete*|*/upload*|*/import*|*/billing*|*/datasets*)
      return 1
      ;;
  esac
  return 0
}

for endpoint in "${ENDPOINTS[@]}"; do
  validate_endpoint "$endpoint" || die blocked_endpoint_template
done

PROBE_ID=$(fm_cognee_new_id cognee-session-cost-probe)
export TELEMETRY WINDOW_START_UTC WINDOW_END_UTC OUTPUT_JSONL MAX_SESSIONS PROBE_ID ENV_FILE_LOADED

FM_COGNEE_PROBE_ENDPOINTS=$(printf '%s\n' "${ENDPOINTS[@]}")
export FM_COGNEE_PROBE_ENDPOINTS

set +e
python3 - <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path


ALLOWED_SECRET_KEYS = {
    "answer",
    "answer_body",
    "prompt",
    "question",
    "query",
    "source",
    "source_body",
    "content",
    "text",
    "api_key",
    "authorization",
    "auth",
    "headers",
    "cookie",
    "cookies",
    "signed_url",
    "url",
    "base_url",
}


def parse_ts(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def now_utc():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_label(value):
    if value is None or value == "":
        return None
    text = str(value)
    if text.startswith("sha256:") and len(text) == 71:
        return text
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def endpoint_parts(spec):
    method, path = spec.split(None, 1)
    return method, path


def walk_for_session_hashes(value, parent_key=""):
    hashes = []
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            lowered = key_text.lower()
            if lowered in ALLOWED_SECRET_KEYS:
                continue
            if lowered == "session_id_hash":
                hashed = sha256_label(child)
                if hashed:
                    hashes.append(hashed)
                continue
            if lowered == "session_id":
                hashed = sha256_label(child)
                if hashed:
                    hashes.append(hashed)
                continue
            hashes.extend(walk_for_session_hashes(child, key_text))
    elif isinstance(value, list):
        for item in value:
            hashes.extend(walk_for_session_hashes(item, parent_key))
    return hashes


telemetry_path = Path(os.environ["TELEMETRY"])
output_path = Path(os.environ["OUTPUT_JSONL"])
window_start_raw = os.environ["WINDOW_START_UTC"]
window_end_raw = os.environ["WINDOW_END_UTC"]
window_start = parse_ts(window_start_raw)
window_end = parse_ts(window_end_raw)
if window_start is None or window_end is None or window_end < window_start:
    raise SystemExit("invalid_window")

events = []
if telemetry_path.exists():
    with telemetry_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(event.get("ts_utc") or event.get("timestamp") or event.get("created_at"))
            if ts is None or window_start <= ts <= window_end:
                events.append(event)

run_ids = []
request_ids = []
logical_ids = []
session_hashes = []
for event in events:
    for target, key in ((run_ids, "run_id"), (request_ids, "request_id"), (logical_ids, "logical_search_id")):
        value = event.get(key)
        if isinstance(value, str) and value and value not in target:
            target.append(value)
    correlation = event.get("correlation")
    if isinstance(correlation, dict):
        for target, key in ((run_ids, "wrapper_run_id"), (request_ids, "wrapper_request_id"), (logical_ids, "logical_search_id")):
            value = correlation.get(key)
            if isinstance(value, str) and value and value not in target:
                target.append(value)
    for hashed in walk_for_session_hashes(event):
        if hashed not in session_hashes:
            session_hashes.append(hashed)

output_path.parent.mkdir(parents=True, exist_ok=True)
probe_id = os.environ["PROBE_ID"]
max_sessions = int(os.environ["MAX_SESSIONS"])
endpoint_specs = [line for line in os.environ["FM_COGNEE_PROBE_ENDPOINTS"].splitlines() if line.strip()]
ts = now_utc()

with output_path.open("w", encoding="utf-8") as handle:
    for idx, spec in enumerate(endpoint_specs, start=1):
        method, endpoint_template = endpoint_parts(spec)
        session_hash = session_hashes[0] if session_hashes else None
        event = {
            "schema_version": "cognee_telemetry.v2",
            "event_type": "session_cost_probe",
            "ts_utc": ts,
            "probe_id": probe_id,
            "task_id": "cognee-session-cost-probe-helper-0630",
            "run_id": run_ids[0] if run_ids else None,
            "request_id": f"{probe_id}-req-{idx}",
            "logical_search_id": logical_ids[0] if logical_ids else None,
            "service": {
                "service_alias": "cognee-cloud",
                "api_version_observed": None,
            },
            "probe": {
                "window_start_utc": window_start_raw,
                "window_end_utc": window_end_raw,
                "endpoint_template": endpoint_template,
                "http_method": method,
                "mutates_remote": False,
                "max_sessions_read": max_sessions,
                "prepared_only": True,
                "live_network_used": False,
            },
            "status": {
                "http_status": None,
                "success": False,
                "error_class": "not_called_disabled_helper",
                "retryable": False,
            },
            "latency": {
                "duration_ms": 0,
            },
            "sizes": {
                "response_body_bytes": 0,
            },
            "privacy": {
                "session_id_hashed": True,
                "answer_body_logged": False,
                "prompt_logged": False,
                "source_body_logged": False,
                "auth_headers_logged": False,
                "full_base_url_logged": False,
                "response_content_redacted": True,
            },
            "vendor_usage": {
                "vendor_usage_present": False,
                "session_id_hash": session_hash,
                "vendor_request_id_hash": None,
                "input_tokens": None,
                "output_tokens": None,
                "total_tokens": None,
                "cost_usd": None,
                "currency": None,
                "model": None,
                "usage_window_start_utc": window_start_raw,
                "usage_window_end_utc": window_end_raw,
                "raw_vendor_field_names": [],
            },
            "correlation": {
                "wrapper_run_id": run_ids[0] if run_ids else None,
                "wrapper_request_id": request_ids[0] if request_ids else None,
                "logical_search_id": logical_ids[0] if logical_ids else None,
                "method": "unmatched",
                "confidence": "none",
                "matched_session_count": len(session_hashes),
                "matched_api_attempt_count": len(events),
                "time_delta_ms": None,
                "ambiguous_match": len(session_hashes) != 1 or len(events) != 1,
                "unmatched_reason": "disabled_metadata_only_helper",
            },
            "rollup": {
                "account_cost_by_model_usd": None,
                "account_total_tokens_by_model": None,
                "session_detail_total_cost_usd": None,
                "reconciliation_delta_usd": None,
                "reconciliation_delta_percent": None,
            },
            "decision": {
                "cost_correlation_status": "unmatched",
            },
            "external_action_authorized": False,
        }
        handle.write(json.dumps(event, sort_keys=True) + "\n")
PY
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  rm -f "$OUTPUT_JSONL"
  die invalid_window
fi

printf 'status=prepared endpoint_count=%s telemetry=%s output_jsonl=%s env_file_loaded=%s external_action_authorized=false\n' \
  "${#ENDPOINTS[@]}" "$(fm_cognee_safe_label "$(basename "$TELEMETRY")")" \
  "$(fm_cognee_safe_label "$(basename "$OUTPUT_JSONL")")" "$ENV_FILE_LOADED"
