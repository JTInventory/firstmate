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
  echo "label=hint_only reason=no_manifest_or_answer_fixture external_action_authorized=false"
  exit 0
fi

[ -n "$MANIFEST" ] || die "--manifest is required when --answer-file is used"
[ -n "$ANSWER_FILE" ] || die "--answer-file is required when --manifest is used"

"$SCRIPT_DIR/fm-cognee-manifest-check.sh" --manifest "$MANIFEST" --answer-file "$ANSWER_FILE"
