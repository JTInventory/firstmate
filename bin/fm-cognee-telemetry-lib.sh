#!/usr/bin/env bash
# Secret-safe local JSONL telemetry helpers for Cognee wrapper operations.
#
# Telemetry callers pass only labels, counters, timings, and cost classifications.
# This helper's safe env-file loader may read allowlisted Cognee connection names,
# but telemetry events never receive or write prompt text, answer bodies, source
# bodies, auth headers, API keys, cookies, signed URLs, bearer tokens, base URLs,
# or secret values.

fm_cognee_env_trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

fm_cognee_env_is_allowlisted() {
  case "$1" in
    COGNEE_BASE_URL|COGNEE_API_KEY|COGNEE_DATASET_ID|FM_COGNEE_DATASET_ALIAS|FM_COGNEE_MANIFEST)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

fm_cognee_load_env_file() {
  local env_file=${FM_COGNEE_ENV_FILE:-}
  local line line_no key value first last

  FM_COGNEE_ENV_FILE_LOAD_ERROR=
  FM_COGNEE_ENV_FILE_LOAD_LINE=
  FM_COGNEE_ENV_FILE_LOAD_KEY=

  [ -n "$env_file" ] || return 0
  if [ ! -r "$env_file" ] || [ -d "$env_file" ]; then
    FM_COGNEE_ENV_FILE_LOAD_ERROR=env_file_unreadable
    return 1
  fi

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line=${line%$'\r'}
    line=$(fm_cognee_env_trim "$line")
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    case "$line" in
      export[[:space:]]*)
        line=$(fm_cognee_env_trim "${line#export}")
        ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        FM_COGNEE_ENV_FILE_LOAD_ERROR=env_file_malformed
        FM_COGNEE_ENV_FILE_LOAD_LINE=$line_no
        return 1
        ;;
    esac

    key=$(fm_cognee_env_trim "${line%%=*}")
    value=${line#*=}
    value=$(fm_cognee_env_trim "$value")
    case "$key" in
      ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
        # shellcheck disable=SC2034 # Read by callers after fm_cognee_load_env_file returns.
        FM_COGNEE_ENV_FILE_LOAD_ERROR=env_file_malformed
        # shellcheck disable=SC2034 # Read by callers after fm_cognee_load_env_file returns.
        FM_COGNEE_ENV_FILE_LOAD_LINE=$line_no
        return 1
        ;;
    esac

    fm_cognee_env_is_allowlisted "$key" || continue
    if [ -n "$value" ]; then
      first=${value%"${value#?}"}
      last=${value#"${value%?}"}
      if [ "$first" = "'" ] || [ "$first" = '"' ]; then
        if [ "$last" != "$first" ] || [ "${#value}" -lt 2 ]; then
          # shellcheck disable=SC2034 # Read by callers after fm_cognee_load_env_file returns.
          FM_COGNEE_ENV_FILE_LOAD_ERROR=env_file_malformed
          # shellcheck disable=SC2034 # Read by callers after fm_cognee_load_env_file returns.
          FM_COGNEE_ENV_FILE_LOAD_LINE=$line_no
          # shellcheck disable=SC2034 # Read by callers after fm_cognee_load_env_file returns.
          FM_COGNEE_ENV_FILE_LOAD_KEY=$key
          return 1
        fi
        value=${value#?}
        value=${value%?}
      fi
    fi

    if [ -z "${!key+x}" ] || [ -z "${!key}" ]; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
    fi
  done < "$env_file"
  return 0
}

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

fm_cognee_safe_label() {
  printf '%s' "${1:-}" | sed -E 's/[^A-Za-z0-9_.:-]+/_/g; s/^_+//; s/_+$//' | cut -c 1-160
}

fm_cognee_new_id() {
  local prefix ts rand
  prefix=$(fm_cognee_safe_label "${1:-cognee-id}")
  [ -n "$prefix" ] || prefix=cognee-id
  ts=$(date -u '+%Y%m%dT%H%M%SZ')
  rand=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$rand" ]; then
    rand=$(fm_cognee_telemetry_now_ms 2>/dev/null || printf '0')
  fi
  printf '%s-%s-%s\n' "$prefix" "$ts" "$rand"
}

fm_cognee_hash_id() {
  [ -n "${1:-}" ] || return 0
  printf 'sha256:%s\n' "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
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
  local estimate_source=${20:-missing_vendor_metadata}
  local vendor_usage_present=${21:-false}
  local run_id=${22:-${FM_COGNEE_RUN_ID:-}}
  local request_id=${23:-}
  local logical_search_id=${24:-${FM_COGNEE_LOGICAL_SEARCH_ID:-}}
  local dataset_alias=${25:-unknown}
  local dataset_id_hash=${26:-}
  local search_type=${27:-}
  local top_k=${28:-}
  local include_references=${29:-}
  local request_body_bytes=${30:-}
  local response_body_bytes=${31:-}
  local parsed_source_id_count=${32:-0}
  local final_attempt=${33:-false}
  local telemetry_file

  [ -n "$run_id" ] || run_id=$(fm_cognee_new_id cognee-run)
  [ -n "$request_id" ] || request_id=$(fm_cognee_new_id cognee-req)
  [ -n "$logical_search_id" ] || logical_search_id=$(fm_cognee_new_id cognee-search)
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
    FM_COGNEE_API_T_RUN_ID=$run_id \
    FM_COGNEE_API_T_REQUEST_ID=$request_id \
    FM_COGNEE_API_T_LOGICAL_SEARCH_ID=$logical_search_id \
    FM_COGNEE_API_T_DATASET_ALIAS=$dataset_alias \
    FM_COGNEE_API_T_DATASET_ID_HASH=$dataset_id_hash \
    FM_COGNEE_API_T_SEARCH_TYPE=$search_type \
    FM_COGNEE_API_T_TOP_K=$top_k \
    FM_COGNEE_API_T_INCLUDE_REFERENCES=$include_references \
    FM_COGNEE_API_T_REQUEST_BODY_BYTES=$request_body_bytes \
    FM_COGNEE_API_T_RESPONSE_BODY_BYTES=$response_body_bytes \
    FM_COGNEE_API_T_PARSED_SOURCE_ID_COUNT=$parsed_source_id_count \
    FM_COGNEE_API_T_FINAL_ATTEMPT=$final_attempt \
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
run_id = label("FM_COGNEE_API_T_RUN_ID")
request_id = label("FM_COGNEE_API_T_REQUEST_ID")
logical_search_id = label("FM_COGNEE_API_T_LOGICAL_SEARCH_ID")
vendor_usage_present = boolean("FM_COGNEE_API_T_VENDOR_USAGE")
attempt_number = integer("FM_COGNEE_API_T_ATTEMPT", 1)
retry_count = max(attempt_number - 1, 0)
verification_status = label("FM_COGNEE_API_T_VERIFICATION", "not_attempted")
parsed_source_id_count = integer("FM_COGNEE_API_T_PARSED_SOURCE_ID_COUNT", 0)
event = {
    "schema_version": "cognee_telemetry.v2",
    "ts_utc": now,
    "event_type": "api_attempt",
    "run_id": run_id,
    "request_id": request_id,
    "logical_search_id": logical_search_id,
    "operation_name": label("FM_COGNEE_API_T_OPERATION"),
    "mode": "live",
    "retry_count": retry_count,
    "source_verification_outcome": verification_status,
    "dataset": {
        "dataset_alias": label("FM_COGNEE_API_T_DATASET_ALIAS", "unknown"),
        "dataset_id_hash": os.environ.get("FM_COGNEE_API_T_DATASET_ID_HASH") or None,
    },
    "correlation": {
        "wrapper_run_id": run_id,
        "wrapper_request_id": request_id,
        "logical_search_id": logical_search_id,
    },
    "operation": {
        "operation_name": label("FM_COGNEE_API_T_OPERATION"),
        "http_method": label("FM_COGNEE_API_T_METHOD"),
        "endpoint_template": label("FM_COGNEE_API_T_ENDPOINT"),
        "mutates_remote": boolean("FM_COGNEE_API_T_MUTATES"),
        "search_type": label("FM_COGNEE_API_T_SEARCH_TYPE", "unknown"),
        "top_k": maybe_int("FM_COGNEE_API_T_TOP_K"),
        "include_references": boolean("FM_COGNEE_API_T_INCLUDE_REFERENCES"),
    },
    "status": {
        "status": status,
        "success": status in {"success", "verified"},
        "error_class": label("FM_COGNEE_API_T_ERROR", "none"),
        "http_status": maybe_int("FM_COGNEE_API_T_HTTP_STATUS"),
        "retryable": boolean("FM_COGNEE_API_T_RETRYABLE"),
    },
    "attempt": {
        "retry_count": retry_count,
        "attempt_number": attempt_number,
        "max_attempts": integer("FM_COGNEE_API_T_MAX_ATTEMPTS", 1),
        "is_retry": boolean("FM_COGNEE_API_T_IS_RETRY"),
        "retry_reason": label("FM_COGNEE_API_T_RETRY_REASON", "none"),
        "final_attempt": boolean("FM_COGNEE_API_T_FINAL_ATTEMPT"),
    },
    "latency": {
        "duration_ms": integer("FM_COGNEE_API_T_DURATION_MS", 0),
        "timeout_ms": maybe_int("FM_COGNEE_API_T_TIMEOUT_MS"),
    },
    "sizes": {
        "request_body_bytes": maybe_int("FM_COGNEE_API_T_REQUEST_BODY_BYTES"),
        "response_body_bytes": maybe_int("FM_COGNEE_API_T_RESPONSE_BODY_BYTES"),
    },
    "source_verification": {
        "verification_status": verification_status,
        "verification_required": boolean("FM_COGNEE_API_T_VERIFICATION_REQUIRED"),
    },
    "results": {
        "result_count": integer("FM_COGNEE_API_T_RESULT_COUNT", 0),
        "parsed_source_count": parsed_source_id_count,
        "parsed_source_id_count": parsed_source_id_count,
        "answer_body_logged": False,
    },
    "cost_estimate": {
        "estimated_cost_usd": number_or_none("FM_COGNEE_API_T_COST_USD"),
        "currency": "USD",
        "confidence": label("FM_COGNEE_API_T_COST_CONFIDENCE", "unknown"),
        "estimate_source": label("FM_COGNEE_API_T_ESTIMATE_SOURCE", "missing_vendor_metadata"),
    },
    "vendor_usage": {
        "vendor_usage_present": vendor_usage_present,
        "session_id_hash": None,
        "vendor_request_id_hash": None,
        "input_tokens": None,
        "output_tokens": None,
        "total_tokens": None,
        "cost_usd": None,
        "currency": None,
        "model": None,
        "usage_window_start_utc": None,
        "usage_window_end_utc": None,
        "raw_vendor_field_names": [],
    },
    "vendor_usage_present": vendor_usage_present,
    "privacy": {
        "prompt_logged": False,
        "answer_body_logged": False,
        "source_body_logged": False,
        "auth_headers_logged": False,
        "full_base_url_logged": False,
        "response_content_redacted": True,
    },
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
