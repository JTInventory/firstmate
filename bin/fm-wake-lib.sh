#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$FM_WAKE_LIB_DIR/fm-worker-isolation-lib.sh"
if [ "${FM_SESSION_LOCK_BOOTSTRAP:-0}" != 1 ]; then
  fm_worker_refuse_primary_operation "wake state initialization" || exit 1
fi
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
FM_LOCK_LEGACY_IDENTITY_MAX_AGE="${FM_LOCK_LEGACY_IDENTITY_MAX_AGE:-300}"
FM_LOCK_WAIT_SECS="${FM_LOCK_WAIT_SECS:-30}"
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_is_zombie() {
  local pid=$1 state
  state=$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null) || return 1
  case "$state" in
    Z*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_pid_command_matches_path() {
  local pid=$1 path=$2 command
  [ -n "$path" ] || return 2
  command=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 2
  case "$command" in
    *"$path"*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_pid_identity_for_locale() {
  local pid=$1 locale=$2 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$locale" ] || return 1
  out=$(LC_ALL="$locale" ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//')"
}

fm_pid_identity() {
  local identity
  identity=$(fm_pid_identity_for_locale "$1" C) || return 1
  printf 'v1:%s\n' "$identity"
}

fm_pid_start_ps_token() {
  local pid=$1 format=$2 out prefix
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$format" in
    raw)
      prefix=
      out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
      ;;
    ps1)
      prefix=ps:
      out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
      ;;
    ps2)
      prefix=ps:
      out=$(LC_ALL=C ps -p "$pid" -o lstart= -o pgid= -o tty= 2>/dev/null) || return 1
      ;;
    ps3)
      prefix=ps:
      out=$(LC_ALL=C ps -p "$pid" -o lstart= -o pgid= -o tty= -o command= 2>/dev/null) || return 1
      ;;
    current)
      prefix=ps:v1:
      out=$(LC_ALL=C ps -p "$pid" -o lstart= -o pgid= -o tty= -o command= 2>/dev/null) || return 1
      ;;
    *) return 2 ;;
  esac
  [ -n "$out" ] || return 1
  printf '%s%s\n' "$prefix" "$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//')"
}

fm_pid_start() {
  local pid=$1 proc_stat
  local -a proc_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/stat" ]; then
    proc_stat=$(cat "/proc/$pid/stat" 2>/dev/null || true)
    if [ -n "$proc_stat" ]; then
      proc_stat=${proc_stat##*) }
      read -r -a proc_fields <<< "$proc_stat"
      if [ "${#proc_fields[@]}" -ge 20 ]; then
        printf 'proc:%s\n' "${proc_fields[19]}"
        return 0
      fi
    fi
  fi
  fm_pid_start_ps_token "$pid" current
}

fm_pid_start_matches_stored() {
  local pid=$1 stored=$2 current candidate format
  [ -n "$stored" ] || return 2
  current=$(fm_pid_start "$pid") || return 2
  [ "$current" = "$stored" ] && return 0
  for format in raw ps1 ps2 ps3; do
    candidate=$(fm_pid_start_ps_token "$pid" "$format" 2>/dev/null) || continue
    [ "$candidate" = "$stored" ] && return 0
  done
  return 1
}

fm_pid_start_is_cleanup_safe() {
  case "$1" in
    proc:*) return 0 ;;
    ps:v1:*--fm-detach-token=*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_pid_identity_matches_stored() {
  local pid=$1 stored_identity=$2 current_identity
  [ -n "$stored_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$stored_identity" ]
}

fm_pid_identity_is_legacy() {
  local stored_identity=$1
  case "$stored_identity" in
    v1:*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_pid_identity_matches_legacy() {
  local pid=$1 stored_identity=$2 locale candidate
  [ -n "$stored_identity" ] || return 1
  while IFS= read -r locale; do
    [ -n "$locale" ] || continue
    candidate=$(fm_pid_identity_for_locale "$pid" "$locale") || continue
    [ "$candidate" = "$stored_identity" ] && return 0
  done < <(
    printf '%s\n' "${LC_ALL:-}" "${LANG:-}" C
    if command -v locale >/dev/null 2>&1; then
      locale -a 2>/dev/null || true
    fi
  )
  return 1
}

fm_lock_migrate_legacy_identity() {
  local lockdir=$1 pid=$2 owner stored_identity current_identity temp
  owner=$(fm_lock_link_owner "$lockdir") || return 1
  stored_identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  fm_pid_identity_is_legacy "$stored_identity" || return 1
  [ "$(cat "$owner/pid" 2>/dev/null || true)" = "$pid" ] || return 1
  fm_pid_alive "$pid" || return 1
  fm_pid_identity_matches_legacy "$pid" "$stored_identity" || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  fm_lock_points_to_owner "$lockdir" "$owner" || return 1
  [ "$(cat "$owner/pid" 2>/dev/null || true)" = "$pid" ] || return 1
  [ "$(cat "$owner/pid-identity" 2>/dev/null || true)" = "$stored_identity" ] || return 1
  temp="$owner/.pid-identity.migrate.$(fm_current_pid)"
  printf '%s\n' "$current_identity" > "$temp" || return 1
  if ! fm_lock_points_to_owner "$lockdir" "$owner" || ! mv -f "$temp" "$owner/pid-identity"; then
    rm -f "$temp" 2>/dev/null || true
    return 1
  fi
}

fm_lock_migrate_legacy_watcher_identity() {
  local lockdir=$1 pid=$2 expected_home=$3 expected_path=$4 owner
  owner=$(fm_lock_link_owner "$lockdir") || return 1
  [ "$(cat "$owner/fm-home" 2>/dev/null || true)" = "$expected_home" ] || return 1
  [ "$(cat "$owner/watcher-path" 2>/dev/null || true)" = "$expected_path" ] || return 1
  fm_lock_migrate_legacy_identity "$lockdir" "$pid"
}

fm_watcher_lock_scope_matches() {
  local lockdir=$1 expected_home=$2 expected_path=$3 lock_home lock_path
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  [ "$lock_home" = "$expected_home" ] || return 1
  [ "$lock_path" = "$expected_path" ]
}

fm_watcher_lock_matches_pid() {
  local lockdir=$1 pid=$2 expected_home=$3 expected_path=$4 lock_identity lock_start
  fm_pid_alive "$pid" || return 1
  fm_pid_is_zombie "$pid" && return 1
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  lock_start=$(cat "$lockdir/pid-start" 2>/dev/null || true)
  fm_watcher_lock_scope_matches "$lockdir" "$expected_home" "$expected_path" || return 1
  [ -n "$lock_start" ] || return 1
  fm_pid_start_matches_stored "$pid" "$lock_start" || return 1
  [ -n "$lock_identity" ] || return 1
  if fm_pid_identity_matches_stored "$pid" "$lock_identity"; then
    return 0
  fi
  fm_pid_identity_is_legacy "$lock_identity" || return 1
  fm_lock_migrate_legacy_watcher_identity "$lockdir" "$pid" "$expected_home" "$expected_path" \
    && fm_pid_identity_matches_stored "$pid" "$(cat "$lockdir/pid-identity" 2>/dev/null || true)"
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/pid-start" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    "$lockdir/owner-path" \
    "$lockdir/incarnation" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 owner_home=${2:-} owner_path=${3:-} mypid back identity start
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ] || return 1
  identity=$(fm_pid_identity "$mypid" 2>/dev/null || true)
  [ -z "$identity" ] || printf '%s\n' "$identity" > "$ownerdir/pid-identity"
  start=$(fm_pid_start "$mypid" 2>/dev/null || true)
  [ -z "$start" ] || printf '%s\n' "$start" > "$ownerdir/pid-start"
  if [ -n "$owner_home" ]; then
    printf '%s\n' "$owner_home" > "$ownerdir/fm-home" || return 1
  fi
  if [ -n "$owner_path" ]; then
    printf '%s\n' "$owner_path" > "$ownerdir/owner-path" || return 1
  fi
  if [ -n "${FM_LOCK_OWNER_INCARNATION:-}" ]; then
    printf '%s\n' "$FM_LOCK_OWNER_INCARNATION" > "$ownerdir/incarnation" || return 1
    back=$(cat "$ownerdir/incarnation" 2>/dev/null || true)
    [ "$back" = "$FM_LOCK_OWNER_INCARNATION" ] || return 1
  fi
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  if [ -d "$lockdir" ] && [ ! -L "$lockdir" ]; then
    printf '%s\n' "$lockdir"
    return 0
  fi
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  if [ "$lockdir" = "$ownerdir" ] && [ -d "$lockdir" ] && [ ! -L "$lockdir" ]; then
    return 0
  fi
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} owner_home=${3:-} owner_path=${4:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 2
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir" "$owner_home" "$owner_path"; then
    fm_lock_discard_owner "$ownerdir"
    return 2
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_live_pid_has_mismatched_identity() {
  local lockdir=$1 pid=$2 legacy_path=${3:-} expected_home=${4:-} expected_path=${5:-}
  local stored_home stored_path stored_identity stored_start start_status
  FM_LOCK_LIVE_UNVERIFIED=0
  fm_pid_alive "$pid" || return 1
  fm_pid_is_zombie "$pid" && return 0
  stored_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  stored_path=$(cat "$lockdir/owner-path" 2>/dev/null || true)
  if [ -n "$expected_home" ] || [ -n "$expected_path" ]; then
    if [ -n "$stored_home" ] && [ -n "$stored_path" ]; then
      if [ "$stored_home" != "$expected_home" ] || [ "$stored_path" != "$expected_path" ]; then
        return 0
      fi
    else
      fm_pid_command_matches_path "$pid" "$legacy_path"
      case "$?" in
        0)
          FM_LOCK_LIVE_UNVERIFIED=1
          return 1
          ;;
        1) return 0 ;;
        *) return 1 ;;
      esac
    fi
  fi
  stored_start=$(cat "$lockdir/pid-start" 2>/dev/null || true)
  if [ -n "$stored_start" ]; then
    fm_pid_start_matches_stored "$pid" "$stored_start"
    start_status=$?
    case "$start_status" in
      0) ;;
      1) return 0 ;;
      *) return 1 ;;
    esac
  fi
  stored_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  if [ -z "$stored_identity" ]; then
    [ -n "$legacy_path" ] || return 1
    fm_pid_command_matches_path "$pid" "$legacy_path"
    case "$?" in
      0) return 1 ;;
      1) return 0 ;;
      *) return 1 ;;
    esac
  fi
  fm_pid_identity_matches_stored "$pid" "$stored_identity" && return 1
  if fm_pid_identity_is_legacy "$stored_identity"; then
    fm_lock_migrate_legacy_identity "$lockdir" "$pid" && return 1
    [ "$(fm_path_age "$lockdir")" -ge "$FM_LOCK_LEGACY_IDENTITY_MAX_AGE" ] || return 1
  fi
  return 0
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 legacy_path=${4:-}
  local expected_home=${5:-} expected_path=${6:-} actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    fm_lock_live_pid_has_mismatched_identity "$lockdir" "$actual_pid" "$legacy_path" \
      "$expected_home" "$expected_path" || return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire() {
  local lockdir=$1 legacy_path=${2:-} owner_home=${3:-} owner_path=${4:-}
  local pid steal cur rc create_rc steal_rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_HELD_UNVERIFIED=0
  FM_LOCK_OWNER_DIR=

  fm_lock_try_create "$lockdir" '' "$owner_home" "$owner_path"
  create_rc=$?
  if [ "$create_rc" -eq 0 ]; then
    return 0
  fi
  [ "$create_rc" -eq 2 ] && return 2
  if [ ! -e "$lockdir" ] && [ ! -L "$lockdir" ]; then
    return 1
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    if fm_lock_live_pid_has_mismatched_identity "$lockdir" "$pid" "$legacy_path" "$owner_home" "$owner_path"; then
      :
    else
      FM_LOCK_HELD_PID=$pid
      [ "${FM_LOCK_LIVE_UNVERIFIED:-0}" -eq 1 ] && FM_LOCK_HELD_UNVERIFIED=1
      return 1
    fi
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  fm_lock_try_acquire "$steal"
  steal_rc=$?
  if [ "$steal_rc" -ne 0 ]; then
    [ "$steal_rc" -eq 2 ] && return 2
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    if fm_lock_live_pid_has_mismatched_identity "$lockdir" "$cur" "$legacy_path" "$owner_home" "$owner_path"; then
      :
    else
      fm_lock_release "$steal"
      FM_LOCK_HELD_PID=$cur
      # shellcheck disable=SC2034
      [ "${FM_LOCK_LIVE_UNVERIFIED:-0}" -eq 1 ] && FM_LOCK_HELD_UNVERIFIED=1
      FM_LOCK_OWNER_DIR=
      return 1
    fi
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    # shellcheck disable=SC2034
    [ "${FM_LOCK_LIVE_UNVERIFIED:-0}" -eq 1 ] && FM_LOCK_HELD_UNVERIFIED=1
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur" "$legacy_path" \
    "$owner_home" "$owner_path"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  fm_lock_try_create "$lockdir" "$steal_owner" "$owner_home" "$owner_path"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    fm_lock_release "$steal"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

# Waits only for CONTENTION. fm_lock_try_acquire returns 2 when the lock's
# owner directory cannot be prepared at all - an unwritable or full filesystem -
# which no amount of waiting resolves, so retrying there spins forever on the
# spawn and teardown hot paths instead of letting the caller take its
# fail-closed refusal. Returns nonzero for that case so every caller can refuse.
fm_lock_acquire_wait() {
  local lockdir=$1 rc max_ticks elapsed=0 owner
  case "$FM_LOCK_WAIT_SECS" in
    ''|*[!0-9]*) max_ticks=300 ;;
    *) max_ticks=$((FM_LOCK_WAIT_SECS * 10)) ;;
  esac
  while :; do
    rc=0
    fm_lock_try_acquire "$lockdir" || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) return 1 ;;
    esac
    if [ "$elapsed" -ge "$max_ticks" ]; then
      owner=${FM_LOCK_HELD_PID:-unknown}
      printf 'fm-wake-lib: timed out after %ss waiting for %s (owner %s)\n' \
        "$FM_LOCK_WAIT_SECS" "$lockdir" "$owner" >&2
      return 1
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_queue_txn_field() {
  local manifest=$1 wanted=$2
  awk -F= -v wanted="$wanted" \
    '$1 == wanted { print substr($0, index($0, "=") + 1); count++ } END { exit(count == 1 ? 0 : 1) }' \
    "$manifest" 2>/dev/null
}

fm_wake_queue_txn_manifest_write() {
  local txn=$1 phase=$2 action=$3 offset=$4 had_queue=$5 had_cursor=$6 tmp
  tmp=$(mktemp "$txn/.manifest.XXXXXX") || return 1
  if ! printf 'schema=fm-wake-queue-transaction.v1\nphase=%s\naction=%s\noffset=%s\nhad_queue=%s\nhad_cursor=%s\n' \
    "$phase" "$action" "$offset" "$had_queue" "$had_cursor" > "$tmp" \
    || ! mv -f "$tmp" "$txn/manifest"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

fm_wake_queue_txn_cleanup_locked() {
  local txn=$1
  rm -f "$txn/queue.new" "$txn/queue.old" "$txn/cursor.old" "$txn/manifest" "$txn"/.manifest.* || return 1
  rmdir "$txn" 2>/dev/null
}

fm_wake_queue_txn_rollback_locked() {
  local txn=$1 had_queue=$2 had_cursor=$3 cursor status=0
  cursor=$(fm_wake_queue_cursor_path)
  if [ -e "$FM_WAKE_QUEUE" ] || [ -L "$FM_WAKE_QUEUE" ]; then
    [ ! -L "$FM_WAKE_QUEUE" ] || return 1
    [ -f "$FM_WAKE_QUEUE" ] || return 1
  fi
  if [ -e "$cursor" ] || [ -L "$cursor" ]; then
    [ ! -L "$cursor" ] || return 1
    [ -f "$cursor" ] || return 1
  fi
  if [ -e "$txn/queue.old" ] || [ -L "$txn/queue.old" ]; then
    [ -f "$txn/queue.old" ] && [ ! -L "$txn/queue.old" ] || return 1
    rm -f "$FM_WAKE_QUEUE" || return 1
    mv -f "$txn/queue.old" "$FM_WAKE_QUEUE" || return 1
  elif [ "$had_queue" = 0 ]; then
    rm -f "$FM_WAKE_QUEUE" || return 1
  elif [ ! -e "$FM_WAKE_QUEUE" ]; then
    return 1
  fi
  if [ -e "$txn/cursor.old" ] || [ -L "$txn/cursor.old" ]; then
    [ -f "$txn/cursor.old" ] && [ ! -L "$txn/cursor.old" ] || return 1
    rm -f "$cursor" || return 1
    mv -f "$txn/cursor.old" "$cursor" || return 1
  elif [ "$had_cursor" = 0 ]; then
    rm -f "$cursor" || return 1
  elif [ ! -e "$cursor" ]; then
    return 1
  fi
  if [ -e "$txn/queue.new" ] || [ -L "$txn/queue.new" ]; then
    [ -f "$txn/queue.new" ] && [ ! -L "$txn/queue.new" ] || return 1
    rm -f "$txn/queue.new" || status=1
  fi
  return "$status"
}

fm_wake_queue_txn_recover_one_locked() {
  local txn=$1 manifest="$1/manifest" schema phase action offset had_queue had_cursor
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  schema=$(fm_wake_queue_txn_field "$manifest" schema) || return 1
  [ "$schema" = fm-wake-queue-transaction.v1 ] || return 1
  phase=$(fm_wake_queue_txn_field "$manifest" phase) || return 1
  action=$(fm_wake_queue_txn_field "$manifest" action) || return 1
  offset=$(fm_wake_queue_txn_field "$manifest" offset) || return 1
  had_queue=$(fm_wake_queue_txn_field "$manifest" had_queue) || return 1
  had_cursor=$(fm_wake_queue_txn_field "$manifest" had_cursor) || return 1
  case "$phase" in prepared|staged|queue-saved|cursor-saved|queue-installed|rollback|committed) ;; *) return 1 ;; esac
  case "$action" in write|remove|keep) ;; *) return 1 ;; esac
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  case "$had_queue" in 0|1) ;; *) return 1 ;; esac
  case "$had_cursor" in 0|1) ;; *) return 1 ;; esac
  if [ "$phase" = committed ]; then
    fm_wake_queue_txn_cleanup_locked "$txn"
    return $?
  fi
  if { [ "$phase" = prepared ] || [ "$phase" = staged ]; } \
    && [ ! -e "$txn/queue.old" ] && [ ! -e "$txn/cursor.old" ]; then
    fm_wake_queue_txn_cleanup_locked "$txn"
    return $?
  fi
  fm_wake_queue_txn_rollback_locked "$txn" "$had_queue" "$had_cursor" || return 1
  fm_wake_queue_txn_cleanup_locked "$txn"
}

fm_wake_queue_txn_recover_transactions_locked() {
  local txn
  for txn in "$STATE"/.wake-queue.txn.*; do
    [ -e "$txn" ] || continue
    [ -d "$txn" ] && [ ! -L "$txn" ] || return 1
    fm_wake_queue_txn_recover_one_locked "$txn" || return 1
  done
}

fm_wake_queue_txn_replace_locked() {
  local replacement=$1 action=$2 offset=${3:-0} txn cursor had_queue=0 had_cursor=0 phase
  [ -f "$replacement" ] && [ ! -L "$replacement" ] || return 1
  case "$action" in
    write) case "$offset" in ''|*[!0-9]*) return 1 ;; esac ;;
    remove|keep) [ "$offset" = 0 ] || return 1 ;;
    *) return 1 ;;
  esac
  [ ! -L "$FM_WAKE_QUEUE" ] || return 1
  cursor=$(fm_wake_queue_cursor_path)
  [ ! -L "$cursor" ] || return 1
  if [ -e "$FM_WAKE_QUEUE" ]; then
    [ -f "$FM_WAKE_QUEUE" ] || return 1
    had_queue=1
  fi
  if [ -e "$cursor" ]; then
    [ -f "$cursor" ] || return 1
    had_cursor=1
  fi
  if [ "$action" = keep ] && [ "$had_cursor" = 1 ]; then
    return 1
  fi
  txn=$(mktemp -d "$STATE/.wake-queue.txn.XXXXXX") || return 1
  chmod 700 "$txn" || { rmdir "$txn" 2>/dev/null; return 1; }
  if ! fm_wake_queue_txn_manifest_write "$txn" prepared "$action" "$offset" "$had_queue" "$had_cursor"; then
    rmdir "$txn" 2>/dev/null
    return 1
  fi
  if ! mv -f "$replacement" "$txn/queue.new"; then
    fm_wake_queue_txn_cleanup_locked "$txn" || true
    return 1
  fi
  fm_wake_queue_txn_manifest_write "$txn" staged "$action" "$offset" "$had_queue" "$had_cursor" || {
    rm -f "$txn/queue.new"
    fm_wake_queue_txn_cleanup_locked "$txn" || true
    return 1
  }
  if [ "$had_queue" = 1 ] && ! mv -f "$FM_WAKE_QUEUE" "$txn/queue.old"; then
    fm_wake_queue_txn_recover_one_locked "$txn" || true
    return 1
  fi
  fm_wake_queue_txn_manifest_write "$txn" queue-saved "$action" "$offset" "$had_queue" "$had_cursor" || {
    fm_wake_queue_txn_recover_one_locked "$txn" || true
    return 1
  }
  if [ "$had_cursor" = 1 ] && ! mv -f "$cursor" "$txn/cursor.old"; then
    fm_wake_queue_txn_recover_one_locked "$txn" || true
    return 1
  fi
  fm_wake_queue_txn_manifest_write "$txn" cursor-saved "$action" "$offset" "$had_queue" "$had_cursor" || {
    fm_wake_queue_txn_recover_one_locked "$txn" || true
    return 1
  }
  if ! mv -f "$txn/queue.new" "$FM_WAKE_QUEUE"; then
    fm_wake_queue_txn_recover_one_locked "$txn" || true
    return 1
  fi
  fm_wake_queue_txn_manifest_write "$txn" queue-installed "$action" "$offset" "$had_queue" "$had_cursor" || {
    fm_wake_queue_txn_recover_one_locked "$txn" || true
    return 1
  }
  case "$action" in
    write)
      fm_wake_queue_cursor_write "$offset" || phase=failed
      ;;
    remove)
      if [ -e "$cursor" ] || [ -L "$cursor" ]; then
        [ ! -L "$cursor" ] || phase=failed
        [ "${phase:-}" = failed ] || rm -f "$cursor" || phase=failed
      fi
      ;;
    keep) : ;;
  esac
  if [ "${phase:-}" = failed ]; then
    fm_wake_queue_txn_rollback_locked "$txn" "$had_queue" "$had_cursor" || return 1
    fm_wake_queue_txn_manifest_write "$txn" rollback "$action" "$offset" "$had_queue" "$had_cursor" || return 1
    fm_wake_queue_txn_cleanup_locked "$txn" || return 1
    return 1
  fi
  fm_wake_queue_txn_manifest_write "$txn" committed "$action" "$offset" "$had_queue" "$had_cursor" || {
    fm_wake_queue_txn_rollback_locked "$txn" "$had_queue" "$had_cursor" || return 1
    return 1
  }
  fm_wake_queue_txn_cleanup_locked "$txn" || true
  return 0
}

fm_wake_append_locked() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  fm_wake_queue_txn_recover_transactions_locked || return 1
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  return "$status"
}

fm_wake_append() {
  local status
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || {
    printf 'fm_wake_append: could not serialize the wake queue; refusing to append unlocked\n' >&2
    return 1
  }
  fm_wake_append_locked "$@"
  status=$?
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

fm_wake_queue_key_status_locked() {
  local queue=$1 key=$2 budget=${FM_WAKE_QUEUE_STATUS_BUDGET_SECS:-1}
  case "$budget" in ''|*[!0-9]*|0) budget=1 ;; esac
  command -v perl >/dev/null 2>&1 || return 2
  perl - "$queue" "$key" "$budget" <<'PERL'
use strict;
use warnings;

my ($path, $wanted, $seconds) = @ARGV;
$SIG{ALRM} = sub { exit 124 };
alarm($seconds);
open(my $fh, '<', $path) or exit 2;
while (defined(my $line = <$fh>)) {
  my @fields = split(/\t/, $line, -1);
  if (defined($fields[3]) && $fields[3] eq $wanted) {
    close($fh) or exit 2;
    exit 0;
  }
}
$fh->error() and exit 2;
close($fh) or exit 2;
exit 1;
PERL
  local status=$?
  case "$status" in
    0|1) return "$status" ;;
    *) return 2 ;;
  esac
}

fm_wake_append_if_absent_locked() {  # <result-var> <kind> <key> <payload>
  local result_var=$1 kind=$2 key=$3 payload=$4 status=0
  FM_WAKE_APPEND_CREATED=0
  case "$result_var" in ''|*[!A-Za-z0-9_]*) return 2 ;; esac
  if [ -e "$FM_WAKE_QUEUE" ] || [ -L "$FM_WAKE_QUEUE" ]; then
    [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 1
    if fm_wake_queue_key_status_locked "$FM_WAKE_QUEUE" "$key"; then
      printf -v "$result_var" '%s' 0
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] || return "$status"
  fi
  fm_wake_append_locked "$kind" "$key" "$payload"
  status=$?
  [ "$status" -eq 0 ] && { FM_WAKE_APPEND_CREATED=1; printf -v "$result_var" '%s' 1; }
  return "$status"
}

fm_wake_remove_key_locked() {
  local key=$1 tmp cursor cursor_offset=0 cursor_active=0 new_offset
  fm_wake_queue_txn_recover_transactions_locked || return 1
  [ ! -L "$FM_WAKE_QUEUE" ] || return 1
  [ -e "$FM_WAKE_QUEUE" ] || return 0
  [ -f "$FM_WAKE_QUEUE" ] || return 1
  cursor=$(fm_wake_queue_cursor_path)
  if [ -e "$cursor" ] || [ -L "$cursor" ]; then
    fm_wake_queue_cursor_read || return 1
    cursor_offset=$FM_WAKE_QUEUE_CURSOR_OFFSET
    cursor_active=1
  fi
  tmp=$(mktemp "$STATE/.wake-queue.remove.XXXXXX") || return 1
  if ! new_offset=$(perl - "$FM_WAKE_QUEUE" "$tmp" "$key" "$cursor_offset" "$cursor_active" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT);

my ($input, $output, $wanted, $cursor_offset, $cursor_active) = @ARGV;
open(my $in, '<', $input) or exit 1;
binmode($in);
my $nofollow = eval { O_NOFOLLOW() };
defined($nofollow) or exit 1;
sysopen(my $out, $output, O_WRONLY | O_TRUNC | $nofollow) or exit 1;
binmode($out);
my $removed_before = 0;
while (1) {
  my $start = tell($in);
  defined($start) or exit 1;
  my $line = <$in>;
  last unless defined $line;
  my $end = tell($in);
  defined($end) or exit 1;
  my @fields = split(/\t/, $line, -1);
  if (defined($fields[3]) && $fields[3] eq $wanted) {
    $removed_before += $end - $start if $cursor_active && $start < $cursor_offset;
    next;
  }
  print $out $line or exit 1;
}
close($in) or exit 1;
close($out) or exit 1;
print $cursor_offset - $removed_before if $cursor_active;
PERL
  ); then
    rm -f "$tmp"
    return 1
  fi
  if [ "$cursor_active" = 1 ]; then
    case "$new_offset" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
  fi
  [ ! -L "$FM_WAKE_QUEUE" ] || { rm -f "$tmp"; return 1; }
  if [ "$cursor_active" = 1 ]; then
    fm_wake_queue_txn_replace_locked "$tmp" write "$new_offset" || { rm -f "$tmp"; return 1; }
  else
    fm_wake_queue_txn_replace_locked "$tmp" keep 0 || { rm -f "$tmp"; return 1; }
  fi
}

fm_wake_append_if_absent() {  # <result-var> <kind> <key> <payload>
  local status=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || {
    printf 'fm_wake_append_if_absent: could not serialize the wake queue; refusing to append unlocked\n' >&2
    return 1
  }
  fm_wake_append_if_absent_locked "$@" || status=$?
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore status=0
  [ -f "$drained" ] && [ ! -L "$drained" ] || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  fm_wake_queue_txn_recover_transactions_locked || status=1
  if [ "$status" = 0 ]; then
    [ ! -L "$FM_WAKE_QUEUE" ] || status=1
    restore=$(mktemp "$STATE/.wake-queue.restore.XXXXXX") || status=1
    if [ "$status" = 0 ] && [ -e "$FM_WAKE_QUEUE" ]; then
      [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || status=1
      [ "$status" -ne 0 ] || cat "$drained" "$FM_WAKE_QUEUE" > "$restore" || status=1
    elif [ "$status" = 0 ]; then
      cat "$drained" > "$restore" || status=1
    fi
    [ "$status" -ne 0 ] || fm_wake_queue_txn_replace_locked "$restore" remove 0 || status=1
  fi
  [ "$status" -eq 0 ] || rm -f "$restore"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

fm_wake_queue_signature() {
  local queue=$1
  if [ ! -e "$queue" ]; then
    printf 'missing'
    return 0
  fi
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i:%z:%m' "$queue" 2>/dev/null
  else
    stat -c '%d:%i:%s:%Y:%y' "$queue" 2>/dev/null
  fi
}

fm_wake_queue_cursor_path() {
  printf '%s.cursor' "$FM_WAKE_QUEUE"
}

fm_wake_queue_identity() {
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i:%z' "$queue" 2>/dev/null
  else
    stat -c '%d:%i:%s' "$queue" 2>/dev/null
  fi
}

fm_wake_queue_cursor_write() {
  local offset=$1 cursor identity tmp
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(fm_wake_queue_identity "$FM_WAKE_QUEUE") || return 1
  cursor=$(fm_wake_queue_cursor_path)
  [ ! -L "$cursor" ] || return 1
  tmp=$(mktemp "$cursor.XXXXXX") || return 1
  if ! printf 'schema=fm-wake-queue-cursor.v1\nidentity=%s\noffset=%s\n' \
    "$identity" "$offset" > "$tmp" || [ -L "$cursor" ] || ! mv -f "$tmp" "$cursor"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_wake_queue_cursor_read() {
  local cursor identity current offset schema_count identity_count offset_count
  cursor=$(fm_wake_queue_cursor_path)
  [ -f "$cursor" ] && [ ! -L "$cursor" ] || return 1
  schema_count=$(awk -F= '$1 == "schema" { print $2; n++ } END { exit(n == 1 ? 0 : 1) }' "$cursor" 2>/dev/null) || return 1
  [ "$schema_count" = fm-wake-queue-cursor.v1 ] || return 1
  identity_count=$(awk -F= '$1 == "identity" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }' "$cursor" 2>/dev/null) || return 1
  offset=$(awk -F= '$1 == "offset" { print $2; n++ } END { exit(n == 1 ? 0 : 1) }' "$cursor" 2>/dev/null) || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  case "$identity_count" in *:*:*) ;; *) return 1 ;; esac
  current=$(fm_wake_queue_identity "$FM_WAKE_QUEUE") || return 1
  [ "${current%%:*}" = "${identity_count%%:*}" ] || return 1
  current=${current#*:}; identity_count=${identity_count#*:}
  [ "${current%%:*}" = "${identity_count%%:*}" ] || return 1
  current=${current#*:}
  [ "$offset" -le "$current" ] || return 1
  if [ "$offset" -gt 0 ]; then
    perl - "$FM_WAKE_QUEUE" "$offset" <<'PERL' || return 1
use strict;
use warnings;
my ($path, $offset) = @ARGV;
open(my $fh, '<', $path) or exit 1;
binmode($fh);
seek($fh, $offset - 1, 0) or exit 1;
my $byte = getc($fh);
close($fh) or exit 1;
exit(defined($byte) && $byte eq "\n" ? 0 : 1);
PERL
  fi
  FM_WAKE_QUEUE_CURSOR_OFFSET=$offset
}

fm_wake_queue_stream_from_offset() {
  local queue=$1 offset=$2
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  perl - "$queue" "$offset" <<'PERL'
use strict;
use warnings;
my ($path, $offset) = @ARGV;
open(my $fh, '<', $path) or exit 1;
binmode($fh);
seek($fh, $offset, 0) or exit 1;
while (defined(my $line = <$fh>)) {
  print $line or exit 1;
}
close($fh) or exit 1;
PERL
}

fm_wake_queue_offset_valid() {
  local queue=$1 offset=$2
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  perl - "$queue" "$offset" <<'PERL'
use strict;
use warnings;
my ($path, $offset) = @ARGV;
open(my $fh, '<', $path) or exit 1;
binmode($fh);
seek($fh, 0, 2) or exit 1;
my $size = tell($fh);
defined($size) && $offset <= $size or exit 1;
if ($offset > 0) {
  seek($fh, $offset - 1, 0) or exit 1;
  my $byte = getc($fh);
  defined($byte) && $byte eq "\n" or exit 1;
}
close($fh) or exit 1;
PERL
}

fm_wake_queue_offset_after_rows() {
  local queue=$1 offset=$2 rows=$3
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  case "$rows" in ''|*[!0-9]*) return 1 ;; esac
  perl - "$queue" "$offset" "$rows" <<'PERL'
use strict;
use warnings;
my ($path, $offset, $rows) = @ARGV;
open(my $fh, '<', $path) or exit 1;
binmode($fh);
seek($fh, $offset, 0) or exit 1;
my $next = $offset;
for (1 .. $rows) {
  my $line = <$fh>;
  last unless defined $line;
  $next = tell($fh);
  defined($next) or exit 1;
}
print $next;
close($fh) or exit 1;
PERL
}

fm_wake_install_queue_cursor_atomic() {
  local drained=$1 offset=$2 restore expected current status=0
  [ -f "$drained" ] && [ ! -L "$drained" ] || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  for attempt in 1 2 3 4 5 6 7 8; do
    status=0
    expected=$(fm_wake_queue_signature "$FM_WAKE_QUEUE") || return 1
    restore=$(mktemp "$STATE/.wake-queue.cursor-install.XXXXXX") || return 1
    if [ -e "$FM_WAKE_QUEUE" ]; then
      if [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ]; then
        cat "$drained" "$FM_WAKE_QUEUE" > "$restore" || status=1
      else
        status=1
      fi
    else
      cat "$drained" > "$restore" || status=1
    fi
    if [ "${status:-0}" -ne 0 ]; then
      rm -f "$restore"
      return 1
    fi
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || { rm -f "$restore"; return 1; }
    fm_wake_queue_txn_recover_transactions_locked || status=1
    current=$(fm_wake_queue_signature "$FM_WAKE_QUEUE") || status=1
    if [ "${status:-0}" -eq 0 ] && [ "$current" = "$expected" ] \
      && [ ! -L "$FM_WAKE_QUEUE" ]; then
      fm_wake_queue_txn_replace_locked "$restore" write "$offset" || status=1
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
      [ "$status" -eq 0 ] && return 0
      return 1
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    rm -f "$restore"
    status=0
  done
  return 1
}

fm_wake_restore_queue_atomic() {
  local drained=$1 restore expected current status=0 attempt
  [ -f "$drained" ] && [ ! -L "$drained" ] || return 1
  for attempt in 1 2 3 4 5 6 7 8; do
    expected=$(fm_wake_queue_signature "$FM_WAKE_QUEUE") || return 1
    restore=$(mktemp "$STATE/.wake-queue.restore.XXXXXX") || return 1
    [ -f "$restore" ] && [ ! -L "$restore" ] || { rm -f "$restore"; return 1; }
    if [ -e "$FM_WAKE_QUEUE" ]; then
      [ -f "$FM_WAKE_QUEUE" ] || { rm -f "$restore"; return 1; }
      cat "$drained" "$FM_WAKE_QUEUE" > "$restore" || status=1
    else
      cat "$drained" > "$restore" || status=1
    fi
    if [ "$status" -ne 0 ]; then
      rm -f "$restore"
      return 1
    fi
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || { rm -f "$restore"; return 1; }
    fm_wake_queue_txn_recover_transactions_locked || status=1
    current=$(fm_wake_queue_signature "$FM_WAKE_QUEUE") || status=1
    if [ "$status" -eq 0 ] && [ "$current" = "$expected" ] \
      && [ ! -L "$FM_WAKE_QUEUE" ]; then
      fm_wake_queue_txn_replace_locked "$restore" remove 0 || status=1
      [ "$status" -ne 0 ] && { fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true; return 1; }
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 1
      return 0
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    rm -f "$restore"
    status=0
  done
  return 1
}

fm_wake_surface_consumed_path() {
  printf '%s/.hb-surface-consumed-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

fm_wake_mark_surface_consumed() {
  local key=$1 retry marker tmp retry_key published snapshot spawn_incarnation
  retry="$STATE/.hb-surface-retry-$(printf '%s' "$key" | tr ':/.' '___')"
  [ -e "$retry" ] || return 0
  [ -f "$retry" ] && [ ! -L "$retry" ] || return 1
  retry_key=$(awk -F= -v wanted=wake_key '$1 == wanted { print substr($0, index($0, "=") + 1); count++ } END { exit(count == 1 ? 0 : 1) }' "$retry" 2>/dev/null) || return 1
  [ "$retry_key" = "$key" ] || return 0
  published=$(awk -F= -v wanted=wake_published '$1 == wanted { print substr($0, index($0, "=") + 1); count++ } END { exit(count == 1 ? 0 : 1) }' "$retry" 2>/dev/null) || return 1
  [ "$published" = 2 ] || return 0
  snapshot=$(awk -F= -v wanted=snapshot '$1 == wanted { print substr($0, index($0, "=") + 1); count++ } END { exit(count == 1 ? 0 : 1) }' "$retry" 2>/dev/null) || return 1
  spawn_incarnation=$(awk -F= -v wanted=spawn_incarnation '$1 == wanted { print substr($0, index($0, "=") + 1); count++ } END { exit(count == 1 ? 0 : 1) }' "$retry" 2>/dev/null) || return 1
  marker=$(fm_wake_surface_consumed_path "$key")
  tmp=$(mktemp "$STATE/.hb-surface-consumed.XXXXXX") || return 1
  if ! printf 'schema=fm-hb-surface-consumed.v1\ntask=%s\nwake_key=%s\nsnapshot=%s\nspawn_incarnation=%s\n' \
    "$key" "$key" "$snapshot" "$spawn_incarnation" > "$tmp" \
    || [ -L "$marker" ] || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
