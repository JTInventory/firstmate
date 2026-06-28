#!/usr/bin/env bash
# Validate local Cognee manifest rows and verify answer references against them.
#
# This is intentionally local-only. It never calls Cognee, never mutates config,
# and never treats a generated answer as proof without reopening the local source.
set -eu

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

required_fields='row_id source_group source_path source_truth_pointer source_kind recommended_tier decision_status redaction_status redaction_notes sensitivity_label stale_risk supersession_check source_size_bytes source_mtime_utc source_sha256 estimated_words estimated_tokens estimated_cost_formula import_text_prefix raw_readback_status verification_status'
allowed_redaction=' passed redacted summarized path_index_only '
allowed_stale=' low medium high live_external unknown '
allowed_raw=' not_attempted passed failed_404 not_trusted not_applicable '
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
      [ "$value" = "$seed_name" ] && return 0
      case "$import_text" in *"SEED_FILE=$value"*|*"SEED_FILE: $value"*) return 0 ;; esac
      ;;
  esac
  return 1
}

validate_current_row() {
  local field value source_path source_path_lc expected actual actual_size redaction stale raw verification size

  for field in $required_fields; do
    value=$(field_value "$field")
    [ -n "$value" ] || {
      echo "label=blocked_missing_proof reason=missing_$field external_action_authorized=false"
      return 1
    }
  done

  source_path=$(field_value source_path)
  source_path_lc=$(printf '%s' "$source_path" | tr '[:upper:]' '[:lower:]')
  case "$source_path_lc" in
    *secret*|*token*|*api_key*|*password*|*credential*|*auth*|*bearer*|*cookie*|*private_key*|*.env*|*session*|*oauth*|*signed*)
      echo "label=blocked_missing_proof reason=path_risk_scan_failed external_action_authorized=false"
      return 1
      ;;
  esac

  case "$source_path" in
    /*) ;;
    *)
      echo "label=blocked_missing_proof reason=source_path_not_absolute source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac
  [ -r "$source_path" ] || {
    echo "label=blocked_missing_proof reason=source_unreadable source_path=$source_path external_action_authorized=false"
    return 1
  }

  redaction=$(field_value redaction_status)
  case "$allowed_redaction" in
    *" $redaction "*) ;;
    *)
      echo "label=blocked_missing_proof reason=redaction_not_passed redaction_status=$redaction source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  stale=$(field_value stale_risk)
  case "$allowed_stale" in
    *" $stale "*) ;;
    *)
      echo "label=blocked_missing_proof reason=invalid_stale_risk stale_risk=$stale source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  raw=$(field_value raw_readback_status)
  case "$allowed_raw" in
    *" $raw "*) ;;
    *)
      echo "label=blocked_missing_proof reason=invalid_raw_readback_status raw_readback_status=$raw source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  verification=$(field_value verification_status)
  case "$allowed_verification" in
    *" $verification "*) ;;
    *)
      echo "label=blocked_missing_proof reason=invalid_verification_status verification_status=$verification source_path=$source_path external_action_authorized=false"
      return 1
      ;;
  esac

  size=$(field_value source_size_bytes)
  actual_size=$(wc -c < "$source_path" | tr -d ' ')
  [ "$size" = "$actual_size" ] || {
    echo "label=blocked_missing_proof reason=size_mismatch source_path=$source_path external_action_authorized=false"
    return 1
  }

  expected=$(field_value source_sha256)
  actual=$(sha256_file "$source_path")
  [ "$expected" = "$actual" ] || {
    echo "label=blocked_missing_proof reason=checksum_mismatch source_path=$source_path external_action_authorized=false"
    return 1
  }

  return 0
}

sanitize_ref() {
  # Strip wrapping punctuation without printing answer text.
  sed -E 's/^[`"'\''[:space:]]+//; s/[`"'\'',.;:)[:space:]]+$//'
}

REFS=$(mktemp "${TMPDIR:-/tmp}/fm-cognee-refs.XXXXXX")
trap 'rm -f "$REFS"' EXIT

if [ -n "$ANSWER_FILE" ]; then
  {
    grep -Eoh 'SOURCE_ID[[:space:]]*[:=][[:space:]]*[^[:space:],;)]+' "$ANSWER_FILE" 2>/dev/null \
      | sed -E 's/^SOURCE_ID[[:space:]]*[:=][[:space:]]*//' | sanitize_ref | awk 'NF {print "SOURCE_ID\t"$0}'
    grep -Eoh 'SOURCE_PATH[[:space:]]*[:=][[:space:]]*[^[:space:],;)]+' "$ANSWER_FILE" 2>/dev/null \
      | sed -E 's/^SOURCE_PATH[[:space:]]*[:=][[:space:]]*//' | sanitize_ref | awk 'NF {print "SOURCE_PATH\t"$0}'
    grep -Eoh 'SEED_FILE[[:space:]]*[:=][[:space:]]*[^[:space:],;)]+' "$ANSWER_FILE" 2>/dev/null \
      | sed -E 's/^SEED_FILE[[:space:]]*[:=][[:space:]]*//' | sanitize_ref | awk 'NF {print "SEED_FILE\t"$0}'
  } | sort -u > "$REFS"
fi

if "$VALIDATE"; then
  ok=true
  while IFS=$'\t' read -r -a COLS || [ "${#COLS[@]}" -gt 0 ]; do
    [ "${#COLS[@]}" -eq 0 ] && continue
    validate_current_row || ok=false
  done < <(tail -n +2 "$MANIFEST")
  "$ok" || exit 1
  echo "manifest_status=valid external_action_authorized=false"
fi

if [ -n "$ANSWER_FILE" ]; then
  if [ ! -s "$REFS" ]; then
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
    echo "label=blocked_missing_proof reason=manifest_reference_not_found external_action_authorized=false"
    exit 3
  fi
fi
