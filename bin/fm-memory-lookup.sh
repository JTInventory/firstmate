#!/usr/bin/env bash
# Manual read-only memory lookup for optional pre-dispatch context.
#
# This command is intentionally not wired into dispatch. It only runs when a
# firstmate invokes it by hand. Cognee output is treated as an untrusted hint;
# only local source files that can be opened are eligible for brief attachment.
# Configure a read-only lookup backend with:
#   FM_COGNEE_LOOKUP_CMD=/absolute/path/to/read-only-lookup
# The backend is executed as: "$FM_COGNEE_LOOKUP_CMD" "$query"
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

APPEND_BRIEF=
FROM_FILE=
MAX_HINT_LINES=${FM_MEMORY_LOOKUP_MAX_HINT_LINES:-40}
QUERY_PARTS=()

usage() {
  cat >&2 <<'EOF'
usage: fm-memory-lookup.sh [--append-brief path] [--from-file path] -- <question>

Runs an optional read-only Cognee lookup and prints:
  memory hint
  verified local source path
  warning

Without FM_COGNEE_LOOKUP_CMD, it exits 0 with a memory-unavailable note so
dispatch can continue without Cognee.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --append-brief)
      [ $# -ge 2 ] || { usage; exit 2; }
      APPEND_BRIEF=$2
      shift 2
      ;;
    --from-file)
      [ $# -ge 2 ] || { usage; exit 2; }
      FROM_FILE=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        QUERY_PARTS+=("$1")
        shift
      done
      ;;
    *)
      QUERY_PARTS+=("$1")
      shift
      ;;
  esac
done

QUERY=${QUERY_PARTS[*]:-}
if [ -z "$QUERY" ] && [ -z "$FROM_FILE" ]; then
  usage
  exit 2
fi

strip_ref_token() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  while :; do
    case "$value" in
      \"*|\'*|\`*|\[*|\(*|"<"*) value=${value#?} ;;
      *) break ;;
    esac
  done
  value=${value%%[[:space:],;\)]*}
  value=${value%\"}
  value=${value%\'}
  value=${value%\`}
  value=${value%]}
  value=${value%>}
  value=${value%.}
  printf '%s\n' "$value"
}

extract_source_paths() {
  local line rest path seen_file=$1
  : > "$seen_file"
  while IFS= read -r line; do
    rest=
    case "$line" in
      *SOURCE_PATH=*) rest=${line#*SOURCE_PATH=} ;;
      *SOURCE_PATH:*) rest=${line#*SOURCE_PATH:} ;;
      *source_path=*) rest=${line#*source_path=} ;;
      *source_path:*) rest=${line#*source_path:} ;;
      *"Source path:"*) rest=${line#*"Source path:"} ;;
      *"source path:"*) rest=${line#*"source path:"} ;;
    esac
    [ -n "$rest" ] || continue
    path=$(strip_ref_token "$rest")
    [ -n "$path" ] || continue
    grep -Fx -- "$path" "$seen_file" >/dev/null 2>&1 || printf '%s\n' "$path" >> "$seen_file"
  done
}

canonical_path() {
  local path=$1 dir base
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  dir=$(dirname "$path")
  base=$(basename "$path")
  [ -d "$dir" ] || return 1
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

append_brief_section() {
  local brief=$1 unavailable=$2 verified_file=$3 warnings_file=$4
  [ -n "$brief" ] || return 0
  mkdir -p "$(dirname "$brief")"
  {
    printf '\n# Optional memory lookup\n'
    printf 'Memory lookup is advisory only. Cognee hints are not proof, source truth, or approval for external action.\n'
    if [ -n "$unavailable" ]; then
      printf '\nMemory unavailable: %s\n' "$unavailable"
      printf 'Dispatch continues without memory context.\n'
    else
      printf '\nVerified local source paths:\n'
      if [ -s "$verified_file" ]; then
        sed 's/^/- /' "$verified_file"
      else
        printf 'none\n'
      fi
      printf '\nWarnings:\n'
      if [ -s "$warnings_file" ]; then
        sed 's/^/- /' "$warnings_file"
      else
        printf 'none\n'
      fi
    fi
  } >> "$brief"
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-memory-lookup.XXXXXX")
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

RAW="$TMP_DIR/raw.txt"
ERR="$TMP_DIR/err.txt"
PATHS="$TMP_DIR/paths.txt"
VERIFIED="$TMP_DIR/verified.txt"
WARNINGS="$TMP_DIR/warnings.txt"
: > "$VERIFIED"
: > "$WARNINGS"

UNAVAILABLE=
if [ -n "$FROM_FILE" ]; then
  if [ -r "$FROM_FILE" ]; then
    cat "$FROM_FILE" > "$RAW"
  else
    UNAVAILABLE="memory input file cannot be opened: $FROM_FILE"
    : > "$RAW"
  fi
elif [ -z "${FM_COGNEE_LOOKUP_CMD:-}" ]; then
  UNAVAILABLE="FM_COGNEE_LOOKUP_CMD is not set"
  : > "$RAW"
else
  case "$FM_COGNEE_LOOKUP_CMD" in
    *[[:space:]]*)
      UNAVAILABLE="FM_COGNEE_LOOKUP_CMD must be an executable path, not a shell command"
      : > "$RAW"
      ;;
    *)
      if [ ! -x "$FM_COGNEE_LOOKUP_CMD" ]; then
        UNAVAILABLE="lookup command is not executable: $FM_COGNEE_LOOKUP_CMD"
        : > "$RAW"
      elif "$FM_COGNEE_LOOKUP_CMD" "$QUERY" > "$RAW" 2> "$ERR"; then
        :
      else
        UNAVAILABLE="lookup command failed; dispatch continues without memory context"
        : > "$RAW"
      fi
      ;;
  esac
fi

if [ -z "$UNAVAILABLE" ]; then
  extract_source_paths "$PATHS" < "$RAW"
  if [ -s "$PATHS" ]; then
    while IFS= read -r source_path; do
      if canon=$(canonical_path "$source_path" 2>/dev/null) && [ -f "$canon" ] && [ -r "$canon" ] && head -c 0 "$canon" >/dev/null 2>&1; then
        printf '%s\n' "$canon" >> "$VERIFIED"
      else
        printf 'local source cannot be opened: %s\n' "$source_path" >> "$WARNINGS"
      fi
    done < "$PATHS"
  else
    printf 'no SOURCE_PATH references found; memory hint is unverified\n' >> "$WARNINGS"
  fi
fi

printf 'memory hint:\n'
if [ -n "$UNAVAILABLE" ]; then
  printf 'memory unavailable: %s\n' "$UNAVAILABLE"
elif [ -s "$RAW" ]; then
  sed -n "1,${MAX_HINT_LINES}p" "$RAW"
else
  printf 'none\n'
fi

printf '\nverified local source path:\n'
if [ -s "$VERIFIED" ]; then
  sed 's/^/- /' "$VERIFIED"
else
  printf 'none\n'
fi

printf '\nwarning:\n'
if [ -n "$UNAVAILABLE" ]; then
  printf -- '- %s\n' "$UNAVAILABLE"
  printf -- '- dispatch continues without memory context\n'
elif [ -s "$WARNINGS" ]; then
  sed 's/^/- /' "$WARNINGS"
else
  printf 'none\n'
fi

append_brief_section "$APPEND_BRIEF" "$UNAVAILABLE" "$VERIFIED" "$WARNINGS"

# Keep this command fail-closed for authority but non-blocking for dispatch:
# operational failures are surfaced as warnings and exit 0.
exit 0
