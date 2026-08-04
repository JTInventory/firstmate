#!/usr/bin/env bash
set -eu

authority_platform=$(uname -s 2>/dev/null || true)
authority_arch=$(uname -m 2>/dev/null || true)
case "$authority_platform:$authority_arch" in
  Linux:x86_64|Linux:amd64|Linux:aarch64|Linux:riscv64|Linux:s390x|Linux:i[3-6]86|Linux:arm*|Linux:ppc64*) ;;
  *) exit 125 ;;
esac

AUTHORITY_EXEC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

[ "$#" -gt 0 ] || {
  echo "usage: fm-session-authority-exec.sh command [args...]" >&2
  exit 2
}
enrollment_launch=
enrollment_consumer_key=
enrollment_consumer_digest=
enrollment_authorized=
enrollment_confirmed=
enrollment_final_pending=0
enrollment_ticket_data=
enrollment_acceptance_data=
enrollment_trusted_ticket_data=
enrollment_trusted_acceptance_data=
enrollment_trusted_consumer_key=
enrollment_ticket=
durable_recovery=
durable_consumer_key=
durable_consumer_digest=
cleanup_enrollment_ticket() {
  [ -z "$enrollment_ticket" ] || rm -f -- "$enrollment_ticket"
}
trap cleanup_enrollment_ticket EXIT
if [ "${1:-}" = --durable-recovery ]; then
  [ "$#" -gt 6 ] || exit 2
  durable_recovery=$2
  [ "$3" = --durable-consumer-key ] || exit 2
  durable_consumer_key=$4
  [ "$5" = --durable-consumer-key-sha256 ] || exit 2
  durable_consumer_digest=$6
  shift 6
  [ "${#durable_recovery}" -eq 64 ] \
    && [ "${#durable_consumer_digest}" -eq 64 ] || exit 1
  case "$durable_recovery:$durable_consumer_digest" in
    *[!0-9a-f:]*) exit 1 ;;
  esac
fi
if [ "${1:-}" = --enrollment-confirmed ]; then
  [ "$#" -gt 2 ] || exit 2
  enrollment_confirmed=$2
  shift 2
  [ "${#enrollment_confirmed}" -eq 64 ] || exit 1
  case "$enrollment_confirmed" in *[!0-9a-f]*) exit 1 ;; esac
fi
if [ "${1:-}" = --enrollment-ticket-data ]; then
  [ "$#" -gt 2 ] || exit 2
  enrollment_ticket_data=$2
  shift 2
fi
if [ "${1:-}" = --enrollment-acceptance-data ]; then
  [ "$#" -gt 2 ] || exit 2
  enrollment_acceptance_data=$2
  shift 2
fi
if [ "${1:-}" = --enrollment-authorized ]; then
  [ "$#" -gt 2 ] || exit 2
  enrollment_authorized=$2
  shift 2
  [ "${#enrollment_authorized}" -eq 64 ] || exit 1
  case "$enrollment_authorized" in *[!0-9a-f]*) exit 1 ;; esac
fi
if [ "${1:-}" = --enrollment-launch ]; then
  [ "$#" -gt 2 ] || exit 2
  enrollment_launch=$2
  shift 2
  [ "${#enrollment_launch}" -eq 64 ] || exit 1
  case "$enrollment_launch" in *[!0-9a-f]*) exit 1 ;; esac
fi
if [ "${1:-}" = --enrollment-consumer-key ]; then
  [ "$#" -gt 4 ] || exit 2
  enrollment_consumer_key=$2
  [ "$3" = --enrollment-consumer-key-sha256 ] || exit 2
  enrollment_consumer_digest=$4
  shift 4
fi
case "${FM_AGENT_ROLE:-}" in
  ""|primary)
    [ -z "${FM_AGENT_TASK:-}" ] && [ -z "${FM_AGENT_OWNER_HOME:-}" ] || {
      echo "error: task workers cannot create session authority" >&2
      exit 1
    }
    ;;
  secondmate)
    [ -n "${FM_AGENT_TASK:-}" ] && [ -n "${FM_AGENT_OWNER_HOME:-}" ] || {
      echo "error: incomplete secondmate identity cannot create session authority" >&2
      exit 1
    }
    [ -n "$enrollment_launch" ] || {
      echo "error: secondmate enrollment launch identity is missing" >&2
      exit 1
    }
    ;;
  *) echo "error: task workers cannot create session authority" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
unset FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED
unset FM_SESSION_AUTHORITY_DESCRIPTOR_ORIGIN
FM_SESSION_AUTHORITY_DESCRIPTOR_ORIGIN=none
if [ "${FM_AGENT_ROLE:-}" = secondmate ] \
  && ! fm_worker_secondmate_effective_scope_matches; then
  echo "error: secondmate scope does not match its declared owner home" >&2
  exit 1
fi
if [ "${FM_AGENT_ROLE:-}" = secondmate ] \
  && ! fm_worker_isolation_sweep_current; then
  echo "error: secondmate isolation sweep is unproven" >&2
  exit 1
fi
unset FM_SESSION_ENROLLMENT_TRACE_FILE
if [ "${FM_SESSION_ENROLLMENT_STAGE_TRACE:-0}" = 1 ] \
  && [ "${FM_AGENT_ROLE:-}" = secondmate ]; then
  mkdir -p "$STATE" && [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
  FM_SESSION_ENROLLMENT_TRACE_FILE="$STATE/.session-enrollment-stage.trace"
  if [ ! -e "$FM_SESSION_ENROLLMENT_TRACE_FILE" ] \
    && [ ! -L "$FM_SESSION_ENROLLMENT_TRACE_FILE" ]; then
    enrollment_trace_tmp=$(mktemp "$STATE/.session-enrollment-stage.trace.XXXXXX") \
      || exit 1
    chmod 600 "$enrollment_trace_tmp" \
      && mv "$enrollment_trace_tmp" "$FM_SESSION_ENROLLMENT_TRACE_FILE" || {
        rm -f "$enrollment_trace_tmp"
        exit 1
      }
  fi
  [ -f "$FM_SESSION_ENROLLMENT_TRACE_FILE" ] \
    && [ ! -L "$FM_SESSION_ENROLLMENT_TRACE_FILE" ] || exit 1
  export FM_SESSION_ENROLLMENT_TRACE_FILE
  if [ "${FM_SESSION_ENROLLMENT_ENDPOINT_GENERATION_PRESENT:-0}" = 1 ]; then
    fm_session_enrollment_trace endpoint-generation-presence present || exit 1
  else
    fm_session_enrollment_trace endpoint-generation-presence absent || exit 1
  fi
fi

fm_session_close_descriptor() {
  local fd=$1 fd_path
  case "$fd" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$fd" -ge 3 ] 2>/dev/null || return 1
  if [ -d "/proc/$$/fd" ]; then
    fd_path="/proc/$$/fd/$fd"
  elif [ -d /dev/fd ]; then
    fd_path="/dev/fd/$fd"
  else
    return 1
  fi
  [ -e "$fd_path" ] || return 1
  exec {fd}<&-
}

if [ -n "${FM_SESSION_AUTHORITY_FD:-}" ] \
  && ! fm_session_descriptor_channel_isolated "$FM_SESSION_AUTHORITY_FD"; then
  if fm_session_authority_durable_capability_present; then
    unset FM_SESSION_AUTHORITY_FD
  else
    echo "error: session authority descriptor isolation is unavailable" >&2
    exit 1
  fi
fi
authority="$STATE/.session-authority"
home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || exit 1
authorized=0
if fm_session_authority_read "$authority" \
  && [ "$FM_SESSION_AUTHORITY_HOME" = "$home_real" ] \
  && fm_session_authority_is_current_ancestor "$authority"; then
  authorized=1
elif [ "${FM_SESSION_AUTHORITY_DURABLE_FD:-}" = 18 ] \
  && fm_session_authority_durable_capability_present \
  && fm_session_durable_custodian_validate \
    "$STATE/.session-durable-authority" \
  && [ "$FM_SESSION_DURABLE_CUSTODIAN_HOME" = "$home_real" ] \
  && [ "$FM_SESSION_DURABLE_CUSTODIAN_CHECKOUT" = "$FM_ROOT" ] \
  && fm_session_process_runs_script \
    "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
    "$FM_ROOT/bin/fm-session-durable-authority.sh" \
  && fm_session_durable_custodian_challenge \
    "$STATE" "$FM_SESSION_DURABLE_CUSTODIAN_PID" \
    "$FM_SESSION_DURABLE_CUSTODIAN_START"; then
  authorized=1
elif [ "${FM_AGENT_ROLE:-}" = secondmate ]; then
  enrollment="$STATE/.session-authority-enrollment"
  enrollment_ticket="$enrollment.consumer.$$"
  if [ -n "$enrollment_confirmed" ]; then
    confirmed_ticket=$(mktemp "${TMPDIR:-/tmp}/fm-enrollment-ticket.XXXXXX") \
      || exit 1
    confirmed_acceptance=$(
      mktemp "${TMPDIR:-/tmp}/fm-enrollment-acceptance.XXXXXX"
    ) || {
      rm -f "$confirmed_ticket"
      exit 1
    }
    if chmod 600 "$confirmed_ticket" "$confirmed_acceptance" \
      && printf '%s' "$enrollment_ticket_data" \
        | openssl base64 -d -A > "$confirmed_ticket" 2>/dev/null \
      && printf '%s' "$enrollment_acceptance_data" \
        | openssl base64 -d -A > "$confirmed_acceptance" 2>/dev/null \
      && fm_session_enrollment_ticket_validate \
        "$confirmed_ticket" "$FM_AGENT_TASK" "$home_real" \
      && [ "$(fm_session_sha256_file "$confirmed_acceptance" 2>/dev/null)" \
        = "$enrollment_confirmed" ] \
      && fm_session_enrollment_acceptance_validate \
        "$confirmed_acceptance" "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
        "$FM_SESSION_ENROLLMENT_NONCE" "$FM_SESSION_ENROLLMENT_PUBLIC_KEY" \
        "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" \
        "$(sed -n '6s/^consumer-public-key-sha256=//p' \
          "$confirmed_acceptance")" \
      && [ "$(sed -n '4s/^consumer-pid=//p' \
        "$confirmed_acceptance")" = "$$" ]; then
      if [ -f "${enrollment}.accepted.final" ] \
        && [ ! -L "${enrollment}.accepted.final" ] \
        && fm_session_enrollment_final_validate \
          "${enrollment}.accepted.final" \
          "$(fm_session_sha256_file "$confirmed_acceptance")" \
          "$FM_SESSION_ENROLLMENT_SIGNER_PID" "$FM_SESSION_ENROLLMENT_NONCE" \
          "$$" "$(fm_session_process_start "$$")" \
          "${FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY:-}" \
          "${FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256:-}" \
        || fm_session_enrollment_final_write \
          "${enrollment}.accepted.final" "$confirmed_acceptance" \
          "$FM_SESSION_ENROLLMENT_SIGNER_PID" "$FM_SESSION_ENROLLMENT_NONCE" \
          "$(sed -n '6s/^consumer-public-key-sha256=//p' \
            "$confirmed_acceptance")"; then
        enrollment_trusted_ticket_data=$enrollment_ticket_data
        enrollment_trusted_acceptance_data=$enrollment_acceptance_data
        enrollment_trusted_consumer_key=${FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY:-}
        authorized=1
      fi
    fi
    rm -f "$confirmed_ticket" "$confirmed_acceptance"
  elif [ -n "$enrollment_authorized" ]; then
    if fm_session_enrollment_ticket_validate \
      "$enrollment_ticket" "$FM_AGENT_TASK" "$home_real" \
      && [ "$(fm_session_sha256_file "${enrollment}.accepted" 2>/dev/null)" \
        = "$enrollment_authorized" ] \
      && fm_session_enrollment_acceptance_validate \
        "${enrollment}.accepted" "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
        "$FM_SESSION_ENROLLMENT_NONCE" "$FM_SESSION_ENROLLMENT_PUBLIC_KEY" \
        "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" \
        "$(sed -n '6s/^consumer-public-key-sha256=//p' \
          "${enrollment}.accepted")" \
      && [ "$(sed -n '4s/^consumer-pid=//p' \
        "${enrollment}.accepted")" = "$$" ]; then
      enrollment_ticket_data=$(openssl base64 -A < "$enrollment_ticket") \
        || exit 1
      enrollment_acceptance_data=$(
        openssl base64 -A < "${enrollment}.accepted"
      ) || exit 1
      rm -f -- "$enrollment_ticket" || exit 1
      enrollment_ticket=
      exec "$SCRIPT_DIR/fm-session-authority-exec.sh" \
        --enrollment-confirmed "$enrollment_authorized" \
        --enrollment-ticket-data "$enrollment_ticket_data" \
        --enrollment-acceptance-data "$enrollment_acceptance_data" \
        --enrollment-launch "$enrollment_launch" "$@"
    fi
  elif [ -z "$enrollment_consumer_key" ]; then
    fm_session_enrollment_consumer_prepare || exit 1
    enrollment_consumer_key=$FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY
    enrollment_consumer_digest=$FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256
  fi
  if [ -z "$enrollment_authorized" ] && [ -z "$enrollment_confirmed" ]; then
    fm_session_enrollment_consumer_key_validate \
      "$enrollment_consumer_key" "$enrollment_consumer_digest" || exit 1
    enrollment_attempts=0
    while [ "$enrollment_attempts" -lt 1500 ] \
      && { [ ! -f "$enrollment" ] || [ -L "$enrollment" ]; }; do
      sleep 0.02
      enrollment_attempts=$((enrollment_attempts + 1))
    done
    if [ -f "$enrollment" ] && [ ! -L "$enrollment" ] \
      && [ ! -e "$enrollment_ticket" ] && [ ! -L "$enrollment_ticket" ] \
      && mv "$enrollment" "$enrollment_ticket"; then
      if fm_session_enrollment_ticket_validate \
          "$enrollment_ticket" "$FM_AGENT_TASK" "$home_real"; then
        if fm_session_enrollment_consumption_request \
            "$enrollment" "$FM_AGENT_TASK" "$home_real"; then
          fm_session_enrollment_trace consume-request-written pass 2>/dev/null || true
          enrollment_attempts=0
          while [ "$enrollment_attempts" -lt 250 ]; do
          if fm_session_enrollment_acceptance_validate \
            "${enrollment}.accepted" "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
            "$FM_SESSION_ENROLLMENT_NONCE" "$FM_SESSION_ENROLLMENT_PUBLIC_KEY" \
            "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" \
            "$enrollment_consumer_digest" \
            && [ "$(sed -n '4s/^consumer-pid=//p' \
              "${enrollment}.accepted")" = "$$" ] \
            && fm_session_enrollment_ack_write \
              "${enrollment}.accepted.ack" "${enrollment}.accepted" \
              "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
              "$FM_SESSION_ENROLLMENT_NONCE" "$enrollment_consumer_digest"; then
            fm_session_enrollment_trace consumer-acceptance-validation pass 2>/dev/null || true
            fm_session_enrollment_trace consumer-pid-binding pass 2>/dev/null || true
            fm_session_enrollment_trace consumer-ack-written pass 2>/dev/null || true
            enrollment_authorized=$(
              fm_session_sha256_file "${enrollment}.accepted"
            ) || exit 1
            fm_session_enrollment_trace consumer-acceptance-digest pass 2>/dev/null || true
            if fm_session_enrollment_ticket_validate \
                "$enrollment_ticket" "$FM_AGENT_TASK" "$home_real" \
              && [ "$(fm_session_sha256_file \
                  "${enrollment}.accepted" 2>/dev/null)" \
                = "$enrollment_authorized" ] \
              && fm_session_enrollment_acceptance_validate \
                "${enrollment}.accepted" "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
                "$FM_SESSION_ENROLLMENT_NONCE" \
                "$FM_SESSION_ENROLLMENT_PUBLIC_KEY" \
                "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" \
                "$enrollment_consumer_digest" \
              && [ "$(sed -n '4s/^consumer-pid=//p' \
                  "${enrollment}.accepted")" = "$$" ]; then
              fm_session_enrollment_trace consumer-acceptance-revalidation pass 2>/dev/null || true
              enrollment_trusted_ticket_data=$(openssl base64 -A < "$enrollment_ticket") \
                || exit 1
              enrollment_trusted_acceptance_data=$(openssl base64 -A < \
                "${enrollment}.accepted") || exit 1
              enrollment_trusted_consumer_key=${FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY:-}
              rm -f -- "$enrollment_ticket" || exit 1
              enrollment_ticket=
              authorized=1
              enrollment_final_pending=1
              fm_session_enrollment_trace consumer-authorized pass 2>/dev/null || true
              break
            fi
          fi
          kill -0 "$FM_SESSION_ENROLLMENT_SIGNER_PID" 2>/dev/null || break
          sleep 0.02
          enrollment_attempts=$((enrollment_attempts + 1))
          done
          if [ "$authorized" -ne 1 ]; then
            rm -f "$enrollment_ticket" "${enrollment}.consume" \
              "${enrollment}.accepted" "${enrollment}.accepted.ack"
          fi
        else
          fm_session_enrollment_trace consume-request-written fail 2>/dev/null || true
          rm -f "$enrollment_ticket" "${enrollment}.consume"
        fi
      else
        rm -f "$enrollment_ticket" "${enrollment}.consume"
      fi
    fi
  fi
elif fm_worker_primary_bootstrap_matches; then
  if [ ! -e "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] \
    && [ ! -e "$STATE/.primary-checkout" ] && [ ! -L "$STATE/.primary-checkout" ] \
    && [ ! -e "$authority" ] && [ ! -L "$authority" ]; then
    authorized=1
  elif [ -d "$STATE/.session-authority-transaction" ] \
    && [ ! -L "$STATE/.session-authority-transaction" ]; then
    authorized=1
  elif fm_session_authority_read_shape "$authority" \
    && [ "$FM_SESSION_AUTHORITY_HOME" = "$home_real" ]; then
    authority_state=0
    fm_session_authority_process_state "$authority" || authority_state=$?
    [ "$authority_state" -eq 1 ] && authorized=1
  fi
fi
[ "$authorized" -eq 1 ] || {
  echo "error: trusted session enrollment capability is missing or invalid" >&2
  exit 1
}
FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED=1
export FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED
mkdir -p "$STATE" && [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: trusted session state directory is unavailable" >&2
  exit 1
}
if [ "$enrollment_final_pending" -eq 1 ]; then
  fm_session_enrollment_acceptance_validate \
      "${enrollment}.accepted" "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
      "$FM_SESSION_ENROLLMENT_NONCE" "$FM_SESSION_ENROLLMENT_PUBLIC_KEY" \
      "$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" \
      "$(sed -n '6s/^consumer-public-key-sha256=//p' \
        "${enrollment}.accepted")" \
    && [ "$(sed -n '4s/^consumer-pid=//p' \
        "${enrollment}.accepted")" = "$$" ] \
    && fm_session_enrollment_final_write \
      "${enrollment}.accepted.final" "${enrollment}.accepted" \
      "$FM_SESSION_ENROLLMENT_SIGNER_PID" \
      "$FM_SESSION_ENROLLMENT_NONCE" \
      "$(sed -n '6s/^consumer-public-key-sha256=//p' \
        "${enrollment}.accepted")" || {
        fm_session_enrollment_trace consumer-final-written fail 2>/dev/null || true
        echo "error: protected session authority launch finalization failed" >&2
        exit 1
      }
  fm_session_enrollment_trace consumer-final-written pass 2>/dev/null || true
fi
enrollment_fd=${FM_SESSION_AUTHORITY_FD:-}
durable_fd=${FM_SESSION_AUTHORITY_DURABLE_FD:-}
if [ "$enrollment_fd" != 9 ] && ( : <&9 ) 2>/dev/null; then
  echo "error: session authority descriptor 9 is already in use" >&2
  exit 1
fi
if ( : <&17 ) 2>/dev/null || ( : >&17 ) 2>/dev/null; then
  echo "error: custodian signing descriptor 17 is already in use" >&2
  exit 1
fi
if [ "${FM_AGENT_ROLE:-}" = secondmate ]; then
  if [ "$enrollment_fd" = 9 ]; then
    exec 9<&-
  elif [ -n "$enrollment_fd" ]; then
    fm_session_close_descriptor "$enrollment_fd" || exit 1
  fi
  unset FM_SESSION_AUTHORITY_FD
  if fm_session_authority_socket_broker_present; then
    if [ "$durable_fd" = 18 ]; then
      exec 18<&-
    elif [ -n "$durable_fd" ]; then
      fm_session_close_descriptor "$durable_fd" || exit 1
    fi
    unset FM_SESSION_AUTHORITY_DURABLE_FD
  elif [ "$durable_fd" = 18 ] \
    && fm_session_authority_durable_capability_present rotation; then
    fm_session_authority_live_descriptor_rotate || {
      fm_session_enrollment_trace consumer-authority-descriptor fail 2>/dev/null || true
      echo "error: protected session authority rotation failed" >&2
      exit 1
    }
  else
    if [ "$durable_fd" = 18 ]; then
      exec 18<&-
    elif [ -n "$durable_fd" ]; then
      fm_session_close_descriptor "$durable_fd" || exit 1
    fi
    unset FM_SESSION_AUTHORITY_DURABLE_FD
    if [ -e "$STATE/.session-durable-authority" ] \
      || [ -L "$STATE/.session-durable-authority" ]; then
        [ -f "$STATE/.session-durable-authority" ] \
          && [ ! -L "$STATE/.session-durable-authority" ] || {
          fm_session_enrollment_trace consumer-authority-descriptor fail 2>/dev/null || true
          echo "error: durable session authority custodian is invalid" >&2
          exit 1
        }
      if [ -z "$durable_recovery" ]; then
        fm_session_durable_consumer_prepare || {
          fm_session_enrollment_trace consumer-authority-descriptor fail 2>/dev/null || true
          echo "error: durable session authority recovery key is unavailable" >&2
          exit 1
        }
        exec "$SCRIPT_DIR/fm-session-authority-exec.sh" \
          --durable-recovery "$FM_SESSION_DURABLE_RECOVERY_NONCE" \
          --durable-consumer-key "$FM_SESSION_DURABLE_CONSUMER_PUBLIC" \
          --durable-consumer-key-sha256 "$FM_SESSION_DURABLE_CONSUMER_SHA256" \
          --enrollment-launch "$enrollment_launch" "$@"
      fi
      fm_session_durable_authority_recover \
        "$STATE" "$home_real" "$FM_ROOT" "$durable_recovery" \
        "$durable_consumer_key" "$durable_consumer_digest" \
        && fm_session_authority_live_descriptor_rotate || {
          fm_session_enrollment_trace consumer-authority-descriptor fail 2>/dev/null || true
          echo "error: durable session authority recovery failed" >&2
          exit 1
        }
    else
      fm_session_authority_descriptor_create || {
        fm_session_enrollment_trace consumer-authority-descriptor fail 2>/dev/null || true
        echo "error: protected session authority descriptor is unavailable" >&2
        exit 1
      }
    fi
  fi
  fm_session_enrollment_trace consumer-authority-descriptor pass 2>/dev/null || true
elif [ "$enrollment_fd" = 9 ] \
  && fm_session_authority_capability_present; then
  if ! fm_session_authority_durable_capability_present; then
    unset FM_SESSION_AUTHORITY_DURABLE_FD
    if [ -e "$STATE/.session-durable-authority" ] \
      || [ -L "$STATE/.session-durable-authority" ]; then
      [ -f "$STATE/.session-durable-authority" ] \
        && [ ! -L "$STATE/.session-durable-authority" ] || {
          echo "error: durable session authority custodian is invalid" >&2
          exit 1
        }
      if [ -z "$durable_recovery" ]; then
        fm_session_durable_consumer_prepare || {
          echo "error: durable session authority recovery key is unavailable" >&2
          exit 1
        }
        exec "$SCRIPT_DIR/fm-session-authority-exec.sh" \
          --durable-recovery "$FM_SESSION_DURABLE_RECOVERY_NONCE" \
          --durable-consumer-key "$FM_SESSION_DURABLE_CONSUMER_PUBLIC" \
          --durable-consumer-key-sha256 "$FM_SESSION_DURABLE_CONSUMER_SHA256" \
          "$@"
      fi
      fm_session_durable_authority_recover \
        "$STATE" "$home_real" "$FM_ROOT" "$durable_recovery" \
        "$durable_consumer_key" "$durable_consumer_digest" || {
          echo "error: durable session authority recovery failed" >&2
          exit 1
        }
    else
      fm_session_authority_durable_descriptor_adopt || {
        echo "error: durable session authority adoption failed" >&2
        exit 1
      }
    fi
  fi
  exec 9<&-
  unset FM_SESSION_AUTHORITY_FD
  fm_session_authority_live_descriptor_rotate || {
    echo "error: protected session authority rotation failed" >&2
    exit 1
  }
elif [ "$durable_fd" = 18 ] \
  && { [ "$enrollment_fd" = 9 ] \
    && fm_session_authority_durable_capability_present \
    || [ "$enrollment_fd" != 9 ] \
    && fm_session_authority_durable_capability_present rotation; }; then
  if [ "$enrollment_fd" = 9 ]; then
    exec 9<&-
  elif [ -n "$enrollment_fd" ]; then
    fm_session_close_descriptor "$enrollment_fd" || exit 1
  fi
  unset FM_SESSION_AUTHORITY_FD
  fm_session_authority_live_descriptor_rotate || {
    echo "error: protected session authority rotation failed" >&2
    exit 1
  }
else
  if [ "$enrollment_fd" = 9 ]; then
    exec 9<&-
  elif [ -n "$enrollment_fd" ]; then
    fm_session_close_descriptor "$enrollment_fd" || exit 1
  fi
  if [ "$durable_fd" = 18 ]; then
    exec 18<&-
  elif [ -n "$durable_fd" ]; then
    fm_session_close_descriptor "$durable_fd" || exit 1
  fi
  unset FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
  if [ -f "$STATE/.session-durable-authority" ] \
    && [ ! -L "$STATE/.session-durable-authority" ]; then
    if [ -z "$durable_recovery" ]; then
      fm_session_durable_consumer_prepare || {
        echo "error: durable session authority recovery key is unavailable" >&2
        exit 1
      }
      exec "$SCRIPT_DIR/fm-session-authority-exec.sh" \
        --durable-recovery "$FM_SESSION_DURABLE_RECOVERY_NONCE" \
        --durable-consumer-key "$FM_SESSION_DURABLE_CONSUMER_PUBLIC" \
        --durable-consumer-key-sha256 "$FM_SESSION_DURABLE_CONSUMER_SHA256" \
        "$@"
    fi
    fm_session_durable_authority_recover \
      "$STATE" "$home_real" "$FM_ROOT" "$durable_recovery" \
      "$durable_consumer_key" "$durable_consumer_digest" \
      && fm_session_authority_live_descriptor_rotate || {
        echo "error: durable session authority recovery failed" >&2
        exit 1
      }
  elif [ -e "$STATE/.session-durable-authority" ] \
    || [ -L "$STATE/.session-durable-authority" ] \
    || [ -e "$authority" ] || [ -L "$authority" ]; then
    echo "error: durable session authority custodian is unavailable" >&2
    exit 1
  else
    fm_session_authority_descriptor_create || {
      echo "error: protected session authority descriptor is unavailable" >&2
      exit 1
    }
  fi
fi
fm_session_authority_transaction_recover "$STATE" || {
  echo "error: session authority recovery could not be verified; operate read-only until resolved" >&2
  exit 1
}
FM_SESSION_AUTHORITY_BROKER_PID=$$
FM_SESSION_AUTHORITY_BROKER_START=$(fm_session_process_start "$$") || exit 1
FM_SESSION_AUTHORITY_BROKER_IDENTITY=$(fm_session_process_identity "$$") || exit 1
FM_SESSION_AUTHORITY_BROKER_SCRIPT="$SCRIPT_DIR/fm-session-authority-exec.sh"
if [ "${FM_AGENT_ROLE:-}" != secondmate ] \
  && [ ! -e "$STATE/.primary-checkout" ] \
  && [ ! -L "$STATE/.primary-checkout" ] \
  && [ ! -e "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] \
  && [ ! -e "$authority" ] && [ ! -L "$authority" ] \
  && [ ! -e "$STATE/.session-authority-live" ] \
  && [ ! -L "$STATE/.session-authority-live" ]; then
  bootstrap_root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || exit 1
  bootstrap_owner=$(fm_session_lock_owner) || exit 1
  bootstrap_checkout_tmp=$(mktemp "$STATE/.primary-checkout.XXXXXX") || exit 1
  bootstrap_lock_tmp=$(mktemp "$STATE/.lock.XXXXXX") || {
    rm -f "$bootstrap_checkout_tmp"
    exit 1
  }
  bootstrap_authority_tmp=$(mktemp "$STATE/.session-authority.XXXXXX") || {
    rm -f "$bootstrap_checkout_tmp" "$bootstrap_lock_tmp"
    exit 1
  }
  bootstrap_live_tmp=$(mktemp "$STATE/.session-authority-live.XXXXXX") || {
    rm -f "$bootstrap_checkout_tmp" "$bootstrap_lock_tmp" \
      "$bootstrap_authority_tmp"
    exit 1
  }
  if chmod 600 "$bootstrap_checkout_tmp" "$bootstrap_lock_tmp" \
      "$bootstrap_authority_tmp" "$bootstrap_live_tmp" \
    && printf '%s\n' "$bootstrap_root" > "$bootstrap_checkout_tmp" \
    && printf '%s\n' "$bootstrap_owner" > "$bootstrap_lock_tmp" \
    && fm_session_authority_write_file \
      "$bootstrap_authority_tmp" "$$" "$bootstrap_owner" \
      "$home_real" "$bootstrap_root" \
    && fm_session_authority_live_binding_write \
      "$STATE" "$bootstrap_live_tmp" "$bootstrap_authority_tmp" \
    && fm_session_authority_transaction_stage \
      "$STATE" "$bootstrap_checkout_tmp" "$bootstrap_lock_tmp" \
      "$bootstrap_authority_tmp" "$bootstrap_live_tmp" \
    && fm_session_authority_transaction_commit "$STATE"; then
    :
  else
    fm_session_authority_transaction_recover "$STATE" || true
    rm -f "$bootstrap_checkout_tmp" "$bootstrap_lock_tmp" \
      "$bootstrap_authority_tmp" "$bootstrap_live_tmp" \
      "$STATE/.primary-checkout" "$STATE/.lock" "$authority" \
      "$STATE/.session-authority-live"
    exit 1
  fi
fi
if fm_session_authority_socket_broker_present; then
  fm_session_enrollment_trace consumer-authority-broker pass 2>/dev/null || true
else
  fm_session_durable_custodian_ensure "$STATE" "$home_real" "$FM_ROOT" || {
    fm_session_enrollment_trace consumer-durable-custodian fail 2>/dev/null || true
    echo "error: durable session authority custodian is unavailable" >&2
    exit 1
  }
  fm_session_enrollment_trace consumer-durable-custodian pass 2>/dev/null || true
fi
[ -z "${FM_SESSION_AUTHORITY_FD:-}" ] || export FM_SESSION_AUTHORITY_FD
[ -z "${FM_SESSION_AUTHORITY_DURABLE_FD:-}" ] \
  || export FM_SESSION_AUTHORITY_DURABLE_FD
export FM_SESSION_AUTHORITY_BROKER_PID
export FM_SESSION_AUTHORITY_BROKER_START FM_SESSION_AUTHORITY_BROKER_IDENTITY
export FM_SESSION_AUTHORITY_BROKER_SCRIPT
fm_session_enrollment_trace consumer-launch-ready pass 2>/dev/null || true
child_pid=
child_pgid=
wrapper_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)
child_group_is_alive() {
  case "$child_pgid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$child_pgid" != "$wrapper_pgid" ] || return 1
  kill -0 -- "-$child_pgid" 2>/dev/null
}
child_is_alive() {
  [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null
}
child_is_running() {
  local state
  child_is_alive || return 1
  state=$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)
  case "$state" in
    Z*) return 1 ;;
  esac
  return 0
}
signal_child() {
  local signal=$1
  [ -n "$child_pid" ] || return 0
  if child_group_is_alive; then
    kill -"$signal" -- "-$child_pgid" 2>/dev/null || true
  else
    kill -"$signal" "$child_pid" 2>/dev/null || true
  fi
}
cleanup_child() {
  local attempts=0
  signal_child TERM
  while child_is_running && [ "$attempts" -lt 50 ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  if child_is_running; then
    signal_child KILL
    attempts=0
    while child_is_running && [ "$attempts" -lt 50 ]; do
      sleep 0.02
      attempts=$((attempts + 1))
    done
  fi
  child_is_running && return 1
  wait "$child_pid" 2>/dev/null || true
  if child_group_is_alive; then
    signal_child KILL
    attempts=0
    while child_group_is_alive && [ "$attempts" -lt 50 ]; do
      sleep 0.02
      attempts=$((attempts + 1))
    done
  fi
  child_group_is_alive && return 1
  return 0
}
forward_hup() {
  trap '' HUP INT TERM
  cleanup_child || exit 1
  exit 129
}
forward_int() {
  trap '' HUP INT TERM
  cleanup_child || exit 1
  exit 130
}
forward_term() {
  trap '' HUP INT TERM
  cleanup_child || exit 1
  exit 143
}
trap forward_hup HUP
trap forward_int INT
trap forward_term TERM
start_child() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 1; exec @ARGV' "$@" &
  else
    "$@" &
  fi
  child_pid=$!
  child_pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)
}
set +e
export -n FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED 2>/dev/null || true
unset FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED FM_SESSION_AUTHORITY_DESCRIPTOR_ORIGIN \
  FM_SESSION_ENROLLMENT_NONCE \
  FM_SESSION_ENROLLMENT_PUBLIC_KEY FM_SESSION_ENROLLMENT_PUBLIC_SHA256 \
  FM_SESSION_ENROLLMENT_SIGNER_PID FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY \
  FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256
start_child "$@"
wait "$child_pid"
status=$?
trap - HUP INT TERM
exit "$status"
