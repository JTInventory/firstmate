#!/usr/bin/env bash

fm_procargs2_dump() {
  sysctl -n kern.procargs2 "$1"
}

fm_procargs2_read() {
  local pid=$1 argc token saw_exec=0 argv_started=0 argv_count=0 snapshot
  local -a tokens=()
  FM_PROCARGS_ARGV=()
  FM_PROCARGS_ENV=()
  command -v od >/dev/null 2>&1 || return 1
  command -v dd >/dev/null 2>&1 || return 1
  snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-procargs2.XXXXXX") || return 1
  fm_procargs2_dump "$pid" > "$snapshot" 2>/dev/null || {
    rm -f "$snapshot"
    return 1
  }
  argc=$(od -An -tu4 -N4 "$snapshot" 2>/dev/null | tr -d '[:space:]') || {
    rm -f "$snapshot"
    return 1
  }
  case "$argc" in ''|*[!0-9]*) rm -f "$snapshot"; return 1 ;; esac
  [ "$argc" -gt 0 ] || { rm -f "$snapshot"; return 1; }
  while IFS= read -r -d '' token; do
    tokens+=("$token")
  done < <(dd if="$snapshot" bs=4 skip=1 2>/dev/null)
  rm -f "$snapshot"
  for token in "${tokens[@]}"; do
    if [ "$saw_exec" -eq 0 ]; then
      [ -n "$token" ] || continue
      saw_exec=1
      continue
    fi
    if [ "$argv_count" -lt "$argc" ]; then
      if [ "$argv_started" -eq 0 ]; then
        [ -n "$token" ] || continue
        argv_started=1
      fi
      FM_PROCARGS_ARGV+=("$token")
      argv_count=$((argv_count + 1))
      continue
    fi
    [ -n "$token" ] || continue
    case "$token" in *=*) FM_PROCARGS_ENV+=("$token") ;; *) return 1 ;; esac
  done
  [ "$saw_exec" -eq 1 ] && [ "$argv_count" -eq "$argc" ]
}

fm_procargs2_environ() {
  local pid=$1 item
  fm_procargs2_read "$pid" || return 1
  for item in "${FM_PROCARGS_ENV[@]}"; do
    printf '%s\n' "$item"
  done
}
