#!/usr/bin/env bash
# Summarize durable CBM usage from $FM_HOME/data/cbm/usage.jsonl.
#
# Usage:
#   fm-cbm-usage.sh              # path + totals by source/tool
#   fm-cbm-usage.sh summary
#   fm-cbm-usage.sh path
#   fm-cbm-usage.sh tail [N]     # last N raw lines (default 20)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-cbm-lib.sh
. "$SCRIPT_DIR/fm-cbm-lib.sh"

log=$(fm_cbm_usage_log_path)
cmd=${1:-summary}
shift || true

case "$cmd" in
  -h|--help|help)
    cat <<'EOF'
Usage: fm-cbm-usage.sh [summary|path|tail [N]]
EOF
    exit 0
    ;;
  path)
    printf '%s\n' "$log"
    ;;
  tail)
    n=${1:-20}
    if [ ! -f "$log" ]; then
      echo "no usage log yet: $log"
      exit 0
    fi
    tail -n "$n" "$log"
    ;;
  summary)
    printf 'log: %s\n' "$log"
    if [ ! -f "$log" ]; then
      echo 'events: 0 (file missing)'
      exit 0
    fi
    total=$(wc -l <"$log" | tr -d ' ')
    printf 'events: %s\n' "$total"
    if command -v jq >/dev/null 2>&1; then
      echo 'by_source:'
      jq -r '.source // "unknown"' "$log" | sort | uniq -c | sort -nr | awk '{printf "  %s %s\n", $2, $1}'
      echo 'by_tool:'
      jq -r '.tool // "unknown"' "$log" | sort | uniq -c | sort -nr | awk '{printf "  %s %s\n", $2, $1}'
    else
      echo '(install jq for source/tool breakdown)'
    fi
    ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 1
    ;;
esac
