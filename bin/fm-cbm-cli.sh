#!/usr/bin/env bash
# Logged CLI wrapper for codebase-memory-mcp.
# Soft dependency: if the real binary is missing, exit 127 after a best-effort log.
#
# Usage (same shape as upstream CLI):
#   fm-cbm-cli.sh <tool> [json-args]
#   fm-cbm-cli.sh cli <tool> [json-args]   # accepted for copy-paste parity
#
# Each invocation appends one line to $FM_HOME/data/cbm/usage.jsonl
# (see fm_cbm_usage_log in bin/fm-cbm-lib.sh). Set FM_CBM_TASK_ID to tag a task.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-cbm-lib.sh
. "$SCRIPT_DIR/fm-cbm-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-cbm-cli.sh <tool> [json-args]
       fm-cbm-cli.sh cli <tool> [json-args]
EOF
}

if [ "${1:-}" = '-h' ] || [ "${1:-}" = '--help' ] || [ "${1:-}" = 'help' ]; then
  usage
  exit 0
fi

# Accept both `fm-cbm-cli.sh list_projects` and `fm-cbm-cli.sh cli list_projects`.
if [ "${1:-}" = 'cli' ]; then
  shift || true
fi

tool=${1:-}
if [ -z "$tool" ]; then
  usage >&2
  exit 2
fi
shift || true

if ! fm_cbm_prepare_environment; then
  fm_cbm_usage_log --source cli --tool "$tool" --rc 127 --detail 'binary-missing-or-disabled'
  echo "error: CBM disabled or binary missing" >&2
  exit 127
fi

export CBM_CACHE_DIR=$FM_CBM_RESOLVED_CACHE
export CBM_MEM_BUDGET_MB=$FM_CBM_RESOLVED_MEM
export CBM_WORKERS=$FM_CBM_RESOLVED_WORKERS
export PATH="$FM_CBM_RESOLVED_PATH_PREFIX:$PATH"

start_ms=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
set +e
"$FM_CBM_RESOLVED_BIN" cli "$tool" "$@"
rc=$?
set -e
end_ms=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
ms=$((end_ms - start_ms))
# Strip log noise from duration edge cases
[ "$ms" -ge 0 ] 2>/dev/null || ms=

fm_cbm_usage_log --source cli --tool "$tool" --rc "$rc" --ms "${ms:-}"
exit "$rc"
