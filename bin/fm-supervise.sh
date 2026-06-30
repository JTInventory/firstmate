#!/usr/bin/env bash
# Print a read-only Firstmate operational supervision checklist.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervision-model.sh
. "$SCRIPT_DIR/fm-supervision-model.sh"

MODE=text
INCLUDE_OK=0
DEFAULT_REMINDERS=1
EXTERNAL_PRS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --text)
      MODE=text
      ;;
    --json)
      MODE=json
      ;;
    --schema)
      MODE=schema
      ;;
    --include-ok)
      INCLUDE_OK=1
      ;;
    --no-default-reminders)
      DEFAULT_REMINDERS=0
      ;;
    --external-pr)
      shift
      if [ "$#" -eq 0 ]; then
        fm_supervision_usage >&2
        exit 2
      fi
      EXTERNAL_PRS="${EXTERNAL_PRS:+$EXTERNAL_PRS }$1"
      ;;
    --help|-h)
      fm_supervision_usage
      exit 0
      ;;
    *)
      fm_supervision_usage >&2
      exit 2
      ;;
  esac
  shift
done

export FM_SUPERVISE_INCLUDE_OK="$INCLUDE_OK"
export FM_SUPERVISE_DEFAULT_REMINDERS_ENABLED="$DEFAULT_REMINDERS"
export FM_SUPERVISE_EXTERNAL_PRS="$EXTERNAL_PRS"

fm_supervision_collect_and_emit "$MODE"
