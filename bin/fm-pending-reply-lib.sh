#!/usr/bin/env bash
# fm-pending-reply-lib.sh - parent-owned secondmate missed-report guards.
#
# When the main firstmate delivers a marked from-firstmate request to a
# secondmate, this library records a durable parent-owned pending-reply
# expectation BEFORE delivery, embeds a privacy-safe correlation id in the
# outbound message, and later resolves that expectation only from a correlated
# parent status line or status-pointed document - never from transport success,
# chat content, or unrelated status activity.
#
# Safety property (captain direction 2026-07-22): a secondmate agent may ignore
# the marker and answer only in its visible conversation. The parent must notice
# the missing correlated report without scraping that conversation, send exactly
# one automatic recovery request asking for a repost through the parent channel,
# and escalate once if the recovery turn also completes without a correlated
# report. Never loop, never repeatedly inject, never silently expire unresolved
# records, and never treat wrong-home or structured-home heuristics as
# acknowledgement.
#
# Record location (parent FM_HOME):
#   state/pending-replies/<corr_id>
# Each record is a key=value file owned by this library. Schema:
#   schema=fm-pending-reply.v1
#   corr_id=                privacy-safe correlation token
#   task_id=                secondmate task id in the parent home
#   parent_home=            absolute parent FM_HOME
#   parent_status=          absolute path of parent state/<task_id>.status
#   parent_status_scan_signature=
#   request_summary=        short sanitized summary (no secrets by design)
#   created_epoch=          when the expectation was created
#   delivered_epoch=        when the marked request was confirmed delivered
#                           (empty until delivery; delivery never resolves)
#   phase=                  awaiting_report | delivery_unknown | recovery_sending |
#                           recovery_sent | recovery_failed | recovery_unknown |
#                           escalated | resolved | retired
#   turn_seen_busy=         0|1 after delivery for the original request turn
#   request_turn_completed_epoch=
#   recovery_attempted_epoch=
#   recovery_sender_pid=
#   recovery_sender_identity=
#   recovery_sent_epoch=
#   recovery_delivery_outcome=
#   recovery_turn_seen_busy=
#   recovery_turn_completed_epoch=
#   escalated_epoch=
#   resolved_epoch=
#   resolved_via=           status | document | helper | empty
#   retired_epoch=
#   retired_via=
#   retired_from=
#   retirement_staged_epoch=
#   retirement_history_state=
#   retirement_staged_from=
#   retirement_source_state=
#   wrong_home_hits=        count of corr sightings under the secondmate home
#   wrong_home_sightings=   comma-separated identities of counted sightings
#   wrong_home_scan_signature=
#   grace_secs=             bounded grace before recovery is eligible
#
# Sourced by bin/fm-send.sh, bin/fm-watch.sh, bin/fm-secondmate-report.sh, and
# tests. No side effects on source. set -u / set -e safe.
#
# Tunables (env):
#   FM_PENDING_REPLY_GRACE_SECS   default 120
#   FM_PENDING_REPLY_DIR_OVERRIDE override the pending-replies directory (tests)
#   FM_PENDING_REPLY_SEND_HOOK    optional command template for recovery delivery
#                                 (tests); receives task_id and full message as args
#   FM_PENDING_REPLY_NOW          optional fixed epoch for deterministic tests

# shellcheck source=bin/fm-marker-lib.sh
_FM_PENDING_REPLY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PENDING_REPLY_LIB_DIR="."
# shellcheck source=bin/fm-marker-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-tmux-lib.sh"

FM_PENDING_REPLY_SCHEMA='fm-pending-reply.v1'
FM_PENDING_REPLY_CORR_RE='(^|[^[:alnum:]_])corr=([A-Fa-f0-9]{16})($|[^[:alnum:]_])'
FM_PENDING_REPLY_GRACE_DEFAULT=120

fm_pending_reply_now() {
  if [ -n "${FM_PENDING_REPLY_NOW:-}" ]; then
    printf '%s' "$FM_PENDING_REPLY_NOW"
    return 0
  fi
  date +%s
}

fm_pending_reply_grace_secs() {
  local g=${FM_PENDING_REPLY_GRACE_SECS:-$FM_PENDING_REPLY_GRACE_DEFAULT}
  case "$g" in
    ''|*[!0-9]*) g=$FM_PENDING_REPLY_GRACE_DEFAULT ;;
  esac
  printf '%s' "$g"
}

# Directory holding durable pending-reply records for <state-dir>.
fm_pending_reply_dir() {  # <state-dir>
  local state=$1
  if [ -n "${FM_PENDING_REPLY_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$FM_PENDING_REPLY_DIR_OVERRIDE"
    return 0
  fi
  printf '%s/pending-replies' "$state"
}

fm_pending_reply_history_dir() {  # <state-dir>
  printf '%s/pending-reply-history' "$1"
}

fm_pending_reply_active_path() {  # <state-dir> <corr_id>
  printf '%s/%s' "$(fm_pending_reply_dir "$1")" "$2"
}

fm_pending_reply_path() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 active history
  active=$(fm_pending_reply_active_path "$state" "$corr")
  history="$(fm_pending_reply_history_dir "$state")/$corr"
  if [ -f "$active" ] || [ ! -f "$history" ]; then
    printf '%s' "$active"
  else
    printf '%s' "$history"
  fi
}

fm_pending_reply_source_identity() {  # <state-dir>
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_pending_reply_source_key() {  # <source-state>
  printf '%s' "$1" | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}'
}

fm_pending_reply_handoff_path() {  # <history-state-dir> <source-state> <corr_id>
  local history_state=$1 source_state=$2 corr=$3 source_key
  source_key=$(fm_pending_reply_source_key "$source_state") || return 1
  [ -n "$source_key" ] || return 1
  printf '%s/.handoff-%s-%s' "$(fm_pending_reply_history_dir "$history_state")" "$source_key" "$corr"
}

fm_pending_reply_txn_lock_path() {  # <state-dir> <corr_id>
  printf '%s/.txn-%s.lock' "$(fm_pending_reply_dir "$1")" "$2"
}

fm_pending_reply_txn_lock_value() {  # <lock-path> <key>
  local path=$1 key=$2
  if [ -f "$path" ] && [ ! -d "$path" ]; then
    fm_pending_reply_get "$path" "$key"
  else
    cat "$path/$key" 2>/dev/null || true
  fi
}

fm_pending_reply_txn_owner_write() {  # <owner-path> <pid> <identity> <token> <choosing|waiting|owned> <ticket>
  local owner=$1 pid=$2 identity=$3 token=$4 phase=$5 ticket=$6 tmp
  tmp="$(dirname "$(dirname "$owner")")/.owner-${token}.$$.$RANDOM"
  if ! printf '%s\n' \
    "pid=$pid" \
    "identity=$identity" \
    "token=$token" \
    "phase=$phase" \
    "ticket=$ticket" > "$tmp"; then
    rm -f "$tmp" || true
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$owner" 2>/dev/null; then
    rm -f "$tmp" || true
    return 1
  fi
}

fm_pending_reply_txn_lock_acquire() {  # <state-dir> <corr_id> <result-var>
  local state=$1 corr=$2 result_var=$3 lock owner pid identity lock_token phase ticket
  local existing_pid existing_identity existing_token actual attempt=0 generation
  local incomplete_signature='' incomplete_seen=0 current_signature
  local winner winner_ticket winner_token live_owner live_choosing max_ticket
  local legacy_present
  lock=$(fm_pending_reply_txn_lock_path "$state" "$corr")
  mkdir -p "$(dirname "$lock")" || return 1
  pid=${BASHPID:-$$}
  identity=$(fm_pending_reply_pid_identity "$pid") || return 1
  lock_token="$pid-$RANDOM-$(fm_pending_reply_now)"
  owner="$lock/owner-$lock_token"
  while [ "$attempt" -lt 200 ]; do
    if [ -f "$lock" ] && [ ! -d "$lock" ]; then
      existing_pid=$(fm_pending_reply_txn_lock_value "$lock" pid)
      existing_identity=$(fm_pending_reply_txn_lock_value "$lock" identity)
      existing_token=$(fm_pending_reply_txn_lock_value "$lock" token)
      actual=$(fm_pending_reply_pid_identity "$existing_pid" 2>/dev/null || true)
      if [ -n "$existing_pid" ] && [ -n "$existing_identity" ] && [ -n "$existing_token" ] \
         && [ "$actual" != "$existing_identity" ] \
         && [ "$(fm_pending_reply_txn_lock_value "$lock" token)" = "$existing_token" ]; then
        rm -f "$lock" 2>/dev/null || true
        continue
      fi
      sleep 0.05
      attempt=$((attempt + 1))
      continue
    fi
    mkdir "$lock" 2>/dev/null || [ -d "$lock" ] || return 1
    existing_pid=$(cat "$lock/pid" 2>/dev/null || true)
    existing_identity=$(cat "$lock/identity" 2>/dev/null || true)
    existing_token=$(cat "$lock/token" 2>/dev/null || true)
    if [ -n "$existing_pid" ] || [ -n "$existing_identity" ] || [ -n "$existing_token" ]; then
      if [ -n "$existing_pid" ] && [ -n "$existing_identity" ] && [ -n "$existing_token" ]; then
        actual=$(fm_pending_reply_pid_identity "$existing_pid" 2>/dev/null || true)
        if [ "$actual" != "$existing_identity" ] \
           && [ "$(cat "$lock/token" 2>/dev/null || true)" = "$existing_token" ]; then
          rm -f "$lock/pid" "$lock/identity" "$lock/token" || return 1
          incomplete_signature=
          incomplete_seen=0
          continue
        fi
      else
        current_signature=$(fm_pending_reply_file_signature "$lock")
        if [ "$current_signature" = "$incomplete_signature" ]; then
          incomplete_seen=$((incomplete_seen + 1))
        else
          incomplete_signature=$current_signature
          incomplete_seen=0
        fi
        if [ "$incomplete_seen" -ge 20 ]; then
          rm -f "$lock/pid" "$lock/identity" "$lock/token" || return 1
          incomplete_signature=
          incomplete_seen=0
          continue
        fi
      fi
      sleep 0.05
      attempt=$((attempt + 1))
      continue
    fi
    incomplete_signature=
    incomplete_seen=0
    legacy_present=0
    for generation in "$lock"/owner-*; do
      [ -f "$generation" ] || continue
      existing_pid=$(fm_pending_reply_get "$generation" pid)
      existing_identity=$(fm_pending_reply_get "$generation" identity)
      existing_token=$(fm_pending_reply_get "$generation" token)
      phase=$(fm_pending_reply_get "$generation" phase)
      ticket=$(fm_pending_reply_get "$generation" ticket)
      actual=$(fm_pending_reply_pid_identity "$existing_pid" 2>/dev/null || true)
      if [ -z "$existing_pid" ] || [ -z "$existing_identity" ] || [ -z "$existing_token" ] \
         || [ "$actual" != "$existing_identity" ]; then
        [ "$(fm_pending_reply_get "$generation" token)" = "$existing_token" ] \
          && rm -f "$generation" 2>/dev/null
        continue
      fi
      [ -z "$ticket" ] || continue
      case "$phase" in
        waiting|owned) ;;
        *) rm -f "$owner" 2>/dev/null || true; return 1 ;;
      esac
      legacy_present=1
    done
    if [ "$legacy_present" = 1 ]; then
      rm -f "$owner" 2>/dev/null || true
      return 1
    fi
    if [ ! -f "$owner" ]; then
      if ! fm_pending_reply_txn_owner_write \
        "$owner" "$pid" "$identity" "$lock_token" choosing 0; then
        rm -f "$owner" 2>/dev/null || true
        return 1
      fi
      max_ticket=0
      for generation in "$lock"/owner-*; do
        [ -f "$generation" ] || continue
        existing_pid=$(fm_pending_reply_get "$generation" pid)
        existing_identity=$(fm_pending_reply_get "$generation" identity)
        existing_token=$(fm_pending_reply_get "$generation" token)
        phase=$(fm_pending_reply_get "$generation" phase)
        ticket=$(fm_pending_reply_get "$generation" ticket)
        actual=$(fm_pending_reply_pid_identity "$existing_pid" 2>/dev/null || true)
        if [ -z "$existing_pid" ] || [ -z "$existing_identity" ] || [ -z "$existing_token" ] \
           || [ "$actual" != "$existing_identity" ]; then
          [ "$(fm_pending_reply_get "$generation" token)" = "$existing_token" ] \
            && rm -f "$generation" 2>/dev/null
          continue
        fi
        case "$phase" in
          waiting|owned)
            case "$ticket" in
              '') legacy_present=1; break ;;
              *[!0-9]*) rm -f "$owner" 2>/dev/null || true; return 1 ;;
            esac
            [ "$ticket" -le "$max_ticket" ] || max_ticket=$ticket
            ;;
          choosing) ;;
          *) rm -f "$owner" 2>/dev/null || true; return 1 ;;
        esac
      done
      if [ "$legacy_present" = 1 ]; then
        rm -f "$owner" 2>/dev/null || true
        return 1
      fi
      ticket=$((max_ticket + 1))
      if ! fm_pending_reply_txn_owner_write \
        "$owner" "$pid" "$identity" "$lock_token" waiting "$ticket"; then
        rm -f "$owner" 2>/dev/null || true
        return 1
      fi
    fi
    ticket=$(fm_pending_reply_get "$owner" ticket)
    case "$ticket" in ''|*[!0-9]*) rm -f "$owner" 2>/dev/null || true; return 1 ;; esac
    winner=
    winner_ticket=
    winner_token=
    live_owner=0
    live_choosing=0
    for generation in "$lock"/owner-*; do
      [ -f "$generation" ] || continue
      existing_pid=$(fm_pending_reply_get "$generation" pid)
      existing_identity=$(fm_pending_reply_get "$generation" identity)
      existing_token=$(fm_pending_reply_get "$generation" token)
      phase=$(fm_pending_reply_get "$generation" phase)
      ticket=$(fm_pending_reply_get "$generation" ticket)
      actual=$(fm_pending_reply_pid_identity "$existing_pid" 2>/dev/null || true)
      if [ -z "$existing_pid" ] || [ -z "$existing_identity" ] || [ -z "$existing_token" ] \
         || [ "$actual" != "$existing_identity" ]; then
        [ "$(fm_pending_reply_get "$generation" token)" = "$existing_token" ] \
          && rm -f "$generation" 2>/dev/null
        continue
      fi
      case "$phase" in
        owned)
          if [ -z "$ticket" ]; then
            legacy_present=1
            break
          fi
          case "$ticket" in *[!0-9]*) rm -f "$owner" 2>/dev/null || true; return 1 ;; esac
          if [ "$existing_token" = "$lock_token" ]; then
            printf -v "$result_var" '%s' "$lock_token"
            return 0
          fi
          live_owner=1
          ;;
        choosing)
          live_choosing=1
          ;;
        waiting)
          case "$ticket" in
            '') legacy_present=1; break ;;
            *[!0-9]*) rm -f "$owner" 2>/dev/null || true; return 1 ;;
          esac
          if [ -z "$winner" ] || [ "$ticket" -lt "$winner_ticket" ] \
             || { [ "$ticket" -eq "$winner_ticket" ] \
                  && [[ $existing_token < $winner_token ]]; }; then
            winner=$generation
            winner_ticket=$ticket
            winner_token=$existing_token
          fi
          ;;
        *) rm -f "$owner" 2>/dev/null || true; return 1 ;;
      esac
    done
    if [ "$legacy_present" = 1 ]; then
      rm -f "$owner" 2>/dev/null || true
      return 1
    fi
    if [ "$live_choosing" = 0 ] && [ "$live_owner" = 0 ] && [ "$winner" = "$owner" ]; then
      if ! fm_pending_reply_txn_owner_write \
        "$owner" "$pid" "$identity" "$lock_token" owned "$winner_ticket"; then
        rm -f "$owner" 2>/dev/null || true
        return 1
      fi
      printf -v "$result_var" '%s' "$lock_token"
      return 0
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  rm -f "$owner" 2>/dev/null || true
  return 1
}

fm_pending_reply_txn_lock_release() {  # <state-dir> <corr_id> <token>
  local state=$1 corr=$2 token=$3 lock owner
  lock=$(fm_pending_reply_txn_lock_path "$state" "$corr")
  owner="$lock/owner-$token"
  [ -f "$owner" ] || return 1
  [ "$(fm_pending_reply_get "$owner" token)" = "$token" ] || return 1
  [ "$(fm_pending_reply_get "$owner" phase)" = owned ] || return 1
  rm -f "$owner" || return 1
  rmdir "$lock" 2>/dev/null || true
}

# Privacy-safe correlation id: 16 lowercase hex chars (64 bits of entropy).
fm_pending_reply_new_id() {
  local raw hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" | cksum 2>/dev/null | awk '{print $1}')
    hex=$(printf '%s' "$raw$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:16}
  fi
  printf '%s' "$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)"
}

fm_pending_reply_corr_token() {  # <corr_id>
  printf 'corr=%s' "$1"
}

# Extract the first corr=<16hex> token from free text, or empty.
fm_pending_reply_extract_corr() {  # <text>
  local text=$1
  if [[ $text =~ $FM_PENDING_REPLY_CORR_RE ]]; then
    printf '%s' "${BASH_REMATCH[2]}" | tr 'A-F' 'a-f'
  fi
  return 0
}

# 0 if <text> carries the exact correlation token for <corr_id>.
fm_pending_reply_text_has_corr() {  # <text> <corr_id>
  local text=$1 corr=$2 match consumed
  corr=$(printf '%s' "$corr" | tr 'A-F' 'a-f')
  while [[ $text =~ $FM_PENDING_REPLY_CORR_RE ]]; do
    match=$(printf '%s' "${BASH_REMATCH[2]}" | tr 'A-F' 'a-f')
    [ "$match" = "$corr" ] && return 0
    consumed=${BASH_REMATCH[0]}
    text=${text#*"$consumed"}
  done
  return 1
}

# Sanitize a short request summary: single line, bounded, no control chars.
fm_pending_reply_summarize() {  # <text>
  local text=$1 cleaned
  cleaned=$(printf '%s' "$text" | tr '\t\r\n' '   ' | tr -cd '\11\12\15\40-\176' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Drop an already-present marker/corr prefix so the durable summary stays short.
  cleaned=${cleaned#"$FM_FROMFIRST_MARK"}
  cleaned=$(printf '%s' "$cleaned" | sed -E "s/^corr=[A-Fa-f0-9]{16}[[:space:]]*//")
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

fm_pending_reply_get() {  # <record-path> <key>
  local rec=$1 key=$2
  [ -f "$rec" ] || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_pending_reply_corr_reusable() {  # <state-dir> <corr_id> <task_id>
  local state=$1 corr=$2 task_id=$3 rec phase
  printf '%s' "$corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 1
  rec=$(fm_pending_reply_active_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ "$(fm_pending_reply_get "$rec" task_id)" = "$task_id" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending|recovery_sent) return 0 ;;
  esac
  return 1
}

# Rewrite one key in a pending-reply record atomically. Other keys preserved.
fm_pending_reply_set() {  # <record-path> <key> <value>
  local rec=$1 key=$2 value=$3 dir base tmp line
  [ -f "$rec" ] || return 1
  dir=$(dirname "$rec")
  base=$(basename "$rec")
  tmp="$dir/.${base}.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || return 1
  mv -f "$tmp" "$rec"
}

fm_pending_reply_set_retirement_stage() {  # <record-path> <epoch> <history-state> <source-phase> <source-state>
  local rec=$1 epoch=$2 history_state=$3 source_phase=$4 source_state=$5 dir base tmp line
  [ -f "$rec" ] || return 1
  dir=$(dirname "$rec")
  base=$(basename "$rec")
  tmp="$dir/.${base}.stage.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      retirement_staged_epoch=*|retirement_history_state=*|retirement_staged_from=*|retirement_source_state=*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  printf '%s\n' \
    "retirement_staged_epoch=$epoch" \
    "retirement_history_state=$history_state" \
    "retirement_staged_from=$source_phase" \
    "retirement_source_state=$source_state" >> "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec"
}

fm_pending_reply_clear_retirement_stage() {  # <record-path>
  local rec=$1 dir base tmp line
  [ -f "$rec" ] || return 1
  dir=$(dirname "$rec")
  base=$(basename "$rec")
  tmp="$dir/.${base}.unstage.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      retirement_staged_epoch=*|retirement_history_state=*|retirement_staged_from=*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec"
}

# Embed or replace a correlation token after the from-firstmate marker.
# Idempotent for the same corr; replaces a different leading corr token.
# Result is assigned to <result-var>.
# Trailing newlines in the request body are preserved: never strip via bare
# $(...) on the body (command substitution removes trailing newlines).
fm_pending_reply_embed_corr() {  # <message> <corr_id> <result-var>
  local message=$1 corr=$2 result_var=$3 body token marked existing
  [ -n "$result_var" ] || return 2
  token=$(fm_pending_reply_corr_token "$corr")
  fm_message_mark_from_firstmate "$message" marked
  body=${marked#"$FM_FROMFIRST_MARK"}
  # Strip a leading corr=<16hex> plus following blanks (space/tab only).
  existing=${body:0:21}
  case "$existing" in
    corr=[a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9])
      body=${body:21}
      while [ "${body# }" != "$body" ]; do body=${body# }; done
      while [ "${body#$'\t'}" != "$body" ]; do body=${body#$'\t'}; done
      ;;
  esac
  printf -v "$result_var" '%s' "${FM_FROMFIRST_MARK}${token} ${body}"
}

# Create a durable pending-reply expectation. Prints corr_id on success.
# Does not deliver anything. Fails if parent paths cannot be prepared.
fm_pending_reply_create() {  # <parent-home> <state-dir> <task_id> <request-text>
  local parent_home=$1 state=$2 task_id=$3 request_text=$4
  local dir rec corr now summary status_path tmp
  [ -n "$parent_home" ] && [ -n "$state" ] && [ -n "$task_id" ] || return 2
  dir=$(fm_pending_reply_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  corr=$(fm_pending_reply_new_id)
  [ "${#corr}" -eq 16 ] || return 1
  rec=$(fm_pending_reply_path "$state" "$corr")
  # Extremely unlikely collision; regenerate once.
  if [ -e "$rec" ]; then
    corr=$(fm_pending_reply_new_id)
    rec=$(fm_pending_reply_path "$state" "$corr")
    [ ! -e "$rec" ] || return 1
  fi
  now=$(fm_pending_reply_now)
  summary=$(fm_pending_reply_summarize "$request_text")
  status_path="$state/${task_id}.status"
  # Prefer absolute parent_status when parent_home/state resolve.
  case "$status_path" in
    /*) ;;
    *) status_path="$(cd "$state" 2>/dev/null && pwd)/${task_id}.status" ;;
  esac
  case "$parent_home" in
    /*) ;;
    *) parent_home=$(cd "$parent_home" 2>/dev/null && pwd) || parent_home=$1 ;;
  esac
  tmp="$dir/.${corr}.tmp.$$"
  cat > "$tmp" <<EOF
schema=$FM_PENDING_REPLY_SCHEMA
corr_id=$corr
task_id=$task_id
parent_home=$parent_home
parent_status=$status_path
parent_status_scan_signature=
request_summary=$summary
created_epoch=$now
delivered_epoch=
phase=awaiting_report
turn_seen_busy=0
request_turn_completed_epoch=
recovery_attempted_epoch=
recovery_sender_pid=
recovery_sender_identity=
recovery_sent_epoch=
recovery_delivery_outcome=
recovery_turn_seen_busy=0
recovery_turn_completed_epoch=
escalated_epoch=
resolved_epoch=
resolved_via=
retired_epoch=
retired_via=
retired_from=
retirement_staged_epoch=
retirement_history_state=
retirement_staged_from=
retirement_source_state=
wrong_home_hits=0
wrong_home_sightings=
wrong_home_scan_signature=
grace_secs=$(fm_pending_reply_grace_secs)
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec" || return 1
  printf '%s' "$corr"
}

# Mark delivery success for an existing expectation. Never resolves.
fm_pending_reply_mark_delivered() {  # <state-dir> <corr_id> [confirmed-epoch]
  local state=$1 corr=$2 confirmed_epoch=${3-} rec phase delivered now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|delivery_unknown|recovery_sending|recovery_sent|escalated|resolved) ;;
    *) return 1 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    now=${confirmed_epoch:-$(fm_pending_reply_now)}
    fm_pending_reply_set "$rec" delivered_epoch "$now" || return 1
  fi
  if [ "$phase" = delivery_unknown ]; then
    fm_pending_reply_set "$rec" phase awaiting_report || return 1
  fi
  return 0
}

fm_pending_reply_delivery_confirmation_path() {  # <state-dir> <corr_id>
  printf '%s/.delivery-confirmed-%s' "$(fm_pending_reply_dir "$1")" "$2"
}

fm_pending_reply_write_delivery_confirmation() {  # <state-dir> <corr_id> <state> <value>
  local pending_state=$1 corr=$2 delivery_state=$3 value=$4 marker dir tmp
  marker=$(fm_pending_reply_delivery_confirmation_path "$pending_state" "$corr")
  dir=$(dirname "$marker")
  mkdir -p "$dir" || return 1
  tmp="$marker.tmp.$$"
  printf '%s=%s\n' "$delivery_state" "$value" > "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker"
}

fm_pending_reply_prepare_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 0
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  [ -f "$marker" ] && return 0
  now=$(fm_pending_reply_now)
  fm_pending_reply_write_delivery_confirmation "$state" "$corr" attempted "$now"
}

fm_pending_reply_confirm_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 now marker
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  if ! fm_pending_reply_prepare_delivery "$state" "$corr"; then
    return 1
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_write_delivery_confirmation "$state" "$corr" confirmed "$now" || return 1
  if fm_pending_reply_mark_delivered "$state" "$corr" "$now"; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  return 2
}

fm_pending_reply_reconcile_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker entry delivery_state value epoch
  local grace now age phase
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -n "$delivered" ]; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  [ -f "$marker" ] || return 1
  entry=$(cat "$marker" 2>/dev/null || true)
  delivery_state=${entry%%=*}
  value=${entry#*=}
  case "$delivery_state" in
    confirmed)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      fm_pending_reply_mark_delivered "$state" "$corr" "$epoch" || return 1
      rm -f "$marker" 2>/dev/null || true
      return 0
      ;;
    attempted)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      grace=$(fm_pending_reply_get "$rec" grace_secs)
      case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
      now=$(fm_pending_reply_now)
      age=$((now - epoch))
      [ "$age" -ge "$grace" ] || return 1
      phase=$(fm_pending_reply_get "$rec" phase)
      [ "$phase" = awaiting_report ] || return 1
      fm_pending_reply_set "$rec" phase delivery_unknown || return 1
      return 0
      ;;
  esac
  return 1
}

# Drop an undelivered expectation after a failed send so transport failure does
# not masquerade as a missed report later.
fm_pending_reply_discard_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 0
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  rm -f "$marker" 2>/dev/null || true
  rm -f "$rec"
}

# 0 if a status line is a correlated acknowledgement for <corr_id>.
# Accepts short status replies and status lines that point at a document.
# Unrelated verbs without the token never match. Stale/wrong corr never match.
# The parent's own pending-reply-missed escalation line must not self-resolve:
# it names the request with pending-reply-id= rather than corr=.
fm_pending_reply_line_resolves() {  # <line> <corr_id>
  local line=$1 corr=$2
  [ -n "$line" ] && [ -n "$corr" ] || return 1
  case "$line" in
    *pending-reply-missed*) return 1 ;;
    done:*|done[[:space:]]*|needs-decision:*|needs-decision[[:space:]]*|blocked:*|blocked[[:space:]]*|failed:*|failed[[:space:]]*) ;;
    *) return 1 ;;
  esac
  fm_pending_reply_text_has_corr "$line" "$corr"
}

# Scan a status file for a correlated resolve. Prints the matching line or empty.
fm_pending_reply_find_resolve_line() {  # <status-file> <corr_id>
  local status_file=$1 corr=$2 line
  [ -f "$status_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if fm_pending_reply_line_resolves "$line" "$corr"; then
      printf '%s' "$line"
      return 0
    fi
  done < "$status_file"
  return 0
}

fm_pending_reply_file_signature() {  # <path>
  local path=$1
  [ -f "$path" ] || { printf 'missing'; return 0; }
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null || printf 'unreadable'
  else
    LC_ALL=C stat -c '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null || printf 'unreadable'
  fi
}

fm_pending_reply_status_set_signature() {  # <status-dir>
  local status_dir=$1 status_file signature
  {
    for status_file in "$status_dir"/*.status; do
      [ -f "$status_file" ] || continue
      signature=$(fm_pending_reply_file_signature "$status_file")
      printf '%s:%s:%s\n' "${#status_file}" "$status_file" "$signature"
    done
  } | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}'
}

# Classify how a resolving line acknowledged the request.
fm_pending_reply_resolve_via_of_line() {  # <line>
  local line=$1
  case "$line" in
    *data/*report*|*report.md*|*document*|*pointer*)
      printf 'document'
      ;;
    *via-helper*|*fm-secondmate-report*)
      printf 'helper'
      ;;
    *)
      printf 'status'
      ;;
  esac
}

fm_pending_reply_archive_terminal() {  # <state-dir> <corr_id> [history-state-dir]
  local state=$1 corr=$2 history_state=${3:-$1} active history_dir history phase staged_state source_state
  active=$(fm_pending_reply_active_path "$state" "$corr")
  [ -f "$active" ] || return 0
  phase=$(fm_pending_reply_get "$active" phase)
  case "$phase" in resolved|retired) ;; *) return 1 ;; esac
  if [ "$phase" = resolved ]; then
    staged_state=$(fm_pending_reply_get "$active" retirement_history_state)
    source_state=$(fm_pending_reply_get "$active" retirement_source_state)
    if [ -n "$staged_state" ] && [ -n "$source_state" ]; then
      fm_pending_reply_promote_resolved_record "$active" "$staged_state" "$source_state"
      return $?
    fi
  fi
  history_dir=$(fm_pending_reply_history_dir "$history_state")
  mkdir -p "$history_dir" || return 1
  chmod 700 "$history_dir" 2>/dev/null || true
  history="$history_dir/$corr"
  [ ! -e "$history" ] || return 1
  mv "$active" "$history"
}

fm_pending_reply_prepare_resolved_handoff() {  # <history-path> <history-state-dir> <source-state>
  local history=$1 history_state=$2 source_state=$3 corr task_id receipt tmp line
  corr=$(fm_pending_reply_get "$history" corr_id)
  task_id=$(fm_pending_reply_get "$history" task_id)
  [ -n "$corr" ] && [ -n "$task_id" ] || return 1
  [ "$(fm_pending_reply_get "$history" phase)" = resolved ] || return 1
  receipt=$(fm_pending_reply_handoff_path "$history_state" "$source_state" "$corr") || return 1
  if [ -f "$receipt" ]; then
    [ "$(fm_pending_reply_get "$receipt" corr_id)" = "$corr" ] || return 1
    [ "$(fm_pending_reply_get "$receipt" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$receipt" retirement_source_state)" = "$source_state" ] || return 1
    if [ "$(fm_pending_reply_get "$receipt" phase)" = resolved ]; then
      return 0
    fi
    [ "$(fm_pending_reply_get "$receipt" phase)" = retired ] || return 1
    [ "$(fm_pending_reply_get "$receipt" retired_via)" = forced-teardown ] || return 1
  fi
  tmp="${receipt}.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in retirement_source_state=*|retirement_history_state=*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$history"
  printf '%s\n' \
    "retirement_history_state=$history_state" \
    "retirement_source_state=$source_state" >> "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$receipt"
}

fm_pending_reply_promote_resolved_record() {  # <record-path> <history-state-dir> <source-state>
  local record=$1 history_state=$2 source_state=$3 corr task_id history_dir history receipt tmp line
  [ -f "$record" ] || return 1
  corr=$(fm_pending_reply_get "$record" corr_id)
  task_id=$(fm_pending_reply_get "$record" task_id)
  [ -n "$corr" ] && [ -n "$task_id" ] || return 1
  [ "$(fm_pending_reply_get "$record" phase)" = resolved ] || return 1
  history_dir=$(fm_pending_reply_history_dir "$history_state")
  mkdir -p "$history_dir" || return 1
  chmod 700 "$history_dir" 2>/dev/null || true
  history="$history_dir/$corr"
  if [ "$record" != "$history" ]; then
    if [ -f "$history" ]; then
      [ "$(fm_pending_reply_get "$history" corr_id)" = "$corr" ] || return 1
      [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || return 1
      [ "$(fm_pending_reply_get "$history" phase)" = resolved ] || return 1
      [ "$(fm_pending_reply_get "$history" retirement_source_state)" = "$source_state" ] || return 1
    else
      tmp="$history_dir/.${corr}.resolved.$$"
      : > "$tmp" || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in retirement_source_state=*|retirement_history_state=*) continue ;; esac
        printf '%s\n' "$line" >> "$tmp" || return 1
      done < "$record"
      printf '%s\n' \
        "retirement_history_state=$history_state" \
        "retirement_source_state=$source_state" >> "$tmp" || return 1
      chmod 600 "$tmp" 2>/dev/null || true
      mv "$tmp" "$history" || return 1
    fi
    rm -f "$record" || return 1
  else
    fm_pending_reply_set "$history" retirement_history_state "$history_state" || return 1
    fm_pending_reply_set "$history" retirement_source_state "$source_state" || return 1
  fi
  fm_pending_reply_prepare_resolved_handoff "$history" "$history_state" "$source_state" || return 1
  receipt=$(fm_pending_reply_handoff_path "$history_state" "$source_state" "$corr") || return 1
  [ "$(fm_pending_reply_get "$receipt" phase)" = resolved ] || return 1
  rm -f "$history_dir/.retire-$corr" || return 1
}

fm_pending_reply_handoff_resolved_history() {  # <state-dir> <corr_id> <history-state-dir> <source-state>
  local state=$1 corr=$2 history_state=$3 source_state=$4 source_history history
  source_history="$(fm_pending_reply_history_dir "$state")/$corr"
  history="$(fm_pending_reply_history_dir "$history_state")/$corr"
  if [ -f "$source_history" ]; then
    fm_pending_reply_promote_resolved_record "$source_history" "$history_state" "$source_state"
  elif [ -f "$history" ]; then
    fm_pending_reply_promote_resolved_record "$history" "$history_state" "$source_state"
  else
    return 1
  fi
}

fm_pending_reply_archive_resolved() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 active
  active=$(fm_pending_reply_active_path "$state" "$corr")
  if [ -f "$active" ] && [ "$(fm_pending_reply_get "$active" phase)" != resolved ]; then
    return 1
  fi
  fm_pending_reply_archive_terminal "$state" "$corr"
}

fm_pending_reply_reconcile_resolution() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase delivered resolved via
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = resolved ] || [ "$phase" = retired ]; then
    fm_pending_reply_archive_terminal "$state" "$corr"
    return $?
  fi
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  resolved=$(fm_pending_reply_get "$rec" resolved_epoch)
  via=$(fm_pending_reply_get "$rec" resolved_via)
  [ -n "$delivered" ] && [ -n "$resolved" ] && [ -n "$via" ] || return 2
  fm_pending_reply_set "$rec" phase resolved || return 1
  fm_pending_reply_archive_resolved "$state" "$corr"
}

# Idempotently resolve an expectation from a correlated parent report.
# Returns 0 when the record is resolved after the call (already or newly).
fm_pending_reply_try_resolve_locked() {  # <state-dir> <corr_id> [status-file-override]
  local state=$1 corr=$2 status_override=${3-}
  local rec phase delivered marker delivery_entry delivery_state status_file signature previous line via now
  local unconfirmed=0 reconcile_rc
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  if fm_pending_reply_reconcile_resolution "$state" "$corr"; then
    return 0
  else
    reconcile_rc=$?
  fi
  [ "$reconcile_rc" = 2 ] || return "$reconcile_rc"
  rec=$(fm_pending_reply_path "$state" "$corr")
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = resolved ] || [ "$phase" = retired ]; then
    return 0
  fi
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
    [ -f "$marker" ] || return 2
    delivery_entry=$(cat "$marker" 2>/dev/null || true)
    delivery_state=${delivery_entry%%=*}
    case "$delivery_state" in attempted|confirmed) ;; *) return 1 ;; esac
    unconfirmed=1
  fi
  status_file=${status_override:-$(fm_pending_reply_get "$rec" parent_status)}
  if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
    signature=$(fm_pending_reply_file_signature "$status_file")
    previous=$(fm_pending_reply_get "$rec" parent_status_scan_signature)
    [ "$signature" != "$previous" ] || return 2
  fi
  line=$(fm_pending_reply_find_resolve_line "$status_file" "$corr")
  if [ -z "$line" ]; then
    if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
      fm_pending_reply_set "$rec" parent_status_scan_signature "$signature" || return 1
    fi
    return 2
  fi
  via=$(fm_pending_reply_resolve_via_of_line "$line")
  now=$(fm_pending_reply_now)
  if [ -z "$delivered" ]; then
    fm_pending_reply_mark_delivered "$state" "$corr" "$now" || return 1
    rm -f "$marker" 2>/dev/null || true
  fi
  fm_pending_reply_set "$rec" resolved_epoch "$now" || return 1
  fm_pending_reply_set "$rec" resolved_via "$via" || return 1
  fm_pending_reply_set "$rec" phase resolved || return 1
  fm_pending_reply_archive_resolved "$state" "$corr"
}

fm_pending_reply_try_resolve() {  # <state-dir> <corr_id> [status-file-override]
  local state=$1 corr=$2 status_override=${3-} token rc
  fm_pending_reply_txn_lock_acquire "$state" "$corr" token || return 1
  if fm_pending_reply_try_resolve_locked "$state" "$corr" "$status_override"; then
    rc=0
  else
    rc=$?
  fi
  fm_pending_reply_txn_lock_release "$state" "$corr" "$token" || return 1
  return "$rc"
}

# Observe backend busy/idle evidence for the active turn without reading chat.
# busy_state must be one of: busy | idle | unknown.
fm_pending_reply_observe_busy() {  # <state-dir> <corr_id> <busy_state>
  local state=$1 corr=$2 busy_state=$3
  local rec phase delivered now seen completed field_seen field_completed
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sent) ;;
    *) return 0 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  if [ "$phase" = awaiting_report ]; then
    field_seen=turn_seen_busy
    field_completed=request_turn_completed_epoch
  else
    field_seen=recovery_turn_seen_busy
    field_completed=recovery_turn_completed_epoch
  fi
  seen=$(fm_pending_reply_get "$rec" "$field_seen")
  completed=$(fm_pending_reply_get "$rec" "$field_completed")
  case "$busy_state" in
    busy)
      if [ "$seen" != 1 ]; then
        fm_pending_reply_set "$rec" "$field_seen" 1 || return 1
      fi
      ;;
    idle)
      if [ -z "$completed" ]; then
        # Prefer a busy->idle transition. Also accept a pure idle after delivery
        # when the first observation already missed the busy window (fast turns).
        if [ "$seen" = 1 ] || [ "$seen" = 0 ]; then
          now=$(fm_pending_reply_now)
          fm_pending_reply_set "$rec" "$field_completed" "$now" || return 1
        fi
      fi
      ;;
    unknown)
      # No independent proof; leave completion unset.
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

fm_pending_reply_fallback_idle_eligible() {  # <record-path>
  local rec=$1 phase start seen grace now age
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report)
      start=$(fm_pending_reply_get "$rec" delivered_epoch)
      seen=$(fm_pending_reply_get "$rec" turn_seen_busy)
      ;;
    recovery_sent)
      start=$(fm_pending_reply_get "$rec" recovery_sent_epoch)
      seen=$(fm_pending_reply_get "$rec" recovery_turn_seen_busy)
      ;;
    *) return 1 ;;
  esac
  [ "$seen" = 1 ] && return 0
  grace=$(fm_pending_reply_get "$rec" grace_secs)
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
  now=$(fm_pending_reply_now)
  age=$((now - start))
  [ "$age" -ge "$grace" ]
}

fm_pending_reply_backend_observation() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected_label=${3-} native tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$native" in
    busy|idle) printf '%s' "$native"; return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 "$expected_label" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'busy'
  else
    printf 'fallback-idle'
  fi
}

fm_pending_reply_busy_state_from_observation() {  # <record-path> <observation>
  local rec=$1 observation=$2
  case "$observation" in
    busy|idle|unknown) printf '%s' "$observation" ;;
    fallback-idle)
      if fm_pending_reply_fallback_idle_eligible "$rec"; then
        printf 'idle'
      else
        printf 'unknown'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

# Explicit turn-completion proof (for tests and turn-end backends that surface
# a completion event without a busy/idle pair).
fm_pending_reply_mark_turn_completed() {  # <state-dir> <corr_id> [which: request|recovery]
  local state=$1 corr=$2 which=${3:-request}
  local rec phase field now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$which" in
    request) field=request_turn_completed_epoch ;;
    recovery) field=recovery_turn_completed_epoch ;;
    *) return 2 ;;
  esac
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" "$field" "$now" || return 1
  # Keep phase consistent with which turn completed.
  if [ "$which" = recovery ] && [ "$phase" = awaiting_report ]; then
    : # recovery completion only meaningful after recovery_sent
  fi
  return 0
}

# Build the one automatic recovery message for a pending record.
fm_pending_reply_recovery_message() {  # <record-path>
  local rec=$1 corr summary token msg
  corr=$(fm_pending_reply_get "$rec" corr_id)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  token=$(fm_pending_reply_corr_token "$corr")
  msg="REPOST REQUIRED: previous marked request had no correlated parent report. Reply on the parent status channel including ${token}. Original request: ${summary}"
  fm_pending_reply_embed_corr "$msg" "$corr" msg
  printf '%s' "$msg"
}

# Deliver the recovery message once. Caller must hold phase awaiting_report with
# turn completed and grace elapsed. Uses FM_PENDING_REPLY_SEND_HOOK when set
# (tests), otherwise invokes fm-send with FM_PENDING_REPLY_EXISTING_CORR so a
# second expectation is not created.
fm_pending_reply_send_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed delivered attempted grace now age task_id msg parent_home send_status=0
  local sender_pid sender_identity
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = awaiting_report ] || return 1
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  if [ -n "$attempted" ]; then
    fm_pending_reply_reconcile_recovery "$state" "$corr" || true
    return 1
  fi
  completed=$(fm_pending_reply_get "$rec" request_turn_completed_epoch)
  [ -n "$completed" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 1
  grace=$(fm_pending_reply_get "$rec" grace_secs)
  case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
  now=$(fm_pending_reply_now)
  age=$((now - delivered))
  [ "$age" -ge "$grace" ] || return 1
  task_id=$(fm_pending_reply_get "$rec" task_id)
  parent_home=$(fm_pending_reply_get "$rec" parent_home)
  msg=$(fm_pending_reply_recovery_message "$rec")
  sender_pid=${BASHPID:-$$}
  sender_identity=$(fm_pending_reply_pid_identity "$sender_pid") || return 1
  fm_pending_reply_set "$rec" recovery_sender_pid "$sender_pid" || return 1
  fm_pending_reply_set "$rec" recovery_sender_identity "$sender_identity" || return 1
  fm_pending_reply_set "$rec" recovery_attempted_epoch "$now" || return 1
  fm_pending_reply_set "$rec" phase recovery_sending || return 1
  if [ -n "${FM_PENDING_REPLY_SEND_HOOK:-}" ]; then
    # Hook receives: task_id message
    # shellcheck disable=SC2086
    if ! eval "$FM_PENDING_REPLY_SEND_HOOK" "$(printf '%q' "$task_id")" "$(printf '%q' "$msg")"; then
      send_status=1
    fi
  else
    if [ -z "$parent_home" ] || [ ! -d "$parent_home" ]; then
      send_status=1
    elif ! env FM_HOME="$parent_home" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
      "$_FM_PENDING_REPLY_LIB_DIR/fm-send.sh" "fm-$task_id" "$msg"; then
      send_status=1
    fi
  fi
  if [ "$send_status" = 0 ]; then
    fm_pending_reply_finish_recovery "$state" "$corr" confirmed
    return $?
  fi
  fm_pending_reply_finish_recovery "$state" "$corr" failed || return 1
  return 1
}

fm_pending_reply_pid_identity() {  # <pid>
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s' "$identity"
}

fm_pending_reply_sender_alive() {  # <record-path>
  local rec=$1 pid expected actual
  pid=$(fm_pending_reply_get "$rec" recovery_sender_pid)
  expected=$(fm_pending_reply_get "$rec" recovery_sender_identity)
  [ -n "$expected" ] || return 1
  actual=$(fm_pending_reply_pid_identity "$pid") || return 1
  [ "$actual" = "$expected" ]
}

fm_pending_reply_finish_recovery() {  # <state-dir> <corr_id> <confirmed|failed>
  local state=$1 corr=$2 outcome=$3 rec phase now sent
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = recovery_sending ] || return 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome "$outcome" || return 1
  if [ "$outcome" = confirmed ]; then
    sent=$(fm_pending_reply_get "$rec" recovery_sent_epoch)
    if [ -z "$sent" ]; then
      now=$(fm_pending_reply_now)
      fm_pending_reply_set "$rec" recovery_sent_epoch "$now" || return 1
    fi
    fm_pending_reply_set "$rec" recovery_turn_seen_busy 0 || return 1
    fm_pending_reply_set "$rec" recovery_turn_completed_epoch "" || return 1
    fm_pending_reply_set "$rec" phase recovery_sent || return 1
  else
    [ "$outcome" = failed ] || return 1
    fm_pending_reply_set "$rec" phase recovery_failed || return 1
  fi
}

fm_pending_reply_reconcile_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase attempted outcome
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|recovery_sending) ;; *) return 1 ;; esac
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  [ -n "$attempted" ] || return 1
  case "$attempted" in *[!0-9]*) return 1 ;; esac
  outcome=$(fm_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$outcome" in
    confirmed) fm_pending_reply_finish_recovery "$state" "$corr" confirmed; return $? ;;
    failed) fm_pending_reply_finish_recovery "$state" "$corr" failed; return $? ;;
    unknown)
      fm_pending_reply_set "$rec" phase recovery_unknown || return 1
      return 0
      ;;
  esac
  fm_pending_reply_sender_alive "$rec" && return 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome unknown || return 1
  fm_pending_reply_set "$rec" phase recovery_unknown || return 1
}

# Escalate once after a missed recovery report or failed delivery outcome.
# Retains the durable unresolved record. Never loops.
fm_pending_reply_maybe_escalate_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed now task_id summary payload parent_status outcome resolve_rc
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = delivery_unknown ]; then
    fm_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(fm_pending_reply_get "$rec" phase)
    [ "$phase" = delivery_unknown ] || return 0
  fi
  case "$phase" in
    recovery_sent)
      completed=$(fm_pending_reply_get "$rec" recovery_turn_completed_epoch)
      [ -n "$completed" ] || return 1
      ;;
    delivery_unknown|recovery_failed|recovery_unknown) ;;
    *) return 1 ;;
  esac
  # Resolve wins if a late report arrived between completion and this call.
  if fm_pending_reply_try_resolve_locked "$state" "$corr"; then
    return 0
  else
    resolve_rc=$?
  fi
  [ "$resolve_rc" = 2 ] || return "$resolve_rc"
  task_id=$(fm_pending_reply_get "$rec" task_id)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  # Use pending-reply-id= (not corr=) so this parent-written line cannot be
  # mistaken for a secondmate acknowledgement by fm_pending_reply_line_resolves.
  outcome=$(fm_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$phase" in
    delivery_unknown)
      payload="pending-reply-delivery-unknown: task=${task_id} pending-reply-id=${corr} request=${summary}"
      ;;
    recovery_failed|recovery_unknown)
      payload="pending-reply-recovery-delivery-${outcome}: task=${task_id} pending-reply-id=${corr} request=${summary}"
      ;;
    *) payload="pending-reply-missed: task=${task_id} pending-reply-id=${corr} request=${summary}" ;;
  esac
  [ -n "$parent_status" ] || return 1
  mkdir -p "$(dirname "$parent_status")" 2>/dev/null || return 1
  if ! grep -Fqx "blocked: $payload" "$parent_status" 2>/dev/null; then
    printf 'blocked: %s\n' "$payload" >> "$parent_status" 2>/dev/null || return 1
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" escalated_epoch "$now" || return 1
  fm_pending_reply_set "$rec" phase escalated || return 1
  return 0
}

fm_pending_reply_maybe_escalate() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 token rc
  fm_pending_reply_txn_lock_acquire "$state" "$corr" token || return 1
  if fm_pending_reply_maybe_escalate_locked "$state" "$corr"; then
    rc=0
  else
    rc=$?
  fi
  fm_pending_reply_txn_lock_release "$state" "$corr" "$token" || return 1
  return "$rc"
}

# Detect a correlated report written under the secondmate home (wrong home)
# without treating it as acknowledgement.
fm_pending_reply_detect_wrong_home_locked() {  # <state-dir> <corr_id> <secondmate-home>
  local state=$1 corr=$2 sm_home=$3
  local rec delivered hits sightings snapshot previous status_file line line_no sighting_id phase changed=0
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ -n "$sm_home" ] && [ -d "$sm_home" ] || return 0
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" != resolved ] || return 0
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  snapshot=$(fm_pending_reply_status_set_signature "$sm_home/state")
  previous=$(fm_pending_reply_get "$rec" wrong_home_scan_signature)
  [ "$snapshot" != "$previous" ] || return 0
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  sightings=$(fm_pending_reply_get "$rec" wrong_home_sightings)
  for status_file in "$sm_home"/state/*.status; do
    [ -e "$status_file" ] || continue
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      fm_pending_reply_line_resolves "$line" "$corr" || continue
      sighting_id=$(printf '%s:%s:%s:%s' "${#status_file}" "$status_file" "$line_no" "$line" \
        | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}')
      [ -n "$sighting_id" ] || continue
      case ",$sightings," in
        *",$sighting_id,"*) continue ;;
      esac
      if [ -n "$sightings" ]; then
        sightings="$sightings,$sighting_id"
      else
        sightings=$sighting_id
      fi
      hits=$((hits + 1))
      changed=1
    done < "$status_file"
  done
  if [ "$changed" = 1 ]; then
    fm_pending_reply_set "$rec" wrong_home_sightings "$sightings" || return 1
    fm_pending_reply_set "$rec" wrong_home_hits "$hits" || return 1
  fi
  fm_pending_reply_set "$rec" wrong_home_scan_signature "$snapshot" || return 1
  return 0
}

fm_pending_reply_detect_wrong_home() {  # <state-dir> <corr_id> <secondmate-home>
  local state=$1 corr=$2 sm_home=$3 token rc
  fm_pending_reply_txn_lock_acquire "$state" "$corr" token || return 1
  if fm_pending_reply_detect_wrong_home_locked "$state" "$corr" "$sm_home"; then
    rc=0
  else
    rc=$?
  fi
  fm_pending_reply_txn_lock_release "$state" "$corr" "$token" || return 1
  return "$rc"
}

# One reconciliation tick for a single record: resolve, observe, recover, escalate.
# busy_state is busy|idle|unknown for the secondmate endpoint.
# secondmate_home may be empty when unknown.
fm_pending_reply_tick_one() {  # <state-dir> <corr_id> <busy_state> [secondmate-home]
  local state=$1 corr=$2 busy_state=$3 sm_home=${4-}
  local rec phase delivered
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  fm_pending_reply_reconcile_delivery "$state" "$corr" || true
  phase=$(fm_pending_reply_get "$rec" phase)
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    case "$phase" in
      delivery_unknown) fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true ;;
      escalated) fm_pending_reply_try_resolve "$state" "$corr" >/dev/null 2>&1 || true ;;
    esac
    return 0
  fi
  # Correlated parent report always wins and is idempotent.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending)
      if [ -n "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
        fm_pending_reply_reconcile_recovery "$state" "$corr" || true
        phase=$(fm_pending_reply_get "$rec" phase)
      fi
      ;;
  esac
  case "$phase" in
    resolved) return 0 ;;
    escalated)
      # Unresolved durable record retained; never auto-delete.
      if [ -n "$sm_home" ]; then
        fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
      fi
      return 0
      ;;
    recovery_sending) return 0 ;;
    recovery_failed|recovery_unknown)
      fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      return 0
      ;;
  esac
  if [ -n "$sm_home" ]; then
    fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
  fi
  fm_pending_reply_observe_busy "$state" "$corr" "$busy_state" || true
  # Re-check resolve after observation in case a concurrent status write landed.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = awaiting_report ]; then
    fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null || true
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    recovery_sent|recovery_failed|recovery_unknown)
      fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Scan every pending record for this parent state. Safe to call every poll.
# Never scrapes secondmate conversation; uses only parent status, backend busy
# state, and optional secondmate-home wrong-home path checks.
fm_pending_reply_tick() {  # <state-dir>
  local state=$1 dir rec corr task_id phase delivered meta backend target label busy sm_home
  local observation observation_task found i
  local -a observation_tasks=() observation_values=()
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in
      .*) continue ;;
    esac
    corr=$(fm_pending_reply_get "$rec" corr_id)
    [ -n "$corr" ] || corr=$(basename "$rec")
    task_id=$(fm_pending_reply_get "$rec" task_id)
    phase=$(fm_pending_reply_get "$rec" phase)
    if [ "$phase" = resolved ] || [ "$phase" = retired ]; then
      if [ "$phase" = resolved ]; then
        fm_pending_reply_try_resolve "$state" "$corr" || true
      else
        fm_pending_reply_archive_terminal "$state" "$corr" || true
      fi
      continue
    fi
    if fm_pending_reply_try_resolve "$state" "$corr"; then
      continue
    fi
    fm_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(fm_pending_reply_get "$rec" phase)
    delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
    if [ -z "$delivered" ]; then
      case "$phase" in
        delivery_unknown|escalated)
          fm_pending_reply_tick_one "$state" "$corr" unknown "" || true
          ;;
      esac
      continue
    fi
    case "$phase" in
      awaiting_report|recovery_sending)
        if [ -n "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
          fm_pending_reply_reconcile_recovery "$state" "$corr" || true
          phase=$(fm_pending_reply_get "$rec" phase)
        fi
        ;;
    esac
    meta="$state/${task_id}.meta"
    if [ "$phase" = escalated ]; then
      if fm_pending_reply_try_resolve "$state" "$corr"; then
        continue
      fi
      if [ -f "$meta" ]; then
        sm_home=$(fm_meta_get "$meta" home)
        if [ -n "$sm_home" ]; then
          fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
        fi
      fi
      continue
    fi
    case "$phase" in
      recovery_failed|recovery_unknown)
        fm_pending_reply_tick_one "$state" "$corr" unknown "" || true
        continue
        ;;
    esac
    case "$phase" in
      awaiting_report|recovery_sent) ;;
      *) continue ;;
    esac
    backend=tmux
    target=
    busy=unknown
    sm_home=
    if [ -f "$meta" ]; then
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      sm_home=$(fm_meta_get "$meta" home)
      if [ -n "$target" ]; then
        label="fm-$task_id"
        observation=
        found=0
        for ((i = 0; i < ${#observation_tasks[@]}; i++)); do
          observation_task=${observation_tasks[$i]}
          [ "$observation_task" = "$task_id" ] || continue
          observation=${observation_values[$i]}
          found=1
          break
        done
        if [ "$found" = 0 ]; then
          observation=$(fm_pending_reply_backend_observation "$backend" "$target" "$label")
          observation_tasks+=("$task_id")
          observation_values+=("$observation")
        fi
        busy=$(fm_pending_reply_busy_state_from_observation "$rec" "$observation")
      fi
    fi
    fm_pending_reply_tick_one "$state" "$corr" "$busy" "$sm_home" || true
  done
  return 0
}

# True when any open (non-resolved) pending reply exists for a task.
fm_pending_reply_task_has_open() {  # <state-dir> <task_id>
  local state=$1 task_id=$2 dir rec corr phase tid
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 1
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    tid=$(fm_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task_id" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    case "$phase" in
      resolved|retired)
        if [ "$phase" = resolved ] \
           && [ -n "$(fm_pending_reply_get "$rec" retirement_history_state)" ]; then
          return 0
        fi
        corr=$(fm_pending_reply_get "$rec" corr_id)
        [ -n "$corr" ] || corr=$(basename "$rec")
        if [ "$phase" = resolved ]; then
          fm_pending_reply_try_resolve "$state" "$corr" || return 0
        else
          fm_pending_reply_archive_terminal "$state" "$corr" || return 0
        fi
        continue
        ;;
    esac
    return 0
  done
  return 1
}

fm_pending_reply_task_force_retirable() {  # <state-dir> <task_id>
  local state=$1 task_id=$2 dir rec phase tid
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    tid=$(fm_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task_id" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    case "$phase" in
      resolved|retired|escalated|recovery_failed|recovery_unknown) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

fm_pending_reply_stage_force_retire_one_locked() {  # <state-dir> <task-id> <history-state-dir> <source-state> <record> <corr-id> <now>
  local state=$1 task_id=$2 history_state=$3 source_state=$4 rec=$5 corr=$6 now=$7
  local phase source_phase staged_epoch staged_history staged_from staged_source
  [ -f "$rec" ] || return 0
  [ "$(fm_pending_reply_get "$rec" task_id)" = "$task_id" ] || return 0
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    resolved)
      fm_pending_reply_archive_terminal "$state" "$corr" || return 1
      fm_pending_reply_handoff_resolved_history \
        "$state" "$corr" "$history_state" "$source_state"
      return $?
      ;;
    retired)
      fm_pending_reply_archive_terminal "$state" "$corr" "$history_state"
      return $?
      ;;
  esac
  staged_epoch=$(fm_pending_reply_get "$rec" retirement_staged_epoch)
  staged_history=$(fm_pending_reply_get "$rec" retirement_history_state)
  staged_from=$(fm_pending_reply_get "$rec" retirement_staged_from)
  staged_source=$(fm_pending_reply_get "$rec" retirement_source_state)
  source_phase=${staged_from:-$phase}
  case "$source_phase" in escalated|recovery_failed|recovery_unknown) ;; *) return 1 ;; esac
  [ -z "$staged_history" ] || [ "$staged_history" = "$history_state" ] || return 1
  [ -z "$staged_source" ] || [ "$staged_source" = "$source_state" ] || return 1
  [ -n "$staged_epoch" ] || staged_epoch=$now
  fm_pending_reply_set_retirement_stage \
    "$rec" "$staged_epoch" "$history_state" "$source_phase" "$source_state" || return 1
  case "$phase" in
    recovery_failed|recovery_unknown)
      fm_pending_reply_maybe_escalate_locked "$state" "$corr" || return 1
      rec=$(fm_pending_reply_active_path "$state" "$corr")
      if [ ! -f "$rec" ]; then
        fm_pending_reply_handoff_resolved_history \
          "$state" "$corr" "$history_state" "$source_state"
        return $?
      fi
      phase=$(fm_pending_reply_get "$rec" phase)
      [ "$phase" = escalated ] || return 1
      ;&
    escalated)
      fm_pending_reply_prepare_forced_retirement "$rec" "$history_state" "$source_state"
      return $?
      ;;
  esac
}

fm_pending_reply_stage_force_retire_one() {  # <state-dir> <task-id> <history-state-dir> <source-state> <record> <corr-id> <now>
  local state=$1 task_id=$2 history_state=$3 source_state=$4 rec=$5 corr=$6 now=$7 token rc
  fm_pending_reply_txn_lock_acquire "$state" "$corr" token || return 1
  if fm_pending_reply_stage_force_retire_one_locked \
    "$state" "$task_id" "$history_state" "$source_state" "$rec" "$corr" "$now"; then
    rc=0
  else
    rc=$?
  fi
  fm_pending_reply_txn_lock_release "$state" "$corr" "$token" || return 1
  return "$rc"
}

fm_pending_reply_handoff_resolved_task_history() {  # <state-dir> <task-id> <history-state-dir> <source-state> [result-var]
  local state=$1 task_id=$2 history_state=$3 source_state=$4 result_var=${5-}
  local history_dir history corr token rc migrated=0
  local retained_dir retained source_key receipt
  [ -z "$result_var" ] || printf -v "$result_var" '%s' 0
  [ "$state" != "$history_state" ] || return 0
  history_dir=$(fm_pending_reply_history_dir "$state")
  [ -d "$history_dir" ] || return 0
  for history in "$history_dir"/*; do
    [ -f "$history" ] || continue
    [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || continue
    [ "$(fm_pending_reply_get "$history" phase)" = resolved ] || continue
    corr=$(fm_pending_reply_get "$history" corr_id)
    [ -n "$corr" ] || continue
    fm_pending_reply_txn_lock_acquire "$state" "$corr" token || return 1
    if [ -f "$history" ]; then
      if fm_pending_reply_handoff_resolved_history \
        "$state" "$corr" "$history_state" "$source_state"; then
        rc=0
        migrated=1
      else
        rc=$?
      fi
    else
      rc=0
    fi
    fm_pending_reply_txn_lock_release "$state" "$corr" "$token" || return 1
    [ "$rc" -eq 0 ] || return "$rc"
  done
  source_key=$(fm_pending_reply_source_key "$source_state") || return 1
  retained_dir=$(fm_pending_reply_history_dir "$history_state")
  for receipt in "$retained_dir"/.handoff-"$source_key"-*; do
    [ -f "$receipt" ] || continue
    [ "$(fm_pending_reply_get "$receipt" task_id)" = "$task_id" ] || continue
    [ "$(fm_pending_reply_get "$receipt" retirement_source_state)" = "$source_state" ] \
      || return 1
    [ "$(fm_pending_reply_get "$receipt" phase)" = resolved ] || continue
    migrated=1
  done
  for retained in "$retained_dir"/*; do
    [ -f "$retained" ] || continue
    [ "$(fm_pending_reply_get "$retained" task_id)" = "$task_id" ] || continue
    [ "$(fm_pending_reply_get "$retained" phase)" = resolved ] || continue
    [ "$(fm_pending_reply_get "$retained" retirement_source_state)" = "$source_state" ] \
      || continue
    [ "$(fm_pending_reply_get "$retained" retirement_history_state)" = "$history_state" ] \
      || continue
    migrated=1
  done
  [ -z "$result_var" ] || printf -v "$result_var" '%s' "$migrated"
}

fm_pending_reply_stage_force_retire_task() {  # <state-dir> <task_id> [history-state-dir]
  local state=$1 task_id=$2 history_state=${3:-$1} dir rec corr now source_state
  fm_pending_reply_task_force_retirable "$state" "$task_id" || return 1
  source_state=$(fm_pending_reply_source_identity "$state") || return 1
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  now=$(fm_pending_reply_now)
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$task_id" ] || continue
    corr=$(fm_pending_reply_get "$rec" corr_id)
    [ -n "$corr" ] || corr=$(basename "$rec")
    fm_pending_reply_stage_force_retire_one \
      "$state" "$task_id" "$history_state" "$source_state" "$rec" "$corr" "$now" || return 1
  done
  fm_pending_reply_handoff_resolved_task_history \
    "$state" "$task_id" "$history_state" "$source_state"
}

fm_pending_reply_prepare_forced_retirement() {  # <record-path> <history-state-dir> <source-state>
  local rec=$1 history_state=$2 source_state=$3 corr task_id staged_from history_dir history staged tmp line now
  corr=$(fm_pending_reply_get "$rec" corr_id)
  task_id=$(fm_pending_reply_get "$rec" task_id)
  staged_from=$(fm_pending_reply_get "$rec" retirement_staged_from)
  [ -n "$corr" ] && [ -n "$task_id" ] || return 1
  case "$staged_from" in escalated|recovery_failed|recovery_unknown) ;; *) return 1 ;; esac
  history_dir=$(fm_pending_reply_history_dir "$history_state")
  mkdir -p "$history_dir" || return 1
  chmod 700 "$history_dir" 2>/dev/null || true
  history="$history_dir/$corr"
  staged=$(fm_pending_reply_handoff_path "$history_state" "$source_state" "$corr") || return 1
  if [ -f "$history" ]; then
    [ "$(fm_pending_reply_get "$history" corr_id)" = "$corr" ] || return 1
    [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$history" phase)" = retired ] || return 1
    [ "$(fm_pending_reply_get "$history" retired_via)" = forced-teardown ] || return 1
    [ "$(fm_pending_reply_get "$history" retired_from)" = "$staged_from" ] || return 1
    [ "$(fm_pending_reply_get "$history" retirement_source_state)" = "$source_state" ] || return 1
    return 0
  fi
  if [ -f "$staged" ]; then
    [ "$(fm_pending_reply_get "$staged" corr_id)" = "$corr" ] || return 1
    [ "$(fm_pending_reply_get "$staged" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$staged" phase)" = retired ] || return 1
    [ "$(fm_pending_reply_get "$staged" retired_via)" = forced-teardown ] || return 1
    [ "$(fm_pending_reply_get "$staged" retired_from)" = "$staged_from" ] || return 1
    [ "$(fm_pending_reply_get "$staged" retirement_source_state)" = "$source_state" ] || return 1
    return 0
  fi
  tmp="$history_dir/.${corr}.retire.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      phase=*|retired_epoch=*|retired_via=*|retired_from=*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  now=$(fm_pending_reply_now)
  printf '%s\n' \
    "retired_epoch=$now" \
    "retired_via=forced-teardown" \
    "retired_from=$staged_from" \
    "phase=retired" >> "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  [ ! -e "$staged" ] || return 1
  mv "$tmp" "$staged"
}

fm_pending_reply_finalize_force_retire_one_locked() {  # <state-dir> <task-id> <history-state-dir> <source-state> <corr-id>
  local state=$1 task_id=$2 history_state=$3 source_state=$4 corr=$5
  local active receipt history phase staged_history staged_source staged_from receipt_phase resolve_rc
  active=$(fm_pending_reply_active_path "$state" "$corr")
  receipt=$(fm_pending_reply_handoff_path "$history_state" "$source_state" "$corr") || return 1
  history="$(fm_pending_reply_history_dir "$history_state")/$corr"
  if [ -f "$active" ]; then
    [ "$(fm_pending_reply_get "$active" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$active" corr_id)" = "$corr" ] || return 1
    phase=$(fm_pending_reply_get "$active" phase)
    case "$phase" in
      resolved)
        fm_pending_reply_archive_terminal "$state" "$corr" || return 1
        ;;
      retired)
        fm_pending_reply_archive_terminal "$state" "$corr" "$history_state" || return 1
        ;;
      escalated)
        staged_history=$(fm_pending_reply_get "$active" retirement_history_state)
        staged_source=$(fm_pending_reply_get "$active" retirement_source_state)
        staged_from=$(fm_pending_reply_get "$active" retirement_staged_from)
        [ "$staged_history" = "$history_state" ] || return 1
        [ "$staged_source" = "$source_state" ] || return 1
        case "$staged_from" in escalated|recovery_failed|recovery_unknown) ;; *) return 1 ;; esac
        if fm_pending_reply_try_resolve_locked "$state" "$corr"; then
          resolve_rc=0
        else
          resolve_rc=$?
        fi
        case "$resolve_rc" in 0|2) ;; *) return "$resolve_rc" ;; esac
        ;;
      *) return 1 ;;
    esac
  fi
  active=$(fm_pending_reply_active_path "$state" "$corr")
  if [ -f "$history" ] && [ "$(fm_pending_reply_get "$history" phase)" = resolved ]; then
    [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$history" corr_id)" = "$corr" ] || return 1
    [ "$(fm_pending_reply_get "$history" retirement_source_state)" = "$source_state" ] || return 1
    if [ -f "$receipt" ]; then
      [ "$(fm_pending_reply_get "$receipt" task_id)" = "$task_id" ] || return 1
      [ "$(fm_pending_reply_get "$receipt" corr_id)" = "$corr" ] || return 1
      [ "$(fm_pending_reply_get "$receipt" retirement_source_state)" = "$source_state" ] || return 1
      case "$(fm_pending_reply_get "$receipt" phase)" in resolved|retired) ;; *) return 1 ;; esac
      rm -f "$receipt" || return 1
    fi
    if [ -f "$active" ]; then
      [ "$(fm_pending_reply_get "$active" task_id)" = "$task_id" ] || return 1
      phase=$(fm_pending_reply_get "$active" phase)
      case "$phase" in resolved|escalated) ;; *) return 1 ;; esac
      if [ "$phase" = escalated ]; then
        [ "$(fm_pending_reply_get "$active" retirement_history_state)" = "$history_state" ] || return 1
        [ "$(fm_pending_reply_get "$active" retirement_source_state)" = "$source_state" ] || return 1
      fi
      rm -f "$active" || return 1
    fi
    fm_pending_reply_clear_retirement_stage "$history" || return 1
    return 0
  fi
  if [ -f "$receipt" ]; then
    [ "$(fm_pending_reply_get "$receipt" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$receipt" corr_id)" = "$corr" ] || return 1
    [ "$(fm_pending_reply_get "$receipt" retirement_source_state)" = "$source_state" ] || return 1
    receipt_phase=$(fm_pending_reply_get "$receipt" phase)
    [ "$receipt_phase" = retired ] || return 1
    [ "$(fm_pending_reply_get "$receipt" retired_via)" = forced-teardown ] || return 1
    if [ -f "$history" ]; then
      [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || return 1
      [ "$(fm_pending_reply_get "$history" corr_id)" = "$corr" ] || return 1
      [ "$(fm_pending_reply_get "$history" phase)" = retired ] || return 1
      [ "$(fm_pending_reply_get "$history" retired_via)" = forced-teardown ] || return 1
      [ "$(fm_pending_reply_get "$history" retired_from)" = \
        "$(fm_pending_reply_get "$receipt" retired_from)" ] || return 1
      [ "$(fm_pending_reply_get "$history" retirement_source_state)" = "$source_state" ] || return 1
      rm -f "$receipt" || return 1
    else
      mv "$receipt" "$history" || return 1
    fi
  fi
  [ -f "$history" ] || return 1
  [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || return 1
  [ "$(fm_pending_reply_get "$history" corr_id)" = "$corr" ] || return 1
  [ "$(fm_pending_reply_get "$history" phase)" = retired ] || return 1
  [ "$(fm_pending_reply_get "$history" retired_via)" = forced-teardown ] || return 1
  [ "$(fm_pending_reply_get "$history" retirement_source_state)" = "$source_state" ] || return 1
  if [ -f "$active" ]; then
    [ "$(fm_pending_reply_get "$active" task_id)" = "$task_id" ] || return 1
    [ "$(fm_pending_reply_get "$active" phase)" = escalated ] || return 1
    staged_history=$(fm_pending_reply_get "$active" retirement_history_state)
    staged_source=$(fm_pending_reply_get "$active" retirement_source_state)
    staged_from=$(fm_pending_reply_get "$active" retirement_staged_from)
    [ "$staged_history" = "$history_state" ] || return 1
    [ "$staged_source" = "$source_state" ] || return 1
    [ "$(fm_pending_reply_get "$history" retired_from)" = "$staged_from" ] || return 1
    rm -f "$active" || return 1
  fi
  fm_pending_reply_clear_retirement_stage "$history" || return 1
}

fm_pending_reply_finalize_force_retire_one() {  # <state-dir> <task-id> <history-state-dir> <source-state> <corr-id>
  local state=$1 task_id=$2 history_state=$3 source_state=$4 corr=$5 token rc
  fm_pending_reply_txn_lock_acquire "$state" "$corr" token || return 1
  if fm_pending_reply_finalize_force_retire_one_locked \
    "$state" "$task_id" "$history_state" "$source_state" "$corr"; then
    rc=0
  else
    rc=$?
  fi
  fm_pending_reply_txn_lock_release "$state" "$corr" "$token" || return 1
  return "$rc"
}

fm_pending_reply_finalize_force_retire_task() {  # <state-dir> <task_id> [history-state-dir] [source-state]
  local state=$1 task_id=$2 history_state=${3:-$1} source_state=${4-}
  local dir history_dir source_key rec staged history corr found=0
  if [ -z "$source_state" ]; then
    source_state=$(fm_pending_reply_source_identity "$state") || return 1
  fi
  source_key=$(fm_pending_reply_source_key "$source_state") || return 1
  [ -n "$source_key" ] || return 1
  dir=$(fm_pending_reply_dir "$state")
  history_dir=$(fm_pending_reply_history_dir "$history_state")
  if [ -d "$dir" ]; then
    for rec in "$dir"/*; do
      [ -f "$rec" ] || continue
      [ "$(fm_pending_reply_get "$rec" task_id)" = "$task_id" ] || continue
      corr=$(fm_pending_reply_get "$rec" corr_id)
      [ -n "$corr" ] || return 1
      fm_pending_reply_finalize_force_retire_one \
        "$state" "$task_id" "$history_state" "$source_state" "$corr" || return 1
      found=1
    done
  fi
  for staged in "$history_dir"/.handoff-"$source_key"-*; do
    [ -f "$staged" ] || continue
    [ "$(fm_pending_reply_get "$staged" task_id)" = "$task_id" ] || continue
    [ "$(fm_pending_reply_get "$staged" retirement_source_state)" = "$source_state" ] || return 1
    corr=$(fm_pending_reply_get "$staged" corr_id)
    [ -n "$corr" ] || return 1
    fm_pending_reply_finalize_force_retire_one \
      "$state" "$task_id" "$history_state" "$source_state" "$corr" || return 1
    found=1
  done
  for history in "$history_dir"/*; do
    [ -f "$history" ] || continue
    [ "$(fm_pending_reply_get "$history" task_id)" = "$task_id" ] || continue
    [ "$(fm_pending_reply_get "$history" retirement_source_state)" = "$source_state" ] || continue
    corr=$(fm_pending_reply_get "$history" corr_id)
    [ -n "$corr" ] || return 1
    fm_pending_reply_finalize_force_retire_one \
      "$state" "$task_id" "$history_state" "$source_state" "$corr" || return 1
    found=1
  done
  [ "$found" = 1 ]
}
