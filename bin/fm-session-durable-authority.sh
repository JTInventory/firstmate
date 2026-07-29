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
unset live_key custodian_private
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
      "$(printf '%sauthority-hmac=%s' "$body" "$hmac")" ] || {
        tmp=$(mktemp "${record}.XXXXXX") || exit 1
        printf '%sauthority-hmac=%s\n' "$body" "$hmac" > "$tmp" \
          && chmod 600 "$tmp" && mv "$tmp" "$record" || {
            rm -f "$tmp"
            exit 1
          }
      }
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
    rm -f "$request" "$response"
  done
  sleep 0.05
done
