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
  FM_COGNEE_GATE_COST_USAGE_EVIDENCE=acceptable
  FM_COGNEE_GATE_SOURCE_VERIFICATION_THRESHOLD=pass
  FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass
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

reject_external_action_authority() {
  local rel report
  for rel in \
    cognee-p7-production-readiness-0628/report.md \
    cognee-p7-benchmark-verified-answers-0629/report.md \
    cognee-usage-rollup-real-telemetry-0629/report.md \
    cognee-cost-usage-metadata-check-0629/report.md \
    cognee-vendor-raw-durability-escalation-0629/report.md
  do
    report="$EVIDENCE_ROOT/$rel"
    [ -f "$report" ] || continue
    if grep -Fq -- "external_action_authorized=true" "$report"; then
      block "evidence attempts to authorize external action: $report"
    fi
  done
}

case "$MODE" in
  manual-verified)
    printf 'manual_verified_lookup_allowed=true\n'
    printf 'automatic_lookup_allowed=false\n'
    emit_safe_defaults
    printf 'source_authority=local_source_required\n'
    printf 'note=manual Cognee lookup may be used only as a source-verified hint\n'
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
    require_marker \
      cognee-cost-usage-metadata-check-0629/report.md \
      "FM_COGNEE_GATE_COST_USAGE_EVIDENCE=acceptable" \
      "missing acceptable cost/usage evidence"
    require_marker \
      cognee-p7-production-readiness-0628/report.md \
      "FM_COGNEE_GATE_SOURCE_VERIFICATION_THRESHOLD=pass" \
      "missing source verification threshold evidence"
    require_marker \
      cognee-vendor-raw-durability-escalation-0629/report.md \
      "FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass" \
      "missing raw durability/source-authority evidence"

    reject_external_action_authority

    printf 'automatic_lookup_allowed=true\n'
    printf 'manual_verified_lookup_allowed=true\n'
    emit_safe_defaults
    printf 'source_authority=local_source_required\n'
    ;;
  *)
    usage
    exit 2
    ;;
esac
