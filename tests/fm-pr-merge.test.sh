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
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$dir/bin/fm-pr-lib.sh"
  cat > "$dir/bin/fm-pr-check.sh" <<'SH'
#!/usr/bin/env bash
meta="$FM_STATE_OVERRIDE/$1.meta"
sed '/^pr=/d;/^pr_head=/d' "$meta" > "$meta.tmp"
printf 'pr=%s\npr_head=%s\n' "$2" "$FAKE_HEAD" >> "$meta.tmp"
chmod 0600 "$meta.tmp"
mv "$meta.tmp" "$meta"
SH
  chmod +x "$dir/bin/fm-pr-check.sh"
  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$1 $2 $3" != 'api GET /repos/JTInventory/firstmate/pulls/47' ] || printf '%s\n' "$FAKE_HEAD"
[ "$1 $2 $3" != 'api GET /repos/JTInventory/firstmate/pulls/48' ] || printf '%s\n' "$FAKE_HEAD"
SH
  chmod +x "$dir/bin/gh-axi"
  printf 'branch=codex/task-x1\n' > "$dir/state/task-x1.meta"
  cat > "$dir/state/task-x1.pr-presentation" <<'EOF'
firstmate-pr-presentation-v1
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  chmod 0600 "$dir/state/task-x1.meta" "$dir/state/task-x1.pr-presentation"
  printf '%s\n' "$dir"
}

run_merge() {
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_PR_CHECK_BIN="$dir/bin/fm-pr-check.sh" FAKE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    GH_LOG="$dir/gh.log" "$dir/bin/fm-pr-merge.sh" "$@"
}

test_approved_url_defaults_to_squash() {
  local dir; dir=$(make_case approved)
  FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/47 || fail 'approved merge failed'
  grep -qxF 'api PUT /repos/JTInventory/firstmate/pulls/47/merge --field sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --field merge_method=squash' "$dir/gh.log" || fail 'URL was not converted to atomic squash API call'
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

test_repo_override_refuses_and_explicit_method_is_preserved() {
  local dir rc
  dir=$(make_case override)
  set +e; FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/47 -- --repo other/repo >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'repository override was accepted'
  [ ! -s "$dir/gh.log" ] || fail 'repository override reached gh-axi'

  dir=$(make_case method)
  sed -i 's#/pull/47#/pull/48#' "$dir/state/task-x1.pr-presentation"
  FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/48 -- --merge || fail 'explicit merge method failed'
  grep -qxF 'api PUT /repos/JTInventory/firstmate/pulls/48/merge --field sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --field merge_method=merge' "$dir/gh.log" || fail 'explicit merge method was overridden by squash'
  pass 'repository override refuses and explicit merge method is preserved'
}

test_approved_url_defaults_to_squash
test_refusals_do_not_record_or_merge
test_repo_override_refuses_and_explicit_method_is_preserved
