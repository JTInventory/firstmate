#!/usr/bin/env bash

set -u

test_path=$1
job_root=$2
log_path=$3
start_gate=$4
abort_gate=$5
test_root=$6
test_timeout=$7
bounded_script=$8

(
  if [ -n "${FM_TEST_SUPERVISOR_PID_FILE:-}" ]; then
    supervisor_pid=$$
    IFS= read -r supervisor_stat <"/proc/$supervisor_pid/stat" || exit 125
    supervisor_fields=${supervisor_stat##*) }
    set -- $supervisor_fields
    [ "$#" -ge 20 ] || exit 125
    printf '%s:%s\n' "$supervisor_pid" "${20}" >"$FM_TEST_SUPERVISOR_PID_FILE" || exit 125
  fi
  for ((start_tick = 0; start_tick < 500; start_tick++)); do
    [ -f "$abort_gate" ] && exit 125
    [ -f "$start_gate" ] && break
    sleep 0.01
  done
  [ -f "$start_gate" ] || exit 125
  cd "$test_root" || exit 1
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
  if ! command -v perl >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: perl is required for child-subreaper timeout enforcement' >&2
    exit 125
  fi
  bounded_perl=$(<"$bounded_script") || exit 125
  exec perl -e "$bounded_perl" "$test_timeout" python3 - "$test_path" \
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
