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

fm_session_enrollment_signer_prepare() {
  local script=$1 private public output public_digest public_key
  shift
  if ( : <&10 ) 2>/dev/null || ( : >&10 ) 2>/dev/null; then
    return 1
  fi
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
  FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD=10
  FM_SESSION_ENROLLMENT_PUBLIC_KEY=$public_key
  FM_SESSION_ENROLLMENT_PUBLIC_SHA256=$public_digest
  export FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD
  export FM_SESSION_ENROLLMENT_PUBLIC_KEY FM_SESSION_ENROLLMENT_PUBLIC_SHA256
  exec "$script" "$@"
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
  local broker broker_start broker_identity broker_script descriptor signer_start signer_identity
  local private_key_fd=${FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD:-}
  local public_key=${FM_SESSION_ENROLLMENT_PUBLIC_KEY:-}
  local public_digest=${FM_SESSION_ENROLLMENT_PUBLIC_SHA256:-}
  local ready="${file}.ready" consume="${file}.consume" accepted="${file}.accepted"
  local consumer consumer_start consumer_identity consume_task consume_home
  local expected_script env_role env_task env_home attempts=0
  [ "$private_key_fd" = 10 ] && [ -r /dev/fd/10 ] || return 1
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
  for tmp in "$file" "$ready" "$consume" "$accepted"; do
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
    && mv "$tmp" "$file" && : > "$ready" || {
      rm -f "$tmp"
      rm -f "$body" "$signature"
      return 1
    }
  rm -f "$body" "$signature"
  while [ "$attempts" -lt 1500 ]; do
    if [ -f "$consume" ] && [ ! -L "$consume" ] \
      && [ "$(wc -l < "$consume" | tr -d ' ')" -eq 7 ] \
      && [ "$(sed -n '1s/^signer-pid=//p' "$consume")" = "$$" ] \
      && [ "$(sed -n '2s/^nonce=//p' "$consume")" = "$nonce" ]; then
      consumer=$(sed -n '3s/^consumer-pid=//p' "$consume")
      consumer_start=$(sed -n '4s/^consumer-start=//p' "$consume")
      consumer_identity=$(sed -n '5s/^consumer-identity=//p' "$consume")
      consume_task=$(sed -n '6s/^task=//p' "$consume")
      consume_home=$(sed -n '7s/^home=//p' "$consume")
      case "$consumer" in ''|*[!0-9]*) return 1 ;; esac
      expected_script="$broker_script"
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
        && [ "$env_home" = "$home_real" ] || return 1
      body=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-accepted.XXXXXX") \
        || return 1
      signature=$(mktemp "${TMPDIR:-/tmp}/fm-session-enrollment-accepted-signature.XXXXXX") \
        || { rm -f "$body"; return 1; }
      chmod 600 "$body" "$signature" \
        && printf 'version=1\nsigner-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\n' \
          "$$" "$nonce" "$consumer" "$consumer_start" > "$body" \
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
      rm -f "$body" "$signature" "$consume" "$ready"
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  rm -f "$file" "$ready" "$consume" "$accepted"
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
    if [ -f "$ready" ]; then
      nonce=$(sed -n '7s/^nonce=//p' "$file")
      [ "${#nonce}" -eq 64 ] || return 1
      case "$nonce" in *[!0-9a-f]*) return 1 ;; esac
      FM_SESSION_ENROLLMENT_NONCE=$nonce
      public_key=$(sed -n '17s/^public-key=//p' "$file")
      public_digest=$(sed -n '18s/^public-key-sha256=//p' "$file")
      [ -n "$public_key" ] && [ "${#public_digest}" -eq 64 ] || return 1
      case "$public_digest" in *[!0-9a-f]*) return 1 ;; esac
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
  rm -f "$file" "$ready" "${file}.consume" "${file}.accepted"
  return 1
}

fm_session_enrollment_acceptance_validate() {
  local accepted=$1 signer=$2 nonce=$3 public_key=$4 public_digest=$5
  local public_file signature_file body_file signature status
  [ -f "$accepted" ] && [ ! -L "$accepted" ] || return 1
  [ "$(wc -l < "$accepted" | tr -d ' ')" -eq 6 ] || return 1
  [ "$(sed -n '1p' "$accepted")" = version=1 ] || return 1
  [ "$(sed -n '2s/^signer-pid=//p' "$accepted")" = "$signer" ] || return 1
  [ "$(sed -n '3s/^nonce=//p' "$accepted")" = "$nonce" ] || return 1
  signature=$(sed -n '6s/^signature=//p' "$accepted")
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
    && sed -n '1,5p' "$accepted" > "$body_file" || {
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

fm_session_enrollment_consumption_request() {
  local file=$1 task=$2 home=$3 tmp start identity
  local consume="${file}.consume"
  [ ! -e "$consume" ] && [ ! -L "$consume" ] || return 1
  start=$(fm_session_process_start "$$") || return 1
  identity=$(fm_session_process_identity "$$") || return 1
  tmp=$(mktemp "${consume}.XXXXXX") || return 1
  chmod 600 "$tmp" \
    && printf 'signer-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\nconsumer-identity=%s\ntask=%s\nhome=%s\n' \
      "$FM_SESSION_ENROLLMENT_SIGNER_PID" "$FM_SESSION_ENROLLMENT_NONCE" \
      "$$" "$start" "$identity" "$task" "$home" > "$tmp" \
    && mv "$tmp" "$consume" || {
      rm -f "$tmp"
      return 1
    }
}

fm_session_enrollment_ticket_wait_accepted() {
  local file=$1 signer=$2 nonce=$3 public_key=$4 public_digest=$5
  local attempts=${6:-1500} accepted="${file}.accepted" seen=0
  case "$signer:$attempts" in *[!0-9:]*) return 1 ;; esac
  [ "${#nonce}" -eq 64 ] || return 1
  case "$nonce" in *[!0-9a-f]*) return 1 ;; esac
  while [ "$seen" -lt "$attempts" ]; do
    if fm_session_enrollment_acceptance_validate \
      "$accepted" "$signer" "$nonce" "$public_key" "$public_digest"; then
      wait "$signer" 2>/dev/null || return 1
      rm -f "$accepted" "${file}.ready" "${file}.consume"
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
  signer_public_digest=$(fm_session_process_environment_value \
    "$signer" FM_SESSION_ENROLLMENT_PUBLIC_SHA256 2>/dev/null || true)
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
    && fm_session_authority_read_shape "$authority" \
    && [ "$FM_SESSION_AUTHORITY_PID" = "$broker" ] \
    && [ "$FM_SESSION_AUTHORITY_HOME" = "$issuer_real" ] \
    && [ -f "$lock" ] && [ ! -L "$lock" ] \
    && [ "$(cat "$lock" 2>/dev/null)" = "$FM_SESSION_AUTHORITY_OWNER" ] \
    && [ -f "$binding" ] && [ ! -L "$binding" ] \
    && [ "$(cat "$binding" 2>/dev/null)" = "$FM_SESSION_AUTHORITY_CHECKOUT" ] \
    && [ "$broker_script" = \
      "$FM_SESSION_AUTHORITY_CHECKOUT/bin/fm-session-authority-exec.sh" ] \
    && [ "$(fm_session_process_start "$broker" 2>/dev/null)" = "$broker_start" ] \
    && [ "$(fm_session_process_identity "$broker" 2>/dev/null)" = "$broker_identity" ] \
    && fm_session_process_runs_script "$broker" "$broker_script" \
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
