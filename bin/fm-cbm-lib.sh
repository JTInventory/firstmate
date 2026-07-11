# shellcheck shell=bash
# Optional codebase-memory-mcp (CBM) helpers for First Mate.
#
# CBM is a soft orientation dependency: when the binary or index is missing,
# callers degrade silently and crewmates keep using normal search/read tools.
#
# Usage: . bin/fm-cbm-lib.sh
# Expects CONFIG (and optionally FM_HOME) to already be set by the caller, the
# same way other firstmate libs do. Pure functions write nothing to stdout
# except the explicit echo helpers below.

# Defaults (overridable via environment or config/cbm.env).
# FM_CBM_ENABLED: unset/auto = on when binary exists; 0/false/off = force off; 1/true/on = force on
# FM_CBM_CACHE_DIR: sqlite store; default $HOME/.cache/codebase-memory-mcp or /root/var/cbm-cache if present
# FM_CBM_MEM_BUDGET_MB / FM_CBM_WORKERS: resource caps for the host

fm_cbm_truthy() {
  case "${1:-}" in
    ''|0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *) return 0 ;;
  esac
}

fm_cbm_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_cbm_resource_cap() {
  local value=${1:-} fallback=$2 maximum=$3
  if [[ "$value" =~ ^[1-9][0-9]*$ ]] && [ "$value" -le "$maximum" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

fm_cbm_canonical_executable() {
  local candidate=$1 dir
  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -x "$candidate" ] || return 1
  dir=$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$candidate")"
}

fm_cbm_load_config_file() {
  local conf key val
  conf="${CONFIG:-${FM_HOME:-}/config}/cbm.env"
  [ -f "$conf" ] || return 0
  # Only allow simple FM_CBM_*=VALUE lines; no shell execution / source.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      FM_CBM_*=*)
        key=${line%%=*}
        val=${line#*=}
        val=${val%$'\r'}
        val=${val#\"}; val=${val%\"}
        val=${val#\'}; val=${val%\'}
        case "$key" in
          FM_CBM_ENABLED|FM_CBM_CACHE_DIR|FM_CBM_MEM_BUDGET_MB|FM_CBM_WORKERS|FM_CBM_BIN)
            export "$key=$val"
            ;;
        esac
        ;;
    esac
  done < "$conf"
}

fm_cbm_binary() {
  local b
  if [ -n "${FM_CBM_BIN:-}" ]; then
    fm_cbm_canonical_executable "$FM_CBM_BIN" && return 0
  fi
  b=$(command -v codebase-memory-mcp 2>/dev/null || true)
  if [ -n "$b" ] && [ -x "$b" ]; then
    case "$b" in
      /*) fm_cbm_canonical_executable "$b" && return 0 ;;
      *)
        b="$(cd -P "$(dirname "$b")" 2>/dev/null && pwd)/$(basename "$b")"
        fm_cbm_canonical_executable "$b" && return 0
        ;;
    esac
  fi
  for b in "$HOME/.local/bin/codebase-memory-mcp" /root/.local/bin/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp; do
    if [ -x "$b" ]; then
      fm_cbm_canonical_executable "$b" && return 0
    fi
  done
  return 1
}

fm_cbm_cache_dir() {
  if [ -n "${FM_CBM_CACHE_DIR:-}" ]; then
    printf '%s\n' "$FM_CBM_CACHE_DIR"
    return 0
  fi
  if [ -d /root/var/cbm-cache ]; then
    printf '%s\n' /root/var/cbm-cache
    return 0
  fi
  printf '%s\n' "${HOME:-/root}/.cache/codebase-memory-mcp"
}

fm_cbm_enabled() {
  fm_cbm_load_config_file
  case "${FM_CBM_ENABLED:-auto}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
    1|true|TRUE|yes|YES|on|ON) fm_cbm_binary >/dev/null 2>&1 ;;
    auto|''|*) fm_cbm_binary >/dev/null 2>&1 ;;
  esac
}

# Allowlist: config/cbm-projects (local) — one token per line:
#   .openclaw
#   firstmate
#   jt-control-room
#   /absolute/path/to/repo
# Empty/missing file => default allowlist: .openclaw, jt-control-room, firstmate
fm_cbm_default_allowlist() {
  printf '%s\n' '.openclaw' 'jt-control-room' 'firstmate' 'JT-Control-Room'
}

fm_cbm_project_eligible() {
  local project_abs=${1:-} base lower line conf
  [ -n "$project_abs" ] || return 1
  base=$(basename "$project_abs")
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  conf="${CONFIG:-${FM_HOME:-}/config}/cbm-projects"

  if [ -f "$conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      line=${line%$'\r'}
      if [ "$line" = "$project_abs" ] || [ "$line" = "$base" ]; then
        return 0
      fi
      # case-insensitive name match
      if [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" = "$lower" ]; then
        return 0
      fi
    done < "$conf"
    return 1
  fi

  case "$project_abs" in
    */JT-Control-Room|*/JT-Control-Room/*|*/jt-control-room|*/jt-control-room/*) return 0 ;;
  esac

  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" = "$lower" ] && return 0
  done <<EOF
$(fm_cbm_default_allowlist)
EOF
  # .openclaw primary checkout hosts JT work
  [ "$lower" = ".openclaw" ] && return 0
  return 1
}

fm_cbm_index_target_eligible() {
  local project_abs=${1:-}
  [ -n "$project_abs" ] || return 1
  fm_cbm_project_eligible "$project_abs" || return 1
  case "$project_abs" in
    */.openclaw) return 1 ;;
  esac
}

# Print shell-safe KEY=VALUE assignments suitable for prefixing a launch command
# or for `export` via tmux. One assignment per line without the export keyword.
fm_cbm_env_assignments() {
  local bin cache mem workers path_prefix
  fm_cbm_enabled || return 1
  bin=$(fm_cbm_binary) || return 1
  cache=$(fm_cbm_cache_dir)
  mem=$(fm_cbm_resource_cap "${FM_CBM_MEM_BUDGET_MB:-}" 1024 4096)
  workers=$(fm_cbm_resource_cap "${FM_CBM_WORKERS:-}" 2 8)
  mkdir -p "$cache" 2>/dev/null || true
  path_prefix=$(dirname "$bin")
  printf 'CBM_CACHE_DIR=%s\n' "$(fm_cbm_shell_quote "$cache")"
  printf 'FM_CBM_BIN=%s\n' "$(fm_cbm_shell_quote "$bin")"
  printf 'CBM_MEM_BUDGET_MB=%s\n' "$(fm_cbm_shell_quote "$mem")"
  printf 'CBM_WORKERS=%s\n' "$(fm_cbm_shell_quote "$workers")"
  printf 'FM_CBM_PATH_PREFIX=%s\n' "$(fm_cbm_shell_quote "$path_prefix")"
}

fm_cbm_prepare_environment() {
  fm_cbm_enabled || return 1
  FM_CBM_RESOLVED_BIN=$(fm_cbm_binary) || return 1
  FM_CBM_RESOLVED_CACHE=$(fm_cbm_cache_dir)
  FM_CBM_RESOLVED_MEM=$(fm_cbm_resource_cap "${FM_CBM_MEM_BUDGET_MB:-}" 1024 4096)
  FM_CBM_RESOLVED_WORKERS=$(fm_cbm_resource_cap "${FM_CBM_WORKERS:-}" 2 8)
  FM_CBM_RESOLVED_PATH_PREFIX=$(dirname "$FM_CBM_RESOLVED_BIN")
  mkdir -p "$FM_CBM_RESOLVED_CACHE" 2>/dev/null || true
}

# Echo a single-line env prefix for the agent launch command (codex/claude/...).
# Example: CBM_CACHE_DIR='...' CBM_MEM_BUDGET_MB=1024 PATH='/x:/usr/bin'
fm_cbm_launch_env_prefix_prepared() {
  printf "CBM_CACHE_DIR=%s CBM_MEM_BUDGET_MB=%s CBM_WORKERS=%s PATH=%s:\"\$PATH\" " \
    "$(fm_cbm_shell_quote "$FM_CBM_RESOLVED_CACHE")" \
    "$(fm_cbm_shell_quote "$FM_CBM_RESOLVED_MEM")" \
    "$(fm_cbm_shell_quote "$FM_CBM_RESOLVED_WORKERS")" \
    "$(fm_cbm_shell_quote "$FM_CBM_RESOLVED_PATH_PREFIX")"
}

fm_cbm_launch_env_prefix() {
  fm_cbm_prepare_environment || return 1
  fm_cbm_launch_env_prefix_prepared
}

# Append orientation policy to a crewmate brief when eligible.
# Args: <brief-path> <project-abs> <kind>
fm_cbm_append_brief_policy() {
  local brief=$1 project_abs=$2
  local bin cache slug fm_root_for_cli cli_wrap
  [ -f "$brief" ] || return 0
  grep -qxF '<!-- firstmate:cbm-orientation:start -->' "$brief" 2>/dev/null && return 0
  fm_cbm_enabled || return 0
  fm_cbm_project_eligible "$project_abs" || return 0
  bin=$(fm_cbm_binary) || return 0
  cache=$(fm_cbm_cache_dir)
  slug=$(basename "$project_abs")
  # Prefer the repo bin that wrote this brief (works in worktrees and homes).
  fm_root_for_cli=${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  cli_wrap="$fm_root_for_cli/bin/fm-cbm-cli.sh"

  cat >> "$brief" <<EOF

<!-- firstmate:cbm-orientation:start -->
# Optional code orientation (codebase-memory-mcp)

CBM is optional memory/orientation for multi-file code exploration. It is not proof, not runtime truth, and not authority for merge, deploy, refresh, purchase, or destructive action.

## When to use it
- Prefer CBM for architecture maps, call chains, multi-module domain navigation, and "where is X?" scouting.
- Skip CBM for tiny one-file tasks (single manifest/doc read) when a direct Read is enough.

## How to use it (if tools or CLI are available)
1. Prefer MCP tools from \`codebase-memory-mcp\` when listed (host MCP registration).
2. Or logged CLI (preferred for First Mate metering): \`$cli_wrap <tool> [json]\` with env \`CBM_CACHE_DIR=$cache\` (and \`FM_CBM_TASK_ID\` if set). Fallback raw: \`$bin cli …\`.
3. Start with \`list_projects\` / \`get_architecture\` (overview) or \`search_graph\` with a tight limit.
4. Then **Read** the few real files needed to verify claims. Graph edges can be noisy.
5. Project path for this task: \`$project_abs\` (basename \`$slug\`). Indexed JT app path is often under \`workspace/projects/active/JT-Control-Room\` when the spawn root is \`.openclaw\`.

## If CBM is missing or empty
Continue with Grep/Glob/Read/shell. Append a short note in your report that CBM was unavailable. Do not block solely because CBM failed.
<!-- firstmate:cbm-orientation:end -->
EOF
}

# One-line status for bootstrap/guard surfaces (never fails the caller hard).
fm_cbm_status_line() {
  local bin cache
  if ! fm_cbm_enabled; then
    printf 'CBM: off\n'
    return 0
  fi
  bin=$(fm_cbm_binary) || { printf 'CBM: missing-binary\n'; return 0; }
  cache=$(fm_cbm_cache_dir)
  if [ -d "$cache" ] && [ -n "$(ls -A "$cache" 2>/dev/null || true)" ]; then
    printf 'CBM: ready binary=%s cache=%s\n' "$bin" "$cache"
  else
    printf 'CBM: binary-ok empty-cache=%s (run index for projects)\n' "$cache"
  fi
}

# Durable CBM usage log (survives Codex log cleanup). Under $FM_HOME/data/cbm/.
fm_cbm_usage_dir() {
  local home data
  home=${FM_HOME:-${FM_ROOT:-}}
  if [ -z "$home" ]; then
    home=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || home="${HOME:-/root}/firstmate"
  fi
  data=${FM_DATA_OVERRIDE:-$home/data}
  printf '%s\n' "$data/cbm"
}

fm_cbm_usage_log_path() {
  printf '%s/usage.jsonl\n' "$(fm_cbm_usage_dir)"
}

# Append one JSONL usage event. Never fails the caller (best-effort).
# Args: --source <cli|index|mcp-session|...> --tool <name> [--rc N] [--ms N] [--detail <text>]
fm_cbm_usage_log() {
  local source tool rc=0 ms detail task logdir logfile line
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source=${2:-}; shift 2 ;;
      --tool) tool=${2:-}; shift 2 ;;
      --rc) rc=${2:-0}; shift 2 ;;
      --ms) ms=${2:-}; shift 2 ;;
      --detail) detail=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$source" ] || return 0
  [ -n "$tool" ] || tool=unknown
  task=${FM_CBM_TASK_ID:-${FM_TASK_ID:-}}
  logdir=$(fm_cbm_usage_dir) || return 0
  mkdir -p "$logdir" 2>/dev/null || return 0
  logfile="$logdir/usage.jsonl"
  if command -v jq >/dev/null 2>&1; then
    line=$(
      jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg source "$source" \
        --arg tool "$tool" \
        --argjson rc "$rc" \
        --arg ms "${ms:-}" \
        --arg task "$task" \
        --arg detail "$detail" \
        '{
          ts: $ts,
          source: $source,
          tool: $tool,
          rc: $rc,
          ms: (if $ms == "" then null else ($ms|tonumber) end),
          task_id: (if $task == "" then null else $task end),
          detail: (if $detail == "" then null else $detail end)
        }'
    ) || return 0
  else
    command -v python3 >/dev/null 2>&1 || return 0
    line=$(python3 - "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$source" "$tool" "$rc" "${ms:-}" "$task" "$detail" <<'PY'
import json
import sys

ts, source, tool, rc, ms, task, detail = sys.argv[1:]
event = {
    "ts": ts,
    "source": source,
    "tool": tool,
    "rc": int(rc),
    "ms": int(ms) if ms else None,
    "task_id": task or None,
    "detail": detail or None,
}
print(json.dumps(event, separators=(",", ":")))
PY
    ) || return 0
  fi
  printf '%s\n' "$line" >>"$logfile" 2>/dev/null || true
}
