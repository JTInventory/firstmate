#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-pr-merge.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

make_case() {
  local name=$1 dir
  dir="$TMP/$name"; mkdir -p "$dir/bin" "$dir/state"
  ln -s "$SCRIPT" "$dir/bin/fm-pr-merge.sh"
  cat > "$dir/bin/fm-pr-check.sh" <<'SH'
#!/usr/bin/env bash
echo "pr=$2" >> "$FM_STATE_OVERRIDE/$1.meta"
SH
  chmod +x "$dir/bin/fm-pr-check.sh"
  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
SH
  chmod +x "$dir/bin/gh-axi"
  : > "$dir/state/task-x1.meta"
  printf '%s\n' "$dir"
}

run_merge() {
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" GH_LOG="$dir/gh.log" "$dir/bin/fm-pr-merge.sh" "$@"
}

test_approved_url_defaults_to_squash() {
  local dir; dir=$(make_case approved)
  FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/47 || fail 'approved merge failed'
  grep -qxF 'pr merge 47 --repo JTInventory/firstmate --squash' "$dir/gh.log" || fail 'URL was not converted to number/repo/squash'
  pass 'approved URL merge records evidence and defaults to squash'
}

test_refusals_do_not_record_or_merge() {
  local dir rc; dir=$(make_case refused)
  set +e; run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/47 >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'missing captain approval was accepted'
  set +e; FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 https://gitlab.com/x/y/pull/1 >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'malformed URL was accepted'
  [ ! -s "$dir/gh.log" ] || fail 'refused merge reached gh-axi'
  pass 'missing approval and malformed URL refuse before side effects'
}

test_approved_url_defaults_to_squash
test_refusals_do_not_record_or_merge
