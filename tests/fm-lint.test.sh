#!/usr/bin/env bash
# Contract tests for deterministic ShellCheck parity between CI and no-mistakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"

test_owner_and_gate_wiring() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable"
  assert_grep 'shellcheck --norc -x -P SCRIPTDIR -S warning bin/*.sh tests/*.sh' "$LINT" "lint owner does not define the canonical file set"
  assert_grep 'run: bin/fm-lint.sh' "$CI" "CI does not invoke the lint owner"
  assert_grep 'fm-install-shellcheck.sh' "$NM" "no-mistakes does not provision pinned ShellCheck"
  assert_grep 'bin/fm-lint.sh' "$NM" "no-mistakes does not invoke the lint owner"
  assert_grep 'fm-lint.sh" --required-version' "$INSTALLER" "installer does not read the lint owner version"
  pass "CI and no-mistakes share one lint owner"
}

test_version_pin_and_rejection() {
  local required tmp fakebin output rc
  required=$("$LINT" --required-version) || fail "lint owner cannot report its version"
  [ "$required" = '0.11.0' ] || fail "unexpected ShellCheck pin: $required"
  tmp=$(fm_test_tmproot fm-lint-version)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = '--version' ]; then
  printf '%s\n' 'version: 0.9.0'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  output=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "lint owner accepted an unpinned ShellCheck"
  assert_contains "$output" "$required" "version error omitted the required ShellCheck pin"
  pass "lint owner rejects version drift"
}

test_owner_and_gate_wiring
test_version_pin_and_rejection
