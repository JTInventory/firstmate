#!/usr/bin/env bash
# Contract tests for deterministic ShellCheck parity between CI and no-mistakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"

write_logging_shellcheck() {
  local fake_shellcheck=$1
  cat >"$fake_shellcheck" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = '--version' ]; then
  printf '%s\n' 'version: 0.11.0'
  exit 0
fi

count_file=${FAKE_SHELLCHECK_COUNT:?}
paths_file=${FAKE_SHELLCHECK_PATHS:?}
args_file=${FAKE_SHELLCHECK_ARGS:?}
count=0
if [ -s "$count_file" ]; then
  count=$(sed -n '1p' "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

printf '%s|%s|%s|%s|%s|%s|%s\n' \
  "$1" "$2" "$3" "$4" "$5" "$6" "$7" >>"$args_file"

record_paths=0
for arg in "$@"; do
  if [ "$arg" = '--' ]; then
    record_paths=1
    continue
  fi
  if [ "$record_paths" -eq 1 ]; then
    printf '%s\0' "$arg" >>"$paths_file"
  fi
done
SH
  chmod +x "$fake_shellcheck"
}

test_owner_and_gate_wiring() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable"
  assert_grep 'lint_files=(bin/*.sh tests/*.sh)' "$LINT" "lint owner does not define the canonical file set"
  assert_grep 'shellcheck --norc -x -P SCRIPTDIR -S warning --' "$LINT" "lint owner changed the ShellCheck flags"
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

test_batched_complete_coverage_and_flags() {
  local tmp fakebin count_file paths_file args_file output rc expected_count actual_count expected_batches count line
  local -a expected_paths observed_paths
  tmp=$(fm_test_tmproot fm-lint-batches)
  fakebin=$(fm_fakebin "$tmp")
  count_file="$tmp/count"
  paths_file="$tmp/paths"
  args_file="$tmp/args"
  : >"$count_file"
  : >"$paths_file"
  : >"$args_file"
  write_logging_shellcheck "$fakebin/shellcheck"

  rc=0
  output=$(
    FAKE_SHELLCHECK_COUNT="$count_file" \
      FAKE_SHELLCHECK_PATHS="$paths_file" \
      FAKE_SHELLCHECK_ARGS="$args_file" \
      PATH="$fakebin:$PATH" "$LINT" 2>&1
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "batched lint unexpectedly failed: $output"

  mapfile -t expected_paths < <(printf '%s\n' bin/*.sh tests/*.sh)
  mapfile -d '' -t observed_paths <"$paths_file"
  expected_count=${#expected_paths[@]}
  actual_count=${#observed_paths[@]}
  [ "$actual_count" -eq "$expected_count" ] \
    || fail "batched lint covered $actual_count of $expected_count files"
  for ((i = 0; i < expected_count; i++)); do
    [ "${observed_paths[i]}" = "${expected_paths[i]}" ] \
      || fail "batched lint changed file order at index $i"
  done

  count=$(sed -n '1p' "$count_file")
  [ "$count" -gt 1 ] || fail "lint did not use multiple ShellCheck batches"
  expected_batches=$(( (expected_count + 19) / 20 ))
  [ "$count" -eq "$expected_batches" ] \
    || fail "lint used $count batches for $expected_count files"
  while IFS= read -r line; do
    [ "$line" = '--norc|-x|-P|SCRIPTDIR|-S|warning|--' ] \
      || fail "lint changed ShellCheck flags: $line"
  done <"$args_file"
  pass "lint batches preserve flags, order, and complete coverage"
}

test_explicit_paths_remain_single_arguments() {
  local tmp fakebin count_file paths_file args_file output rc
  local -a observed_paths
  tmp=$(fm_test_tmproot fm-lint-paths)
  fakebin=$(fm_fakebin "$tmp")
  count_file="$tmp/count"
  paths_file="$tmp/paths"
  args_file="$tmp/args"
  : >"$count_file"
  : >"$paths_file"
  : >"$args_file"
  write_logging_shellcheck "$fakebin/shellcheck"

  rc=0
  output=$(
    FAKE_SHELLCHECK_COUNT="$count_file" \
      FAKE_SHELLCHECK_PATHS="$paths_file" \
      FAKE_SHELLCHECK_ARGS="$args_file" \
      PATH="$fakebin:$PATH" "$LINT" \
      "path with spaces.sh" "--path-looking-name.sh" 2>&1
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "explicit-path lint unexpectedly failed: $output"

  mapfile -d '' -t observed_paths <"$paths_file"
  [ "${#observed_paths[@]}" -eq 2 ] || fail "explicit paths were not both passed"
  [ "${observed_paths[0]}" = 'path with spaces.sh' ] \
    || fail "path with spaces was split"
  [ "${observed_paths[1]}" = '--path-looking-name.sh' ] \
    || fail "path beginning with a dash was changed"
  pass "lint passes explicit paths without word splitting"
}

test_batch_failure_propagates() {
  local tmp fakebin count_file paths_file output rc count
  tmp=$(fm_test_tmproot fm-lint-failure)
  fakebin=$(fm_fakebin "$tmp")
  count_file="$tmp/count"
  paths_file="$tmp/paths"
  : >"$count_file"
  : >"$paths_file"
  write_logging_shellcheck "$fakebin/shellcheck"
  cat >"$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = '--version' ]; then
  printf '%s\n' 'version: 0.11.0'
  exit 0
fi
count_file=${FAKE_SHELLCHECK_COUNT:?}
count=0
if [ -s "$count_file" ]; then
  count=$(sed -n '1p' "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
[ "$count" -ne 2 ] || exit 42
exit 0
SH
  chmod +x "$fakebin/shellcheck"

  rc=0
  output=$(
    FAKE_SHELLCHECK_COUNT="$count_file" \
      FAKE_SHELLCHECK_PATHS="$paths_file" \
      PATH="$fakebin:$PATH" "$LINT" 2>&1
  ) || rc=$?
  [ "$rc" -eq 42 ] || fail "lint did not propagate batch failure (rc=$rc): $output"
  count=$(sed -n '1p' "$count_file")
  [ "$count" = 2 ] || fail "lint continued after failed batch"
  pass "lint propagates a failed ShellCheck batch"
}

test_owner_and_gate_wiring
test_version_pin_and_rejection
test_batched_complete_coverage_and_flags
test_explicit_paths_remain_single_arguments
test_batch_failure_propagates
