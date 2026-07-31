#!/usr/bin/env bash
# Shared session-lock authority.
# This file is sourced by scripts and has no side effects on source.

FM_HARNESS_RE='claude|codex|opencode|grok|^pi$'
_FM_SESSION_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_FM_SESSION_LOCK_LIB_DIR/fm-procargs-lib.sh"

fm_session_process_start() {
  local pid=$1 stat
  local -a fields=()
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*) }
    read -r -a fields <<< "$stat"
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf 'proc:%s\n' "${fields[19]}"
    return
  fi
  stat=$(LC_ALL=C ps -p "$pid" -o lstart= -o pgid= -o tty= 2>/dev/null) || return 1
  [ -n "$stat" ] || return 1
  printf 'ps:%s\n' "$(printf '%s\n' "$stat" | sed 's/^[[:space:]]*//')"
}

fm_session_process_identity() {
  local pid=$1 path
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -e "/proc/$pid/exe" ]; then
    path=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
  elif command -v lsof >/dev/null 2>&1; then
    path=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
      | sed -n 's/^n//p' | head -n 1) || return 1
  else
    return 1
  fi
  case "$path" in /*) printf 'exe:%s\n' "$path" ;; *) return 1 ;; esac
}

fm_session_parent_pid() {
  local pid=$1 stat state ppid
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*) }
    read -r state ppid _ <<< "$stat"
  else
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  fi
  case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ppid" -ge 1 ] || return 1
  printf '%s\n' "$ppid"
}

fm_session_darwin_getsid() {
  /usr/bin/perl -e '
    require "sys/syscall.ph";
    defined(&SYS_getsid) or exit 1;
    my $call = SYS_getsid();
    my $pid = int($ARGV[0]);
    my $sid = syscall($call, $pid);
    $sid >= 0 or exit 1;
    print "$sid\n";
  ' "$1" 2>/dev/null
}

fm_session_process_session_id() {
  local pid=$1 stat state ppid pgrp sid current parent
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*) }
    read -r state ppid pgrp sid _ <<< "$stat"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    sid=$(fm_session_darwin_getsid "$pid") || return 1
    case "$sid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$sid" -gt 1 ] || return 1
    current=$pid
    while [ "$current" -gt 1 ]; do
      [ "$current" != "$sid" ] || {
        printf '%s\n' "$sid"
        return
      }
      parent=$(fm_session_parent_pid "$current") || return 1
      [ "$parent" != "$current" ] || return 1
      current=$parent
    done
    return 1
  else
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  fi
  case "$sid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sid" -gt 1 ] || return 1
  printf '%s\n' "$sid"
}

fm_session_process_start_epoch() {
  local pid=$1 stat start ticks boot raw
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ] && [ -r /proc/stat ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*) }
    set -- $stat
    [ "$#" -ge 20 ] || return 1
    start=${20}
    ticks=$(getconf CLK_TCK 2>/dev/null) || return 1
    boot=$(sed -n 's/^btime //p' /proc/stat | head -n 1) || return 1
    case "$start:$ticks:$boot" in *[!0-9:]*|:*|*::*|*:) return 1 ;; esac
    [ "$ticks" -gt 0 ] || return 1
    printf '%s\n' "$((boot + start / ticks))"
    return
  fi
  raw=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  date -j -f '%a %b %e %T %Y' "$raw" '+%s' 2>/dev/null
}

fm_session_path_birth_epoch() {
  local path=$1 value
  [ -e "$path" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    value=$(stat -f '%B' "$path" 2>/dev/null) || return 1
  else
    value=$(stat -c '%W' "$path" 2>/dev/null) || return 1
  fi
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -gt 0 ] || return 1
  printf '%s\n' "$value"
}

fm_session_ancestry_reaches_session_leader() {
  local pid=$$ sid ppid
  sid=$(fm_session_process_session_id "$pid") || return 1
  [ "$sid" != "$pid" ] || return 1
  while [ "$pid" -gt 1 ]; do
    [ "$pid" != "$sid" ] || return 0
    ppid=$(fm_session_parent_pid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
  done
  return 1
}

fm_session_descriptor_identity() {
  local pid=$1 fd=$2 value
  if [ -e "/proc/$pid/fd/$fd" ]; then
    value=$(readlink "/proc/$pid/fd/$fd" 2>/dev/null) || return 1
  elif command -v lsof >/dev/null 2>&1; then
    value=$(lsof -a -p "$pid" -d "$fd" -Fn 2>/dev/null \
      | sed -n 's/^n//p' | head -n 1) || return 1
  else
    return 1
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_session_process_runs_script() {
  local pid=$1 script=$2 actual args
  if [ -r "/proc/$pid/cmdline" ]; then
    actual=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '2p') || return 1
    [ "$actual" = "$script" ]
    return
  fi
  args=$(ps -ww -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in *" $script"|*" $script "*) return 0 ;; *) return 1 ;; esac
}

fm_session_process_environment() {
  local pid=$1 value
  if [ -r "/proc/$pid/environ" ]; then
    value=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null ) || return 1
    [ -n "$value" ] || return 1
    printf '%s' "$value"
    return
  fi
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 1
  fm_procargs2_environ "$pid"
}

fm_session_process_environment_value() {
  local pid=$1 name=$2 env value count
  env=$(fm_session_process_environment "$pid") || return 1
  count=$(printf '%s\n' "$env" | sed -n "/^${name}=/p" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || return 1
  value=$(printf '%s\n' "$env" | sed -n "s/^${name}=//p")
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_session_process_argument_value() {
  local pid=$1 wanted=$2 item previous=
  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' item; do
      if [ "$previous" = "$wanted" ]; then
        printf '%s\n' "$item"
        return
      fi
      previous=$item
    done < "/proc/$pid/cmdline"
    return 1
  fi
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 1
  fm_procargs2_read "$pid" || return 1
  for item in "${FM_PROCARGS_ARGV[@]}"; do
    if [ "$previous" = "$wanted" ]; then
      printf '%s\n' "$item"
      return
    fi
    previous=$item
  done
  return 1
}

fm_session_random_hex() {
  local bytes=${1:-48} value
  case "$bytes" in ''|*[!0-9]*|0) return 1 ;; esac
  value=$(od -An -N "$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  [ "${#value}" -eq $((bytes * 2)) ] || return 1
  case "$value" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_session_sha256_file() {
  local file=$1 output digest
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  output=$(openssl dgst -sha256 "$file" 2>/dev/null) || return 1
  digest=${output##*= }
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$digest"
}

fm_session_hmac_pad() {
  local key=$1 pad=$2 index=0 byte value octal
  while [ "$index" -lt 64 ]; do
    if [ $((index * 2)) -lt "${#key}" ]; then
      byte=${key:$((index * 2)):2}
      value=$((16#$byte))
    else
      value=0
    fi
    octal=$(printf '%03o' $((value ^ pad))) || return 1
    printf "\\$octal" || return 1
    index=$((index + 1))
  done
}

fm_session_hmac_sha256_key() {
  local key=$1 inner output digest
  [ "${#key}" -ge 2 ] && [ "${#key}" -le 128 ] \
    && [ $(( ${#key} % 2 )) -eq 0 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  command -v openssl >/dev/null 2>&1 || return 1
  inner=$(
    set -o pipefail
    {
      fm_session_hmac_pad "$key" 54 || exit 1
      cat || exit 1
    } | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A
  ) || return 1
  output=$(
    set -o pipefail
    {
      fm_session_hmac_pad "$key" 92 || exit 1
      printf '%s' "$inner" | openssl base64 -d -A || exit 1
    } | openssl dgst -sha256 2>/dev/null
  ) || return 1
  digest=${output##*= }
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$digest"
}

fm_session_hmac_sha256_key_file() {
  local key_file=$1 key
  [ -r "$key_file" ] || return 1
  IFS= read -r key < "$key_file" || return 1
  fm_session_hmac_sha256_key "$key"
}

fm_session_authority_key_path() {
  local fd=${FM_SESSION_AUTHORITY_FD:-} path
  case "$fd" in ''|*[!0-9]*) return 1 ;; esac
  for path in "/dev/fd/$fd" "/proc/self/fd/$fd"; do
    [ -r "$path" ] || continue
    printf '%s\n' "$path"
    return
  done
  return 1
}

fm_session_authority_capability_present() {
  local key fd=${FM_SESSION_AUTHORITY_FD:-}
  if ! fm_session_descriptor_channel_isolated "$fd"; then
    fm_session_test_authority_broker_present || return 1
    FM_SESSION_AUTHORITY_FD=$FM_TEST_AUTHORITY_FD
    export FM_SESSION_AUTHORITY_FD
  fi
  fm_session_descriptor_channel_isolated \
    "${FM_SESSION_AUTHORITY_FD:-}" \
    && fm_session_exec_descriptor_isolation_durable || return 1
  IFS= read -r key <&"$FM_SESSION_AUTHORITY_FD" || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
}

fm_session_test_authority_broker_present() {
  local broker=${FM_TEST_AUTHORITY_BROKER_PID:-}
  local fd=${FM_TEST_DURABLE_AUTHORITY_FD:-} live_fd=${FM_TEST_AUTHORITY_FD:-}
  local caller_target broker_target
  [ "${FM_TEST_PROCESS:-0}" = 1 ] || return 1
  case "$broker" in ''|*[!0-9]*) return 1 ;; esac
  [ "$broker" != "$$" ] || return 1
  kill -0 "$broker" 2>/dev/null || return 1
  fm_session_descriptor_channel_isolated "$fd" || return 1
  caller_target=$(fm_session_descriptor_identity "$$" "$fd") || return 1
  broker_target=$(fm_session_descriptor_identity "$broker" "$fd") || return 1
  [ "$caller_target" = "$broker_target" ] || return 1
  if ! fm_session_descriptor_channel_isolated "$live_fd"; then
    case "$live_fd" in ''|*[!0-9]*) return 1 ;; esac
    eval "exec ${live_fd}<&${fd}"
  fi
  fm_session_descriptor_channel_isolated "$live_fd"
}

fm_session_process_runs_authority_broker() {
  local pid=$1 script=$2
  fm_session_process_runs_script "$pid" "$script" && return 0
  fm_session_test_authority_broker_present \
    && [ "$pid" = "$FM_TEST_AUTHORITY_BROKER_PID" ]
}

fm_session_authority_broker_present() {
  local script=$1 broker=${FM_SESSION_AUTHORITY_BROKER_PID:-}
  local start=${FM_SESSION_AUTHORITY_BROKER_START:-}
  local identity=${FM_SESSION_AUTHORITY_BROKER_IDENTITY:-}
  local current caller_target broker_target
  if fm_session_test_authority_broker_present \
    && { [ -z "${FM_SESSION_AUTHORITY_BROKER_PID:-}" ] \
      || [ "$FM_SESSION_AUTHORITY_BROKER_PID" = "$FM_TEST_AUTHORITY_BROKER_PID" ]; }; then
    if [ -n "${FM_SESSION_AUTHORITY_FD:-}" ]; then
      [ "$(fm_session_descriptor_identity "$$" \
          "$FM_SESSION_AUTHORITY_FD" 2>/dev/null || true)" = \
        "$(fm_session_descriptor_identity "$$" \
          "$FM_TEST_AUTHORITY_FD" 2>/dev/null || true)" ] || return 1
    fi
    if [ -n "${FM_SESSION_AUTHORITY_DURABLE_FD:-}" ]; then
      [ "$(fm_session_descriptor_identity "$$" \
          "$FM_SESSION_AUTHORITY_DURABLE_FD" 2>/dev/null || true)" = \
        "$(fm_session_descriptor_identity "$$" \
          "$FM_TEST_DURABLE_AUTHORITY_FD" 2>/dev/null || true)" ] || return 1
    fi
    FM_SESSION_AUTHORITY_FD=$FM_TEST_AUTHORITY_FD
    FM_SESSION_AUTHORITY_DURABLE_FD=$FM_TEST_DURABLE_AUTHORITY_FD
    FM_SESSION_AUTHORITY_BROKER_PID=$FM_TEST_AUTHORITY_BROKER_PID
    FM_SESSION_AUTHORITY_BROKER_START=$(
      fm_session_process_start "$FM_SESSION_AUTHORITY_BROKER_PID"
    ) || return 1
    FM_SESSION_AUTHORITY_BROKER_IDENTITY=$(
      fm_session_process_identity "$FM_SESSION_AUTHORITY_BROKER_PID"
    ) || return 1
    FM_SESSION_AUTHORITY_BROKER_SCRIPT=$script
    export FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
    export FM_SESSION_AUTHORITY_BROKER_PID FM_SESSION_AUTHORITY_BROKER_START
    export FM_SESSION_AUTHORITY_BROKER_IDENTITY FM_SESSION_AUTHORITY_BROKER_SCRIPT
    return 0
  fi
  fm_session_authority_capability_present || return 1
  case "$broker" in ''|*[!0-9]*) return 1 ;; esac
  [ "$broker" != "$$" ] || return 1
  fm_session_pid_is_current_ancestor "$broker" || return 1
  current=$(fm_session_process_start "$broker") || return 1
  [ "$current" = "$start" ] || return 1
  current=$(fm_session_process_identity "$broker") || return 1
  [ "$current" = "$identity" ] || return 1
  fm_session_process_runs_script "$broker" "$script" || return 1
  caller_target=$(fm_session_descriptor_identity \
    "$$" "$FM_SESSION_AUTHORITY_FD") || return 1
  broker_target=$(fm_session_descriptor_identity \
    "$broker" "$FM_SESSION_AUTHORITY_FD") || return 1
  [ "$caller_target" = "$broker_target" ]
}

fm_session_descriptor_channel_isolated() {
  local fd=$1 system parent=${BASHPID:-$$} opened=0 status=0
  case "$fd" in ''|*[!0-9]*) return 1 ;; esac
  system=$(uname -s 2>/dev/null) || return 1
  case "$system" in
    Darwin)
      return 0
      ;;
    Linux)
      if [ ! -e "/proc/$parent/fd/$fd" ]; then
        case "$fd" in
          7) exec 7</dev/null ;;
          8) exec 8</dev/null ;;
          9) exec 9</dev/null ;;
          10) exec 10</dev/null ;;
          16) exec 16</dev/null ;;
          17) exec 17</dev/null ;;
          18) exec 18</dev/null ;;
          19) exec 19</dev/null ;;
          *) return 1 ;;
        esac
        opened=1
      fi
      if [ ! -e "/proc/$parent/fd/$fd" ] \
        || (: < "/proc/$parent/fd/$fd") 2>/dev/null; then
        status=1
      fi
      if [ "$opened" -eq 1 ]; then
        case "$fd" in
          7) exec 7<&- ;;
          8) exec 8<&- ;;
          9) exec 9<&- ;;
          10) exec 10<&- ;;
          16) exec 16<&- ;;
          17) exec 17<&- ;;
          18) exec 18<&- ;;
          19) exec 19<&- ;;
        esac
      fi
      if [ "$status" -ne 0 ] && [ "$opened" -eq 0 ] \
        && [ "${FM_TEST_PROCESS:-0}" = 1 ]; then
        case "${FM_TEST_AUTHORITY_BROKER_PID:-}" in
          ''|*[!0-9]*) ;;
          *)
            if kill -0 "$FM_TEST_AUTHORITY_BROKER_PID" 2>/dev/null \
              && [ -e "/proc/$parent/fd/${FM_TEST_DURABLE_AUTHORITY_FD:-18}" ] \
              && [ "$(fm_session_descriptor_identity \
                "$parent" "${FM_TEST_DURABLE_AUTHORITY_FD:-18}" \
                2>/dev/null || true)" = \
                "$(fm_session_descriptor_identity \
                "$FM_TEST_AUTHORITY_BROKER_PID" \
                "${FM_TEST_DURABLE_AUTHORITY_FD:-18}" \
                2>/dev/null || true)" ]; then
              return 0
            fi
            ;;
        esac
      fi
      return "$status"
      ;;
    *)
      return 1
      ;;
  esac
}

fm_session_exec_descriptor_isolation_durable() {
  local system value
  system=$(uname -s 2>/dev/null) || return 1
  case "$system" in
    Darwin)
      return 0
      ;;
    Linux)
      [ -r /proc/sys/kernel/yama/ptrace_scope ] || return 1
      value=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null) || return 1
      case "$value" in ''|*[!0-9]*) return 1 ;; esac
      [ "$value" -ge 1 ]
      ;;
    *)
      return 1
      ;;
  esac
}

fm_session_authority_descriptor_create() {
  local key durable_key
  if ( : <&9 ) 2>/dev/null || ( : >&9 ) 2>/dev/null \
    || ( : <&18 ) 2>/dev/null || ( : >&18 ) 2>/dev/null; then
    return 1
  fi
  fm_session_exec_descriptor_isolation_durable || return 1
  key=$(fm_session_random_hex 48) || return 1
  durable_key=$(fm_session_random_hex 48) || return 1
  exec 9< <(while :; do printf '%s\n' "$key"; done) || return 1
  exec 18< <(while :; do printf '%s\n' "$durable_key"; done) || {
    exec 9<&-
    return 1
  }
  unset key durable_key
  fm_session_descriptor_channel_isolated 9 \
    && fm_session_descriptor_channel_isolated 18 || {
      exec 9<&-
      exec 18<&-
      return 1
    }
  FM_SESSION_AUTHORITY_FD=9
  FM_SESSION_AUTHORITY_DURABLE_FD=18
}

fm_session_authority_live_descriptor_rotate() {
  local key
  fm_session_authority_durable_capability_present || return 1
  if ( : <&9 ) 2>/dev/null || ( : >&9 ) 2>/dev/null; then
    return 1
  fi
  fm_session_exec_descriptor_isolation_durable || return 1
  key=$(fm_session_random_hex 48) || return 1
  exec 9< <(while :; do printf '%s\n' "$key"; done) || return 1
  unset key
  fm_session_descriptor_channel_isolated 9 || {
    exec 9<&-
    return 1
  }
  FM_SESSION_AUTHORITY_FD=9
}

fm_session_authority_durable_descriptor_adopt() {
  local key
  [ -z "${FM_SESSION_AUTHORITY_DURABLE_FD:-}" ] || return 1
  if ( : <&18 ) 2>/dev/null || ( : >&18 ) 2>/dev/null; then
    return 1
  fi
  fm_session_authority_capability_present \
    && fm_session_exec_descriptor_isolation_durable || return 1
  IFS= read -r key <&"$FM_SESSION_AUTHORITY_FD" || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  exec 18< <(while :; do printf '%s\n' "$key"; done) || return 1
  unset key
  fm_session_descriptor_channel_isolated 18 || {
    exec 18<&-
    return 1
  }
  FM_SESSION_AUTHORITY_DURABLE_FD=18
}

fm_session_durable_consumer_prepare() {
  local private public output digest
  if ( : <&16 ) 2>/dev/null || ( : >&16 ) 2>/dev/null; then
    return 1
  fi
  fm_session_exec_descriptor_isolation_durable || return 1
  private=$(openssl genpkey -algorithm RSA \
    -pkeyopt rsa_keygen_bits:2048 2>/dev/null) || return 1
  public=$(printf '%s\n' "$private" | openssl pkey -pubout 2>/dev/null) \
    || return 1
  output=$(printf '%s\n' "$public" | openssl dgst -sha256 2>/dev/null) \
    || return 1
  digest=${output##*= }
  [ "${#digest}" -eq 64 ] || return 1
  exec 16< <(printf '%s\n' "$private") || return 1
  unset private
  fm_session_descriptor_channel_isolated 16 || {
    exec 16<&-
    return 1
  }
  FM_SESSION_DURABLE_CONSUMER_PRIVATE_FD=16
  FM_SESSION_DURABLE_CONSUMER_PUBLIC=$(printf '%s\n' "$public" \
    | openssl base64 -A) || return 1
  FM_SESSION_DURABLE_CONSUMER_SHA256=$digest
  FM_SESSION_DURABLE_RECOVERY_NONCE=$(fm_session_random_hex 32) || return 1
  export FM_SESSION_DURABLE_CONSUMER_PRIVATE_FD
  export FM_SESSION_DURABLE_CONSUMER_PUBLIC
  export FM_SESSION_DURABLE_CONSUMER_SHA256
  export FM_SESSION_DURABLE_RECOVERY_NONCE
}

fm_session_durable_custodian_read() {
  local file=$1 current
  [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(wc -l < "$file" | tr -d ' ')" -eq 11 ] \
    && [ "$(sed -n '1p' "$file")" = version=3 ] || return 1
  FM_SESSION_DURABLE_CUSTODIAN_PID=$(sed -n '2s/^pid=//p' "$file")
  FM_SESSION_DURABLE_CUSTODIAN_START=$(sed -n '3s/^start=//p' "$file")
  FM_SESSION_DURABLE_CUSTODIAN_IDENTITY=$(sed -n '4s/^identity=//p' "$file")
  FM_SESSION_DURABLE_CUSTODIAN_SESSION=$(sed -n '5s/^session-pid=//p' "$file")
  FM_SESSION_DURABLE_CUSTODIAN_SESSION_START=$(
    sed -n '6s/^session-start=//p' "$file"
  )
  FM_SESSION_DURABLE_CUSTODIAN_HOME=$(sed -n '7s/^home=//p' "$file")
  FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT=$(sed -n '8s/^checkout=//p' "$file")
  FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_KEY=$(
    sed -n '9s/^custodian-public-key=//p' "$file"
  )
  FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_SHA256=$(
    sed -n '10s/^custodian-public-key-sha256=//p' "$file"
  )
  case "$FM_SESSION_DURABLE_CUSTODIAN_PID:$FM_SESSION_DURABLE_CUSTODIAN_SESSION" in
    *[!0-9:]*|:) return 1 ;;
  esac
  case "$FM_SESSION_DURABLE_CUSTODIAN_START:$FM_SESSION_DURABLE_CUSTODIAN_IDENTITY:$FM_SESSION_DURABLE_CUSTODIAN_SESSION_START:$FM_SESSION_DURABLE_CUSTODIAN_HOME:$FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT:$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_KEY:$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_SHA256" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$FM_SESSION_DURABLE_CUSTODIAN_START" ] \
    && [ -n "$FM_SESSION_DURABLE_CUSTODIAN_IDENTITY" ] \
    && [ -n "$FM_SESSION_DURABLE_CUSTODIAN_SESSION_START" ] \
    && [ -n "$FM_SESSION_DURABLE_CUSTODIAN_HOME" ] \
    && [ -n "$FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT" ] \
    && fm_session_enrollment_public_key_validate \
      "$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_KEY" \
      "$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_SHA256" \
    && [ "$(fm_session_process_argument_value \
      "$FM_SESSION_DURABLE_CUSTODIAN_PID" --custodian-public-key)" \
      = "$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_KEY" ] \
    && [ "$(fm_session_process_argument_value \
      "$FM_SESSION_DURABLE_CUSTODIAN_PID" --custodian-public-key-sha256)" \
      = "$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_SHA256" ] || return 1
  current=$(fm_session_process_start \
    "$FM_SESSION_DURABLE_CUSTODIAN_PID") || return 1
  [ "$current" = "$FM_SESSION_DURABLE_CUSTODIAN_START" ] \
    && [ "$(fm_session_process_identity \
      "$FM_SESSION_DURABLE_CUSTODIAN_PID" 2>/dev/null)" \
      = "$FM_SESSION_DURABLE_CUSTODIAN_IDENTITY" ] \
    && [ "$(fm_session_process_start \
      "$FM_SESSION_DURABLE_CUSTODIAN_SESSION" 2>/dev/null)" \
      = "$FM_SESSION_DURABLE_CUSTODIAN_SESSION_START" ]
}

fm_session_durable_custodian_validate() {
  local file=$1
  fm_session_durable_custodian_read "$file" \
    && fm_session_authority_record_validate "$file" 11
}

fm_session_durable_custodian_broker_authorized() {
  local checkout=$1 script="$1/bin/fm-session-authority-exec.sh"
  local start identity
  [ "${FM_SESSION_AUTHORITY_BROKER_PID:-}" = "$$" ] \
    && [ "${FM_SESSION_AUTHORITY_BROKER_SCRIPT:-}" = "$script" ] \
    && fm_session_process_runs_script "$$" "$script" || return 1
  start=$(fm_session_process_start "$$") || return 1
  identity=$(fm_session_process_identity "$$") || return 1
  [ "${FM_SESSION_AUTHORITY_BROKER_START:-}" = "$start" ] \
    && [ "${FM_SESSION_AUTHORITY_BROKER_IDENTITY:-}" = "$identity" ]
}

fm_session_durable_custodian_launch_write() {
  local file=$1 pid=$2 start=$3 identity=$4 state=$5 home=$6 checkout=$7
  local session=$8 session_start=$9 public=${10} public_digest=${11}
  local broker=${12} broker_start=${13} broker_identity=${14}
  local broker_script=${15}
  local body live_hmac durable_hmac tmp
  case "$pid:$start:$identity:$state:$home:$checkout:$session:$session_start:$public:$public_digest:$broker:$broker_start:$broker_identity:$broker_script" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  body=$(printf 'version=3\npid=%s\nstart=%s\nidentity=%s\nstate=%s\nhome=%s\ncheckout=%s\nsession-pid=%s\nsession-start=%s\ncustodian-public-key=%s\ncustodian-public-key-sha256=%s\nbroker-pid=%s\nbroker-start=%s\nbroker-identity=%s\nbroker-script=%s\n' \
    "$pid" "$start" "$identity" "$state" "$home" "$checkout" "$session" \
    "$session_start" "$public" "$public_digest" "$broker" "$broker_start" \
    "$broker_identity" "$broker_script") \
    || return 1
  body="${body}"$'\n'
  live_hmac=$(printf '%s' "$body" | fm_session_authority_hmac) || return 1
  durable_hmac=$(printf '%s' "$body" | fm_session_authority_durable_hmac) \
    || return 1
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  chmod 600 "$tmp" \
    && printf '%slive-authority-hmac=%s\ndurable-authority-hmac=%s\n' \
      "$body" "$live_hmac" "$durable_hmac" > "$tmp" \
    && mv "$tmp" "$file" || {
      rm -f "$tmp"
      return 1
    }
}

fm_session_durable_custodian_challenge() {
  local state=$1 custodian=$2 custodian_start=$3 nonce requests request response
  local start body response_body actual expected tmp attempts=0
  nonce=$(fm_session_random_hex 32) || return 1
  start=$(fm_session_process_start "$$") || return 1
  requests="$state/.session-durable-authority-requests"
  request="$requests/$nonce.challenge"
  response="${request}.response"
  [ -d "$requests" ] && [ ! -L "$requests" ] \
    && [ ! -e "$request" ] && [ ! -L "$request" ] \
    && [ ! -e "$response" ] && [ ! -L "$response" ] || return 1
  tmp=$(mktemp "${request}.XXXXXX") || return 1
  body=$(printf 'version=1\nnonce=%s\ncustodian-pid=%s\ncustodian-start=%s\nrequester-pid=%s\nrequester-start=%s\n' \
    "$nonce" "$custodian" "$custodian_start" "$$" "$start") || return 1
  body="${body}"$'\n'
  printf '%s' "$body" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$request" || {
      rm -f "$tmp"
      return 1
    }
  while [ "$attempts" -lt 100 ]; do
    [ ! -f "$response" ] || break
    kill -0 "$custodian" 2>/dev/null || {
      rm -f "$request" "$response"
      return 1
    }
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$response" ] && [ ! -L "$response" ] \
    && [ "$(wc -l < "$response" | tr -d ' ')" -eq 7 ] || {
      rm -f "$request" "$response"
      return 1
    }
  response_body=$(sed -n '1,6p' "$response")$'\n'
  [ "$response_body" = "$body" ] || {
    rm -f "$request" "$response"
    return 1
  }
  actual=$(sed -n '7s/^authority-hmac=//p' "$response")
  expected=$(printf '%s' "$body" | fm_session_authority_durable_hmac) || {
    rm -f "$request" "$response"
    return 1
  }
  rm -f "$request" "$response"
  [ "$actual" = "$expected" ]
}

fm_session_durable_custodian_candidate_challenge() {
  local state=$1 custodian=$2 custodian_start=$3 key=$4 public=$5 digest=$6
  local nonce requests request response start body response_body actual expected
  local tmp attempts=0 signature public_file signature_file body_file status
  nonce=$(fm_session_random_hex 32) || return 1
  start=$(fm_session_process_start "$$") || return 1
  requests="$state/.session-durable-authority-requests"
  request="$requests/$nonce.recovery-challenge"
  response="${request}.response"
  [ -d "$requests" ] && [ ! -L "$requests" ] \
    && [ ! -e "$request" ] && [ ! -L "$request" ] \
    && [ ! -e "$response" ] && [ ! -L "$response" ] || return 1
  body=$(printf 'version=1\nnonce=%s\ncustodian-pid=%s\ncustodian-start=%s\nrequester-pid=%s\nrequester-start=%s\n' \
    "$nonce" "$custodian" "$custodian_start" "$$" "$start") || return 1
  body="${body}"$'\n'
  tmp=$(mktemp "${request}.XXXXXX") || return 1
  printf '%s' "$body" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$request" || {
      rm -f "$tmp"
      return 1
    }
  while [ "$attempts" -lt 100 ]; do
    [ ! -f "$response" ] || break
    kill -0 "$custodian" 2>/dev/null || {
      rm -f "$request" "$response"
      return 1
    }
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$response" ] && [ ! -L "$response" ] \
    && [ "$(wc -l < "$response" | tr -d ' ')" -eq 8 ] || {
      rm -f "$request" "$response"
      return 1
    }
  response_body=$(sed -n '1,6p' "$response")$'\n'
  signature=$(sed -n '7s/^custodian-signature=//p' "$response")
  actual=$(sed -n '8s/^authority-hmac=//p' "$response")
  expected=$(printf '%s' "$body" | fm_session_hmac_sha256_key "$key") || {
    rm -f "$request" "$response"
    return 1
  }
  rm -f "$request" "$response"
  [ "$response_body" = "$body" ] && [ "$actual" = "$expected" ] || return 1
  public_file=$(mktemp "${TMPDIR:-/tmp}/fm-custodian-public.XXXXXX") \
    || return 1
  signature_file=$(mktemp "${TMPDIR:-/tmp}/fm-custodian-signature.XXXXXX") \
    || { rm -f "$public_file"; return 1; }
  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-custodian-body.XXXXXX") || {
    rm -f "$public_file" "$signature_file"
    return 1
  }
  status=1
  if printf '%s' "$public" | openssl base64 -d -A \
      > "$public_file" 2>/dev/null \
    && [ "$(fm_session_sha256_file "$public_file")" = "$digest" ] \
    && printf '%s' "$signature" | openssl base64 -d -A \
      > "$signature_file" 2>/dev/null \
    && printf '%s' "$body" > "$body_file" \
    && openssl dgst -sha256 -verify "$public_file" \
      -signature "$signature_file" "$body_file" >/dev/null 2>&1; then
    status=0
  fi
  rm -f "$public_file" "$signature_file" "$body_file"
  return "$status"
}

fm_session_durable_custodian_ensure_locked() {
  local state=$1 home=$2 checkout=$3 record script session session_start pid
  local attempts=0 log launch start identity private public output digest key
  record="$state/.session-durable-authority"
  script="$checkout/bin/fm-session-durable-authority.sh"
  fm_session_durable_custodian_broker_authorized "$checkout" || return 1
  if fm_session_durable_custodian_validate "$record" \
    && [ "$FM_SESSION_DURABLE_CUSTODIAN_HOME" = "$home" ] \
    && [ "$FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT" = "$checkout" ] \
    && fm_session_process_runs_script \
      "$FM_SESSION_DURABLE_CUSTODIAN_PID" "$script" \
    && fm_session_durable_custodian_challenge \
      "$state" "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
      "$FM_SESSION_DURABLE_CUSTODIAN_START"; then
    return 0
  fi
  fm_session_authority_durable_capability_present || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    if fm_session_durable_custodian_read "$record" \
      && [ "$FM_SESSION_DURABLE_CUSTODIAN_HOME" = "$home" ] \
      && [ "$FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT" = "$checkout" ] \
      && fm_session_process_runs_script \
        "$FM_SESSION_DURABLE_CUSTODIAN_PID" "$script"; then
      IFS= read -r key <&"$FM_SESSION_AUTHORITY_DURABLE_FD" || return 1
      fm_session_durable_custodian_candidate_challenge \
        "$state" "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
        "$FM_SESSION_DURABLE_CUSTODIAN_START" "$key" \
        "$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_KEY" \
        "$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_SHA256" || {
          unset key
          return 1
        }
      unset key
      attempts=0
      while [ "$attempts" -lt 100 ]; do
        fm_session_durable_custodian_validate "$record" \
          && fm_session_durable_custodian_challenge \
            "$state" "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
            "$FM_SESSION_DURABLE_CUSTODIAN_START" \
          && return 0
        sleep 0.02
        attempts=$((attempts + 1))
      done
      return 1
    else
      fm_session_authority_record_validate "$record" 11 || return 1
    fi
    rm -f "$record" || return 1
  fi
  session=$(fm_session_process_session_id "$$") || return 1
  session_start=$(fm_session_process_start "$session") || return 1
  if ( : <&17 ) 2>/dev/null || ( : >&17 ) 2>/dev/null; then
    return 1
  fi
  fm_session_exec_descriptor_isolation_durable || return 1
  private=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null) \
    || return 1
  public=$(printf '%s\n' "$private" | openssl ec -pubout 2>/dev/null) \
    || return 1
  output=$(printf '%s\n' "$public" | openssl dgst -sha256 2>/dev/null) \
    || return 1
  digest=${output##*= }
  [ "${#digest}" -eq 64 ] || return 1
  public=$(printf '%s\n' "$public" | openssl base64 -A) || return 1
  exec 17< <(printf '%s\n' "$private") || return 1
  unset private
  fm_session_descriptor_channel_isolated 17 \
    && fm_session_exec_descriptor_isolation_durable || {
      exec 17<&-
      return 1
    }
  log="$state/.session-durable-authority.log"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$script" "$state" "$home" "$checkout" "$session" "$session_start" \
      --broker-pid "$FM_SESSION_AUTHORITY_BROKER_PID" \
      --broker-start "$FM_SESSION_AUTHORITY_BROKER_START" \
      --broker-identity "$FM_SESSION_AUTHORITY_BROKER_IDENTITY" \
      --broker-script "$FM_SESSION_AUTHORITY_BROKER_SCRIPT" \
      --custodian-public-key "$public" \
      --custodian-public-key-sha256 "$digest" \
      </dev/null >>"$log" 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 1; exec @ARGV' \
      "$script" "$state" "$home" "$checkout" "$session" "$session_start" \
      --broker-pid "$FM_SESSION_AUTHORITY_BROKER_PID" \
      --broker-start "$FM_SESSION_AUTHORITY_BROKER_START" \
      --broker-identity "$FM_SESSION_AUTHORITY_BROKER_IDENTITY" \
      --broker-script "$FM_SESSION_AUTHORITY_BROKER_SCRIPT" \
      --custodian-public-key "$public" \
      --custodian-public-key-sha256 "$digest" \
      </dev/null >>"$log" 2>&1 &
  else
    exec 17<&-
    return 1
  fi
  pid=$!
  while [ "$attempts" -lt 100 ] \
    && ! fm_session_process_runs_script "$pid" "$script"; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.02
    attempts=$((attempts + 1))
  done
  fm_session_process_runs_script "$pid" "$script" \
    && start=$(fm_session_process_start "$pid") \
    && identity=$(fm_session_process_identity "$pid") || {
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exec 17<&-
      return 1
    }
  attempts=0
  launch="${record}.launch.$pid"
  fm_session_durable_custodian_launch_write \
    "$launch" "$pid" "$start" "$identity" "$state" "$home" "$checkout" \
    "$session" "$session_start" "$public" "$digest" \
    "$FM_SESSION_AUTHORITY_BROKER_PID" "$FM_SESSION_AUTHORITY_BROKER_START" \
    "$FM_SESSION_AUTHORITY_BROKER_IDENTITY" \
    "$FM_SESSION_AUTHORITY_BROKER_SCRIPT" \
    || {
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$launch"
      exec 17<&-
      return 1
    }
  while [ "$attempts" -lt 100 ]; do
    if fm_session_durable_custodian_validate "$record" \
      && [ "$FM_SESSION_DURABLE_CUSTODIAN_PID" = "$pid" ] \
      && fm_session_process_runs_script "$pid" "$script" \
      && fm_session_durable_custodian_challenge \
        "$state" "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
        "$FM_SESSION_DURABLE_CUSTODIAN_START"; then
      rm -f "$launch"
      exec 17<&-
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || {
      rm -f "$launch"
      exec 17<&-
      return 1
    }
    sleep 0.02
    attempts=$((attempts + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$launch"
  exec 17<&-
  return 1
}

fm_session_durable_custodian_ensure() {
  local state=$1 home=$2 checkout=$3 lock status attempts=0
  lock="$state/.session-durable-authority-transaction.lock"
  if ! type fm_lock_try_acquire >/dev/null 2>&1; then
    FM_WAKE_LIB_READ_ONLY=1
    . "$_FM_SESSION_LOCK_LIB_DIR/fm-wake-lib.sh"
  fi
  while [ "$attempts" -lt 400 ]; do
    fm_lock_try_acquire "$lock" && break
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ "$attempts" -lt 400 ] || return 1
  fm_session_durable_custodian_ensure_locked \
    "$state" "$home" "$checkout"
  status=$?
  fm_lock_release "$lock" || status=1
  return "$status"
}

fm_session_durable_authority_recover() {
  local state=$1 home=$2 checkout=$3 nonce=$4 public=$5 digest=$6
  local record requests request response start identity tmp attempts=0
  local private_path encrypted_file ciphertext key actual expected body
  local response_custodian response_custodian_start response_requester
  local response_requester_start response_digest
  local custodian_public custodian_public_digest
  record="$state/.session-durable-authority"
  fm_session_durable_custodian_read "$record" \
    && [ "$FM_SESSION_DURABLE_CUSTODIAN_HOME" = "$home" ] \
    && [ "$FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT" = "$checkout" ] || return 1
  custodian_public=$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_KEY
  custodian_public_digest=$FM_SESSION_DURABLE_CUSTODIAN_PUBLIC_SHA256
  [ "${FM_SESSION_DURABLE_CONSUMER_PRIVATE_FD:-}" = 16 ] \
    && fm_session_descriptor_channel_isolated 16 || return 1
  start=$(fm_session_process_start "$$") || return 1
  identity=$(fm_session_process_identity "$$") || return 1
  requests="$state/.session-durable-authority-requests"
  request="$requests/$nonce.request"
  response="$requests/$nonce.response"
  [ ! -e "$request" ] && [ ! -L "$request" ] \
    && [ ! -e "$response" ] && [ ! -L "$response" ] || return 1
  tmp=$(mktemp "${request}.XXXXXX") || return 1
  printf 'version=1\npid=%s\nstart=%s\nidentity=%s\nnonce=%s\npublic-key=%s\npublic-key-sha256=%s\n' \
    "$$" "$start" "$identity" "$nonce" "$public" "$digest" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$request" || {
      rm -f "$tmp"
      return 1
    }
  while [ "$attempts" -lt 200 ]; do
    [ ! -f "$response" ] || break
    kill -0 "$FM_SESSION_DURABLE_CUSTODIAN_PID" 2>/dev/null || {
      rm -f "$request" "$response"
      return 1
    }
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$response" ] && [ ! -L "$response" ] \
    && [ "$(wc -l < "$response" | tr -d ' ')" -eq 9 ] \
    && [ "$(sed -n '1p' "$response")" = version=2 ] \
    && [ "$(sed -n '2s/^nonce=//p' "$response")" = "$nonce" ] || {
      rm -f "$request" "$response"
      return 1
    }
  ciphertext=$(sed -n '3s/^ciphertext=//p' "$response")
  response_custodian=$(sed -n '4s/^custodian-pid=//p' "$response")
  response_custodian_start=$(sed -n '5s/^custodian-start=//p' "$response")
  response_requester=$(sed -n '6s/^requester-pid=//p' "$response")
  response_requester_start=$(sed -n '7s/^requester-start=//p' "$response")
  response_digest=$(sed -n '8s/^public-key-sha256=//p' "$response")
  actual=$(sed -n '9s/^authority-hmac=//p' "$response")
  body=$(sed -n '1,8p' "$response")$'\n'
  private_path=/dev/fd/16
  [ -r "$private_path" ] || private_path=/proc/self/fd/16
  [ -r "$private_path" ] || {
    rm -f "$request" "$response"
    return 1
  }
  encrypted_file=$(mktemp "${TMPDIR:-/tmp}/fm-durable-ciphertext.XXXXXX") || {
    rm -f "$request" "$response"
    return 1
  }
  printf '%s' "$ciphertext" | openssl base64 -d -A \
      > "$encrypted_file" 2>/dev/null \
    && key=$(openssl pkeyutl -decrypt -inkey "$private_path" \
      -in "$encrypted_file" 2>/dev/null) || {
        rm -f "$encrypted_file" "$request" "$response"
        return 1
      }
  rm -f "$encrypted_file"
  exec 16<&-
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  [ "$response_custodian" = "$FM_SESSION_DURABLE_CUSTODIAN_PID" ] \
    && [ "$response_custodian_start" \
      = "$FM_SESSION_DURABLE_CUSTODIAN_START" ] \
    && [ "$response_requester" = "$$" ] \
    && [ "$response_requester_start" = "$start" ] \
    && [ "$response_digest" = "$digest" ] || {
      rm -f "$request" "$response"
      return 1
    }
  expected=$(printf '%s' "$body" | fm_session_hmac_sha256_key "$key") || {
    rm -f "$request" "$response"
    return 1
  }
  [ "$actual" = "$expected" ] \
    && fm_session_durable_custodian_candidate_challenge \
      "$state" "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
      "$FM_SESSION_DURABLE_CUSTODIAN_START" "$key" \
      "$custodian_public" "$custodian_public_digest" || {
    rm -f "$request" "$response"
    return 1
  }
  rm -f "$request" "$response"
  exec 18< <(while :; do printf '%s\n' "$key"; done) || return 1
  unset key
  FM_SESSION_AUTHORITY_DURABLE_FD=18
  fm_session_durable_custodian_validate "$record" || {
    exec 18<&-
    unset FM_SESSION_AUTHORITY_DURABLE_FD
    return 1
  }
}

fm_session_enrollment_signer_prepare() {
  local private public output public_digest public_key
  if ( : <&10 ) 2>/dev/null || ( : >&10 ) 2>/dev/null; then
    return 1
  fi
  if [ -n "${FM_SESSION_AUTHORITY_FD:-}" ]; then
    fm_session_descriptor_channel_isolated "$FM_SESSION_AUTHORITY_FD" \
      || return 1
  fi
  fm_session_exec_descriptor_isolation_durable || return 1
  private=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null) \
    || return 1
  public=$(printf '%s\n' "$private" | openssl ec -pubout 2>/dev/null) \
    || return 1
  output=$(printf '%s\n' "$public" | openssl dgst -sha256 2>/dev/null) \
    || return 1
  public_digest=${output##*= }
  [ "${#public_digest}" -eq 64 ] || return 1
  case "$public_digest" in *[!0-9a-f]*) return 1 ;; esac
  public_key=$(printf '%s\n' "$public" | openssl base64 -A) || return 1
  exec 10< <(printf '%s\n' "$private") || return 1
  unset private public
  fm_session_descriptor_channel_isolated 10 || {
    exec 10<&-
    return 1
  }
  FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD=10
  FM_SESSION_ENROLLMENT_PUBLIC_KEY=$public_key
  FM_SESSION_ENROLLMENT_PUBLIC_SHA256=$public_digest
  export FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD
  export FM_SESSION_ENROLLMENT_PUBLIC_KEY FM_SESSION_ENROLLMENT_PUBLIC_SHA256
}

fm_session_enrollment_consumer_prepare() {
  local private public output public_digest public_key
  fm_session_exec_descriptor_isolation_durable || return 1
  private=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null) \
    || return 1
  public=$(printf '%s\n' "$private" | openssl ec -pubout 2>/dev/null) \
    || return 1
  output=$(printf '%s\n' "$public" | openssl dgst -sha256 2>/dev/null) \
    || return 1
  public_digest=${output##*= }
  [ "${#public_digest}" -eq 64 ] || return 1
  case "$public_digest" in *[!0-9a-f]*) return 1 ;; esac
  public_key=$(printf '%s\n' "$public" | openssl base64 -A) || return 1
  FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY=$private
  unset private public
  FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY=$public_key
  FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256=$public_digest
  export FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY
  export FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256
}

fm_session_enrollment_public_key_validate() {
  local public_key=$1 public_digest=$2 public_file status=1
  [ -n "$public_key" ] && [ "${#public_digest}" -eq 64 ] || return 1
  case "$public_digest" in *[!0-9a-f]*) return 1 ;; esac
  public_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-consumer-public.XXXXXX") \
    || return 1
  if printf '%s' "$public_key" | openssl base64 -d -A \
      > "$public_file" 2>/dev/null \
    && [ "$(fm_session_sha256_file "$public_file" 2>/dev/null)" \
      = "$public_digest" ]; then
    status=0
  fi
  rm -f "$public_file"
  return "$status"
}

fm_session_enrollment_consumer_key_validate() {
  local derived derived_key
  [ -n "${FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY:-}" ] || return 1
  derived=$(printf '%s\n' "$FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY" \
    | openssl ec -pubout 2>/dev/null) || return 1
  derived_key=$(printf '%s\n' "$derived" | openssl base64 -A) || return 1
  unset derived
  [ "$derived_key" = "$1" ] \
    && fm_session_enrollment_public_key_validate "$1" "$2"
}

fm_session_enrollment_sign_data() {
  local private=$1 signature=$2 body=$3
  printf '%s\n' "$private" \
    | openssl dgst -sha256 -sign /dev/stdin -out "$signature" "$body" 2>/dev/null
}

fm_session_enrollment_signer_run() {
  local file=$1 task=$2 home=$3 issuer=$4 endpoint=$5 endpoint_start=$6
  local endpoint_identity=$7 home_real issuer_real marker private
  local authority lock binding authority_digest nonce tmp body signature
  local accepted_digest
  local broker broker_start broker_identity broker_script descriptor signer_start signer_identity
  local private_key_fd=${FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD:-}
  local public_key=${FM_SESSION_ENROLLMENT_PUBLIC_KEY:-}
  local public_digest=${FM_SESSION_ENROLLMENT_PUBLIC_SHA256:-}
  local ready="${file}.ready" consume="${file}.consume" accepted="${file}.accepted"
  local acknowledged="${file}.accepted.ack" finalized="${file}.accepted.final"
  local consumer consumer_start consumer_identity consume_task consume_home
  local consumer_public_key consumer_public_digest
  local expected_script env_role env_task env_home attempts=0
  [ "$private_key_fd" = 10 ] && [ -r /dev/fd/10 ] || return 1
  fm_session_descriptor_channel_isolated "$private_key_fd" || return 1
  private=$(cat <&10) || return 1
  exec 10<&-
  case "$endpoint" in ''|*[!0-9]*) return 1 ;; esac
  [ "$endpoint" -gt 1 ] \
    && [ "$(fm_session_process_start "$endpoint" 2>/dev/null)" = "$endpoint_start" ] \
    && [ "$(fm_session_process_identity "$endpoint" 2>/dev/null)" = "$endpoint_identity" ] \
    || return 1
  [ -n "$public_key" ] && [ "${#public_digest}" -eq 64 ] || return 1
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  issuer_real=$(cd "$issuer" 2>/dev/null && pwd -P) || return 1
  marker="$home_real/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    && [ "$(cat "$marker" 2>/dev/null)" = "$task" ] || return 1
  authority="$issuer_real/state/.session-authority"
  lock="$issuer_real/state/.lock"
  binding="$issuer_real/state/.primary-checkout"
  fm_session_authority_read "$authority" \
    && fm_session_authority_is_current_ancestor "$authority" \
    && [ "$FM_SESSION_AUTHORITY_HOME" = "$issuer_real" ] \
    && [ -f "$lock" ] && [ ! -L "$lock" ] \
    && [ "$(cat "$lock" 2>/dev/null)" = "$FM_SESSION_AUTHORITY_OWNER" ] \
    && [ -f "$binding" ] && [ ! -L "$binding" ] \
    && [ "$(cat "$binding" 2>/dev/null)" = "$FM_SESSION_AUTHORITY_CHECKOUT" ] || return 1
  broker_script="$FM_SESSION_AUTHORITY_CHECKOUT/bin/fm-session-authority-exec.sh"
  [ -z "${FM_SESSION_AUTHORITY_BROKER_SCRIPT:-}" ] \
    || [ "$FM_SESSION_AUTHORITY_BROKER_SCRIPT" = "$broker_script" ] || return 1
  fm_session_authority_broker_present "$broker_script" || return 1
  broker=$FM_SESSION_AUTHORITY_BROKER_PID
  broker_start=$FM_SESSION_AUTHORITY_BROKER_START
  broker_identity=$FM_SESSION_AUTHORITY_BROKER_IDENTITY
  descriptor=$(fm_session_descriptor_identity "$$" "$FM_SESSION_AUTHORITY_FD") || return 1
  [ "$descriptor" = "$(fm_session_descriptor_identity \
    "$broker" "$FM_SESSION_AUTHORITY_FD" 2>/dev/null)" ] || return 1
  signer_start=$(fm_session_process_start "$$") || return 1
  signer_identity=$(fm_session_process_identity "$$") || return 1
  authority_digest=$(fm_session_sha256_file "$authority") || return 1
  nonce=$(fm_session_random_hex 32) || return 1
  case "$task:$home_real:$issuer_real:$broker_start:$broker_identity:$broker_script:$descriptor:$signer_start:$signer_identity:$public_digest:$endpoint_start:$endpoint_identity" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ "${#public_digest}" -eq 64 ] || return 1
  case "$public_digest" in *[!0-9a-f]*) return 1 ;; esac
  for tmp in "$file" "$ready" "$consume" "$accepted" "$acknowledged" "$finalized"; do
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  done
  body=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-body.XXXXXX") || {
    return 1
  }
  signature=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-signature.XXXXXX") || {
    rm -f "$body"
    return 1
  }
  chmod 600 "$body" "$signature" || {
    rm -f "$body" "$signature"
    return 1
  }
  printf 'version=5\nrole=secondmate\ntask=%s\nhome=%s\nissuer-home=%s\nissuer-authority=%s\nnonce=%s\nbroker-pid=%s\nbroker-start=%s\nbroker-identity=%s\nbroker-script=%s\nauthority-fd=%s\nauthority-descriptor=%s\nsigner-pid=%s\nsigner-start=%s\nsigner-identity=%s\npublic-key=%s\npublic-key-sha256=%s\nendpoint-pid=%s\nendpoint-start=%s\nendpoint-identity=%s\n' \
    "$task" "$home_real" "$issuer_real" "$authority_digest" "$nonce" \
    "$broker" "$broker_start" "$broker_identity" "$broker_script" \
    "$FM_SESSION_AUTHORITY_FD" "$descriptor" "$$" "$signer_start" \
    "$signer_identity" "$public_key" "$public_digest" "$endpoint" \
    "$endpoint_start" "$endpoint_identity" > "$body" || {
      rm -f "$body" "$signature"
      return 1
    }
  fm_session_enrollment_sign_data "$private" "$signature" "$body" || {
    rm -f "$body" "$signature"
    return 1
  }
  mkdir -p "${file%/*}" || {
    rm -f "$body" "$signature"
    return 1
  }
  tmp=$(mktemp "${file}.XXXXXX") || {
    rm -f "$body" "$signature"
    return 1
  }
  chmod 600 "$tmp" && cat "$body" > "$tmp" \
    && printf 'signature=%s\n' "$(openssl base64 -A < "$signature")" >> "$tmp" \
    && mv "$tmp" "$file" || {
      rm -f "$tmp"
      rm -f "$body" "$signature"
      return 1
    }
  tmp=$(mktemp "${ready}.XXXXXX") || {
    rm -f "$body" "$signature"
    return 1
  }
  chmod 600 "$tmp" \
    && printf 'nonce=%s\npublic-key=%s\npublic-key-sha256=%s\n' \
      "$nonce" "$public_key" "$public_digest" > "$tmp" \
    && mv "$tmp" "$ready" || {
      rm -f "$tmp" "$body" "$signature"
      return 1
    }
  rm -f "$body" "$signature"
  while [ "$attempts" -lt 1500 ]; do
    if [ -f "$consume" ] && [ ! -L "$consume" ] \
      && [ "$(wc -l < "$consume" | tr -d ' ')" -eq 9 ] \
      && [ "$(sed -n '1s/^signer-pid=//p' "$consume")" = "$$" ] \
      && [ "$(sed -n '2s/^nonce=//p' "$consume")" = "$nonce" ]; then
      consumer=$(sed -n '3s/^consumer-pid=//p' "$consume")
      consumer_start=$(sed -n '4s/^consumer-start=//p' "$consume")
      consumer_identity=$(sed -n '5s/^consumer-identity=//p' "$consume")
      consume_task=$(sed -n '6s/^task=//p' "$consume")
      consume_home=$(sed -n '7s/^home=//p' "$consume")
      consumer_public_key=$(sed -n '8s/^consumer-public-key=//p' "$consume")
      consumer_public_digest=$(sed -n '9s/^consumer-public-key-sha256=//p' "$consume")
      case "$consumer" in ''|*[!0-9]*) return 1 ;; esac
      expected_script="$home_real/bin/fm-session-authority-exec.sh"
      env_role=$(fm_session_process_environment_value \
        "$consumer" FM_AGENT_ROLE 2>/dev/null || true)
      env_task=$(fm_session_process_environment_value \
        "$consumer" FM_AGENT_TASK 2>/dev/null || true)
      env_home=$(fm_session_process_environment_value \
        "$consumer" FM_AGENT_OWNER_HOME 2>/dev/null || true)
      [ "$consume_task" = "$task" ] && [ "$consume_home" = "$home_real" ] \
        && [ "$(fm_session_process_start "$consumer" 2>/dev/null)" = "$consumer_start" ] \
        && [ "$(fm_session_process_identity "$consumer" 2>/dev/null)" = "$consumer_identity" ] \
        && [ "$(fm_session_process_start "$endpoint" 2>/dev/null)" = "$endpoint_start" ] \
        && [ "$(fm_session_process_identity "$endpoint" 2>/dev/null)" = "$endpoint_identity" ] \
        && [ "$consumer" = "$endpoint" ] \
        && fm_session_process_runs_script "$consumer" "$expected_script" \
        && [ "$env_role" = secondmate ] && [ "$env_task" = "$task" ] \
        && [ "$env_home" = "$home_real" ] \
        && fm_session_enrollment_public_key_validate \
          "$consumer_public_key" "$consumer_public_digest" || return 1
      body=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-accepted.XXXXXX") \
        || return 1
      signature=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-accepted-signature.XXXXXX") \
        || { rm -f "$body"; return 1; }
      chmod 600 "$body" "$signature" \
        && printf 'version=2\nsigner-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\nconsumer-public-key-sha256=%s\n' \
          "$$" "$nonce" "$consumer" "$consumer_start" \
          "$consumer_public_digest" > "$body" \
        && fm_session_enrollment_sign_data "$private" "$signature" "$body" || {
            rm -f "$body" "$signature"
            return 1
          }
      tmp=$(mktemp "${accepted}.XXXXXX") || {
        rm -f "$body" "$signature"
        return 1
      }
      chmod 600 "$tmp" && cat "$body" > "$tmp" \
        && printf 'signature=%s\n' "$(openssl base64 -A < "$signature")" >> "$tmp" \
        && mv "$tmp" "$accepted" || {
          rm -f "$tmp" "$body" "$signature"
          return 1
        }
      accepted_digest=$(fm_session_sha256_file "$accepted") || return 1
      rm -f "$body" "$signature" "$consume" "$ready"
      attempts=0
      while [ "$attempts" -lt 1500 ]; do
        if fm_session_enrollment_ack_validate \
          "$acknowledged" "$accepted_digest" "$$" "$nonce" "$consumer" \
          "$consumer_start" "$consumer_public_key" "$consumer_public_digest" \
          && [ "$(fm_session_process_start "$consumer" 2>/dev/null)" = "$consumer_start" ] \
          && [ "$(fm_session_process_identity "$consumer" 2>/dev/null)" = "$consumer_identity" ] \
          && fm_session_enrollment_final_validate \
            "$finalized" "$accepted_digest" "$$" "$nonce" "$consumer" \
            "$consumer_start" "$consumer_public_key" "$consumer_public_digest"; then
          return 0
        fi
        kill -0 "$consumer" 2>/dev/null || return 1
        sleep 0.02
        attempts=$((attempts + 1))
      done
      return 1
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  rm -f "$file" "$ready" "$consume" "$accepted" "$acknowledged" "$finalized"
  return 1
}

fm_session_enrollment_ticket_write() {
  local file=$1 task=$2 home=$3 issuer=$4 endpoint=$5 endpoint_start=$6
  local endpoint_identity=$7 signer ready nonce public_key public_digest
  local attempts=0
  local signer_script issuer_real authority broker_script
  case "$endpoint" in ''|*[!0-9]*) return 1 ;; esac
  [ "$endpoint" -gt 1 ] \
    && [ "$(fm_session_process_start "$endpoint" 2>/dev/null)" = "$endpoint_start" ] \
    && [ "$(fm_session_process_identity "$endpoint" 2>/dev/null)" = "$endpoint_identity" ] \
    || return 1
  issuer_real=$(cd "$issuer" 2>/dev/null && pwd -P) || return 1
  authority="$issuer_real/state/.session-authority"
  fm_session_authority_read "$authority" || return 1
  broker_script="$FM_SESSION_AUTHORITY_CHECKOUT/bin/fm-session-authority-exec.sh"
  [ -z "${FM_SESSION_AUTHORITY_BROKER_SCRIPT:-}" ] \
    || [ "$FM_SESSION_AUTHORITY_BROKER_SCRIPT" = "$broker_script" ] || return 1
  fm_session_authority_broker_present "$broker_script" || return 1
  signer_script="$FM_SESSION_AUTHORITY_CHECKOUT/bin/fm-session-enrollment-signer.sh"
  [ -x "$signer_script" ] && [ ! -L "$signer_script" ] || return 1
  ready="${file}.ready"
  [ ! -e "$ready" ] && [ ! -L "$ready" ] || return 1
  "$signer_script" "$file" "$task" "$home" "$issuer" "$endpoint" \
    "$endpoint_start" "$endpoint_identity" >/dev/null 2>&1 &
  signer=$!
  FM_SESSION_ENROLLMENT_SIGNER_PID=$signer
  export FM_SESSION_ENROLLMENT_SIGNER_PID
  while [ "$attempts" -lt 250 ]; do
    if [ -f "$ready" ] && [ ! -L "$ready" ]; then
      nonce=$(sed -n '1s/^nonce=//p' "$ready")
      [ "${#nonce}" -eq 64 ] || return 1
      case "$nonce" in *[!0-9a-f]*) return 1 ;; esac
      FM_SESSION_ENROLLMENT_NONCE=$nonce
      public_key=$(sed -n '2s/^public-key=//p' "$ready")
      public_digest=$(sed -n '3s/^public-key-sha256=//p' "$ready")
      [ -n "$public_key" ] && [ "${#public_digest}" -eq 64 ] || return 1
      case "$public_digest" in *[!0-9a-f]*) return 1 ;; esac
      [ "$(fm_session_process_argument_value \
        "$signer" --public-sha256 2>/dev/null || true)" = "$public_digest" ] \
        || return 1
      FM_SESSION_ENROLLMENT_PUBLIC_KEY=$public_key
      FM_SESSION_ENROLLMENT_PUBLIC_SHA256=$public_digest
      export FM_SESSION_ENROLLMENT_NONCE FM_SESSION_ENROLLMENT_PUBLIC_KEY
      export FM_SESSION_ENROLLMENT_PUBLIC_SHA256
      return 0
    fi
    kill -0 "$signer" 2>/dev/null || {
      wait "$signer" 2>/dev/null || true
      return 1
    }
    sleep 0.02
    attempts=$((attempts + 1))
  done
  kill "$signer" 2>/dev/null || true
  wait "$signer" 2>/dev/null || true
  rm -f "$file" "$ready" "${file}.consume" "${file}.accepted" \
    "${file}.accepted.ack" "${file}.accepted.final"
  return 1
}

fm_session_enrollment_acceptance_validate() {
  local accepted=$1 signer=$2 nonce=$3 public_key=$4 public_digest=$5
  local consumer_public_digest=${6:-}
  local public_file signature_file body_file signature status
  [ -f "$accepted" ] && [ ! -L "$accepted" ] || return 1
  [ "$(wc -l < "$accepted" | tr -d ' ')" -eq 7 ] || return 1
  [ "$(sed -n '1p' "$accepted")" = version=2 ] || return 1
  [ "$(sed -n '2s/^signer-pid=//p' "$accepted")" = "$signer" ] || return 1
  [ "$(sed -n '3s/^nonce=//p' "$accepted")" = "$nonce" ] || return 1
  if [ -n "$consumer_public_digest" ]; then
    [ "$(sed -n '6s/^consumer-public-key-sha256=//p' "$accepted")" \
      = "$consumer_public_digest" ] || return 1
  fi
  signature=$(sed -n '7s/^signature=//p' "$accepted")
  [ -n "$signature" ] && [ "${#public_digest}" -eq 64 ] || return 1
  public_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-accepted-public.XXXXXX") \
    || return 1
  signature_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-accepted-signature.XXXXXX") \
    || { rm -f "$public_file"; return 1; }
  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-accepted-body.XXXXXX") || {
    rm -f "$public_file" "$signature_file"
    return 1
  }
  printf '%s' "$public_key" | openssl base64 -d -A > "$public_file" 2>/dev/null \
    && printf '%s' "$signature" | openssl base64 -d -A > "$signature_file" 2>/dev/null \
    && sed -n '1,6p' "$accepted" > "$body_file" || {
      rm -f "$public_file" "$signature_file" "$body_file"
      return 1
    }
  [ "$(fm_session_sha256_file "$public_file" 2>/dev/null)" = "$public_digest" ] \
    && openssl dgst -sha256 -verify "$public_file" -signature "$signature_file" \
      "$body_file" >/dev/null 2>&1
  status=$?
  rm -f "$public_file" "$signature_file" "$body_file"
  return "$status"
}

fm_session_enrollment_receipt_validate() {
  local acknowledged=$1 accepted_digest=$2 signer=$3 nonce=$4 consumer=$5
  local consumer_start=$6 public_key=$7 public_digest=$8
  local expected_stage=$9
  local public_file signature_file body_file signature status
  [ -f "$acknowledged" ] && [ ! -L "$acknowledged" ] || return 1
  [ "${#accepted_digest}" -eq 64 ] || return 1
  case "$accepted_digest" in *[!0-9a-f]*) return 1 ;; esac
  [ "$(wc -l < "$acknowledged" | tr -d ' ')" -eq 9 ] || return 1
  [ "$(sed -n '1p' "$acknowledged")" = version=2 ] \
    && [ "$(sed -n '2s/^stage=//p' "$acknowledged")" = "$expected_stage" ] \
    && [ "$(sed -n '3s/^signer-pid=//p' "$acknowledged")" = "$signer" ] \
    && [ "$(sed -n '4s/^nonce=//p' "$acknowledged")" = "$nonce" ] \
    && [ "$(sed -n '5s/^consumer-pid=//p' "$acknowledged")" = "$consumer" ] \
    && [ "$(sed -n '6s/^consumer-start=//p' "$acknowledged")" = "$consumer_start" ] \
    && [ "$(sed -n '8s/^consumer-public-key-sha256=//p' "$acknowledged")" \
      = "$public_digest" ] || return 1
  [ "$(sed -n '7s/^acceptance-sha256=//p' "$acknowledged")" \
    = "$accepted_digest" ] || return 1
  signature=$(sed -n '9s/^signature=//p' "$acknowledged")
  [ -n "$signature" ] && [ "${#public_digest}" -eq 64 ] || return 1
  public_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-ack-public.XXXXXX") \
    || return 1
  signature_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-ack-signature.XXXXXX") \
    || { rm -f "$public_file"; return 1; }
  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-ack-body.XXXXXX") || {
    rm -f "$public_file" "$signature_file"
    return 1
  }
  printf '%s' "$public_key" | openssl base64 -d -A > "$public_file" 2>/dev/null \
    && printf '%s' "$signature" | openssl base64 -d -A \
      > "$signature_file" 2>/dev/null \
    && sed -n '1,8p' "$acknowledged" > "$body_file" || {
      rm -f "$public_file" "$signature_file" "$body_file"
      return 1
    }
  [ "$(fm_session_sha256_file "$public_file" 2>/dev/null)" = "$public_digest" ] \
    && openssl dgst -sha256 -verify "$public_file" -signature "$signature_file" \
      "$body_file" >/dev/null 2>&1
  status=$?
  rm -f "$public_file" "$signature_file" "$body_file"
  return "$status"
}

fm_session_enrollment_ack_validate() {
  fm_session_enrollment_receipt_validate "$@" ack
}

fm_session_enrollment_final_validate() {
  fm_session_enrollment_receipt_validate "$@" final
}

fm_session_enrollment_receipt_write() {
  local acknowledged=$1 accepted=$2 signer=$3 nonce=$4 public_digest=$5
  local stage=$6
  local private consumer_start accepted_digest body signature tmp
  fm_session_exec_descriptor_isolation_durable || return 1
  [ -n "${FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY:-}" ] || return 1
  [ ! -e "$acknowledged" ] && [ ! -L "$acknowledged" ] || return 1
  consumer_start=$(fm_session_process_start "$$") || return 1
  accepted_digest=$(fm_session_sha256_file "$accepted") || return 1
  private=$FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY
  body=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-ack.XXXXXX") \
    || return 1
  signature=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-ack-signature.XXXXXX") \
    || { rm -f "$body"; return 1; }
  chmod 600 "$body" "$signature" \
    && printf 'version=2\nstage=%s\nsigner-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\nacceptance-sha256=%s\nconsumer-public-key-sha256=%s\n' \
      "$stage" "$signer" "$nonce" "$$" "$consumer_start" "$accepted_digest" \
      "$public_digest" > "$body" \
    && fm_session_enrollment_sign_data "$private" "$signature" "$body" || {
      rm -f "$body" "$signature"
      return 1
    }
  unset private
  tmp=$(mktemp "${acknowledged}.XXXXXX") || {
    rm -f "$body" "$signature"
    return 1
  }
  chmod 600 "$tmp" && cat "$body" > "$tmp" \
    && printf 'signature=%s\n' "$(openssl base64 -A < "$signature")" >> "$tmp" \
    && mv "$tmp" "$acknowledged" || {
      rm -f "$tmp" "$body" "$signature"
      return 1
    }
  rm -f "$body" "$signature"
}

fm_session_enrollment_ack_write() {
  fm_session_enrollment_receipt_write "$@" ack
}

fm_session_enrollment_final_write() {
  fm_session_enrollment_receipt_write "$@" final || return 1
  unset FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY
}

fm_session_enrollment_consumption_request() {
  local file=$1 task=$2 home=$3 tmp start identity public_key public_digest
  local consume="${file}.consume"
  [ ! -e "$consume" ] && [ ! -L "$consume" ] || return 1
  start=$(fm_session_process_start "$$") || return 1
  identity=$(fm_session_process_identity "$$") || return 1
  public_key=${FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY:-}
  public_digest=${FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256:-}
  fm_session_enrollment_public_key_validate "$public_key" "$public_digest" \
    || return 1
  case "$public_key:$public_digest" in *$'\n'*|*$'\r'*) return 1 ;; esac
  tmp=$(mktemp "${consume}.XXXXXX") || return 1
  chmod 600 "$tmp" \
    && printf 'signer-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\nconsumer-identity=%s\ntask=%s\nhome=%s\nconsumer-public-key=%s\nconsumer-public-key-sha256=%s\n' \
      "$FM_SESSION_ENROLLMENT_SIGNER_PID" "$FM_SESSION_ENROLLMENT_NONCE" \
      "$$" "$start" "$identity" "$task" "$home" "$public_key" \
      "$public_digest" > "$tmp" \
    && mv "$tmp" "$consume" || {
      rm -f "$tmp"
      return 1
    }
}

fm_session_enrollment_ticket_wait_accepted() {
  local file=$1 signer=$2 nonce=$3 public_key=$4 public_digest=$5
  local attempts=${6:-1500} accepted="${file}.accepted" ack="${file}.accepted.ack"
  local final="${file}.accepted.final"
  local seen=0
  case "$signer:$attempts" in *[!0-9:]*) return 1 ;; esac
  [ "${#nonce}" -eq 64 ] || return 1
  case "$nonce" in *[!0-9a-f]*) return 1 ;; esac
  while [ "$seen" -lt "$attempts" ]; do
    if [ -f "$ack" ] && [ ! -L "$ack" ] \
      && fm_session_enrollment_acceptance_validate \
        "$accepted" "$signer" "$nonce" "$public_key" "$public_digest"; then
      wait "$signer" 2>/dev/null || return 1
      rm -f "$accepted" "$ack" "$final" "${file}.ready" "${file}.consume"
      return 0
    elif ! kill -0 "$signer" 2>/dev/null; then
      wait "$signer" 2>/dev/null || true
      return 1
    fi
    sleep 0.02
    seen=$((seen + 1))
  done
  return 1
}

fm_session_enrollment_ticket_validate() {
  local file=$1 task=$2 home=$3 home_real version role ticket_task ticket_home
  local issuer authority_digest nonce body public_key public_digest signature
  local public_file signature_file body_file signer_public_digest
  local issuer_real authority lock binding current_digest status=1
  local broker broker_start broker_identity broker_script authority_fd descriptor
  local signer signer_start signer_identity signer_script current
  local endpoint endpoint_start endpoint_identity
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 22 ] || return 1
  version=$(sed -n '1s/^version=//p' "$file")
  role=$(sed -n '2s/^role=//p' "$file")
  ticket_task=$(sed -n '3s/^task=//p' "$file")
  ticket_home=$(sed -n '4s/^home=//p' "$file")
  issuer=$(sed -n '5s/^issuer-home=//p' "$file")
  authority_digest=$(sed -n '6s/^issuer-authority=//p' "$file")
  nonce=$(sed -n '7s/^nonce=//p' "$file")
  broker=$(sed -n '8s/^broker-pid=//p' "$file")
  broker_start=$(sed -n '9s/^broker-start=//p' "$file")
  broker_identity=$(sed -n '10s/^broker-identity=//p' "$file")
  broker_script=$(sed -n '11s/^broker-script=//p' "$file")
  authority_fd=$(sed -n '12s/^authority-fd=//p' "$file")
  descriptor=$(sed -n '13s/^authority-descriptor=//p' "$file")
  signer=$(sed -n '14s/^signer-pid=//p' "$file")
  signer_start=$(sed -n '15s/^signer-start=//p' "$file")
  signer_identity=$(sed -n '16s/^signer-identity=//p' "$file")
  public_key=$(sed -n '17s/^public-key=//p' "$file")
  public_digest=$(sed -n '18s/^public-key-sha256=//p' "$file")
  endpoint=$(sed -n '19s/^endpoint-pid=//p' "$file")
  endpoint_start=$(sed -n '20s/^endpoint-start=//p' "$file")
  endpoint_identity=$(sed -n '21s/^endpoint-identity=//p' "$file")
  signature=$(sed -n '22s/^signature=//p' "$file")
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  [ "$version" = 5 ] && [ "$role" = secondmate ] \
    && [ "$ticket_task" = "$task" ] && [ "$ticket_home" = "$home_real" ] \
    && [ "${#authority_digest}" -eq 64 ] && [ "${#nonce}" -eq 64 ] \
    && [ -n "$broker_start" ] && [ -n "$broker_identity" ] \
    && [ -n "$broker_script" ] && [ -n "$descriptor" ] \
    && [ -n "$signer_start" ] && [ -n "$signer_identity" ] \
    && [ -n "$public_key" ] && [ "${#public_digest}" -eq 64 ] \
    && [ -n "$endpoint_start" ] && [ -n "$endpoint_identity" ] \
    && [ -n "$signature" ] || return 1
  case "$broker:$signer:$authority_fd:$endpoint" in *[!0-9:]*) return 1 ;; esac
  case "$authority_digest:$nonce:$public_digest" in
    *[!0-9a-f:]*) return 1 ;;
  esac
  issuer_real=$(cd "$issuer" 2>/dev/null && pwd -P) || return 1
  [ "$issuer_real" != "$home_real" ] || return 1
  public_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-public.XXXXXX") || return 1
  signature_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-signature.XXXXXX") || {
    rm -f "$public_file"
    return 1
  }
  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-body.XXXXXX") || {
    rm -f "$public_file" "$signature_file"
    return 1
  }
  body=$(sed -n '1,21p' "$file")$'\n'
  printf '%s' "$public_key" | openssl base64 -d -A > "$public_file" 2>/dev/null \
    && printf '%s' "$signature" | openssl base64 -d -A > "$signature_file" 2>/dev/null \
    && printf '%s' "$body" > "$body_file" || {
      rm -f "$public_file" "$signature_file" "$body_file"
      return 1
    }
  authority="$issuer_real/state/.session-authority"
  lock="$issuer_real/state/.lock"
  binding="$issuer_real/state/.primary-checkout"
  current_digest=$(fm_session_sha256_file "$authority" 2>/dev/null || true)
  signer_script="${broker_script%/*}/fm-session-enrollment-signer.sh"
  current=$(fm_session_process_start "$signer" 2>/dev/null || true)
  signer_public_digest=$(fm_session_process_argument_value \
    "$signer" --public-sha256 2>/dev/null || true)
  if openssl dgst -sha256 -verify "$public_file" -signature "$signature_file" \
      "$body_file" >/dev/null 2>&1 \
    && [ "$(fm_session_sha256_file "$public_file" 2>/dev/null)" = "$public_digest" ] \
    && [ "$signer_public_digest" = "$public_digest" ] \
    && [ "$current" = "$signer_start" ] \
    && [ "$(fm_session_process_identity "$signer" 2>/dev/null)" = "$signer_identity" ] \
    && fm_session_process_runs_script "$signer" "$signer_script" \
    && [ "$(fm_session_descriptor_identity "$signer" "$authority_fd" 2>/dev/null)" = "$descriptor" ] \
    && [ "$(fm_session_descriptor_identity "$broker" "$authority_fd" 2>/dev/null)" = "$descriptor" ] \
    && [ "$current_digest" = "$authority_digest" ] \
    && fm_session_authority_read "$authority" \
    && [ "$(fm_session_descriptor_identity \
          "$FM_SESSION_AUTHORITY_PID" "$authority_fd" 2>/dev/null)" \
      = "$descriptor" ] \
    && [ "$FM_SESSION_AUTHORITY_HOME" = "$issuer_real" ] \
    && [ -f "$lock" ] && [ ! -L "$lock" ] \
    && [ "$(cat "$lock" 2>/dev/null)" = "$FM_SESSION_AUTHORITY_OWNER" ] \
    && [ -f "$binding" ] && [ ! -L "$binding" ] \
    && [ "$(cat "$binding" 2>/dev/null)" = "$FM_SESSION_AUTHORITY_CHECKOUT" ] \
    && [ "$broker_script" = \
      "$FM_SESSION_AUTHORITY_CHECKOUT/bin/fm-session-authority-exec.sh" ] \
    && [ "$(fm_session_process_start "$broker" 2>/dev/null)" = "$broker_start" ] \
    && [ "$(fm_session_process_identity "$broker" 2>/dev/null)" = "$broker_identity" ] \
    && fm_session_process_runs_authority_broker "$broker" "$broker_script" \
    && [ "$(fm_session_process_start "$endpoint" 2>/dev/null)" = "$endpoint_start" ] \
    && [ "$(fm_session_process_identity "$endpoint" 2>/dev/null)" = "$endpoint_identity" ] \
    && [ "$endpoint" = "$$" ]; then
    status=0
    FM_SESSION_ENROLLMENT_SIGNER_PID=$signer
    FM_SESSION_ENROLLMENT_NONCE=$nonce
    FM_SESSION_ENROLLMENT_PUBLIC_KEY=$public_key
    FM_SESSION_ENROLLMENT_PUBLIC_SHA256=$public_digest
    export FM_SESSION_ENROLLMENT_SIGNER_PID FM_SESSION_ENROLLMENT_NONCE
    export FM_SESSION_ENROLLMENT_PUBLIC_KEY FM_SESSION_ENROLLMENT_PUBLIC_SHA256
  fi
  rm -f "$public_file" "$signature_file" "$body_file"
  return "$status"
}

fm_session_hmac_from_descriptor() {
  local fd=$1 key
  case "$fd" in ''|*[!0-9]*) return 1 ;; esac
  IFS= read -r key <&"$fd" || return 1
  fm_session_hmac_sha256_key "$key"
}

fm_session_authority_hmac() {
  fm_session_authority_capability_present || return 1
  fm_session_descriptor_channel_isolated \
    "${FM_SESSION_AUTHORITY_FD:-}" \
    && fm_session_exec_descriptor_isolation_durable || return 1
  fm_session_hmac_from_descriptor "$FM_SESSION_AUTHORITY_FD"
}

fm_session_authority_durable_capability_present() {
  local key fd=${FM_SESSION_AUTHORITY_DURABLE_FD:-}
  if [ -z "$fd" ] && fm_session_test_authority_broker_present; then
    fd=$FM_TEST_DURABLE_AUTHORITY_FD
    FM_SESSION_AUTHORITY_DURABLE_FD=$fd
    export FM_SESSION_AUTHORITY_DURABLE_FD
  fi
  fm_session_descriptor_channel_isolated "$fd" \
    && fm_session_exec_descriptor_isolation_durable || return 1
  IFS= read -r key <&"$fd" || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
}

fm_session_authority_durable_hmac() {
  local fd=${FM_SESSION_AUTHORITY_DURABLE_FD:-}
  if [ -z "$fd" ]; then
    fm_session_authority_durable_capability_present || return 1
    fd=$FM_SESSION_AUTHORITY_DURABLE_FD
  fi
  fm_session_descriptor_channel_isolated "$fd" \
    && fm_session_exec_descriptor_isolation_durable || return 1
  fm_session_hmac_from_descriptor "$fd"
}

fm_session_authority_record_write() {
  local file=$1 body=$2 hmac tmp
  case "$body" in *$'\r'*) return 1 ;; esac
  hmac=$(printf '%s' "$body" | fm_session_authority_durable_hmac) || return 1
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  chmod 600 "$tmp" \
    && printf '%sauthority-hmac=%s\n' "$body" "$hmac" > "$tmp" \
    && mv "$tmp" "$file" || {
      rm -f "$tmp"
      return 1
    }
}

fm_session_authority_record_validate() {
  local file=$1 lines=$2 body actual expected
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" -eq "$lines" ] || return 1
  actual=$(sed -n "${lines}s/^authority-hmac=//p" "$file")
  [ "${#actual}" -eq 64 ] || return 1
  case "$actual" in *[!0-9a-f]*) return 1 ;; esac
  body=$(sed -n "1,$((lines - 1))p" "$file")$'\n'
  expected=$(printf '%s' "$body" | fm_session_authority_durable_hmac) || return 1
  [ "$actual" = "$expected" ]
}

fm_session_launch_receipt_write() {
  local file=$1 task=$2 home=$3 pid=$4 start=$5 identity=$6 body
  case "$task:$home:$pid:$start:$identity" in *$'\n'*|*$'\r'*) return 1 ;; esac
  body=$(printf 'version=1\ntask=%s\nhome=%s\npid=%s\nstart=%s\nidentity=%s\n' \
    "$task" "$home" "$pid" "$start" "$identity") || return 1
  fm_session_authority_record_write "$file" "${body}"$'\n'
}

fm_session_launch_receipt_validate() {
  local file=$1 task=$2 home=$3 pid=$4 start=$5 identity=$6
  fm_session_authority_record_validate "$file" 7 \
    && [ "$(sed -n '1p' "$file")" = version=1 ] \
    && [ "$(sed -n '2s/^task=//p' "$file")" = "$task" ] \
    && [ "$(sed -n '3s/^home=//p' "$file")" = "$home" ] \
    && [ "$(sed -n '4s/^pid=//p' "$file")" = "$pid" ] \
    && [ "$(sed -n '5s/^start=//p' "$file")" = "$start" ] \
    && [ "$(sed -n '6s/^identity=//p' "$file")" = "$identity" ]
}

fm_session_authority_token() {
  local pid=$1 start=$2 identity=$3 owner=$4 home=$5 checkout=$6
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$pid" "$start" "$identity" "$owner" "$home" "$checkout" \
    | fm_session_authority_durable_hmac
}

fm_session_authority_write_file() {
  local file=$1 pid=$2 owner=$3 home=$4 checkout=$5 start identity token
  start=$(fm_session_process_start "$pid") || return 1
  identity=$(fm_session_process_identity "$pid") || return 1
  token=$(fm_session_authority_token \
    "$pid" "$start" "$identity" "$owner" "$home" "$checkout") || return 1
  case "$owner:$home:$checkout:$start:$identity:$token" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  printf 'version=2\npid=%s\nstart=%s\nidentity=%s\ntoken=%s\nowner=%s\nhome=%s\ncheckout=%s\n' \
    "$pid" "$start" "$identity" "$token" "$owner" "$home" "$checkout" > "$file"
}

fm_session_authority_read_shape() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 8 ] || return 1
  [ "$(sed -n '1p' "$file")" = version=2 ] || return 1
  FM_SESSION_AUTHORITY_PID=$(sed -n '2s/^pid=//p' "$file")
  FM_SESSION_AUTHORITY_START=$(sed -n '3s/^start=//p' "$file")
  FM_SESSION_AUTHORITY_IDENTITY=$(sed -n '4s/^identity=//p' "$file")
  FM_SESSION_AUTHORITY_TOKEN=$(sed -n '5s/^token=//p' "$file")
  FM_SESSION_AUTHORITY_OWNER=$(sed -n '6s/^owner=//p' "$file")
  FM_SESSION_AUTHORITY_HOME=$(sed -n '7s/^home=//p' "$file")
  FM_SESSION_AUTHORITY_CHECKOUT=$(sed -n '8s/^checkout=//p' "$file")
  case "$FM_SESSION_AUTHORITY_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#FM_SESSION_AUTHORITY_TOKEN}" -eq 64 ] || return 1
  case "$FM_SESSION_AUTHORITY_TOKEN" in *[!0-9a-f]*) return 1 ;; esac
  [ -n "$FM_SESSION_AUTHORITY_START" ] \
    && [ -n "$FM_SESSION_AUTHORITY_IDENTITY" ] \
    && [ -n "$FM_SESSION_AUTHORITY_OWNER" ] \
    && [ -n "$FM_SESSION_AUTHORITY_HOME" ] \
    && [ -n "$FM_SESSION_AUTHORITY_CHECKOUT" ] || return 1
}

fm_session_authority_read() {
  local file=$1 expected
  fm_session_authority_read_shape "$file" || return 1
  expected=$(fm_session_authority_token \
    "$FM_SESSION_AUTHORITY_PID" "$FM_SESSION_AUTHORITY_START" \
    "$FM_SESSION_AUTHORITY_IDENTITY" "$FM_SESSION_AUTHORITY_OWNER" \
    "$FM_SESSION_AUTHORITY_HOME" "$FM_SESSION_AUTHORITY_CHECKOUT") || return 1
  [ "$FM_SESSION_AUTHORITY_TOKEN" = "$expected" ]
}

fm_session_authority_process_state() {
  local file=$1 current
  fm_session_authority_read_shape "$file" || return 2
  if ! kill -0 "$FM_SESSION_AUTHORITY_PID" 2>/dev/null; then
    return 1
  fi
  current=$(fm_session_process_start "$FM_SESSION_AUTHORITY_PID") || return 2
  [ "$current" = "$FM_SESSION_AUTHORITY_START" ] || return 1
  current=$(fm_session_process_identity "$FM_SESSION_AUTHORITY_PID") || return 2
  [ "$current" = "$FM_SESSION_AUTHORITY_IDENTITY" ] || return 1
  return 0
}

fm_session_authority_is_current_ancestor() {
  local file=$1 pid=$$ ppid marker
  fm_session_authority_process_state "$file" || return 1
  if marker=$(fm_codex_owner_marker "$FM_SESSION_AUTHORITY_OWNER" 2>/dev/null); then
    fm_codex_thread_active && [ "$CODEX_THREAD_ID" = "$marker" ] || return 1
  fi
  while [ "$pid" -gt 1 ]; do
    [ "$pid" != "$FM_SESSION_AUTHORITY_PID" ] || return 0
    ppid=$(fm_session_parent_pid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
  done
  return 1
}

fm_session_pid_is_current_ancestor() {
  fm_session_pid_is_ancestor_of "$1" "$$"
}

fm_session_pid_is_ancestor_of() {
  local wanted=$1 pid=$2 ppid
  case "$wanted:$pid" in *[!0-9:]*) return 1 ;; esac
  [ "$wanted" -gt 1 ] || return 1
  while [ "$pid" -gt 1 ]; do
    [ "$pid" != "$wanted" ] || return 0
    ppid=$(fm_session_parent_pid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
  done
  return 1
}

fm_verified_harness_ancestry_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  return 1
}

# Compatibility name for existing callers in older JT worktrees.
fm_harness_ancestry_pid() {
  fm_verified_harness_ancestry_pid
}

fm_codex_thread_active() {
  [ "${CLAUDECODE:-}" != "1" ] \
    && [ "${PI_CODING_AGENT:-}" != "true" ] \
    && [ "${GROK_AGENT:-}" != "1" ] \
    && [ -n "${CODEX_THREAD_ID:-}" ]
}

fm_session_lock_owner() {
  local pid=$$ parent fd=${FM_SESSION_AUTHORITY_FD:-} durable_fd
  local current target harness
  fm_session_authority_capability_present || return 1
  harness=
  if fm_session_test_authority_broker_present; then
    if [ "${FM_TEST_SESSION_LOCK_STABLE_OWNER:-0}" = 1 ]; then
      harness=${FM_TEST_AUTHORITY_OWNER_PID:-}
      case "$harness" in
        ''|*[!0-9]*) harness= ;;
        *)
          durable_fd=${FM_SESSION_AUTHORITY_DURABLE_FD:-}
          if ! kill -0 "$harness" 2>/dev/null \
            || { ! fm_session_pid_is_current_ancestor "$harness" \
              && [ "$(fm_session_descriptor_identity \
                    "$$" "$fd" 2>/dev/null || true)" != \
                  "$(fm_session_descriptor_identity \
                    "$harness" "$fd" 2>/dev/null || true)" ] \
              && [ "$(fm_session_descriptor_identity \
                    "$$" "$durable_fd" 2>/dev/null || true)" != \
                  "$(fm_session_descriptor_identity \
                    "$harness" "$durable_fd" 2>/dev/null || true)" ]; }; then
            harness=
          fi
          ;;
      esac
    else
      harness=$$
    fi
  fi
  if [ -n "$harness" ]; then
    pid=$harness
  else
    target=$(fm_session_descriptor_identity "$pid" "$fd" 2>/dev/null || true)
  fi
  if [ -z "$harness" ] && [ -n "$target" ]; then
    while [ "$pid" -gt 1 ]; do
      parent=$(fm_session_parent_pid "$pid") || return 1
      [ "$parent" != "$pid" ] || return 1
      current=$(fm_session_descriptor_identity "$parent" "$fd" 2>/dev/null || true)
      [ "$current" = "$target" ] || break
      pid=$parent
    done
  fi
  fm_session_process_start "$pid" >/dev/null || return 1
  fm_session_process_identity "$pid" >/dev/null || return 1
  if fm_codex_thread_active; then
    if fm_session_test_authority_broker_present; then
      printf '%s|codex:%s|capability\n' "$pid" "$CODEX_THREAD_ID"
    else
      printf '%s|codex:%s|descriptor\n' "$pid" "$CODEX_THREAD_ID"
    fi
    return
  fi
  printf '%s\n' "$pid"
}

fm_harness_pid_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}

fm_codex_owner_marker() {
  local owner=$1 pid rest marker suffix
  pid=${owner%%|*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  rest=${owner#*|}
  case "$rest" in codex:*) rest=${rest#codex:} ;; *) return 1 ;; esac
  marker=${rest%%|*}
  case "$marker" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  if [ "$rest" != "$marker" ]; then
    suffix=${rest#*|}
    case "$suffix" in harness|fallback|capability|descriptor) ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$marker"
}

fm_codex_owner_kind() {
  local owner=$1 rest marker suffix
  fm_codex_owner_marker "$owner" >/dev/null || return 1
  rest=${owner#*|codex:}
  marker=${rest%%|*}
  if [ "$rest" = "$marker" ]; then
    printf '%s\n' legacy
    return 0
  fi
  suffix=${rest#*|}
  printf '%s\n' "$suffix"
}

# Return 0 when owner $1 is live or belongs to the current Codex thread, 1 when
# it is provably stale, 2 when another Codex thread cannot verify it, and 3 for
# an invalid owner record.
fm_session_lock_holder_state() {
  local owner=$1 pid marker kind
  case "$owner" in
    *'|codex:'*)
      pid=${owner%%|*}
      case "$pid" in ''|*[!0-9]*) return 3 ;; esac
      marker=$(fm_codex_owner_marker "$owner") || return 3
      if fm_codex_thread_active && [ "$CODEX_THREAD_ID" = "$marker" ]; then
        return 0
      fi
      kind=$(fm_codex_owner_kind "$owner") || return 3
      if [ "$kind" = harness ]; then
        fm_harness_pid_alive "$pid"
        return $?
      fi
      return 2
      ;;
    *)
      case "$owner" in ''|*[!0-9]*) return 3 ;; esac
      fm_harness_pid_alive "$owner"
      ;;
  esac
}

fm_session_lock_owned_by_self() {
  local state=$1 owner marker my_pid
  owner=$(cat "$state/.lock" 2>/dev/null || true)
  if marker=$(fm_codex_owner_marker "$owner"); then
    fm_codex_thread_active && [ "$CODEX_THREAD_ID" = "$marker" ]
    return $?
  fi
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  my_pid=$(fm_verified_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$owner" ]
}

fm_session_legacy_owner_is_current() {
  local owner=$1 pid marker
  pid=${owner%%|*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_session_pid_is_current_ancestor "$pid" || return 1
  if marker=$(fm_codex_owner_marker "$owner" 2>/dev/null); then
    fm_codex_thread_active && [ "$CODEX_THREAD_ID" = "$marker" ]
  else
    [ "$owner" = "$pid" ]
  fi
}
