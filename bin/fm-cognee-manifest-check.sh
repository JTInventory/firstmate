#!/usr/bin/env bash
# Validate local Cognee manifest rows and verify answer references against them.
#
# This is intentionally local-only. It never calls Cognee, never mutates config,
# and never treats a generated answer as proof without reopening the local source.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-cognee-telemetry-lib.sh"
TELEMETRY_START_MS=$(fm_cognee_telemetry_now_ms)
TELEMETRY_MODE=unknown
TELEMETRY_STATUS=failed
TELEMETRY_ERROR_CLASS=unhandled_exit
TELEMETRY_IMPORTED_BYTES=
TELEMETRY_IMPORTED_TOKENS=
TELEMETRY_SOURCE_OUTCOME=not_attempted
REFS=

telemetry_finish() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "$TELEMETRY_STATUS" = failed ]; then
    TELEMETRY_STATUS=success
    TELEMETRY_ERROR_CLASS=none
  fi
  fm_cognee_telemetry_log \
    cognee_manifest_check "$TELEMETRY_MODE" "$TELEMETRY_STATUS" "$TELEMETRY_ERROR_CLASS" 0 \
    "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" \
    "$TELEMETRY_IMPORTED_BYTES" "$TELEMETRY_IMPORTED_TOKENS" "$TELEMETRY_SOURCE_OUTCOME" \
    0 known_zero_local "" not_called
}

cleanup_manifest_check() {
  [ -n "${REFS:-}" ] && rm -f "$REFS"
  telemetry_finish
}
trap cleanup_manifest_check EXIT

usage() {
  cat >&2 <<'USAGE'
usage: fm-cognee-manifest-check.sh --manifest <manifest.tsv> [--validate | --answer-file <answer.txt>]

The manifest must be TSV with the row fields from the Cognee import policy.
Answer verification looks for SOURCE_ID=, SOURCE_PATH=, and SEED_FILE= labels.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

MANIFEST=
ANSWER_FILE=
VALIDATE=false

while [ $# -gt 0 ]; do
  case "$1" in
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
    --validate)
      VALIDATE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

[ -n "$MANIFEST" ] || { usage; exit 1; }
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
if [ -n "$ANSWER_FILE" ]; then
  [ -f "$ANSWER_FILE" ] || die "answer file not found: $ANSWER_FILE"
fi
if ! "$VALIDATE" && [ -z "$ANSWER_FILE" ]; then
  usage
  exit 1
fi
if "$VALIDATE"; then
  TELEMETRY_MODE=validate
else
  TELEMETRY_MODE=answer_verify
fi

required_fields='row_id source_group source_path source_truth_pointer source_kind recommended_tier decision_status redaction_status redaction_notes sensitivity_label stale_risk supersession_check source_size_bytes source_mtime_utc source_sha256 estimated_words estimated_tokens estimated_cost_formula import_text_prefix raw_readback_status verification_status'
allowed_redaction=' passed redacted summarized path_index_only '
allowed_stale=' low medium high live_external unknown '
allowed_raw=' not_attempted passed failed_404 404 not_trusted not_applicable '
allowed_verification=' not_imported verified_local_source hint_only failed stale '

declare -A IDX
IFS=$'\t' read -r -a HEADER < "$MANIFEST" || die "manifest is empty"
for i in "${!HEADER[@]}"; do
  IDX["${HEADER[$i]}"]=$i
done

for field in $required_fields; do
  [ -n "${IDX[$field]+x}" ] || die "manifest missing required field: $field"
done

field_value() {
  local name=$1 idx=${IDX[$1]}
  printf '%s' "${COLS[$idx]:-}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

row_matches_ref() {
  local kind=$1 value=$2
  local row_id source_path import_text cognee_source_id cognee_data_id cognee_chunk_ids summary_path seed_name
  row_id=$(field_value row_id)
  source_path=$(field_value source_path)
  import_text=$(field_value import_text_prefix)
  cognee_source_id=
  cognee_data_id=
  cognee_chunk_ids=
  summary_path=
  [ -n "${IDX[cognee_source_id]+x}" ] && cognee_source_id=$(field_value cognee_source_id)
  [ -n "${IDX[cognee_data_id]+x}" ] && cognee_data_id=$(field_value cognee_data_id)
  [ -n "${IDX[cognee_chunk_ids]+x}" ] && cognee_chunk_ids=$(field_value cognee_chunk_ids)
  [ -n "${IDX[summary_path]+x}" ] && summary_path=$(field_value summary_path)
  seed_name=$(basename "$source_path")

  case "$kind" in
    SOURCE_ID)
      [ "$value" = "$row_id" ] && return 0
      [ -n "$cognee_source_id" ] && [ "$value" = "$cognee_source_id" ] && return 0
      [ -n "$cognee_data_id" ] && [ "$value" = "$cognee_data_id" ] && return 0
      case " $cognee_chunk_ids " in *" $value "*) return 0 ;; esac
      case "$import_text" in *"SOURCE_ID=$value"*|*"SOURCE_ID: $value"*) return 0 ;; esac
      ;;
    SOURCE_PATH)
      [ "$value" = "$source_path" ] && return 0
      [ -n "$summary_path" ] && [ "$value" = "$summary_path" ] && return 0
      ;;
    SEED_FILE)
      # A bare "report.md" appears across many imported report rows. It is
      # useful as hint text, but too generic to prove exact attribution.
      [ "$value" = "report.md" ] && return 1
      [ "$value" = "$seed_name" ] && return 0
      case "$import_text" in *"SEED_FILE=$value"*|*"SEED_FILE: $value"*) return 0 ;; esac
      ;;
  esac
  return 1
}

validate_current_row() {
  local field value source_path source_path_lc expected actual actual_size redaction stale raw verification size tokens

  for field in $required_fields; do
    value=$(field_value "$field")
    [ -n "$value" ] || {
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=missing_$field
      TELEMETRY_SOURCE_OUTCOME=missing_$field
      echo "label=blocked_missing_proof reason=missing_$field external_action_authorized=false"
      return 1
    }
  done

  source_path=$(field_value source_path)
  source_path_lc=$(printf '%s' "$source_path" | tr '[:upper:]' '[:lower:]')
  case "$source_path_lc" in
    *secret*|*token*|*api_key*|*password*|*credential*|*auth*|*bearer*|*cookie*|*private_key*|*.env*|*session*|*oauth*|*signed*)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=path_risk_scan_failed
      TELEMETRY_SOURCE_OUTCOME=path_risk_scan_failed
      echo "label=blocked_missing_proof reason=path_risk_scan_failed external_action_authorized=false"
      return 1
      ;;
  esac

  case "$source_path" in
    /*) ;;
    *)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=source_path_not_absolute
      TELEMETRY_SOURCE_OUTCOME=source_path_not_absolute
      echo "label=blocked_missing_proof reason=source_path_not_absolute source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac
  [ -r "$source_path" ] || {
    TELEMETRY_STATUS=blocked
    TELEMETRY_ERROR_CLASS=source_unreadable
    TELEMETRY_SOURCE_OUTCOME=source_unreadable
    echo "label=blocked_missing_proof reason=source_unreadable source_path=$source_path external_action_authorized=false"
    return 1
  }

  redaction=$(field_value redaction_status)
  case "$allowed_redaction" in
    *" $redaction "*) ;;
    *)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=redaction_not_passed
      TELEMETRY_SOURCE_OUTCOME=redaction_not_passed
      echo "label=blocked_missing_proof reason=redaction_not_passed redaction_status=$redaction source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  stale=$(field_value stale_risk)
  case "$allowed_stale" in
    *" $stale "*) ;;
    *)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=invalid_stale_risk
      TELEMETRY_SOURCE_OUTCOME=invalid_stale_risk
      echo "label=blocked_missing_proof reason=invalid_stale_risk stale_risk=$stale source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  raw=$(field_value raw_readback_status)
  case "$raw" in
    failed_404|404)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=raw_readback_durability_failure
      TELEMETRY_SOURCE_OUTCOME=raw_readback_durability_failure
      echo "label=blocked_missing_proof reason=raw_readback_durability_failure raw_readback_status=$raw external_action_authorized=false"
      return 1
      ;;
  esac
  case "$allowed_raw" in
    *" $raw "*) ;;
    *)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=invalid_raw_readback_status
      TELEMETRY_SOURCE_OUTCOME=invalid_raw_readback_status
      echo "label=blocked_missing_proof reason=invalid_raw_readback_status raw_readback_status=$raw source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  verification=$(field_value verification_status)
  case "$allowed_verification" in
    *" $verification "*) ;;
    *)
      TELEMETRY_STATUS=blocked
      TELEMETRY_ERROR_CLASS=invalid_verification_status
      TELEMETRY_SOURCE_OUTCOME=invalid_verification_status
      echo "label=blocked_missing_proof reason=invalid_verification_status verification_status=$verification source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  size=$(field_value source_size_bytes)
  actual_size=$(wc -c < "$source_path" | tr -d ' ')
  [ "$size" = "$actual_size" ] || {
    TELEMETRY_STATUS=blocked
    TELEMETRY_ERROR_CLASS=size_mismatch
    TELEMETRY_SOURCE_OUTCOME=size_mismatch
    echo "label=blocked_missing_proof reason=size_mismatch source_path=$source_path external_action_authorized=false"
    return 1
  }

  expected=$(field_value source_sha256)
  actual=$(sha256_file "$source_path")
  [ "$expected" = "$actual" ] || {
    TELEMETRY_STATUS=blocked
    TELEMETRY_ERROR_CLASS=checksum_mismatch
    TELEMETRY_SOURCE_OUTCOME=checksum_mismatch
    echo "label=blocked_missing_proof reason=checksum_mismatch source_path=$source_path external_action_authorized=false"
    return 1
  }

  tokens=$(field_value estimated_tokens)
  case "$size" in ''|*[!0-9]*) ;; *) TELEMETRY_IMPORTED_BYTES=$(( ${TELEMETRY_IMPORTED_BYTES:-0} + size )) ;; esac
  case "$tokens" in ''|*[!0-9]*) ;; *) TELEMETRY_IMPORTED_TOKENS=$(( ${TELEMETRY_IMPORTED_TOKENS:-0} + tokens )) ;; esac
  return 0
}

sanitize_ref() {
  # Strip wrapping punctuation without printing answer text.
  sed -E 's/^[`"'\''[:space:]]+//; s/[`"'\'',.;:)[:space:]]+$//'
}

REFS=$(mktemp "${TMPDIR:-/tmp}/fm-cognee-refs.XXXXXX")

if [ -n "$ANSWER_FILE" ]; then
  python3 - "$ANSWER_FILE" > "$REFS" <<'PY'
import re
import sys
from pathlib import Path


label_re = re.compile(
    r"\b(SOURCE_ID|SOURCE_PATH|SEED_FILE)\s*[:=]\s*[*_`\u202f\s]*"
    r"(?:\"([^\"]*)\"|'([^']*)'|([^\s,;\]\)]+))"
)

try:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
except Exception:
    raise SystemExit

refs = set()
for match in label_re.finditer(text):
    value = next(group for group in match.groups()[1:] if group is not None).strip()
    value = value.strip("`\"'[],;.)")
    if value:
        refs.add((match.group(1), value))

for kind, value in sorted(refs):
    print(f"{kind}\t{value}")
PY
fi

if "$VALIDATE"; then
  ok=true
  while IFS=$'\t' read -r -a COLS || [ "${#COLS[@]}" -gt 0 ]; do
    [ "${#COLS[@]}" -eq 0 ] && continue
    validate_current_row || ok=false
  done < <(tail -n +2 "$MANIFEST")
  "$ok" || exit 1
  TELEMETRY_STATUS=valid
  TELEMETRY_ERROR_CLASS=none
  TELEMETRY_SOURCE_OUTCOME=manifest_valid
  echo "manifest_status=valid external_action_authorized=false"
fi

if [ -n "$ANSWER_FILE" ]; then
  if [ ! -s "$REFS" ]; then
    TELEMETRY_STATUS=blocked
    TELEMETRY_ERROR_CLASS=no_usable_citations
    TELEMETRY_SOURCE_OUTCOME=no_usable_citations
    echo "label=blocked_missing_proof reason=no_usable_citations external_action_authorized=false"
    exit 3
  fi

  found=false
  failed=false
  while IFS=$'\t' read -r -a COLS || [ "${#COLS[@]}" -gt 0 ]; do
    [ "${#COLS[@]}" -eq 0 ] && continue
    while IFS=$'\t' read -r ref_kind ref_value; do
      if row_matches_ref "$ref_kind" "$ref_value"; then
        if validate_current_row >/dev/null; then
          found=true
          row_id=$(field_value row_id)
          source_path=$(field_value source_path)
          stale=$(field_value stale_risk)
          verification=$(field_value verification_status)
          label=verified_local_source
          case "$stale" in high|live_external) label=stale_warning ;; esac
          TELEMETRY_STATUS=verified
          TELEMETRY_ERROR_CLASS=none
          TELEMETRY_SOURCE_OUTCOME=$label
          echo "label=$label row_id=$row_id matched_ref=$ref_kind source_path=$source_path stale_risk=$stale manifest_verification_status=$verification external_action_authorized=false"
        else
          failed=true
          validate_current_row || true
        fi
        break
      fi
    done < "$REFS"
  done < <(tail -n +2 "$MANIFEST")

  if ! "$found"; then
    if "$failed"; then
      exit 1
    fi
    TELEMETRY_STATUS=blocked
    TELEMETRY_ERROR_CLASS=manifest_reference_not_found
    TELEMETRY_SOURCE_OUTCOME=manifest_reference_not_found
    echo "label=blocked_missing_proof reason=manifest_reference_not_found external_action_authorized=false"
    exit 3
  fi
fi
