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
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
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
case "$1 $2 $3" in
  'api GET /repos/JTInventory/firstmate/pulls/47'|'api GET /repos/JTInventory/firstmate/pulls/48')
    head=$(printf '%s' "$FAKE_HEAD" | base64 | tr -d '\n')
    base_ref=$(printf '%s' "${FAKE_BASE_REF:-main}" | base64 | tr -d '\n')
    base=$(printf '%s' "$FAKE_BASE" | base64 | tr -d '\n')
    repo=$(printf '%s' JTInventory/firstmate | base64 | tr -d '\n')
    ref=$(printf '%s' "${FAKE_HEAD_REF:-codex/task-x1}" | base64 | tr -d '\n')
    printf 'head_b64: %s\nbase_ref_b64: %s\nbase_b64: %s\nhead_repo_b64: %s\nhead_ref_b64: %s\n' \
      "$head" "$base_ref" "$base" "$repo" "$ref"
    ;;
esac
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit "${FAKE_PUT_FAIL:-0}"
SH
  chmod +x "$dir/bin/gh-axi" "$dir/bin/gh"
  printf 'branch=codex/task-x1\n' > "$dir/state/task-x1.meta"
  cat > "$dir/state/task-x1.pr-presentation" <<'EOF'
firstmate-pr-presentation-v2
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
presented_pr_base_ref=main
presented_pr_base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
presentation_nonce=11111111111111111111111111111111
EOF
  chmod 0600 "$dir/state/task-x1.meta" "$dir/state/task-x1.pr-presentation"
  printf '%s\n' "$dir"
}

run_merge() {
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_PR_CHECK_BIN="$dir/bin/fm-pr-check.sh" FAKE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FAKE_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    FM_CAPTAIN_APPROVED_PR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FM_CAPTAIN_APPROVED_PRESENTATION_NONCE=11111111111111111111111111111111 \
    GH_LOG="$dir/gh.log" "$dir/bin/fm-pr-merge.sh" "$@"
}

test_approved_url_defaults_to_squash() {
  local dir; dir=$(make_case approved)
  FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/47 || fail 'approved merge failed'
  grep -qxF 'api --method PUT /repos/JTInventory/firstmate/pulls/47/merge --raw-field sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --raw-field merge_method=squash' "$dir/gh.log" || fail 'URL was not converted to atomic squash API call'
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
  grep -qxF 'api --method PUT /repos/JTInventory/firstmate/pulls/48/merge --raw-field sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --raw-field merge_method=merge' "$dir/gh.log" || fail 'explicit merge method was overridden by squash'
  pass 'repository override refuses and explicit merge method is preserved'
}

test_compatible_merge_options_are_translated() {
  local dir; dir=$(make_case options)
  FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 \
    https://github.com/JTInventory/firstmate/pull/47 -- \
    --squash --subject '123' --body '@not-a-file' --delete-branch \
    || fail 'compatible merge options failed'
  grep -qxF 'api --method PUT /repos/JTInventory/firstmate/pulls/47/merge --raw-field sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --raw-field merge_method=squash --raw-field commit_title=123 --raw-field commit_message=@not-a-file' "$dir/gh.log" \
    || fail 'subject and body were not preserved as literal strings'
  grep -qxF 'api DELETE /repos/JTInventory/firstmate/git/refs/heads/codex/task-x1' "$dir/gh.log" \
    || fail 'requested remote branch deletion was not preserved'
  pass 'compatible merge options are translated to atomic API calls'
}

test_branch_ref_is_decoded_and_percent_encoded() {
  local dir ref expected name
  while IFS='|' read -r name ref expected; do
    dir=$(make_case "encoded-ref-$name")
    FAKE_HEAD_REF="$ref" FM_CAPTAIN_APPROVED_MERGE=1 \
      run_merge "$dir" task-x1 https://github.com/JTInventory/firstmate/pull/47 -- --delete-branch \
      || fail "valid $name branch ref was refused"
    grep -qxF "api DELETE /repos/JTInventory/firstmate/git/refs/heads/$expected" "$dir/gh.log" \
      || fail "$name branch ref was not decoded and encoded by path component"
  done <<'EOF'
keyword|true|true
numeric|123|123
punctuation|feature/#100%,one|feature/%23100%25%2Cone
EOF
  pass 'branch deletion decodes TOON transport and encodes the API path'
}

test_deferred_merge_option_is_explicitly_refused() {
  local dir rc; dir=$(make_case auto)
  set +e
  FM_CAPTAIN_APPROVED_MERGE=1 run_merge "$dir" task-x1 \
    https://github.com/JTInventory/firstmate/pull/47 -- --auto \
    >"$dir/stdout" 2>"$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'deferred auto-merge was accepted'
  grep -q 'incompatible with an immediate merge bound to the captain-approved head' "$dir/stderr" \
    || fail 'auto-merge refusal did not explain the atomic approval conflict'
  [ ! -s "$dir/gh.log" ] || fail 'refused auto-merge reached gh-axi'
  pass 'deferred merge options are deliberately refused'
}

test_approved_url_defaults_to_squash
test_refusals_do_not_record_or_merge
test_repo_override_refuses_and_explicit_method_is_preserved
test_compatible_merge_options_are_translated
test_branch_ref_is_decoded_and_percent_encoded
test_deferred_merge_option_is_explicitly_refused
