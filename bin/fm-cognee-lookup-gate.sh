#!/usr/bin/env bash
# Fail-closed policy gate for Cognee lookup modes.
#
# This script never calls Cognee. It reads local evidence reports only.
# Automatic lookup stays off unless the captain explicitly enables it and all
# required gate markers are present in the local report set.
set -eu

MODE=${1:-}
EVIDENCE_ROOT=${FM_COGNEE_EVIDENCE_ROOT:-/root/firstmate/data}

usage() {
  cat >&2 <<'EOF'
usage: fm-cognee-lookup-gate.sh automatic|manual-verified

Automatic lookup requires:
  FM_COGNEE_AUTO_LOOKUP=1

Evidence reports must contain these exact gate markers:
  FM_COGNEE_GATE_BENCHMARK_THRESHOLD=pass
  FM_COGNEE_GATE_TELEMETRY_ROLLUP_THRESHOLD=pass
  FM_COGNEE_GATE_COST_USAGE_EVIDENCE=per_wrapper_call
  FM_COGNEE_GATE_SOURCE_VERIFICATION_THRESHOLD=pass
  FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass

Trial-only evidence is recognized but still blocks automatic lookup:
  FM_COGNEE_GATE_COST_USAGE_EVIDENCE=session_window_only
EOF
}

emit_safe_defaults() {
  printf 'external_action_authorized=false\n'
}

block() {
  printf 'automatic_lookup_allowed=false\n'
  emit_safe_defaults
  printf 'blocked: %s\n' "$1"
  exit 1
}

report_has_marker() {
  local report=$1 marker=$2
  [ -f "$report" ] || return 1
  grep -Fqx -- "$marker" "$report"
}

require_marker() {
  local rel=$1 marker=$2 reason=$3 report
  report="$EVIDENCE_ROOT/$rel"
  report_has_marker "$report" "$marker" || block "$reason: $report"
}

evidence_reports() {
  cat <<'EOF'
cognee-p7-production-readiness-0628/report.md
cognee-p7-benchmark-verified-answers-0629/report.md
cognee-usage-rollup-real-telemetry-0629/report.md
cognee-cost-usage-metadata-check-0629/report.md
cognee-vendor-raw-durability-escalation-0629/report.md
EOF
}

reject_unsafe_evidence() {
  local rel report marker
  for rel in \
    $(evidence_reports)
  do
    report="$EVIDENCE_ROOT/$rel"
    [ -f "$report" ] || continue
    for marker in \
      "external_action_authorized=true" \
      "answer_body_logged=true" \
      "question_logged=true" \
      "context_logged=true" \
      "raw_session_detail_logged=true" \
      "raw_session_json_logged=true" \
      "auth_headers_logged=true" \
      "base_url_logged=true" \
      "full_base_url_logged=true" \
      "secret_value_logged=true"
    do
      if grep -Fq -- "$marker" "$report"; then
        block "unsafe Cognee logging evidence ($marker): $report"
      fi
    done
  done
}

require_per_wrapper_call_cost_evidence() {
  local rel report value
  rel=cognee-cost-usage-metadata-check-0629/report.md
  report="$EVIDENCE_ROOT/$rel"
  [ -f "$report" ] || block "missing cost/usage evidence: $report"
  value=$(
    awk -F= '
      $1 == "FM_COGNEE_GATE_COST_USAGE_EVIDENCE" {
        print $2
        exit
      }
    ' "$report"
  )
  case "$value" in
    per_wrapper_call)
      printf 'cost_usage_evidence=per_wrapper_call\n'
      ;;
    session_window_only)
      printf 'cost_usage_evidence=session_window_only\n'
      block "session-window-only cost evidence is trial-only; no safe per-wrapper-call cost/request/session/QA id bridge exists today: $report"
      ;;
    *)
      block "missing cost/usage evidence: $report"
      ;;
  esac
}

reject_legacy_acceptable_cost_evidence() {
  local report="$EVIDENCE_ROOT/cognee-cost-usage-metadata-check-0629/report.md"
  [ -f "$report" ] || return 0
  if report_has_marker "$report" "FM_COGNEE_GATE_COST_USAGE_EVIDENCE=acceptable"; then
    block "legacy ambiguous cost/usage evidence is not enough for automatic lookup; require per_wrapper_call proof: $report"
  fi
}

emit_manual_verified_contract() {
  printf 'manual_verified_lookup_allowed=true\n'
  printf 'automatic_lookup_allowed=false\n'
  emit_safe_defaults
  printf 'read_only=true\n'
  printf 'hint_only=true\n'
  printf 'fail_closed=true\n'
  printf 'source_authority=local_source_required\n'
  printf 'note=manual Cognee lookup may be used only as a source-verified hint\n'
}

emit_automatic_allowed() {
  printf 'automatic_lookup_allowed=true\n'
  printf 'manual_verified_lookup_allowed=true\n'
  emit_safe_defaults
  printf 'read_only=true\n'
  printf 'hint_only=true\n'
  printf 'fail_closed=true\n'
  printf 'source_authority=local_source_required\n'
}

case "$MODE" in
  manual-verified)
    emit_manual_verified_contract
    ;;
  automatic)
    if [ "${FM_COGNEE_AUTO_LOOKUP:-0}" != "1" ]; then
      block "captain has not enabled Cognee automatic lookup"
    fi

    require_marker \
      cognee-p7-benchmark-verified-answers-0629/report.md \
      "FM_COGNEE_GATE_BENCHMARK_THRESHOLD=pass" \
      "missing benchmark threshold evidence"
    require_marker \
      cognee-usage-rollup-real-telemetry-0629/report.md \
      "FM_COGNEE_GATE_TELEMETRY_ROLLUP_THRESHOLD=pass" \
      "missing telemetry rollup threshold evidence"
    reject_legacy_acceptable_cost_evidence
    require_per_wrapper_call_cost_evidence
    require_marker \
      cognee-p7-production-readiness-0628/report.md \
      "FM_COGNEE_GATE_SOURCE_VERIFICATION_THRESHOLD=pass" \
      "missing source verification threshold evidence"
    require_marker \
      cognee-vendor-raw-durability-escalation-0629/report.md \
      "FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass" \
      "missing raw durability/source-authority evidence"

    reject_unsafe_evidence

    emit_automatic_allowed
    ;;
  *)
    usage
    exit 2
    ;;
esac
