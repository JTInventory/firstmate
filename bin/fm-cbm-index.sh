#!/usr/bin/env bash
# Index or report status for optional codebase-memory-mcp projects.
# Soft ops helper: never required for fleet health.
#
# Usage:
#   fm-cbm-index.sh status
#   fm-cbm-index.sh list
#   fm-cbm-index.sh index [<abs-path>|jt|firstmate|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-cbm-lib.sh
. "$SCRIPT_DIR/fm-cbm-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-cbm-index.sh status|list|index [<path>|jt|firstmate|all]
EOF
}

cmd=${1:-status}
shift || true

case "$cmd" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

if ! fm_cbm_prepare_environment; then
  echo "CBM: disabled or binary missing"
  [ "$cmd" = status ] && exit 0
  exit 1
fi

bin=$FM_CBM_RESOLVED_BIN
cache=$FM_CBM_RESOLVED_CACHE
export CBM_CACHE_DIR=$cache
export CBM_MEM_BUDGET_MB=$FM_CBM_RESOLVED_MEM
export CBM_WORKERS=$FM_CBM_RESOLVED_WORKERS
export PATH="$FM_CBM_RESOLVED_PATH_PREFIX:$PATH"

resolve_target() {
  case "$1" in
    jt|JT|jt-control-room|JT-Control-Room)
      if [ -d /root/.openclaw/workspace/projects/active/JT-Control-Room ]; then
        printf '%s\n' /root/.openclaw/workspace/projects/active/JT-Control-Room
      elif [ -d "$FM_HOME/../.openclaw/workspace/projects/active/JT-Control-Room" ]; then
        printf '%s\n' "$(cd "$FM_HOME/../.openclaw/workspace/projects/active/JT-Control-Room" && pwd -P)"
      else
        return 1
      fi
      ;;
    firstmate|fm)
      printf '%s\n' "$FM_ROOT"
      ;;
    all)
      resolve_target jt || true
      resolve_target firstmate || true
      ;;
    /*)
      [ -d "$1" ] || return 1
      printf '%s\n' "$1"
      ;;
    *)
      return 1
      ;;
  esac
}

case "$cmd" in
  status)
    fm_cbm_status_line
    ;;
  list)
    "$bin" cli list_projects 2>/dev/null | sed '/^level=/d' || echo '{"projects":[]}'
    ;;
  index)
    target=${1:-jt}
    if [ "$target" = all ]; then
      mapfile -t paths < <(resolve_target all)
    else
      mapfile -t paths < <(resolve_target "$target")
    fi
    if [ "${#paths[@]}" -eq 0 ]; then
      echo "error: could not resolve index target '$target'" >&2
      exit 1
    fi
    for p in "${paths[@]}"; do
      [ -n "$p" ] || continue
      if ! fm_cbm_project_eligible "$p"; then
        echo "error: index target is not allowlisted: $p" >&2
        exit 1
      fi
      echo "indexing: $p"
      payload=$(jq -cn --arg repo_path "$p" '{repo_path: $repo_path}')
      "$bin" cli index_repository "$payload" 2>&1 | sed '/^level=/d'
    done
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
