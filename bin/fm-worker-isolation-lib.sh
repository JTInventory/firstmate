#!/usr/bin/env bash
# bin/fm-worker-isolation-lib.sh - the ONE owner of the launched-agent home
# declaration contract.
#
# A firstmate script resolves its operational home from ambient environment
# (FM_HOME, then the FM_*_OVERRIDE family, then its own FM_ROOT). That
# resolution is correct for a firstmate primary and catastrophic for a task
# child: a crewmate, scout, or audit agent launched from a primary's pane
# inherits that primary's exported FM_HOME, so every firstmate script it runs -
# including bin/fm-lock.sh - resolves the PRIMARY's state directory. A worker
# that then runs session start acquires the primary's session-owner record and
# the real primary is locked out of its own home (incident 2026-07-24).
#
# The fix is a DECLARATION, not a guess: every task child is launched with an
# explicit home environment, and declares which home owns it and in what role.
# Nothing downstream has to infer ownership from cwd, pane, or process tree.
#
#   FM_AGENT_ROLE        crewmate | secondmate  (the declared role)
#   FM_AGENT_TASK        the owning task or secondmate id
#   FM_AGENT_OWNER_HOME  absolute path of the home that launched this agent
#
# `crewmate` covers every ship/scout/audit task child. Such an agent is never a
# firstmate primary anywhere, so it must never own a home, acquire a session
# lock, or fire a primary-home hook - see fm_worker_refuse_primary_operation and
# bin/fm-primary-scope-lib.sh.
#
# `secondmate` is a primary IN ITS OWN HOME and only there, so it keeps a
# concrete FM_HOME while every inheritable override is cleared. Its own
# crewmates are launched by its own bin/fm-spawn.sh and get the crewmate
# treatment against the secondmate's home, which is what keeps a secondmate
# child from ever reaching the primary's home.
#
# The markers are also the backend-independent identity key that
# bin/fm-agent-cwd-lib.sh uses to find the real agent process, so a launch that
# omits them costs authoritative cwd proof as well as home isolation.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# This file is sourced by scripts and hook entrypoints and has no side effects
# on source.

# Every operational-home variable a firstmate script reads. Extend here, not at
# a call site, when a new home override is introduced.
FM_WORKER_ISOLATION_HOME_VARS="FM_HOME FM_ROOT STATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE"
FM_WORKER_ISOLATION_LIFECYCLE_VARS="FM_LIFECYCLE_HOME FM_LIFECYCLE_STATE FM_LIFECYCLE_SCRIPT FM_LOCK_PROCESS_TOKEN"
FM_WORKER_ISOLATION_AUTHORITY_VARS="FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD FM_SESSION_AUTHORITY_BROKER_PID FM_SESSION_AUTHORITY_BROKER_START FM_SESSION_AUTHORITY_BROKER_IDENTITY FM_SESSION_AUTHORITY_BROKER_SCRIPT FM_TEST_AUTHORITY_FD FM_TEST_DURABLE_AUTHORITY_FD FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID FM_TEST_SESSION_LOCK_STABLE_OWNER FM_TEST_AUTHORITY_HARNESS FM_TEST_AUTHORITY_HARNESS_PID FM_TEST_AUTHORITY_HARNESS_SCRIPT FM_TEST_AUTHORITY_EXEC_SCRIPT FM_TEST_AUTHORITY_BROKER_PID_FILE"
_FM_WORKER_ISOLATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_FM_WORKER_ISOLATION_LIB_DIR/fm-procargs-lib.sh"

fm_worker_shell_quote() {  # <text>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_worker_treehouse_lease_command <task-id>
# Print the pane command that durably leases a pooled slot and enters it. The
# lease remains held even if the worker process exits, so only Firstmate's
# ownership-gated teardown can return and recycle the slot.
fm_worker_treehouse_lease_command() {
  local id=$1 quoted
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  quoted=$(fm_worker_shell_quote "$id") || return 1
  printf 'fm_wt=$(treehouse get --lease --lease-holder %s) && cd -- "$fm_wt" && unset fm_wt' \
    "$quoted"
}

# fm_worker_launch_env_prefix <role> <task-id> <owner-home>
# Print the exact env-assignment prefix a launch command must carry, with one
# trailing space, so a caller composes `<prefix><launch command>`. Refuses an
# unknown role, an empty id, or a non-absolute home rather than emitting a
# partial prefix that would leave the child inheriting a home.
fm_worker_launch_env_prefix() {
  local role=$1 id=$2 home=$3 var authority_fd closed_fds='' strip_authority=0
  local current_home target_home
  case "$role" in
    crewmate|secondmate) ;;
    *) echo "error: unknown agent role '$role'; expected crewmate or secondmate" >&2; return 1 ;;
  esac
  [ -n "$id" ] || { echo "error: agent role $role requires a task id" >&2; return 1; }
  case "$home" in
    /*) ;;
    *) echo "error: agent role $role requires an absolute owning home, got '${home:-<empty>}'" >&2; return 1 ;;
  esac
  if [ "$role" = crewmate ]; then
    strip_authority=1
  else
    current_home=$(fm_worker_canonical_path "${FM_HOME:-}")
    target_home=$(fm_worker_canonical_path "$home")
    [ -n "$current_home" ] && [ "$current_home" = "$target_home" ] \
      || strip_authority=1
  fi
  if [ "$strip_authority" -eq 1 ]; then
    printf 'export PATH GOTMPDIR; '
    for var in FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD \
      FM_TEST_AUTHORITY_FD \
      FM_TEST_DURABLE_AUTHORITY_FD; do
      eval "authority_fd=\${$var:-}"
      case "$authority_fd" in
        ''|*[!0-9]*) ;;
        *)
          case " $closed_fds " in *" $authority_fd "*) continue ;; esac
          case "$var" in
            FM_SESSION_AUTHORITY_DURABLE_FD)
              [ "$authority_fd" != "${FM_SESSION_AUTHORITY_FD:-}" ] || continue
              ;;
            FM_TEST_DURABLE_AUTHORITY_FD)
              [ "$authority_fd" != "${FM_TEST_AUTHORITY_FD:-}" ] || continue
              ;;
          esac
          printf '%s' "if [ -d /proc/\$\$/fd ] && [ -r /proc/\$\$/fd ] && [ -x /proc/\$\$/fd ]; then [ ! -e /proc/\$\$/fd/$authority_fd ] || exec $authority_fd>&-; elif [ -d /dev/fd ] && [ -r /dev/fd ] && [ -x /dev/fd ]; then [ ! -e /dev/fd/$authority_fd ] || exec $authority_fd>&-; else echo 'error: cannot prove authority descriptor $authority_fd absent before worker launch' >&2; exit 1; fi; "
          closed_fds="$closed_fds $authority_fd"
          ;;
      esac
    done
  fi
  for var in $FM_WORKER_ISOLATION_HOME_VARS; do
    if [ "$var" = FM_HOME ] && [ "$role" = secondmate ]; then
      printf 'FM_HOME=%s ' "$(fm_worker_shell_quote "$home")"
    else
      printf '%s= ' "$var"
    fi
  done
  for var in $FM_WORKER_ISOLATION_LIFECYCLE_VARS; do
    printf '%s= ' "$var"
  done
  if [ "$strip_authority" -eq 1 ]; then
    for var in $FM_WORKER_ISOLATION_AUTHORITY_VARS; do
      printf '%s= ' "$var"
    done
  fi
  printf 'FM_AGENT_ROLE=%s ' "$role"
  printf 'FM_AGENT_TASK=%s ' "$(fm_worker_shell_quote "$id")"
  printf 'FM_AGENT_OWNER_HOME=%s ' "$(fm_worker_shell_quote "$home")"
}

# fm_worker_declared_role: the current process's declared role, or empty when
# it declares none (a primary firstmate, or a pre-declaration legacy agent).
fm_worker_declared_role() {
  case "${FM_AGENT_ROLE:-}" in
    primary|crewmate|secondmate) printf '%s' "$FM_AGENT_ROLE" ;;
  esac
}

# fm_worker_is_task_worker: 0 when this process is a declared task child that
# must never act as a firstmate primary in any home.
fm_worker_is_task_worker() {
  [ "${FM_AGENT_ROLE:-}" = crewmate ]
}

# fm_worker_owning_home: the home that declared this agent, or empty.
fm_worker_owning_home() {
  printf '%s' "${FM_AGENT_OWNER_HOME:-}"
}

fm_worker_canonical_path() {
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

fm_worker_secondmate_scope_matches() {
  local home=$1 state=$2 owner_real home_real state_real marker marker_task
  [ -n "${FM_AGENT_TASK:-}" ] && [ -n "${FM_AGENT_OWNER_HOME:-}" ] || return 1
  owner_real=$(cd "${FM_AGENT_OWNER_HOME:-}" 2>/dev/null && pwd -P) || return 1
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  state_real=$(fm_worker_canonical_path "$state") || return 1
  [ "$home_real" = "$owner_real" ] && [ "$state_real" = "$owner_real/state" ] || return 1
  marker="$owner_real/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  marker_task=$(cat "$marker" 2>/dev/null) || return 1
  [ "$marker_task" = "$FM_AGENT_TASK" ]
}

fm_worker_secondmate_effective_scope_matches() {
  local home state var value suffix expected actual owner_real root_override
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-}}
  [ -n "$home" ] || return 1
  state=${FM_STATE_OVERRIDE:-$home/state}
  fm_worker_secondmate_scope_matches "$home" "$state" || return 1
  owner_real=$(fm_worker_canonical_path "${FM_AGENT_OWNER_HOME:-}") || return 1
  root_override=${FM_ROOT_OVERRIDE:-}
  if [ -n "$root_override" ]; then
    actual=$(fm_worker_canonical_path "$root_override") || return 1
    [ "$actual" = "$owner_real" ] || return 1
  fi
  for var in FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE; do
    value=${!var:-}
    [ -n "$value" ] || continue
    case "$var" in
      FM_DATA_OVERRIDE) suffix=data ;;
      FM_PROJECTS_OVERRIDE) suffix=projects ;;
      FM_CONFIG_OVERRIDE) suffix=config ;;
    esac
    expected="$owner_real/$suffix"
    actual=$(fm_worker_canonical_path "$value") || return 1
    [ "$actual" = "$expected" ] || return 1
  done
}

fm_worker_process_environment() {
  fm_process_environment "$1"
}

fm_worker_linked_primary_topology_matches() {
  local root=$1 home=$2 root_common home_common root_top home_top
  root_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  home_top=$(git -C "$home" rev-parse --show-toplevel 2>/dev/null) || return 1
  root_common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || return 1
  home_common=$(git -C "$home" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || return 1
  [ "$(fm_worker_canonical_path "$root_top")" = "$root" ] \
    && [ "$(fm_worker_canonical_path "$home_top")" = "$home" ] \
    && [ "$(fm_worker_canonical_path "$root_common")" = \
      "$(fm_worker_canonical_path "$home_common")" ]
}

fm_worker_primary_bootstrap_matches() {
  local root home root_real home_real cwd branch default ref pid ppid sid env
  local common common_real common_birth sid_start
  case "${FM_AGENT_ROLE:-}" in ""|primary) ;; *) return 1 ;; esac
  [ -z "${FM_AGENT_TASK:-}" ] && [ -z "${FM_AGENT_OWNER_HOME:-}" ] || return 1
  root=${FM_ROOT_OVERRIDE:-$(cd "$_FM_WORKER_ISOLATION_LIB_DIR/.." && pwd)}
  home=${FM_HOME:-$root}
  root_real=$(fm_worker_canonical_path "$root") || return 1
  home_real=$(fm_worker_canonical_path "$home") || return 1
  [ "$root_real" = "$home_real" ] || return 1
  cwd=$(pwd -P) || return 1
  [ "$cwd" = "$root_real" ] || return 1
  branch=$(git -C "$root_real" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  ref=$(git -C "$root_real" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    default=${ref#origin/}
  elif git -C "$root_real" show-ref --verify --quiet refs/heads/main; then
    default=main
  elif git -C "$root_real" show-ref --verify --quiet refs/heads/master; then
    default=master
  else
    return 1
  fi
  [ "$branch" = "$default" ] || return 1
  [ ! -e "$root_real/.fm-secondmate-home" ] && [ ! -L "$root_real/.fm-secondmate-home" ] \
    || return 1
  # shellcheck source=/dev/null
  . "$_FM_WORKER_ISOLATION_LIB_DIR/fm-session-lock-lib.sh"
  common=$(git -C "$root_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || return 1
  common_real=$(fm_worker_canonical_path "$common") || return 1
  common_birth=$(fm_session_path_birth_epoch "$common_real") || return 1
  sid=$(fm_session_process_session_id "$$") || return 1
  [ "$sid" != "$$" ] || return 1
  sid_start=$(fm_session_process_start_epoch "$sid") || return 1
  [ "$sid_start" -lt "$common_birth" ] || return 1
  pid=$$
  while [ "$pid" -gt 1 ]; do
    env=$(fm_worker_process_environment "$pid") || return 1
    if printf '%s\n' "$env" | grep -Eq '(^|[[:space:]])FM_AGENT_ROLE=(crewmate|secondmate)($|[[:space:]])'; then
      return 1
    fi
    [ "$pid" != "$sid" ] || return 0
    ppid=$(fm_session_parent_pid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
  done
  return 1
}

fm_worker_primary_authority_matches_unlocked() {
  local operation=${1:-} root home root_real home_real cwd branch default ref
  local pid ppid env binding lock authority old marker authority_state binding_bound=0
  local test_tmp test_state test_bind_state='' legacy_test_state root_top
  case "${FM_AGENT_ROLE:-}" in ""|primary) ;; *) return 1 ;; esac
  [ -z "${FM_AGENT_TASK:-}" ] && [ -z "${FM_AGENT_OWNER_HOME:-}" ] || return 1
  root=${FM_ROOT_OVERRIDE:-$(cd "$_FM_WORKER_ISOLATION_LIB_DIR/.." && pwd)}
  home=${FM_HOME:-$root}
  root_real=$(fm_worker_canonical_path "$root") || return 1
  home_real=$(fm_worker_canonical_path "$home") || return 1
  cwd=$(pwd -P) || return 1
  if [ "${FM_TEST_PROCESS:-0}" = 1 ]; then
    test_tmp=$(fm_worker_canonical_path "${TMPDIR:-}") || return 1
    if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
      test_state=$(fm_worker_canonical_path "$FM_STATE_OVERRIDE") || return 1
      case "$test_state" in "$test_tmp"/*) ;; *) return 1 ;; esac
      test_bind_state=$test_state
      if [ -z "${FM_HOME:-}" ]; then
        home_real=$(fm_worker_canonical_path "${test_state%/*}") || return 1
      fi
    fi
    case "$root_real:$home_real" in
      "$cwd:$cwd"|"$cwd:$test_tmp"|"$cwd:$test_tmp"/*|\
      "$test_tmp"/*:"$test_tmp"/*|*:"$test_tmp"/*) ;;
      *) return 1 ;;
    esac
    root_top=$(git -C "$root_real" rev-parse --show-toplevel 2>/dev/null || true)
    if [ "$root_real" = "$home_real" ] \
      && [ "$(fm_worker_canonical_path "$root_top" 2>/dev/null || true)" \
        = "$root_real" ] \
      && [ -z "${FM_ROOT_OVERRIDE:-}" ] \
      && [ -z "${FM_HOME:-}" ] \
      && [ -z "${FM_STATE_OVERRIDE:-}" ]; then
      fm_worker_test_authority_capability_present
      return
    fi
    legacy_test_state=${test_bind_state:-$home_real/state}
    if [ "$operation" = "session lock acquisition" ] \
      && [ -f "$legacy_test_state/.primary-checkout" ] \
      && [ ! -L "$legacy_test_state/.primary-checkout" ] \
      && [ "$(cat "$legacy_test_state/.primary-checkout" 2>/dev/null)" \
        = "$root_real" ] \
      && [ -f "$legacy_test_state/.lock" ] \
      && [ ! -L "$legacy_test_state/.lock" ] \
      && [ ! -e "$legacy_test_state/.session-authority" ] \
      && [ ! -L "$legacy_test_state/.session-authority" ]; then
      . "$_FM_WORKER_ISOLATION_LIB_DIR/fm-session-lock-lib.sh"
      fm_session_test_authority_broker_present
      return
    fi
    if [ -n "$test_bind_state" ] || [ "$root_real" != "$home_real" ] \
      || [ "$(fm_worker_canonical_path "$root_top" 2>/dev/null || true)" \
        != "$root_real" ]; then
      [ -n "$test_bind_state" ] || test_bind_state="$home_real/state"
      fm_worker_test_authority_capability_present || return 1
      if [ ! -e "$test_bind_state" ] && [ ! -L "$test_bind_state" ]; then
        return 1
      fi
      if [ -e "$test_bind_state" ] || [ -L "$test_bind_state" ]; then
        if [ -f "$test_bind_state" ] && [ ! -L "$test_bind_state" ]; then
          return 0
        fi
        [ -d "$test_bind_state" ] && [ ! -L "$test_bind_state" ] || return 1
      fi
      FM_SESSION_AUTHORITY_FD=$FM_WORKER_TEST_AUTHORITY_FD
      FM_SESSION_AUTHORITY_DURABLE_FD=$FM_WORKER_TEST_DURABLE_AUTHORITY_FD
      export FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
      if fm_worker_test_primary_identity_bind \
        "$root_real" "$home_real" "$test_bind_state"; then
        return 0
      fi
      [ "$operation" = "session lock acquisition" ] || return 1
    fi
  fi
  git -C "$root_real" rev-parse --git-dir >/dev/null 2>&1 || return 1
  branch=$(git -C "$root_real" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  ref=$(git -C "$root_real" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    default=${ref#origin/}
  elif git -C "$root_real" show-ref --verify --quiet refs/heads/main; then
    default=main
  elif git -C "$root_real" show-ref --verify --quiet refs/heads/master; then
    default=master
  else
    return 1
  fi
  [ "$branch" = "$default" ] || return 1
  [ ! -e "$root_real/.fm-secondmate-home" ] && [ ! -L "$root_real/.fm-secondmate-home" ] \
    || return 1
  # shellcheck source=/dev/null
  . "$_FM_WORKER_ISOLATION_LIB_DIR/fm-session-lock-lib.sh"
  binding="$home_real/state/.primary-checkout"
  lock="$home_real/state/.lock"
  authority="$home_real/state/.session-authority"
  if [ -f "$binding" ] && [ ! -L "$binding" ]; then
    [ "$(cat "$binding" 2>/dev/null || true)" = "$root_real" ] || return 1
    binding_bound=1
  elif [ -e "$binding" ] || [ -L "$binding" ]; then
    return 1
  elif [ "$operation" != "session lock acquisition" ]; then
    return 1
  fi
  if [ "$root_real" != "$home_real" ] && [ "$binding_bound" -eq 0 ]; then
    fm_worker_linked_primary_topology_matches "$root_real" "$home_real" || return 1
  fi
  if [ -f "$lock" ] && [ ! -L "$lock" ] \
    && [ -f "$authority" ] && [ ! -L "$authority" ]; then
    old=$(cat "$lock" 2>/dev/null) || return 1
    fm_session_authority_read_shape "$authority" || return 1
    [ "$FM_SESSION_AUTHORITY_OWNER" = "$old" ] \
      && [ "$FM_SESSION_AUTHORITY_HOME" = "$home_real" ] \
      && [ "$FM_SESSION_AUTHORITY_CHECKOUT" = "$root_real" ] || return 1
    if fm_session_authority_read "$authority"; then
      authority_state=0
      fm_session_authority_process_state "$authority" || authority_state=$?
      if [ "$authority_state" -eq 0 ]; then
        fm_session_authority_is_current_ancestor "$authority" || return 1
      else
        [ "$authority_state" -eq 1 ] \
          && [ "$operation" = "session lock acquisition" ] \
          && fm_session_authority_capability_present || return 1
      fi
    else
      authority_state=0
      fm_session_authority_process_state "$authority" || authority_state=$?
      [ "$authority_state" -eq 1 ] && [ "$operation" = "session lock acquisition" ] \
        && fm_session_authority_capability_present || return 1
    fi
  else
    [ ! -e "$authority" ] && [ ! -L "$authority" ] || return 1
    if [ -e "$lock" ] || [ -L "$lock" ]; then
      [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
      old=$(cat "$lock" 2>/dev/null) || return 1
      pid=${old%%|*}
      case "$pid" in ''|*[!0-9]*) return 1 ;; esac
      if kill -0 "$pid" 2>/dev/null; then
        fm_session_legacy_owner_is_current "$old" || return 1
        case "$operation" in "session lock acquisition"|update) ;; *) return 1 ;; esac
      else
        [ "$operation" = "session lock acquisition" ] || return 1
      fi
    else
      [ "$operation" = "session lock acquisition" ] || return 1
    fi
    fm_session_authority_capability_present || return 1
  fi
  pid=$$
  while [ "$pid" -gt 1 ]; do
    env=$(fm_worker_process_environment "$pid") || return 1
    if printf '%s\n' "$env" | grep -Eq '(^|[[:space:]])FM_AGENT_ROLE=(crewmate|secondmate)($|[[:space:]])'; then
      return 1
    fi
    ppid=$(fm_session_parent_pid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
  done
  [ "$pid" -eq 1 ] || return 1
  [ "$cwd" = "$root_real" ]
}

fm_worker_isolation_sweep_current() {
  local script root home state
  script="$_FM_WORKER_ISOLATION_LIB_DIR/fm-isolation-sweep.sh"
  [ -x "$script" ] || return 1
  root=${FM_ROOT_OVERRIDE:-$(cd "$_FM_WORKER_ISOLATION_LIB_DIR/.." && pwd)}
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}
  state=${FM_STATE_OVERRIDE:-$home/state}
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$script"
}

fm_worker_primary_authority_matches() {
  local operation=${1:-}
  fm_worker_isolation_sweep_current || return 2
  if [ "${FM_TEST_PROCESS:-0}" != 1 ]; then
    fm_worker_primary_authority_matches_unlocked "$operation"
    return
  fi
  case "${FM_TEST_AUTHORITY_BROKER_PID:-}" in
    ''|*[!0-9]*)
      fm_worker_primary_authority_matches_unlocked "$operation"
      return
      ;;
  esac
  # Keep the hostile lock-path check, but leave the short capability-read lock
  # inside the test-only helper. Do not hold it across the /proc proof.
  fm_worker_test_primary_identity_lock_validate || return 1
  fm_worker_primary_authority_matches_unlocked "$operation"
}

# fm_worker_refuse_primary_operation <operation>
# Fail closed with one actionable line when a declared task worker attempts an
# operation only a home's primary may perform. Silent and successful for every
# other process, so a call site can guard unconditionally.
fm_worker_refuse_primary_operation() {
  local operation=$1 status=0
  case "${FM_AGENT_ROLE:-}" in
    primary|"")
      fm_worker_primary_authority_matches "$operation" && return 0
      status=$?
      if [ "$status" -eq 2 ]; then
        echo "error: $operation refused: worker isolation sweep is unproven" >&2
        return 1
      fi
      echo "error: $operation refused: primary identity is not bound to this process and checkout" >&2
      return 1
      ;;
    crewmate)
      echo "error: $operation refused: this process is task worker '${FM_AGENT_TASK:-unnamed}' launched by ${FM_AGENT_OWNER_HOME:-an unrecorded home}; a task worker never owns a firstmate operational home" >&2
      return 1
      ;;
    secondmate)
      if ! fm_worker_secondmate_effective_scope_matches; then
        echo "error: $operation refused: secondmate '${FM_AGENT_TASK:-unnamed}' is not operating in its declared home ${FM_AGENT_OWNER_HOME:-<missing>}" >&2
        return 1
      fi
      if ! fm_worker_isolation_sweep_current; then
        echo "error: $operation refused: worker isolation sweep is unproven" >&2
        return 1
      fi
      . "$_FM_WORKER_ISOLATION_LIB_DIR/fm-session-lock-lib.sh"
      if ! fm_session_authority_broker_present \
        "$_FM_WORKER_ISOLATION_LIB_DIR/fm-session-authority-exec.sh"; then
        echo "error: $operation refused: authenticated secondmate authority broker is missing or invalid" >&2
        return 1
      fi
      return 0
      ;;
    *)
      echo "error: $operation refused: unknown worker role '${FM_AGENT_ROLE}'" >&2
      return 1
      ;;
  esac
}
