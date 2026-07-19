#!/usr/bin/env bash
# Behavior tests for bin/fm-run-behavior-tests.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-run-behavior-tests.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-behavior-tests)

make_fixture_root() {
  local fixture="$TMP_ROOT/$1"
  mkdir -p "$fixture/bin" "$fixture/tests"
  cp "$HELPER" "$fixture/bin/fm-run-behavior-tests.sh" \
    || fail "fixture could not copy the behavior-test runner"
  cat > "$fixture/bin/fm-no-mistakes-pr-target-guard.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'guard-ran\n' > "$FM_FIXTURE_OUTPUT_DIR/guard-ran"
SH
  cat > "$fixture/bin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-V" ]; then
  printf 'tmux fixture 0\n'
fi
SH
  chmod +x "$fixture/bin/fm-no-mistakes-pr-target-guard.sh" "$fixture/bin/tmux"

  for test_name in pass-a fail-b; do
    cat > "$fixture/tests/$test_name.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
name=$(basename "$0" .test.sh)
printf '%s\n' "$TMPDIR" > "$FM_FIXTURE_OUTPUT_DIR/$name.tmpdir"
printf '%s\n' "$GOTMPDIR" > "$FM_FIXTURE_OUTPUT_DIR/$name.gotmpdir"
[ -d "$TMPDIR" ] || exit 20
[ -d "$GOTMPDIR" ] || exit 21
[ -z "${FM_HOME:-}" ] || exit 22
# Ambient Herdr from a live captain pane must not leak into hermetic fixtures.
[ -z "${HERDR_ENV:-}" ] || exit 23
[ -z "${HERDR_PANE_ID:-}" ] || exit 24
[ -z "${HERDR_SESSION:-}" ] || exit 25
[ "${FM_BACKEND:-}" = tmux ] || exit 26
printf 'start\n' > "$FM_FIXTURE_OUTPUT_DIR/$name.started"
owns_active=0
if mkdir "$FM_FIXTURE_OUTPUT_DIR/active" 2>/dev/null; then
  owns_active=1
else
  printf 'overlap\n' > "$FM_FIXTURE_OUTPUT_DIR/parallel-overlap"
fi
sleep 0.15
printf 'end\n' > "$FM_FIXTURE_OUTPUT_DIR/$name.finished"
if [ "$owns_active" -eq 1 ]; then
  rmdir "$FM_FIXTURE_OUTPUT_DIR/active"
fi
case "$name" in
  fail-*)
    printf 'fixture failure\n' >&2
    exit 7
    ;;
esac
printf 'fixture pass\n'
SH
    chmod +x "$fixture/tests/$test_name.test.sh"
  done
  git -C "$fixture" init -q -b main
  git -C "$fixture" add .
  git -C "$fixture" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm fixture
  cat > "$fixture/tests/working-tree.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ -z "${FM_HOME:-}" ] || exit 22
[ -z "${HERDR_ENV:-}" ] || exit 23
[ "${FM_BACKEND:-}" = tmux ] || exit 26
printf 'working-tree fixture pass\n'
SH
  chmod +x "$fixture/tests/working-tree.test.sh"
  printf '%s\n' "$fixture"
}

run_fixture() {
  local fixture=$1 jobs=$2 output=$3 fixture_output
  fixture_output="$TMP_ROOT/$fixture-output-$jobs"
  mkdir -p "$fixture_output"
  set +e
  (
    cd "$fixture" || exit 1
    # Simulate launching the suite from inside a live Herdr pane: ambient
    # HERDR_* and a shared FM_HOME must not reach hermetic child tests.
    PATH="$fixture/bin:$PATH" \
      FM_TEST_JOBS="$jobs" \
      FM_HOME="$TMP_ROOT/shared-firstmate-home" \
      HERDR_ENV=1 \
      HERDR_SESSION=default \
      HERDR_PANE_ID=w9:p9 \
      HERDR_TAB_ID=w9:t9 \
      HERDR_WORKSPACE_ID=w9 \
      HERDR_SOCKET_PATH=/tmp/fake-herdr.sock \
      FM_FIXTURE_OUTPUT_DIR="$fixture_output" \
      bash "$fixture/bin/fm-run-behavior-tests.sh"
  ) >"$output" 2>&1
  local rc=$?
  set -u
  printf '%s\n' "$fixture_output"
  return "$rc"
}

test_parallel_isolation_and_failure_aggregation() {
  local fixture output fixture_output rc tmp_a tmp_b gotmp_a gotmp_b
  fixture=$(make_fixture_root parallel)
  output="$TMP_ROOT/parallel.out"
  set +e
  fixture_output=$(run_fixture "$fixture" 2 "$output")
  rc=$?
  set -u
  expect_code 1 "$rc" "parallel fixture run aggregates a failed test"
  assert_grep "PASS: tests/pass-a.test.sh" "$output" "parallel run did not report the passing fixture"
  assert_grep "PASS: tests/working-tree.test.sh" "$output" "parallel run omitted the untracked working-tree fixture"
  assert_grep "FAIL: tests/fail-b.test.sh (exit 7)" "$output" "parallel run did not report the failing fixture"
  assert_grep "1 test(s) failed" "$output" "parallel run did not summarize failures"
  [ -e "$fixture_output/guard-ran" ] || fail "parallel run did not execute the target guard"
  [ -e "$fixture_output/parallel-overlap" ] || fail "parallel run did not overlap fixture jobs"
  tmp_a=$(cat "$fixture_output/pass-a.tmpdir")
  tmp_b=$(cat "$fixture_output/fail-b.tmpdir")
  gotmp_a=$(cat "$fixture_output/pass-a.gotmpdir")
  gotmp_b=$(cat "$fixture_output/fail-b.gotmpdir")
  [ "$tmp_a" != "$tmp_b" ] || fail "parallel fixtures shared TMPDIR"
  [ "$gotmp_a" != "$gotmp_b" ] || fail "parallel fixtures shared GOTMPDIR"
  pass "behavior runner isolates parallel tests and aggregates failures"
}

test_serial_mode_remains_serial() {
  local fixture output fixture_output rc
  fixture=$(make_fixture_root serial)
  output="$TMP_ROOT/serial.out"
  set +e
  fixture_output=$(run_fixture "$fixture" 1 "$output")
  rc=$?
  set -u
  expect_code 1 "$rc" "serial fixture run still reports a failed test"
  assert_not_contains "$(cat "$fixture_output"/parallel-overlap 2>/dev/null || true)" "overlap" \
    "FM_TEST_JOBS=1 allowed fixture overlap"
  assert_grep "PASS: tests/pass-a.test.sh" "$output" "serial run did not report the passing fixture"
  assert_grep "PASS: tests/working-tree.test.sh" "$output" "serial run omitted the untracked working-tree fixture"
  assert_grep "FAIL: tests/fail-b.test.sh (exit 7)" "$output" "serial run did not report the failing fixture"
  pass "FM_TEST_JOBS=1 preserves serial fixture execution"
}

test_delta_overlay_contract_is_checked_and_portable() {
  local source
  source=$(cat "$HELPER")
  assert_not_contains "$source" 'sort -z' \
    "behavior runner must not depend on GNU-only sort -z"
  assert_contains "$source" 'if ! copy_worktree_delta' \
    "behavior runner must check the working-tree overlay result"
  assert_contains "$source" 'unset HERDR_ENV HERDR_SESSION HERDR_PANE_ID' \
    "behavior runner must scrub ambient Herdr pane markers"
  assert_contains "$source" 'export FM_BACKEND=tmux' \
    "behavior runner must pin hermetic jobs to tmux when FM_BACKEND is unset"
  pass "behavior runner checks its portable working-tree overlay"
}

test_lib_scrubs_ambient_herdr_for_hermetic_sources() {
  local out
  out=$(
    HERDR_ENV=1 HERDR_SESSION=default HERDR_PANE_ID=w1:p1 \
      bash -c '
        set -eu
        # Fresh shell: re-source lib with ambient Herdr set, as a single-file
        # test would when launched from a captain Herdr pane.
        FM_TEST_LIB_SOURCED=
        # shellcheck source=tests/lib.sh
        . "'"$ROOT"'/tests/lib.sh"
        [ -z "${HERDR_ENV:-}" ] || { echo "HERDR_ENV leaked"; exit 1; }
        [ -z "${HERDR_SESSION:-}" ] || { echo "HERDR_SESSION leaked"; exit 1; }
        [ -z "${HERDR_PANE_ID:-}" ] || { echo "HERDR_PANE_ID leaked"; exit 1; }
        [ "${FM_BACKEND:-}" = tmux ] || { echo "FM_BACKEND=${FM_BACKEND:-}"; exit 1; }
        echo ok
      '
  ) || fail "tests/lib.sh did not scrub ambient Herdr for hermetic sources: $out"
  [ "$out" = ok ] || fail "unexpected lib scrub output: $out"
  pass "tests/lib.sh scrubs ambient Herdr for hermetic single-file runs"
}

test_parallel_isolation_and_failure_aggregation
test_serial_mode_remains_serial
test_delta_overlay_contract_is_checked_and_portable
test_lib_scrubs_ambient_herdr_for_hermetic_sources
