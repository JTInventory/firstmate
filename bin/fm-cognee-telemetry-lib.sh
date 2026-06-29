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


now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
event = {
    "schema_version": "cognee_telemetry.v1",
    "ts_utc": now,
    "operation_name": label("FM_COGNEE_T_OPERATION"),
    "mode": label("FM_COGNEE_T_MODE"),
    "status": label("FM_COGNEE_T_STATUS"),
    "error_class": label("FM_COGNEE_T_ERROR_CLASS", "none"),
    "retry_count": integer("FM_COGNEE_T_RETRY_COUNT"),
    "latency_ms": integer("FM_COGNEE_T_LATENCY_MS"),
    "imported_bytes": number_or_none("FM_COGNEE_T_IMPORTED_BYTES"),
    "imported_tokens": number_or_none("FM_COGNEE_T_IMPORTED_TOKENS"),
    "source_verification_outcome": label("FM_COGNEE_T_SOURCE_OUTCOME", "not_attempted"),
    "estimated_cost_usd": number_or_none("FM_COGNEE_T_ESTIMATED_COST_USD"),
    "estimated_cost_status": label("FM_COGNEE_T_ESTIMATED_COST_STATUS"),
    "vendor_estimated_cost_usd": number_or_none("FM_COGNEE_T_VENDOR_ESTIMATED_COST_USD"),
    "vendor_cost_status": label("FM_COGNEE_T_VENDOR_COST_STATUS"),
    "currency": "USD",
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

fm_cognee_telemetry_latency_ms() {
  local start_ms=${1:-0} now_ms
  now_ms=$(fm_cognee_telemetry_now_ms 2>/dev/null || printf '0\n')
  if [ "$now_ms" -gt "$start_ms" ] 2>/dev/null; then
    printf '%s\n' "$((now_ms - start_ms))"
  else
    printf '0\n'
  fi
}
