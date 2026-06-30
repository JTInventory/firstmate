#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMPROOT=$(fm_test_tmproot cognee-gate)
EVIDENCE="$TMPROOT/data"
mkdir -p "$EVIDENCE"

run_gate() {
  FM_COGNEE_EVIDENCE_ROOT="$EVIDENCE" "$ROOT/bin/fm-cognee-lookup-gate.sh" "$@" 2>&1
}

write_report() {
  local rel=$1
  shift
  mkdir -p "$EVIDENCE/$(dirname "$rel")"
  printf '%s\n' "$@" > "$EVIDENCE/$rel"
}

write_all_passing_reports() {
  write_report cognee-p7-production-readiness-0628/report.md \
    "FM_COGNEE_GATE_SOURCE_VERIFICATION_THRESHOLD=pass"
  write_report cognee-p7-benchmark-verified-answers-0629/report.md \
    "FM_COGNEE_GATE_BENCHMARK_THRESHOLD=pass"
  write_report cognee-usage-rollup-real-telemetry-0629/report.md \
    "FM_COGNEE_GATE_TELEMETRY_ROLLUP_THRESHOLD=pass"
  write_report cognee-cost-usage-metadata-check-0629/report.md \
    "FM_COGNEE_GATE_COST_USAGE_EVIDENCE=per_wrapper_call"
  write_report cognee-vendor-raw-durability-escalation-0629/report.md \
    "FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass"
}

test_default_automatic_lookup_disabled() {
  local out rc
  out=$(run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "default automatic lookup"
  assert_contains "$out" "blocked: captain has not enabled Cognee automatic lookup" "default automatic lookup explains captain enablement"
  assert_contains "$out" "external_action_authorized=false" "default automatic lookup authorizes no action"
  pass "default automatic lookup is disabled"
}

test_missing_benchmark_blocks_enablement() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports
  rm "$EVIDENCE/cognee-p7-benchmark-verified-answers-0629/report.md"

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "missing benchmark"
  assert_contains "$out" "missing benchmark threshold evidence" "missing benchmark blocks with clear reason"
  assert_contains "$out" "external_action_authorized=false" "missing benchmark authorizes no action"
  pass "missing benchmark blocks automatic enablement"
}

test_missing_telemetry_rollup_blocks_enablement() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports
  rm "$EVIDENCE/cognee-usage-rollup-real-telemetry-0629/report.md"

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "missing telemetry rollup"
  assert_contains "$out" "missing telemetry rollup threshold evidence" "missing telemetry blocks with clear reason"
  pass "missing telemetry rollup blocks automatic enablement"
}

test_unknown_cost_blocks_enablement() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports
  write_report cognee-cost-usage-metadata-check-0629/report.md \
    "FM_COGNEE_GATE_COST_USAGE_EVIDENCE=unknown"

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "unknown cost evidence"
  assert_contains "$out" "missing cost/usage evidence" "unknown cost blocks with clear reason"
  pass "missing or unknown cost evidence blocks automatic enablement"
}

test_missing_cost_evidence_blocks_enablement() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports
  rm "$EVIDENCE/cognee-cost-usage-metadata-check-0629/report.md"

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "missing cost evidence"
  assert_contains "$out" "missing cost/usage evidence" "missing cost evidence blocks with clear reason"
  assert_contains "$out" "external_action_authorized=false" "missing cost evidence authorizes no action"
  pass "missing cost evidence blocks automatic enablement"
}

test_session_window_only_cost_blocks_automatic_promotion() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports
  write_report cognee-cost-usage-metadata-check-0629/report.md \
    "FM_COGNEE_GATE_COST_USAGE_EVIDENCE=session_window_only"

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "session-window-only cost evidence"
  assert_contains "$out" "cost_usage_evidence=session_window_only" "session-window-only evidence should be reported"
  assert_contains "$out" "no safe per-wrapper-call cost/request/session/QA id bridge exists today" \
    "session-window-only evidence blocks with the bridge reason"
  assert_contains "$out" "external_action_authorized=false" "session-window-only evidence authorizes no action"
  pass "session-window-only cost evidence is trial-only and blocks automatic promotion"
}

test_unsafe_logging_evidence_blocks_enablement() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports
  write_report cognee-usage-rollup-real-telemetry-0629/report.md \
    "FM_COGNEE_GATE_TELEMETRY_ROLLUP_THRESHOLD=pass" \
    "answer_body_logged=true"

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 1 "$rc" "unsafe logging evidence"
  assert_contains "$out" "unsafe Cognee logging evidence" "unsafe logging marker blocks with clear reason"
  assert_contains "$out" "answer_body_logged=true" "blocked reason names unsafe marker"
  assert_contains "$out" "external_action_authorized=false" "unsafe logging evidence authorizes no action"
  pass "unsafe answer/session body logging evidence blocks automatic enablement"
}

test_no_external_action_is_authorized() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
  write_all_passing_reports

  out=$(FM_COGNEE_AUTO_LOOKUP=1 run_gate automatic)
  rc=$?

  expect_code 0 "$rc" "passing automatic evidence"
  assert_contains "$out" "automatic_lookup_allowed=true" "passing evidence allows lookup"
  assert_contains "$out" "external_action_authorized=false" "passing evidence still authorizes no action"
  assert_not_contains "$out" "external_action_authorized=true" "gate never authorizes external action"
  pass "no external action is authorized"
}

test_manual_verified_lookup_remains_allowed() {
  local out rc
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"

  out=$(run_gate manual-verified)
  rc=$?

  expect_code 0 "$rc" "manual verified lookup"
  assert_contains "$out" "manual_verified_lookup_allowed=true" "manual verified lookup allowed"
  assert_contains "$out" "automatic_lookup_allowed=false" "manual verified lookup does not enable automatic lookup"
  assert_contains "$out" "external_action_authorized=false" "manual lookup authorizes no external action"
  assert_contains "$out" "read_only=true" "manual lookup remains read-only"
  assert_contains "$out" "hint_only=true" "manual lookup remains hint-only"
  assert_contains "$out" "fail_closed=true" "manual lookup remains fail-closed"
  assert_contains "$out" "source_authority=local_source_required" "manual lookup still requires local source proof"
  pass "manual verified lookup remains allowed"
}

test_default_automatic_lookup_disabled
test_missing_benchmark_blocks_enablement
test_missing_telemetry_rollup_blocks_enablement
test_unknown_cost_blocks_enablement
test_missing_cost_evidence_blocks_enablement
test_session_window_only_cost_blocks_automatic_promotion
test_unsafe_logging_evidence_blocks_enablement
test_no_external_action_is_authorized
test_manual_verified_lookup_remains_allowed
