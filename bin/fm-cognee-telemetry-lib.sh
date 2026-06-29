#!/usr/bin/env bash
# Secret-safe local JSONL telemetry helpers for Cognee wrapper operations.
#
# Callers pass only labels, counters, timings, and cost classifications. This
# helper never receives prompt text, answer bodies, source bodies, auth headers,
# API keys, cookies, signed URLs, bearer tokens, or secret values.

fm_cognee_telemetry_now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

fm_cognee_telemetry_default_path() {
  local root
  root=${FM_HOME:-${FM_ROOT_OVERRIDE:-}}
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  printf '%s/data/cognee/telemetry.jsonl\n' "$root"
}

fm_cognee_telemetry_log() {
  local operation_name=${1:-unknown}
  local mode=${2:-unknown}
  local status=${3:-unknown}
  local error_class=${4:-none}
  local retry_count=${5:-0}
  local latency_ms=${6:-0}
  local imported_bytes=${7:-}
  local imported_tokens=${8:-}
  local source_verification_outcome=${9:-not_attempted}
  local estimated_cost_usd=${10:-}
  local estimated_cost_status=${11:-unknown_vendor_cost}
  local vendor_estimated_cost_usd=${12:-}
  local vendor_cost_status=${13:-unknown_vendor_cost}
  local telemetry_file

  telemetry_file=${FM_COGNEE_TELEMETRY_FILE:-$(fm_cognee_telemetry_default_path)}
  (
    set +e
    mkdir -p "$(dirname "$telemetry_file")" >/dev/null 2>&1 || exit 0
    FM_COGNEE_T_OPERATION=$operation_name \
    FM_COGNEE_T_MODE=$mode \
    FM_COGNEE_T_STATUS=$status \
    FM_COGNEE_T_ERROR_CLASS=$error_class \
    FM_COGNEE_T_RETRY_COUNT=$retry_count \
    FM_COGNEE_T_LATENCY_MS=$latency_ms \
    FM_COGNEE_T_IMPORTED_BYTES=$imported_bytes \
    FM_COGNEE_T_IMPORTED_TOKENS=$imported_tokens \
    FM_COGNEE_T_SOURCE_OUTCOME=$source_verification_outcome \
    FM_COGNEE_T_ESTIMATED_COST_USD=$estimated_cost_usd \
    FM_COGNEE_T_ESTIMATED_COST_STATUS=$estimated_cost_status \
    FM_COGNEE_T_VENDOR_ESTIMATED_COST_USD=$vendor_estimated_cost_usd \
    FM_COGNEE_T_VENDOR_COST_STATUS=$vendor_cost_status \
    FM_COGNEE_T_FILE=$telemetry_file \
    python3 - <<'PY' >/dev/null 2>&1
import datetime as dt
import json
import os
import re
from pathlib import Path


LABEL_RE = re.compile(r"[^A-Za-z0-9_.:-]+")


def label(name, default="unknown"):
    value = os.environ.get(name, "") or default
    value = LABEL_RE.sub("_", value.strip())[:120]
    return value or default


def integer(name, default=0):
    try:
        value = int(os.environ.get(name, "") or default)
    except ValueError:
        value = default
    return max(value, 0)


def number_or_none(name):
    value = os.environ.get(name, "")
    if value == "":
        return None
    try:
        number = float(value)
    except ValueError:
        return None
    if number.is_integer():
        return int(number)
    return number


def cost_confidence(status):
    if status in {"known_zero_local", "known_zero", "known"}:
        return "known"
    if status in {"not_called"}:
        return "not_called"
    return "unknown"


now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
operation_name = label("FM_COGNEE_T_OPERATION")
mode = label("FM_COGNEE_T_MODE")
status = label("FM_COGNEE_T_STATUS")
error_class = label("FM_COGNEE_T_ERROR_CLASS", "none")
retry_count = integer("FM_COGNEE_T_RETRY_COUNT")
latency_ms = integer("FM_COGNEE_T_LATENCY_MS")
source_outcome = label("FM_COGNEE_T_SOURCE_OUTCOME", "not_attempted")
estimated_cost_status = label("FM_COGNEE_T_ESTIMATED_COST_STATUS")
estimated_cost_usd = number_or_none("FM_COGNEE_T_ESTIMATED_COST_USD")
vendor_cost_status = label("FM_COGNEE_T_VENDOR_COST_STATUS")
event = {
    "schema_version": "cognee_telemetry.v2",
    "ts_utc": now,
    "event_type": "operation",
    "operation_name": operation_name,
    "mode": mode,
    "status": status,
    "error_class": error_class,
    "retry_count": retry_count,
    "latency_ms": latency_ms,
    "imported_bytes": number_or_none("FM_COGNEE_T_IMPORTED_BYTES"),
    "imported_tokens": number_or_none("FM_COGNEE_T_IMPORTED_TOKENS"),
    "source_verification_outcome": source_outcome,
    "estimated_cost_usd": estimated_cost_usd,
    "estimated_cost_status": estimated_cost_status,
    "vendor_estimated_cost_usd": number_or_none("FM_COGNEE_T_VENDOR_ESTIMATED_COST_USD"),
    "vendor_cost_status": vendor_cost_status,
    "currency": "USD",
    "operation": {
        "operation_name": operation_name,
        "mode": mode,
        "mutates_remote": False,
    },
    "status_detail": {
        "status": status,
        "error_class": error_class,
    },
    "attempt": {
        "retry_count": retry_count,
        "is_retry": retry_count > 0,
    },
    "latency": {
        "duration_ms": latency_ms,
        "timeout_ms": None,
    },
    "source_verification": {
        "verification_status": source_outcome,
        "verification_required": source_outcome not in {"not_attempted", "not_required"},
    },
    "cost_estimate": {
        "estimated_cost_usd": estimated_cost_usd,
        "currency": "USD",
        "confidence": cost_confidence(estimated_cost_status),
        "estimate_source": estimated_cost_status,
    },
    "vendor_usage_present": vendor_cost_status not in {"unknown_vendor_cost", "not_called"},
    "answer_body_logged": False,
    "answer_body_redacted": True,
    "response_content_redacted": True,
    "external_action_authorized": False,
}
try:
    path = Path(os.environ["FM_COGNEE_T_FILE"])
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")
except Exception:
    pass
PY
  ) || true
  return 0
}

fm_cognee_telemetry_log_api_attempt() {
  local operation_name=${1:-unknown}
  local http_method=${2:-unknown}
  local endpoint_template=${3:-unknown}
  local mutates_remote=${4:-false}
  local status=${5:-unknown}
  local error_class=${6:-none}
  local http_status=${7:-}
  local retryable=${8:-false}
  local attempt_number=${9:-1}
  local max_attempts=${10:-1}
  local is_retry=${11:-false}
  local retry_reason=${12:-none}
  local duration_ms=${13:-0}
  local timeout_ms=${14:-}
  local verification_status=${15:-not_attempted}
  local verification_required=${16:-false}
  local result_count=${17:-0}
  local estimated_cost_usd=${18:-}
  local cost_confidence=${19:-unknown}
  local estimate_source=${20:-vendor_metadata_missing}
  local vendor_usage_present=${21:-false}
  local telemetry_file

  telemetry_file=${FM_COGNEE_TELEMETRY_FILE:-$(fm_cognee_telemetry_default_path)}
  (
    set +e
    mkdir -p "$(dirname "$telemetry_file")" >/dev/null 2>&1 || exit 0
    FM_COGNEE_API_T_OPERATION=$operation_name \
    FM_COGNEE_API_T_METHOD=$http_method \
    FM_COGNEE_API_T_ENDPOINT=$endpoint_template \
    FM_COGNEE_API_T_MUTATES=$mutates_remote \
    FM_COGNEE_API_T_STATUS=$status \
    FM_COGNEE_API_T_ERROR=$error_class \
    FM_COGNEE_API_T_HTTP_STATUS=$http_status \
    FM_COGNEE_API_T_RETRYABLE=$retryable \
    FM_COGNEE_API_T_ATTEMPT=$attempt_number \
    FM_COGNEE_API_T_MAX_ATTEMPTS=$max_attempts \
    FM_COGNEE_API_T_IS_RETRY=$is_retry \
    FM_COGNEE_API_T_RETRY_REASON=$retry_reason \
    FM_COGNEE_API_T_DURATION_MS=$duration_ms \
    FM_COGNEE_API_T_TIMEOUT_MS=$timeout_ms \
    FM_COGNEE_API_T_VERIFICATION=$verification_status \
    FM_COGNEE_API_T_VERIFICATION_REQUIRED=$verification_required \
    FM_COGNEE_API_T_RESULT_COUNT=$result_count \
    FM_COGNEE_API_T_COST_USD=$estimated_cost_usd \
    FM_COGNEE_API_T_COST_CONFIDENCE=$cost_confidence \
    FM_COGNEE_API_T_ESTIMATE_SOURCE=$estimate_source \
    FM_COGNEE_API_T_VENDOR_USAGE=$vendor_usage_present \
    FM_COGNEE_API_T_FILE=$telemetry_file \
    python3 - <<'PY' >/dev/null 2>&1
import datetime as dt
import json
import os
import re
from pathlib import Path


LABEL_RE = re.compile(r"[^A-Za-z0-9_.:/-]+")


def label(name, default="unknown"):
    value = os.environ.get(name, "") or default
    value = LABEL_RE.sub("_", value.strip())[:160]
    return value or default


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


def number_or_none(name):
    value = os.environ.get(name, "")
    if value == "":
        return None
    try:
        number = float(value)
    except ValueError:
        return None
    return int(number) if number.is_integer() else number


def boolean(name):
    return (os.environ.get(name, "") or "").lower() == "true"


now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
status = label("FM_COGNEE_API_T_STATUS")
event = {
    "schema_version": "cognee_telemetry.v2",
    "ts_utc": now,
    "event_type": "api_attempt",
    "operation": {
        "operation_name": label("FM_COGNEE_API_T_OPERATION"),
        "http_method": label("FM_COGNEE_API_T_METHOD"),
        "endpoint_template": label("FM_COGNEE_API_T_ENDPOINT"),
        "mutates_remote": boolean("FM_COGNEE_API_T_MUTATES"),
    },
    "status": {
        "status": status,
        "success": status in {"success", "verified"},
        "error_class": label("FM_COGNEE_API_T_ERROR", "none"),
        "http_status": maybe_int("FM_COGNEE_API_T_HTTP_STATUS"),
        "retryable": boolean("FM_COGNEE_API_T_RETRYABLE"),
    },
    "attempt": {
        "attempt_number": integer("FM_COGNEE_API_T_ATTEMPT", 1),
        "max_attempts": integer("FM_COGNEE_API_T_MAX_ATTEMPTS", 1),
        "is_retry": boolean("FM_COGNEE_API_T_IS_RETRY"),
        "retry_reason": label("FM_COGNEE_API_T_RETRY_REASON", "none"),
    },
    "latency": {
        "duration_ms": integer("FM_COGNEE_API_T_DURATION_MS", 0),
        "timeout_ms": maybe_int("FM_COGNEE_API_T_TIMEOUT_MS"),
    },
    "source_verification": {
        "verification_status": label("FM_COGNEE_API_T_VERIFICATION", "not_attempted"),
        "verification_required": boolean("FM_COGNEE_API_T_VERIFICATION_REQUIRED"),
    },
    "results": {
        "result_count": integer("FM_COGNEE_API_T_RESULT_COUNT", 0),
    },
    "cost_estimate": {
        "estimated_cost_usd": number_or_none("FM_COGNEE_API_T_COST_USD"),
        "currency": "USD",
        "confidence": label("FM_COGNEE_API_T_COST_CONFIDENCE", "unknown"),
        "estimate_source": label("FM_COGNEE_API_T_ESTIMATE_SOURCE", "vendor_metadata_missing"),
    },
    "vendor_usage_present": boolean("FM_COGNEE_API_T_VENDOR_USAGE"),
    "answer_body_logged": False,
    "answer_body_redacted": True,
    "response_content_redacted": True,
    "external_action_authorized": False,
}
try:
    path = Path(os.environ["FM_COGNEE_API_T_FILE"])
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")
except Exception:
    pass
PY
  ) || true
  return 0
}

fm_cognee_telemetry_latency_ms() {
  local start_ms=${1:-0} now_ms
  now_ms=$(fm_cognee_telemetry_now_ms 2>/dev/null || printf '0\n')
  if [ "$now_ms" -gt "$start_ms" ] 2>/dev/null; then
    printf '%s\n' "$((now_ms - start_ms))"
  else
    printf '0\n'
  fi
}
