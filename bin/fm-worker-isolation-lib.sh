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
FM_WORKER_ISOLATION_HOME_VARS="FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE"
FM_WORKER_ISOLATION_LIFECYCLE_VARS="FM_LIFECYCLE_HOME FM_LIFECYCLE_STATE FM_LIFECYCLE_SCRIPT"
_FM_WORKER_ISOLATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_worker_shell_quote() {  # <text>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_worker_launch_env_prefix <role> <task-id> <owner-home>
# Print the exact env-assignment prefix a launch command must carry, with one
# trailing space, so a caller composes `<prefix><launch command>`. Refuses an
# unknown role, an empty id, or a non-absolute home rather than emitting a
# partial prefix that would leave the child inheriting a home.
fm_worker_launch_env_prefix() {
  local role=$1 id=$2 home=$3 var
  case "$role" in
    crewmate|secondmate) ;;
    *) echo "error: unknown agent role '$role'; expected crewmate or secondmate" >&2; return 1 ;;
  esac
  [ -n "$id" ] || { echo "error: agent role $role requires a task id" >&2; return 1; }
  case "$home" in
    /*) ;;
    *) echo "error: agent role $role requires an absolute owning home, got '${home:-<empty>}'" >&2; return 1 ;;
  esac
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

fm_worker_primary_authority_matches() {
  local root home root_real home_real pid ppid env role task cwd
  case "${FM_AGENT_ROLE:-}" in ""|primary) ;; *) return 1 ;; esac
  [ -z "${FM_AGENT_TASK:-}" ] && [ -z "${FM_AGENT_OWNER_HOME:-}" ] || return 1
  root=${FM_ROOT_OVERRIDE:-$(cd "$_FM_WORKER_ISOLATION_LIB_DIR/.." && pwd)}
  home=${FM_HOME:-$root}
  root_real=$(fm_worker_canonical_path "$root") || return 1
  home_real=$(fm_worker_canonical_path "$home") || return 1
  [ -d "$home_real/state" ] || return 1
  [ -d /proc ] || return 1
  pid=$$
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    env=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null ) || return 1
    role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p' | head -1)
    task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p' | head -1)
    if [ "$pid" != "$$" ]; then
      case "$role" in crewmate|secondmate) return 1 ;; esac
      [ -z "$task" ] || return 1
    fi
    ppid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null) || return 1
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    pid=$ppid
  done
  cwd=$(readlink -f "/proc/$$/cwd" 2>/dev/null) || return 1
  [ "$cwd" = "$root_real" ] || return 1
  git -C "$root_real" rev-parse --git-dir >/dev/null 2>&1 || return 1
  [ ! -e "$root_real/.fm-secondmate-home" ] && [ ! -L "$root_real/.fm-secondmate-home" ] \
    || return 1
}

# fm_worker_refuse_primary_operation <operation>
# Fail closed with one actionable line when a declared task worker attempts an
# operation only a home's primary may perform. Silent and successful for every
# other process, so a call site can guard unconditionally.
fm_worker_refuse_primary_operation() {
  local operation=$1
  case "${FM_AGENT_ROLE:-}" in
    primary|"")
      fm_worker_primary_authority_matches && return 0
      echo "error: $operation refused: primary identity is not bound to this process and checkout" >&2
      return 1
      ;;
    crewmate)
      echo "error: $operation refused: this process is task worker '${FM_AGENT_TASK:-unnamed}' launched by ${FM_AGENT_OWNER_HOME:-an unrecorded home}; a task worker never owns a firstmate operational home" >&2
      return 1
      ;;
    secondmate)
      fm_worker_secondmate_effective_scope_matches && return 0
      echo "error: $operation refused: secondmate '${FM_AGENT_TASK:-unnamed}' is not operating in its declared home ${FM_AGENT_OWNER_HOME:-<missing>}" >&2
      return 1
      ;;
    *)
      echo "error: $operation refused: unknown worker role '${FM_AGENT_ROLE}'" >&2
      return 1
      ;;
  esac
}
