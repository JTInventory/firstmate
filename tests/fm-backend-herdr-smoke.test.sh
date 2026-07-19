#!/usr/bin/env bash
# Optional read-only smoke for a real Herdr installation.
set -u

if [ "${FM_HERDR_SMOKE:-}" != 1 ]; then
  echo "skip: set FM_HERDR_SMOKE=1 to opt into the real Herdr smoke"
  exit 0
fi
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr CLI not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not installed"; exit 0; }

status=$(herdr status --json 2>/dev/null) || { echo "skip: Herdr status unavailable (no live socket)"; exit 0; }
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // 0' 2>/dev/null)
running=$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)
[ "$running" = true ] || { echo "skip: Herdr server is not running"; exit 0; }
[ "$protocol" -ge 14 ] 2>/dev/null || { echo "skip: Herdr protocol ${protocol:-unknown} is older than 14"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_version_check
echo "ok - real Herdr smoke: client protocol $protocol and live server verified (read-only)"
