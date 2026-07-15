#!/usr/bin/env bash
# Run every firstmate behavior test with bounded optional parallelism.
#
# FM_TEST_JOBS controls the number of test processes in flight. It defaults to
# min(4, nproc) and FM_TEST_JOBS=1 preserves the legacy serial loop. Every test
# receives a private TMPDIR and GOTMPDIR so temporary state cannot collide.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! bash "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh"; then
  printf '%s\n' 'FAIL: PR target guard rejected this checkout; tests were not started' >&2
  exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: tmux is required for e2e tests' >&2
  exit 1
fi
if ! tmux -V; then
  printf '%s\n' 'FAIL: tmux could not report its version' >&2
  exit 1
fi

default_jobs=1
cpu_count=
if command -v nproc >/dev/null 2>&1; then
  cpu_count=$(nproc 2>/dev/null || true)
elif command -v getconf >/dev/null 2>&1; then
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
fi
case "$cpu_count" in
  ''|*[!0-9]*) ;;
  0) ;;
  *)
    default_jobs=$cpu_count
    [ "$default_jobs" -le 4 ] || default_jobs=4
    ;;
esac

jobs=${FM_TEST_JOBS:-$default_jobs}
case "$jobs" in
  ''|*[!0-9]*)
    printf 'FAIL: FM_TEST_JOBS must be a positive integer (got %s)\n' "$jobs" >&2
    exit 1
    ;;
esac
if [ "$jobs" -lt 1 ]; then
  printf 'FAIL: FM_TEST_JOBS must be at least 1 (got %s)\n' "$jobs" >&2
  exit 1
fi

mapfile -t tests < <(compgen -G 'tests/*.test.sh' | sort)
if [ "${#tests[@]}" -eq 0 ]; then
  printf '%s\n' 'FAIL: no tests/*.test.sh files found' >&2
  exit 1
fi

base_tmp=${TMPDIR:-/tmp}
if ! mkdir -p "$base_tmp"; then
  printf 'FAIL: could not create temporary base %s\n' "$base_tmp" >&2
  exit 1
fi
suite_tmp=$(mktemp -d "$base_tmp/fm-behavior-tests.XXXXXX") || {
  printf 'FAIL: could not create an isolated behavior-test root\n' >&2
  exit 1
}
test_root="$suite_tmp/repo"
if ! git clone --quiet --no-hardlinks "$ROOT" "$test_root"; then
  printf 'FAIL: could not create a normal behavior-test clone\n' >&2
  exit 1
fi
cleanup() {
  rm -rf -- "$suite_tmp"
}
trap cleanup EXIT

mapfile -t tests < <(cd "$test_root" && compgen -G 'tests/*.test.sh' | sort)
total=${#tests[@]}
active_jobs=$jobs
[ "$active_jobs" -le "$total" ] || active_jobs=$total
printf 'Running %s behavior tests with %s parallel job(s)\n' "$total" "$active_jobs"

run_one() {
  local test_path=$1 job_root=$2 log_path=$3
  (
    cd "$test_root" || exit 1
    # A Firstmate supervisor may export its operational home into the shell that
    # launches this gate. Do not let tests share that live state; fixture tests
    # that need a home set their own FM_* overrides explicitly.
    unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
      FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
    unset NO_MISTAKES_GATE
    export TMPDIR="$job_root/tmp"
    export GOTMPDIR="$job_root/gotmp"
    bash "$test_path"
  ) >"$log_path" 2>&1
}

failed_count=0
index=0
while [ "$index" -lt "$total" ]; do
  pids=()
  batch_tests=()
  batch_logs=()
  batch_roots=()
  batch_count=0

  while [ "$index" -lt "$total" ] && [ "$batch_count" -lt "$active_jobs" ]; do
    test_path=${tests[$index]}
    test_name=${test_path##*/}
    test_id=${test_name%.test.sh}
    job_root="$suite_tmp/$test_id"
    log_path="$job_root/output.log"
    mkdir -p "$job_root/tmp" "$job_root/gotmp"
    printf 'START: %s (TMPDIR=%s GOTMPDIR=%s)\n' "$test_path" "$job_root/tmp" "$job_root/gotmp"
    run_one "$test_path" "$job_root" "$log_path" &
    pids+=("$!")
    batch_tests+=("$test_path")
    batch_logs+=("$log_path")
    batch_roots+=("$job_root")
    index=$((index + 1))
    batch_count=$((batch_count + 1))
  done

  for batch_index in "${!pids[@]}"; do
    test_rc=0
    wait "${pids[$batch_index]}" || test_rc=$?
    if [ "$test_rc" -eq 0 ]; then
      printf 'PASS: %s\n' "${batch_tests[$batch_index]}"
    else
      printf 'FAIL: %s (exit %s)\n' "${batch_tests[$batch_index]}" "$test_rc" >&2
      failed_count=$((failed_count + 1))
    fi
    if [ -s "${batch_logs[$batch_index]}" ]; then
      cat "${batch_logs[$batch_index]}"
    fi
  done
done

if [ "$failed_count" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failed_count" >&2
  exit 1
fi
printf 'All %s behavior tests passed\n' "$total"
