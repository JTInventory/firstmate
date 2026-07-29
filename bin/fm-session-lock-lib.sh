#!/usr/bin/env bash
# Shared session-lock authority.
# This file is sourced by scripts and has no side effects on source.

FM_HARNESS_RE='claude|codex|opencode|grok|^pi$'

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

fm_session_process_session_id() {
  local pid=$1 stat state ppid pgrp sid
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*) }
    read -r state ppid pgrp sid _ <<< "$stat"
  else
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  fi
  case "$sid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sid" -gt 1 ] || return 1
  printf '%s\n' "$sid"
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

fm_session_hmac_sha256_key_file() {
  local key_file=$1 key output digest
  [ -r "$key_file" ] || return 1
  key=$(tr -d '\n' < "$key_file" 2>/dev/null) || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  command -v openssl >/dev/null 2>&1 || return 1
  output=$(openssl dgst -sha256 -hmac "$key" 2>/dev/null) || return 1
  digest=${output##*= }
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$digest"
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
  local key_path key
  key_path=$(fm_session_authority_key_path) || return 1
  key=$(tr -d '\n' < "$key_path" 2>/dev/null) || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
}

fm_session_authority_broker_present() {
  local script=$1 broker=${FM_SESSION_AUTHORITY_BROKER_PID:-}
  local start=${FM_SESSION_AUTHORITY_BROKER_START:-}
  local identity=${FM_SESSION_AUTHORITY_BROKER_IDENTITY:-}
  local current caller_target broker_target
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

fm_session_authority_hmac() {
  local key_path
  key_path=$(fm_session_authority_key_path) || return 1
  fm_session_hmac_sha256_key_file "$key_path"
}

fm_session_authority_token() {
  local pid=$1 start=$2 identity=$3 owner=$4 home=$5 checkout=$6
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$pid" "$start" "$identity" "$owner" "$home" "$checkout" \
    | fm_session_authority_hmac
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
  local wanted=$1 pid=$$ ppid
  case "$wanted" in ''|*[!0-9]*) return 1 ;; esac
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
  local pid=$$ parent fd=${FM_SESSION_AUTHORITY_FD:-} current target
  fm_session_authority_capability_present || return 1
  target=$(fm_session_descriptor_identity "$pid" "$fd" 2>/dev/null || true)
  if [ -n "$target" ]; then
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
    printf '%s|codex:%s|descriptor\n' "$pid" "$CODEX_THREAD_ID"
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
