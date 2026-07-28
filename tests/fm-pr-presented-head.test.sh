#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESENT="$ROOT/bin/fm-pr-present.sh"
MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-presented-head.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

make_case() {
  local name=$1 head=${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa} dir
  dir="$TMP/$name"; mkdir -p "$dir/bin" "$dir/state"
  printf 'branch=codex/task-x1\nworktree=%s\n' "$dir" > "$dir/state/task-x1.meta"
  cat > "$dir/bin/fm-pr-check" <<'SH'
#!/usr/bin/env bash
meta="$FM_STATE_OVERRIDE/$1.meta"
sed '/^pr=/d;/^pr_head=/d' "$meta" > "$meta.tmp"
printf 'pr=%s\npr_head=%s\n' "$2" "$FAKE_HEAD" >> "$meta.tmp"
chmod 0600 "$meta.tmp"
mv "$meta.tmp" "$meta"
SH
  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2 $3" = 'api GET /repos/JTInventory/firstmate/pulls/47' ]; then
  printf '%s\n' "$FAKE_FORGE_HEAD"
fi
[ "$1" != api ] || [ "$2" != PUT ] || [ "${FAKE_PUT_FAIL:-0}" != 1 ] || exit 1
SH
  chmod +x "$dir/bin/fm-pr-check" "$dir/bin/gh-axi"
  printf '%s\n' "$head" > "$dir/head"
  printf '%s\n' "$dir"
}

run_present() {
  local dir=$1
  PATH="$dir/bin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_PR_CHECK_BIN="$dir/bin/fm-pr-check" FAKE_HEAD="$(cat "$dir/head")" \
    "$PRESENT" task-x1 https://github.com/JTInventory/firstmate/pull/47
}

run_merge() {
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_PR_CHECK_BIN="$dir/bin/fm-pr-check" FAKE_HEAD="$FAKE_FORGE_HEAD" \
    FAKE_PUT_FAIL="${FAKE_PUT_FAIL:-0}" GH_LOG="$dir/gh.log" FM_CAPTAIN_APPROVED_MERGE=1 \
    "$MERGE" task-x1 https://github.com/JTInventory/firstmate/pull/47 "$@"
}

test_present_receipt_is_immutable_across_poll_refresh() {
  local dir; dir=$(make_case immutable)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  grep -qxF 'presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$dir/state/task-x1.pr-presentation" || fail 'presented head missing'
  FAKE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$dir/bin/fm-pr-check" task-x1 https://github.com/JTInventory/firstmate/pull/47
  grep -qxF 'presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$dir/state/task-x1.pr-presentation" || fail 'ordinary poll rewrote presentation receipt'
  pass 'ordinary PR refresh cannot rewrite the presented head'
}

test_merge_binds_atomic_api_to_presented_head() {
  local dir; dir=$(make_case unchanged)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null || fail 'unchanged head merge failed'
  grep -qxF 'api PUT /repos/JTInventory/firstmate/pulls/47/merge --field sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --field merge_method=squash' "$dir/gh.log" || fail 'merge API was not atomically bound to presented head'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'successful merge retained its consumed approval receipt'
  pass 'merge uses the forge atomic expected-head primitive'
}

test_changed_head_invalidates_approval_and_never_calls_put() {
  local dir rc; dir=$(make_case changed)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  set +e
  FAKE_FORGE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'changed head was accepted'
  ! grep -q '^api PUT ' "$dir/gh.log" || fail 'stale approval reached merge API'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'stale presentation receipt was retained'
  pass 'changed head invalidates approval before merge mutation'
}

test_missing_or_malformed_receipt_and_yolo_refuse() {
  local dir rc
  dir=$(make_case missing)
  set +e; FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa FM_YOLO=1 run_merge "$dir" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'yolo bypassed missing presentation'
  printf 'version=firstmate-pr-presentation-v1\npr=https://github.com/JTInventory/firstmate/pull/47\npresented_pr_head=bad\n' > "$dir/state/task-x1.pr-presentation"
  chmod 0600 "$dir/state/task-x1.pr-presentation"
  set +e; FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'malformed receipt was accepted'
  [ ! -e "$dir/gh.log" ] || ! grep -q '^api PUT ' "$dir/gh.log" || fail 'refused receipt reached merge API'
  pass 'missing and malformed receipts fail closed even in yolo mode'
}

test_atomic_forge_rejection_invalidates_approval() {
  local dir rc; dir=$(make_case atomic-race)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  set +e
  FAKE_PUT_FAIL=1 FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'forge TOCTOU rejection was accepted'
  grep -q '^api PUT .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$dir/gh.log" || fail 'atomic request omitted presented SHA'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'rejected atomic merge retained approval'
  pass 'forge-side head race invalidates approval after atomic rejection'
}

test_gitlab_presentation_remains_unsupported_without_side_effect() {
  local dir rc; dir=$(make_case gitlab)
  set +e
  PATH="$dir/bin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PR_CHECK_BIN="$dir/bin/fm-pr-check" \
    "$PRESENT" task-x1 https://gitlab.com/group/repo/-/merge_requests/47 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'GitLab presentation was accepted as GitHub approval proof'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'GitLab refusal created a presentation receipt'
  pass 'GitLab polling compatibility is unchanged and presentation stays GitHub-only'
}

test_receipt_inode_swap_is_refused() {
  local dir rc receipt swap
  dir=$(make_case inode-swap)
  receipt="$dir/state/task-x1.pr-presentation"
  swap="$dir/state/swap-receipt"
  cat > "$receipt" <<'EOF'
firstmate-pr-presentation-v1
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  cat > "$swap" <<'EOF'
firstmate-pr-presentation-v1
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
  chmod 0600 "$receipt" "$swap"
  set +e
  RECEIPT_FILE="$receipt" SWAP_FILE="$swap" bash -c '
    . "$1"
    fm_pr_private_fd_valid() { mv -f -- "$SWAP_FILE" "$RECEIPT_FILE"; return 0; }
    fm_pr_presentation_parse "$RECEIPT_FILE"
  ' bash "$ROOT/bin/fm-pr-lib.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'receipt inode swap was accepted'
  pass 'presentation parsing refuses a stat/open inode swap'
}

test_present_receipt_is_immutable_across_poll_refresh
test_merge_binds_atomic_api_to_presented_head
test_changed_head_invalidates_approval_and_never_calls_put
test_missing_or_malformed_receipt_and_yolo_refuse
test_atomic_forge_rejection_invalidates_approval
test_gitlab_presentation_remains_unsupported_without_side_effect
test_receipt_inode_swap_is_refused
