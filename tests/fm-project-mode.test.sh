#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-mode-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

run_mode() {
  local home=$1 project=$2
  FM_HOME="$home" "$MODE" "$project" 2>/dev/null
}

test_legacy_defaults_and_old_direct_pr() {
  local home out
  home="$TMP_ROOT/legacy"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<EOF
- old-default - legacy default (added 2026-06-24)
- old-direct [direct-PR] - direct project (added 2026-06-24)
EOF

  out=$(run_mode "$home" old-default)
  [ "$out" = "no-mistakes off off" ] || fail "legacy default output changed: $out"
  out=$(run_mode "$home" old-direct)
  [ "$out" = "direct-PR off off" ] || fail "old direct-PR output changed: $out"
  pass "legacy and old direct-PR projects return nm_gate=off"
}

test_nm_gate_and_yolo_parse() {
  local home out
  home="$TMP_ROOT/nm"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<EOF
- gated [direct-PR +nm-gate] - gated direct project (added 2026-06-24)
- gated-yolo [direct-PR +yolo +nm-gate] - gated direct project (added 2026-06-24)
EOF

  out=$(run_mode "$home" gated)
  [ "$out" = "direct-PR off on" ] || fail "direct-PR +nm-gate did not parse: $out"
  out=$(run_mode "$home" gated-yolo)
  [ "$out" = "direct-PR on on" ] || fail "direct-PR +yolo +nm-gate did not parse: $out"
  pass "nm-gate parses with and without yolo"
}

test_missing_registry_fallback_has_three_fields() {
  local home out
  home="$TMP_ROOT/missing"
  mkdir -p "$home"
  out=$(run_mode "$home" absent)
  [ "$out" = "no-mistakes off off" ] || fail "missing registry fallback should return three fields: $out"
  pass "missing registry fallback stays three-field compatible"
}

test_legacy_defaults_and_old_direct_pr
test_nm_gate_and_yolo_parse
test_missing_registry_fallback_has_three_fields
