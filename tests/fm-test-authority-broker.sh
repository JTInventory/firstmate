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
authority_checkout=$(cd "$(dirname "$authority_real")/.." 2>/dev/null && pwd -P) || exit 1
authority_home=$(cd "${FM_HOME:-$authority_checkout}" 2>/dev/null && pwd -P) || exit 1
authority_state=${FM_STATE_OVERRIDE:-$authority_home/state}

cleanup_primary_authority() {
  local record="$authority_state/.session-durable-authority"
  local authority="$authority_state/.session-authority"
  local pid start identity session session_start pgid tick current process_state
  local authority_pid authority_start authority_identity authority_token
  cleanup_primary_authority_fail() {
    printf 'error: test authority cleanup: %s\n' "$1" >&2
    return 1
  }
  durable_group_has_running_process() {
    local process_pid process_pgid process_stat
    while read -r process_pid process_pgid process_stat; do
      [ "$process_pgid" = "$pgid" ] || continue
      case "$process_stat" in
        Z*) ;;
        *) return 0 ;;
      esac
    done < <(ps -eo pid=,pgid=,stat= 2>/dev/null)
    return 1
  }
  [ "${FM_TEST_AUTHORITY_PROVISION_PRIMARY:-0}" = 1 ] || return 0
  [ -f "$authority_state/.primary-checkout" ] \
    && [ ! -L "$authority_state/.primary-checkout" ] \
    && [ "$(cat "$authority_state/.primary-checkout" 2>/dev/null)" = \
      "$authority_checkout" ] || return 0
  . "$authority_checkout/bin/fm-session-lock-lib.sh"
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] \
      || { cleanup_primary_authority_fail 'durable record is not a regular file'; return 1; }
    [ "$(wc -l < "$record" | tr -d ' ')" -eq 11 ] \
      && [ "$(sed -n '1p' "$record")" = version=3 ] \
      || { cleanup_primary_authority_fail 'durable record shape is invalid'; return 1; }
    record_hmac=$(sed -n '11s/^authority-hmac=//p' "$record")
    [ "${#record_hmac}" -eq 64 ] \
      && case "$record_hmac" in *[!0-9a-f]*) false ;; *) true ;; esac \
      || { cleanup_primary_authority_fail 'durable record hmac shape is invalid'; return 1; }
    [ "$(sed -n '2s/^pid=//p' "$record")" != '' ] \
      && pid=$(sed -n '2s/^pid=//p' "$record") \
      || { cleanup_primary_authority_fail 'durable pid is invalid'; return 1; }
    start=$(sed -n '3s/^start=//p' "$record")
    identity=$(sed -n '4s/^identity=//p' "$record")
    session=$(sed -n '5s/^session-pid=//p' "$record")
    session_start=$(sed -n '6s/^session-start=//p' "$record")
    case "$pid:$session" in
      ''|*[!0-9:]*|*:*:*)
        cleanup_primary_authority_fail 'durable process identity is invalid'
        return 1
        ;;
    esac
    [ -n "$start" ] && [ -n "$identity" ] && [ -n "$session_start" ] \
      || { cleanup_primary_authority_fail 'durable process identity is incomplete'; return 1; }
    [ "$(sed -n '7s/^home=//p' "$record")" = "$authority_home" ] \
      || { cleanup_primary_authority_fail 'durable home mismatch'; return 1; }
    [ "$(sed -n '8s/^checkout=//p' "$record")" = "$authority_checkout" ] \
      || { cleanup_primary_authority_fail 'durable checkout mismatch'; return 1; }
    current=$(fm_session_process_start "$pid" 2>/dev/null || true)
    if [ -n "$current" ]; then
      [ "$current" = "$start" ] \
        || { cleanup_primary_authority_fail 'durable process start mismatch'; return 1; }
      process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
      case "$process_state" in
        Z*) current= ;;
      esac
    fi
    if [ -n "$current" ]; then
      [ "$(fm_session_process_identity "$pid" 2>/dev/null || true)" = "$identity" ] \
        || { cleanup_primary_authority_fail 'durable process identity mismatch'; return 1; }
      fm_session_process_runs_script \
        "$pid" "$authority_checkout/bin/fm-session-durable-authority.sh" \
        || { cleanup_primary_authority_fail 'durable process script mismatch'; return 1; }
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') \
        || { cleanup_primary_authority_fail 'could not read durable process group'; return 1; }
      [ "$pgid" = "$pid" ] \
        || { cleanup_primary_authority_fail 'durable process group mismatch'; return 1; }
      kill -TERM -- "-$pgid" 2>/dev/null \
        || { cleanup_primary_authority_fail 'could not terminate durable process group'; return 1; }
      for ((tick = 0; tick < 100; tick++)); do
        durable_group_has_running_process || break
        sleep 0.01
      done
      if durable_group_has_running_process; then
        kill -KILL -- "-$pgid" 2>/dev/null \
          || { cleanup_primary_authority_fail 'could not kill durable process group'; return 1; }
        for ((tick = 0; tick < 100; tick++)); do
          durable_group_has_running_process || break
          sleep 0.01
        done
        durable_group_has_running_process \
          && { cleanup_primary_authority_fail 'durable process group survived teardown'; return 1; }
      fi
    fi
  fi
  if [ -e "$authority" ] || [ -L "$authority" ]; then
    [ -f "$authority" ] && [ ! -L "$authority" ] \
      || { cleanup_primary_authority_fail 'authority record is not a regular file'; return 1; }
    [ "$(wc -l < "$authority" | tr -d ' ')" -eq 8 ] \
      && [ "$(sed -n '1p' "$authority")" = version=2 ] \
      || { cleanup_primary_authority_fail 'authority record shape is invalid'; return 1; }
    authority_pid=$(sed -n '2s/^pid=//p' "$authority")
    authority_start=$(sed -n '3s/^start=//p' "$authority")
    authority_identity=$(sed -n '4s/^identity=//p' "$authority")
    authority_token=$(sed -n '5s/^token=//p' "$authority")
    case "$authority_pid" in ''|*[!0-9]*)
      cleanup_primary_authority_fail 'authority pid is invalid'
      return 1
      ;;
    esac
    [ -n "$authority_start" ] && [ -n "$authority_identity" ] \
      || { cleanup_primary_authority_fail 'authority process identity is incomplete'; return 1; }
    [ "${#authority_token}" -eq 64 ] \
      && case "$authority_token" in *[!0-9a-f]*) false ;; *) true ;; esac \
      || { cleanup_primary_authority_fail 'authority token shape is invalid'; return 1; }
    [ "$(sed -n '7s/^home=//p' "$authority")" = "$authority_home" ] \
      || { cleanup_primary_authority_fail 'authority home mismatch'; return 1; }
    [ "$(sed -n '8s/^checkout=//p' "$authority")" = "$authority_checkout" ] \
      || { cleanup_primary_authority_fail 'authority checkout mismatch'; return 1; }
    current=$(fm_session_process_start "$authority_pid" 2>/dev/null || true)
    if [ -n "$current" ]; then
      [ "$current" = "$authority_start" ] \
        || { cleanup_primary_authority_fail 'authority process start mismatch'; return 1; }
      [ "$(fm_session_process_identity "$authority_pid" 2>/dev/null || true)" = "$authority_identity" ] \
        || { cleanup_primary_authority_fail 'authority process identity mismatch'; return 1; }
      cleanup_primary_authority_fail 'authority process is still active'
      return 1
    fi
  fi
  rm -f "$authority_state"/.lock "$authority_state"/.primary-checkout \
    "$authority_state"/.session-durable-authority \
    "$authority_state"/.session-durable-authority.log \
    "$authority_state"/.session-durable-authority-transaction.lock \
    "$authority_state"/.session-authority \
    "$authority_state"/.session-authority-live \
    "$authority_state"/.session-authority-admission.lock \
    "$authority_state"/.session-authority-broker-recovery.lock \
    "$authority_state"/.session-authority-enrollment \
    "$authority_state"/.session-authority-enrollment.accepted.final \
    "$authority_state"/.session-authority-launch \
    "$authority_state"/.session-enrollment-stage.trace*
  rm -rf "$authority_state"/.session-durable-authority-requests \
    "$authority_state"/.session-authority-transaction
}

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
  broker_command='unset FM_TEST_AUTHORITY_PROVISION_PRIMARY; FM_TEST_AUTHORITY_BROKER_PID=$$ FM_TEST_AUTHORITY_OWNER_PID=$$; export FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID; exec /usr/bin/bash "$1" /usr/bin/bash "$2"'
  bash -c "$broker_command" fm-test-authority "$authority_real" "$fixture" &
else
  broker_command='unset FM_TEST_AUTHORITY_PROVISION_PRIMARY; FM_TEST_AUTHORITY_BROKER_PID=$$ FM_TEST_AUTHORITY_OWNER_PID=$$; export FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID; exec /usr/bin/bash "$1"'
  bash -c "$broker_command" fm-test-authority "$fixture" &
fi
broker_pid=$!
if [ -n "$broker_pid_file" ]; then
  printf '%s\n' "$broker_pid" > "$broker_pid_file"
fi
stop_broker_bounded() {
  local tick=0
  kill -TERM "$broker_pid" 2>/dev/null || true
  while [ "$tick" -lt 100 ] && kill -0 "$broker_pid" 2>/dev/null; do
    sleep 0.01
    tick=$((tick + 1))
  done
  if kill -0 "$broker_pid" 2>/dev/null; then
    kill -KILL "$broker_pid" 2>/dev/null || true
    tick=0
    while [ "$tick" -lt 100 ] && kill -0 "$broker_pid" 2>/dev/null; do
      sleep 0.01
      tick=$((tick + 1))
    done
  fi
  kill -0 "$broker_pid" 2>/dev/null && return 1
  wait "$broker_pid" 2>/dev/null || true
  return 0
}
handle_broker_signal() {
  local signal_status=0
  trap - HUP INT TERM
  stop_broker_bounded || signal_status=1
  cleanup_primary_authority || signal_status=1
  [ "$signal_status" -eq 0 ] || \
    printf '%s\n' 'error: test authority signal cleanup could not be proven' >&2
  exit 125
}
trap handle_broker_signal HUP INT TERM
broker_status=0
wait "$broker_pid" || broker_status=$?
trap - HUP INT TERM
cleanup_status=0
cleanup_primary_authority || cleanup_status=$?
[ "$cleanup_status" -eq 0 ] || \
  printf '%s\n' 'error: test authority cleanup could not be proven' >&2
[ "$broker_status" -ne 0 ] || [ "$cleanup_status" -eq 0 ] || broker_status=125
  exit "$broker_status"
