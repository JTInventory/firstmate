#!/usr/bin/env bash

fm_procargs2_dump() {
  sysctl -n kern.procargs2 "$1"
}

fm_procargs2_read() {
  local pid=$1 argc token saw_exec=0 argv_started=0 argv_count=0 snapshot
  local read_fd='' write_fd='' candidate
  local -a tokens=()
  FM_PROCARGS_ARGV=()
  FM_PROCARGS_ENV=()
  command -v od >/dev/null 2>&1 || return 1
  command -v dd >/dev/null 2>&1 || return 1
  snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-procargs2.XXXXXX") || return 1
  candidate=10
  while [ "$candidate" -le 99 ]; do
    if ! eval ": <&$candidate" 2>/dev/null \
      && ! eval ": >&$candidate" 2>/dev/null; then
      if [ -z "$read_fd" ]; then read_fd=$candidate; else write_fd=$candidate; break; fi
    fi
    candidate=$((candidate + 1))
  done
  [ -n "$read_fd" ] && [ -n "$write_fd" ] || { rm -f "$snapshot"; return 1; }
  eval "exec $read_fd< \"\$snapshot\"" || { rm -f "$snapshot"; return 1; }
  eval "exec $write_fd> \"\$snapshot\"" || {
    eval "exec $read_fd<&-"
    rm -f "$snapshot"
    return 1
  }
  rm -f "$snapshot" || {
    eval "exec $read_fd<&-; exec $write_fd>&-"
    return 1
  }
  if ! eval "fm_procargs2_dump \"\$pid\" >&$write_fd 2>/dev/null"; then
    eval "exec $read_fd<&-; exec $write_fd>&-"
    return 1
  fi
  eval "exec $write_fd>&-"
  argc=$(eval "dd bs=4 count=1 <&$read_fd 2>/dev/null" | od -An -tu4 2>/dev/null \
    | tr -d '[:space:]') || {
    eval "exec $read_fd<&-"
    return 1
  }
  case "$argc" in ''|*[!0-9]*) eval "exec $read_fd<&-"; return 1 ;; esac
  [ "$argc" -gt 0 ] || { eval "exec $read_fd<&-"; return 1; }
  while IFS= read -r -d '' token; do
    tokens+=("$token")
  done < <(eval "dd bs=1 <&$read_fd 2>/dev/null")
  eval "exec $read_fd<&-"
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
