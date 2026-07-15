#!/usr/bin/env bash
# Shared fail-safe proof that a Git lock file is abandoned.
#
# A lock is removable only when it still exists, lsof proves that no process
# holds the lock or its companion directory, and its mtime is older than the
# caller's threshold. Missing lsof, lsof errors, unreadable mtime, and live
# holders all return non-zero so callers leave the lock untouched.

fm_lock_log() {
  echo "${FM_LOCK_LOG_PREFIX:-fm-lock}: $*" >&2
}

fm_lock_path_mtime() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# 0 = holder found, 1 = no holder, 2 = lsof could not answer.
fm_lock_lsof_holder() {
  local target=$1 output status
  if output=$(lsof -- "$target" 2>&1); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 1
  fi
  if [ -n "$output" ]; then
    fm_lock_log "lsof check failed for $target: $output"
  else
    fm_lock_log "lsof check failed for $target with exit $status"
  fi
  return 2
}

# Returns 0 when a holder exists or lsof is unavailable/uncertain. Returns 1
# only after lsof proves that both the lock and companion directory are free.
fm_lock_has_live_holder() {
  local lock=$1 companion=$2 status
  command -v lsof >/dev/null 2>&1 || return 0
  for target in "$lock" "$companion"; do
    [ -n "$target" ] || continue
    if fm_lock_lsof_holder "$target"; then
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] || return 0
  done
  return 1
}

fm_lock_age() {
  local lock=$1 mtime now
  mtime=$(fm_lock_path_mtime "$lock") || return 1
  now=$(date +%s) || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - mtime))"
}

# fm_lock_is_provably_stale <lock> <companion-dir> <minimum-age-seconds>
fm_lock_is_provably_stale() {
  local lock=$1 companion=$2 minimum_age=$3 age
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  fm_lock_has_live_holder "$lock" "$companion" && return 1
  age=$(fm_lock_age "$lock") || {
    fm_lock_log "cannot read mtime for Git lock $lock; leaving it in place"
    return 1
  }
  [ "$age" -ge "$minimum_age" ]
}
