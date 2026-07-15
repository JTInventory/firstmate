#!/usr/bin/env bash
# Portable process-group detachment for long-lived supervision processes.
# Source bin/fm-wake-lib.sh before this file.
#
# A harness-tracked background task may be reaped by SIGTERM to its whole
# process group. A plain child, nohup, or shell '&' remains in that group and
# dies with the task. These helpers put the long-lived process in its own
# session/process group, then let the caller follow it by pid.

fm_detach_spawn() {
  local output=$1 pid command marker=__fm_detach_launcher__
  shift
  [ "$#" -gt 0 ] || return 2
  command=$1
  if command -v setsid >/dev/null 2>&1; then
    pid=$(fm_detach_spawn_setsid "$output" "$marker" "$@") || return 1
  elif command -v perl >/dev/null 2>&1; then
    pid=$(fm_detach_spawn_perl "$output" "$marker" "$@") || return 1
  else
    printf '%s\n' 'fm_detach_spawn: cannot detach supervision: neither setsid(1) nor perl is available.' >&2
    printf '%s\n' 'fm_detach_spawn: install perl or util-linux (setsid(1)) before arming the watcher.' >&2
    return 127
  fi
  fm_detach_wait_for_exec "$pid" "$command" "$marker" || return 1
  printf '%s\n' "$pid"
}

fm_detach_wait_for_exec() {
  local pid=$1 command=$2 marker=$3 i=0
  while [ "$i" -lt 100 ]; do
    fm_pid_alive "$pid" || return 0
    fm_detach_process_is_execed "$pid" "$command" "$marker" && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

fm_detach_process_is_execed() {
  local pid=$1 command=$2 marker=$3 current
  current=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 2
  case "$current" in
    *"$command"*) ;;
    *) return 1 ;;
  esac
  case "$current" in
    *"$marker"*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_detach_spawn_setsid() {
  local output=$1 marker=$2 pidfile pid i
  shift 2
  pidfile=$(mktemp "${TMPDIR:-/tmp}/firstmate-detach.XXXXXX") || return 1
  # The inner shell writes its own pid after setsid has created the new session.
  # The short-lived launcher subshell exits immediately, so the target is
  # reparented instead of remaining a child that the arm would need to wait on.
  # shellcheck disable=SC2016 # $$ and $@ must expand in the detached shell.
  (
    setsid sh -c 'printf "%s\n" "$$" > "$1"; shift 2; exec "$@"' \
      fm-detach "$pidfile" "$marker" "$@" < /dev/null >>"$output" 2>&1 &
  )
  pid=
  i=0
  while [ "$i" -lt 100 ]; do
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  rm -f "$pidfile"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

fm_detach_spawn_perl() {
  local output=$1 marker=$2
  shift 2
  perl -e '
    use POSIX ();
    my $output = shift @ARGV;
    shift @ARGV;
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;
    if (!$pid) {
      POSIX::setsid() or die "setsid failed: $!\n";
      open(STDIN, "<", "/dev/null") or die "cannot open /dev/null: $!\n";
      open(STDOUT, ">>", $output) or die "cannot open $output: $!\n";
      open(STDERR, ">&", \*STDOUT) or die "cannot dup stderr: $!\n";
      exec { $ARGV[0] } @ARGV or die "exec failed: $!\n";
    }
    print "$pid\n";
  ' "$output" "$marker" "$@"
}

# Follow the process that was started, not whatever later reuses its pid.
fm_detach_follow() {
  local pid=$1 poll=${2:-0.5} start
  start=$(fm_pid_start "$pid") || return 0
  while fm_pid_alive "$pid" && [ "$(fm_pid_start "$pid")" = "$start" ]; do
    sleep "$poll"
  done
}

# Signal only a process whose start time still matches the pinned launch.
fm_detach_kill() {
  local pid=$1 start=${2:-} sig=${3:-TERM}
  [ -n "$start" ] || return 1
  fm_pid_start_is_cleanup_safe "$start" || return 1
  fm_pid_alive "$pid" || return 1
  fm_pid_start_matches_stored "$pid" "$start" || return 1
  kill -"$sig" "$pid" 2>/dev/null
}
