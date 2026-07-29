#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

state=$1
home=$2
checkout=$3
session_pid=$4
session_start=$5
record="$state/.session-durable-authority"
requests="$state/.session-durable-authority-requests"
key=
IFS= read -r key <&18 || exit 1
[ "${#key}" -ge 64 ] || exit 1
case "$key" in *[!0-9a-f]*) exit 1 ;; esac
exec 18<&-

start=$(fm_session_process_start "$$") || exit 1
identity=$(fm_session_process_identity "$$") || exit 1
tmp=$(mktemp "${record}.XXXXXX") || exit 1
mkdir -p "$requests" || exit 1
chmod 700 "$requests" || exit 1
printf 'version=1\npid=%s\nstart=%s\nidentity=%s\nsession-pid=%s\nsession-start=%s\nhome=%s\ncheckout=%s\n' \
  "$$" "$start" "$identity" "$session_pid" "$session_start" "$home" \
  "$checkout" > "$tmp" \
  && chmod 600 "$tmp" && mv "$tmp" "$record" || {
    rm -f "$tmp"
    exit 1
  }

while :; do
  [ -f "$record" ] \
    && [ "$(sed -n '2s/^pid=//p' "$record" 2>/dev/null)" = "$$" ] || exit 0
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
      && [ "$(fm_session_process_argument_value \
        "$requester" --durable-recovery 2>/dev/null)" = "$nonce" ] \
      && [ "$(fm_session_process_argument_value \
        "$requester" --durable-consumer-key-sha256 2>/dev/null)" \
        = "$public_digest" ] || {
          rm -f "$request"
          continue
        }
    role_found=0
    current=$requester
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
      printf 'version=1\nnonce=%s\nciphertext=%s\n' "$nonce" \
        "$(openssl base64 -A < "$encrypted")" > "$response_tmp" \
        && chmod 600 "$response_tmp" && mv "$response_tmp" "$response" \
        || rm -f "$response_tmp"
    fi
    rm -f "$request" "$public_file" "$encrypted"
  done
  sleep 0.05
done
