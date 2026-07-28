#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
FM_LOCK_LEGACY_IDENTITY_MAX_AGE="${FM_LOCK_LEGACY_IDENTITY_MAX_AGE:-300}"
[ "${FM_WAKE_LIB_READ_ONLY:-0}" = 1 ] || mkdir -p "$STATE"

fm_spawn_admission_lock_path() {
  printf '%s/.locks/spawn-admission.lock\n' "$1"
}

fm_spawn_admission_lock_paths() {
  printf '%s/.spawn-admission.lock\n' "$1"
  fm_spawn_admission_lock_path "$1"
}

fm_spawn_legacy_task_lock_busy() {
  local state=$1 lock
  for lock in "$state"/.spawn-*.lock; do
    [ -e "$lock" ] || [ -L "$lock" ] || continue
    [ "$lock" != "$state/.spawn-admission.lock" ] || continue
    if fm_lock_try_acquire "$lock"; then
      fm_lock_release "$lock"
      continue
    fi
    return 0
  done
  return 1
}

fm_lifecycle_canonical_path() {
  local path=$1 parent base
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -d "$path" ]; then
    cd "$path" 2>/dev/null && pwd -P
    return
  fi
  parent=${path%/*}
  base=${path##*/}
  [ -n "$parent" ] || parent=/
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${parent%/}" "$base"
}

fm_lifecycle_process_cwd() {
  local pid=$1 cwd
  if [ -L "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1
    fm_lifecycle_canonical_path "$cwd"
    return
  fi
  cwd=$(LC_ALL=C lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1) \
    || return 1
  [ -n "$cwd" ] || return 1
  fm_lifecycle_canonical_path "$cwd"
}

fm_lifecycle_process_script_path() {
  local pid=$1 script=$2 cwd
  case "$script" in
    /*) fm_lifecycle_canonical_path "$script" ;;
    *)
      cwd=$(fm_lifecycle_process_cwd "$pid") || return 1
      fm_lifecycle_canonical_path "$cwd/$script"
      ;;
  esac
}

fm_lifecycle_script_from_argv() {
  local command=${1:-} base arg
  FM_LIFECYCLE_SCRIPT=
  [ -n "$command" ] || return 1
  base=${command##*/}
  case "$base" in
    fm-spawn.sh|fm-teardown.sh)
      FM_LIFECYCLE_SCRIPT=$command
      return 0
      ;;
    env)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --) shift; break ;;
          -u|--unset|-C|--chdir|-S|--split-string|-a|--argv0)
            shift
            [ "$#" -gt 0 ] || return 1
            shift
            ;;
          --unset=*|--chdir=*|--split-string=*|--argv0=*|-u?*|-C?*|-S?*|-a?*|\
          -i|--ignore-environment|-0|--null|-v|--debug|*=*)
            shift
            ;;
          -*) return 1 ;;
          *) break ;;
        esac
      done
      [ "$#" -gt 0 ] || return 1
      fm_lifecycle_script_from_argv "$@"
      return
      ;;
    bash|sh|dash|zsh|ksh)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --) shift; break ;;
          -c|--command|-[^-]*c*) return 1 ;;
          -O|+O|-o|+o)
            shift
            [ "$#" -gt 0 ] || return 1
            shift
            ;;
          --init-file|--rcfile)
            shift
            [ "$#" -gt 0 ] || return 1
            shift
            ;;
          --init-file=*|--rcfile=*|--debugger|--dump-po-strings|--dump-strings|\
          --login|--noediting|--noprofile|--norc|--posix|--pretty-print|\
          --restricted|--verbose)
            shift
            ;;
          --help|--version) return 1 ;;
          --*) return 1 ;;
          -*|+*) shift ;;
          *) break ;;
        esac
      done
      arg=${1:-}
      case "${arg##*/}" in
        fm-spawn.sh|fm-teardown.sh)
          FM_LIFECYCLE_SCRIPT=$arg
          return 0
          ;;
      esac
      ;;
  esac
  return 1
}

fm_lifecycle_read_proc_argv() {
  local pid=$1 arg
  FM_LIFECYCLE_ARGV=()
  [ -e "/proc/$pid/cmdline" ] || return 1
  if ! { exec 9< "/proc/$pid/cmdline"; } 2>/dev/null; then
    return 2
  fi
  while IFS= read -r -d '' arg <&9; do
    FM_LIFECYCLE_ARGV+=("$arg")
  done
  exec 9<&-
  [ "${#FM_LIFECYCLE_ARGV[@]}" -gt 0 ] || return 2
}

fm_lifecycle_read_fallback_argv() {
  local pid=$1 command
  FM_LIFECYCLE_ARGV=()
  command=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) || return 2
  command=${command#"${command%%[![:space:]]*}"}
  command=${command%"${command##*[![:space:]]}"}
  [ -n "$command" ] || return 2
  case "${command##*/}" in
    fm-spawn.sh|fm-teardown.sh)
      FM_LIFECYCLE_ARGV=("$command")
      return 0
      ;;
  esac
  return 1
}

fm_lifecycle_process_executable() {
  local pid=$1 executable
  executable=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
  if [ -n "$executable" ]; then
    printf '%s\n' "$executable"
    return 0
  fi
  executable=$(LC_ALL=C lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
    | sed -n 's/^n//p' | head -1) || return 1
  [ -n "$executable" ] || return 1
  printf '%s\n' "$executable"
}

fm_lifecycle_process_live() {
  fm_pid_alive "$1" && ! fm_pid_is_zombie "$1"
}

fm_lifecycle_process_kernel_thread() {
  grep -Eq '^Kthread:[[:space:]]*1$' "/proc/$1/status" 2>/dev/null
}

fm_lifecycle_process_script() {
  local pid=$1 provider_rc fallback_rc executable= executable_base base parsed_rc
  local -a argv=()
  if fm_lifecycle_read_proc_argv "$pid"; then
    provider_rc=0
  else
    provider_rc=$?
  fi
  if [ "$provider_rc" -ne 0 ]; then
    if [ "$provider_rc" -eq 2 ]; then
      fm_lifecycle_process_live "$pid" || return 1
      fm_lifecycle_process_kernel_thread "$pid" && return 1
    fi
    if fm_lifecycle_read_fallback_argv "$pid"; then
      fallback_rc=0
    else
      fallback_rc=$?
    fi
    [ "$fallback_rc" -eq 0 ] || {
      [ "$fallback_rc" -eq 1 ] && return 1
      [ "$provider_rc" -eq 1 ] && return 1
      return 2
    }
  fi
  argv=("${FM_LIFECYCLE_ARGV[@]}")
  [ "${#argv[@]}" -gt 0 ] || return 2
  executable=$(fm_lifecycle_process_executable "$pid" 2>/dev/null || true)
  executable_base=${executable##*/}
  executable_base=${executable_base% (deleted)}
  base=${argv[0]##*/}
  if fm_lifecycle_script_from_argv "${argv[@]}"; then
    parsed_rc=0
  else
    parsed_rc=$?
  fi
  case "$base" in
    fm-spawn.sh|fm-teardown.sh)
      [ "$parsed_rc" -eq 0 ] || return 1
      case "$executable_base" in
        fm-spawn.sh|fm-teardown.sh|bash|sh|dash|zsh|ksh) return 0 ;;
        *) return 3 ;;
      esac
      ;;
    env)
      [ "$parsed_rc" -eq 0 ] || return 1
      [ "$executable_base" = env ] && return 0
      return 3
      ;;
    bash|sh|dash|zsh|ksh)
      [ "$parsed_rc" -eq 0 ] || return 1
      case "$executable_base" in
        bash|sh|dash|zsh|ksh) return 0 ;;
        *) return 3 ;;
      esac
      ;;
    *)
      case "$executable_base" in
        fm-spawn.sh|fm-teardown.sh|bash|sh|dash|zsh|ksh)
          argv[0]=$executable
          fm_lifecycle_script_from_argv "${argv[@]}"
          return
          ;;
      esac
      return 1
      ;;
  esac
}

fm_lifecycle_process_environment() {
  local pid=$1
  FM_LIFECYCLE_ENVIRONMENT=
  FM_LIFECYCLE_ENVIRONMENT_SOURCE=
  if [ -e "/proc/$pid/environ" ]; then
    if FM_LIFECYCLE_ENVIRONMENT=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null); then
      FM_LIFECYCLE_ENVIRONMENT_SOURCE=proc
      return 0
    fi
    FM_LIFECYCLE_ENVIRONMENT=
  fi
  FM_LIFECYCLE_ENVIRONMENT=$(LC_ALL=C ps eww -p "$pid" -o command= 2>/dev/null) \
    || return 2
  [ -n "$FM_LIFECYCLE_ENVIRONMENT" ] || return 2
  FM_LIFECYCLE_ENVIRONMENT_SOURCE=ps
}

fm_spawn_legacy_process_matches_scope() {
  local pid=$1 script=$2 target_home=$3 target_state=$4
  local line lifecycle_home= lifecycle_state= home= root= state=
  local process_home= process_state= environment raw canonical linked=0
  fm_lifecycle_process_environment "$pid" || return 2
  environment=$FM_LIFECYCLE_ENVIRONMENT
  if [ "$FM_LIFECYCLE_ENVIRONMENT_SOURCE" = proc ]; then
    while IFS= read -r line; do
      case "$line" in
        FM_LIFECYCLE_HOME=*) lifecycle_home=${line#FM_LIFECYCLE_HOME=} ;;
        FM_LIFECYCLE_STATE=*) lifecycle_state=${line#FM_LIFECYCLE_STATE=} ;;
        FM_HOME=*) home=${line#FM_HOME=} ;;
        FM_ROOT_OVERRIDE=*) root=${line#FM_ROOT_OVERRIDE=} ;;
        FM_STATE_OVERRIDE=*) state=${line#FM_STATE_OVERRIDE=} ;;
      esac
    done <<< "$environment"
  else
    return 2
  fi
  for raw in "$lifecycle_home" "$home" "$root"; do
    [ -n "$raw" ] || continue
    canonical=$(fm_lifecycle_canonical_path "$raw") || return 2
    [ -z "$process_home" ] || [ "$process_home" = "$canonical" ] || return 0
    process_home=$canonical
    [ "$canonical" != "$target_home" ] || linked=1
  done
  if [ -z "$process_home" ]; then
    raw=${script%/*}
    raw=${raw%/*}
    process_home=$(fm_lifecycle_canonical_path "$raw") || return 2
    [ "$process_home" != "$target_home" ] || linked=1
  fi
  for raw in "$lifecycle_state" "$state"; do
    [ -n "$raw" ] || continue
    canonical=$(fm_lifecycle_canonical_path "$raw") || return 2
    [ -z "$process_state" ] || [ "$process_state" = "$canonical" ] || return 0
    process_state=$canonical
    [ "$canonical" != "$target_state" ] || linked=1
  done
  if [ -z "$process_state" ]; then
    process_state=$(fm_lifecycle_canonical_path "$process_home/state") || return 2
    [ "$process_state" != "$target_state" ] || linked=1
  fi
  [ "$linked" = 0 ] || return 0
  return 1
}

fm_pid_list_contains() {
  local list=$1 wanted=$2 pid
  for pid in $list; do
    [ "$pid" = "$wanted" ] && return 0
  done
  return 1
}

fm_lifecycle_identity_result_busy() {
  case "$1" in
    2|3) return 0 ;;
    *) return 1 ;;
  esac
}

fm_spawn_legacy_lifecycle_process_busy() {
  local target_home=$1 target_state=$2 exclude_pids=${3:-} entry pid script rc
  target_home=$(fm_lifecycle_canonical_path "$target_home") || return 0
  target_state=$(fm_lifecycle_canonical_path "$target_state") || return 0
  if [ -d /proc ]; then
    for entry in /proc/[0-9]*; do
      pid=${entry#/proc/}
      fm_pid_list_contains "$exclude_pids" "$pid" && continue
      if fm_lifecycle_process_script "$pid"; then rc=0; else rc=$?; fi
      fm_lifecycle_identity_result_busy "$rc" && return 0
      [ "$rc" -eq 0 ] || continue
      script=$FM_LIFECYCLE_SCRIPT
      if fm_spawn_legacy_process_matches_scope \
        "$pid" "$script" "$target_home" "$target_state"; then rc=0; else rc=$?; fi
      [ "$rc" -eq 1 ] || return 0
    done
    return 1
  fi
  while read -r pid _; do
    fm_pid_list_contains "$exclude_pids" "$pid" && continue
    if fm_lifecycle_process_script "$pid"; then rc=0; else rc=$?; fi
    fm_lifecycle_identity_result_busy "$rc" && return 0
    [ "$rc" -eq 0 ] || continue
    script=$FM_LIFECYCLE_SCRIPT
    if fm_spawn_legacy_process_matches_scope \
      "$pid" "$script" "$target_home" "$target_state"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 1 ] || return 0
  done < <(LC_ALL=C ps -A -o pid= -o args= 2>/dev/null)
  return 1
}

fm_spawn_legacy_lifecycle_quiescent() {
  local target_home=$1 target_state=$2 exclude_pids=${3:-}
  local passes=${FM_LEGACY_LIFECYCLE_QUIESCENCE_PASSES:-3}
  local wait=${FM_LEGACY_LIFECYCLE_QUIESCENCE_WAIT:-0.1} pass
  case "$passes" in
    3|4|5) ;;
    *) passes=3 ;;
  esac
  case "$wait" in
    0.1|.1|0.2|.2|0.3|.3|0.4|.4|0.5|.5) ;;
    *) wait=0.1 ;;
  esac
  pass=1
  while [ "$pass" -le "$passes" ]; do
    fm_spawn_legacy_lifecycle_process_busy "$target_home" "$target_state" "$exclude_pids" \
      && return 1
    [ "$pass" -eq "$passes" ] && return 0
    sleep "$wait" || return 1
    pass=$((pass + 1))
  done
  return 1
}

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

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
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

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
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
