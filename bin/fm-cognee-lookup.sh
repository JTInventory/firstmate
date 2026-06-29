#!/usr/bin/env bash
# Local dry-run wrapper for future Cognee lookup integration.
#
# This script deliberately does not call Cognee. It accepts a local answer
# fixture, treats it as an untrusted hint, and asks the local manifest checker to
# prove whether any cited source can be reopened and checksum-verified.
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: fm-cognee-lookup.sh --dry-run --query <text> [--manifest <manifest.tsv> --answer-file <answer.txt>]

No live mode exists yet. Without --dry-run this command fails closed before any
network, environment, MCP, or config access can happen.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-cognee-telemetry-lib.sh"
TELEMETRY_START_MS=$(fm_cognee_telemetry_now_ms)
DRY_RUN=false
QUERY=
MANIFEST=
ANSWER_FILE=

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --query)
      QUERY=${2:-}
      [ -n "$QUERY" ] || die "--query requires text"
      shift 2
      ;;
    --manifest)
      MANIFEST=${2:-}
      [ -n "$MANIFEST" ] || die "--manifest requires a path"
      shift 2
      ;;
    --answer-file)
      ANSWER_FILE=${2:-}
      [ -n "$ANSWER_FILE" ] || die "--answer-file requires a path"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if ! "$DRY_RUN"; then
  fm_cognee_telemetry_log \
    cognee_lookup live blocked live_cognee_lookup_not_implemented 0 \
    "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" \
    "" "" not_attempted "" unknown_vendor_cost "" unknown_vendor_cost
  echo "label=blocked_missing_proof reason=live_cognee_lookup_not_implemented external_action_authorized=false" >&2
  exit 2
fi

[ -n "$QUERY" ] || die "--query is required in dry-run mode"

query_hash=$(printf '%s' "$QUERY" | sha256sum | awk '{print $1}')
query_bytes=$(printf '%s' "$QUERY" | wc -c | tr -d ' ')

echo "mode=dry-run"
echo "query_sha256=$query_hash"
echo "query_bytes=$query_bytes"
echo "cognee_answer_status=hint_only"
echo "external_action_authorized=false"

if [ -z "$MANIFEST" ] && [ -z "$ANSWER_FILE" ]; then
  fm_cognee_telemetry_log \
    cognee_lookup dry-run hint_only none 0 \
    "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" \
    "" "" no_manifest_or_answer_fixture 0 known_zero_local "" not_called
  echo "label=hint_only reason=no_manifest_or_answer_fixture external_action_authorized=false"
  exit 0
fi

[ -n "$MANIFEST" ] || die "--manifest is required when --answer-file is used"
[ -n "$ANSWER_FILE" ] || die "--answer-file is required when --manifest is used"

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-cognee-lookup.XXXXXX")
cleanup_lookup() { rm -f "$TMP_OUT"; }
trap cleanup_lookup EXIT

set +e
"$SCRIPT_DIR/fm-cognee-manifest-check.sh" --manifest "$MANIFEST" --answer-file "$ANSWER_FILE" > "$TMP_OUT"
rc=$?
set -e
cat "$TMP_OUT"

source_outcome=$(
  awk '
    {
      label = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^reason=/) { sub(/^reason=/, "", $i); print $i; exit }
        if ($i ~ /^label=/) { label = $i; sub(/^label=/, "", label) }
      }
      if (label != "") { print label; exit }
    }
  ' "$TMP_OUT"
)
[ -n "$source_outcome" ] || source_outcome=manifest_check_exit_$rc
if [ "$rc" -eq 0 ]; then
  tel_status=verified
  tel_error=none
else
  tel_status=blocked
  tel_error=$source_outcome
fi
fm_cognee_telemetry_log \
  cognee_lookup dry-run "$tel_status" "$tel_error" 0 \
  "$(fm_cognee_telemetry_latency_ms "$TELEMETRY_START_MS")" \
  "" "" "$source_outcome" 0 known_zero_local "" not_called
exit "$rc"
