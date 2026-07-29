#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

state=$1
home=$2
checkout=$3
session_pid=$4
session_start=$5
[ "$6" = --broker-pid ] || exit 1
broker_pid=$7
[ "$8" = --broker-start ] || exit 1
broker_start=$9
[ "${10}" = --broker-identity ] || exit 1
broker_identity=${11}
[ "${12}" = --broker-script ] || exit 1
broker_script=${13}
[ "${14}" = --custodian-public-key ] || exit 1
custodian_public=${15}
[ "${16}" = --custodian-public-key-sha256 ] || exit 1
custodian_public_digest=${17}
record="$state/.session-durable-authority"
requests="$state/.session-durable-authority-requests"
key=
live_key=
custodian_private=
[ "$broker_script" = "$checkout/bin/fm-session-authority-exec.sh" ] \
  && [ "$(fm_session_parent_pid "$$" 2>/dev/null)" = "$broker_pid" ] \
  && [ "$(fm_session_process_start "$broker_pid" 2>/dev/null)" \
    = "$broker_start" ] \
  && [ "$(fm_session_process_identity "$broker_pid" 2>/dev/null)" \
    = "$broker_identity" ] \
  && fm_session_process_runs_script "$broker_pid" "$broker_script" \
  && [ "$(fm_session_descriptor_identity "$$" 9 2>/dev/null)" \
    = "$(fm_session_descriptor_identity "$broker_pid" 9 2>/dev/null)" ] \
  && [ "$(fm_session_descriptor_identity "$$" 18 2>/dev/null)" \
    = "$(fm_session_descriptor_identity "$broker_pid" 18 2>/dev/null)" ] \
  && [ "$(fm_session_descriptor_identity "$$" 17 2>/dev/null)" \
    = "$(fm_session_descriptor_identity "$broker_pid" 17 2>/dev/null)" ] \
  || exit 1
IFS= read -r key <&18 || exit 1
IFS= read -r live_key <&9 || exit 1
IFS= read -r custodian_private <&17 || exit 1
while IFS= read -r custodian_private_line <&17; do
  custodian_private="${custodian_private}
${custodian_private_line}"
done
[ "${#key}" -ge 64 ] || exit 1
case "$key" in *[!0-9a-f]*) exit 1 ;; esac
[ "${#live_key}" -ge 64 ] || exit 1
case "$live_key" in *[!0-9a-f]*) exit 1 ;; esac
derived_public_pem=$(printf '%s\n' "$custodian_private" \
  | openssl ec -pubout 2>/dev/null) || exit 1
derived_public=$(printf '%s\n' "$derived_public_pem" \
  | openssl base64 -A) || exit 1
[ "$derived_public" = "$custodian_public" ] || exit 1
derived_public_digest_output=$(printf '%s\n' "$derived_public_pem" \
  | openssl dgst -sha256 2>/dev/null) || exit 1
derived_public_digest=${derived_public_digest_output##*= }
[ "$derived_public_digest" = "$custodian_public_digest" ] || exit 1
unset derived_public_pem derived_public derived_public_digest_output
unset derived_public_digest
launch="${record}.launch.$$"
attempts=0
while [ "$attempts" -lt 100 ] \
  && { [ ! -f "$launch" ] || [ -L "$launch" ]; }; do
  sleep 0.02
  attempts=$((attempts + 1))
done
[ -f "$launch" ] && [ ! -L "$launch" ] \
  && [ "$(wc -l < "$launch" | tr -d ' ')" -eq 17 ] \
  && [ "$(sed -n '1p' "$launch")" = version=3 ] \
  && [ "$(sed -n '2s/^pid=//p' "$launch")" = "$$" ] \
  && [ "$(sed -n '3s/^start=//p' "$launch")" \
    = "$(fm_session_process_start "$$" 2>/dev/null)" ] \
  && [ "$(sed -n '4s/^identity=//p' "$launch")" \
    = "$(fm_session_process_identity "$$" 2>/dev/null)" ] \
  && [ "$(sed -n '5s/^state=//p' "$launch")" = "$state" ] \
  && [ "$(sed -n '6s/^home=//p' "$launch")" = "$home" ] \
  && [ "$(sed -n '7s/^checkout=//p' "$launch")" = "$checkout" ] \
  && [ "$(sed -n '8s/^session-pid=//p' "$launch")" = "$session_pid" ] \
  && [ "$(sed -n '9s/^session-start=//p' "$launch")" = "$session_start" ] \
  && [ "$(sed -n '10s/^custodian-public-key=//p' "$launch")" \
    = "$custodian_public" ] \
  && [ "$(sed -n '11s/^custodian-public-key-sha256=//p' "$launch")" \
    = "$custodian_public_digest" ] \
  && [ "$(sed -n '12s/^broker-pid=//p' "$launch")" = "$broker_pid" ] \
  && [ "$(sed -n '13s/^broker-start=//p' "$launch")" = "$broker_start" ] \
  && [ "$(sed -n '14s/^broker-identity=//p' "$launch")" \
    = "$broker_identity" ] \
  && [ "$(sed -n '15s/^broker-script=//p' "$launch")" = "$broker_script" ] \
  || exit 1
launch_body=$(sed -n '1,15p' "$launch")$'\n'
launch_live=$(sed -n '16s/^live-authority-hmac=//p' "$launch")
launch_durable=$(sed -n '17s/^durable-authority-hmac=//p' "$launch")
[ "$launch_live" = "$(printf '%s' "$launch_body" \
    | fm_session_hmac_sha256_key "$live_key")" ] \
  && [ "$launch_durable" = "$(printf '%s' "$launch_body" \
    | fm_session_hmac_sha256_key "$key")" ] || exit 1
rm -f "$launch"
exec 9<&-
exec 18<&-
exec 17<&-
unset live_key
unset FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
unset FM_SESSION_AUTHORITY_BROKER_PID FM_SESSION_AUTHORITY_BROKER_START
unset FM_SESSION_AUTHORITY_BROKER_IDENTITY FM_SESSION_AUTHORITY_BROKER_SCRIPT

start=$(fm_session_process_start "$$") || exit 1
identity=$(fm_session_process_identity "$$") || exit 1
tmp=$(mktemp "${record}.XXXXXX") || exit 1
mkdir -p "$requests" || exit 1
chmod 700 "$requests" || exit 1
body=$(printf 'version=3\npid=%s\nstart=%s\nidentity=%s\nsession-pid=%s\nsession-start=%s\nhome=%s\ncheckout=%s\ncustodian-public-key=%s\ncustodian-public-key-sha256=%s\n' \
  "$$" "$start" "$identity" "$session_pid" "$session_start" "$home" \
  "$checkout" "$custodian_public" "$custodian_public_digest") || exit 1
body="${body}"$'\n'
hmac=$(printf '%s' "$body" | fm_session_hmac_sha256_key "$key") || exit 1
printf '%sauthority-hmac=%s\n' "$body" "$hmac" > "$tmp" \
  && chmod 600 "$tmp" && mv "$tmp" "$record" || {
    rm -f "$tmp"
    exit 1
  }

while :; do
  [ -f "$record" ] && [ ! -L "$record" ] \
    && [ "$(cat "$record" 2>/dev/null)" = \
      "$(printf '%sauthority-hmac=%s' "$body" "$hmac")" ] || exit 0
  for challenge in "$requests"/*.recovery-challenge; do
    [ -e "$challenge" ] || continue
    challenge_response="${challenge}.response"
    [ -f "$challenge" ] && [ ! -L "$challenge" ] \
      && [ ! -e "$challenge_response" ] && [ ! -L "$challenge_response" ] \
      && [ "$(wc -l < "$challenge" | tr -d ' ')" -eq 6 ] \
      && [ "$(sed -n '1p' "$challenge")" = version=1 ] \
      && [ "$(sed -n '3s/^custodian-pid=//p' "$challenge")" = "$$" ] \
      && [ "$(sed -n '4s/^custodian-start=//p' "$challenge")" = "$start" ] \
      || {
        rm -f "$challenge"
        continue
      }
    challenge_requester=$(sed -n '5s/^requester-pid=//p' "$challenge")
    challenge_requester_start=$(sed -n '6s/^requester-start=//p' "$challenge")
    case "$challenge_requester" in
      ''|*[!0-9]*) rm -f "$challenge"; continue ;;
    esac
    [ "$(fm_session_process_start "$challenge_requester" 2>/dev/null)" \
      = "$challenge_requester_start" ] || {
        rm -f "$challenge"
        continue
      }
    challenge_body=$(cat "$challenge")$'\n'
    challenge_hmac=$(printf '%s' "$challenge_body" \
      | fm_session_hmac_sha256_key "$key") || {
        rm -f "$challenge"
        continue
      }
    challenge_signature=$(mktemp "${TMPDIR:-/tmp}/fm-custodian-signature.XXXXXX") \
      || {
        rm -f "$challenge"
        continue
      }
    challenge_body_file=$(mktemp "${TMPDIR:-/tmp}/fm-custodian-body.XXXXXX") \
      || {
        rm -f "$challenge" "$challenge_signature"
        continue
      }
    printf '%s' "$challenge_body" > "$challenge_body_file" \
      && fm_session_enrollment_sign_data \
        "$custodian_private" "$challenge_signature" "$challenge_body_file" \
      && challenge_signature_data=$(openssl base64 -A < "$challenge_signature") \
      || {
        rm -f "$challenge" "$challenge_signature" "$challenge_body_file"
        continue
      }
    rm -f "$challenge_signature" "$challenge_body_file"
    challenge_tmp=$(mktemp "${challenge_response}.XXXXXX") || {
      rm -f "$challenge"
      continue
    }
    printf '%scustodian-signature=%s\nauthority-hmac=%s\n' \
      "$challenge_body" "$challenge_signature_data" "$challenge_hmac" \
      > "$challenge_tmp" \
      && chmod 600 "$challenge_tmp" \
      && mv "$challenge_tmp" "$challenge_response" \
      || rm -f "$challenge_tmp"
    rm -f "$challenge"
  done
  for challenge in "$requests"/*.challenge; do
    [ -e "$challenge" ] || continue
    challenge_response="${challenge}.response"
    [ -f "$challenge" ] && [ ! -L "$challenge" ] \
      && [ ! -e "$challenge_response" ] && [ ! -L "$challenge_response" ] \
      && [ "$(wc -l < "$challenge" | tr -d ' ')" -eq 6 ] \
      && [ "$(sed -n '1p' "$challenge")" = version=1 ] \
      && [ "$(sed -n '3s/^custodian-pid=//p' "$challenge")" = "$$" ] \
      && [ "$(sed -n '4s/^custodian-start=//p' "$challenge")" = "$start" ] \
      || {
        rm -f "$challenge"
        continue
      }
    challenge_requester=$(sed -n '5s/^requester-pid=//p' "$challenge")
    challenge_requester_start=$(sed -n '6s/^requester-start=//p' "$challenge")
    case "$challenge_requester" in
      ''|*[!0-9]*) rm -f "$challenge"; continue ;;
    esac
    [ "$(fm_session_process_start "$challenge_requester" 2>/dev/null)" \
      = "$challenge_requester_start" ] || {
        rm -f "$challenge"
        continue
      }
    challenge_body=$(cat "$challenge")$'\n'
    challenge_hmac=$(printf '%s' "$challenge_body" \
      | fm_session_hmac_sha256_key "$key") || {
        rm -f "$challenge"
        continue
      }
    challenge_tmp=$(mktemp "${challenge_response}.XXXXXX") || {
      rm -f "$challenge"
      continue
    }
    printf '%sauthority-hmac=%s\n' "$challenge_body" "$challenge_hmac" \
      > "$challenge_tmp" \
      && chmod 600 "$challenge_tmp" \
      && mv "$challenge_tmp" "$challenge_response" \
      || rm -f "$challenge_tmp"
    rm -f "$challenge"
  done
  for request in "$requests"/*.request; do
    [ -e "$request" ] || continue
    response="${request%.request}.response"
    [ -f "$request" ] && [ ! -L "$request" ] \
      && [ ! -e "$response" ] && [ ! -L "$response" ] || {
        rm -f "$request"
        continue
      }
    [ "$(wc -l < "$request" | tr -d ' ')" -eq 7 ] || {
      rm -f "$request"
      continue
    }
    requester=$(sed -n '2s/^pid=//p' "$request")
    requester_start=$(sed -n '3s/^start=//p' "$request")
    requester_identity=$(sed -n '4s/^identity=//p' "$request")
    nonce=$(sed -n '5s/^nonce=//p' "$request")
    public_key=$(sed -n '6s/^public-key=//p' "$request")
    public_digest=$(sed -n '7s/^public-key-sha256=//p' "$request")
    case "$requester" in ''|*[!0-9]*) rm -f "$request"; continue ;; esac
    case "$requester_start:$requester_identity:$nonce:$public_key:$public_digest" in
      *$'\n'*|*$'\r'*) rm -f "$request"; continue ;;
    esac
    [ -n "$requester_start" ] && [ -n "$requester_identity" ] \
      && [ -n "$public_key" ] || {
        rm -f "$request"
        continue
      }
    [ "${#nonce}" -eq 64 ] && [ "${#public_digest}" -eq 64 ] || {
      rm -f "$request"
      continue
    }
    case "$nonce:$public_digest" in
      *[!0-9a-f:]*) rm -f "$request"; continue ;;
    esac
    [ "$(sed -n '1p' "$request")" = version=1 ] \
      && [ "$(fm_session_process_start "$requester" 2>/dev/null)" \
        = "$requester_start" ] \
      && [ "$(fm_session_process_identity "$requester" 2>/dev/null)" \
        = "$requester_identity" ] \
      && fm_session_process_runs_script \
        "$requester" "$checkout/bin/fm-session-authority-exec.sh" \
      && [ "$(fm_session_process_session_id "$requester" 2>/dev/null)" \
        = "$session_pid" ] \
      && [ "$(fm_session_process_start "$session_pid" 2>/dev/null)" \
        = "$session_start" ] \
      && [ "$(fm_session_process_argument_value \
        "$requester" --durable-recovery 2>/dev/null)" = "$nonce" ] \
      && [ "$(fm_session_process_argument_value \
        "$requester" --durable-consumer-key-sha256 2>/dev/null)" \
        = "$public_digest" ] || {
          rm -f "$request"
          continue
        }
    requester_role=$(fm_session_process_environment_value \
      "$requester" FM_AGENT_ROLE 2>/dev/null || true)
    requester_task=$(fm_session_process_environment_value \
      "$requester" FM_AGENT_TASK 2>/dev/null || true)
    requester_home=$(fm_session_process_environment_value \
      "$requester" FM_AGENT_OWNER_HOME 2>/dev/null || true)
    role_found=0
    case "$requester_role" in
      "")
        current=$requester
        ;;
      secondmate)
        [ -n "$requester_task" ] && [ "$requester_home" = "$home" ] || {
          rm -f "$request"
          continue
        }
        current=$(fm_session_parent_pid "$requester" 2>/dev/null || printf 1)
        ;;
      *)
        rm -f "$request"
        continue
        ;;
    esac
    while [ "$current" -gt 1 ]; do
      if ! env=$(fm_session_process_environment "$current" 2>/dev/null); then
        role_found=1
        break
      fi
      if printf '%s\n' "$env" | grep -q '^FM_AGENT_ROLE=.'; then
        role_found=1
        break
      fi
      [ "$current" != "$session_pid" ] || break
      current=$(fm_session_parent_pid "$current" 2>/dev/null || printf 1)
    done
    [ "$role_found" -eq 0 ] && [ "$current" = "$session_pid" ] || {
      rm -f "$request"
      continue
    }
    public_file=$(mktemp "${TMPDIR:-/tmp}/fm-durable-public.XXXXXX") || {
      rm -f "$request"
      continue
    }
    encrypted=$(mktemp "${TMPDIR:-/tmp}/fm-durable-encrypted.XXXXXX") || {
      rm -f "$request" "$public_file"
      continue
    }
    if printf '%s' "$public_key" | openssl base64 -d -A \
        > "$public_file" 2>/dev/null \
      && [ "$(fm_session_sha256_file "$public_file" 2>/dev/null)" \
        = "$public_digest" ] \
      && printf '%s\n' "$key" | openssl pkeyutl -encrypt -pubin \
        -inkey "$public_file" -out "$encrypted" 2>/dev/null; then
      response_tmp=$(mktemp "${response}.XXXXXX") || {
        rm -f "$request" "$public_file" "$encrypted"
        continue
      }
      ciphertext=$(openssl base64 -A < "$encrypted") || {
        rm -f "$request" "$public_file" "$encrypted" "$response_tmp"
        continue
      }
      response_body=$(printf 'version=2\nnonce=%s\nciphertext=%s\ncustodian-pid=%s\ncustodian-start=%s\nrequester-pid=%s\nrequester-start=%s\npublic-key-sha256=%s\n' \
        "$nonce" "$ciphertext" "$$" "$start" "$requester" "$requester_start" \
        "$public_digest") || {
          rm -f "$request" "$public_file" "$encrypted" "$response_tmp"
          continue
        }
      response_body="${response_body}"$'\n'
      response_hmac=$(printf '%s' "$response_body" \
        | fm_session_hmac_sha256_key "$key") || {
          rm -f "$request" "$public_file" "$encrypted" "$response_tmp"
          continue
        }
      printf '%sauthority-hmac=%s\n' "$response_body" "$response_hmac" \
        > "$response_tmp" \
        && chmod 600 "$response_tmp" && mv "$response_tmp" "$response" \
        || rm -f "$response_tmp"
    fi
    rm -f "$request" "$public_file" "$encrypted"
  done
  sleep 0.05
done
