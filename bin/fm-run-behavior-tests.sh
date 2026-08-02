#!/usr/bin/env bash
# Run every firstmate behavior test with bounded serial-by-default execution.
#
# FM_TEST_JOBS controls the number of test processes in flight. Values above one
# require FM_TEST_PARALLEL_ALLOWLIST to name isolated tests explicitly.

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

jobs=${FM_TEST_JOBS:-1}
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

test_timeout=${FM_TEST_TIMEOUT_SECONDS:-300}
case "$test_timeout" in
  ''|*[!0-9]*)
    printf 'FAIL: FM_TEST_TIMEOUT_SECONDS must be a positive integer (got %s)\n' "$test_timeout" >&2
    exit 1
    ;;
esac
if [ "$test_timeout" -lt 1 ] || [ "$test_timeout" -gt 900 ]; then
  printf 'FAIL: FM_TEST_TIMEOUT_SECONDS must be between 1 and 900 seconds (got %s)\n' "$test_timeout" >&2
  exit 1
fi

FM_TEST_BOUNDED_GROUP_PERL='
use Errno qw(ECHILD ESRCH);
use POSIX qw(:signal_h :sys_wait_h setpgid);
my $seconds = shift;
my $blocked = POSIX::SigSet->new(SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGCONT);
my $old = POSIX::SigSet->new();
defined(sigprocmask(SIG_BLOCK, $blocked, $old)) or exit 125;
pipe(my $ready_r, my $ready_w) or exit 125;
my $pid = fork;
defined($pid) or exit 125;
if (!$pid) {
  close $ready_r;
  setpgid(0, 0) == 0 or exit 125;
  syswrite($ready_w, "1") == 1 or exit 125;
  close $ready_w;
  defined(sigprocmask(SIG_SETMASK, $old)) or exit 125;
  exec @ARGV;
  exit 127;
}
close $ready_w;
my $ready = "";
my $ready_count = sysread($ready_r, $ready, 1);
close $ready_r;
if (!$ready_count) {
  my $waited = waitpid $pid, 0;
  my $status = $?;
  defined(sigprocmask(SIG_SETMASK, $old)) or exit 125;
  exit 125 if $waited < 0;
  exit(128 + ($status & 127)) if $status & 127;
  exit($status >> 8);
}
my %tracked = ($pid => 1);
my $tracking_ok = 1;
my $process_children = sub {
  my %children;
  open my $ps, "-|", "ps", "-axo", "pid=,ppid=" or return;
  while (my $line = <$ps>) {
    next if $line =~ /^\s*$/;
    $line =~ /^\s*(\d+)\s+(\d+)\s*$/ or return;
    push @{$children{$2}}, $1;
  }
  close $ps or return;
  return \%children;
};
my $refresh_tracked = sub {
  my $children = $process_children->();
  if (!$children) {
    $tracking_ok = 0;
    return;
  }
  my %seen = %tracked;
  my @queue = keys %tracked;
  while (@queue) {
    my $parent = shift @queue;
    for my $child (@{$children->{$parent} || []}) {
      next if exists $seen{$child};
      $seen{$child} = 1;
      $tracked{$child} = 1;
      push @queue, $child;
    }
  }
};
my $signal_tracked = sub {
  my $signal = shift;
  for my $tracked_pid (keys %tracked) {
    next if $tracked_pid == $$;
    kill $signal, $tracked_pid;
  }
};
my $group_gone = sub {
  for (1 .. 20) {
    my $probe = kill 0, -$pid;
    return 1 if !$probe && $!{ESRCH};
    return 0 if !$probe;
    select undef, undef, undef, 0.1;
  }
  return 0;
};
my $tracked_gone = sub {
  for my $tracked_pid (keys %tracked) {
    my $probe = kill 0, $tracked_pid;
    return 0 if $probe;
    return 0 if !$probe && !$!{ESRCH};
  }
  return 1;
};
my $stop = sub {
  my ($signal, $code) = @_;
  $refresh_tracked->();
  $SIG{ALRM} = $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = $SIG{TSTP} = $SIG{CONT} = "IGNORE";
  sigprocmask(SIG_BLOCK, $blocked);
  kill $signal, -$pid;
  $signal_tracked->($signal);
  select undef, undef, undef, 0.2;
  kill "KILL", -$pid;
  $signal_tracked->("KILL");
  my $waited = waitpid $pid, 0;
  my $wait_ok = $waited == $pid || ($waited < 0 && $!{ECHILD});
  exit 125 unless $wait_ok && $tracking_ok && $group_gone->() && $tracked_gone->();
  exit $code;
};
$SIG{ALRM} = sub { $stop->("TERM", 124) };
$SIG{HUP} = sub { $stop->("HUP", 129) };
$SIG{INT} = sub { $stop->("INT", 130) };
$SIG{QUIT} = sub { $stop->("QUIT", 131) };
$SIG{TERM} = sub { $stop->("TERM", 143) };
my $suspend;
$suspend = sub {
  kill "TSTP", -$pid;
  $SIG{TSTP} = "DEFAULT";
  kill "TSTP", $$;
  $SIG{TSTP} = $suspend;
};
$SIG{TSTP} = $suspend;
$SIG{CONT} = sub { kill "CONT", -$pid };
$refresh_tracked->();
alarm $seconds;
defined(sigprocmask(SIG_SETMASK, $old)) or exit 125;
my $waited = 0;
my $status = 0;
while (1) {
  $waited = waitpid $pid, WNOHANG;
  last if $waited == $pid || $waited < 0;
  $refresh_tracked->();
  select undef, undef, undef, 0.05;
}
if ($waited == $pid) {
  $status = $?;
}
alarm 0;
exit 125 if $waited < 0;
 $refresh_tracked->();
if (!$tracking_ok || !$group_gone->() || !$tracked_gone->()) {
  $stop->("TERM", 125);
}
exit(128 + ($status & 127)) if $status & 127;
exit($status >> 8);
'
run_bounded() {
  local seconds=$1
  shift
  local outer_seconds=$((seconds + 5))
  if ! command -v perl >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: perl is required for process-group timeout enforcement' >&2
    return 125
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$outer_seconds" perl -e "$FM_TEST_BOUNDED_GROUP_PERL" "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5 "$outer_seconds" perl -e "$FM_TEST_BOUNDED_GROUP_PERL" "$seconds" "$@"
  else
    perl -e "$FM_TEST_BOUNDED_GROUP_PERL" "$seconds" "$@"
  fi
}

mapfile -t tests < <(compgen -G 'tests/*.test.sh' | sort)
if [ "${#tests[@]}" -eq 0 ]; then
  printf '%s\n' 'FAIL: no tests/*.test.sh files found' >&2
  exit 1
fi

gate_test="$ROOT/tests/fm-gate-refuse.test.sh"
if [ -f "$gate_test" ] && ! run_bounded "$test_timeout" bash "$gate_test"; then
  printf '%s\n' 'FAIL: gate-refusal test failed; tests were not started' >&2
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
delta_manifest="$suite_tmp/worktree-delta"
if ! {
  git -C "$ROOT" diff --name-only -z HEAD &&
  git -C "$ROOT" ls-files --others --exclude-standard -z
} >"$delta_manifest"; then
  printf 'FAIL: could not enumerate current working-tree contents\n' >&2
  exit 1
fi
copy_worktree_delta() {
  local path src dst
  while IFS= read -r -d '' path; do
    src="$ROOT/$path"
    dst="$test_root/$path"
    if [ -e "$src" ] || [ -L "$src" ]; then
      mkdir -p "$(dirname "$dst")" || return 1
      rm -rf -- "$dst" || return 1
      cp -a -- "$src" "$dst" || return 1
    else
      rm -rf -- "$dst" || return 1
    fi
  done <"$delta_manifest"
}
if ! copy_worktree_delta; then
  printf 'FAIL: could not overlay current working-tree contents\n' >&2
  exit 1
fi
if [ -f "$test_root/bin/fm-gate-refuse-lib.sh" ]; then
  cat > "$test_root/bin/fm-gate-refuse-lib.sh" <<'SH'
FM_GATE_REFUSE_EXIT=3
fm_refuse_if_gate_agent() { return 0; }
SH
fi
cleanup() {
  rm -rf -- "$suite_tmp"
}
trap cleanup EXIT

mapfile -t tests < <(
  cd "$test_root" || exit 1
  for test_path in tests/*.test.sh; do
    [ -f "$test_path" ] || continue
    [ "$test_path" = tests/fm-gate-refuse.test.sh ] || printf '%s\n' "$test_path"
  done
)
total=${#tests[@]}
active_jobs=$jobs
[ "$active_jobs" -le "$total" ] || active_jobs=$total
parallel_allowlist_entries=()
parallel_allowlist=${FM_TEST_PARALLEL_ALLOWLIST:-}
if [ "$active_jobs" -gt 1 ]; then
  if [ -z "$parallel_allowlist" ]; then
    printf '%s\n' 'FAIL: FM_TEST_JOBS above 1 requires FM_TEST_PARALLEL_ALLOWLIST' >&2
    exit 1
  fi
  IFS=',' read -r -a parallel_allowlist_entries <<< "$parallel_allowlist"
  for allowlist_index in "${!parallel_allowlist_entries[@]}"; do
    entry=${parallel_allowlist_entries[$allowlist_index]}
    case "$entry" in
      tests/*.test.sh) entry=${entry#tests/} ;;
      *.test.sh) ;;
      *)
        printf 'FAIL: FM_TEST_PARALLEL_ALLOWLIST has an invalid test name: %s\n' "$entry" >&2
        exit 1
        ;;
    esac
    parallel_allowlist_entries[$allowlist_index]=$entry
    found=0
    for test_path in "${tests[@]}"; do
      [ "$test_path" = "tests/$entry" ] && found=1 && break
    done
    if [ "$found" -ne 1 ]; then
      printf 'FAIL: FM_TEST_PARALLEL_ALLOWLIST names a missing test: %s\n' "$entry" >&2
      exit 1
    fi
  done
fi
parallel_test_allowed() {
  local test_path=$1 entry
  for entry in "${parallel_allowlist_entries[@]}"; do
    [ "$test_path" = "tests/$entry" ] && return 0
  done
  return 1
}
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
    if [ "${FM_HERDR_ALLOW_AMBIENT:-0}" != 1 ]; then
      unset HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_TAB_ID \
        HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
      if [ -z "${FM_BACKEND:-}" ]; then
        export FM_BACKEND=tmux
      fi
    fi
    export TMPDIR="$job_root/tmp"
    export GOTMPDIR="$job_root/gotmp"
    run_bounded "$test_timeout" python3 - "$test_path" \
      "$test_root/bin/fm-session-authority-exec.sh" <<'PY'
import os
import socket
import sys
import threading

keys = {
    19: b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n",
    18: b"fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n",
}

writers = []
for target_fd, key in keys.items():
    reader, writer = socket.socketpair()
    os.dup2(reader.fileno(), target_fd)
    os.set_inheritable(target_fd, True)
    reader.close()
    writers.append((writer, key))

def serve(writer, key):
    while True:
        try:
            writer.sendall(key)
        except (BrokenPipeError, ConnectionResetError):
            return

for writer, key in writers:
    threading.Thread(target=serve, args=(writer, key), daemon=True).start()

env = os.environ.copy()
env["FM_TEST_AUTHORITY_FD"] = "19"
env["FM_TEST_DURABLE_AUTHORITY_FD"] = "18"
env["FM_TEST_PROCESS"] = "1"
env["FM_TEST_SESSION_LOCK_STABLE_OWNER"] = "1"
status = os.spawnve(
    os.P_WAIT,
    "/usr/bin/bash",
    [
        "bash",
        sys.argv[2],
        "--behavior-test-authority-broker",
        sys.argv[1],
    ],
    env,
)
for writer, _ in writers:
    writer.close()
sys.exit(status)
PY
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

  batch_limit=$active_jobs
  if [ "$active_jobs" -gt 1 ] && ! parallel_test_allowed "${tests[$index]}"; then
    batch_limit=1
  fi
  while [ "$index" -lt "$total" ] && [ "$batch_count" -lt "$batch_limit" ]; do
    test_path=${tests[$index]}
    if [ "$batch_limit" -gt 1 ] && ! parallel_test_allowed "$test_path"; then
      break
    fi
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
