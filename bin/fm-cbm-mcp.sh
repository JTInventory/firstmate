#!/usr/bin/env bash
# Optional MCP entrypoint wrapper: logs one mcp-session event, then execs the
# real codebase-memory-mcp binary with full stdio passthrough.
#
# Point Codex (or other hosts) at this script instead of the raw binary to count
# MCP process starts in $FM_HOME/data/cbm/usage.jsonl. Per-tool MCP calls still
# need host-side telemetry; this only records sessions.
#
# Example (~/.codex/config.toml):
#   [mcp_servers.codebase-memory-mcp]
#   command = "/root/firstmate/bin/fm-cbm-mcp.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-cbm-lib.sh
. "$SCRIPT_DIR/fm-cbm-lib.sh"

if ! fm_cbm_prepare_environment; then
  fm_cbm_usage_log --source mcp-session --tool stdio --rc 127 --detail 'binary-missing-or-disabled'
  echo "error: CBM disabled or binary missing" >&2
  exit 127
fi

export CBM_CACHE_DIR=$FM_CBM_RESOLVED_CACHE
export CBM_MEM_BUDGET_MB=$FM_CBM_RESOLVED_MEM
export CBM_WORKERS=$FM_CBM_RESOLVED_WORKERS

fm_cbm_usage_log --source mcp-session --tool stdio --rc 0 --detail "bin=$FM_CBM_RESOLVED_BIN"
exec "$FM_CBM_RESOLVED_BIN" "$@"
