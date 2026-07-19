#!/usr/bin/env bash
# Guarded lifecycle helper for isolated Herdr lab sessions.
#
# Usage: fm-herdr-lab.sh name <label>
#        fm-herdr-lab.sh prepare|provision|stop|teardown <fm-lab-session>
#        fm-herdr-lab.sh run <fm-lab-session> <herdr-subcommand> [args...]
#
# Only names beginning with fm-lab- are accepted. The default session is never
# a valid target. Destructive commands require an ownership tripwire recording
# the captain's running default session before the lab was provisioned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

fm_herdr_lab_error() { echo "fm-herdr-lab: $*" >&2; }

fm_herdr_lab_validate_name() {
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[A-Za-z0-9][A-Za-z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error 'refusing an empty session name' ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() { printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID:-0}}"; }
fm_herdr_lab_tripwire_path() { printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"; }

fm_herdr_lab_raw() {
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { fm_herdr_lab_raw "$1" session list --json; }

fm_herdr_lab_fleet_state() {
  local name=$1 sessions snapshot
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error 'cannot read Herdr sessions for the fleet-state tripwire'
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error 'fleet-state tripwire requires exactly one running default session'
    return 1
  }
  printf '%s\n' "$snapshot"
}

fm_herdr_lab_prepare() {
  local name=$1 sessions state_dir tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error 'herdr is required'; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error 'jq is required'; return 1; }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg want "$name" '.sessions[]? | select(.name == $want)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi
  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || { fm_herdr_lab_error "tripwire already exists for '$name'"; return 1; }
  fm_herdr_lab_fleet_state "$name" > "$tripwire" || { rm -f "$tripwire"; return 1; }
}

fm_herdr_lab_refuse_if_default() {
  local name=$1 sessions flag
  fm_herdr_lab_validate_name "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error 'refusing destructive call because session list failed'
    return 1
  }
  flag=$(printf '%s' "$sessions" | jq -r --arg want "$name" '.sessions[]? | select(.name == $want) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_guard_destructive() {
  local name=$1
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_refuse_if_default "$name"
}

fm_herdr_lab_cli() {
  local name=${1:-} arg
  shift || true
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error 'run requires Herdr arguments'; return 1; }
  case "$1" in
    -*) fm_herdr_lab_error 'run forbids a leading option before the Herdr subcommand'; return 1 ;;
  esac
  for arg in "$@"; do
    case "$arg" in --session|--session=*) fm_herdr_lab_error 'run forbids caller-supplied --session'; return 1 ;; esac
  done
  case "$1 ${2:-}" in
    'server '*) fm_herdr_lab_error 'run forbids server operations; use provision'; return 1 ;;
    'session stop'|'session delete'|'session create'|'session rename') fm_herdr_lab_error 'run forbids session lifecycle operations; use guarded lifecycle commands'; return 1 ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

fm_herdr_lab_cancel_server() {
  local pid=$1 attempt=0
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 20 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() {
  local name=$1 sessions tripwire running pid attempt=0
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error 'herdr is required'; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error 'jq is required'; return 1; }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
  if printf '%s' "$sessions" | jq -e --arg want "$name" '.sessions[]? | select(.name == $want)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || { fm_herdr_lab_error "missing tripwire for existing session '$name'"; return 1; }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg want "$name" '.sessions[]? | select(.name == $want) | .running' 2>/dev/null)
    [ "$running" = false ] || { fm_herdr_lab_error "session '$name' is already running"; return 1; }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  pid=$!
  while [ "$attempt" -lt 300 ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null || true)
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || { fm_herdr_lab_cancel_server "$pid"; return 1; }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_server "$pid"
  fm_herdr_lab_error "lab session '$name' did not report running within 60 seconds"
  return 1
}

fm_herdr_lab_check_tripwire() {
  local name=$1 tripwire before after
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || { fm_herdr_lab_error "missing tripwire for '$name'; refusing unverified teardown"; return 1; }
  before=$(cat "$tripwire")
  after=$(fm_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error 'FLEET-STATE TRIPWIRE FAILED: default session changed during lab work'
    return 1
  }
}

fm_herdr_lab_verify_tripwire() {
  local name=$1
  fm_herdr_lab_check_tripwire "$name" || return 1
  rm -f "$(fm_herdr_lab_tripwire_path "$name")"
}

fm_herdr_lab_stop() {
  local name=$1
  fm_herdr_lab_validate_name "$name" || return 1
  [ -f "$(fm_herdr_lab_tripwire_path "$name")" ] || { fm_herdr_lab_error "missing tripwire for '$name'; refusing stop"; return 1; }
  fm_herdr_lab_guard_destructive "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_teardown() {
  local name=$1 sessions delete_status=0 stop_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  [ -f "$(fm_herdr_lab_tripwire_path "$name")" ] || { fm_herdr_lab_error "missing tripwire for '$name'; refusing destructive calls"; return 1; }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
  if ! printf '%s' "$sessions" | jq -e --arg want "$name" '.sessions[]? | select(.name == $want)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || stop_status=$?
  if [ "$stop_status" -ne 0 ]; then
    sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
    if printf '%s' "$sessions" | jq -e --arg want "$name" '.sessions[]? | select(.name == $want)' >/dev/null 2>&1; then
      fm_herdr_lab_error "session stop failed for '$name'; refusing delete"
      return 1
    fi
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  sleep 0.5
  fm_herdr_lab_guard_destructive "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
  if printf '%s' "$sessions" | jq -e --arg want "$name" '.sessions[]? | select(.name == $want)' >/dev/null 2>&1; then
    if [ "$delete_status" -eq 0 ]; then
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    else
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_name() {
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'A-Za-z0-9_-' | sed 's/^[^A-Za-z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}; label=${label%-}; [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name) [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }; fm_herdr_lab_name "$2" ;;
    prepare|provision|stop|teardown) [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }; "fm_herdr_lab_$command" "$2" ;;
    run) [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }; shift; fm_herdr_lab_cli "$@" ;;
    -h|--help|help) fm_herdr_lab_usage ;;
    *) fm_herdr_lab_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  case "${1:-}" in
    prepare|provision|stop|teardown|run) fm_refuse_if_gate_agent ;;
  esac
  fm_herdr_lab_main "$@"
fi
