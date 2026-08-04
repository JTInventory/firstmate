#!/usr/bin/env bash
set -eu

[ "$#" -eq 3 ] && [ "$1" = --authority-script ] || exit 2
authority_script=$2
fixture=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
harness_script="$script_dir/fm-test-authority-broker.sh"
authority_real=$(cd "$(dirname "$authority_script")" 2>/dev/null && pwd -P)/$(basename "$authority_script") || exit 1
[ -f "$authority_real" ] && [ ! -L "$authority_real" ] || exit 1
[ -f "$fixture" ] && [ ! -L "$fixture" ] || exit 1
[ "${FM_TEST_PROCESS:-0}" = 1 ] || exit 1
[ "${FM_TEST_AUTHORITY_FD:-19}" = 19 ] \
  && [ "${FM_TEST_DURABLE_AUTHORITY_FD:-18}" = 18 ] || exit 1
if [ -d /proc/$$/fd ]; then
  [ -e /proc/$$/fd/19 ] && [ -e /proc/$$/fd/18 ] || exit 1
elif [ -d /dev/fd ]; then
  [ -e /dev/fd/19 ] && [ -e /dev/fd/18 ] || exit 1
else
  exit 1
fi
export FM_TEST_AUTHORITY_HARNESS=1
export FM_TEST_AUTHORITY_HARNESS_PID=$$
export FM_TEST_AUTHORITY_HARNESS_SCRIPT=$harness_script
export FM_TEST_AUTHORITY_EXEC_SCRIPT=$authority_real
broker_pid_file=${FM_TEST_AUTHORITY_BROKER_PID_FILE:-}
if [ "${FM_TEST_AUTHORITY_PROVISION_PRIMARY:-0}" = 1 ]; then
  if ( : <&9 ) 2>/dev/null || ( : >&9 ) 2>/dev/null; then
    exec 9<&-
  fi
  if ( : <&17 ) 2>/dev/null || ( : >&17 ) 2>/dev/null; then
    exec 17<&-
  fi
  if ( : <&18 ) 2>/dev/null || ( : >&18 ) 2>/dev/null; then
    exec 18<&-
  fi
  broker_command='FM_TEST_AUTHORITY_BROKER_PID=$$ FM_TEST_AUTHORITY_OWNER_PID=$$; export FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID; exec /usr/bin/bash "$1" "$2"'
  bash -c "$broker_command" fm-test-authority "$authority_real" "$fixture" &
else
  broker_command='FM_TEST_AUTHORITY_BROKER_PID=$$ FM_TEST_AUTHORITY_OWNER_PID=$$; export FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID; exec /usr/bin/bash "$1"'
  bash -c "$broker_command" fm-test-authority "$fixture" &
fi
broker_pid=$!
if [ -n "$broker_pid_file" ]; then
  printf '%s\n' "$broker_pid" > "$broker_pid_file"
fi
wait "$broker_pid"
