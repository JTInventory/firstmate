#!/usr/bin/env bash
# Behavior tests for bin/fm-run-behavior-tests.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-run-behavior-tests.sh"
JOB_HELPER="$ROOT/bin/fm-run-behavior-job.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-behavior-tests)

make_fixture_root() {
  local fixture="$TMP_ROOT/$1"
  mkdir -p "$fixture/bin" "$fixture/tests"
  cp "$HELPER" "$fixture/bin/fm-run-behavior-tests.sh" \
    || fail "fixture could not copy the behavior-test runner"
  cp "$ROOT/bin/fm-session-authority-exec.sh" \
    "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-procargs-lib.sh" "$fixture/bin/" \
    || fail "fixture could not copy the behavior authority broker"
  cp "$ROOT/bin/fm-run-behavior-job.sh" "$fixture/bin/" \
    || fail "fixture could not copy the behavior-test job helper"
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
fixture_root=$(cd "$(dirname "$0")/.." && pwd -P)
broker_script="$fixture_root/bin/fm-session-authority-exec.sh"
expected_broker_script="$TMPDIR/issuer-checkout/bin/fm-session-authority-exec.sh"
mkdir -p "${expected_broker_script%/*}"
cp "$broker_script" "$expected_broker_script"
case "${FM_TEST_AUTHORITY_BROKER_PID:-}" in
  ''|*[!0-9]*) exit 30 ;;
esac
env -u FM_TEST_PROCESS -u FM_TEST_AUTHORITY_FD \
  -u FM_TEST_DURABLE_AUTHORITY_FD -u FM_TEST_AUTHORITY_BROKER_PID \
  -u FM_TEST_AUTHORITY_OWNER_PID -u FM_TEST_SESSION_LOCK_STABLE_OWNER \
  bash -c '
    . "$1"
    fm_session_process_runs_authority_broker "$2" "$3"
  ' _ "$fixture_root/bin/fm-session-lock-lib.sh" \
  "$FM_TEST_AUTHORITY_BROKER_PID" "$expected_broker_script" || exit 31
printf '\n# byte-mismatch fixture\n' >> "$expected_broker_script"
if env -u FM_TEST_PROCESS -u FM_TEST_AUTHORITY_FD \
  -u FM_TEST_DURABLE_AUTHORITY_FD -u FM_TEST_AUTHORITY_BROKER_PID \
  -u FM_TEST_AUTHORITY_OWNER_PID -u FM_TEST_SESSION_LOCK_STABLE_OWNER \
  bash -c '
    . "$1"
    fm_session_process_runs_authority_broker "$2" "$3"
  ' _ "$fixture_root/bin/fm-session-lock-lib.sh" \
  "$FM_TEST_AUTHORITY_BROKER_PID" "$expected_broker_script"; then
  exit 32
fi
printf '%s\n' "$TMPDIR" > "$FM_FIXTURE_OUTPUT_DIR/$name.tmpdir"
printf '%s\n' "$GOTMPDIR" > "$FM_FIXTURE_OUTPUT_DIR/$name.gotmpdir"
[ -d "$TMPDIR" ] || exit 20
[ -d "$GOTMPDIR" ] || exit 21
[ -z "${FM_HOME:-}" ] || exit 22
if [ "${FM_EXPECT_AMBIENT:-0}" = 1 ]; then
  [ "${HERDR_ENV:-}" = 1 ] || exit 23
  [ "${HERDR_SESSION:-}" = default ] || exit 25
  [ "${HERDR_PANE_ID:-}" = w9:p9 ] || exit 24
  [ "${HERDR_TAB_ID:-}" = w9:t9 ] || exit 27
  [ "${HERDR_WORKSPACE_ID:-}" = w9 ] || exit 28
  [ "${HERDR_SOCKET_PATH:-}" = /tmp/fake-herdr.sock ] || exit 29
  [ -z "${FM_BACKEND:-}" ] || exit 26
else
  [ -z "${HERDR_ENV:-}" ] || exit 23
  [ -z "${HERDR_PANE_ID:-}" ] || exit 24
  [ -z "${HERDR_SESSION:-}" ] || exit 25
  [ -z "${HERDR_TAB_ID:-}" ] || exit 27
  [ -z "${HERDR_WORKSPACE_ID:-}" ] || exit 28
  [ -z "${HERDR_SOCKET_PATH:-}" ] || exit 29
  [ "${FM_BACKEND:-}" = tmux ] || exit 26
fi
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
if [ "${FM_EXPECT_AMBIENT:-0}" = 1 ]; then
  [ "${HERDR_ENV:-}" = 1 ] || exit 23
  [ "${HERDR_SESSION:-}" = default ] || exit 25
  [ "${HERDR_PANE_ID:-}" = w9:p9 ] || exit 24
  [ "${HERDR_TAB_ID:-}" = w9:t9 ] || exit 27
  [ "${HERDR_WORKSPACE_ID:-}" = w9 ] || exit 28
  [ "${HERDR_SOCKET_PATH:-}" = /tmp/fake-herdr.sock ] || exit 29
  [ -z "${FM_BACKEND:-}" ] || exit 26
else
  [ -z "${HERDR_ENV:-}" ] || exit 23
  [ -z "${HERDR_SESSION:-}" ] || exit 25
  [ -z "${HERDR_PANE_ID:-}" ] || exit 24
  [ -z "${HERDR_TAB_ID:-}" ] || exit 27
  [ -z "${HERDR_WORKSPACE_ID:-}" ] || exit 28
  [ -z "${HERDR_SOCKET_PATH:-}" ] || exit 29
  [ "${FM_BACKEND:-}" = tmux ] || exit 26
fi
printf 'working-tree fixture pass\n'
SH
  chmod +x "$fixture/tests/working-tree.test.sh"
  printf '%s\n' "$fixture"
}

run_fixture() {
  local fixture=$1 jobs=$2 output=$3 allow_ambient=${4:-0}
  local parallel_allowlist=${5:-} timeout_seconds=${6:-} path_override=${7:-}
  local force_root_failure=${8:-0} force_supervisor_failure=${9:-}
  local supervisor_pid_file=${10:-} root_pid_file=${11:-} fixture_output
  fixture_output="$TMP_ROOT/$fixture-output-$jobs"
  mkdir -p "$fixture_output"
  set +e
  (
    cd "$fixture" || exit 1
    # Simulate launching the suite from inside a live Herdr pane: ambient
    # HERDR_* and a shared FM_HOME must not reach hermetic child tests.
      PATH="${path_override:-$fixture/bin:$PATH}" \
      FM_TEST_JOBS="$jobs" \
      FM_TEST_PARALLEL_ALLOWLIST="$parallel_allowlist" \
      FM_TEST_TIMEOUT_SECONDS="$timeout_seconds" \
      FM_TEST_FORCE_ROOT_HANDLE_FAILURE="$force_root_failure" \
      FM_TEST_FORCE_SUPERVISOR_IDENTITY_FAILURE="$force_supervisor_failure" \
      FM_TEST_SUPERVISOR_PID_FILE="$supervisor_pid_file" \
      FM_TEST_ROOT_PID_FILE="$root_pid_file" \
      FM_HOME="$TMP_ROOT/shared-firstmate-home" \
      FM_BACKEND="" \
      HERDR_ENV=1 \
      HERDR_SESSION=default \
      HERDR_PANE_ID=w9:p9 \
      HERDR_TAB_ID=w9:t9 \
      HERDR_WORKSPACE_ID=w9 \
      HERDR_SOCKET_PATH=/tmp/fake-herdr.sock \
      FM_HERDR_ALLOW_AMBIENT="$allow_ambient" \
      FM_EXPECT_AMBIENT="$allow_ambient" \
      FM_FIXTURE_OUTPUT_DIR="$fixture_output" \
      bash "$fixture/bin/fm-run-behavior-tests.sh"
  ) >"$output" 2>&1
  local rc=$?
  set -u
  printf '%s\n' "$fixture_output"
  return "$rc"
}

test_runner_honors_ambient_opt_in() {
  local fixture output rc
  fixture=$(make_fixture_root ambient)
  output="$TMP_ROOT/ambient.out"
  set +e
  run_fixture "$fixture" 1 "$output" 1 >/dev/null
  rc=$?
  set -u
  expect_code 1 "$rc" "ambient opt-in fixture still reports its deliberate failure"
  assert_grep "PASS: tests/pass-a.test.sh" "$output" \
    "ambient opt-in did not preserve Herdr markers for a fixture"
  assert_grep "PASS: tests/working-tree.test.sh" "$output" \
    "ambient opt-in did not preserve Herdr markers for the working-tree fixture"
  assert_not_contains "$output" "exit 23" \
    "ambient opt-in scrubbed HERDR_ENV"
  assert_not_contains "$output" "exit 26" \
    "ambient opt-in forced FM_BACKEND"
  pass "behavior runner honors the ambient Herdr opt-in"
}

test_parallel_isolation_and_failure_aggregation() {
  local fixture output fixture_output rc tmp_a tmp_b gotmp_a gotmp_b
  fixture=$(make_fixture_root parallel)
  output="$TMP_ROOT/parallel.out"
  set +e
  fixture_output=$(run_fixture "$fixture" 2 "$output" 0 \
    'pass-a.test.sh,fail-b.test.sh,working-tree.test.sh')
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

test_parallel_mode_requires_an_explicit_allowlist() {
  local fixture output rc
  fixture=$(make_fixture_root parallel-requires-allowlist)
  output="$TMP_ROOT/parallel-requires-allowlist.out"
  set +e
  run_fixture "$fixture" 2 "$output" >/dev/null
  rc=$?
  set -u
  expect_code 1 "$rc" "parallel mode without an allowlist must refuse to start"
  assert_grep 'FM_TEST_JOBS above 1 requires FM_TEST_PARALLEL_ALLOWLIST' "$output" \
    "parallel mode did not require its isolation allowlist"
  pass "parallel behavior tests require an explicit isolation allowlist"
}

test_default_mode_is_serial() {
  local fixture output fixture_output rc
  fixture=$(make_fixture_root default-serial)
  output="$TMP_ROOT/default-serial.out"
  set +e
  fixture_output=$(run_fixture "$fixture" '' "$output")
  rc=$?
  set -u
  expect_code 1 "$rc" "default serial mode still reports a failed test"
  assert_not_contains "$(cat "$fixture_output"/parallel-overlap 2>/dev/null || true)" overlap \
    "the default behavior runner overlapped fixture jobs"
  pass "behavior tests default to serial execution"
}

test_each_behavior_test_has_a_hard_timeout() {
  local fixture output fixture_output fallback_bin tool target rc
  fixture=$(make_fixture_root timeout)
  cat > "$fixture/tests/double-fork-escape.sh" <<'SH'
#!/usr/bin/env bash
set -eu
setsid bash -c "setsid bash -c 'sleep 2; printf \"escaped\\n\" > \"\$FM_FIXTURE_OUTPUT_DIR/escaped-descendant-survived\"' & exit 0" &
SH
  chmod +x "$fixture/tests/double-fork-escape.sh"
  cat > "$fixture/tests/hang.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
(sleep 2; printf 'survived\n' > "$FM_FIXTURE_OUTPUT_DIR/descendant-survived") &
"$(cd "$(dirname "$0")" && pwd -P)/double-fork-escape.sh"
sleep 10
SH
  chmod +x "$fixture/tests/hang.test.sh"
  fallback_bin="$fixture/fallback-bin"
  mkdir -p "$fallback_bin"
  for tool in awk bash basename cat cp cut date dirname diff env git grep head \
    mkdir mkfifo mktemp od perl ps python3 readlink realpath rm rmdir sed setsid sleep \
    sort tail tmux tr wc; do
    target=$(command -v "$tool" || true)
    [ -n "$target" ] || fail "fallback timeout fixture could not find $tool"
    ln -s "$target" "$fallback_bin/$tool"
  done
  output="$TMP_ROOT/timeout.out"
  set +e
  fixture_output=$(run_fixture "$fixture" 1 "$output" 0 '' 1 "$fallback_bin")
  rc=$?
  set -u
  expect_code 1 "$rc" "a timed-out behavior test must fail the runner"
  assert_grep 'FAIL: tests/hang.test.sh (exit 124)' "$output" \
    "the behavior runner did not report its hard per-test timeout"
  sleep 2
  [ ! -e "$fixture_output/descendant-survived" ] \
    || fail "a timed-out behavior descendant survived process-group cleanup"
  [ ! -e "$fixture_output/escaped-descendant-survived" ] \
    || fail "a timed-out escaped descendant survived process-tree cleanup"
  pass "behavior tests have a hard per-test timeout"
}

test_bounded_runner_uses_stable_containment() {
  local source
  source=$(cat "$HELPER")
  assert_contains "$source" 'syscall($sys_prctl, 36, 1' \
    "bounded runner must establish child-subreaper containment"
  assert_contains "$source" '/proc/$parent/task/$parent/children' \
    "bounded runner must read kernel-owned child containment"
  assert_contains "$source" 'my $release_count = sysread($release_r, $release, 1)' \
    "bounded runner must hold the root before executing the test"
  assert_contains "$source" 'syswrite($release_w, "1") == 1' \
    "bounded runner must release a verified root handle"
  assert_contains "$source" 'syswrite($release_w, "0")' \
    "bounded runner must close the root gate after binding failure"
  assert_contains "$source" '[ -n "$SUPERVISOR_HANDLE_LAUNCHED_IDENTITY" ]' \
    "behavior runner must reject unknown supervisor identity"
  assert_contains "$source" 'my %tracked = ($pid => $root)' \
    "bounded runner must bind the root PID to a process handle"
  assert_contains "$source" 'syscall($sys_pidfd_open, $pid, 0)' \
    "bounded runner must open atomic process handles"
  assert_contains "$source" 'syscall($sys_pidfd_send_signal, $fd, $signal, 0, 0)' \
    "bounded runner must signal through process handles"
  assert_not_contains "$source" 'kill $signal, $tracked_pid' \
    "bounded runner must not signal tracked numeric PIDs"
  assert_contains "$source" 'waitpid(-1, WNOHANG)' \
    "bounded runner must reap adopted descendants"
  assert_contains "$source" 'RUNNING_TEST_PIDS+=("$test_id|$SUPERVISOR_HANDLE_LAUNCHED_PID|$SUPERVISOR_HANDLE_LAUNCHED_IDENTITY")' \
    "behavior runner must register every active supervisor"
  assert_contains "$source" 'signal_running_supervisor "$entry"' \
    "behavior runner must verify supervisors before signaling"
  assert_contains "$source" 'FM_TEST_SUPERVISOR_HANDLE_PERL' \
    "behavior runner must start a retained handle broker"
  assert_contains "$source" 'supervisor_handle_launch "$test_id" "$test_root/bin/fm-run-behavior-job.sh"' \
    "behavior runner must retain each supervisor pidfd before launch"
  assert_contains "$source" 'supervisor_handle_request "signal|$key"' \
    "behavior runner must signal supervisors through retained pidfds"
  assert_contains "$source" 'supervisor_handle_request "state|$key"' \
    "behavior runner must prove supervisor disappearance through retained pidfds"
  assert_contains "$source" 'supervisor_handle_request shutdown' \
    "behavior runner must shut down the retained handle broker"
  assert_not_contains "$source" 'supervisor_pidfd_action' \
    "behavior runner must not reopen supervisor pidfds during cleanup"
  assert_contains "$source" 'supervisor_handle_request "wait|$key"' \
    "behavior runner must reap supervisors through the retained handle broker"
  assert_contains "$source" ': >"$start_gate"' \
    "behavior runner must release the start gate only after handle acquisition"
  assert_not_contains "$source" 'run_one "$test_path"' \
    "behavior runner must not launch jobs through an unbound shell child"
  pass "bounded behavior tests use stable process containment"
}

test_fast_escape_after_test_exit_is_rejected() {
  local fixture output fixture_output rc
  fixture=$(make_fixture_root fast-escape)
  cat > "$fixture/tests/fast-escape.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
setsid bash -c "setsid bash -c 'sleep 2; printf \"escaped\\n\" > \"\$FM_FIXTURE_OUTPUT_DIR/fast-escaped-descendant\"' & exit 0" &
exit 0
SH
  chmod +x "$fixture/tests/fast-escape.test.sh"
  output="$TMP_ROOT/fast-escape.out"
  set +e
  fixture_output=$(run_fixture "$fixture" 1 "$output" 0 '' 1)
  rc=$?
  set -u
  expect_code 125 "$rc" "a fast escaped descendant must fail the runner closed"
  assert_grep 'FAIL: tests/fast-escape.test.sh (fail-closed exit 125)' "$output" \
    "the runner did not reject a descendant after the test exited"
  sleep 2
  [ ! -e "$fixture_output/fast-escaped-descendant" ] \
    || fail "a fast escaped descendant survived cleanup"
  pass "behavior tests reject escaped descendants after test exit"
}

assert_identity_gone() {
  local identity=$1 pid stat_line stat_fields current
  pid=${identity%%:*}
  if [ -r "/proc/$pid/stat" ]; then
    IFS= read -r stat_line <"/proc/$pid/stat" || fail "could not read recorded process identity"
    stat_fields=${stat_line##*) }
    set -- $stat_fields
    [ "$#" -ge 20 ] || fail "recorded process identity was malformed"
    current="$pid:${20}"
    [ "$current" != "$identity" ] || fail "recorded process identity survived cleanup"
  fi
}

test_failure_injection_refuses_before_launch() {
  local fixture output fixture_output rc sentinel_pid sentinel_marker supervisor_pid_file root_pid_file
  fixture=$(make_fixture_root root-handle-failure)
  output="$TMP_ROOT/root-handle-failure.out"
  sentinel_marker="$TMP_ROOT/root-handle-sentinel-term"
  supervisor_pid_file="$TMP_ROOT/root-handle-supervisor.identity"
  root_pid_file="$TMP_ROOT/root-handle-root.identity"
  (trap 'printf term > "$sentinel_marker"; exit 0' TERM; while :; do sleep 0.1; done) &
  sentinel_pid=$!
  set +e
  fixture_output=$(run_fixture "$fixture" 1 "$output" 0 '' 1 '' 1 0 "$supervisor_pid_file" "$root_pid_file")
  rc=$?
  set -u
  expect_code 125 "$rc" "root handle failure must refuse before launch"
  assert_not_contains "$output" 'PASS: tests/pass-a.test.sh' \
    "root handle failure launched a behavior test"
  [ ! -e "$fixture_output/pass-a.started" ] \
    || fail "root handle failure launched a fixture process"
  [ -s "$supervisor_pid_file" ] || fail "root handle failure did not record its supervisor"
  [ -s "$root_pid_file" ] || fail "root handle failure did not record its root"
  assert_identity_gone "$(cat "$supervisor_pid_file")"
  assert_identity_gone "$(cat "$root_pid_file")"
  [ ! -e "$sentinel_marker" ] \
    || fail "root handle failure signaled an unrelated process"
  kill -TERM "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true

  fixture=$(make_fixture_root supervisor-registration-failure)
  output="$TMP_ROOT/supervisor-registration-failure.out"
  sentinel_marker="$TMP_ROOT/supervisor-registration-sentinel-term"
  supervisor_pid_file="$TMP_ROOT/supervisor-registration-supervisor.identity"
  root_pid_file="$TMP_ROOT/supervisor-registration-root.identity"
  (trap 'printf term > "$sentinel_marker"; exit 0' TERM; while :; do sleep 0.1; done) &
  sentinel_pid=$!
  set +e
  fixture_output=$(run_fixture "$fixture" 1 "$output" 0 '' 1 '' 0 1 "$supervisor_pid_file" "$root_pid_file")
  rc=$?
  set -u
  expect_code 125 "$rc" "supervisor registration failure must refuse before launch"
  assert_not_contains "$output" 'PASS: tests/pass-a.test.sh' \
    "supervisor registration failure launched a behavior test"
  [ ! -e "$fixture_output/pass-a.started" ] \
    || fail "supervisor registration failure launched a fixture process"
  [ -s "$supervisor_pid_file" ] || fail "supervisor registration failure did not record its supervisor"
  assert_identity_gone "$(cat "$supervisor_pid_file")"
  [ ! -e "$root_pid_file" ] || fail "supervisor registration failure launched its root"
  [ ! -e "$sentinel_marker" ] \
    || fail "supervisor registration failure signaled an unrelated process"
  kill -TERM "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  pass "failure injection refuses before launching behavior tests"
}

test_pidfd_handles_do_not_follow_stale_pids() {
  if [ "$(uname -s)" != Linux ]; then
    pass "skip stale PID handle regression outside Linux"
    return
  fi
  perl <<'PERL' || fail "pidfd stale-handle regression failed"
use strict;
use warnings;
use Errno qw(ESRCH);
use POSIX qw(:sys_wait_h);
my $first = fork;
defined $first or die "first fork failed\n";
if (!$first) {
  sleep 1;
  exit 0;
}
my $fd = syscall(434, $first, 0);
defined $fd && $fd >= 0 or die "pidfd_open failed\n";
my $valid = syscall(424, $fd, 0, 0, 0);
defined $valid && $valid == 0 or die "pidfd_send_signal validity check failed\n";
kill "TERM", $first or die "first child signal failed\n";
waitpid($first, 0) == $first or die "first child reap failed\n";
my $second = fork;
defined $second or die "second fork failed\n";
if (!$second) {
  sleep 3;
  exit 0;
}
my $reused_slot = $first;
my %registry = ($reused_slot => $fd);
$registry{$reused_slot} = $second;
$registry{$reused_slot} == $second or die "numeric PID slot simulation failed\n";
my $sent = syscall(424, $fd, 15, 0, 0);
my $errno = 0 + $!;
defined $sent && $sent == -1 && $errno == ESRCH or die "stale pidfd did not return ESRCH\n";
kill 0, $second or die "replacement child did not survive\n";
kill "TERM", $second or die "replacement child cleanup failed\n";
waitpid($second, 0) == $second or die "replacement child reap failed\n";
POSIX::close($fd);
PERL
  pass "pidfd handles do not follow stale numeric PIDs"
}

test_gate_refusal_has_a_hard_timeout() {
  local fixture output started finished elapsed rc
  fixture=$(make_fixture_root gate-timeout)
  cat > "$fixture/tests/fm-gate-refuse.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'gate-started\n' > "$FM_FIXTURE_OUTPUT_DIR/gate-started"
sleep 10
SH
  chmod +x "$fixture/tests/fm-gate-refuse.test.sh"
  output="$TMP_ROOT/gate-timeout.out"
  started=$(date +%s)
  set +e
  run_fixture "$fixture" 1 "$output" 0 '' 1 >/dev/null
  rc=$?
  set -u
  finished=$(date +%s)
  elapsed=$((finished - started))
  expect_code 1 "$rc" "a timed-out gate-refusal test must fail the runner"
  assert_grep 'FAIL: gate-refusal test failed; tests were not started' "$output" \
    "the runner did not report the bounded gate-refusal failure"
  [ "$elapsed" -lt 5 ] || fail "the gate-refusal test exceeded its hard timeout: ${elapsed}s"
  pass "the gate-refusal test has a hard timeout"
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
  source=$(cat "$HELPER" "$JOB_HELPER")
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
    FM_BACKEND="" FM_HERDR_ALLOW_AMBIENT=0 \
      HERDR_ENV=1 HERDR_SESSION=default HERDR_PANE_ID=w1:p1 \
      HERDR_TAB_ID=w1:t1 HERDR_WORKSPACE_ID=w1 \
      HERDR_SOCKET_PATH=/tmp/fake-herdr.sock \
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
        [ -z "${HERDR_TAB_ID:-}" ] || { echo "HERDR_TAB_ID leaked"; exit 1; }
        [ -z "${HERDR_WORKSPACE_ID:-}" ] || { echo "HERDR_WORKSPACE_ID leaked"; exit 1; }
        [ -z "${HERDR_SOCKET_PATH:-}" ] || { echo "HERDR_SOCKET_PATH leaked"; exit 1; }
        [ "${FM_BACKEND:-}" = tmux ] || { echo "FM_BACKEND=${FM_BACKEND:-}"; exit 1; }
        echo ok
      '
  ) || fail "tests/lib.sh did not scrub ambient Herdr for hermetic sources: $out"
  [ "$out" = ok ] || fail "unexpected lib scrub output: $out"
  pass "tests/lib.sh scrubs ambient Herdr for hermetic single-file runs"
}

test_parallel_isolation_and_failure_aggregation
test_parallel_mode_requires_an_explicit_allowlist
test_default_mode_is_serial
test_each_behavior_test_has_a_hard_timeout
test_bounded_runner_uses_stable_containment
test_fast_escape_after_test_exit_is_rejected
test_failure_injection_refuses_before_launch
test_pidfd_handles_do_not_follow_stale_pids
test_gate_refusal_has_a_hard_timeout
test_serial_mode_remains_serial
test_delta_overlay_contract_is_checked_and_portable
test_lib_scrubs_ambient_herdr_for_hermetic_sources
test_runner_honors_ambient_opt_in
