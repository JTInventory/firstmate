#!/usr/bin/env bash

FM_WATCH_HERDR_EVENT_CAPABLE_SESSIONS=${FM_WATCH_HERDR_EVENT_CAPABLE_SESSIONS:-}
FM_WATCH_HERDR_EVENT_INCAPABLE_SESSIONS=${FM_WATCH_HERDR_EVENT_INCAPABLE_SESSIONS:-}

fm_watch_herdr_event_session_known() {
  local list=$1 session=$2
  case "|$list|" in
    *"|$session|"*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_watch_herdr_events_capable() {
  local session=$1
  fm_watch_herdr_event_session_known "$FM_WATCH_HERDR_EVENT_CAPABLE_SESSIONS" "$session" && return 0
  fm_watch_herdr_event_session_known "$FM_WATCH_HERDR_EVENT_INCAPABLE_SESSIONS" "$session" && return 1
  if fm_backend_events_capable herdr "$session"; then
    FM_WATCH_HERDR_EVENT_CAPABLE_SESSIONS="${FM_WATCH_HERDR_EVENT_CAPABLE_SESSIONS:+$FM_WATCH_HERDR_EVENT_CAPABLE_SESSIONS|}$session"
    return 0
  fi
  FM_WATCH_HERDR_EVENT_INCAPABLE_SESSIONS="${FM_WATCH_HERDR_EVENT_INCAPABLE_SESSIONS:+$FM_WATCH_HERDR_EVENT_INCAPABLE_SESSIONS|}$session"
  return 1
}

fm_watch_wait_herdr_transition() {  # <state> <timeout> <session:pane...>
  local state=$1 timeout=$2 session w
  shift 2
  local -a windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  session=${windows[0]%%:*}
  [ -n "$session" ] && [ "$session" != "${windows[0]}" ] || return 2
  for w in "${windows[@]}"; do
    [ "${w%%:*}" = "$session" ] || return 2
  done
  fm_watch_herdr_events_capable "$session" || return 2
  local -x FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1
  fm_backend_wait_transition herdr "$session" "$timeout" "$state" "${windows[@]}"
}
